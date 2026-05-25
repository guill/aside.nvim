#!/usr/bin/env bash
# Run all aside_*.sh tmux scenario scripts.
# Each scenario script is self-contained: it sets up its own tmux session,
# its own isolated .aside data dir, asserts, and cleans up via trap EXIT.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
FAILED_SCRIPTS=()

for script in test/tmux/aside_*.sh; do
  if [[ ! -x "$script" ]]; then
    chmod +x "$script" || true
  fi
  if bash "$script"; then
    echo "PASS: $script"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $script"
    FAIL=$((FAIL + 1))
    FAILED_SCRIPTS+=("$script")
  fi
done

echo ""
echo "================================================================"
echo "Results: $PASS pass, $FAIL fail"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed scripts:"
  for s in "${FAILED_SCRIPTS[@]}"; do
    echo "  - $s"
  done
fi
echo "================================================================"

[[ "$FAIL" -eq 0 ]]
