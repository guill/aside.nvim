local M = {}

local config = require("aside.config")
local state = require("aside.state")

local save_timer = nil
local pending_save = false

local function get_family_file(family_name)
  local data_dir = config.get_data_dir()
  return data_dir .. "/" .. family_name .. ".json"
end

local function ensure_data_dir()
  local data_dir = config.get_data_dir()
  if vim.fn.isdirectory(data_dir) == 0 then
    vim.fn.mkdir(data_dir, "p")
  end
  return data_dir
end

function M.save_family(family_name)
  local family = state.get_family(family_name)
  if not family then
    return false
  end
  ensure_data_dir()
  local annotations = {}
  for id, _ in pairs(family.annotations) do
    local ann = state.get_annotation(id)
    if ann then
      table.insert(annotations, {
        id = ann.id,
        file = ann.file,
        start_line = ann.start_line,
        end_line = ann.end_line,
        title = ann.title,
        contents = ann.contents,
        sort_key = ann.sort_key,
        metadata = ann.metadata,
        verified = ann.verified,
        created_at = ann.created_at,
        context_before = ann.context_before,
        marked_content = ann.marked_content,
        context_after = ann.context_after,
      })
    end
  end
  local data = {
    version = 1,
    family = family_name,
    config = family.config,
    annotations = annotations,
  }
  local ok, json_str = pcall(vim.json.encode, data)
  if not ok then
    return false
  end
  local file_path = get_family_file(family_name)
  local file = io.open(file_path, "w")
  if not file then
    return false
  end
  file:write(json_str)
  file:close()
  return true
end

function M.load_family(family_name)
  local file_path = get_family_file(family_name)
  if vim.fn.filereadable(file_path) == 0 then
    return false
  end
  local file = io.open(file_path, "r")
  if not file then
    return false
  end
  local content = file:read("*all")
  file:close()
  if not content or content == "" then
    return false
  end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or not data then
    return false
  end
  local family = state.ensure_family(family_name)
  if data.config then
    family:configure(data.config)
  end
  for _, ann_data in ipairs(data.annotations or {}) do
    state.add_annotation({
      id = ann_data.id,
      family = family_name,
      file = ann_data.file,
      start_line = ann_data.start_line,
      end_line = ann_data.end_line,
      title = ann_data.title,
      contents = ann_data.contents,
      sort_key = ann_data.sort_key,
      metadata = ann_data.metadata,
      verified = ann_data.verified,
      created_at = ann_data.created_at,
      context_before = ann_data.context_before,
      marked_content = ann_data.marked_content,
      context_after = ann_data.context_after,
    })
  end
  return true
end

function M.delete_family_file(family_name)
  local file_path = get_family_file(family_name)
  if vim.fn.filereadable(file_path) == 1 then
    vim.fn.delete(file_path)
  end
end

function M.save_all()
  for _, family_name in ipairs(state.list_families()) do
    M.save_family(family_name)
  end
end

function M.load_all()
  local data_dir = config.get_data_dir()
  if vim.fn.isdirectory(data_dir) == 0 then
    return
  end
  local files = vim.fn.glob(data_dir .. "/*.json", false, true)
  for _, file_path in ipairs(files) do
    local family_name = vim.fn.fnamemodify(file_path, ":t:r")
    M.load_family(family_name)
  end
end

local function schedule_save()
  if save_timer then
    vim.fn.timer_stop(save_timer)
  end
  pending_save = true
  local debounce_ms = config.get_value("persistence_debounce_ms", 1000)
  save_timer = vim.fn.timer_start(debounce_ms, function()
    save_timer = nil
    if pending_save then
      pending_save = false
      M.save_all()
    end
  end)
end

function M.setup()
  M.load_all()
  state.on("annotation_added", function()
    schedule_save()
  end)
  state.on("annotation_updated", function()
    schedule_save()
  end)
  state.on("annotation_deleted", function()
    schedule_save()
  end)
  state.on("annotation_relocated", function()
    schedule_save()
  end)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("AsidePersistence", { clear = true }),
    callback = function()
      if pending_save then
        M.save_all()
      end
    end,
  })
  require("aside.tracking").setup_global_tracking()
end

return M
