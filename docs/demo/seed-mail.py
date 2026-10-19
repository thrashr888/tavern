#!/usr/bin/env python3
"""Seeds a demo event store with Guild mail: python3 seed-mail.py <tavern.sqlite>."""
import json, sqlite3, sys, time

now = time.time()
H = 3600
threads = [
    ("t-digest", "Weekly digest: what shipped", None, [
        ("sage", "Sage <sage@example.com>", 30 * H,
         "Highlights this week: the pricing page fix, faster staging deploys, and the new onboarding emails.\n\nNeeds from Sam: approve the release notes draft before Friday.\n\nSage"),
    ]),
    ("t-pricing", "Website: annual plan price", "website", [
        ("lark", "Lark <lark@example.com>", 5 * H, "The pricing page still says $96 a year. Scout, can you take this one?"),
        ("scout", "Scout <scout@example.com>", 4 * H, "On it. PR is up: https://github.com/example/website/pull/42"),
        (None, "Sam <sam@example.com>", 3 * H, "Thanks both. Merge when CI is green."),
    ]),
    ("t-staging", "Infra: staging cleanup", "infra", [
        ("forge", "Forge <forge@example.com>", 50 * 60, "Staging is healthy. There's an old database container holding 14 GB; I've asked Sam in Tavern before removing it."),
    ]),
    ("t-onboarding", "Onboarding email copy", None, [
        ("lark", "Lark <lark@example.com>", 52 * H, "Draft of the three onboarding emails is in the handbook. Comments welcome."),
        ("sage", "Sage <sage@example.com>", 49 * H, "Tightened the second one and added a link to the docs.\n\nSage"),
    ]),
]
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, source_id TEXT NOT NULL,
  thread_key TEXT NOT NULL, author_agent TEXT, source_ts REAL NOT NULL, received_ts REAL NOT NULL, kind TEXT NOT NULL,
  payload BLOB NOT NULL, UNIQUE (source, source_id));
CREATE TABLE IF NOT EXISTS cursors (source TEXT PRIMARY KEY, value TEXT NOT NULL, updated_ts REAL NOT NULL);
""")
n = 0
for thread_id, subject, project, messages in threads:
    for author, sender, ago, body in messages:
        n += 1
        payload = {"threadId": thread_id, "subject": subject, "from": sender, "snippet": body[:120], "body": body}
        if project:
            payload["project"] = project
        db.execute("INSERT OR REPLACE INTO events (source, source_id, thread_key, author_agent, source_ts, received_ts, kind, payload) "
                   "VALUES ('gmail', ?, ?, ?, ?, ?, 'mail.message', ?)",
                   (f"m{n}", f"gmail-thread:{thread_id}", author, now - ago, now - ago, json.dumps(payload).encode()))
db.commit()
print(f"seeded {n} messages")
