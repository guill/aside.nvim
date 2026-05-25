-- Minimal init for tmux scenario tests.
-- No print() calls so nvim does not show a "Press ENTER" prompt at startup.
-- Honors $ASIDE_TEST_DATA_DIR so each scenario can use an isolated data
-- directory and not pollute the project's .aside/ folder.

vim.opt.rtp:prepend(vim.fn.getcwd())

local data_dir = os.getenv("ASIDE_TEST_DATA_DIR")
if not data_dir or data_dir == "" then
  data_dir = ".aside_tmux_test"
end

require("aside").setup({
  context_lines = 3,
  persistence_debounce_ms = 200,
  default_display = "hover",
  data_dir = data_dir,
  aside_width = 40,
})

require("aside").ensure_family("test_comments")
