#!/usr/bin/env bash
# Behavior tests for the opt-in per-home worker account pin
# (config/claude-account, config/pi-account; bin/fm-worker-account-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane whose
# ambient environment carries a different account. The fake claude and pi
# answer the sign-in checks the way the real runners do - an environment
# credential counts as signed in (claude reports it as authMethod
# oauth_token), otherwise the selected root's stored login decides - and
# record the account environment and arguments a launched worker receives,
# plus a process snapshot. A fake security (tests/lib.sh fm_fake_security)
# holds the fake tokens the Claude token source cases map onto pool accounts.
# tests/fm-worker-account-live-e2e.test.sh and
# tests/fm-claude-token-live-e2e.test.sh prove those answers against the real
# runners and the real Keychain tool.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY

# make_account_fakes <fakebin> <case-dir>
# The fakes cannot read test variables during a sign-in check, which runs with
# a cleared environment, so their log paths are written into them here.
make_account_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$dir/claude-checks'
  printf '%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN:+token-present}" >> '$dir/claude-check-tokens'
  root=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}
  if [ -n "\${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -f "\$root/ignores-token" ]; then
    printf '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}\n'
    exit 0
  fi
  if [ -n "\${ANTHROPIC_API_KEY:-}" ]; then
    printf '{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}\n'
    exit 0
  fi
  if [ -f "\$root/.credentials.json" ]; then
    printf '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}\n'
    exit 0
  fi
  printf '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}\n'
  exit 1
fi
{
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
  printf 'ANTHROPIC_API_KEY=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "\${ANTHROPIC_AUTH_TOKEN-unset}"
  case "\${CLAUDE_CODE_OAUTH_TOKEN-unset}" in
    fm-synthetic-oauth-token) printf 'CLAUDE_CODE_OAUTH_TOKEN=expected\n' ;;
    fm-synthetic-first-token) printf 'CLAUDE_CODE_OAUTH_TOKEN=first-item\n' ;;
    fm-synthetic-second-token) printf 'CLAUDE_CODE_OAUTH_TOKEN=second-item\n' ;;
    *) printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}" ;;
  esac
  printf 'CLAUDE_CODE_USE_BEDROCK=%s\n' "\${CLAUDE_CODE_USE_BEDROCK-unset}"
} > '$dir/claude-worker'
ps -axww -o args= > '$dir/ps-snapshot' 2>/dev/null || true
SH
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" >> '$dir/pi-checks'
    if [ -f "\$root/old-pi" ]; then echo "Unknown command: auth" >&2; exit 1; fi
    if [ -n "\${OPENAI_API_KEY:-}" ] || grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"oauth"}\n' "\$provider"
      exit 0
    fi
    if grep -qx "\$provider" "\$root/extension-providers" 2>/dev/null; then
      printf '{"status":"not_ready","provider":"%s","reason":"provider_not_found"}\n' "\$provider"
      exit 1
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"
    exit 1
    ;;
  --list-models)
    printf 'provider  model  context\n'
    [ ! -f "\$root/listed" ] || cat "\$root/listed"
    exit 0
    ;;
esac
{
  printf 'PI_CODING_AGENT_DIR=%s\n' "\${PI_CODING_AGENT_DIR-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
SH
  cat > "$fakebin/security" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/security-argv'
case "\$*" in
  'find-generic-password -s fm-claude-token -a worker -w') printf '%s\n' 'fm-synthetic-oauth-token' ;;
  'find-generic-password -s first-token -a worker -w') printf '%s\n' 'fm-synthetic-first-token' ;;
  'find-generic-password -s second-token -a worker -w') printf '%s\n' 'fm-synthetic-second-token' ;;
  *) exit 44 ;;
esac
SH
  chmod +x "$fakebin/claude" "$fakebin/pi" "$fakebin/security"
  cp "$fakebin/pi" "$fakebin/pi-signed"
}

# new_case <name> <crew-harness> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_account_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# fake_macos_host: the Keychain adapter runs only on Darwin, so the Keychain
# cases report Darwin to `uname -s` on every host. Other uname forms still
# answer from the real host, so platform-specific stat and /proc readers keep
# working.
fake_macos_host() {
  local real
  real=$(command -v uname)
  cat > "$FAKEBIN/uname" <<SH
#!/usr/bin/env bash
[ "\$*" != -s ] || { printf '%s\n' Darwin; exit 0; }
exec '$real' "\$@"
SH
  chmod +x "$FAKEBIN/uname"
}

# signed_in_claude_root <dir>: a Claude config root holding a stored login.
signed_in_claude_root() {
  mkdir -p "$1"
  printf '{}\n' > "$1/.credentials.json"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn from HOME_DIR whose invoking
# process carries an ambient signed-in Claude root and an ambient API key.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  signed_in_claude_root "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    ANTHROPIC_API_KEY=ambient-invoker-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

# pane [VAR=value...]: execute the recorded launch in a pane whose ambient
# environment names another account for every runner, plus any extra
# assignments, and return the launch's status.
pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-pane-token ANTHROPIC_AUTH_TOKEN=ambient-pane-auth CLAUDE_CODE_USE_BEDROCK=1 \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" OPENAI_API_KEY=ambient-pane-openai \
    "$@" bash -c "$(cat "$CASE/launch.log")"
}

# run_pane: a pane launch that must succeed.
run_pane() {
  pane || fail "the recorded launch failed in the synthetic pane"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_pin_keeps_the_launch_unchanged() {
  local out rc id=acct-absent
  new_case absent claude
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an unpinned Claude spawn should succeed: $out"
  assert_not_contains "$out" "account=" "an unpinned spawn must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "an unpinned task record must not carry an account"
  assert_absent "$CASE/claude-checks" "an unpinned spawn must not run a sign-in check"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "an unpinned launch must keep forwarding the invoking process's own Claude root"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "an unpinned launch must leave the pane's environment credentials alone"

  new_case absent-pi pi
  out=$(spawn_ship acct-absent-pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "an unpinned Pi spawn with an unqualified model should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "--provider" "an unpinned Pi launch must not add a provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/ambient-pi" "$CASE/pi-worker" \
    "an unpinned Pi launch must keep the pane's own Pi root"
  pass "an absent pin leaves Claude and Pi launches exactly as they were"
}

test_claude_pin_selects_the_root_and_sheds_ambient_credentials() {
  local out rc id=acct-claude
  new_case claude-pin claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn pinned to a signed-in root should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the spawn should report the pinned account"
  assert_grep "account=$CASE/work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/work" ] \
    || fail "the sign-in check should ask about the pinned root only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$CASE/work/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the pinned root's store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the pin"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient OAuth token must not outrank the pin"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=unset" "$CASE/claude-worker" "an ambient cloud-provider switch must not outrank the pin"
  pass "a Claude pin selects its root and sheds the credentials that would outrank it"
}

test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login() {
  local out rc id=acct-claude-out
  new_case claude-signed-out claude
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a Claude pin to a signed-out root must refuse"
  assert_refused_before_launch "$id" "$out" "config/claude-account pins Claude workers to $CASE/work, which is not signed in"
  assert_absent "$CASE/work/.claude.json" "a refused spawn must not register trust in the pinned root"
  pass "a Claude pin refuses a signed-out root even when the invoking process has a usable login and API key"
}

test_claude_ordinary_pin_unsets_the_config_root() {
  local out rc id=acct-ordinary
  new_case ordinary claude
  printf 'ordinary' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "an ordinary pin with no default login must refuse"
  assert_refused_before_launch "$id" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an ordinary pin with a default login should succeed: $out"
  assert_contains "$out" "account=ordinary" "the spawn should report the ordinary account"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the ordinary check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$HOME_DIR/user-home/.claude.json" 2>/dev/null)" "$WT" \
    "ordinary trust should land in the default ~/.claude.json store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" \
    "the ordinary account must drop an ambient CLAUDE_CONFIG_DIR"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the ordinary pin"
  pass "an ordinary Claude pin selects the default login and drops an ambient root"
}

test_malformed_pins_refuse_before_launch() {
  local out rc id=acct-bad n=0 body
  new_case malformed claude
  mkdir -p "$CASE/work"
  for body in 'relative/root' "$CASE/work"$'\r' '' 'ordinary'$'\n''environment' "$CASE/missing-root"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-$n"); rc=$?
    expect_code 1 "$rc" "malformed pin #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account"
  done
  rm "$HOME_DIR/config/claude-account"
  mkdir "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-dir"); rc=$?
  expect_code 1 "$rc" "a directory in place of the pin must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-account must be a readable regular file"
  rmdir "$HOME_DIR/config/claude-account"
  printf 'ordinary\n' > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-pi" --harness pi --model openai-codex/gpt-5.5); rc=$?
  expect_code 1 "$rc" "a Pi pin without a providers line must refuse"
  assert_refused_before_launch "$id-pi" "$out" "config/pi-account must hold"
  assert_absent "$CASE/claude-checks" "a malformed pin must refuse before any sign-in check"
  pass "malformed, relative, CR-terminated, empty, extra-line, missing-root, and non-file pins refuse before launch"
}

test_claude_pool_defaults_to_the_first_line_and_account_selects_another() {
  local out rc id=acct-pool
  new_case pool claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/mon"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  printf '%s\n' "$CASE/work" "$CASE/mon" ordinary > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-first"); rc=$?
  expect_code 0 "$rc" "a pool spawn without --account should launch on the first line: $out"
  assert_contains "$out" "account=$CASE/work" "the spawn should report the pool's first line"
  assert_grep "account=$CASE/work" "$HOME_DIR/state/$id-first.meta" "the task record should carry the first line"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/work" ] \
    || fail "only the selected account should be sign-in checked: $(cat "$CASE/claude-checks")"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id-mon" --account "$CASE/mon"); rc=$?
  expect_code 0 "$rc" "--account naming a declared line should launch on it: $out"
  assert_contains "$out" "account=$CASE/mon" "the spawn should report the selected account"
  assert_grep "account=$CASE/mon" "$HOME_DIR/state/$id-mon.meta" "the task record should carry the selected account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/mon" ] \
    || fail "the sign-in check should ask about the selected account only: $(cat "$CASE/claude-checks")"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/mon" "$CASE/claude-worker" "the worker should run under the selected account"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "a selected pool account must still shed ambient credentials"
  out=$(spawn_ship "$id-ord" --account=ordinary); rc=$?
  expect_code 0 "$rc" "--account ordinary should launch on the default login: $out"
  assert_contains "$out" "account=ordinary" "the spawn should report the ordinary account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "the ordinary pool line must drop an ambient root"
  pass "a Claude pool launches on its first line by default and on any declared line named by --account"
}

test_claude_pool_and_account_refusals() {
  local out rc id=acct-pool-bad n=0 body
  new_case pool-refusals claude
  signed_in_claude_root "$CASE/work"
  mkdir -p "$CASE/mon"
  out=$(spawn_ship "$id-nofile" --account ordinary); rc=$?
  expect_code 1 "$rc" "--account without config/claude-account must refuse"
  assert_refused_before_launch "$id-nofile" "$out" "--account 'ordinary' needs config/claude-account"
  printf '%s\n' "$CASE/work" "$CASE/mon" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-undeclared" --account "$CASE/other"); rc=$?
  expect_code 1 "$rc" "an undeclared --account must refuse"
  assert_refused_before_launch "$id-undeclared" "$out" "--account '$CASE/other' is not declared in config/claude-account"
  out=$(spawn_ship "$id-prefix" --account "$CASE/wor"); rc=$?
  expect_code 1 "$rc" "--account must match a declared line exactly"
  assert_refused_before_launch "$id-prefix" "$out" "is not declared in config/claude-account"
  out=$(spawn_ship "$id-out" --account "$CASE/mon"); rc=$?
  expect_code 1 "$rc" "a signed-out selected account must refuse even when the first line is signed in"
  assert_refused_before_launch "$id-out" "$out" "config/claude-account pins Claude workers to $CASE/mon, which is not signed in"
  out=$(spawn_ship "$id-codex" --harness codex --account "$CASE/work"); rc=$?
  expect_code 1 "$rc" "--account for another harness must refuse"
  assert_refused_before_launch "$id-codex" "$out" "applies to Claude workers only, not codex"
  out=$(spawn_ship "$id-pi" --harness pi --model openai-codex/gpt-5.5 --account "$CASE/work"); rc=$?
  expect_code 1 "$rc" "--account for Pi must refuse"
  assert_refused_before_launch "$id-pi" "$out" "applies to Claude workers only, not pi"
  out=$(spawn_ship "$id-empty" --account ''); rc=$?
  expect_code 1 "$rc" "an empty --account must refuse"
  assert_refused_before_launch "$id-empty" "$out" "--account requires a non-empty value"
  for body in "$CASE/work"$'\n'"$CASE/work" "$CASE/work"$'\n\n'"$CASE/mon" \
    "$CASE/work"$'\n''relative/root' "$CASE/work"$'\n'"$CASE/mon"$'\r' "$CASE/work"$'\n'"$CASE/missing"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-malformed-$n"); rc=$?
    expect_code 1 "$rc" "malformed pool #$n must refuse"
    assert_refused_before_launch "$id-malformed-$n" "$out" "config/claude-account"
  done
  assert_contains "$out" "-> $CASE/missing" "a pool with an unusable later root should name that root"
  printf '%s\n' "$CASE/work" "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-dup"); rc=$?
  assert_refused_before_launch "$id-dup" "$out" "must hold one account per line - 'ordinary' or an absolute path - each distinct"
  pass "a pool refuses --account outside Claude, without a file, undeclared, signed out, or empty, and refuses malformed pools"
}

test_pi_pin_selects_the_root_and_the_declared_provider() {
  local out rc id=acct-pi launch
  new_case pi-pin pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model openai-codex/gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn pinned to a signed-in provider should succeed: $out"
  assert_contains "$out" "account=$CASE/pi-work account_provider=openai-codex" \
    "the spawn should report the pinned root and provider"
  assert_grep "account=$CASE/pi-work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned root"
  assert_grep "account_provider=openai-codex" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned provider"
  [ "$(cat "$CASE/pi-checks")" = "$CASE/pi-work openai-codex" ] \
    || fail "the sign-in check should ask the pinned root about the model's provider: $(cat "$CASE/pi-checks")"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--provider 'openai-codex' --model 'openai-codex/gpt-5.5'" \
    "the launch should confine Pi's model lookup to the declared provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the worker should run under the pinned Pi root"
  assert_grep "--provider openai-codex --model openai-codex/gpt-5.5" "$CASE/pi-worker" \
    "the worker should receive the declared provider"
  pass "a Pi pin selects its root and passes the declared provider"
}

test_pi_pin_refusals() {
  local out rc id=acct-pi-bad
  new_case pi-refusals pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-bare" --model gpt-5.5); rc=$?
  expect_code 1 "$rc" "an unqualified Pi model must refuse under a pin"
  assert_refused_before_launch "$id-bare" "$out" "'gpt-5.5' names no provider"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a Pi launch with no model must refuse under a pin"
  assert_refused_before_launch "$id-none" "$out" "'none' names no provider"
  out=$(spawn_ship "$id-other" --model openrouter/gpt-5.5); rc=$?
  expect_code 1 "$rc" "an undeclared Pi provider must refuse"
  assert_refused_before_launch "$id-other" "$out" "names provider 'openrouter'"
  out=$(OPENAI_API_KEY=ambient-invoker-openai spawn_ship "$id-out" --model anthropic/claude-sonnet); rc=$?
  expect_code 1 "$rc" "a declared provider the root is not signed in to must refuse"
  assert_refused_before_launch "$id-out" "$out" "which is not signed in for provider 'anthropic'"
  out=$(spawn_ship "$id-raw" --harness "pi --provider openai-codex --model openai-codex/gpt-5.5"); rc=$?
  expect_code 1 "$rc" "a raw Pi launch must refuse under a pin"
  assert_refused_before_launch "$id-raw" "$out" "a raw Pi launch command runs verbatim"
  pass "a Pi pin refuses unqualified, missing, undeclared, signed-out, and raw launches"
}

test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing() {
  local out rc id=acct-pi-list
  new_case pi-listing pi
  mkdir -p "$CASE/pi-work"
  printf 'codex-native\n' > "$CASE/pi-work/extension-providers"
  printf '%s\ncodex-native openai-codex\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-unlisted" --model codex-native/gpt-6); rc=$?
  expect_code 1 "$rc" "an extension provider the root lists no model for must refuse"
  assert_refused_before_launch "$id-unlisted" "$out" "no model listed for provider codex-native"
  printf 'codex-native  gpt-6  272K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-ext" --model codex-native/gpt-6); rc=$?
  expect_code 0 "$rc" "an extension provider listed under the root should launch: $out"
  : > "$CASE/pi-work/old-pi"
  printf 'openai-codex-mini  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old-near" --model openai-codex/gpt-5); rc=$?
  expect_code 1 "$rc" "a Pi without auth check must match the provider column exactly"
  assert_refused_before_launch "$id-old-near" "$out" "no model listed for provider openai-codex"
  printf 'openai-codex  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old" --model openai-codex/gpt-5); rc=$?
  expect_code 0 "$rc" "a Pi without auth check should launch when the root lists the provider: $out"
  pass "extension providers and a Pi without auth check fall back to an exact model-listing match"
}

test_a_pin_governs_only_its_own_runner() {
  local out rc id=acct-scope
  new_case scope codex
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-codex"); rc=$?
  expect_code 0 "$rc" "a codex spawn must ignore a Claude pin: $out"
  assert_not_contains "$out" "account=" "a codex spawn must not report a Claude pin"
  out=$(spawn_ship "$id-pi" --harness pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn must ignore a Claude pin: $out"
  assert_absent "$CASE/claude-checks" "no Claude sign-in check may run for another runner"
  pass "a Claude pin leaves codex and Pi launches unchanged"
}

test_raw_claude_command_receives_the_pin() {
  local out rc id=acct-raw
  new_case raw-claude claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" --harness "claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude spawn under a signed-in pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "a raw Claude spawn should report the pin"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "a raw Claude worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "a raw Claude worker must not keep an ambient API key"
  pass "a raw Claude launch command receives the home's pin"
}

test_raw_claude_account_override_refuses_under_a_pin() {
  local out rc id=acct-raw-override var
  new_case raw-override claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/other"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  for var in "CLAUDE_CONFIG_DIR=$CASE/other" ANTHROPIC_API_KEY=override-key; do
    out=$(spawn_ship "$id-${var%%=*}" --harness "FOO=1 $var claude --print raw"); rc=$?
    expect_code 1 "$rc" "a raw Claude command setting ${var%%=*} must refuse under a pin"
    assert_refused_before_launch "$id-${var%%=*}" "$out" "the raw launch command sets ${var%%=*}"
    assert_contains "$out" "remove ${var%%=*} from the raw command, or change or remove config/claude-account" \
      "the refusal should say how to proceed"
  done
  assert_absent "$CASE/claude-worker" "a refused raw override must never start Claude"
  pass "a pinned home refuses a raw Claude command that overrides the account"
}

test_raw_claude_account_override_is_kept_without_a_pin() {
  local out rc id=acct-raw-unpinned
  new_case raw-unpinned claude
  mkdir -p "$CASE/other"
  out=$(spawn_ship "$id" --harness "CLAUDE_CONFIG_DIR=$CASE/other ANTHROPIC_API_KEY=override-key claude --print raw"); rc=$?
  expect_code 0 "$rc" "an unpinned home should accept a raw Claude account override: $out"
  assert_not_contains "$out" "account=" "an unpinned raw spawn must not report an account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/other" "$CASE/claude-worker" "an unpinned raw override should keep its own root"
  assert_grep "ANTHROPIC_API_KEY=override-key" "$CASE/claude-worker" "an unpinned raw override should keep its own key"
  pass "an unpinned home keeps a raw Claude account override"
}

test_local_secondmate_reads_the_launching_home_pin() {
  local out rc id=acct-sm sm
  new_case secondmate claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$CASE/sm-own"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$CASE/sm-own" > "$sm/config/claude-account"
  signed_in_claude_root "$CASE/ambient-claude"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a local secondmate spawn under the launching home's pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the secondmate spawn should report the launching home's pin"
  [ "$(cat "$sm/config/claude-account")" = "$CASE/sm-own" ] \
    || fail "the launching home's pin must not be inherited over the secondmate home's own file"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" \
    "the secondmate agent should run under the launching home's pinned root"
  pass "a local secondmate reads the launching home's pin and its own home's file is never inherited over"
}

spawn_account_secondmate() {
  local id=$1 sm="$CASE/$1-home"
  shift
  mkdir -p "$sm/bin" "$sm/data" "$sm/config"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate "$@"
}

test_secondmate_account_override() {
  local out rc id=acct-sm-override harness file variable worker
  for harness in claude pi pi-signed; do
    new_case "secondmate-override-$harness" "$harness"
    case "$harness" in
    claude) file=claude-account; variable=CLAUDE_CONFIG_DIR; worker=claude ;;
    *) file=pi-account; variable=PI_CODING_AGENT_DIR; worker=pi ;;
    esac
    signed_in_claude_root "$CASE/primary"
    signed_in_claude_root "$CASE/mate"
    printf 'openai-codex\n' > "$CASE/primary/signed-in"
    printf 'openai-codex\n' > "$CASE/mate/signed-in"
    printf '%s\n' "$CASE/primary" > "$HOME_DIR/config/$file"
    mkdir -p "$HOME_DIR/config/secondmate-accounts/$id" "$HOME_DIR/config/secondmate-accounts/acct-ship"
    printf '%s\n' "$CASE/mate" > "$HOME_DIR/config/secondmate-accounts/$id/$file"
    if [ "$harness" != claude ]; then
      printf 'openai-codex\n' >> "$HOME_DIR/config/$file"
      printf 'openai-codex\n' >> "$HOME_DIR/config/secondmate-accounts/$id/$file"
    fi
    cp "$HOME_DIR/config/secondmate-accounts/$id/$file" "$HOME_DIR/config/secondmate-accounts/acct-ship/$file"
    out=$(spawn_account_secondmate "$id" --model openai-codex/gpt-5.5); rc=$?
    expect_code 0 "$rc" "a $harness secondmate with its own account should launch: $out"
    assert_contains "$out" "account=$CASE/mate" "the per-mate pin must override the primary's pin"
    run_pane
    assert_grep "$variable=$CASE/mate" "$CASE/$worker-worker" "the mate must receive its own account"
    if [ "$harness" != claude ]; then
      assert_grep '--provider openai-codex' "$CASE/$worker-worker" "the mate must receive its pinned provider"
    fi
    out=$(spawn_account_secondmate acct-other --model openai-codex/gpt-5.5); rc=$?
    expect_code 0 "$rc" "an unconfigured secondmate should keep the primary's pin: $out"
    run_pane
    assert_grep "$variable=$CASE/primary" "$CASE/$worker-worker" "another mate must not receive the override"
    out=$(spawn_ship acct-ship --model openai-codex/gpt-5.5); rc=$?
    expect_code 0 "$rc" "an ordinary worker must keep the primary's pin: $out"
    run_pane
    assert_grep "$variable=$CASE/primary" "$CASE/$worker-worker" "per-mate configuration must not pin ordinary workers"
  done
  pass "Claude, Pi, and pi-signed secondmates use their own pins without changing other launches"
}

test_secondmate_account_refusals() {
  local out rc id=acct-sm-refuse file harness body pin
  for harness in claude pi; do
    new_case "secondmate-refuse-$harness" "$harness"
    file=claude-account
    [ "$harness" = claude ] || file=pi-account
    signed_in_claude_root "$CASE/primary"
    printf 'openai-codex\n' > "$CASE/primary/signed-in"
    printf '%s\n' "$CASE/primary" > "$HOME_DIR/config/$file"
    [ "$harness" = claude ] || printf 'openai-codex\n' >> "$HOME_DIR/config/$file"
    mkdir -p "$HOME_DIR/config/secondmate-accounts/$id" "$CASE/signed-out"
    pin="$HOME_DIR/config/secondmate-accounts/$id/$file"
    for body in '' relative "$CASE/missing" "$CASE/signed-out"; do
      printf '%s\n' "$body" > "$pin"
      [ "$harness" = claude ] || printf 'openai-codex\n' >> "$pin"
      out=$(spawn_account_secondmate "$id" --model openai-codex/gpt-5.5); rc=$?
      expect_code 1 "$rc" "an unusable per-mate $harness pin must refuse: $out"
      assert_refused_before_launch "$id" "$out" "$pin"
    done
    rm "$pin"
    ln -s "$CASE/no-file" "$pin"
    out=$(spawn_account_secondmate "$id" --model openai-codex/gpt-5.5); rc=$?
    expect_code 1 "$rc" "a broken per-mate pin link must not fall back"
    assert_refused_before_launch "$id" "$out" "$pin"
    rm "$pin"
    mkdir "$pin"
    out=$(spawn_account_secondmate "$id" --model openai-codex/gpt-5.5); rc=$?
    expect_code 1 "$rc" "a non-file per-mate pin must not fall back"
    assert_refused_before_launch "$id" "$out" "$pin"
  done
  pass "unusable per-mate pins name the setting and refuse rather than use the primary's usable account"
}

test_remote_secondmate_account_override_refuses_locally() {
  local out rc id=acct-remote
  new_case remote-account claude
  mkdir -p "$HOME_DIR/config/secondmate-accounts/$id"
  printf 'ordinary\n' > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  printf -- '- %s - Remote fixture (host: account-test.invalid; root: /srv/firstmate; home: /srv/mate; scope: tests; projects: none; added 2026-10-17)\n' \
    "$id" > "$HOME_DIR/data/secondmates.md"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate); rc=$?
  expect_code 1 "$rc" "a primary-side remote account override must refuse"
  assert_refused_before_launch "$id" "$out" "$HOME_DIR/config/secondmate-accounts/$id/claude-account cannot pin remote secondmate"
  assert_absent "$CASE/claude-checks" "a remote refusal must not inspect a local login"
  pass "a remote route refuses a primary-side account override instead of silently ignoring it"
}

# The liveness sweep respawns a local secondmate whose endpoint is dead with a
# bare `fm-spawn.sh <id> --secondmate`, so each respawn below first ends the
# fake window. That respawn keeps the pool account recorded
# on the task while the file declares it, and re-resolves once it does not.
test_local_secondmate_respawn_keeps_the_recorded_pool_account() {
  local out rc id=acct-sm-pool sm
  new_case secondmate-pool claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/mon"
  printf '%s\n' "$CASE/work" "$CASE/mon" > "$HOME_DIR/config/claude-account"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  signed_in_claude_root "$CASE/ambient-claude"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --account "$CASE/mon" --secondmate); rc=$?
  expect_code 0 "$rc" "a local secondmate spawn on the pool's second line should succeed: $out"
  assert_grep "account=$CASE/mon" "$HOME_DIR/state/$id.meta" "the secondmate record should carry the selected account"

  "$FAKEBIN/tmux" kill-window -t "firstmate:fm-$id"
  : > "$CASE/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate); rc=$?
  expect_code 0 "$rc" "a respawn of the local secondmate should succeed: $out"
  assert_contains "$out" "account=$CASE/mon" "the respawn should report the recorded account"
  assert_grep "account=$CASE/mon" "$HOME_DIR/state/$id.meta" "the respawned record should keep the recorded account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/mon" "$CASE/claude-worker" \
    "the respawned secondmate should run on the recorded account, not the pool's first line"

  signed_in_claude_root "$CASE/spare"
  printf '%s\n' "$CASE/work" "$CASE/spare" > "$HOME_DIR/config/claude-account"
  "$FAKEBIN/tmux" kill-window -t "firstmate:fm-$id"
  : > "$CASE/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate); rc=$?
  expect_code 0 "$rc" "a respawn whose recorded account is no longer declared should re-resolve: $out"
  assert_grep "account=$CASE/work" "$HOME_DIR/state/$id.meta" "an undeclared recorded account should fall back to the first line"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" \
    "a respawn off an undeclared account should run on the pool's first line"

  rm "$HOME_DIR/config/claude-account"
  "$FAKEBIN/tmux" kill-window -t "firstmate:fm-$id"
  : > "$CASE/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate); rc=$?
  expect_code 0 "$rc" "a respawn in a home whose file is gone should launch unpinned: $out"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "an unpinned respawn must drop the recorded account"
  pass "a local secondmate respawn keeps its recorded pool account, and re-resolves once the file no longer declares it"
}

# --- Claude token source (config/claude-account-tokens) ---------------------

TOKEN_FAKE=fm-test-not-a-secret-worker-token-42

# token_case <name>: a Claude home with a two-seat signed-in pool whose first
# seat is mapped to a Keychain token source held by the fake security.
token_case() {
  new_case "$1" claude
  fm_fake_security "$FAKEBIN" "$CASE/fake-keychain" "$CASE/security-calls"
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/mon"
  printf '%s\n' "$CASE/work" "$CASE/mon" > "$HOME_DIR/config/claude-account"
  printf '%s keychain:fm-svc/cm\n' "$CASE/work" > "$HOME_DIR/config/claude-account-tokens"
  printf '%s\n' "$TOKEN_FAKE" > "$CASE/fake-keychain/fm-svc.cm"
}

# assert_token_nowhere_in_home <msg>: the fake token is in no record, launch
# file, or output under the home or the recorded launch.
assert_token_nowhere_in_home() {
  local hits
  hits=$(grep -rlF -- "$TOKEN_FAKE" "$HOME_DIR" "$CASE/launch.log" 2>/dev/null || true)
  [ -z "$hits" ] || fail "$1: $hits"
}

test_claude_token_source_loads_the_mapped_account_token_only() {
  local out rc id=acct-token launch
  token_case token
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a spawn on a token-mapped account should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the spawn should report the pinned account"
  assert_contains "$out" "account_token=keychain:fm-svc/cm" "the spawn should report the token source reference"
  assert_not_contains "$out" "$TOKEN_FAKE" "the spawn output must never hold the token"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/work" ] \
    || fail "the sign-in check should ask about the mapped root only: $(cat "$CASE/claude-checks")"
  [ "$(cat "$CASE/claude-check-tokens")" = token-present ] \
    || fail "the sign-in check must run with the mapped token loaded: $(cat "$CASE/claude-check-tokens")"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "/fm-claude-token.sh' exec 'keychain:fm-svc/cm' --" "the launch should load the token through the helper"
  assert_contains "$launch" "/fm-claude-token.sh' exec 'keychain:fm-svc/cm' -- env -u " \
    "the helper must run outside the credential shed, so the token it loads replaces an ambient one and survives the shed"
  assert_contains "$launch" " bash -c '" "the whole launch expression must run under the helper and the shed"
  assert_token_nowhere_in_home "no record or launch file may hold the token"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the mapped root"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_FAKE" "$CASE/claude-worker" "the worker should receive the mapped token"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must still be shed"
  assert_grep "ANTHROPIC_AUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient auth token must still be shed"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=unset" "$CASE/claude-worker" "an ambient cloud-provider switch must still be shed"
  assert_grep "keychain:fm-svc/cm" "$CASE/ps-snapshot" "the process snapshot should capture the launch chain"
  assert_no_grep "$TOKEN_FAKE" "$CASE/ps-snapshot" "the token must not appear in any process's arguments"
  : > "$CASE/claude-check-tokens"
  out=$(spawn_ship "$id-mon" --account "$CASE/mon"); rc=$?
  expect_code 0 "$rc" "a spawn on the unmapped pool account should succeed: $out"
  assert_not_contains "$out" "account_token=" "an unmapped account must not report a token source"
  [ "$(cat "$CASE/claude-check-tokens")" = "" ] \
    || fail "an unmapped account's sign-in check must run without a token: $(cat "$CASE/claude-check-tokens")"
  assert_not_contains "$(cat "$CASE/launch.log")" "fm-claude-token.sh" "an unmapped account's launch must not load any token"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/mon" "$CASE/claude-worker" "the unmapped worker should run under its own root"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an unmapped account must still shed the pane's ambient token"
  printf '# %s keychain:fm-svc/cm\n' "$CASE/work" > "$HOME_DIR/config/claude-account-tokens"
  out=$(spawn_ship "$id-disabled"); rc=$?
  expect_code 0 "$rc" "a spawn whose mapping is commented out should succeed: $out"
  assert_not_contains "$out" "account_token=" "a commented-out mapping must not report a token source"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "a commented-out mapping must launch the account on its stored login again"
  pass "a token-mapped account loads its token into the check and the worker only, an unmapped pool account is unchanged, and a comment disables a mapping"
}

test_claude_token_map_leaves_unmapped_launches_byte_identical() {
  local a b id=acct-token-inv
  token_case token-invariant
  # Only the task id and two per-spawn generated names differ between the two
  # launches: the private git-config env file and the launch-brief record.
  normalize() {
    sed -e "s/$1/<id>/g" -e 's/git-config\.s[0-9]*\.[0-9]*\.[0-9]*\.sh/git-config.<gen>.sh/g' \
      -e 's#operational-inbox/[0-9]*-[0-9a-f]*\.msg#operational-inbox/<record>.msg#g' "$CASE/launch.log"
  }
  spawn_ship "$id-a" --account "$CASE/mon" >/dev/null || fail "the unmapped spawn beside a token map should succeed"
  a=$(normalize "$id-a")
  rm "$HOME_DIR/config/claude-account-tokens"
  spawn_ship "$id-b" --account "$CASE/mon" >/dev/null || fail "the unmapped spawn without a token map should succeed"
  b=$(normalize "$id-b")
  [ "$a" = "$b" ] || fail "an unmapped account's launch must not change when a token map exists for another account"$'\n'"--- with map ---"$'\n'"$a"$'\n'"--- without map ---"$'\n'"$b"
  pass "a token map for one pool account leaves the other account's launch byte for byte as before"
}

test_claude_token_source_refuses_without_falling_back() {
  local out rc id=acct-token-bad
  token_case token-refusals
  printf '%s keychain:fm-svc/absent\n' "$CASE/work" > "$HOME_DIR/config/claude-account-tokens"
  out=$(spawn_ship "$id-missing"); rc=$?
  expect_code 1 "$rc" "a mapped account whose item is missing must refuse"
  assert_refused_before_launch "$id-missing" "$out" \
    "config/claude-account-tokens maps Claude account '$CASE/work' to keychain:fm-svc/absent, but its token could not be loaded"
  assert_contains "$out" "has no item 'absent' under service 'fm-svc'" "the helper's reason should be relayed"
  assert_contains "$out" "never falls back to the account's stored login" "the refusal should say there is no fallback"
  assert_absent "$CASE/claude-checks" "no sign-in check may run on the stored login when the token cannot be loaded"
  out=$(CLAUDE_CODE_OAUTH_TOKEN=ambient-invoker-token spawn_ship "$id-ambient"); rc=$?
  expect_code 1 "$rc" "a token in firstmate's own environment must not substitute for the mapped source"
  assert_refused_before_launch "$id-ambient" "$out" "could not be loaded"
  printf '%s keychain:fm-svc/cm\n' "$CASE/work" > "$HOME_DIR/config/claude-account-tokens"
  : > "$CASE/fake-keychain/.locked"
  out=$(spawn_ship "$id-locked"); rc=$?
  expect_code 1 "$rc" "a locked keychain must refuse"
  assert_refused_before_launch "$id-locked" "$out" "could not be loaded"
  assert_contains "$out" "keychain is locked in this session" "the locked reason should be relayed"
  rm "$CASE/fake-keychain/.locked"
  printf 'two\nlines\n' > "$CASE/fake-keychain/fm-svc.cm"
  out=$(spawn_ship "$id-value"); rc=$?
  expect_code 1 "$rc" "an item that does not hold one token must refuse"
  assert_refused_before_launch "$id-value" "$out" "is not a single-line token"
  printf '%s\n' "$TOKEN_FAKE" > "$CASE/fake-keychain/fm-svc.cm"
  : > "$CASE/work/ignores-token"
  out=$(spawn_ship "$id-ignored"); rc=$?
  expect_code 1 "$rc" "a runner that does not take the token must refuse"
  assert_refused_before_launch "$id-ignored" "$out" \
    "claude auth status reports authMethod 'claude.ai' instead of oauth_token"
  rm "$CASE/work/ignores-token"
  assert_absent "$CASE/claude-worker" "no refused spawn may start Claude"
  assert_token_nowhere_in_home "refusals must leave the token in no record"
  pass "a mapped account refuses a missing item, a locked keychain, a malformed value, and a runner that ignores the token, never falling back"
}

test_claude_token_map_malformed_refuses_every_claude_launch() {
  local out rc id=acct-token-cfg n=0 body
  token_case token-malformed
  for body in "$CASE/other keychain:fm-svc/cm" "$CASE/work keychain:fm-svc/cm"$'\n'"$CASE/work keychain:fm-svc/cm2" \
    "$CASE/work file:/tmp/x" "$CASE/work keychain:fm-svc/cm@relative.keychain-db" "$CASE/work keychain:fm-svc/cm"$'\r' \
    '' "$CASE/work" "$CASE/work  keychain:fm-svc/cm" "ordinary keychain:fm-svc/cm"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-account-tokens"
    out=$(spawn_ship "$id-$n" --account "$CASE/mon"); rc=$?
    expect_code 1 "$rc" "malformed token map #$n must refuse every Claude launch, including an unmapped account"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account-tokens"
  done
  assert_contains "$out" "maps 'ordinary', which config/claude-account does not declare" "an undeclared account should be named"
  assert_absent "$CASE/claude-checks" "a malformed token map must refuse before any sign-in check"
  rm "$HOME_DIR/config/claude-account-tokens"
  mkdir "$HOME_DIR/config/claude-account-tokens"
  out=$(spawn_ship "$id-dir"); rc=$?
  expect_code 1 "$rc" "a directory in place of the token map must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-account-tokens must be a readable regular file"
  rmdir "$HOME_DIR/config/claude-account-tokens"
  rm "$HOME_DIR/config/claude-account"
  printf '%s keychain:fm-svc/cm\n' "$CASE/work" > "$HOME_DIR/config/claude-account-tokens"
  out=$(spawn_ship "$id-nopin"); rc=$?
  expect_code 1 "$rc" "a token map without config/claude-account must refuse"
  assert_refused_before_launch "$id-nopin" "$out" \
    "config/claude-account-tokens maps token sources onto config/claude-account, which this home does not have"
  out=$(spawn_ship "$id-codex" --harness codex); rc=$?
  expect_code 0 "$rc" "a codex spawn must ignore the Claude token map: $out"
  pass "a malformed token map refuses every Claude launch before any check, and leaves other runners alone"
}

# One launch path serves both declared forms of a token source, so the map
# also covers the entries of a config/claude-accounts list.
test_account_list_entry_uses_its_token_map_line() {
  local out rc id=acct-list-map
  new_case list-token-map claude
  fm_fake_security "$FAKEBIN" "$CASE/fake-keychain" "$CASE/security-calls"
  signed_in_claude_root "$CASE/first"
  signed_in_claude_root "$CASE/second"
  declare_accounts "$CASE/first" "$CASE/second"
  printf '%s keychain:fm-svc/one\n%s keychain:fm-svc/retired\n' "$CASE/first" "$CASE/retired" \
    > "$HOME_DIR/config/claude-account-tokens"
  printf '%s\n' "$TOKEN_FAKE" > "$CASE/fake-keychain/fm-svc.one"
  out=$(spawn_ship "$id" --account "$CASE/first"); rc=$?
  expect_code 0 "$rc" "a list entry with a map line should launch, and a line for an undeclared account must stay inert: $out"
  assert_contains "$out" "account=$CASE/first" "the spawn should report the chosen entry"
  assert_contains "$out" "account_token=keychain:fm-svc/one" "the spawn should report the entry's token source"
  assert_grep "account_token=keychain:fm-svc/one" "$HOME_DIR/state/$id.meta" "the task record should carry the token source reference"
  [ "$(cat "$CASE/claude-check-tokens")" = token-present ] \
    || fail "the sign-in check must run with the entry's token loaded: $(cat "$CASE/claude-check-tokens")"
  assert_token_nowhere_in_home "no record or launch file may hold the token"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/first" "$CASE/claude-worker" "the worker should run under the chosen entry"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_FAKE" "$CASE/claude-worker" "the worker should receive the entry's mapped token"
  assert_no_grep "$TOKEN_FAKE" "$CASE/ps-snapshot" "the token must not appear in any process's arguments"
  : > "$CASE/claude-check-tokens"
  out=$(spawn_ship "$id-plain" --account "$CASE/second"); rc=$?
  expect_code 0 "$rc" "a list entry without a map line should launch on its stored login: $out"
  assert_not_contains "$out" "account_token=" "an unmapped entry must not report a token source"
  [ "$(cat "$CASE/claude-check-tokens")" = "" ] \
    || fail "an unmapped entry's sign-in check must run without a token: $(cat "$CASE/claude-check-tokens")"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an unmapped entry must still shed the pane's ambient token"
  rm "$CASE/fake-keychain/fm-svc.one"
  out=$(spawn_ship "$id-missing" --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "a mapped entry whose item is missing must refuse"
  assert_refused_before_launch "$id-missing" "$out" \
    "config/claude-account-tokens maps Claude account '$CASE/first' to keychain:fm-svc/one, but its token could not be loaded"
  assert_contains "$out" "never falls back to the account's stored login" "the refusal must say there is no fallback"
  printf '%s file:/tmp/x\n' "$CASE/first" > "$HOME_DIR/config/claude-account-tokens"
  out=$(spawn_ship "$id-malformed" --account "$CASE/second"); rc=$?
  expect_code 1 "$rc" "a malformed token map beside a list must refuse every Claude launch, including an unmapped entry"
  assert_refused_before_launch "$id-malformed" "$out" "config/claude-account-tokens"
  pass "a token map covers a list's entries: a mapped entry loads its token, an unmapped one keeps its stored login, an undeclared line is inert, and a missing item or malformed map refuses"
}

# A single-line pin may carry both declared forms; the map line wins.
test_claude_pin_token_map_line_wins_over_its_declaration_file() {
  local out rc id=acct-token-both other=fm-test-not-a-secret-declaration-token-9
  new_case token-precedence claude
  fake_macos_host
  fm_fake_security "$FAKEBIN" "$CASE/fake-keychain" "$CASE/security-calls"
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/mon"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  printf '%s keychain:fm-svc/cm\n' "$CASE/work" > "$HOME_DIR/config/claude-account-tokens"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-decl","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source.json"
  printf '%s\n' "$TOKEN_FAKE" > "$CASE/fake-keychain/fm-svc.cm"
  printf '%s\n' "$other" > "$CASE/fake-keychain/fm-decl.worker"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a pin with both forms should launch on the map line: $out"
  assert_contains "$out" "account_token=keychain:fm-svc/cm" "the map line must win"
  assert_contains "$out" "claude-account-credential-source.json is not used for this launch" "the launch should say the declaration file was not used"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_FAKE" "$CASE/claude-worker" "the worker should receive the map line's token"
  printf '# %s keychain:fm-svc/cm\n' "$CASE/work" > "$HOME_DIR/config/claude-account-tokens"
  out=$(spawn_ship "$id-decl"); rc=$?
  expect_code 0 "$rc" "with the map line commented out the declaration file should apply: $out"
  assert_contains "$out" "claude-account-credential-source.json" "the spawn should report the declaration file as the token source"
  assert_not_contains "$out" "is not used for this launch" "nothing is overridden once the map line is commented out"
  run_pane
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=$other" "$CASE/claude-worker" "the worker should receive the declaration file's token"
  assert_not_contains "$(cat "$CASE/launch.log" "$HOME_DIR/state/$id-decl.meta")" "$other" "the token never appears in the launch or the record"
  printf '%s keychain:fm-svc/cm\n' "$CASE/work" > "$HOME_DIR/config/claude-account-tokens"
  printf '{\n' > "$HOME_DIR/config/claude-account-credential-source.json"
  out=$(spawn_ship "$id-bad"); rc=$?
  expect_code 1 "$rc" "a malformed declaration file must refuse even while the map line wins"
  assert_refused_before_launch "$id-bad" "$out" "malformed"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-decl","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source.json"
  printf '%s\n' "$CASE/work" "$CASE/mon" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-pool"); rc=$?
  expect_code 1 "$rc" "a several-line pool must refuse a declaration file beside it"
  assert_refused_before_launch "$id-pool" "$out" "applies to a single-line Claude account pin"
  pass "a pin with both token forms launches on its map line, falls to the declaration file when that line is commented out, and a pool refuses a declaration file"
}

# A per-secondmate Claude pin may itself be a pool: --account selects among its
# own lines, and the home-wide pool's lines do not apply to that secondmate.
test_secondmate_pool_pin_selects_among_its_own_lines() {
  local out rc id=acct-sm-own-pool
  new_case secondmate-own-pool claude
  signed_in_claude_root "$CASE/home-acct"
  signed_in_claude_root "$CASE/mate-a"
  signed_in_claude_root "$CASE/mate-b"
  printf '%s\n' "$CASE/home-acct" > "$HOME_DIR/config/claude-account"
  mkdir -p "$HOME_DIR/config/secondmate-accounts/$id"
  printf '%s\n' "$CASE/mate-a" "$CASE/mate-b" > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  out=$(spawn_account_secondmate "$id" --account "$CASE/home-acct"); rc=$?
  expect_code 1 "$rc" "a home-wide line must not select an account for a secondmate with its own pin: $out"
  assert_refused_before_launch "$id" "$out" "secondmate-accounts/$id/claude-account (declared: "
  out=$(spawn_account_secondmate "$id" --account "$CASE/mate-b"); rc=$?
  expect_code 0 "$rc" "a line of the secondmate's own pool should launch: $out"
  assert_contains "$out" "account=$CASE/mate-b" "the spawn should report the secondmate pool's selected line"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/mate-b" "$CASE/claude-worker" \
    "the secondmate agent should run on its own pool's selected line"
  pass "a per-secondmate pool selects among its own lines and refuses the home-wide pool's"
}

test_remote_secondmate_refuses_account() {
  local out rc id=acct-remote-flag
  new_case remote-account-flag claude
  signed_in_claude_root "$CASE/first"
  declare_accounts "$CASE/first"
  printf -- '- %s - Remote fixture (host: account-test.invalid; root: /srv/firstmate; home: /srv/mate; scope: tests; projects: none; added 2026-10-17)\n' \
    "$id" > "$HOME_DIR/data/secondmates.md"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "--account on a remote secondmate must refuse"
  assert_refused_before_launch "$id" "$out" "--account applies to ships and scouts"
  assert_absent "$CASE/claude-checks" "a refused remote launch must not inspect a local login"
  pass "a remote secondmate refuses --account instead of launching on the remote home's account"
}

# declare_accounts <entry>...: the home's config/claude-accounts list.
declare_accounts() {
  printf '%s\n' "$@" > "$HOME_DIR/config/claude-accounts"
}

test_no_account_list_keeps_today_and_refuses_account() {
  local out rc id=acct-list-off
  new_case list-off claude
  signed_in_claude_root "$CASE/work"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn in a home without a list should succeed: $out"
  assert_not_contains "$out" "account=" "a home without a list must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "a home without a list must not record an account"
  assert_absent "$CASE/claude-checks" "a home without a list must not run a sign-in check"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "a home without a list must keep forwarding the invoking process's own Claude root"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "a home without a list must leave the pane's environment credentials alone"
  out=$(spawn_ship "$id-flag" --account "$CASE/work"); rc=$?
  expect_code 1 "$rc" "--account without a list must refuse"
  assert_refused_before_launch "$id-flag" "$out" "--account '$CASE/work' needs config/claude-accounts, which this home does not declare"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id-pin"); rc=$?
  expect_code 0 "$rc" "the single pin must keep working without a list: $out"
  assert_contains "$out" "account=$CASE/work" "the single pin must still report its account"
  pass "without config/claude-accounts the launch, the single pin, and the record are unchanged, and --account refuses"
}

test_account_list_launches_the_named_entry() {
  local out rc id=acct-list
  new_case list claude
  signed_in_claude_root "$CASE/first"
  signed_in_claude_root "$CASE/second"
  declare_accounts "$CASE/first" "$CASE/second"
  out=$(spawn_ship "$id" --account "$CASE/second"); rc=$?
  expect_code 0 "$rc" "a spawn naming a declared, signed-in account should succeed: $out"
  assert_contains "$out" "account=$CASE/second" "the spawn line should name the chosen account"
  assert_grep "account=$CASE/second" "$HOME_DIR/state/$id.meta" "the task record should carry the chosen account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/second" ] \
    || fail "the sign-in check should ask about the chosen account only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$CASE/second/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the chosen account's store"
  assert_absent "$CASE/first/.claude.json" "the other declared account must not be touched"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/second" "$CASE/claude-worker" "the worker should run under the chosen account"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the chosen account"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient OAuth token must not outrank the chosen account"
  pass "a declared account named with --account is checked, launched, and recorded like a pin"
}

test_account_list_refusals() {
  local out rc id=acct-list-bad n=0 body
  new_case list-refusals claude
  signed_in_claude_root "$CASE/first"
  signed_in_claude_root "$CASE/second"
  mkdir -p "$CASE/signed-out"
  declare_accounts "$CASE/first" "$CASE/second" "$CASE/signed-out" ordinary
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a Claude spawn without --account must refuse under a list"
  assert_refused_before_launch "$id-none" "$out" "config/claude-accounts declares 4 Claude accounts, so a Claude ship or scout launch must name one with --account"
  out=$(spawn_ship "$id-other" --account "$CASE/elsewhere"); rc=$?
  expect_code 1 "$rc" "an undeclared account must refuse"
  assert_refused_before_launch "$id-other" "$out" "account '$CASE/elsewhere' is not declared in config/claude-accounts"
  signed_in_claude_root "$CASE/elsewhere"$'\n'"$CASE/first"
  out=$(spawn_ship "$id-newline" --account "$CASE/elsewhere"$'\n'"$CASE/first"); rc=$?
  expect_code 1 "$rc" "an account holding a newline must refuse even when one of its lines is declared"
  assert_refused_before_launch "$id-newline" "$out" "--account must name one config/claude-accounts entry exactly, with no control characters"
  [ ! -e "$CASE/claude-checks" ] || assert_no_grep "$CASE/elsewhere" "$CASE/claude-checks" "a newline account must be refused before its sign-in check"
  out=$(spawn_ship "$id-out" --account "$CASE/signed-out"); rc=$?
  expect_code 1 "$rc" "a signed-out declared account must refuse even with an ambient login and key"
  assert_refused_before_launch "$id-out" "$out" "config/claude-accounts pins Claude workers to $CASE/signed-out, which is not signed in"
  out=$(spawn_ship "$id-ordinary" --account ordinary); rc=$?
  expect_code 1 "$rc" "a signed-out ordinary entry must refuse"
  assert_refused_before_launch "$id-ordinary" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  out=$(spawn_ship "$id-codex" --harness codex --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "--account on another runner must refuse"
  assert_refused_before_launch "$id-codex" "$out" "applies to Claude workers only, not codex"
  out=$(spawn_ship "$id-raw" --account "$CASE/first" --harness "CLAUDE_CONFIG_DIR=$CASE/second claude --print raw"); rc=$?
  expect_code 1 "$rc" "a raw command overriding the chosen account must refuse"
  assert_refused_before_launch "$id-raw" "$out" "the raw launch command sets CLAUDE_CONFIG_DIR"
  printf '%s\n' "$CASE/first" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-both" --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "a list beside a single pin must refuse"
  assert_refused_before_launch "$id-both" "$out" "config/claude-accounts and config/claude-account are both present"
  rm "$HOME_DIR/config/claude-account"
  for body in "$CASE/first"$'\n\n'"$CASE/second" "relative/root" "$CASE/first"$'\r' '' "$CASE/first"$'\n'"$CASE/first" "$CASE/first"$'\n'"$CASE/missing"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-accounts"
    out=$(spawn_ship "$id-$n" --account "$CASE/first"); rc=$?
    if [ "$n" = 6 ]; then
      expect_code 0 "$rc" "a missing entry that is not chosen must not block another: $out"
      out=$(spawn_ship "$id-$n-missing" --account "$CASE/missing"); rc=$?
      expect_code 1 "$rc" "a missing chosen entry must refuse"
      assert_refused_before_launch "$id-$n-missing" "$out" "config/claude-accounts must name readable, searchable existing directories"
      continue
    fi
    expect_code 1 "$rc" "malformed list #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-accounts"
  done
  rm "$HOME_DIR/config/claude-accounts"
  mkdir "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-dir" --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "a directory in place of the list must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-accounts must be a readable regular file"
  assert_no_grep "$CASE/second" "$CASE/claude-checks" "an account no launch chose must never be sign-in checked"
  assert_absent "$CASE/claude-worker" "no refused launch may start Claude"
  pass "a list refuses a missing, undeclared, signed-out, wrong-runner, raw-override, doubled, or malformed choice"
}

test_account_list_secondmate_needs_its_own_pin() {
  local out rc id=acct-list-sm
  new_case list-secondmate claude
  signed_in_claude_root "$CASE/first"
  signed_in_claude_root "$CASE/mate"
  declare_accounts "$CASE/first"
  out=$(spawn_account_secondmate "$id"); rc=$?
  expect_code 1 "$rc" "a secondmate without its own pin must refuse under a list: $out"
  assert_refused_before_launch "$id" "$out" "secondmate $id needs its own pin in config/secondmate-accounts/$id/claude-account"
  out=$(spawn_account_secondmate "$id" --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "--account on a secondmate must refuse"
  assert_refused_before_launch "$id" "$out" "--account applies to ships and scouts"
  mkdir -p "$HOME_DIR/config/secondmate-accounts/$id"
  printf '%s\n' "$CASE/mate" > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  out=$(spawn_account_secondmate "$id"); rc=$?
  expect_code 0 "$rc" "a secondmate with its own pin should launch under a list: $out"
  assert_contains "$out" "account=$CASE/mate" "the secondmate should launch on its own pin"
  pass "a list never chooses a secondmate's account: it needs its own pin and refuses --account"
}

# --- Claude weekly-use cap (config/claude-account-caps) ---------------------

# cap_case <name>: a Claude home with a signed-in two-seat pool, ca first and
# cm2 second, ca capped at 80% weekly use, and a fake quota-axi that answers
# from $CASE/quota.json (absent: a failed read).
cap_case() {
  new_case "$1" claude
  signed_in_claude_root "$CASE/ca"
  signed_in_claude_root "$CASE/cm2"
  printf '%s\n' "$CASE/ca" "$CASE/cm2" > "$HOME_DIR/config/claude-account"
  printf '%s 80\n' "$CASE/ca" > "$HOME_DIR/config/claude-account-caps"
  fm_fake_claude_quota "$FAKEBIN" "$CASE/quota.json" "$CASE/quota-calls"
  : > "$CASE/quota-calls"
}

# cap_quota <lane-json>...: the snapshot the fake quota-axi answers with.
cap_quota() {
  printf '%s\n' "$@" | jq -s '{schemaVersion: 6, providers: .}' > "$CASE/quota.json"
}

test_claude_cap_default_pool_skips_an_account_not_under_its_cap() {
  local out rc id=acct-cap-skip
  cap_case cap-skip
  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 85)"
  out=$(spawn_ship "$id-over"); rc=$?
  expect_code 0 "$rc" "a pool spawn without --account should skip an over-cap first line: $out"
  assert_contains "$out" "account=$CASE/cm2" "the spawn should launch on the next declared line"
  assert_contains "$out" "caps Claude account '$CASE/ca' at 80% weekly use" "the skip note should name the account and the cap"
  assert_contains "$out" "weekly use 85% is at or over the cap" "the skip note should name the reading"
  assert_grep "account=$CASE/cm2" "$HOME_DIR/state/$id-over.meta" "the task record should carry the skipped-to account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/cm2" ] \
    || fail "only the account the cap allowed should be sign-in checked: $(cat "$CASE/claude-checks")"
  assert_equals "PROFILES=$CASE/ca SNAPSHOT_ENV=unset ARGS=--provider claude --full --json" "$(cat "$CASE/quota-calls")" \
    "quota-axi should read the capped account once, without a fixture override"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/cm2" "$CASE/claude-worker" "the worker should run on the skipped-to account"

  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 80)"
  out=$(spawn_ship "$id-at"); rc=$?
  expect_code 0 "$rc" "a first line exactly at its cap should be skipped: $out"
  assert_contains "$out" "account=$CASE/cm2" "use at the cap is not under it"

  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 79.5)"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id-under"); rc=$?
  expect_code 0 "$rc" "a first line under its cap should launch: $out"
  assert_contains "$out" "account=$CASE/ca" "a capped account under its cap keeps the pool's first place"
  assert_not_contains "$out" "skips it" "an account under its cap is not skipped"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/ca" ] || fail "the first line should be the one sign-in checked"
  pass "a pool spawn without --account skips a capped account at or over its cap for the next declared line, in order"
}

test_claude_cap_refuses_an_explicit_account_not_under_its_cap() {
  local out rc id=acct-cap-explicit
  cap_case cap-explicit
  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 92)"
  out=$(spawn_ship "$id-over" --account "$CASE/ca"); rc=$?
  expect_code 1 "$rc" "--account naming an over-cap account must refuse"
  assert_refused_before_launch "$id-over" "$out" "Claude account '$CASE/ca' capped at 80%"
  assert_contains "$out" "weekly use 92% is at or over the cap: seven_day 92% used, refreshedAt" \
    "the refusal should name the reading"
  assert_contains "$out" "no flag or variable overrides the cap" "the refusal should say it cannot be bypassed"
  assert_absent "$CASE/claude-checks" "a refused account must not be sign-in checked"
  out=$(FM_CLAUDE_ACCOUNT_CAP=off FM_CLAUDE_PICK_WEEKLY_MAX=100 spawn_ship "$id-env" --account "$CASE/ca"); rc=$?
  expect_code 1 "$rc" "no environment variable may lift the cap"
  assert_refused_before_launch "$id-env" "$out" "capped at 80%"
  : > "$CASE/quota-calls"
  out=$(spawn_ship "$id-other" --account "$CASE/cm2"); rc=$?
  expect_code 0 "$rc" "--account naming an uncapped account should launch: $out"
  assert_contains "$out" "account=$CASE/cm2" "the uncapped account should launch"
  assert_equals "" "$(cat "$CASE/quota-calls")" "an uncapped account must not read quota"
  pass "--account naming a capped account at or over its cap refuses with the account, reading, and cap, and nothing overrides it"
}

test_claude_cap_unknown_stale_or_unmatched_use_is_not_under_the_cap() {
  local out rc id=acct-cap-unknown n=0 lanes
  cap_case cap-unknown
  rm -f "$CASE/quota.json"
  out=$(spawn_ship "$id-failed" --account "$CASE/ca"); rc=$?
  expect_code 1 "$rc" "a failed quota read must refuse a capped account"
  assert_refused_before_launch "$id-failed" "$out" "weekly use unknown, which never counts as under the cap: quota-axi printed no valid quota snapshot"
  for lanes in \
    "$(fm_claude_weekly_lane ca "$CASE/ca" 10 1200)" \
    "$(fm_claude_weekly_lane ca "$CASE/ca" 10 30 rate_limited)" \
    "$(fm_claude_weekly_lane ca "$CASE/ca" -)" \
    "$(fm_claude_weekly_lane other "$CASE/other" 10)" \
    "$(fm_claude_weekly_lane ca "$CASE/ca" 10 -3600)"; do
    n=$((n + 1))
    printf '%s\n' "$lanes" | jq -s '{schemaVersion: 6, providers: .}' > "$CASE/quota.json"
    out=$(FM_CLAUDE_QUOTA_READING_MAX_AGE=999999 spawn_ship "$id-$n" --account "$CASE/ca"); rc=$?
    expect_code 1 "$rc" "unknown weekly use #$n must refuse a capped account: $out"
    assert_refused_before_launch "$id-$n" "$out" "weekly use unknown, which never counts as under the cap"
  done
  assert_contains "$out" "dated in the future" "a future reading should be named"
  out=$(spawn_ship "$id-pool"); rc=$?
  expect_code 0 "$rc" "a pool default should skip an unknown capped line for an uncapped one: $out"
  assert_contains "$out" "account=$CASE/cm2" "the pool default should fall through to the uncapped line"
  printf '%s 80\n%s 50\n' "$CASE/ca" "$CASE/cm2" > "$HOME_DIR/config/claude-account-caps"
  rm -f "$CASE/quota.json"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a pool whose every line is capped with unknown use must refuse"
  assert_refused_before_launch "$id-none" "$out" "no declared Claude account is under its weekly-use cap"
  assert_contains "$out" "'$CASE/cm2' capped at 50%" "the refusal should name every capped account and its cap"
  pass "an unknown, failed, stale, rate-limited, future, or unmatched weekly reading never counts as under the cap"
}

test_claude_cap_reuses_a_fresh_reading_of_the_same_account() {
  local out rc id=acct-cap-reading
  cap_case cap-reading
  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 0 30 rate_limited)"
  mkdir -p "$HOME_DIR/user-home/.local/state/quota-axi-refresh"
  printf '%s\n' "$(fm_claude_weekly_lane ca "$CASE/ca" 40 60)" | jq -s '{schemaVersion: 6, providers: .}' \
    > "$HOME_DIR/user-home/.local/state/quota-axi-refresh/ca.json"
  out=$(QUOTA_AXI_SNAPSHOT="$CASE/forged.json" spawn_ship "$id-fresh" --account "$CASE/ca"); rc=$?
  expect_code 0 "$rc" "a fresh same-account reading under the cap should launch: $out"
  assert_contains "$out" "account=$CASE/ca" "the capped account should launch on the reused reading"
  assert_contains "$(cat "$CASE/quota-calls")" "SNAPSHOT_ENV=unset" "a fixture override must never reach quota-axi"
  printf '%s\n' "$(fm_claude_weekly_lane ca "$CASE/ca" 40 900)" | jq -s '{schemaVersion: 6, providers: .}' \
    > "$HOME_DIR/user-home/.local/state/quota-axi-refresh/ca.json"
  out=$(FM_CLAUDE_QUOTA_READING_MAX_AGE=3600 spawn_ship "$id-old" --account "$CASE/ca"); rc=$?
  expect_code 1 "$rc" "a reading older than 600 s must refuse even when the variable allows more"
  assert_refused_before_launch "$id-old" "$out" "weekly use unknown"
  pass "a capped account is measured from a fresh same-account reading, never one older than 600 s"
}

test_claude_cap_leaves_an_uncapped_launch_byte_identical() {
  local a b id=acct-cap-inv
  cap_case cap-invariant
  normalize() {
    sed -e "s/$1/<id>/g" -e 's/git-config\.s[0-9]*\.[0-9]*\.[0-9]*\.sh/git-config.<gen>.sh/g' \
      -e 's#operational-inbox/[0-9]*-[0-9a-f]*\.msg#operational-inbox/<record>.msg#g' "$CASE/launch.log"
  }
  printf '%s\n' "$CASE/cm2" "$CASE/ca" > "$HOME_DIR/config/claude-account"
  spawn_ship "$id-a" >/dev/null || fail "an uncapped first line beside a cap map should launch"
  a=$(normalize "$id-a")
  rm "$HOME_DIR/config/claude-account-caps"
  spawn_ship "$id-b" >/dev/null || fail "the same launch without a cap map should succeed"
  b=$(normalize "$id-b")
  assert_equals "$b" "$a" "a cap map must not change an uncapped account's launch"
  assert_equals "" "$(cat "$CASE/quota-calls")" "an uncapped launch must not read quota"
  pass "an uncapped account launches byte for byte as before, without a quota read"
}

test_claude_cap_refuses_a_secondmate_respawn_on_its_recorded_account() {
  local out rc id=acct-cap-sm
  cap_case cap-secondmate
  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 20)"
  out=$(spawn_account_secondmate "$id" --account "$CASE/ca"); rc=$?
  expect_code 0 "$rc" "a secondmate on a capped account under its cap should launch: $out"
  assert_grep "account=$CASE/ca" "$HOME_DIR/state/$id.meta" "the secondmate record should carry its account"
  "$FAKEBIN/tmux" kill-window -t "firstmate:fm-$id"
  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 81)"
  : > "$CASE/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" --secondmate); rc=$?
  expect_code 1 "$rc" "a respawn on a recorded account over its cap must refuse: $out"
  assert_contains "$out" "Claude account '$CASE/ca' capped at 80%" "the refusal should name the recorded account and cap"
  assert_contains "$out" "weekly use 81% is at or over the cap" "the refusal should name the reading"
  [ ! -s "$CASE/launch.log" ] || fail "a refused respawn must not launch: $(cat "$CASE/launch.log")"
  pass "a local secondmate respawn refuses on its recorded account at or over its cap"
}

test_claude_cap_list_and_malformed_maps() {
  local out rc id=acct-cap-bad n=0 body
  cap_case cap-malformed
  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 95)"
  for body in "$CASE/other 80" "$CASE/ca 0" "$CASE/ca 101" "$CASE/ca 80%" "$CASE/ca 80"$'\n'"$CASE/ca 70" "$CASE/ca"; do
    n=$((n + 1))
    printf '%s\n' "$body" > "$HOME_DIR/config/claude-account-caps"
    out=$(spawn_ship "$id-$n" --account "$CASE/cm2"); rc=$?
    expect_code 1 "$rc" "malformed cap map #$n must refuse every Claude launch: $out"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account-caps"
  done
  printf '%s 80\n' "$CASE/ca" > "$HOME_DIR/config/claude-account-caps"
  rm "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-unpinned"); rc=$?
  expect_code 1 "$rc" "a cap map without declared accounts must refuse"
  assert_refused_before_launch "$id-unpinned" "$out" "this launch has no declared Claude account"
  declare_accounts "$CASE/ca" "$CASE/cm2"
  out=$(spawn_ship "$id-list" --account "$CASE/ca"); rc=$?
  expect_code 1 "$rc" "a listed account over its cap must refuse"
  assert_refused_before_launch "$id-list" "$out" "capped at 80% (weekly use 95% is at or over the cap"
  out=$(spawn_ship "$id-list-ok" --account "$CASE/cm2"); rc=$?
  expect_code 0 "$rc" "an uncapped listed account should launch: $out"
  pass "a cap map refuses undeclared accounts, bad caps, repeats, and no declared accounts, and also governs config/claude-accounts"
}

# A list entry may carry a tab and its declaration file; a cap names the
# account alone and still governs that entry.
test_claude_cap_covers_a_list_entry_that_names_a_declaration_file() {
  local out rc id=acct-cap-decl
  cap_case cap-list-declaration
  fake_macos_host
  rm "$HOME_DIR/config/claude-account"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-claude-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source-ca.json"
  declare_accounts "$CASE/ca"$'\t'claude-account-credential-source-ca.json "$CASE/cm2"
  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 95)"
  out=$(spawn_ship "$id-over" --account "$CASE/ca"); rc=$?
  expect_code 1 "$rc" "a listed account with a declaration file must still refuse over its cap: $out"
  assert_refused_before_launch "$id-over" "$out" "capped at 80% (weekly use 95% is at or over the cap"
  cap_quota "$(fm_claude_weekly_lane ca "$CASE/ca" 40)"
  out=$(spawn_ship "$id-under" --account "$CASE/ca"); rc=$?
  expect_code 0 "$rc" "a listed account with a declaration file should launch under its cap: $out"
  assert_contains "$out" "account=$CASE/ca" "the spawn should report the capped entry it launched on"
  assert_contains "$out" "claude-account-credential-source-ca.json" "the entry should still launch on its declared token source"
  pass "a weekly-use cap governs a list entry that names a declaration file"
}

test_claude_account_pool_keychain_sources() {
  local out rc id measured chosen
  new_case pool-keychain-dispatch claude
  fake_macos_host
  signed_in_claude_root "$CASE/first"
  signed_in_claude_root "$CASE/second"
  declare_accounts "$CASE/first"$'\t'claude-account-credential-source-first.json \
    "$CASE/second"$'\t'claude-account-credential-source-second.json
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"first-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source-first.json"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"second-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source-second.json"
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70,"selection":{"spendPriority":0.2}}]}}]}'
SH
  chmod +x "$FAKEBIN/quota-axi"
  measured=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-claude-account-quota.sh"); rc=$?
  expect_code 0 "$rc" "dispatch must be able to measure the Keychain pool: $measured"
  chosen=${measured#*row: }
  chosen=${chosen%%  root=*}
  assert_equals "$CASE/first" "$chosen" "the quota row must expose a bare account usable for dispatch"
  id=acct-pool-keychain-dispatch
  out=$(spawn_ship "$id" --account "$chosen"); rc=$?
  expect_code 0 "$rc" "the dispatch-selected pool entry should use its Keychain source: $out"
  assert_contains "$out" "account=$CASE/first" "the dispatch-selected entry should remain the recorded account"
  assert_equals 'find-generic-password -s first-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "the dispatch-selected entry should read only its mapped Keychain item"
  run_pane
  assert_grep 'CLAUDE_CODE_OAUTH_TOKEN=first-item' "$CASE/claude-worker" \
    "the dispatch-selected pool entry should receive its own synthetic token"
  assert_equals $'find-generic-password -s first-token -a worker -w\nfind-generic-password -s first-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "both check and launch must read only the first entry's item"
  assert_not_contains "$(cat "$CASE/launch.log" "$CASE/security-argv" "$CASE/claude-worker")" \
    'fm-synthetic-' "the dispatch-selected token must not appear in output or logs"

  : > "$CASE/security-argv"
  id=acct-pool-keychain-explicit
  out=$(spawn_ship "$id" --account "$CASE/second"); rc=$?
  expect_code 0 "$rc" "an explicitly named pool entry should use its own Keychain source: $out"
  assert_contains "$out" "account=$CASE/second" "the explicit entry should be recorded"
  assert_equals 'find-generic-password -s second-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "--account must check only the matching entry's Keychain item"
  run_pane
  assert_grep 'CLAUDE_CODE_OAUTH_TOKEN=second-item' "$CASE/claude-worker" \
    "the explicit pool entry must receive its own synthetic token"
  assert_equals $'find-generic-password -s second-token -a worker -w\nfind-generic-password -s second-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "both check and launch must read only the second entry's item"
  assert_not_contains "$(cat "$CASE/launch.log" "$CASE/security-argv" "$CASE/claude-worker")" \
    'fm-synthetic-' "the explicit token must not appear in output or logs"
  pass "dispatch-selected and explicit Claude pool entries use only their own Keychain sources"
}

test_pool_entry_keychain_read_failure_never_falls_back() {
  local out rc id=acct-pool-keychain-missing
  new_case pool-keychain-missing claude
  fake_macos_host
  signed_in_claude_root "$CASE/first"
  declare_accounts "$CASE/first"$'\t'claude-account-credential-source-first.json
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"missing-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source-first.json"
  out=$(spawn_ship "$id" --account "$CASE/first"); rc=$?
  expect_code 1 "$rc" "an unavailable pool-entry Keychain item must refuse despite a stored login"
  assert_refused_before_launch "$id" "$out" "token could not be loaded"
  assert_equals 'find-generic-password -s missing-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "only the selected entry's missing Keychain item should be queried"
  pass "an unavailable pool-entry Keychain token refuses without falling back to the account's stored login"
}

test_claude_credential_source_requires_a_single_pin() {
  local out rc id=acct-claude-token-source-invalid
  new_case keychain-source-no-pin claude
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-claude-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source.json"
  out=$(spawn_ship "$id-no-pin"); rc=$?
  expect_code 1 "$rc" "a credential source without a pin must refuse"
  assert_refused_before_launch "$id-no-pin" "$out" "requires a Claude account pin"

  new_case keychain-source-list claude
  mkdir -p "$CASE/work"
  declare_accounts "$CASE/work"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-claude-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source.json"
  out=$(spawn_ship "$id-list" --account "$CASE/work"); rc=$?
  expect_code 1 "$rc" "a token source cannot apply to a Claude account list"
  assert_refused_before_launch "$id-list" "$out" "applies to one config/claude-account pin, not config/claude-accounts"
  pass "a credential-source mapping requires one matching Claude account pin"
}

test_local_secondmate_pin_uses_its_keychain_oauth_token() {
  local out rc id=acct-mate-token
  new_case keychain-mate-token claude
  fake_macos_host
  signed_in_claude_root "$CASE/primary"
  printf '%s\n' "$CASE/primary" > "$HOME_DIR/config/claude-account"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"primary-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source.json"
  mkdir -p "$HOME_DIR/config/secondmate-accounts/$id"
  signed_in_claude_root "$CASE/mate"
  printf '%s\n' "$CASE/mate" > "$HOME_DIR/config/secondmate-accounts/$id/claude-account"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-claude-token","account":"worker"}}' \
    > "$HOME_DIR/config/secondmate-accounts/$id/claude-account-credential-source.json"
  out=$(spawn_account_secondmate "$id"); rc=$?
  expect_code 0 "$rc" "a local secondmate pin with a readable Keychain OAuth token should launch: $out"
  assert_contains "$out" "account=$CASE/mate" "the secondmate's own account pin is selected"
  run_pane
  assert_grep 'CLAUDE_CODE_OAUTH_TOKEN=expected' "$CASE/claude-worker" \
    "the secondmate receives the synthetic token from its environment"
  assert_equals $'find-generic-password -s fm-claude-token -a worker -w\nfind-generic-password -s fm-claude-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "the secondmate checks and loads only its declared item"
  pass "a local secondmate uses its own credential source without inheriting the primary's"
}

test_claude_pin_uses_a_keychain_oauth_token() {
  local out rc id=acct-claude-token
  new_case keychain-token claude
  fake_macos_host
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-claude-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source.json"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude pin with a readable Keychain OAuth token should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the pinned account remains the selected account"
  assert_equals 'find-generic-password -s fm-claude-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "the shared credential-source adapter checks only the declared item"
  run_pane
  assert_equals $'find-generic-password -s fm-claude-token -a worker -w\nfind-generic-password -s fm-claude-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "the shared adapter loads the declared item once for check and once for launch"
  assert_grep 'CLAUDE_CODE_OAUTH_TOKEN=expected' "$CASE/claude-worker" \
    "the worker receives the synthetic token from its environment"
  assert_not_contains "$(cat "$CASE/launch.log" "$CASE/security-argv" "$CASE/claude-worker")" \
    'fm-synthetic-oauth-token' "the token never appears in the launch command or execution logs"
  assert_not_contains "$(cat "$HOME_DIR/state/$id.meta")" 'fm-synthetic-oauth-token' \
    "the task record never contains the token"
  pass "a Claude pin uses its declared Keychain OAuth token without logging or passing the token as an argument"
}

# keychain_token_ship <id> [spawn args...]: a ship spawn whose Claude pin maps to the fake
# Keychain item, after the pre-launch check has read the token once.
keychain_token_ship() {
  local out rc
  fake_macos_host
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-claude-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source.json"
  out=$(spawn_ship "$@"); rc=$?
  expect_code 0 "$rc" "a Claude pin with a readable Keychain OAuth token should launch: $out"
}

test_claude_pin_keeps_the_token_out_of_an_inherited_xtrace() {
  new_case keychain-token-xtrace claude
  keychain_token_ship acct-claude-token-xtrace
  pane SHELLOPTS=xtrace 2> "$CASE/pane-stderr" ||
    fail "the traced launch failed in the synthetic pane: $(cat "$CASE/pane-stderr")"
  assert_grep 'CLAUDE_CODE_OAUTH_TOKEN=expected' "$CASE/claude-worker" \
    "the traced worker still receives the synthetic token"
  assert_grep 'fm-claude-token.sh exec' "$CASE/pane-stderr" \
    "the pane really traced the launch"
  assert_not_contains "$(cat "$CASE/pane-stderr")" 'fm-synthetic-oauth-token' \
    "an inherited xtrace never prints the token"
  pass "an inherited bash xtrace in the pane never prints the Keychain token"
}

test_claude_pin_does_not_fall_back_when_its_keychain_token_vanishes_after_the_check() {
  new_case keychain-token-vanished claude
  keychain_token_ship acct-claude-token-vanished
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$*\" >> '$CASE/security-argv'" 'exit 44' \
    > "$FAKEBIN/security"
  # The launch ends with a disarm `|| true`, so its status cannot show the
  # refusal; the diagnostic and the missing worker do.
  pane 2> "$CASE/pane-stderr"
  assert_contains "$(cat "$CASE/pane-stderr")" 'is unavailable' "the pane says the token source is unavailable"
  assert_absent "$CASE/claude-worker" "Claude must never start on its stored login or the pane's credentials"
  assert_equals $'find-generic-password -s fm-claude-token -a worker -w\nfind-generic-password -s fm-claude-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "the launch read the declared item a second time"
  pass "a token that vanishes after the pre-launch check stops the launch without falling back"
}

test_raw_claude_retry_does_not_bypass_a_failed_keychain_read() {
  new_case keychain-token-raw-retry claude
  keychain_token_ship acct-claude-token-raw-retry --harness 'claude --print first || claude --print retry'
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$*\" >> '$CASE/security-argv'" 'exit 44' \
    > "$FAKEBIN/security"
  # Contract: a failed launch-time token read refuses the entire raw expression,
  # even when the pane has credentials that would let its retry start Claude.
  pane 2> "$CASE/pane-stderr"
  assert_contains "$(cat "$CASE/pane-stderr")" 'is unavailable' "the pane reports the failed token read"
  assert_absent "$CASE/claude-worker" "neither side of the raw retry may start Claude after token refusal"
  assert_equals $'find-generic-password -s fm-claude-token -a worker -w\nfind-generic-password -s fm-claude-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "the pre-launch read succeeded and the launch-time read was attempted"
  pass "a raw Claude retry cannot bypass a failed launch-time Keychain read"
}

test_claude_pin_does_not_fall_back_when_its_keychain_token_is_unavailable() {
  local out rc id=acct-claude-token-missing
  new_case keychain-token-missing claude
  fake_macos_host
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"missing-token","account":"worker"}}' \
    > "$HOME_DIR/config/claude-account-credential-source.json"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a missing Keychain token must refuse despite a stored Claude login"
  assert_refused_before_launch "$id" "$out" "token could not be loaded"
  assert_equals 'find-generic-password -s missing-token -a worker -w' \
    "$(cat "$CASE/security-argv")" "only the configured missing Keychain item is queried"
  pass "an unavailable mapped token refuses without falling back to the pinned Claude login"
}

test_absent_pin_keeps_the_launch_unchanged
test_claude_pin_selects_the_root_and_sheds_ambient_credentials
test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login
test_claude_ordinary_pin_unsets_the_config_root
test_malformed_pins_refuse_before_launch
test_claude_pool_defaults_to_the_first_line_and_account_selects_another
test_claude_pool_and_account_refusals
test_pi_pin_selects_the_root_and_the_declared_provider
test_pi_pin_refusals
test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing
test_a_pin_governs_only_its_own_runner
test_raw_claude_command_receives_the_pin
test_raw_claude_account_override_refuses_under_a_pin
test_raw_claude_account_override_is_kept_without_a_pin
test_local_secondmate_reads_the_launching_home_pin
test_local_secondmate_respawn_keeps_the_recorded_pool_account
test_secondmate_account_override
test_secondmate_account_refusals
test_local_secondmate_pin_uses_its_keychain_oauth_token
test_claude_credential_source_requires_a_single_pin
test_claude_pin_uses_a_keychain_oauth_token
test_claude_pin_does_not_fall_back_when_its_keychain_token_is_unavailable
test_claude_pin_keeps_the_token_out_of_an_inherited_xtrace
test_claude_pin_does_not_fall_back_when_its_keychain_token_vanishes_after_the_check
test_raw_claude_retry_does_not_bypass_a_failed_keychain_read
test_remote_secondmate_account_override_refuses_locally
test_claude_token_source_loads_the_mapped_account_token_only
test_claude_token_map_leaves_unmapped_launches_byte_identical
test_claude_token_source_refuses_without_falling_back
test_claude_token_map_malformed_refuses_every_claude_launch
test_account_list_entry_uses_its_token_map_line
test_claude_pin_token_map_line_wins_over_its_declaration_file
test_secondmate_pool_pin_selects_among_its_own_lines
test_remote_secondmate_refuses_account
test_no_account_list_keeps_today_and_refuses_account
test_account_list_launches_the_named_entry
test_account_list_refusals
test_claude_account_pool_keychain_sources
test_pool_entry_keychain_read_failure_never_falls_back
test_account_list_secondmate_needs_its_own_pin
test_claude_cap_default_pool_skips_an_account_not_under_its_cap
test_claude_cap_refuses_an_explicit_account_not_under_its_cap
test_claude_cap_unknown_stale_or_unmatched_use_is_not_under_the_cap
test_claude_cap_reuses_a_fresh_reading_of_the_same_account
test_claude_cap_leaves_an_uncapped_launch_byte_identical
test_claude_cap_refuses_a_secondmate_respawn_on_its_recorded_account
test_claude_cap_list_and_malformed_maps
test_claude_cap_covers_a_list_entry_that_names_a_declaration_file

echo "# all fm-worker-account tests passed"
