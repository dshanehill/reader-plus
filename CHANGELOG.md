# Changes

## Unreleased — responsiveness fixes (2026-11-13)

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
