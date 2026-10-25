# Jot: notes for AI coding agents

Jot is voice dictation for the Mac that runs entirely on the Mac: hold a key, talk, and the
words are typed wherever the cursor is. It was built with AI and is meant to be easy to change
with AI. This file is what an agent needs before touching it.

## Layout

- `project.yml`: XcodeGen spec (`xcodegen generate` makes `Jot.xcodeproj`). The version is
  `MARKETING_VERSION`; each version gets one line in the README.
- `Mac/`: the app, plain Swift and SwiftUI, no packages.
  - `Dictation.swift`: the flow from key to typed text, the mic, pasting, the logs.
  - `Transcription.swift`: Apple's on-device speech (SpeechAnalyzer).
  - `Polish.swift`, `Rules.swift`: clean-up, corrections, styles, the Dictionary.
  - `FnKey.swift`, `Pill.swift`, `Settings.swift`, `History.swift`, `Ask.swift`, `FormFill.swift`.
  - `RulesCheck.swift`: checks for the pure rules: `cat Mac/Rules.swift Mac/RulesCheck.swift | swift -`.
- `site/`: jot.fru.dev, retired 2026-10-25: every page 301s to https://glyph.fru.dev/dictate (vercel.json); only `/download` and `/privacy.html` still answer here.
- `scripts/`: `install.sh` (build and install), `check.sh`, `release.sh`, `ship.sh`.

## Rules

- **Nothing leaves the Mac.** No network requests from the app, no cloud models, no audio
  written to disk. Speech is Apple's on-device model; clean-up uses Apple Intelligence.
- **Never lose what someone said.** A paste must be checked to have landed, or the words stay
  on the clipboard. If speech stalls, restart it on the sound so far (kept in memory only).
- Never type into a password field (secure input on).
- Examples, tests and docs use made-up names (Sam Lee, Northwind, Austin).
- Keep it small: no dependencies; standard library and Apple frameworks first.

## Build

Xcode 26 and XcodeGen (`brew install xcodegen`), macOS 26 on Apple silicon:

```sh
xcodegen generate
xcodebuild -project Jot.xcodeproj -scheme Jot -configuration Debug build
```

The first run asks for Microphone, Accessibility and Input Monitoring.
