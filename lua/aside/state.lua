local M = {}

local config = require("aside.config")

local families = {}
local annotations_by_id = {}
local event_listeners = {}

local function generate_uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end)
end

function M.initialize()
  math.randomseed(os.time())
  families = {}
  annotations_by_id = {}
end

---@class Aside.FamilyInternal
---@field name string
---@field config table
---@field annotations table<string, boolean>
---@field created_at number

local FamilyMethods = {}
FamilyMethods.__index = FamilyMethods

function FamilyMethods:configure(opts)
  self.config = vim.tbl_deep_extend("force", self.config, opts or {})
  require("aside.display").refresh_family(self.name)
end

function FamilyMethods:get_config()
  local global_config = config.get()
  return vim.tbl_deep_extend("force", {
    display = global_config.default_display,
    gutter_icon = global_config.default_gutter_icon,
    context_lines = global_config.context_lines,
    highlight_groups = global_config.highlight_groups,
  }, self.config)
end

function M.ensure_family(name)
  if not families[name] then
    families[name] = setmetatable({
      name = name,
      config = {},
      annotations = {},
      created_at = os.time(),
    }, FamilyMethods)
  end
  return families[name]
end

function M.family_exists(name)
  return families[name] ~= nil
end

function M.list_families()
  local names = {}
  for name, _ in pairs(families) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

function M.delete_family(name)
  local family = families[name]
  if not family then
    return false
  end
  
  for id, _ in pairs(family.annotations) do
    annotations_by_id[id] = nil
  end
  
  families[name] = nil
  
  local persistence = require("aside.persistence")
  persistence.delete_family_file(name)
  
  return true
end

function M.get_family(name)
  return families[name]
end

function M.get_all_families()
  return families
end

function M.add_annotation(annotation)
  annotation.id = annotation.id or generate_uuid()
  annotation.created_at = annotation.created_at or os.time()
  annotation.verified = annotation.verified ~= false
  
  annotations_by_id[annotation.id] = annotation
  
  local family = M.ensure_family(annotation.family)
  family.annotations[annotation.id] = true
  
  M.emit("annotation_added", { annotation = annotation })
  
  return annotation
end

function M.get_annotation(id)
  return annotations_by_id[id]
end

function M.get_all_annotations()
  local result = {}
  for _, ann in pairs(annotations_by_id) do
    table.insert(result, ann)
  end
  return result
end

function M.update_annotation(id, updates)
  local annotation = annotations_by_id[id]
  if not annotation then
    return nil
  end
  
  local old_annotation = vim.deepcopy(annotation)
  
  for key, value in pairs(updates) do
    annotation[key] = value
  end
  
  M.emit("annotation_updated", {
    annotation = annotation,
    old_annotation = old_annotation,
  })
  
  return annotation
end

function M.delete_annotation(id)
  local annotation = annotations_by_id[id]
  if not annotation then
    return nil
  end
  
  annotations_by_id[id] = nil
  
  local family = families[annotation.family]
  if family then
    family.annotations[id] = nil
  end
  
  M.emit("annotation_deleted", { annotation = annotation })
  
  return annotation
end

function M.relocate_annotation(id, new_start, new_end, is_external)
  local annotation = annotations_by_id[id]
  if not annotation then
    return nil
  end
  
  local old_position = {
    start_line = annotation.start_line,
    end_line = annotation.end_line,
  }
  
  annotation.start_line = new_start
  annotation.end_line = new_end
  
  M.emit("annotation_relocated", {
    annotation = annotation,
    old_position = old_position,
    is_external_reload = is_external or false,
  })
  
  return annotation
end

function M.on(event, callback)
  if not event_listeners[event] then
    event_listeners[event] = {}
  end
  
  table.insert(event_listeners[event], callback)
  
  return function()
    for i, cb in ipairs(event_listeners[event] or {}) do
      if cb == callback then
        table.remove(event_listeners[event], i)
        break
      end
    end
  end
end

function M.emit(event, data)
  for _, callback in ipairs(event_listeners[event] or {}) do
    local ok, err = pcall(callback, data)
    if not ok then
      vim.notify("aside.nvim event error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

function M.clear()
  families = {}
  annotations_by_id = {}
end

return M
