import SwiftUI
import UIKit
@main struct MikaRemoteApp: App {
    @State private var didModelProbe=false
    @State private var selectedTab=0
    @StateObject var hub = NearbyHub()
    @Environment(\.scenePhase) var phase
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                NearbyRadar(hub: hub).tag(0).tabItem { Label("设备", systemImage: "iphone.gen3.radiowaves.left.and.right") }
                AgentHome(hub:hub,onDevices:{selectedTab=0}).tag(1).tabItem { Label("agent", systemImage: "bubble.left.and.bubble.right") }
                FleetNotifications(hub:hub).tag(2).tabItem{Label("消息",systemImage:"bell")}
                FleetManagement(hub:hub).tag(3).tabItem{Label("设置",systemImage:"slider.horizontal.3")}
            }
                .task { await MessageAlerts.shared.prepare() }
                .onReceive(NotificationCenter.default.publisher(for:.agentMessageOpened)) { event in
                    selectedTab=0
                    hub.requestedDevice=event.userInfo?["deviceId"] as? String
                }
                .onOpenURL { url in
                    if url.scheme == "mikaremote", url.host == "device" { hub.requestedDevice = url.lastPathComponent }
                }
                .task(id: phase) {
                    guard phase == .active else { hub.stopDiscovery(); return }
                    await MessageAlerts.shared.prepare()
                    hub.start()
                    #if DEBUG
                    if !didModelProbe && ProcessInfo.processInfo.arguments.contains("--import-provider-test") {didModelProbe=true;Task{await ModelCatalog.shared.importProviderForTesting()}}
                    if !didModelProbe && ProcessInfo.processInfo.environment["AGENT_MODEL_PROBE"] == "1" {
                        didModelProbe=true
                        Task { await ModelCatalog.shared.diagnosticProbe() }
                    }
                    #endif
                    #if DEBUG && targetEnvironment(simulator)
                    if ProcessInfo.processInfo.environment["MIKA_PREVIEW_NEARBY"] == "1" { await hub.showDemo() }
                    #endif
                    while !Task.isCancelled { await hub.refresh(); try? await Task.sleep(for: .seconds(hub.refreshInterval)) }
                }
        }
    }
}

struct FleetManagement:View {
    @ObservedObject var hub:NearbyHub
    var body:some View {
        NavigationStack{List{
            Section("当前主控端"){
                NavigationLink{ModelSettingsView()}label:{Label("主控模型",systemImage:"sparkles").padding(.vertical,5)}
                NavigationLink{SyncSettings()}label:{Label("连接与同步",systemImage:"antenna.radiowaves.left.and.right").padding(.vertical,5)}
            }
            Section("设备设置"){
                NavigationLink{FleetExecutionSettings(hub:hub,notifications:true)}label:{Label("通知来源",systemImage:"bell.badge").padding(.vertical,5)}
                NavigationLink{FleetQueueView(hub:hub)}label:{Label("任务队列",systemImage:"checklist").padding(.vertical,5)}
                NavigationLink{FleetFilesView(hub:hub)}label:{Label("文件",systemImage:"folder").padding(.vertical,5)}
                NavigationLink{FleetBrowserSettings(hub:hub)}label:{Label("浏览器与网站登录",systemImage:"globe").padding(.vertical,5)}
                NavigationLink{FleetReports(hub:hub,usage:true)}label:{Label("模型用量",systemImage:"chart.bar").padding(.vertical,5)}
                NavigationLink{FleetReports(hub:hub)}label:{Label("设备诊断",systemImage:"stethoscope").padding(.vertical,5)}
                NavigationLink{FleetAutomationView(hub:hub)}label:{Label("定时任务",systemImage:"clock").padding(.vertical,5)}
                NavigationLink{FleetAutomationView(hub:hub,routes:true)}label:{Label("操作路线",systemImage:"point.topleft.down.to.point.bottomright.curvepath").padding(.vertical,5)}
                NavigationLink{FleetExecutionSettings(hub:hub)}label:{Label("执行设置",systemImage:"slider.horizontal.3").padding(.vertical,5)}
                NavigationLink{FleetExecutionSettings(hub:hub,services:true)}label:{Label("电脑连接 MCP",systemImage:"desktopcomputer").padding(.vertical,5)}
                NavigationLink{KnowledgeView(hub:hub,defaultDevice:"all")}label:{Label("记忆与技能",systemImage:"heart").padding(.vertical,5)}
            }
        }.listStyle(.insetGrouped).tint(.teal).navigationTitle("设置")}
    }
}
struct FleetNotifications:View {
    @ObservedObject var hub:NearbyHub
    private struct ReplyContext:Identifiable {let id=UUID();let device:NearbyAgent;let message:MessagePreview}
    @State private var reply:ReplyContext?
    var body:some View {
        NavigationStack{List{
            ForEach(hub.agents.filter{$0.approved && !$0.demo}){agent in
                NavigationLink{
                    ScrollView{MessageInbox(bridge:agent.client,reply:{message in reply=ReplyContext(device:agent,message:message)}).padding()}.navigationTitle(agent.name)
                }label:{FleetNotificationDeviceLabel(agent:agent)}
            }
        }.navigationTitle("消息")}
        .sheet(item:$reply){context in FleetNotificationReply(agent:context.device,message:context.message).presentationDetents([.medium,.large]).presentationDragIndicator(.visible)}
    }
}


private struct FleetNotificationReply:View {
    @ObservedObject var agent:NearbyAgent
    var message:MessagePreview
    var body:some View {
        Dashboard(agentName:agent.name,avatarShape:agent.avatarShape,avatarHue:agent.avatarHue,notificationReply:message)
            .environmentObject(agent.client)
    }
}

private struct FleetNotificationDeviceLabel: View {
    @ObservedObject var agent: NearbyAgent
    @ObservedObject private var reads = NotificationReadState.shared
    var body: some View { FleetNotificationCount(bridge: agent.client, name: agent.name) }
}
private struct FleetNotificationCount: View {
    @ObservedObject var bridge: BridgeClient
    let name: String
    @ObservedObject private var reads = NotificationReadState.shared
    var body: some View {
        HStack { Text(name); Spacer(); Text("\(reads.unread(bridge.snapshot.messages, device: bridge.surfaceId)) 未读").foregroundStyle(.secondary) }
    }
}

// MARK: - iOS 16 兼容：替代 iOS 17 的 ContentUnavailableView
struct LegacyEmptyState: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    private var symbol: String {
        UIImage(systemName: systemImage) != nil ? systemImage : "iphone"
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding()
    }
}
