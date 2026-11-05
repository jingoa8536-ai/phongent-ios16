import SwiftUI

struct LocalChatMessage: Identifiable {let id=UUID();var role:String;var text:String}
@MainActor final class ModelChat: ObservableObject {
    @Published var messages:[LocalChatMessage]=[]
    @Published var busy=false
    @Published var error:String?
    private let sessionId=UUID().uuidString
    private var requestTask:Task<Void,Never>?
    func send(_ text:String) {
        guard !busy,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        messages.append(.init(role:"user",text:text));busy=true;error=nil
        let history=messages
        messages.append(.init(role:"assistant",text:""))
        let outputId=messages.last!.id
        requestTask=Task {
            defer{busy=false;requestTask=nil}
            do {
                let catalog=ModelCatalog.shared
                guard let selected=catalog.selection(.main),let provider=catalog.saved.providers.first(where:{$0.id==selected.providerId}) else {throw ModelFailure(message:"请在模型设置中选择主模型")}
                _=try await catalog.reply(provider:provider,model:selected.model,messages:history.filter{!$0.text.isEmpty}.map{["role":$0.role,"content":$0.text]},session:sessionId) { value in
                    if let index=self.messages.firstIndex(where:{$0.id==outputId}){self.messages[index].text=value}
                }
            } catch is CancellationError {error="已停止"} catch {self.error=error.localizedDescription}
        }
    }
    func stop(){requestTask?.cancel()}
}
struct ModelChatView:View {
    @StateObject private var chat=ModelChat()
    @State private var text=""
    @State private var settings=false
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                ScrollViewReader {proxy in
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:16) {
                            ForEach(chat.messages){message in
                                HStack {
                                    if message.role=="user" {Spacer(minLength:36)}
                                    Text(message.text.isEmpty ? "…":message.text).textSelection(.enabled).padding(14)
                                        .background(message.role=="user" ? Color.mint.opacity(0.2):Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:16))
                                    if message.role != "user" {Spacer(minLength:36)}
                                }.id(message.id)
                            }
                            if let error=chat.error {Text(error).font(.caption).foregroundStyle(.orange)}
                        }.padding()
                    }.onChange(of:chat.messages.last?.text){_ in if let id=chat.messages.last?.id{proxy.scrollTo(id,anchor:.bottom)}}
                }
                HStack(alignment:.bottom) {
                    TextField("与 agent 对话",text:$text,axis:.vertical).lineLimit(1...6).padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:14))
                    if chat.busy {Button("停止"){chat.stop()}}
                    else{Button {let value=text;text="";chat.send(value)} label:{Image(systemName:"arrow.up.circle.fill").font(.title)}.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                }.padding()
            }.navigationTitle("agent").navigationBarTitleDisplayMode(.inline)
                .toolbar{Button("模型",systemImage:"slider.horizontal.3"){settings=true}}
                .sheet(isPresented:$settings){ModelSettingsView()}
        }
    }
}
