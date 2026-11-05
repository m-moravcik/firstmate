#!/usr/bin/env bash
export FM_HOME=~/.no-mistakes/evidence/01M6PE6P3PVADA0A483VFFTGJX/local-api-fixtures-proof/invalid-account-leading-hyphen
export FM_STATE_OVERRIDE=~/.no-mistakes/evidence/01M6PE6P3PVADA0A483VFFTGJX/local-api-fixtures-proof/invalid-account-leading-hyphen/state
export FM_DATA_OVERRIDE=~/.no-mistakes/evidence/01M6PE6P3PVADA0A483VFFTGJX/local-api-fixtures-proof/invalid-account-leading-hyphen/data
export FM_CONFIG_OVERRIDE=~/.no-mistakes/evidence/01M6PE6P3PVADA0A483VFFTGJX/local-api-fixtures-proof/invalid-account-leading-hyphen/config
export FM_CONTRIBUTIONS_BUDGET=25
export FM_CONTRIBUTIONS_REPLY_AGE=300
exec {run-worktree}/bin/fm-contributions.sh poll
