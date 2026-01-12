local M = {}

local state = require("aside.state")
local config = require("aside.config")

local aside_windows = {}

local function get_source_win(win)
  win = win or vim.api.nvim_get_current_win()
  if win == 0 then
    win = vim.api.nvim_get_current_win()
  end
  return win
end

function M.setup()
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("AsidePanelClose", { clear = true }),
    callback = function(args)
      local closed_win = tonumber(args.match)
      for source_win, aside_data in pairs(aside_windows) do
        if aside_data.win == closed_win then
          aside_windows[source_win] = nil
          break
        end
        if source_win == closed_win then
          M.close(source_win)
          break
        end
      end
    end,
  })
end

function M.open(opts)
  local family_name = opts.family
  if not family_name then
    vim.notify("aside: family is required for open_aside", vim.log.levels.ERROR)
    return
  end
  if not state.family_exists(family_name) then
    state.ensure_family(family_name)
  end
  local source_win
  if opts.buf then
    local buf = opts.buf
    if buf == 0 then
      buf = vim.api.nvim_get_current_buf()
    end
    source_win = vim.fn.bufwinid(buf)
    if source_win == -1 then
      source_win = vim.api.nvim_get_current_win()
    end
  else
    source_win = get_source_win(opts.win)
  end
  if aside_windows[source_win] then
    M.set_family(source_win, family_name)
    return
  end
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local source_path = vim.api.nvim_buf_get_name(source_buf)
  local aside_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[aside_buf].buftype = "nofile"
  vim.bo[aside_buf].bufhidden = "wipe"
  vim.bo[aside_buf].swapfile = false
  vim.bo[aside_buf].filetype = "aside"
  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(source_win)
  vim.cmd("vertical rightbelow split")
  local aside_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(aside_win, aside_buf)
  vim.api.nvim_win_set_width(aside_win, 40)
  vim.wo[aside_win].wrap = true
  vim.wo[aside_win].number = false
  vim.wo[aside_win].relativenumber = false
  vim.wo[aside_win].signcolumn = "no"
  vim.wo[aside_win].foldcolumn = "0"
  vim.wo[aside_win].cursorline = false
  vim.api.nvim_set_current_win(current_win)
  aside_windows[source_win] = {
    win = aside_win,
    buf = aside_buf,
    family = family_name,
    source_path = source_path,
  }
  M.setup_scroll_sync(source_win)
  M.render_aside(source_win)
end

function M.close(win)
  win = get_source_win(win)
  local aside_data = aside_windows[win]
  if not aside_data then
    return
  end
  if vim.api.nvim_win_is_valid(aside_data.win) then
    vim.api.nvim_win_close(aside_data.win, true)
  end
  aside_windows[win] = nil
end

function M.set_family(win, family_name)
  win = get_source_win(win)
  local aside_data = aside_windows[win]
  if not aside_data then
    return
  end
  if not state.family_exists(family_name) then
    state.ensure_family(family_name)
  end
  aside_data.family = family_name
  M.render_aside(win)
end

function M.setup_scroll_sync(source_win)
  local group = vim.api.nvim_create_augroup("AsideScrollSync_" .. source_win, { clear = true })
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
    group = group,
    callback = function()
      if not vim.api.nvim_win_is_valid(source_win) then
        pcall(vim.api.nvim_del_augroup_by_id, group)
        return
      end
      local aside_data = aside_windows[source_win]
      if not aside_data or not vim.api.nvim_win_is_valid(aside_data.win) then
        pcall(vim.api.nvim_del_augroup_by_id, group)
        return
      end
      M.sync_scroll(source_win)
    end,
  })
end

function M.sync_scroll(source_win)
  local aside_data = aside_windows[source_win]
  if not aside_data then
    return
  end
  if not vim.api.nvim_win_is_valid(source_win) or not vim.api.nvim_win_is_valid(aside_data.win) then
    return
  end
  local source_topline = vim.fn.line("w0", source_win)
  local source_cursor = vim.api.nvim_win_get_cursor(source_win)[1]
  local aside_buf = aside_data.buf
  local line_map = aside_data.line_map or {}
  local target_line = 1
  for source_line, aside_line in pairs(line_map) do
    if source_line <= source_cursor and aside_line > target_line then
      target_line = aside_line
    end
  end
  local aside_line_count = vim.api.nvim_buf_line_count(aside_buf)
  target_line = math.min(target_line, aside_line_count)
  pcall(function()
    vim.api.nvim_win_set_cursor(aside_data.win, { target_line, 0 })
  end)
end

function M.render_aside(source_win)
  local aside_data = aside_windows[source_win]
  if not aside_data then
    return
  end
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local source_path = vim.api.nvim_buf_get_name(source_buf)
  aside_data.source_path = source_path
  local annotations = require("aside.annotations").get_by_file(source_path)
  local family_annotations = {}
  for _, ann in ipairs(annotations) do
    if ann.family == aside_data.family then
      table.insert(family_annotations, ann)
    end
  end
  local lines = {}
  local line_map = {}
  local hl_ranges = {}
  local family = state.get_family(aside_data.family)
  local hl_groups = family and family:get_config().highlight_groups or config.get().highlight_groups
  local aside_line = 1
  for _, ann in ipairs(family_annotations) do
    line_map[ann.start_line] = aside_line
    local range_str = ann.start_line == ann.end_line
      and string.format("L%d", ann.start_line)
      or string.format("L%d-%d", ann.start_line, ann.end_line)
    table.insert(lines, "\226\148\140\226\148\128 " .. range_str)
    table.insert(hl_ranges, { aside_line, hl_groups.border or "AsideBorder", 0, 5 })
    table.insert(hl_ranges, { aside_line, hl_groups.range_indicator or "AsideRangeIndicator", 5, -1 })
    aside_line = aside_line + 1
    if ann.title and ann.title ~= "" then
      table.insert(lines, "\226\148\130 " .. ann.title)
      table.insert(hl_ranges, { aside_line, hl_groups.border or "AsideBorder", 0, 4 })
      table.insert(hl_ranges, { aside_line, hl_groups.title or "AsideTitle", 4, -1 })
      aside_line = aside_line + 1
    end
    table.insert(lines, "\226\148\156\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128")
    table.insert(hl_ranges, { aside_line, hl_groups.border or "AsideBorder", 0, -1 })
    aside_line = aside_line + 1
    if ann.contents and ann.contents ~= "" then
      local content_lines = vim.split(ann.contents, "\n", { plain = true })
      for _, content_line in ipairs(content_lines) do
        table.insert(lines, "\226\148\130 " .. content_line)
        table.insert(hl_ranges, { aside_line, hl_groups.border or "AsideBorder", 0, 4 })
        table.insert(hl_ranges, { aside_line, hl_groups.contents or "AsideContents", 4, -1 })
        aside_line = aside_line + 1
      end
    else
      table.insert(lines, "\226\148\130 (empty)")
      table.insert(hl_ranges, { aside_line, hl_groups.border or "AsideBorder", 0, 4 })
      table.insert(hl_ranges, { aside_line, "Comment", 4, -1 })
      aside_line = aside_line + 1
    end
    table.insert(lines, "\226\148\148\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128")
    table.insert(hl_ranges, { aside_line, hl_groups.border or "AsideBorder", 0, -1 })
    aside_line = aside_line + 1
    table.insert(lines, "")
    aside_line = aside_line + 1
  end
  if #lines == 0 then
    lines = { "No annotations in this family" }
  end
  aside_data.line_map = line_map
  vim.bo[aside_data.buf].modifiable = true
  vim.api.nvim_buf_set_lines(aside_data.buf, 0, -1, false, lines)
  for _, hl in ipairs(hl_ranges) do
    local line_num, hl_group, col_start, col_end = hl[1], hl[2], hl[3], hl[4]
    if col_end == -1 then
      col_end = #lines[line_num]
    end
    pcall(function()
      vim.api.nvim_buf_add_highlight(aside_data.buf, -1, hl_group, line_num - 1, col_start, col_end)
    end)
  end
  vim.bo[aside_data.buf].modifiable = false
end

function M.refresh_if_visible(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  for source_win, aside_data in pairs(aside_windows) do
    if aside_data.source_path == path then
      M.render_aside(source_win)
    end
  end
end

function M.get_aside_data(source_win)
  return aside_windows[get_source_win(source_win)]
end

return M
