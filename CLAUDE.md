# CLAUDE.md

Tavern is a SwiftUI macOS app (Swift package, macOS 14+).

- Build and test only work on macOS: `scripts/check.sh` before every push (there is no CI; macOS builds run locally, never in GitHub Actions). `scripts/bundle.sh` installs a release build; `scripts/release.sh` cuts a release from the Mac: checks, signs, notarizes, zips, tags and publishes the GitHub release (it needs `RELEASE_APPROVED=yes`, which only Paul sets).
- Pi agents have exactly one thread each. Never add session lists or new/switch-session UI.
- Event log rows dedup on `(source, source_id)`. Cursors move only inside the transaction that stores their events.
- Page restore uses stable Tavern ids, never display names.
- Personal setup (members, hosts, links, mail rules) belongs in the user's `roster.json`, never in code.
- Never commit credentials. Linear writes stay limited to agent labels, issue creation and issue field edits.
