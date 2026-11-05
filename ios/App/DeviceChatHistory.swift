import Foundation

struct DeviceChatMessage:Codable,Identifiable {
    var id:String
    var role:String
    var text:String
    var status:String
    var time:Double
}
enum DeviceChatHistory {
    static func read(_ device:String)->[DeviceChatMessage] {
        guard let data=UserDefaults.standard.data(forKey:"deviceChat."+device) else{return []}
        return (try? JSONDecoder().decode([DeviceChatMessage].self,from:data)) ?? []
    }
    static func save(_ messages:[DeviceChatMessage],device:String) {
        if let data=try? JSONEncoder().encode(Array(messages.suffix(200))) {UserDefaults.standard.set(data,forKey:"deviceChat."+device)}
    }
    static func merge(_ snapshot:AgentSnapshot,into messages:inout [DeviceChatMessage]) {
        if let current=snapshot.currentConversationId,current != snapshot.conversationId {return}
        guard !snapshot.runId.isEmpty,!snapshot.isDemo,snapshot.phase != "idle" else{return}
        if let goal=snapshot.goal,!goal.isEmpty {
            let key=(snapshot.commandId?.isEmpty == false ? snapshot.commandId! : snapshot.runId)+"-user"
            if !messages.contains(where:{$0.id==key || $0.id==snapshot.runId+"-agent"}) {messages.append(.init(id:key,role:"user",text:goal,status:"已接收",time:snapshot.updatedAt))}
        }
        if let command=snapshot.commandId,!command.isEmpty,
           let index=messages.firstIndex(where:{$0.id==command+"-user"}) {
            messages[index].status=snapshot.title
        }
        let key=snapshot.runId+"-agent"
        let text=snapshot.detail.isEmpty ? snapshot.title : snapshot.detail
        if let index=messages.firstIndex(where:{$0.id==key}) {messages[index].text=text;messages[index].status=snapshot.title}
        else {messages.append(.init(id:key,role:"agent",text:text,status:snapshot.title,time:snapshot.updatedAt))}
        if messages.count>200 {messages=Array(messages.suffix(200))}
    }
}
