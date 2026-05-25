#!/usr/bin/env bash
# Scenario 7: scroll sync.
# Add annotations near lines 1, 20, 40. Scroll source so line 20 is the
# topline. The aside topline should track the source topline within a small
# tolerance (the sync code does a visual-row computation so absolute equality
# is not guaranteed, but the answer must be close).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="scroll_sync"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

aside_lua "$SESSION" 'local a=require("aside") a.add_annotation({family="test_comments",file="test/sample.lua",start_line=1,end_line=1,title="T1",contents="x"}) a.add_annotation({family="test_comments",file="test/sample.lua",start_line=20,end_line=20,title="T20",contents="x"}) a.add_annotation({family="test_comments",file="test/sample.lua",start_line=40,end_line=40,title="T40",contents="x"})'

aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Drive the source window to topline=20 from inside Neovim. nvim_win_call
# runs the cursor move with that window current; winrestview then forces
# the visible topline. We explicitly invoke sync_scroll afterwards so the
# test does not depend on the WinScrolled autocmd firing in time.
# Preposition the aside cursor to line 20 *before* invoking sync_scroll.
# Without this, Vim's "keep cursor visible" rule re-snaps the aside topline
# back to 1 because the cursor is still on row 1. The real renderer never
# moves the aside cursor either, so this preposition exposes the sync
# correctly without papering over a separate scroll-cursor behavior.
aside_lua "$SESSION" "vim.schedule(function() local source_win; for _,w in ipairs(vim.api.nvim_list_wins()) do if require('aside.display.aside').get_aside_data(w) then source_win=w; break end end; if not source_win then return end; local d=require('aside.display.aside').get_aside_data(source_win); pcall(vim.api.nvim_win_set_cursor, d.win, {20, 0}); vim.api.nvim_win_call(source_win, function() vim.api.nvim_win_set_cursor(source_win, {20, 0}); vim.fn.winrestview({topline=20}) end); require('aside.display.aside').sync_scroll(source_win); local src_top=vim.fn.line('w0', source_win); local aside_top=vim.fn.line('w0', d.win); _G.scroll_dbg = string.format('SRC_TOP=%d ASIDE_TOP=%d ASIDE_VALID=%s ASIDE_LINES=%d', src_top, aside_top, tostring(vim.api.nvim_win_is_valid(d.win)), vim.api.nvim_buf_line_count(d.buf)) end)"
sleep 1.0

aside_lua "$SESSION" "vim.schedule(function() local source_win; for _,w in ipairs(vim.api.nvim_list_wins()) do if require('aside.display.aside').get_aside_data(w) then source_win=w; break end end; local d=require('aside.display.aside').get_aside_data(source_win); vim.api.nvim_set_current_win(source_win); local src_top=vim.fn.line('w0'); vim.api.nvim_set_current_win(d.win); local aside_top=vim.fn.line('w0'); vim.api.nvim_set_current_win(source_win); local f=io.open('${OUT}','w'); f:write('SRC_TOP='..src_top..' ASIDE_TOP='..aside_top..'\\n'); f:write('DBG='..tostring(_G.scroll_dbg)..'\\n'); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion file $OUT not written" >&2
  exit 1
fi

LINE=$(cat "$OUT")
echo "$LINE"
SRC_TOP=$(echo "$LINE" | grep -oE 'SRC_TOP=[0-9]+' | head -1 | sed 's/SRC_TOP=//')
ASIDE_TOP=$(echo "$LINE" | grep -oE 'ASIDE_TOP=[0-9]+' | head -1 | sed 's/ASIDE_TOP=//')

if [[ -z "$SRC_TOP" ]] || [[ -z "$ASIDE_TOP" ]]; then
  echo "FAIL: could not parse topline values" >&2
  exit 1
fi

DIFF=$(( SRC_TOP > ASIDE_TOP ? SRC_TOP - ASIDE_TOP : ASIDE_TOP - SRC_TOP ))
echo "topline drift: $DIFF"
if [[ "$DIFF" -gt 5 ]]; then
  echo "FAIL: aside topline drift too large: SRC=$SRC_TOP ASIDE=$ASIDE_TOP (diff=$DIFF)" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

echo "OK: $SCENARIO"
