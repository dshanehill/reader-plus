# Reader+

**A free screen reader for the Mac, made for people with low vision.**

Reader+ reads your screen aloud with your Mac's own voices, the same voices VoiceOver uses, without turning VoiceOver on. Think of it as the reading half of ZoomText. Keep your magnifier the way you like it, and add speech that follows what you point at, select or click.

## Why Reader+ exists

macOS has a great magnifier and a full screen reader, VoiceOver, but nothing in between. Many partially sighted people can see the screen with magnification and just want help *reading* it: an article, a long Facebook post, the words in a picture. VoiceOver takes over the whole Mac to do that. Reader+ doesn't.

Reader+ is shared freely to help the partially sighted and low-vision community. If it helps you, pass it on.

## What it does

Reader+ is made for the mouse. There's no list of keyboard shortcuts to learn: you hold **Command** and use your mouse. If you want lots of keyboard commands, that's what VoiceOver is for.

- **⌘-click to read by headings and paragraphs.** Click a heading to hear it and everything under it, up to the next heading. Click a paragraph to hear everything from there to the end without stopping, or just that paragraph if you prefer. It works in AI chat apps too (Claude, ChatGPT and others), so you can hear a whole reply even when the app has no read-aloud button.
- **Links and long lists too.** ⌘-click a link to hear it and everything after it, instead of opening it. It starts exactly where you click, even far down a long page like a YouTube list, and carries on down from there.
- **Other apps.** ⌘-click reads text, buttons and boxes in any app. In Finder, Mail and other lists, ⌘-click still selects things as usual and Reader+ reads the item.
- **Whole posts on social media.** On Facebook, Instagram, X, Threads, LinkedIn, Reddit and similar sites, ⌘-click a post. Reader+ presses *See more* for you and reads the entire post. It skips the Like, Comment and Share buttons.
- **Words in pictures (OCR).** ⌘-click a screenshot, meme or scanned page to hear the words in it. It uses the Mac's built-in text recognition, so nothing leaves your computer.
- **Read a whole page.** ⌘-right-click anywhere on a page or window to hear all of it from the top. If it has no real text, Reader+ reads the words it sees on screen.
- **Stop, move and change speed with the mouse.** While Reader+ is talking, ⌘-right-click stops it, ⌘ with your mouse's Back and Forward side buttons moves by paragraph, and ⌘ with the scroll wheel makes speech faster (up) or slower (down).
- **Stop with Control, just like VoiceOver.** Tap the Control key by itself to stop talking.
- **Siri voice.** Choose *Siri / System Voice* in Reader+ and it speaks with the voice picked in System Settings › Accessibility › Spoken Content, including Siri voices.
- **Kokoro voices (free).** One click in Reader+'s Voice settings installs Kokoro, free and natural-sounding AI voices that run entirely on your Mac: no account, no limits, and nothing is sent online. The install downloads about 400 MB.
- **ElevenLabs voices (optional).** Paste your own ElevenLabs API key in Reader+'s Voice settings and choose one of your ElevenLabs voices for very human-sounding reading. The key is kept in your Mac's Keychain. When an ElevenLabs voice is chosen, the text being read is sent to ElevenLabs and uses your credits; if it can't be reached, Reader+ carries on with an Apple voice.
- **Mouse Echo.** Rest the pointer on a button, menu, link or line of text to hear it, for example "Save, button".
- **Key Echo.** Hear the characters, the words, or both as you type.
- **Reading window.** Big, high-contrast text, with the word being spoken highlighted. There are five color schemes and adjustable size.
- **Outline on screen.** The paragraph being read gets a yellow outline on the page itself.
- **Guided tour.** A spoken, step-by-step tour runs the first time you open Reader+.

Mouse Echo, Key Echo, the reading window, voices, reading selected text or the clipboard, and the tour are all in the Reader+ window and the Reader+ icon in the menu bar.

## Mouse commands

| Do this | What happens |
|---|---|
| ⌘-click | Read a heading and its section, everything from a paragraph onward (also in AI chat apps), a whole social media post, or the words in a picture |
| ⌘-right-click | Read the whole page or window |
| ⌘-right-click while reading | Stop talking |
| ⌘ + mouse Back / Forward button | Previous / next paragraph |
| ⌘ + scroll up / down | Faster / slower |
| Tap ⌃ Control | Stop talking, like VoiceOver |

If you choose ⌥⌘-Click in the settings, hold Option as well.

## Install

1. Go to the [Releases page](../../releases/latest) and download **Reader+.zip**.
2. Open the zip, then drag **Reader+** into your **Applications** folder.
3. Open Reader+. Because it comes from the internet and isn't from the App Store, macOS will say it can't check it. To open it anyway:
   - Open **System Settings**, then **Privacy & Security**.
   - Scroll down and click **Open Anyway** next to the message about Reader+.
4. The first time it opens, Reader+ builds itself from its source code, which takes about a minute. If your Mac doesn't have Apple's free **Command Line Tools** yet, macOS offers to install them. Click **Install**, then open Reader+ again.
5. Follow the spoken tour. It shows you how to turn on the permissions below.

**Requirements:** macOS 13 Ventura or later. Reading words in pictures needs macOS 14 Sonoma or later. It works on Apple Silicon and Intel Macs.

## Permissions, and why

macOS keeps apps from seeing other apps unless you allow it. Reader+ asks for:

| Permission | Why |
|---|---|
| **Accessibility** | To see the words in Safari, Chrome, Mail and your other apps. Without it, Reader+ can only read the clipboard. |
| **Input Monitoring** | So Key Echo can hear what you type. |
| **Screen Recording** | To read the words in pictures and scanned pages. |

Turn them on in **System Settings → Privacy & Security**. Reader+'s **Permissions** pane has a button for each one. After turning on Input Monitoring or Screen Recording, quit and reopen Reader+.

## Privacy

Reader+ has no account, no ads and no analytics. Speech and text recognition happen entirely on your Mac, and Kokoro voices run on your Mac too. Reader+ uses the internet only to install Kokoro, and if you choose an ElevenLabs voice: then the text being read is sent to ElevenLabs to make the speech. The only file it writes is a small log at `~/Library/Logs/Reader+.log`, which helps with troubleshooting.

## Build from source

Reader+ is one Swift file: `Reader+.app/Contents/Resources/main.swift`. The app builds itself when you open it. The `launch` script compiles the source with `swiftc` the first time the app opens, and again whenever the source changes. To change Reader+, edit `main.swift` and reopen the app.

## Feedback and help

Found a site where Reader+ doesn't read correctly, or have an idea? Please [open an issue](../../issues). Mention the app or website, what you clicked or pressed, and what you heard.

## License

[MIT](LICENSE). Free to use, share and change.

## Automatically read AI answers

AI answer reading is **on by default**, including for existing installations. In
**General → AI Answers**, you can turn it off, choose a 2/4/6 second completion
settling delay, stop the previous automatic reading when another answer starts,
and choose whether automatic readings open the reading window. The menu bar also
has an **Automatically Read AI Answers** switch. Voice and speed use the existing
Reader+ controls. The status in General explains whether a readable chat is found.

The initial adapters support English accessibility layouts on **ChatGPT
(chatgpt.com and chat.openai.com), Claude (claude.ai), and Gemini
(gemini.google.com)** in a foreground browser. They use macOS Accessibility;
there is no browser extension, JavaScript permission, or account setup. The
existing Accessibility permission is required. Only the active application's
focused web window is inspected; this is not background-tab monitoring.

Reader+ watches for an exposed generation indicator or a newly appended assistant
turn after its baseline, isolates the newest assistant turn, waits for generation
to end and a Copy control within that turn, then waits
for the text to settle. A quiet stream alone never counts as completion. Opening
an existing chat or enabling the feature establishes a baseline without reading
history. Prompt text, editable composers and action labels are excluded. Repeated
polls do not repeat playback. Tap Control or use Stop to cancel; a stopped or
manually superseded answer is not retried. Manual readings and paused speech take
priority: automatic answers that finish while the speaker is occupied are skipped,
not queued. New generation can stop only speech owned by auto-read, according to
the interruption setting. Switching to another app stops its automatic reading;
opening Reader+'s own controls preserves playback so Pause/Resume still work.

Limitations:

- Polling runs about every 0.75 s, with one bounded background scan at a time.
  A newly appended completed assistant turn can be detected even when its stream
  was too fast to observe. An entire prompt-and-answer cycle between polls, answers generated
  while the browser is in the background, and pages opened only after completion
  may be skipped. There is no timeout-based partial-reading fallback.
- English assistant headings and accessible Copy/generation controls must be
  exposed. Other languages, native desktop AI apps, Copilot, Perplexity, Grok,
  embedded side panels and alternate layouts are not validated or supported yet.
- Long or inaccessible trees are skipped after a bounded scan. Three unavailable
  scans reset the baseline. No OCR or whole-page fallback is used for auto-read.
- Recognizable stopped/error indicators suppress playback. A site's own Stop
  button can still produce a readable partial answer if the site exposes it
  exactly like a completed answer without a cancellation indicator.
- Text is passed to the selected voice engine. Apple/Kokoro stay local; choosing
  an ElevenLabs voice sends the answer to ElevenLabs under the existing settings.
  Auto-read logs status and character counts, not prompts or answer text.

Validation for this change: actual Chrome accessibility layouts were inspected
while generating and after completion on ChatGPT, Claude and Gemini; the installed
native app recognized completed assistant content and exposed the new settings.
Automated fixtures exercise the actual extraction and completion state code.
Existing native speech/pipeline/OCR regressions pass. **Full live automatic audio
playback on those sites has not been verified end to end**; do not interpret the
layout checks as a playback certification.

Run `python3 tests/run_auto_read.py` for the non-speaking AI regression tests, and
`python3 tests/run_regressions.py` for the existing Mac reading/speech checks.
