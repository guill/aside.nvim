# aside.nvim Design Doc

# Overview

The intention behind aside.nvim is to provide a library for tracking and displaying annotations in code files. The primary goal isn't to provide options directly to users, but to provide APIs that can be used to make plugins like:
1. Something that displays PR comments on the code and allows the user to add their own comments.
2. A way to provide instructions to an LLM directly tied to code.
3. A way for an LLM to provide commentary and suggestions in the code (without actually changing the contents of the file).

There are several primary components to this plugin:
1. The addition of annotations
2. The tracking and auto updating of the position of annotations as the file is modified (either in NeoVim or externally).
3. The display of annotations in one of several formats which can be toggled at runtime.
4. Programmatic access to querying annotations.

## Configuration Philosophy

Options follow a **global defaults with per-family overrides** pattern. Nearly all configuration options can be set globally and then overwritten on a per-family basis.

## Annotation Addition

### Annotation Families
All annotations will live in an annotation 'family'. Annotation families can be created dynamically and can be individually configured to display in different ways. For example, we might do this like this:

```lua
local family = aside.ensure_family("pr_comments")
family:configure({
    display = 'inline'
})
```

#### Family Management API

```lua
-- Create or get existing family
local family = aside.ensure_family("pr_comments")

-- Check if family exists
local exists = aside.family_exists("pr_comments")

-- List all families
local families = aside.list_families() -- Returns array of family names

-- Delete a family and all its annotations
aside.delete_family("pr_comments")
```

**Note**: Adding an annotation to a non-existent family will fail. Use `ensure_family` first.

### Adding Annotations
When an annotation is added, it is added to a specific range of lines within a particular file. (Note that the range may be a single line.) This might look like this:

```lua
local id = aside.add_annotation({
    family = family or "pr_comments", -- A family object or the string identifier
    file = "foo/bar/baz.go", -- Relative or absolute path (converted to absolute internally)
    start_line = 27,
    end_line = 29,
    title = "A title",
    contents = "This is the actual content of the annotation.\nIt can be multiple lines as well.",
    sort_key = nil, -- Optional: explicit sort order for overlapping annotations
    metadata = { -- Optional arbitrary table for plugin-specific data
        author = "user@example.com",
        pr_comment_id = 12345,
        resolved = false,
    }
})
```

#### Annotation IDs
Annotation IDs are UUIDs generated automatically. External IDs (like PR comment IDs) should be stored in `metadata` and queried using `get_annotations_by_metadata`.

#### File Path Handling
File paths are always stored as absolute paths internally. When relative paths are provided as input to any function, they are immediately converted to absolute paths based on the current working directory. This ensures consistent behavior regardless of how paths are specified.

### Annotation CRUD API
The plugin provides full CRUD operations for annotations:

```lua
-- Create
local id = aside.add_annotation({...})

-- Read
local annotation = aside.get_annotation(id)
local annotations = aside.get_annotations_by_file("foo/bar/baz.go")
local annotations = aside.get_annotations_by_family("pr_comments")

-- Query by metadata (iterates through all annotations, no optimization needed)
local annotations = aside.get_annotations_by_metadata(function(metadata)
    return metadata and metadata.pr_comment_id == 12345
end)

-- Update (uses vim.tbl_extend("force", ...) - merges provided fields)
aside.update_annotation(id, {
    title = "Updated title",
    contents = "Updated contents",
    metadata = { resolved = true } -- Replaces entire metadata table
})

-- Delete
aside.delete_annotation(id)
```

#### Annotation Object Structure
All getter functions return annotation objects. The structure is documented using LuaCATS annotations in the source code. An annotation object contains all current data including:
- `id` - The UUID
- `family` - Family name
- `file` - Absolute file path
- `start_line`, `end_line` - Current line positions (may differ from original after tracking)
- `title`, `contents` - The annotation content
- `metadata` - Arbitrary user data
- `verified` - Boolean indicating if position is verified after external edits
- `created_at` - Timestamp

### Annotation Metadata
Annotations support an optional `metadata` field that can store arbitrary tables. This data is serialized to JSON and can be used by plugins to store additional information (author, timestamps, status, external IDs, etc.).

### Tracking annotations
It's important that when a file is modified, the annotations update their positions appropriately. When the file is edited in NeoVim, this can be done using extmarks. To handle the case where a file is edited outside of NeoVim (e.g. by something like ClaudeCode), we will include both the content of the annotated text and several lines of context. Then, when we load the file, we can look for that contents with some amount of fuzzy matching (e.g. reducing how much context needs to match, comparing only the first and last lines of the context, using an edit difference, etc.)

#### Context Storage
The number of lines of context stored around annotated text is configurable globally, with per-family overrides available.

#### Failed Relocation
When fuzzy matching fails to relocate an annotation after an external edit, the annotation remains at its original line numbers but is marked as "unverified". This allows consumers to identify annotations that may need manual review.

#### Deleted Lines
When lines that have annotations are deleted, the annotation attaches to the nearest remaining line (preferring the line after the deleted range).

#### Persistence
Annotations are persisted to disk with debouncing (e.g., 1 second after the last change) to avoid excessive writes.

### Annotation Display
Display mode is configured per-family, with a global default for families that don't specify their own. Every annotation family can be displayed in one of several ways:

1. `hidden` - The annotation doesn't display at all.
2. `hover` - An icon appears in the gutter on the first line of the annotation range, with line characters (e.g., `│`) on subsequent lines to show the range. The annotation appears in a floating box when hovering over any line in the range. The gutter icon is configurable (global default with per-family override).
3. `below` - Using virtual lines, the annotation appears below. Here is an example of what it might look like:
```
        dependencies = {                            
┌─
│           "sudo-tee/opencode.nvim",               
│           "mfussenegger/nvim-dap",                
│           "grapp-dev/nui-components.nvim",        
├── ● A title
│ This is the actual content of the annotation.
│ It can be multiple lines as well.
└─────────────                                      
        },                                          
```

4. `aside` - We open up a horizontal split to the right of the pane. All annotations are placed in the buffer in the pane to the right. As the pane on the left (the actual code pane) is scrolled, the pane on the right is scrolled to match up annotations. Note that because annotations may be longer than the lines they annotate, we may sometimes need to use lines like this:
```
        dependencies = {                            │
            "sudo-tee/opencode.nvim",               │┐
            "mfussenegger/nvim-dap",                │├ This is the actual content of the annotation.
            "grapp-dev/nui-components.nvim",        │┘ It can be multiple lines as well.
        },                                          │
```
In this way, the annotations on the right can actually be editable with the virtual text showing what they align to in the code on the left. Changes are synced to annotation storage when the user saves (`:w`).

#### Aside Panel Management
The aside panel is controlled explicitly via API functions - changing a family's display mode to `aside` does not automatically open a panel. Only one family can be displayed in the aside panel at a time.

```lua
-- Open panel for a specific window/buffer, showing annotations from a family
aside.open_aside({
    family = "pr_comments",
    win = 0,      -- Window ID (0 for current window)
    -- or: buf = 0,  -- Buffer ID (0 for current buffer, uses current window)
})

aside.close_aside(win)           -- Close the aside panel for this window (0 for current)
aside.set_aside_family(win, "llm") -- Change which family is shown in this window's aside
```

The aside panel opens as a vertical split to the right of the specified window and stays synchronized with that window's scrolling.

#### Aside Panel Updates
When the code file changes while the user is editing in the aside panel, updates to the panel are delayed until the user exits insert mode to avoid disruption.

#### Highlight Groups
Highlight groups for annotation display use global defaults with per-family overrides available.

#### Overlapping Annotations
When multiple annotations mark the same lines, they are displayed stacked vertically (in `below` mode). Sort order is:
1. Explicit `sort_key` field (if provided)
2. Last line number (ascending)
3. First line number (ascending)
4. Family name (alphabetical)
5. Creation timestamp (oldest first)

### Programmatic Access
It's important that we be able to programmatically access all annotations in a nice and easy to use API. That way, we can easily give annotations to LLMs or submit them as PR reviews.

### Events & Hooks
The plugin provides a Lua callback registration API for responding to annotation changes. The `on` function returns an unsubscribe handle:

```lua
local unsub = aside.on("annotation_added", function(annotation)
    -- Handle new annotation
end)
unsub() -- Unregister the callback

aside.on("annotation_updated", function(annotation, old_annotation)
    -- Handle annotation update
end)

aside.on("annotation_deleted", function(annotation)
    -- Handle annotation deletion
end)

-- Fired both during normal editing (extmark moves) and after external file reloads
aside.on("annotation_relocated", function(annotation, old_position, is_external_reload)
    if is_external_reload then
        -- This was caused by reloading file after external changes
    else
        -- This was caused by normal editing within Neovim
    end
end)
```

## References
There are some references you may want to look at for inspiration, but it's important to carefully consider what they do and why they do it -- do not just copy the code entirely.

- `/home/guill/projects/devconfig/files/default/home/.config/nvim/lua/devconfig/plugins/ai.lua` - Look at how `marker_annotations` are registered as MCP tools for the AI to use as well as how they are used to pass context to the AI.
- `/home/guill/.local/share/nvim/lazy/marker-groups.nvim` - This is a good reference for how virtual lines can be used for the `below` method of display. It also has code for tracking the movement of annotations as the user types with extmarks as well as some code for finding annotation locations when a file gets updated externally, but we should aim to do better.

## Additional Constraints
- Annotations should be stored in a folder in the current working directory at `./.aside/family-name.json`
- Annotations can be either shorter or longer than the text they annotate.
- Multiple annotations can mark the same lines. When annotations overlap, just do your best to make it understandable.
- Multi-instance safety (concurrent Neovim instances): last-write-wins; no special handling in v1.
- File rename/move tracking: only if easy to implement, otherwise out of scope for v1.
- Undo/redo integration for annotation positions: out of scope for v1.
