local M = {}

local hover = require("aside.display.hover")
local below = require("aside.display.below")
local aside_panel = require("aside.display.aside")
local state = require("aside.state")

local display_ns = vim.api.nvim_create_namespace("aside_display")

function M.setup()
  hover.setup()
  below.setup()
  aside_panel.setup()
  M.setup_event_handlers()
end

function M.setup_event_handlers()
  state.on("annotation_added", function(data)
    vim.schedule(function()
      M.refresh_annotation(data.annotation)
    end)
  end)
  state.on("annotation_updated", function(data)
    vim.schedule(function()
      M.refresh_annotation(data.annotation)
    end)
  end)
  state.on("annotation_deleted", function(data)
    vim.schedule(function()
      M.refresh_file(data.annotation.file)
    end)
  end)
  state.on("annotation_relocated", function(data)
    vim.schedule(function()
      M.refresh_annotation(data.annotation)
    end)
  end)
end

function M.get_display_mode(family_name)
  local family = state.get_family(family_name)
  if not family then
    return "hidden"
  end
  return family:get_config().display or "hover"
end

function M.refresh_annotation(annotation)
  local buf = vim.fn.bufnr(annotation.file)
  if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  M.refresh_buffer(buf)
end

function M.refresh_file(file_path)
  local buf = vim.fn.bufnr(file_path)
  if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  M.refresh_buffer(buf)
end

function M.refresh_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then
    return
  end
  hover.clear_buffer(buf)
  below.clear_buffer(buf)
  local annotations = require("aside.annotations").get_by_file(path)
  local by_family = {}
  for _, ann in ipairs(annotations) do
    if not by_family[ann.family] then
      by_family[ann.family] = {}
    end
    table.insert(by_family[ann.family], ann)
  end
  for family_name, family_annotations in pairs(by_family) do
    local mode = M.get_display_mode(family_name)
    if mode == "hover" then
      hover.render_annotations(buf, family_annotations, family_name)
    elseif mode == "below" then
      below.render_annotations(buf, family_annotations, family_name)
    end
  end
  aside_panel.refresh_if_visible(buf)
end

function M.refresh_family(family_name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      if path and path ~= "" then
        local annotations = require("aside.annotations").get_by_file(path)
        local has_family = false
        for _, ann in ipairs(annotations) do
          if ann.family == family_name then
            has_family = true
            break
          end
        end
        if has_family then
          M.refresh_buffer(buf)
        end
      end
    end
  end
end

function M.open_aside(opts)
  aside_panel.open(opts)
end

function M.close_aside(win)
  aside_panel.close(win)
end

function M.set_aside_family(win, family)
  aside_panel.set_family(win, family)
end

function M.get_namespace()
  return display_ns
end

return M
