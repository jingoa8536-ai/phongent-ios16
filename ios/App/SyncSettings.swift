import SwiftUI
import UniformTypeIdentifiers
import ImageIO

enum SyncPreferences {
    static var push:Bool {UserDefaults.standard.object(forKey:"syncPush") as? Bool ?? true}
    static var heartbeat:Double {min(120,max(15,UserDefaults.standard.object(forKey:"syncHeartbeat") as? Double ?? 30))}
    static var longPolling:Bool {UserDefaults.standard.object(forKey:"syncLongPolling") as? Bool ?? true}
    static var wait:Double {min(60,max(5,UserDefaults.standard.object(forKey:"syncWait") as? Double ?? 20))}
    static var interval:Double {min(60,max(0.5,UserDefaults.standard.object(forKey:"syncInterval") as? Double ?? 2))}
    static var stateInterval:Double {min(60,max(1,UserDefaults.standard.object(forKey:"syncStateInterval") as? Double ?? 2))}
    static var signature:String {"\(push)-\(heartbeat)-\(longPolling)-\(wait)-\(interval)"}
}
struct SyncSettings:View {
    @AppStorage("showAgentWindows") private var showWindows=true
    @AppStorage("syncPush") private var push=true
    @AppStorage("syncHeartbeat") private var heartbeat=30.0
    @AppStorage("syncLongPolling") private var longPolling=true
    @AppStorage("syncWait") private var wait=20.0
    @AppStorage("syncInterval") private var interval=2.0
    @AppStorage("syncStateInterval") private var stateInterval=2.0
    var body:some View {
        Form {
            Section("小窗"){Toggle("显示安卓小窗",isOn:$showWindows)}
            Section("连接方式") {
                Toggle("TCP 主动推送",isOn:$push)
                if push {
                    Stepper("空闲心跳：\(Int(heartbeat)) 秒",value:$heartbeat,in:15...120,step:15)
                    Text("通知与任务状态有变化立即推送。断线自动重连并补同步；旧版安卓暂用轮询。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !push { Section("消息同步") {
                Toggle("独立长轮询",isOn:$longPolling)
                if longPolling {
                    Stepper("最长等待：\(Int(wait)) 秒",value:$wait,in:5...60,step:5)
                    Text("收到通知立即返回；等待时间只决定没有新消息时多久重连。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Stepper("轮询间隔：\(interval,specifier:"%.1f") 秒",value:$interval,in:0.5...60,step:0.5)
                }
            }
            Section("设备状态") {Stepper("刷新间隔：\(Int(stateInterval)) 秒",value:$stateInterval,in:1...60)}
            }
            Section {Text("设置自动保存，应用于所有设备。iPhone 在后台挂起时无法持续进行局域网同步。").font(.caption).foregroundStyle(.secondary)}
        }.navigationTitle("同步设置")
    }
}

struct FleetExecutionSettings:View {
    @ObservedObject var hub:NearbyHub
    var services=false
    var notifications=false
    @State private var selected:Set<String>=[]
    @State private var all=true
    @State private var values:[String:[String:Any]]=[:]
    @State private var results:[String:String]=[:]
    @State private var busy=false
    @State private var failed:Set<String>=[]
    @State private var lastWrite:Data?
    private var devices:[NearbyAgent]{hub.agents.filter{$0.approved && !$0.demo && $0.client.connected}}
    private var targets:[NearbyAgent]{devices.filter{all || selected.contains($0.id)}}
    private var notificationApps:[(package:String,name:String)]{
        var apps:[String:String]=[:]
        for device in targets{for app in values[device.id]?["notificationApps"] as? [[String:Any]] ?? []{if let key=app["package"] as? String{apps[key]=app["name"] as? String ?? key}}}
        return apps.map{(package:$0.key,name:$0.value)}.sorted{$0.name<$1.name}
    }
    private func summary(_ key:String)->String {
        let rows=targets.compactMap{values[$0.id]?[key].map{String(describing:$0)}}
        if rows.count != targets.count || rows.isEmpty{return "未读取"}
        return Set(rows).count==1 ? rows[0]:"配置不同"
    }
    var body:some View {
        Form{
            Section("应用范围"){
                Toggle("全部已连接设备",isOn:$all)
                FleetGroupPicker(hub:hub){ids in all=false;selected=ids}
                if !all{ForEach(devices){agent in Toggle(agent.name,isOn:Binding(get:{selected.contains(agent.id)},set:{if $0{selected.insert(agent.id)}else{selected.remove(agent.id)}}))}}
            }.disabled(busy)
            if !notifications{Section(services ? "电脑连接":"执行设置"){
                ForEach(services ? ["mcpLan","mcpUsb"]:["keepScreenOn","muteTarget"],id:\.self){key in
                    Menu{Button("开启"){apply(key,true)};Button("关闭"){apply(key,false)}}label:{HStack{Text(["keepScreenOn":"保持屏幕常亮","muteTarget":"操作应用静音","mcpLan":"MCP 局域网连接","mcpUsb":"MCP USB 连接"][key] ?? key);Spacer();Text(summary(key)).foregroundStyle(.secondary)}}
                }
                if !services{Menu{ForEach(1...3,id:\.self){n in Button("\(n)"){apply("parallelMax",n)}}}label:{HStack{Text("同时任务数");Spacer();Text(summary("parallelMax"))}}
                ForEach(["operatingPace","capsuleMode"],id:\.self){key in
                    let optionsKey=key=="operatingPace" ? "paceOptions":"capsuleOptions"
                    let options=Set(targets.flatMap{values[$0.id]?[optionsKey] as? [String] ?? []}).sorted()
                    Menu{ForEach(options,id:\.self){option in Button(option){apply(key,option)}}}label:{HStack{Text(key=="operatingPace" ? "操作节奏":"悬浮胶囊");Spacer();Text(summary(key))}}
                }
                }
            }.disabled(busy || targets.isEmpty)
            }
            if !services && !notifications{Section("执行优化"){
                ForEach(["inlineScreen","batchSteps","replay","deepLinks","lightSteps","parallelTasks","structuredCompaction","adaptiveVision"],id:\.self){key in
                    Menu{Button("开启"){apply(key,true)};Button("关闭"){apply(key,false)}}label:{HStack{Text(["inlineScreen":"操作后读屏","batchSteps":"连续操作","replay":"路线重放","deepLinks":"应用直达","lightSteps":"轻量步骤","parallelTasks":"并行任务","structuredCompaction":"结构化摘要","adaptiveVision":"分级读屏"][key] ?? key);Spacer();Text(summary(key)).foregroundStyle(.secondary)}}
                }
            }.disabled(busy || targets.isEmpty)}
            if notifications{Section("通知来源"){
                Text("选择同步通知的应用；历史消息保留。通知读取权限需在安卓本机开启。").font(.caption).foregroundStyle(.secondary)
                ForEach(notificationApps,id:\.package){app in
                    VStack(alignment:.leading,spacing:6){Text(app.name)
                        ForEach(targets){device in
                            let state=(values[device.id]?["notificationApps"] as? [[String:Any]])?.first{($0["package"] as? String)==app.package}?["enabled"] as? Bool
                            Text(device.name+" · "+(state.map{$0 ? "已开启":"已关闭"} ?? "未读取")).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack{Button("开启"){apply("notificationApp",["package":app.package,"enabled":true])};Button("关闭"){apply("notificationApp",["package":app.package,"enabled":false])}}.buttonStyle(.borderless)
                    }
                }
            }.disabled(busy || targets.isEmpty)}
            if !failed.isEmpty{Section{Button("重试上次操作失败设备（\(failed.count)）"){write(lastWrite,to:hub.agents.filter{failed.contains($0.id)},retry:true)}.disabled(busy)}}
            Section{Button("刷新设置"){Task{await reload()}}.disabled(busy)}
            ForEach(targets){agent in Section(agent.name){Text(results[agent.id] ?? "尚未读取").font(.caption)}}
        }.navigationTitle(notifications ? "通知来源":services ? "电脑连接 MCP":"执行设置").task(id:targets.map(\.id).joined()){await reload()}
    }
    private func reload() async {
        for agent in targets{do{let data=try await agent.client.request("/settings");values[agent.id]=try JSONSerialization.jsonObject(with:data) as? [String:Any];results[agent.id]="已读取"}catch{results[agent.id]=error.localizedDescription}}
    }
    private func apply(_ key:String,_ value:Any){write(try? JSONSerialization.data(withJSONObject:[key:value]),to:targets)}
    private func write(_ payload:Data?,to devices:[NearbyAgent],retry:Bool=false){
        guard let payload,!busy else{return};busy=true
        if !retry{failed=[];lastWrite=payload}
        Task{@MainActor in defer{busy=false}
            for agent in devices{do{let data=try await agent.client.request("/settings",body:payload);values[agent.id]=try JSONSerialization.jsonObject(with:data) as? [String:Any];failed.remove(agent.id);results[agent.id]="已应用"}catch{failed.insert(agent.id);results[agent.id]="未应用："+error.localizedDescription}}
        }
    }
}

struct FleetAutomationView:View {
    @ObservedObject var hub:NearbyHub
    var routes=false
    @State private var all=true
    @State private var selected:Set<String>=[]
    @State private var rows:[String:[[String:Any]]]=[:]
    @State private var results:[String:String]=[:]
    @State private var goal=""
    @State private var date=Date().addingTimeInterval(3600)
    @State private var repeatHours=0
    @State private var busy=false
    @State private var failed:Set<String>=[]
    @State private var lastWrite:[String:Any]=[:]
    @State private var showEditor=false
    @State private var editorDevices:[NearbyAgent]=[]
    @State private var editorPlan:[String:Any]=[:]
    @State private var draftID=UUID().uuidString
    private var devices:[NearbyAgent]{hub.agents.filter{$0.approved && !$0.demo && $0.client.connected}}
    private var targets:[NearbyAgent]{devices.filter{all || selected.contains($0.id)}}
    private var path:String{routes ? "/routes":"/plans"}
    var body:some View {
        Form {
            Section("应用范围"){
                Toggle("全部已连接设备",isOn:$all)
                FleetGroupPicker(hub:hub){ids in all=false;selected=ids}
                if !all {ForEach(devices){device in Toggle(device.name,isOn:Binding(get:{selected.contains(device.id)},set:{if $0{selected.insert(device.id)}else{selected.remove(device.id)}}))}}
            }.disabled(busy)
            if !routes {
                Section("新增定时任务"){
                    TextField("任务内容",text:$goal,axis:.vertical)
                    DatePicker("首次执行",selection:$date,in:Date()...)
                    Stepper(repeatHours==0 ? "只执行一次":"每 \(repeatHours) 小时",value:$repeatHours,in:0...168)
                    Button("添加到所选设备"){
                        var plan:[String:Any]=["id":draftID,"goal":goal,"nextAtMs":Int64(date.timeIntervalSince1970*1000)]
                        if repeatHours>0{plan["intervalMs"]=repeatHours*3600000}
                        submit(["action":"save","id":draftID,"plan":plan],to:targets)
                    }.disabled(busy || targets.isEmpty || goal.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Button("详细设置"){editorDevices=targets;editorPlan=["id":draftID,"goal":goal,"nextAtMs":Int64(date.timeIntervalSince1970*1000)];showEditor=true}.disabled(busy || targets.isEmpty)
                    Button("新建另一项任务"){draftID=UUID().uuidString;goal=""}.disabled(busy)
                }
            }
            if !failed.isEmpty{Section{Button("重试上次操作失败设备（\(failed.count)）"){submit(lastWrite,to:hub.agents.filter{failed.contains($0.id)},retry:true)}.disabled(busy)}}
            ForEach(targets){device in
                Section(device.name){
                    Text(results[device.id] ?? "尚未读取").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array((rows[device.id] ?? []).enumerated()),id:\.offset){_,row in
                        let id=row["id"] as? String ?? ""
                        VStack(alignment:.leading,spacing:8){
                            Text(row[routes ? "template":"goal"] as? String ?? id)
                            if !routes,let ms=row["nextAtMs"] as? Double{Text(Date(timeIntervalSince1970:ms/1000),style:.date).font(.caption);Text(Date(timeIntervalSince1970:ms/1000),style:.time).font(.caption)}
                            HStack{
                                if routes{
                                    Button("复制到所选设备"){submit(["action":"save","route":row],to:targets.filter{$0.id != device.id})}
                                }else{
                                    Button((row["enabled"] as? Bool ?? true) ? "停用":"启用"){submit(["action":"enable","id":id,"enabled":!(row["enabled"] as? Bool ?? true)],to:[device])}
                                    Button("编辑"){editorDevices=[device];editorPlan=row;showEditor=true}
                                    Button("立即执行"){submit(["action":"run","id":id],to:[device])}
                                }
                                Button("删除",role:.destructive){submit(["action":"delete","id":id],to:[device])}
                            }.buttonStyle(.borderless).disabled(busy)
                        }
                    }
                }
            }
        }.navigationTitle(routes ? "操作路线":"定时任务")
        .task(id:targets.map(\.id).joined()){await reload()}
        .refreshable{await reload()}
        .sheet(isPresented:$showEditor){FleetPlanEditor(devices:editorDevices,original:editorPlan){showEditor=false;Task{await reload()}}}
    }
    private func consume(_ data:Data,device:NearbyAgent)throws{
        let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
        rows[device.id]=object["items"] as? [[String:Any]] ?? []
        results[device.id]=(object["exactAlarm"] as? Bool)==false ? "已读取；请在安卓允许准时闹钟":"已同步"
    }
    private func reload()async{
        for device in targets{do{try consume(await device.client.request(path),device:device)}catch{results[device.id]=error.localizedDescription}}
    }
    private func submit(_ payload:[String:Any],to devices:[NearbyAgent],retry:Bool=false){
        guard !busy else{return};busy=true
        if !retry{failed=[];lastWrite=payload}
        Task{@MainActor in defer{busy=false}
            for device in devices{do{let body=try JSONSerialization.data(withJSONObject:payload);try consume(await device.client.request(path,body:body),device:device);failed.remove(device.id)}catch{failed.insert(device.id);results[device.id]="失败："+error.localizedDescription}}
        }
    }
}

struct FleetModelSettings:View {
    @ObservedObject var hub:NearbyHub
    @State private var all=true
    @State private var selected:Set<String>=[]
    @State private var role="Main"
    @State private var effort=""
    @State private var providerName=""
    @State private var providerURL=""
    @State private var providerKey=""
    @State private var providerModel=""
    @State private var providerKind="OpenAiCompat"
    @State private var states:[String:[String:Any]]=[:]
    @State private var results:[String:String]=[:]
    @State private var busy=false
    @State private var failed:Set<String>=[]
    @State private var lastWrite:Data?
    private var devices:[NearbyAgent]{hub.agents.filter{$0.approved && $0.client.connected && !$0.demo}}
    private var targets:[NearbyAgent]{devices.filter{all || selected.contains($0.id)}}
    var body:some View {
        Form{
            Section("设备范围"){
                Toggle("全部已连接设备",isOn:$all)
                FleetGroupPicker(hub:hub){ids in all=false;selected=ids}
                if !all{ForEach(devices){device in Toggle(device.name,isOn:Binding(get:{selected.contains(device.id)},set:{if $0{selected.insert(device.id)}else{selected.remove(device.id)}}))}}
            }.disabled(busy)
            Section("添加服务商"){
                Picker("接口类型",selection:$providerKind){Text("OpenAI 兼容").tag("OpenAiCompat");Text("Responses").tag("OpenAiResponses");Text("Anthropic").tag("Anthropic");Text("Gemini").tag("Gemini")}
                TextField("名称",text:$providerName)
                TextField("服务地址",text:$providerURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key，留空保留已有密钥",text:$providerKey)
                TextField("测试模型",text:$providerModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("在所选设备测试并保存，不修改当前执行模型。").font(.caption).foregroundStyle(.secondary)
                Button("测试并保存到所选设备"){apply(["action":"connect_provider","name":providerName,"baseURL":providerURL,"kind":providerKind,"apiKey":providerKey,"model":providerModel])}.disabled(targets.isEmpty || providerName.isEmpty || providerURL.isEmpty || providerModel.isEmpty)
            }.disabled(busy)
            Section("设备执行模型"){
                Picker("用途",selection:$role){Text("主模型").tag("Main");Text("视觉模型").tag("Vision");Text("轻量模型").tag("Light")}
                if role != "Main"{Button("所选设备均跟随主模型"){apply(["action":"inherit"])};if role=="Vision"{Button("所选设备均关闭视觉模型"){apply(["action":"off"])}}}
            }.disabled(busy)
            Section("应用到所选设备"){
                Text("选择下方任一模型，将应用到上方选中的设备；目标设备需已配置相同服务商。").font(.caption).foregroundStyle(.secondary)
                TextField("思考档位（留空使用默认）",text:$effort)
                Button("应用思考档位"){apply(["action":"reasoning","effort":effort.trimmingCharacters(in:.whitespacesAndNewlines)])}.disabled(busy || targets.isEmpty)
            }
            if !failed.isEmpty{Section{Button("重试上次操作失败设备（\(failed.count)）"){write(lastWrite,to:hub.agents.filter{failed.contains($0.id)},retry:true)}.disabled(busy)}}
            ForEach(targets){device in
                Section(device.name){
                    let roles=states[device.id]?["roles"] as? [String:[String:Any]] ?? [:]
                    Text("当前："+(roles[role]?["model"] as? String ?? "未设置"))
                    Text(results[device.id] ?? "未读取").font(.caption).foregroundStyle(.secondary)
                    let providers=states[device.id]?["providers"] as? [[String:Any]] ?? []
                    ForEach(Array(providers.enumerated()),id:\.offset){_,provider in
                        let name=provider["name"] as? String ?? "服务商"
                        Menu(name){ForEach(provider["models"] as? [String] ?? [],id:\.self){model in Button(model){apply(["action":"select","providerName":name,"baseURL":provider["baseURL"] as? String ?? "","model":model])}}}.disabled(busy)
                    }
                }
            }
        }.navigationTitle("设备执行模型").task(id:targets.map(\.id).joined()){await reload()}
    }
    private func reload()async{
        for device in targets{do{let data=try await device.client.request("/models/settings");states[device.id]=try JSONSerialization.jsonObject(with:data) as? [String:Any];results[device.id]="已读取"}catch{results[device.id]=error.localizedDescription}}
    }
    private func apply(_ fields:[String:Any]){var payload=fields;payload["role"]=role;write(try? JSONSerialization.data(withJSONObject:payload),to:targets)}
    private func write(_ payload:Data?,to devices:[NearbyAgent],retry:Bool=false){
        guard let payload,!busy else{return};busy=true
        if !retry{failed=[];lastWrite=payload}
        Task{@MainActor in defer{busy=false};for device in devices{do{let data=try await device.client.request("/models/settings",body:payload);states[device.id]=try JSONSerialization.jsonObject(with:data) as? [String:Any];failed.remove(device.id);results[device.id]="已应用"}catch{failed.insert(device.id);results[device.id]=error.localizedDescription}}}
    }
}

struct FleetQueueView:View {
    @ObservedObject var hub:NearbyHub
    @State private var records:[String:[RemoteQueuedTask]]=[:]
    @State private var errors:[String:String]=[:]
    @State private var busy=false
    @State private var acknowledging:RemoteQueuedTask?
    @State private var selectedDevice:NearbyAgent?
    var body:some View {
        List{ForEach(hub.agents.filter{$0.approved && !$0.demo}){device in
            Section(device.name){
                if let error=errors[device.id]{Text(error).foregroundStyle(.orange)}
                ForEach(records[device.id] ?? []){task in
                    VStack(alignment:.leading,spacing:6){Text(task.text).lineLimit(3);Text(["queued":"排队中","dispatching":"正在启动","running":"执行中","completed":"已完成","failed":"失败","cancelled":"已取消","uncertain":"待核实"][task.state] ?? task.state).font(.caption).foregroundStyle(.secondary)
                        if let result=task.result,!result.isEmpty{Text(result).font(.body)}
                        if !task.error.isEmpty{Text(task.error).font(.caption)}
                        if ["failed","cancelled"].contains(task.state){Button("重新执行"){action(device,task,"retry")}.disabled(busy)}
                        if task.state=="queued"{Button("取消排队",role:.destructive){action(device,task,"cancel")}.disabled(busy)}
                        if task.state=="uncertain"{Button("已核实执行结果"){selectedDevice=device;acknowledging=task}.disabled(busy)}
                    }
                }
            }
        }}.navigationTitle("任务队列").task{await reload()}.refreshable{await reload()}
        .alert("确认已核实安卓执行结果？",isPresented:Binding(get:{acknowledging != nil},set:{if !$0{acknowledging=nil}})){Button("返回",role:.cancel){acknowledging=nil};Button("移出待核实队列"){if let task=acknowledging,let device=selectedDevice{action(device,task,"acknowledge")};acknowledging=nil}}message:{Text("此操作不会重新执行该任务，后续排队任务将继续运行。")}
    }
    private func reload()async{for device in hub.agents.filter({$0.approved && !$0.demo}){do{let data=try await device.client.request("/tasks");struct Response:Decodable{var items:[RemoteQueuedTask]};records[device.id]=try JSONDecoder().decode(Response.self,from:data).items;errors[device.id]=nil}catch{errors[device.id]=error.localizedDescription}}}
    private func action(_ device:NearbyAgent,_ task:RemoteQueuedTask,_ action:String){busy=true;Task{@MainActor in defer{busy=false};do{_ = try await device.client.request("/tasks",body:JSONSerialization.data(withJSONObject:["id":task.id,"action":action]));await reload()}catch{errors[device.id]=error.localizedDescription}}}
}


private struct FleetPlanEditor:View {
    var devices:[NearbyAgent]
    var original:[String:Any]
    var saved:()->Void
    @Environment(\.dismiss) private var dismiss
    @State private var goal:String
    @State private var date:Date
    @State private var mode:String
    @State private var interval:String
    @State private var clock:String
    @State private var zone:String
    @State private var days:Set<Int>
    @State private var condition:String
    @State private var reminder:String
    @State private var idle:Bool
    @State private var enabled:Bool
    @State private var planID=UUID().uuidString
    @State private var failed:Set<String>=[]
    @State private var lastPayload:Data?
    @State private var busy=false
    @State private var results:[String:String]=[:]
    init(devices:[NearbyAgent],original:[String:Any],saved:@escaping()->Void){
        self.devices=devices;self.original=original;self.saved=saved
        _goal=State(initialValue:original["goal"] as? String ?? "")
        _date=State(initialValue:max(Date().addingTimeInterval(60),Date(timeIntervalSince1970:(original["nextAtMs"] as? Double ?? 0)/1000)))
        _mode=State(initialValue:original["calendarTime"] is String ? "calendar":original["intervalMs"] is NSNumber ? "interval":"once")
        _interval=State(initialValue:String((original["intervalMs"] as? Double ?? 3600000)/3600000))
        _clock=State(initialValue:original["calendarTime"] as? String ?? "09:00")
        _zone=State(initialValue:original["calendarZone"] as? String ?? TimeZone.current.identifier)
        _days=State(initialValue:Set(original["calendarDays"] as? [Int] ?? []))
        _condition=State(initialValue:original["conditionGoal"] as? String ?? "")
        _reminder=State(initialValue:original["reminderText"] as? String ?? "")
        _idle=State(initialValue:original["idleOnly"] as? Bool ?? false)
        _enabled=State(initialValue:original["enabled"] as? Bool ?? true)
    }
    var body:some View{NavigationStack{Form{
        Section("任务"){TextField("内容",text:$goal,axis:.vertical);Toggle("启用",isOn:$enabled);Toggle("仅设备空闲时执行",isOn:$idle)}
        Section("时间"){
            Picker("重复",selection:$mode){Text("一次").tag("once");Text("固定间隔").tag("interval");Text("每周钟点").tag("calendar")}
            if mode != "calendar"{DatePicker("首次执行",selection:$date,in:Date()...)}
            if mode=="interval"{TextField("间隔小时",text:$interval).keyboardType(.decimalPad)}
            if mode=="calendar"{TextField("时间 HH:mm",text:$clock);TextField("时区",text:$zone);ForEach(1...7,id:\.self){day in Toggle(["周一","周二","周三","周四","周五","周六","周日"][day-1],isOn:Binding(get:{days.contains(day)},set:{if $0{days.insert(day)}else{days.remove(day)}}))};Text("未选择星期时每天执行。").font(.caption).foregroundStyle(.secondary)}
        }
        Section("条件与提醒"){TextField("执行前检查条件，可留空",text:$condition,axis:.vertical);TextField("固定提醒原文，可留空",text:$reminder,axis:.vertical);Text("填写固定提醒时，到点直接提醒，不调用模型执行任务。").font(.caption).foregroundStyle(.secondary)}
        ForEach(devices){device in if let result=results[device.id]{Section(device.name){Text(result)}}}
        if !failed.isEmpty{Button("重试失败设备（\(failed.count)）"){if let lastPayload{write(lastPayload,to:devices.filter{failed.contains($0.id)})}}}
        Button("保存到所选设备"){submit()}.disabled(busy || goal.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }.disabled(busy).navigationTitle("定时任务").toolbar{ToolbarItem(placement:.cancellationAction){Button("关闭"){dismiss()}.disabled(busy)}}}}
    private func submit(){
        var plan=original;let id=plan["id"] as? String ?? planID
        plan["id"]=id;plan["goal"]=goal;plan["nextAtMs"]=Int64(date.timeIntervalSince1970*1000);plan["enabled"]=enabled;plan["idleOnly"]=idle
        for key in ["intervalMs","calendarTime","calendarZone","calendarDays","conditionGoal","reminderText"]{plan.removeValue(forKey:key)}
        if !condition.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{plan["conditionGoal"]=condition}
        if !reminder.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{plan["reminderText"]=reminder}
        if mode=="interval"{guard let hours=Double(interval),hours>0,hours<=8760 else{results[devices.first?.id ?? ""]="请输入有效的间隔小时";return};plan["intervalMs"]=Int64(hours*3600000)}
        if mode=="calendar"{plan["calendarTime"]=clock;plan["calendarZone"]=zone;plan["calendarDays"]=days.sorted()}
        do{let payload=try JSONSerialization.data(withJSONObject:["action":"save","id":id,"plan":plan]);lastPayload=payload;failed=[];write(payload,to:devices)}catch{results[devices.first?.id ?? ""]=error.localizedDescription}
    }
    private func write(_ payload:Data,to targets:[NearbyAgent]){
        busy=true
        Task{@MainActor in defer{busy=false}
            for device in targets{do{_ = try await device.client.request("/plans",body:payload);failed.remove(device.id);results[device.id]="已保存"}catch{failed.insert(device.id);results[device.id]=error.localizedDescription}}
            if failed.isEmpty{saved()}
        }
    }
}

struct FleetReports:View {
    @ObservedObject var hub:NearbyHub
    var usage=false
    @State private var values:[String:[String:Any]]=[:]
    @State private var errors:[String:String]=[:]
    private var devices:[NearbyAgent]{hub.agents.filter{$0.approved && !$0.demo}}
    var body:some View{List{
        ForEach(devices){device in Section(device.name){
            if let error=errors[device.id]{Text(error).foregroundStyle(.orange)}
            if let value=values[device.id]{
                if usage{
                    let rows=value["items"] as? [[String:Any]] ?? []
                    ForEach(Array(rows.enumerated()),id:\.offset){_,row in VStack(alignment:.leading,spacing:5){Text((row["provider"] as? String ?? "")+" · "+(row["model"] as? String ?? ""));Text("调用 \(number(row,"calls")) 次 · 输入 \(number(row,"input")) · 输出 \(number(row,"output"))").font(.caption);Text("缓存命中 \(number(row,"cached")) · 未返回用量 \(number(row,"unknownCalls")) 次").font(.caption).foregroundStyle(.secondary)}}
                    if rows.isEmpty{Text("暂无模型用量").foregroundStyle(.secondary)}
                }else{
                    LabeledContent("版本",value:value["version"] as? String ?? "")
                    LabeledContent("安卓",value:value["android"] as? String ?? "")
                    ForEach(["accessibility","notifications","notificationListener","busy"],id:\.self){key in LabeledContent(["accessibility":"无障碍服务","notifications":"通知权限","notificationListener":"通知监听","busy":"任务执行中"][key] ?? key,value:(value[key] as? Bool ?? false) ? "是":"否")}
                    LabeledContent("可用存储",value:ByteCountFormatter.string(fromByteCount:(value["freeBytes"] as? NSNumber)?.int64Value ?? 0,countStyle:.file))
                }
            }
        }}
    }.navigationTitle(usage ? "模型用量":"设备诊断").task{await reload()}.refreshable{await reload()}}
    private func number(_ row:[String:Any],_ key:String)->String{(row[key] as? NSNumber)?.stringValue ?? "0"}
    private func reload()async{for device in devices{do{let data=try await device.client.request(usage ? "/usage":"/diagnostics");values[device.id]=try JSONSerialization.jsonObject(with:data) as? [String:Any];errors[device.id]=nil}catch{errors[device.id]=error.localizedDescription}}}
}

struct FleetFilesView:View {
    @ObservedObject var hub:NearbyHub
    @State private var all=true
    @State private var selected:Set<String>=[]
    @State private var importing=false
    @State private var busy=false
    @State private var pending:[String:[String:Any]]=[:]
    @State private var results:[String:String]=[:]
    private var devices:[NearbyAgent]{hub.agents.filter{$0.approved && !$0.demo && $0.client.connected}}
    var body:some View{List{
        Section("上传范围"){Toggle("全部已连接设备",isOn:$all);FleetGroupPicker(hub:hub){all=false;selected=$0};if !all{ForEach(devices){device in Toggle(device.name,isOn:Binding(get:{selected.contains(device.id)},set:{if $0{selected.insert(device.id)}else{selected.remove(device.id)}}))}};Button("上传文件"){importing=true}.disabled(busy || devices.filter{all || selected.contains($0.id)}.isEmpty)}.disabled(busy)
        if !pending.isEmpty{Button("重试失败设备（\(pending.count)）"){upload(to:devices.filter{pending[$0.id] != nil})}.disabled(busy)}
        Section("设备工作区"){ForEach(devices){device in NavigationLink{FleetWorkspaceFiles(agent:device)}label:{VStack(alignment:.leading){Text(device.name);if let result=results[device.id]{Text(result).font(.caption).foregroundStyle(.secondary)}}}}}
    }.navigationTitle("文件").fileImporter(isPresented:$importing,allowedContentTypes:[.data]){result in
        do{let url=try result.get();let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=8*1024*1024 else{throw ModelFailure(message:"文件超过 8 MB")}
            let data=try Data(contentsOf:url);let name=url.lastPathComponent;let id=UUID().uuidString;let targets=devices.filter{all || selected.contains($0.id)}
            pending=Dictionary(uniqueKeysWithValues:targets.map{($0.id,["action":"upload","id":id,"name":name,"data":data.base64EncodedString(),"conversationId":$0.client.snapshot.currentConversationId ?? ""] as [String:Any])})
            upload(to:targets)
        }catch{results[devices.first?.id ?? ""]=error.localizedDescription}
    }}
    private func upload(to targets:[NearbyAgent]){
        busy=true
        Task{@MainActor in defer{busy=false};for device in targets{do{
            guard var body=pending[device.id] else{continue}
            if (body["conversationId"] as? String ?? "").isEmpty{body["conversationId"]=device.client.snapshot.currentConversationId ?? "";pending[device.id]=body}
            guard !(body["conversationId"] as? String ?? "").isEmpty else{throw ModelFailure(message:"请先打开一个聊天")}
            let response=try await device.client.request("/workspace",body:JSONSerialization.data(withJSONObject:body))
            let object=try JSONSerialization.jsonObject(with:response) as? [String:Any]
            results[device.id]="已保存："+(object?["path"] as? String ?? "文件");pending.removeValue(forKey:device.id)
        }catch{results[device.id]=error.localizedDescription}}}
    }

}
private struct WorkspaceEntry:Decodable,Identifiable{var name:String;var path:String;var directory:Bool;var size:Int64;var id:String{path}}
private struct FleetWorkspaceFiles:View {
    @ObservedObject var agent:NearbyAgent
    @State private var conversation=""
    @State private var path=""
    @State private var entries:[WorkspaceEntry]=[]
    @State private var error:String?
    @State private var downloaded:URL?
    @State private var deleting:WorkspaceEntry?
    @State private var busy=false
    var body:some View{List{
        if let error{Section{Text(error).foregroundStyle(.orange)}}
        Section{if !path.isEmpty{Button("上一级"){path=path.split(separator:"/").dropLast().joined(separator:"/");Task{await load()}}};Text(path.isEmpty ? "工作区":path).font(.caption).foregroundStyle(.secondary)}
        ForEach(entries){entry in HStack{Button{if entry.directory{path=entry.path;Task{await load()}}else{download(entry)}}label:{Label(entry.name,systemImage:entry.directory ? "folder":"doc")};Spacer();if !entry.directory{Button(role:.destructive){deleting=entry}label:{Image(systemName:"trash")}}}.buttonStyle(.borderless).disabled(busy)}
        if let downloaded{Section("已下载"){ShareLink(item:downloaded){Label("保存或分享文件",systemImage:"square.and.arrow.up")};if let image=workspaceThumbnail(downloaded){Image(uiImage:image).resizable().scaledToFit()}}}
    }.navigationTitle(agent.name).task{conversation=agent.client.snapshot.currentConversationId ?? "";await load()}.refreshable{await load()}
        .alert("删除文件？",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}})){Button("取消",role:.cancel){deleting=nil};Button("删除",role:.destructive){if let file=deleting{Task{@MainActor in do{_ = try await call(["action":"delete","path":file.path]);await load()}catch{self.error=error.localizedDescription}}};deleting=nil}}message:{Text(deleting?.name ?? "")}
    }
    private func call(_ fields:[String:Any])async throws->Data{guard !conversation.isEmpty else{throw ModelFailure(message:"请先在设备打开一个聊天")};var body=fields;body["conversationId"]=conversation;return try await agent.client.request("/workspace",body:JSONSerialization.data(withJSONObject:body))}
    private func load()async{let requested=path;do{let data=try await call(["action":"list","path":requested]);struct Response:Decodable{var items:[WorkspaceEntry]};guard path==requested else{return};entries=try JSONDecoder().decode(Response.self,from:data).items;error=nil}catch{self.error=error.localizedDescription}}
    private func download(_ entry:WorkspaceEntry){busy=true;Task{@MainActor in defer{busy=false};do{let response=try await call(["action":"read","path":entry.path]);guard let object=try JSONSerialization.jsonObject(with:response) as? [String:Any],let encoded=object["data"] as? String,let data=Data(base64Encoded:encoded) else{throw ModelFailure(message:"文件响应无效")};let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);let url=directory.appendingPathComponent(entry.name);try data.write(to:url);downloaded=url}catch{self.error=error.localizedDescription}}}
}

private func workspaceThumbnail(_ url:URL)->UIImage?{
    guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1200,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return nil}
    return UIImage(cgImage:image)
}

struct FleetBrowserSettings:View {
    @ObservedObject var hub:NearbyHub
    @State private var all=true
    @State private var selected:Set<String>=[]
    @State private var host=""
    @State private var states:[String:[[String:Any]]]=[:]
    @State private var results:[String:String]=[:]
    @State private var busy=false
    @State private var confirming=false
    @State private var pending:[String:Any]=[:]
    @State private var failed:Set<String>=[]
    @State private var lastWrite:Data?
    private var devices:[NearbyAgent]{hub.agents.filter{$0.approved && $0.client.connected && !$0.demo}}
    private var targets:[NearbyAgent]{devices.filter{all || selected.contains($0.id)}}
    var body:some View {
        Form{
            Section("设备范围"){
                Toggle("全部已连接设备",isOn:$all)
                FleetGroupPicker(hub:hub){ids in all=false;selected=ids}
                if !all{ForEach(devices){device in Toggle(device.name,isOn:Binding(get:{selected.contains(device.id)},set:{if $0{selected.insert(device.id)}else{selected.remove(device.id)}}))}}
            }.disabled(busy)
            Section("网站登录"){
                TextField("网站域名，例如 example.com",text:$host).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("在所选设备打开登录"){apply(["action":"open","host":host.trimmingCharacters(in:.whitespacesAndNewlines)])}.disabled(targets.isEmpty || host.isEmpty)
                Button("全部退出并清除网页数据",role:.destructive){pending=["action":"clear"];confirming=true}.disabled(targets.isEmpty)
            }.disabled(busy)
            if !failed.isEmpty{Button("重试失败设备（\(failed.count)）"){write(lastWrite,to:hub.agents.filter{failed.contains($0.id)},retry:true)}.disabled(busy)}
            ForEach(targets){device in
                Section(device.name){
                    Text(results[device.id] ?? "读取中").font(.caption).foregroundStyle(.secondary)
                    let sites=states[device.id] ?? []
                    if sites.isEmpty{Text("暂无网站记录").foregroundStyle(.secondary)}
                    ForEach(Array(sites.enumerated()),id:\.offset){_,site in
                        let name=site["host"] as? String ?? ""
                        VStack(alignment:.leading){
                            Text(name)
                            Text(site["loggedIn"] as? Bool == true ? "已登录":"已访问").font(.caption).foregroundStyle(.secondary)
                            HStack{
                                Button("打开登录"){apply(["action":"open","host":name])}
                                Button("退出此网站",role:.destructive){pending=["action":"logout","host":name];confirming=true}
                            }.buttonStyle(.borderless).disabled(busy)
                        }
                    }
                }
            }
        }.navigationTitle("浏览器与网站登录")
        .task(id:targets.map(\.id).joined()){await reload()}
        .confirmationDialog("清除所选设备的网站登录？",isPresented:$confirming,titleVisibility:.visible){Button("清除",role:.destructive){apply(pending)};Button("取消",role:.cancel){}}message:{Text("此操作会退出网站并清除网页数据。")}
    }
    private func reload()async{
        for device in targets{do{let data=try await device.client.request("/browser");let response=try JSONSerialization.jsonObject(with:data) as? [String:Any];states[device.id]=response?["sites"] as? [[String:Any]] ?? [];results[device.id]="已读取"}catch{results[device.id]=error.localizedDescription}}
    }
    private func apply(_ body:[String:Any]){write(try? JSONSerialization.data(withJSONObject:body),to:targets)}
    private func write(_ body:Data?,to targets:[NearbyAgent],retry:Bool=false){
        guard let body,!busy else{return};busy=true
        if !retry{failed=[];lastWrite=body}
        Task{@MainActor in defer{busy=false};for device in targets{do{
            let data=try await device.client.request("/browser",body:body);let response=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            states[device.id]=response?["sites"] as? [[String:Any]] ?? [];results[device.id]=response?["status"] as? String ?? "已同步";failed.remove(device.id)
        }catch{failed.insert(device.id);results[device.id]=error.localizedDescription}}}
    }
}
