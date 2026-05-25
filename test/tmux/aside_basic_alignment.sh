#!/usr/bin/env bash
# Scenario 1: basic alignment.
# Open aside panel with 2 annotations and verify that the aside buffer has
# the same line count as the source buffer (1:1 row alignment).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="basic_alignment"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

aside_lua "$SESSION" 'local a=require("aside") a.add_annotation({family="test_comments",file="test/sample.lua",start_line=1,end_line=3,title="FirstAnno",contents="content one"}) a.add_annotation({family="test_comments",file="test/sample.lua",start_line=9,end_line=11,title="SecondAnno",contents="content two"})'

aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Headless assertion: write line counts to a file.
aside_lua "$SESSION" "vim.schedule(function() local d=require('aside.display.aside').get_aside_data(0); local src=vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(0)); local ann=(d and d.buf) and vim.api.nvim_buf_line_count(d.buf) or -1; local f=io.open('${OUT}','w'); f:write('SRC='..src..' ASIDE='..ann..'\\n'); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

# Assertion 1: line count file written and aside == source.
if [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion file $OUT not written" >&2
  exit 1
fi
read -r SRC_LINE < "$OUT"
echo "Line-count: $SRC_LINE"
if ! grep -qE 'SRC=43 ASIDE=43' "$OUT"; then
  echo "FAIL: expected SRC=43 ASIDE=43, got: $SRC_LINE" >&2
  cat "$OUT" >&2
  exit 1
fi

# Assertion 2: aside pane shows at least one annotation title.
aside_assert_grep "$ACTUAL" '(FirstAnno|SecondAnno)' "annotation title"

aside_golden_diff "$ACTUAL" "$GOLDEN"

echo "OK: $SCENARIO"
