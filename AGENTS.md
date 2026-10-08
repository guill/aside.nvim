# AGENTS.md - aside.nvim

Guidelines for AI agents working on this Neovim plugin codebase.

## Project Overview

aside.nvim is a Lua library for Neovim that tracks and displays code annotations. It provides APIs for creating annotation "families" with configurable display modes (hover, below, aside panel). Annotations persist to disk and track their positions as files change.

## Build/Lint/Test Commands

### Running Tests

Test dependencies (neovim, tmux, mini.nvim) come from the nix flake. The
flake's dev shell exports `MINI_PATH`, which `test/init_minimal.lua` adds to
the runtimepath. On this machine `LD_LIBRARY_PATH` must be unset or the
shell's bash crashes ("stack smashing detected").

```bash
# Core suite
env -u LD_LIBRARY_PATH nix develop -c nvim --headless -u test/init_minimal.lua \
  -c "lua require('mini.test').run_file('test/aside_spec.lua')"

# Aside panel suite (scroll alignment, save/edit round-trips, live realign)
env -u LD_LIBRARY_PATH nix develop -c nvim --headless -u test/init_minimal.lua \
  -c "lua require('mini.test').run_file('test/aside_panel_spec.lua')"

# Filter to matching test cases (desc = { file, set, case })
env -u LD_LIBRARY_PATH nix develop -c nvim --headless -u test/init_minimal.lua \
  -c "lua require('mini.test').run_file('test/aside_panel_spec.lua', { collect = { filter_cases = function(c) return c.desc[3]:find('scrolloff') ~= nil end } })"
```

Without nix: install mini.nvim anywhere and point `MINI_PATH` at it.

Each mini.test child starts in a fresh temp cwd (see `test/init_minimal.lua`),
so persisted `.aside/` data never leaks between runs.

Headless-vs-TUI caveats for `test/aside_panel_spec.lua`:
- `vim.wait()` inside an RPC call never reaches the main loop's normal_check,
  so `WinScrolled` does not fire. Settle by idling the child from the parent
  (`vim.uv.sleep` in the test process), as the spec's `settle()` does.
- Headless `<C-e>` skips virt_line filler rows that the TUI shows
  (`topfill`). Set such views explicitly with `winrestview`.

### Manual Testing

```bash
nvim -u test/init.lua test/sample.lua
```

### No Linter/Formatter Configured

This project does not have stylua, luacheck, or other linting tools configured. Follow existing code style when making changes.

## Code Style Guidelines

### Module Structure

```lua
local M = {}

local config = require("aside.config")  -- Requires at top
local state = require("aside.state")

function M.public_function(opts)  -- Public functions on M
  -- implementation
end

local function helper()  -- Private functions use local
  -- implementation
end

return M
```

### Type Annotations (LuaCATS)

```lua
---@class Aside.AnnotationOpts
---@field family string|Aside.Family Family name or object
---@field file string File path (relative or absolute)
---@field start_line number Starting line number (1-indexed)
---@field end_line? number Optional ending line number

---@param opts Aside.AnnotationOpts
---@return string? id The annotation UUID, or nil on failure
function M.add(opts)
```

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Modules | lowercase | `aside.config` |
| Public functions | snake_case | `M.add_annotation()` |
| Private functions | snake_case with local | `local function normalize_path()` |
| Classes/Types | PascalCase with dot prefix | `Aside.Annotation` |
| Namespaces | descriptive string | `"aside_tracking"` |

### Line Numbers

- **User-facing APIs**: 1-indexed (matches Vim convention)
- **Neovim API calls**: Often 0-indexed (check API docs)

### Error Handling

```lua
-- pcall for Neovim API calls that might fail
local ok, result = pcall(function()
  return vim.api.nvim_buf_set_extmark(buf, ns_id, line - 1, 0, opts)
end)

-- vim.notify for user-facing errors
if not file then
  vim.notify("aside: file path is required", vim.log.levels.ERROR)
  return nil
end
```

### Key Patterns

```lua
-- Namespaces for extmarks/virtual text
local ns_id = vim.api.nvim_create_namespace("aside_tracking")

-- Autocommand groups
local group = vim.api.nvim_create_augroup("AsideTracking", { clear = true })

-- Deferred execution
vim.schedule(function() M.refresh_buffer(buf) end)

-- Debounced operations
vim.defer_fn(function() M.sync_extmarks(buf) end, 100)

-- Deep copy for data isolation
return vim.deepcopy(annotation)

-- Table merging
config = vim.tbl_deep_extend("force", defaults, opts or {})
```

## Project Structure

```
lua/aside/
  init.lua          -- Main entry point, public API
  config.lua        -- Configuration management
  state.lua         -- Internal state, families, events
  annotations.lua   -- Annotation CRUD operations
  context.lua       -- File content capture for relocation
  relocator.lua     -- Fuzzy matching to find moved annotations
  tracking.lua      -- Extmark management, buffer sync
  display/
    init.lua        -- Display coordinator
    hover.lua       -- Hover mode display
    below.lua       -- Below mode (virtual lines)
    aside.lua       -- Side panel display

plugin/aside.lua    -- User commands (:AsideAdd, etc.)
test/aside_spec.lua -- mini.test test suite
```

## Key Architectural Patterns

1. **State Management**: All annotations live in `state.lua`. Other modules query state, not store their own copies.
2. **Event-Driven Updates**: Changes emit events -> display modules subscribe and refresh.
3. **Display Abstraction**: Each display mode implements `setup()`, `clear_buffer()`, `render_annotations()`.
4. **Persistence**: Debounced JSON writes to `.aside/family-name.json`. Auto-loads on setup.
5. **Position Tracking**: Extmarks for in-session edits, fuzzy content matching for external edits.

## Common Pitfalls

1. **Don't mutate returned annotations** - They're deep copies, changes won't persist
2. **Check buffer validity** - `vim.api.nvim_buf_is_valid(buf)` before operations
3. **Line number conversion** - API is 0-indexed, user-facing is 1-indexed
4. **Avoid circular requires** - Use lazy requires inside functions if needed
5. **pcall Neovim API** - extmark operations can fail on invalid buffers/lines

## Testing Patterns

Tests use mini.test with a child Neovim process:

```lua
local child = MiniTest.new_child_neovim()

T["test name"] = function()
  child.lua([[
    _G.result = require("aside").add_annotation({...})
  ]])
  local result = child.lua_get("_G.result")
  eq(result, expected)
end
```

## Data Storage

Annotations persist to `.aside/<family>.json`:

```json
{
  "version": 1,
  "family": "pr_comments",
  "config": { "display": "hover" },
  "annotations": [...]
}
```

## Design Document

See `DESIGN.md` for detailed architecture decisions and API design rationale.
