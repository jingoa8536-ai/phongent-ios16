import Foundation
import Combine
import UIKit

struct FleetDelivery:Codable,Identifiable {
    var id:String;var deviceID:String;var name:String;var status:String;var reply="";var phase="";var exchange:NativeChatExchange?;var task:String?;var conversation:String?;var needsRetry:Bool?
}
struct FleetBatch:Codable,Identifiable {var id:String;var text:String;var time:Double;var deliveries:[FleetDelivery]}
@MainActor final class FleetChatStore:ObservableObject {
    @Published var batches:[FleetBatch]=[]
    @Published var sending=false
    private var subscriptions:[String:AnyCancellable]=[:]
    init(){if let data=UserDefaults.standard.data(forKey:"fleetChats"),let saved=try? JSONDecoder().decode([FleetBatch].self,from:data){batches=saved}}
    func observe(_ agents:[NearbyAgent]) {
        let ids=Set(agents.map(\.id))
        subscriptions=subscriptions.filter{ids.contains($0.key)}
        for agent in agents where subscriptions[agent.id]==nil {
            let deviceID=agent.id
            subscriptions[agent.id]=agent.client.$snapshot.sink{[weak self] snapshot in Task{@MainActor in self?.update(device:deviceID,snapshot:snapshot)}}
        }
    }
    func clearHistory(){batches.removeAll();save()}
    private func save(){if let data=try? JSONEncoder().encode(Array(batches.suffix(100))){UserDefaults.standard.set(data,forKey:"fleetChats")}}
    private func update(device:String,snapshot:AgentSnapshot){
        for task in snapshot.queuedTasks ?? [] {
            for i in batches.indices{if let j=batches[i].deliveries.firstIndex(where:{$0.id==task.id && $0.deviceID==device}){batches[i].deliveries[j].needsRetry=false;batches[i].deliveries[j].status=["queued":"已排队","dispatching":"正在启动","running":"执行中","completed":"已完成","failed":"执行失败","cancelled":"已取消","uncertain":"待核实"][task.state] ?? task.state;if let result=task.result,!result.isEmpty{batches[i].deliveries[j].reply=result};if !task.error.isEmpty{batches[i].deliveries[j].reply=task.error}}}
        }
        save()
        guard let command=snapshot.commandId,!command.isEmpty else{return}
        for i in batches.indices {
            guard let j=batches[i].deliveries.firstIndex(where:{$0.id==command && $0.deviceID==device}) else{continue}
            batches[i].deliveries[j].phase=snapshot.phase;batches[i].deliveries[j].status=snapshot.title;batches[i].deliveries[j].reply=snapshot.detail
            if var ex=snapshot.exchanges?.last,ex.goal==(batches[i].deliveries[j].task ?? batches[i].text){ex.goal="";batches[i].deliveries[j].exchange=ex}
            save();return
        }
    }
    func retry(_ delivery:FleetDelivery,agent:NearbyAgent) async {
        guard !sending,agent.client.connected,agent.client.snapshot.taskQueueVersion==1,
              let i=batches.firstIndex(where:{$0.deliveries.contains{$0.id==delivery.id}}),
              let j=batches[i].deliveries.firstIndex(where:{$0.id==delivery.id}) else{return}
        sending=true;defer{sending=false}
        let accepted=await agent.client.command("task",text:delivery.task ?? batches[i].text,commandId:delivery.id,expectedConversation:delivery.conversation)
        batches[i].deliveries[j].needsRetry = !accepted
        batches[i].deliveries[j].status=accepted ? "已接收":(agent.client.chatMessages.last(where:{$0.id==delivery.id+"-user"})?.status ?? "提交结果未确认")
        save()
    }
    func send(_ text:String,to agents:[NearbyAgent],tasks:[String:String]?=nil,conversations:[String:String]=[:]) async {
        let targets=agents.filter{$0.approved && $0.client.connected && !$0.demo && (tasks == nil || tasks?[$0.id] != nil)}
        guard !sending,!targets.isEmpty else{return}
        sending=true;defer{sending=false}
        let batch=FleetBatch(id:UUID().uuidString,text:text,time:Date().timeIntervalSince1970,deliveries:targets.map{.init(id:UUID().uuidString,deviceID:$0.id,name:$0.name,status:"提交中",task:tasks?[$0.id],conversation:conversations[$0.id] ?? $0.client.snapshot.currentConversationId)})
        batches.append(batch);save()
        for start in stride(from:0,to:batch.deliveries.count,by:3){
        await withTaskGroup(of:Void.self){group in
            for target in batch.deliveries.dropFirst(start).prefix(3) {
                guard let agent=targets.first(where:{$0.id==target.deviceID}) else{continue}
                group.addTask{@MainActor in
                    let client=agent.client
                    let result:String
                    if !client.connected{result="设备已断开，未发送"}
                    else if (client.snapshot.busy && client.snapshot.taskQueueVersion != 1) || client.sending || client.switchingChat{result="设备忙，未发送"}
                    else{await client.command("task",text:target.task ?? text,commandId:target.id,expectedConversation:target.conversation);result=client.chatMessages.first(where:{$0.id==target.id+"-user"})?.status ?? "提交结果未确认"}
                    if let i=self.batches.firstIndex(where:{$0.id==batch.id}),let j=self.batches[i].deliveries.firstIndex(where:{$0.id==target.id}),self.batches[i].deliveries[j].phase.isEmpty{self.batches[i].deliveries[j].status=result;self.batches[i].deliveries[j].needsRetry = !["已接收","已排队","completed","failed","cancelled","uncertain"].contains(result);self.save()}
                }
            }
        }
        }
    }
}

struct FleetTaskPlan:Decodable {
    struct Card:Decodable {var title:String;var body:String;var accent:String?}
    struct Assignment:Decodable {var deviceID:String;var task:String;var cards:[Card]?}
    var assignments:[Assignment]
    var clarification:String?
    func validated(allowed:Set<String>) throws -> [String:String] {
        if let clarification,!clarification.isEmpty{throw ModelFailure(message:clarification)}
        var result:[String:String]=[:]
        for item in assignments {
            guard allowed.contains(item.deviceID),result[item.deviceID]==nil,item.task.count<=8000,!item.task.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ModelFailure(message:"任务分配结果无效，未发送，请重新描述")}
            result[item.deviceID]=item.task
        }
        guard !result.isEmpty else{throw ModelFailure(message:"没有可分配的任务，未发送")}
        return result
    }
}
@MainActor enum FleetTaskRouter {
    static func plan(_ text:String,agents:[NearbyAgent],imageCount:Int=0,groups:[String:String]=[:]) async throws -> FleetTaskPlan {
        let catalog=ModelCatalog.shared
        guard let selected=catalog.selection(.dispatch),let provider=catalog.saved.providers.first(where:{$0.id==selected.providerId}) else{throw ModelFailure(message:"请在设置 → 主控模型中选择任务下发模型")}
        let devices=agents.map{["deviceID":$0.id,"name":$0.name,"group":groups[$0.id] ?? "默认组"]}
        let roster=String(data:try JSONSerialization.data(withJSONObject:devices),encoding:.utf8)!
        let system="""
        你是任务路由器，只识别目标设备、拆分并转述任务，不执行任务，也不创作任务要求的正文或图片。目标安卓 agent 拥有执行工具；你的输出会由程序下发给它们。你没有工具不是无法分发的理由，不要以直接对话模式回答或要求用户为你授予设备权限。设备清单：\(roster)。用户附图数量：\(imageCount)，这些图会随任务下发；你不能凭空描述其内容。
        输出纯 JSON：{"assignments":[{"deviceID":"清单中的ID","task":"发给该设备的完整指令","cards":[{"title":"图卡标题","body":"图卡正文","accent":"#287A76"}]}],"clarification":""}。
        清单包含设备组别。按组分配时展开到该组所有设备；组内点名任务优先于该组通用任务，其余成员执行组任务。可以同时给不同组不同任务；组名与设备名歧义时澄清。
        用户可以直接说“A干某事、B干某事”，不需要@；设备名或唯一简称均可，@只是快捷方式。其余设备指清单中未被明确指定的设备；@全部或所有设备表示全部。
        搜索、打开应用、截图、查找或发送图片、写文案、制作图卡等均作为任务交给目标 agent，不能在分发阶段自行完成。cards 必须为空数组。
        用户要求去应用查找图片时，原样保留查找与回传要求，不要误认为必须先上传图片。素材不足或执行权限问题由执行端核实并询问；你只澄清目标设备或任务分工的真实歧义。
        不要把某台设备的专属任务发给其他设备。不添加用户未要求的操作。保留截图、汇报等要求。
        同一设备多个任务合并成一条。无指定对象的普通指令默认全部设备执行。
        名称重复、提及不存在的设备或分工不明确时，assignments为空，clarification说明需要澄清什么。不得猜测对象。
        """
        let raw=try await catalog.reply(provider:provider,model:selected.model,messages:[["role":"system","content":system],["role":"user","content":text]],session:UUID().uuidString,onText:{_ in})
        var json=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        if json.hasPrefix("```"){json=json.components(separatedBy:"\n").dropFirst().dropLast().joined(separator:"\n")}
        let plan=try JSONDecoder().decode(FleetTaskPlan.self,from:Data(json.utf8))
        guard plan.assignments.allSatisfy({$0.cards?.isEmpty != false}) else{throw ModelFailure(message:"分发模型返回了创作内容，任务未发送，请重试")}
        _ = try plan.validated(allowed:Set(agents.map(\.id)))
        return plan
    }
}

@MainActor enum FleetContentCard {
    static func render(_ card:FleetTaskPlan.Card)throws->Data{
        guard !card.title.isEmpty,card.title.count<=60,!card.body.isEmpty,card.body.count<=500 else{throw ModelFailure(message:"图卡内容过长，请减少单张文字")}
        let raw=(card.accent ?? "287A76").replacingOccurrences(of:"#",with:"")
        let hex=UInt32(raw,radix:16) ?? 0x287A76
        let accent=UIColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1)
        let titleStyle: [NSAttributedString.Key:Any]=[.font:UIFont.boldSystemFont(ofSize:64),.foregroundColor:accent]
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=14
        let bodyStyle: [NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:40),.foregroundColor:UIColor(red:0.14,green:0.15,blue:0.17,alpha:1),.paragraphStyle:paragraph]
        let titleHeight=(card.title as NSString).boundingRect(with:CGSize(width:920,height:1200),options:.usesLineFragmentOrigin,attributes:titleStyle,context:nil).height
        let bodyHeight=(card.body as NSString).boundingRect(with:CGSize(width:920,height:1400),options:.usesLineFragmentOrigin,attributes:bodyStyle,context:nil).height
        guard 210+titleHeight+bodyHeight<1360 else{throw ModelFailure(message:"图卡排版超出范围，请缩短内容")}
        let format=UIGraphicsImageRendererFormat();format.scale=1
        return UIGraphicsImageRenderer(size:CGSize(width:1080,height:1440),format:format).pngData{ctx in
            UIColor(red:247/255,green:247/255,blue:242/255,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:1080,height:1440))
            accent.setFill();UIBezierPath(roundedRect:CGRect(x:64,y:72,width:952,height:20),cornerRadius:10).fill()
            (card.title as NSString).draw(in:CGRect(x:80,y:150,width:920,height:titleHeight+8),withAttributes:titleStyle)
            (card.body as NSString).draw(in:CGRect(x:80,y:210+titleHeight,width:920,height:bodyHeight+8),withAttributes:bodyStyle)
        }
    }
}
