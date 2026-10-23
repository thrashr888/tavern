---
name: pi-agent-model-switch
description: "Pi agent model switch. Use when: Paul orders a model change for Tally, Ember or Flint."
metadata:
  id: SB-18
  version: 1
  kind: spell
  owner: peter
  review-owner: rook
  applies-to: peter
  proposed-by: "Peter"
  source: Spellbook sheet row 18, ported 2026-10-22
---

# Pi agent model switch

## When to use

Paul orders a model change for Tally, Ember or Flint

## Steps

1. Confirm the exact model version with Paul first.
2. ser8: edit the systemd service template; Macs: edit the LaunchAgent plist.
3. daemon-reload / restart the agent.
4. Verify via RPC get_state on 127.0.0.1:18999.
5. Report per agent.

## Done when

Not written yet. Add it at the next Friday review.

## Tools

SSH, systemd / launchd, Pi RPC

## Permissions

This spell grants no authority. Follow Outward-action check (SB-12) and Paul's standing rules: ask Paul before anything outside the Smithery or anything irreversible, and keep secrets out of mail, docs and repos.

## Notes

Latest sonnet was ambiguous once (5-5 vs 4.6); Paul's call was 4.6 for all three, 2026-10-15.
