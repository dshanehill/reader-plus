let app = NSApplication.shared
registerDefaults()
prefs.removeObject(forKey: Key.voice)
_ = Speaker.shared
_ = Reading.shared
_ = Overlay.shared
_ = primaryHeight
precondition(ClickReader.modifiersMatch(.maskCommand))
precondition(ClickReader.modifiersMatch([.maskCommand,.maskShift]))
precondition(ClickReader.modifiersMatch([.maskCommand,.maskControl]))
precondition(ClickReader.modifiersMatch([.maskCommand,.maskAlternate]))
precondition(!ClickReader.modifiersMatch([]))
print("PASS Command-click modifiers including magnifier modifiers")
var testDelivered: [Int] = []
var testReplayed: [CGEvent] = []
var testReplayPIDs: [pid_t] = []
var permissionRequests = 0
var visionPassed = false
var delayedRan = false
var validDelayRan = false
var callbackTimes: [Double] = []
func click(_ x: Int, release: Bool = true, targetPID: Int64 = 4242) {
 let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x,y:100), mouseButton:.left)!
 event.flags = .maskCommand
 event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
 let t = ProcessInfo.processInfo.systemUptime
 let result = clickTapCallback(OpaquePointer(bitPattern: 1)!, .leftMouseDown, event, nil)
 callbackTimes.append(ProcessInfo.processInfo.systemUptime-t)
 precondition(result == nil, "reading click was passed to the application")
 if release { releaseClick(x) }
}
func releaseClick(_ x: Int) {
 let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:CGPoint(x:x,y:100),mouseButton:.left)!
 precondition(clickTapCallback(OpaquePointer(bitPattern:1)!, .leftMouseUp, up, nil) == nil)
}
// A small fake accessibility tree exercises actual document traversal and section boundaries.
for i in 0..<11 { nodes.append(AXUIElementCreateApplication(pid_t(100000+i))) }
func node(_ i: Int, _ role: String, _ text: String? = nil, _ kids: [Int] = []) {
 graph[i] = ["AXRole":role, "AXChildren":kids.map {nodes[$0]}]
 if let text = text { graph[i]!["AXValue"] = text }
 for k in kids { graph[k, default: [:]]["AXParent"] = nodes[i] }
}
// Assign parents after all node dictionaries exist.
node(0,"AXWebArea",nil,[1,3,6,8])
node(1,"AXHeading",nil,[2]); graph[1]!["AXValue"] = 2
node(2,"AXStaticText","Section one")
node(3,"AXGroup",nil,[4,10]); node(4,"AXStaticText","Alpha"); node(10,"AXGroup",nil,[5]); node(5,"AXStaticText","continued.")
node(6,"AXGroup",nil,[7]); node(7,"AXStaticText","Beta.")
node(8,"AXHeading",nil,[9]); graph[8]!["AXValue"] = 2
node(9,"AXStaticText","Section two")
for (parent,kids) in [(0,[1,3,6,8]),(1,[2]),(3,[4,10]),(10,[5]),(6,[7]),(8,[9])] {
 for k in kids { graph[k]!["AXParent"] = nodes[parent] }
}
let section = collectBlocks(nodes[0],from:nodes[1],sectionOnly:true)
precondition(section.map { $0.text } == ["Section one","Alpha continued.","Beta."], "section traversal overran its heading")
let para = collectBlocks(nodes[0],from:nodes[3],sectionOnly:true,paragraphOnly:true)
precondition(para.count == 1 && para[0].text == "Alpha continued.","paragraph traversal read beyond the requested paragraph")
print("PASS heading boundaries and complete paragraph text")

func pass(_ name: String) { print("PASS " + name); fflush(stdout) }
let utf = "First.\n\n😀 Second paragraph.\n\nThird." as NSString
let second = utf.range(of:"😀").location
precondition(utf.substring(with: clickedReadingRange(utf,at:second,paragraphOnly:true)!) == "😀 Second paragraph.\n")
precondition(utf.substring(with: clickedReadingRange(utf,at:second,paragraphOnly:false)!).hasPrefix("😀 Second"))
for invalid in [nil, -1, Int.max, utf.length, utf.length + 1] as [Int?] {
 precondition(clickedReadingRange(utf,at:invalid,paragraphOnly:true) == nil)
}
precondition(clickedReadingRange("" as NSString,at:0,paragraphOnly:false) == nil)
for invalid in [CFRange(location:-1,length:0), CFRange(location:0,length:-1), CFRange(location:Int.max,length:0), CFRange(location:Int.max-1,length:4)] {
 var r = invalid
 precondition(axRangeValue(AXValueCreate(.cfRange,&r)) == nil)
}
pass("invalid, missing, overflowing and Unicode text positions")
let lines = [
 OCRLine(text:"Unrelated title.",bounds:CGRect(x:0.05,y:0.85,width:0.45,height:0.06)),
 OCRLine(text:"Clicked paragraph starts",bounds:CGRect(x:0.05,y:0.55,width:0.4,height:0.06)),
 OCRLine(text:"and finishes here.",bounds:CGRect(x:0.05,y:0.47,width:0.35,height:0.06)),
 OCRLine(text:"Other column.",bounds:CGRect(x:0.65,y:0.55,width:0.3,height:0.06)),
 OCRLine(text:"Another paragraph.",bounds:CGRect(x:0.05,y:0.2,width:0.4,height:0.06))]
precondition(recognizedText(lines,readingAt:CGPoint(x:0.2,y:0.5)) == "Clicked paragraph starts and finishes here.")
precondition(recognizedText(lines).contains("Unrelated title."))
pass("screen fallback selects clicked paragraph and excludes other columns")
let stopped = ReadRequest(800); stopped.cancel()
ocrRead(CGRect(x:0,y:0,width:100,height:100),request:stopped)
precondition(permissionRequests == 0)
let denied = ClickReader.shared.begin()
ocrRead(CGRect(x:0,y:0,width:100,height:100),request:denied)
precondition(permissionRequests == 1 && !ClickReader.shared.hasPending && !denied.valid)
pass("cancelled OCR does nothing; missing permission clears pending reading")
let superseded = ReadRequest(801)
PreviousApp.finishSwitch(superseded) { delayedRan = true }
superseded.cancel()
let validSwitch = ReadRequest(802)
PreviousApp.finishSwitch(validSwitch) { validDelayRan = true }
let context = CGContext(data:nil,width:1000,height:360,bitsPerComponent:8,bytesPerRow:4000,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:1000,height:360))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:34),.foregroundColor:NSColor.black]
("Unrelated heading." as NSString).draw(at:CGPoint(x:40,y:280),withAttributes:attrs)
("Second target paragraph." as NSString).draw(at:CGPoint(x:40,y:170),withAttributes:attrs)
("Other text below." as NSString).draw(at:CGPoint(x:40,y:60),withAttributes:attrs)
NSGraphicsContext.restoreGraphicsState()
recognizeText(context.makeImage()!,readingAt:CGPoint(x:0.2,y:0.54)) { text in
 DispatchQueue.main.async {
  precondition(text.contains("Second target paragraph"),"Vision OCR failed target: \(text)")
  precondition(!text.contains("Unrelated") && !text.contains("below"),"OCR selected unrelated text: \(text)")
  visionPassed = true; pass("actual macOS Vision recognition of clicked target in a rendered image")
 }
}

DispatchQueue.main.async { click(100) }
DispatchQueue.main.asyncAfter(deadline:.now()+0.04) { click(200) }
DispatchQueue.main.asyncAfter(deadline:.now()+0.08) { click(300) }
DispatchQueue.main.asyncAfter(deadline:.now()+2.0) {
 precondition(testDelivered == [300], "stale reading was delivered: \(testDelivered)")
 print("PASS Command-click is not swallowed by a Reader window; newest click wins; delivered=\(testDelivered)")
 click(400)
 DispatchQueue.main.asyncAfter(deadline:.now()+0.05) { Speaker.shared.stop() }
}
DispatchQueue.main.asyncAfter(deadline:.now()+2.6) {
 precondition(testDelivered == [300], "a stopped lookup started later")
 precondition(callbackTimes.max()! < 0.03, "event tap blocked on slow app")
 print("PASS stop cancels an already-started text lookup")
 print("PASS callback max seconds=\(callbackTimes.max()!) despite 0.25s target delay")
 click(500)
}
DispatchQueue.main.asyncAfter(deadline:.now()+3.2) {
 precondition(testReplayed.map { $0.type } == [.leftMouseDown,.leftMouseUp], "quick native click was not paired")
 click(600,release:false,targetPID:0)
}
DispatchQueue.main.asyncAfter(deadline:.now()+3.6) { releaseClick(600) }
DispatchQueue.main.asyncAfter(deadline:.now()+3.8) {
 click(550)
 Speaker.shared.stop()
}
DispatchQueue.main.asyncAfter(deadline:.now()+4.4) {
 precondition(testReplayed.map { $0.type } == [.leftMouseDown,.leftMouseUp,.leftMouseDown,.leftMouseUp,.leftMouseDown,.leftMouseUp],"held or cancelled native click was not paired")
 for e in testReplayed {
  precondition(e.getIntegerValueField(.eventSourceUserData) == ClickReader.replayMarker)
  precondition(clickTapCallback(OpaquePointer(bitPattern:1)!,e.type,e,nil) != nil,"replayed click was captured again")
 }
 print("PASS native selection click pairing and loop prevention")
 let token = ReadRequest(999); token.cancel()
 let value = AXWork.run(seconds:1, valid:{token.valid}) { axString(nodes[2],"AXValue") }
 precondition(value == nil,"cancelled traversal kept querying")
 let expired = AXWork.run(seconds:0) { axString(nodes[2],"AXValue") }
 precondition(expired == nil,"expired traversal kept querying")
 print("PASS cancellation and deadline stop accessibility work")
 precondition(testReplayPIDs == [4242,4242,8888,8888,4242,4242],"native click target changed: \(testReplayPIDs)")
 precondition(!delayedRan && validDelayRan,"delayed controls action ignored cancellation")
 precondition(visionPassed,"actual OCR test did not finish")
 pass("cancelled speech still preserves the real native click and mouse-up")
 pass("native replay preserves original process and uses classified process only when needed")
 pass("superseded controls action is cancelled; current controls action runs")
 Speaker.shared.stop()
 fflush(stdout); exit(0)
}
app.run()
