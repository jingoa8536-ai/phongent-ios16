import Foundation
import Security

@MainActor final class ModelCatalog:ObservableObject {
    static let shared=ModelCatalog()
    struct Saved:Codable {var providers:[ModelProvider]=[];var roles:[String:ModelSelection]=[:];var visionDisabled=false}
    @Published var saved=Saved()
    @Published var errors:[String:String]=[:]
    @Published var busy=Set<String>()
    private var query:[String:Any]{[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"AgentModelCatalog",kSecAttrAccount as String:"providers"]}
    init() {
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne;var result:CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess,let data=result as? Data,let value=try? JSONDecoder().decode(Saved.self,from:data){saved=value}
        let old=ModelAccount.shared.credentials
        if saved.providers.isEmpty,!old.apiKey.isEmpty {
            let p=ModelProvider(name:URL(string:old.baseURL)?.host ?? "OpenAI",kind:.responses,baseURL:old.baseURL,apiKey:old.apiKey,models:[.init(id:old.model,name:old.model)])
            saved.providers.append(p);if !old.usePlan {saved.roles["main"] = .init(providerId:p.id,model:old.model)};try? persist()
        }
        syncChatGPT()
    }
    #if DEBUG
    func importProviderForTesting() async {
        let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let file=directory.appendingPathComponent("provider-import.json")
        let result=directory.appendingPathComponent("provider-test.json")
        do {
            let data=try Data(contentsOf:file)
            try FileManager.default.removeItem(at:file)
            let provider=try JSONDecoder().decode(ModelProvider.self,from:data)
            saved.providers.removeAll{$0.id==provider.id};saved.providers.append(provider)
            saved.roles["main"] = .init(providerId:provider.id,model:provider.models[0].id)
            try persist()
            let response=try await reply(provider:provider,model:provider.models[0].id,messages:[["role":"user","content":"test"]],session:UUID().uuidString,onText:{_ in})
            try JSONSerialization.data(withJSONObject:["result":"success","reply":response]).write(to:result)
        }catch{try? JSONSerialization.data(withJSONObject:["result":"failed","error":error.localizedDescription]).write(to:result)}
    }
    #endif
    func diagnosticProbe() async {
        let target=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("model-diagnostics.json")
        func record(_ values:[String:String]) {if let data=try? JSONSerialization.data(withJSONObject:values){try? data.write(to:target,options:[.atomic,.completeFileProtection])}}
        guard let choice=selection(.main),let p=saved.providers.first(where:{$0.id==choice.providerId}) else {record(["result":"no_main_model"]);return}
        record(["result":"testing","provider":p.name,"protocol":p.kind.rawValue,"model":choice.model])
        await probe(p,model:choice.model)
        record(["result":errors[p.id] ?? "unknown","provider":p.name,"protocol":p.kind.rawValue,"model":choice.model])
    }
    func persist() throws {
        let data=try JSONEncoder().encode(saved)
        var status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {var q=query;q[kSecValueData as String]=data;q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;status=SecItemAdd(q as CFDictionary,nil)}
        guard status==errSecSuccess else{throw ModelFailure(message:"保存服务商失败")}
    }
    func syncChatGPT() {
        let account=ModelAccount.shared
        guard !account.credentials.clientId.isEmpty else{return}
        let models=account.models.map{ProviderModel(id:$0,name:$0)}
        if let i=saved.providers.firstIndex(where:{$0.kind == .chatGPT}) {if !models.isEmpty{saved.providers[i].models=models}}
        else {
            var p=ModelProvider(id:"chatgpt",name:"ChatGPT",kind:.chatGPT,baseURL:"https://api.openai.com/v1",models:models)
            if p.models.isEmpty {p.models=[.init(id:account.credentials.model,name:account.credentials.model)]}
            saved.providers.append(p)
            if saved.roles["main"]==nil{saved.roles["main"] = .init(providerId:p.id,model:account.credentials.model)}
        }
        do {try persist()}catch{errors["chatgpt"]=error.localizedDescription}
    }
    func selection(_ role:ModelRole)->ModelSelection? {if role == .dispatch{return saved.roles[role.rawValue]};if role == .vision && saved.visionDisabled{return nil};return saved.roles[role.rawValue] ?? saved.roles["main"]}
    func label(_ role:ModelRole)->String {
        if role == .vision && saved.visionDisabled{return "不用"}
        if role != .main && role != .dispatch && saved.roles[role.rawValue]==nil{return "用主模型"}
        return selection(role)?.model ?? "未选择"
    }
    func choose(_ role:ModelRole,provider:ModelProvider,model:String) {
        saved.roles[role.rawValue] = .init(providerId:provider.id,model:model)
        if role == .vision{saved.visionDisabled=false}
        do{try persist()}catch{errors[provider.id]=error.localizedDescription}
    }
    func inherit(_ role:ModelRole,disabled:Bool=false){saved.roles.removeValue(forKey:role.rawValue);if role == .vision{saved.visionDisabled=disabled};do{try persist()}catch{errors["settings"]=error.localizedDescription}}
    func remove(_ id:String){if saved.providers.first(where:{$0.id==id})?.kind == .chatGPT {ModelAccount.shared.signOut()};saved.providers.removeAll{$0.id==id};saved.roles=saved.roles.filter{$0.value.providerId != id};do{try persist()}catch{errors[id]=error.localizedDescription}}
    func bearer(_ provider:ModelProvider,force:Bool=false) async throws -> String {
        if provider.kind == .chatGPT {return try await ModelAccount.shared.planBearer(force:force)}
        return provider.apiKey
    }
    func refresh(_ id:String) async {
        guard let p=saved.providers.first(where:{$0.id==id}),!busy.contains(id) else{return}
        busy.insert(id);errors[id]=nil;defer{busy.remove(id)}
        do{let models=try await list(p);if let i=saved.providers.firstIndex(where:{$0.id==id}){saved.providers[i].models=models;try persist()}}
        catch{errors[id]=error.localizedDescription}
    }
    func list(_ provider:ModelProvider) async throws -> [ProviderModel] {
        for retry in 0...1 {
            let token=try await bearer(provider,force:retry==1)
            let request=try ModelRequests.request(provider:provider,path:ModelRequests.listPath(provider.kind),bearer:token,session:UUID().uuidString)
            let (data,response)=try await URLSession.shared.data(for:request);let code=(response as? HTTPURLResponse)?.statusCode ?? 0
            if code==401 && provider.kind == .chatGPT && retry==0 {continue}
            guard (200..<300).contains(code) else{throw ModelHTTPFailure.make(status:code,data:data,stage:"获取模型")}
            guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw ModelFailure(message:"模型列表格式无效")}
            let models=ModelRequests.models(json,kind:provider.kind)
            guard !models.isEmpty else{throw ModelFailure(message:"服务未返回可用模型，可填写模型 ID 后测试")};return models
        }
        throw ModelFailure(message:"请重新登录 ChatGPT")
    }
    func reply(provider:ModelProvider,model:String,messages:[[String:String]],session:String,onText:@escaping(String)->Void) async throws -> String {
        for retry in 0...1 {
            let token=try await bearer(provider,force:retry==1)
            let request=try ModelRequests.chat(provider:provider,model:model,messages:messages,bearer:token,session:session)
            if provider.kind == .responses || provider.kind == .chatGPT {
                let (bytes,response)=try await URLSession.shared.bytes(for:request);let code=(response as? HTTPURLResponse)?.statusCode ?? 0
                if code==401 && provider.kind == .chatGPT && retry==0 {continue}
                guard (200..<300).contains(code) else {
                    var data=Data();for try await byte in bytes {data.append(byte);if data.count>=8192{break}}
                    throw ModelHTTPFailure.make(status:code,data:data,stage:"调用 \(model)")
                }
                var stream=ModelResponseStream()
                for try await line in bytes.lines {try Task.checkCancellation();try stream.accept(line);onText(stream.text);if stream.completed{break}}
                try stream.validateCompletion();return stream.text
            } else {
                let (data,response)=try await URLSession.shared.data(for:request);let code=(response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else{throw ModelHTTPFailure.make(status:code,data:data,stage:"调用 \(model)")}
                guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw ModelFailure(message:"模型回复格式无效")}
                let text=ModelRequests.text(json,kind:provider.kind);guard !text.isEmpty else{throw ModelFailure(message:"模型未返回文本")};onText(text);return text
            }
        }
        throw ModelFailure(message:"登录失效，请重新登录")
    }
    func testAndSave(_ draft:ModelProvider,manualModel:String) async throws {
        var p=draft
        do {p.models=try await list(p)} catch {
            // Only a missing model-list endpoint permits manual fallback; auth failures never do.
            guard let failure=error as? ModelHTTPFailure,[404,405].contains(failure.status),!manualModel.isEmpty else{throw error}
            p.models=[.init(id:manualModel,name:manualModel)]
        }
        let model=manualModel.isEmpty ? p.models.first!.id:manualModel
        _=try await reply(provider:p,model:model,messages:[["role":"user","content":"只回复 OK。"]],session:UUID().uuidString,onText:{_ in})
        if !p.models.contains(where:{$0.id==model}){p.models.append(.init(id:model,name:model))}
        let previous=saved
        saved.providers.removeAll{$0.id==p.id};saved.providers.append(p)
        if saved.roles["main"]==nil{saved.roles["main"] = .init(providerId:p.id,model:model)}
        do {try persist()}catch{saved=previous;throw error}
    }
    func probe(_ provider:ModelProvider,model:String) async {
        guard !busy.contains(provider.id) else{return};busy.insert(provider.id);errors[provider.id]=nil;defer{busy.remove(provider.id)}
        do{_=try await reply(provider:provider,model:model,messages:[["role":"user","content":"只回复 OK。"]],session:UUID().uuidString,onText:{_ in});errors[provider.id]="调用成功 · \(model)"}
        catch{errors[provider.id]=error.localizedDescription}
    }
}
