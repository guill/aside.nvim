#!/usr/bin/env bash
set -euo pipefail
SCENARIO="${1:-}"
if [[ -z "$SCENARIO" ]]; then
  echo "Usage: $0 <scenario-name>" >&2
  exit 1
fi
SCRIPT="test/tmux/${SCENARIO}.sh"
if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: Script not found: $SCRIPT" >&2
  exit 1
fi
bash "$SCRIPT"
