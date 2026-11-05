import SwiftUI

struct ModelSettingsView:View {
    @ObservedObject private var catalog=ModelCatalog.shared
    @ObservedObject private var account=ModelAccount.shared
    @Environment(\.dismiss) var dismiss
    @State private var adding:ProviderPreset?
    var body:some View {
        NavigationStack {
            List {
                Section("本机主控模型") {
                    ForEach(ModelRole.allCases,id:\.self){role in
                        NavigationLink {ModelRolePicker(role:role)} label:{HStack{Text(role.title);Spacer();Text(catalog.label(role)).foregroundStyle(.secondary).lineLimit(1)}}
                    }
                }
                Section("服务商") {
                    ForEach(catalog.saved.providers){provider in
                        NavigationLink {ModelProviderDetail(id:provider.id)} label:{
                            VStack(alignment:.leading,spacing:5){Text(provider.name);Text(provider.kind == .chatGPT ? (account.credentials.accessToken.isEmpty ? "未登录":account.credentials.email):"\(provider.models.count) 个模型 · \(provider.kind.label)").font(.caption).foregroundStyle(.secondary)}
                        }
                    }
                }
                Section("添加服务商") {
                    ForEach(ProviderPreset.all) { preset in
                        Button { adding=preset } label: {
                            HStack { Text(preset.name); Spacer(); Text(preset.kind.label).font(.caption).foregroundStyle(.secondary); Image(systemName:"plus.circle").foregroundStyle(.mint) }
                        }.foregroundStyle(.primary)
                    }
                }
                if account.credentials.accessToken.isEmpty {
                    Section("ChatGPT 套餐") {
                        Button("Continue with ChatGPT"){account.signIn()}.disabled(account.working)
                        Text(account.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error=catalog.errors["settings"]{Text(error).foregroundStyle(.orange)}
            }.navigationTitle("模型").navigationBarTitleDisplayMode(.inline)
                .toolbar{Button("完成"){dismiss()}}
                .sheet(item:$adding){preset in AddModelProviderView(initialPreset:preset)}
                .onAppear{catalog.syncChatGPT()}
                .onChange(of:account.models){_ in catalog.syncChatGPT()}
                .onChange(of:account.credentials.clientId){_ in catalog.syncChatGPT()}
        }
    }
}
struct ModelRolePicker:View {
    let role:ModelRole
    @ObservedObject private var catalog=ModelCatalog.shared
    @Environment(\.dismiss) var dismiss
    @State private var search=""
    var body:some View {
        List {
            if role != .main && role != .dispatch {
                Section {
                    Button("用主模型"){catalog.inherit(role);dismiss()}
                    if role == .vision{Button("不用"){catalog.inherit(role,disabled:true);dismiss()}}
                }
            }
            if role == .dispatch {Section{Text("仅当前主控端调用，用于拆分和分配任务；不下发到设备执行模型。").font(.footnote)}}
            ForEach(catalog.saved.providers){provider in
                Section(provider.name) {
                    ForEach(provider.models.filter{search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search)}){model in
                        Button {catalog.choose(role,provider:provider,model:model.id);dismiss()} label:{
                            HStack {VStack(alignment:.leading){Text(model.name);if model.name != model.id{Text(model.id).font(.caption).foregroundStyle(.secondary)}};Spacer();if catalog.saved.roles[role.rawValue] == ModelSelection(providerId:provider.id,model:model.id){Image(systemName:"checkmark")}}
                        }
                    }
                }
            }
        }.searchable(text:$search,prompt:"搜索模型").navigationTitle(role.title)
    }
}
struct AddModelProviderView:View {
    @ObservedObject private var account=ModelAccount.shared
    @ObservedObject private var catalog=ModelCatalog.shared
    @Environment(\.dismiss) var dismiss
    @State private var preset="DeepSeek"
    @State private var draft=ModelProvider(name:"DeepSeek",kind:.chatCompletions,baseURL:"https://api.deepseek.com")
    @State private var manual=""
    @State private var testing=false
    @State private var error:String?
    @State private var showKey=false
    init(initialPreset:ProviderPreset = ProviderPreset.all[0]) {
        _preset=State(initialValue:initialPreset.name)
        _draft=State(initialValue:ModelProvider(name:initialPreset.name,kind:initialPreset.kind,baseURL:initialPreset.baseURL,sessionHeader:initialPreset.sessionHeader))
    }
    var body:some View {
        NavigationStack {
            Form {
                if account.credentials.accessToken.isEmpty {
                    Section {
                        Text("用你的 ChatGPT 套餐").font(.headline)
                        Button("Continue with ChatGPT"){account.signIn()}.disabled(account.working || testing)
                        if account.working{ProgressView("等待授权")}
                        Text(account.status).font(.caption).foregroundStyle(.secondary)
                    }
                } else {Button("使用已登录的 ChatGPT"){catalog.syncChatGPT();dismiss()}}
                Section("添加服务商") {
                    ScrollView(.horizontal,showsIndicators:false){HStack {ForEach(ProviderPreset.all){item in
                        Button(item.name){preset=item.name;draft=ModelProvider(name:item.name,kind:item.kind,baseURL:item.baseURL,sessionHeader:item.sessionHeader);error=nil}
                            .buttonStyle(.bordered).tint(preset==item.name ? .mint:.gray)
                    }}}.listRowInsets(EdgeInsets(top:12,leading:0,bottom:12,trailing:0))
                    if preset=="自定义" {
                        TextField("名称",text:$draft.name)
                        Picker("接口类型",selection:$draft.kind){ForEach(ModelProtocol.allCases.filter{$0 != .chatGPT},id:\.self){Text($0.label).tag($0)}}
                        TextField("Base URL",text:$draft.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    HStack {
                        Group{if showKey{TextField("API Key",text:$draft.apiKey)}else{SecureField("API Key",text:$draft.apiKey)}}.textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(showKey ? "隐藏":"显示"){showKey.toggle()}.font(.caption)
                    }
                    TextField("测试模型 ID（可选）",text:$manual).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(testing ? "测试中…":"测试并保存") {
                        testing=true;error=nil
                        let provider=draft,model=manual.trimmingCharacters(in:.whitespacesAndNewlines)
                        Task {do{try await catalog.testAndSave(provider,manualModel:model);dismiss()}catch{self.error=error.localizedDescription};testing=false}
                    }.disabled(testing || draft.baseURL.isEmpty || (draft.apiKey.isEmpty && preset != "自定义"))
                    if let error{Text(error).font(.caption).foregroundStyle(.orange)}
                }.disabled(testing)
            }.navigationTitle("添加服务商").navigationBarTitleDisplayMode(.inline)
                .toolbar{Button("取消"){dismiss()}.disabled(testing)}
                .onChange(of:account.credentials.accessToken){token in if !token.isEmpty{catalog.syncChatGPT()}}
        }.interactiveDismissDisabled(testing)
    }
}
struct ModelProviderDetail:View {
    let id:String
    @ObservedObject private var catalog=ModelCatalog.shared
    @ObservedObject private var account=ModelAccount.shared
    @Environment(\.dismiss) var dismiss
    @State private var key=""
    @State private var changingKey=false
    @State private var confirmRemove=false
    @State private var search=""
    var provider:ModelProvider?{catalog.saved.providers.first{$0.id==id}}
    var body:some View {
        Group {
            if let provider {
                List {
                    Section("连接") {
                        Text(provider.kind.label)
                        Text(provider.baseURL).font(.caption).foregroundStyle(.secondary)
                        if provider.kind == .chatGPT {
                            Text(account.credentials.accessToken.isEmpty ? "未登录":account.credentials.email)
                            Button(account.credentials.accessToken.isEmpty ? "Continue with ChatGPT":"重新登录"){account.signIn()}.disabled(account.working)
                            Link("管理套餐用量",destination:URL(string:"https://chatgpt.com/settings/usage")!)
                            Button("退出登录",role:.destructive){account.signOut()}
                            Text(account.status).font(.caption).foregroundStyle(.secondary)
                        } else {Button("修改 API Key"){changingKey=true}}
                        Button(catalog.busy.contains(id) ? "加载中…":"刷新模型列表"){Task{await catalog.refresh(id)}}.disabled(catalog.busy.contains(id))
                        if let message=catalog.errors[id]{Text(message).font(.caption).foregroundStyle(message.hasPrefix("调用成功") ? .green:.orange)}
                    }
                    Section("模型（\(provider.models.count)）") {
                        ForEach(provider.models.filter{search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search)}){model in
                            VStack(alignment:.leading,spacing:8){
                                Text(model.name).font(.headline)
                                if model.name != model.id{Text(model.id).font(.caption).foregroundStyle(.secondary)}
                                HStack {
                                    ForEach(ModelRole.allCases,id:\.self){role in
                                        Button(role.title){catalog.choose(role,provider:provider,model:model.id)}.buttonStyle(.bordered).tint(catalog.selection(role)==ModelSelection(providerId:id,model:model.id) ? .mint:.gray)
                                    }
                                }.font(.caption)
                                Button("测试调用"){Task{await catalog.probe(provider,model:model.id)}}.font(.caption).disabled(catalog.busy.contains(id))
                            }.padding(.vertical,5)
                        }
                    }
                    Section{Button("移除服务商",role:.destructive){confirmRemove=true}}
                }.navigationTitle(provider.name).searchable(text:$search,prompt:"搜索模型")
                    .confirmationDialog("移除服务商及其模型用途？",isPresented:$confirmRemove,titleVisibility:.visible){Button("移除",role:.destructive){catalog.remove(id);dismiss()}}
                    .alert("修改 API Key",isPresented:$changingKey){SecureField("API Key",text:$key);Button("测试并保存"){var draft=provider;draft.apiKey=key;key="";Task{do{try await catalog.testAndSave(draft,manualModel:catalog.selection(.main)?.providerId==id ? catalog.selection(.main)!.model:"")}catch{catalog.errors[id]=error.localizedDescription}}};Button("取消",role:.cancel){key=""}}
            } else {LegacyEmptyState(title:"服务商已移除",systemImage:"network")}
        }
    }
}
