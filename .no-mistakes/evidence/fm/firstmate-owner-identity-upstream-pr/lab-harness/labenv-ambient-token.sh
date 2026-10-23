#!/usr/bin/env bash
# Run one command as this lab home's firstmate would: lab FM_HOME, lab gh config, routed gh, no fleet overrides.
set -a; . /var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0/harness/tokens.env; set +a; export GH_TOKEN="$FMLAB_PERSONAL_TOKEN" OWNER_GH_TOKEN="$FMLAB_ACME_TOKEN"; unset FMLAB_ACME_TOKEN FMLAB_PERSONAL_TOKEN
exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u GITHUB_TOKEN -u GH_HOST -u TMUX \
  PATH="/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0/fakebin:$PATH" FM_HOME="/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0" TMUX_TMPDIR="/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0/tmux" GH_CONFIG_DIR="/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0/ghconfig" \
  FMLAB_PROXY="http://127.0.0.1:63614" TMPDIR="/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0/tmp" FMLAB_ARGV_LOG="/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0/harness/gh-argv.log" "$@"
