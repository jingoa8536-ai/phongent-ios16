import SwiftUI
import CryptoKit

final class NotificationReadState: ObservableObject {
    static let shared = NotificationReadState()
    private let defaults: UserDefaults
    @Published private var read: [String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.read = defaults.stringArray(forKey: "notificationRead.v1") ?? []
    }
    func key(_ message: MessagePreview, device: String) -> String {
        let parts = [device, message.id, String(message.time), message.text]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func unread(_ messages: [MessagePreview], device: String) -> Int {
        let known = Set(read)
        return messages.filter { !known.contains(key($0, device: device)) }.count
    }
    func mark(_ messages: [MessagePreview], device: String) {
        let keys = messages.map { key($0, device: device) }
        let known = Set(read)
        let fresh = keys.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        read = Array((read + fresh).suffix(10000))
        defaults.set(read, forKey: "notificationRead.v1")
    }
}


struct MessageInbox:View {
    @ObservedObject private var reads = NotificationReadState.shared
    @ObservedObject var bridge:BridgeClient
    var reply:(MessagePreview)->Void
    var apps:[String] { Array(Set(bridge.snapshot.messages.map(\.app))).sorted { a,b in
        (bridge.snapshot.messages.filter{$0.app==a}.map(\.time).max() ?? 0) > (bridge.snapshot.messages.filter{$0.app==b}.map(\.time).max() ?? 0)
    }}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("消息").font(.title2.bold())
            if apps.isEmpty {LegacyEmptyState(title:"暂无通知",systemImage:"bell")}
            ForEach(apps,id:\.self) { app in
                let messages=bridge.snapshot.messages.filter{$0.app==app}
                NavigationLink {
                    ConversationList(bridge:bridge,app:app,reply:reply)
                } label: {
                    HStack(spacing:14) {
                        Image(systemName:"app.fill").font(.title).foregroundStyle(.mint)
                        VStack(alignment:.leading,spacing:5) {
                            Text(app).font(.headline)
                            Text(messages.max(by:{$0.time<$1.time})?.text ?? "").lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(reads.unread(messages, device: bridge.surfaceId)) 未读").foregroundStyle(.secondary)
                        Image(systemName:"chevron.right").font(.caption)
                    }.padding(16).background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:16))
                }.buttonStyle(.plain)
            }
        }
    }
}
struct ConversationList:View {
    @ObservedObject private var reads = NotificationReadState.shared
    @ObservedObject var bridge:BridgeClient
    let app:String
    var reply:(MessagePreview)->Void
    var body:some View {
        List(MessageGrouping.conversations(bridge.snapshot.messages.filter{$0.app==app})) { conversation in
            NavigationLink {
                NotificationDetail(bridge:bridge,conversationId:conversation.id,app:app,reply:reply)
            } label: {
                VStack(alignment:.leading,spacing:6) {
                    HStack {Text(conversation.latest.title).font(.headline);Spacer();Text(Date(timeIntervalSince1970:conversation.latest.time),style:.time).font(.caption).foregroundStyle(.secondary)}
                    Text(conversation.latest.text).lineLimit(2).foregroundStyle(.secondary)
                    Text("\(conversation.messages.count) 条通知 · \(reads.unread(conversation.messages, device: bridge.surfaceId)) 未读").font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical,6)
            }
        }.navigationTitle(app)
    }
}
struct NotificationDetail:View {
    @ObservedObject private var reads = NotificationReadState.shared
    @ObservedObject var bridge:BridgeClient
    let conversationId:String
    let app:String
    var reply:(MessagePreview)->Void
    var messages:[MessagePreview] {MessageGrouping.conversations(bridge.snapshot.messages.filter{$0.app==app}).first{$0.id==conversationId}?.messages ?? []}
    var body:some View {
        List {
            if let latest=messages.first {
                Section {
                    if app=="微信" || app=="QQ" {Button("通过 agent 回复") {reply(latest)}}
                    if let status=bridge.commandStatus {Text(status).font(.caption).foregroundStyle(.secondary)}
                }
            }
            ForEach(messages) { message in
                Section {
                    Text(message.text).textSelection(.enabled)
                    if message.canOpen == true {
                        Button("在安卓打开原通知",systemImage:"arrow.up.forward.app") {Task{await bridge.openNotification(message)}}.disabled(!bridge.connected)
                    }
                    if let raw=message.link,let url=URL(string:raw),["http","https"].contains(url.scheme ?? "") {
                        Link("在 iPhone 打开链接",destination:url)
                    }
                } header: {Text(Date(timeIntervalSince1970:message.time),style:.time)}
            }
        }.navigationTitle(messages.first?.title ?? app)
        .task(id: messages.map { reads.key($0, device: bridge.surfaceId) }) {
            reads.mark(messages, device: bridge.surfaceId)
        }
    }
}
