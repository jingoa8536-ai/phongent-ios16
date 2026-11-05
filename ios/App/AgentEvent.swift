import Foundation

struct AgentEvent:Decodable {
    var kind:String
    var sequence:Int64
    var snapshot:AgentSnapshot?
    var upserts:[MessagePreview]?
    var removed:[String]?
}
struct AgentEventReducer {
    private(set) var sequence:Int64=0
    mutating func apply(_ event:AgentEvent,to state:AgentSnapshot) throws -> AgentSnapshot {
        guard event.sequence == sequence+1 else {throw URLError(.cannotParseResponse)}
        var next=state
        switch event.kind {
        case "snapshot":
            guard sequence==0,let snapshot=event.snapshot else {throw URLError(.cannotParseResponse)}
            next=snapshot
        case "state":
            guard sequence>0,var snapshot=event.snapshot else {throw URLError(.cannotParseResponse)}
            snapshot.messages=state.messages;next=snapshot
        case "messages":
            guard sequence>0,let upserts=event.upserts,let removed=event.removed else {throw URLError(.cannotParseResponse)}
            var records=Dictionary(state.messages.map{($0.id,$0)},uniquingKeysWith:{$1})
            for id in removed {records.removeValue(forKey:id)}
            for message in upserts {records[message.id]=message}
            next.messages=records.values.sorted{$0.time>$1.time}
        case "heartbeat":guard sequence>0 else {throw URLError(.cannotParseResponse)}
        default:throw URLError(.cannotParseResponse)
        }
        sequence=event.sequence
        return next
    }
}
