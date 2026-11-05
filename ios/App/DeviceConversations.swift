import Foundation

struct DeviceConversation:Codable,Identifiable {
    var id:String
    var title:String
    var preview:String
    var updatedAt:Double
    var busy:Bool
    var needsAttention:Bool
}
