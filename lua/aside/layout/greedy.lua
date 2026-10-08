local M = {}

local CLOSER_TEXT = string.rep("\226\148\128", 13) -- "─" x 13

local function width_of(s)
  return vim.fn.strdisplaywidth(s)
end

--- Split one logical line into chunks of display width <= `width`, breaking
--- at whitespace when possible and on character (not byte) boundaries.
--- Each chunk records `sep`, the whitespace dropped before it, so joining
--- `chunk[1].text .. chunk[2].sep .. chunk[2].text ..` restores `text`.
---@param text string
---@param width integer
---@return {text: string, sep: string?}[]
function M.wrap(text, width)
  local chunks, sep, rest = {}, nil, text
  while width >= 1 and width_of(rest) > width do
    local lo, hi = 1, vim.fn.strchars(rest)
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if width_of(vim.fn.strcharpart(rest, 0, mid)) <= width then lo = mid else hi = mid - 1 end
    end
    local head = vim.fn.strcharpart(rest, 0, lo)
    local after = rest:sub(#head + 1)
    local cut_sep
    if after:match("^%s") then
      cut_sep = after:match("^%s+")
    else
      local s = head:find("%s+%S*$")
      if s and s > 1 then
        cut_sep = head:sub(s):match("^%s+")
        head = head:sub(1, s - 1)
      else
        cut_sep = ""
      end
    end
    rest = rest:sub(#head + #cut_sep + 1)
    if rest == "" then
      table.insert(chunks, { text = head .. cut_sep, sep = sep })
      return chunks
    end
    table.insert(chunks, { text = head, sep = sep })
    sep = cut_sep
  end
  table.insert(chunks, { text = rest, sep = sep })
  return chunks
end

-- DESIGN.md ordering for annotations stacked on the same line.
local function compare_annotations(a, b)
  if a.sort_key ~= nil and b.sort_key ~= nil then
    if a.sort_key ~= b.sort_key then return a.sort_key < b.sort_key end
  elseif a.sort_key ~= nil then
    return true
  elseif b.sort_key ~= nil then
    return false
  end
  if a.end_line ~= b.end_line then return a.end_line < b.end_line end
  if a.start_line ~= b.start_line then return a.start_line < b.start_line end
  if (a.family or "") ~= (b.family or "") then return (a.family or "") < (b.family or "") end
  return (a.created_at or 0) < (b.created_at or 0)
end

-- Text rows of one annotation in reading order: title, then contents.
local function text_rows(ann, width, icon)
  local rows = {}
  if ann.title and ann.title ~= "" then
    local prefix = icon .. " "
    for i, c in ipairs(M.wrap(ann.title, width - width_of(prefix))) do
      table.insert(rows, { row_kind = "title", segment_idx = 0, text = (i == 1 and prefix or "") .. c.text, sep = c.sep })
    end
  end
  if ann.contents and ann.contents ~= "" then
    for seg, line in ipairs(vim.split(ann.contents, "\n", { plain = true })) do
      for _, c in ipairs(M.wrap(line, width)) do
        table.insert(rows, { row_kind = "content", segment_idx = seg, text = c.text, sep = c.sep })
      end
    end
  end
  return rows
end

--- Lay annotations out as aside rows grouped into one block per source line.
--- An annotation's rows are contiguous and start at the block of its
--- start_line when that block is free. Rows continue into following free
--- blocks up to the next annotation's start line; anything beyond becomes
--- extra rows inside the last block (the source gets padding for those).
--- When the room below is short, the box starts higher (spills above).
---@param annotations Aside.Annotation[]
---@param source_line_count number
---@param options Aside.Layout.SolverOptions
---@return Aside.Layout.Result
function M.solve(annotations, source_line_count, options)
  options = options or {}
  local n_lines = math.max(1, source_line_count)
  local width = options.wrap_width or 30
  local icon = options.gutter_icon or "\226\151\143"
  local above = options.spill_direction == "above"

  local anns = {}
  for _, a in ipairs(annotations) do
    local s = math.min(math.max(1, a.start_line), n_lines)
    local e = math.min(math.max(s, a.end_line or s), n_lines)
    table.insert(anns, setmetatable({ s = s, e = e }, { __index = a }))
  end
  table.sort(anns, function(a, b)
    if a.s ~= b.s then return a.s < b.s end
    return compare_annotations(a, b)
  end)

  local blocks = {} -- source_line -> rows placed in that block
  for line = 1, n_lines do blocks[line] = {} end
  local last_used = 0
  local meta = {}

  for i, a in ipairs(anns) do
    local limit = n_lines
    for j = i + 1, #anns do
      if anns[j].s > a.s then limit = anns[j].s - 1 break end
    end

    local rows = text_rows(a, width, icon)
    local want = math.max(#rows, 1, math.min(a.e, limit) - a.s + 1)
    while #rows < want do table.insert(rows, { row_kind = "spill", text = "" }) end
    local n = #rows

    local first_free = last_used + 1
    local line
    if a.s < first_free then
      line = last_used -- start block already taken: continue as extra rows
    elseif above then
      line = math.max(first_free, math.min(a.s, math.min(a.e, limit) - n + 1))
    elseif n <= limit - a.s + 1 then
      line = a.s
    else
      line = math.max(first_free, math.min(a.s, limit - n + 1))
    end

    for k, row in ipairs(rows) do
      row.ann_id = a.id
      table.insert(blocks[line], row)
      if k < n and line + 1 <= limit and #blocks[line + 1] == 0 then line = line + 1 end
    end
    if n >= 2 then
      table.insert(blocks[line], { ann_id = a.id, row_kind = "closer", text = CLOSER_TEXT })
    end
    last_used = math.max(last_used, line)
    table.insert(meta, { id = a.id, start_line = a.s, end_line = a.e })
  end

  local result, extra = {}, {}
  for line = 1, n_lines do
    local list = blocks[line]
    if #list == 0 then
      list = { { row_kind = "empty", text = "" } }
    elseif #list > 1 then
      extra[line] = #list - 1
    end
    for _, row in ipairs(list) do
      row.source_line = line
      table.insert(result, row)
    end
  end

  require("aside.layout").decorate(result, meta)
  return { rows = result, virt_lines_by_source_line = extra, annotations = meta }
end

require("aside.layout").register("greedy", M)

return M
