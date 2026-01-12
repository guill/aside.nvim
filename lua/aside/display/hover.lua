local M = {}

local state = require("aside.state")
local config = require("aside.config")

local ns_gutter = vim.api.nvim_create_namespace("aside_hover_gutter")
local ns_range = vim.api.nvim_create_namespace("aside_hover_range")

local hover_win = nil
local hover_buf = nil
local current_annotation = nil

function M.setup()
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = vim.api.nvim_create_augroup("AsideHover", { clear = true }),
    callback = function()
      M.update_hover()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = vim.api.nvim_create_augroup("AsideHoverClose", { clear = true }),
    callback = function()
      M.close_hover()
    end,
  })
end

function M.clear_buffer(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns_gutter, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, ns_range, 0, -1)
  end
end

function M.render_annotations(buf, annotations, family_name)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local family = state.get_family(family_name)
  if not family then
    return
  end
  local family_config = family:get_config()
  local gutter_icon = family_config.gutter_icon or config.get_value("default_gutter_icon", "\226\151\143")
  local hl_groups = family_config.highlight_groups or config.get().highlight_groups
  for _, ann in ipairs(annotations) do
    local line_count = vim.api.nvim_buf_line_count(buf)
    local start_line = math.min(ann.start_line, line_count)
    local end_line = math.min(ann.end_line, line_count)
    pcall(function()
      vim.api.nvim_buf_set_extmark(buf, ns_gutter, start_line - 1, 0, {
        sign_text = gutter_icon,
        sign_hl_group = hl_groups.gutter or "AsideGutter",
        priority = 100,
      })
    end)
    if end_line > start_line then
      for line = start_line + 1, end_line do
        pcall(function()
          vim.api.nvim_buf_set_extmark(buf, ns_range, line - 1, 0, {
            sign_text = "\226\148\130",
            sign_hl_group = hl_groups.range_indicator or "AsideRangeIndicator",
            priority = 99,
          })
        end)
      end
    end
  end
end

function M.update_hover()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then
    M.close_hover()
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local annotations = require("aside.annotations").get_by_file(path)
  local annotation_at_cursor = nil
  for _, ann in ipairs(annotations) do
    local mode = require("aside.display").get_display_mode(ann.family)
    if mode == "hover" and line >= ann.start_line and line <= ann.end_line then
      annotation_at_cursor = ann
      break
    end
  end
  if not annotation_at_cursor then
    M.close_hover()
    return
  end
  if current_annotation and current_annotation.id == annotation_at_cursor.id then
    return
  end
  M.show_hover(annotation_at_cursor)
end

function M.show_hover(annotation)
  M.close_hover()
  current_annotation = annotation
  local lines = {}
  if annotation.title and annotation.title ~= "" then
    table.insert(lines, annotation.title)
    table.insert(lines, string.rep("\226\148\128", math.min(40, #annotation.title)))
  end
  if annotation.contents and annotation.contents ~= "" then
    for _, line in ipairs(vim.split(annotation.contents, "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end
  if #lines == 0 then
    table.insert(lines, "(empty annotation)")
  end
  local max_width = 60
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, max_width)
  local height = math.min(#lines, 10)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local screen_row = vim.fn.screenpos(0, row, 1).row
  local editor_height = vim.o.lines
  local float_row
  if screen_row > editor_height / 2 then
    float_row = -height - 2
  else
    float_row = 1
  end
  hover_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hover_buf, 0, -1, false, lines)
  vim.bo[hover_buf].modifiable = false
  vim.bo[hover_buf].bufhidden = "wipe"
  local family = state.get_family(annotation.family)
  local hl_groups = family and family:get_config().highlight_groups or config.get().highlight_groups
  if annotation.title and annotation.title ~= "" then
    vim.api.nvim_buf_add_highlight(hover_buf, -1, hl_groups.title or "AsideTitle", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(hover_buf, -1, hl_groups.border or "AsideBorder", 1, 0, -1)
    for i = 2, #lines - 1 do
      vim.api.nvim_buf_add_highlight(hover_buf, -1, hl_groups.contents or "AsideContents", i, 0, -1)
    end
  else
    for i = 0, #lines - 1 do
      vim.api.nvim_buf_add_highlight(hover_buf, -1, hl_groups.contents or "AsideContents", i, 0, -1)
    end
  end
  hover_win = vim.api.nvim_open_win(hover_buf, false, {
    relative = "cursor",
    row = float_row,
    col = 0,
    width = width + 2,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = false,
  })
end

function M.close_hover()
  if hover_win and vim.api.nvim_win_is_valid(hover_win) then
    vim.api.nvim_win_close(hover_win, true)
  end
  hover_win = nil
  hover_buf = nil
  current_annotation = nil
end

return M
