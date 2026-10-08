#!/usr/bin/env bash
# Scenario 4: crowded annotations force source-side virt_lines.
# 4 consecutive annotations each with 3 lines of content cannot fit 1:1 with
# their source anchors, so the renderer must push virt_lines into the source
# buffer in the "aside_source_padding" namespace to keep alignment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"
source test/tmux/lib.sh
source test/tmux/_common.sh

SCENARIO="virt_lines"
SESSION="aside-test-${SCENARIO}"
OUT="/tmp/aside_test_${SCENARIO}_out.txt"
aside_assert_session_not_dev "$SESSION"

trap 'aside_tmux_kill "$SESSION"; aside_cleanup_scenario_state "$SCENARIO"' EXIT

aside_cleanup_scenario_state "$SCENARIO"
rm -f "$OUT"

aside_tmux_session_new "$SESSION"
tmux send-keys -t "$SESSION" "ASIDE_TEST_DATA_DIR=.aside_${SCENARIO} nvim -u test/tmux/init_test.lua test/sample.lua" Enter
aside_wait_nvim_ready "$SESSION"

aside_lua "$SESSION" 'local a=require("aside") for i=1,4 do a.add_annotation({family="test_comments",file="test/sample.lua",start_line=i,end_line=i,title="T"..i,contents="c1\nc2\nc3"}) end'

aside_lua "$SESSION" 'require("aside").open_aside({family="test_comments",win=0})'
sleep 0.8

# Count extmarks in the aside_source_padding namespace on the source buffer.
aside_lua "$SESSION" "vim.schedule(function() local marks={}; for name,ns in pairs(vim.api.nvim_get_namespaces()) do if name:find('^aside_source_padding') then vim.list_extend(marks, vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) end end; local f=io.open('${OUT}','w'); f:write('PAD_MARKS='..#marks..'\\n'); f:close() end)"
sleep 0.5

GOLDEN="test/tmux/snapshots/${SCENARIO}.txt"
ACTUAL="test/tmux/snapshots/${SCENARIO}.actual.txt"
aside_tmux_capture "$SESSION" "$ACTUAL"

if [[ ! -f "$OUT" ]]; then
  echo "FAIL: assertion file $OUT not written" >&2
  exit 1
fi

PAD_LINE=$(grep -oE 'PAD_MARKS=[0-9]+' "$OUT" || echo "PAD_MARKS=0")
PAD=${PAD_LINE#PAD_MARKS=}
echo "source padding extmarks: $PAD"
if [[ "$PAD" -lt 1 ]]; then
  echo "FAIL: expected >0 padding extmarks, got $PAD" >&2
  cat "$OUT" >&2
  exit 1
fi

aside_golden_diff "$ACTUAL" "$GOLDEN"

echo "OK: $SCENARIO"
