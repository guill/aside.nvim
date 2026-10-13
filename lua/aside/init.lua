---@mod aside.nvim Annotation tracking and display library for Neovim
---@brief [[
--- aside.nvim provides APIs for tracking and displaying annotations in code files.
--- It supports multiple annotation "families" with configurable display modes.
---@brief ]]

local M = {}
local config = require("aside.config")
local state = require("aside.state")
local annotations = require("aside.annotations")
local persistence = require("aside.persistence")
local display = require("aside.display")

local did_setup = false

---@class Aside.SetupOpts
---@field context_lines? number Lines of context stored around annotated text (default: 3)
---@field persistence_debounce_ms? number Debounce time for persistence writes (default: 1000)
---@field default_display? "hidden"|"hover"|"below"|"aside" Default display mode for new families (default: "hover")
---@field default_gutter_icon? string Default gutter icon for hover mode (default: "●")
---@field aside_width? number Width of the aside panel (default: 40)
---@field spill_direction? "above"|"below" Direction to spill overflow annotation rows (default: "below")
---@field layout_solver? string Name of the layout solver to use (default: "greedy")
---@field data_dir? string Directory for storing annotation data (default: ".aside")
---@field highlight_groups? table<string, table> Default highlight groups

--- Initialize aside.nvim with the given options
---@param opts? Aside.SetupOpts
function M.setup(opts)
  if vim.fn.has("nvim-0.11") == 0 then
    vim.notify("aside.nvim requires Neovim 0.11 or later", vim.log.levels.ERROR)
    return
  end

  local setup_opts = vim.deepcopy(opts or {})
  if setup_opts.default_gutter_icon ~= nil and vim.fn.strdisplaywidth(setup_opts.default_gutter_icon) ~= 1 then
    vim.notify("aside: default_gutter_icon must be display-width 1", vim.log.levels.ERROR)
    setup_opts.default_gutter_icon = nil
  end
  if setup_opts.spill_direction ~= nil and setup_opts.spill_direction ~= "above" and setup_opts.spill_direction ~= "below" then
    vim.notify("aside: spill_direction must be 'above' or 'below'", vim.log.levels.ERROR)
    setup_opts.spill_direction = nil
  end
  if setup_opts.aside_width ~= nil and (type(setup_opts.aside_width) ~= "number" or math.floor(setup_opts.aside_width) ~= setup_opts.aside_width or setup_opts.aside_width <= 0) then
    vim.notify("aside: aside_width must be a positive integer", vim.log.levels.ERROR)
    setup_opts.aside_width = nil
  end
  if setup_opts.layout_solver ~= nil and type(setup_opts.layout_solver) ~= "string" then
    vim.notify("aside: layout_solver must be a string", vim.log.levels.ERROR)
    setup_opts.layout_solver = nil
  end

  config.setup(setup_opts)
  state.initialize()
  persistence.setup()
  display.setup()
  did_setup = true
end

--- Whether `setup()` has run (for plugins that drive aside optionally)
---@return boolean
function M.is_setup()
  return did_setup
end

-- ============================================================================
-- Family Management API
-- ============================================================================

---@class Aside.Family
---@field name string The family name
---@field configure fun(self: Aside.Family, opts: Aside.FamilyConfig) Configure family options
---@field get_config fun(self: Aside.Family): Aside.FamilyConfig Get current configuration

---@class Aside.FamilyConfig
---@field display? "hidden"|"hover"|"below"|"aside" Display mode
---@field gutter_icon? string Gutter icon for hover mode
---@field context_lines? number Lines of context to store
---@field aside_width? number Width of the aside panel (default: 40)
---@field spill_direction? "above"|"below" Direction to spill overflow annotation rows (default: "below")
---@field layout_solver? string Name of the layout solver to use (default: "greedy")
---@field highlight_groups? table<string, string> Highlight group overrides
---@field ephemeral? boolean Keep the family in memory only; never written to disk (for externally owned data)

--- Create or get an existing family
---@param name string Family name
---@return Aside.Family
function M.ensure_family(name)
  return state.ensure_family(name)
end

--- Check if a family exists
---@param name string Family name
---@return boolean
function M.family_exists(name)
  return state.family_exists(name)
end

--- List all family names
---@return string[]
function M.list_families()
  return state.list_families()
end

--- Delete a family and all its annotations
---@param name string Family name
---@return boolean success
function M.delete_family(name)
  return state.delete_family(name)
end

-- ============================================================================
-- Annotation CRUD API
-- ============================================================================

---@class Aside.AddAnnotationOpts
---@field family string|Aside.Family Family name or object
---@field file string File path (relative or absolute)
---@field start_line number Starting line number (1-indexed)
---@field end_line? number Ending line number (defaults to start_line)
---@field title? string Annotation title
---@field contents? string Annotation content (can be multiline)
---@field sort_key? any Explicit sort order for overlapping annotations
---@field metadata? table Arbitrary plugin-specific data

--- Add a new annotation
---@param opts Aside.AddAnnotationOpts
---@return string? id The annotation UUID, or nil on failure
function M.add_annotation(opts)
  return annotations.add(opts)
end

---@class Aside.Annotation
---@field id string UUID
---@field family string Family name
---@field file string Absolute file path
---@field start_line number Current start line
---@field end_line number Current end line
---@field title string Annotation title
---@field contents string Annotation content
---@field sort_key? any Sort order
---@field metadata? table User data
---@field verified boolean Position verified after external edits
---@field created_at number Timestamp

--- Get an annotation by ID
---@param id string Annotation UUID
---@return Aside.Annotation?
function M.get_annotation(id)
  return annotations.get(id)
end

--- Get all annotations for a file
---@param file string File path
---@return Aside.Annotation[]
function M.get_annotations_by_file(file)
  return annotations.get_by_file(file)
end

--- Get all annotations in a family
---@param family string Family name
---@return Aside.Annotation[]
function M.get_annotations_by_family(family)
  return annotations.get_by_family(family)
end

--- Query annotations by metadata predicate
---@param predicate fun(metadata: table?): boolean
---@return Aside.Annotation[]
function M.get_annotations_by_metadata(predicate)
  return annotations.get_by_metadata(predicate)
end

---@class Aside.UpdateAnnotationOpts
---@field title? string
---@field contents? string
---@field sort_key? any
---@field metadata? table Replaces entire metadata table

--- Update an annotation (merges provided fields)
---@param id string Annotation UUID
---@param updates Aside.UpdateAnnotationOpts
---@return boolean success
function M.update_annotation(id, updates)
  return annotations.update(id, updates)
end

--- Delete an annotation
---@param id string Annotation UUID
---@return boolean success
function M.delete_annotation(id)
  return annotations.delete(id)
end

-- ============================================================================
-- Aside Panel API
-- ============================================================================

---@class Aside.OpenAsideOpts
---@field family string Family name
---@field win? number Window ID (0 for current)
---@field buf? number Buffer ID (0 for current, uses its window)
---@field on_padding? fun(pads: table<integer, integer>, source_buf: integer?) Called whenever the panel's padding in the source window changes: `pads[line] = n` blank rows below source `line` (empty table when cleared). Use it to mirror the rows into windows kept row-aligned with the source (e.g. the other side of a diff).

--- Open the aside panel for a window
---@param opts Aside.OpenAsideOpts
---@return integer? win The panel window, or nil on failure
function M.open_aside(opts)
  return display.open_aside(opts)
end

--- Re-render a window's aside panel, following its source buffer when the
--- buffer was swapped or renamed without a BufEnter/BufWinEnter.
---@param win? number Source or panel window ID (0 for current)
function M.refresh_aside(win)
  require("aside.display.aside").refresh(win)
end

--- Close the aside panel for a window
---@param win? number Window ID (0 for current)
function M.close_aside(win)
  display.close_aside(win)
end

--- Change which family is shown in a window's aside panel
---@param win number Window ID (0 for current)
---@param family string Family name
function M.set_aside_family(win, family)
  display.set_aside_family(win, family)
end

-- ============================================================================
-- Events API
-- ============================================================================

---@alias Aside.EventName
---| "annotation_added"
---| "annotation_updated"
---| "annotation_deleted"
---| "annotation_relocated"

---@class Aside.AnnotationAddedData
---@field annotation Aside.Annotation

---@class Aside.AnnotationUpdatedData
---@field annotation Aside.Annotation
---@field old_annotation Aside.Annotation

---@class Aside.AnnotationDeletedData
---@field annotation Aside.Annotation

---@class Aside.AnnotationRelocatedData
---@field annotation Aside.Annotation
---@field old_position { start_line: number, end_line: number }
---@field is_external_reload boolean

--- Register an event callback
---@param event Aside.EventName
---@param callback function
---@return function unsubscribe
function M.on(event, callback)
  return state.on(event, callback)
end

return M
