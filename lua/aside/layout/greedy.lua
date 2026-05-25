---@diagnostic disable: undefined-global, undefined-field
local nvim = _G.vim
local M = {}

-- Split a single logical line (no newlines inside) into chunks of at most
-- `width` bytes, preferring to break at whitespace. Byte-level for now;
-- multi-byte UTF-8 may yield slightly off widths but does not corrupt text.
local function wrap_text(text, width)
  if width <= 0 or #text <= width then
    return { text }
  end
  local result = {}
  local pos = 1
  while pos <= #text do
    local chunk = text:sub(pos, pos + width - 1)
    local last_space = chunk:reverse():find("%s")
    if last_space and pos + width <= #text then
      chunk = chunk:sub(1, #chunk - last_space)
    end
    table.insert(result, chunk)
    pos = pos + #chunk
    while text:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end
  if #result == 0 then
    result = { "" }
  end
  return result
end

-- Take an annotation's full `contents` string (may have \n separators) and
-- return an ordered list of wrapped chunks ready for placement.
local function wrap_content(text, width)
  local logical = nvim.split(text, "\n", { plain = true })
  local result = {}
  for _, line in ipairs(logical) do
    if line == "" then
      table.insert(result, "")
    else
      local chunks = wrap_text(line, width)
      for _, c in ipairs(chunks) do
        table.insert(result, c)
      end
    end
  end
  return result
end

-- DESIGN.md ordering:
-- 1) sort_key (ann with sort_key wins; ascending among themselves)
-- 2) end_line ascending
-- 3) start_line ascending
-- 4) family alphabetical
-- 5) created_at ascending
local function compare_annotations(a, b)
  if a.sort_key ~= nil and b.sort_key ~= nil then
    if a.sort_key ~= b.sort_key then
      return a.sort_key < b.sort_key
    end
  elseif a.sort_key ~= nil then
    return true
  elseif b.sort_key ~= nil then
    return false
  end
  if a.end_line ~= b.end_line then
    return a.end_line < b.end_line
  end
  if a.start_line ~= b.start_line then
    return a.start_line < b.start_line
  end
  local af = a.family or ""
  local bf = b.family or ""
  if af ~= bf then
    return af < bf
  end
  local ac = a.created_at or 0
  local bc = b.created_at or 0
  return ac < bc
end

local function sort_annotations(annotations)
  local sorted = {}
  for _, a in ipairs(annotations) do
    table.insert(sorted, a)
  end
  table.sort(sorted, compare_annotations)
  return sorted
end

-- How many visual rows the annotation would like to occupy after wrapping.
-- Always at least the anchor span (we cannot collapse rows belonging to the
-- source anchor range).
local function compute_rendered_rows(ann, wrap_width)
  local rendered = 0
  if ann.title and ann.title ~= "" then
    rendered = rendered + 1
  end
  if ann.contents and ann.contents ~= "" then
    local lines = nvim.split(ann.contents, "\n", { plain = true })
    for _, line in ipairs(lines) do
      if line == "" then
        rendered = rendered + 1
      else
        local n = math.max(1, math.ceil(#line / math.max(1, wrap_width)))
        rendered = rendered + n
      end
    end
  end
  if rendered == 0 then
    rendered = 1
  end
  local anchor_span = ann.end_line - ann.start_line + 1
  if anchor_span < 1 then anchor_span = 1 end
  return math.max(anchor_span, rendered)
end

---@param annotations Aside.Annotation[]
---@param source_line_count number
---@param options Aside.Layout.SolverOptions
---@return Aside.Layout.Result
function M.solve(annotations, source_line_count, options)
  options = options or {}
  local spill_direction = options.spill_direction or "below"
  local wrap_width = options.wrap_width or 30
  local gutter_icon = options.gutter_icon or "●"

  local sorted = sort_annotations(annotations)

  -- Reserve every annotation's anchor lines up-front so that earlier-sorted
  -- annotations cannot spill into a later annotation's anchor range.
  local anchor_reserved = {}
  for _, ann in ipairs(sorted) do
    local s = math.max(1, ann.start_line)
    local e = math.min(source_line_count, ann.end_line)
    for line = s, e do
      anchor_reserved[line] = true
    end
  end

  local source_owner = {}                  -- source_line -> ann_id
  local virt_alloc = {}                    -- source_line -> { {ann_id, count}, ... }
  local virt_count_by_line = {}            -- source_line -> total virt rows
  local ann_rows = {}                      -- ann_id -> ordered list of visual rows

  for _, ann in ipairs(sorted) do
    local required = compute_rendered_rows(ann, wrap_width)
    local anchor_span = ann.end_line - ann.start_line + 1
    if anchor_span < 1 then anchor_span = 1 end
    local extra = required - anchor_span

    local rows_for_ann = {}

    -- 1. Anchor rows (always claimed)
    for line = ann.start_line, ann.end_line do
      if line >= 1 and line <= source_line_count then
        source_owner[line] = ann.id
        table.insert(rows_for_ann, { kind = "source", source_line = line, is_anchor = true })
      end
    end

    local remaining = extra

    local function try_spill_below()
      local line = ann.end_line + 1
      while remaining > 0 and line <= source_line_count do
        if source_owner[line] == nil and not anchor_reserved[line] then
          source_owner[line] = ann.id
          table.insert(rows_for_ann, { kind = "source", source_line = line, is_anchor = false })
          remaining = remaining - 1
          line = line + 1
        else
          break
        end
      end
    end

    local function try_spill_above()
      local line = ann.start_line - 1
      while remaining > 0 and line >= 1 do
        if source_owner[line] == nil and not anchor_reserved[line] then
          source_owner[line] = ann.id
          table.insert(rows_for_ann, 1, { kind = "source", source_line = line, is_anchor = false })
          remaining = remaining - 1
          line = line - 1
        else
          break
        end
      end
    end

    if remaining > 0 then
      if spill_direction == "above" then
        try_spill_above()
        if remaining > 0 then try_spill_below() end
      else
        try_spill_below()
        if remaining > 0 then try_spill_above() end
      end
    end

    -- 3. Virt_lines fallback for whatever is still missing
    if remaining > 0 then
      local anchor_target = ann.end_line
      if anchor_target < 1 then anchor_target = 1 end
      if anchor_target > source_line_count then anchor_target = source_line_count end
      local existing = virt_count_by_line[anchor_target] or 0
      virt_count_by_line[anchor_target] = existing + remaining
      local list = virt_alloc[anchor_target]
      if list == nil then
        list = {}
        virt_alloc[anchor_target] = list
      end
      table.insert(list, { ann_id = ann.id, count = remaining })
      for i = 1, remaining do
        table.insert(rows_for_ann, {
          kind = "virt",
          source_line = anchor_target,
          virt_idx = existing + i,
        })
      end
      remaining = 0
    end

    ann_rows[ann.id] = rows_for_ann
  end

  -- Decide per-row text/segment for every annotation. Title sits on the row
  -- aligned to ann.start_line; remaining rows take content segments in
  -- visual order; leftover rows become spill.
  local ann_row_content = {}
  for _, ann in ipairs(sorted) do
    local rows = ann_rows[ann.id]
    local title_text = nil
    if ann.title and ann.title ~= "" then
      title_text = gutter_icon .. " " .. ann.title
    end
    local segments = {}
    if ann.contents and ann.contents ~= "" then
      local chunks = wrap_content(ann.contents, wrap_width)
      for i, c in ipairs(chunks) do
        table.insert(segments, { text = c, segment_idx = i })
      end
    end

    local title_visual_idx = nil
    for i, row in ipairs(rows) do
      if row.kind == "source" and row.source_line == ann.start_line then
        title_visual_idx = i
        break
      end
    end

    local content = {}
    local seg_idx = 1
    for i, _ in ipairs(rows) do
      if i == title_visual_idx and title_text ~= nil then
        content[i] = { row_kind = "title", segment_idx = 0, text = title_text }
      elseif seg_idx <= #segments then
        local seg = segments[seg_idx]
        content[i] = { row_kind = "content", segment_idx = seg.segment_idx, text = seg.text }
        seg_idx = seg_idx + 1
      else
        content[i] = { row_kind = "spill", segment_idx = nil, text = "" }
      end
    end
    ann_row_content[ann.id] = content
  end

  -- Per-annotation totals for box/anchor position glyph computation.
  local ann_meta = {}
  for _, ann in ipairs(sorted) do
    local rows = ann_rows[ann.id]
    local first_anchor_idx, last_anchor_idx
    for i, row in ipairs(rows) do
      if row.is_anchor then
        if first_anchor_idx == nil then first_anchor_idx = i end
        last_anchor_idx = i
      end
    end
    ann_meta[ann.id] = {
      total_rows = #rows,
      first_anchor_idx = first_anchor_idx,
      last_anchor_idx = last_anchor_idx,
    }
  end

  local function position_for(ann_id, visual_idx, is_anchor)
    local meta = ann_meta[ann_id]
    local total = meta.total_rows
    local box
    if total == 1 then
      box = "single"
    elseif visual_idx == 1 then
      box = "top"
    elseif visual_idx == total then
      box = "bottom"
    else
      box = "middle"
    end

    local anchor
    if not is_anchor then
      anchor = "none"
    else
      if meta.first_anchor_idx == meta.last_anchor_idx then
        anchor = "single"
      elseif visual_idx == meta.first_anchor_idx then
        anchor = "top"
      elseif visual_idx == meta.last_anchor_idx then
        anchor = "bottom"
      else
        anchor = "middle"
      end
    end
    return box, anchor
  end

  -- Index ann_rows for quick lookup when emitting.
  local ann_row_index = {}
  for ann_id, rows in pairs(ann_rows) do
    local map = {}
    for i, row in ipairs(rows) do
      if row.kind == "source" then
        map["s:" .. row.source_line] = i
      else
        map["v:" .. row.source_line .. ":" .. row.virt_idx] = i
      end
    end
    ann_row_index[ann_id] = map
  end

  local result_rows = {}

  local function emit_empty(source_line)
    table.insert(result_rows, {
      source_line = source_line,
      ann_id = nil,
      row_kind = "empty",
      segment_idx = nil,
      text = "",
      is_anchor = false,
      box_position = "none",
      anchor_position = "none",
    })
  end

  local function emit_ann_row(ann_id, source_line, visual_idx, is_anchor)
    local content = ann_row_content[ann_id][visual_idx]
    local box, anchor = position_for(ann_id, visual_idx, is_anchor)
    table.insert(result_rows, {
      source_line = source_line,
      ann_id = ann_id,
      row_kind = content.row_kind,
      segment_idx = content.segment_idx,
      text = content.text,
      is_anchor = is_anchor,
      box_position = box,
      anchor_position = anchor,
    })
  end

  for source_line = 1, source_line_count do
    local owner = source_owner[source_line]
    if owner then
      local visual_idx = ann_row_index[owner]["s:" .. source_line]
      local row_data = ann_rows[owner][visual_idx]
      emit_ann_row(owner, source_line, visual_idx, row_data.is_anchor)
    else
      emit_empty(source_line)
    end

    local list = virt_alloc[source_line]
    if list then
      local consumed = 0
      for _, alloc in ipairs(list) do
        for _ = 1, alloc.count do
          consumed = consumed + 1
          local visual_idx = ann_row_index[alloc.ann_id]["v:" .. source_line .. ":" .. consumed]
          emit_ann_row(alloc.ann_id, source_line, visual_idx, false)
        end
      end
    end
  end

  return {
    rows = result_rows,
    virt_lines_by_source_line = virt_count_by_line,
  }
end

require("aside.layout").register("greedy", M)

return M
