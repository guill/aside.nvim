#!/usr/bin/env bash
# <C-e> in the aside past the end of the source.
# The last annotation ("End" on line 400 of 400) has more rows than the
# source has lines left, so the source shows them as padding below its last
# line. The source topline cannot go past 400, so once it reaches 400 the
# aside must stay with "End"'s title as its topline. Observed in the TUI
# only (headless never overshoots): every few presses a <C-e> fires no
# WinScrolled at all, so the aside is left one row ahead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="eof_scroll"
SESSION="aside-test-${SCENARIO}"
SRC="/tmp/aside_test_${SCENARIO}_src.lua"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
for i in $(seq 1 400); do echo "local line_$i = $i"; done > "$SRC"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua $SRC" Enter
aside_wait_nvim_ready "$SESSION"

aside_lua "$SESSION" 'local a=require("aside") a.ensure_family("f"):configure({display="hidden"}) a.add_annotation({family="f",file=vim.fn.expand("%:p"),start_line=399,title="A",contents=""}) a.add_annotation({family="f",file=vim.fn.expand("%:p"),start_line=400,title="End",contents="e1\ne2\ne3\ne4\ne5\ne6"}) a.open_aside({family="f",win=0})'
sleep 0.6

tmux send-keys -t "$SESSION" C-w l G
sleep 0.5
for _ in $(seq 1 40); do
  tmux send-keys -t "$SESSION" C-e
  sleep 0.1
done
sleep 0.5

# Assert on the screen: running a :lua probe between presses hides the bug.
BAD=""
for step in 1 2 3 4 5 6; do
  tmux send-keys -t "$SESSION" C-e
  sleep 0.6
  TOP=$(tmux capture-pane -p -t "$SESSION" | head -1)
  echo "STEP=$step TOP=$TOP"
  if [[ "$TOP" == *"line_400 = 400"* && "$TOP" != *"End"* ]]; then
    BAD+="step $step: $TOP"$'\n'
  fi
done

aside_tmux_capture "$SESSION" "test/tmux/snapshots/${SCENARIO}.actual.txt"

if [[ -n "$BAD" ]]; then
  echo "FAIL: aside scrolled past the source at end of file:" >&2
  echo "$BAD" >&2
  exit 1
fi

echo "OK: $SCENARIO"
