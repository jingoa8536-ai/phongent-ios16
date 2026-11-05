import SwiftUI
import AVFoundation

final class VideoCanvas:UIView {
    override class var layerClass:AnyClass {AVSampleBufferDisplayLayer.self}
    var display:AVSampleBufferDisplayLayer {layer as! AVSampleBufferDisplayLayer}
}
struct VideoSurface:UIViewRepresentable {
    let canvas:VideoCanvas
    func makeUIView(context:Context)->VideoCanvas {canvas}
    func updateUIView(_ view:VideoCanvas,context:Context){}
}
@MainActor final class RemoteVideo:ObservableObject {
    @Published var status="准备连接"
    @Published var aspect:CGFloat=9/20
    @Published var live=false
    @Published var controlling=false
    @Published var sending=false
    @Published var canControlVirtual=false
    @Published var virtualControlled=false
    @Published var virtualControlledByOther=false
    @Published var controlError:String?
    private var virtualIdentity:[String:Any]=[:]
    let canvas=VideoCanvas()
    var lastFrame=Date.distantPast
    private var waitingKeyframe=true
    private var format:CMVideoFormatDescription?
    private var sps=Data(),pps=Data()
    private var session:URLSession?
    private var stream:URLSessionDataTask?
    private var receiver:VideoReceiver?
    private var run:Task<Void,Never>?
    func start(_ bridge:BridgeClient,virtual:Bool=false) {
        stop();run=Task { [weak self] in
            guard let self else{return}
            if !virtual {do {_ = try await bridge.request("/video/start",body:Data("{}".utf8))}catch{status=error.localizedDescription;return}}
            while !Task.isCancelled {
                do {
                    struct State:Decodable {var active:Bool;var width:Int;var height:Int;var error:String;var canControl:Bool?;var controlled:Bool?;var controlledByOther:Bool?;var runId:String?;var conversationId:String?;var displayId:Int?}
                    let state=try JSONDecoder().decode(State.self,from:await bridge.request(virtual ? "/virtual/status":"/video/status"))
                    guard !Task.isCancelled else{return}
                    if virtual {
                        canControlVirtual=state.canControl ?? false
                        virtualControlled=state.controlled ?? false
                        virtualControlledByOther=state.controlledByOther ?? false
                        virtualIdentity=["runId":state.runId ?? "","conversationId":state.conversationId ?? "","displayId":state.displayId ?? -1]
                    }
                    if state.active && state.width>0 && state.height>0 {
                        aspect=CGFloat(state.width)/CGFloat(state.height)
                        if stream==nil {connect(bridge,virtual:virtual)}
                        if Date().timeIntervalSince(lastFrame)>5 && live {disconnect();status="视频中断，正在重连"}
                    } else {disconnect();status=state.error.isEmpty ? "请点击安卓屏幕共享通知并允许共享":"\(state.error)；关闭小屏后重试"}
                } catch {disconnect();status="连接中断，正在重连"}
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }
    func stop(){run?.cancel();run=nil;disconnect()}
    private func disconnect(){stream?.cancel();stream=nil;session?.invalidateAndCancel();session=nil;receiver=nil;live=false;controlling=false;canControlVirtual=false;virtualControlled=false;virtualControlledByOther=false;virtualIdentity=[:];format=nil;waitingKeyframe=true;sps=Data();pps=Data();canvas.display.flushAndRemoveImage()}
    private func connect(_ bridge:BridgeClient,virtual:Bool=false){
        guard let pairing=bridge.pairing,let url=URL(string:pairing.url+(virtual ? "/virtual/video":"/video")) else{return}
        status="连接视频流";lastFrame=Date()
        let receiver=VideoReceiver();self.receiver=receiver
        receiver.packet={ [weak self,weak receiver] packet in Task{@MainActor in guard let receiver,self?.receiver === receiver else{return};self?.decode(packet)}}
        receiver.ended={ [weak self,weak receiver] in Task{@MainActor in guard let receiver,self?.receiver === receiver else{return};self?.disconnect();self?.status="视频中断，正在重连"}}
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=10;config.timeoutIntervalForResource=86400
        let session=URLSession(configuration:config,delegate:receiver,delegateQueue:nil);self.session=session
        var req=URLRequest(url:url);req.setValue("Bearer "+pairing.token,forHTTPHeaderField:"Authorization")
        stream=session.dataTask(with:req);stream?.resume()
    }
    private func decode(_ data:Data){
        guard stream != nil else{return}
        let bytes=[UInt8](data);var starts:[(Int,Int)]=[];var i=0
        while i+3<=bytes.count {
            if bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==1 {starts.append((i,i+3));i+=3}
            else if i+4<=bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==0 && bytes[i+3]==1 {starts.append((i,i+4));i+=4}
            else{i+=1}
        }
        var payload=Data();var changed=false;var keyframe=false
        for n in starts.indices {
            let start=starts[n].1,end=n+1<starts.count ? starts[n+1].0:bytes.count
            guard end>start else{continue};let nal=Data(bytes[start..<end]);let type=bytes[start]&31
            if type==5 {keyframe=true}
            if type==7 {if sps != nal {sps=nal;changed=true}}
            else if type==8 {if pps != nal {pps=nal;changed=true}}
            else {var length=UInt32(nal.count).bigEndian;withUnsafeBytes(of:&length){payload.append(contentsOf:$0)};payload.append(nal)}
        }
        if changed && !sps.isEmpty && !pps.isEmpty {
            sps.withUnsafeBytes {s in pps.withUnsafeBytes {p in
                let pointers=[s.bindMemory(to:UInt8.self).baseAddress!,p.bindMemory(to:UInt8.self).baseAddress!]
                let sizes=[sps.count,pps.count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:kCFAllocatorDefault,parameterSetCount:2,parameterSetPointers:pointers,parameterSetSizes:sizes,nalUnitHeaderLength:4,formatDescriptionOut:&format)
            }}
        }
        guard !payload.isEmpty,let format else{return}
        if canvas.display.status == .failed {canvas.display.flush();waitingKeyframe=true}
        if waitingKeyframe && !keyframe {return}
        waitingKeyframe=false
        var block:CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:payload.count,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:payload.count,flags:0,blockBufferOut:&block)==noErr,let block else{return}
        let copied=payload.withUnsafeBytes {CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:payload.count)}
        guard copied==noErr else{return}
        var sample:CMSampleBuffer?;var size=payload.count
        guard CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,sampleCount:1,sampleTimingEntryCount:0,sampleTimingArray:nil,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)==noErr,let sample else{return}
        if let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true) {
            let dict=unsafeBitCast(CFArrayGetValueAtIndex(attachments,0),to:CFMutableDictionary.self)
            CFDictionarySetValue(dict,Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if canvas.display.status == .failed {canvas.display.flush()}
        canvas.display.videoGravity = .resizeAspect;canvas.display.enqueue(sample)
        lastFrame=Date();live=true;status="实时画面"
    }
    func virtualInput(_ bridge:BridgeClient,action:String,values:[String:Any]=[:]) async {
        guard !sending else{return}
        guard !virtualIdentity.isEmpty else{controlError="画面已变化，请重试";return}
        if action != "release" {
            guard live,canControlVirtual,Date().timeIntervalSince(lastFrame)<3 else{controlError="等待实时画面";return}
            if action != "acquire" && action != "takeover", !virtualControlled {controlError="等待 agent 暂停";return}
        }
        sending=true;defer{sending=false}
        var body=virtualIdentity
        body["action"]=action
        for (key,value) in values{body[key]=value}
        do{
            _ = try await bridge.request("/virtual/input",body:JSONSerialization.data(withJSONObject:body))
            controlError=nil
            if action=="release"{virtualControlled=false}
        }catch{controlError=error.localizedDescription}
    }
    func input(_ bridge:BridgeClient,_ body:[String:Any]) async {
        guard live,controlling,!sending,Date().timeIntervalSince(lastFrame)<3 else{status="等待实时画面后再操作";return}
        guard !bridge.snapshot.busy else{controlling=false;status="agent 正在执行任务，当前仅查看";return}
        sending=true;defer{sending=false}
        do {_ = try await bridge.request("/screen/input",body:JSONSerialization.data(withJSONObject:body));status="实时画面"}
        catch {status=error.localizedDescription}
    }
}
final class VideoReceiver:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    var packet:((Data)->Void)?
    var ended:(()->Void)?
    private var buffer=Data()
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){completionHandler((response as? HTTPURLResponse)?.statusCode==200 ? .allow:.cancel)}
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){
        buffer.append(data)
        while buffer.count>=4 {
            let size=buffer.prefix(4).reduce(0){($0<<8)|Int($1)}
            guard size>0 && size<=4_000_000 else{dataTask.cancel();return}
            guard buffer.count>=size+4 else{return}
            packet?(Data(buffer.dropFirst(4).prefix(size)));buffer.removeFirst(size+4)
        }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){ended?()}
}
struct RemoteVideoPanel:View {
    @ObservedObject var bridge:BridgeClient
    @StateObject private var video=RemoteVideo()
    @Environment(\.scenePhase) private var scenePhase
    @State private var expanded=false
    @State private var position=CGSize.zero
    @GestureState private var drag=CGSize.zero
    @State private var text=""
    @State private var showText=false
    var close:()->Void
    var body:some View {
        GeometryReader { geometry in
            let width=expanded ? geometry.size.width-24:min(200,geometry.size.width-30)
            let height=min(width/video.aspect,geometry.size.height-(expanded ? 140:190))
            let actualWidth=height*video.aspect
            VStack(spacing:6) {
                HStack {
                    Image(systemName:"line.3.horizontal").foregroundStyle(.secondary)
                    Text("安卓小屏").font(.caption)
                    Spacer()
                    Button {expanded.toggle();position = .zero} label:{Image(systemName:expanded ? "arrow.down.right.and.arrow.up.left":"arrow.up.left.and.arrow.down.right")}
                    Button {video.stop();close()} label:{Image(systemName:"xmark")}
                }.padding(8).contentShape(Rectangle())
                    .gesture(DragGesture().updating($drag){value,state,_ in if !expanded {state=value.translation}}.onEnded{value in if !expanded {position=CGSize(width:max(0,min(geometry.size.width-width-12,position.width+value.translation.width)),height:max(0,min(geometry.size.height-height-135,position.height+value.translation.height)))}})
                VideoSurface(canvas:video.canvas).frame(width:actualWidth,height:height).background(.black).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:0).onEnded {value in
                        func normalized(_ point:CGPoint)->(Double,Double){(Double(max(0,min(1,point.x/actualWidth))),Double(max(0,min(1,point.y/height))))}
                        let a=normalized(value.startLocation),b=normalized(value.location)
                        Task{await video.input(bridge,["action":"gesture","x":a.0,"y":a.1,"endX":b.0,"endY":b.1,"duration":abs(value.translation.width)+abs(value.translation.height)<6 ? 80:350])}
                    })
                Text(video.status).font(.caption2).lineLimit(3).frame(maxWidth:.infinity)
                HStack(spacing:12) {
                    Button(video.controlling ? "仅查看":"控制"){video.controlling.toggle()}.disabled(!video.live || bridge.snapshot.busy)
                    Button {Task{await video.input(bridge,["action":"back"])}} label:{Image(systemName:"chevron.left")}
                    Button {Task{await video.input(bridge,["action":"home"])}} label:{Image(systemName:"house")}
                    Button {showText=true} label:{Image(systemName:"keyboard")}
                }.font(.caption).padding(.bottom,8)
            }.frame(width:width).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16)).clipShape(RoundedRectangle(cornerRadius:16)).shadow(radius:8)
                .offset(x:expanded ? 12:max(0,min(geometry.size.width-width-12,position.width+drag.width)),y:expanded ? 10:max(0,min(geometry.size.height-height-135,position.height+drag.height)))
        }.padding(.top,expanded ? 0:125).padding(.bottom,expanded ? 0:85)
        .task{video.start(bridge)}.onDisappear{video.stop()}
        .onChange(of:scenePhase){phase in if phase == .active{video.start(bridge)}else{video.stop()}}
        .alert("输入到安卓当前输入框",isPresented:$showText){TextField("文本",text:$text);Button("取消",role:.cancel){};Button("填入"){let value=text;Task{await video.input(bridge,["action":"text","text":value])}}}message:{Text("先点击安卓输入框。填入会替换该输入框内容，不会自动发送。")}
    }
}

struct NativeVirtualPip:View {
    @ObservedObject var bridge:BridgeClient
    @StateObject private var video=RemoteVideo()
    @Environment(\.scenePhase) private var scenePhase
    @State private var expanded=false
    @State private var cornerRight=true
    @State private var cornerBottom=true
    @GestureState private var drag=CGSize.zero
    var body:some View {
        GeometryReader {geo in
            if video.live {
                let width=min(expanded ? 220.0:96.0,geo.size.width-24)
                let controls:CGFloat=expanded && video.canControlVirtual ? 45:0
                let height=min(width/video.aspect,max(1,geo.size.height-24-controls))
                let w=height*video.aspect
                VirtualControlSurface(video:video,bridge:bridge,width:w,height:height,expanded:$expanded)
                    .offset(x:max(12,min(geo.size.width-w-12,(cornerRight ? geo.size.width-w-12:12)+drag.width)),y:max(12,min(geo.size.height-height-controls-12,(cornerBottom ? geo.size.height-height-controls-12:12)+drag.height)))
                    .gesture(DragGesture(minimumDistance:8).updating($drag){v,s,_ in if !video.virtualControlled{s=v.translation}}.onEnded{v in
                        guard !video.virtualControlled else{return}
                        cornerRight=(cornerRight ? geo.size.width-w/2-12:w/2+12)+v.translation.width>geo.size.width/2
                        cornerBottom=(cornerBottom ? geo.size.height-height/2-12:height/2+12)+v.translation.height>geo.size.height/2
                    },including:video.virtualControlled ? .subviews:.all)
            }
        }.padding(.top,125).padding(.bottom,85)
        .task {video.start(bridge,virtual:true)}.onDisappear{video.stop()}
        .onChange(of:scenePhase){phase in if phase == .active{video.start(bridge,virtual:true)}else{video.stop()}}
    }
}

struct VirtualControlSurface:View {
    @ObservedObject var video:RemoteVideo
    @ObservedObject var bridge:BridgeClient
    let width:CGFloat
    let height:CGFloat
    @Binding var expanded:Bool
    @State private var editing=false
    @State private var confirmTakeover=false
    @State private var text=""
    var body:some View {
        VStack(spacing:3){
            ZStack{
                VideoSurface(canvas:video.canvas).frame(width:width,height:height)
                if video.virtualControlled {
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onEnded{value in
                        let x={ (point:CGPoint) in min(1,max(0,point.x/width)) }
                        let y={ (point:CGPoint) in min(1,max(0,point.y/height)) }
                        let duration=abs(value.translation.width)+abs(value.translation.height)<6 ? 80:350
                        Task{await video.virtualInput(bridge,action:"gesture",values:["x":x(value.startLocation),"y":y(value.startLocation),"endX":x(value.location),"endY":y(value.location),"duration":duration])}
                    })
                }else{Color.clear.contentShape(Rectangle()).onTapGesture{expanded.toggle()}}
            }.frame(width:width,height:height).background(.black).clipShape(RoundedRectangle(cornerRadius:12))
            if expanded && video.canControlVirtual {
                HStack{
                    Button{if video.virtualControlledByOther{confirmTakeover=true}else{Task{await video.virtualInput(bridge,action:video.virtualControlled ? "release":"acquire")}}}label:{Image(systemName:video.virtualControlled ? "play.fill":"hand.tap")}.accessibilityLabel(video.virtualControlled ? "交回 agent":"接管虚拟屏")
                    Button{editing=true}label:{Image(systemName:"keyboard")}.disabled(!video.virtualControlled).accessibilityLabel("输入文本")
                }.buttonStyle(.bordered).disabled(video.sending)
            }
        }.frame(width:width)
        .confirmationDialog("其他主控正在操作，接管此设备？",isPresented:$confirmTakeover,titleVisibility:.visible){Button("接管"){Task{await video.virtualInput(bridge,action:"takeover")}};Button("取消",role:.cancel){}}
        .alert("输入文本",isPresented:$editing){TextField("文本",text:$text);Button("取消",role:.cancel){};Button("填入"){Task{await video.virtualInput(bridge,action:"text",values:["text":String(text.prefix(4000))])}}}
        .alert("操作未完成",isPresented:Binding(get:{video.controlError != nil},set:{if !$0{video.controlError=nil}})){Button("好"){video.controlError=nil}}message:{Text(video.controlError ?? "")}
    }
}
