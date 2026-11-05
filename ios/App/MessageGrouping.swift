import Foundation

struct MessageConversation:Identifiable {
    var id:String
    var messages:[MessagePreview]
    var latest:MessagePreview {messages[0]}
}
enum MessageGrouping {
    static func conversations(_ messages:[MessagePreview])->[MessageConversation] {
        Dictionary(grouping:messages){$0.conversationId ?? ($0.app+":"+$0.title)}.map {
            MessageConversation(id:$0.key,messages:$0.value.sorted{$0.time>$1.time})
        }.sorted{$0.latest.time>$1.latest.time}
    }
}
