import WidgetKit
import SwiftUI
import ActivityKit

struct StatusEntry: TimelineEntry { var date: Date; var snapshot: AgentSnapshot; var devices: [FleetDevice] = [] }
struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: .now, snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) { completion(StatusEntry(date: .now, snapshot: SharedState.read(), devices: SharedState.readDevices())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        completion(Timeline(entries: [StatusEntry(date: .now, snapshot: SharedState.read(), devices: SharedState.readDevices())], policy: .after(Date().addingTimeInterval(900))))
    }
}
struct StatusWidget: Widget {
    let kind = "MikaStatus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            StatusWidgetContent(entry: entry)
                .background(Color(red: 0.035, green: 0.055, blue: 0.075))
                .widgetURL(URL(string: "mikaremote://dashboard"))
        }.configurationDisplayName("agent 状态").description("设备与任务状态").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct StatusWidgetContent: View {
    var entry: StatusEntry
    @Environment(\.widgetFamily) var family
    var body: some View {
        if family == .systemMedium && !entry.devices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("agent").font(.caption.bold()); Spacer(); Text("\(entry.devices.count) 台").font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 14) {
                    ForEach(Array(entry.devices.prefix(3))) { device in
                        Link(destination: URL(string: "mikaremote://device/" + device.id)!) {
                            VStack(spacing: 4) {
                                AoraAvatar(phase: device.phase).frame(width: 54, height: 54)
                                Text(device.name).font(.caption2).lineLimit(1)
                                Text((device.demo ? "演示 · " : "") + AgentSnapshot.label(device.phase)).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
                Text("最近状态").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack { AoraAvatar(phase: entry.snapshot.phase).frame(width: 28, height: 28); Text(entry.snapshot.isDemo ? "agent · 演示" : "agent").font(.caption.bold()); Spacer(); Image(systemName: "iphone.gen3") }
                Text(entry.snapshot.updatedAt > 0 && Date().timeIntervalSince(entry.snapshot.date) > 90 ? "上次：" + entry.snapshot.title : entry.snapshot.title).font(.title2.bold())
                Text(entry.snapshot.device).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if entry.snapshot.updatedAt > 0 {
                    HStack(spacing: 3) { Text("更新于"); Text(entry.snapshot.date, style: .time) }.font(.caption2).foregroundStyle(.secondary)
                } else { Text("打开 App 连接安卓").font(.caption2) }
                Text("查看 ↗").font(.caption).foregroundStyle(.mint)
            }
        }
    }
}
struct LiveStatus: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivity.self) { context in
            HStack(spacing: 15) {
                AoraAvatar(phase: context.isStale ? "offline" : context.state.phase).frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text(context.isStale ? "等待状态更新" : AgentSnapshot.label(context.state.phase)).font(.headline)
                    Text(context.attributes.device + (context.attributes.isDemo ? " · 本机演示" : " · agent")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.state.updatedAt, style: .time).font(.caption.monospacedDigit())
            }.padding(20).activityBackgroundTint(Color(red: 0.035, green: 0.055, blue: 0.075))
                .widgetURL(URL(string: "mikaremote://device/" + context.attributes.deviceId))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { HStack { AoraAvatar(phase: context.isStale ? "offline" : context.state.phase).frame(width: 42, height: 42); Text(context.attributes.isDemo ? "演示" : "agent").font(.caption) } }
                DynamicIslandExpandedRegion(.trailing) { Text(context.attributes.device).font(.caption).foregroundStyle(.secondary) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack { Text(context.isStale ? "等待状态更新" : AgentSnapshot.label(context.state.phase)).font(.headline); Spacer(); Link("打开控制台", destination: URL(string: "mikaremote://device/" + context.attributes.deviceId)!).font(.caption).foregroundStyle(.mint) }.padding(.vertical, 10)
                }
            } compactLeading: { AoraAvatar(phase: context.isStale ? "offline" : context.state.phase).frame(width: 24, height: 24) }
              compactTrailing: { Image(systemName: context.isStale ? "clock" : context.state.phase == "running" ? "ellipsis" : "hand.raised.fill").foregroundStyle(context.isStale ? .orange : .mint) }
              minimal: { AoraAvatar(phase: context.isStale ? "offline" : context.state.phase).frame(width: 24, height: 24) }
              .widgetURL(URL(string: "mikaremote://device/" + context.attributes.deviceId)).keylineTint(.mint)
        }
    }
}
@main struct MikaWidgetBundle: WidgetBundle { var body: some Widget { StatusWidget(); LiveStatus() } }
