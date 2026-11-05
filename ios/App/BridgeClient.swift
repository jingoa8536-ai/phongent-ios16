import Foundation
import Security
import SwiftUI
import WidgetKit
import ActivityKit

struct BridgeServerError:LocalizedError {
    var status:Int
    var code:String
    var errorDescription:String? {
        switch code {
        case "conversation_switch_blocked_by_running_task":return "安卓当前正在执行任务，暂不允许切换；任务继续执行。"
        case "conversation_not_found":return "安卓上已找不到该聊天，请刷新列表。"
        case "conversation_changed":return "安卓当前聊天已变化，请重新选择后发送。"
        case "accessibility_required":return "请在安卓开启 agent 无障碍服务"
        case "screen_protected":return "当前安卓页面禁止截屏"
        case "screen_unavailable":return "暂时无法读取安卓画面，请解锁后重试"
        case "screen_stale","screen_changed":return "画面已变化，请等待刷新后重试"
        case "invalid_site":return "请填写有效的网站域名"
        case "site_not_found":return "此设备没有该网站记录"
        case "browser_login_busy":return "设备已有登录窗口，请先完成或关闭它"
        case "controlled_by_other":return "其他主控正在操作，请确认接管后重试"
        case "control_not_owned":return "控制权已变化，请重新接管"
        case "waiting_for_agent_pause":return "等待 agent 暂停当前操作后再试"
        case "virtual_screen_closed","task_ended":return "虚拟屏已关闭或任务已结束"
        case "API Key 无效或没有权限","额度已用完","网络连接失败","服务地址无效","模型未通过工具调用测试，未保存":return code
        case "focus_input_first":return "请先点击安卓画面中的输入框"
        case "input_rejected":return "安卓未接受操作，请检查当前页面"
        case "agent_busy":return "安卓正在执行任务，请等待完成或先停止任务。"
        case "sensitive":return "安卓拒绝保存此类敏感内容"
        case "too_long","invalid_content":return "内容为空或超过长度限制"
        case "missing_section":return "技能缺少必需章节，请保留编辑器中的五个标题"
        case "unknown_tool","unrunnable_script":return "技能引用了不可用的工具或脚本"
        case "memory_full":return "安卓记忆容量已满"
        case "unavailable","knowledge_unavailable":return "安卓记忆存储暂不可用，请解锁设备后重试"
        case "request_changed":return "请求内容已变化，请重新编辑后保存"
        case "unauthorized":return "连接授权已失效，请重新连接设备。"
        default:return "设备拒绝请求（HTTP \(status)）"
        }
    }
}
struct AgentNotice:Identifiable {let id=UUID();var text:String}

struct Pairing: Codable { var url: String; var token: String }
enum PairingStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MikaPairing", kSecAttrAccount as String: "owner"]
    static func load() -> Pairing? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }
    static func save(_ value: Pairing) throws {
        let data = try JSONEncoder().encode(value)
        SecItemDelete(query as CFDictionary)
        var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotWriteToFile) }
    }
}
@MainActor final class BridgeClient: ObservableObject {
    @Published var snapshot = AgentSnapshot.empty
    @Published var conversations:[DeviceConversation]=[]
    @Published var conversationError:String?
    @Published var switchingChat=false
    @Published var chatMessages:[DeviceChatMessage]=[]
    private var chatDevice=""
    @Published var connected = false
    @Published var status = "请导入设备配对信息"
    @Published var sending = false
    @Published var demoMode = false
    @Published var notice:AgentNotice?
    @Published var deletionTarget:DeviceConversation?
    @Published var commandStatus: String?
    private var demoRunId = ""
    @Published var pairing: Pairing?
    var surfaceId = "primary"
    var publishesWidget = true
    private var streaming=false
    private var eventSession:URLSession?
    private var messageConfiguration=""
    private var messageTask: Task<Void, Never>?
    private var session: URLSession?
    private var lastWidget = Date.distantPast
    private var lastPhase = ""
    private var lastActivityUpdate = Date.distantPast
    private var lastActivitySignature = ""
    private var observedActivities = Set<String>()
    init(loadSaved: Bool = true) {
        pairing = loadSaved ? PairingStore.load() : nil
        configure()
        #if DEBUG && targetEnvironment(simulator)
        if let raw = ProcessInfo.processInfo.environment["MIKA_PAIRING_URL"], let url = URL(string: raw) {
            try? pair(url)
        }
        #endif
    }
    func configure() {
        stopMessages(); session?.invalidateAndCancel(); session = nil; connected = false
        guard let pairing else { return }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config)
    }
    func pair(_ url: URL) throws {
        guard url.scheme == "mikaremote", url.host == "pair", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        func item(_ name: String) -> String { components.queryItems?.first { $0.name == name }?.value ?? "" }
        let p = Pairing(url: item("url"), token: item("token"))
        guard URL(string: p.url)?.scheme == "http", p.token.count >= 32 else { throw URLError(.badURL) }
        try PairingStore.save(p); pairing = p; configure()
        status = "已保存配对，正在连接"
    }
    func request(_ path: String, body: Data? = nil) async throws -> Data {
        guard let pairing, let session, let url = URL(string: pairing.url + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url); if path.hasPrefix("/messages?") { req.timeoutInterval = max(25,SyncPreferences.wait + 5) }; req.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
        if path=="/models/settings", body != nil { req.timeoutInterval=30 }
        if let body { req.httpMethod = "POST"; req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        guard let http=response as? HTTPURLResponse else{throw URLError(.badServerResponse)}
        guard (200..<300).contains(http.statusCode) else {
            let payload=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            throw BridgeServerError(status:http.statusCode,code:payload?["error"] as? String ?? "")
        }
        return data
    }
    func stopMessages() { messageTask?.cancel(); messageTask=nil;eventSession?.invalidateAndCancel();eventSession=nil;streaming=false }
    func startMessages() {
        if messageConfiguration != SyncPreferences.signature { stopMessages();messageConfiguration=SyncPreferences.signature }
        guard messageTask == nil, !demoMode else {return}
        if SyncPreferences.push && snapshot.eventStream == true { startEventStream();return }
        messageTask=Task { [weak self] in
            var revision:Int64 = -1
            while !Task.isCancelled {
                guard let self else{return}
                do {
                    struct Update:Decodable {var revision:Int64;var messages:[MessagePreview]}
                    let after = SyncPreferences.longPolling ? revision : -1
                    let waitQuery = self.snapshot.messageWaitConfig == true ? "&wait=\(SyncPreferences.longPolling ? Int(SyncPreferences.wait) : 0)" : ""
                    let update=try JSONDecoder().decode(Update.self,from:await self.request("/messages?after=\(after)"+waitQuery))
                    guard !Task.isCancelled else{return}
                    revision=update.revision
                    self.snapshot.messages=update.messages
                    await MessageAlerts.shared.receive(update.messages,deviceId:self.surfaceId,deviceName:self.snapshot.device)
                    if !SyncPreferences.longPolling {try await Task.sleep(for:.seconds(SyncPreferences.interval))}
                } catch {
                    if Task.isCancelled{return}
                    try? await Task.sleep(for:.seconds(3))
                }
            }
        }
    }
    private func startEventStream() {
        streaming=true
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=SyncPreferences.heartbeat+15
        config.timeoutIntervalForResource=7*24*60*60
        let transport=URLSession(configuration:config);eventSession=transport
        messageTask=Task { [weak self] in
            var failures=0
            while !Task.isCancelled {
                guard let self,let pairing=self.pairing,let url=URL(string:pairing.url+"/events?heartbeat=\(Int(SyncPreferences.heartbeat))") else{return}
                do {
                    var request=URLRequest(url:url);request.setValue("Bearer "+pairing.token,forHTTPHeaderField:"Authorization")
                    let (bytes,response)=try await transport.bytes(for:request)
                    guard let http=response as? HTTPURLResponse,http.statusCode==200 else{throw URLError(.badServerResponse)}
                    var reducer=AgentEventReducer()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else{continue}
                        guard let data=line.dropFirst(6).data(using:.utf8) else{throw URLError(.cannotParseResponse)}
                        let event=try JSONDecoder().decode(AgentEvent.self,from:data)
                        self.snapshot=try reducer.apply(event,to:self.snapshot)
                        failures=0;self.connected=true;self.status="已连接 · TCP 推送 · "+self.snapshot.device
                        if event.kind != "heartbeat" {
                            await MessageAlerts.shared.receive(self.snapshot.messages,deviceId:self.surfaceId,deviceName:self.snapshot.device)
                            await self.publishState()
                        }
                    }
                    throw URLError(.networkConnectionLost)
                } catch {
                    if Task.isCancelled{return}
                    await self.refresh(force:true)
                    if !self.connected {self.status="连接中断 · 自动重连中"}
                    failures=min(failures+1,5)
                    try? await Task.sleep(for:.seconds(min(30,pow(2,Double(failures-1)))))
                }
            }
        }
    }
    private var chatStorageKey:String {
        let current=snapshot.currentConversationId ?? snapshot.conversationId ?? ""
        return current.isEmpty ? surfaceId : surfaceId+"/"+current
    }
    func loadChat() {
        guard chatDevice != chatStorageKey else{return}
        chatDevice=chatStorageKey;chatMessages=DeviceChatHistory.read(chatDevice)
    }
    private func recordSnapshot() {
        loadChat();
        if let current=snapshot.currentConversationId,current != snapshot.conversationId {return}
        DeviceChatHistory.merge(snapshot,into:&chatMessages);DeviceChatHistory.save(chatMessages,device:chatDevice)
    }
    private func commandResult(_ id:String,_ status:String) {
        if let index=chatMessages.firstIndex(where:{$0.id==id+"-user"}) {chatMessages[index].status=status}
        DeviceChatHistory.save(chatMessages,device:chatDevice)
    }
    private func publishState() async {
        saveNativeChat()
        recordSnapshot()
        if publishesWidget {SharedState.save(snapshot)}
        if lastPhase != snapshot.phase || Date().timeIntervalSince(lastWidget)>60 {
            WidgetCenter.shared.reloadAllTimelines();lastWidget=Date();lastPhase=snapshot.phase
        }
        await updateLiveActivity()
    }
    func openNotification(_ message:MessagePreview) async {
        do {
            _ = try await request("/notification/open",body:JSONEncoder().encode(["id":message.id]))
            commandStatus="已请求安卓打开原通知，请查看安卓屏幕"
        } catch {commandStatus="通知已失效或安卓阻止打开，请在安卓解锁后重试"}
    }
    func refresh(force:Bool=false) async {
        guard !demoMode, pairing != nil else { return }
        if messageConfiguration != SyncPreferences.signature {stopMessages()}
        if streaming && connected && !force {return}
        do {
            var state = try JSONDecoder().decode(AgentSnapshot.self, from: await request("/state"))
            if messageTask != nil {state.messages=snapshot.messages}
            snapshot=state
            saveNativeChat()
            recordSnapshot()
            if messageTask == nil {await MessageAlerts.shared.receive(snapshot.messages, deviceId:surfaceId, deviceName:snapshot.device)}
            startMessages()
            connected = true; status = "已连接 · " + snapshot.device
            if publishesWidget { SharedState.save(snapshot) }
            if lastPhase != snapshot.phase || Date().timeIntervalSince(lastWidget) > 60 {
                WidgetCenter.shared.reloadAllTimelines(); lastWidget = Date(); lastPhase = snapshot.phase
            }
            await updateLiveActivity()
        } catch { connected = false; status = "连接中断 · 上次状态" }
    }
    private func refreshCapabilities() async throws {
        let state=try JSONDecoder().decode(AgentSnapshot.self,from:await request("/state"))
        snapshot.chatRoutingVersion=state.chatRoutingVersion
        snapshot.knowledgeVersion=state.knowledgeVersion
        snapshot.eventStream=state.eventStream
    }
    func refreshConversations() async {
        if conversations.isEmpty,let data=UserDefaults.standard.data(forKey:"chatList."+surfaceId) {
            conversations=(try? JSONDecoder().decode([DeviceConversation].self,from:data)) ?? []
        }
        guard connected,!demoMode else{return}
        if (snapshot.chatRoutingVersion ?? 0)<3 {try? await refreshCapabilities()}
        do {
            struct ListResponse:Decodable {var chats:[DeviceConversation]}
            conversations=try JSONDecoder().decode(ListResponse.self,from:await request("/chats")).chats
            if let data=try? JSONEncoder().encode(conversations) {UserDefaults.standard.set(data,forKey:"chatList."+surfaceId)}
            conversationError=nil
        } catch {conversationError="聊天列表更新失败，显示上次记录"}
    }
    private func saveNativeChat() {
        if let exchanges=snapshot.exchanges,let id=snapshot.currentConversationId,let data=try? JSONEncoder().encode(exchanges) {UserDefaults.standard.set(data,forKey:"nativeChat."+surfaceId+"/"+id)}
    }
    private func restoreNativeChat(_ id:String) {
        snapshot.exchanges=UserDefaults.standard.data(forKey:"nativeChat."+surfaceId+"/"+id).flatMap{try? JSONDecoder().decode([NativeChatExchange].self,from:$0)}
    }
    func markChatRead(_ id:String) {UserDefaults.standard.set(Date().timeIntervalSince1970,forKey:"chatRead."+surfaceId+"/"+id)}
    func chatUnread(_ chat:DeviceConversation)->Bool {chat.updatedAt > UserDefaults.standard.double(forKey:"chatRead."+surfaceId+"/"+chat.id)}
    func selectChat(_ id:String) async -> Bool {
        guard !switchingChat,!sending else{return false}
        switchingChat=true;defer{switchingChat=false}
        if !connected {snapshot.currentConversationId=id;restoreNativeChat(id);loadChat();return true}
        do {
            let body=["id":UUID().uuidString,"action":"select_chat","conversationId":id]
            let data=try await request("/command",body:JSONEncoder().encode(body))
            let result=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard result?["status"] as? String == "accepted",result?["conversationId"] as? String == id else{throw URLError(.badServerResponse)}
            snapshot.currentConversationId=id;restoreNativeChat(id);loadChat();markChatRead(id)
            await loadRemoteHistory(id);conversationError=nil
            return true
        } catch let error as BridgeServerError {conversationError=error.localizedDescription;return false}
        catch {conversationError="切换结果未确认，请检查设备连接。未发送新任务。";return false}
    }
    func loadRemoteHistory(_ id:String) async {
        guard connected,(snapshot.chatRoutingVersion ?? 0)>=3,!id.isEmpty else{return}
        do {
            struct History:Decodable {var messages:[DeviceChatMessage];var exchanges:[NativeChatExchange]?}
            let history=try JSONDecoder().decode(History.self,from:await request("/chat/"+id))
            guard snapshot.currentConversationId==id else{return}
            if let exchanges=history.exchanges {snapshot.exchanges=exchanges;saveNativeChat()}
            var messages=history.messages
            if snapshot.conversationId==id {
                let currentRun=snapshot.runId+"-agent"
                if !messages.contains(where:{$0.id==currentRun}) {
                    let user=(snapshot.commandId ?? "")+"-user"
                    messages += chatMessages.filter{$0.id==user || $0.id==currentRun}
                }
                DeviceChatHistory.merge(snapshot,into:&messages)
            }
            for pending in chatMessages where pending.status=="提交结果不确定" && !messages.contains(where:{$0.id==pending.id}) {messages.append(pending)}
            chatMessages=messages;DeviceChatHistory.save(messages,device:chatDevice)
        } catch {conversationError="历史消息读取失败，保留本机记录"}
    }
    func deleteChat(_ id:String) async {
        guard connected,!sending,!switchingChat else {notice=AgentNotice(text:"请连接设备后重试");return}
        sending=true;defer{sending=false}
        do {
            let data=try await request("/command",body:JSONEncoder().encode(["id":UUID().uuidString,"action":"delete_chat","conversationId":id]))
            let result=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard result?["status"] as? String == "accepted" else {throw URLError(.badServerResponse)}
            conversations.removeAll{$0.id==id}
            UserDefaults.standard.removeObject(forKey:"nativeChat."+surfaceId+"/"+id)
            UserDefaults.standard.removeObject(forKey:"deviceChat."+surfaceId+"/"+id)
            UserDefaults.standard.removeObject(forKey:"chatRead."+surfaceId+"/"+id)
            if snapshot.currentConversationId==id {snapshot.currentConversationId="";snapshot.exchanges=[];chatMessages=[]}
            await refresh();await refreshConversations()
            notice=AgentNotice(text:"已提交删除")
        } catch let error as BridgeServerError {notice=AgentNotice(text:error.localizedDescription)}
        catch {notice=AgentNotice(text:"删除结果未确认，请刷新列表后检查")}
    }
    func newChat() async -> Bool {
        commandStatus=nil;notice=nil
        guard connected,!sending,!switchingChat,!snapshot.busy else{notice=AgentNotice(text:"设备未连接或正在处理任务，请稍后重试");return false}
        sending=true;defer{sending=false}
        let id=UUID().uuidString
        do {
            try await refreshCapabilities()
        } catch {notice=AgentNotice(text:"无法读取安卓当前状态，请检查设备连接后重试");return false}
        do {
            let data=try await request("/command",body:JSONEncoder().encode(["id":id,"action":"new_chat"]))
            let result=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard result?["status"] as? String == "accepted",let conversation=result?["conversationId"] as? String,!conversation.isEmpty else{throw URLError(.badServerResponse)}
            snapshot.currentConversationId=conversation
            snapshot.exchanges=[]
            loadChat();commandStatus=nil
            await refreshConversations()
            return true
        } catch let error as BridgeServerError {notice=AgentNotice(text:error.localizedDescription);return false}
        catch {notice=AgentNotice(text:"新建聊天结果不确定，请先检查安卓当前聊天");return false}
    }
    @Published var stopping=false
    @discardableResult func stopAllTasks() async -> Bool {
        guard !stopping else{return false}
        stopping=true;defer{stopping=false}
        await refresh(force:true)
        guard connected else{commandStatus="设备未连接，结束任务未送达";return false}
        do {
            _ = try await request("/tasks",body:JSONSerialization.data(withJSONObject:["action":"stop_all"]))
            await refresh(force:true)
            commandStatus="已请求结束该设备全部任务"
            return true
        } catch {commandStatus="结束任务失败："+error.localizedDescription;return false}
    }
    @discardableResult func command(_ action: String, text: String = "", commandId:String=UUID().uuidString, expectedConversation:String?=nil) async -> Bool {
        guard !demoMode, !sending, !switchingChat else {commandStatus="正在提交，请稍后重试";return false}
        if !connected {await refresh(force:true)}
        guard connected else{commandStatus="设备未连接，请重试连接";return false}
        sending = true; defer { sending = false }
        // The same ID is retained for one explicit attempt. Never auto-resend on a network error.
        loadChat()
        chatMessages.removeAll{$0.id==commandId+"-user"}
        chatMessages.append(.init(id:commandId+"-user",role:"user",text:action == "stop" ? "停止任务" : text,status:"提交中",time:Date().timeIntervalSince1970))
        DeviceChatHistory.save(chatMessages,device:chatDevice)
        let body: [String: String] = ["id": commandId, "action": action, "text": text, "runId": snapshot.runId,"conversationId":expectedConversation ?? snapshot.currentConversationId ?? snapshot.conversationId ?? ""]
        do {
            let data = try await request(action=="task" && snapshot.taskQueueVersion==1 ? "/tasks":"/command", body: JSONEncoder().encode(body))
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let current=result?["conversationId"] as? String,!current.isEmpty,current != snapshot.currentConversationId {
                let pending=chatMessages.first{$0.id==commandId+"-user"}
                chatMessages.removeAll{$0.id==commandId+"-user"};DeviceChatHistory.save(chatMessages,device:chatDevice)
                snapshot.currentConversationId=current;loadChat()
                if let pending,!chatMessages.contains(where:{$0.id==pending.id}) {chatMessages.append(pending)}
            }
            commandResult(commandId,["accepted","queued","dispatching","running","completed","failed","cancelled","uncertain"].contains(result?["status"] as? String ?? "") ? ((result?["status"] as? String)=="queued" ? "已排队":"已接收") : (result?["status"] as? String ?? "未知"))
            commandStatus = "指令状态：" + (result?["status"] as? String ?? "未知")
            await refresh(force:true)
            return ["accepted","queued","dispatching","running","completed","failed","cancelled","uncertain"].contains(result?["status"] as? String ?? "")
        } catch let error as BridgeServerError {commandResult(commandId,error.localizedDescription);commandStatus=error.localizedDescription}
        catch {
            // A lost HTTP reply does not mean the durable enqueue failed.
            if action=="task",snapshot.taskQueueVersion==1,
               let data=try? await request("/tasks"),
               let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
               let tasks=root["items"] as? [[String:Any]],
               let task=tasks.first(where:{$0["id"] as? String==commandId}) {
                let state=task["state"] as? String ?? "queued"
                let label=["queued":"已排队","dispatching":"正在启动","running":"执行中","completed":"已完成","failed":"执行失败","cancelled":"已取消","uncertain":"待核实"][state] ?? "已接收"
                commandResult(commandId,"已接收");commandStatus=label
                return true
            }
            commandResult(commandId,"提交结果不确定");commandStatus = "提交结果不确定，请先核查安卓任务，不要重复发送"
        }
        return false
    }
    func showDemo(_ phase: String, device: String? = nil) async {
        if !demoMode { demoRunId = "demo-" + UUID().uuidString }
        demoMode = true; connected = false; commandStatus = nil
        let descriptions = ["running": "正在整理回复", "waiting": "等待确认回复", "completed": "任务已完成"]
        snapshot = AgentSnapshot(phase: phase, detail: descriptions[phase] ?? "本机演示", runId: demoRunId, busy: phase != "completed", device: device ?? snapshot.device, updatedAt: Date().timeIntervalSince1970, messages: [], demo: true)
        status = "演示模式"
        if publishesWidget { SharedState.save(snapshot); WidgetCenter.shared.reloadAllTimelines() }
        lastActivitySignature = ""
        await updateLiveActivity()
    }
    func endDemo() async {
        for activity in Activity<AgentActivity>.activities where activity.attributes.isDemo && activity.attributes.deviceId == surfaceId {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        demoMode = false; snapshot = .empty; connected = false
        status = pairing == nil ? "请导入设备配对信息" : "等待连接安卓"
        if publishesWidget { SharedState.save(snapshot); WidgetCenter.shared.reloadAllTimelines() }
        lastActivitySignature = ""; await refresh()
    }
    private func observeToken(_ activity: Activity<AgentActivity>) {
        guard !activity.attributes.isDemo, observedActivities.insert(activity.id).inserted else { return }
        Task {
            for await token in activity.pushTokenUpdates {
                let value = ["token": token.map { String(format: "%02x", $0) }.joined(), "runId": activity.attributes.runId]
                do { _ = try await request("/activity", body: JSONEncoder().encode(value)) }
                catch { status = "实时活动推送注册失败，前台仍可更新" }
            }
        }
    }
    func updateLiveActivity() async {
        let signature = snapshot.phase + snapshot.runId
        guard signature != lastActivitySignature || Date().timeIntervalSince(lastActivityUpdate) > 15 else { return }
        lastActivitySignature = signature; lastActivityUpdate = Date()
        let state = AgentActivity.ContentState(phase: snapshot.phase, detail: snapshot.title, updatedAt: snapshot.date, messageCount: snapshot.messages.count)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        let active = ["running", "waiting", "takeover", "confirmation"].contains(snapshot.phase)
        for activity in Activity<AgentActivity>.activities where activity.attributes.deviceId == surfaceId {
            observeToken(activity)
            if activity.attributes.runId != snapshot.runId || !active {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
            } else { await activity.update(content) }
        }
        if active && !Activity<AgentActivity>.activities.contains(where: { $0.attributes.runId == snapshot.runId && $0.attributes.deviceId == surfaceId }) {
            do { let activity = try Activity.request(attributes: AgentActivity(device: snapshot.device, runId: snapshot.runId, isDemo: demoMode, deviceId: surfaceId), content: content, pushType: nil); observeToken(activity) }
            catch { status = "灵动岛暂不可用：" + error.localizedDescription }
        }
    }
}
