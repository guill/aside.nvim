local M = {}

local state = require("aside.state")
local config = require("aside.config")

local ns_below = vim.api.nvim_create_namespace("aside_below")

function M.setup()
end

function M.clear_buffer(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns_below, 0, -1)
  end
end

local function get_window_width(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return vim.api.nvim_win_get_width(win)
    end
  end
  return 80
end

local function wrap_text(text, width)
  if width <= 0 or #text <= width then
    return { text }
  end
  local result = {}
  local pos = 1
  while pos <= #text do
    local chunk = text:sub(pos, pos + width - 1)
    local last_space = chunk:reverse():find("%s")
    if last_space and pos + width <= #text then
      chunk = chunk:sub(1, #chunk - last_space)
    end
    table.insert(result, chunk)
    pos = pos + #chunk
    while text:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end
  if #result == 0 then
    result = { "" }
  end
  return result
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
  local hl_groups = family_config.highlight_groups or config.get().highlight_groups
  local win_width = get_window_width(buf)
  local wrap_width = math.max(20, win_width - 10)
  for _, ann in ipairs(annotations) do
    local line_count = vim.api.nvim_buf_line_count(buf)
    local start_line = math.min(ann.start_line, line_count)
    local end_line = math.min(ann.end_line, line_count)
    local virt_lines = {}
    table.insert(virt_lines, {
      { "\226\148\140\226\148\128 ", hl_groups.border or "AsideBorder" },
    })
    for line_num = start_line, end_line do
      pcall(function()
        local line = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
        local first_char = line:sub(1, 1)
        if first_char == "" or first_char:match("%s") then
          vim.api.nvim_buf_set_extmark(buf, ns_below, line_num - 1, 0, {
            virt_text = { { "\226\148\130", hl_groups.border or "AsideBorder" } },
            virt_text_pos = "overlay",
            priority = 100,
          })
        end
      end)
    end
    if ann.title and ann.title ~= "" then
      local title_icon = family_config.gutter_icon or config.get_value("default_gutter_icon", "\226\151\143")
      table.insert(virt_lines, {
        { "\226\148\156\226\148\128\226\148\128 ", hl_groups.border or "AsideBorder" },
        { title_icon .. " ", hl_groups.gutter or "AsideGutter" },
        { ann.title, hl_groups.title or "AsideTitle" },
      })
    end
    if ann.contents and ann.contents ~= "" then
      local content_lines = vim.split(ann.contents, "\n", { plain = true })
      for _, content_line in ipairs(content_lines) do
        local wrapped = wrap_text(content_line, wrap_width - 4)
        for _, wrapped_line in ipairs(wrapped) do
          table.insert(virt_lines, {
            { "\226\148\130 ", hl_groups.border or "AsideBorder" },
            { wrapped_line, hl_groups.contents or "AsideContents" },
          })
        end
      end
    end
    table.insert(virt_lines, {
      { "\226\148\148\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128\226\148\128", hl_groups.border or "AsideBorder" },
    })
    pcall(function()
      vim.api.nvim_buf_set_extmark(buf, ns_below, start_line - 1, 0, {
        virt_lines = { virt_lines[1] },
        virt_lines_above = true,
        priority = 100,
      })
    end)
    if #virt_lines > 2 then
      local content_lines = {}
      for i = 2, #virt_lines do
        table.insert(content_lines, virt_lines[i])
      end
      pcall(function()
        vim.api.nvim_buf_set_extmark(buf, ns_below, end_line - 1, 0, {
          virt_lines = content_lines,
          virt_lines_above = false,
          priority = 100,
        })
      end)
    end
  end
end

return M
