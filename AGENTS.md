# Glyph Jot: notes for AI coding agents

Glyph Jot (formerly Jot, Glyph Dictate and Glyph Record) is context capture for the Mac that
runs entirely on the Mac: hold a key and talk, and the words are typed wherever the cursor is;
click Record and a meeting is recorded, transcribed and summarized; everything lands in one
library. It was built with AI and is meant to be easy to change with AI. This file is what an
agent needs before touching it.

## Layout

- `project.yml`: XcodeGen spec (`xcodegen generate` makes `Jot.xcodeproj`). Three targets:
  `JotMac` (the app, `Jot.app`, bundle id `dev.fru.jot.mac`), `JotEngine` (the dictation engine,
  embedded as `Contents/Helpers/Glyph Jot Dictation.app`) and `GlyphJotTests`. The version is
  `MARKETING_VERSION` (patch bumps); each version gets one line in the README.
- `Record/`: the app: library, recorder panel, settings window, menu bar, `Engine.swift` (starts
  and watches the engine), `Notes.swift` (Notes and Dictations).
- `Mac/`: the dictation engine (`EngineApp.swift`, `EngineLink.swift`, `Dictation.swift`,
  `FnKey.swift`, `Pill.swift`, `Polish.swift`, `Rules.swift`, `FormFill.swift`, `Learner.swift`)
  and the files both processes share (`Link.swift`, `Storage.swift`, `Polish.swift`,
  `Settings.swift` and `History.swift` are compiled into the app).
- `Packages/GlyphCore`: the shared package: the plain-file library (`docs/vault-format.md`),
  recording, transcription, summaries.
- `site/`: the old jot.fru.dev, retired: every page 301s to https://glyph.fru.dev/jot.
- `scripts/`: `install.sh`, `check.sh`, `release.sh`, `ship.sh`, and the live checks.

## Rules

- **Nothing leaves the Mac.** No network requests from the app, no cloud models. Dictation
  writes no audio to disk; a recording is an `.m4a` in the library folder the user chose.
  Speech is Apple's on-device model; clean-up and summaries use Apple Intelligence.
- **Never lose what someone said.** A paste must be checked to have landed, or the words stay
  on the clipboard. If speech stalls, restart it on the sound so far (kept in memory only).
- Never type into a password field (secure input on).
- Examples, tests and docs use made-up names (Sam Lee, Northwind, Austin).
- Keep it small: no dependencies; standard library and Apple frameworks first.
- **Two processes, kept apart.** The engine (`Mac/`) never links GlyphCore or the recorder; the
  app (`Record/`) never types into other apps. They talk only over `Mac/Link.swift`.
- **What you jot while recording stays private**: a jot's stretch never reaches a transcript or
  a summary (`Transcript.excluding`).

## Build

Xcode 26 and XcodeGen (`brew install xcodegen`), macOS 26 on Apple silicon:

```sh
xcodegen generate
xcodebuild -project Jot.xcodeproj -scheme JotMac -configuration Debug build
```

The first run asks for Microphone, Accessibility and Input Monitoring.
