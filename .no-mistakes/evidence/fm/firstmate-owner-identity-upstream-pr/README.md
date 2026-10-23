# Live lab: repository-owner GitHub identity for the contributions observer

Change under test: `fix(bin): configure the GitHub identity used to observe contributions`
(target d0aa30b, base 0fc9651).

## Setup (disposable, torn down after the run)

- A marked lab home made with `bin/fm-lab-home.sh create`, holding two durable tasks
  enrolled with `bin/fm-contributions.sh enroll` and the contributions check armed
  with `bin/fm-contributions.sh arm`:
  - `acme-fix` -> `https://github.com/acme-corp/private-repo/pull/42` (a private company repository)
  - `personal-fix` -> `https://github.com/fmlab-personal/public-repo/pull/7` (a public personal repository)
- The machine's real `gh` 2.103.0 with an isolated `GH_CONFIG_DIR` holding two stored
  logins with throwaway random tokens: `fmlab-personal` (active, the ambient identity)
  and the Enterprise-Managed-User-style `jdoe_acme` (`lab-harness/ghconfig-hosts.yml.masked`).
- `lab-harness/gh-router` only re-addresses `github.com` API traffic: the real gh runs
  with `GH_HOST=github.localhost` behind an HTTP proxy that is the disposable fake
  GitHub (`lab-harness/fakegithub.py`); `gh auth token` runs unmodified against the
  isolated store.
- The fake GitHub decides identity only from the Authorization header the real gh
  sends: `acme-corp/private-repo` answers 404 to anyone but `jdoe_acme` (which can push),
  the public repository answers everyone (only `fmlab-personal` can push). While each
  request is in flight it snapshots every process command line on the machine and the
  observer's live temp directory and records whether any lab token appears in either.
- Each phase (`lab-harness/phase.sh`) drains and acknowledges queued wakes as the primary
  does, writes `config/github-owner-accounts`, runs the real `bin/fm-watch.sh` for one
  check sweep, then records the wake, gh argv, fake-GitHub requests, saved records,
  Bearings contribution counts, and whether the gh account store changed.

## Phases

| Phase | Config | Result |
| --- | --- | --- |
| A | absent | private PR wakes `gh: Not Found (HTTP 404)` read as `personal` (reported symptom, unchanged default) |
| B | `Acme-Corp jdoe_acme` (+ comment, blank line) | every private read sent as `jdoe_acme`, record observed, `can_merge:false` despite push, Bearings counts it `maintainer`; personal reads stay `personal`, `can_merge:true` |
| C1 | `acme-corp jdoe_missing` | wake names `identity read for jdoe_missing ... no oauth token found`; zero private-repo requests (no fallback) |
| C2 | same | no second wake, identity read retried, record not retired |
| D1 | line 2 has a third field | every observation, including the unmapped personal one, unavailable with `line 2 is malformed`; zero forge calls |
| D2 | `acme_corp jdoe_acme` | owner field stays narrow: `line 1 is malformed`, zero forge calls |
| D3 | a directory | `is unreadable`, zero forge calls |
| E1 | `Acme-Corp jdoe_acme` again | both observed, errors cleared, personal-first rotation order |
| E2 | same, ambient `GH_TOKEN` + inherited stray `OWNER_GH_TOKEN` | personal reads stay `personal`; real gh `auth token --user` still returns the stored `jdoe_acme` token |
| F | same, scripts from base 0fc9651 | config ignored, `gh: Not Found (HTTP 404)` again (fails before the fix) |
| G | same, fixed scripts re-armed | observed again, error cleared |

In every phase no lab token appeared in any process command line or the observer's temp
files during a request, `hosts.yml` kept its pre-run sha256 (the active account never
changed), and no lab file outside the gh store held a token.
