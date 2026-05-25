local vim = rawget(_G, "vim")

vim.opt.rtp:prepend(vim.fn.getcwd())

local mini_candidates = {
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

require("aside").setup()
