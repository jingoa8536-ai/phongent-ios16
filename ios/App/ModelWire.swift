import Foundation

struct ModelFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
struct ModelResponseStream {
    private(set) var text = ""
    private(set) var completed = false
    mutating func accept(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let raw=line.dropFirst(5).trimmingCharacters(in:.whitespaces)
        if raw=="[DONE]" { return } // Transport end alone must not mark inference successful.
        guard let data=raw.data(using:.utf8),let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw ModelFailure(message:"模型数据格式错误")}
        switch value["type"] as? String {
        case "response.output_text.delta": text += value["delta"] as? String ?? ""
        case "response.completed":
            if text.isEmpty,let response=value["response"] as? [String:Any],let output=response["output"] as? [[String:Any]] {
                text=output.flatMap{($0["content"] as? [[String:Any]]) ?? []}.filter{$0["type"] as? String=="output_text"}.compactMap{$0["text"] as? String}.joined()
            }
            completed=true
        case "response.failed", "error": throw ModelFailure(message:"模型未能完成请求")
        case "response.incomplete": throw ModelFailure(message:"回复未完成，请重试")
        default: break
        }
    }
    func validateCompletion() throws {if !completed {throw ModelFailure(message:"连接中断，回复未完成")}}
}
