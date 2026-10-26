#!/bin/zsh
# Glyph Jot keeps typing when the rest of the app dies (decision d-mvo8tyob). A Debug build
# is crashed on purpose (kill -9 of the app process, where recording and the library run);
# the dictation engine must keep running, open the app again, hand over to a fresh engine,
# and that engine must type. Then the engine is crashed: the app must start a new one.
#
#   scripts/engine-isolation-check.sh [path/to/Debug/Jot.app]
#
# Only when the Mac is idle (15 minutes untouched; JOT_IDLE=seconds to change): speaks aloud and quits the installed
# Glyph Jot for the duration (started again, in the background, at the end).
set -uo pipefail
cd "${0:A:h}/.."
app=${1:-build/Build/Products/Debug/Jot.app}
[[ -x $app/Contents/MacOS/Jot ]] || { echo "build the Debug app first"; exit 2; }
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
(( idle >= ${JOT_IDLE:-900} )) || { echo "the Mac is in use (idle ${idle}s, needs ${JOT_IDLE:-900})"; exit 3; }
work=$(mktemp -d /tmp/jot-iso.XXXXXX)
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
print 'import Foundation; let a = CommandLine.arguments; DistributedNotificationCenter.default().postNotificationName(.init(a[1]), object: a[2], userInfo: nil, deliverImmediately: true)' > $work/post.swift
swiftc -O -o $work/post $work/post.swift 2>/dev/null || exit 2
hook() { $work/post dev.fru.jot.mac.app.check "$1"; }
engine() { $work/post dev.fru.jot.mac.check "$1"; }
mainpid() { pgrep -f "$app/Contents/MacOS/Jot" | head -1; }
enginepid() { pgrep -f "$app/Contents/Helpers/Glyph Jot Dictation.app" | head -1; }

clip=$(pbpaste 2>/dev/null)
vol=$(osascript -e 'output volume of (get volume settings)')
installed=$(pgrep -f '^/Applications/Glyph Jot.app/Contents/MacOS/Jot$')
oldNotes=$(defaults read dev.fru.jot.mac vaultPath 2>/dev/null || true)
restore() {
  pkill -TERM -f "$app/Contents/MacOS/Jot" 2>/dev/null
  for _ in {1..30}; do pgrep -f "$app/Contents" >/dev/null || break; sleep 0.5; done
  pkill -9 -f "$app/Contents" 2>/dev/null
  if [[ -n $oldNotes ]]; then defaults write dev.fru.jot.mac vaultPath "$oldNotes"; else defaults delete dev.fru.jot.mac vaultPath 2>/dev/null; fi
  osascript -e "set volume output volume $vol"
  print -rn -- "$clip" | pbcopy
  [[ -n $installed ]] && open -g "/Applications/Glyph Jot.app"
}
trap restore EXIT
[[ -n $installed ]] && { kill $installed; sleep 2; }
defaults write dev.fru.jot.mac vaultPath $work/notes
osascript -e 'set volume output volume 45'
open -n $app --args -recordingsPath $work/recordings
for _ in {1..40}; do [[ -n $(enginepid) ]] && break; sleep 0.5; done
m1=$(mainpid) e1=$(enginepid)
[[ -n $m1 && -n $e1 ]] && ok "app $m1 and engine $e1 are two processes" || { bad "not running"; exit 1; }
sleep 5

kill -9 $m1
sleep 0.5
[[ $(enginepid) == $e1 ]] && ok "the app crashed and the engine kept running" || bad "the engine died with the app"
for _ in {1..40}; do m2=$(mainpid); [[ -n $m2 && $m2 != $m1 ]] && break; sleep 0.5; done
[[ -n $m2 && $m2 != $m1 ]] && ok "the engine opened the app again ($m2)" || bad "the app did not come back"
for _ in {1..60}; do e2=$(enginepid); [[ -n $e2 && $e2 != $e1 ]] && ! kill -0 $e1 2>/dev/null && break; sleep 0.5; done
[[ -n $e2 && $e2 != $e1 ]] && ! kill -0 $e1 2>/dev/null && ok "the new app retired the old engine and started its own ($e2)" || bad "engines: old $e1 alive=$(kill -0 $e1 2>/dev/null && echo yes || echo no), new ${e2:-none}"
(( $(pgrep -f "$app/Contents/Helpers" | wc -l) == 1 )) && ok "exactly one engine hears the talk key" || bad "$(pgrep -f "$app/Contents/Helpers" | wc -l) engines running"
sleep 6

# Type only into this test's own window: never start dictation unless it is in front.
[[ -n ${m2:-} ]] && hook scratch && sleep 0.3 && \
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $m2) to true" >/dev/null 2>&1
sleep 0.5
if [[ -z ${m2:-} || $(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true') != $m2 ]]; then
  bad "the test window is not in front; not dictating"; exit 1
fi
engine start; sleep 0.6
say -r 170 "Typing still works after a crash."
sleep 0.8; engine stop; sleep 3
hook "scratchtext:$work/typed.txt"; sleep 0.5
[[ $(cat $work/typed.txt 2>/dev/null) == *crash* ]] && ok "the fresh engine types: \"$(cat $work/typed.txt)\"" || bad "nothing typed: \"$(cat $work/typed.txt 2>/dev/null)\""

kill -9 $e2
for _ in {1..20}; do e3=$(enginepid); [[ -n $e3 && $e3 != $e2 ]] && break; sleep 0.5; done
[[ -n $e3 && $e3 != $e2 ]] && ok "the engine crashed and the app started a new one ($e3)" || bad "no engine after the engine crashed"
[[ $(mainpid) == $m2 ]] && ok "the app was not touched by the engine crash" || bad "the app restarted too"
echo "evidence: $work"
exit $fail
