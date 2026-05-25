#!/usr/bin/env bash
# Scenario 2: overlapping annotations.
# Two annotations on the same line range -- both titles must appear in the
# rendered aside buffer (the layout solver must stack them, not drop one).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="overlapping"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

# Two overlapping annotations. The greedy layout solver assigns each source
# line to a single owner and sorts by (sort_key, end_line, start_line). Sort
# A before B (sort_key=1 < 2) so A claims 5..8 first, then B overwrites 6..7;
# both annotations end up with at least one owned source line and both
# titles must render.
aside_lua "$SESSION" 'local a=require("aside") a.add_annotation({family="test_comments",file="test/sample.lua",start_line=5,end_line=8,sort_key=1,title="OverlapA",contents="aaa"}) a.add_annotation({family="test_comments",file="test/sample.lua",start_line=6,end_line=7,sort_key=2,title="OverlapB",contents="bbb"})'

aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Dump aside buffer contents to a file so we can grep without depending on what
# happens to be currently visible in the tmux pane.
aside_lua "$SESSION" "vim.schedule(function() local d=require('aside.display.aside').get_aside_data(0); if not d then local f=io.open('${OUT}','w'); f:write('NO_ASIDE\\n'); f:close(); return end; local lines=vim.api.nvim_buf_get_lines(d.buf,0,-1,false); local f=io.open('${OUT}','w'); f:write(table.concat(lines,'\\n')); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion file $OUT not written" >&2
  exit 1
fi

# Assertion: both annotation titles present in aside buffer dump.
if ! grep -q "OverlapA" "$OUT"; then
  echo "FAIL: OverlapA missing from aside buffer dump" >&2
  cat "$OUT" >&2
  exit 1
fi
if ! grep -q "OverlapB" "$OUT"; then
  echo "FAIL: OverlapB missing from aside buffer dump" >&2
  cat "$OUT" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

echo "OK: $SCENARIO"
