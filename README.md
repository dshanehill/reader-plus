# Reader+

**A free screen reader for the Mac, made for people with low vision.**

Reader+ reads your screen aloud with your Mac's own voices, the same voices VoiceOver uses, without turning VoiceOver on. Think of it as the reading half of ZoomText. Keep your magnifier the way you like it, and add speech that follows what you point at, select or click.

## Why Reader+ exists

Reader+ was created by **Shane** ([@dshanehill](https://github.com/dshanehill)), who is legally blind. Originally from Dallas, Texas, Shane lives as an expat in Cebu Business Park, Cebu City, Philippines.

He built Reader+ because macOS has a great magnifier and a full screen reader, VoiceOver, but nothing in between. Many partially sighted people can see the screen with magnification and just want help *reading* it: an article, a long Facebook post, the words in a picture. VoiceOver takes over the whole Mac to do that. Reader+ doesn't.

Shane shares Reader+ freely to help the partially sighted and low-vision community. If it helps you, pass it on.

## What it does

- **⌘-click to read by headings and paragraphs.** Click a heading to hear it and everything under it, up to the next heading. Click a paragraph to hear the article from there, or just that paragraph if you prefer.
- **Whole posts on social media.** On Facebook, Instagram, X, Threads, LinkedIn, Reddit and similar sites, ⌘-click a post. Reader+ presses *See more* for you and reads the entire post. It skips the Like, Comment and Share buttons.
- **Words in pictures (OCR).** ⌘-click a screenshot, meme or scanned page to hear the words in it. Control-Option-O reads everything in the window under your pointer, even in apps with no real text. It uses the Mac's built-in text recognition, so nothing leaves your computer.
- **Read what you select.** Select text in any app and press Control-Option-S.
- **Read a whole page.** Control-Option-R reads from your cursor, or the whole page if there's no cursor. While it reads, Control-Option with the arrow keys jumps by paragraph (left and right) and by heading (up and down).
- **Mouse Echo.** Rest the pointer on a button, menu, link or line of text to hear it, for example "Save, button".
- **Key Echo.** Hear the characters, the words, or both as you type.
- **Reading window.** Big, high-contrast text, with the word being spoken highlighted. There are five color schemes and adjustable size.
- **Outline on screen.** The paragraph being read gets a yellow outline on the page itself.
- **VoiceOver-style controls.** Tap Control to stop talking. Control-Option-P pauses, and Control-Option with = and − makes speech faster or slower.
- **Guided tour.** A spoken, step-by-step tour runs the first time you open Reader+. Control-Option-T opens it again.

## Keyboard shortcuts

All shortcuts use **Control + Option** (⌃⌥), like VoiceOver.

| Shortcut | What it does |
|---|---|
| ⌘-click | Read by headings and paragraphs, a whole social media post, or the words in a picture |
| ⌃⌥ S | Read selected text |
| ⌃⌥ R | Read from the cursor, or the whole page |
| ⌃⌥ V | Read the clipboard |
| ⌃⌥ O | Read the words in the window under the pointer (OCR) |
| ⌃⌥ P | Pause or resume |
| Tap ⌃ | Stop talking (also ⌃⌥ X) |
| ⌃⌥ = and ⌃⌥ − | Faster and slower |
| ⌃⌥ → and ⌃⌥ ← | Next and previous paragraph |
| ⌃⌥ ↓ and ⌃⌥ ↑ | Next and previous heading |
| ⌃⌥ M | Mouse Echo on or off |
| ⌃⌥ K | Key Echo: off, characters, words, both |
| ⌃⌥ W | Show or hide the reading window |
| ⌃⌥ H | Spoken help |
| ⌃⌥ T | Guided tour |

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
| **Input Monitoring** | So Key Echo can hear what you type, and a tap of Control can stop speech. |
| **Screen Recording** | To read the words in pictures and scanned pages. |

Turn them on in **System Settings → Privacy & Security**. Reader+'s **Permissions** pane has a button for each one. After turning on Input Monitoring or Screen Recording, quit and reopen Reader+.

## Privacy

Reader+ has no account, no ads, no analytics and no network access. Speech and text recognition happen entirely on your Mac. The only file it writes is a small log at `~/Library/Logs/Reader+.log`, which helps with troubleshooting.

## Build from source

Reader+ is one Swift file: `Reader+.app/Contents/Resources/main.swift`. The app builds itself when you open it. The `launch` script compiles the source with `swiftc` the first time the app opens, and again whenever the source changes. To change Reader+, edit `main.swift` and reopen the app.

## Feedback and help

Found a site where Reader+ doesn't read correctly, or have an idea? Please [open an issue](../../issues). Mention the app or website, what you clicked or pressed, and what you heard.

## License

[MIT](LICENSE). Free to use, share and change.
