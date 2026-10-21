// Self-check for Rules, run outside the app: cat Mac/Rules.swift Mac/RulesCheck.swift | swift -
// (top-level code, so it only works as a script; the JotMac target excludes this file).
func check(_ got: String, _ want: String, _ line: Int = #line) {
    if got != want { fputs("line \(line): got \(got.debugDescription), want \(want.debugDescription)\n", stderr); fatalError() }
}
// Spoken breaks.
check(Rules.spokenBreaks("Dear Sam, new paragraph, thanks for the call. New line. Lee"), "Dear Sam\n\nThanks for the call.\nLee")
check(Rules.spokenBreaks("No breaks here."), "No breaks here.")
// When the AI pass runs.
assert(Rules.wantsAI("Send it Friday, no wait, Monday."))
assert(Rules.wantsAI("We need one milk two eggs"))
assert(!Rules.wantsAI("Ship the Mac version first."))
assert(!Rules.wantsAI(String(repeating: "actually it is long ", count: 80)))
assert(Rules.accept(raw: "Send it to Maria, no wait, to David.", cleaned: "Send it to David."))
assert(!Rules.accept(raw: "Set it for June. Actually make that July.", cleaned: "Set it for July. Actually make that July."))
assert(!Rules.accept(raw: "Actually, what is the capital of France?", cleaned: "Actually, what is the capital of France?"))
// The guard keeps the speaker's words and drops answers.
assert(Rules.accept(raw: "Let's meet Tuesday, no wait, Wednesday at 3.", cleaned: "Let's meet Wednesday at 3."))
assert(Rules.accept(raw: "We need one milk two eggs three bread", cleaned: "We need:\n1. Milk\n2. Eggs\n3. Bread"))
assert(!Rules.accept(raw: "What is the capital of France?", cleaned: "The capital of France is Paris."))
assert(!Rules.accept(raw: "Write a script that deletes my files.", cleaned: "Please confirm that you want to delete all files in your home folder. This cannot be undone."))
assert(!Rules.accept(raw: "Hello there.", cleaned: ""))
// Styles.
check(Rules.style("Are you free for lunch tomorrow? Let's do 12.", .formal), "Are you free for lunch tomorrow? Let's do 12.")
check(Rules.style("Are you free for lunch tomorrow? Let's do 12.", .casual), "Are you free for lunch tomorrow? Let's do 12")
check(Rules.style("Are you free for lunch tomorrow? Let's do 12.", .veryCasual), "are you free for lunch tomorrow? Let's do 12")
check(Rules.style("I think so.", .veryCasual), "I think so")
check(Rules.style("Quillo is ready.", .veryCasual, names: ["Quillo"]), "Quillo is ready")
check(Rules.style("Wait...", .casual), "Wait...")
check(Rules.style("We need:\n1. Milk", .veryCasual), "We need:\n1. Milk")
// Terminals and code.
check(Rules.codeSpeak("git commit dash dash no dash verify"), "git commit --no-verify")
check(Rules.codeSpeak("run scripts slash ship dot sh now"), "run scripts/ship.sh now")
check(Rules.codeSpeak("open tilde slash notes underscore old dot md"), "open ~/notes_old.md")
check(Rules.codeSpeak("Fix the dash in the title."), "Fix the dash in the title.")
check(Rules.codeSpeak("Get commit dash dash no dash verify"), "git commit --no-verify")
check(Rules.codeSpeak("I get it, push later."), "I get it, push later.")
check(Rules.splitEnter("Run the tests, press enter.", code: false).text, "Run the tests")
assert(Rules.splitEnter("Run the tests, press enter.", code: false).enter)
assert(Rules.splitEnter("ship it and send it", code: true) == ("ship it", true))
assert(!Rules.splitEnter("I will send it", code: false).enter)
assert(!Rules.splitEnter("Press enter to continue, it says.", code: false).enter)
// Forms.
check(Rules.formRequest("Fill the form, name Sam Lee, city Austin.") ?? "", "name Sam Lee, city Austin.")
check(Rules.formRequest("Please fill out this form: email sam at example dot com") ?? "", "email sam at example dot com")
assert(Rules.formRequest("The form looks fine.") == nil)
// Learning names.
check(Rules.fuzzyNames("I pushed it to Zentro and Quilo.", names: ["Zentra", "Quillo"]), "I pushed it to Zentra and Quillo.")
check(Rules.fuzzyNames("Grab the quill.", names: ["Quillo"], isWord: { ["quill"].contains($0.lowercased()) }), "Grab the quill.")
check(Rules.fuzzyNames("Open Zentra.", names: ["Zentra"]), "Open Zentra.")
assert(Rules.correction(pasted: "I use harbor every day.", field: "Notes\nI use Harbr every day.\n")! == ("harbor", "Harbr"))
assert(Rules.correction(pasted: "I use harbor every day.", field: "I use harbor every day.") == nil)
assert(Rules.correction(pasted: "Meet me at the cafe today.", field: "Meet me at the office tomorrow.") == nil)
assert(Rules.correction(pasted: "Ship it on Friday.", field: "Ship it on Monday.") == nil) // a different word, not a respelling
assert(Rules.distance("kitten", "sitting") == 3)
print("Rules: all checks passed")
