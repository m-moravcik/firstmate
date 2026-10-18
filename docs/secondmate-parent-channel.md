# Secondmate parent channel

This note records why a secondmate home's captain-facing outcomes are delivered by scripts instead of by the mate model, which script delivers each one, and which of them wake the parent.
`bin/fm-parent-channel-lib.sh` owns the channel contract: where the channel lives, how a line is appended, which lines go to the parent's digest instead of waking it, and the return codes every publisher shares.
[`remote-secondmates.md`](remote-secondmates.md) owns the transport that carries the remote form of the channel back to the parent.

## The problem

A secondmate is a firstmate in its own home, and nobody reads its chat: the captain and the main firstmate see only what is appended to the parent channel.
On 2026-09-02 four outcomes across two mate homes never reached the captain.
The watcher had delivered the parent's request within a minute each time, the mate did the work, and then the mate addressed "captain" in its own chat instead of appending to the channel.
The cause is structural rather than a one-off lapse: the mate can satisfy the [address rule in `AGENTS.md`](../AGENTS.md#firstmate) in local chat while missing the charter's later return-channel instruction.
The captain's framing of the requirement was: "the root problem is not specific to PRs, right? it looks like any message or outcomes from second mates can miss. we need to make sure our fixes are addressing this in a principled, fundamental way, not surgically treating the symptoms of just this PR update miss."
A PR-ready report was the observed symptom, but a finding, a decision, a blocker, and a failure all fail the same way, because every one of them depended on the mate model remembering to write one line.

The design goal is therefore: the parent channel must not depend on the model remembering to write to it.

## The design

The delivery rule has one sentence: the scripts report facts, the mate reports judgement.
Every captain-facing outcome that leaves durable evidence in the mate home is published on the channel by the script that records that evidence, at record time or on the next supervision poll, and the charter reserves the mate's own appends for judgement.

| Outcome | Durable evidence in the mate home | Published by | Reaches the parent as |
|---|---|---|---|
| Ship child PR ready | the child's `done:` PR ready line, whose accepted spellings the publisher below owns; `pr=` in the child's record once registered | `bin/fm-inactive-reconcile.sh` on the next poll with the child's line; `bin/fm-pr-check.sh` at registration with the canonical URL, or after the green report when [`config/ready-after-green`](configuration.md#pr-ready-line-after-green-configready-after-green) is set | digest |
| Scout child findings | the child's `done:` line plus `data/<child>/report.md` | `bin/fm-inactive-reconcile.sh` on the next poll, with the report pointer | digest |
| Child failed | the child's `failed:` line | `bin/fm-inactive-reconcile.sh` on the next poll | wake |
| Child decision escalated to the captain | the task held for the captain in the mate backlog | `bin/fm-captain-hold.sh hold`, and its answer by `answer` | wake for the hold; digest for the answer once the parent has closed that hold, otherwise wake |
| PR merged | the merge poll or the mate's own merge | `bin/fm-merge-outcome-lib.sh` | digest |
| Child leaving the home | its final ledger line | `bin/fm-teardown.sh`, which refuses to remove the child while that line is undelivered | digest for done, wake for failed |
| Child ended silently | terminal current state with a silent ledger | the existing inactive-outcome scan in `bin/fm-inactive-reconcile.sh` | digest for done, wake for failed |
| Answer to a marked request | a correlated line guarded by the pending-reply record | `bin/fm-secondmate-report.sh`, which resolves the parent channel from the mate home; the pending-reply guard repairs a line stranded in the local mate's same-basename status file before recovery or escalation | wake |
| An outcome that exists only in the mate's reasoning | none | the charter and the `AGENTS.md` carve-outs only | wake |

The ledger delivery reads files, plus a local git reachability check on a ship `done:` with no delivery record yet (`bin/fm-dod-lib.sh`): it calls no harness, no forge, and no current-state reader, so it is identical for every harness and runtime backend.
Each delivery is keyed with the first eight hexadecimal characters of its receipt fingerprint and uses the shared append contract above, and the ledger path reuses the inactive scan's per-fingerprint receipts, so a replayed poll or restart cannot deliver an event twice while a genuinely new terminal event is delivered again.
A duplicate line is harmless and a missed one is not, so the mate may still append its own judgement about a delivered outcome, and the parent reads the script's line as the fact and the mate's line as commentary.
For marked replies, the report helper accepts no caller-selected destination and uses the channel resolver for both local and remote homes; its script header owns the exact invocation contract.
The pending-reply guard may restate only the correlated line from a local mate's `state/<mate-id>.status` onto the parent channel, which repairs the common parent-home versus mate-home mixup without accepting arbitrary mate-home sightings as acknowledgement.
Other correlated mate-home status lines remain wrong-home evidence, while a remote home's routed `state/parent-replies.status` is already the parent channel and is not classified as wrong-home.
The mate home's own status scans treat that remote channel the same way: `status_scan_parent_channel_exclude` in `bin/fm-classify-lib.sh` resolves the outbound path through the same `bin/fm-parent-channel-lib.sh` binding, and the watcher's signal scan and heartbeat backstop, the away-mode daemon's catch-all scan, and the fleet-wide folds skip exactly that resolved path, never a file name.
The remote reply adapter already mirrors every channel line into the parent home, so folding the channel again here would only spin spurious wakes and a phantom `parent-replies` task, while a `parent-replies.status` in a main home or in a local mate is an ordinary task log that keeps folding and waking.
A missed-reply escalation includes the complete first sighting path and line number in readable shell-escaped form.

## Wake or digest

Delivery and waking are separate questions.
Every line on a secondmate's status stream in the parent home wakes the parent, and on 2026-10-18 two mates woke their parent 3 to 15 times an hour, mostly with child PR-ready, merged, child-done, and answered-hold lines that needed nothing from it.
The captain's rule is that only what needs immediate action or input wakes the parent: a captain question, a blocker, a failure, and the answer to work the parent handed over.
The last column of the table above applies that rule, and `bin/fm-parent-channel-lib.sh` owns its exact form.
A routine line is appended to `state/<mate-id>.digest` beside the stream instead, which no watcher scan, heartbeat backstop, decision fold, or away-mode catch-all reads, so it is delivered without a wake.
The parent reads the digest when its drain presents a heartbeat, and on demand through `bin/fm-secondmate-digest.sh`, whose header owns the read position.
An answered hold stays a wake while the parent's stream still holds that hold open, because only a line on the stream closes it in the parent's open-decision fold; once the parent's own answer has closed it, the mate's matching line is routine.
A local mate routes each line when it publishes it, and the parent's remote reply adapter routes each mirrored line of a remote mate by the same rule, so both routes give the parent the same stream and digest.
Because the routine facts no longer wake anyone, the charter tells the mate that a step needing the captain's word, such as a merge approval, still needs a captain hold or the mate's own line.

## What is deliberately not built

- No mirror of the mate's chat: chat can mix outcomes with other conversation, so choosing which sentence is an outcome would itself be model behavior, and every harness exposes turn text differently.
- No threshold escalation of a child's open decision or blocker: a decision the mate escalates is a captain hold, which is published; a decision the mate neither answers nor escalates is a supervision-quality question, separable from channel delivery.
- No second watcher or standalone scanner: a lightweight ledger pass runs inside the existing inactive-outcome command on every watcher poll and reuses its receipts and upstream append.
- No orphan lifecycle: teardown refuses instead of removing an undelivered outcome, the same way it refuses on other unlanded conditions.

## Regression coverage

`tests/fm-inactive-reconcile.test.sh` covers the ledger delivery against real ledgers with no harness: immediate done and failed delivery with note, PR, mode, posture, and report pointer, once-only delivery across polls, a ship `done:` withheld while its named head exists only in the worker copy, a pending one still delivered after teardown removes that copy, a line still being appended, later routine status prose not minting a fresh parent event because the inactive receipt identity binds structured fields only, the remote route, the yield of the inactive path to a terminal ledger, and the real watcher poll driving it.
`tests/fm-captain-hold-lifecycle.test.sh` covers a mate home publishing a hold, its answer, and a distinct occurrence on re-hold, and a main home publishing nothing.
`tests/fm-pr-merge.test.sh` covers the PR-ready line at registration and the merge outcome's upward report.
`tests/fm-teardown.test.sh` covers teardown delivering a child's final line and refusing when the channel cannot be written.
It also covers the registration-time ready line and its withholding until checks are green under `config/ready-after-green`.
`tests/fm-brief.test.sh` pins the charter's channel rule.
`tests/fm-pending-reply.test.sh` covers helper-selected local routing, remote-channel classification, same-basename restatement before false escalation, readable wrong-home diagnostics, and the rule that arbitrary mate-home sightings never acknowledge a reply.
`tests/fm-parent-channel-digest.test.sh` covers the wake-or-digest routing against real local and remote fixtures: every routine publisher line landing in the digest and every waking one on the stream, an answered hold that stays on the stream until the parent closes it, a decision opened and answered inside one remote delta, the real watcher scan staying quiet on digest growth, the reader's read position, and the real drain presenting the digest only with a heartbeat.
`tests/fm-parent-channel-scan-exclusion.test.sh` covers the home-shape-aware scan exclusion against real remote, main-home, and local-mate fixtures: the watcher signal scan, both heartbeat backstops, the fleet-wide folds, and the real `fm-wake-drain.sh` end to end.

## Live verification

[`verification/secondmate-parent-channel.md`](verification/secondmate-parent-channel.md) records the dated live run: both real watchers re-armed after each wake and no model, with every delivered parent line, whether it reached the stream or the digest, and the one parent wake the run produced.
