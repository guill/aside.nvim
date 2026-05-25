#!/usr/bin/env bash
# Scenario 11: deleting all rows of an annotation triggers the delete prompt.
# Save aside buffer with an annotation's full region emptied. handle_save() must
# call vim.ui.select() to confirm the deletion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="full_delete_prompt"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

aside_lua "$SESSION" '_G.tid = require("aside").add_annotation({family="test_comments",file="test/sample.lua",start_line=5,end_line=7,title="ToDelete",contents="body line one"})'
aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Install a vim.ui.select spy that records the call and answers "Delete annotation".
aside_lua "$SESSION" "_G.aside_select_calls = {} vim.ui.select = function(items, opts, on_choice) table.insert(_G.aside_select_calls, {items=items, prompt=(opts or {}).prompt or ''}); on_choice('Delete annotation') end"
sleep 0.2

# Truly remove the annotation's buffer rows (not just blank them) so the
# ann_end extmark collapses to <= the first seg_start, which is the
# condition handle_save uses to detect a deletion.
aside_lua "$SESSION" "vim.schedule(function() local d=require('aside.display.aside').get_aside_data(0); if not d then return end; vim.api.nvim_set_current_win(d.win); local lines=vim.api.nvim_buf_get_lines(d.buf,0,-1,false); local rm={}; for i,l in ipairs(lines) do if l:find('ToDelete') or l:find('body line one') then table.insert(rm, i) end end; table.sort(rm, function(a,b) return a>b end); for _,i in ipairs(rm) do vim.api.nvim_buf_set_lines(d.buf, i-1, i, false, {}) end; vim.cmd('silent! write') end)"
sleep 1.0

# Read back the spy log and the annotation existence.
aside_lua "$SESSION" "vim.schedule(function() local calls=_G.aside_select_calls or {}; local ann=require('aside').get_annotation(_G.tid); local f=io.open('${OUT}','w'); f:write('SELECT_CALLS='..#calls..'\\n'); for _,c in ipairs(calls) do f:write('  prompt='..(c.prompt or '')..'\\n') end; f:write('ANN_EXISTS='..(ann and 'yes' or 'no')..'\\n'); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion file $OUT not written" >&2
  exit 1
fi

echo "----- $OUT -----"
cat "$OUT"
echo "----------------"

if ! grep -qE 'SELECT_CALLS=[1-9][0-9]*' "$OUT"; then
  echo "FAIL: vim.ui.select was never invoked" >&2
  exit 1
fi
if ! grep -q 'prompt=Delete annotation' "$OUT"; then
  echo "FAIL: prompt label did not match expected Delete annotation prompt" >&2
  cat "$OUT" >&2
  exit 1
fi
if ! grep -q 'ANN_EXISTS=no' "$OUT"; then
  echo "FAIL: annotation should have been deleted after user approved prompt" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

echo "OK: $SCENARIO"
