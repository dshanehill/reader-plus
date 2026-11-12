let app = NSApplication.shared
registerDefaults()
prefs.removeObject(forKey: Key.voice)
_ = Speaker.shared
_ = Reading.shared
_ = Overlay.shared
_ = primaryHeight
var t0 = Date()
var n = 0
var heard = Set<Int>()
var failures: [String] = []
var paragraphOffsets = Set<Int>()
var indentedOffset: Int?
Speaker.shared.onWord = { r in
 if n == 10 && indentedOffset == nil { indentedOffset = r.location }
 if n == 9 { paragraphOffsets.insert(r.location) }
 if !heard.contains(n) {
  heard.insert(n)
  print("FIRST_WORD test=\(n) seconds=\(Date().timeIntervalSince(t0))"); fflush(stdout)
 }
}
Speaker.shared.onDone = { print("DONE test=\(n)"); fflush(stdout) }
func speak(_ id: Int, _ text: String) {
 n = id; t0 = Date(); print("REQUEST test=\(n)"); fflush(stdout)
 Speaker.shared.say(text, track: true)
}
for i in 0..<3 {
 DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3) { speak(i + 1, "Line \(i + 1). This should start promptly.") }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { speak(4, "This old reading must stop and never resume. " + String(repeating: "Old text. ", count: 20)) }
DispatchQueue.main.asyncAfter(deadline: .now() + 9.1) { speak(5, "This is the replacement reading.") }
DispatchQueue.main.asyncAfter(deadline: .now() + 9.2) { speak(6, "This is the final replacement reading.") }
DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
 let r = ClickReader.shared.begin()
 precondition(r.valid && ClickReader.shared.hasPending, "new request cancelled itself")
 Speaker.shared.stop()
 precondition(!r.valid && !ClickReader.shared.hasPending, "stop didn't cancel pending extraction")
 print("PASS pending request cancellation"); fflush(stdout)
 let r1 = ClickReader.shared.begin(), r2 = ClickReader.shared.begin()
 precondition(!r1.valid && r2.valid, "newest request didn't win")
 ClickReader.shared.cancelPending()
 print("PASS newer request supersedes old request"); fflush(stdout)
 speak(7, "This reading should be cancelled before its first word.")
 Speaker.shared.stop()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 13) { speak(8, "Reading works after stop.") }
DispatchQueue.main.asyncAfter(deadline: .now() + 16) { speak(9, "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.") }
DispatchQueue.main.asyncAfter(deadline: .now() + 16.3) { Speaker.shared.pauseOrResume() }
DispatchQueue.main.asyncAfter(deadline: .now() + 16.9) { Speaker.shared.pauseOrResume() }
DispatchQueue.main.asyncAfter(deadline:.now()+22) { speak(10,"   Indented text stays aligned.") }
DispatchQueue.main.asyncAfter(deadline:.now()+25) {
 guard let voice = AVSpeechSynthesisVoice(language:"en-US") else { failures.append("no installed Apple voice for native voice test"); return }
 prefs.set(voice.identifier,forKey:Key.voice)
 speak(11,"The installed Apple voice also works.")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
 let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph." as NSString
 for word in ["First", "Second", "Third"] {
  if !paragraphOffsets.contains(text.range(of: word).location) { failures.append("missing paragraph \(word)") }
 }
 print("PARAGRAPH OFFSETS \(paragraphOffsets.sorted())")
 for id in [1,2,3,6,8,10,11] { if !heard.contains(id) { failures.append("missing first word for \(id)") } }
 if indentedOffset != 3 { failures.append("leading-space word offset was \(String(describing:indentedOffset))") }
 if heard.contains(7) { failures.append("cancelled speech started") }
 print("RESULT \(failures.isEmpty ? "PASS" : failures.joined(separator: "; "))")
 fflush(stdout); exit(failures.isEmpty ? 0 : 1)
}
app.run()
