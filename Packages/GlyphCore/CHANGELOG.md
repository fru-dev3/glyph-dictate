# Changelog

GlyphCore follows semantic versioning (the number is in `VERSION`). A change that alters
the on-disk format or breaks the public API is a major version, a new API a minor one, a
fix a patch. Every change gets a line here, so an app can see what moved before it updates.

## 0.1.0 (2026-10-25)

First version, from JotCore (the vault reader Jot Studio started from).

- Products: `GlyphVault`, `GlyphCapture`, `GlyphAI`, and `GlyphCore` re-exporting all three.
- GlyphVault: the Memosa vault reader (field-for-field parity with Memosa's reader) and a
  writer in the exact format: conversations with dated slugs, meta.json, transcript.json and
  transcript.txt, notes.md, task toggles, rename, move, trash into `.memosa/trash` (never
  deletes), folders; People and Accounts notes with rename rewriting every link; links
  through aliases; suggestions; tasks across the vault; `Library` (`@Observable`) following
  the folder on disk. Golden files pin the format.
- GlyphCapture: `Recorder` (mic and the Mac's sound into one AAC .m4a, levels, pause,
  safe stop, feedable for tests), `Transcriber` (SpeechAnalyzer on the device, names as
  context, model download with progress), `Permissions`.
- GlyphAI: `Summarizer` (summary, decisions, action items with owner and due date, long calls
  in parts) and `LinkSuggester`, with Apple's on-device model.
