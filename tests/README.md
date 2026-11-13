# macOS regression checks

Run from a Mac with Apple's Command Line Tools installed:

```sh
python3 tests/run_regressions.py
```

The speech checks speak short test sentences for about 30 seconds. Use `--only pipeline` or `--only speech` to run one fixture. Each fixture compiles the repository's current implementation in Swift 5 language mode with optimization and enabled preconditions. Test preferences and logs are isolated from the installed app.

The pipeline fixture substitutes the accessibility transport, hit classification, text-delivery transport, permission response, and native-event posting. It runs the real callback, cancellation coordinator, document walker, range validation, OCR text selection, and delayed-action guard. Posted mouse events are recorded instead of being sent to the desktop. It also renders an image and runs actual macOS Vision recognition on its clicked target paragraph.

Coverage includes:

- Command-click with magnifier modifiers and a Reader+ window under the pointer.
- Newest-click delivery, slow and out-of-order text lookup, and Stop during lookup.
- Native click/down-up pairing even if speech is cancelled before classification.
- Preserving the original target process and avoiding replay loops.
- Heading boundaries, nested formatting inside a single paragraph, Unicode text, missing/invalid positions, and overflowing ranges.
- Point-based OCR paragraph and column selection, cancelled OCR, and clearing pending state when permission is unavailable.
- Cancelling delayed controls actions when a newer reading or Stop supersedes them.
- Actual system and installed Apple speech, rapid replacement, stopping before speech starts, reading after Stop, pause/resume, paragraph offsets, and leading whitespace.

These fixtures do not establish physical Command-click behavior on every website, actual Finder/Dock selection, screen-capture permission flows, or optional ElevenLabs service behavior. Those boundaries require separate end-to-end checks before making broader release claims.

AI auto-read checks run separately without speaking:

```sh
python3 tests/run_auto_read.py
```

This compiles the actual `AIChatSnapshot`, `AIAutoReadState`, and `AINode` source
with deterministic fixtures modeled on the inspected English Chrome layouts.
It covers partial streams and long pauses, explicit completion and settling,
fast appended replies, duplicate suppression, Stop and subsequent answers,
missing completion controls, history baselines, local-to-server ChatGPT URL
resolution, navigation with identical prompts, and assistant extraction from a
parent containing both prompts and answers on ChatGPT, Claude and Gemini.
It does not substitute for a live automatic playback test or certify other sites,
languages, browser accessibility transports, or cancellation signals from a site.
