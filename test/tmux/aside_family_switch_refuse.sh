#!/usr/bin/env bash
# Scenario 10: set_aside_family refuses while there are unsaved aside edits.
# After making the aside buffer modified, a set_aside_family() call must
# vim.notify an ERROR and leave the current family unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="family_switch_refuse"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

aside_lua "$SESSION" 'require("aside").ensure_family("other_family") require("aside").add_annotation({family="test_comments",file="test/sample.lua",start_line=1,end_line=1,title="A",contents="x"})'
aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Capture notifications so we can assert on them. Override vim.notify so the
# call from set_family() is captured even though it would otherwise scroll off.
aside_lua "$SESSION" "_G.aside_notifs = {} vim.notify = function(msg, lvl) table.insert(_G.aside_notifs, {msg=msg, lvl=lvl}) end"
sleep 0.2

# Dirty the aside buffer by appending a line through the buffer API. Then call
# set_aside_family from a scheduled callback so the modified flag is observed.
aside_lua "$SESSION" "vim.schedule(function() local source_win=vim.api.nvim_get_current_win(); local d=require('aside.display.aside').get_aside_data(source_win); vim.api.nvim_set_current_win(d.win); vim.api.nvim_buf_set_lines(d.buf, 0, 0, false, {'dirty-line'}); end)"
sleep 0.4

# Move focus back to source window and attempt family switch.
aside_lua "$SESSION" "vim.schedule(function() local source_win; for _,w in ipairs(vim.api.nvim_list_wins()) do local d=require('aside.display.aside').get_aside_data(w); if d then source_win=w; break end end; vim.api.nvim_set_current_win(source_win); require('aside').set_aside_family(source_win, 'other_family') end)"
sleep 0.5

# Read back: family of aside_data, and the notification log.
aside_lua "$SESSION" "vim.schedule(function() local sw; local d; for _,w in ipairs(vim.api.nvim_list_wins()) do d=require('aside.display.aside').get_aside_data(w); if d then sw=w; break end end; local fam=d and d.family or 'NIL'; local notifs=''; for _,n in ipairs(_G.aside_notifs or {}) do notifs=notifs..'['..(n.lvl or 'x')..']'..(n.msg or '')..'\\n' end; local f=io.open('${OUT}','w'); f:write('FAMILY='..fam..'\\n') f:write('NOTIFS:\\n'..notifs); f:close() end)"
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

if ! grep -q 'FAMILY=test_comments' "$OUT"; then
  echo "FAIL: family was changed despite unsaved edits" >&2
  exit 1
fi
if ! grep -qE 'unsaved changes|modified|:w|e!' "$OUT"; then
  echo "FAIL: expected error notification about unsaved changes" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

echo "OK: $SCENARIO"
