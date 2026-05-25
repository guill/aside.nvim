---@diagnostic disable: undefined-global
--- BufWriteCmd save parser for the aside buffer.
---
--- Responsibility: read the live extmark regions in the aside buffer,
--- reconstruct logical annotation text from buffer lines (collapsing wrap
--- continuations, preserving naked-line splits), diff against the stored
--- annotations, and apply updates / deletions via the annotations API.
---
--- This module never touches the source buffer, never modifies extmarks,
--- and never re-renders the aside buffer. Re-render is the caller's job.

local nvim = _G.vim
local M = {}

local extmarks = require("aside.display.aside_extmarks")
local annotations_mod = require("aside.annotations")
local state = require("aside.state")
local config = require("aside.config")

--- Resolve the gutter-icon prefix (`"<icon> "`) that the aside renderer
--- prepends to every annotation's title row. The parser strips this prefix
--- before storing so that repeated `:w` cycles do not compound the icon into
--- the persisted title (CRITICAL-1).
---@param family_name string|nil
---@return string prefix Empty string if no prefix should be stripped
local function get_title_prefix(family_name)
  local gutter_icon
  if family_name then
    local family = state.get_family(family_name)
    local family_config = (family and family.get_config and family:get_config()) or {}
    gutter_icon = family_config.gutter_icon
  end
  gutter_icon = gutter_icon
    or config.get_value("default_gutter_icon", "\226\151\143")
  if type(gutter_icon) ~= "string" or gutter_icon == "" then
    return ""
  end
  return gutter_icon .. " "
end

local function buf_is_valid(buf)
  local ok, valid = pcall(nvim.api.nvim_buf_is_valid, buf)
  return ok and valid
end

--- Read buffer lines in the inclusive 0-indexed row range [start_row, end_row].
---@param buf integer
---@param start_row integer 0-indexed
---@param end_row integer 0-indexed (inclusive)
---@return string[]
local function get_lines(buf, start_row, end_row)
  if start_row > end_row then
    return {}
  end
  local ok, lines = pcall(
    nvim.api.nvim_buf_get_lines,
    buf,
    start_row,
    end_row + 1,
    false
  )
  if not ok or type(lines) ~= "table" then
    return {}
  end
  return lines
end

--- Reconstruct the logical text of a single segment from its buffer lines.
--- A segment owns rows [seg_start_row .. next_seg_start_row - 1].
--- Within that range:
---   - row `seg_start` is the first logical chunk
---   - `wrap_cont` rows are display-wrap continuations → join with no separator
---   - `none` rows are user-inserted naked lines → join with "\n"
---@param buf integer
---@param start_row integer 0-indexed
---@param end_row integer 0-indexed inclusive
---@return string
local function reconstruct_segment(buf, start_row, end_row)
  local lines = get_lines(buf, start_row, end_row)
  if #lines == 0 then
    return ""
  end
  local pieces = { lines[1] }
  for i = 2, #lines do
    local row = start_row + i - 1
    local role = extmarks.get_role_at(buf, row)
    local sep
    if role == "wrap_cont" then
      sep = ""
    else
      -- "none" naked line, or anything else we treat as a hard newline
      sep = "\n"
    end
    pieces[#pieces + 1] = sep
    pieces[#pieces + 1] = lines[i]
  end
  return table.concat(pieces)
end

--- Parse the aside buffer into a structured diff against stored annotations.
---@param buf integer
---@param layout table Layout result (unused here; reserved for Task 10 type_creates)
---@param family_name string|nil Family name (used to resolve gutter-icon prefix
---  for title stripping; without it, falls back to the global default icon).
---@return table parse_result `{updates, deletions, type_creates}`
function M.parse(buf, layout, family_name)
  local result = {
    updates = {},
    deletions = {},
    type_creates = {},
  }

  if not buf_is_valid(buf) then
    return result
  end

  local regions = extmarks.get_regions(buf)
  if type(regions) ~= "table" then
    return result
  end

  local title_prefix = get_title_prefix(family_name)

  for _, region in ipairs(regions) do
    local ann_id = region.ann_id
    if ann_id ~= nil then
      if region.collapsed then
        table.insert(result.deletions, ann_id)
      else
        local stored = state.get_annotation(ann_id)
        if stored ~= nil then
          local segments = region.segments or {}
          local title_text = nil
          local content_pieces = {}

          for _, segment in ipairs(segments) do
            local buf_lines = segment.buf_lines or {}
            local seg_start = buf_lines[1]
            local seg_end = buf_lines[2]
            if type(seg_start) == "number" and type(seg_end) == "number" then
              local text = reconstruct_segment(buf, seg_start, seg_end)
              if (segment.segment_idx or 0) == 0 then
                -- Strip the renderer-injected gutter-icon prefix so the
                -- persisted title matches the user's logical title.
                if title_prefix ~= "" and vim.startswith(text, title_prefix) then
                  text = text:sub(#title_prefix + 1)
                end
                title_text = text
              else
                table.insert(content_pieces, text)
              end
            end
          end

          local new_contents = table.concat(content_pieces, "\n")
          local changes = {}

          if title_text ~= nil and title_text ~= (stored.title or "") then
            changes.title = title_text
          end
          if new_contents ~= (stored.contents or "") then
            changes.contents = new_contents
          end

          if not vim.tbl_isempty(changes) then
            result.updates[ann_id] = changes
          end
        end
      end
    end
  end

  -- type-to-create: each maximal run of non-empty out-of-region rows becomes
  -- one new annotation anchored to the run's first row's source_line.
  -- Padding rows (virt_lines) have no real source line → reject with WARN.
  local layout_rows = (layout and layout.rows) or {}
  local virt_counts = (layout and layout.virt_lines_by_source_line) or {}

  local ok_count, line_count = pcall(nvim.api.nvim_buf_line_count, buf)
  if not ok_count or type(line_count) ~= "number" then
    return result
  end

  -- Pre-compute, for each aside row index (1-indexed), whether that row is a
  -- virt_line padding row. A virt_line padding row is any row whose
  -- source_line has at least one virt_line allocated and which is NOT the
  -- first row in layout.rows carrying that source_line.
  local is_virt_padding = {}
  local first_seen_for_src = {}
  for i = 1, #layout_rows do
    local lr = layout_rows[i]
    if lr and type(lr.source_line) == "number" then
      local src = lr.source_line
      if (virt_counts[src] or 0) > 0 then
        if first_seen_for_src[src] == nil then
          first_seen_for_src[src] = i
          is_virt_padding[i] = false
        else
          is_virt_padding[i] = true
        end
      else
        is_virt_padding[i] = false
      end
    end
  end

  local function flush_run(run)
    if not run then return end
    local first_row = layout_rows[run.start_aside_row + 1]
    local source_line = (first_row and type(first_row.source_line) == "number")
        and first_row.source_line
        or 1
    table.insert(result.type_creates, {
      source_line = source_line,
      contents = table.concat(run.lines, "\n"),
    })
  end

  local current_run = nil
  for row = 0, line_count - 1 do
    local role = extmarks.get_role_at(buf, row)
    local lines = get_lines(buf, row, row)
    local line_text = lines[1] or ""
    local layout_row = layout_rows[row + 1]

    -- A row is "in-region" if either (a) an aside_edit_regions extmark
    -- lives on it, or (b) the layout assigns it to an annotation (this
    -- catches naked Enter lines inside an annotation region whose role
    -- reports "none").
    local in_region = (role ~= "none")
    if layout_row and layout_row.ann_id ~= nil then
      in_region = true
    end

    -- Trim whitespace from type-to-create lines so the `A <text>` keystroke
    -- pattern (which leaves a leading space) does not corrupt the stored
    -- contents. Whitespace-only rows are treated the same as empty rows
    -- (run-terminating).
    local trimmed = vim.trim(line_text)

    if not in_region and trimmed ~= "" then
      if is_virt_padding[row + 1] then
        nvim.notify(
          "aside: cannot create annotation on padding row (virt_line)",
          nvim.log.levels.WARN
        )
        -- Break any in-flight run; do not include this line.
        flush_run(current_run)
        current_run = nil
      else
        if not current_run then
          current_run = { start_aside_row = row, lines = {} }
        end
        table.insert(current_run.lines, trimmed)
      end
    else
      flush_run(current_run)
      current_run = nil
    end
  end
  flush_run(current_run)

  return result
end

--- Apply a parse_result to the annotations store.
---@param parse_result table `{updates, deletions, type_creates}`
---@param buf integer Aside buffer (unused; reserved for symmetry)
---@param source_path string|nil Source file path (unused here)
---@param family_name string|nil Family name (unused here)
---@return table actions List of `{ann_id, action}` tuples for logging
function M.commit(parse_result, buf, source_path, family_name)
  local actions = {}

  if type(parse_result) ~= "table" then
    return actions
  end

  for ann_id, changes in pairs(parse_result.updates or {}) do
    annotations_mod.update(ann_id, changes)
    table.insert(actions, { ann_id = ann_id, action = "update" })
  end

  for _, ann_id in ipairs(parse_result.deletions or {}) do
    annotations_mod.delete(ann_id)
    table.insert(actions, { ann_id = ann_id, action = "delete" })
  end

  for _, tc in ipairs(parse_result.type_creates or {}) do
    if family_name and source_path then
      local new_id = annotations_mod.add({
        family = family_name,
        file = source_path,
        start_line = tc.source_line,
        end_line = tc.source_line,
        title = "",
        contents = tc.contents,
      })
      if new_id then
        table.insert(actions, { ann_id = new_id, action = "create" })
      end
    end
  end

  return actions
end

--- Confirm deletions interactively. Mutates `parse_result.deletions` in place,
--- keeping only the annotation ids the user (or test default) approved.
---@param parse_result table
local function confirm_deletions(parse_result)
  local pending = parse_result.deletions or {}
  if #pending == 0 then
    return
  end

  local approved = {}

  local select_fn = nvim.ui and nvim.ui.select
  if type(select_fn) ~= "function" then
    -- No interactive UI available (e.g. headless tests). Safe default: cancel.
    parse_result.deletions = approved
    return
  end

  for _, ann_id in ipairs(pending) do
    local ann = state.get_annotation(ann_id)
    local label = (ann and ann.title and ann.title ~= "") and ann.title or "<no title>"
    local choice = nil
    local ok = pcall(function()
      select_fn(
        { "Delete annotation", "Cancel save and restore" },
        { prompt = 'Delete annotation "' .. label .. '"?' },
        function(picked)
          choice = picked
        end
      )
    end)
    if ok and choice == "Delete annotation" then
      table.insert(approved, ann_id)
    end
  end

  parse_result.deletions = approved
end

--- BufWriteCmd entry point. Parses, confirms deletions, commits, clears modified.
---@param buf integer Aside buffer id
---@param source_path string|nil Source file path
---@param family_name string|nil Family name
---@param layout table Layout result for this aside buffer
---@return table parse_result (caller re-renders based on this)
function M.handle_save(buf, source_path, family_name, layout)
  local parse_result = M.parse(buf, layout, family_name)

  if #parse_result.deletions > 0 then
    confirm_deletions(parse_result)
  end

  M.commit(parse_result, buf, source_path, family_name)

  if buf_is_valid(buf) then
    pcall(function()
      nvim.bo[buf].modified = false
    end)
  end

  return parse_result
end

return M
