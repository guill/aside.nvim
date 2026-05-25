#!/usr/bin/env bash
# Scenario 3: spillover.
# One annotation anchored to a single line but containing several content lines
# must occupy more than one aside row (the body has to spill above or below).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="spill"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

# Single-line anchor (line 5..5), 5 lines of content -> must spill.
aside_lua "$SESSION" 'require("aside").add_annotation({family="test_comments",file="test/sample.lua",start_line=5,end_line=5,title="SpillCase",contents="line1\nline2\nline3\nline4\nline5"})'

aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Count how many aside buffer rows contain any of: title or content tokens
# associated with this annotation.
aside_lua "$SESSION" "vim.schedule(function() local d=require('aside.display.aside').get_aside_data(0); if not d then local f=io.open('${OUT}','w'); f:write('NO_ASIDE\\n'); f:close(); return end; local lines=vim.api.nvim_buf_get_lines(d.buf,0,-1,false); local hits=0; for _,l in ipairs(lines) do if l:find('SpillCase') or l:find('line%d') then hits=hits+1 end end; local f=io.open('${OUT}','w'); f:write('HITS='..hits..'\\n'); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion file $OUT not written" >&2
  exit 1
fi

HITS_LINE=$(grep -oE 'HITS=[0-9]+' "$OUT" || echo "HITS=0")
HITS=${HITS_LINE#HITS=}
echo "Spill rows used: $HITS"
if [[ "$HITS" -lt 2 ]]; then
  echo "FAIL: expected >1 aside row for spillover annotation, got $HITS" >&2
  cat "$OUT" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

echo "OK: $SCENARIO"
