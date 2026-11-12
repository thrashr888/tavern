# Independent reliability review reconciliation, November 11, 2026

## Candidate and method

Quill and Peter independently reviewed PR #20's `919dd32` shared-chat implementation. This follow-up uses a separate clean worktree based on that exact commit; the original worktree's unrelated Gateway, Mail, PAP and discovery changes are untouched. Tests use isolated stores, fake transports and the real Pi session/app dispatcher. No live agent host was restarted and no release or production app was changed.

Peter's review used the older `multiagent-live-20261110.md` record. The newer `multiagent-reliability-20261111.md` already records a real active-app restart with a queued successor and a real Tally → Ember → Flint → Tally → Ember chain. Four handoffs ran once each; a fifth was blocked. These checks are not new claims made by this follow-up, and do not replace the outstanding destructive live host/network tests.

## Confirmed defects and changes

### Clock rollback could revive attempted work and old routing settings

Two failing-before regressions appended a newer state revision with an earlier timestamp. The old reducer selected the older queued state, allowing `claimNextQueued` to return the same request again. A second regression restored removed project membership. Completion state could also revert after reopening.

Project state now reduces SQLite insertion order, not wall-clock timestamp. Other event consumers retain chronological ordering. An incremental index observes newly appended records across independent database connections and preserves explicit prompt clearing. Queue order remains its existing monotonic sequence.

### Long history blocked interactive operations

An opt-in fixture seeds 2,000 prior requests, 6,000 state revisions, 2,000-character texts and 40,000-character prompts, about 252 MB of payload. On the same M5, baseline warm message/chat reads took about 0.91 seconds per pair; enqueue plus claim took 1.86 seconds. The incremental index measured about 0.00001 seconds per warm read pair and 0.0076 seconds for enqueue plus claim. Cold indexing measured 0.15 seconds versus 0.55 seconds before. These are local synthetic measurements, not production latency guarantees.

Repeated reads no longer decode every prior prompt revision. The append-only log still retains those historical copies; disk compaction or normalized prompt storage is not part of this change. Initial load still scales with history. The benchmark enforces warm-read and enqueue/claim ceilings of 100 ms and 200 ms respectively.

### Interrupted turns were mislabeled as sending/waiting indefinitely

An app-recovered outstanding attempt, a disconnected in-progress request, and an authoritative idle history read without an attributable terminal response now show an explicit uncertain state and an explanation. They remain blocked until a matching reply is recovered or a human reviews and closes tracking. No timeout or history gap is treated as proof the agent never executed the request.

Steering in a private chat preserves the strict user/system transcript boundary. Later private text is not copied into the shared project. If there is no safely attributable response, tracking becomes uncertain rather than remaining misleadingly waiting. Manual close releases the queued successor exactly once.

Fresh acknowledgements can precede busy publication. Durable idle history must come from a read begun after the submission and without a newer lifecycle event; an overlapping busy read cannot prove the turn ended. In-flight sends are excluded from reconciliation.

A further independent review caught the reverse ordering: a positive “started” acknowledgement arriving after the terminal reply. The held-ACK regression failed five assertions before the fix: presence reverted to working, the shared reply was not recorded, and the successor did not dispatch. Both send paths now preserve newer settled state or verified idle history. Tests cover settled-before-ACK and explicit idle-sync-before-ACK without a lifecycle event.

### Smaller review findings

- A missing Pi client returns `notSent`, leaves the request queued, and does not create an uncertain delivery or busy retry loop.
- Replies recovered across app restart still never route historical handoffs. A persistent per-request notice now explains which handoffs were not sent.
- Routing cancellation after participant/endpoint/handoff settings changes records a visible reason.
- Handoff IDs are matched case-insensitively; duplicate case variants route once, and ambiguous configured IDs are rejected.
- Recovered replies clear their stale per-request uncertainty reason. Transient UI error cleanup is checked separately so unrelated errors and handoff-limit notices are not erased.

## Semantics retained

- **Replied is a response status, not a claim that work succeeded.** A denied tool followed by a normal final answer is a reply. A terminal failed tool without a final answer closes as failure. Refusal text remains visible.
- **The budget is four automatic routing attempts per human root.** Cancelled, failed or uncertain handoffs continue to count. Refunding attempts would let failed chains evade the bound. This behavior is preserved, not silently changed to four successful completions.
- **Pending approvals intentionally block that agent's queue.** The inline dialog is surfaced; the app does not auto-approve, auto-decline or bypass it. Other agents can continue.
- **Hosted participants remain unsupported.** Existing tests reject them without invocation. The separate Gateway owner-session code is not a shared-chat participant route.
- **Uncertain delivery is never automatically retried.** A recovered reply can release the queue; missing history alone cannot.

## Verification

The final combined source tree passed `scripts/check.sh` with `TAVERN_HISTORY_BENCHMARK=1`:

- 55 Node tests, all passing.
- Swift build passed.
- 247 Swift test executions: 223 core and 24 app; zero failures, four existing opt-in tests skipped.
- All 18 real-dispatcher reliability tests passed, including the new transport/history ordering cases.
- The large-history three-agent stress case completed 120 new invocations, preserving FIFO and exactly-once accounting, with 2,000 old requests and repeated disconnects.
- Final large-history measurement: 0.137 s cold index, 0.000010 s warm read pair, 0.0065 s enqueue plus claim. Stress-case elapsed time was 3.37 s; this is accelerated isolated traffic, not a duration soak.
- `git diff --check` passed. A separate read-only review of the final patch found no remaining blocking issue; that review did not run tests or live agents.

The first sandboxed aggregate run could not launch the macOS WebKit test fixture and inherited signing for disposable Git fixtures. The final aggregate ran with the required local test permissions and per-process Git fixture signing disabled, without changing global Git configuration. No test was omitted to obtain the pass.

### Remaining limits

- No destructive live network outage, shared live host restart, or long-duration live soak was performed in this follow-up.
- The fixed code was not installed into the development or production app in this follow-up. The earlier live chain and active-app restart results apply to the prior candidate described above.
- Unknown delivery still requires human review; a host that lost history cannot prove non-execution.
- Append-only prompt copies and unbounded historical disk growth remain. The incremental index removes repeated decode cost, not retention cost.
- Pending approvals remain human-gated, and hosted chat remains unimplemented.
- PR remains draft. No merge or release.
