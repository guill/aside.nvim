#!/usr/bin/env bash
# Scenario 9: switching the source file rebinds the aside buffer.
# Open aside on file A. :e a different file in the source window. The aside
# buffer's name must update to point at the new source path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="file_change"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

aside_lua "$SESSION" 'require("aside").add_annotation({family="test_comments",file="test/sample.lua",start_line=1,end_line=1,title="OnA",contents="x"})'
aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Capture initial aside buffer name.
aside_lua "$SESSION" "vim.schedule(function() local d=require('aside.display.aside').get_aside_data(0); local f=io.open('${OUT}.before','w'); f:write('BEFORE='..vim.api.nvim_buf_get_name(d.buf)..'\\n'); f:close() end)"
sleep 0.3

# Switch source to a different existing file.
aside_ex "$SESSION" "edit test/init_minimal.lua"
sleep 0.6

# Capture aside buffer name after file change.
aside_lua "$SESSION" "vim.schedule(function() local d=require('aside.display.aside').get_aside_data(0); local f=io.open('${OUT}','w'); f:write('AFTER='..(d and vim.api.nvim_buf_get_name(d.buf) or 'NIL')..'\\n'); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "${OUT}.before" ]] || [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion files not written" >&2
  exit 1
fi

echo "before: $(cat "${OUT}.before")"
echo "after:  $(cat "$OUT")"

if ! grep -q 'sample.lua' "${OUT}.before"; then
  echo "FAIL: expected initial aside name to reference sample.lua" >&2
  cat "${OUT}.before" >&2
  exit 1
fi
if ! grep -q 'init_minimal.lua' "$OUT"; then
  echo "FAIL: expected updated aside name to reference init_minimal.lua after :edit" >&2
  cat "$OUT" >&2
  exit 1
fi
if ! grep -q 'aside://test_comments/' "$OUT"; then
  echo "FAIL: expected aside:// scheme in updated name" >&2
  cat "$OUT" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

rm -f "${OUT}.before"
echo "OK: $SCENARIO"
