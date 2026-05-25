#!/usr/bin/env bash
# Scenario 8: in-insert events are deferred.
# When the aside buffer is in insert mode, an annotation update event must not
# trigger an immediate re-render -- the aside_data.deferred_render flag must
# be raised instead. Leaving insert mode should clear the flag.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="insert_mode_defer"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

aside_lua "$SESSION" '_G.tid = require("aside").add_annotation({family="test_comments",file="test/sample.lua",start_line=5,end_line=5,title="Pre",contents="pre"})'

aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Strategy: pre-arm a long-delay vim.defer_fn (3 seconds). Move focus into
# the aside window. Send 'i' to enter insert mode. While we're sitting in
# insert mode, the deferred function fires update_annotation() -- which goes
# through the event bus, hits display.refresh_if_visible, sees in_insert==true,
# and sets deferred_render=true. After Escape, the InsertLeave autocmd clears
# the flag. We snapshot the flag values from inside the deferred function
# itself, which avoids needing to run any Lua while in insert mode.
# The event bus delivers annotation_updated via vim.schedule on the display
# module side, so refresh_if_visible has not run yet at the instant
# update_annotation() returns. We wrap our snapshot in a nested vim.schedule
# so it observes state AFTER the deferred refresh has fired.
aside_lua "$SESSION" "vim.defer_fn(function() require('aside').update_annotation(_G.tid, {title='Updated'}); vim.schedule(function() local sw; for _,w in ipairs(vim.api.nvim_list_wins()) do local d=require('aside.display.aside').get_aside_data(w); if d then sw=d; break end end; local during=sw and tostring(sw.deferred_render) or 'NIL'; local in_ins=sw and tostring(sw.in_insert) or 'NIL'; local f=io.open('${OUT}.during','w'); f:write('DURING_DEFER='..during..' DURING_INSERT='..in_ins..'\\n'); f:close() end) end, 3000)"
sleep 0.3

# Move into the aside window via window navigation keys (more reliable than
# nvim_set_current_win timing under tmux).
tmux send-keys -t "$SESSION" Escape
sleep 0.2
tmux send-keys -t "$SESSION" "C-w" "l"
sleep 0.6

# Confirm we are in the aside window before we enter insert mode.
aside_lua "$SESSION" "vim.schedule(function() local cur=vim.api.nvim_get_current_win(); local d=require('aside.display.aside'); local in_aside=false; for _,w in ipairs(vim.api.nvim_list_wins()) do local x=d.get_aside_data(w); if x and x.win==cur then in_aside=true; break end end; local f=io.open('${OUT}.precheck','w'); f:write('IN_ASIDE_WIN='..tostring(in_aside)..'\\n'); f:close() end)"
sleep 0.4

# Now enter insert mode in the aside buffer and stay there past the 3-second
# defer_fn trigger.
tmux send-keys -t "$SESSION" "i"
sleep 3.2

# Leave insert mode. InsertLeave autocmd fires, clearing deferred_render.
tmux send-keys -t "$SESSION" Escape
sleep 0.8

# Verify deferred_render cleared after InsertLeave.
aside_lua "$SESSION" "vim.schedule(function() local sw; for _,w in ipairs(vim.api.nvim_list_wins()) do local d=require('aside.display.aside').get_aside_data(w); if d then sw=d; break end end; local after=sw and tostring(sw.deferred_render) or 'NIL'; local in_ins=sw and tostring(sw.in_insert) or 'NIL'; local f=io.open('${OUT}','w'); f:write('AFTER_DEFER='..after..' AFTER_INSERT='..in_ins..'\\n'); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "${OUT}.during" ]] || [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion files not written (during=${OUT}.during after=${OUT})" >&2
  ls -la "${OUT}"* 2>&1 || true
  exit 1
fi

if [[ -f "${OUT}.precheck" ]]; then
  echo "precheck: $(cat "${OUT}.precheck")"
fi
echo "during: $(cat "${OUT}.during")"
echo "after:  $(cat "$OUT")"

# While in insert mode + with an update queued, deferred_render must be true
# AND in_insert must be true.
if ! grep -q 'DURING_INSERT=true' "${OUT}.during"; then
  echo "FAIL: expected in_insert=true during insert mode" >&2
  cat "${OUT}.during" >&2
  exit 1
fi
if ! grep -q 'DURING_DEFER=true' "${OUT}.during"; then
  echo "FAIL: expected deferred_render=true during update-in-insert" >&2
  cat "${OUT}.during" >&2
  exit 1
fi

# After InsertLeave the flag must have been consumed.
if ! grep -q 'AFTER_DEFER=false' "$OUT"; then
  echo "FAIL: expected deferred_render=false after InsertLeave, got: $(cat "$OUT")" >&2
  exit 1
fi
if ! grep -q 'AFTER_INSERT=false' "$OUT"; then
  echo "FAIL: expected in_insert=false after InsertLeave" >&2
  cat "$OUT" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

rm -f "${OUT}.during" "${OUT}.precheck"
echo "OK: $SCENARIO"
