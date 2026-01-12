vim.opt.rtp:prepend(vim.fn.getcwd())

require("aside").setup({
  context_lines = 3,
  persistence_debounce_ms = 500,
  default_display = "hover",
})

local aside = require("aside")
aside.ensure_family("test_comments")

print("aside.nvim loaded successfully!")
print("Families: " .. vim.inspect(aside.list_families()))

print([[

=== Recommended Keybindings (not auto-registered) ===

Add these to your config if desired:

-- Add annotation at cursor
vim.keymap.set("n", "<leader>aa", function()
  local file = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  require("aside").add_annotation({
    family = "my_family",
    file = file,
    start_line = line,
    end_line = line,
    title = "Annotation title",
    contents = "Annotation contents",
  })
end)

-- Add annotation to visual selection
vim.keymap.set("v", "<leader>aa", function()
  local file = vim.api.nvim_buf_get_name(0)
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  require("aside").add_annotation({
    family = "my_family",
    file = file,
    start_line = start_line,
    end_line = end_line,
    title = "Range annotation",
    contents = "Covers lines " .. start_line .. " to " .. end_line,
  })
end)

-- List annotations in current file
vim.keymap.set("n", "<leader>al", function()
  local file = vim.api.nvim_buf_get_name(0)
  local annotations = require("aside").get_annotations_by_file(file)
  for _, ann in ipairs(annotations) do
    print(string.format("[%s] L%d-%d: %s", ann.id:sub(1, 8), ann.start_line, ann.end_line, ann.title))
  end
end)

-- Open aside panel
vim.keymap.set("n", "<leader>ao", function()
  require("aside").open_aside({ family = "my_family", win = 0 })
end)

-- Close aside panel  
vim.keymap.set("n", "<leader>ac", function()
  require("aside").close_aside(0)
end)

=== User Commands (always available) ===

:AsideAdd <family> [title]     - Add annotation at cursor/selection
:AsideDelete <id>              - Delete annotation by ID
:AsideList [family]            - List annotations
:AsideFamilies                 - List all families
:AsideOpen <family>            - Open aside panel
:AsideClose                    - Close aside panel
:AsideToggleDisplay <family>   - Cycle display mode

]])
