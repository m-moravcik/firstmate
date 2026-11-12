# Claude Keychain live validation

The requested six-scenario proof is incomplete: two refusal scenarios passed against the real product; four successful-token scenarios remain untested.

The independent oracle is the user intent and docs/configuration.md's worker account and Claude token-source contracts. A source without its matching pin, an invalid source declaration, and an unreadable token must refuse before a worker starts. Pool entries must retain their own identity and source, and successful token handling must not expose token values.

## Observed product behavior

- Real fm-spawn.sh in a marked, disposable lab home rejected an unbound source and an unknown declaration field. Both exited 1 and created no task metadata.
- Real fm-spawn.sh rejected an unavailable token even with synthetic ambient API-key and OAuth-token variables set. It reported that it never falls back to the stored login and created no task metadata.
- Both operator-provisioned synthetic items returned exit 152 and no bytes through real /usr/bin/security, both through the ordinary search list and when the exact provided test keychain path was passed explicitly. No stderr diagnostic was emitted. The provided keychain file exists. This establishes inability to read here, not its cause.
- Real fm-claude-account-quota.sh with real quota-axi 0.1.69 printed the two bare account paths and disclosed unknown quota because the isolated roots have no profile credentials. No production credentials were used.
- Explicit --account for the second entry reached its own source declaration but could not load its token; no worker started.
- Real fm-claude-token.sh under inherited SHELLOPTS=xtrace disabled tracing before the attempted read and exited 3 for the unavailable source. This does not establish containment of a successfully read token or the successful-first-read/failing-second-read transition.

## Six scenarios

| Scenario | Result |
| --- | --- |
| Malformed or unbound token sources refuse before launch | Live pass |
| Unreadable Keychain source refuses despite ambient credentials | Live pass |
| Dispatch selects a pool entry from quota and delivers its own token | Untested: no measured profile quota and no readable synthetic token |
| Explicit --account for the second entry delivers the second token | Untested: real spawn refused at the first Keychain read |
| Relaunch preserves the recorded pool entry and token source | Untested: no initial token-authenticated worker could be started |
| Successful tokens remain absent from argv, records, logs and xtrace; failed second read prevents Claude startup | Untested: first read never succeeded |

To complete the four scenarios, the operator must restore read access to only the two prepared synthetic items for this execution context. A successful first read is required before second-read failure can be exercised. No keychain, item, credential, or search-list mutation was authorized in this phase, so none was attempted. tmux was absent on PATH; Herdr was available, but no runtime session was provisioned because authentication already refused before endpoint creation. No CLI, login, token source, quota reading, or runtime was fabricated for the live evidence.

The interface is CLI-only for this change, and no worker UI could start, so no screenshot was produced. Raw product commands and outputs are retained in live-product.json; live-driver.py records the isolated execution. Existing regression logs use test doubles and are supporting regression evidence only, never a live success claim.

A further read-only attempt in a real PTY also returned 152 for both items. The required host access remains unavailable independently of stdin being a pipe.

The disposable lab home and temporary worktree files were moved out of the worktree into disposable-lab-retired in the evidence directory. No runtime server, viewer, worker, or monitor was started by the live driver. The prepared keychain and its search list were left untouched for the operator to clean up.

## Completed targeted regressions

- `bash tests/fm-worker-account.test.sh`: exit 0 with the standard temporary directory. This includes separate pool tokens, inherited xtrace containment and second-read failure refusal using test doubles.
- `TMPDIR="$PWD/.live-validation/tmp" bash tests/fm-claude-account-quota.test.sh`: exit 0.
- `bash tests/fm-control-relaunch.test.sh`: exit 0 with the standard temporary directory, including recorded pool-entry credential-source reuse.

The initial worker-account and control-relaunch invocations set TMPDIR inside the worktree. Their secondmate fixtures were then correctly refused because secondmate homes cannot be inside the firstmate repository. Both entire scripts were rerun with the standard toolchain temporary directory and completed successfully. Those initial failures were setup errors, and no product code was changed to bypass the guard.

All started command sessions completed and their actual exit statuses were read. The worktree has no source or test changes. The final live verdict remains inconclusive: the regressions passed, but successful real Keychain-to-Claude delivery was not demonstrated.
