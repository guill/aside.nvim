--- Layout row types define the contract between layout solving and display.
--- Each row maps exactly one aside-buffer line, while source-line bookkeeping
--- records where virtual lines must be inserted beneath the original code.

---@class Aside.Layout.Row
---@field source_line number which source visual row this aside row aligns to (1-indexed)
---@field ann_id string? annotation owning this row (nil for empty rows)
---@field row_kind "empty"|"title"|"content"|"spill" type of row
---@field segment_idx number? logical segment index within annotation (0=title, 1+=content lines)
---@field text string buffer text for this row (empty string for empty/spill rows)
---@field is_anchor boolean true if source_line is one of the annotation's real anchor lines
---@field box_position "top"|"middle"|"bottom"|"single"|"none" outer-column statuscolumn glyph
---@field anchor_position "top"|"middle"|"bottom"|"single"|"none" inner-column statuscolumn glyph

---@class Aside.Layout.Result
---@field rows Aside.Layout.Row[] one entry per aside buffer line
---@field virt_lines_by_source_line table<number, number> map source line number → count of virt_lines to insert BELOW it

---@class Aside.Layout.SolverOptions
---@field spill_direction "above"|"below" default "below"
---@field wrap_width number column width available for content text
---@field gutter_icon string for title-row computation

---@class Aside.Layout.Solver
---@field solve fun(annotations: Aside.Annotation[], source_line_count: number, options: Aside.Layout.SolverOptions): Aside.Layout.Result

local M = {}

return M
