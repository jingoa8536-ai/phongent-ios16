import SwiftUI
import Combine
import PhotosUI

struct FleetWorkspace:View {
    @ObservedObject var hub:NearbyHub
    @StateObject private var store=FleetChatStore()
    @State private var collapsedGroups:Set<String>=[]
    @State private var selection:String?
    @State private var selectedGroup:String?
    @State private var input=""
    @State private var photoItems:[PhotosPickerItem]=[]
    @State private var photos:[Data]=[]
    @State private var loadingPhotos=false
    @State private var planning=false
    @State private var stoppingAll=false
    @State private var pressingDevice:String?
    @State private var mentionedDevice:String?
    @State private var routingError:String?
    @State private var showModels=false
    @State private var showKnowledge=false
    @State private var rename=false
    @State private var name=""
    @State private var templates:[String:String]=UserDefaults.standard.dictionary(forKey:"fleetTaskTemplates") as? [String:String] ?? [:]
    @State private var templateName=""
    @State private var savingTemplate=false
    @FocusState private var focused:Bool
    init(hub:NearbyHub,initialSelection:String?=nil){self.hub=hub;_selection=State(initialValue:initialSelection)}
    private var allAgents:[NearbyAgent]{hub.agents.filter{$0.approved && !$0.demo}}
    private var agents:[NearbyAgent]{allAgents.filter{selectedGroup==nil || hub.group(of:$0.id)==selectedGroup}}
    private var chosen:NearbyAgent?{agents.first{$0.id==selection}}
    var body:some View {
        HStack(spacing:0){
            ScrollView{LazyVStack(spacing:14){
                Button{focused=false;selection=nil;selectedGroup=nil}label:{VStack(spacing:4){Image(systemName:"square.grid.2x2.fill").font(.title2).frame(width:52,height:52);Text("全部").font(.caption2)}.padding(4).background(selection==nil ? Color.mint.opacity(0.14):.clear,in:RoundedRectangle(cornerRadius:16))}.buttonStyle(.plain)
                ForEach(hub.groupNames,id:\.self){group in
                    HStack(spacing:0){Button{selection=nil;selectedGroup=group}label:{Text(group).font(.caption2).lineLimit(2)};Button{if !collapsedGroups.insert(group).inserted{collapsedGroups.remove(group)}}label:{Image(systemName:collapsedGroups.contains(group) ? "chevron.right":"chevron.down").font(.caption2).frame(width:22,height:32)}}
                    if !collapsedGroups.contains(group){ForEach(allAgents.filter{hub.group(of:$0.id)==group}){agent in
                    VStack(spacing:1){AoraAnimatedAvatar(phase:agent.phase,active:agent.client.connected,shape:agent.avatarShape,hue:agent.avatarHue).frame(width:58,height:58);Text(agent.name).font(.caption2).lineLimit(2).frame(width:60);Circle().fill(agent.client.connected ? .green:.gray).frame(width:5,height:5)}.padding(.vertical,5).background(selection==agent.id ? Color.mint.opacity(0.14):.clear,in:RoundedRectangle(cornerRadius:16))
                    .frame(width:68,height:92)
                    .background(Color.mint.opacity(pressingDevice==agent.id || mentionedDevice==agent.id ? 0.18:0),in:RoundedRectangle(cornerRadius:16))
                    .animation(.spring(response:0.28,dampingFraction:0.65),value:pressingDevice)
                    .animation(.spring(response:0.28,dampingFraction:0.65),value:mentionedDevice)
                    .overlay{AvatarTouchSurface(label:agent.name,onTap:{focused=false;selectedGroup=nil;selection=agent.id;hub.select(agent)},onPress:{down in pressingDevice=down ? agent.id:nil},onLongPress:{
                        guard !planning else{return}
                        selection=nil;selectedGroup=nil;input += (input.isEmpty ? "":" ")+"@"+agent.name+" ";focused=true
                        mentionedDevice=agent.id
                        Task{@MainActor in try? await Task.sleep(for:.milliseconds(450));if mentionedDevice==agent.id{mentionedDevice=nil}}
                    })}

                }
                }}
            }.padding(.vertical,10)}.frame(width:74)
            Divider()
            VStack(spacing:0){
                HStack{
                    Button(chosen?.name ?? selectedGroup ?? "全部设备"){if let chosen{name=chosen.name;rename=true}}.font(.headline).foregroundStyle(.primary).disabled(chosen==nil)
                    Spacer()
                    Button {stoppingAll=true;Task {
                        var failed:[String]=[]
                        for agent in allAgents {if !(await agent.client.stopAllTasks()){failed.append(agent.name)}}
                        stoppingAll=false
                        if !failed.isEmpty{routingError="结束任务未成功："+failed.joined(separator:"、")}
                    }} label:{Image(systemName:"stop.circle.fill").foregroundStyle(.red).frame(width:36,height:36)}
                    .disabled(stoppingAll).accessibilityLabel("结束所有 agent 的任务")
                    Menu{
                        if !templates.isEmpty{Menu("任务模板"){ForEach(templates.keys.sorted(),id:\.self){title in Menu(title){Button("使用"){input=templates[title] ?? "";selection=nil};Button("删除",role:.destructive){templates.removeValue(forKey:title);UserDefaults.standard.set(templates,forKey:"fleetTaskTemplates")}}}}}
                        Button("保存输入为模板"){templateName=String(input.prefix(24));savingTemplate=true}.disabled(input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        ForEach(hub.groupNames,id:\.self){group in Button("分组 · "+group){selectedGroup=group;selection=nil}}
                        Button("模型设置",systemImage:"slider.horizontal.3"){showModels=true}
                        Button("记忆与技能",systemImage:"heart"){showKnowledge=true}
                        if chosen==nil {Button("删除聊天记录",systemImage:"trash",role:.destructive){store.clearHistory()}.disabled(planning || store.sending)}
                    }label:{Image(systemName:"ellipsis").frame(width:36,height:36)}
                }.padding(.horizontal,14)
                allChat
            }

        }.background(Color(uiColor:.systemGroupedBackground))
        .safeAreaInset(edge:.bottom,spacing:0){composer}
        .onChange(of:photoItems){items in
            loadingPhotos=true
            Task{@MainActor in
                defer{loadingPhotos=false}
                do{var loaded:[Data]=[]
                    for item in items{guard let raw=try await item.loadTransferable(type:Data.self),let image=UIImage(data:raw),let data=image.jpegData(compressionQuality:0.8),data.count<=8*1024*1024 else{throw ModelFailure(message:"图片不可读取或超过 8 MB")};loaded.append(data)}
                    photos=loaded
                }catch{routingError=error.localizedDescription;photos=[]}
            }
        }
        .task(id:allAgents.map{$0.id}.joined()){store.observe(allAgents)}
        .alert("保存任务模板",isPresented:$savingTemplate){TextField("模板名称",text:$templateName);Button("取消",role:.cancel){};Button("保存"){let title=String(templateName.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40));if !title.isEmpty{templates[title]=String(input.prefix(8000));UserDefaults.standard.set(templates,forKey:"fleetTaskTemplates")}}}
        .sheet(isPresented:$showModels){NavigationStack{ModelSettingsView()}}
        .alert("任务未发送",isPresented:Binding(get:{routingError != nil},set:{if !$0{routingError=nil}})){Button("好",role:.cancel){routingError=nil}}message:{Text(routingError ?? "")}
        .sheet(isPresented:$showKnowledge){NavigationStack{KnowledgeView(hub:hub,defaultDevice:chosen?.id ?? agents.first?.id ?? "")}}
        .alert("设备名称",isPresented:$rename){TextField("名称",text:$name);Button("取消",role:.cancel){};Button("保存"){if let chosen{hub.rename(chosen,to:name)}}}
    }
    private func sendTasks(){
        let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        let devices=agents.filter{$0.client.connected && (selection==nil || $0.id==selection)}
        planning=true;focused=false
        Task{@MainActor in
            defer{planning=false}
            do{
                let plan=try await FleetTaskRouter.plan(text,agents:devices,imageCount:photos.count,groups:hub.deviceGroups)
                var tasks=try plan.validated(allowed:Set(devices.map(\.id)))
                var generated:[String:[Data]]=[:]
                for assignment in plan.assignments{
                    guard (assignment.cards?.count ?? 0)<=4 else{throw ModelFailure(message:"单设备图卡最多4张")}
                    generated[assignment.deviceID]=try (assignment.cards ?? []).map{try FleetContentCard.render($0)}
                }
                var conversations:[String:String]=[:]
                for device in devices where tasks[device.id] != nil {
                    let devicePhotos=photos+(generated[device.id] ?? [])
                    guard let conversation=device.client.snapshot.currentConversationId,!conversation.isEmpty else{if !devicePhotos.isEmpty{throw ModelFailure(message:"请先在 "+device.name+" 中打开一个聊天，再发送图片")};continue}
                    if !devicePhotos.isEmpty{conversations[device.id]=conversation}
                    for image in devicePhotos {
                        let body=try JSONSerialization.data(withJSONObject:["conversationId":conversation,"data":image.base64EncodedString()])
                        let data=try await device.client.request("/attachments",body:body)
                        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let line=object["line"] as? String else{throw ModelFailure(message:"图片上传结果无效")}
                        tasks[device.id,default:""] += "\n"+line
                    }
                }
                guard devices.filter({tasks[$0.id] != nil}).allSatisfy({$0.client.connected}) else{throw ModelFailure(message:"目标设备已断开，任务未发送")}
                input="";photos=[];photoItems=[]
                await store.send(text,to:devices,tasks:tasks,conversations:conversations)
            }catch{routingError=error.localizedDescription}
        }
    }

    private var composer:some View {

                VStack(alignment:.leading,spacing:8){
                    if !photos.isEmpty {
                        ScrollView(.horizontal){
                            HStack(spacing:10){
                                ForEach(Array(photos.enumerated()),id:\.offset){index,data in
                                    if let image=UIImage(data:data){
                                        Image(uiImage:image).resizable().scaledToFill()
                                            .frame(width:56,height:56).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius:8))
                                            .overlay(alignment:.topTrailing){
                                                Button{
                                                    guard photos.indices.contains(index),photoItems.indices.contains(index) else{return}
                                                    photos.remove(at:index)
                                                    photoItems.remove(at:index)
                                                }label:{
                                                    Image(systemName:"minus.circle.fill")
                                                        .font(.system(size:20,weight:.semibold))
                                                        .symbolRenderingMode(.palette)
                                                        .foregroundStyle(.white,Color.black.opacity(0.7))
                                                        .frame(width:32,height:32)
                                                        .contentShape(Rectangle())
                                                }.buttonStyle(.plain)
                                                .disabled(planning || loadingPhotos || store.sending)
                                                .accessibilityLabel("移除第\(index+1)张图片")
                                            }
                                    }
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                    if planning {Label("正在分配任务…",systemImage:"sparkles").font(.caption)}
                HStack(alignment:.bottom,spacing:10){
                    TextField("发消息或描述各设备的任务",text:$input,axis:.vertical).lineLimit(1...5).focused($focused).disabled(planning).padding(.horizontal,14).padding(.vertical,12).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:20))
                    PhotosPicker(selection:$photoItems,maxSelectionCount:4,matching:.images){Image(systemName:"plus.circle").font(.system(size:30,weight:.regular)).frame(width:42,height:46)}.disabled(planning || loadingPhotos).accessibilityLabel("添加图片")
                    if !input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{Button{sendTasks()}label:{Image(systemName:"arrow.up.circle.fill").font(.system(size:32)).frame(width:40,height:46)}.disabled(loadingPhotos || planning || store.sending || !agents.contains{$0.client.connected})}
                    if focused{Button{focused=false}label:{Image(systemName:"keyboard.chevron.compact.down").frame(width:28,height:46)}.accessibilityLabel("收起键盘")}
                }

                }.padding(.horizontal,14).padding(.vertical,10).background(.ultraThinMaterial)

    }
    private var allChat:some View {
        ScrollViewReader{proxy in
            ScrollView{
                LazyVStack(alignment:.leading,spacing:18){
                    ForEach(store.batches.filter{($0.deliveries.contains{delivery in agents.contains{$0.id==delivery.deviceID} && (selection==nil || delivery.deviceID==selection)})}){batch in
                        HStack{Spacer(minLength:30);Text(batch.text).padding(12).foregroundStyle(.white).background(.blue,in:RoundedRectangle(cornerRadius:18))}
                        ForEach(batch.deliveries.filter{delivery in agents.contains{$0.id==delivery.deviceID} && (selection==nil || delivery.deviceID==selection)}){delivery in
                            VStack(alignment:.leading,spacing:8){
                                HStack(spacing:4){if let agent=agents.first(where:{$0.id==delivery.deviceID}){AoraAnimatedAvatar(phase:delivery.phase,active:delivery.phase=="running",shape:agent.avatarShape,hue:agent.avatarHue).frame(width:30,height:30)};Text(delivery.name).font(.caption.bold());Spacer();Text(delivery.status).font(.caption2).foregroundStyle(.secondary)}
                                if let task=delivery.task {Text(task).font(.caption).foregroundStyle(.secondary)}
                                if delivery.needsRetry==true,let agent=agents.first(where:{$0.id==delivery.deviceID}),agent.client.snapshot.taskQueueVersion==1{
                                    Button("重试此设备"){Task{await store.retry(delivery,agent:agent)}}.disabled(store.sending || !agent.client.connected)
                                }

                                if let ex=delivery.exchange {NativeExchangeView(exchange:ex,client:agents.first{$0.id==delivery.deviceID}?.client)}else if !delivery.reply.isEmpty{AndroidMarkdown(text:delivery.reply)}
                            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:16))
                        }
                    }
                    Color.clear.frame(height:1).id("fleet-bottom")
                }.padding(12)
            }.scrollDismissesKeyboard(.interactively).onTapGesture{focused=false}
            .onChange(of:store.batches.count){_ in proxy.scrollTo("fleet-bottom",anchor:.bottom)}
            .overlay(alignment:.bottomTrailing){FleetPipStack(agents:agents).padding(8)}

        }
    }
}
struct FleetPipStack:View {
    var agents:[NearbyAgent]
    @AppStorage("showAgentWindows") private var showWindows=true
    var body:some View {if showWindows{ScrollView(.horizontal){HStack(alignment:.bottom,spacing:8){ForEach(agents){agent in FleetPip(agent:agent)}}}.fixedSize(horizontal:false,vertical:true)}}
}
struct FleetPip:View {
    @ObservedObject var agent:NearbyAgent
    @StateObject private var video=RemoteVideo()
    @Environment(\.scenePhase) private var phase
    @State private var expanded=false
    @State private var offset=CGSize.zero
    @GestureState private var drag=CGSize.zero
    var body:some View {
        ZStack{if video.live {VStack(spacing:3){Text(agent.name).font(.caption2).lineLimit(1);VirtualControlSurface(video:video,bridge:agent.client,width:expanded ? 150:82,height:(expanded ? 150:82)/video.aspect,expanded:$expanded)}.frame(width:expanded ? 150:82).offset(x:offset.width+drag.width,y:offset.height+drag.height).gesture(DragGesture(minimumDistance:12).updating($drag){v,s,_ in if !video.virtualControlled{s=v.translation}}.onEnded{v in guard !video.virtualControlled else{return};offset=CGSize(width:max(-40,min(40,offset.width+v.translation.width)),height:max(-220,min(0,offset.height+v.translation.height)))},including:video.virtualControlled ? .subviews:.all)}}
        .frame(width:video.live ? (expanded ? 150:82):0,height:video.live ? (expanded ? 150:82)/video.aspect+(expanded && video.canControlVirtual ? 65:20):0)
        .task{video.start(agent.client,virtual:true)}.onDisappear{video.stop()}
        .onChange(of:phase){value in if value == .active{video.start(agent.client,virtual:true)}else{video.stop()}}
    }
}

/// Fixed hit region; animation never changes the touch geometry.
private struct AvatarTouchSurface:UIViewRepresentable {
    var label:String
    var onTap:()->Void
    var onPress:(Bool)->Void
    var onLongPress:()->Void
    func makeUIView(context:Context)->AvatarTouchView{AvatarTouchView()}
    func updateUIView(_ view:AvatarTouchView,context:Context){
        view.accessibilityLabel=label;view.tap=onTap;view.press=onPress;view.hold=onLongPress
    }
}
private final class AvatarTouchView:UIView {
    var tap:(()->Void)?;var press:((Bool)->Void)?;var hold:(()->Void)?
    private var pending:DispatchWorkItem?;private var origin=CGPoint.zero
    private var completed=false;private var cancelled=false
    private let sweep=CALayer()
    override init(frame:CGRect){super.init(frame:frame);isAccessibilityElement=true;accessibilityTraits = .button;layer.cornerRadius=16;clipsToBounds=true;sweep.backgroundColor=UIColor.systemMint.withAlphaComponent(0.24).cgColor;layer.addSublayer(sweep)}
    required init?(coder:NSCoder){fatalError()}
    override func accessibilityActivate()->Bool{tap?();return true}
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?){
        guard let touch=touches.first else{return};origin=touch.location(in:self);completed=false;cancelled=false
        sweep.frame=CGRect(x:0,y:0,width:bounds.width,height:0)
        let animation=CABasicAnimation(keyPath:"bounds.size.height");animation.fromValue=0;animation.toValue=bounds.height;animation.duration=0.45
        sweep.anchorPoint=CGPoint(x:0.5,y:0);sweep.position=CGPoint(x:bounds.midX,y:0);sweep.bounds=CGRect(x:0,y:0,width:bounds.width,height:bounds.height);sweep.add(animation,forKey:"fill")
        let work=DispatchWorkItem{[weak self] in guard let self,!self.cancelled else{return};self.completed=true;self.press?(true);UIImpactFeedbackGenerator(style:.light).impactOccurred();self.hold?()};pending=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.45,execute:work)
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?){if let p=touches.first?.location(in:self),hypot(p.x-origin.x,p.y-origin.y)>24{cancelled=true;reset()}}
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?){let shouldTap = !completed && !cancelled;reset();if shouldTap{tap?()}}
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?){cancelled=true;reset()}
    private func reset(){pending?.cancel();pending=nil;press?(false);sweep.removeAllAnimations();sweep.bounds.size.height=0}
    override func didMoveToWindow(){super.didMoveToWindow();if window==nil{cancelled=true;reset()}}
}
