import Foundation
import SwiftUI
import Combine
import Security
import WidgetKit

struct RememberedAgent: Codable { var id: String; var name: String; var pairing: Pairing }
@MainActor final class NearbyAgent: ObservableObject, Identifiable {
    let id: String
    @Published var name: String
    @Published var url: String
    @Published var connection = "发现设备"
    @Published var available = true
    @Published var approved = false
    let avatarShape:String
    let avatarHue:Double
    @Published var simulated=false
    let demo: Bool
    let client = BridgeClient(loadSaved: false)
    init(id: String, name: String, url: String = "", demo: Bool = false) {
        self.id = id; self.name = name.replacingOccurrences(of:"模拟安卓 ",with:"设备 "); self.url = url; self.demo = demo
        let identity=id.lowercased().utf8.reduce(UInt32(2166136261)){($0 ^ UInt32($1)) &* 16777619}
        avatarHue=Double(identity % 360000)/1000
        avatarShape=["blob","wedge","gem"][Int(identity % 3)]

        client.surfaceId = id; client.publishesWidget = false
    }
    var phase: String { !available ? "offline" : demo || (approved && client.connected) ? client.snapshot.phase : connection == "等待安卓允许" ? "waiting" : "idle" }
}
enum AgentTrustStore {
    static var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"MikaNearbyPeers",kSecAttrAccount as String:"agents"] }
    static func load() -> [RememberedAgent] {
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne;var item:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let data=item as? Data else{return []}
        return (try? JSONDecoder().decode([RememberedAgent].self,from:data)) ?? []
    }
    static func save(_ agents:[RememberedAgent]) {
        guard let data=try? JSONEncoder().encode(agents) else{return}
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {var q=query;q[kSecValueData as String]=data;q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;SecItemAdd(q as CFDictionary,nil)}
    }
}
@MainActor final class NearbyHub: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var agents:[NearbyAgent]=[]
    @Published var deviceGroups:[String:String]=UserDefaults.standard.dictionary(forKey:"agentDeviceGroups") as? [String:String] ?? [:]
    func group(of id:String)->String{deviceGroups[id] ?? "默认组"}
    var groupNames:[String]{Array(Set(agents.map{group(of:$0.id)})).sorted()}
    @Published var connecting:Set<String>=[]
    func setGroup(_ device:String,name:String){let value=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40));if value.isEmpty || value=="默认组"{deviceGroups.removeValue(forKey:device)}else{deviceGroups[device]=value};UserDefaults.standard.set(deviceGroups,forKey:"agentDeviceGroups")}
    func members(of group:String)->Set<String>{Set(agents.filter{self.group(of:$0.id)==group}.map(\.id))}
    @Published var discoveryStatus="搜索中…"
    @Published var showingDemo=false
    private let browser=NetServiceBrowser()
    private var services:[NetService]=[]
    private var serviceIds:[String:String]=[:]
    private var observers:[String:AnyCancellable]=[:]
    private var remembered=AgentTrustStore.load()
    private var started=false
    private var lastWidgetSignature = ""
    private var lastWidgetDate = Date.distantPast
    @Published var requestedDevice: String?
    override init() {
        super.init()
        #if DEBUG
        // Explicit maintenance launch arguments remove only the requested device IDs.
        let removals=Set(ProcessInfo.processInfo.arguments.filter{$0.hasPrefix("--forget-device=")}.map{String($0.dropFirst("--forget-device=".count))})
        if !removals.isEmpty {
            remembered.removeAll{removals.contains($0.id)}
            AgentTrustStore.save(remembered)
            var shapes=UserDefaults.standard.dictionary(forKey:"deviceAvatarShapes") as? [String:String] ?? [:]
            for id in removals {shapes.removeValue(forKey:id)}
            UserDefaults.standard.set(shapes,forKey:"deviceAvatarShapes")
            if let selected=UserDefaults.standard.string(forKey:"widgetDevice"),removals.contains(selected){UserDefaults.standard.removeObject(forKey:"widgetDevice")}
        }
        #endif
        for trust in remembered {
            let agent = NearbyAgent(id: trust.id, name: trust.name, url: trust.pairing.url)
            agent.client.snapshot.device = trust.name
            agent.available = false; agent.approved = true; agent.connection = "等待设备上线"
            agent.client.pairing = trust.pairing; agent.client.configure()
            agents.append(agent); observe(agent)
        }
    }
    @Published var renameError:String?
    func rename(_ agent:NearbyAgent,to name:String) {
        Task {
            do {try await renameOnDevice(agent,to:name)}
            catch {renameError="重命名失败，请确认安卓已更新并保持连接："+error.localizedDescription}
        }
    }
    private func renameOnDevice(_ agent:NearbyAgent,to name:String) async throws {
        let value=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40));guard !value.isEmpty else{return}
        _ = try await agent.client.request("/device/name",body:JSONEncoder().encode(["name":value]))
        agent.name=value
        if let index=remembered.firstIndex(where:{$0.id==agent.id}) {remembered[index].name=value;AgentTrustStore.save(remembered)}
        objectWillChange.send()
    }
    func select(_ agent: NearbyAgent) {
        for item in agents { item.client.publishesWidget = item.id == agent.id }
        UserDefaults.standard.set(agent.id, forKey: "widgetDevice")
        SharedState.save(agent.client.snapshot); WidgetCenter.shared.reloadAllTimelines()
    }
    private func publishWidgets() {
        let devices = agents.map { agent in
            FleetDevice(id: agent.id, name: agent.name, phase: agent.demo ? agent.client.snapshot.phase : agent.available && agent.client.connected ? agent.client.snapshot.phase : "offline", updatedAt: agent.client.snapshot.updatedAt, demo: agent.demo)
        }
        SharedState.saveDevices(devices)
        if let selected = agents.first(where: { $0.id == UserDefaults.standard.string(forKey: "widgetDevice") }) ?? agents.first(where: { $0.approved || $0.demo }) {
            for agent in agents { agent.client.publishesWidget = agent.id == selected.id }
            SharedState.save(selected.client.snapshot)
        } else { SharedState.save(.empty) }
        let signature = devices.map { $0.id + $0.phase }.joined()
        if signature != lastWidgetSignature || Date().timeIntervalSince(lastWidgetDate) > 60 {
            WidgetCenter.shared.reloadAllTimelines(); lastWidgetSignature = signature; lastWidgetDate = Date()
        }
    }
    var ownerName:String { UIDevice.current.name }
    func start() {
        guard !started else{return};started=true;browser.delegate=self
        browser.searchForServices(ofType:"_mika-agent._tcp.",inDomain:"local.")
    }
    func stopDiscovery() { agents.forEach { $0.client.stopMessages() }; browser.stop(); services.forEach { $0.stop() }; services.removeAll(); started=false }
    func netServiceBrowser(_ browser:NetServiceBrowser,didFind service:NetService,moreComing:Bool) {
        services.removeAll { $0.name == service.name }; services.append(service);service.delegate=self;service.resolve(withTimeout:6)
    }
    func netServiceBrowser(_ browser:NetServiceBrowser,didRemove service:NetService,moreComing:Bool) {
        if let id=serviceIds[service.name],let agent=agents.first(where:{$0.id==id}){agent.connection=agent.client.connected ? "已连接":"正在重连"}
        services.removeAll{$0==service};objectWillChange.send()
    }
    func netServiceBrowser(_ browser:NetServiceBrowser,didNotSearch errorDict:[String:NSNumber]) {discoveryStatus="未能发现设备，请检查本地网络权限和 Wi-Fi"}
    func netServiceDidResolveAddress(_ service:NetService) {
        guard let raw=service.txtRecordData(),let host=service.hostName else{return}
        let txt=NetService.dictionary(fromTXTRecord:raw)
        func value(_ k:String)->String{txt[k].flatMap{String(data:$0,encoding:.utf8)} ?? ""}
        let id=value("id")
        guard UUID(uuidString:id) != nil,value("transport") == "tcp-http-v1",service.port>0 else{return}
        let name=String(value("name").prefix(60));let endpoint="http://\(host.trimmingCharacters(in:CharacterSet(charactersIn:"."))):\(service.port)"
        serviceIds[service.name]=id
        let agent=agents.first{$0.id==id} ?? NearbyAgent(id:id,name:name.isEmpty ? service.name:name,url:endpoint)
        agent.url=endpoint;agent.available=true;agent.simulated=value("simulation")=="1"
        if !agents.contains(where:{$0.id==id}) {agents.append(agent);observe(agent)}
        if let trust=remembered.first(where:{$0.id==id}) {
            var pairing=trust.pairing;pairing.url=endpoint;if agent.client.pairing?.url != pairing.url || agent.client.pairing?.token != pairing.token {agent.client.pairing=pairing;agent.client.configure()};agent.approved=true;agent.connection=agent.client.connected ? "已连接":"正在重连"
        }
        discoveryStatus="已发现 \(agents.filter{!$0.demo && $0.available}.count) 台设备"
    }
    private func observe(_ agent:NearbyAgent){observers[agent.id]=agent.client.objectWillChange.sink{[weak self] _ in self?.objectWillChange.send()}}
    var refreshInterval:Double {
        let live=agents.filter{$0.approved && !$0.demo && !connecting.contains($0.id)}
        return SyncPreferences.push && !live.isEmpty && live.allSatisfy{$0.client.snapshot.eventStream == true} ? 30 : SyncPreferences.stateInterval
    }
    func refresh() async {
        let live=agents.filter{$0.approved && !$0.demo && !connecting.contains($0.id)}
        await withTaskGroup(of:Void.self){ group in
            for agent in live{group.addTask{@MainActor in await agent.client.refresh();agent.available=agent.client.connected;agent.connection=agent.client.connected ? "已连接":"连接中断"}}
        }
        publishWidgets(); objectWillChange.send()
    }
    func connect(_ agent:NearbyAgent) async -> Bool {
        guard !connecting.contains(agent.id) else{return false}
        if agent.client.connected{return true}
        connecting.insert(agent.id);defer{connecting.remove(agent.id);objectWillChange.send()}
        if agent.approved {
            agent.connection="连接中…"
            await agent.client.refresh(force:true)
            agent.available=agent.client.connected
            agent.connection=agent.client.connected ? "已连接":"重连失败，请检查设备网络和服务"
        }else{await invite(agent)}
        return agent.client.connected
    }
    func connectAll(_ targets:[NearbyAgent]) async -> [String] {
        var failures:[String]=[]
        for start in stride(from:0,to:targets.count,by:3){
            let batch=Array(targets.dropFirst(start).prefix(3))
            await withTaskGroup(of:String?.self){group in
                for agent in batch{group.addTask{@MainActor in await self.connect(agent) ? nil:agent.name}}
                for await failure in group{if let failure{failures.append(failure)}}
            }
        }
        return failures
    }
    func invite(_ agent:NearbyAgent) async {
        guard agent.available,!agent.approved,!agent.demo,agent.connection != "等待安卓允许" else{return}
        agent.connection="等待安卓允许";objectWillChange.send()
        let nonce=UUID().uuidString+UUID().uuidString
        let session=URLSession(configuration:.ephemeral)
        defer{session.invalidateAndCancel()}
        func request(_ path:String,_ body:[String:String]?=nil) async throws -> [String:Any] {
            var r=URLRequest(url:URL(string:agent.url+path)!);r.timeoutInterval=7
            if let body{r.httpMethod="POST";r.httpBody=try JSONEncoder().encode(body);r.setValue("application/json",forHTTPHeaderField:"Content-Type")}
            let (data,response)=try await session.data(for:r)
            guard let response=response as? HTTPURLResponse,(200..<300).contains(response.statusCode),let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw URLError(.badServerResponse)}
            return value
        }
        do {
            let offer=try await request("/pair",["requestId":nonce,"name":ownerName])
            guard offer["status"] as? String == "pending" else{throw URLError(.cannotConnectToHost)}
            for _ in 0..<40 {
                try await Task.sleep(for:.seconds(2))
                let result=try await request("/pair/"+nonce)
                if result["status"] as? String == "approved",let token=result["token"] as? String,token.count>=32{
                    let p=Pairing(url:agent.url,token:token)
                    agent.client.pairing=p;agent.client.configure();agent.approved=true;agent.connection="已连接"
                    remembered.removeAll{$0.id==agent.id};remembered.append(.init(id:agent.id,name:agent.name,pairing:p));AgentTrustStore.save(remembered)
                    await agent.client.refresh();objectWillChange.send();return
                }
                if result["status"] as? String == "expired" {agent.connection="申请已过期，点击重试";return}
                if result["status"] as? String == "denied"{agent.connection="安卓已拒绝连接";objectWillChange.send();return}
            }
            agent.connection="申请已过期，点击重试"
        } catch {agent.connection="连接失败，请检查安卓服务"}
        objectWillChange.send()
    }
    func showDemo() async {
        guard !showingDemo else{return};showingDemo=true
        for (i,name) in ["Galaxy","Pixel","OnePlus"].enumerated(){
            let a=NearbyAgent(id:"demo-\(i)",name:name,demo:true);agents.append(a);observe(a)
            await a.client.showDemo(["running","waiting","completed"][i], device: name);a.connection="演示设备"
        }
        publishWidgets(); objectWillChange.send()
    }
    func hideDemo() async {
        for a in agents where a.demo{await a.client.endDemo();observers.removeValue(forKey:a.id)}
        agents.removeAll{$0.demo};showingDemo=false;publishWidgets()
    }
    func forget(_ agent:NearbyAgent){remembered.removeAll{$0.id==agent.id};AgentTrustStore.save(remembered);agent.approved=false;agent.client.pairing=nil;agent.client.configure();agent.connection="已断开";objectWillChange.send()}
}


struct FleetGroupPicker:View {
    @ObservedObject var hub:NearbyHub
    var select:(Set<String>)->Void
    var body:some View {
        if !hub.groupNames.isEmpty{Menu("按分组选择"){ForEach(hub.groupNames,id:\.self){group in Button(group){select(hub.members(of:group))}}}}
    }
}
