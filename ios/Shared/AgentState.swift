import Foundation
import ActivityKit

struct MessagePreview: Codable, Identifiable {
    var id: String
    var app: String
    var title: String
    var text: String
    var conversationId: String? = nil
    var canOpen: Bool? = nil
    var link: String? = nil
    var receivedAt: Double? = nil
    var time: Double
}
struct AgentSnapshot: Codable {
    var exchanges:[NativeChatExchange]? = nil
    var phase: String
    var detail: String
    var runId: String
    var busy: Bool
    var device: String
    var updatedAt: Double
    var messages: [MessagePreview]
    var currentConversationId: String? = nil
    var queuedTasks:[RemoteQueuedTask]?=nil
    var taskQueueVersion:Int?=nil
    var knowledgeVersion: Int? = nil
    var chatRevision: Int64? = nil
    var chatRoutingVersion: Int? = nil
    var goal: String? = nil
    var commandId: String? = nil
    var conversationId: String? = nil
    var eventStream: Bool? = nil
    var messageWaitConfig: Bool? = nil
    var notificationAccess: Bool? = nil
    var notificationListenerConnected: Bool? = nil
    var demo: Bool? = nil
    var isDemo: Bool { demo == true }
    static let empty = AgentSnapshot(phase: "offline", detail: "等待连接安卓设备", runId: "", busy: false, device: "Android", updatedAt: 0, messages: [])
    var title: String { Self.label(phase) }
    static func label(_ phase: String) -> String {
        ["offline":"未连接", "idle":"准备就绪", "running":"正在执行", "waiting":"等待处理", "takeover":"需要接管", "confirmation":"需要确认", "completed":"任务完成", "failed":"执行失败", "cancelled":"已停止"][phase] ?? phase
    }
    var date: Date { Date(timeIntervalSince1970: updatedAt) }
}
struct AgentActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var detail: String
        var updatedAt: Date
        var messageCount: Int
    }
    var device: String
    var runId: String
    var isDemo: Bool
    var deviceId: String
}
struct FleetDevice: Codable, Identifiable {
    var id: String
    var name: String
    var phase: String
    var updatedAt: Double
    var demo: Bool
}
enum SharedState {
    static func saveDevices(_ devices: [FleetDevice]) {
        if let data = try? JSONEncoder().encode(devices) { UserDefaults(suiteName: group)?.set(data, forKey: "devices") }
    }
    static func readDevices() -> [FleetDevice] {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: "devices") else { return [] }
        return (try? JSONDecoder().decode([FleetDevice].self, from: data)) ?? []
    }
    static let group = "group.com.kassen.mikaremote"
    static func save(_ snapshot: AgentSnapshot) {
        // Home widgets expose status only, never conversation previews or message bodies.
        var redacted = snapshot
        redacted.messages = []
        redacted.detail = snapshot.title
        if let data = try? JSONEncoder().encode(redacted) { UserDefaults(suiteName: group)?.set(data, forKey: "snapshot") }
    }
    static func read() -> AgentSnapshot {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: "snapshot"), let s = try? JSONDecoder().decode(AgentSnapshot.self, from: data) else { return .empty }
        return s
    }
}

struct NativeChatExchange:Codable,Identifiable {
    var conversationId:String?
    var id:String;var goal:String;var phase:String;var body:String;var draft:String;var progress:String
    var startedAt:Double;var elapsed:Double?;var title:String;var verification:String;var evidence:String
    var options:[String];var steps:[NativeChatStep];var steers:[NativeChatSteer];var notes:[String];var files:[NativeChatFile]
    var active:Bool {!["done","failed","cancelled"].contains(phase)}
}
struct NativeChatStep:Codable {var number:Int;var title:String;var subtitle:String;var state:String;var reason:String}
struct NativeChatSteer:Codable {var text:String;var state:String}
struct NativeChatFile:Codable {var name:String;var size:Int64;var savedAs:String}

struct RemoteQueuedTask:Codable,Identifiable {var id:String;var text:String;var conversation:String;var state:String;var error:String;var result:String?}
