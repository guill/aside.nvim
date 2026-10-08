if vim.g.loaded_aside then
  return
end
vim.g.loaded_aside = true

vim.api.nvim_create_user_command("AsideAdd", function(opts)
  local aside = require("aside")
  local family = opts.fargs[1]
  local title = opts.fargs[2] or ""
  local start_line, end_line
  if opts.range == 2 then
    start_line = opts.line1
    end_line = opts.line2
  else
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
  end
  
  local file = vim.api.nvim_buf_get_name(0)
  -- From inside an aside panel, annotate the source lines the rows sit beside.
  local panel = require("aside.display.aside")
  local source_file, source_start = panel.map_to_source(vim.api.nvim_get_current_buf(), start_line)
  if source_file then
    local _, source_end = panel.map_to_source(vim.api.nvim_get_current_buf(), end_line)
    file, start_line, end_line = source_file, source_start, source_end
  end
  if file == "" then
    vim.notify("Buffer must be saved to a file first", vim.log.levels.ERROR)
    return
  end
  
  local id = aside.add_annotation({
    family = family,
    file = file,
    start_line = start_line,
    end_line = end_line,
    title = title,
    contents = "",
  })
  
  if id then
    vim.notify("Annotation added: " .. id, vim.log.levels.INFO)
  end
end, {
  nargs = "+",
  range = true,
  desc = "Add an annotation to the current line or selection",
  complete = function(arg_lead, cmd_line, cursor_pos)
    local aside = require("aside")
    return aside.list_families()
  end,
})

vim.api.nvim_create_user_command("AsideDelete", function(opts)
  local aside = require("aside")
  local id = opts.fargs[1]
  if aside.delete_annotation(id) then
    vim.notify("Annotation deleted", vim.log.levels.INFO)
  else
    vim.notify("Failed to delete annotation", vim.log.levels.ERROR)
  end
end, {
  nargs = 1,
  desc = "Delete an annotation by ID",
})

vim.api.nvim_create_user_command("AsideList", function(opts)
  local aside = require("aside")
  local family = opts.fargs[1]
  local annotations = aside.get_annotations_by_family(family)
  
  if #annotations == 0 then
    vim.notify("No annotations in family: " .. (family or "all"), vim.log.levels.INFO)
    return
  end
  
  for _, ann in ipairs(annotations) do
    local loc = string.format("%s:%d-%d", vim.fn.fnamemodify(ann.file, ":~:."), ann.start_line, ann.end_line)
    print(string.format("[%s] %s: %s", ann.id:sub(1, 8), loc, ann.title or "(no title)"))
  end
end, {
  nargs = "?",
  desc = "List annotations in a family",
  complete = function()
    return require("aside").list_families()
  end,
})

vim.api.nvim_create_user_command("AsideFamilies", function()
  local aside = require("aside")
  local families = aside.list_families()
  if #families == 0 then
    vim.notify("No families defined", vim.log.levels.INFO)
  else
    for _, name in ipairs(families) do
      print(name)
    end
  end
end, {
  desc = "List all annotation families",
})

vim.api.nvim_create_user_command("AsideOpen", function(opts)
  local aside = require("aside")
  local family = opts.fargs[1]
  aside.open_aside({
    family = family,
    win = 0,
  })
end, {
  nargs = 1,
  desc = "Open the aside panel for a family",
  complete = function()
    return require("aside").list_families()
  end,
})

vim.api.nvim_create_user_command("AsideClose", function()
  local aside = require("aside")
  aside.close_aside(0)
end, {
  desc = "Close the aside panel",
})

vim.api.nvim_create_user_command("AsideToggleDisplay", function(opts)
  local aside = require("aside")
  local family_name = opts.fargs[1]
  local mode = opts.fargs[2]
  
  if not family_name then
    vim.notify("Usage: AsideToggleDisplay <family> [mode]", vim.log.levels.ERROR)
    return
  end
  
  local family = aside.ensure_family(family_name)
  if mode then
    family:configure({ display = mode })
  else
    local modes = { "hidden", "hover", "below", "aside" }
    local current = family:get_config().display or "hover"
    local current_idx = 1
    for i, m in ipairs(modes) do
      if m == current then
        current_idx = i
        break
      end
    end
    local next_mode = modes[(current_idx % #modes) + 1]
    family:configure({ display = next_mode })
    vim.notify("Display mode: " .. next_mode, vim.log.levels.INFO)
  end
end, {
  nargs = "+",
  desc = "Toggle or set display mode for a family",
  complete = function(arg_lead, cmd_line)
    local parts = vim.split(cmd_line, "%s+")
    if #parts <= 2 then
      return require("aside").list_families()
    else
      return { "hidden", "hover", "below", "aside" }
    end
  end,
})
