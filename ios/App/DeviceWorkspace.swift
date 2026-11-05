import SwiftUI

struct DeviceWorkspace:View {
    @ObservedObject var hub:NearbyHub
    var singleDevice:Bool
    var onLeave:(()->Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDevice:String
    @State private var drawer=false
    @State private var search=""
    @State private var renameTarget:NearbyAgent?
    @State private var renameText=""
    init(hub:NearbyHub,initialDevice:String,singleDevice:Bool=false,onLeave:(()->Void)?=nil) {self.hub=hub;self.singleDevice=singleDevice;self.onLeave=onLeave;_selectedDevice=State(initialValue:initialDevice);_drawer=State(initialValue:!singleDevice)}
    private var selected:NearbyAgent? {hub.agents.first{$0.id==selectedDevice}}
    private var wide:Bool {sizeClass == .regular && !singleDevice}
    var body:some View {
        if !singleDevice || hub.agents.filter({$0.approved && !$0.demo}).count>1 {FleetWorkspace(hub:hub,initialSelection:singleDevice ? selectedDevice:nil)}else{legacyBody}
    }
    private var legacyBody:some View {
        GeometryReader { geometry in
            ZStack(alignment:.leading) {
                HStack(spacing:0) {
                    if wide {sidebar.frame(width:300);Divider()}
                    if let agent=selected {
                        Dashboard(onShowSidebar:{withAnimation(.easeOut(duration:0.2)){drawer.toggle()}},agentName:agent.name,avatarShape:agent.avatarShape,avatarHue:agent.avatarHue,onRename:{renameText=agent.name;renameTarget=agent})
                            .environmentObject(agent.client).id(agent.id)
                    } else {LegacyEmptyState(title:"选择设备",systemImage:"iphone.gen3")}
                }
                if drawer && !wide {
                    Color.black.opacity(0.45).ignoresSafeArea().onTapGesture{withAnimation{drawer=false}}
                    sidebar.frame(width:min(350,geometry.size.width*0.88)).transition(.move(edge:.leading)).shadow(radius:20)
                }
            }
        }.overlay(alignment:.top) {if let agent=selected {AgentNoticeBanner(bridge:agent.client).padding(.horizontal,14).padding(.top,8)}}
        .alert("设备名称",isPresented:Binding(get:{renameTarget != nil},set:{if !$0{renameTarget=nil}})) {
            TextField("名称",text:$renameText)
            Button("取消",role:.cancel){renameTarget=nil}
            Button("保存"){if let agent=renameTarget{hub.rename(agent,to:renameText)};renameTarget=nil}
        }
    }
    @ViewBuilder private var sidebar:some View {
        if singleDevice,let agent=selected {
            SingleDeviceDrawer(agent:agent,hub:hub,close:{withAnimation{drawer=false}},leave:{if let onLeave{onLeave()}else{dismiss()}})
        } else { multiSidebar }
    }
    private var multiSidebar:some View {
        NavigationStack {
            List {
                Button {
                    guard let agent=selected else{return}
                    Task {
                        let created=await agent.client.newChat()
                        if created {withAnimation{drawer=false}}
                    }
                } label:{Label("新建聊天",systemImage:"square.and.pencil").font(.headline)}
                .disabled(selected == nil || selected?.client.connected != true || selected?.client.sending == true || selected?.client.switchingChat == true || selected?.client.snapshot.busy == true)
                if let agent=selected,let status=agent.client.commandStatus,!status.hasPrefix("指令状态") {Text(status).font(.caption).foregroundStyle(.orange)}
                if let agent=selected {
                    NavigationLink {KnowledgeView(hub:hub,defaultDevice:agent.id)} label:{Label("记忆与技能",systemImage:"heart")}
                }
                NavigationLink {ModelChatView()} label:{Label("模型对话",systemImage:"bubble.left.and.bubble.right")}
                ForEach(hub.agents.filter{$0.approved || $0.demo}) {agent in
                    DeviceConversationGroup(agent:agent,selectedDevice:selectedDevice,search:search,onDevice:{chooseDevice(agent)},onConversation:{chat in
                        Task {
                            if await agent.client.selectChat(chat.id) {chooseDevice(agent)}
                        }
                    },rename:{renameText=agent.name;renameTarget=agent})
                }
            }.listStyle(.sidebar).searchable(text:$search,prompt:"搜索设备或聊天")
            .navigationTitle("聊天").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading){Button("设备",systemImage:"chevron.left"){if let onLeave{onLeave()}else{dismiss()}}}
                if !wide {ToolbarItem(placement:.topBarTrailing){Button {withAnimation{drawer=false}} label:{Image(systemName:"xmark")}.accessibilityLabel("关闭侧栏")}}
            }
            .task {await refreshLists()}
            .refreshable {await refreshLists()}
        }
    }
    private func refreshLists() async {
        await withTaskGroup(of:Void.self) {group in
            for agent in hub.agents where agent.approved {group.addTask{@MainActor in await agent.client.refreshConversations()}}
        }
    }
    private func chooseDevice(_ agent:NearbyAgent) {
        selectedDevice=agent.id;hub.select(agent)
        if let id=agent.client.snapshot.currentConversationId {agent.client.markChatRead(id)}
        withAnimation{drawer=false}
    }
}

private struct DeviceConversationGroup:View {
    @ObservedObject var agent:NearbyAgent
    @ObservedObject var bridge:BridgeClient
    var selectedDevice:String
    var search:String
    var onDevice:()->Void
    var onConversation:(DeviceConversation)->Void
    var rename:()->Void
    @State private var expanded=true
    init(agent:NearbyAgent,selectedDevice:String,search:String,onDevice:@escaping()->Void,onConversation:@escaping(DeviceConversation)->Void,rename:@escaping()->Void) {
        self.agent=agent;self.bridge=agent.client;self.selectedDevice=selectedDevice;self.search=search;self.onDevice=onDevice;self.onConversation=onConversation;self.rename=rename
    }
    private var chats:[DeviceConversation] {
        bridge.conversations.filter{search.isEmpty || agent.name.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search)}
    }
    private var color:Color {let colors:[Color]=[.mint,.orange,.purple,.blue,.pink];return colors[agent.id.utf8.reduce(0){$0+Int($1)} % colors.count]}
    var body:some View {
        if search.isEmpty || agent.name.localizedCaseInsensitiveContains(search) || !chats.isEmpty {
            DisclosureGroup(isExpanded:$expanded) {
                Button("当前聊天",action:onDevice).font(.caption).foregroundStyle(color)
                if let error=bridge.conversationError {Text(error).font(.caption).foregroundStyle(.orange)}
                ForEach(chats) {chat in
                    Button {onConversation(chat)} label:{
                        HStack(alignment:.top,spacing:8) {
                            VStack(alignment:.leading,spacing:5) {
                                HStack {
                                    Text(chat.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Spacer(minLength:4)
                                    if bridge.chatUnread(chat) {Circle().fill(color).frame(width:6,height:6)}
                                }
                                Text(chat.needsAttention ? "需要处理" : chat.busy ? "正在执行" : chat.preview).font(.caption).foregroundStyle(chat.needsAttention ? Color.orange : .secondary).lineLimit(1)
                                if chat.updatedAt>0 {Text(Date(timeIntervalSince1970:chat.updatedAt),style:.relative).font(.caption2).foregroundStyle(.tertiary)}
                            }
                            if selectedDevice==agent.id && bridge.snapshot.currentConversationId==chat.id {Image(systemName:"checkmark").font(.caption).foregroundStyle(color)}
                        }.padding(.vertical,5).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(bridge.switchingChat || bridge.sending)
                        .modifier(ChatDeletionActions(bridge:bridge,chat:chat))
                        .listRowBackground(selectedDevice==agent.id && bridge.snapshot.currentConversationId==chat.id ? color.opacity(0.12):Color.clear)
                }
                if chats.isEmpty && bridge.conversationError == nil {Text(bridge.connected ? "暂无历史聊天":"离线 · 暂无缓存").font(.caption).foregroundStyle(.secondary)}
            } label:{
                HStack(spacing:10) {
                    AoraAnimatedAvatar(phase:agent.phase,active:bridge.snapshot.busy,shape:agent.avatarShape,hue:agent.avatarHue).frame(width:38,height:38).background(color.opacity(0.16),in:Circle())
                    VStack(alignment:.leading,spacing:3) {
                        Text(agent.name).font(.headline).lineLimit(1)
                        Text(bridge.connected ? bridge.snapshot.title : "离线").font(.caption2).foregroundStyle(bridge.connected ? color : .gray)
                    }
                }.contextMenu{Button("重命名",action:rename)}
            }
            .onChange(of:bridge.snapshot.chatRevision) { _ in Task{await bridge.refreshConversations()} }
            .onChange(of:bridge.snapshot.currentConversationId) { _ in Task{await bridge.refreshConversations()} }
            .onChange(of:bridge.snapshot.phase) { _ in Task{await bridge.refreshConversations()} }
        }
    }
}

private struct AgentNoticeBanner:View {
    @ObservedObject var bridge:BridgeClient
    var body:some View {
        ZStack {
            Color.clear.frame(width:1,height:1).allowsHitTesting(false)
            if let notice=bridge.notice {
                HStack(spacing:10) {
                    Image(systemName:"exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(notice.text).font(.subheadline).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:0)
                    Button {bridge.notice=nil} label:{Image(systemName:"xmark").font(.caption.bold()).frame(width:32,height:32)}.accessibilityLabel("关闭提示")
                }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:20)).shadow(color:.black.opacity(0.2),radius:10,y:4)
                    .accessibilityElement(children:.contain)
            }
        }.alert("删除聊天？",isPresented:Binding(get:{bridge.deletionTarget != nil},set:{if !$0{bridge.deletionTarget=nil}}),presenting:bridge.deletionTarget) {chat in
            Button("删除",role:.destructive){Task{await bridge.deleteChat(chat.id)}}
            Button("取消",role:.cancel){}
        } message:{chat in Text("删除“\(chat.title)”及安卓端对应记录、附件和关联定时任务。无法撤销。")}
        .task(id:bridge.notice?.id) {
            guard let id=bridge.notice?.id else{return}
            do {try await Task.sleep(for:.seconds(4))}catch{return}
            if bridge.notice?.id==id {bridge.notice=nil}
        }
    }
}
