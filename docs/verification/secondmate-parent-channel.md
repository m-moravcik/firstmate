# Secondmate parent channel: live verification

Maintainer-verification record for the guarantee in [`secondmate-parent-channel.md`](../secondmate-parent-channel.md): a captain-facing outcome recorded inside a secondmate home reaches the parent without the mate model writing it, and only the outcomes that need the parent wake it while routine ones land in its digest.
Refresh it by rerunning the fixture below after changing any publisher named in `bin/fm-parent-channel-lib.sh` or its wake-or-digest routing.
[`bin/fm-classify-lib.sh`](../../bin/fm-classify-lib.sh) owns the `[at=<epoch>]` emission-time tag shown below; nothing this record proves depends on its value.

## What was run

Date: 2026-10-18.
Tree: this change's branch on macOS 27.0.1, with bash 3.2.57 as `/bin/bash` and the repo's own scripts.
Fixture: two isolated homes under a scratch directory, `$P` (parent) and `$M` (mate).
The mate home carries `.fm-secondmate-home` (`mate`) and a local `.fm-secondmate-parent` binding to `$P`; the parent home carries `state/mate.meta` (`kind=secondmate`, `home=$M`).
The mate's child task `child` is recorded in `$M/state/child.meta` with `kind=ship`, `mode=no-mistakes`, and `yolo=off`, and its copy's head is reachable from a remote-tracking ref.
Both homes run the real `bin/fm-watch.sh` (`FM_POLL=2`), re-armed after every wake through `bin/fm-wake-drain.sh` acknowledgement, exactly as fleet supervision re-arms a watcher after a handled turn, and each starts with its existing status already read.
No agent harness, no model, and no session backend pane runs anywhere in the fixture: tmux is not installed on this host and the run drives no Herdr session, so neither task records an endpoint, and the child's terminal line is the same shell append its pane would have typed.
A stub `gh` that exits 1 sits first on `PATH`, so no forge is reached.

The mate's only actions are the scripts a firstmate runs when it registers a PR and when it holds a task for the captain and records the answer.
The parent's only action is closing the hold the way `bin/fm-send.sh --resolve-key` does at answer time, through `fm_wake_status_append_self_announced` in `bin/fm-wake-lib.sh`.

## Transcript

`bin/fm-pr-check.sh` also printed `bin/fm-guard.sh`'s worktree-tangle banner, because the fixture ran the scripts from this feature branch's copy, and a queued-wake warning for the mate's own not-yet-acknowledged signal; both are omitted below.

```text
$ # Setup: mate home $M is a secondmate of parent home $P (local route); both real watchers are live and re-armed after every wake

$ # Step 1: the child appends its terminal line

$ echo 'done: PR https://github.com/example/repo/pull/9999 checks green' >> $M/state/child.status

$ cat $P/state/mate.status   (the parent stream)
working: delegated scope

$ cat $P/state/mate.digest   (the parent digest)
done [key=child-outcome-child-done-34edbd0e] [at=<epoch>]: child child done: PR https://github.com/example/repo/pull/9999 checks green pr=https://github.com/example/repo/pull/9999 mode=no-mistakes yolo=off

$ parent watcher wakes so far

$ # Step 2: the mate registers the PR with fm-pr-check

$ FM_HOME=$M FM_STATE_OVERRIDE=$M/state bin/fm-pr-check.sh child https://github.com/example/repo/pull/9999
armed: state/child.check.sh

$ cat $P/state/mate.digest
done [key=child-outcome-child-done-34edbd0e] [at=<epoch>]: child child done: PR https://github.com/example/repo/pull/9999 checks green pr=https://github.com/example/repo/pull/9999 mode=no-mistakes yolo=off
done [key=child-pr-child] [at=<epoch>]: child child PR ready: https://github.com/example/repo/pull/9999 mode=no-mistakes yolo=off

$ parent watcher wakes so far

$ # Step 3: the mate holds a task for the captain

$ FM_HOME=$M bin/fm-captain-hold.sh hold child-call --title 'Pick the rollout window' --reason 'rollout window choice pending' --repo alpha
child-call

$ cat $P/state/mate.status
working: delegated scope
needs-decision [key=captain-hold-child-call-1] [at=<epoch>]: captain hold child-call: rollout window choice pending

$ parent watcher wakes so far
signal: P/state/mate.status

$ # Step 4: the parent closes that decision as fm-send --resolve-key does, then the mate records the captain's answer

$ fm_wake_status_append_self_announced $P/state $P/state/mate.status 'resolved [key=captain-hold-child-call-1]: roll out on Monday'

$ FM_HOME=$M bin/fm-captain-hold.sh answer child-call --decision-file decision.txt   (decision: roll out on Monday)
answered: child-call

$ cat $P/state/mate.status   (final parent stream)
working: delegated scope
needs-decision [key=captain-hold-child-call-1] [at=<epoch>]: captain hold child-call: rollout window choice pending
resolved [key=captain-hold-child-call-1] [at=<epoch>]: roll out on Monday

$ cat $P/state/mate.digest   (final parent digest)
done [key=child-outcome-child-done-34edbd0e] [at=<epoch>]: child child done: PR https://github.com/example/repo/pull/9999 checks green pr=https://github.com/example/repo/pull/9999 mode=no-mistakes yolo=off
done [key=child-pr-child] [at=<epoch>]: child child PR ready: https://github.com/example/repo/pull/9999 mode=no-mistakes yolo=off
resolved [key=captain-hold-child-call-1] [at=<epoch>]: captain hold child-call: answered

$ parent watcher wakes so far
signal: P/state/mate.status

$ mate watcher wakes so far
signal: M/state/child.status

$ # Step 5: the parent reads its digest on demand

$ FM_HOME=$P bin/fm-secondmate-digest.sh
SECONDMATE DIGEST (routine child events your secondmates reported without waking you, oldest first within each secondmate; relay only what the captain needs):
mate done [key=child-outcome-child-done-34edbd0e] [at=<epoch>]: child child done: PR https://github.com/example/repo/pull/9999 checks green pr=https://github.com/example/repo/pull/9999 mode=no-mistakes yolo=off
mate done [key=child-pr-child] [at=<epoch>]: child child PR ready: https://github.com/example/repo/pull/9999 mode=no-mistakes yolo=off
mate resolved [key=captain-hold-child-call-1] [at=<epoch>]: captain hold child-call: answered
```

## Why this proves the guarantee

- No model runs in the fixture, yet four captain-facing facts reached the parent: the child's terminal done line with its note, canonical PR, mode, and posture; the PR-ready line at registration; the captain hold; and the hold's answer.
- Each line was written by the script that recorded the underlying fact: `bin/fm-inactive-reconcile.sh` on the mate watcher's poll, `bin/fm-pr-check.sh`, and `bin/fm-captain-hold.sh`.
- The real parent watcher woke exactly once, for the captain hold, which is the only one of the four that needed it; the three routine lines landed in `$P/state/mate.digest`, which no parent watcher scan reads.
- The mate's answer reached the digest rather than the stream because the parent had already closed that hold itself, and the parent's own close did not wake it either.
- The parent read all three routine lines in one batch with `bin/fm-secondmate-digest.sh`, the same reader its drain runs when it presents a heartbeat.
- The mate watcher's own `signal:` on `child.status` shows the mate was woken as before; whatever the mate model would have said in its chat afterward is irrelevant to delivery.
