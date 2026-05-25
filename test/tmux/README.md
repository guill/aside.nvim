# Tmux Scenario Tests

End-to-end scenario tests that drive a real Neovim instance through `tmux`
and assert on observable state. They complement the unit tests in
`test/aside_spec.lua` by exercising the **full integration path** — actual
windows, autocommands, scroll sync, file events, save handling, and the
`vim.ui.select` prompt.

## Files

| File | Purpose |
|------|---------|
| `lib.sh` | Low-level tmux helpers (session new/kill/send/capture, safety guards). |
| `_common.sh` | Higher-level helpers (`aside_lua`, `aside_ex`, `aside_assert_grep`, `aside_golden_diff`). Sourced after `lib.sh`. |
| `init_test.lua` | Minimal `nvim -u` init used by every scenario. Honors `$ASIDE_TEST_DATA_DIR` so each scenario gets isolated annotation storage. |
| `run.sh <name>` | Run a single scenario by name (just dispatches to `test/tmux/<name>.sh`). |
| `all.sh` | Run every `aside_*.sh` scenario, tally pass/fail, exit non-zero on any failure. |
| `snapshots/` | Generated golden pane captures (`<scenario>.txt`) and per-run actual captures (`<scenario>.actual.txt`). |
| `aside_<scenario>.sh` | One scenario each. See the list below. |

## Running

Single scenario:

```bash
bash test/tmux/aside_basic_alignment.sh
```

All scenarios:

```bash
bash test/tmux/all.sh
```

`all.sh` will print a `PASS: …` or `FAIL: …` line per scenario and a final
tally. It exits 0 only when every scenario passed.

## How each scenario works

Each script follows the same pattern:

1. Resolve `$PROJECT_DIR` and `cd` there. **Never** uses absolute paths.
2. Source `test/tmux/lib.sh` and `test/tmux/_common.sh`.
3. Define `SESSION="aside-test-<scenario>"` and call
   `aside_assert_session_not_dev` — the helpers refuse to touch a session
   literally named `dev`.
4. `trap` on `EXIT` to (a) kill the tmux session and (b) remove the
   per-scenario `.aside_<scenario>/` data dir and any `/tmp/aside_test_*`
   scratch files. Cleanup runs unconditionally on success, failure, or
   interrupt.
5. Boot Neovim inside the session with `ASIDE_TEST_DATA_DIR=.aside_<scenario>`
   so persistence is isolated.
6. Drive the editor with `aside_lua` / `aside_ex`. Wherever a deterministic
   answer is required, the scenario writes a result file to
   `/tmp/aside_test_<scenario>_out.txt` from inside Neovim and the shell
   greps that file. **Pane captures are kept for visual debugging only — the
   grep assertions over the result files are the real correctness signal.**
7. `aside_tmux_capture` writes the pane to
   `test/tmux/snapshots/<scenario>.actual.txt`.
8. `aside_golden_diff` copies that to `<scenario>.txt` on first run, and
   reports (informationally, not fatally) any diff on subsequent runs.

## Scenarios

| Script | What it proves |
|---|---|
| `aside_basic_alignment.sh` | Aside buffer has 1:1 row alignment with the source buffer (line counts match) and shows annotation titles. |
| `aside_overlapping.sh` | Two annotations on the same source range both render — neither title is dropped. |
| `aside_spill.sh` | A single-line anchor with multi-line content occupies more than one aside row. |
| `aside_virt_lines.sh` | Crowded annotations force the renderer to insert virt_lines into the source buffer via the `aside_source_padding` namespace. |
| `aside_edit_roundtrip.sh` | Editing a title in the aside buffer and `:w` updates the annotation in state. |
| `aside_type_to_create.sh` | Typing into an empty aside row and saving creates a brand-new annotation. |
| `aside_scroll_sync.sh` | Scrolling the source window drags the aside topline along (within a small visual-row tolerance). |
| `aside_insert_mode_defer.sh` | Annotation updates that fire while the aside buffer is in insert mode raise `deferred_render` instead of re-rendering immediately, and the flag clears on `InsertLeave`. |
| `aside_file_change.sh` | `:edit <other-file>` in the source window updates the aside buffer's name to point at the new path. |
| `aside_family_switch_refuse.sh` | `set_aside_family` refuses (with a vim.notify error) when the aside buffer has unsaved edits and leaves the family unchanged. |
| `aside_full_delete_prompt.sh` | Deleting an annotation's whole region and saving invokes `vim.ui.select` to confirm the delete. |
| `aside_wrap.sh` | Long single-line content occupies multiple aside rows but the stored `contents` remains a single logical line after a round-trip save. |

## Conventions

- **Session names** must include `aside-test-` and never equal `dev`.
  `aside_assert_session_not_dev` enforces this; `lib.sh` calls it from
  `aside_tmux_session_new` as a defense-in-depth check.
- **No absolute paths**: scenarios `cd "$PROJECT_DIR"` and reference files
  relative to it.
- **No `cd <dir> &&` chaining** — use `cd "$PROJECT_DIR"` once at the top.
- **Determinism**: don't rely on tmux pane contents for assertions when a
  Lua/Vim API can answer the same question. Write the answer to a file,
  then grep it.
- **Cleanup is mandatory**: every script `trap`s `EXIT` to kill its tmux
  session and remove its `.aside_<scenario>/` data dir.

## Adding a new scenario

1. Copy the closest existing `aside_*.sh` as a template.
2. Set a unique `SCENARIO` name.
3. Replace the deterministic assertion block with whatever your scenario
   needs to prove.
4. Run it once to generate `test/tmux/snapshots/<scenario>.txt`.
5. Commit the script **and** its golden file.
