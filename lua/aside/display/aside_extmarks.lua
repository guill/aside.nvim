---@diagnostic disable: undefined-global
--- Extmark role manager for the aside buffer's edit-region tracking.
--- Manages three extmark roles per annotation:
---   - seg_start:  first buffer line of a segment (title or content)
---   - wrap_cont:  continuation line of a wrapped segment (same ann_id + segment_idx as prev)
---   - ann_end:    one-past-last row of an annotation (right_gravity=true)
---
--- This module owns no rendering — it only places and queries metadata extmarks.

local nvim = _G.vim
local M = {}

local ns_id = nvim.api.nvim_create_namespace("aside_edit_regions")

--- Module-local registry: buf -> { extmark_id -> { ann_id, role, segment_idx? } }
---@type table<integer, table<integer, {ann_id: string, role: string, segment_idx: number?}>>
local regions_by_buf = {}

local function buf_is_valid(buf)
  local ok, valid = pcall(nvim.api.nvim_buf_is_valid, buf)
  return ok and valid
end

--- Get the registered namespace (exposed for tests / introspection).
function M.get_namespace_id()
  return ns_id
end

--- Clear all aside_edit_regions extmarks and per-buffer state.
---@param buf integer
function M.clear(buf)
  regions_by_buf[buf] = nil
  if not buf_is_valid(buf) then
    return
  end
  pcall(nvim.api.nvim_buf_clear_namespace, buf, ns_id, 0, -1)
end

--- Internal: place a single extmark and record it in the registry.
local function place_mark(buf, line, opts, ann_id, role, segment_idx)
  local ok, id = pcall(nvim.api.nvim_buf_set_extmark, buf, ns_id, line, 0, opts)
  if ok and type(id) == "number" then
    regions_by_buf[buf][id] = {
      ann_id = ann_id,
      role = role,
      segment_idx = segment_idx,
    }
    return id
  end
  return nil
end

--- Place extmarks for every annotation present in `layout`.
--- Replaces any existing aside_edit_regions extmarks on `buf`.
---@param buf integer
---@param layout Aside.Layout.Result
function M.place(buf, layout)
  M.clear(buf)
  if not buf_is_valid(buf) then
    return
  end
  regions_by_buf[buf] = {}

  if not layout or type(layout.rows) ~= "table" then
    return
  end

  local rows = layout.rows
  local n = #rows
  if n == 0 then
    return
  end

  local ok_count, buf_line_count = pcall(nvim.api.nvim_buf_line_count, buf)
  if not ok_count then
    return
  end

  local prev_ann_id = nil
  local prev_segment_idx = nil
  local ann_order = {}
  local ann_seen = {}
  local ann_last_row = {} -- ann_id -> 1-indexed row position of the last row belonging to that annotation

  for i, row in ipairs(rows) do
    local kind = row.row_kind
    local ann_id = row.ann_id

    if (kind == "title" or kind == "content") and ann_id ~= nil then
      local segment_idx = row.segment_idx
      local buf_line = i - 1 -- 0-indexed buffer row

      if not ann_seen[ann_id] then
        ann_seen[ann_id] = true
        table.insert(ann_order, ann_id)
      end
      ann_last_row[ann_id] = i

      local is_new_segment = (prev_ann_id ~= ann_id) or (prev_segment_idx ~= segment_idx)

      if is_new_segment then
        place_mark(
          buf,
          buf_line,
          { right_gravity = false },
          ann_id,
          "seg_start",
          segment_idx
        )
      else
        -- same annotation, same segment_idx → wrap continuation
        place_mark(
          buf,
          buf_line,
          { right_gravity = false },
          ann_id,
          "wrap_cont",
          segment_idx
        )
      end

      prev_ann_id = ann_id
      prev_segment_idx = segment_idx
    else
      -- empty / spill / nil-ann rows break any in-flight segment continuation
      prev_ann_id = nil
      prev_segment_idx = nil
    end
  end

  -- Place one ann_end per annotation at the row AFTER its last row.
  -- If that would land past the buffer's last line, place it at the last
  -- buffer line with right_gravity=true so it stays pinned to EOF.
  for _, ann_id in ipairs(ann_order) do
    local last_row = ann_last_row[ann_id] -- 1-indexed array position
    local end_line = last_row -- 0-indexed buffer line directly after last_row-1
    if end_line >= buf_line_count then
      end_line = buf_line_count - 1
    end
    if end_line < 0 then
      end_line = 0
    end
    place_mark(
      buf,
      end_line,
      { right_gravity = true },
      ann_id,
      "ann_end",
      nil
    )
  end
end

--- Return one structured region per annotation, computed from live extmark positions.
---@param buf integer
---@return table[] regions
function M.get_regions(buf)
  local result = {}
  if not buf_is_valid(buf) then
    return result
  end
  local entries = regions_by_buf[buf]
  if not entries then
    return result
  end

  -- Group entries by ann_id, resolving live row from each extmark id.
  local by_ann = {}
  local ann_order = {}

  for extmark_id, meta in pairs(entries) do
    local ok, pos = pcall(
      nvim.api.nvim_buf_get_extmark_by_id,
      buf,
      ns_id,
      extmark_id,
      {}
    )
    if ok and type(pos) == "table" and pos[1] ~= nil then
      local row = pos[1]
      local ann_id = meta.ann_id
      if not by_ann[ann_id] then
        by_ann[ann_id] = { starts = {}, ann_end = nil }
        table.insert(ann_order, ann_id)
      end
      if meta.role == "seg_start" then
        table.insert(by_ann[ann_id].starts, {
          row = row,
          segment_idx = meta.segment_idx,
        })
      elseif meta.role == "ann_end" then
        by_ann[ann_id].ann_end = row
      end
      -- wrap_cont marks are not needed for segment shape — their rows are
      -- implied by the gap between this seg_start and the next.
    end
  end

  for _, ann_id in ipairs(ann_order) do
    local data = by_ann[ann_id]
    table.sort(data.starts, function(a, b)
      return (a.segment_idx or 0) < (b.segment_idx or 0)
    end)

    local segments = {}
    local first_start_row = data.starts[1] and data.starts[1].row or nil
    for i, ss in ipairs(data.starts) do
      local next_row
      if i < #data.starts then
        next_row = data.starts[i + 1].row
      else
        next_row = data.ann_end or ss.row
      end
      local end_row = next_row > ss.row and (next_row - 1) or ss.row
      table.insert(segments, {
        kind = (ss.segment_idx == 0) and "title" or "content",
        segment_idx = ss.segment_idx,
        buf_lines = { ss.row, end_row },
      })
    end

    local collapsed = false
    if data.ann_end ~= nil and first_start_row ~= nil then
      collapsed = data.ann_end <= first_start_row
    end

    table.insert(result, {
      ann_id = ann_id,
      segments = segments,
      end_marker_row = data.ann_end,
      collapsed = collapsed,
    })
  end

  return result
end

--- Return the role of the extmark at a given 0-indexed buffer row.
--- Returns "seg_start", "wrap_cont", "ann_end", or "none".
---@param buf integer
---@param row integer 0-indexed buffer row
---@return string role
function M.get_role_at(buf, row)
  if not buf_is_valid(buf) then
    return "none"
  end
  local entries = regions_by_buf[buf]
  if not entries then
    return "none"
  end

  local ok, marks = pcall(
    nvim.api.nvim_buf_get_extmarks,
    buf,
    ns_id,
    { row, 0 },
    { row, -1 },
    { details = false }
  )
  if not ok or type(marks) ~= "table" then
    return "none"
  end

  -- Prefer seg_start > wrap_cont > ann_end if multiple coincide.
  local priority = { seg_start = 3, wrap_cont = 2, ann_end = 1 }
  local best_role = nil
  local best_score = 0
  for _, mark in ipairs(marks) do
    local id = mark[1]
    local mark_row = mark[2]
    if mark_row == row then
      local meta = entries[id]
      if meta then
        local score = priority[meta.role] or 0
        if score > best_score then
          best_score = score
          best_role = meta.role
        end
      end
    end
  end

  return best_role or "none"
end

return M
