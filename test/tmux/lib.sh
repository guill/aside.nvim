#!/usr/bin/env bash
set -euo pipefail

aside_assert_session_not_dev() {
  local session_name="$1"
  if [[ "$session_name" == "dev" ]]; then
    echo "ERROR: Refusing to use 'dev' tmux session. Use a different session name." >&2
    exit 1
  fi
}

aside_tmux_session_new() {
  local session_name="$1"
  aside_assert_session_not_dev "$session_name"
  tmux kill-session -t "$session_name" 2>/dev/null || true
  tmux new-session -d -s "$session_name" -x 120 -y 40 -c "$(pwd)"
}

aside_tmux_send() {
  local session="$1"
  local keys="$2"
  tmux send-keys -t "$session" "$keys" Enter
}

aside_tmux_capture() {
  local session="$1"
  local output_path="$2"
  sleep 0.5
  tmux capture-pane -p -t "$session" > "$output_path"
}

aside_tmux_kill() {
  local session="$1"
  tmux kill-session -t "$session" 2>/dev/null || true
}
