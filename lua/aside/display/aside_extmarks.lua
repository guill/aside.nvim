--- Row identity tracking for the aside buffer.
---
--- `place()` puts one mark on every annotation row (namespace
--- aside_edit_regions) and one on every row recording its source line's
--- block (namespace aside_blocks). Marks use `invalidate`, so a deleted row's
--- mark disappears while edits inside a row keep it. `read()` turns the
--- edited buffer back into rows: a row is identified by its leftmost valid
--- mark (`J` moves the joined row's mark to a later column), and rows the
--- user inserted inherit the annotation and block of the row above them.
---
--- Blocks follow source edits: `place()` also marks each block's line in the
--- source buffer, and `read()` reports where that mark is now. A deleted
--- source line's mark falls to the next line, so its rows join that block.

local M = {}

local ns_id = vim.api.nvim_create_namespace("aside_edit_regions")
local block_ns = vim.api.nvim_create_namespace("aside_blocks")

---@type table<integer, {rows: table<integer, table>, blocks: table<integer, integer>, ann_ids: string[]}>
local registry = {}

local function buf_is_valid(buf)
  local ok, valid = pcall(vim.api.nvim_buf_is_valid, buf)
  return ok and valid
end

function M.get_namespace_id()
  return ns_id
end

-- Namespace of the source-line marks owned by aside buffer `buf`.
local function source_ns(buf)
  return vim.api.nvim_create_namespace("aside_source_lines_" .. buf)
end

---@param buf integer
function M.clear(buf)
  local reg = registry[buf]
  if reg and buf_is_valid(reg.source_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, reg.source_buf, source_ns(buf), 0, -1)
  end
  registry[buf] = nil
  if buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns_id, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, buf, block_ns, 0, -1)
  end
end

--- Mark the rows of a freshly rendered buffer. `layout.rows` closer rows are
--- not buffer lines and are skipped.
---@param buf integer
---@param layout Aside.Layout.Result
---@param source_buf? integer Source buffer whose edits blocks should follow
function M.place(buf, layout, source_buf)
  M.clear(buf)
  if not buf_is_valid(buf) then
    return
  end
  local reg = { rows = {}, blocks = {}, ann_ids = {}, line_marks = {} }
  if buf_is_valid(source_buf) then
    reg.source_buf = source_buf
  end
  registry[buf] = reg
  local seen_ann = {}
  local row = 0
  for _, r in ipairs((layout and layout.rows) or {}) do
    if r.row_kind ~= "closer" then
      if r.ann_id then
        local id = vim.api.nvim_buf_set_extmark(buf, ns_id, row, 0, { invalidate = true })
        reg.rows[id] = { ann_id = r.ann_id, row_kind = r.row_kind, sep = r.sep }
        if not seen_ann[r.ann_id] then
          seen_ann[r.ann_id] = true
          table.insert(reg.ann_ids, r.ann_id)
        end
      end
      if r.source_line then
        local id = vim.api.nvim_buf_set_extmark(buf, block_ns, row, 0, { invalidate = true })
        reg.blocks[id] = r.source_line
        if reg.source_buf and not reg.line_marks[r.source_line] then
          local ok, mark = pcall(vim.api.nvim_buf_set_extmark, reg.source_buf, source_ns(buf), r.source_line - 1, 0, {})
          reg.line_marks[r.source_line] = ok and mark or nil
        end
      end
      row = row + 1
    end
  end
end

--- Annotation ids placed by the last `place()`.
---@param buf integer
---@return string[]
function M.placed_ann_ids(buf)
  return (registry[buf] and registry[buf].ann_ids) or {}
end

-- row (0-indexed) -> metadata of the leftmost valid mark on that row
local function leftmost(buf, ns, meta)
  local by_row, col_of = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local id, row, col, details = m[1], m[2], m[3], m[4]
    if meta[id] and not details.invalid and (col_of[row] == nil or col < col_of[row]) then
      by_row[row], col_of[row] = meta[id], col
    end
  end
  return by_row
end

--- Rebuild the aside rows from the live buffer. Returns one entry per buffer
--- line (fields: lnum, source_line, text, ann_id?, row_kind, sep?) with a
--- synthetic `row_kind = "closer"` entry (no lnum) after the last row of each
--- annotation that has two or more rows.
---@param buf integer
---@param layout table? Fallback source lines for unmarked rows
---@return table[]
function M.read(buf, layout)
  if not buf_is_valid(buf) then
    return {}
  end
  local reg = registry[buf] or { rows = {}, blocks = {} }
  local rows = leftmost(buf, ns_id, reg.rows)
  local blocks = leftmost(buf, block_ns, reg.blocks)
  local now = {} -- source line at render -> source line now
  if buf_is_valid(reg.source_buf) then
    local pos = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(reg.source_buf, source_ns(buf), 0, -1, {})) do
      pos[m[1]] = m[2] + 1
    end
    for line, id in pairs(reg.line_marks) do
      now[line] = pos[id]
    end
  end
  local fallback = (layout and layout.rows) or {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local entries, prev = {}, nil
  for i, text in ipairs(lines) do
    local r = i - 1
    local mark = rows[r]
    local block = blocks[r] and (now[blocks[r]] or blocks[r])
    local e = { lnum = i, text = text, source_line = block or (prev and prev.source_line)
      or (fallback[i] and fallback[i].source_line) or 1 }
    if mark then
      e.ann_id, e.row_kind, e.sep = mark.ann_id, mark.row_kind, mark.sep
    elseif prev and not blocks[r] then
      e.ann_id, e.row_kind = prev.ann_id, prev.ann_id and "inserted" or "empty"
    else
      e.row_kind = "empty"
    end
    table.insert(entries, e)
    prev = e
  end

  local count, last = {}, {}
  for i, e in ipairs(entries) do
    if e.ann_id then
      count[e.ann_id] = (count[e.ann_id] or 0) + 1
      last[e.ann_id] = i
    end
  end
  local out = {}
  for i, e in ipairs(entries) do
    table.insert(out, e)
    if e.ann_id and last[e.ann_id] == i and count[e.ann_id] >= 2 then
      table.insert(out, { ann_id = e.ann_id, row_kind = "closer", source_line = e.source_line, attach = i })
    end
  end
  return out
end

--- Role of the row's own mark: "seg_start" (starts a logical line),
--- "wrap_cont" (continues the previous row), or "none".
---@param buf integer
---@param row integer 0-indexed
---@return string
function M.get_role_at(buf, row)
  if not buf_is_valid(buf) or not registry[buf] then
    return "none"
  end
  local mark = leftmost(buf, ns_id, registry[buf].rows)[row]
  if not mark then
    return "none"
  end
  return mark.sep and "wrap_cont" or "seg_start"
end

return M
