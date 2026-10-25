#!/bin/zsh
# Safe at any time (no mic, no typing, no window in front): a Debug Glyph Jot with a quiet
# engine (-quietEngine: no talk key, no mic) is crashed twice. When the app dies, the engine
# must open it again and the new app must retire the old engine and start one of its own;
# when the engine dies, the app must start a new one. The installed Glyph Jot is not touched.
# The typing half of the story is scripts/engine-isolation-check.sh (needs an idle Mac).
#   scripts/engine-restart-check.sh [path/to/Debug/Jot.app]
set -uo pipefail
cd "${0:A:h}/.."
app=${1:-build/Build/Products/Debug/Jot.app}
[[ -x $app/Contents/MacOS/Jot ]] || { echo "build the Debug app first"; exit 2; }
work=$(mktemp -d /tmp/jot-restart.XXXXXX)
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
mainpid() { pgrep -f "$app/Contents/MacOS/Jot" | head -1; }
enginepid() { pgrep -f "$app/Contents/Helpers/Glyph Jot Dictation.app" | head -1; }
engines() { pgrep -f "$app/Contents/Helpers/Glyph Jot Dictation.app" | wc -l | tr -d ' '; }
restore() {
  pkill -TERM -f "$app/Contents/MacOS/Jot" 2>/dev/null
  for _ in {1..30}; do pgrep -f "$app/Contents" >/dev/null || break; sleep 0.5; done
  pkill -9 -f "$app/Contents" 2>/dev/null
}
trap restore EXIT
open -g -j -n $app --args -quietEngine -recordingsPath $work/recordings
for _ in {1..40}; do [[ -n $(enginepid) ]] && break; sleep 0.5; done
m1=$(mainpid) e1=$(enginepid)
[[ -n $m1 && -n $e1 ]] && ok "app $m1 and engine $e1 run as two processes" || { bad "not running"; exit 1; }
[[ $(ps -o ppid= -p $e1 | tr -d ' ') == $m1 ]] && ok "the engine is the app's child" || bad "the engine's parent is $(ps -o ppid= -p $e1)"

kill -9 $m1; sleep 0.05
kill -0 $e1 2>/dev/null && ok "the app crashed; the engine kept running" || bad "the engine died with the app"
for _ in {1..40}; do m2=$(mainpid); [[ -n $m2 && $m2 != $m1 ]] && break; sleep 0.5; done
[[ -n ${m2:-} && $m2 != $m1 ]] && ok "the engine opened the app again ($m2)" || bad "the app did not come back"
for _ in {1..60}; do e2=$(enginepid); [[ -n $e2 && $e2 != $e1 ]] && ! kill -0 $e1 2>/dev/null && break; sleep 0.5; done
[[ -n ${e2:-} && $e2 != $e1 ]] && ! kill -0 $e1 2>/dev/null && ok "the new app retired the old engine and started its own ($e2)" || bad "old engine $e1 alive=$(kill -0 $e1 2>/dev/null && echo yes || echo no), new ${e2:-none}"
[[ $(engines) == 1 ]] && ok "exactly one engine" || bad "$(engines) engines"

kill -9 $e2
for _ in {1..20}; do e3=$(enginepid); [[ -n $e3 && $e3 != $e2 ]] && break; sleep 0.5; done
[[ -n ${e3:-} && $e3 != $e2 ]] && ok "the engine crashed; the app started a new one ($e3)" || bad "no engine after the engine crashed"
[[ $(mainpid) == $m2 ]] && ok "the app was untouched by the engine crash" || bad "the app restarted too"

kill -TERM $m2
for _ in {1..20}; do pgrep -f "$app/Contents" >/dev/null || break; sleep 0.5; done
pgrep -f "$app/Contents" >/dev/null && bad "quitting left a process behind" || ok "quitting the app quits the engine too"
exit $fail
