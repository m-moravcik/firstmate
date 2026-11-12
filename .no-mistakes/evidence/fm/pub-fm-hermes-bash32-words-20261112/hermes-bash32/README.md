# Hermes Bash 3.2 live validation

The authoritative acceptance criterion is that empty argv is a clean non-match under macOS Bash 3.2 with nounset. The process-identity contract in docs/verification/hermes.md (Foreground process liveness) and the existing Hermes harness regression examples supplies the positive and adversarial oracles: the supported Node entry and Python module shapes identify an agent; an unrelated Node eval carrying the entry path is ambiguous.

The driver ran the real Firstmate tmux backend against a private, 120x30 session, using a locally compiled tmux 3.5a and libevent 2.1.12. It compared the baseline library from a02b089835a114844cc53d0429570155dfe4ef3a with target 9a382a512480e91fa86675b5f005715f33dc4093. No product source was edited.

The idle pane reproduces the real macOS no-/proc fallback: the backend passes empty args plus the real foreground PID. Baseline exits 127 with words[@]: unbound variable. Target returns dead, status 0, and no stderr. The trace excerpt confirms that this exact empty-argv path executed.

Positive input processes are a real Node runtime executing a synthetic ui-tui/dist/entry.js and a native sleep-only argv carrier launched as python3 -m tui_gateway.entry. The latter supplies synthetic process-identity input; it is not a Python interpreter or Hermes CLI. Both yield alive. A real Node eval process carrying the same entry path as a later argument yields ambiguous. These are local parser/liveness proofs, not a real Hermes application or login validation.

Exploratory Homebrew and Apple Python launchers exposed uppercase Python argv, outside the existing lowercase matcher contract, so they were unsuitable carriers for the supported python3 shape. No widening of this narrowly approved fix was made. Native empty-argv and short-lived-process ancestry explorations did not reproduce the failure; the real tmux idle path did. A first trace collection had a Python UTF-8 decoding failure; the driver now tolerates non-UTF-8 Bash xtrace bytes and completed with exit 0.

The focused empty-input regression was also executed directly against both libraries: baseline exits 127, target returns non-match status 1 and the shell continues. The private server and all four pane PIDs were confirmed stopped before completion. Build dependencies and runtime fixtures were removed from the worktree after testing. No full suite, linter, formatter, pipeline control, push or PR action was run.
