# Live run against real github.com: repository-owner GitHub identity

Change under test: target 87336d7c, base 86437e28.

Driver: `live-owner-identity-driver.sh`. Redacted output: `live-owner-identity-transcript.txt`.

## Setup

- One marked lab home per scenario, made with `bin/fm-lab-home.sh create`. Each holds backlog rows that own the PR URLs, and the contributions check is armed with `bin/fm-contributions.sh arm`. Every scenario runs the generated `state/contributions.check.sh` once, the same way the watcher runs it. All lab homes are removed when the driver exits.
- The machine's real `gh` 2.103.0 and its existing stored github.com logins: the active personal login `m-moravcik` (in `hosts.yml`) and two inactive company logins (in the keyring). Nothing signs in, signs out, switches accounts or edits the store. The transcript shows the active login and the `hosts.yml` mtime before and after: both unchanged.
- Targets (names redacted in the transcript):
  - `company-a/private-repo-a/pull/6` is an open PR in a private repository that only the `company-a` login can read. The ambient login reads it as HTTP 404.
  - `company-b/shared-repo-b/pull/10` is an open PR that both the ambient login and `company-b` can read and push to.
- The only thing between PATH and the real `gh` is a passthrough shim. For every call it:
  - names the identity by matching a sha256 fingerprint of `GH_TOKEN`, or records "ambient" when `GH_TOKEN` is unset;
  - checks the argv of each ancestor process for the token;
  - records `GH_CONFIG_DIR`;
  - then `exec`s the real `gh` unchanged.

  The real `gh` makes every read against real github.com.

## Scenarios (sections of the transcript)

- **S0:** The real `gh auth token --user X` returns that account's stored token even when an ambient `GH_TOKEN` is set. A missing account fails with exit 1 and `no oauth token found for github.com account X`.
- **S1:** With no config, the private PR is reported unavailable with `gh: Not Found (HTTP 404)`. This is the bug being fixed.
- **S2:** A mapping with a mixed-case owner, a comment and a blank line makes the private PR observable. All 8 forge reads, including the closing `pr view`, run as `GH_TOKEN=company-a`. The record has no error, `state` open, the head observed and `can_merge: false`. No lab file contains any stored token.
- **S3:** With a mapped and an unmapped owner in one home, the unmapped owner's reads stay on the ambient identity and keep `can_merge: true` from the ambient push permission.
- **S4:** A repository read as its owner account, which has push permission, records `can_merge: false`.
- **S5:** A mapped account with no stored login reports the failed identity read and makes no forge read. A second poll is silent but tries the identity read again. The record is never retired.
- **S6:** An underscore account name (EMU form, `jdoe_acme`) is accepted as well formed and goes on to the identity read.
- **S7:** Seven malformed or unreadable configs each refuse both URLs, including the one the ambient login could read, with zero `gh` calls:
  - an underscore in the owner field;
  - one field;
  - three fields;
  - a leading hyphen;
  - an owner repeated with different case;
  - a CRLF line ending;
  - a directory in place of the file.
- **S8:** A decoy ambient `GH_TOKEN` in the watcher environment does not affect the mapped read: the private PR is still observed as `company-a`. The unmapped read uses the decoy and fails with HTTP 401, which shows the ambient identity is left untouched for unmapped owners.
