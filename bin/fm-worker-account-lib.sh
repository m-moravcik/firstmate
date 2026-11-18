#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# and per-secondmate account pins: which runners can be pinned, how a pin file
# is parsed and resolved, the launch-time sign-in check under it, and the
# environment credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Worker account pin" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command. A Claude pin
# may have config/claude-account-credential-source.json beside it, using the
# shared credential-source schema for its OAuth token. The token helper loads
# it separately for the pre-launch check and worker command, without falling
# back to the pinned root's stored login.
#
# config/claude-account may declare a pool: several lines, each `ordinary` or
# one absolute path, all distinct, with no blank or other lines. The first
# line is the home's default account; a launch selects another only by naming
# that exact line (fm-spawn.sh --account). A single line is today's pin,
# unchanged: every relaunch re-resolves it. Every declared root must be
# usable, so a broken pool refuses every Claude launch rather than being
# selected around. A relaunch in a pool keeps the account recorded on its task
# while the file still declares it, and refuses before the running agent stops
# when the file no longer does; an explicit --account is a deliberate switch,
# and a home whose file is gone launches unpinned as before. The Pi pin keeps
# one root and re-resolves on relaunch.
#
# An optional config/claude-account-tokens maps declared Claude accounts to a
# long-lived token source, one `<account> <source>` line each (a line starting
# with # is a comment): <account> is a line of config/claude-account exactly
# (everything before the last space), and <source> is
# keychain:<service>/<account>[@<keychain-file>], a reference
# to a macOS Keychain generic password - never the token itself. A mapped
# account's sign-in check and its worker both receive that token as
# CLAUDE_CODE_OAUTH_TOKEN, loaded by bin/fm-claude-token.sh into the one
# process's environment (never an argument, file, or output), replacing any
# ambient value while the shed below removes every other ambient credential,
# and the check accepts only a `claude auth status` that reports authMethod
# oauth_token, so the launch provably spends the token rather than the root's
# shared stored login. A
# missing, locked, unreadable, or malformed source refuses that launch and
# never falls back to the stored login or an ambient variable; a malformed map
# (an undeclared or repeated account, a bad source, a map with no
# config/claude-account) refuses every Claude launch like a broken pool. Beside
# a config/claude-accounts list the same map covers the list's entries
# (fm_worker_account_token_map owns the one difference in validation). An
# unmapped account is untouched, byte for byte. docs/configuration.md "Claude
# token source" owns the operator contract, and fm_worker_account_select owns
# which form wins when a pin has both a map line and a declaration file.
#
# A local secondmate whose primary home holds
# config/secondmate-accounts/<id>/<runner>-account launches from that directory
# instead (fm_worker_account_config): its pin file, pool, recorded-account rule,
# and claude-account-tokens map are read there, and the home-wide ones do not
# apply to that secondmate.
#
# The stored-login check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch sheds ambient credentials; a declared source supplies
# CLAUDE_CODE_OAUTH_TOKEN through the helper instead of the root's stored login.
# Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.
#
# A home that spends several Claude subscriptions declares them instead in
# config/claude-accounts: one entry per line, each `ordinary` or an absolute
# path exactly as config/claude-account would hold it, optionally followed by
# a tab and a config-local `claude-account-credential-source-<name>.json` file.
# The list has no blank lines, duplicate accounts, or other control characters, and
# an optional final newline. The list is opt-in in the same way: absent, nothing
# here changes. Present, it replaces the home-wide pin, which must then be
# absent, and every Claude ship or scout launch names one declared entry with
# --account; Firstmate chooses it at intake and never picks from file order. A
# selected entry's source file uses the shared credential-source schema, and
# the launch reads only that entry's source. The named entry passes the same
# root, raw-command, and sign-in refusals as a pin and is recorded as account=,
# which a ship or scout relaunch reuses unless an explicit --account moves it.
# A local secondmate's agent never draws from the list: it needs its own pin.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
# shellcheck source=bin/fm-credential-source-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-credential-source-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}
FM_WORKER_ACCOUNT_TOKEN_FILE=claude-account-tokens
FM_WORKER_ACCOUNT_CREDENTIAL_SOURCE_FILE=claude-account-credential-source.json

# fm_worker_account_has_credential_source <config-dir>
# Succeeds when <config-dir> holds a Claude credential-source declaration
# entry of any kind, including a dangling symlink.
fm_worker_account_has_credential_source() {
  [ -e "$1/$FM_WORKER_ACCOUNT_CREDENTIAL_SOURCE_FILE" ] || [ -L "$1/$FM_WORKER_ACCOUNT_CREDENTIAL_SOURCE_FILE" ]
}
FM_WORKER_ACCOUNT_TOKEN_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-claude-token.sh"

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# For Claude prints every declared entry, one per line, in file order; for Pi
# prints "declared<TAB>providers". An entry is `ordinary` or an absolute path.
# The final newline is optional; any other control byte, including a CR, is
# malformed. Parses bytes before the shell can drop NULs or trailing newlines;
# paths are literal, never shell expressions. Returns 0 on success, 3 when the
# file does not exist, 4 when it cannot be inspected (one error already
# printed), 5 when it is not a readable regular file, 6 when a single-line
# file is malformed, and 7 when a several-line Claude pool is malformed (a
# blank, invalid, or repeated line).
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      (my $lines = $body) =~ s/\n\z//;
      if ($lines !~ /\n/) {
        $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
        print $1, "\n";
      } else {
        my %seen;
        my @entries = split /\n/, $lines, -1;
        for (@entries) {
          /\A(?:ordinary|\/[^\x00-\x1f\x7f]*)\z/ or exit 7;
          $seen{$_}++ and exit 7;
        }
        print "$_\n" for @entries;
      }
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_config <harness> <config-dir> [<secondmate-id>]
# Prints the directory containing the applicable pin. A missing per-mate pin
# falls back to the home pin, except for Claude with an orphaned token source:
# that source must reach validation rather than silently inherit a login.
# Unreadable or malformed pins still select the override for parser refusal.
# Non-pinnable runners and ordinary workers keep the supplied directory unchanged.
fm_worker_account_config() {
  local harness=$1 config=$2 mate=${3:-} file candidate rc
  if [ -z "$mate" ] || ! file=$(fm_worker_account_file "$harness"); then
    printf '%s\n' "$config"
    return 0
  fi
  candidate="$config/secondmate-accounts/$mate"
  fm_worker_account_read "$harness" "$candidate/$file" >/dev/null
  rc=$?
  case "$rc" in
  3)
    if [ "$file" = claude-account ] && fm_worker_account_has_credential_source "$candidate"; then
      printf '%s\n' "$candidate"
    else
      printf '%s\n' "$config"
    fi
    ;;
  4) return 1 ;;
  *) printf '%s\n' "$candidate" ;;
  esac
}

# fm_worker_account_setting <harness> <home-config-dir> <selected-config-dir>
# Prints the name a refusal gives the selected pin file: config/<file> for the
# home pin, or the full path of a per-secondmate pin.
fm_worker_account_setting() {
  local file
  file=$(fm_worker_account_file "$1") || file=
  if [ "$3" = "$2" ]; then
    printf 'config/%s\n' "$file"
  else
    printf '%s/%s\n' "$3" "$file"
  fi
}

# fm_worker_account_token_source_parse <source>
# Prints "service<TAB>account<TAB>keychain-file" (the file empty for the
# default search list) for keychain:<service>/<account>[@<keychain-file>], where
# service and account are [A-Za-z0-9][A-Za-z0-9._-]* and the file is an
# absolute path without whitespace or control characters. Returns 1, silently,
# for anything else; this is the single owner of the source grammar.
fm_worker_account_token_source_parse() {
  local source=$1 rest service account keychain=
  case "$source" in
  keychain:*) ;;
  *) return 1 ;;
  esac
  rest=${source#keychain:}
  case "$rest" in
  *@*)
    keychain=${rest#*@}
    rest=${rest%%@*}
    [ -n "$keychain" ] || return 1
    ;;
  esac
  case "$rest" in
  */*) ;;
  *) return 1 ;;
  esac
  service=${rest%%/*}
  account=${rest#*/}
  [[ $service =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ $account =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  if [ -n "$keychain" ]; then
    [[ $keychain =~ ^/[^[:space:][:cntrl:]]+$ ]] || return 1
  fi
  printf '%s\t%s\t%s\n' "$service" "$account" "$keychain"
}

# fm_worker_account_token_read <file>
# Prints one "account<TAB>source" line per mapping of config/claude-account-tokens
# in file order; a line starting with # is a comment, which is how one mapping
# is disabled without deleting it. Same byte discipline as
# fm_worker_account_read. Returns 0 on
# success, 3 when the file does not exist, 4 when it cannot be inspected (one
# error already printed), 5 when it is not a readable regular file, and 6 when
# it is malformed, printing the reason instead of mappings; the source grammar
# is checked by the caller through fm_worker_account_token_source_parse.
fm_worker_account_token_read() {
  perl -MErrno=ENOENT -e '
    my ($f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    (my $lines = $body) =~ s/\n\z//;
    if ($lines eq "") { print "the file is empty"; exit 6 }
    my ($n, %seen, @out) = (0);
    for my $line (split /\n/, $lines, -1) {
      $n++;
      if ($line =~ /[\x00-\x1f\x7f]/) { print "line $n holds a control character"; exit 6 }
      if ($line eq "") { print "line $n is blank"; exit 6 }
      next if $line =~ /\A#/;
      if ($line !~ /\A(.+) ([^ ]+)\z/) { print "line $n is not <account> <source>"; exit 6 }
      my ($account, $source) = ($1, $2);
      if ($account !~ /\A(?:ordinary|\/.*)\z/) { print "line $n maps \x27$account\x27, which is neither ordinary nor an absolute path"; exit 6 }
      if ($seen{$account}++) { print "line $n maps \x27$account\x27 a second time"; exit 6 }
      push @out, "$account\t$source\n";
    }
    print @out;
  ' -- "$1"
}

# fm_worker_account_token_map <config-dir> <entries> [<setting>] [list]
# Validates config/claude-account-tokens against the declared Claude accounts
# (<entries> as fm_worker_account_entries prints them) and prints its
# "account<TAB>source" lines. Prints nothing and returns 0 when the home has no
# map. On refusal - an unreadable or malformed file, a map in a home with no
# config/claude-account, an undeclared or repeated account, or a source outside
# the grammar - prints one error naming the file and returns 1. <setting> names
# the pin file in that refusal (default config/claude-account).
# With the literal fourth argument `list` the map sits beside a
# config/claude-accounts list, whose entries it also covers: only the map's
# own form is validated, and a line for an account the list does not declare
# is inert rather than a refusal. A list names the account of every launch
# with --account, so such a line can never select a credential, and accounts
# rotate in and out of a list while their mapping stays ready.
fm_worker_account_token_map() {
  local config=$1 entries=$2 pin=${3:-config/claude-account} scope=${4:-} out rc account source entry found list=''
  local cfg="$config/$FM_WORKER_ACCOUNT_TOKEN_FILE" tokens
  tokens="${pin%/*}/$FM_WORKER_ACCOUNT_TOKEN_FILE"
  out=$(fm_worker_account_token_read "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: $tokens must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    echo "error: $tokens must hold one '<account> <source>' line per mapped Claude account - <account> a line of $pin exactly, one space, <source> keychain:<service>/<account>[@<keychain-file>] - with no blank lines or control characters ($out): $cfg" >&2
    return 1
    ;;
  esac
  if [ -z "$entries" ] && [ "$scope" != list ]; then
    echo "error: $tokens maps token sources onto $pin, which this home does not have; declare the accounts there first, or remove the token map: $cfg" >&2
    return 1
  fi
  # A file of comments only maps nothing.
  [ -n "$out" ] || return 0
  while IFS= read -r entry; do
    list="${list:+$list, }${entry%%$'\t'*}"
  done <<EOF_ENTRIES
$entries
EOF_ENTRIES
  while IFS=$'\t' read -r account source; do
    found=0
    while IFS= read -r entry; do
      if [ "${entry%%$'\t'*}" = "$account" ]; then
        found=1
        break
      fi
    done <<EOF_ENTRIES
$entries
EOF_ENTRIES
    if [ "$found" != 1 ] && [ "$scope" != list ]; then
      echo "error: $tokens maps '$account', which $pin does not declare (declared: $list); map a declared line exactly: $cfg" >&2
      return 1
    fi
    if ! fm_worker_account_token_source_parse "$source" >/dev/null; then
      echo "error: $tokens maps '$account' to '$source', which is not keychain:<service>/<account>[@<keychain-file>] (service and account: letters, digits, . _ -; the file: an absolute path without whitespace): $cfg" >&2
      return 1
    fi
  done <<EOF_MAP
$out
EOF_MAP
  printf '%s\n' "$out"
}

# fm_worker_account_token_source <config-dir> <declared>
# Prints the token source mapped to one declared Claude account, or nothing
# when the home has no map or the account is unmapped. Assumes the map was
# validated by fm_worker_account_entries on the way here; an unreadable map
# still returns 1 with its error.
fm_worker_account_token_source() {
  local config=$1 declared=$2 out rc line
  out=$(fm_worker_account_token_read "$config/$FM_WORKER_ACCOUNT_TOKEN_FILE")
  rc=$?
  case "$rc" in
  0) [ -n "$out" ] || return 0 ;;
  3) return 0 ;;
  *)
    # Unreachable after a validated pin unless the file changed underneath;
    # the map validator prints the same refusal it would have printed then.
    fm_worker_account_token_map "$config" "$declared" >/dev/null
    return 1
    ;;
  esac
  while IFS= read -r line; do
    if [ "${line%$'\t'*}" = "$declared" ]; then
      printf '%s\n' "${line##*$'\t'}"
      return 0
    fi
  done <<EOF_MAP
$out
EOF_MAP
  return 0
}

# fm_worker_account_entries <harness> <config-dir> [<setting>]
# Prints one "declared<TAB>root<TAB>providers" line per declared account of a
# valid pin, in file order, where root is the directory a launch on it selects
# (empty for ordinary Claude, meaning CLAUDE_CONFIG_DIR unset) and providers
# is empty for Claude. Prints nothing and returns 0 when the runner is not
# pinnable or the home has no pin. On refusal prints one error naming the file
# as <setting> (default config/<file>) and returns 1.
fm_worker_account_entries() {
  local harness=$1 config=$2 setting=${3:-} file cfg token rc declared root fallback providers='' result=''
  file=$(fm_worker_account_file "$harness") || return 0
  [ -n "$setting" ] || setting="config/$file"
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3)
    if [ "$file" = claude-account ] && fm_worker_account_has_credential_source "$config"; then
      echo "error: $config/$FM_WORKER_ACCOUNT_CREDENTIAL_SOURCE_FILE requires a Claude account pin: $cfg" >&2
      return 1
    fi
    # No pin: a token map left behind without it is a malformed pin, not a
    # silently ignored file, so a Claude home still refuses on one, unless a
    # config/claude-accounts list beside it is what the map covers.
    if [ "$harness" = claude ] && [ ! -e "$config/claude-accounts" ] && [ ! -L "$config/claude-accounts" ]; then
      fm_worker_account_token_map "$config" "" "$setting" >/dev/null || return 1
    fi
    return 0
    ;;
  4) return 1 ;;
  5)
    echo "error: $setting must be a readable regular file: $cfg" >&2
    return 1
    ;;
  7)
    echo "error: $setting must hold one account per line - 'ordinary' or an absolute path - each distinct, with no blank lines or control characters; the first line is this home's default account: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: $setting must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: $setting must hold 'ordinary' or one absolute path on a single line with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *)
    fallback='~/.pi/agent'
    providers=${token#*$'\t'}
    token=${token%%$'\t'*}
    ;;
  esac
  while IFS= read -r declared; do
    root=$declared
    if [ "$declared" = ordinary ]; then
      case "$harness" in
      claude) root= ;;
      *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
      esac
    fi
    if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
      echo "error: $setting must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
      return 1
    fi
    result="${result:+$result$'\n'}$declared	$root	$providers"
  done <<EOF_ENTRIES
$token
EOF_ENTRIES
  # A token map is part of the pin: a malformed one refuses every Claude
  # launch, like a broken pool, so no account can be selected around it.
  if [ "$harness" = claude ]; then
    fm_worker_account_token_map "$config" "$result" "$setting" >/dev/null || return 1
  fi
  printf '%s\n' "$result"
}

# fm_worker_account_resolve <harness> <config-dir> [<entry>] [<setting>]
# Prints "declared<TAB>root<TAB>providers" for the account a launch selects:
# the declared line exactly equal to <entry>, or the first line when <entry>
# is empty. Prints nothing and returns 0 when the runner is not pinnable or
# the home has no pin and no <entry> was asked for. On refusal - a malformed
# pin, an <entry> for a runner other than Claude, an <entry> in a home with
# no config/claude-account, or an <entry> the file does not declare - prints
# one error naming the pin file as <setting> (default config/claude-account)
# and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 entry=${3:-} setting=${4:-config/claude-account} entries line declared list=
  if [ -n "$entry" ] && [ "$harness" != claude ]; then
    echo "error: --account selects a declared line of $setting, so it applies only to Claude launches, not '${harness:-a raw launch command}'" >&2
    return 1
  fi
  entries=$(fm_worker_account_entries "$harness" "$config" "$setting") || return 1
  if [ -z "$entries" ]; then
    [ -z "$entry" ] && return 0
    echo "error: --account '$entry' needs config/claude-accounts, which this home does not declare, or $setting, which this home does not have; only the captain declares the accounts a home may launch Claude workers on: $config/claude-account" >&2
    return 1
  fi
  if [ -z "$entry" ]; then
    printf '%s\n' "${entries%%$'\n'*}"
    return 0
  fi
  while IFS= read -r line; do
    declared=${line%%$'\t'*}
    if [ "$declared" = "$entry" ]; then
      printf '%s\n' "$line"
      return 0
    fi
    list="${list:+$list, }$declared"
  done <<EOF_ENTRIES
$entries
EOF_ENTRIES
  echo "error: --account '$entry' is not declared in $setting (declared: $list); pass one declared line exactly: $config/claude-account" >&2
  return 1
}

# fm_worker_account_relaunch_entry <harness> <config-dir> <recorded-harness> <recorded-account> <explicit-entry> <task-id> [<secondmate-id>]
# Prints the Claude account a relaunch must name with --account, or nothing
# for the launch's ordinary selection. An explicit entry wins and is validated
# by the launch itself. Otherwise a Claude task recorded on a Claude account
# keeps it while a several-line config/claude-account pool still declares it;
# when the pool no longer declares it, prints one error naming the recorded
# account and the fix and returns 1, so the caller refuses before the running
# agent stops. A single-line pin, a home whose file is gone, another runner,
# or a task with no recorded Claude account prints nothing. A secondmate with
# its own per-secondmate pin (fm_worker_account_config) is judged against that
# pin's pool instead.
fm_worker_account_relaunch_entry() {
  local harness=$1 config=$2 recorded_harness=$3 recorded=$4 explicit=$5 id=$6 mate=${7:-} entries line list='' selected setting
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  [ "$harness" = claude ] && [ "$recorded_harness" = claude ] && [ -n "$recorded" ] || return 0
  selected=$(fm_worker_account_config claude "$config" "$mate") || return 1
  setting=$(fm_worker_account_setting claude "$config" "$selected")
  entries=$(fm_worker_account_entries claude "$selected" "$setting") || return 1
  [ "$entries" != "${entries%%$'\n'*}" ] || return 0
  while IFS= read -r line; do
    if [ "${line%%$'\t'*}" = "$recorded" ]; then
      printf '%s\n' "$recorded"
      return 0
    fi
    list="${list:+$list, }${line%%$'\t'*}"
  done <<EOF_ENTRIES
$entries
EOF_ENTRIES
  echo "error: task $id was launched on Claude account '$recorded', which $setting no longer declares (declared: $list); restore that line in $selected/claude-account, or relaunch with --account <entry> to move the task to a declared account deliberately" >&2
  return 1
}

# fm_worker_account_list <harness> <config-dir>
# Prints account entries from config/claude-accounts, preserving an optional
# tab-separated credential-source filename. Prints nothing for another runner
# or an absent list. On a malformed or unreadable list, prints one error.
fm_worker_account_list() {
  local harness=$1 cfg="$2/claude-accounts" out rc
  [ "$harness" = claude ] || return 0
  out=$(perl -MErrno=ENOENT -e '
    my ($f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    $body =~ /\A(?:(?:ordinary|\/[^\x00-\x1f\x7f]*)(?:\tclaude-account-credential-source-[A-Za-z0-9][A-Za-z0-9._-]*\.json)?\n)*(?:ordinary|\/[^\x00-\x1f\x7f]*)(?:\tclaude-account-credential-source-[A-Za-z0-9][A-Za-z0-9._-]*\.json)?\n?\z/ or exit 6;
    my %seen;
    for my $entry (split /\n/, $body) {
      my ($account) = split /\t/, $entry, 2;
      exit 7 if $seen{$account}++;
      print $entry, "\n";
    }
  ' -- "$cfg")
  rc=$?
  case "$rc" in
  0) printf '%s\n' "$out" ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/claude-accounts must be a readable regular file: $cfg" >&2
    return 1
    ;;
  7)
    echo "error: config/claude-accounts declares the same account twice: $cfg" >&2
    return 1
    ;;
  *)
    echo "error: config/claude-accounts must hold one 'ordinary' or absolute-path account per line, optionally followed by a tab and claude-account-credential-source-<name>.json; no blank lines or control characters: $cfg" >&2
    return 1
    ;;
  esac
}

# fm_worker_account_relaunch_request <harness> <config-dir> <prior-harness> <recorded-account> <explicit-account> [<secondmate-id>] [<task-id>]
# Prints the declared account a relaunch asks fm_worker_account_select for:
# the explicit one when given; otherwise, when the home declares
# config/claude-accounts and a Claude ship or scout stays on Claude, the
# task's recorded account; otherwise the recorded account a several-line
# config/claude-account pool still declares (fm_worker_account_relaunch_entry,
# which also judges a secondmate against its own pin). <prior-harness> is the
# recorded harness family. Prints nothing otherwise, so a relaunch re-reads a
# single-line pin exactly as before. Returns 1 when the explicit account holds
# a control character, the list cannot be read, or the pool no longer declares
# the recorded account.
fm_worker_account_relaunch_request() {
  local harness=$1 config=$2 prior=$3 recorded=$4 explicit=$5 mate=${6:-} id=${7:-} listed
  fm_worker_account_request_valid "$explicit" || return 1
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -z "$mate" ]; then
    listed=$(fm_worker_account_list "$harness" "$config") || return 1
    if [ -n "$listed" ]; then
      [ "$prior" = claude ] || return 0
      printf '%s\n' "$recorded"
      return 0
    fi
  fi
  fm_worker_account_relaunch_entry "$harness" "$config" "$prior" "$recorded" "" "$id" "$mate"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_credential_source_file <config-dir> [<filename>]
# Prints the checked Claude credential-source declaration path, or nothing
# when this account uses the selected root's stored login.
fm_worker_account_credential_source_file() {
  local config=$1 filename=${2:-$FM_WORKER_ACCOUNT_CREDENTIAL_SOURCE_FILE} path source problem
  if [ "$filename" = "$FM_WORKER_ACCOUNT_CREDENTIAL_SOURCE_FILE" ]; then
    fm_worker_account_has_credential_source "$config" || return 0
  elif [[ ! "$filename" =~ ^claude-account-credential-source-[A-Za-z0-9][A-Za-z0-9._-]*\.json$ ]]; then
    echo "error: invalid Claude credential-source filename: $filename" >&2
    return 1
  fi
  path="$config/$filename"
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    echo "error: $path must be a readable regular file" >&2
    return 1
  fi
  problem=$(fm_credsrc_check "$path" claude) || {
    echo "error: malformed $path - $problem" >&2
    return 1
  }
  source=$(fm_credsrc_field "$path" claude source)
  fm_credsrc_supported "$source" || {
    echo "error: $path declares unsupported source $source on this host" >&2
    return 1
  }
  printf '%s\n' "$path"
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>] [<token-source>] [<config-dir>] [<setting>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1. For a Claude
# account with a <token-source> - a config/claude-account-tokens reference
# (keychain:...) or the path of a checked credential-source declaration - the
# check runs under that token (bin/fm-claude-token.sh exec) and passes only
# when `claude auth status` reports loggedIn with authMethod oauth_token; it
# does not validate the token remotely. A source that cannot be loaded, or a
# runner that answers with another method, refuses without consulting the
# root's stored login. <config-dir> only names the map file in that refusal,
# and <setting> names the pin file (default config/<file>) in every refusal.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} source=${6:-} config=${7:-} setting=${8:-} out verdict name rc method cfg='' tokens
  [ -n "$setting" ] || setting="config/$(fm_worker_account_file "$harness")"
  tokens="${setting%/*}/$FM_WORKER_ACCOUNT_TOKEN_FILE"
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  case "$harness" in
  claude)
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if [ -n "$source" ]; then
      out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$FM_WORKER_ACCOUNT_TOKEN_HELPER" exec "$source" -- "$executable" auth status </dev/null)
      rc=$?
      method=
      if [ "$rc" -eq 0 ]; then
        method=$(printf '%s\n' "$out" | jq -r 'if type == "object" and .loggedIn == true then (.authMethod // "") else "" end' 2>/dev/null)
        [ "$method" != oauth_token ] || return 0
      fi
      case "$source" in
      keychain:*)
        # A config/claude-account-tokens reference.
        [ -z "$config" ] || cfg=": $config/$FM_WORKER_ACCOUNT_TOKEN_FILE"
        if [ "$rc" -eq 0 ]; then
          echo "error: $tokens maps Claude account '$declared' to $source, but claude auth status reports authMethod '${method:-none}' instead of oauth_token, so the launch would spend the account's stored login rather than the token; check the installed claude, or remove the mapping$cfg" >&2
        elif [ "$rc" -eq 3 ]; then
          echo "error: $tokens maps Claude account '$declared' to $source, but its token could not be loaded (the reason is above); the launch never falls back to the account's stored login - fix the Keychain item or the mapping$cfg" >&2
        elif fm_timed_out "$rc"; then
          echo "error: $tokens maps Claude account '$declared' to $source, but the sign-in check under that token timed out after ${FM_WORKER_ACCOUNT_CHECK_SECONDS}s; the launch never falls back to the account's stored login$cfg" >&2
        else
          echo "error: $tokens maps Claude account '$declared' to $source, but claude auth status does not accept that token as a login (exit $rc); the launch never falls back to the account's stored login - re-create the token with claude setup-token and re-import it$cfg" >&2
        fi
        ;;
      *)
        # A credential-source declaration file.
        if [ "$rc" -eq 0 ]; then
          echo "error: $source maps the pinned Claude account to a token source, but claude auth status did not confirm authMethod oauth_token; the launch never falls back to the stored login" >&2
        elif [ "$rc" -eq 3 ]; then
          echo "error: $source token could not be loaded; the launch never falls back to the stored login" >&2
        elif fm_timed_out "$rc"; then
          echo "error: $source sign-in check timed out; the launch never falls back to the stored login" >&2
        else
          echo "error: $source token did not load as Claude's auth method (claude auth status exit $rc); the launch never falls back to the stored login" >&2
        fi
        ;;
      esac
      return 1
    fi
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: $setting pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: $setting pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: $setting pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_request_valid <account>
# Refuses an --account value holding a control character. Declared entries
# never hold one, and a newline would otherwise split the value before the
# whole-entry membership check or the account= record sees it.
fm_worker_account_request_valid() {
  case "$1" in
  *[[:cntrl:]]*)
    echo "error: --account must name one config/claude-accounts entry exactly, with no control characters (or, without that list, one config/claude-account line)" >&2
    return 1
    ;;
  esac
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command>] [<secondmate-id>] [<account>]
# The whole launch-time decision. A local secondmate's own per-secondmate pin
# replaces the home pin (fm_worker_account_config). <account> names one declared
# Claude account: under a config/claude-accounts list it is the entry a Claude
# ship or scout must name; otherwise it is one line of a config/claude-account
# pool (fm_worker_account_resolve), and empty selects the first line. Prints
# nothing for an unpinned runner, so the caller keeps today's launch unchanged.
# For a pinned one prints "declared<TAB>root<TAB>provider<TAB>token-source",
# where provider is the Pi launch model's own (empty for Claude) and
# token-source is what bin/fm-claude-token.sh loads the Claude account's token
# from (empty for Pi and for an account that spends its stored login), after
# the model guard and the sign-in check pass. On refusal prints one error and
# returns 1. bin/fm-spawn.sh runs it before any endpoint exists, and
# bin/fm-control.sh before a relaunch stops the live agent.
#
# A Claude account's token source has two declared forms, and one launch path
# serves both. config/claude-account-tokens maps an account - a
# config/claude-account pin or pool line, or a config/claude-accounts entry -
# to a keychain: reference. A credential-source declaration file is the other
# form: config/claude-account-credential-source.json beside a single-line pin,
# or the file a config/claude-accounts entry names after its tab. When one
# account has both, the map line wins: it names that account explicitly and
# carries the richer source, while a declaration file is bound to its account
# only by position; a note on stderr says the declaration was not used, and it
# is still validated, so a malformed one refuses. A commented-out map line
# maps nothing, so the declaration then applies. A several-line pool refuses a
# declaration file beside it, because that file cannot say which line it is
# for.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} mate=${6:-} account=${7:-}
  local selection declared root providers word provider='' source='' selected_config setting listed count source_name='' source_file='' pool
  fm_worker_account_request_valid "$account" || return 1
  if [ -n "$account" ] && [ "$harness" != claude ]; then
    echo "error: --account names one declared Claude account and applies to Claude workers only, not ${harness:-a raw launch command}" >&2
    return 1
  fi
  listed=$(fm_worker_account_list "$harness" "$config") || return 1
  if [ -n "$listed" ] && [ -n "$account" ] && [ -n "$mate" ]; then
    echo "error: --account applies to ships and scouts under config/claude-accounts; secondmate $mate launches on its own config/secondmate-accounts/$mate/claude-account pin" >&2
    return 1
  fi
  if [ -n "$listed" ] && { [ -e "$config/claude-account" ] || [ -L "$config/claude-account" ]; }; then
    echo "error: config/claude-accounts and config/claude-account are both present; keep the account list or the single pin, not both" >&2
    return 1
  fi
  selected_config=$(fm_worker_account_config "$harness" "$config" "$mate") || return 1
  setting=$(fm_worker_account_setting "$harness" "$config" "$selected_config")
  if [ -n "$listed" ] && [ -n "$mate" ] && [ "$selected_config" = "$config" ]; then
    echo "error: config/claude-accounts chooses accounts for ships and scouts only; secondmate $mate needs its own pin in config/secondmate-accounts/$mate/claude-account" >&2
    return 1
  elif [ -n "$listed" ] && [ -z "$mate" ]; then
    setting=config/claude-accounts
    # The token map covers a list's entries too; a malformed one refuses every
    # Claude launch, like a malformed list.
    fm_worker_account_token_map "$config" "" "$setting" list >/dev/null || return 1
    if [ -z "$account" ]; then
      count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
      echo "error: config/claude-accounts declares $count Claude accounts, so a Claude ship or scout launch must name one with --account; bin/fm-claude-account-quota.sh measures each, and Firstmate never picks a default" >&2
      return 1
    fi
    declared=
    while IFS= read -r word; do
      [ "${word%%$'\t'*}" != "$account" ] || {
        declared=$account
        [[ "$word" == *$'\t'* ]] && source_name=${word#*$'\t'}
        break
      }
    done <<< "$listed"
    [ -n "$declared" ] || {
      echo "error: account '$account' is not declared in config/claude-accounts; name a declared entry with --account" >&2
      return 1
    }
    declared=$account
    root=$account
    [ "$declared" != ordinary ] || root=
    if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
      # shellcheck disable=SC2088  # Literal text for the refusal.
      echo "error: $setting must name readable, searchable existing directories (ordinary means ~/.claude with CLAUDE_CONFIG_DIR unset): $root" >&2
      return 1
    fi
    providers=
  else
    selection=$(fm_worker_account_resolve "$harness" "$selected_config" "$account" "$setting") || return 1
    if [ -z "$selection" ]; then
      [ "$selected_config" = "$config" ] && return 0
      echo "error: secondmate account pin disappeared during selection: $setting" >&2
      return 1
    fi
    declared=${selection%%$'\t'*}
    root=${selection#*$'\t'}
    providers=${root#*$'\t'}
    root=${root%%$'\t'*}
  fi
  if [ "$harness" = claude ]; then
    if [ -n "$listed" ] && [ -z "$mate" ]; then
      if fm_worker_account_has_credential_source "$selected_config"; then
        echo "error: $selected_config/$FM_WORKER_ACCOUNT_CREDENTIAL_SOURCE_FILE applies to one config/claude-account pin, not config/claude-accounts" >&2
        return 1
      fi
      if [ -n "$source_name" ]; then
        source_file=$(fm_worker_account_credential_source_file "$selected_config" "$source_name") || return 1
      fi
    else
      source_file=$(fm_worker_account_credential_source_file "$selected_config") || return 1
      if [ -n "$source_file" ]; then
        pool=$(fm_worker_account_entries "$harness" "$selected_config" "$setting") || return 1
        if [ "$pool" != "${pool%%$'\n'*}" ]; then
          echo "error: $source_file applies to a single-line Claude account pin, but $setting declares several accounts, so it cannot say which one it is for; map each account in ${setting%/*}/$FM_WORKER_ACCOUNT_TOKEN_FILE instead, or remove the file" >&2
          return 1
        fi
      fi
    fi
    source=$(fm_worker_account_token_source "$selected_config" "$declared") || return 1
    if [ -z "$source" ]; then
      source=$source_file
    elif [ -n "$source_file" ]; then
      echo "note: ${setting%/*}/$FM_WORKER_ACCOUNT_TOKEN_FILE maps Claude account '$declared' to $source, so $source_file is not used for this launch" >&2
    fi
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
        *" ${word%%=*} "*)
          echo "error: $setting pins Claude workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove $setting" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
  else
    if [ -n "$raw" ]; then
      echo "error: $setting pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: $setting pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: $setting pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
  fi
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" "$source" "$selected_config" "$setting" || return 1
  printf '%s\t%s\t%s\t%s\n' "$declared" "$root" "$provider" "$source"
}

# fm_worker_account_claude_shed [<token-source>]
# Prints the `env` launch prefix that unsets ambient credentials which could
# override the pin. With a token source, it preserves the OAuth variable the
# token helper sets; the caller appends the pinned root or unsets
# CLAUDE_CONFIG_DIR for the ordinary Claude account.
fm_worker_account_claude_shed() {
  local token_source=${1:-} var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    [ "$var" != CLAUDE_CODE_OAUTH_TOKEN ] || [ -z "$token_source" ] || continue
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
