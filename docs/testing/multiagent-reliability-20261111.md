# Shared-chat reliability verification, November 11, 2026

## Scope

This change publishes the shared project-chat implementation, its draft/widget/UI dependencies, and reliability regressions. Gateway integration, mail catch-up, discovery/tailnet changes, and general settings work remain outside this PR. The exact staged source tree was exported and tested independently, rather than relying on the broader development worktree.

No merge, production deployment, or release is part of this verification.

## New defects reproduced and fixed

### Explicit prompt rejection blocked the queue

The real app dispatcher and Pi session treated every failed send as an unknown delivery. A server response explicitly rejecting a prompt therefore left the request uncertain forever and blocked its successor.

A failing-before integration test reproduced this. The session now preserves the distinction between an accepted prompt, explicit rejection, and uncertain transport failure. Explicit rejection closes the request with the actual reason and releases the next queued request. Rejected text is not added to later shared context. Disconnects and lost acknowledgements remain uncertain and are never automatically resent.

### Project rows did not open their threads

In the installed development build, clicking a project row left Home or the current agent selected. Keyboard navigation also skipped project rows. The project section now assigns the selected project explicitly and supplies its list tag. After updating the same development app and restarting, one click opened the existing verification thread. No thread recreation or membership changes were needed.

## Automated verification

Nine new integration tests exercise the actual `ProjectChatsModel`, `PiAgentSession`, and `PiClient` together with isolated transports and stores:

- An offline participant queues without blocking healthy participants.
- Lost acknowledgement after acceptance reconciles on reconnect without replay, then drains the successor.
- A restarted host with lost history does not cause an unknown attempt to be replayed.
- A denied confirmation and terminal failed tool close the failed turn and release the queue.
- Explicit prompt rejection closes correctly and does not leak rejected content into context.
- Four handoffs are allowed, a fifth is refused, and transcript resync does not repeat them.
- A hosted/non-Pi participant is rejected without any invocation. Hosted participation is not implemented by these tests.
- Reopening a disk-backed event store recovers queued work, records the completed reply once, and does not initiate historical handoffs.
- Sustained three-agent queues preserve FIFO order and exactly one invocation/reply per request across repeated disconnects.

Normal stress case: 120 requests across three isolated agents. Opt-in timed soak: 180 requests across three isolated agents, six disconnect/reconnect cycles, 303 seconds, no duplicates or unresolved requests. This is a bounded five-minute soak, not a long-duration live soak.

Run the timed case with:

```sh
TAVERN_RELIABILITY_SOAK=1 swift test --filter ProjectChatReliabilityTests/testSustainedThreeAgentQueuesSurviveRepeatedDisconnectsWithoutDuplicates -j 4
```

Full checks on the exact PR tree: 55 Node tests; 232 Swift test executions (217 core, 15 app), zero failures, four opt-in tests skipped. The broader development worktree also passed: 55 Node tests; 299 Swift executions, zero failures, four skipped. Counts differ because unrelated work is deliberately excluded from this PR.

## Live candidate verification

Development build `20261111.1` retains the existing development app path, bundle ID `dev.thrashr888.tavern.dev`, and signing identity. Release compilation and strict deep signature verification passed. Production was not replaced. A rollback copy of the previous development build was retained.

Executable SHA-256: `0924f82892457829bf9b91b00b9b03dd6809b817b9a3a3d9da85ebfa714a3765`.

- Project navigation was verified in the actual updated app.
- A bounded Tally reply was visibly in progress, and a second request was visibly queued, before the development app was quit and reopened.
- Both requests then completed. The stored Pi transcript and project ledger show exactly one actual invocation and one attributed reply per request. No unresolved requests remain from that restart check.

- With explicit approval, handoffs were enabled only for the existing verification thread. The live chain completed Tally → Ember → Flint → Tally → Ember: four handoffs after the human root, five total invocations and five attributed replies, each exactly once.
- Ember requested a fifth handoff to Flint. The app displayed **Handoff limit reached; request to flint was not sent.** No fifth-handoff request/invocation was created, and no unresolved work remained.
- Test-only handoffs were restored to off afterward. Participants and other threads were unchanged.

## Limits

Destructive network changes and restarting shared live agent hosts were not performed. Outage and host-loss behavior above uses isolated fault injection; the app restart check uses the real agent and UI. The earlier optional live participant-removal scenario remains outside this verification. No membership or security settings were changed for the isolated tests.
