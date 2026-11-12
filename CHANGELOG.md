# Changes

## Unreleased — responsiveness fixes (2026-11-13)

### Follow-up audit and reproducible regressions

- Reject invalid, missing and overflowing text positions; use screen text rather than crashing or reading the wrong document start.
- Keep complete single paragraphs across nested formatting containers.
- Anchor screen-text fallback to the pointer's paragraph and column, including correct coordinates when a capture is clipped at a screen edge.
- Capture Reader+'s own visible text too, excluding only its highlight overlay.
- Clear pending readings when screen-text recognition is unavailable or lacks permission.
- Preserve leading whitespace so system-voice word highlighting stays aligned.
- Cancel stale reading-button actions during application switching.
- Replay native selection clicks to their original process, and preserve their down/up pairing even when speech is cancelled before classification.
- Add reproducible regression fixtures under `tests/`, using isolated test preferences/logs, actual macOS Vision OCR, and actual system/Apple speech.

Validation: the expanded pipeline and speech suites passed. Repeated system-voice first-word timings in this audit were 0.045–0.085 seconds; the initial system start took 0.477 seconds and the installed Apple-voice case took 0.237 seconds. The final callback test remained below 0.3 ms with a simulated 250 ms target delay. These measurements describe the test run, not guaranteed response times. See `tests/README.md` for transport substitutions and verification limits.


### Command-click correction

- Route Command-click through the same reading pipeline for Reader+'s own text and other apps' text. The previous special case could silently pass or discard a click based on Reader+'s window geometry, including when its window was covered by another app.
- Keep Command-click working when Shift, Control (used for magnification), or Option is also held in the normal Command-click mode. Explicit Off and Option-Command modes remain respected.
- Use screen-text recognition automatically if a clicked app's accessibility lookup times out, instead of abandoning the reading request.
- Recognize text children inside controls rather than skipping the clicked label.
- Use active-app state and window order for the remaining direct-window check, ignoring click-through windows.

Validation: the actual callback passes a regression case where the own-window helper reports a Reader+ window with no direct text view; it must still capture and deliver the reading request. Modifier combinations, cancellation, paragraph boundaries, paired native-selection events, replay prevention, and deadlines also pass controlled transport tests. These tests do not establish physical mouse behavior in every application.


- Move accessibility queries out of the mouse-event callback so a slow target app does not block click processing.
- Reuse the system speech engine, wait for stop acknowledgement before replacement speech, and read paragraphs without recreating the engine between them.
- Cancel superseded text/OCR requests, including requests stopped before speech begins.
- Bound accessibility work and avoid silently reading incomplete text after a timeout.
- Avoid unnecessary document traversal beyond the requested paragraph or heading section.
- Prevent stale hover and highlight results from interfering with a newer reading.
- Move selected-text lookup and native highlight queries away from the main thread; preserve clipboard formats when a copy fallback is needed.
- Add reading status and timing from request receipt through the first spoken word.

### Validation

Built for Apple Silicon with Swift 5 language mode and a macOS 13 deployment target. Actual macOS system-speech tests passed for repeated readings, rapid replacement, stop-before-speech, reading after Stop, three paragraphs with correct offsets, and pause/resume. In the final test run, the initial first word took 0.764 seconds; repeated starts took 0.041–0.149 seconds. These are observations, not guaranteed latency or a controlled cold-start benchmark.

Controlled transport tests passed for heading/paragraph boundaries, newest-request delivery, cancellation, paired native-selection mouse events, replay-loop prevention, and deadline handling. With a simulated 250 ms target-app delay, the longest event callback took 0.085 ms.

Physical Command-click behavior across websites and actual Finder/Dock selection remain unverified by those simulations. Optional ElevenLabs service behavior and every social-media/OCR case were not exercised. This entry documents source changes; the existing v1.0 release download is unchanged.
