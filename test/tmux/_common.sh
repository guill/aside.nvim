#!/usr/bin/env bash
# Shared helpers for tmux scenario scripts.
# Sourced by every aside_*.sh after test/tmux/lib.sh.

# Wait briefly for nvim to come up. Sends a couple of <CR> presses to dismiss
# any startup "Press ENTER" prompt (none expected from init_test.lua, but it's
# cheap insurance against tooltips / messages on slow CI runners).
aside_wait_nvim_ready() {
  local session="$1"
  sleep 1.2
  tmux send-keys -t "$session" Enter
  sleep 0.2
  tmux send-keys -t "$session" Escape
  sleep 0.2
}

# Run a single-line :lua command non-interactively. Caller is responsible for
# escaping inner quotes (use double-quotes inside, single-quote the whole
# argument when passing it through bash).
aside_lua() {
  local session="$1"
  local cmd="$2"
  tmux send-keys -t "$session" Escape
  sleep 0.05
  aside_tmux_send "$session" ":lua ${cmd}"
  sleep 0.25
}

# Run a normal-mode ex-command (no leading colon needed in $cmd).
aside_ex() {
  local session="$1"
  local cmd="$2"
  tmux send-keys -t "$session" Escape
  sleep 0.05
  aside_tmux_send "$session" ":${cmd}"
  sleep 0.25
}

# Assert that $ACTUAL contains a given pattern; print a helpful error otherwise.
aside_assert_grep() {
  local file="$1"
  local pattern="$2"
  local label="${3:-pattern}"
  if ! grep -qE "$pattern" "$file"; then
    echo "FAIL: ${label} not found in $file (pattern: ${pattern})" >&2
    echo "--- begin capture ---" >&2
    cat "$file" >&2
    echo "--- end capture ---" >&2
    return 1
  fi
  return 0
}

# Generate the golden snapshot on first run; diff against it on later runs.
# Diff mismatches are reported but are NOT a hard failure -- snapshots are
# inherently sensitive to terminal width / nvim version. The deterministic
# assertions inside each scenario provide the real correctness signal.
aside_golden_diff() {
  local actual="$1"
  local golden="$2"
  if [[ ! -f "$golden" ]]; then
    cp "$actual" "$golden"
    echo "Generated golden: $golden"
    return 0
  fi
  if ! diff -q "$actual" "$golden" >/dev/null 2>&1; then
    echo "NOTE: snapshot differs from golden: $golden (informational; assertions are the source of truth)"
  fi
  return 0
}

# Remove a per-scenario data dir and any /tmp scratch files for that scenario.
aside_cleanup_scenario_state() {
  local scenario="$1"
  rm -rf ".aside_${scenario}"
  rm -f "/tmp/aside_test_${scenario}_"*
}
