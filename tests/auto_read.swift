import Foundation

func snapshot(_ text: String = "Answer", busy: Bool = false, complete: Bool = true, chat: String = "chat", id: String = "response") -> AIChatSnapshot {
    AIChatSnapshot(conversation: chat, responseID: id, text: text, generating: busy, complete: complete)
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
var state = AIAutoReadState()
check(state.observe(snapshot("Old answer"), now: 0, delay: 2) == nil, "launch history")
check(state.observe(snapshot("Partial", busy: true), now: 1, delay: 2) == nil, "stream")
check(state.observe(snapshot("Partial", busy: true), now: 20, delay: 2) == nil, "long stream pause")
check(state.observe(snapshot("Final"), now: 21, delay: 2) == nil, "new text settles")
check(state.observe(snapshot("Final"), now: 22, delay: 2) == nil, "delay")
check(state.observe(snapshot("Final"), now: 23, delay: 2) == "Final", "completed answer once")
check(state.observe(snapshot("Final"), now: 30, delay: 2) == nil, "no duplicate")
check(state.observe(snapshot("Next", busy: true), now: 31, delay: 2) == nil, "next stream")
state.suppress()
check(state.observe(snapshot("Next", busy: true), now: 32, delay: 2) == nil, "stop during stream")
check(state.observe(snapshot("Next"), now: 40, delay: 2) == nil, "stopped completion")
check(state.observe(snapshot("Next"), now: 45, delay: 2) == nil, "stopped never replayed")
_ = state.observe(snapshot("Third", busy: true), now: 46, delay: 2)
check(state.observe(snapshot("Third", complete: false), now: 60, delay: 2) == nil, "no completion control")
check(state.observe(snapshot("Third"), now: 61, delay: 2) == "Third", "next response after Stop")
check(state.observe(snapshot("History", chat: "other"), now: 70, delay: 2) == nil, "navigation history")
_ = state.observe(snapshot("New", busy: true, chat: "other"), now: 71, delay: 2)
check(state.observe(snapshot("New", chat: "other"), now: 74, delay: 2) == "New", "new answer in other chat")

func node(_ role: String = "AXGroup", _ label: String = "", text: String = "", id: String = "", children: [AINode] = []) -> AINode {
    AINode(role: role, label: label, identifier: id, text: text, children: children)
}
for label in ["ChatGPT said:", "Claude responded: First sentence.", "Gemini said"] {
    let flattened = node(children: [
        node("AXHeading", "You said: Private prompt"), node("AXStaticText", text: "Private prompt"), node("AXButton", "Copy message"),
        node("AXHeading", label), node("AXStaticText", text: "First sentence.\nSecond sentence."),
        node("AXToolbar", children: [node("AXButton", "Copy")]),
        node("AXHeading", "Latest response"), node("AXTextArea", text: "Unsent prompt")
    ])
    let responses = flattened.responses()
    check(responses.count == 1, "one assistant turn for \(label)")
    check(responses[0].spokenText == "First sentence.\nSecond sentence.", "exclude prompts, labels, toolbar, editor for \(label)")
    check(responses[0].contains { $0.copy }, "scoped completion copy for \(label)")
}
let promptOnly = node(children: [node("AXHeading", "You said: Prompt"), node("AXButton", "Copy message")])
check(promptOnly.responses().isEmpty, "prompt copy never becomes response")
check(node("AXButton", "Stop response").stop, "Gemini stream control")
check(node("AXButton", "Stop").stop, "ChatGPT stream control")
check(!node("AXStaticText", "Stop").stop, "quoted content is not a control")
print("PASS: AI completion, settling, duplicate, navigation, Stop, next response, and ChatGPT/Claude/Gemini extraction fixtures")

var fast = AIAutoReadState()
_ = fast.observe(snapshot("Old", id: "1"), now: 0, delay: 2)
check(fast.observe(snapshot("Fast", id: "2"), now: 1, delay: 2) == nil, "fast answer settles")
check(fast.observe(snapshot("Fast", id: "2"), now: 3, delay: 2) == "Fast", "new assistant turn without observed stream")
check(fast.observe(snapshot("Fast", id: "2"), now: 5, delay: 2) == nil, "fast answer once")
print("PASS: fast completed assistant turn detection")

var navigation = AIAutoReadState()
var local = snapshot("Part", busy: true); local.page = "/c/local-chatgpt:123"
_ = navigation.observe(local, now: 0, delay: 2)
var resolved = snapshot("Whole"); resolved.page = "/c/server123"
check(navigation.observe(resolved, now: 1, delay: 2) == nil, "server URL settles")
check(navigation.observe(resolved, now: 3, delay: 2) == "Whole", "local-to-server URL retains stream")
var history = snapshot("Other chat history"); history.page = "/c/different"
check(navigation.observe(history, now: 4, delay: 2) == nil, "different URL establishes baseline even with identical prompts")
check(navigation.observe(history, now: 8, delay: 2) == nil, "history never queued")
print("PASS: server URL resolution and same-prompt conversation navigation")
