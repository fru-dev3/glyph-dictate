// Self-check for FnGesture, run outside the app: cat Mac/FnKey.swift Mac/FnKeyCheck.swift | swift -
// (top-level code, so it only works as a script; the JotMac target excludes this file).
var g = FnGesture()
// Hold to talk.
assert(g.fnDown(0) == .start)
assert(g.fnUp(1.2) == .stop)
assert(g.tick(2) == .none)
// A lone tap is dropped.
g = FnGesture()
assert(g.fnDown(0) == .start)
assert(g.fnUp(0.1) == .none)
assert(g.tick(0.46) == .cancel)
// Double-tap locks; the next Fn stops.
g = FnGesture()
assert(g.fnDown(0) == .start)
assert(g.fnUp(0.1) == .none)
assert(g.fnDown(0.3) == .none && g.locked)
assert(g.fnUp(0.35) == .none)
assert(g.tick(0.5) == .none)
assert(g.fnDown(9) == .stop && !g.recording)
// Fn+arrow cancels a hold; typing while locked doesn't, Esc does.
g = FnGesture()
_ = g.fnDown(0)
assert(g.cancel(esc: false) == .cancel)
g = FnGesture()
_ = g.fnDown(0); _ = g.fnUp(0.1); _ = g.fnDown(0.2)
assert(g.cancel(esc: false) == .none)
assert(g.cancel(esc: true) == .cancel)
// Second tap too late: the first is dropped, the late press starts fresh.
g = FnGesture()
_ = g.fnDown(0); _ = g.fnUp(0.1)
assert(g.tick(0.5) == .cancel)
assert(g.fnDown(0.6) == .start)
// Late second press before the timer fires becomes a hold, not a lost recording.
g = FnGesture()
_ = g.fnDown(0); _ = g.fnUp(0.1)
assert(g.fnDown(0.5) == .none && g.recording)
assert(g.tick(0.52) == .none)
assert(g.fnUp(1.5) == .stop)
print("FnGesture: all checks passed")
