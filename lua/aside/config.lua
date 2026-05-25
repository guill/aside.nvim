local M = {}

local defaults = {
  context_lines = 3,
  persistence_debounce_ms = 1000,
  default_display = "hover",
  default_gutter_icon = "\226\151\143",
  aside_width = 40,
  spill_direction = "below",
  layout_solver = "greedy",
  data_dir = ".aside",
  highlight_groups = {
    title = "AsideTitle",
    contents = "AsideContents",
    border = "AsideBorder",
    gutter = "AsideGutter",
    range_indicator = "AsideRangeIndicator",
  },
}

local config = vim.deepcopy(defaults)

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.setup_highlights()
end

function M.get()
  return config
end

function M.get_value(key, default)
  local value = config[key]
  if value == nil then
    return default
  end
  return value
end

function M.setup_highlights()
  local bg = vim.o.background

  local highlight_defs = {
    AsideTitle = {
      light = { fg = "#0451A5", bold = true },
      dark = { fg = "#61AFEF", bold = true },
    },
    AsideContents = {
      light = { fg = "#0E8A00", italic = true },
      dark = { fg = "#98C379", italic = true },
    },
    AsideBorder = {
      light = { fg = "#6A6A6A" },
      dark = { fg = "#5C6370" },
    },
    AsideGutter = {
      light = { fg = "#AF00DB" },
      dark = { fg = "#C678DD" },
    },
    AsideRangeIndicator = {
      light = { fg = "#6A6A6A" },
      dark = { fg = "#ABB2BF" },
    },
  }

  for group, colors in pairs(highlight_defs) do
    local hl_opts = bg == "light" and colors.light or colors.dark
    hl_opts.default = true
    vim.api.nvim_set_hl(0, group, hl_opts)
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("AsideHighlights", { clear = true }),
    callback = function()
      M.setup_highlights()
    end,
  })
end

function M.get_data_dir()
  local data_dir = config.data_dir
  if not vim.startswith(data_dir, "/") then
    data_dir = vim.fn.getcwd() .. "/" .. data_dir
  end
  return data_dir
end

return M
