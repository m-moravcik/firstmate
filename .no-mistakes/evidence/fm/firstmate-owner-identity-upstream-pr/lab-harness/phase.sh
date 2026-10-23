#!/usr/bin/env bash
# phase.sh <name> <ABSENT|DIRECTORY|content-file> <watch-seconds> [base]: one real watcher cycle in the lab, evidence to the evidence dir.
set -u
LAB=/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0
ROOT=~/.no-mistakes/worktrees/38ab7cb04e39/01M5M5NXPGRYZC4CSDVTA3CPA6
EVD=~/.no-mistakes/evidence/01M5M5NXPGRYZC4CSDVTA3CPA6
R="${FMLAB_LABENV:-$LAB/harness/labenv.sh}"; H="$LAB/harness"
name=$1 mode=$2 secs=$3 tree=${4:-$ROOT}
cfg="$LAB/config/github-owner-accounts"
rm -rf -- "$cfg"
case "$mode" in ABSENT) ;; DIRECTORY) mkdir "$cfg" ;; *) cp -- "$mode" "$cfg" ;; esac
: > "$H/requests.jsonl"; : > "$H/gh-argv.log"
cd "$tree" || exit 1
"$H/drain.sh" >/dev/null
started=$(date -u +%H:%M:%SZ)
"$R" env FM_POLL=60 FM_CHECK_INTERVAL=1 "$tree/bin/fm-watch.sh" > "$H/watch.out" 2> "$H/watch.err" &
wp=$!
for _ in $(seq 1 "$secs"); do kill -0 "$wp" 2>/dev/null || break; sleep 1; done
if kill -0 "$wp" 2>/dev/null; then
  kill "$wp"; wait "$wp" 2>/dev/null
  verdict="watcher absorbed the cycle and kept blocking (no wake within ${secs}s); stopped by its recorded pid $wp"
else
  wait "$wp"; verdict="watcher exited rc=$? with a wake"
fi
. "$H/tokens.env"
mask() { sed -e "s/$FMLAB_ACME_TOKEN/<acme-token>/g" -e "s/$FMLAB_PERSONAL_TOKEN/<personal-token>/g"; }
{
  printf '## Phase %s (%s, scripts from %s)\n\n' "$name" "$started" "$tree"
  printf '### config/github-owner-accounts\n'
  if [ -d "$cfg" ]; then echo '(a directory, not a file)'; elif [ -e "$cfg" ]; then LC_ALL=C sed -n 'l' "$cfg" | sed 's/^/    /'; else echo '(absent)'; fi
  printf '\n### Watcher (bin/fm-watch.sh) result\n%s\n' "$verdict"
  sed 's/^/    /' "$H/watch.out"
  [ ! -s "$H/watch.err" ] || { echo 'stderr:'; sed 's/^/    /' "$H/watch.err"; }
  printf '\n### gh command lines the observer ran (argv as received by the gh router)\n'
  sed 's/^/    /' "$H/gh-argv.log"
  printf '\n### Requests the fake GitHub received from the real gh (identity = Authorization header)\n'
  jq -r '"    \(.method) \(.path) as=\(.identity) -> \(.status)  token-in-any-argv=\(.token_in_any_argv) token-in-product-tmp-file=\(.token_in_product_tmp_file) live-observer-tmp=\(.product_tmp_dirs_scanned | join(","))"' "$H/requests.jsonl"
  printf '\n### Saved contribution records\n'
  for t in acme-fix personal-fix; do
    jq -c --arg t "$t" '.records[0] | {task:$t,url,error,checked_at,head:.observation.head,state:.observation.state,can_merge:.observation.can_merge,retired}' "$LAB/data/$t/contributions.json" | sed 's/^/    /'
  done
  printf '\n### Bearings contributions (captain-facing)\n'
  "$R" "$tree/bin/fm-bearings-snapshot.sh" --json | jq -c '.contributions | {known,checked,counts,complete,captain:[.captain[] | {task,url,reason}]}' | sed 's/^/    /'
  printf '\n### gh active account file unchanged?\n'
  if shasum -a 256 -c "$H/hosts.sha.before" >/dev/null 2>&1; then echo '    hosts.yml sha256 matches the pre-run snapshot (active account fmlab-personal unchanged)'; else echo '    hosts.yml CHANGED'; fi
  leaked=$(grep -rlF -e "$FMLAB_ACME_TOKEN" -e "$FMLAB_PERSONAL_TOKEN" "$LAB" 2>/dev/null | grep -v -e '/ghconfig/hosts.yml$' -e '/harness/tokens.env$' | tr '\n' ' ')
  printf '    lab files holding a lab token outside the gh store and the harness token file: %s\n' "${leaked:-none}"
} | mask > "$EVD/phase-$name.txt"
cat "$EVD/phase-$name.txt"
