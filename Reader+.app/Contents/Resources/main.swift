// Reader+ — a ZoomText-style screen reader for the Mac, without the magnifier.
// Speaks with the Mac's own voices (the same ones VoiceOver uses) without turning VoiceOver on.
//
//   Reader+ is a mouse-first app. No keyboard shortcuts to learn; people who want lots of
//   commands can use VoiceOver. Everything below uses the Command key and the mouse:
//
//   ⌘-click                Read by structure: a heading reads its whole section; a paragraph reads the
//                          article from there (or just that paragraph). A social media post is read in full,
//                          and a picture has its words read (OCR).
//   ⌘-right-click          Read the whole page or window under the pointer (OCR if it has no real text).
//                          While Reader+ is talking, it stops instead.
//   ⌘ + Back / Forward     Previous / next paragraph (the side buttons on a mouse), while reading.
//   ⌘ + scroll wheel       Faster (up) / slower (down), while reading.
//   Tap Control            Stop talking, like VoiceOver.
//   Everything else is in the Reader+ window and the menu bar icon.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement
import SwiftUI
import Vision
import ScreenCaptureKit

// MARK: - Log & settings

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Reader+.log")
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

enum Key {
    static let voice = "voice", rate = "rate", mouseEcho = "mouseEcho", hoverDelay = "hoverDelay"
    static let keyEcho = "keyEcho", fontSize = "fontSize", theme = "theme"
    static let screenHighlight = "screenHighlight", showReader = "showReader"
    static let clickMode = "clickMode", paragraphMode = "paragraphMode", clickShowsReader = "clickShowsReader"
}
let prefs = UserDefaults.standard
func registerDefaults() {
    prefs.register(defaults: [
        Key.rate: 0.5, Key.mouseEcho: false, Key.hoverDelay: 0.45, Key.keyEcho: 0,
        Key.fontSize: 34.0, Key.theme: 0, Key.screenHighlight: true, Key.showReader: true,
        Key.clickMode: 1,      // 0 off, 1 ⌘-click, 2 ⌥⌘-click
        Key.paragraphMode: 0,  // 0 read from the paragraph to the end, 1 just that paragraph
        Key.clickShowsReader: false, // ⌘-click just reads aloud, without opening the reading window
    ])
}

struct Theme { let name: String; let fg: NSColor; let bg: NSColor; let hl: NSColor; let hlText: NSColor }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
let themes: [Theme] = [
    Theme(name: "Yellow on Black", fg: rgb(1, 0.9, 0.2), bg: .black, hl: rgb(0.15, 0.45, 1), hlText: .white),
    Theme(name: "White on Black", fg: .white, bg: .black, hl: rgb(1, 0.85, 0), hlText: .black),
    Theme(name: "Black on White", fg: .black, bg: .white, hl: rgb(1, 0.85, 0), hlText: .black),
    Theme(name: "White on Blue", fg: .white, bg: rgb(0.04, 0.13, 0.42), hl: rgb(1, 0.85, 0), hlText: .black),
    Theme(name: "Black on Cream", fg: .black, bg: rgb(1, 0.97, 0.86), hl: rgb(0.55, 0.8, 1), hlText: .black),
]

func readingVoices() -> [AVSpeechSynthesisVoice] {
    let lang = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
    return AVSpeechSynthesisVoice.speechVoices()
        .filter { v in
            guard v.language.hasPrefix(lang) else { return false }
            if #available(macOS 14.0, *) { return !v.voiceTraits.contains(.isNoveltyVoice) }
            return true
        }
        .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

// MARK: - Speech (system voices — the same ones VoiceOver uses)

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    let synth = AVSpeechSynthesizer()
    private var offsets: [ObjectIdentifier: Int] = [:]   // where each piece starts in the full text
    private var lastPiece: AVSpeechUtterance?
    var onWord: ((NSRange) -> Void)?
    var onDone: (() -> Void)?

    override init() { super.init(); synth.delegate = self }

    var isReading: Bool { lastPiece != nil }
    var isPaused: Bool { synth.isPaused }

    var voice: AVSpeechSynthesisVoice? {
        if let id = prefs.string(forKey: Key.voice), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Splits text into pieces of about a paragraph (long paragraphs at sentence ends).
    static func pieces(_ text: String) -> [(Int, String)] {
        let ns = text as NSString
        var out: [(Int, String)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, pr, _, _ in
            guard !ns.substring(with: pr).trimmed.isEmpty else { return }
            if pr.length <= 600 { out.append((pr.location, ns.substring(with: pr))); return }
            var start = pr.location, end = pr.location
            ns.enumerateSubstrings(in: pr, options: .bySentences) { _, sr, _, _ in
                if NSMaxRange(sr) - start > 450 && end > start {
                    out.append((start, ns.substring(with: NSRange(location: start, length: end - start))))
                    start = end
                }
                end = NSMaxRange(sr)
            }
            if NSMaxRange(pr) > start { out.append((start, ns.substring(with: NSRange(location: start, length: NSMaxRange(pr) - start)))) }
        }
        return out
    }

    /// Speak text. `track` = this is a reading (word highlighting, reading window).
    func say(_ text: String, track: Bool = false) {
        guard !text.trimmed.isEmpty else { return }
        let wasReading = lastPiece != nil
        offsets = [:]; lastPiece = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        let rate = Float(prefs.double(forKey: Key.rate)), v = voice
        if !track {
            if wasReading { onDone?() }
            let u = AVSpeechUtterance(string: text.trimmed); u.rate = rate; u.voice = v
            synth.speak(u); return
        }
        for (off, piece) in Speaker.pieces(text) {
            let u = AVSpeechUtterance(string: piece); u.rate = rate; u.voice = v
            offsets[ObjectIdentifier(u)] = off
            lastPiece = u
            synth.speak(u)
        }
    }

    func pauseOrResume() {
        if synth.isPaused { synth.continueSpeaking() }
        else if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
    }

    func stop() {
        let wasReading = lastPiece != nil
        offsets = [:]; lastPiece = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        if wasReading { onDone?() }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        DispatchQueue.main.async {
            guard let off = self.offsets[id] else { return }
            self.onWord?(NSRange(location: r.location + off, length: r.length))
        }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { ended(u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { ended(u) }
    private func ended(_ u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard u === self.lastPiece else { return }
            self.lastPiece = nil; self.offsets = [:]
            self.onDone?()
        }
    }
}

func say(_ s: String) { Speaker.shared.say(s) }

// MARK: - Accessibility helpers

func ax(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
}
func axString(_ e: AXUIElement, _ attr: String) -> String? { ax(e, attr) as? String }
func axElement(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = ax(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func axChildren(_ e: AXUIElement) -> [AXUIElement] { (ax(e, "AXChildren") as? [AXUIElement]) ?? [] }
func axParam(_ e: AXUIElement, _ attr: String, _ p: CFTypeRef) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(e, attr as CFString, p, &v) == .success ? v : nil
}
func axRangeValue(_ v: CFTypeRef?) -> CFRange? {
    guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var r = CFRange()
    return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
}
func axRectValue(_ v: CFTypeRef?) -> CGRect? {
    guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var r = CGRect.zero
    return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
}
func makeRange(_ loc: Int, _ len: Int) -> AXValue { var r = CFRange(location: loc, length: len); return AXValueCreate(.cfRange, &r)! }
func makePoint(_ p: CGPoint) -> AXValue { var pp = p; return AXValueCreate(.cgPoint, &pp)! }

let systemWide = AXUIElementCreateSystemWide()
func focusedElement() -> AXUIElement? { axElement(systemWide, "AXFocusedUIElement") }

/// Asks Chrome / Electron apps to expose their web content to accessibility.
@discardableResult
func frontAppElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let e = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(e, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetMessagingTimeout(e, 1.5)
    return e
}

var exposedPIDs = Set<pid_t>()
/// Chromium and Electron apps (Chrome, Claude, ChatGPT, Slack, Discord…) only share their page text with
/// assistive apps once asked. VoiceOver asks automatically; Reader+ asks here.
func exposeText(_ pid: pid_t) {
    guard pid != ProcessInfo.processInfo.processIdentifier, !exposedPIDs.contains(pid) else { return }
    exposedPIDs.insert(pid)
    let e = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(e, 0.5)
    AXUIElementSetAttributeValue(e, "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

/// Roles where ⌘-click means something else (selecting several files, rows or list items).
let selectionRoles: Set<String> = ["AXOutline", "AXTable", "AXList", "AXBrowser", "AXRow", "AXCell", "AXMenu", "AXMenuBar", "AXToolbar"]

// Screen coordinates: AX uses a top-left origin, AppKit a bottom-left one.
var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
func axPoint(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
func cocoaRect(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }

let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                 "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTab", "AXSlider", "AXComboBox",
                                 "AXTextField", "AXDisclosureTriangle", "AXIncrementor"]

/// What Mouse Echo says for the thing under the pointer.
func textAt(_ p: CGPoint) -> (text: String, frame: CGRect?)? {
    var found: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &found) == .success, let e = found else { return nil }
    AXUIElementSetMessagingTimeout(e, 0.8)
    let role = axString(e, "AXRole") ?? ""

    // Long text (documents, articles): read just the line under the pointer.
    if let v = axString(e, "AXValue"), (v as NSString).length > 160,
       ["AXTextArea", "AXTextField", "AXStaticText"].contains(role) {
        if let idx = axRangeValue(axParam(e, "AXRangeForPosition", makePoint(p)))?.location,
           let line = axParam(e, "AXLineForIndex", NSNumber(value: idx) as CFTypeRef) as? Int,
           let lr = axRangeValue(axParam(e, "AXRangeForLine", NSNumber(value: line) as CFTypeRef)),
           let s = axParam(e, "AXStringForRange", makeRange(lr.location, lr.length)) as? String, !s.trimmed.isEmpty {
            let frame = axRectValue(axParam(e, "AXBoundsForRange", makeRange(lr.location, lr.length)))
            return (s.trimmed, frame)
        }
        return (String(v.prefix(300)), nil)
    }

    var parts: [String] = []
    func add(_ s: String?) { if let s = s?.trimmed, !s.isEmpty, !parts.contains(s) { parts.append(s) } }
    add(axString(e, "AXValue")); add(axString(e, "AXTitle")); add(axString(e, "AXDescription"))
    if parts.isEmpty, let t = axElement(e, "AXTitleUIElement") { add(axString(t, "AXValue")) }
    if parts.isEmpty { for c in axChildren(e).prefix(10) { add(axString(c, "AXValue")); add(axString(c, "AXTitle")) } }
    if parts.isEmpty { add(axString(e, "AXHelp")) }
    if controlRoles.contains(role), let rd = axString(e, "AXRoleDescription"), !parts.isEmpty { parts.append(rd) }
    if role == "AXCheckBox" || role == "AXRadioButton", let n = ax(e, "AXValue") as? NSNumber {
        parts.append(n.intValue == 1 ? "checked" : "not checked")
    }
    guard !parts.isEmpty else { return nil }
    let frame: CGRect? = {
        guard let pv = ax(e, "AXPosition"), let sv = ax(e, "AXSize"),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pt); AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }()
    return (parts.joined(separator: ", "), frame)
}

/// Text to read for AppReader, with where it lives on screen (for the on-screen highlight).
struct ReadSource {
    let text: String; let element: AXUIElement?; let base: Int
    var blocks: [(range: NSRange, element: AXUIElement, heading: Int)] = []
}

// MARK: - Document structure (headings and paragraphs on web pages and documents)

struct DocBlock { let element: AXUIElement; var text: String; let heading: Int } // heading 0 = paragraph

func headingLevel(_ e: AXUIElement) -> Int {
    if let n = ax(e, "AXValue") as? NSNumber, n.intValue > 0 { return n.intValue }
    if let d = axString(e, "AXRoleDescription"), let n = Int(d.filter(\.isNumber)), n > 0 { return n }
    return 2
}

/// Buttons and form controls ("Like", "Share", "Reply"…) aren't part of what you want read.
let skipRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
                              "AXTextField", "AXComboBox", "AXToolbar", "AXMenu", "AXMenuBar", "AXSlider"]

/// Do two containers sit side by side in the same paragraph (same parent, or one inside the other)?
func sameParagraph(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
    guard let pb = axElement(b, "AXParent") else { return false }
    if CFEqual(pb, a) { return true }
    if let pa = axElement(a, "AXParent"), CFEqual(pa, pb) { return true }
    return false
}

/// The paragraph-level element that holds a clicked spot: the first ancestor that isn't text, a link or a picture.
func blockStart(_ chain: [AXUIElement], within root: AXUIElement) -> AXUIElement? {
    let inline: Set<String> = ["AXStaticText", "AXLink", "AXImage", "AXButton", "AXCheckBox", "AXRadioButton",
                               "AXTextField", "AXPopUpButton", "AXMenuButton"]
    for a in chain {
        if CFEqual(a, root) { return nil }
        if !inline.contains(axString(a, "AXRole") ?? "") { return a }
    }
    return nil
}

/// Splits a web page (or other content) into headings and paragraphs, in reading order.
/// With `startNode`, it starts there (the spot you clicked) and only goes forward, so even the
/// bottom of a very long page (a YouTube list, a long feed) is reached quickly.
func collectBlocks(_ root: AXUIElement, from startNode: AXUIElement? = nil) -> [DocBlock] {
    var blocks: [DocBlock] = []
    var visited = 0
    var path: [AXUIElement] = []
    if let st = startNode {
        let up = ancestors(st, max: 150)
        if let ri = up.firstIndex(where: { CFEqual($0, root) }) { path = Array(up[0...ri].reversed()) }
    }
    func add(_ text: String, _ container: AXUIElement, _ heading: Int) {
        if var last = blocks.last {
            if CFEqual(last.element, container) && last.heading == heading {
                last.text += " " + text; blocks[blocks.count - 1] = last; return
            }
            // Pieces of one sentence split across little containers — keep them together, but only when
            // they really are in the same paragraph (never glue separate list items or videos together).
            if heading == 0 && last.heading == 0, let ch = last.text.last, !".!?:;\"”)]".contains(ch),
               (last.text as NSString).length < 400, sameParagraph(last.element, container) {
                last.text += " " + text; blocks[blocks.count - 1] = last; return
            }
        }
        blocks.append(DocBlock(element: container, text: text, heading: heading))
    }
    func walk(_ e: AXUIElement, _ depth: Int, _ container: AXUIElement, _ heading: Int, _ pi: Int?) {
        if visited > 40000 || depth > 150 { return }
        visited += 1
        let role = axString(e, "AXRole") ?? ""
        if skipRoles.contains(role) { return }
        if role == "AXStaticText" {
            if let v = axString(e, "AXValue")?.trimmed, !v.isEmpty { add(v, container, heading) }
            return
        }
        if role == "AXTextArea", let v = axString(e, "AXValue")?.trimmed, !v.isEmpty {
            for para in v.components(separatedBy: "\n") where !para.trimmed.isEmpty { blocks.append(DocBlock(element: e, text: para.trimmed, heading: 0)) }
            return
        }
        let next: AXUIElement = role == "AXLink" ? container : e
        let h = role == "AXHeading" ? headingLevel(e) : heading
        let kids = axChildren(e)
        if let i = pi, i + 1 < path.count {
            // Skip everything before the clicked spot.
            let target = path[i + 1]
            guard let at = kids.firstIndex(where: { CFEqual($0, target) }) else {
                for c in kids { walk(c, depth + 1, next, h, nil) }; return
            }
            walk(kids[at], depth + 1, next, h, i + 1)
            for c in kids[(at + 1)...] { walk(c, depth + 1, next, h, nil) }
        } else {
            for c in kids { walk(c, depth + 1, next, h, nil) }
        }
    }
    walk(root, 0, root, 0, path.isEmpty ? nil : 0)
    return blocks
}

func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let pv = ax(e, "AXPosition"), let sv = ax(e, "AXSize"),
          CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &pt); AXValueGetValue(sv as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func ancestors(_ e: AXUIElement, max: Int = 60) -> [AXUIElement] {
    var out: [AXUIElement] = [e]; var cur = e
    while out.count < max, let p = axElement(cur, "AXParent") { out.append(p); cur = p }
    return out
}

/// Builds what to read from a list of blocks, starting at `index`.
/// A heading reads its section; a paragraph reads to the end (or just itself).
func sourceFromBlocks(_ blocks: [DocBlock], start index: Int, sectionOnly: Bool, paragraphOnly: Bool) -> ReadSource {
    var end = blocks.count
    let first = blocks[index]
    if first.heading > 0 && sectionOnly {
        end = blocks[(index + 1)...].firstIndex(where: { $0.heading > 0 && $0.heading <= first.heading }) ?? blocks.count
    } else if first.heading == 0 && paragraphOnly {
        end = index + 1
    }
    var text = ""
    var ranges: [(range: NSRange, element: AXUIElement, heading: Int)] = []
    for b in blocks[index..<end] {
        if !text.isEmpty { text += "\n\n" }
        let loc = (text as NSString).length
        let t = b.heading > 0 && !".!?:".contains(b.text.last ?? " ") ? b.text + "." : b.text
        text += t
        ranges.append((NSRange(location: loc, length: (t as NSString).length), b.element, b.heading))
        if (text as NSString).length > 80000 { break }
    }
    var src = ReadSource(text: text, element: nil, base: 0)
    src.blocks = ranges
    return src
}

/// ⌘-click: read by structure at a screen point (top-left coordinates). Returns nil if there's nothing to read.
func readSourceAt(_ p: CGPoint) -> ReadSource? {
    var found: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &found) == .success, let hit = found else { return nil }
    AXUIElementSetMessagingTimeout(hit, 1.5)
    let chain = ancestors(hit)
    let paragraphOnly = prefs.integer(forKey: Key.paragraphMode) == 1

    // Documents (TextEdit, Notes, Pages text…): read from the clicked paragraph.
    if let ta = chain.first(where: { axString($0, "AXRole") == "AXTextArea" }),
       !chain.contains(where: { axString($0, "AXRole") == "AXWebArea" }),
       let v = axString(ta, "AXValue"), !v.trimmed.isEmpty {
        let ns = v as NSString
        let idx = min(axRangeValue(axParam(ta, "AXRangeForPosition", makePoint(p)))?.location ?? 0, max(ns.length - 1, 0))
        let para = ns.paragraphRange(for: NSRange(location: idx, length: 0))
        let r = paragraphOnly ? para : NSRange(location: para.location, length: ns.length - para.location)
        return ReadSource(text: ns.substring(with: r), element: ta, base: r.location)
    }

    // Buttons, boxes, checkboxes, menus and the like: say what they are, like "Subscribe, button".
    let hitRole = axString(hit, "AXRole") ?? ""
    if controlRoles.contains(hitRole) && hitRole != "AXLink" {
        if let t = textAt(p), !t.text.trimmed.isEmpty { return ReadSource(text: t.text, element: nil, base: 0) }
    }
    // Lists where ⌘-click selects (Finder, Mail, the Dock…): read just that item.
    if chain.prefix(8).contains(where: { selectionRoles.contains(axString($0, "AXRole") ?? "") })
        && !chain.contains(where: { axString($0, "AXRole") == "AXWebArea" }) {
        if let t = textAt(p), !t.text.trimmed.isEmpty { return ReadSource(text: t.text, element: nil, base: 0) }
        let t = collectText(hit); if !t.trimmed.isEmpty { return ReadSource(text: t, element: nil, base: 0) }
    }

    // Web pages: headings and paragraphs.
    guard let web = chain.first(where: { axString($0, "AXRole") == "AXWebArea" }) else {
        // Native apps (for example a chat app's replies): read from the clicked paragraph onward.
        if let area = chain.first(where: { axString($0, "AXRole") == "AXScrollArea" }) {
            let blocks = collectBlocks(area, from: blockStart(chain, within: area))
            if !blocks.isEmpty { return sourceFromBlocks(blocks, start: 0, sectionOnly: true, paragraphOnly: paragraphOnly) }
        }
        if let t = textAt(p) { return ReadSource(text: t.text, element: nil, base: 0) }
        let t = collectText(hit)
        return t.trimmed.isEmpty ? nil : ReadSource(text: t, element: nil, base: 0)
    }

    // Social media: read the whole post, opening "See more" first.
    if isSocial(web), let post = postContainer(chain, web: web) {
        if expandSeeMore(post) {
            usleep(700_000) // let the site show the rest of the post
            var again: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &again) == .success, let h = again,
               let fresh = postContainer(ancestors(h), web: web) {
                let b = collectBlocks(fresh)
                if !b.isEmpty { return sourceFromBlocks(b, start: 0, sectionOnly: false, paragraphOnly: false) }
            }
        }
        let b = collectBlocks(post)
        if !b.isEmpty { return sourceFromBlocks(b, start: 0, sectionOnly: false, paragraphOnly: false) }
    }

    // Every other page: start exactly where you clicked (a paragraph, a link, a video in a long list)
    // and keep going down the page from there.
    let root = chain.first(where: { isArticle($0) }) ?? web
    let blocks = collectBlocks(root, from: blockStart(chain, within: root))
    if !blocks.isEmpty { return sourceFromBlocks(blocks, start: 0, sectionOnly: true, paragraphOnly: paragraphOnly) }

    // Last resort: the nearest bit of the page around the click that has words in it.
    for a in chain.prefix(12) {
        if CFEqual(a, web) { break }
        let t = collectText(a)
        if t.count >= 20 { return ReadSource(text: t, element: nil, base: 0) }
    }
    return nil
}

// MARK: - Social media posts

let socialHosts = ["facebook.com", "instagram.com", "x.com", "twitter.com", "threads.net", "threads.com",
                   "linkedin.com", "reddit.com", "tiktok.com", "bsky.app", "tumblr.com", "mastodon"]

func webURL(_ web: AXUIElement) -> String? {
    guard let u = ax(web, "AXURL") else { return nil }
    if CFGetTypeID(u) == CFURLGetTypeID() { return (u as! URL).absoluteString }
    return u as? String
}

func isSocial(_ web: AXUIElement) -> Bool {
    guard let u = webURL(web)?.lowercased(), let host = URL(string: u)?.host else { return false }
    return socialHosts.contains(where: { host.contains($0) })
}

func isArticle(_ e: AXUIElement) -> Bool {
    if axString(e, "AXSubrole") == "AXDocumentArticle" { return true }
    return (axString(e, "AXRoleDescription") ?? "").lowercased() == "article"
}

/// The post that holds the click: an <article> if the site marks one, otherwise the
/// smallest block around the click that looks like a whole post.
func postContainer(_ chain: [AXUIElement], web: AXUIElement) -> AXUIElement? {
    for a in chain {
        if CFEqual(a, web) { break }
        if isArticle(a) { return a }
    }
    var best: AXUIElement? = nil
    for a in chain.prefix(30) {
        if CFEqual(a, web) { break }
        let t = collectText(a)
        if t.count > 3000 { break }          // that's several posts or the whole feed, not one post
        if t.count >= 60 { best = a }
        if t.count >= 400 { break }
    }
    return best
}

/// Presses "See more" / "Read more" inside a post. Returns true if it pressed something.
func expandSeeMore(_ post: AXUIElement) -> Bool {
    let words = ["see more", "read more", "show more", "…more", "... more", "...more", "more", "see more…", "show full post"]
    var pressed = false
    var visited = 0
    func label(_ e: AXUIElement) -> String {
        (axString(e, "AXTitle") ?? axString(e, "AXValue") ?? axString(e, "AXDescription") ?? "").trimmed.lowercased()
    }
    func press(_ e: AXUIElement) -> Bool {
        var cur: AXUIElement? = e
        for _ in 0..<4 {
            guard let c = cur else { return false }
            var names: CFArray?
            if AXUIElementCopyActionNames(c, &names) == .success, let n = names as? [String], n.contains("AXPress") {
                return AXUIElementPerformAction(c, "AXPress" as CFString) == .success
            }
            cur = axElement(c, "AXParent")
        }
        return false
    }
    func walk(_ e: AXUIElement, _ depth: Int) {
        if pressed || visited > 4000 || depth > 60 { return }
        visited += 1
        let role = axString(e, "AXRole") ?? ""
        if ["AXButton", "AXLink", "AXStaticText"].contains(role), words.contains(label(e)) {
            if press(e) { pressed = true; log("pressed See more"); return }
        }
        for c in axChildren(e) { walk(c, depth + 1) }
    }
    walk(post, 0)
    return pressed
}

enum ClickUse { case ignore, read, readAndPass }

/// What a ⌘-click at this point should do. Everything on a web page is read, links included.
/// In other apps, text and controls are read too; in lists where ⌘-click selects things
/// (Finder, Mail, the Dock), Reader+ reads the item and still lets the click select it.
func clickUse(_ p: CGPoint) -> ClickUse {
    var found: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &found) == .success, let hit = found else { return .read }
    AXUIElementSetMessagingTimeout(hit, 0.25)
    var pid: pid_t = 0
    if AXUIElementGetPid(hit, &pid) == .success {
        exposeText(pid)
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" { return .readAndPass }
    }
    var cur: AXUIElement? = hit; var n = 0; var selectable = false
    while let c = cur, n < 60 {
        let r = axString(c, "AXRole") ?? ""
        if r == "AXWebArea" { return .read }
        if r == "AXMenuBar" || r == "AXMenu" { return .readAndPass }
        if selectionRoles.contains(r) { selectable = true }
        if r == "AXWindow" || r == "AXApplication" { break }
        cur = axElement(c, "AXParent"); n += 1
    }
    return selectable ? .readAndPass : .read
}

/// Older check, kept for anything that only needs a yes or no.
func clickIsReadable(_ p: CGPoint) -> Bool {
    var found: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &found) == .success, let hit = found else { return false }
    AXUIElementSetMessagingTimeout(hit, 0.25)
    var pid: pid_t = 0
    if AXUIElementGetPid(hit, &pid) == .success { exposeText(pid) }
    let hitRole = axString(hit, "AXRole") ?? ""
    if hitRole == "AXImage" { return true }
    var cur: AXUIElement? = hit; var n = 0; var inScroll = false
    while let c = cur, n < 40 {
        let r = axString(c, "AXRole") ?? ""
        if r == "AXLink" || r == "AXButton" || r == "AXTextField" { return false }
        if r == "AXWebArea" || r == "AXTextArea" { return true }
        if selectionRoles.contains(r) { return false }
        if r == "AXScrollArea" { inScroll = true }
        if r == "AXWindow" || r == "AXApplication" {
            // Native apps (like a chat app's messages): text inside a scrolling area can be read.
            return inScroll && (hitRole == "AXStaticText" || hitRole == "AXGroup")
        }
        cur = axElement(c, "AXParent"); n += 1
    }
    return false
}

func readSourceFromFocus() -> ReadSource? {
    let app = frontAppElement()
    guard let f = focusedElement() else { return nil }
    AXUIElementSetMessagingTimeout(f, 1.5)
    let role = axString(f, "AXRole") ?? ""
    if let v = axString(f, "AXValue"), !v.trimmed.isEmpty, ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) {
        let ns = v as NSString
        var start = axRangeValue(ax(f, "AXSelectedTextRange"))?.location ?? 0
        if start >= ns.length - 1 { start = 0 } // cursor at the end → read it all
        return ReadSource(text: ns.substring(from: start), element: f, base: start)
    }
    // Otherwise read the web page or window that holds the focus.
    var root: AXUIElement? = nil
    var cur: AXUIElement? = f; var hops = 0
    while let c = cur, hops < 80 {
        let r = axString(c, "AXRole") ?? ""
        if r == "AXWebArea" || r == "AXWindow" { root = c; break }
        cur = axElement(c, "AXParent"); hops += 1
    }
    if root == nil, let a = app { root = axElement(a, "AXFocusedWindow") }
    guard let r = root else { return nil }
    let blocks = collectBlocks(r)
    if !blocks.isEmpty {
        // Start at the paragraph that has the focus, if any.
        let chain = ancestors(f)
        var start = 0
        for a in chain { if let i = blocks.firstIndex(where: { CFEqual($0.element, a) }) { start = i; break } }
        return sourceFromBlocks(blocks, start: start, sectionOnly: false, paragraphOnly: false)
    }
    let text = collectText(r)
    return text.trimmed.isEmpty ? nil : ReadSource(text: text, element: nil, base: 0)
}

func collectText(_ root: AXUIElement) -> String {
    var parts: [String] = []
    var visited = 0
    func walk(_ e: AXUIElement, _ depth: Int) {
        if visited > 8000 || depth > 70 { return }
        visited += 1
        let role = axString(e, "AXRole") ?? ""
        if role == "AXStaticText" || role == "AXTextArea" {
            if let v = axString(e, "AXValue")?.trimmed, !v.isEmpty { parts.append(v) }
            return
        }
        if role == "AXImage", let d = axString(e, "AXDescription")?.trimmed, !d.isEmpty, d.count > 3 { parts.append("Image: \(d).") }
        for c in axChildren(e) { walk(c, depth + 1) }
    }
    walk(root, 0)
    var out = ""
    for p in parts {
        if out.isEmpty { out = p; continue }
        let last = out.last ?? " "
        out += (".!?:;".contains(last) || p.count > 80) ? "\n" + p : " " + p
    }
    return out
}

/// The text view in one of Reader+'s own windows at a screen point (AppKit coordinates), if any.
/// Returns nil (no hit) when the point isn't over a Reader+ window at all.
func ownWindowHit(_ cp: NSPoint) -> (inOwnWindow: Bool, textView: NSTextView?, index: Int) {
    for w in NSApp.windows where w.isVisible && w !== Overlay.shared.win && w.frame.contains(cp) {
        guard let cv = w.contentView, let frameView = cv.superview else { return (true, nil, 0) }
        let wp = w.convertPoint(fromScreen: cp)
        var v = frameView.hitTest(frameView.convert(wp, from: nil))
        while let x = v, !(x is NSTextView) { v = x.superview }
        if let tv = v as? NSTextView {
            return (true, tv, tv.characterIndexForInsertion(at: tv.convert(wp, from: nil)))
        }
        return (true, nil, 0)
    }
    return (false, nil, 0)
}

/// Selected text: straight from accessibility, or by copying it as a fallback.
func withSelectedText(_ done: @escaping (String?, AXUIElement?, Int) -> Void) {
    if NSApp.isActive {
        // Reader+ itself is in front (the tour's practice box, the reading window…)
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.selectedRange().length > 0 {
            done((tv.string as NSString).substring(with: tv.selectedRange()), nil, 0)
        } else { done(nil, nil, 0) }
        return
    }
    frontAppElement()
    if let f = focusedElement(), let s = axString(f, "AXSelectedText"), !s.trimmed.isEmpty {
        let loc = axRangeValue(ax(f, "AXSelectedTextRange"))?.location ?? -1
        done(s, loc >= 0 ? f : nil, max(loc, 0)); return
    }
    let pb = NSPasteboard.general
    let before = pb.changeCount
    let saved = pb.string(forType: .string)
    postKey(CGKeyCode(kVK_ANSI_C), .maskCommand)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard pb.changeCount != before else { done(nil, nil, 0); return }
        let s = pb.string(forType: .string)
        if let saved = saved { pb.clearContents(); pb.setString(saved, forType: .string) }
        done(s, nil, 0)
    }
}

func postKey(_ code: CGKeyCode, _ flags: CGEventFlags) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = flags; d?.post(tap: .cghidEventTap)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = flags; u?.post(tap: .cghidEventTap)
}

// MARK: - On-screen highlight (follows the word being read, or the item Mouse Echo reads)

final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        NSColor.systemYellow.withAlphaComponent(0.28).setFill(); p.fill()
        NSColor.systemOrange.setStroke(); p.lineWidth = 3; p.stroke()
    }
}

final class Overlay {
    static let shared = Overlay()
    let win: NSWindow
    var hideWork: DispatchWorkItem?
    init() {
        win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.ignoresMouseEvents = true; win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.contentView = HighlightView()
    }
    func show(axRect r: CGRect, for seconds: Double? = nil) {
        guard prefs.bool(forKey: Key.screenHighlight), r.width > 0, r.height > 0, r.width < 1400, r.height < 70 else { hide(); return }
        win.setFrame(cocoaRect(r).insetBy(dx: -4, dy: -3), display: true)
        win.orderFrontRegardless()
        hideWork?.cancel()
        if let s = seconds {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
        }
    }
    func hide() { hideWork?.cancel(); win.orderOut(nil) }
}

// MARK: - Reading window (large, high-contrast text with the spoken word highlighted)

final class ReaderWindow: NSObject, NSWindowDelegate {
    static let shared = ReaderWindow()
    var window: NSPanel?
    var textView: NSTextView!
    var playButton: NSButton!
    var lastHL: NSRange?

    var theme: Theme { themes[max(0, min(prefs.integer(forKey: Key.theme), themes.count - 1))] }
    var fontSize: CGFloat { CGFloat(prefs.double(forKey: Key.fontSize)) }

    var isVisible: Bool { window?.isVisible ?? false }

    func build() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main!
        let vf = screen.visibleFrame
        let size = NSSize(width: min(760, vf.width * 0.6), height: min(440, vf.height * 0.5))
        let p = NSPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Reading Window"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        // A modest window that never fills the screen.
        p.collectionBehavior = [.fullScreenNone]
        p.contentMinSize = NSSize(width: 420, height: 260)
        p.contentMaxSize = NSSize(width: 1100, height: 700)
        p.setFrameAutosaveName("ReaderPlusReadingSmall")
        if p.frame.width > 1120 || p.frame.height > 760 {
            p.setContentSize(size); p.center()
        }

        let content = NSView(frame: p.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let bar = NSStackView()
        bar.orientation = .horizontal; bar.spacing = 8; bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        func button(_ title: String, _ sel: Selector, _ tip: String, _ symbol: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.font = .systemFont(ofSize: 15); b.bezelStyle = .rounded; b.controlSize = .large
            b.toolTip = tip; b.setAccessibilityLabel(tip)
            bar.addArrangedSubview(b); return b
        }
        playButton = button("Read", #selector(playPause), "Read from the cursor, or pause and resume", "play.fill")
        _ = button("Stop", #selector(stopReading), "Stop reading", "stop.fill")
        _ = button("Slower", #selector(slower), "Read slower", "tortoise.fill")
        _ = button("Faster", #selector(faster), "Read faster", "hare.fill")
        _ = button("Smaller", #selector(smaller), "Smaller text", "textformat.size.smaller")
        _ = button("Larger", #selector(bigger), "Larger text", "textformat.size.larger")
        _ = button("Colors", #selector(nextTheme), "Change colors", "circle.lefthalf.filled")

        let barH: CGFloat = 52
        bar.frame = NSRect(x: 0, y: content.bounds.height - barH, width: content.bounds.width, height: barH)
        bar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(bar)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - barH))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.isSelectable = true; tv.isRichText = true
        tv.textContainerInset = NSSize(width: 24, height: 20)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel("Reading text")
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv
        p.contentView = content
        window = p
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = fontSize * 0.35
        return [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: theme.fg, .paragraphStyle: ps]
    }

    func show(_ text: String) {
        if window == nil { build() }
        lastHL = nil
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes()))
        applyTheme()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        window?.orderFrontRegardless()
        setPlaying(true)
    }

    func toggle() {
        if isVisible { window?.orderOut(nil) }
        else {
            if window == nil { build(); show("Hold Command and click text to read it, or Command right-click to read the whole page.") ; setPlaying(false) }
            window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applyTheme() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        tv.backgroundColor = theme.bg
        tv.insertionPointColor = theme.fg
        tv.selectedTextAttributes = [.backgroundColor: theme.hl.withAlphaComponent(0.5), .foregroundColor: theme.hlText]
        ts.setAttributes(baseAttributes(), range: NSRange(location: 0, length: ts.length))
        if let r = lastHL { highlight(r) }
    }

    func highlight(_ r: NSRange) {
        guard let ts = textView?.textStorage, NSMaxRange(r) <= ts.length else { return }
        if let old = lastHL, NSMaxRange(old) <= ts.length {
            ts.addAttributes([.foregroundColor: theme.fg], range: old)
            ts.removeAttribute(.backgroundColor, range: old)
        }
        ts.addAttributes([.backgroundColor: theme.hl, .foregroundColor: theme.hlText], range: r)
        lastHL = r
        textView.scrollRangeToVisible(r)
    }

    func setPlaying(_ on: Bool) {
        playButton?.title = on ? "Pause" : "Read"
        playButton?.image = NSImage(systemSymbolName: on ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        ReaderModel.shared.changed()
    }

    @objc func playPause() {
        if Speaker.shared.isReading { Speaker.shared.pauseOrResume(); setPlaying(!Speaker.shared.isPaused); return }
        guard let tv = textView else { return }
        let all = tv.string as NSString
        var from = tv.selectedRange().location
        if from >= all.length - 1 { from = 0 }
        Reading.shared.start(ReadSource(text: tv.string, element: nil, base: 0), from: from, showWindow: false)
    }
    @objc func stopReading() { Speaker.shared.stop() }
    @objc func slower() { Reading.shared.changeRate(-0.05) }
    @objc func faster() { Reading.shared.changeRate(0.05) }
    @objc func smaller() { prefs.set(max(14, fontSize - 4), forKey: Key.fontSize); applyTheme() }
    @objc func bigger() { prefs.set(min(120, fontSize + 4), forKey: Key.fontSize); applyTheme() }
    @objc func nextTheme() {
        let n = (prefs.integer(forKey: Key.theme) + 1) % themes.count
        prefs.set(n, forKey: Key.theme); applyTheme()
        if !Speaker.shared.isReading { say(themes[n].name) }
    }
    func windowWillClose(_ notification: Notification) { Speaker.shared.stop() }
}

// MARK: - Reading controller

final class Reading {
    static let shared = Reading()
    var source: ReadSource?
    var offset = 0          // where the current utterance starts inside source.text
    var lastWord = NSRange(location: 0, length: 0)
    var currentBlock = -1

    init() {
        Speaker.shared.onWord = { [weak self] r in self?.word(r) }
        Speaker.shared.onDone = { ReaderWindow.shared.setPlaying(false); Overlay.shared.hide() }
    }

    func start(_ src: ReadSource, from: Int = 0, showWindow: Bool = true) {
        source = src
        let ns = src.text as NSString
        offset = max(0, min(from, ns.length))
        lastWord = NSRange(location: offset, length: 0)
        currentBlock = -1
        if showWindow && prefs.bool(forKey: Key.showReader) && ns.length > 60 { ReaderWindow.shared.show(src.text) }
        ReaderWindow.shared.setPlaying(true)
        Speaker.shared.say(ns.substring(from: offset), track: true)
    }

    func word(_ r: NSRange) {
        let full = NSRange(location: r.location + offset, length: r.length)
        lastWord = full
        if ReaderWindow.shared.isVisible { ReaderWindow.shared.highlight(full) }
        guard let src = source else { return }
        if let e = src.element,
           let rect = axRectValue(axParam(e, "AXBoundsForRange", makeRange(src.base + full.location, full.length))) {
            Overlay.shared.show(axRect: rect)
        } else if let bi = blockIndex(at: full.location), bi != currentBlock {
            currentBlock = bi
            let el = src.blocks[bi].element
            DispatchQueue.global(qos: .userInitiated).async {
                AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
                usleep(120_000)
                let f = axFrame(el)
                DispatchQueue.main.async { if let f = f, self.currentBlock == bi { Overlay.shared.show(axRect: f) } }
            }
        }
    }

    func blockIndex(at loc: Int) -> Int? {
        guard let b = source?.blocks, !b.isEmpty else { return nil }
        var found: Int? = nil
        for (i, x) in b.enumerated() where x.range.location <= loc { found = i }
        return found
    }

    /// Jump by paragraph (headingsOnly = false) or by heading.
    func jump(_ dir: Int, headingsOnly: Bool) {
        guard let src = source, !src.blocks.isEmpty else { say(headingsOnly ? "No headings here." : "Nothing is being read."); return }
        let cur = blockIndex(at: lastWord.location) ?? 0
        var i = cur + dir
        while i >= 0 && i < src.blocks.count {
            if !headingsOnly || src.blocks[i].heading > 0 { break }
            i += dir
        }
        guard i >= 0 && i < src.blocks.count else { say(dir > 0 ? "End" : "Beginning"); return }
        if !ReaderWindow.shared.isVisible && prefs.bool(forKey: Key.showReader) { ReaderWindow.shared.show(src.text) }
        start(src, from: src.blocks[i].range.location, showWindow: false)
    }

    /// Restart from the current word (after changing speed or voice).
    func restartHere() {
        guard let src = source, Speaker.shared.isReading else { return }
        start(src, from: lastWord.location, showWindow: false)
    }

    func changeRate(_ delta: Double) {
        let r = max(0.1, min(1.0, prefs.double(forKey: Key.rate) + delta))
        prefs.set(r, forKey: Key.rate)
        if Speaker.shared.isReading { restartHere() } else { say(delta > 0 ? "Faster" : "Slower") }
    }
}

// MARK: - Mouse Echo

final class MouseEcho {
    static let shared = MouseEcho()
    var timer: Timer?
    var lastPoint = NSPoint(x: -1, y: -1)
    var stillSince = Date()
    var handled = false
    var lastText = ""
    var busy = false

    func apply() {
        timer?.invalidate(); timer = nil
        guard prefs.bool(forKey: Key.mouseEcho) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
    }

    func tick() {
        let p = NSEvent.mouseLocation
        if p != lastPoint { lastPoint = p; stillSince = Date(); handled = false; return }
        guard !handled, !busy, Date().timeIntervalSince(stillSince) >= prefs.double(forKey: Key.hoverDelay) else { return }
        handled = true
        if Speaker.shared.isReading { return }
        if NSApp.windows.contains(where: { $0.isVisible && $0 !== Overlay.shared.win && $0.frame.contains(p) }) { return }
        busy = true
        let q = axPoint(p)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = textAt(q)
            DispatchQueue.main.async {
                self.busy = false
                guard let f = found else { return }
                self.lastText = f.text
                say(f.text)
                if let r = f.frame { Overlay.shared.show(axRect: r, for: 1.6) }
            }
        }
    }
}

// MARK: - Key Echo (and tapping Control to stop speech)

final class KeyEcho {
    static let shared = KeyEcho()
    var tap: CFMachPort?
    var word = ""
    var controlAlone = false

    var mode: Int { prefs.integer(forKey: Key.keyEcho) } // 0 off, 1 characters, 2 words, 3 both

    @discardableResult
    func startTap() -> Bool {
        if tap != nil { return true }
        guard CGPreflightListenEventAccess() else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: keyTapCallback, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        log("keyboard listening on")
        return true
    }

    var controlDownAt = Date.distantPast

    func flagsChanged(_ code: Int64, _ flags: CGEventFlags) {
        let isControl = code == 59 || code == 62
        let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
        if isControl && flags.contains(.maskControl) && flags.intersection(others).isEmpty {
            controlAlone = true; controlDownAt = Date()
        } else if isControl && !flags.contains(.maskControl) && controlAlone {
            controlAlone = false
            // Only a quick tap stops speech. Holding Control (to zoom with the magnifier) doesn't.
            if Date().timeIntervalSince(controlDownAt) < 0.5 { Speaker.shared.stop(); Overlay.shared.hide(); log("stopped by tapping Control") }
        } else { controlAlone = false }
    }

    func keyDown(_ code: Int64, _ chars: String, _ flags: CGEventFlags) {
        controlAlone = false
        let m = mode
        guard m != 0 else { return }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { word = ""; return }
        let names: [Int64: String] = [36: "return", 76: "enter", 48: "tab", 51: "delete", 117: "forward delete", 49: "space",
                                      53: "escape", 123: "left", 124: "right", 125: "down", 126: "up",
                                      115: "home", 119: "end", 116: "page up", 121: "page down"]
        let named = names[code]
        var toSay: String? = nil
        if code == 51 { if !word.isEmpty { word.removeLast() } }
        let c = chars
        let isWordChar = named == nil && c.count == 1 && (c.first!.isLetter || c.first!.isNumber || c == "'" || c == "-")
        if isWordChar { word += c }
        if (m & 1) != 0 { toSay = named ?? (c == " " ? "space" : c) }
        if (m & 2) != 0, !isWordChar, code != 51, !word.isEmpty {
            toSay = (m & 1) != 0 ? word + (toSay.map { ", " + $0 } ?? "") : word
            word = ""
        } else if !isWordChar && code != 51 { word = "" }
        if let s = toSay, !s.isEmpty { say(s) }
    }
}

let keyTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = KeyEcho.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    if type == .flagsChanged {
        DispatchQueue.main.async { KeyEcho.shared.flagsChanged(code, flags) }
    } else if type == .keyDown {
        let chars = NSEvent(cgEvent: event)?.characters ?? ""
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !isRepeat { DispatchQueue.main.async { KeyEcho.shared.keyDown(code, chars, flags) } }
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - OCR: reading words in pictures

var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

func askForScreenRecording() {
    _ = CGRequestScreenCaptureAccess()
    say("To read text in pictures, Reader plus needs Screen Recording permission. Turn on Reader plus in System Settings, Privacy and Security, Screen and System Audio Recording. Then quit and reopen Reader plus.")
}

/// Takes a picture of part of the screen (top-left screen coordinates), leaving out Reader+'s own windows.
func captureScreen(_ rect: CGRect, _ done: @escaping (CGImage?) -> Void) {
    guard #available(macOS 14.0, *) else { done(nil); return }
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else { done(nil); return }
            let mine = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: mine)
            let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            guard local.width > 4, local.height > 4 else { done(nil); return }
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.sourceRect = local
            cfg.width = Int(local.width * scale)
            cfg.height = Int(local.height * scale)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            done(img)
        } catch {
            log("screen capture failed: \(error.localizedDescription)")
            done(nil)
        }
    }
}

/// Finds the words in a picture, top to bottom.
func recognizeText(_ img: CGImage, _ done: @escaping (String) -> Void) {
    let req = VNRecognizeTextRequest { r, _ in
        let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
        let sorted = obs.sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.012 ? a.boundingBox.midY > b.boundingBox.midY
                                                                  : a.boundingBox.minX < b.boundingBox.minX
        }
        var out = ""
        for o in sorted {
            guard let line = o.topCandidates(1).first?.string.trimmed, !line.isEmpty else { continue }
            if out.isEmpty { out = line; continue }
            out += ".!?:".contains(out.last ?? " ") ? "\n" + line : " " + line
        }
        done(out)
    }
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    if #available(macOS 13.0, *) { req.automaticallyDetectsLanguage = true }
    DispatchQueue.global(qos: .userInitiated).async {
        do { try VNImageRequestHandler(cgImage: img, options: [:]).perform([req]) }
        catch { log("OCR failed: \(error.localizedDescription)"); done("") }
    }
}

/// Reads the words found in an area of the screen. `fallback` is used if no words are found (e.g. an image description).
func ocrRead(_ rect: CGRect, fallback: String? = nil, showWindow: Bool = true) {
    guard #available(macOS 14.0, *) else { say("Reading text in pictures needs macOS 14 or later."); return }
    guard hasScreenRecording else { askForScreenRecording(); return }
    Overlay.shared.show(axRect: rect, for: 1.2)
    captureScreen(rect) { img in
        guard let img = img else { DispatchQueue.main.async { say("I couldn't look at the screen there.") }; return }
        recognizeText(img) { text in
            DispatchQueue.main.async {
                if !text.trimmed.isEmpty {
                    log("OCR read \(text.count) characters")
                    Reading.shared.start(ReadSource(text: text, element: nil, base: 0), showWindow: showWindow)
                } else if let f = fallback, !f.trimmed.isEmpty {
                    say(f)
                } else {
                    say("I couldn't find any words there.")
                }
            }
        }
    }
}

/// The frame of the window under a point (top-left coordinates), not counting Reader+'s own windows.
func windowFrame(at p: CGPoint) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowOwnerPID as String] as? Int) != me,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.contains(p) else { continue }
        return r
    }
    return nil
}

// MARK: - ⌘-click to read by structure

final class ClickReader {
    static let shared = ClickReader()
    var tap: CFMachPort?
    var swallowUp = false
    var swallowRightUp = false
    var swallowOtherUp = false
    var lastScroll = Date.distantPast

    /// ⌘-right-click: read the whole page or window under the pointer, from the top.
    func readPage(at p: CGPoint) {
        let showWindow = prefs.bool(forKey: Key.clickShowsReader)
        DispatchQueue.global(qos: .userInitiated).async {
            var root: AXUIElement? = nil
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success, let h = hit {
                AXUIElementSetMessagingTimeout(h, 1.5)
                root = ancestors(h, max: 80).first(where: { axString($0, "AXRole") == "AXWebArea" })
                    ?? ancestors(h, max: 80).first(where: { axString($0, "AXRole") == "AXWindow" })
            }
            var src: ReadSource? = nil
            if let r = root {
                let blocks = collectBlocks(r)
                if !blocks.isEmpty { src = sourceFromBlocks(blocks, start: 0, sectionOnly: false, paragraphOnly: false) }
                else { let t = collectText(r); if !t.trimmed.isEmpty { src = ReadSource(text: t, element: nil, base: 0) } }
            }
            DispatchQueue.main.async {
                if let s = src, !s.text.trimmed.isEmpty { Reading.shared.start(s, showWindow: showWindow); return }
                if let w = windowFrame(at: p) { ocrRead(w, showWindow: showWindow) }
                else { ocrRead(CGRect(x: p.x - 450, y: p.y - 250, width: 900, height: 500), showWindow: showWindow) }
            }
        }
    }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        var mask: UInt64 = 0
        for t: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                               .otherMouseDown, .otherMouseUp, .scrollWheel, .flagsChanged, .keyDown] {
            mask |= 1 << UInt64(t.rawValue)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: clickTapCallback, userInfo: nil) else {
            log("click tap not available"); return
        }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        log("click-to-read on")
    }

    static func modifiersMatch(_ f: CGEventFlags) -> Bool {
        let mode = prefs.integer(forKey: Key.clickMode)
        guard mode != 0, f.contains(.maskCommand), !f.contains(.maskControl), !f.contains(.maskShift) else { return false }
        return mode == 2 ? f.contains(.maskAlternate) : !f.contains(.maskAlternate)
    }

    func read(at p: CGPoint) {
        let showWindow = prefs.bool(forKey: Key.clickShowsReader)
        DispatchQueue.global(qos: .userInitiated).async {
            // Pictures: read the words in them.
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success, let h = hit {
                AXUIElementSetMessagingTimeout(h, 1.0)
                let up = ancestors(h, max: 6)
                let img = up.prefix(4).first(where: { axString($0, "AXRole") == "AXImage" })
                let link = up.first(where: { axString($0, "AXRole") == "AXLink" })
                let linkWords = link.map { collectText($0).trimmed } ?? ""
                if let im = img, linkWords.count < 3, let f = axFrame(im), f.width >= 24, f.height >= 24 {
                    let desc = axString(im, "AXDescription") ?? axString(im, "AXTitle")
                    DispatchQueue.main.async { ocrRead(f, fallback: desc.map { "Image: \($0)" }, showWindow: showWindow) }
                    return
                }
            }
            let t0 = Date()
            let src = readSourceAt(p)
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            log(String(format: "click in %@: %d blocks, %d chars, %.1fs, starts \"%@\"", app, src?.blocks.count ?? 0,
                       (src?.text ?? "").count, Date().timeIntervalSince(t0), String((src?.text ?? "nothing").prefix(40))))
            DispatchQueue.main.async {
                if let s = src, !s.text.trimmed.isEmpty { Reading.shared.start(s, showWindow: showWindow); return }
                // Nothing in the page's text there — look at the screen instead.
                ocrRead(CGRect(x: p.x - 450, y: p.y - 140, width: 900, height: 280), showWindow: showWindow)
            }
        }
    }
}

let clickTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = ClickReader.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // Scrolling or clicking while Control is held (zooming, Control-click) isn't a "tap" of Control.
    if (type == .scrollWheel || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown),
       event.flags.contains(.maskControl) {
        DispatchQueue.main.async { KeyEcho.shared.controlAlone = false }
    }
    if type == .flagsChanged || type == .keyDown {
        // Tap Control by itself to stop talking, like VoiceOver. Only used when Key Echo's listener isn't running.
        if KeyEcho.shared.tap == nil {
            let code = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
            if type == .flagsChanged { DispatchQueue.main.async { KeyEcho.shared.flagsChanged(code, flags) } }
            else { DispatchQueue.main.async { KeyEcho.shared.controlAlone = false } }
        }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown, ClickReader.modifiersMatch(event.flags) {
        let p = event.location
        let own = ownWindowHit(NSPoint(x: p.x, y: primaryHeight - p.y))
        if own.inOwnWindow {
            guard let tv = own.textView else { return Unmanaged.passUnretained(event) }
            let ns = tv.string as NSString
            guard ns.length > 0 else { return Unmanaged.passUnretained(event) }
            let para = ns.paragraphRange(for: NSRange(location: min(own.index, ns.length - 1), length: 0))
            ClickReader.shared.swallowUp = true
            DispatchQueue.main.async {
                if tv === ReaderWindow.shared.textView {
                    Reading.shared.start(ReadSource(text: tv.string, element: nil, base: 0), from: para.location, showWindow: false)
                } else {
                    let r = prefs.integer(forKey: Key.paragraphMode) == 1 ? para : NSRange(location: para.location, length: ns.length - para.location)
                    Reading.shared.start(ReadSource(text: ns.substring(with: r), element: nil, base: 0), showWindow: false)
                }
            }
            return nil
        }
        switch clickUse(p) {
        case .read:
            ClickReader.shared.swallowUp = true
            ClickReader.shared.read(at: p)
            return nil // the click is used for reading, so the page doesn't get it
        case .readAndPass:
            ClickReader.shared.read(at: p)
            return Unmanaged.passUnretained(event)
        case .ignore:
            break
        }
    }
    if type == .leftMouseUp && ClickReader.shared.swallowUp {
        ClickReader.shared.swallowUp = false
        return nil
    }
    let cr = ClickReader.shared
    let talking = Speaker.shared.isReading
    // ⌘-right-click: stop while talking, otherwise read the whole page or window.
    if type == .rightMouseDown, ClickReader.modifiersMatch(event.flags) {
        let p = event.location
        if talking || Speaker.shared.synth.isSpeaking {
            cr.swallowRightUp = true
            DispatchQueue.main.async {
                Speaker.shared.stop()
                Overlay.shared.hide()
                ReaderWindow.shared.setPlaying(false)
                log("stopped by Command right-click")
            }
            return nil
        }
        if !ownWindowHit(NSPoint(x: p.x, y: primaryHeight - p.y)).inOwnWindow {
            cr.swallowRightUp = true
            cr.readPage(at: p)
            return nil
        }
    }
    if type == .rightMouseUp && cr.swallowRightUp { cr.swallowRightUp = false; return nil }
    // ⌘ + the mouse's Back / Forward side buttons: previous / next paragraph while reading.
    if type == .otherMouseDown, talking, ClickReader.modifiersMatch(event.flags) {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if button == 3 || button == 4 {
            cr.swallowOtherUp = true
            DispatchQueue.main.async { Reading.shared.jump(button == 4 ? 1 : -1, headingsOnly: false) }
            return nil
        }
    }
    if type == .otherMouseUp && cr.swallowOtherUp { cr.swallowOtherUp = false; return nil }
    // ⌘ + scroll wheel: faster (up) / slower (down) while reading.
    if type == .scrollWheel, talking, ClickReader.modifiersMatch(event.flags) {
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if dy != 0 && momentum == 0 && Date().timeIntervalSince(cr.lastScroll) > 0.35 {
            cr.lastScroll = Date()
            DispatchQueue.main.async { Reading.shared.changeRate(dy > 0 ? 0.05 : -0.05) }
        }
        return nil
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Global hotkeys (not used: Reader+ is mouse-first)

var hotKeyActions: [UInt32: () -> Void] = [:]
var hotKeyRefs: [EventHotKeyRef] = []

func installHotKeys(_ list: [(Int, () -> Void)]) {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        let id = hk.id
        DispatchQueue.main.async { hotKeyActions[id]?() }
        return noErr
    }, 1, &spec, nil, nil)
    for (i, item) in list.enumerated() {
        let id = UInt32(i + 1)
        hotKeyActions[id] = item.1
        var ref: EventHotKeyRef?
        let hkid = EventHotKeyID(signature: OSType(0x52445250), id: id) // 'RDRP'
        let st = RegisterEventHotKey(UInt32(item.0), UInt32(controlKey | optionKey), hkid, GetApplicationEventTarget(), 0, &ref)
        if st == noErr, let r = ref { hotKeyRefs.append(r) } else { log("hotkey \(item.0) not available (\(st))") }
    }
}

// MARK: - Guided tour (Ubuntu-style welcome slides, read aloud)

struct Slide {
    let symbol: String
    let color: NSColor
    let title: String
    let body: String
    var keys: [String] = []          // shown as key caps
    var spokenKeys: String? = nil    // how the shortcut is said
    var practice: String? = nil      // a box to try the feature in
    var permissions = false          // shows permission status and buttons
}

let slides: [Slide] = [
    Slide(symbol: "text.bubble.fill", color: rgb(0.96, 0.45, 0.15), title: "Welcome to Reader+",
          body: "Reader+ reads your screen out loud using the Mac's own voices, the same ones VoiceOver uses, without turning VoiceOver on. Your magnifier stays exactly as it is. Reader+ just adds speech.\n\nThere are no keyboard shortcuts to learn. You hold the Command key and use your mouse.\n\nPress Return or click Next to go on."),
    Slide(symbol: "lock.open.fill", color: rgb(0.2, 0.7, 0.35), title: "Permissions, and why",
          body: "macOS keeps apps from reading other apps' text unless you allow it.\n\nAccessibility lets Reader+ see the words in Safari, Chrome, Mail and your other apps, and notice your Command-clicks. Screen Recording lets Reader+ read the words in pictures. Input Monitoring is only needed for Key Echo.",
          permissions: true),
    Slide(symbol: "list.bullet.indent", color: rgb(0.6, 0.35, 0.95), title: "⌘-click to read",
          body: "Hold Command and click a heading to hear that heading and everything under it, up to the next heading. Command-click a paragraph to hear everything from there to the end, without stopping. This works in AI chat apps too, so you can hear a whole reply.\n\nLinks work too: Command-click one to hear it and everything after it, like the rest of a list of videos. It starts exactly where you click, even far down a long page. In other apps, Command-click reads text, buttons and list items.",
          keys: ["⌘ Command", "Click"], spokenKeys: "Command click",
          practice: "Try it. Hold Command and click this paragraph. Reader+ reads from here to the end of this box.\n\nThis is the second paragraph. Reading carries on into it by itself.\n\nAnd here's a third paragraph, so you can hear it keep going."),
    Slide(symbol: "bubble.left.and.text.bubble.right.fill", color: rgb(0.25, 0.45, 0.95), title: "Whole posts on social media",
          body: "On Facebook, Instagram, X, Threads, LinkedIn, Reddit and similar sites, Command-click a post and Reader+ reads the whole post. It presses See more for you, so you don't have to find it.\n\nIt skips buttons like Like, Comment and Share, so you only hear what people wrote.",
          keys: ["⌘ Command", "Click"], spokenKeys: "Command click"),
    Slide(symbol: "text.viewfinder", color: rgb(0.15, 0.6, 0.95), title: "Words in pictures",
          body: "Command-click a picture, like a screenshot, a meme or a scanned page, and Reader+ reads the words in it. It uses the text recognition built into your Mac, so nothing leaves your computer.",
          keys: ["⌘ Command", "Click"], spokenKeys: "Command click"),
    Slide(symbol: "doc.text.magnifyingglass", color: rgb(0.1, 0.65, 0.7), title: "Read a whole page",
          body: "Hold Command and right-click anywhere on a page or window to hear all of it from the top. If it has no real text, Reader+ reads the words it sees on the screen instead.\n\nWhile Reader+ is talking, Command right-click stops it. Tapping the Control key stops it too.",
          keys: ["⌘ Command", "Right-click"], spokenKeys: "Command right-click"),
    Slide(symbol: "computermouse.fill", color: rgb(0.6, 0.35, 0.95), title: "Move and change speed",
          body: "While Reader+ is reading, hold Command and press the Back button on the side of your mouse to go to the previous paragraph, or Forward for the next one.\n\nHold Command and scroll up to read faster, or down to read slower.",
          keys: ["⌘ Command", "Side buttons or scroll"], spokenKeys: "Command with the mouse side buttons or the scroll wheel"),
    Slide(symbol: "speaker.slash.fill", color: rgb(0.96, 0.45, 0.15), title: "Stop talking",
          body: "To stop talking, just tap the Control key by itself, exactly like VoiceOver.\n\nYou can pick a voice in the Reader+ window. Enhanced and Premium voices sound the most natural.",
          keys: ["⌃ Control"], spokenKeys: "Control"),
    Slide(symbol: "slider.horizontal.3", color: rgb(0.95, 0.75, 0.1), title: "Everything else",
          body: "Mouse Echo reads what the pointer rests on. Key Echo says what you type. The reading window shows big, high-contrast text with each word highlighted.\n\nYou turn these on in the Reader+ window or from the Reader+ icon in the menu bar, not with keys. If you ever want lots of keyboard commands, that's what VoiceOver is for."),
    Slide(symbol: "checkmark.seal.fill", color: rgb(0.2, 0.7, 0.35), title: "You're ready",
          body: "Remember three things. Command-click to read from there on. Command right-click to stop, or to read the whole page when nothing is playing. Tapping Control stops it too.\n\nYou can take this tour again from the Reader+ window, under General."),
]

final class TourController: NSObject, NSWindowDelegate {
    static let shared = TourController()
    var window: NSWindow?
    var index = 0
    var content = NSView()
    var dots = NSStackView()
    var backButton: NSButton!
    var nextButton: NSButton!
    var narrate = true
    var statusTimer: Timer?
    var axLabel: NSTextField?
    var imLabel: NSTextField?
    var srLabel: NSTextField?

    func show(from start: Int = 0) {
        if window == nil { build() }
        index = start
        render()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Reader+ Tour"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self

        let root = NSView()
        w.contentView = root

        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        // Bottom bar: Back · dots · Repeat · Narration · Next
        let bar = NSStackView()
        bar.orientation = .horizontal; bar.spacing = 14
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)

        func bigButton(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded; b.controlSize = .large
            b.font = .systemFont(ofSize: 15)
            return b
        }
        backButton = bigButton("Back", #selector(back))
        backButton.keyEquivalent = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
        backButton.keyEquivalentModifierMask = []
        nextButton = bigButton("Continue", #selector(next))
        nextButton.keyEquivalent = "\r"
        let repeatButton = bigButton("Repeat", #selector(repeatSlide))
        repeatButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        repeatButton.imagePosition = .imageLeading
        repeatButton.bezelStyle = .inline
        repeatButton.keyEquivalent = "r"; repeatButton.keyEquivalentModifierMask = []
        let narration = NSButton(checkboxWithTitle: "Read slides aloud", target: self, action: #selector(toggleNarration(_:)))
        narration.state = .on
        narration.font = .systemFont(ofSize: 13)

        dots.orientation = .horizontal; dots.spacing = 8
        let spacerL = NSView(), spacerR = NSView()
        spacerL.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerR.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [backButton!, spacerL, dots, spacerR, narration, repeatButton, nextButton!] as [NSView] { bar.addArrangedSubview(v) }

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 60),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -60),
            content.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            bar.heightAnchor.constraint(equalToConstant: 44),
        ])
        window = w
    }

    func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        l.preferredMaxLayoutWidth = 760
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 760).isActive = true
        return l
    }

    func render() {
        statusTimer?.invalidate(); statusTimer = nil
        axLabel = nil; imLabel = nil; srLabel = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        let s = slides[index]

        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
        ])

        // Large symbol on a soft rounded square, like Apple's welcome screens
        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.backgroundColor = s.color.withAlphaComponent(0.15).cgColor
        circle.layer?.cornerRadius = 26
        circle.layer?.cornerCurve = .continuous
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.widthAnchor.constraint(equalToConstant: 104).isActive = true
        circle.heightAnchor.constraint(equalToConstant: 104).isActive = true
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 50, weight: .medium).applying(.init(paletteColors: [s.color])))
        iv.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(iv)
        NSLayoutConstraint.activate([iv.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
                                     iv.centerYAnchor.constraint(equalTo: circle.centerYAnchor)])
        stack.addArrangedSubview(circle)

        stack.addArrangedSubview(label(s.title, size: 30, weight: .bold))

        if !s.keys.isEmpty {
            let keys = NSStackView(); keys.orientation = .horizontal; keys.spacing = 8
            for (i, k) in s.keys.enumerated() {
                if i > 0 { keys.addArrangedSubview(label("+", size: 17, weight: .regular, color: .tertiaryLabelColor)) }
                let cap = label(" \(k) ", size: 17, weight: .medium, color: .labelColor)
                cap.drawsBackground = true
                cap.backgroundColor = .controlBackgroundColor
                cap.wantsLayer = true; cap.layer?.cornerRadius = 6; cap.layer?.masksToBounds = true
                cap.layer?.borderWidth = 1; cap.layer?.borderColor = NSColor.separatorColor.cgColor
                keys.addArrangedSubview(cap)
            }
            stack.addArrangedSubview(keys)
        }

        stack.addArrangedSubview(label(s.body, size: 17, weight: .regular, color: .secondaryLabelColor))

        if let practice = s.practice {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalToConstant: 740).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 740, height: 130))
            tv.isEditable = false; tv.isSelectable = true
            tv.backgroundColor = .textBackgroundColor
            tv.textContainerInset = NSSize(width: 14, height: 12)
            tv.autoresizingMask = [.width]
            tv.textStorage?.setAttributedString(NSAttributedString(string: practice, attributes: [
                .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.textColor]))
            tv.setAccessibilityLabel("Practice text")
            scroll.documentView = tv
            scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10; scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = NSColor.separatorColor.cgColor
            stack.addArrangedSubview(scroll)
        }

        if s.permissions {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 24
            let col1 = NSStackView(); col1.orientation = .vertical; col1.spacing = 8
            let col2 = NSStackView(); col2.orientation = .vertical; col2.spacing = 8
            let ax = label("", size: 18, weight: .semibold); axLabel = ax
            let im = label("", size: 18, weight: .semibold); imLabel = im
            let b1 = NSButton(title: "Turn On Accessibility", target: self, action: #selector(openAccessibility))
            let b2 = NSButton(title: "Turn On Input Monitoring", target: self, action: #selector(openInputMonitoring))
            let b3 = NSButton(title: "Turn On Screen Recording", target: self, action: #selector(openScreenRecording))
            b3.bezelStyle = .rounded; b3.controlSize = .large
            let sr = label("", size: 17, weight: .semibold); srLabel = sr
            for b in [b1, b2] { b.bezelStyle = .rounded; b.controlSize = .large }
            col1.addArrangedSubview(ax); col1.addArrangedSubview(b1)
            col2.addArrangedSubview(im); col2.addArrangedSubview(b2)
            let col3 = NSStackView(); col3.orientation = .vertical; col3.spacing = 8
            col3.addArrangedSubview(sr); col3.addArrangedSubview(b3)
            row.addArrangedSubview(col1); row.addArrangedSubview(col2); row.addArrangedSubview(col3)
            stack.addArrangedSubview(row)
            updatePermissions()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updatePermissions() }
        }

        // Dots
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in 0..<slides.count {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.cornerRadius = 6
            d.layer?.cornerRadius = 4
            d.layer?.backgroundColor = (i == index ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: i == index ? 20 : 8).isActive = true
            d.heightAnchor.constraint(equalToConstant: 8).isActive = true
            dots.addArrangedSubview(d)
        }
        dots.setAccessibilityLabel("Slide \(index + 1) of \(slides.count)")

        backButton.isEnabled = index > 0
        nextButton.title = index == slides.count - 1 ? "Get Started" : "Continue"
        window?.title = "Reader+ Tour — \(index + 1) of \(slides.count)"
        speak()
    }

    func spokenText() -> String {
        let s = slides[index]
        var t = "\(s.title.replacingOccurrences(of: "⌘-click", with: "Command click")). "
        if let k = s.spokenKeys { t += "How: \(k). " }
        t += s.body.replacingOccurrences(of: "\n\n", with: " ")
        if s.permissions {
            t += " Right now, Accessibility is \(AXIsProcessTrusted() ? "on" : "off"), Input Monitoring is \(CGPreflightListenEventAccess() ? "on" : "off"), and Screen Recording is \(CGPreflightScreenCaptureAccess() ? "on" : "off")."
        }
        if s.practice != nil { t += " The practice box is in the middle of the window." }
        return t
    }

    func speak() { if narrate { say(spokenText()) } else { Speaker.shared.stop() } }

    func updatePermissions() {
        let a = AXIsProcessTrusted(), m = CGPreflightListenEventAccess()
        axLabel?.stringValue = a ? "Accessibility: On" : "Accessibility: Off"
        axLabel?.textColor = a ? .systemGreen : .systemOrange
        imLabel?.stringValue = m ? "Input Monitoring: On" : "Input Monitoring: Off"
        imLabel?.textColor = m ? .systemGreen : .systemOrange
        let r = CGPreflightScreenCaptureAccess()
        srLabel?.stringValue = r ? "Screen Recording: On" : "Screen Recording: Off"
        srLabel?.textColor = r ? .systemGreen : .systemOrange
    }

    @objc func next() {
        if index < slides.count - 1 { index += 1; render() }
        else { finish() }
    }
    @objc func back() { if index > 0 { index -= 1; render() } }
    @objc func repeatSlide() { if narrate { say(spokenText()) } }
    @objc func toggleNarration(_ sender: NSButton) {
        narrate = sender.state == .on
        if narrate { say(spokenText()) } else { Speaker.shared.stop() }
    }
    @objc func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        say("In System Settings, turn on Reader plus under Accessibility. This tour will show On when it's done.")
    }
    @objc func openScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        say("In System Settings, turn on Reader plus under Screen and System Audio Recording. Then quit and reopen Reader plus.")
    }
    @objc func openInputMonitoring() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        say("In System Settings, turn on Reader plus under Input Monitoring. Then quit and reopen Reader plus so Key Echo can start.")
    }
    func finish() {
        prefs.set(true, forKey: "tourSeen")
        say("That's the tour. Reader plus is in the menu bar whenever you need it.")
        window?.orderOut(nil)
        statusTimer?.invalidate()
    }
    func windowWillClose(_ notification: Notification) {
        prefs.set(true, forKey: "tourSeen")
        statusTimer?.invalidate()
        Speaker.shared.stop()
    }
}

// MARK: - Control window (the app's main interface)

/// Remembers the last app you used, so buttons in the control window act on it.
final class PreviousApp {
    static let shared = PreviousApp()
    var app: NSRunningApplication?
    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               a.processIdentifier != ProcessInfo.processInfo.processIdentifier { self.app = a }
        }
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != ProcessInfo.processInfo.processIdentifier { app = f }
        // Ask every app you switch to for its full text (Electron/Chromium apps hide it until asked).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { exposeText(a.processIdentifier) }
        }
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { exposeText(a.processIdentifier) }
    }
    /// Switch back to the app you were using, then do something there.
    func run(_ action: @escaping () -> Void) {
        if NSApp.isActive, let a = app {
            a.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
        } else { action() }
    }
}

var appDel: AppDelegate { NSApp.delegate as! AppDelegate }

/// Keeps the SwiftUI window in step with settings changed elsewhere (hotkeys, menu bar).
final class ReaderModel: ObservableObject {
    static let shared = ReaderModel()
    @Published var tick = 0
    private var timer: Timer?
    func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick &+= 1 }
    }
    func changed() { objectWillChange.send() }
    func bool(_ key: String, set: ((Bool) -> Void)? = nil) -> Binding<Bool> {
        Binding(get: { prefs.bool(forKey: key) },
                set: { v in if let s = set { s(v) } else { prefs.set(v, forKey: key) }; self.changed() })
    }
    func int(_ key: String, set: ((Int) -> Void)? = nil) -> Binding<Int> {
        Binding(get: { prefs.integer(forKey: key) },
                set: { v in if let s = set { s(v) } else { prefs.set(v, forKey: key) }; self.changed() })
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case general, reading, click, echo, voice, display, permissions
    var id: Pane { self }
    var title: String {
        switch self {
        case .general: return "General"
        case .reading: return "Reading"
        case .click: return "Click to Read"
        case .echo: return "Mouse & Key Echo"
        case .voice: return "Voice"
        case .display: return "Display"
        case .permissions: return "Permissions"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .reading: return "text.bubble.fill"
        case .click: return "cursorarrow.click.2"
        case .echo: return "keyboard.fill"
        case .voice: return "waveform"
        case .display: return "textformat.size"
        case .permissions: return "hand.raised.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: return .gray
        case .reading: return .orange
        case .click: return .purple
        case .echo: return .indigo
        case .voice: return .pink
        case .display: return .blue
        case .permissions: return .green
        }
    }
}

struct PaneIcon: View {
    let pane: Pane
    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pane.color.gradient))
    }
}

struct KeysText: View {
    let keys: String
    var body: some View { Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary) }
}

let shortcutList: [(String, String)] = [
    ("Read a heading, paragraph, post or picture", "⌘-click"),
    ("Read the whole page or window", "⌘-right-click"),
    ("Stop talking", "⌘-right-click while reading"),
    ("Previous / next paragraph", "⌘ + mouse Back / Forward"),
    ("Faster / slower", "⌘ + scroll up / down"),
    ("Stop talking", "Tap ⌃ Control"),
]

struct ControlView: View {
    @ObservedObject var model = ReaderModel.shared
    @State private var pane: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label { Text(p.title) } icon: { PaneIcon(pane: p) }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 165, max: 200)
        } detail: {
            detail(pane ?? .general)
                .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 900, minHeight: 380, idealHeight: 440, maxHeight: 700)
        .onAppear { model.startTicking() }
    }

    @ViewBuilder func detail(_ p: Pane) -> some View {
        switch p {
        case .general: GeneralPane()
        case .reading: ReadingPane()
        case .click: ClickPane()
        case .echo: EchoPane()
        case .voice: VoicePane()
        case .display: DisplayPane()
        case .permissions: PermissionsPane()
        }
    }
}

struct GeneralPane: View {
    @ObservedObject var model = ReaderModel.shared
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reader+").font(.title.bold())
                        Text("Reads your screen aloud with your Mac's own voices, without turning on VoiceOver.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                Toggle("Open Reader+ when you log in", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { _ in appDel.toggleLogin(); model.changed() }))
                LabeledContent("Guided tour") { Button("Take the Tour…") { TourController.shared.show() } }
                LabeledContent("Spoken help") { Button("Play") { appDel.help() } }
            }
            Section {
                ForEach(shortcutList.indices, id: \.self) { i in
                    LabeledContent(shortcutList[i].0) { KeysText(keys: shortcutList[i].1) }
                }
            } header: { Text("Mouse Commands") } footer: {
                Text("If you picked ⌥⌘-Click under Click to Read, hold Option as well. That's all there is to learn; for lots of keyboard commands, use VoiceOver.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ReadingPane: View {
    @ObservedObject var model = ReaderModel.shared
    func row(_ title: String, _ symbol: String, _ keys: String, _ action: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 12) { KeysText(keys: keys); Button("Read", action: action) }
        } label: { Label(title, systemImage: symbol) }
    }
    var body: some View {
        Form {
            Section {
                row("Selected text", "text.cursor", "") { PreviousApp.shared.run { appDel.readSelection() } }
                row("From the cursor, or the whole page", "doc.text", "") { PreviousApp.shared.run { appDel.readFromFocus() } }
                row("Clipboard", "doc.on.clipboard", "") { appDel.readClipboard() }
                row("Words in pictures under the pointer", "text.viewfinder", "") { appDel.readScreenUnderPointer() }
            } header: { Text("Read") } footer: {
                Text("These buttons switch back to the app you were using, then read from it.").foregroundStyle(.secondary)
            }
            Section("Playback") {
                HStack {
                    Button {
                        Speaker.shared.pauseOrResume(); model.changed()
                    } label: {
                        Label(Speaker.shared.isPaused ? "Resume" : "Pause", systemImage: Speaker.shared.isPaused ? "play.fill" : "pause.fill")
                    }
                    Button { Speaker.shared.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    Spacer()
                }
                LabeledContent("Stop at any time") { KeysText(keys: "Tap ⌃ Control") }
                LabeledContent("Or") { KeysText(keys: "⌘-right-click") }
                LabeledContent("Faster / slower") { KeysText(keys: "⌘ + scroll") }
            }
        }
        .formStyle(.grouped)
    }
}

struct ClickPane: View {
    @ObservedObject var model = ReaderModel.shared
    var body: some View {
        Form {
            Section {
                Picker("Click to read with", selection: model.int(Key.clickMode)) {
                    Text("Off").tag(0); Text("⌘-Click").tag(1); Text("⌥⌘-Click").tag(2)
                }
                Picker("Clicking a paragraph reads", selection: model.int(Key.paragraphMode)) {
                    Text("The article from there to the end").tag(0)
                    Text("Just that paragraph").tag(1)
                }
                .pickerStyle(.radioGroup)
                Toggle("Open the reading window when I click", isOn: model.bool(Key.clickShowsReader))
            } footer: {
                Text("Command right-click reads the whole page or window, and stops Reader+ while it's talking. While reading, hold Command and use your mouse's Back and Forward buttons to move by paragraph, or the scroll wheel to change the speed. Clicking a heading reads the heading and everything under it, up to the next heading of the same level. On Facebook, Instagram, X and other social sites, clicking a post opens See more and reads the whole post. Clicking a picture reads the words in it. Command-clicking a link reads it and carries on down the page, instead of opening it. Buttons and boxes say what they are. In Finder, Mail and other lists, Command-click still selects as usual and Reader+ reads the item. Clicks read aloud without opening the reading window unless you turn it on above.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct EchoPane: View {
    @ObservedObject var model = ReaderModel.shared
    let delays = [0.25, 0.45, 0.8, 1.2]
    var body: some View {
        Form {
            Section {
                Toggle("Mouse Echo", isOn: model.bool(Key.mouseEcho, set: { v in
                    if v != prefs.bool(forKey: Key.mouseEcho) { appDel.toggleMouseEcho() }
                }))
                Picker("Wait before speaking", selection: Binding<Int>(
                    get: {
                        let d = prefs.double(forKey: Key.hoverDelay)
                        return delays.indices.min(by: { abs(delays[$0] - d) < abs(delays[$1] - d) }) ?? 1
                    },
                    set: { prefs.set(delays[$0], forKey: Key.hoverDelay); model.changed() })) {
                    Text("Short").tag(0); Text("Normal").tag(1); Text("Long").tag(2); Text("Very long").tag(3)
                }
                .disabled(!prefs.bool(forKey: Key.mouseEcho))
            } footer: {
                Text("Rest the pointer on a button, menu, link or line of text to hear it.").foregroundStyle(.secondary)
            }
            Section {
                Picker("Key Echo", selection: model.int(Key.keyEcho, set: { appDel.setKeyEcho($0) })) {
                    Text("Off").tag(0); Text("Characters").tag(1); Text("Words").tag(2); Text("Both").tag(3)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Words are spoken when you type a space or punctuation. Key Echo needs Input Monitoring permission.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct VoicePane: View {
    @ObservedObject var model = ReaderModel.shared
    func title(_ v: AVSpeechSynthesisVoice) -> String {
        v.name + (v.quality == .premium ? " (Premium)" : (v.quality == .enhanced ? " (Enhanced)" : ""))
    }
    var body: some View {
        let rate = prefs.double(forKey: Key.rate)
        Form {
            Section {
                Picker("Voice", selection: Binding<String>(
                    get: { prefs.string(forKey: Key.voice) ?? "" },
                    set: { v in
                        if v.isEmpty { prefs.removeObject(forKey: Key.voice) } else { prefs.set(v, forKey: Key.voice) }
                        model.changed()
                        if Speaker.shared.isReading { Reading.shared.restartHere() } else { say("This is my voice.") }
                    })) {
                    Text("System Voice").tag("")
                    Divider()
                    ForEach(readingVoices(), id: \.identifier) { v in Text(title(v)).tag(v.identifier) }
                }
                LabeledContent("Speed") {
                    HStack {
                        Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { prefs.double(forKey: Key.rate) },
                                              set: { prefs.set(($0 * 20).rounded() / 20, forKey: Key.rate); model.changed() }),
                               in: 0.1...1.0,
                               onEditingChanged: { editing in
                                   if !editing { if Speaker.shared.isReading { Reading.shared.restartHere() } else { say("This is my speed.") } }
                               })
                        Image(systemName: "hare.fill").foregroundStyle(.secondary)
                        Text("\(Int((rate * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .frame(maxWidth: 360)
                }
                HStack {
                    Spacer()
                    Button("Test Voice") { say("Hello. This is how Reader plus sounds.") }
                    Button("Get More Voices…") { appDel.moreVoices() }
                }
            } footer: {
                Text("Reader+ uses the same voices as VoiceOver. Enhanced and Premium voices sound the most natural.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DisplayPane: View {
    @ObservedObject var model = ReaderModel.shared
    var body: some View {
        let size = prefs.double(forKey: Key.fontSize)
        let theme = themes[max(0, min(prefs.integer(forKey: Key.theme), themes.count - 1))]
        Form {
            Section("On Screen") {
                Toggle("Outline the text being read", isOn: model.bool(Key.screenHighlight, set: { v in
                    prefs.set(v, forKey: Key.screenHighlight); if !v { Overlay.shared.hide() }
                }))
                Toggle("Open the reading window when reading", isOn: model.bool(Key.showReader))
            }
            Section {
                Picker("Colors", selection: model.int(Key.theme, set: { prefs.set($0, forKey: Key.theme); ReaderWindow.shared.applyTheme() })) {
                    ForEach(themes.indices, id: \.self) { i in Text(themes[i].name).tag(i) }
                }
                LabeledContent("Text size") {
                    HStack {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { prefs.double(forKey: Key.fontSize) },
                                              set: { prefs.set($0, forKey: Key.fontSize); ReaderWindow.shared.applyTheme(); model.changed() }),
                               in: 16...96, step: 2)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        Text("\(Int(size)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    .frame(maxWidth: 360)
                }
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: min(size, 44), weight: .medium))
                    .foregroundStyle(Color(nsColor: theme.fg))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: theme.bg)))
                HStack { Spacer(); Button("Show Reading Window") { ReaderWindow.shared.toggle() } }
            } header: { Text("Reading Window") }
        }
        .formStyle(.grouped)
    }
}

struct PermissionsPane: View {
    @ObservedObject var model = ReaderModel.shared
    func permission(_ title: String, _ why: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        LabeledContent {
            if on { Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Button("Turn On…", action: action) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(why).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    var body: some View {
        let _ = model.tick
        Form {
            Section {
                permission("Accessibility", "Lets Reader+ see the text in your other apps.", on: AXIsProcessTrusted()) {
                    TourController.shared.openAccessibility()
                }
                permission("Input Monitoring", "Lets Key Echo hear what you type.", on: CGPreflightListenEventAccess()) {
                    TourController.shared.openInputMonitoring()
                }
                permission("Screen Recording", "Lets Reader+ read the words in pictures and scanned pages.", on: CGPreflightScreenCaptureAccess()) {
                    TourController.shared.openScreenRecording()
                }
            } footer: {
                Text("macOS asks you to allow these in System Settings › Privacy & Security. After turning on Input Monitoring or Screen Recording, quit and reopen Reader+.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

final class ControlWindow: NSObject, NSWindowDelegate {
    static let shared = ControlWindow()
    var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: ControlView())
            if #available(macOS 13.0, *) { host.sizingOptions = [] }
            let w = NSWindow(contentViewController: host)
            w.title = "Reader+"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbar = NSToolbar(identifier: "ReaderPlusToolbar")
            w.toolbarStyle = .unified
            // A small window, never full screen.
            w.collectionBehavior = [.fullScreenNone]
            w.contentMinSize = NSSize(width: 540, height: 380)
            w.contentMaxSize = NSSize(width: 900, height: 700)
            w.setContentSize(NSSize(width: 620, height: 440))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("ReaderPlusSmallWindow")
            // If a saved size is bigger than the small window, go back to the small size.
            if w.frame.width > 900 || w.frame.height > 760 {
                w.setContentSize(NSSize(width: 620, height: 440)); w.center()
            }
            window = w
        }
        ReaderModel.shared.changed()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!

    let helpText = """
    Reader plus works with the mouse while you hold the Command key. \
    Command-click a heading to hear it and everything under it. Command-click a paragraph to hear the article from there. \
    Command-click a social media post to hear the whole post, or a picture to hear the words in it. \
    Command right-click to hear the whole page or window. While Reader plus is talking, Command right-click stops it. \
    Hold Command and press the Back or Forward button on the side of your mouse to go to the previous or next paragraph. \
    Hold Command and scroll up to read faster, or down to read slower. \
    Tap the Control key by itself to stop talking. \
    Everything else, like Mouse Echo, Key Echo and the reading window, is in the Reader plus window and the menu bar icon.
    """

    func applicationDidFinishLaunching(_ n: Notification) {
        registerDefaults()
        AXUIElementSetMessagingTimeout(systemWide, 0.6)
        _ = Reading.shared
        _ = PreviousApp.shared
        buildMenu()
        buildMainMenu()
        ClickReader.shared.start()
        MouseEcho.shared.apply()
        KeyEcho.shared.startTap()
        log("started; accessibility \(AXIsProcessTrusted() ? "on" : "off"), keyboard \(CGPreflightListenEventAccess() ? "on" : "off"), screen \(CGPreflightScreenCaptureAccess() ? "on" : "off")")

        ControlWindow.shared.show()
        if !prefs.bool(forKey: "tourSeen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { TourController.shared.show() }
            if !AXIsProcessTrusted() { waitForTrust() }
        } else if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            say("Reader plus is on. To let it read other apps, it needs Accessibility permission. In the window that just opened, choose Open System Settings, then turn on Reader plus.")
            waitForTrust()
        } else {
            say("Reader plus ready. Hold Command and click to read.")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ControlWindow.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let am = NSMenu()
        am.addItem(withTitle: "About Reader+", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        am.addItem(.separator())
        let tourItem = NSMenuItem(title: "Take the Tour…", action: #selector(tour), keyEquivalent: ""); tourItem.target = self; am.addItem(tourItem)
        am.addItem(.separator())
        am.addItem(withTitle: "Hide Reader+", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        am.addItem(withTitle: "Quit Reader+", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = am
        let editItem = NSMenuItem(); main.addItem(editItem)
        let em = NSMenu(title: "Edit")
        em.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        em.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = em
        let winItem = NSMenuItem(); main.addItem(winItem)
        let wm = NSMenu(title: "Window")
        let ctl = NSMenuItem(title: "Reader+ Controls", action: #selector(showControls), keyEquivalent: "0"); ctl.target = self; wm.addItem(ctl)
        let rw = NSMenuItem(title: "Reading Window", action: #selector(toggleReader), keyEquivalent: ""); rw.target = self; wm.addItem(rw)
        wm.addItem(.separator())
        wm.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        wm.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = wm
        NSApp.windowsMenu = wm
        NSApp.mainMenu = main
    }

    @objc func showControls() { ControlWindow.shared.show() }

    func waitForTrust() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            if AXIsProcessTrusted() {
                t.invalidate(); ClickReader.shared.start()
                say("Thank you. Reader plus can now read your apps."); log("accessibility granted")
            }
        }
    }

    func needTrust() -> Bool {
        if AXIsProcessTrusted() { return false }
        say("Reader plus needs Accessibility permission first. Turn on Reader plus in System Settings, Privacy and Security, Accessibility.")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        return true
    }

    // MARK: Commands

    @objc func readSelection() {
        if needTrust() { return }
        withSelectedText { text, el, base in
            guard let t = text, !t.trimmed.isEmpty else { say("No text is selected."); return }
            Reading.shared.start(ReadSource(text: t, element: el, base: base))
        }
    }

    @objc func readFromFocus() {
        if NSApp.isActive, let tv = NSApp.keyWindow?.firstResponder as? NSTextView, !tv.string.trimmed.isEmpty {
            let ns = tv.string as NSString
            var from = tv.selectedRange().location
            if from >= ns.length - 1 { from = 0 }
            Reading.shared.start(ReadSource(text: tv.string, element: nil, base: 0), from: from, showWindow: tv !== ReaderWindow.shared.textView)
            return
        }
        if needTrust() { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let src = readSourceFromFocus()
            DispatchQueue.main.async {
                guard let s = src else { say("I couldn't find any text to read here."); return }
                Reading.shared.start(s)
            }
        }
    }

    @objc func readScreenUnderPointer() {
        let p = axPoint(NSEvent.mouseLocation)
        if let r = windowFrame(at: p) { ocrRead(r) }
        else { ocrRead(CGRect(x: p.x - 450, y: p.y - 250, width: 900, height: 500)) }
    }

    @objc func readClipboard() {
        guard let t = NSPasteboard.general.string(forType: .string), !t.trimmed.isEmpty else { say("The clipboard has no text."); return }
        Reading.shared.start(ReadSource(text: t, element: nil, base: 0))
    }

    @objc func pauseResume() { Speaker.shared.pauseOrResume() }
    @objc func stopSpeech() { Speaker.shared.stop() }

    @objc func toggleMouseEcho() {
        if !prefs.bool(forKey: Key.mouseEcho) && needTrust() { return }
        let on = !prefs.bool(forKey: Key.mouseEcho)
        prefs.set(on, forKey: Key.mouseEcho)
        MouseEcho.shared.apply()
        say(on ? "Mouse Echo on" : "Mouse Echo off")
    }

    @objc func cycleKeyEcho() { setKeyEcho((prefs.integer(forKey: Key.keyEcho) + 1) % 4) }

    func setKeyEcho(_ m: Int) {
        if m != 0 && !KeyEcho.shared.startTap() {
            CGRequestListenEventAccess()
            say("Key Echo needs Input Monitoring permission. Turn on Reader plus in System Settings, Privacy and Security, Input Monitoring, then quit and reopen Reader plus.")
            return
        }
        prefs.set(m, forKey: Key.keyEcho)
        say(["Key Echo off", "Key Echo: characters", "Key Echo: words", "Key Echo: characters and words"][m])
    }

    // MARK: Menu bar

    func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = status.button {
            b.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Reader+")
            b.toolTip = "Reader+"
        }
        let m = NSMenu(); m.delegate = self
        status.menu = m
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        func item(_ t: String, _ sel: Selector?, _ key: String = "", on: Bool? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.target = self
            if !key.isEmpty { i.keyEquivalentModifierMask = [.control, .option] }
            if let on = on { i.state = on ? .on : .off }
            m.addItem(i); return i
        }
        _ = item("Read Selected Text", #selector(readSelection))
        _ = item("Read From the Cursor, or the Whole Page", #selector(readFromFocus))
        _ = item("Read Clipboard", #selector(readClipboard))
        _ = item("Read Text in Window Under Pointer (OCR)", #selector(readScreenUnderPointer))
        _ = item(Speaker.shared.isPaused ? "Resume" : "Pause", #selector(pauseResume))
        _ = item("Stop Talking (tap Control)", #selector(stopSpeech))
        m.addItem(.separator())
        _ = item("Mouse Echo", #selector(toggleMouseEcho), on: prefs.bool(forKey: Key.mouseEcho))
        let keyItem = item("Key Echo", nil)
        let km = NSMenu()
        for (i, t) in ["Off", "Characters", "Words", "Characters and Words"].enumerated() {
            let ki = NSMenuItem(title: t, action: #selector(pickKeyEcho(_:)), keyEquivalent: "")
            ki.target = self; ki.tag = i; ki.state = prefs.integer(forKey: Key.keyEcho) == i ? .on : .off
            km.addItem(ki)
        }
        keyItem.submenu = km
        let delayItem = item("Mouse Echo Delay", nil)
        let dm = NSMenu()
        for (t, v) in [("Quick (0.25 s)", 0.25), ("Normal (0.45 s)", 0.45), ("Slow (0.8 s)", 0.8), ("Very Slow (1.2 s)", 1.2)] {
            let di = NSMenuItem(title: t, action: #selector(pickDelay(_:)), keyEquivalent: "")
            di.target = self; di.representedObject = v; di.state = abs(prefs.double(forKey: Key.hoverDelay) - v) < 0.01 ? .on : .off
            dm.addItem(di)
        }
        delayItem.submenu = dm
        let clickItem = item("Click to Read", nil)
        let cm = NSMenu()
        for (i, t) in ["Off", "⌘-Click", "⌥⌘-Click"].enumerated() {
            let ci = NSMenuItem(title: t, action: #selector(pickClickMode(_:)), keyEquivalent: "")
            ci.target = self; ci.tag = i; ci.state = prefs.integer(forKey: Key.clickMode) == i ? .on : .off
            cm.addItem(ci)
        }
        cm.addItem(.separator())
        let hdr = NSMenuItem(title: "Clicking a paragraph reads:", action: nil, keyEquivalent: ""); hdr.isEnabled = false
        cm.addItem(hdr)
        for (i, t) in ["The article from there to the end", "Just that paragraph"].enumerated() {
            let pi = NSMenuItem(title: t, action: #selector(pickParagraphMode(_:)), keyEquivalent: "")
            pi.target = self; pi.tag = i; pi.state = prefs.integer(forKey: Key.paragraphMode) == i ? .on : .off
            pi.indentationLevel = 1
            cm.addItem(pi)
        }
        let hn = NSMenuItem(title: "Clicking a heading reads its whole section.", action: nil, keyEquivalent: ""); hn.isEnabled = false
        cm.addItem(hn)
        clickItem.submenu = cm
        _ = item("Highlight What's Being Read on Screen", #selector(toggleScreenHL), on: prefs.bool(forKey: Key.screenHighlight))
        _ = item("Open Reading Window When Reading", #selector(toggleShowReader), on: prefs.bool(forKey: Key.showReader))
        m.addItem(.separator())

        let voiceItem = item("Voice", nil)
        let vm = NSMenu()
        let current = prefs.string(forKey: Key.voice)
        let voices = readingVoices()
        let sys = NSMenuItem(title: "System Voice (Spoken Content)", action: #selector(pickVoice(_:)), keyEquivalent: "")
        sys.target = self; sys.representedObject = ""; sys.state = current == nil ? .on : .off
        vm.addItem(sys); vm.addItem(.separator())
        for v in voices {
            let q = v.quality == .premium ? " (Premium)" : (v.quality == .enhanced ? " (Enhanced)" : "")
            let vi = NSMenuItem(title: "\(v.name)\(q) — \(v.language)", action: #selector(pickVoice(_:)), keyEquivalent: "")
            vi.target = self; vi.representedObject = v.identifier; vi.state = v.identifier == current ? .on : .off
            vm.addItem(vi)
        }
        vm.addItem(.separator())
        let more = NSMenuItem(title: "Get More Voices…", action: #selector(moreVoices), keyEquivalent: ""); more.target = self
        vm.addItem(more)
        voiceItem.submenu = vm
        let speed = Int((prefs.double(forKey: Key.rate) * 100).rounded())
        item("Speed: \(speed)%", nil).isEnabled = false
        _ = item("Faster", #selector(faster))
        _ = item("Slower", #selector(slower))
        m.addItem(.separator())
        _ = item(ReaderWindow.shared.isVisible ? "Hide Reading Window" : "Show Reading Window", #selector(toggleReader))
        _ = item("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        _ = item("Spoken Help", #selector(help))
        _ = item("Take the Tour…", #selector(tour))
        _ = item("Show Reader+ Controls", #selector(showControls))
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit Reader+", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(q)
    }

    @objc func pickKeyEcho(_ s: NSMenuItem) { setKeyEcho(s.tag) }
    @objc func pickClickMode(_ s: NSMenuItem) {
        prefs.set(s.tag, forKey: Key.clickMode)
        say(["Click to read off", "Command click to read", "Option Command click to read"][s.tag])
    }
    @objc func pickParagraphMode(_ s: NSMenuItem) {
        prefs.set(s.tag, forKey: Key.paragraphMode)
        say(s.tag == 0 ? "Clicking a paragraph reads the article from there." : "Clicking a paragraph reads just that paragraph.")
    }
    @objc func pickDelay(_ s: NSMenuItem) { if let v = s.representedObject as? Double { prefs.set(v, forKey: Key.hoverDelay) } }
    @objc func toggleScreenHL() {
        let on = !prefs.bool(forKey: Key.screenHighlight); prefs.set(on, forKey: Key.screenHighlight)
        if !on { Overlay.shared.hide() }
    }
    @objc func toggleShowReader() { prefs.set(!prefs.bool(forKey: Key.showReader), forKey: Key.showReader) }
    @objc func pickVoice(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        if id.isEmpty { prefs.removeObject(forKey: Key.voice) } else { prefs.set(id, forKey: Key.voice) }
        if Speaker.shared.isReading { Reading.shared.restartHere() } else { say("This is my voice.") }
    }
    @objc func moreVoices() {
        say("To add voices, choose Manage Voices under System Voice. Enhanced and Premium voices sound the most natural.")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
    }
    @objc func faster() { Reading.shared.changeRate(0.05) }
    @objc func slower() { Reading.shared.changeRate(-0.05) }
    @objc func toggleReader() { ReaderWindow.shared.toggle() }
    @objc func help() { say(helpText) }
    @objc func tour() { TourController.shared.show() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister(); say("Reader plus won't open at login.") }
            else { try SMAppService.mainApp.register(); say("Reader plus will open at login.") }
        } catch { log("login item: \(error.localizedDescription)"); say("I couldn't change that setting.") }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
