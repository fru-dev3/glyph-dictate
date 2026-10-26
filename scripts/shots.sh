#!/bin/zsh
# Screenshots of Glyph Jot for review and the site, from a Debug build, with made-up data
# (RecordTests/make-demo-vault.py and make-demo-notes.py) and a quiet engine (no talk key,
# no mic), so it can run while someone works: windows open behind theirs and are captured
# by window, not by screen. Light and dark, three window sizes.
#   scripts/shots.sh <out folder> [path/to/Debug/Jot.app]
set -uo pipefail
cd "${0:A:h}/.."
# The app by full path: cleanup kills by it, and must never match another copy (another
# worktree's Debug build, or the installed /Applications/Jot.app).
out=${1:?out folder}; app=${2:-$PWD/build/Build/Products/Debug/Jot.app}
[[ $app == /Applications/* ]] && { echo "shots.sh runs a Debug build, never the installed app"; exit 2; }
mkdir -p $out
demo=$(mktemp -d /tmp/jot-shots.XXXXXX)
python3 RecordTests/make-demo-vault.py $demo/rec >/dev/null
python3 RecordTests/make-demo-notes.py $demo/notes $demo/rec >/dev/null
print 'import Foundation; let a = CommandLine.arguments; DistributedNotificationCenter.default().postNotificationName(.init(a[1]), object: a[2], userInfo: nil, deliverImmediately: true)' > $demo/post.swift
swiftc -O -o $demo/post $demo/post.swift 2>/dev/null || exit 2
hook() { $demo/post dev.fru.jot.mac.app.check "$1"; sleep ${2:-0.8}; }
# The Debug build shares the installed app's settings (one bundle id): put back the window
# sizes, sidebar and filters it changed, so the shots never resize anyone's library.
defaults export dev.fru.jot.mac $demo/prefs-before.plist 2>/dev/null
restore() {
  pkill -TERM -f "$app/Contents/MacOS/Jot"; sleep 2; pkill -9 -f "$app/Contents" 2>/dev/null
  [[ -f $demo/prefs-before.plist ]] && python3 - $demo/prefs-before.plist <<'PY'
import plistlib, subprocess, sys
before = plistlib.load(open(sys.argv[1], "rb"))
now = plistlib.loads(subprocess.run(["defaults", "export", "dev.fru.jot.mac", "-"], capture_output=True).stdout or plistlib.dumps({}))
ui = lambda k: k.startswith(("NSWindow Frame", "NSSplitView")) or k in ("sidebar.closed", "historyFilter", "recordingsPath", "vaultPath")
changed = [k for k in set(before) | set(now) if ui(k) and before.get(k) != now.get(k)]
for k in changed:
    if k in before: now[k] = before[k]
    else: now.pop(k, None)
if changed:
    subprocess.run(["defaults", "import", "dev.fru.jot.mac", "-"], input=plistlib.dumps(now), check=True)
    print("put back", len(changed), "settings")
PY
}
trap restore EXIT
open -g -n $app --args -quietEngine -recordingsPath $demo/rec -vaultPath $demo/notes
sleep 5
hook library 1.5
# With nobody at the Mac the window comes forward, so the shots show it active (not greyed).
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
if (( idle >= 300 )); then
  pid=$(pgrep -f "$app/Contents/MacOS/Jot" | head -1)
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1
  hook front
fi
win() { local kind=${1:-} # the window number of the library (or the first other window when $1 = other)
  hook "windows:$demo/w.json" 0.5
  python3 -c "import json,sys; w=json.load(open('$demo/w.json')); big=[x for x in w if not x['panel'] and x['w'] > 300]; lib=[x for x in big if x['title']=='Glyph Jot']; pick=[x for x in w if x['panel']] if '$kind'=='panel' else ([x for x in big if x['title']!='Glyph Jot'] if '$kind'=='other' else lib); print(pick[0]['number'] if pick else '')"
}
shot() { local n=$(win ${2:-}); [[ -n $n ]] && screencapture -x -o -l$n "$out/$1.png" && echo "$1"; }
conv=Work/Acme/$(ls $demo/rec/Work/Acme | grep -v '^_' | grep kickoff | head -1)
linked=$(python3 -c "import json,glob; print([json.load(open(f))['id'] for f in glob.glob('$demo/rec/**/meta.json', recursive=True) if 'jots' in json.load(open(f))][0])")
for look in light dark; do
  hook "look:$look"
  for size in 1280x800 1728x1080 900x600; do
    hook "size:$size"
    hook "side:all" 1.5; shot "$look-$size-all"
    hook "side:recordings"; hook "conv:$conv"; hook "tab:summary" 1.2; shot "$look-$size-recording-summary"
    hook "side:notes" 1.2; shot "$look-$size-notes"
    hook "side:dictations" 1.5; shot "$look-$size-dictations"
    hook "side:object:person/sam-lee" 1.2; shot "$look-$size-person"
    [[ $size == 1280x800 ]] || continue
    hook "side:object:org/acme" 1.2; shot "$look-$size-product"
    hook "side:object:domain/career" 1.2; shot "$look-$size-domain"
    hook "side:object:mission/kitchen-remodel" 1.2; shot "$look-$size-project"
    hook "side:recordings"; hook "conv:$linked"; hook "tab:transcript" 1.2; shot "$look-$size-transcript-with-jots"
    # Settings and the recorder panel come to the front: only when nobody is at the Mac.
    idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
    (( idle >= 300 )) || { echo "skipped settings and recorder shots (Mac in use)"; continue; }
    hook "settings" 1.5; shot "$look-settings-jot" other; hook "closesettings"
    hook "side:recordings"; hook "feed:/System/Library/Sounds/Submarine.aiff"; hook "record:start" 2.5
    hook "jot:on" 1.2; shot "$look-recorder-jotting" panel
    hook "jot:off" 1; shot "$look-recorder-after-jot" panel
    hook "record:stop" 2
  done
done
echo "screenshots in $out"
