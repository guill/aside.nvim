local vim = rawget(_G, "vim")

vim.opt.rtp:prepend(vim.fn.getcwd())

local mini_candidates = {
  os.getenv("MINI_PATH") or "",
  vim.fn.expand("~/.local/share/nvim/lazy/mini.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/*/start/mini.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/*/opt/mini.nvim"),
}

for _, path in ipairs(mini_candidates) do
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.rtp:prepend(path)
    break
  end
end

-- mini.test children (started with --listen) get a fresh cwd so persisted
-- `.aside/` data never leaks between runs.
if vim.tbl_contains(vim.v.argv, "--listen") then
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.chdir(dir)
end

require("aside").setup()
