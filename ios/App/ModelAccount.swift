import Foundation
import Security
import CryptoKit
import AuthenticationServices
import Network
import UIKit

struct ModelCredentials: Codable {
    var clientId = ""
    var accessToken = ""
    var refreshToken = ""
    var idToken = ""
    var email = ""
    var expiresAt = Date.distantPast
    var model = "gpt-5.6-luna"
    var apiKey = ""
    var baseURL = "https://api.openai.com/v1"
    var usePlan = true
}
@MainActor final class ModelAccount: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = ModelAccount()
    @Published var credentials = ModelCredentials()
    @Published var status = "未登录"
    @Published var models: [String] = []
    @Published var working = false
    private var browser: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?
    private var attempt: (state: String, nonce: String, verifier: String, redirect: String)?
    private var refreshing: Task<String, Error>?
    private let issuer = "https://auth.openai.com"
    private let scope = "chatgpt.tokens.use.direct"
    private var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"AgentModelAccount",kSecAttrAccount as String:"primary"] }
    override init() {
        super.init()
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var value: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary,&value)==errSecSuccess, let data=value as? Data, let saved=try? JSONDecoder().decode(ModelCredentials.self,from:data) {
            credentials=saved; status=saved.accessToken.isEmpty ? "未登录" : saved.email
        }
    }
    func save() throws {
        let data=try JSONEncoder().encode(credentials)
        var result=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result==errSecItemNotFound {var q=query;q[kSecValueData as String]=data;q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;result=SecItemAdd(q as CFDictionary,nil)}
        guard result==errSecSuccess else {throw ModelFailure(message:"无法保存登录信息")}
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func random() throws -> String {
        var bytes=[UInt8](repeating:0,count:48)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw ModelFailure(message:"无法创建登录会话")}
        return Self.b64(Data(bytes))
    }
    static func b64(_ data: Data) -> String {data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
    static func unb64(_ value: String) -> Data? { let s=value.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");return Data(base64Encoded:s+String(repeating:"=",count:(4-s.count%4)%4)) }
    func signIn() {
        guard !working else{return}; working=true;status="正在打开登录"
        do {
            let state=try random(),nonce=try random(),verifier=try random()
            let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
            let listener=try NWListener(using:parameters);self.listener=listener
            listener.newConnectionHandler={ [weak self] connection in
                connection.start(queue:.main)
                Task { @MainActor in self?.readCallback(connection,buffer:Data()) }
            }
            listener.stateUpdateHandler={ [weak self] value in
                Task { @MainActor in
                guard let self else{return}
                if case .ready=value, let port=listener.port {
                    let redirect="http://127.0.0.1:\(port.rawValue)/auth/callback"
                    self.attempt=(state,nonce,verifier,redirect)
                    var host=UserDefaults.standard.string(forKey:"modelHost")
                    if host==nil {host="urn:uuid:"+UUID().uuidString;UserDefaults.standard.set(host,forKey:"modelHost")}
                    var fields=["client_id":self.credentials.clientId.isEmpty ? "dynamic_agent_client":self.credentials.clientId,
                        "ext_agent_host_id":host!,"response_type":"code","redirect_uri":redirect,
                        "scope":"openid profile email offline_access resource.invoke \(self.scope)","resource":"https://api.openai.com/v1",
                        "state":state,"nonce":nonce,"code_challenge_method":"S256","code_challenge":Self.b64(Data(SHA256.hash(data:Data(verifier.utf8))))]
                    if self.credentials.clientId.isEmpty {fields["agent_name_hint"]="phongent"}
                    else if !self.credentials.idToken.isEmpty {fields["id_token_hint"]=self.credentials.idToken}
                    var url=URLComponents(string:self.issuer+"/api/accounts/authorize")!;url.queryItems=fields.map{URLQueryItem(name:$0.key,value:$0.value)}
                    let browser=ASWebAuthenticationSession(url:url.url!,callbackURLScheme:"agentauth") { [weak self] _,error in
                        Task { @MainActor in if error != nil && self?.attempt != nil {self?.finish("登录已取消")} }
                    }
                    browser.presentationContextProvider=self;self.browser=browser
                    if !browser.start(){self.finish("无法打开登录窗口")}
                } else if case .failed=value {self.finish("无法启动登录回调")}
            }
            }
            listener.start(queue:.main)
            timeout=Task {try? await Task.sleep(for:.seconds(300));if !Task.isCancelled {finish("登录超时，请重试")}}
        } catch {finish(error.localizedDescription)}
    }
    private func readCallback(_ connection:NWConnection,buffer:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] data,_,done,error in
            Task { @MainActor in
            guard let self else {connection.cancel();return}
            var buffer=buffer;if let data {buffer.append(data)}
            guard buffer.count<=16384,error==nil else {connection.cancel();return}
            guard let request=String(data:buffer,encoding:.utf8),request.contains("\r\n\r\n") else {
                if !done {self.readCallback(connection,buffer:buffer)} else {connection.cancel()};return
            }
            let parts=request.components(separatedBy:"\r\n")[0].split(separator:" ")
            guard parts.count==3,parts[0]=="GET",let url=URLComponents(string:"http://127.0.0.1"+parts[1]),url.path=="/auth/callback",let attempt=self.attempt else{connection.cancel();return}
            var fields:[String:String]=[:];for item in url.queryItems ?? [] {if fields[item.name] != nil {connection.cancel();return};fields[item.name]=item.value}
            guard fields["state"]==attempt.state else{connection.cancel();return}
            self.attempt=nil
            let response="HTTP/1.1 302 Found\r\nLocation: agentauth://complete\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content:Data(response.utf8),completion:.contentProcessed{_ in connection.cancel()})
            await self.completeSignIn(fields,attempt:attempt)
            }
        }
    }
    private func completeSignIn(_ fields:[String:String],attempt:(state:String,nonce:String,verifier:String,redirect:String)) async {
        do {
            guard fields["error"]==nil,let code=fields["code"] else {throw ModelFailure(message:"登录未获授权")}
            let client=fields["client_id"] ?? credentials.clientId
            guard !client.isEmpty,client != "dynamic_agent_client",credentials.clientId.isEmpty || client==credentials.clientId else {throw ModelFailure(message:"登录客户端不匹配")}
            let result=try await token(["grant_type":"authorization_code","client_id":client,"code":code,"code_verifier":attempt.verifier,"redirect_uri":attempt.redirect])
            guard let id=result["id_token"] as? String else {throw ModelFailure(message:"缺少身份令牌")}
            let email=try await verify(id,client:client,nonce:attempt.nonce)
            let scopes=(result["scope"] as? String ?? "").split(separator:" ")
            guard scopes.contains(Substring(scope)) else {throw ModelFailure(message:"该账号未授权套餐调用")}
            var next=credentials;next.clientId=client;next.email=email;next.idToken=id;next.usePlan=true
            try applyTokens(result,to:&next);credentials=next;try save();finish("已登录 · "+email)
            await loadModels()
        } catch {finish(error.localizedDescription)}
    }
    private func finish(_ message:String) {attempt=nil;timeout?.cancel();timeout=nil;listener?.cancel();listener=nil;browser?.cancel();browser=nil;working=false;status=message}
    private func token(_ fields:[String:String]) async throws -> [String:Any] {
        var fields=fields;fields["resource"]="https://api.openai.com/v1"
        var components=URLComponents();components.queryItems=fields.map{URLQueryItem(name:$0.key,value:$0.value)}
        var request=URLRequest(url:URL(string:issuer+"/api/accounts/oauth/token")!);request.httpMethod="POST"
        request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        request.httpBody=Data((components.percentEncodedQuery ?? "").replacingOccurrences(of:"+",with:"%2B").utf8)
        return try await json(request)
    }
    private func applyTokens(_ value:[String:Any],to target:inout ModelCredentials) throws {
        guard let access=value["access_token"] as? String,!access.isEmpty else {throw ModelFailure(message:"登录返回无效")}
        target.accessToken=access;target.refreshToken=value["refresh_token"] as? String ?? target.refreshToken
        target.idToken=value["id_token"] as? String ?? target.idToken
        target.expiresAt=Date().addingTimeInterval(value["expires_in"] as? Double ?? 3600)
    }
    func bearer(force:Bool=false) async throws -> String {
        if !credentials.usePlan {guard !credentials.apiKey.isEmpty else{throw ModelFailure(message:"请填写 API Key")};return credentials.apiKey}
        return try await planBearer(force:force)
    }
    func planBearer(force:Bool=false) async throws -> String {
        if !force,credentials.expiresAt.timeIntervalSinceNow>300,!credentials.accessToken.isEmpty{return credentials.accessToken}
        if let refreshing{return try await refreshing.value}
        let task=Task { @MainActor () throws -> String in
            guard !credentials.refreshToken.isEmpty else{throw ModelFailure(message:"请先登录 ChatGPT")}
            let value=try await token(["grant_type":"refresh_token","client_id":credentials.clientId,"refresh_token":credentials.refreshToken])
            if let scopes=value["scope"] as? String,!scopes.split(separator:" ").contains(Substring(scope)){throw ModelFailure(message:"套餐调用权限未获授权")}
            var next=credentials;try applyTokens(value,to:&next);credentials=next;try save();return next.accessToken
        };refreshing=task;defer{refreshing=nil};return try await task.value
    }
    func json(_ request:URLRequest) async throws -> [String:Any] {
        let (data,response)=try await URLSession.shared.data(for:request)
        let code=(response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else{throw ModelHTTPFailure.make(status:code,data:data,stage:"账号请求")}
        guard let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw ModelFailure(message:"服务返回无效")};return result
    }
    static func httpMessage(_ code:Int) -> String {switch code{case 401:return "登录已失效或 API Key 无效，请重新登录";case 403:return "账号或模型未获授权";case 429:return "额度不足或请求过于频繁";default:return "模型服务错误（HTTP \(code)）"}}
    func loadModels() async {
        do {
            let token=try await bearer();let base=credentials.usePlan ? "https://api.openai.com/v1":credentials.baseURL.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            guard let url=URL(string:base+"/models"),url.scheme=="https" else{throw ModelFailure(message:"模型地址需使用 HTTPS")}
            var request=URLRequest(url:url);request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
            let value=try await json(request);models=(value["data"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String}.sorted()
            status=models.contains(credentials.model) ? "模型可用":"请从账号模型列表中选择"
        } catch {status=error.localizedDescription}
    }
    func signOut() {refreshing?.cancel();refreshing=nil;finish("已退出登录");credentials=ModelCredentials();models=[];SecItemDelete(query as CFDictionary)}
    private func verify(_ jwt:String,client:String,nonce:String) async throws -> String {
        func fail() -> ModelFailure{ModelFailure(message:"登录身份校验失败")}
        let parts=jwt.split(separator:".").map(String.init)
        guard parts.count==3,let hd=Self.unb64(parts[0]),let cd=Self.unb64(parts[1]),let sig=Self.unb64(parts[2]),
              let header=try JSONSerialization.jsonObject(with:hd) as? [String:Any],let claims=try JSONSerialization.jsonObject(with:cd) as? [String:Any],
              header["alg"] as? String=="RS256",let kid=header["kid"] as? String else{throw fail()}
        let keys=try await json(URLRequest(url:URL(string:issuer+"/.well-known/jwks.json")!))
        guard let key=(keys["keys"] as? [[String:Any]])?.first(where:{$0["kid"] as? String==kid}),let n=key["n"] as? String,let e=key["e"] as? String,let modulus=Self.unb64(n),let exponent=Self.unb64(e) else{throw fail()}
        func length(_ n:Int)->Data {if n<128{return Data([UInt8(n)])};var n=n;var bytes:[UInt8]=[];while n>0{bytes.insert(UInt8(n&255),at:0);n>>=8};return Data([0x80|UInt8(bytes.count)]+bytes)}
        func integer(_ d:Data)->Data {var d=d;if d.first! & 0x80 != 0{d.insert(0,at:0)};return Data([2])+length(d.count)+d}
        let sequence=integer(modulus)+integer(exponent);let der=Data([0x30])+length(sequence.count)+sequence
        let attrs=[kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeyClass:kSecAttrKeyClassPublic] as CFDictionary
        guard let publicKey=SecKeyCreateWithData(der as CFData,attrs,nil),SecKeyVerifySignature(publicKey,.rsaSignatureMessagePKCS1v15SHA256,Data((parts[0]+"."+parts[1]).utf8) as CFData,sig as CFData,nil),
              claims["iss"] as? String==issuer,claims["nonce"] as? String==nonce,
              (claims["aud"] as? String==client || (claims["aud"] as? [String] ?? []).contains(client)),
              let expires=claims["exp"] as? Double,expires+120>Date().timeIntervalSince1970,let sub=claims["sub"] as? String,!sub.isEmpty else {throw fail()}
        return claims["email"] as? String ?? (claims["https://api.openai.com/profile"] as? [String:Any])?["email"] as? String ?? "ChatGPT"
    }
}
