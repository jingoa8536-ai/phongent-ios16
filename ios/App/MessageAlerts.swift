import Foundation
import UserNotifications
import SwiftUI

extension Notification.Name {static let agentMessageOpened=Notification.Name("agentMessageOpened")}
@MainActor final class MessageAlerts:NSObject,ObservableObject,UNUserNotificationCenterDelegate {
    static let shared=MessageAlerts()
    @Published var enabled=false
    @Published var status=""
    private var preparing=false
    private let began=Date().timeIntervalSince1970
    private var seen:[String:[String]] = (UserDefaults.standard.dictionary(forKey:"agentMessageSeen") as? [String:[String]]) ?? [:]
    func prepare() async {
        guard !preparing else{return};preparing=true;defer{preparing=false}
        let center=UNUserNotificationCenter.current();center.delegate=self
        let settings=await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {enabled=try await center.requestAuthorization(options:[.alert,.sound,.badge])}catch{enabled=false;status="通知授权失败"}
        } else {enabled=settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional}
        if !enabled{status="iPhone 通知未开启"}else{status=""}
    }
    func receive(_ messages:[MessagePreview],deviceId:String,deviceName:String) async {
        let previous=Set(seen[deviceId] ?? [])
        let new=messages.filter{!previous.contains($0.id) && $0.time >= began-5}.sorted{$0.time<$1.time}
        // Record IDs before scheduling, so two-second polling and reconnects cannot repeat alerts.
        var ids=seen[deviceId] ?? [];for message in messages where !previous.contains(message.id){ids.append(message.id)}
        seen[deviceId]=Array(ids.suffix(500));UserDefaults.standard.set(seen,forKey:"agentMessageSeen")
        guard enabled,!new.isEmpty else{return}
        for message in new.suffix(5) {
            let content=UNMutableNotificationContent()
            content.title="\(deviceName) · \(message.app)"
            content.subtitle=message.title
            content.body=message.text
            content.sound = .default
            content.threadIdentifier=deviceId+"/"+message.app
            content.userInfo=["deviceId":deviceId,"messageId":message.id]
            do {try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:deviceId+"/"+message.id,content:content,trigger:nil))}
            catch {status="消息提醒失败，请检查通知权限"}
        }
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping(UNNotificationPresentationOptions)->Void) {completionHandler([.banner,.list,.sound])}
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping()->Void) {
        let id=response.notification.request.content.userInfo["deviceId"] as? String
        Task { @MainActor in if let id {NotificationCenter.default.post(name:.agentMessageOpened,object:nil,userInfo:["deviceId":id])};completionHandler() }
    }
}
struct MessageAlertSettings:View {
    @ObservedObject var alerts=MessageAlerts.shared
    var body:some View {
        if !alerts.enabled {
            Button("开启 iPhone 消息提醒",systemImage:"bell.badge") {
                if let url=URL(string:UIApplication.openSettingsURLString){UIApplication.shared.open(url)}
            }.font(.caption)
        }
        if !alerts.status.isEmpty{Text(alerts.status).font(.caption).foregroundStyle(.orange)}
    }
}
