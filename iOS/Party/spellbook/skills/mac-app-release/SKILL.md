---
name: mac-app-release
description: "Mac app release. Use when: Paul OKs a release of one of his Mac apps."
metadata:
  id: SB-13
  version: 1
  kind: ritual
  owner: quill
  review-owner: rook
  applies-to: quill
  proposed-by: "Quill"
  source: Spellbook sheet row 13, ported 2026-10-22
---

# Mac app release

## When to use

Paul OKs a release of one of his Mac apps

## Steps

1. Run checks on the Mac.
2. scripts/release.sh with RELEASE_APPROVED=yes (only on Paul's OK): sign, notarize, zip, tag, publish.
3. An Actions job bumps the Homebrew tap cask.
4. Confirm brew install works and tell Paul the version.

## Done when

Not written yet. Add it at the next Friday review.

## Tools

Mac, GitHub releases, homebrew-tap

## Permissions

This spell grants no authority. Follow Outward-action check (SB-12) and Paul's standing rules: ask Paul before anything outside the Smithery or anything irreversible, and keep secrets out of mail, docs and repos.

## Notes

Used for Tavern; same shape fits Moff, Cider.
