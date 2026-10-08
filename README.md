# aside.nvim

A Lua library for Neovim that tracks and displays code annotations. Designed as a foundation for building plugins like PR comment viewers, LLM instruction systems, and AI annotation displays.

## Features

- **Annotation Families**: Organize annotations into named groups with independent configuration
- **Multiple Display Modes**: Hidden, hover (gutter icon + popup), below (virtual lines), or aside (side panel)
- **Position Tracking**: Annotations follow their code through edits using extmarks and fuzzy content matching
- **Persistence**: Annotations save to disk automatically with debounced writes
- **Event System**: Subscribe to annotation changes with Lua callbacks
- **Full CRUD API**: Programmatic access to create, read, update, and delete annotations

## Requirements

- Neovim 0.11+
- No external dependencies

## Installation

### lazy.nvim

```lua
{
  "guill/aside.nvim",
  config = function()
    require("aside").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "guill/aside.nvim",
  config = function()
    require("aside").setup()
  end,
}
```

### Manual

Clone to your Neovim packages directory:

```bash
git clone https://github.com/guill/aside.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/aside.nvim
```

## Quick Start

```lua
local aside = require("aside")

-- Initialize the plugin
aside.setup()

-- Create a family for your annotations
local family = aside.ensure_family("my_comments")

-- Add an annotation
local id = aside.add_annotation({
  family = "my_comments",
  file = vim.api.nvim_buf_get_name(0),
  start_line = 10,
  end_line = 12,
  title = "Review needed",
  contents = "This function could be simplified.",
})

-- Query annotations
local annotations = aside.get_annotations_by_file(vim.api.nvim_buf_get_name(0))
for _, ann in ipairs(annotations) do
  print(ann.title, ann.start_line)
end
```

## Configuration

```lua
require("aside").setup({
  -- Lines of context stored around annotated text for relocation
  context_lines = 3,
  
  -- Debounce time for persistence writes (ms)
  persistence_debounce_ms = 1000,

  -- Width of the aside panel in columns
  aside_width = 40,

  -- Direction to spill overflow annotation rows
  spill_direction = "below",  -- "above" | "below"

  -- Name of the layout solver to use
  layout_solver = "greedy",
  
  -- Default display mode for new families
  default_display = "hover",  -- "hidden" | "hover" | "below" | "aside"
  
  -- Default gutter icon for hover mode
  default_gutter_icon = "●",
  
  -- Directory for storing annotation data (relative to cwd)
  data_dir = ".aside",
  
  -- Default highlight groups
  highlight_groups = {
    title = "AsideTitle",
    contents = "AsideContents",
    border = "AsideBorder",
    gutter = "AsideGutter",
    range_indicator = "AsideRangeIndicator",
  },
})
```

### Highlight Groups

| Group | Default (dark) | Description |
|-------|----------------|-------------|
| `AsideTitle` | Bold blue | Annotation titles |
| `AsideContents` | Italic green | Annotation content |
| `AsideBorder` | Gray | Box drawing characters |
| `AsideGutter` | Purple | Gutter icons |
| `AsideRangeIndicator` | Light gray | Range indicator lines |

Override with `vim.api.nvim_set_hl()` or your colorscheme.

## API Reference

### Setup

#### `aside.setup(opts?)`

Initialize the plugin with optional configuration.

```lua
require("aside").setup({
  default_display = "below",
})
```

### Family Management

#### `aside.ensure_family(name) -> Family`

Create or get an existing annotation family. Returns a Family object.

```lua
local family = aside.ensure_family("pr_comments")

-- Configure the family
family:configure({
  display = "below",
  -- Must be display-width 1 (single terminal column)
  gutter_icon = "!",
  context_lines = 5,
})

-- Get current configuration
local config = family:get_config()
```

#### `aside.family_exists(name) -> boolean`

Check if a family exists.

#### `aside.list_families() -> string[]`

Get names of all families.

#### `aside.delete_family(name) -> boolean`

Delete a family and all its annotations.

### Annotation CRUD

#### `aside.add_annotation(opts) -> string?`

Add a new annotation. Returns the UUID or nil on failure.

```lua
local id = aside.add_annotation({
  family = "pr_comments",       -- Family name or Family object (required)
  file = "src/main.lua",        -- File path (required)
  start_line = 10,              -- Start line, 1-indexed (required)
  end_line = 12,                -- End line (default: start_line)
  title = "Note",               -- Title (optional)
  contents = "Multi-line\ntext", -- Content (optional)
  sort_key = 1,                 -- Sort order for overlapping annotations (optional)
  metadata = {                  -- Arbitrary data (optional)
    author = "user@example.com",
    external_id = 12345,
  },
})
```

#### `aside.get_annotation(id) -> Annotation?`

Get an annotation by UUID.

#### `aside.get_annotations_by_file(file) -> Annotation[]`

Get all annotations for a file path.

#### `aside.get_annotations_by_family(family) -> Annotation[]`

Get all annotations in a family.

#### `aside.get_annotations_by_metadata(predicate) -> Annotation[]`

Query annotations with a predicate function.

```lua
local resolved = aside.get_annotations_by_metadata(function(metadata)
  return metadata and metadata.resolved == true
end)
```

#### `aside.update_annotation(id, updates) -> boolean`

Update an annotation. Merges provided fields.

```lua
aside.update_annotation(id, {
  title = "Updated title",
  contents = "New content",
  metadata = { resolved = true },  -- Replaces entire metadata table
})
```

#### `aside.delete_annotation(id) -> boolean`

Delete an annotation by UUID.

### Annotation Object

Returned by getter functions:

```lua
{
  id = "550e8400-e29b-41d4-a716-446655440000",
  family = "pr_comments",
  file = "/absolute/path/to/file.lua",
  start_line = 10,
  end_line = 12,
  title = "Note",
  contents = "Annotation text",
  sort_key = nil,
  metadata = { author = "user@example.com" },
  verified = true,      -- false if position uncertain after external edit
  created_at = 1704067200,
}
```

### Aside Panel

#### `aside.open_aside(opts)`

Open the aside panel for a window.

```lua
aside.open_aside({
  family = "pr_comments",
  win = 0,  -- Window ID (0 for current)
})
```

#### `aside.close_aside(win?)`

Close the aside panel. Pass 0 or omit for current window.

#### `aside.set_aside_family(win, family)`

Change which family is displayed in an open aside panel.

### Events

#### `aside.on(event, callback) -> unsubscribe`

Register an event callback. Returns an unsubscribe function.

```lua
local unsub = aside.on("annotation_added", function(annotation)
  print("New annotation:", annotation.id)
end)

-- Later: stop listening
unsub()
```

#### Events

| Event | Callback Arguments |
|-------|-------------------|
| `annotation_added` | `annotation` |
| `annotation_updated` | `annotation, old_annotation` |
| `annotation_deleted` | `annotation` |
| `annotation_relocated` | `annotation, old_position, is_external_reload` |

```lua
aside.on("annotation_relocated", function(annotation, old_pos, is_external)
  if is_external then
    -- File was edited outside Neovim
    print("Annotation moved from", old_pos.start_line, "to", annotation.start_line)
  end
end)
```

## Display Modes

### hidden

Annotations are stored but not displayed.

### hover

A gutter icon appears on the first line of the annotation range. Hovering over any line in the range shows the annotation in a floating window.

```
   10 │ ● function example()
   11 │ │   return "hello"
   12 │ │ end
```

### below

Annotations appear as virtual lines below the annotated code:

```
   10 │ function example()
   11 │   return "hello"
   12 │ end
      │ ┌─
      │ │ function example()
      │ │   return "hello"
      │ ├── Note
      │ │ This function could be simplified.
      │ └─────────────
   13 │
```

### aside

Opens a vertical split panel to the right. In aside mode, annotations line up row-by-row with the source buffer so each annotation line sits next to its anchor code. Alignment holds while scrolling either pane, with wrapped source lines, closed folds (mirrored in the panel), `scrolloff`, and virtual lines from other plugins. The gutter is a 2-column non-editable sign column: an outer bracket over the anchored source lines plus an inner box around the annotation.

The annotation text itself is editable; save with `:w` to persist changes, or `:e!` to discard them. The panel realigns live while you add or remove lines, and re-renders from storage are deferred while it has unsaved edits. Type-to-create is supported: typing on empty aside rows creates new annotations on save. Removing all of an annotation's text asks for confirmation on save; cancelling aborts the whole save. Each source window can have its own per-window aside panel, and switching the source file automatically switches the aside content for that window (unsaved edits are kept for when you switch back). If you switch families while there are unsaved edits, the change is refused until you `:w` or `:e!` first.

```lua
aside.open_aside({ family = "pr_comments", win = 0 })
```

```
        dependencies = {                            │
            "sudo-tee/opencode.nvim",               │┐
            "mfussenegger/nvim-dap",                │├ This is the actual content of the annotation.
            "grapp-dev/nui-components.nvim",        │┘ It can be multiple lines as well.
        },                                          │
```

## User Commands

| Command | Description |
|---------|-------------|
| `:AsideAdd {family} [title]` | Add annotation at cursor or visual selection |
| `:AsideDelete {id}` | Delete annotation by ID |
| `:AsideList [family]` | List annotations in a family |
| `:AsideFamilies` | List all families |
| `:AsideOpen {family}` | Open aside panel |
| `:AsideClose` | Close aside panel |
| `:AsideToggleDisplay {family} [mode]` | Cycle or set display mode |

Commands support tab completion for family names and display modes.

## Data Storage

Annotations persist to `.aside/<family>.json` in your project directory:

```json
{
  "version": 1,
  "family": "pr_comments",
  "config": { "display": "hover" },
  "annotations": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "file": "/path/to/file.lua",
      "start_line": 10,
      "end_line": 12,
      "title": "Note",
      "contents": "Annotation text",
      "metadata": {},
      "verified": true,
      "created_at": 1704067200,
      "context": {
        "before": ["-- previous lines"],
        "content": ["function example()"],
        "after": ["-- following lines"]
      }
    }
  ]
}
```

Add `.aside/` to your `.gitignore` if annotations should not be shared.

## Use Cases

aside.nvim is designed as a library for building higher-level plugins:

### PR Comment Viewer

```lua
local aside = require("aside")

-- Fetch PR comments from GitHub API and display them
local function load_pr_comments(pr_number)
  local family = aside.ensure_family("pr_" .. pr_number)
  family:configure({ display = "hover" })
  
  -- For each comment from API:
  aside.add_annotation({
    family = family,
    file = comment.path,
    start_line = comment.line,
    title = comment.author,
    contents = comment.body,
    metadata = { comment_id = comment.id },
  })
end
```

### LLM Instruction System

```lua
-- Let users attach instructions for AI directly to code
local family = aside.ensure_family("llm_instructions")
family:configure({ display = "below" })

-- Export for AI context
local function get_instructions_for_file(file)
  return aside.get_annotations_by_file(file)
end
```

### AI Code Review

```lua
-- Display AI suggestions without modifying files
local family = aside.ensure_family("ai_suggestions")
family:configure({ display = "aside" })

aside.on("annotation_updated", function(ann)
  -- User edited annotation in aside panel - sync changes
  if ann.metadata and ann.metadata.accepted then
    apply_suggestion(ann)
  end
end)
```

## License

MIT
