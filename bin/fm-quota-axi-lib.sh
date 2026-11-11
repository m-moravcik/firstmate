# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, the
# --json snapshot validator, and the provider-row join dispatch consumers use.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns an absent binary into the operator-facing MISSING diagnostic and an
# incompatible installed build into OUTDATED, which keeps an older build from
# reaching a dispatch intake at all.
#
# Snapshot schemas: fm_quota_json_valid accepts quota-axi schema 5 (one row per
# provider, no accountKey) and schema 6 (every row carries accountKey, unique on
# provider + accountKey; quota-axi emits it once any provider expands to more
# than one account). Schema 5 keeps its exact pre-schema-6 rules so an older
# quota-axi keeps working unchanged. FM_QUOTA_ROW_JQ is the one join used to
# bind a candidate to its row under either schema.

FM_QUOTA_AXI_MIN=0.1.51
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

# The eligibility section of .agents/skills/quota-array-dispatch/SKILL.md
# owns the account-matching contract these jq definitions implement.
# Prepend them to a consumer's program:
#   quota_lane($harness; $model)   the candidate's account key, or "" when none
#                                  is identified by the contract.
#   quota_row($snapshot; $provider; $lane)
#                                  the one provider row the candidate binds to,
#                                  or null; schema 5 ignores $lane.
#   quota_family_scope($provider; $model)
#                                  the one quota-axi model scope a full model id
#                                  is evidenced to draw on beyond its own
#                                  `model:<id>`, or "" when none is evidenced.
#                                  quota-axi names a Claude model window
#                                  `model:<vendor model id>` (its README: "model-scoped
#                                  ones (e.g. Fable) as a `model:<slug>` window"), and
#                                  the Fable window is `model:fable`, labelled "Fable
#                                  week", while Claude Code takes `fable` as the
#                                  alias for the Fable family and a full name such
#                                  as claude-fable-5-1 for one version of it
#                                  (`claude --help`, --model). Only that family is
#                                  mapped; a model with no evidenced scope here
#                                  keeps its caller's all_models fallback, and
#                                  no mapping is derived for another family.
#   quota_claude_entry_lane($lanes; $entry; $home)
#                                  the one schema-6 claude lane a declared
#                                  Claude account entry binds to through its
#                                  --full accountLocator, or null:
#                                  `ordinary` is the lane whose keychainService
#                                  is exactly the unsuffixed
#                                  `Claude Code-credentials` store, or, on a
#                                  host whose lanes carry no keychainService at
#                                  all, the lane at $home/.claude; a path is the
#                                  lane at exactly that path whose
#                                  keychainService is not the unsuffixed store.
#   quota_claude_weekly($row; $max_age)
#                                  {used, why}: the lane's `seven_day` window
#                                  percentUsed when the lane is fresh, not
#                                  stale, and its state.refreshedAt is at most
#                                  $max_age seconds old (and not over 60 s in
#                                  the future); otherwise used is null and why
#                                  says which of those failed. A reused reading
#                                  is judged by its own refreshedAt.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_ROW_JQ='
  def quota_family_scope($provider; $model):
    if $provider == "claude" and (($model // "") | test("^claude-fable-[0-9]")) then "model:fable"
    else "" end;
  def quota_claude_entry_lane($lanes; $entry; $home):
    if $entry == "ordinary" then
      if ([$lanes[] | .accountLocator.keychainService? // empty] | length) > 0 then
        [$lanes[] | select(.accountLocator.keychainService? == "Claude Code-credentials")] | first
      else
        [$lanes[] | select(.accountLocator.path? == ($home + "/.claude"))] | first
      end
    else
      [$lanes[] | select(.accountLocator.path? == $entry and
        (.accountLocator.keychainService? // "") != "Claude Code-credentials")] | first
    end;
  def quota_claude_weekly($row; $max_age):
    ($row.state.refreshedAt? // null) as $at_text |
    (if ($at_text | type) == "string"
     then (try ($at_text | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null)
     else null end) as $at |
    ([($row.windows? // [])[]? | select(.id? == "seven_day")] | first) as $week |
    if $row == null then {used: null, why: "no quota-axi lane carries a locator for this account"}
    elif ($row.state.status? // "unknown") != "fresh" or $row.state.stale? == true then
      {used: null, why: "its quota-axi lane status is \($row.state.status? // "unknown")\(if $row.state.stale? == true then " and stale" else "" end)"}
    elif $at == null then {used: null, why: "its lane carries no readable refreshedAt"}
    elif (now - $at) > $max_age then {used: null, why: "its reading from \($at_text) is older than \($max_age)s"}
    elif (now - $at) < -60 then {used: null, why: "its reading is dated in the future (\($at_text))"}
    elif ($week.percentUsed? | type) != "number" then {used: null, why: "its lane reports no seven_day percentUsed"}
    else {used: $week.percentUsed, why: "seven_day \($week.percentUsed)% used, refreshedAt \($at_text)"}
    end;
  def quota_lane($harness; $model):
    if $harness == "codex" then "codex-home"
    elif ($harness == "pi" or $harness == "pi-signed") and (($model // "") | contains("/"))
    then ($model | split("/") | first | if . == "codex-native" then "codex-home" else . end)
    else "" end;
  def quota_row($snapshot; $provider; $lane):
    ([$snapshot.providers[]? | select(.provider == $provider)]) as $rows |
    if $snapshot.schemaVersion == 6 then
      (([$rows[] | select(.accountKey == $lane)] | first) //
       ([$rows[] | select(.accountKey == "default")] | first) // null)
    else ($rows | first) // null
    end;
'

# fm_quota_axi_version_compatible <version-output>
# True when the printed `quota-axi --version` text meets FM_QUOTA_AXI_MIN.
# Callers that already captured a bounded --version pass that text here so they
# do not launch a second, unbounded version probe.
fm_quota_axi_version_compatible() {
  local output=${1-} parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  fm_quota_axi_version_compatible "$output"
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      (.providers | type) == "array" and
      (if .schemaVersion == 5 then
         (([.providers[].provider] | length) == ([.providers[].provider] | unique | length))
       elif .schemaVersion == 6 then
         all(.providers[];
           (.accountKey | type) == "string" and
           (.accountKey | length) > 0 and
           ((.accountKey | test("\\s")) | not)) and
         (([.providers[] | [.provider, .accountKey]] | length) ==
          ([.providers[] | [.provider, .accountKey]] | unique | length))
       else false
       end) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

# Claude quota readings from another process or machine.
# Quota is per account, not per machine, but a Claude lane quota-axi cannot read
# here (a login keychain locked to this session, or no stored login) reports a
# non-fresh state. fm_quota_reuse_readings lets a consumer measure such a lane
# from a recent token-free `quota-axi --provider claude --full --json` reading
# that a refresher on this host, or another host, left in a file.
#   FM_CLAUDE_QUOTA_READINGS          path-delimiter (:) list of reading files or
#                                     globs; default
#                                     $HOME/.local/state/quota-axi-refresh/*.json;
#                                     set but empty disables reuse.
#   FM_CLAUDE_QUOTA_READING_MAX_AGE   seconds a reading's lane refreshedAt may
#                                     trail now; default 600.
# Reading files hold only quota-axi's own token-free output; this code never
# reads, prints, or stores a credential.

FM_CLAUDE_QUOTA_READING_DEFAULT_MAX_AGE=600

# fm_quota_reading_files
# Print each existing regular file the reading list names, one per line.
fm_quota_reading_files() {
  (
    local spec=${FM_CLAUDE_QUOTA_READINGS-${HOME:-}/.local/state/quota-axi-refresh/*.json}
    local -a patterns
    local pattern file
    shopt -s nullglob
    IFS=: read -r -a patterns <<< "$spec"
    # An empty IFS keeps a space inside a path from splitting; globbing still runs.
    IFS=
    for pattern in "${patterns[@]}"; do
      [ -n "$pattern" ] || continue
      for file in $pattern; do
        [ -f "$file" ] && printf '%s\n' "$file"
      done
    done
  )
}

# fm_quota_reuse_readings
# Reads one live quota-axi --full --json snapshot on stdin and prints it with
# every Claude lane that is not fresh replaced by the freshest reading of the
# same account, else unchanged. A reading lane applies only when it is `fresh`,
# its accountLocator.path equals the live lane's, its state.refreshedAt is at
# most the max age old (and not in the future beyond 60 s of clock skew), and,
# when both sides carry an account identity, that identity matches: accountId
# when both have one, else email, and differing kinds do not match. A live fresh
# lane always wins. The replacement keeps the live lane's accountKey, accountKeys,
# and accountLocator and adds quotaReuse {file, refreshedAt, lane} as provenance.
# Any failure leaves the live snapshot exactly as read.
fm_quota_reuse_readings() {
  local live max_age=${FM_CLAUDE_QUOTA_READING_MAX_AGE:-$FM_CLAUDE_QUOTA_READING_DEFAULT_MAX_AGE}
  local file one readings='' merged
  live=$(cat)
  case "$max_age" in
    ''|*[!0-9]*|0) max_age=$FM_CLAUDE_QUOTA_READING_DEFAULT_MAX_AGE ;;
  esac
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    one=$(jq -sc --arg file "$file" '
      if length == 1 and (.[0] | type) == "object" and (.[0].providers | type) == "array" then
        {file: $file, lanes: [.[0].providers[] | select(type == "object" and .provider == "claude")]}
      else empty end
    ' "$file" 2>/dev/null) || continue
    [ -z "$one" ] || readings="${readings:+$readings,}$one"
  done < <(fm_quota_reading_files)
  if [ -n "$readings" ] &&
    merged=$(printf '%s\n' "$live" | jq -c --argjson readings "[$readings]" --argjson max "$max_age" '
      def epoch: try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;
      def identity: (.account // {}) as $a |
        if (($a.accountId // "") | tostring | length) > 0 then ["accountId", ($a.accountId | tostring)]
        elif (($a.email // "") | tostring | length) > 0 then ["email", ($a.email | tostring | ascii_downcase)]
        else null end;
      def same_account($live; $reading):
        ($live | identity) as $l | ($reading | identity) as $r |
        $l == null or $r == null or $l == $r;
      def usable($lane):
        ($lane.accountLocator.path? // "") as $path |
        [$readings | to_entries[] | .key as $order | .value as $reading |
          $reading.lanes[] |
          select((.state.status? // "") == "fresh" and
                 (.accountLocator.path? // null) == $path and
                 same_account($lane; .)) |
          (.state.refreshedAt? | if type == "string" then epoch else null end) as $at |
          select($at != null and (now - $at) <= $max and (now - $at) >= -60) |
          {lane: ., at: $at, order: $order, file: $reading.file}] |
        sort_by([.at, -.order]) | last;
      if (.providers | type) != "array" then .
      else .providers |= map(
        if type == "object" and .provider == "claude" and (.state.status? // "unknown") != "fresh" and
           (.accountLocator.path? // "") != "" then
          . as $live_lane | (usable($live_lane)) as $hit |
          if $hit == null then .
          else $hit.lane + {accountKey: $live_lane.accountKey, accountLocator: $live_lane.accountLocator} +
            (if $live_lane | has("accountKeys") then {accountKeys: $live_lane.accountKeys} else {} end) +
            {quotaReuse: {file: $hit.file, refreshedAt: $hit.lane.state.refreshedAt, lane: $hit.lane.accountKey}}
          end
        else . end)
      end
    ' 2>/dev/null) && printf '%s\n' "$merged" | fm_quota_json_valid; then
    printf '%s\n' "$merged"
  else
    printf '%s\n' "$live"
  fi
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

# Reads the whole table before answering: leaving the loop early closes the
# pipe mid-write, and where SIGPIPE is ignored the writer prints a broken-pipe
# error on stderr.
fm_quota_single_provider_for_harness() {
  local harness provider found=''
  while read -r harness provider; do
    [ -z "$found" ] && [ "$harness" = "$1" ] && found=$provider || :
  done < <(fm_quota_single_provider_table)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_quota_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *)               return 1 ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}
