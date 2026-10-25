#!/bin/zsh
# Must-pass test for Glyph Jot (decision d-mvo8wkr4): you can jot while recording.
# A Debug build records a meeting (a fed sound file, played in real time) while its
# dictation engine hears a sentence through the speakers and types it into a test window,
# then saves a note with Fn+Shift. Passes when: the typed words landed in that window, the
# recording kept running, meta.json holds both jots (the note linked to its moment), and
# the transcript and summary leave out what was jotted but keep the meeting around it.
#
#   scripts/jot-while-recording-check.sh [path/to/Debug/Jot.app]
#
# Only when the Mac is idle (15 minutes untouched; JOT_IDLE=seconds to change): it plays speech aloud, types into a test window of its own and
# quits the installed Glyph Jot for the duration (started again at the end). Notes and the
# dictation log go to a throwaway folder, not your vault; the clipboard and volume come back.
set -uo pipefail
zmodload zsh/datetime
cd "${0:A:h}/.."
app=${1:-build/Build/Products/Debug/Jot.app}
[[ -x $app/Contents/MacOS/Jot ]] || { echo "build the Debug app first (xcodebuild -scheme JotMac -configuration Debug -derivedDataPath build)"; exit 2; }
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
(( idle >= ${JOT_IDLE:-900} )) || { echo "the Mac is in use (idle ${idle}s, needs ${JOT_IDLE:-900}); try later"; exit 3; }

work=$(mktemp -d /tmp/jot-check.XXXXXX)
rec=$work/recordings notes=$work/notes
mkdir -p $rec $notes
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
# A compiled poster: `swift -e` takes seconds, which would throw the timing off.
print 'import Foundation; let a = CommandLine.arguments; DistributedNotificationCenter.default().postNotificationName(.init(a[1]), object: a[2], userInfo: nil, deliverImmediately: true)' > $work/post.swift
swiftc -O -o $work/post $work/post.swift 2>/dev/null || { echo "swiftc failed"; exit 2; }
app_post() { $work/post "$1" "$2"; }
hook() { app_post dev.fru.jot.mac.app.check "$1"; }      # the app (recording, library)
engine() { app_post dev.fru.jot.mac.check "$1"; }        # the dictation engine

# The meeting: A, then B (what gets jotted), then C, then quiet for the note.
A="Sam wants the Acme renewal signed before the budget freeze."
B="Remind me to book the dentist on Thursday."
C="We will hold this year's price for two years."
N="Call the plumber about the kitchen sink."
for k in A B C; do say -r 170 -o $work/$k.aiff "${(P)k}"; done
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
dA=$(dur $work/A.aiff); dB=$(dur $work/B.aiff); dC=$(dur $work/C.aiff)
bStart=$(( dA + 1.5 )); cStart=$(( bStart + dB + 6 )); cEnd=$(( cStart + dC ))
ffmpeg -v error -y -i $work/A.aiff -i $work/B.aiff -i $work/C.aiff -filter_complex \
  "aevalsrc=0:d=1.5[s1];aevalsrc=0:d=6[s2];aevalsrc=0:d=14[s3];[0][s1][1][s2][2][s3]concat=n=6:v=0:a=1,aresample=48000" \
  -ac 1 $work/feed.wav || { echo "ffmpeg failed"; exit 2; }

# Put things back however this ends.
clip=$(pbpaste 2>/dev/null)
vol=$(osascript -e 'output volume of (get volume settings)')
installed=$(pgrep -f '^/Applications/Jot.app/Contents/MacOS/Jot$')
# The typing target is the debug app's own test window ("Jot test target"); the engine is
# another process, so to it this is any other app.
front() { hook scratch; sleep 0.3
  local pid=$(pgrep -f "$app/Contents/MacOS/Jot" | head -1)
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1; sleep 0.4
  [[ $(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true') == $pid ]]; }
oldNotes=$(defaults read dev.fru.jot.mac vaultPath 2>/dev/null || true)
restore() {
  hook "record:stop"; sleep 1
  pkill -TERM -f "$app/Contents/MacOS/Jot" 2>/dev/null   # the app quits the normal way and takes its engine
  for _ in {1..30}; do pgrep -f "$app/Contents" >/dev/null || break; sleep 0.5; done
  pkill -9 -f "$app/Contents" 2>/dev/null
  if [[ -n $oldNotes ]]; then defaults write dev.fru.jot.mac vaultPath "$oldNotes"; else defaults delete dev.fru.jot.mac vaultPath 2>/dev/null; fi
  defaults delete dev.fru.jot.mac recordingsPath 2>/dev/null
  osascript -e "set volume output volume $vol"
  print -rn -- "$clip" | pbcopy
  [[ -n $installed ]] && open -g /Applications/Jot.app   # back in the background, as it was
}
trap restore EXIT

[[ -n $installed ]] && { kill $installed; sleep 2; }
defaults write dev.fru.jot.mac vaultPath $notes   # notes and the dictation log go to the throwaway folder
osascript -e 'set volume output volume 45'
open -n $app --args -recordingsPath $rec
for _ in {1..40}; do pgrep -f "Glyph Jot Dictation.app" >/dev/null && break; sleep 0.5; done
pgrep -f "Glyph Jot Dictation.app" >/dev/null && ok "the app started its dictation engine (its own process)" || bad "no dictation engine process"
eng=$(pgrep -f "Glyph Jot Dictation.app" | head -1)
sleep 6   # speech model warm-up

front || bad "could not bring the test window forward"
hook "feed:$work/feed.wav"; sleep 0.3
hook "record:start"; t0=$EPOCHREALTIME
# Seconds since the recording started (the feed plays in real time from there).
until_t() { local w=$(( $1 - (EPOCHREALTIME - t0) )); (( w > 0 )) && sleep $w; }
until_t $(( bStart - 0.6 ))
front || { bad "the test window lost the front"; exit 1; }
engine "start"; sleep 0.6
say -r 170 "$B"
sleep 0.8; engine "stop"
until_t $(( cEnd + 1.5 ))
front || { bad "the test window lost the front"; exit 1; }
engine "start:thought"; sleep 0.6
say -r 170 "$N"
sleep 1.2; engine "stop"
sleep 4
hook "state:$work/state.json"; sleep 1
grep -q '"recording" : "Recordings' $work/state.json && ok "the recording kept running through both jots" || bad "the recording stopped: $(cat $work/state.json)"
[[ $(pgrep -f "Glyph Jot Dictation.app" | head -1) == $eng ]] && ok "the engine ran the whole time (pid $eng)" || bad "the engine restarted"
hook "record:stop"

hook "scratchtext:$work/typed.txt"; sleep 0.5
typed=$(cat $work/typed.txt 2>/dev/null)
[[ ${typed:l} == *dentist* ]] && ok "jotted words were typed where the cursor was: \"$typed\"" || bad "the test window has \"$typed\""

conv=$(ls -d $rec/Recordings/*/ 2>/dev/null | while read d; do [[ -f $d/meta.json ]] && grep -q '"source": "recording"' $d/meta.json && echo $d; done | tail -1)
for _ in {1..120}; do [[ -f $conv/transcript.txt && -f $conv/notes.md ]] && break; sleep 1; done
meta=$(cat $conv/meta.json 2>/dev/null)
python3 - "$conv/meta.json" "$notes" <<'EOF' && ok "meta.json holds both jots, the note linked to its moment" || bad "jots in meta.json: $meta"
import json, os, sys
m = json.load(open(sys.argv[1]))
j = m.get("jots", [])
kinds = [x["kind"] for x in j]
assert len(j) == 2 and kinds == ["dictate", "thought"], j
assert all(x["end"] > x["start"] for x in j), j
note = j[1].get("note")
assert note and os.path.exists(os.path.join(sys.argv[2], "data/domains/notes/source/jot", note)) or os.path.exists(os.path.join(sys.argv[2], note)), (note, os.listdir(sys.argv[2]))
EOF
tr=$(cat $conv/transcript.txt 2>/dev/null)
[[ ${tr:l} == *budget* && ${tr:l} == *price* ]] && ok "the meeting around the jot is in the transcript" || bad "transcript lost the meeting: $tr"
[[ ${tr:l} != *dentist* && ${tr:l} != *plumber* ]] && ok "what was jotted is not in the transcript" || bad "the jot leaked into the transcript: $tr"
sum=$(cat $conv/notes.md 2>/dev/null)
[[ ${sum:l} != *dentist* ]] && ok "nor in the summary" || bad "the jot leaked into the summary"
noteText=$(cat $notes/*.md $notes/**/*.md 2>/dev/null)
[[ ${noteText:l} == *plumber* ]] && ok "Fn+Shift saved the note" || bad "no note with the words"
echo "transcript: $(echo $tr | tr '\n' ' ')"
echo "evidence: $work"
exit $fail
