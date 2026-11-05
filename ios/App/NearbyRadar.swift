import SwiftUI

struct NearbyRadar:View {
    @ObservedObject var hub:NearbyHub
    @State private var selected:NearbyAgent?
    @State private var page=0
    @State private var batchBusy=false
    @State private var error:String?
    @State private var editingGroups=false
    @State private var checked:Set<String>=[]
    @State private var groupName=""
    @State private var targetGroup="默认组"
    @State private var renameDevice:NearbyAgent?
    @State private var deviceName=""
    @State private var showRename=false
    @Environment(\.scenePhase) private var scenePhase
    private var devices:[NearbyAgent]{hub.agents.filter{!$0.demo}}
    private var pageSize:Int{devices.count>6 ? 10:6}
    private var pages:Int{max(1,(devices.count+pageSize-1)/pageSize)}
    private var visible:[NearbyAgent]{Array(devices.dropFirst(min(page,pages-1)*pageSize).prefix(pageSize))}
    private func open(_ agent:NearbyAgent){
        guard !hub.connecting.contains(agent.id) else{return}
        if agent.client.connected{selected=agent;return}
        Task{@MainActor in if await hub.connect(agent){selected=agent}else{error=agent.name+"："+agent.connection}}
    }
    private func connectAll(){
        batchBusy=true
        let targets=devices.filter{!$0.client.connected && ($0.approved || $0.available) && !hub.connecting.contains($0.id)}
        Task{@MainActor in defer{batchBusy=false};let failed=await hub.connectAll(targets);if !failed.isEmpty{error="连接失败："+failed.joined(separator:"、")+"。可点击上方设备重试。"}}
    }
    @ViewBuilder private func deviceMenu(_ agent:NearbyAgent)->some View {
        Button("重命名设备",systemImage:"pencil"){renameDevice=agent;deviceName=agent.name;showRename=true}
        Button("移动到分组",systemImage:"folder"){checked=[agent.id];groupName="";targetGroup=hub.group(of:agent.id);editingGroups=true}.disabled(!agent.client.connected)
    }
    var body:some View {
        NavigationStack{
            ScrollView{
                VStack(spacing:16){
                    HStack{Button(batchBusy ? "连接中…":"一键连接",systemImage:"link",action:connectAll).disabled(batchBusy || devices.isEmpty);Spacer();Button("分组",systemImage:"folder"){checked=[];groupName="";targetGroup="默认组";editingGroups=true}}
                    GeometryReader{geo in
                        let center=CGPoint(x:geo.size.width/2,y:170)
                        ZStack{
                            ForEach([100.0,200.0,300.0],id:\.self){size in Circle().stroke(Color.primary.opacity(0.06)).frame(width:size,height:size).position(center)}
                            VStack{AoraAnimatedAvatar(phase:"idle",active:scenePhase == .active).frame(width:76,height:76);Text("本机").font(.caption)}.position(center)
                            ForEach(Array(visible.enumerated()),id:\.element.id){index,agent in
                                let angle = -Double.pi/2+Double(index)*2*Double.pi/Double(max(visible.count,3))
                                Button{open(agent)}label:{DeviceOrb(agent:agent,active:scenePhase == .active,size:devices.count>6 ? 42:62)}.buttonStyle(.plain)
                                    .contextMenu{deviceMenu(agent)}
                                    .position(x:center.x+cos(angle)*min(geo.size.width*0.39,148),y:center.y+sin(angle)*140)
                            }
                        }
                    }.frame(height:345)
                    if pages>1{HStack{Button("上一页"){page=max(0,page-1)}.disabled(page==0);Spacer();Text("\(min(page,pages-1)+1) / \(pages)");Spacer();Button("下一页"){page+=1}.disabled(page>=pages-1)}}
                    HStack{Text("\(devices.filter{$0.client.connected}.count) 已连接 · \(hub.connecting.count) 连接中");Spacer();Text("\(devices.filter{!$0.client.connected}.count) 未连接")}.font(.caption).foregroundStyle(.secondary)
                    HStack{Text("已连接设备").font(.headline);Spacer()}
                    if devices.filter({$0.client.connected}).isEmpty{Text("暂无已连接设备").foregroundStyle(.secondary)}
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:90),spacing:8)],spacing:8){
                        ForEach(devices.filter{$0.client.connected}){agent in
                            Button{open(agent)}label:{
                                VStack(spacing:6){
                                    AoraAnimatedAvatar(phase:agent.phase,active:scenePhase == .active,shape:agent.avatarShape,hue:agent.avatarHue).frame(width:38,height:38)
                                    Text(agent.name).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(hub.group(of:agent.id)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth:.infinity).padding(.vertical,10).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:12))
                            }.buttonStyle(.plain).contextMenu{deviceMenu(agent)}
                        }
                    }
                }.padding(18)
            }.background(Color(uiColor:.systemGroupedBackground)).navigationTitle("设备").navigationBarTitleDisplayMode(.inline)
            .onChange(of:hub.renameError){value in if let value{error=value;hub.renameError=nil}}
            .onChange(of:pages){value in page=min(page,value-1)}
            .sheet(item:$selected){agent in AgentPanel(agent:agent,hub:hub)}
            .sheet(isPresented:$editingGroups){NavigationStack{Form{
                Section("1 · 勾选要移动的设备"){
                    Button(checked.count == devices.filter{$0.client.connected}.count ? "取消全选":"全选"){
                        let ids=Set(devices.filter{$0.client.connected}.map(\.id));checked=checked == ids ? []:ids
                    }
                    ForEach(devices.filter{$0.client.connected}){agent in
                        Button{if checked.contains(agent.id){checked.remove(agent.id)}else{checked.insert(agent.id)}}label:{
                            HStack{Image(systemName:checked.contains(agent.id) ? "checkmark.circle.fill":"circle");VStack(alignment:.leading){Text(agent.name);Text(hub.group(of:agent.id)).font(.caption).foregroundStyle(.secondary)}}
                        }.foregroundStyle(.primary)
                    }
                }
                Section("2 · 选择目标组"){
                    Picker("移动到",selection:$targetGroup){
                        Text("默认组").tag("默认组")
                        ForEach(hub.groupNames.filter{$0 != "默认组"},id:\.self){Text($0).tag($0)}
                        Text("新建分组…").tag("__new__")
                    }
                    if targetGroup == "__new__"{TextField("输入新组名",text:$groupName)}
                    Text("每台设备属于一个组。移动后，原组不再包含该设备。").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("设备分组").toolbar{
                ToolbarItem(placement:.cancellationAction){Button("取消"){editingGroups=false}}
                ToolbarItem(placement:.confirmationAction){Button("移动 \(checked.count) 台"){
                    let name=targetGroup == "__new__" ? groupName.trimmingCharacters(in:.whitespacesAndNewlines):targetGroup
                    for id in checked where devices.contains(where:{$0.id==id && $0.client.connected}){hub.setGroup(id,name:name)}
                    editingGroups=false
                }.disabled(checked.isEmpty || (targetGroup == "__new__" && groupName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty))}
            }}}

            .alert("连接提醒",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("好",role:.cancel){error=nil}}message:{Text(error ?? "")}
            .alert("修改设备名称",isPresented:$showRename){TextField("名称",text:$deviceName);Button("取消",role:.cancel){};Button("保存"){if let agent=renameDevice{hub.rename(agent,to:deviceName)}}}
            .onChange(of:hub.requestedDevice){id in if let id,let agent=devices.first(where:{$0.id==id}){open(agent);hub.requestedDevice=nil}}
        }
    }
}
struct DeviceOrb:View {
    @ObservedObject var agent:NearbyAgent
    var active:Bool
    var size:CGFloat=67
    var body:some View {
        VStack(spacing:4){
            ZStack(alignment:.bottomTrailing){
                Circle().stroke(agent.approved ? Color.mint.opacity(0.6):Color.primary.opacity(0.12),lineWidth:1).frame(width:size,height:size)
                AoraAnimatedAvatar(phase:agent.phase,active:active && agent.available,shape:agent.avatarShape,hue:agent.avatarHue).frame(width:size,height:size)
                Circle().fill(agent.demo ? Color.purple:agent.available && agent.client.connected ? Color.mint:agent.available ? Color.orange:Color.gray).frame(width:9,height:9).overlay(Circle().stroke(Color.black,lineWidth:2)).offset(x:-5,y:-4)
            }
            Text(agent.name).font(.caption.weight(.medium)).lineLimit(1).frame(width:size+24)
            Text(agent.demo ? "演示 · "+agent.client.snapshot.title:agent.connection).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).frame(width:size+24)
        }.accessibilityElement(children:.combine)
    }
}
struct AgentPanel:View {
    @ObservedObject var agent:NearbyAgent
    @ObservedObject var hub:NearbyHub
    @Environment(\.scenePhase) private var scenePhase
    var body:some View {
        if agent.approved || agent.demo {
            DeviceWorkspace(hub:hub,initialDevice:agent.id,singleDevice:true)
                .onAppear{hub.select(agent)}
        } else {
            NavigationStack {
                VStack(spacing:22){
                    Spacer()
                    AoraAnimatedAvatar(phase:agent.phase,active:scenePhase == .active,shape:agent.avatarShape,hue:agent.avatarHue).frame(width:190,height:190)
                    Text(agent.name).font(.title.bold())
                    Text(agent.connection).foregroundStyle(.secondary)
                    Text("请在安卓端允许连接").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(agent.connection == "等待安卓允许" ? "等待安卓允许…":"申请连接",systemImage:"link") {Task{await hub.invite(agent)}}.buttonStyle(.borderedProminent).tint(.mint).disabled(agent.connection == "等待安卓允许" || !agent.available)
                    Spacer()
                }.padding(30).navigationTitle("连接 agent").navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
struct RippleShape:Shape {
    var progress:Double
    func path(in rect:CGRect)->Path {
        var p=Path();let radius=rect.width*0.68*progress
        for i in 0...180{let angle=Double(i)/180*2*Double.pi;let r=radius+(sin(angle*5+progress*9)+sin(angle*3-progress*7))*4*progress;let pt=CGPoint(x:rect.midX+cos(angle)*r,y:rect.midY+sin(angle)*r);if i==0{p.move(to:pt)}else{p.addLine(to:pt)}}
        p.closeSubpath();return p
    }
}
