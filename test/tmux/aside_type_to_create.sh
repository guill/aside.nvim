#!/usr/bin/env bash
# Scenario 6: type-to-create.
# Open aside with no annotations. Type content into an empty aside row, :w,
# and verify a new annotation was created (annotation count went 0 -> >0).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="type_to_create"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

# Open aside with zero annotations.
aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.6

# Confirm starting count is 0.
aside_lua "$SESSION" "vim.schedule(function() local n=#require('aside').get_annotations_by_family('test_comments'); local f=io.open('${OUT}.before','w'); f:write('BEFORE='..n..'\\n'); f:close() end)"
sleep 0.3

# Place the new annotation text directly into row 5 of the aside buffer (the
# 1-indexed buffer line corresponding to source line 5). This is functionally
# what the user would do with "i...<Esc>:w" but is far more deterministic than
# driving the editor character-by-character through tmux.
aside_lua "$SESSION" "vim.schedule(function() local d=require('aside.display.aside').get_aside_data(0); if not d then return end; vim.api.nvim_set_current_win(d.win); vim.api.nvim_buf_set_lines(d.buf, 4, 5, false, {'NewAnnotationContent'}); vim.cmd('silent! write') end)"
sleep 0.8

# Read back final count.
aside_lua "$SESSION" "vim.schedule(function() local anns=require('aside').get_annotations_by_family('test_comments'); local f=io.open('${OUT}','w'); f:write('AFTER='..#anns..'\\n'); for _,a in ipairs(anns) do f:write('  '..(a.contents or '')..'\\n') end; f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "${OUT}.before" ]] || [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion files not written" >&2
  ls -la "${OUT}"* "${OUT%.txt}"* 2>&1 || true
  exit 1
fi

BEFORE=$(grep -oE 'BEFORE=[0-9]+' "${OUT}.before" | head -1)
AFTER=$(grep -oE 'AFTER=[0-9]+' "$OUT" | head -1)
echo "$BEFORE / $AFTER"

if [[ "$BEFORE" != "BEFORE=0" ]]; then
  echo "FAIL: expected 0 annotations at start, got $BEFORE" >&2
  exit 1
fi

AFTER_N=${AFTER#AFTER=}
if [[ -z "$AFTER_N" ]] || [[ "$AFTER_N" -lt 1 ]]; then
  echo "FAIL: expected >=1 annotation after type-to-create, got $AFTER" >&2
  cat "$OUT" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

rm -f "${OUT}.before"
echo "OK: $SCENARIO"
