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
import Security

// MARK: - Log & settings

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Reader+.log")
let logLock = NSLock()
func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }   // one line at a time, even from several threads
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

enum Key {
    static let aiAutoRead = "aiAutoRead", aiDelay = "aiDelay", aiInterrupt = "aiInterrupt", aiShowWindow = "aiShowWindow"
    static let voice = "voice", rate = "rate", mouseEcho = "mouseEcho", hoverDelay = "hoverDelay"
    static let keyEcho = "keyEcho", fontSize = "fontSize", theme = "theme"
    static let screenHighlight = "screenHighlight", showReader = "showReader"
    static let clickMode = "clickMode", paragraphMode = "paragraphMode", clickShowsReader = "clickShowsReader"
}
let prefs = UserDefaults.standard
func registerDefaults() {
    prefs.register(defaults: [
        Key.aiAutoRead: true, Key.aiDelay: 2.0, Key.aiInterrupt: true, Key.aiShowWindow: false,
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

// MARK: - ElevenLabs voices (optional; uses your own ElevenLabs API key)

/// The API key lives in the macOS Keychain, not in a settings file.
enum Keychain {
    static let service = "Reader+ ElevenLabs", account = "api-key"
    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let k = String(data: d, encoding: .utf8)?.trimmed ?? ""
        return k.isEmpty ? nil : k
    }
    static func set(_ key: String) {
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(key.trimmed.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

struct ElevenWord { let loc: Int; let len: Int; let start: Double }

final class Eleven {
    static let shared = Eleven()
    static let prefix = "eleven:"
    let base = "https://api.elevenlabs.io"
    var hasKey: Bool { Keychain.get() != nil }
    /// "eleven_flash_v2_5" is quick to start; "eleven_multilingual_v2" is the richest quality.
    var model: String { prefs.string(forKey: "elevenModel") ?? "eleven_flash_v2_5" }
    /// The voices on your ElevenLabs account, saved after "Load My Voices": [[id, name]].
    var voices: [(id: String, name: String)] {
        ((prefs.array(forKey: "elevenVoices") as? [[String]]) ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }
    /// Reader+ speed (0.1–1.0, 0.5 normal) as ElevenLabs speed (0.7–1.2, 1.0 normal).
    var speed: Double { max(0.7, min(1.2, 1.0 + (prefs.double(forKey: Key.rate) - 0.5) * 1.33)) }

    func loadVoices(_ done: @escaping (String?) -> Void) {
        guard let key = Keychain.get() else { done("Add your ElevenLabs API key first."); return }
        var r = URLRequest(url: URL(string: base + "/v1/voices")!)
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        r.timeoutInterval = 20
        URLSession.shared.dataTask(with: r) { data, resp, err in
            var message: String? = nil
            if let err = err { message = "Couldn't reach ElevenLabs: \(err.localizedDescription)" }
            else if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                message = h.statusCode == 401 ? "ElevenLabs didn't accept that API key." : "ElevenLabs answered with error \(h.statusCode)."
            } else if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let list = j["voices"] as? [[String: Any]] {
                let v = list.compactMap { x -> [String]? in
                    guard let id = x["voice_id"] as? String, let n = x["name"] as? String else { return nil }
                    return [id, n]
                }.sorted { $0[1].lowercased() < $1[1].lowercased() }
                prefs.set(v, forKey: "elevenVoices")
                log("ElevenLabs: \(v.count) voices loaded")
            } else { message = "ElevenLabs sent something Reader+ couldn't read." }
            DispatchQueue.main.async { done(message) }
        }.resume()
    }

    /// Turns text into speech. Returns the audio and when each word starts (for highlighting).
    func speech(_ text: String, voice: String, _ done: @escaping (Data?, [ElevenWord], String?) -> Void) {
        guard let key = Keychain.get() else { done(nil, [], "no ElevenLabs key"); return }
        var c = URLComponents(string: base + "/v1/text-to-speech/\(voice)/with-timestamps")!
        c.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "model_id": model,
                                   "voice_settings": ["stability": 0.5, "similarity_boost": 0.75, "speed": speed]]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { data, resp, err in
            if let err = err { done(nil, [], err.localizedDescription); return }
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                let detail = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200) ?? ""
                done(nil, [], "HTTP \(h.statusCode) \(detail)"); return
            }
            guard let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let b64 = j["audio_base64"] as? String, let audio = Data(base64Encoded: b64) else {
                done(nil, [], "unreadable answer"); return
            }
            var words: [ElevenWord] = []
            if let al = j["alignment"] as? [String: Any], let chars = al["characters"] as? [String],
               let starts = al["character_start_times_seconds"] as? [Double], starts.count == chars.count {
                var loc = 0, wStart = -1, wTime = 0.0
                for (i, ch) in chars.enumerated() {
                    let isSpace = ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if isSpace {
                        if wStart >= 0 { words.append(ElevenWord(loc: wStart, len: loc - wStart, start: wTime)); wStart = -1 }
                    } else if wStart < 0 { wStart = loc; wTime = starts[i] }
                    loc += (ch as NSString).length
                }
                if wStart >= 0 { words.append(ElevenWord(loc: wStart, len: loc - wStart, start: wTime)) }
            }
            done(audio, words, nil)
        }.resume()
    }
}

// MARK: - Kokoro voices (free, natural AI voices that run on this Mac)

let kokoroSetupScript = #"""
#!/bin/bash
# Installs the free Kokoro voices for Reader+. Run by Reader+ with this folder as $1.
set -e
D="$1"; cd "$D"
step() { echo "STEP: $*"; }
PY=""
for c in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10 \
         /usr/local/bin/python3.13 /usr/local/bin/python3.12 /usr/local/bin/python3.11 /usr/local/bin/python3.10 \
         /Library/Frameworks/Python.framework/Versions/3.1[0-3]/bin/python3 \
         /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [ -x "$c" ] || continue
  if "$c" -c "import sys, platform; sys.exit(0 if (3,10) <= sys.version_info[:2] < (3,14) and platform.machine() == '$(uname -m)' else 1)" 2>/dev/null; then PY="$c"; break; fi
done
rm -rf "$D/venv"
if [ -n "$PY" ]; then
  echo "Using $PY"
  step "Setting up"
  "$PY" -m venv "$D/venv"
  step "Installing Kokoro"
  "$D/venv/bin/python" -m pip install --quiet --upgrade pip
  "$D/venv/bin/python" -m pip install --quiet kokoro-onnx numpy
else
  step "Getting Python"
  if [ "$(uname -m)" = arm64 ]; then T=aarch64-apple-darwin; else T=x86_64-apple-darwin; fi
  mkdir -p "$D/uv"
  curl -fsSL --retry 3 "https://github.com/astral-sh/uv/releases/latest/download/uv-$T.tar.gz" | tar -xz -C "$D/uv" --strip-components 1
  "$D/uv/uv" venv --python 3.12 "$D/venv"
  step "Installing Kokoro"
  "$D/uv/uv" pip install --python "$D/venv/bin/python" kokoro-onnx numpy
fi
step "Downloading the voices (about 330 MB)"
"$D/venv/bin/python" -c "import platform, sys; print('Python', sys.version.split()[0], platform.machine())"
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  if [ ! -s "$f" ]; then
    curl -fL --retry 3 -o "$f.part" "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/$f" \
      || curl -fL --retry 3 -o "$f.part" "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/$f"
    mv "$f.part" "$f"
  fi
done
step "Testing the voice"
"$D/venv/bin/python" - <<'PYEOF'
from kokoro_onnx import Kokoro
k = Kokoro("kokoro-v1.0.onnx", "voices-v1.0.bin")
s, sr = k.create("Ready.", voice="af_heart", speed=1.0, lang="en-us")
print("OK", len(s), sr)
PYEOF
touch "$D/installed"
step "Done"
"""#

let kokoroServerScript = #"""
# Reader+ Kokoro voice server. Listens only on this Mac (127.0.0.1).
import sys, json, io, wave, threading, time
import numpy as np
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from kokoro_onnx import Kokoro

d, port = sys.argv[1], int(sys.argv[2])
k = Kokoro(f"{d}/kokoro-v1.0.onnx", f"{d}/voices-v1.0.bin")

# Speed-up: the pronunciation step normally restarts espeak for every request (~0.8 s).
# Keep one espeak running per language instead.
try:
    import phonemizer as _ph
    from phonemizer.backend import EspeakBackend
    from phonemizer.separator import default_separator
    _orig, _cache = _ph.phonemize, {}
    def _fast(text, language="en-us", backend="espeak", separator=None, strip=False, preserve_punctuation=False,
              with_stress=False, tie=False, language_switch="keep-flags", words_mismatch="ignore", **kw):
        try:
            key = (language, preserve_punctuation, with_stress, tie, language_switch, words_mismatch)
            b = _cache.get(key)
            if b is None:
                b = _cache[key] = EspeakBackend(language, preserve_punctuation=preserve_punctuation, with_stress=with_stress,
                                                tie=tie, language_switch=language_switch, words_mismatch=words_mismatch)
            single = isinstance(text, str)
            out = b.phonemize([text] if single else list(text),
                              separator=separator if separator is not None else default_separator, strip=strip)
            return out[0] if single else out
        except Exception:
            return _orig(text, language=language, backend=backend, separator=separator, strip=strip,
                         preserve_punctuation=preserve_punctuation, with_stress=with_stress, tie=tie,
                         language_switch=language_switch, words_mismatch=words_mismatch, **kw)
    _ph.phonemize = _fast
    import kokoro_onnx.tokenizer as _tk
    if hasattr(_tk, "phonemize"): _tk.phonemize = _fast
    if hasattr(_tk, "phonemizer"): _tk.phonemizer.phonemize = _fast
except Exception as e:
    print("phonemizer speed-up not applied:", e, file=sys.stderr)
try: k.create("Hi.", voice="af_heart", speed=1.0, lang="en-us")
except Exception: pass
lock = threading.Lock()
latest = [0]   # the newest reading; older queued pieces are skipped so a new click never waits behind them

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body, kind):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        if getattr(self, "timing", None) is not None: self.send_header("X-Synth-Seconds", "%.2f" % self.timing)
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/ping": self.reply(200, b"ok", "text/plain")
        elif self.path == "/bench":
            out = {}
            try:
                import os, onnxruntime as ort
                t = "Hello there, this is a test."
                t0 = time.time(); ph = k.tokenizer.phonemize(t, "en-us"); out["phonemize"] = round(time.time() - t0, 3)
                t0 = time.time(); k.tokenizer.phonemize("Something new to say.", "en-us"); out["phonemize_new_text"] = round(time.time() - t0, 3)
                with lock:
                    t0 = time.time(); k.create(t, voice="af_heart", speed=1.0, lang="en-us"); out["create_default"] = round(time.time() - t0, 3)
                out["providers"] = ort.get_available_providers()
                out["cpus"] = os.cpu_count()
                for th in (4, 6):
                    so = ort.SessionOptions(); so.intra_op_num_threads = th
                    sess = ort.InferenceSession(f"{d}/kokoro-v1.0.onnx", so, providers=["CPUExecutionProvider"])
                    k2 = Kokoro.from_session(sess, f"{d}/voices-v1.0.bin")
                    k2.create(t, voice="af_heart", speed=1.0, lang="en-us")
                    t0 = time.time(); k2.create(t, voice="af_heart", speed=1.0, lang="en-us"); out[f"threads{th}"] = round(time.time() - t0, 3)
                if "CoreMLExecutionProvider" in ort.get_available_providers():
                    try:
                        sess = ort.InferenceSession(f"{d}/kokoro-v1.0.onnx", providers=["CoreMLExecutionProvider", "CPUExecutionProvider"])
                        k3 = Kokoro.from_session(sess, f"{d}/voices-v1.0.bin")
                        k3.create(t, voice="af_heart", speed=1.0, lang="en-us")
                        t0 = time.time(); k3.create(t, voice="af_heart", speed=1.0, lang="en-us"); out["coreml"] = round(time.time() - t0, 3)
                    except Exception as e: out["coreml_error"] = str(e)[:200]
            except Exception as e: out["error"] = str(e)[:300]
            self.reply(200, json.dumps(out).encode(), "application/json")
        elif self.path == "/voices":
            try: v = sorted(k.get_voices())
            except Exception: v = []
            self.reply(200, json.dumps(v).encode(), "application/json")
        else: self.reply(404, b"", "text/plain")
    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("text") or "").strip()
            if not text: return self.reply(400, b"no text", "text/plain")
            gen = int(req.get("gen", 0))
            if gen > latest[0]: latest[0] = gen
            with lock:
                if gen and gen < latest[0]: return self.reply(409, b"replaced", "text/plain")
                t0 = time.time()
                samples, sr = k.create(text, voice=req.get("voice", "af_heart"),
                                       speed=float(req.get("speed", 1.0)), lang=req.get("lang", "en-us"))
            pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
            buf = io.BytesIO()
            w = wave.open(buf, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm); w.close()
            self.timing = time.time() - t0
            self.reply(200, buf.getvalue(), "audio/wav")
        except Exception as e:
            self.reply(500, str(e).encode(), "text/plain")

ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
"""#

final class Kokoro {
    static let shared = Kokoro()
    static let prefix = "kokoro:"
    let port = 59125
    var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Reader+/Kokoro") }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("installed").path) }
    private(set) var installing = false
    private var server: Process?
    private var ready = false
    private let startLock = NSLock()
    /// The most natural English voices, with friendly names.
    let voices: [(id: String, name: String)] = [
        ("af_heart", "Heart (American woman)"), ("af_bella", "Bella (American woman)"), ("af_nicole", "Nicole (American woman, soft)"),
        ("af_sarah", "Sarah (American woman)"), ("af_sky", "Sky (American woman)"), ("am_michael", "Michael (American man)"),
        ("am_fenrir", "Fenrir (American man)"), ("am_puck", "Puck (American man)"), ("am_adam", "Adam (American man)"),
        ("bf_emma", "Emma (British woman)"), ("bf_isabella", "Isabella (British woman)"), ("bm_george", "George (British man)"),
        ("bm_fable", "Fable (British man)"),
    ]
    /// Reader+ speed (0.1–1.0, 0.5 normal) as Kokoro speed (1.0 normal).
    var speed: Double { max(0.6, min(1.8, prefs.double(forKey: Key.rate) / 0.5)) }

    private func writeScripts() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? kokoroSetupScript.write(to: dir.appendingPathComponent("setup.sh"), atomically: true, encoding: .utf8)
        try? kokoroServerScript.write(to: dir.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    }

    func install(_ update: @escaping (String) -> Void, _ done: @escaping (Bool) -> Void) {
        guard !installing else { return }
        installing = true
        writeScripts()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("installed"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [dir.appendingPathComponent("setup.sh").path, dir.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let logURL = dir.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let fh = try? FileHandle(forWritingTo: logURL)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            fh?.write(d)
            if let text = String(data: d, encoding: .utf8) {
                for line in text.split(separator: "\n") where line.hasPrefix("STEP: ") {
                    let t = String(line.dropFirst(6))
                    log("Kokoro: \(t)")
                    DispatchQueue.main.async { update(t) }
                }
            }
        }
        p.terminationHandler = { pr in
            pipe.fileHandleForReading.readabilityHandler = nil
            try? fh?.close()
            DispatchQueue.main.async {
                self.installing = false
                let ok = pr.terminationStatus == 0 && self.isInstalled
                log("Kokoro install " + (ok ? "finished" : "failed (\(pr.terminationStatus)); see \(logURL.path)"))
                done(ok)
            }
        }
        do { try p.run(); log("Kokoro install started") } catch { installing = false; done(false) }
    }

    private func ping() -> Bool {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ping")!); r.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0); var ok = false
        URLSession.shared.dataTask(with: r) { _, resp, _ in ok = (resp as? HTTPURLResponse)?.statusCode == 200; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return ok
    }

    /// Starts the voice in the background if needed (takes a few seconds the first time).
    private func ensureServer() -> Bool {
        startLock.lock(); defer { startLock.unlock() }
        if ready && ping() { return true }
        ready = false
        if ping() { ready = true; return true }
        if server == nil || !(server!.isRunning) {
            writeScripts()
            let p = Process()
            p.executableURL = dir.appendingPathComponent("venv/bin/python")
            p.arguments = [dir.appendingPathComponent("server.py").path, dir.path, String(port)]
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle(forWritingAtPath: dir.appendingPathComponent("server.log").path) ?? FileHandle.nullDevice
            FileManager.default.createFile(atPath: dir.appendingPathComponent("server.log").path, contents: nil)
            do { try p.run(); server = p; log("Kokoro voice starting") } catch { log("Kokoro couldn't start: \(error)"); return false }
        }
        for _ in 0..<120 { if ping() { ready = true; log("Kokoro voice ready"); return true }; usleep(500_000) }
        return false
    }

    func warmUp() {
        guard isInstalled else { return }
        DispatchQueue.global(qos: .utility).async {
            if self.needsNativeReinstall() {
                DispatchQueue.main.async {
                    self.stopServer()
                    self.install({ _ in }) { ok in log("Kokoro native reinstall " + (ok ? "done" : "failed")); if ok { self.warmUp() } }
                }
                return
            }
            if self.ensureServer() && !prefs.bool(forKey: "kokoroBenched2") {
                prefs.set(true, forKey: "kokoroBenched2")
                var r = URLRequest(url: URL(string: "http://127.0.0.1:\(self.port)/bench")!); r.timeoutInterval = 180
                URLSession.shared.dataTask(with: r) { d, _, _ in
                    log("Kokoro speed test: " + (d.flatMap { String(data: $0, encoding: .utf8) } ?? "no answer"))
                }.resume()
            }
        }
    }

    private var checkedNative = false
    /// True when Kokoro's Python runs through Intel translation on an Apple Silicon Mac (much slower).
    private func needsNativeReinstall() -> Bool {
        if checkedNative { return false }
        checkedNative = true
        let p = Process(); let out = Pipe()
        p.executableURL = dir.appendingPathComponent("venv/bin/python")
        p.arguments = ["-c", "import platform, sys; print(platform.machine(), sys.version.split()[0])"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let info = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmed ?? "?"
        #if arch(arm64)
        let mine = "arm64"
        #else
        let mine = "x86_64"
        #endif
        log("Kokoro Python: \(info); Reader+: \(mine)")
        return !info.hasPrefix(mine)
    }
    func stopServer() { server?.terminate(); server = nil; ready = false }

    func speech(_ text: String, voice: String, gen: Int = 0, _ done: @escaping (Data?, [ElevenWord], String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.ensureServer() else { done(nil, [], "Kokoro didn't start"); return }
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(self.port)/speak")!)
            r.httpMethod = "POST"; r.timeoutInterval = 90
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let lang = voice.hasPrefix("b") ? "en-gb" : "en-us"
            r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "voice": voice, "speed": self.speed, "lang": lang, "gen": gen])
            let t0 = Date()
            URLSession.shared.dataTask(with: r) { data, resp, err in
                if let h = resp as? HTTPURLResponse, h.statusCode == 200 {
                    log(String(format: "Kokoro: %d chars, made in %@s, total %.2fs", text.count,
                               (h.value(forHTTPHeaderField: "X-Synth-Seconds") ?? "?"), Date().timeIntervalSince(t0)))
                }
                if let err = err { self.ready = false; done(nil, [], err.localizedDescription); return }
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let d = data else {
                    done(nil, [], "Kokoro error " + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")); return
                }
                done(d, [], nil)
            }.resume()
        }
    }
}

/// When a voice gives no word timings, estimate them from where each word sits in the text.
func estimateWords(_ text: String, duration: Double) -> [ElevenWord] {
    let ns = text as NSString
    guard ns.length > 0, duration > 0 else { return [] }
    var out: [ElevenWord] = []
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, r, _, _ in
        out.append(ElevenWord(loc: r.location, len: r.length, start: duration * 0.97 * Double(r.location) / Double(ns.length)))
    }
    return out
}

/// Speaks with either a voice picked in Reader+ (AVSpeechSynthesizer), or the Mac's System Voice
/// from System Settings > Accessibility > Spoken Content, which can be a Siri voice (NSSpeechSynthesizer).
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, NSSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()
    let synth = AVSpeechSynthesizer()
    private var sys = NSSpeechSynthesizer()
    private var offsets: [ObjectIdentifier: Int] = [:]   // where each piece starts in the full text
    private var lastPiece: AVSpeechUtterance?
    private var sysOffset = 0
    private var sysReading = false
    private var sysPaused = false
    private var sysBusy = false
    private var sysPending: (String, Bool)?
    private var sysVoice = NSSpeechSynthesizer.defaultVoice
    private var speechStarted: TimeInterval?
    private var speechGeneration = 0
    var request: ReadRequest?
    // ElevenLabs
    private var elQueue: [(Int, String)] = []
    private var elAll: [(Int, String)] = []
    private var elReading = false
    private var elPaused = false
    private var elGen = 0
    private var elPlayer: AVAudioPlayer?
    private var elTimer: Timer?
    private var elWords: [ElevenWord] = []
    private var elOffset = 0
    private var elLastWord = -1
    private var elCache: [Int: (Data?, [ElevenWord], String?)] = [:]
    private var elWaiting: [Int: (Data?, [ElevenWord], String?) -> Void] = [:]
    private var elStarted: Date?
    /// A number that keeps growing across launches, so the voice server can tell new readings from old ones.
    let readingNumber = Int(Date().timeIntervalSince1970) * 1000
    var onWord: ((NSRange) -> Void)?
    var onDone: (() -> Void)?

    override init() { super.init(); synth.delegate = self; sys.delegate = self }

    /// "Siri / System Voice" is chosen (no Reader+ voice picked).
    var useSystemVoice: Bool { (prefs.string(forKey: Key.voice) ?? "").isEmpty }
    /// The ElevenLabs voice ID, when an ElevenLabs voice is chosen and a key is saved.
    /// The chosen ElevenLabs or Kokoro voice ("eleven:ID" / "kokoro:ID"), when it can be used.
    var elevenVoice: String? {
        guard let v = prefs.string(forKey: Key.voice) else { return nil }
        if v.hasPrefix(Eleven.prefix) && Eleven.shared.hasKey { return v }
        if v.hasPrefix(Kokoro.prefix) && Kokoro.shared.isInstalled { return v }
        return nil
    }
    var isReading: Bool { lastPiece != nil || sysReading || elReading }
    var isPaused: Bool { synth.isPaused || sysPaused || elPaused }
    var isSpeaking: Bool { synth.isSpeaking || sys.isSpeaking || (elPlayer?.isPlaying ?? false) }

    var voice: AVSpeechSynthesisVoice? {
        if let id = prefs.string(forKey: Key.voice), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        // With an ElevenLabs voice, short announcements use the best Apple voice installed.
        let best = readingVoices().filter { $0.language.hasPrefix("en") }.max { $0.quality.rawValue < $1.quality.rawValue }
        return best ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Reader+'s speed (0.1–1.0, 0.5 is normal) in words per minute, for the System Voice.
    var wordsPerMinute: Float { Float(max(90, min(520, 185 * prefs.double(forKey: Key.rate) / 0.5))) }

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

    /// Pieces for AI voices. The very first piece is just the opening words (a phrase), so the voice
    /// starts almost at once; then pieces grow (a sentence, ~120, ~220, ~320 characters) while the next
    /// one is always prepared during the current one, so there are no gaps.
    static func quickPieces(_ text: String) -> [(Int, String)] {
        let ns = text as NSString
        var sentences: [NSRange] = []
        for (off, para) in pieces(text) {
            let pn = para as NSString
            pn.enumerateSubstrings(in: NSRange(location: 0, length: pn.length), options: .bySentences) { _, sr, _, _ in
                sentences.append(NSRange(location: off + sr.location, length: sr.length))
            }
        }
        var out: [(Int, String)] = []
        if var first = sentences.first, first.length > 60 {
            let s = ns.substring(with: first) as NSString
            var cut = 0
            for mark in [", ", "; ", ": ", " — ", " - "] {
                let r = s.range(of: mark, options: [], range: NSRange(location: 15, length: min(45, s.length - 15)))
                if r.location != NSNotFound { cut = NSMaxRange(r); break }
            }
            if cut == 0 {
                let r = s.range(of: " ", options: .backwards, range: NSRange(location: 0, length: min(40, s.length)))
                if r.location != NSNotFound && r.location > 10 { cut = r.location + 1 }
            }
            if cut > 0 {
                out.append((first.location, s.substring(to: cut)))
                first = NSRange(location: first.location + cut, length: first.length - cut)
                sentences[0] = first
            }
        }
        let limits = [0, 120, 220, 320]
        var cur: NSRange? = nil
        for sr in sentences {
            let lim = limits[min(out.count, limits.count - 1)]
            if let c = cur {
                if NSMaxRange(sr) - c.location > lim {
                    out.append((c.location, ns.substring(with: c))); cur = sr
                } else { cur = NSRange(location: c.location, length: NSMaxRange(sr) - c.location) }
            } else { cur = sr }
        }
        if let c = cur { out.append((c.location, ns.substring(with: c))) }
        return out.filter { !$0.1.trimmed.isEmpty }
    }

    private func halt() {
        offsets = [:]; lastPiece = nil
        sysReading = false; sysPaused = false; sysPending = nil
        speechGeneration += 1; speechStarted = nil
        elGen += 1; elQueue = []; elAll = []; elReading = false; elPaused = false
        elCache = [:]; elWaiting = [:]; elTimer?.invalidate(); elTimer = nil
        elPlayer?.stop(); elPlayer = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        if sysBusy { sys.stopSpeaking() }
    }

    /// Speak text. `track` = this is a reading (word highlighting, reading window).
    func say(_ text: String, track: Bool = false) {
        guard !text.trimmed.isEmpty else { return }
        let wasReading = isReading
        halt()
        if !track && wasReading { onDone?() }
        speechStarted = track ? ProcessInfo.processInfo.systemUptime : nil
        if track, let ev = elevenVoice {
            monitorSpeechStart(speechGeneration)
            elAll = Speaker.quickPieces(text); elQueue = elAll
            elStarted = Date()
            elReading = true
            nextElevenPiece(ev, elGen)
            return
        }
        let generation = speechGeneration
        if useSystemVoice {
            sysPending = (text, track)
            sysReading = track
            startPendingSystem()
            // If the OS loses a stop callback, recover instead of silently dropping the next click.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard generation == self.speechGeneration, self.sysPending != nil else { return }
                if !self.sys.isSpeaking {
                    self.sys.delegate = nil
                    self.sys = NSSpeechSynthesizer(voice: NSSpeechSynthesizer.defaultVoice) ?? NSSpeechSynthesizer()
                    self.sys.delegate = self; self.sysBusy = false
                    log("system voice recovered after missing stop acknowledgement")
                    self.startPendingSystem()
                }
            }
            monitorSpeechStart(generation)
            return
        }
        monitorSpeechStart(generation)
        let rate = Float(prefs.double(forKey: Key.rate)), v = voice
        if !track {
            let u = AVSpeechUtterance(string: text.trimmed); u.rate = rate; u.voice = v
            synth.speak(u); return
        }
        speakApple(Speaker.pieces(text))
    }

    /// Reads pieces with an Apple voice (also used if ElevenLabs can't be reached).
    private func speakApple(_ list: [(Int, String)]) {
        let rate = Float(prefs.double(forKey: Key.rate)), v = voice
        for (off, piece) in list {
            let u = AVSpeechUtterance(string: piece); u.rate = rate; u.voice = v
            offsets[ObjectIdentifier(u)] = off
            lastPiece = u
            synth.speak(u)
        }
    }

    private func startPendingSystem() {
        guard !sysBusy, let pending = sysPending else { return }
        let selected = NSSpeechSynthesizer.defaultVoice
        if selected != sysVoice {
            sys.delegate = nil
            sys = NSSpeechSynthesizer(voice: selected) ?? NSSpeechSynthesizer()
            sys.delegate = self; sysVoice = selected
        }
        sys.rate = wordsPerMinute
        sysPending = nil; sysOffset = 0; sysBusy = true
        // One utterance avoids stopping and restarting the system engine at every paragraph.
        if !sys.startSpeaking(pending.0) {
            sysBusy = false; sysReading = false
            request?.trace("system voice rejected speech")
            log("system voice rejected speech; falling back to installed Apple voice")
            speakApple(Speaker.pieces(pending.0))
        }
    }

    private func markSpeechStarted(_ engine: String) {
        guard let started = speechStarted else { return }
        speechStarted = nil
        log(String(format: "%@ first word after %.3fs", engine, ProcessInfo.processInfo.systemUptime - started))
        request?.trace("first word (\(engine))")
        ReaderModel.shared.activity = "Reading"
    }

    private func monitorSpeechStart(_ generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard generation == self.speechGeneration, self.speechStarted != nil else { return }
            self.request?.trace("waiting for voice")
            ReaderModel.shared.activity = "Waiting for the voice to start…"
        }
    }

    private func fetchEleven(_ off: Int, _ text: String, _ voiceID: String, _ gen: Int) {
        guard elCache[off] == nil else { return }
        elCache[off] = (nil, [], "pending")
        let finished: (Data?, [ElevenWord], String?) -> Void = { audio, words, err in
            DispatchQueue.main.async {
                guard gen == self.elGen else { return }
                let r = (audio, words, err)
                self.elCache[off] = r
                if let w = self.elWaiting.removeValue(forKey: off) { w(audio, words, err) }
            }
        }
        if voiceID.hasPrefix(Kokoro.prefix) {
            Kokoro.shared.speech(text, voice: String(voiceID.dropFirst(Kokoro.prefix.count)), gen: readingNumber + gen, finished)
        } else {
            Eleven.shared.speech(text, voice: String(voiceID.dropFirst(Eleven.prefix.count)), finished)
        }
    }

    private func nextElevenPiece(_ voiceID: String, _ gen: Int) {
        guard gen == elGen, elReading else { return }
        guard !elQueue.isEmpty else { elReading = false; onDone?(); return }
        let (off, text) = elQueue.removeFirst()
        let play: (Data?, [ElevenWord], String?) -> Void = { audio, words, err in
            guard gen == self.elGen, self.elReading else { return }
            guard let a = audio, let player = try? AVAudioPlayer(data: a) else {
                // ElevenLabs couldn't be reached: carry on with an Apple voice from here.
                log("\(voiceID.hasPrefix(Kokoro.prefix) ? "Kokoro" : "ElevenLabs") failed (\(err ?? "no audio")); using an Apple voice")
                let rest = [(off, text)] + self.elQueue
                self.elReading = false; self.elQueue = []
                self.speakApple(rest)
                return
            }
            self.elPlayer = player; player.delegate = self
            self.elWords = words.isEmpty ? estimateWords(text, duration: player.duration) : words
            self.elOffset = off; self.elLastWord = -1
            player.prepareToPlay(); player.play()
            self.markSpeechStarted(voiceID.hasPrefix(Kokoro.prefix) ? "Kokoro" : "ElevenLabs")
            self.elTimer?.invalidate()
            self.elTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in self.elevenTick() }
            // Get the next piece ready while this one plays, so there's no gap.
            for next in self.elQueue.prefix(2) { self.fetchEleven(next.0, next.1, voiceID, gen) }
            if let t0 = self.elStarted {
                log(String(format: "voice started in %.1fs", Date().timeIntervalSince(t0))); self.elStarted = nil
            }
        }
        if let c = elCache[off], c.2 != "pending" { play(c.0, c.1, c.2) }
        else { elWaiting[off] = play; fetchEleven(off, text, voiceID, gen) }
    }

    private func elevenTick() {
        guard let p = elPlayer, !elWords.isEmpty else { return }
        let t = p.currentTime
        var i = elLastWord
        while i + 1 < elWords.count && elWords[i + 1].start <= t { i += 1 }
        if i != elLastWord && i >= 0 {
            elLastWord = i
            onWord?(NSRange(location: elOffset + elWords[i].loc, length: elWords[i].len))
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard player === self.elPlayer, self.elReading, let v = self.elevenVoice else { return }
            self.elTimer?.invalidate()
            self.nextElevenPiece(v, self.elGen)
        }
    }

    func pauseOrResume() {
        if elReading {
            if elPaused { elPlayer?.play(); elPaused = false } else { elPlayer?.pause(); elPaused = true }
            return
        }
        if sysReading || sys.isSpeaking || sysPaused {
            if sysPaused { sys.continueSpeaking(); sysPaused = false }
            else { sys.pauseSpeaking(at: .wordBoundary); sysPaused = true }
            return
        }
        if synth.isPaused { synth.continueSpeaking() }
        else if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
    }

    func stop(autoReadStop: Bool = false) {
        if !autoReadStop { AIAutoReader.shared.suppressPending() }
        ClickReader.shared.cancelPending()
        request?.trace("stopped"); request = nil
        ReaderModel.shared.activity = "Stopped"
        let wasReading = isReading
        halt()
        if wasReading { onDone?() }
        Reading.shared.generation += 1
        Overlay.shared.hide()
    }

    // System Voice (Siri) callbacks
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord characterRange: NSRange, of string: String) {
        DispatchQueue.main.async {
            guard sender === self.sys, self.sysPending == nil, self.sysBusy else { return }
            self.markSpeechStarted("system voice")
            guard self.sysReading else { return }
            self.onWord?(NSRange(location: characterRange.location + self.sysOffset, length: characterRange.length))
        }
    }
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        DispatchQueue.main.async {
            guard sender === self.sys else { return }
            self.sysBusy = false
            if self.sysPending != nil { self.startPendingSystem(); return }
            guard self.sysReading else { return }
            self.sysReading = false; self.speechStarted = nil
            self.onDone?()
        }
    }

    // Reader+ voice callbacks
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        DispatchQueue.main.async {
            guard let off = self.offsets[id] else { return }
            self.markSpeechStarted("Apple voice")
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
/// A voice sample: spoken with the chosen reading voice (ElevenLabs too).
func sample(_ s: String) { Speaker.shared.request = nil; Speaker.shared.say(s, track: true) }

// MARK: - Bounded, cancellable accessibility work

/// A slow or unresponsive target must never hold the mouse event callback or UI thread.
final class AXWork: NSObject {
    static let key = "ReaderPlus.AXWork"
    let deadline: TimeInterval
    let valid: () -> Bool
    var calls = 0
    var timeouts = 0
    var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline || !valid() }
    init(seconds: Double, valid: @escaping () -> Bool = { true }) {
        deadline = ProcessInfo.processInfo.systemUptime + seconds; self.valid = valid
    }
    static var current: AXWork? { Thread.current.threadDictionary[key] as? AXWork }
    static func run<T>(seconds: Double, valid: @escaping () -> Bool = { true }, _ body: () -> T) -> T {
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = AXWork(seconds: seconds, valid: valid)
        defer { Thread.current.threadDictionary[key] = previous }
        return body()
    }
    static func prepare(_ e: AXUIElement) -> Bool {
        guard let w = current else { AXUIElementSetMessagingTimeout(e, 0.15); return true }
        guard !w.expired else { return false }
        w.calls += 1
        AXUIElementSetMessagingTimeout(e, Float(min(0.12, max(0.001, w.deadline - ProcessInfo.processInfo.systemUptime))))
        return true
    }
}

final class ReadRequest {
    let id: Int
    let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var cancelled = false
    init(_ id: Int) { self.id = id }
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func trace(_ stage: String) {
        log(String(format: "read #%d %@ at %.3fs", id, stage, ProcessInfo.processInfo.systemUptime - started))
    }
}

// MARK: - Accessibility helpers

func ax(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
    guard AXWork.prepare(e) else { return nil }
    var v: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(e, attr as CFString, &v)
    if result == .cannotComplete { AXWork.current?.timeouts += 1 }
    return result == .success ? v : nil
}
func axString(_ e: AXUIElement, _ attr: String) -> String? { ax(e, attr) as? String }
func axElement(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = ax(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func axChildren(_ e: AXUIElement) -> [AXUIElement] { (ax(e, "AXChildren") as? [AXUIElement]) ?? [] }
func axParam(_ e: AXUIElement, _ attr: String, _ p: CFTypeRef) -> CFTypeRef? {
    guard AXWork.prepare(e) else { return nil }
    var v: CFTypeRef?
    let result = AXUIElementCopyParameterizedAttributeValue(e, attr as CFString, p, &v)
    if result == .cannotComplete { AXWork.current?.timeouts += 1 }
    return result == .success ? v : nil
}
func axRangeValue(_ v: CFTypeRef?) -> CFRange? {
    guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var r = CFRange()
    guard AXValueGetValue(v as! AXValue, .cfRange, &r),
          r.location >= 0, r.location != NSNotFound, r.length >= 0, r.length != NSNotFound, r.location <= Int.max - r.length else { return nil }
    return r
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
    AXUIElementSetMessagingTimeout(e, 0.12)
    exposeText(app.processIdentifier)
    return e
}

var exposedPIDs = Set<pid_t>()
let exposedLock = NSLock()
/// Chromium and Electron apps (Chrome, Claude, ChatGPT, Slack, Discord…) only share their page text with
/// assistive apps once asked. VoiceOver asks automatically; Reader+ asks here.
func exposeText(_ pid: pid_t) {
    guard pid != ProcessInfo.processInfo.processIdentifier else { return }
    exposedLock.lock()
    let fresh = exposedPIDs.insert(pid).inserted
    exposedLock.unlock()
    guard fresh else { return }
    DispatchQueue.global(qos: .userInitiated).async {
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.15)
        let result = AXUIElementSetAttributeValue(e, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .cannotComplete {
            exposedLock.lock(); exposedPIDs.remove(pid); exposedLock.unlock()
        }
    }
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

/// The height of one line of text inside an element (from its smallest piece of text).
func lineHeight(in e: AXUIElement) -> CGFloat {
    var best: CGFloat = 0, seen = 0
    func walk(_ x: AXUIElement, _ d: Int) {
        if d > 4 || seen > 60 { return }
        seen += 1
        if axString(x, "AXRole") == "AXStaticText", let f = axFrame(x), f.height >= 8 {
            if best == 0 || f.height < best { best = f.height }
        }
        for c in axChildren(x) { walk(c, d + 1) }
    }
    walk(e, 0)
    return best > 0 ? min(max(best, 12), 64) : 22
}

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
func collectBlocks(_ root: AXUIElement, from startNode: AXUIElement? = nil, sectionOnly: Bool = false, paragraphOnly: Bool = false) -> [DocBlock] {
    if paragraphOnly, let start = startNode, axString(start, "AXRole") != "AXHeading" {
        // A paragraph may split a sentence into nested bold/link/span containers. Read its
        // complete subtree rather than treating the first formatting boundary as the end.
        let text = collectText(start).trimmed
        return text.isEmpty ? [] : [DocBlock(element: start, text: text, heading: 0)]
    }
    var blocks: [DocBlock] = []
    var visited = 0
    var finished = false
    var path: [AXUIElement] = []
    if let st = startNode {
        let up = ancestors(st, max: 150)
        if let ri = up.firstIndex(where: { CFEqual($0, root) }) { path = Array(up[0...ri].reversed()) }
    }
    func add(_ text: String, _ container: AXUIElement, _ heading: Int) {
        if finished { return }
        if let first = blocks.first {
            if paragraphOnly && first.heading == 0 && !CFEqual(first.element, container) { finished = true; return }
            if sectionOnly && first.heading > 0 && heading > 0 && heading <= first.heading && !CFEqual(first.element, container) { finished = true; return }
        }
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
        if finished || AXWork.current?.expired == true || visited > 40000 || depth > 150 { return }
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

/// Returns only valid UTF-16 paragraph ranges. Missing/invalid positions must use the
/// screen-text fallback rather than crashing or silently reading the start of a document.
func clickedReadingRange(_ text: NSString, at location: Int?, paragraphOnly: Bool) -> NSRange? {
    guard let location = location, location >= 0, location < text.length else { return nil }
    let para = text.paragraphRange(for: NSRange(location: location, length: 0))
    return paragraphOnly ? para : NSRange(location: para.location, length: text.length - para.location)
}

/// ⌘-click: read by structure at a screen point (top-left coordinates). Returns nil if there's nothing to read.
func readSourceAt(_ p: CGPoint, hitElement: AXUIElement? = nil) -> ReadSource? {
    var found: AXUIElement? = hitElement
    if found == nil { _ = AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &found) }
    guard let hit = found else { return nil }
    let chain = ancestors(hit)
    let paragraphOnly = prefs.integer(forKey: Key.paragraphMode) == 1

    // Documents (TextEdit, Notes, Pages text…): read from the clicked paragraph.
    if let ta = chain.first(where: { axString($0, "AXRole") == "AXTextArea" }),
       !chain.contains(where: { axString($0, "AXRole") == "AXWebArea" }),
       let v = axString(ta, "AXValue"), !v.trimmed.isEmpty {
        let ns = v as NSString
        let idx = axRangeValue(axParam(ta, "AXRangeForPosition", makePoint(p)))?.location
        guard let r = clickedReadingRange(ns, at: idx, paragraphOnly: paragraphOnly) else { return nil }
        return ReadSource(text: ns.substring(with: r), element: ta, base: r.location)
    }

    // Buttons, boxes, checkboxes, menus and the like: say what they are, like "Subscribe, button".
    let hitRole = axString(hit, "AXRole") ?? ""
    if (controlRoles.contains(hitRole) && hitRole != "AXLink") || chain.prefix(4).contains(where: {
        let role = axString($0, "AXRole") ?? ""
        return controlRoles.contains(role) && role != "AXLink"
    }) {
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
            let blocks = collectBlocks(area, from: blockStart(chain, within: area), sectionOnly: true, paragraphOnly: paragraphOnly)
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
    let blocks = collectBlocks(root, from: blockStart(chain, within: root), sectionOnly: true, paragraphOnly: paragraphOnly)
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
        if AXWork.current?.expired == true || pressed || visited > 4000 || depth > 60 { return }
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
func clickUse(_ p: CGPoint, hitElement: inout AXUIElement?, targetPID: inout pid_t) -> ClickUse {
    var found: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &found) == .success, let hit = found else { return .read }
    hitElement = hit
    AXUIElementSetMessagingTimeout(hit, 0.25)
    var pid: pid_t = 0
    if AXUIElementGetPid(hit, &pid) == .success {
        targetPID = pid
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
        if AXWork.current?.expired == true || visited > 8000 || depth > 70 { return }
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
func ownWindowHit(_ cp: NSPoint, applicationIsActive: Bool = NSApp.isActive,
                  windows: [NSWindow]? = nil) -> (inOwnWindow: Bool, textView: NSTextView?, index: Int) {
    // A window can be visible while covered by Chrome or another app. Its rectangle is not a hit.
    // Only handle Reader+'s text directly while Reader+ is the active app. Otherwise let the
    // normal background accessibility lookup read the actual foreground app at this point.
    guard applicationIsActive else { return (false, nil, 0) }
    for w in windows ?? NSApp.orderedWindows where w.isVisible && !w.ignoresMouseEvents && w.frame.contains(cp) {
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
func withSelectedText(request: ReadRequest? = nil, _ done: @escaping (String?, AXUIElement?, Int) -> Void) {
    if NSApp.isActive {
        // Reader+ itself is in front (the tour's practice box, the reading window…)
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.selectedRange().length > 0 {
            done((tv.string as NSString).substring(with: tv.selectedRange()), nil, 0)
        } else { done(nil, nil, 0) }
        return
    }
    DispatchQueue.global(qos: .userInitiated).async {
        let selection: (String, AXUIElement?, Int)? = AXWork.run(seconds: 0.6, valid: { request?.valid != false }) {
            frontAppElement()
            guard let f = focusedElement(), let s = axString(f, "AXSelectedText"), !s.trimmed.isEmpty else { return nil }
            let loc = axRangeValue(ax(f, "AXSelectedTextRange"))?.location ?? -1
            return (s, loc >= 0 ? f : nil, max(loc, 0))
        }
        DispatchQueue.main.async {
            guard request?.valid != false else { return }
            if let selection = selection { done(selection.0, selection.1, selection.2); return }
            let pb = NSPasteboard.general
            let before = pb.changeCount
            // Preserve all clipboard formats, including images, when copying is needed as a fallback.
            let saved = (pb.pasteboardItems ?? []).map { item in
                item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                    guard let data = item.data(forType: type) else { return nil }; return (type, data)
                }
            }
            postKey(CGKeyCode(kVK_ANSI_C), .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard pb.changeCount != before else { if request?.valid != false { done(nil, nil, 0) }; return }
                let s = pb.string(forType: .string)
                pb.clearContents()
                let items = saved.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                pb.writeObjects(items)
                guard request?.valid != false else { return }
                done(s, nil, 0)
            }
        }
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
        guard prefs.bool(forKey: Key.screenHighlight), r.width > 0, r.height > 0, r.width < 2400, r.height < (NSScreen.main?.frame.height ?? 1000) * 0.85 else { hide(); return }
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
    var generation = 0

    init() {
        Speaker.shared.onWord = { [weak self] r in self?.word(r) }
        Speaker.shared.onDone = {
            ReaderWindow.shared.setPlaying(false); Overlay.shared.hide()
            if ReaderModel.shared.activity == "Reading" { ReaderModel.shared.activity = "Finished" }
        }
    }

    func start(_ src: ReadSource, from: Int = 0, showWindow: Bool = true, request: ReadRequest? = nil, autoRead: Bool = false) {
        if !autoRead { AIAutoReader.shared.suppressPending() }
        ClickReader.shared.cancelPending()
        generation += 1
        Speaker.shared.request = request
        source = src
        let ns = src.text as NSString
        offset = max(0, min(from, ns.length))
        lastWord = NSRange(location: offset, length: 0)
        currentBlock = -1; lastParagraph = -1; lastLine = -1
        if showWindow && prefs.bool(forKey: Key.showReader) && ns.length > 60 { ReaderWindow.shared.show(src.text) }
        ReaderWindow.shared.setPlaying(true)
        Speaker.shared.say(ns.substring(from: offset), track: true)
    }

    func word(_ r: NSRange) {
        let full = NSRange(location: r.location + offset, length: r.length)
        lastWord = full
        if ReaderWindow.shared.isVisible { ReaderWindow.shared.highlight(full) }
        guard let src = source else { return }
        if let e = src.element {
            let ns = src.text as NSString
            guard full.location < ns.length else { return }
            let para = ns.paragraphRange(for: NSRange(location: full.location, length: 0))
            if para.location != lastParagraph {
                lastParagraph = para.location
                let token = generation
                DispatchQueue.global(qos: .utility).async {
                    let rect = AXWork.run(seconds: 0.2) {
                        axRectValue(axParam(e, "AXBoundsForRange", makeRange(src.base + para.location, max(1, para.length))))
                    }
                    DispatchQueue.main.async {
                        guard token == self.generation, Speaker.shared.isReading, let rect = rect else { return }
                        Overlay.shared.show(axRect: rect)
                    }
                }
            }
        } else if let bi = blockIndex(at: full.location) {
            if bi != currentBlock {
                // A new paragraph: bring it on screen and learn its size and line height.
                currentBlock = bi; blockFrame = nil; lastLine = -1
                let el = src.blocks[bi].element
                let token = generation
                DispatchQueue.global(qos: .userInitiated).async {
                    AXUIElementSetMessagingTimeout(el, 0.12)
                    AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
                    usleep(120_000)
                    let f = axFrame(el)
                    let lh = lineHeight(in: el)
                    DispatchQueue.main.async {
                        guard self.generation == token, Speaker.shared.isReading, self.currentBlock == bi, let f = f else { return }
                        self.blockFrame = f; self.blockLineHeight = lh
                        self.followLine(self.lastWord)
                    }
                }
            } else { followLine(full) }
        }
    }

    // The yellow outline follows the line being read inside the current paragraph.
    var blockFrame: CGRect?
    var blockLineHeight: CGFloat = 22
    var lastLine = -1

    var lastParagraph = -1
    var lastFrameCheck = Date.distantPast

    func followLine(_ full: NSRange) {
        guard let src = source, currentBlock >= 0, currentBlock < src.blocks.count, let f = blockFrame else { return }
        if lastLine != currentBlock {
            lastLine = currentBlock
            Overlay.shared.show(axRect: f)
        }
        // If the page was scrolled, move the outline with the paragraph (checked twice a second).
        guard Date().timeIntervalSince(lastFrameCheck) > 0.5 else { return }
        lastFrameCheck = Date()
        let el = src.blocks[currentBlock].element, bi = currentBlock, token = generation
        DispatchQueue.global(qos: .utility).async {
            if let nf = axFrame(el), nf != f {
                DispatchQueue.main.async {
                    if token == self.generation && Speaker.shared.isReading && self.currentBlock == bi { self.blockFrame = nf; Overlay.shared.show(axRect: nf) }
                }
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
        let q = axPoint(p), token = Reading.shared.generation
        DispatchQueue.global(qos: .userInitiated).async {
            let found = textAt(q)
            DispatchQueue.main.async {
                self.busy = false
                guard prefs.bool(forKey: Key.mouseEcho), !Speaker.shared.isReading,
                      !ClickReader.shared.hasPending, token == Reading.shared.generation,
                      NSEvent.mouseLocation == p, let f = found else { return }
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

    func flagsChanged(_ code: Int64, _ flags: CGEventFlags, source: Int64 = 0) {
        let isControl = code == 59 || code == 62
        // Only a real key on your keyboard counts. Other apps sometimes send pretend Control presses
        // (remote control, automation, accessibility tools); those must never stop the reading.
        if isControl && source != 0, source != Int64(ProcessInfo.processInfo.processIdentifier),
           NSRunningApplication(processIdentifier: pid_t(source)) != nil {
            if controlAlone || flags.contains(.maskControl) { log("ignored a Control press sent by another app (pid \(source))") }
            controlAlone = false; return
        }
        let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
        if isControl && flags.contains(.maskControl) && flags.intersection(others).isEmpty {
            controlAlone = true; controlDownAt = Date()
        } else if isControl && !flags.contains(.maskControl) && controlAlone {
            controlAlone = false
            // Only a quick tap stops speech. Holding Control (to zoom with the magnifier) doesn't.
            // A quick tap only (holding Control to zoom doesn't count), and only if that setting is on.
            if Date().timeIntervalSince(controlDownAt) < 0.35 && !prefs.bool(forKey: "noControlStop") && (Speaker.shared.isReading || Speaker.shared.isSpeaking || ClickReader.shared.hasPending) {
                Speaker.shared.stop(); Overlay.shared.hide(); log("stopped by tapping Control")
            }
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
        let src = event.getIntegerValueField(.eventSourceUnixProcessID); DispatchQueue.main.async { KeyEcho.shared.flagsChanged(code, flags, source: src) }
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

/// Takes a picture of the visible text, excluding only the click-through highlight overlay.
func captureScreen(_ rect: CGRect, _ done: @escaping (CGImage?, CGRect) -> Void) {
    guard #available(macOS 14.0, *) else { done(nil, rect); return }
    let overlayID = CGWindowID(clamping: Overlay.shared.win.windowNumber)
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else { done(nil, rect); return }
            let overlays = content.windows.filter { $0.windowID == overlayID }
            let filter = SCContentFilter(display: display, excludingWindows: overlays)
            let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            guard local.width > 4, local.height > 4 else { done(nil, rect); return }
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.sourceRect = local
            cfg.width = Int(local.width * scale)
            cfg.height = Int(local.height * scale)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            done(img, local.offsetBy(dx: display.frame.minX, dy: display.frame.minY))
        } catch {
            log("screen capture failed: \(error.localizedDescription)")
            done(nil, rect)
        }
    }
}

struct OCRLine {
    let text: String
    let bounds: CGRect // normalized Vision coordinates, bottom-left origin
}

/// Whole pictures are read top-to-bottom. For the click fallback, select the paragraph
/// containing the pointer, rather than reading unrelated text above it or in another column.
func recognizedText(_ lines: [OCRLine], readingAt point: CGPoint? = nil) -> String {
    let sorted = lines.filter { !$0.text.trimmed.isEmpty }.sorted { a, b in
        abs(a.bounds.midY - b.bounds.midY) > 0.012 ? a.bounds.midY > b.bounds.midY
                                                                : a.bounds.minX < b.bounds.minX
    }
    guard !sorted.isEmpty else { return "" }
    var selected = sorted
    if let point = point {
        func distance(_ line: OCRLine) -> CGFloat {
            let r = line.bounds
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return dx * dx + 4 * dy * dy
        }
        guard let anchor = sorted.min(by: { distance($0) < distance($1) }) else { return "" }
        let column = sorted.filter { line in
            let overlap = min(anchor.bounds.maxX, line.bounds.maxX) - max(anchor.bounds.minX, line.bounds.minX)
            return overlap > min(anchor.bounds.width, line.bounds.width) * 0.3 || abs(anchor.bounds.minX - line.bounds.minX) < 0.02
        }
        guard let at = column.firstIndex(where: { $0.bounds == anchor.bounds && $0.text == anchor.text }) else { return anchor.text }
        func adjoining(_ upper: OCRLine, _ lower: OCRLine) -> Bool {
            let gap = upper.bounds.minY - lower.bounds.maxY
            let height = max(upper.bounds.height, lower.bounds.height)
            return upper.bounds.midY > lower.bounds.midY && gap >= -height * 0.2 && gap <= height * 0.8
        }
        var first = at, last = at
        while first > 0 && adjoining(column[first - 1], column[first]) { first -= 1 }
        while last + 1 < column.count && adjoining(column[last], column[last + 1]) { last += 1 }
        selected = Array(column[first...last])
    }
    var out = ""
    for line in selected {
        if out.isEmpty { out = line.text.trimmed; continue }
        out += ".!?:".contains(out.last ?? " ") ? "\n" + line.text.trimmed : " " + line.text.trimmed
    }
    return out
}

/// Finds the words in a picture, with optional pointer-based paragraph selection.
func recognizeText(_ img: CGImage, readingAt point: CGPoint? = nil, _ done: @escaping (String) -> Void) {
    let req = VNRecognizeTextRequest { r, _ in
        let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
        let lines = obs.compactMap { o -> OCRLine? in
            guard let text = o.topCandidates(1).first?.string.trimmed, !text.isEmpty else { return nil }
            return OCRLine(text: text, bounds: o.boundingBox)
        }
        done(recognizedText(lines, readingAt: point))
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
func ocrRead(_ rect: CGRect, fallback: String? = nil, showWindow: Bool = true, request: ReadRequest? = nil, readingAt point: CGPoint? = nil) {
    guard request?.valid != false else { return }
    guard #available(macOS 14.0, *) else {
        if request != nil { ClickReader.shared.cancelPending() }
        ReaderModel.shared.activity = "Screen-text reading needs macOS 14 or later."
        say("Reading text in pictures needs macOS 14 or later."); return
    }
    guard hasScreenRecording else {
        if request != nil { ClickReader.shared.cancelPending() }
        ReaderModel.shared.activity = "Screen Recording permission is needed for screen text."
        askForScreenRecording(); return
    }
    Overlay.shared.show(axRect: rect, for: 1.2)
    request?.trace("OCR started")
    captureScreen(rect) { img, capturedRect in
        guard request?.valid != false else { return }
        guard let img = img else {
            DispatchQueue.main.async {
                guard request?.valid != false else { return }
                if request != nil { ClickReader.shared.cancelPending() }
                ReaderModel.shared.activity = "Could not capture that part of the screen."
                say("I couldn't look at the screen there.")
            }
            return
        }
        let normalized = point.map { p in CGPoint(x: (p.x - capturedRect.minX) / capturedRect.width,
                                                  y: 1 - (p.y - capturedRect.minY) / capturedRect.height) }
        recognizeText(img, readingAt: normalized) { text in
            DispatchQueue.main.async {
                guard request?.valid != false else { return }
                if !text.trimmed.isEmpty {
                    log("OCR read \(text.count) characters")
                    let src = ReadSource(text: text, element: nil, base: 0)
                    if let r = request { ClickReader.shared.deliver(src, request: r, showWindow: showWindow) }
                    else { Reading.shared.start(src, showWindow: showWindow) }
                } else if let f = fallback, !f.trimmed.isEmpty {
                    if let r = request { ClickReader.shared.deliver(ReadSource(text: f, element: nil, base: 0), request: r, showWindow: showWindow) }
                    else { say(f) }
                } else {
                    if request != nil { ClickReader.shared.cancelPending() }
                    ReaderModel.shared.activity = "No words found in that part of the screen."
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
    private var serial = 0
    private var pending: ReadRequest?
    var hasPending: Bool { pending?.valid == true }
    static let replayMarker: Int64 = 0x52504C5553
    final class CapturedClick {
        let down: CGEvent
        var up: CGEvent?
        var pass = false
        var targetPID: pid_t
        init(_ event: CGEvent) {
            down = event.copy()!
            targetPID = pid_t(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
        }
    }
    private var heldClick: CapturedClick?

    func cancelPending() { pending?.cancel(); pending = nil }
    private func makeRequest() -> ReadRequest {
        cancelPending(); serial += 1
        let r = ReadRequest(serial); pending = r
        return r
    }
    func begin() -> ReadRequest {
        let r = makeRequest()
        prepare(r)
        return r
    }
    private func prepare(_ r: ReadRequest) {
        guard r.valid else { return }
        pending = nil
        Speaker.shared.stop()
        pending = r
        ReaderModel.shared.activity = "Getting text…"
        r.trace("click received")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard self.pending === r, r.valid else { return }
            ReaderModel.shared.activity = "Waiting for the app to provide text…"
            r.trace("waiting for app text")
        }
    }
    private func replay(_ event: CGEvent, to targetPID: pid_t) {
        guard targetPID > 0 else { log("native click target unavailable; not replaying into a different app"); return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event.postToPid(targetPID)
    }
    func capture(_ event: CGEvent) {
        let click = CapturedClick(event), point = event.location
        heldClick = click
        let r = makeRequest()
        // Return to the event tap before stopping speech, logging, or contacting another app.
        DispatchQueue.main.async {
          if r.valid { self.prepare(r) }
          // Classification must still finish for a cancelled reading: a real native
          // selection click and its mouse-up must not disappear with the speech request.
          DispatchQueue.global(qos: .userInitiated).async {
            var hit: AXUIElement?
            var pid: pid_t = 0
            let use = AXWork.run(seconds: 0.35) { clickUse(point, hitElement: &hit, targetPID: &pid) }
            r.trace("click classified")
            DispatchQueue.main.async {
                if click.targetPID <= 0 { click.targetPID = pid }
                if use == .readAndPass || use == .ignore {
                    click.pass = true
                    self.replay(click.down, to: click.targetPID)
                    if let up = click.up { self.replay(up, to: click.targetPID) }
                }
                guard r.valid else { return }
                self.read(at: point, request: r, hitElement: hit)
            }
          }
        }
    }
    func release(_ event: CGEvent) -> Bool {
        guard let click = heldClick else { return false }
        heldClick = nil
        if click.pass { replay(event.copy()!, to: click.targetPID) } else { click.up = event.copy() }
        return true
    }
    func deliver(_ src: ReadSource?, request r: ReadRequest, showWindow: Bool) {
        guard r.valid else { return }
        pending = nil
        guard let s = src, !s.text.trimmed.isEmpty else {
            ReaderModel.shared.activity = "No readable text found here."
            r.trace("no readable text")
            return
        }
        r.trace("text ready (\(s.text.count) characters)")
        Reading.shared.start(s, showWindow: showWindow, request: r)
    }

    /// ⌘-right-click: read the whole page or window under the pointer, from the top.
    func readPage(at p: CGPoint) {
        let showWindow = prefs.bool(forKey: Key.clickShowsReader)
        let request = begin()
        DispatchQueue.global(qos: .userInitiated).async {
          AXWork.run(seconds: 3, valid: { request.valid }) {
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
            if AXWork.current?.expired == true { src = nil; request.trace("whole-page lookup timed out; using visible-screen OCR") }
            DispatchQueue.main.async {
                guard request.valid else { return }
                if src != nil { self.deliver(src, request: request, showWindow: showWindow); return }
                let rect = windowFrame(at: p) ?? CGRect(x: p.x - 450, y: p.y - 250, width: 900, height: 500)
                ocrRead(rect, showWindow: showWindow, request: request)
            }
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
        guard mode != 0, f.contains(.maskCommand) else { return false }
        return mode != 2 || f.contains(.maskAlternate)
    }

    func read(at p: CGPoint, request: ReadRequest? = nil, hitElement: AXUIElement? = nil) {
        let r = request ?? begin()
        let showWindow = prefs.bool(forKey: Key.clickShowsReader)
        DispatchQueue.global(qos: .userInitiated).async {
            guard r.valid else { return }
            var hit: AXUIElement? = hitElement
            if hit == nil { _ = AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) }
            guard r.valid else { return }
            let image: (CGRect, String?)? = AXWork.run(seconds: 0.25, valid: { r.valid }) {
                guard let h = hit else { return nil }
                let up = ancestors(h, max: 6)
                guard let im = up.prefix(4).first(where: { axString($0, "AXRole") == "AXImage" }),
                      let f = axFrame(im), f.width >= 24, f.height >= 24 else { return nil }
                let link = up.first(where: { axString($0, "AXRole") == "AXLink" })
                if let link = link, collectText(link).trimmed.count >= 3 { return nil }
                return (f, axString(im, "AXDescription") ?? axString(im, "AXTitle"))
            }
            r.trace("hit and image check complete")
            if let image = image {
                DispatchQueue.main.async {
                    guard r.valid else { return }
                    ocrRead(image.0, fallback: image.1, showWindow: showWindow, request: r)
                }
                return
            }
            var timedOut = false
            let src = AXWork.run(seconds: 3.0, valid: { r.valid }) {
                let result = readSourceAt(p, hitElement: hit)
                timedOut = AXWork.current?.expired == true
                let work = AXWork.current!
                r.trace("text lookup (\(work.calls) queries, \(work.timeouts) timeouts)")
                return result
            }
            r.trace("structure complete")
            DispatchQueue.main.async {
                guard r.valid else { return }
                if timedOut {
                    r.trace("text lookup deadline exceeded; reading screen text instead")
                    ReaderModel.shared.activity = "Reading text from the screen…"
                    ocrRead(CGRect(x: p.x - 450, y: p.y - 140, width: 900, height: 280), showWindow: showWindow, request: r, readingAt: p)
                    return
                }
                if let s = src, !s.text.trimmed.isEmpty { self.deliver(s, request: r, showWindow: showWindow); return }
                ocrRead(CGRect(x: p.x - 450, y: p.y - 140, width: 900, height: 280), showWindow: showWindow, request: r, readingAt: p)
            }
        }
    }

}

let clickTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if event.getIntegerValueField(.eventSourceUserData) == ClickReader.replayMarker { return Unmanaged.passUnretained(event) }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("click event listener re-enabled after timeout or user input")
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
            if type == .flagsChanged { let src = event.getIntegerValueField(.eventSourceUnixProcessID); DispatchQueue.main.async { KeyEcho.shared.flagsChanged(code, flags, source: src) } }
            else { DispatchQueue.main.async { KeyEcho.shared.controlAlone = false } }
        }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown, ClickReader.modifiersMatch(event.flags) {
        ClickReader.shared.capture(event)
        return nil
    }
    if type == .leftMouseUp && ClickReader.shared.release(event) { return nil }
    if type == .leftMouseUp && ClickReader.shared.swallowUp {
        ClickReader.shared.swallowUp = false
        return nil
    }
    let cr = ClickReader.shared
    let talking = Speaker.shared.isReading
    // ⌘-right-click: stop while talking, otherwise read the whole page or window.
    if type == .rightMouseDown, ClickReader.modifiersMatch(event.flags) {
        let p = event.location
        if talking || Speaker.shared.isSpeaking || cr.hasPending {
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
            DispatchQueue.main.async { cr.readPage(at: p) }
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
            let intent = ClickReader.shared.begin()
            a.activate(options: [])
            Self.finishSwitch(intent, action)
        } else { action() }
    }
    static func finishSwitch(_ intent: ReadRequest, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard intent.valid else { return }
            action()
        }
    }
}

var appDel: AppDelegate { NSApp.delegate as! AppDelegate }

/// Keeps the SwiftUI window in step with settings changed elsewhere (hotkeys, menu bar).
final class ReaderModel: ObservableObject {
    static let shared = ReaderModel()
    @Published var tick = 0
    @Published var activity = "Ready"
    @Published var aiStatus = "Waiting for a supported AI web chat"
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
                Text(model.activity).accessibilityLabel("Reading status: " + model.activity)
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
            Section("AI Answers") {
                Toggle("Automatically read completed AI answers", isOn: model.bool(Key.aiAutoRead))
                    .onChange(of: prefs.bool(forKey: Key.aiAutoRead)) { _ in AIAutoReader.shared.reset() }
                Toggle("Stop the previous AI reading when a new answer starts", isOn: model.bool(Key.aiInterrupt))
                Toggle("Show the reading window for AI answers", isOn: model.bool(Key.aiShowWindow))
                Picker("Wait after completion", selection: Binding(get: { prefs.double(forKey: Key.aiDelay) }, set: { prefs.set($0, forKey: Key.aiDelay); model.changed() })) {
                    Text("2 seconds").tag(2.0)
                    Text("4 seconds").tag(4.0)
                    Text("6 seconds").tag(6.0)
                }
                Text(model.aiStatus).accessibilityLabel("AI reading status: " + model.aiStatus)
                Text("Reads new answers in the active supported AI web chat. Requires exposed assistant labels, a generation indicator and a completed response control. Existing chats are not read on opening. Uses your selected voice and speed, including any selected online voice service. Tap Control to stop; use the reading controls to pause.")
                    .font(.callout).foregroundStyle(.secondary)
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
                Toggle("Tapping Control stops reading", isOn: Binding(get: { !prefs.bool(forKey: "noControlStop") },
                                                                      set: { prefs.set(!$0, forKey: "noControlStop"); model.changed() }))
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
    @State private var keyField = ""
    @State private var elStatus = ""
    @State private var busy = false
    @State private var koBusy = Kokoro.shared.installing
    @State private var koStatus = ""
    func installKokoro() {
        koBusy = true; koStatus = "Starting the install…"
        Kokoro.shared.install({ if koBusy { koStatus = $0 + "…" } }) { ok in
            koBusy = false
            if ok {
                koStatus = "Installed. Heart is now your voice; pick another Kokoro voice above if you like."
                prefs.set(Kokoro.prefix + "af_heart", forKey: Key.voice)
                Kokoro.shared.warmUp()
                sample("Hi, I'm Heart, one of your new Kokoro voices. I run right here on your Mac.")
            } else {
                koStatus = "The install didn't finish. Check your internet connection and try again."
            }
            model.changed()
        }
    }
    func loadVoices() {
        busy = true; elStatus = "Loading your ElevenLabs voices…"
        Eleven.shared.loadVoices { err in
            busy = false
            elStatus = err ?? "Loaded \(Eleven.shared.voices.count) voices. Pick one in the Voice menu above."
            model.changed()
        }
    }
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
                        if Speaker.shared.isReading { Reading.shared.restartHere() } else { sample("This is my voice.") }
                    })) {
                    Text("Siri / System Voice").tag("")
                    if Kokoro.shared.isInstalled {
                        Divider()
                        ForEach(Kokoro.shared.voices, id: \.id) { v in Text("\(v.name) (Kokoro)").tag(Kokoro.prefix + v.id) }
                    }
                    if Eleven.shared.hasKey && !Eleven.shared.voices.isEmpty {
                        Divider()
                        ForEach(Eleven.shared.voices, id: \.id) { v in Text("\(v.name) (ElevenLabs)").tag(Eleven.prefix + v.id) }
                    }
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
                                   if !editing { if Speaker.shared.isReading { Reading.shared.restartHere() } else { sample("This is my speed.") } }
                               })
                        Image(systemName: "hare.fill").foregroundStyle(.secondary)
                        Text("\(Int((rate * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .frame(maxWidth: 360)
                }
                HStack {
                    Spacer()
                    Button("Test Voice") { sample("Hello. This is how Reader plus sounds.") }
                    Button("Choose Siri Voice…") { appDel.moreVoices() }
                }
            } footer: {
                Text("Siri / System Voice speaks with the voice chosen in System Settings, Accessibility, Spoken Content. Pick a Siri voice there and Reader+ uses it. The other voices are the ones VoiceOver uses; Enhanced and Premium sound the most natural.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if Kokoro.shared.isInstalled && !koBusy {
                    LabeledContent("Kokoro") { Label("Installed", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                } else {
                    LabeledContent("Kokoro") {
                        Button(koBusy ? "Installing…" : "Install Kokoro Voices") { installKokoro() }.disabled(koBusy)
                    }
                }
                if !koStatus.isEmpty { Text(koStatus).foregroundStyle(.secondary) }
            } header: { Text("Kokoro Voices (free, on your Mac)") } footer: {
                Text("Free, natural-sounding AI voices that run on your Mac: no account, no limits, and nothing you read is sent anywhere. The one-time install downloads about 400 MB. Right after Reader+ starts, the first reading can take a few seconds while the voice loads.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if Eleven.shared.hasKey {
                    LabeledContent("API key") {
                        HStack { Label("Saved in your Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                 Button("Remove") { Keychain.delete(); prefs.removeObject(forKey: "elevenVoices")
                                     if (prefs.string(forKey: Key.voice) ?? "").hasPrefix(Eleven.prefix) { prefs.removeObject(forKey: Key.voice) }
                                     elStatus = "Key removed."; model.changed() } }
                    }
                    LabeledContent("Your voices") {
                        Button(busy ? "Loading…" : "Load My Voices") { loadVoices() }.disabled(busy)
                    }
                    Picker("Quality", selection: Binding<String>(
                        get: { Eleven.shared.model },
                        set: { prefs.set($0, forKey: "elevenModel"); model.changed() })) {
                        Text("Fast (starts quickly, uses fewer credits)").tag("eleven_flash_v2_5")
                        Text("Best (richest voice, slower to start)").tag("eleven_multilingual_v2")
                    }
                } else {
                    LabeledContent("API key") {
                        HStack {
                            SecureField("Paste your ElevenLabs API key", text: $keyField).frame(maxWidth: 260)
                            Button("Save") {
                                guard !keyField.trimmed.isEmpty else { return }
                                Keychain.set(keyField); keyField = ""; model.changed(); loadVoices()
                            }
                        }
                    }
                    LabeledContent("Get a key") {
                        Button("Open ElevenLabs…") { NSWorkspace.shared.open(URL(string: "https://elevenlabs.io/app/settings/api-keys")!) }
                    }
                }
                if !elStatus.isEmpty { Text(elStatus).foregroundStyle(.secondary) }
            } header: { Text("ElevenLabs Voices") } footer: {
                Text("Optional. ElevenLabs voices sound like real people. When one is chosen, the text Reader+ reads is sent to ElevenLabs to make the voice, and it uses your ElevenLabs credits. If ElevenLabs can't be reached, Reader+ carries on with an Apple voice.")
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

// MARK: - AI auto-read state (also exercised by tests/auto_read.swift)

struct AIChatSnapshot {
    let conversation: String
    let responseID: String
    let text: String
    let generating: Bool
    let complete: Bool
    var page: String = ""
}

/// Completion is an explicit site signal plus a settling interval, never silence alone.
struct AIAutoReadState {
    var conversation = ""
    var page = ""
    var baseline = ""
    var baselineResponseID = ""
    var candidate = ""
    var changedAt = 0.0
    var armed = false
    var suppressed = false
    mutating func suppress() { suppressed = true; armed = false }
    var consumed = Set<String>()
    mutating func observe(_ s: AIChatSnapshot, now: Double, delay: Double) -> String? {
        let signature = s.responseID + "\n" + s.text
        let localURLResolved = page.contains("/c/local-chatgpt") && s.page.hasPrefix("/c/")
        if conversation != s.conversation || (page != s.page && !localURLResolved) {
            page = s.page; suppressed = false
            conversation = s.conversation; baseline = signature; baselineResponseID = s.responseID; candidate = signature
            changedAt = now; armed = s.generating
            return nil // Never read history on launch or tab navigation.
        }
        page = s.page
        if suppressed {
            if !s.generating { suppressed = false; baseline = signature; baselineResponseID = s.responseID; candidate = signature; changedAt = now }
            return nil
        }
        if s.generating { armed = true; changedAt = now; candidate = signature; return nil }
        if s.complete && !s.text.isEmpty && s.responseID != baselineResponseID { armed = true }
        if candidate != signature { candidate = signature; changedAt = now; return nil }
        guard armed, s.complete, !s.text.isEmpty, signature != baseline,
              now - changedAt >= delay else { return nil }
        armed = false; baseline = signature; baselineResponseID = s.responseID
        // Consume before delivery: Stop, manual reading and speech failure never cause retries.
        guard consumed.insert(conversation + "\n" + signature).inserted else { return nil }
        if consumed.count > 256 { consumed = [conversation + "\n" + signature] }
        return s.text
    }
}

// MARK: - AI accessibility adapter

struct AINode {
    var role: String
    var label: String
    var identifier: String
    var text: String
    var children: [AINode]
    var isButton: Bool { role == "AXButton" }
    var stop: Bool {
        isButton && ["stop", "stop generating", "stop response", "stop responding", "stop streaming"].contains(label.lowercased())
    }
    var copy: Bool {
        isButton && ["copy", "copy response", "copy message", "copy answer"].contains(label.lowercased())
    }
    func contains(_ predicate: (AINode) -> Bool) -> Bool {
        predicate(self) || children.contains { $0.contains(predicate) }
    }
    var spokenText: String {
        // Never include editable fields, button labels, prompts, or page chrome.
        if ["AXTextArea", "AXTextField", "AXButton", "AXToolbar"].contains(role) { return "" }
        if role == "AXStaticText" { return ["ChatGPT said:", "Claude said:", "Gemini said:"].contains(text) ? "" : text }
        return children.map(\.spokenText).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    var assistant: Bool {
        label.lowercased().hasPrefix("claude responded:")
            || ["chatgpt said:", "claude said:", "gemini said:", "gemini said", "assistant response", "assistant message"].contains(label.lowercased())
    }
    func responses() -> [AINode] {
        var result: [AINode] = []
        var index = 0
        while index < children.count {
            let child = children[index]
            if child.role == "AXHeading" && child.assistant {
                // AX can flatten user and assistant turns into the same parent.
                // Slice AFTER the assistant heading, never collect that entire parent.
                let start = index + 1
                var end = start
                while end < children.count {
                    let next = children[end]
                    if next.role == "AXHeading" && (next.assistant || next.label.lowercased().hasPrefix("you said") || next.label == "Latest response") { break }
                    end += 1
                }
                result.append(AINode(role: "AXGroup", label: "Assistant response", identifier: identifier,
                                     text: "", children: Array(children[start..<end])))
                index = end
            } else {
                result += child.responses(); index += 1
            }
        }
        if !result.isEmpty { return result }
        return assistant ? [self] : []
    }

}

final class AIAutoReader {
    static let shared = AIAutoReader()
    private var timer: Timer?
    private var working = false
    private var failure = ""
    private var misses = 0
    private var state = AIAutoReadState()
    private var epoch = 0
    private var observedPID: pid_t?
    private var ownedGeneration: Int?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.poll() }
    }
    func reset() {
        epoch += 1; state = AIAutoReadState()
        stopOwned()
    }
    func suppressPending() { state.suppress() }
    private func stopOwned() {
        if let g = ownedGeneration, g == Reading.shared.generation { Speaker.shared.stop(autoReadStop: true) }
        ownedGeneration = nil
    }
    private func poll() {
        guard prefs.bool(forKey: Key.aiAutoRead), AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication else { reset(); return }
        guard front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if observedPID != front.processIdentifier { reset(); observedPID = front.processIdentifier }
        guard !working else { return }
        working = true
        let pid = front.processIdentifier, token = epoch
        let readingGeneration = Reading.shared.generation
        exposeText(pid)
        DispatchQueue.global(qos: .utility).async {
            let snapshot: AIChatSnapshot? = AXWork.run(seconds: 1.5) {
                self.snapshot(pid)
            }
            DispatchQueue.main.async {
                self.working = false
                guard token == self.epoch, prefs.bool(forKey: Key.aiAutoRead),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                guard let s = snapshot else {
                    self.misses += 1
                    ReaderModel.shared.aiStatus = "No readable supported AI chat in the active window"
                    if self.misses >= 3 { self.reset() }
                    return
                }
                self.misses = 0
                let status = s.generating ? "AI answer is generating" : (s.text.isEmpty ? "Waiting for a recognizable assistant answer" : "Watching for a new completed AI answer")
                if ReaderModel.shared.aiStatus != status { log("AI auto-read: " + status) }
                ReaderModel.shared.aiStatus = status
                if s.generating && prefs.bool(forKey: Key.aiInterrupt) { self.stopOwned() }
                guard let text = self.state.observe(s, now: ProcessInfo.processInfo.systemUptime,
                                                   delay: prefs.double(forKey: Key.aiDelay)) else { return }
                guard readingGeneration == Reading.shared.generation,
                      !Speaker.shared.isReading, !Speaker.shared.isSpeaking, !Speaker.shared.isPaused,
                      !ClickReader.shared.hasPending else { return }
                Reading.shared.start(ReadSource(text: text, element: nil, base: 0),
                                     showWindow: prefs.bool(forKey: Key.aiShowWindow), autoRead: true)
                self.ownedGeneration = Reading.shared.generation
                log("AI auto-read: started completed answer (\(text.count) characters)")
            }
        }
    }
    private func snapshot(_ pid: pid_t) -> AIChatSnapshot? {
        func unavailable(_ reason: String) -> AIChatSnapshot? {
            if failure != reason { failure = reason; log("AI auto-read unavailable: " + reason) }
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        guard let window = axElement(app, "AXFocusedWindow") else { return unavailable("no focused window") }
        var count = 0
        var truncated = false
        func read(_ e: AXUIElement, depth: Int) -> AINode? {
            guard depth < 75, count < 10000, AXWork.current?.expired != true else { truncated = true; return nil }
            count += 1
            let role = axString(e, "AXRole") ?? ""
            if role == "AXStaticText" {
                return AINode(role: role, label: "", identifier: "", text: axString(e, "AXValue") ?? "", children: [])
            }
            if ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) {
                return AINode(role: role, label: "", identifier: "", text: "", children: [])
            }
            let label = axString(e, "AXDescription") ?? ""
            let title = label.isEmpty && ["AXButton", "AXHeading"].contains(role) ? (axString(e, "AXTitle") ?? "") : label
            let children = axChildren(e).compactMap { read($0, depth: depth + 1) }
            let name = title.isEmpty && role == "AXHeading" ? children.map(\.spokenText).joined(separator: " ") : title
            return AINode(role: role, label: name, identifier: "", text: "", children: children)
        }
        // Scope to one web area, and verify the host rather than trusting a window title.
        func web(_ e: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 15, AXWork.current?.expired != true else { return nil }
            if axString(e, "AXRole") == "AXWebArea" { return e }
            for c in axChildren(e) { if let found = web(c, depth: depth + 1) { return found } }
            return nil
        }
        guard let area = web(window, depth: 0) else { return unavailable("no accessible web area") }
        guard let rawURL = ax(area, "AXURL") else { return unavailable("web area has no URL") }
        guard let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:)),
              let host = url.host?.lowercased() else { return unavailable("unreadable web URL") }
        guard ["chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com"].contains(host) else { return unavailable("active page is not a supported AI host") }
        guard let tree = read(area, depth: 0), AXWork.current?.expired != true, count < 10000, !truncated else { return unavailable("accessibility scan exceeded budget") }
        failure = ""
        let responses = tree.responses()
        let response = responses.last
        let generating = tree.contains { $0.stop || $0.label == "Currently streaming message" || $0.text == "Claude is responding" }
        let interrupted = tree.contains {
            ["response stopped", "stopped generating", "you stopped this response", "response interrupted", "something went wrong"].contains($0.text.lowercased())
        }
        // Even an empty stream can arm detection; history alone cannot.
        func prompts(_ n: AINode) -> [String] {
            var result: [String] = []
            for (index, child) in n.children.enumerated() {
                if child.role == "AXHeading" && child.label.lowercased().hasPrefix("you said") {
                    var prompt = child.label
                    if index + 1 < n.children.count, n.children[index + 1].role == "AXStaticText" {
                        prompt += "\n" + n.children[index + 1].text
                    }
                    result.append(prompt)
                } else { result += prompts(child) }
            }
            return result
        }
        // New chats may replace a local URL with a server URL during the same stream.
        // The exposed prompt sequence stays stable through that transition.
        let turnContext = prompts(tree).joined(separator: "\n")
        return AIChatSnapshot(conversation: "\(pid):\(host):\(turnContext)",
                              responseID: "\(responses.count):\(response?.identifier ?? "")", text: response?.spokenText ?? "",
                              generating: generating, complete: !interrupted && (response?.contains { $0.copy } ?? false), page: url.path)
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
    New completed AI answers in supported web chats are read automatically. Change this under General, AI Answers. \
    Everything else, like Mouse Echo, Key Echo and the reading window, is in the Reader plus window and the menu bar icon.
    """

    func applicationDidFinishLaunching(_ n: Notification) {
        registerDefaults()
        AXUIElementSetMessagingTimeout(systemWide, 0.12)
        _ = Reading.shared
        _ = PreviousApp.shared
        buildMenu()
        buildMainMenu()
        AIAutoReader.shared.start()
        ClickReader.shared.start()
        if (prefs.string(forKey: Key.voice) ?? "").hasPrefix(Kokoro.prefix) { Kokoro.shared.warmUp() }
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

    func applicationWillTerminate(_ n: Notification) { Kokoro.shared.stopServer() }

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
        let request = ClickReader.shared.begin()
        withSelectedText(request: request) { text, el, base in
            guard request.valid else { return }
            guard let t = text, !t.trimmed.isEmpty else {
                ClickReader.shared.cancelPending()
                ReaderModel.shared.activity = "No text is selected."
                say("No text is selected."); return
            }
            ClickReader.shared.deliver(ReadSource(text: t, element: el, base: base), request: request, showWindow: true)
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
        let request = ClickReader.shared.begin()
        DispatchQueue.global(qos: .userInitiated).async {
            var expired = false
            let src = AXWork.run(seconds: 3, valid: { request.valid }) {
                let result = readSourceFromFocus()
                expired = AXWork.current?.expired == true
                return result
            }
            DispatchQueue.main.async {
                guard request.valid else { return }
                if expired {
                    ClickReader.shared.cancelPending()
                    ReaderModel.shared.activity = "The app did not provide its text in time."
                    request.trace("focused text lookup timed out")
                    say("That app is taking too long to provide its text. Please try again.")
                    return
                }
                ClickReader.shared.deliver(src, request: request, showWindow: true)
            }
        }
    }

    @objc func readScreenUnderPointer() {
        let p = axPoint(NSEvent.mouseLocation), request = ClickReader.shared.begin()
        if let r = windowFrame(at: p) { ocrRead(r, request: request) }
        else { ocrRead(CGRect(x: p.x - 450, y: p.y - 250, width: 900, height: 500), request: request) }
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
        _ = item("Automatically Read AI Answers", #selector(toggleAIRead), on: prefs.bool(forKey: Key.aiAutoRead))
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
        let sys = NSMenuItem(title: "Siri / System Voice", action: #selector(pickVoice(_:)), keyEquivalent: "")
        sys.target = self; sys.representedObject = ""; sys.state = current == nil ? .on : .off
        vm.addItem(sys); vm.addItem(.separator())
        if Kokoro.shared.isInstalled {
            for kv in Kokoro.shared.voices {
                let ki = NSMenuItem(title: "\(kv.name) (Kokoro)", action: #selector(pickVoice(_:)), keyEquivalent: "")
                ki.target = self; ki.representedObject = Kokoro.prefix + kv.id; ki.state = current == Kokoro.prefix + kv.id ? .on : .off
                vm.addItem(ki)
            }
            vm.addItem(.separator())
        }
        if Eleven.shared.hasKey && !Eleven.shared.voices.isEmpty {
            for ev in Eleven.shared.voices {
                let ei = NSMenuItem(title: "\(ev.name) (ElevenLabs)", action: #selector(pickVoice(_:)), keyEquivalent: "")
                ei.target = self; ei.representedObject = Eleven.prefix + ev.id; ei.state = current == Eleven.prefix + ev.id ? .on : .off
                vm.addItem(ei)
            }
            vm.addItem(.separator())
        }
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
    @objc func toggleAIRead() {
        prefs.set(!prefs.bool(forKey: Key.aiAutoRead), forKey: Key.aiAutoRead)
        AIAutoReader.shared.reset(); ReaderModel.shared.changed()
        say(prefs.bool(forKey: Key.aiAutoRead) ? "AI answer reading on" : "AI answer reading off")
    }
    @objc func toggleShowReader() { prefs.set(!prefs.bool(forKey: Key.showReader), forKey: Key.showReader) }
    @objc func pickVoice(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        if id.isEmpty { prefs.removeObject(forKey: Key.voice) } else { prefs.set(id, forKey: Key.voice) }
        if id.hasPrefix(Kokoro.prefix) { Kokoro.shared.warmUp() }
        if Speaker.shared.isReading { Reading.shared.restartHere() } else { sample("This is my voice.") }
    }
    @objc func moreVoices() {
        say("To use Siri, open System Voice here and pick a Siri voice. Reader plus uses it when Siri, System Voice is chosen. Manage Voices adds more.")
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
