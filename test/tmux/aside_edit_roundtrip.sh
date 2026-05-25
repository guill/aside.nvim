#!/usr/bin/env bash
# Scenario 5: edit -> save -> verify persistence.
# Add an annotation with a known title, open aside, edit the title row, :w,
# then query the annotation through the API to confirm the new title was
# committed to state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="edit_roundtrip"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

# Stash the annotation id in a global so we can reference it after the edit.
aside_lua "$SESSION" '_G.tested_id = require("aside").add_annotation({family="test_comments",file="test/sample.lua",start_line=5,end_line=7,title="OriginalTitle",contents="body"})'

aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Move focus to the aside window, locate the title row programmatically, do an
# in-buffer substitution, save. This avoids fragile cursor counting.
aside_lua "$SESSION" "vim.schedule(function() local d=require('aside.display.aside').get_aside_data(0); if not d then return end; vim.api.nvim_set_current_win(d.win); vim.cmd('silent! %s/OriginalTitle/EditedTitle/g'); vim.cmd('silent! write') end)"
sleep 0.8

# Read back the annotation title.
aside_lua "$SESSION" "vim.schedule(function() local ann=require('aside').get_annotation(_G.tested_id); local f=io.open('${OUT}','w'); f:write('TITLE=['..(ann and ann.title or 'NIL')..']\\n'); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion file $OUT not written" >&2
  exit 1
fi

echo "Result: $(cat "$OUT")"
if ! grep -q 'TITLE=\[EditedTitle\]' "$OUT"; then
  echo "FAIL: annotation title was not updated through round-trip" >&2
  cat "$OUT" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

echo "OK: $SCENARIO"
