# fm-send interruption - live lab transcripts

Real `bin/fm-send.sh` (target 5b80f564) against a marked disposable lab home (`bin/fm-lab-home.sh create`), a guarded Herdr lab session (fm-lab-intr-21185-28119, via `bin/fm-herdr-lab.sh`), and a lab remote-secondmate home reached through `FM_SSH_BIN` = a local ssh shim that runs the real host-local remote leg. Each send runs in its own process group (as a harness tool call does) and the caller's signal goes to the whole group. The watcher-down banner lines are removed from the stderr below.

## L1-local-after-enqueue-wedged-doorbell

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh tl2 L2:\ rebase\ onto\ main,\ then\ rerun\ the\ suite
--- timeline
00:26:41 inbox at interrupt time: [/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl2.inbox/001.msg ]
00:26:41 caller sends SIGINT to process group -6708
00:26:42 fm-send exited rc=130
--- fm-send stderr
fm-send: interrupted by SIGINT after the steer was durably recorded at /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl2.inbox/001.msg; it was delivered, so do not resend it.
```

## L2-local-before-delivery-lock-contention

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh tl2b L2:\ rebase\ onto\ main,\ then\ rerun\ the\ suite
--- timeline
00:27:02 a concurrent holder owns the task metadata lock
00:27:08 fm-send still waiting on the lock; inbox: []
00:27:08 caller sends SIGHUP to process group -41664
00:27:09 fm-send exited rc=129
--- fm-send stderr
Hangup: 1
fm-send: interrupted by SIGHUP before delivery; nothing was sent to tl2b.
fm-send: nothing was sent, so rerunning the same command is safe:
FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh tl2b L2:\ rebase\ onto\ main\,\ then\ rerun\ the\ suite
--- printed rerun run from / with FM_HOME unset (rerun rc=0)
fm-send: doorbell did not reach fm-lab-intr-21185-28119:w1:p1; the steer is durably recorded at /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl2b.inbox/001.msg and the watcher will re-ring
```

## L3-local-resolve-key-interrupt-after-enqueue-slow-fold

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh tl3 --resolve-key api-shape --resolve-key db-engine go\ with\ REST\ on\ postgres
--- timeline
00:31:12 (+2s) progress shows both closes appended; fm-send still in its post-close re-fold
00:31:12 inbox=[001.msg ]
00:31:12 caller sends SIGTERM to process group -5640
00:31:12 fm-send exited rc=143
--- fm-send stderr
fm-send: delivery to tl3 starts now; no delivery step ran before this line
fm-send: durably recorded at /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl3.inbox/001.msg
fm-send: --resolve-key api-shape: recorded (resolved line appended to /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl3.status)
fm-send: --resolve-key db-engine: recorded (resolved line appended to /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl3.status)
fm-send: interrupted by SIGTERM after the steer was durably recorded at /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl3.inbox/001.msg; it was delivered, so do not resend it.
fm-send: --resolve-key api-shape: recorded (resolved line present in /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl3.status)
fm-send: --resolve-key db-engine: recorded (resolved line present in /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl3.status)
```

## L4-local-resolve-key-interrupt-before-delivery-slow-fold

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh tl4 --resolve-key api-shape go\ with\ REST
--- timeline
00:31:29 (+3s) fm-send still folding the decision ledger before delivery; no "starts now" line; inbox=[]
00:31:29 caller sends SIGHUP to process group -26895
00:31:29 fm-send exited rc=129
00:31:29 after: inbox=[]; resolved lines for api-shape=0
00:35:31 printed rerun rc=0 after 233s; inbox=[001.msg ]; latest api-shape line: resolved [key=api-shape]: answered: go with REST
--- fm-send stderr
fm-send: interrupted by SIGHUP before delivery; nothing was sent to tl4.
fm-send: --resolve-key api-shape: NOT recorded (no resolved line for it in /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl4.status)
fm-send: nothing was sent, so rerunning the same command is safe:
FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh tl4 --resolve-key api-shape go\ with\ REST
--- printed rerun run from / with FM_HOME unset (rc=)
fm-send: delivery to tl4 starts now; no delivery step ran before this line
fm-send: durably recorded at /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl4.inbox/001.msg
fm-send: --resolve-key api-shape: recorded (resolved line appended to /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl4.status)
fm-send: doorbell did not reach fm-lab-intr-21185-28119:w1:p1; the steer is durably recorded at /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl4.inbox/001.msg and the watcher will re-ring
```

## L5-local-resolve-key-sigkill-after-close

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh tl5 --resolve-key api-shape --resolve-key db-engine go\ with\ REST\ on\ postgres
--- timeline
00:37:44 (+360s) both closes announced; fm-send is in its post-close re-fold
00:37:44 caller sends SIGKILL to process group -48523
00:37:44 fm-send exited rc=137
api-shape -> resolved [key=api-shape]: answered: go with REST on postgres
db-engine -> resolved [key=db-engine]: answered: go with REST on postgres
inbox=[001.msg ]
--- fm-send stderr
fm-send: delivery to tl5 starts now; no delivery step ran before this line
fm-send: durably recorded at /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl5.inbox/001.msg
fm-send: --resolve-key api-shape: recorded (resolved line appended to /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl5.status)
fm-send: --resolve-key db-engine: recorded (resolved line appended to /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/tl5.status)
```

## R0-BEFORE-base-commit-remote-interrupt-in-flight

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/base/bin/fm-send.sh rsm R0:\ base-commit\ comparison\ steer
--- timeline
00:46:20 [base 9224c902] remote transport in flight
00:46:20 caller sends SIGTERM to process group -88885
00:46:20 fm-send exited rc=143
00:46:48 transport finished anyway: 1 remote leg fm-remote-secondmate-control.sh finished t=1793663208 rc=0; records with this body=1
--- fm-send stderr
/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/base/bin/fm-wake-lib.sh: line 1727: 91204 Done                    printf '%s' "$MESSAGE"
     91205 Terminated: 15          | fm_run_timed "$FM_SEND_REMOTE_BUDGET" "$SCRIPT_DIR/fm-on.sh" --stdin "$TARGET_REMOTE_ID" fm-remote-secondmate-control.sh send-stdin "${REMOTE_SEND_ARGS[@]}"
```

## R1-remote-interrupt-in-flight-lands-later

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh rsm R1:\ rotate\ the\ staging\ keys\ tonight
--- timeline
00:27:43 remote transport in flight (ssh shim pid 87536); remote inbox: []
00:27:43 caller sends SIGTERM to process group -82165
00:27:44 fm-send exited rc=143
00:27:44 pending-reply 29042176080f8ef7 phase=delivery_unknown delivered_epoch=
00:28:13 after fm-send died, the in-flight transport kept running: 1 remote leg fm-remote-secondmate-control.sh finished t=1793662093 rc=0
00:28:13 remote inbox now: [/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/rsm-home/state/parent-route/rsm.inbox/001.msg ]
00:28:13 parent pending-reply phase=delivery_unknown delivered_epoch= (fm-send never saw the result)
--- fm-send stderr
Terminated: 15
fm-send: interrupted by SIGTERM while the remote transport to secondmate rsm was in flight; remote completion is unknown, so the steer may already be recorded there.
fm-send: only this correlation-reusing resend is safe; it lands on the same remote inbox record if the first one arrived, and closes each --resolve-key decision once delivery confirms:
FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent FM_PENDING_REPLY_EXISTING_CORR=29042176080f8ef7 {run-worktree}/bin/fm-send.sh rsm R1:\ rotate\ the\ staging\ keys\ tonight
```

## R2-remote-resolve-key-interrupt-in-flight

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh rsm --resolve-key upgrade-window --resolve-key freeze-day the\ weekend,\ freeze\ Friday
--- timeline
00:29:15 remote transport in flight
00:29:15 caller sends SIGINT to process group -23359
00:29:15 fm-send exited rc=130
00:29:15 rsm.status resolved lines: []
00:29:51 in-flight transport finished after fm-send died: 1 remote leg fm-remote-secondmate-control.sh finished t=1793662190 rc=0; remote inbox=[001.msg 002.msg ]
00:30:11 printed resend rc=0; remote inbox=[001.msg 002.msg ]; records carrying this body=1
00:30:11 rsm.status keyed lines now:
needs-decision [key=upgrade-window]: tonight or the weekend
needs-decision [key=freeze-day]: friday or monday
resolved [key=upgrade-window]: answered: the weekend, freeze Friday
resolved [key=freeze-day]: answered: the weekend, freeze Friday
--- fm-send stderr
fm-send: delivery to rsm starts now; no delivery step ran before this line
fm-send: interrupted by SIGINT while the remote transport to secondmate rsm was in flight; remote completion is unknown, so the steer may already be recorded there.
fm-send: --resolve-key upgrade-window: NOT recorded (no resolved line for it in /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/rsm.status)
fm-send: --resolve-key freeze-day: NOT recorded (no resolved line for it in /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/rsm.status)
fm-send: only this correlation-reusing resend is safe; it lands on the same remote inbox record if the first one arrived, and closes each --resolve-key decision once delivery confirms:
FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent FM_PENDING_REPLY_EXISTING_CORR=75ad6b64aabb0054 {run-worktree}/bin/fm-send.sh rsm --resolve-key upgrade-window --resolve-key freeze-day the\ weekend\,\ freeze\ Friday
--- printed resend run from / with FM_HOME unset (rc=0)
fm-send: delivery to rsm starts now; no delivery step ran before this line
fm-send: durably recorded in remote secondmate rsm's steering inbox
fm-send: --resolve-key upgrade-window: recorded (resolved line appended to /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/rsm.status)
fm-send: --resolve-key freeze-day: recorded (resolved line appended to /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/rsm.status)
```

## R3-remote-own-budget-timeout

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh rsm --resolve-key rollback-plan keep\ the\ old\ schema\ for\ a\ week
--- timeline
00:30:25 fm-send returned on its own rc=1
00:30:34 pending-reply phase=delivery_unknown delivered_epoch=; transport killed at the budget (ssh shim never ran the remote leg)
00:30:52 printed resend rc=0; records carrying this body=1; pending phase=awaiting_report delivered_epoch=1793662251
needs-decision [key=rollback-plan]: keep or drop the old schema
resolved [key=rollback-plan]: answered: keep the old schema for a week
--- fm-send stderr
fm-send: delivery to rsm starts now; no delivery step ran before this line
fm-send: --resolve-key rollback-plan: NOT recorded (no resolved line for it in /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/rsm.status)
error: steer to remote secondmate rsm is unconfirmed (the remote transport did not complete within its 4s budget; remote completion unknown). Only the correlation-reusing resend below is idempotent and lands on the same remote inbox record:
FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent FM_PENDING_REPLY_EXISTING_CORR=6577524b9f0bebc5 {run-worktree}/bin/fm-send.sh rsm --resolve-key rollback-plan keep\ the\ old\ schema\ for\ a\ week
--- printed resend run from / with FM_HOME unset (rc=0)
fm-send: delivery to rsm starts now; no delivery step ran before this line
fm-send: durably recorded in remote secondmate rsm's steering inbox
fm-send: --resolve-key rollback-plan: recorded (resolved line appended to /private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent/state/rsm.status)
```

## R4-reused-corr-resend-interrupted-before-transport

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh rsm R1:\ rotate\ the\ staging\ keys\ tonight
--- timeline
00:28:29 another sender holds rsm metadata lock (as a concurrent in-flight send would)
00:28:37 resend waiting on the lock; pending phase=awaiting_report; ssh calls so far=0
00:28:37 caller sends SIGTERM to process group -55672
00:28:38 fm-send exited rc=143
00:28:38 after interrupt: pending phase=delivery_unknown delivered_epoch=; ssh calls by this resend=0; remote inbox=[/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/rsm-home/state/parent-route/rsm.inbox/001.msg ]
00:29:05 after printed retry: remote inbox=[/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/rsm-home/state/parent-route/rsm.inbox/001.msg ]; pending phase=awaiting_report delivered_epoch=1793662145
--- fm-send stderr
fm-send: interrupted by SIGTERM before this attempt's delivery, so this attempt sent nothing; correlation 29042176080f8ef7's earlier remote attempt to secondmate rsm is still unknown, so the steer may already be recorded there.
fm-send: retry only with this correlation-reusing resend; it lands on the same remote inbox record if the earlier one arrived, and closes each --resolve-key decision once delivery confirms:
FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent FM_PENDING_REPLY_EXISTING_CORR=29042176080f8ef7 {run-worktree}/bin/fm-send.sh rsm R1:\ rotate\ the\ staging\ keys\ tonight
--- printed retry run from / with FM_HOME unset (rc=retry rc=0)
```

## T1-typed-slash-interrupt-mid-submit

```
$ FM_HOME=/private/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/parent {run-worktree}/bin/fm-send.sh tl7 /compact
--- timeline
00:46:08 fm-send is inside the herdr send-text keystroke call (typed plane)
00:46:08 caller sends SIGTERM to process group -79857
00:46:09 fm-send exited rc=143
--- fm-send stderr
fm-send: interrupted by SIGTERM while submitting to fm-lab-intr-21185-28119:w1:p2; delivery is unknown, so verify with fm-peek.sh before any resend.
```
