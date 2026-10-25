#!/usr/bin/env python3
"""A made-up vault for trying Glyph Record and taking its screenshots.

    python3 RecordTests/make-demo-vault.py <empty folder> [--audio]

Every name here is invented. --audio speaks each transcript with `say` into audio.m4a,
so the player and click-to-seek have something real to play.
"""
import json, os, subprocess, sys
from datetime import datetime, timedelta, timezone

WPS = 3.0  # words a second, matching `say -r 180`

PEOPLE = {
    "Sam Lee": ("Acme", ["Sammy"], "Runs procurement at Acme. Prefers a call to email, mornings."),
    "Kim Park": ("Globex", [], "Head of design at Globex. Wants the roadmap a quarter ahead."),
    "Pat Doe": ("Northwind", ["Patricia"], ""),
    "Lee Chen": (None, [], "Contractor for the kitchen."),
}
ACCOUNTS = {
    "Acme": "Our largest account. Renewal every October.",
    "Globex": "Design partner since spring.",
    "Northwind": "",
}

# folder, title, days ago, hour, people, accounts, tags, suggested, transcript, summary, decisions, actions
CONVS = [
    ("Work/Acme", "Acme renewal kickoff", 0, 9, ["Sam Lee"], ["Acme"], ["renewal", "pricing"],
     {"people": ["Kim Park"], "tags": ["q4-planning"]},
     [("Sam Lee", "Thanks for making time this early. I want to get the renewal moving before the budget freeze."),
      ("Me", "Of course. We can hold this year's price if you sign before the end of the month."),
      ("Sam Lee", "That helps a lot. Finance will ask about the seat count though, we grew by about forty people."),
      ("Me", "Then let's price the extra seats at the current rate and lock it for two years."),
      ("Sam Lee", "I like that. Can you send the order form today so I can start the approval?"),
      ("Me", "Yes, I'll send it this afternoon, and I'll copy Kim from Globex on the integration question."),
      ("Sam Lee", "Perfect. Let's check in on Thursday.")],
     "Sam wants the Acme renewal signed before the budget freeze. We offered to hold this year's price if they sign by the end of the month, and to price the forty new seats at the current rate, locked for two years.",
     ["Hold this year's price for a signature by October 31", "Price the new seats at the current rate for two years"],
     [("Send Sam the order form", False, "Me", "2026-10-25"), ("Check in with Sam on Thursday", False, None, "2026-10-29"),
      ("Ask finance about a two year lock", True, "Me", None)]),
    ("Work/Globex", "Globex design review", 0, 14, ["Kim Park"], ["Globex"], ["design", "roadmap"], {},
     [("Kim Park", "The new onboarding screens tested well, people found the record button in under five seconds."),
      ("Me", "Great. What about the empty states?"),
      ("Kim Park", "Those still read like a manual. We should cut them to one line and a single action."),
      ("Me", "Agreed. Let's do that before the beta.")],
     "Kim shared test results for the new onboarding: people found Record in under five seconds. The empty states still read like a manual, so they get cut to one line and one action before the beta.",
     ["Empty states get one line and one action"],
     [("Rewrite the empty states", False, "Kim Park", "2026-10-30")]),
    ("Work/Northwind", "Northwind pilot check-in", 1, 11, ["Pat Doe"], ["Northwind"], ["pilot"], {"tags": ["security-review"]},
     [("Pat Doe", "The pilot team is using it every day now, mostly for customer calls."),
      ("Me", "Any blockers before you roll it out wider?"),
      ("Pat Doe", "Security wants to see where the recordings live. If it stays on the laptop we are fine."),
      ("Me", "Everything stays on the Mac, I can send the one page summary.")],
     "Northwind's pilot team uses it daily for customer calls. Security's only question is where recordings live; they stay on the Mac, and we will send the one page summary.",
     [], [("Send Pat the security one pager", False, "Me", "2026-10-27")]),
    ("Work", "Weekly team sync", 2, 10, ["Sam Lee", "Kim Park", "Pat Doe"], [], ["team"], {},
     [("Kim Park", "Design is on track for the beta."), ("Pat Doe", "Northwind wants to expand the pilot."),
      ("Sam Lee", "Acme renewal is moving, order form goes out this week.")],
     "Design is on track for the beta, Northwind wants a bigger pilot and the Acme renewal is moving.", [],
     [("Plan the Northwind expansion", False, "Pat Doe", None), ("Book the beta retro", True, None, None)]),
    ("Work/Acme", "Acme pricing follow-up", 4, 16, ["Sam Lee"], ["Acme"], ["pricing"], {},
     [("Sam Lee", "Finance came back. They are fine with the price but want quarterly billing."),
      ("Me", "Quarterly works. I'll update the order form.")],
     "Acme finance accepted the price and asked for quarterly billing, which works.", ["Bill Acme quarterly"],
     [("Update the order form to quarterly billing", True, "Me", None)]),
    ("Work/Globex", "Globex roadmap planning", 6, 13, ["Kim Park"], ["Globex"], ["roadmap", "q4-planning"], {},
     [("Kim Park", "For next quarter I want calendar import and shared folders."),
      ("Me", "Calendar import is close. Shared folders need more thought.")],
     "Kim wants calendar import and shared folders next quarter. Calendar import is close; shared folders need more design.",
     [], [("Draft the shared folders proposal", False, "Me", "2026-11-05")]),
    ("Work", "Hiring chat with a designer", 8, 15, [], [], ["hiring"], {"people": ["Lee Chen"]},
     [("Me", "Tell me about a design you are proud of."),
      ("Speaker", "A banking app where we removed half the screens and support calls dropped by a third.")],
     "A strong candidate who cut a banking app's screens in half and lowered support calls by a third.", [],
     [("Send feedback to the recruiter", False, "Me", None)]),
    ("Work/Northwind", "Northwind security review", 9, 9, ["Pat Doe"], ["Northwind"], ["security-review"], {},
     [("Pat Doe", "Security signed off. They liked that nothing leaves the device.")],
     "Northwind security signed off; nothing leaving the device was the deciding point.", [], []),
    ("Work/Acme", "Acme quarterly business review", 13, 10, ["Sam Lee"], ["Acme"], ["qbr"], {},
     [("Sam Lee", "Usage is up thirty percent this quarter, mostly from the sales team.")],
     "Acme usage grew thirty percent this quarter, mostly in sales.", [], [("Share the usage report with Sam", True, None, None)]),
    ("Home", "Call with the contractor", 1, 18, ["Lee Chen"], [], ["kitchen", "budget"], {},
     [("Lee Chen", "The cabinets arrive on the third, we can start demolition the week before."),
      ("Me", "What about the deposit?"), ("Lee Chen", "Half now and half when the counters are in.")],
     "Cabinets arrive November 3; demolition starts the week before. The deposit is half now, half when the counters are in.",
     ["Pay half the deposit now"], [("Pay the kitchen deposit", False, "Me", "2026-10-28"), ("Pick the counter stone", False, None, None)]),
    ("Home/Kitchen", "Counter stone options", 3, 17, ["Lee Chen"], [], ["kitchen"], {},
     [("Lee Chen", "Quartz is easier to keep clean, marble looks warmer but stains.")],
     "Quartz is easier to keep, marble looks warmer but stains.", [], []),
    ("Home", "Planning the holiday trip", 5, 20, [], [], ["travel"], {},
     [("Me", "If we leave on the twentieth we miss the worst traffic.")],
     "Leaving on the twentieth avoids the worst traffic.", ["Leave on December 20"], [("Book the cabin", False, None, "2026-11-01")]),
    ("Home", "Budget for next year", 11, 19, [], [], ["budget"], {},
     [("Me", "Let's keep the kitchen under the number we set and move the rest to savings.")],
     "Keep the kitchen within budget and move the rest to savings.", [], []),
    ("Recordings", "Voice memo on the walk", 0, 7, [], [], [], {},
     [("", "Idea: the recorder panel could show who is speaking, not just the level."),
      ("", "Also, tags during the call should autocomplete from people I already know.")],
     "", [], []),
    ("Recordings", "Recording Oct 22", 3, 12, [], [], [], {"people": ["Sam Lee"], "accounts": ["Acme"]},
     [("", "Quick note after talking to Sam about the Acme renewal and the new seats.")],
     "", [], []),
    ("Recordings", "Podcast notes", 7, 8, [], [], ["ideas"], {},
     [("", "The best interfaces disappear. You notice the work, not the tool.")],
     "A note on interfaces that disappear: you notice the work, not the tool.", [], []),
]


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def slug(title, created):
    s = "".join(c.lower() if c.isalnum() else "-" for c in title)
    s = "-".join(p for p in s.split("-") if p)
    return f"{created[:10]}-{s}"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def main():
    root = sys.argv[1]
    audio = "--audio" in sys.argv
    now = datetime(2026, 10, 25, 23, 0, tzinfo=timezone.utc)
    os.makedirs(os.path.join(root, ".memosa", "index"), exist_ok=True)
    os.makedirs(os.path.join(root, "Work", "Archive"), exist_ok=True)
    for name, (account, aliases, body) in PEOPLE.items():
        fm = "---\nkind: person\n" + (f"account: {account}\n" if account else "") + \
             (f"aliases: [{', '.join(aliases)}]\n" if aliases else "") + "---\n\n"
        write(os.path.join(root, "People", name + ".md"), fm + (body + "\n" if body else ""))
    for name, body in ACCOUNTS.items():
        write(os.path.join(root, "Accounts", name + ".md"), "---\nkind: account\n---\n\n" + (body + "\n" if body else ""))

    for (folder, title, days, hour, people, accounts, tags, sugg, lines, summary, decisions, actions) in CONVS:
        created = iso((now - timedelta(days=days)).replace(hour=hour, minute=5 + days, second=0))
        cid = f"{folder}/{slug(title, created)}"
        d = os.path.join(root, cid)
        speakers, segs, t = {}, [], 0.0
        for who, text in lines:
            key = ""
            if who:
                key = next((k for k, v in speakers.items() if v == who), f"S{len(speakers) + 1}")
                speakers[key] = who
            dur = max(1.5, len(text.split()) / WPS) + 0.4
            segs.append({"start": round(t, 1), "end": round(t + dur, 1), "speaker": key, "text": text})
            t += dur
        # Memos are as long as their audio; calls read like real meetings in the list.
        duration = int(t) if folder == "Recordings" else int(t * 37) + 60 * (days % 7)
        meta = {"schema": 1, "id": cid, "title": title, "created": created, "duration_sec": duration,
                "people": people, "accounts": accounts, "tags": tags}
        if sugg:
            meta["suggested"] = {"people": sugg.get("people", []), "accounts": sugg.get("accounts", []),
                                 "tags": sugg.get("tags", []), "dismissed": []}
        meta.update({"source": "recording", "audio": "audio.m4a", "updated": created})
        write(os.path.join(d, "meta.json"), json.dumps(meta, indent=2))
        tr = {"schema": 1, "language": "en-US", "model": "apple-speech", "speakers": speakers, "segments": segs}
        write(os.path.join(d, "transcript.json"), json.dumps(tr, indent=2))
        write(os.path.join(d, "transcript.txt"), "".join(
            f"[{int(s['start']) // 60:02d}:{int(s['start']) % 60:02d}] {speakers.get(s['speaker'], '') + ': ' if s['speaker'] else ''}{s['text']}\n" for s in segs))
        if summary or actions:
            md = f"---\ntitle: {title}\ndate: {created[:10]}\npeople: [{', '.join(people)}]\ntags: [{', '.join(tags)}]\n---\n\n"
            md += "## Summary\n" + summary + "\n\n"
            if decisions:
                md += "## Decisions\n" + "".join(f"- {x}\n" for x in decisions) + "\n"
            md += "## Action items\n"
            for text, done, owner, due in actions:
                meta_c = "; ".join(x for x in [f"owner: {owner}" if owner else "", f"due: {due}" if due else ""] if x)
                md += f"- [{'x' if done else ' '}] {text}" + (f"  <!-- {meta_c} -->" if meta_c else "") + "\n"
            write(os.path.join(d, "notes.md"), md)
        if audio:
            speech = " ... ".join(text for _, text in lines)
            subprocess.run(["say", "-r", "180", "-o", os.path.join(d, "audio.m4a"), "--file-format=m4af", "--data-format=aac", speech], check=True)
    print(f"{len(CONVS)} conversations in {root}")


if __name__ == "__main__":
    main()
