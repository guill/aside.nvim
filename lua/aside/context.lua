local M = {}

---@class Aside.ContextData
---@field marked_content string[]
---@field context_before string[]
---@field context_after string[]

function M.read_file_lines(file_path, opts)
  opts = opts or {}
  if not file_path or file_path == "" then
    return nil
  end
  
  local normalized_path = vim.fn.fnamemodify(file_path, ":p")
  
  if not opts.force_disk then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        local buf_name = vim.api.nvim_buf_get_name(buf)
        if buf_name == normalized_path then
          return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end
      end
    end
  end
  
  local file = io.open(normalized_path, "r")
  if not file then
    return nil
  end
  
  local lines = {}
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()
  
  return lines
end

local function slice(tbl, start_idx, end_idx)
  local result = {}
  if not tbl or #tbl == 0 then
    return result
  end
  
  start_idx = math.max(1, start_idx)
  end_idx = math.min(#tbl, end_idx)
  
  for i = start_idx, end_idx do
    table.insert(result, tbl[i])
  end
  return result
end

---@param file_path string
---@param start_line number
---@param end_line number
---@param context_line_count number
---@return Aside.ContextData?
function M.capture(file_path, start_line, end_line, context_line_count)
  local lines = M.read_file_lines(file_path)
  if not lines then
    return nil
  end
  
  if #lines == 0 then
    return {
      marked_content = {},
      context_before = {},
      context_after = {},
    }
  end
  
  start_line = math.max(1, math.min(start_line, #lines))
  end_line = math.max(start_line, math.min(end_line, #lines))
  context_line_count = context_line_count or 3
  
  local context_before_start = math.max(1, start_line - context_line_count)
  local context_after_end = math.min(#lines, end_line + context_line_count)
  
  return {
    marked_content = slice(lines, start_line, end_line),
    context_before = slice(lines, context_before_start, start_line - 1),
    context_after = slice(lines, end_line + 1, context_after_end),
  }
end

function M.has_context(annotation)
  if not annotation then
    return false
  end
  if not annotation.marked_content then
    return false
  end
  if type(annotation.marked_content) ~= "table" then
    return false
  end
  return #annotation.marked_content > 0
end

return M
