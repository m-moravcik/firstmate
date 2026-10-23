#!/usr/bin/env bash
# Live driver for the repository-owner GitHub identity change.
# Runs the real bin/fm-contributions.sh (arm + generated watcher check) with the
# machine's real gh and its existing stored logins against real github.com, each
# scenario in its own disposable marked fm-lab home. Every lab is removed on exit.
#
# Inputs (env, so private repository names never land in this file):
#   WT            the gate worktree holding the change
#   URL_PRIVATE   an open PR in a private repo only ACCT_PRIVATE can read (ambient login reads 404)
#   URL_SHARED    an open PR the ambient login can read and push to
#   ACCT_PRIVATE  stored gh login that owns URL_PRIVATE's repo
#   ACCT_SHARED   stored gh login that owns URL_SHARED's repo (and can push to it)
#   AMBIENT       the active gh login
#
# The only thing between PATH and the real gh is a passthrough shim that labels
# each call's identity by a 16-hex sha256 fingerprint of GH_TOKEN, checks every
# ancestor process's argv for the token, records GH_CONFIG_DIR, then execs the
# real gh unchanged. Tokens are never printed or written.
set -u
: "${WT:?}" "${URL_PRIVATE:?}" "${URL_SHARED:?}" "${ACCT_PRIVATE:?}" "${ACCT_SHARED:?}" "${AMBIENT:?}"
REAL_GH=$(command -v gh)
PARENT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$PARENT"' EXIT
PROBE="$PARENT/probe"
mkdir -p "$PROBE" "$PARENT/shim"
DECOY=decoy-ambient-token
fp() { shasum -a 256 | cut -c1-16; }
{
  for a in "$AMBIENT" "$ACCT_PRIVATE" "$ACCT_SHARED"; do
    printf '%s %s\n' "$a" "$(printf %s "$("$REAL_GH" auth token --hostname github.com --user "$a")" | fp)"
  done
  printf '%s(active) %s\n' "$AMBIENT" "$(printf %s "$("$REAL_GH" auth token --hostname github.com)" | fp)"
  printf 'decoy %s\n' "$(printf %s "$DECOY" | fp)"
} > "$PROBE/hashes"

cat > "$PARENT/shim/gh" <<'SH'
#!/usr/bin/env bash
id='ambient(no GH_TOKEN: active stored login)'
leak=no
if [ -n "${GH_TOKEN-}" ]; then
  h=$(printf %s "$GH_TOKEN" | shasum -a 256 | cut -c1-16)
  id=$(awk -v h="$h" '$2 == h { print "GH_TOKEN=" $1; f = 1; exit } END { if (!f) print "GH_TOKEN=unknown" }' "$PROBE/hashes")
  p=$PPID n=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 16 ]; do
    ps -o args= -p "$p" 2>/dev/null | grep -qF -f <(printf '%s\n' "$GH_TOKEN") && leak=yes
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') n=$((n + 1))
  done
fi
printf '%s argv-leak=%s GH_CONFIG_DIR=%s | gh %s\n' "$id" "$leak" "${GH_CONFIG_DIR-unset}" "$*" >> "$PROBE/calls"
exec "$REAL_GH" "$@"
SH
chmod +x "$PARENT/shim/gh"

fmx() { # home cmd...: the runbook's lab environment, PATH led by the shim
  local home=$1
  shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$home/tmux" FM_HOME="$home" PATH="$PARENT/shim:$PATH" PROBE="$PROBE" REAL_GH="$REAL_GH" \
    FM_CONTRIBUTIONS_BUDGET=25 "$@"
}
lab() { # name url...: a fresh marked lab home owning each URL through a backlog row, check armed
  local home="$PARENT/$1" i=0 url
  shift
  "$WT/bin/fm-lab-home.sh" create "$home" >/dev/null || { echo "lab create failed"; exit 1; }
  mkdir -p "$home/tmux"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  for url in "$@"; do
    i=$((i + 1))
    mkdir -p "$home/data/t$i"
    printf -- '- [ ] t%s - Contribution %s (repo: sample) (kind: ship)\n' "$i" "$url" >> "$home/data/backlog.md"
  done
  fmx "$home" "$WT/bin/fm-contributions.sh" arm >/dev/null || { echo "arm failed"; exit 1; }
  printf '%s\n' "$home"
}
poll() { # home: one watcher-check run, its stdout verbatim
  local home=$1 rc=0
  : > "$PROBE/calls"
  echo "\$ bash state/contributions.check.sh"
  fmx "$home" bash "$home/state/contributions.check.sh" > "$PROBE/out" || rc=$?
  sed 's/^/  out: /' "$PROBE/out"
  echo "  [check exit=$rc]"
}
calls() { sed 's/^/  gh call: /' "$PROBE/calls"; [ -s "$PROBE/calls" ] || echo "  gh call: (none)"; }
records() {
  local f
  for f in "$1"/data/t*/contributions.json; do
    [ -f "$f" ] || continue
    jq -c '.task as $t | .records[] | {task:$t,url,error,checked:(.checked_at != null),retired:(.retired // null),
      state:.observation.state,head_observed:((.observation.head // "") | test("^[0-9a-f]{40}$")),can_merge:.observation.can_merge}' "$f" \
      | sed 's/^/  record: /'
  done
}
config() { # home content: write config/github-owner-accounts and show it
  printf '%s' "$2" > "$1/config/github-owner-accounts"
  echo "  config/github-owner-accounts:"
  sed -n 'l' "$1/config/github-owner-accounts" | sed 's/^/    | /'
}
identity_state() {
  echo "  active gh login: $("$REAL_GH" api user --jq .login 2>&1)"
  echo "  gh hosts.yml mtime: $(stat -f %m "$HOME/.config/gh/hosts.yml")"
}

echo "=== S0 real gh token selection (fingerprints only) ==="
for a in "$ACCT_PRIVATE" "$ACCT_SHARED"; do
  echo "  gh auth token --user $a: stored=$("$REAL_GH" auth token --hostname github.com --user "$a" | fp)" \
    "with ambient GH_TOKEN=decoy set=$(GH_TOKEN=$DECOY "$REAL_GH" auth token --hostname github.com --user "$a" | fp)"
done
echo "  gh auth token --user no-such-account-zz9: $("$REAL_GH" auth token --hostname github.com --user no-such-account-zz9 2>&1); exit=$?"
echo "  ambient read of the private repo: $("$REAL_GH" api "repos/$(printf %s "$URL_PRIVATE" | cut -d/ -f4-5)" --jq .full_name 2>&1 | tail -1)"
echo "  $ACCT_SHARED push on the shared repo: $(GH_TOKEN=$("$REAL_GH" auth token --hostname github.com --user "$ACCT_SHARED") "$REAL_GH" api "repos/$(printf %s "$URL_SHARED" | cut -d/ -f4-5)" --jq .permissions.push 2>&1)"
echo "  $AMBIENT push on the shared repo: $("$REAL_GH" api "repos/$(printf %s "$URL_SHARED" | cut -d/ -f4-5)" --jq .permissions.push 2>&1)"
echo "  before:"; identity_state

echo; echo "=== S1 no config: the private contribution reads as 404 with the ambient login (the reported bug) ==="
h=$(lab s1 "$URL_PRIVATE")
poll "$h"; calls; records "$h"

echo; echo "=== S2 owner mapped (mixed case owner, comment and blank line): the private contribution is observed ==="
h=$(lab s2 "$URL_PRIVATE")
config "$h" "# repository owner, gh account

$(printf %s "$ACCT_PRIVATE" | tr '[:lower:]' '[:upper:]') $ACCT_PRIVATE
"
poll "$h"; calls; records "$h"
echo "  files in the lab holding any stored token: $(grep -rlF -f <(for a in "$AMBIENT" "$ACCT_PRIVATE" "$ACCT_SHARED"; do "$REAL_GH" auth token --hostname github.com --user "$a"; done; "$REAL_GH" auth token --hostname github.com) "$PARENT" | wc -l | tr -d ' ')"
echo "  second poll (rotation keeps reading it fresh):"
poll "$h"; records "$h"

echo; echo "=== S3 mapped and unmapped owners in one home: only the named owner changes identity ==="
h=$(lab s3 "$URL_PRIVATE" "$URL_SHARED")
config "$h" "$ACCT_PRIVATE $ACCT_PRIVATE
"
poll "$h"; calls; records "$h"

echo; echo "=== S4 merge-authority boundary: the shared repo read as its owner account records can_merge false ==="
h=$(lab s4 "$URL_SHARED")
config "$h" "$ACCT_SHARED $ACCT_SHARED
"
poll "$h"; calls; records "$h"

echo; echo "=== S5 named account has no stored login: unavailable, no fallback, stays in rotation, never retired ==="
h=$(lab s5 "$URL_PRIVATE")
config "$h" "$ACCT_PRIVATE no-such-account-zz9
"
poll "$h"; calls; records "$h"
echo "  second poll (same episode: silent, still attempted):"
poll "$h"; calls; records "$h"

echo; echo "=== S6 underscore account name (EMU form) is accepted as well formed ==="
h=$(lab s6 "$URL_PRIVATE")
config "$h" "$ACCT_PRIVATE jdoe_acme
"
poll "$h"; calls; records "$h"

echo; echo "=== S7 malformed or unreadable config refuses every URL, including the ambient-readable one ==="
n=0
for content in "owner_x $ACCT_PRIVATE" "$ACCT_PRIVATE" "$ACCT_PRIVATE $ACCT_PRIVATE extra" "-x $ACCT_PRIVATE" \
  "$ACCT_PRIVATE $ACCT_PRIVATE
$(printf %s "$ACCT_PRIVATE" | tr '[:lower:]' '[:upper:]') other" "$ACCT_PRIVATE $ACCT_PRIVATE"$'\r' directory; do
  n=$((n + 1))
  echo "--- S7.$n"
  h=$(lab "s7-$n" "$URL_PRIVATE" "$URL_SHARED")
  if [ "$content" = directory ]; then
    mkdir "$h/config/github-owner-accounts"; echo "  config/github-owner-accounts: (a directory)"
  else
    config "$h" "$content
"
  fi
  poll "$h"; calls; records "$h"
done

echo; echo "=== S8 an ambient GH_TOKEN in the watcher environment cannot hijack a mapped read ==="
h=$(lab s8 "$URL_PRIVATE" "$URL_SHARED")
config "$h" "$ACCT_PRIVATE $ACCT_PRIVATE
"
export GH_TOKEN=$DECOY
poll "$h"; calls; records "$h"
unset GH_TOKEN

echo; echo "=== after all scenarios ==="
identity_state
echo "  files under every lab holding any stored token: $(grep -rlF -f <(for a in "$AMBIENT" "$ACCT_PRIVATE" "$ACCT_SHARED"; do "$REAL_GH" auth token --hostname github.com --user "$a"; done; "$REAL_GH" auth token --hostname github.com) "$PARENT" | wc -l | tr -d ' ')"
