import Foundation

enum ModelProtocol: String, Codable, CaseIterable {
    case chatGPT, chatCompletions, responses, anthropic, gemini
    var label:String {switch self{case .chatGPT:return "ChatGPT 套餐";case .chatCompletions:return "OpenAI 兼容";case .responses:return "Responses";case .anthropic:return "Anthropic";case .gemini:return "Gemini"}}
}
struct ProviderModel: Codable, Identifiable, Hashable {
    var id:String
    var name:String
    var vision:Bool=false
}
struct ModelProvider: Codable, Identifiable {
    var id=UUID().uuidString
    var name:String
    var kind:ModelProtocol
    var baseURL:String
    var apiKey:String=""
    var sessionHeader:String?=nil
    var models:[ProviderModel]=[]
}
struct ModelSelection:Codable,Equatable {var providerId:String;var model:String}
enum ModelRole:String,CaseIterable {case main,dispatch,vision,lightweight
    var title:String{switch self{case .dispatch:return "任务下发模型";case .main:return "主控对话模型";case .vision:return "看图模型";case .lightweight:return "轻量模型"}}
}
struct ProviderPreset: Identifiable {
    var id:String{name};var name:String;var kind:ModelProtocol;var baseURL:String;var sessionHeader:String?=nil
    static let all:[ProviderPreset]=[
        .init(name:"DeepSeek",kind:.chatCompletions,baseURL:"https://api.deepseek.com"),
        .init(name:"OpenAI",kind:.responses,baseURL:"https://api.openai.com/v1"),
        .init(name:"通义千问",kind:.chatCompletions,baseURL:"https://dashscope.aliyuncs.com/compatible-mode/v1"),
        .init(name:"Kimi",kind:.chatCompletions,baseURL:"https://api.moonshot.cn/v1"),
        .init(name:"智谱",kind:.chatCompletions,baseURL:"https://open.bigmodel.cn/api/paas/v4"),
        .init(name:"OpenRouter",kind:.chatCompletions,baseURL:"https://openrouter.ai/api/v1"),
        .init(name:"OpenCode Go",kind:.chatCompletions,baseURL:"https://opencode.ai/zen/go/v1",sessionHeader:"x-opencode-session"),
        .init(name:"Anthropic",kind:.anthropic,baseURL:"https://api.anthropic.com"),
        .init(name:"Gemini",kind:.gemini,baseURL:"https://generativelanguage.googleapis.com"),
        .init(name:"自定义",kind:.chatCompletions,baseURL:"")]
}
struct ModelHTTPFailure:LocalizedError {
    var status:Int;var code:String;var stage:String
    var errorDescription:String? {
        let reason:String
        switch status {case 401:reason="凭据被拒绝，请重新登录或更换 API Key";case 403:reason="账号、模型或地区权限被拒绝";case 404:reason="接口地址或模型不存在";case 429:reason="额度不足或请求过于频繁";default:reason="请求未成功"}
        return "\(stage)：\(reason)（HTTP \(status)\(code.isEmpty ? "" : " · "+code)）"
    }
    static func make(status:Int,data:Data,stage:String)->ModelHTTPFailure {
        let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        let error=root?["error"] as? [String:Any]
        let raw=error?["code"] as? String ?? error?["type"] as? String ?? root?["error"] as? String ?? ""
        // Never expose raw response bodies or token-like strings in errors.
        let code=raw.count<80 && raw.range(of:"^[a-zA-Z0-9_.-]*$",options:.regularExpression) != nil && !raw.hasPrefix("sk-") ? raw:""
        return .init(status:status,code:code,stage:stage)
    }
}
enum ModelRequests {
    static func request(provider:ModelProvider,path:String,bearer:String,session:String) throws -> URLRequest {
        let base=provider.baseURL.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        guard var components=URLComponents(string:base+path),let host=components.host,components.user==nil,components.password==nil,
              components.scheme=="https" || (components.scheme=="http" && (host=="localhost" || host=="127.0.0.1" || host.hasSuffix(".local"))) else {throw ModelFailure(message:"请填写正确的 HTTPS 地址，本机服务也可使用 HTTP")}
        components.fragment=nil
        guard let url=components.url else {throw ModelFailure(message:"接口地址无效")}
        var request=URLRequest(url:url);request.timeoutInterval=90
        request.setValue("agent-iOS/1.0",forHTTPHeaderField:"User-Agent")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let header=provider.sessionHeader {request.setValue(session,forHTTPHeaderField:header)}
        switch provider.kind {
        case .anthropic:request.setValue(bearer,forHTTPHeaderField:"x-api-key");request.setValue("2023-06-01",forHTTPHeaderField:"anthropic-version")
        case .gemini:request.setValue(bearer,forHTTPHeaderField:"x-goog-api-key")
        default:if !bearer.isEmpty {request.setValue("Bearer "+bearer,forHTTPHeaderField:"Authorization")}
        }
        return request
    }
    static func listPath(_ kind:ModelProtocol)->String {switch kind{case .anthropic:return "/v1/models";case .gemini:return "/v1beta/models?pageSize=1000";default:return "/models"}}
    static func models(_ value:[String:Any],kind:ModelProtocol)->[ProviderModel] {
        let rows=value[kind == .gemini ? "models":"data"] as? [[String:Any]] ?? []
        return rows.compactMap { row in
            guard let raw=row[kind == .gemini ? "name":"id"] as? String else{return nil}
            if kind == .gemini,let methods=row["supportedGenerationMethods"] as? [String],!methods.contains("generateContent"){return nil}
            let id=kind == .gemini ? raw.replacingOccurrences(of:"models/",with:""):raw
            let name=row["display_name"] as? String ?? row["displayName"] as? String ?? row["name"] as? String ?? id
            let modalities=(row["input_modalities"] as? [String]) ?? []
            return .init(id:id,name:name,vision:row["vision"] as? Bool ?? modalities.contains("image"))
        }.sorted{$0.id<$1.id}
    }
    static func chat(provider:ModelProvider,model:String,messages:[[String:String]],bearer:String,session:String) throws -> URLRequest {
        let supplied=messages.filter{$0["role"]=="system" || $0["role"]=="developer"}.compactMap{$0["content"]}.joined(separator:"\n")
        let instructions=supplied.isEmpty ? "你是对话助手。没有设备执行工具，不要声称已操作设备。":supplied
        let dialogue=messages.filter{$0["role"] != "system" && $0["role"] != "developer"}
        var path:String;var body:[String:Any]
        switch provider.kind {
        case .chatGPT,.responses:
            path="/responses";body=["model":model,"store":false,"stream":true,"instructions":instructions,"input":dialogue.map{["type":"message","role":$0["role"]!,"content":[["type":$0["role"]=="assistant" ? "output_text":"input_text","text":$0["content"]!]]] as [String:Any]}]
        case .chatCompletions:
            path="/chat/completions";body=["model":model,"stream":false,"messages":[["role":"system","content":instructions]]+dialogue]
        case .anthropic:
            path="/v1/messages";body=["model":model,"max_tokens":4096,"system":instructions,"messages":dialogue]
        case .gemini:
            guard model.range(of:"^[A-Za-z0-9._-]+$",options:.regularExpression) != nil else{throw ModelFailure(message:"Gemini 模型 ID 无效")}
            path="/v1beta/models/\(model):generateContent";body=["systemInstruction":["parts":[["text":instructions]]],"contents":dialogue.map{["role":$0["role"]=="assistant" ? "model":"user","parts":[["text":$0["content"]!]]] as [String:Any]}]
        }
        var request=try request(provider:provider,path:path,bearer:bearer,session:session);request.httpMethod="POST"
        request.httpBody=try JSONSerialization.data(withJSONObject:body)
        if provider.kind == .chatGPT || provider.kind == .responses {request.setValue("text/event-stream",forHTTPHeaderField:"Accept")}
        return request
    }
    static func text(_ value:[String:Any],kind:ModelProtocol)->String {
        switch kind {
        case .chatCompletions:return (((value["choices"] as? [[String:Any]])?.first)?["message"] as? [String:Any])?["content"] as? String ?? ""
        case .anthropic:return (value["content"] as? [[String:Any]] ?? []).compactMap{$0["text"] as? String}.joined()
        case .gemini:return (((value["candidates"] as? [[String:Any]])?.first)?["content"] as? [String:Any]).flatMap{$0["parts"] as? [[String:Any]]}?.compactMap{$0["text"] as? String}.joined() ?? ""
        default:return ""
        }
    }
}
