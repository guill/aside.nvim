local M = {}

local state = require("aside.state")
local context = require("aside.context")
local tracking = require("aside.tracking")

local function normalize_path(file)
  if not file or file == "" then
    return nil
  end
  if not vim.startswith(file, "/") then
    file = vim.fn.fnamemodify(file, ":p")
  end
  return file
end

function M.add(opts)
  if not opts.family then
    vim.notify("aside: family is required", vim.log.levels.ERROR)
    return nil
  end
  
  local family_name = type(opts.family) == "string" and opts.family or opts.family.name
  state.ensure_family(family_name)
  
  local file = normalize_path(opts.file)
  if not file then
    vim.notify("aside: file path is required", vim.log.levels.ERROR)
    return nil
  end
  
  local start_line = opts.start_line
  local end_line = opts.end_line or start_line
  
  if type(start_line) ~= "number" or start_line < 1 then
    vim.notify("aside: valid start_line is required", vim.log.levels.ERROR)
    return nil
  end
  
  if end_line < start_line then
    start_line, end_line = end_line, start_line
  end

  if opts.title and opts.title:find("\n", 1, true) then
    vim.notify("aside: title must not contain newlines", vim.log.levels.ERROR)
    return nil
  end

  local family = state.get_family(family_name)
  local family_config = family:get_config()
  local context_data = context.capture(file, start_line, end_line, family_config.context_lines)
  
  local annotation = state.add_annotation({
    family = family_name,
    file = file,
    start_line = start_line,
    end_line = end_line,
    title = opts.title or "",
    contents = opts.contents or "",
    sort_key = opts.sort_key,
    metadata = opts.metadata,
    context_before = context_data and context_data.context_before,
    marked_content = context_data and context_data.marked_content,
    context_after = context_data and context_data.context_after,
  })
  
  tracking.attach_extmark(annotation)
  
  return annotation.id
end

function M.get(id)
  local annotation = state.get_annotation(id)
  if annotation then
    return vim.deepcopy(annotation)
  end
  return nil
end

function M.get_by_file(file)
  file = normalize_path(file)
  if not file then
    return {}
  end
  
  local result = {}
  for _, ann in ipairs(state.get_all_annotations()) do
    if ann.file == file then
      table.insert(result, vim.deepcopy(ann))
    end
  end
  
  M.sort_annotations(result)
  return result
end

function M.get_by_family(family_name)
  if not family_name then
    return {}
  end
  
  local result = {}
  for _, ann in ipairs(state.get_all_annotations()) do
    if ann.family == family_name then
      table.insert(result, vim.deepcopy(ann))
    end
  end
  
  M.sort_annotations(result)
  return result
end

function M.get_by_metadata(predicate)
  local result = {}
  for _, ann in ipairs(state.get_all_annotations()) do
    if predicate(ann.metadata) then
      table.insert(result, vim.deepcopy(ann))
    end
  end
  
  M.sort_annotations(result)
  return result
end

function M.update(id, updates)
  local annotation = state.get_annotation(id)
  if not annotation then
    return false
  end

  if updates.title and updates.title:find("\n", 1, true) then
    vim.notify("aside: title must not contain newlines", vim.log.levels.ERROR)
    return false
  end

  local allowed_fields = { "title", "contents", "sort_key", "metadata" }
  local filtered_updates = {}
  for _, field in ipairs(allowed_fields) do
    if updates[field] ~= nil then
      filtered_updates[field] = updates[field]
    end
  end
  
  if vim.tbl_isempty(filtered_updates) then
    return true
  end
  
  state.update_annotation(id, filtered_updates)
  return true
end

function M.delete(id)
  local annotation = state.get_annotation(id)
  if not annotation then
    return false
  end
  
  tracking.detach_extmark(annotation)
  state.delete_annotation(id)
  return true
end

function M.sort_annotations(annotations)
  table.sort(annotations, function(a, b)
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
    
    if a.family ~= b.family then
      return a.family < b.family
    end
    
    return a.created_at < b.created_at
  end)
end

return M
