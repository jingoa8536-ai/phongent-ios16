import SwiftUI

struct NativeExchangeView:View {
    let exchange:NativeChatExchange
    var client:BridgeClient?=nil
    var answer:((String)->Void)?=nil
    @State private var resumeError:String?
    @State private var expanded=false
    private var e:NativeChatExchange {exchange}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if !e.goal.isEmpty {user(e.goal)}
            if e.active,let client {
                HStack {Spacer();Button {Task {
                    if !(await client.stopAllTasks()){resumeError=client.commandStatus}
                }} label:{Image(systemName:"stop.circle").foregroundStyle(.red)}.accessibilityLabel("结束该 agent 的任务")}
                if let resumeError {Text(resumeError).font(.caption).foregroundStyle(.orange)}
            }
            if e.active && e.draft.isEmpty {
                HStack(spacing:10){if e.phase=="working"{ProgressView().controlSize(.small)}else{Image(systemName:"pause.circle").foregroundStyle(.orange)};Text(e.progress).font(.subheadline);Spacer();if e.startedAt>0{Text(Date(timeIntervalSince1970:e.startedAt),style:.timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)}}
                steps(live:true)
            } else if !e.active && (!e.steps.isEmpty || e.elapsed != nil) {
                Button {expanded.toggle()} label:{HStack(spacing:6){if e.phase=="done" {Image(systemName:"checkmark")};Text(e.steps.isEmpty ? "执行过程":"\(e.steps.count) 步");if let elapsed=e.elapsed {Text("· \(Int(elapsed)/60):\(String(format:"%02d",Int(elapsed)%60))")};Image(systemName:expanded ? "chevron.up":"chevron.down")}.font(.caption).foregroundStyle(.secondary)}.buttonStyle(.plain)
                if expanded {steps(live:false)}
            }
            ForEach(e.steers.indices,id:\.self){i in user(e.steers[i].text)}
            if e.phase=="done" || (!e.body.isEmpty && e.phase=="cancelled") {
                if e.phase=="cancelled" {Text(e.title).foregroundStyle(.secondary)}
                VStack(alignment:.leading,spacing:10){
                    if !e.verification.isEmpty{Label(e.verification,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange)}
                    AndroidMarkdown(text:e.body)
                    if !e.evidence.isEmpty {DisclosureGroup("来源"){AndroidMarkdown(text:e.evidence).font(.caption)}}
                }.padding(.horizontal,14).padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.065),in:UnevenRoundedRectangle(topLeadingRadius:20,bottomLeadingRadius:6,bottomTrailingRadius:20,topTrailingRadius:20))
            } else if e.phase=="failed" {
                Label(e.title,systemImage:"circle.fill").font(.subheadline.bold()).foregroundStyle(.red)
                AndroidMarkdown(text:e.body).foregroundStyle(.secondary)
            } else if e.phase=="cancelled" {Text(e.title).foregroundStyle(.secondary)}
            else if e.phase != "working" {
                VStack(alignment:.leading,spacing:10){Text(e.title).font(.headline);AndroidMarkdown(text:e.body)
                    if e.phase=="unlock"{Text("等待安卓亮屏并解锁，解锁后自动继续").font(.caption)}
                    if e.phase=="paused",let client {
                        Button("继续任务"){Task{
                            guard client.snapshot.exchanges?.last?.id==e.id, client.snapshot.conversationId==e.conversationId else{resumeError="当前已切换任务";return}
                            if !(await client.command("resume")){resumeError=client.commandStatus ?? "继续任务失败"}
                        }}
                        if let resumeError{Text(resumeError).font(.caption).foregroundStyle(.orange)}
                    }
                    if e.phase=="input",let answer {ForEach(e.options,id:\.self){option in Button(option){answer(option)}}}
                }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
            }
            if !e.draft.isEmpty {AndroidMarkdown(text:e.draft).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.065),in:RoundedRectangle(cornerRadius:20))}
            ForEach(e.files.indices,id:\.self){i in RemoteFileCard(file:e.files[i],exchange:e,index:i,client:client)}
            ForEach(e.notes.indices,id:\.self){i in Text(e.notes[i]).font(.caption).foregroundStyle(.secondary)}
        }.textSelection(.enabled).padding(.vertical,6)
    }
    private func user(_ text:String)->some View {HStack{Spacer(minLength:40);Text(text).foregroundStyle(.white).padding(.horizontal,14).padding(.vertical,10).background(Color.blue,in:UnevenRoundedRectangle(topLeadingRadius:20,bottomLeadingRadius:20,bottomTrailingRadius:6,topTrailingRadius:20))}}
    @ViewBuilder private func steps(live:Bool)->some View {
        let rows=live && !expanded ? Array(e.steps.suffix(5)):e.steps
        if live && e.steps.count>5 {Button(expanded ? "收起":"前面还有 \(e.steps.count-5) 步"){expanded.toggle()}.font(.caption)}
        VStack(alignment:.leading,spacing:0){ForEach(rows.indices,id:\.self){i in
            HStack(alignment:.top,spacing:10){VStack(spacing:0){Circle().fill(rows[i].state=="Run" ? Color.blue:rows[i].state=="Wait" ? .orange:.secondary).frame(width:6,height:6);Rectangle().fill(.secondary.opacity(0.2)).frame(width:1).frame(minHeight:20)}.frame(width:8)
                VStack(alignment:.leading,spacing:3){Text(rows[i].reason.isEmpty ? rows[i].title:rows[i].reason).font(.subheadline);if !rows[i].subtitle.isEmpty{Text(rows[i].subtitle).font(.caption).foregroundStyle(.secondary)}}.padding(.bottom,12)
            }
        }}
    }
}

struct AndroidMarkdown:View {
    let text:String
    private struct Block {var kind:String;var text:String;var level:Int=0}
    private var blocks:[Block] {
        let lines=text.components(separatedBy:"\n");var result:[Block]=[];var paragraph:[String]=[];var code:[String]=[];var fenced=false
        func flush(){if !paragraph.isEmpty{result.append(Block(kind:"text",text:paragraph.joined(separator:"\n")));paragraph=[]}}
        for line in lines {
            if line.hasPrefix("```"){flush();if fenced{result.append(Block(kind:"code",text:code.joined(separator:"\n")));code=[]};fenced.toggle();continue}
            if fenced{code.append(line);continue}
            if line.trimmingCharacters(in:.whitespaces).isEmpty{flush();continue}
            let hashes=line.prefix(while:{$0=="#"}).count
            if hashes>0 && hashes<=6 && line.dropFirst(hashes).first==" "{flush();result.append(Block(kind:"heading",text:String(line.dropFirst(hashes+1)),level:hashes))}
            else if line.hasPrefix("> "){flush();result.append(Block(kind:"quote",text:String(line.dropFirst(2))))}
            else if line=="---" || line=="***" {flush();result.append(Block(kind:"rule",text:""))}
            else if line.hasPrefix("- ") || line.hasPrefix("* "){flush();result.append(Block(kind:"list",text:String(line.dropFirst(2))))}
            else if line.contains("|"){flush();if result.last?.kind=="table"{result[result.count-1].text+="\n"+line}else{result.append(Block(kind:"table",text:line))}}
            else{paragraph.append(line)}
        };flush();if fenced && !code.isEmpty{result.append(Block(kind:"code",text:code.joined(separator:"\n")))};return result
    }
    private func inline(_ s:String)->Text {Text((try? AttributedString(markdown:s,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(s))}
    var body:some View {VStack(alignment:.leading,spacing:10){ForEach(Array(blocks.enumerated()),id:\.offset){_,b in
        switch b.kind {
        case "heading":inline(b.text).font(b.level==1 ? .title2:b.level==2 ? .title3:.headline).bold()
        case "code":ScrollView(.horizontal){Text(b.text).font(.system(.subheadline,design:.monospaced)).padding(10)}.background(Color.primary.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
        case "quote":HStack{Rectangle().fill(.secondary.opacity(0.4)).frame(width:3);inline(b.text).foregroundStyle(.secondary)}.fixedSize(horizontal:false,vertical:true)
        case "list":HStack(alignment:.top){Text("•");inline(b.text)}
        case "rule":Divider()
        case "table":ScrollView(.horizontal){VStack(alignment:.leading,spacing:8){ForEach(Array(b.text.components(separatedBy:"\n").filter{!$0.replacingOccurrences(of:"|",with:"").replacingOccurrences(of:"-",with:"").replacingOccurrences(of:":",with:"").trimmingCharacters(in:.whitespaces).isEmpty}.enumerated()),id:\.offset){_,row in HStack(alignment:.top){ForEach(Array(row.trimmingCharacters(in:CharacterSet(charactersIn:"|")).components(separatedBy:"|").enumerated()),id:\.offset){_,cell in inline(cell.trimmingCharacters(in:.whitespaces)).frame(width:140,alignment:.leading)}};Divider()}}}
        default:inline(b.text).fixedSize(horizontal:false,vertical:true)
        }
    }}} 
}

private struct RemoteFileCard:View {
    let file:NativeChatFile
    let exchange:NativeChatExchange
    let index:Int
    var client:BridgeClient?
    @State private var image:UIImage?
    @State private var url:URL?
    @State private var error:String?
    @State private var loading=false
    @State private var expanded=false
    var body:some View {
        VStack(alignment:.leading,spacing:8){
            if let image{Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:260).onTapGesture{expanded=true}}
            HStack{Image(systemName:"doc");Text(file.name);Spacer();if let url{ShareLink(item:url)}else{Button(loading ? "读取中…":"查看"){Task{await load()}}.disabled(loading || client==nil)}}
            if let error{Text(error).font(.caption).foregroundStyle(.orange)}
        }.padding(12).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
        .task{if ["jpg","jpeg","png","webp"].contains(URL(fileURLWithPath:file.name).pathExtension.lowercased()){await load()}}
        .sheet(isPresented:$expanded){NavigationStack{if let image{ScrollView{Image(uiImage:image).resizable().scaledToFit()}.toolbar{Button("完成"){expanded=false};if let url{ShareLink(item:url)}}}}}
    }
    private func load()async{
        guard !loading,url==nil,let client,let conversation=exchange.conversationId else{return}
        loading=true;defer{loading=false}
        do{
            let body=try JSONSerialization.data(withJSONObject:["conversationId":conversation,"exchangeId":exchange.id,"index":index])
            let response=try await client.request("/files",body:body)
            guard let object=try JSONSerialization.jsonObject(with:response) as? [String:Any],let raw=object["data"] as? String,let data=Data(base64Encoded:raw) else{throw ModelFailure(message:"附件格式无效")}
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let destination=folder.appendingPathComponent(URL(fileURLWithPath:file.name).lastPathComponent)
            try data.write(to:destination);url=destination;image=UIImage(data:data)
        }catch{self.error=error.localizedDescription}
    }
}
