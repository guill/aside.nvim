local M = {}

local context = require("aside.context")

local function build_line_index(file_lines)
  local index = {}
  for i, line in ipairs(file_lines) do
    if not index[line] then
      index[line] = {}
    end
    table.insert(index[line], i)
  end
  return index
end

local function sequence_matches(file_lines, start_pos, expected_lines)
  if #expected_lines == 0 then
    return true
  end
  for i, expected in ipairs(expected_lines) do
    local file_line = file_lines[start_pos + i - 1]
    if file_line ~= expected then
      return false
    end
  end
  return true
end

local function concat_tables(tbl1, tbl2, tbl3)
  local result = {}
  for _, v in ipairs(tbl1 or {}) do
    table.insert(result, v)
  end
  for _, v in ipairs(tbl2 or {}) do
    table.insert(result, v)
  end
  if tbl3 then
    for _, v in ipairs(tbl3) do
      table.insert(result, v)
    end
  end
  return result
end

local function find_sequence_starts(line_index, file_lines, sequence)
  if #sequence == 0 then
    return {}
  end
  local first_line = sequence[1]
  local candidates = line_index[first_line] or {}
  local matches = {}
  for _, pos in ipairs(candidates) do
    if pos + #sequence - 1 <= #file_lines and sequence_matches(file_lines, pos, sequence) then
      table.insert(matches, pos)
    end
  end
  return matches
end

local function find_context_gap(line_index, file_lines, ctx_before, ctx_after, expected_gap)
  if #ctx_before == 0 or #ctx_after == 0 then
    return nil
  end
  local before_starts = find_sequence_starts(line_index, file_lines, ctx_before)
  for _, before_start in ipairs(before_starts) do
    local before_end = before_start + #ctx_before - 1
    local expected_after_start = before_end + expected_gap + 1
    local search_margin = math.max(100, expected_gap - 1)
    local search_start = math.max(before_end + 1, expected_after_start - search_margin)
    local search_end = math.min(#file_lines, expected_after_start + search_margin)
    for after_start = search_start, search_end do
      if sequence_matches(file_lines, after_start, ctx_after) then
        local gap_start = before_end + 1
        local gap_end = after_start - 1
        if gap_end >= gap_start then
          return { gap_start = gap_start, gap_end = gap_end }
        end
      end
    end
  end
  return nil
end

local function shallow_copy(tbl)
  local copy = {}
  for i, v in ipairs(tbl) do
    copy[i] = v
  end
  return copy
end

local function has_meaningful_content(ctx)
  for _, line in ipairs(ctx) do
    if line:match("%S") then
      return true
    end
  end
  return false
end

local function relocate_single(annotation, file_lines, line_index)
  local content = annotation.marked_content or {}
  local ctx_before = annotation.context_before or {}
  local ctx_after = annotation.context_after or {}
  local content_len = #content
  local unchanged_result = {
    annotation_id = annotation.id,
    status = "unchanged",
    new_start = annotation.start_line,
    new_end = annotation.end_line,
  }
  if content_len == 0 and #ctx_before == 0 and #ctx_after == 0 then
    return unchanged_result
  end
  local full_sequence = concat_tables(ctx_before, content, ctx_after)
  if #full_sequence > 0 then
    local full_matches = find_sequence_starts(line_index, file_lines, full_sequence)
    if #full_matches == 1 then
      local new_start = full_matches[1] + #ctx_before
      return {
        annotation_id = annotation.id,
        status = "exact",
        new_start = new_start,
        new_end = new_start + content_len - 1,
      }
    end
  end
  if content_len > 0 then
    local content_matches = find_sequence_starts(line_index, file_lines, content)
    if #content_matches == 1 then
      return {
        annotation_id = annotation.id,
        status = "content_only",
        new_start = content_matches[1],
        new_end = content_matches[1] + content_len - 1,
      }
    end
  end
  if content_len >= 2 and (#ctx_before > 0 or #ctx_after > 0) then
    local anchor_sequence = concat_tables(ctx_before, { content[1], content[content_len] }, ctx_after)
    local anchor_matches = find_sequence_starts(line_index, file_lines, anchor_sequence)
    if #anchor_matches == 1 then
      local new_start = anchor_matches[1] + #ctx_before
      return {
        annotation_id = annotation.id,
        status = "anchors_context",
        new_start = new_start,
        new_end = new_start + content_len - 1,
      }
    end
  end
  if #ctx_before > 0 and #ctx_after > 0 then
    local gap_result = find_context_gap(line_index, file_lines, ctx_before, ctx_after, content_len)
    if gap_result then
      return {
        annotation_id = annotation.id,
        status = "context_only",
        new_start = gap_result.gap_start,
        new_end = gap_result.gap_end,
      }
    end
  end
  local shrunk_before = shallow_copy(ctx_before)
  local shrunk_after = shallow_copy(ctx_after)
  while #shrunk_before > 0 or #shrunk_after > 0 do
    if #shrunk_before > 0 then
      table.remove(shrunk_before, 1)
    end
    if #shrunk_after > 0 then
      table.remove(shrunk_after)
    end
    if content_len > 0 then
      local shrunk_sequence = concat_tables(shrunk_before, content, shrunk_after)
      if #shrunk_sequence > 0 then
        local shrunk_matches = find_sequence_starts(line_index, file_lines, shrunk_sequence)
        if #shrunk_matches == 1 then
          local new_start = shrunk_matches[1] + #shrunk_before
          return {
            annotation_id = annotation.id,
            status = "partial_context",
            new_start = new_start,
            new_end = new_start + content_len - 1,
          }
        end
      end
    end
    if #shrunk_before > 0 and #shrunk_after > 0 then
      if has_meaningful_content(shrunk_before) or has_meaningful_content(shrunk_after) then
        local gap_result = find_context_gap(line_index, file_lines, shrunk_before, shrunk_after, content_len)
        if gap_result then
          return {
            annotation_id = annotation.id,
            status = "partial_context",
            new_start = gap_result.gap_start,
            new_end = gap_result.gap_end,
          }
        end
      end
    end
  end
  return unchanged_result
end

function M.relocate_annotations_for_file(file_path, annotations)
  local file_lines = context.read_file_lines(file_path, { force_disk = true })
  if not file_lines then
    local results = {}
    for _, ann in ipairs(annotations) do
      table.insert(results, {
        annotation_id = ann.id,
        status = "unchanged",
        new_start = ann.start_line,
        new_end = ann.end_line,
      })
    end
    return results
  end
  local line_index = build_line_index(file_lines)
  local results = {}
  for _, annotation in ipairs(annotations) do
    if context.has_context(annotation) then
      table.insert(results, relocate_single(annotation, file_lines, line_index))
    else
      table.insert(results, {
        annotation_id = annotation.id,
        status = "unchanged",
        new_start = annotation.start_line,
        new_end = annotation.end_line,
      })
    end
  end
  return results
end

function M.relocate_all_annotations(annotations)
  local annotations_by_file = {}
  for _, annotation in ipairs(annotations) do
    local path = annotation.file
    if not annotations_by_file[path] then
      annotations_by_file[path] = {}
    end
    table.insert(annotations_by_file[path], annotation)
  end
  local all_results = {}
  for file_path, file_annotations in pairs(annotations_by_file) do
    local results = M.relocate_annotations_for_file(file_path, file_annotations)
    for _, result in ipairs(results) do
      table.insert(all_results, result)
    end
  end
  return all_results
end

return M
