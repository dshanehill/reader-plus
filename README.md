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

Reader+ has no account, no ads, no analytics and no network access. Speech and text recognition happen entirely on your Mac. The only file it writes is a small log at `~/Library/Logs/Reader+.log`, which helps with troubleshooting.

## Build from source

Reader+ is one Swift file: `Reader+.app/Contents/Resources/main.swift`. The app builds itself when you open it. The `launch` script compiles the source with `swiftc` the first time the app opens, and again whenever the source changes. To change Reader+, edit `main.swift` and reopen the app.

## Feedback and help

Found a site where Reader+ doesn't read correctly, or have an idea? Please [open an issue](../../issues). Mention the app or website, what you clicked or pressed, and what you heard.

## License

[MIT](LICENSE). Free to use, share and change.
