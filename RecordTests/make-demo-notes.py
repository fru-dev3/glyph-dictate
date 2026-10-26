#!/usr/bin/env python3
"""A made-up Glyph Studio vault with notes and dictations, for trying Glyph Jot and taking
its screenshots.

    python3 RecordTests/make-demo-notes.py <studio vault folder> [<recordings vault>]

Every word here is invented. The Studio part is the documented layout Glyph Jot reads
(docs/vault-format.md, "Studio links"): people, companies and an app (Products), projects
and domains. With a recordings vault (from make-demo-vault.py), the first note is linked to
the newest recording as a jot said during it.
"""
import json, os, sys
from datetime import datetime, timedelta, timezone

PEOPLE = {"sam-lee": ("Sam Lee", ["Sammy"]), "kim-park": ("Kim Park", []), "pat-doe": ("Pat Doe", ["Patricia"])}
ORGS = {"acme": ("Acme", ["Acme Corp"]), "globex": ("Globex", []), "northwind": ("Northwind", [])}
APPS = {"acme-portal": {"id": "acme-portal", "name": "Acme Portal", "company": "Acme"}, "initech": {"id": "initech", "name": "Initech"}}
MISSIONS = {"acme-renewal": "Acme renewal", "kitchen-remodel": "Kitchen remodel"}
DOMAINS = {"career": "Career", "home": "Home", "health": "Health", "money": "Money", "learning": "Learning"}
# Which notes are filed where (by NOTES index).
NOTE_LINKS = {0: ["person/sam-lee", "org/acme", "domain/career"], 1: ["domain/learning"], 2: ["domain/home", "mission/kitchen-remodel"],
              4: ["domain/health"], 5: ["person/kim-park", "org/globex"]}

NOTES = [
    (0, 9, 41, "Mac", None, "Send Sam the order form today, and ask finance about the forty new seats before Friday."),
    (0, 8, 12, "iPhone", "Riverside Park", "The best onboarding is the one you never notice. Every extra screen is a question the product failed to answer."),
    (1, 18, 5, "iPhone", "Corner Market", "Buy tiles for the kitchen backsplash, the matte green ones Lee showed us."),
    (1, 11, 30, "Mac", None, "Idea: a weekly digest of open action items across every account, sent Monday at seven."),
    (2, 7, 55, "iPhone", "Trailhead Lot", "Ran the long loop in fifty two minutes. Knee felt fine on the downhill this time."),
    (3, 16, 20, "Mac", None, "Kim wants the roadmap a quarter ahead. Draft the Q1 themes before the design review."),
    (4, 21, 2, "iPhone", None, "Read chapter four tonight. The part about deliberate practice is worth a second pass."),
]
DICTATIONS = [
    (0, 10, 2, "Mail", None, "Hi Sam, attached is the order form with the forty additional seats at the current rate. Let me know if finance needs anything else."),
    (0, 9, 15, "Terminal", "glyph-jot", "git commit -m \"Recorder panel: show when a jot is private\""),
    (0, 8, 50, "Slack", None, "on my way, five minutes out"),
    (1, 15, 40, "Safari", None, "best matte green ceramic tile for a kitchen backsplash"),
    (1, 14, 2, "Notes", None, "Questions for the Globex review: who owns the onboarding flow, and what does done look like for Q1?"),
    (2, 12, 30, "Claude", "glyph-jot", "Make the transcript show where I jotted during a recording, with a link to the note."),
    (3, 9, 5, "Calendar", None, "Northwind pilot check-in, Thursday at ten"),
]

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)


def main():
    vault, rec = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
    data = os.path.join(vault, "data")
    for slug, (name, aliases) in PEOPLE.items():
        put(os.path.join(data, "entities/people", slug, "entity.md"), f"---\nname: {name}\nkind: person\naliases: [{', '.join(aliases)}]\nsaved: true\n---\n")
    for slug, (name, aliases) in ORGS.items():
        put(os.path.join(data, "entities/orgs", slug, "entity.md"), f"---\nname: {name}\nkind: org\naliases: [{', '.join(aliases)}]\nsaved: true\n---\n")
    for slug, m in APPS.items():
        put(os.path.join(data, "apps", slug, "manifest.json"), json.dumps(m, indent=2))
    for slug, name in MISSIONS.items():
        put(os.path.join(data, "missions", slug, "mission.md"), f'---\nname: "{name}"\nstatus: active\n---\n')
    for slug, label in DOMAINS.items():
        put(os.path.join(data, "domains", slug, "manifest.json"), json.dumps({"schema": 1, "identity": {"name": slug, "label": label}}))
    notes = os.path.join(data, "domains/notes/source/jot")  # where Glyph Jot keeps notes in a Studio vault
    os.makedirs(notes, exist_ok=True)
    now = datetime.now().replace(second=0, microsecond=0)
    files = []
    for days, h, m, device, place, text in NOTES:
        t = (now - timedelta(days=days)).replace(hour=h, minute=m)
        stem = t.strftime("%Y-%m-%d %H-%M-%S")
        fm = f"---\ndate: {t.strftime('%Y-%m-%dT%H:%M:%S')}\ntags: []\nkind: voice\ndevice: {device}\n"
        if len(files) in NOTE_LINKS: fm += f"links: [{', '.join(NOTE_LINKS[len(files)])}]\n"
        if place: fm += f'place: "{place}"\n'
        fm += "source: jot\n---\n\n"
        open(os.path.join(notes, stem + ".md"), "w").write(fm + text + "\n")
        files.append(stem + ".md")
    log = os.path.join(data, "apps", "jot", "dictations")
    os.makedirs(log, exist_ok=True)
    lines = []
    for days, h, m, app, project, text in DICTATIONS:
        t = (now - timedelta(days=days)).replace(hour=h, minute=m).astimezone(timezone.utc)
        e = {"at": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "text": text, "heard": text, "mode": "dictate", "app": app,
             "bundle": "", "seconds": round(len(text.split()) / 2.6, 1), "finish_ms": 140}
        if project: e["project"] = project
        lines.append(json.dumps(e, sort_keys=True))
    open(os.path.join(log, now.strftime("%Y-%m") + ".demo-mac-local.jsonl"), "w").write("\n".join(lines) + "\n")
    if rec:
        metas = []
        for d, _, fs in os.walk(rec):
            if "meta.json" in fs and "/." not in d:
                m = json.load(open(os.path.join(d, "meta.json")))
                if m.get("duration_sec", 0) > 300: metas.append((m["created"], d, m))
        if metas:
            _, d, m = sorted(metas)[-1]
            m["jots"] = [{"start": 312.4, "end": 321.9, "kind": "dictate"},
                         {"start": 498.0, "end": 505.6, "kind": "thought", "note": files[0]}]
            open(os.path.join(d, "meta.json"), "w").write(json.dumps(m, indent=2) + "\n")
            print("linked", files[0], "to", m["id"])
    print("studio vault, notes and dictations in", vault)

if __name__ == "__main__":
    main()
