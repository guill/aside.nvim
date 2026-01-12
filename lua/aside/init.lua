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

---@class Aside.SetupOpts
---@field context_lines? number Lines of context stored around annotated text (default: 3)
---@field persistence_debounce_ms? number Debounce time for persistence writes (default: 1000)
---@field default_display? "hidden"|"hover"|"below"|"aside" Default display mode for new families (default: "hover")
---@field default_gutter_icon? string Default gutter icon for hover mode (default: "●")
---@field data_dir? string Directory for storing annotation data (default: ".aside")
---@field highlight_groups? table<string, table> Default highlight groups

--- Initialize aside.nvim with the given options
---@param opts? Aside.SetupOpts
function M.setup(opts)
  config.setup(opts or {})
  state.initialize()
  persistence.setup()
  display.setup()
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
---@field highlight_groups? table<string, string> Highlight group overrides

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

--- Open the aside panel for a window
---@param opts Aside.OpenAsideOpts
function M.open_aside(opts)
  display.open_aside(opts)
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
