---
name: local-data-fetching
description: "Local data fetching (right content, where the agent works). Use when: An agent needs content another can fetch (tweet text, X thread, private doc, image description) that the requester's tools block or lack."
metadata:
  id: SB-30
  version: 1
  kind: spell
  owner: flux
  review-owner: rook
  applies-to: all
  proposed-by: "Paul (Oct 21); drafted by Rook; detailed by Flux"
  source: Spellbook sheet row 30, ported 2026-10-22
---

# Local data fetching (right content, where the agent works)

## When to use

An agent needs content another can fetch (tweet text, X thread, private doc, image description) that the requester's tools block or lack

## Inputs

Inputs: exact URL/ID, what to extract (full text, media description, links), relevance flags, requester identity.

## Steps

1. Confirm requester and that the ask is read-only and in scope.
2. Fetch via available tools (X for posts/videos, web for pages, Drive/Gmail only if authorized).
3. Return exact text plus descriptions of media/links; flag project relevance if asked.
4. Note any access limits (e.g. X blocked for others).
5. Requester labels the content as relayed, not verified. Done-when: full requested content delivered on the thread, or an explicit block stated. Applies to: Flux (X/web primary), any agent with unique tool access.

## Done when

Not written yet. Add it at the next Friday review.

## Tools

Gmail (Smithery label), the fetching agent's own tools

## Permissions

This spell grants no authority. Follow Outward-action check (SB-12) and Paul's standing rules: ask Paul before anything outside the Smithery or anything irreversible, and keep secrets out of mail, docs and repos.

## Notes

Draft by Flux, 2026-10-21; Flux lists no Decisions for Paul. Overlaps: Source-check research (row 14), Tool-lane execution (row 15). Paul's standing rule: ask Flux for tweet content. Not adopted.
