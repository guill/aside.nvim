local M = {}

local state = require("aside.state")
local config = require("aside.config")

local aside_windows = {}

-- Dedicated namespace for highlight extmarks (separate from edit-region marks).
local hl_ns = vim.api.nvim_create_namespace("aside_render_hl")

-- Dedicated namespace for source-side virt_lines padding (Task 15).
-- Must be module-level so M.close can clear it safely.
local source_padding_ns = vim.api.nvim_create_namespace("aside_source_padding")

--- Resolve the given window id (with 0/nil = current) to the source window
--- that owns an aside panel. If the input is itself an aside window, return
--- the corresponding source window so callers like `set_family`, `close`, and
--- `get_aside_data` work regardless of whether the user is focused on the
--- source pane or the aside pane.
---@param win integer|nil
---@return integer resolved_win Source window id, or original win if not aside
local function resolve_source_win(win)
  win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
  if aside_windows[win] then
    return win
  end
  for source_win, data in pairs(aside_windows) do
    if data and data.win == win then
      return source_win
    end
  end
  return win
end



--- Test helper: inject aside_data for testing render without a real window.
--- The provided `data` table is stored as-is under `source_win` and may include
--- pre-computed fields (e.g. `wrap_width`) that bypass live window queries.
function M._test_set_data(source_win, data)
  aside_windows[source_win] = data
end

--- Test/introspection helper: retrieve the internal aside_data for a source window.
function M._test_get_data(source_win)
  return aside_windows[source_win]
end

function M.setup()
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("AsidePanelClose", { clear = true }),
    callback = function(args)
      local closed_win = tonumber(args.match)
      local aside_panel_source = nil
      local source_win_closed = nil
      for source_win, aside_data in pairs(aside_windows) do
        if aside_data.win == closed_win then
          aside_panel_source = source_win
          break
        end
        if source_win == closed_win then
          source_win_closed = source_win
          break
        end
      end
      if aside_panel_source then
        local aside_data = aside_windows[aside_panel_source]
        if aside_data and aside_data.augroup_name then
          pcall(vim.api.nvim_del_augroup_by_name, aside_data.augroup_name)
        end
        aside_windows[aside_panel_source] = nil
      elseif source_win_closed then
        M.close(source_win_closed)
      end
    end,
  })
end

function M.open(opts)
  opts = opts or {}
  local family_name = opts.family
  if not family_name then
    vim.notify("aside: family is required for open_aside", vim.log.levels.ERROR)
    return
  end

  -- Resolve source_win. Per spec, when opts.buf is provided we anchor to the
  -- CURRENT window (not bufwinid) so the aside attaches to the window the user
  -- is currently in.
  local source_win
  if opts.buf then
    source_win = vim.api.nvim_get_current_win()
  else
    source_win = (opts.win == nil or opts.win == 0)
        and vim.api.nvim_get_current_win()
        or opts.win
  end

  if aside_windows[source_win] then
    M.set_family(source_win, family_name)
    return
  end

  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local source_path = vim.api.nvim_buf_get_name(source_buf)
  if not source_path or source_path == "" then
    vim.notify(
      "aside: source buffer has no name; cannot open aside panel",
      vim.log.levels.ERROR
    )
    return
  end

  if not state.family_exists(family_name) then
    state.ensure_family(family_name)
  end

  local aside_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[aside_buf].buftype = "acwrite"
  vim.bo[aside_buf].bufhidden = "hide"
  vim.bo[aside_buf].swapfile = false
  vim.bo[aside_buf].filetype = "aside"
  vim.bo[aside_buf].modifiable = true

  local buf_name = "aside://" .. family_name .. "/" .. source_path
  pcall(vim.api.nvim_buf_set_name, aside_buf, buf_name)

  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(source_win)
  vim.cmd("vertical rightbelow split")
  local aside_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(aside_win, aside_buf)

  local family = state.get_family(family_name)
  local family_config = (family and family.get_config and family:get_config()) or {}
  local aside_width = family_config.aside_width
      or config.get_value("aside_width", 40)
  pcall(vim.api.nvim_win_set_width, aside_win, aside_width)

  vim.wo[aside_win].wrap = false
  vim.wo[aside_win].number = false
  vim.wo[aside_win].relativenumber = false
  vim.wo[aside_win].signcolumn = "no"
  vim.wo[aside_win].foldcolumn = "0"
  vim.wo[aside_win].cursorline = false

  vim.wo[aside_win].statuscolumn =
    "%!v:lua.require('aside.display.aside').statuscolumn_for_buf("
    .. aside_buf
    .. ")"

  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end

  local augroup_name = "Aside_" .. source_win .. "_" .. aside_buf

  aside_windows[source_win] = {
    win = aside_win,
    buf = aside_buf,
    family = family_name,
    source_path = source_path,
    layout = nil,
    in_insert = false,
    deferred_render = false,
    modified = false,
    augroup_name = augroup_name,
  }

  local group = vim.api.nvim_create_augroup(augroup_name, { clear = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = aside_buf,
    callback = function()
      local aside_data = aside_windows[source_win]
      if not aside_data then
        return
      end
      local save = require("aside.display.aside_save")
      local layout = aside_data.layout
          or { rows = {}, virt_lines_by_source_line = {} }
      save.handle_save(
        aside_data.buf,
        aside_data.source_path,
        aside_data.family,
        layout
      )
      aside_data.modified = false
      vim.schedule(function()
        if aside_windows[source_win] then
          M.render(source_win)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = aside_buf,
    callback = function()
      local aside_data = aside_windows[source_win]
      if aside_data then
        aside_data.modified = true
      end
    end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = aside_buf,
    callback = function()
      local aside_data = aside_windows[source_win]
      if aside_data then
        aside_data.in_insert = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = aside_buf,
    callback = function()
      local aside_data = aside_windows[source_win]
      if not aside_data then
        return
      end
      aside_data.in_insert = false
      if aside_data.pending_family then
        if aside_data.modified then
          vim.notify(
            "aside: unsaved changes; :w or :e! before switching family",
            vim.log.levels.ERROR
          )
          return
        end
        local pending = aside_data.pending_family
        aside_data.pending_family = nil
        aside_data.deferred_render = false
        M.set_family(source_win, pending)
        return
      end
      if aside_data.deferred_render then
        aside_data.deferred_render = false
        vim.schedule(function()
          if aside_windows[source_win] then
            M.render(source_win)
          end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      if not vim.api.nvim_win_is_valid(source_win) then
        return
      end
      local aside_data = aside_windows[source_win]
      if not aside_data or not vim.api.nvim_win_is_valid(aside_data.win) then
        return
      end
      if M.sync_scroll then
        M.sync_scroll(source_win)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      if not vim.api.nvim_win_is_valid(source_win) then
        return
      end
      if vim.api.nvim_get_current_win() == source_win then
        if M.handle_source_change then
          vim.schedule(function()
            M.handle_source_change(source_win)
          end)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function()
      if not vim.api.nvim_win_is_valid(source_win) then
        return
      end
      if vim.api.nvim_get_current_win() == source_win then
        if M.handle_source_change then
          vim.schedule(function()
            M.handle_source_change(source_win)
          end)
        end
      end
    end,
  })

  M.render(source_win)
end

function M.close(win)
  win = resolve_source_win(win)
  local aside_data = aside_windows[win]
  if not aside_data then
    return
  end

  -- Delete augroup to prevent leaks. nvim_del_augroup_by_name raises if the
  -- group is already gone, so always pcall it.
  if aside_data.augroup_name then
    pcall(vim.api.nvim_del_augroup_by_name, aside_data.augroup_name)
  end

  pcall(function()
    require("aside.display.aside_extmarks").clear(aside_data.buf)
  end)

  -- Clear source-side virt_lines
  local ok_buf, source_buf = pcall(vim.api.nvim_win_get_buf, win)
  if ok_buf and source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, source_buf, source_padding_ns, 0, -1)
  end

  if aside_data.win and vim.api.nvim_win_is_valid(aside_data.win) then
    pcall(vim.api.nvim_win_close, aside_data.win, true)
  end

  if aside_data.buf and vim.api.nvim_buf_is_valid(aside_data.buf) then
    pcall(vim.api.nvim_buf_delete, aside_data.buf, { force = true })
  end

  aside_windows[win] = nil
end

function M.handle_source_change(source_win)
  local aside_data = aside_windows[source_win]
  if not aside_data then
    return
  end
  if not vim.api.nvim_win_is_valid(source_win) then
    return
  end

  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local new_path = vim.api.nvim_buf_get_name(source_buf)

  if new_path == aside_data.source_path then
    return
  end

  if not new_path or new_path == "" then
    vim.notify("aside: source buffer has no name, aside cleared", vim.log.levels.WARN)
    aside_data.source_path = ""
    if vim.api.nvim_buf_is_valid(aside_data.buf) then
      vim.bo[aside_data.buf].modifiable = true
      vim.api.nvim_buf_set_lines(aside_data.buf, 0, -1, false, {})
      pcall(vim.api.nvim_buf_clear_namespace, aside_data.buf, hl_ns, 0, -1)
      pcall(function()
        require("aside.display.aside_extmarks").clear(aside_data.buf)
      end)
      vim.bo[aside_data.buf].modifiable = true
    end
    aside_data.layout = nil
    return
  end

  aside_data.source_path = new_path
  local new_buf_name = "aside://" .. aside_data.family .. "/" .. new_path
  pcall(vim.api.nvim_buf_set_name, aside_data.buf, new_buf_name)

  M.render(source_win)
end

function M.set_family(win, family_name)
  win = resolve_source_win(win)
  local aside_data = aside_windows[win]
  if not aside_data then
    vim.notify(
      "aside: no aside panel open for this window",
      vim.log.levels.ERROR
    )
    return
  end
  if aside_data.modified then
    vim.notify(
      "aside: unsaved changes; :w or :e! before switching family",
      vim.log.levels.ERROR
    )
    return
  end
  if aside_data.in_insert then
    aside_data.pending_family = family_name
    aside_data.deferred_render = true
    return
  end
  if not state.family_exists(family_name) then
    state.ensure_family(family_name)
  end
  aside_data.family = family_name

  if aside_data.buf and vim.api.nvim_buf_is_valid(aside_data.buf) then
    local new_name = "aside://" .. family_name .. "/" .. aside_data.source_path
    pcall(vim.api.nvim_buf_set_name, aside_data.buf, new_name)
  end

  M.render(win)
end

-- Reentrancy guard: prevents WinScrolled from triggering an infinite loop
-- when sync_scroll programmatically scrolls a window (which fires WinScrolled
-- again). Module-level so it spans both window callbacks.
local _syncing = false

--- Sync scroll position between a source window and its aside panel.
--- Uses nvim_win_text_height to compute visual row offsets so wrapped lines,
--- folds, and virt_lines stay aligned. Bidirectional: detects which window
--- fired WinScrolled via vim.v.event.window and syncs the other.
---@param source_win integer
function M.sync_scroll(source_win)
  if _syncing then
    return
  end
  local aside_data = aside_windows[source_win]
  if not aside_data then
    return
  end
  if not vim.api.nvim_win_is_valid(source_win)
    or not vim.api.nvim_win_is_valid(aside_data.win)
  then
    return
  end

  _syncing = true
  pcall(function()
    -- vim.v.event.window holds the window-id that scrolled (Neovim sets this
    -- on WinScrolled). Fallback to source_win if event context is missing.
    local scrolled_win = tonumber(vim.v.event and vim.v.event.window) or 0

    if scrolled_win == aside_data.win then
      M._sync_aside_to_source(source_win, aside_data)
    else
      -- Default: source scrolled (covers scrolled_win == source_win and 0).
      M._sync_source_to_aside(source_win, aside_data)
    end
  end)
  _syncing = false
end

--- Sync the aside panel topline to match the source window's visual scroll
--- offset. Counts visual rows (including wrap, folds, virt_lines) above the
--- source topline and applies the same row offset to the aside (which has
--- wrap=false / no folds, so visual rows == buffer rows).
---@param source_win integer
---@param aside_data table
function M._sync_source_to_aside(source_win, aside_data)
  local source_topline = vim.fn.line("w0", source_win)
  if source_topline <= 1 then
    pcall(vim.api.nvim_win_call, aside_data.win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    return
  end

  -- Count visual rows for buffer rows [0, source_topline - 2] (0-indexed,
  -- inclusive). `all` includes wrap, folds, and virt_lines.
  local ok, result = pcall(vim.api.nvim_win_text_height, source_win, {
    start_row = 0,
    end_row = source_topline - 2,
  })
  local visual_rows_before = (ok and result and result.all)
    or (source_topline - 1)

  -- Aside is 1:1 (wrap=false, no folds), so aside topline = offset + 1.
  local target_aside_row = visual_rows_before + 1
  local aside_line_count = vim.api.nvim_buf_line_count(aside_data.buf)
  target_aside_row = math.max(1, math.min(target_aside_row, aside_line_count))

  pcall(vim.api.nvim_win_call, aside_data.win, function()
    vim.fn.winrestview({ topline = target_aside_row })
  end)
end

--- Sync the source window's topline to match the aside panel's visual scroll
--- offset. Binary-searches for the source buffer row whose cumulative visual
--- row count matches the aside's topline offset.
---@param source_win integer
---@param aside_data table
function M._sync_aside_to_source(source_win, aside_data)
  local aside_topline = vim.fn.line("w0", aside_data.win)
  if aside_topline <= 1 then
    pcall(vim.api.nvim_win_call, source_win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    return
  end

  -- Aside is 1:1, so target visual offset is aside_topline - 1.
  local visual_rows_before = aside_topline - 1

  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local source_line_count = vim.api.nvim_buf_line_count(source_buf)

  -- Binary search for smallest 1-indexed buffer row `mid` such that visual
  -- rows for [0, mid-1] >= visual_rows_before. That row becomes the new
  -- topline.
  local lo, hi = 1, source_line_count
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local ok, result = pcall(vim.api.nvim_win_text_height, source_win, {
      start_row = 0,
      end_row = mid - 1,
    })
    local rows = (ok and result and result.all) or mid
    if rows < visual_rows_before then
      lo = mid + 1
    else
      hi = mid
    end
  end

  local target_source_row = math.max(1, math.min(lo, source_line_count))

  pcall(vim.api.nvim_win_call, source_win, function()
    vim.fn.winrestview({ topline = target_source_row })
  end)
end

--- Apply source-side virt_lines padding for crowded annotations.
--- Clears the dedicated namespace first to prevent accumulation across renders.
---@param source_buf integer Source buffer handle
---@param virt_lines_by_source_line table<integer, integer> source_line -> count
function M.apply_source_virt_lines(source_buf, virt_lines_by_source_line)
  if not vim.api.nvim_buf_is_valid(source_buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(source_buf, source_padding_ns, 0, -1)

  for source_line, count in pairs(virt_lines_by_source_line) do
    if count > 0 then
      local virt_lines = {}
      for _ = 1, count do
        table.insert(virt_lines, { { "", "Conceal" } })
      end
      pcall(vim.api.nvim_buf_set_extmark, source_buf, source_padding_ns, source_line - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
      })
    end
  end
end

--- Render the aside buffer for a source window using the layout solver.
--- Only handles aside-buffer text + highlight extmarks + edit-region extmarks.
--- Does NOT manage window lifecycle (Task 11), scroll sync (Task 13), or
--- source-side virt_lines insertion (Task 15).
---@param source_win integer
function M.render(source_win)
  local aside_data = aside_windows[source_win]
  if not aside_data then
    return
  end

  -- Resolve source buffer / path. Tests may pre-populate these in aside_data.
  local source_buf = aside_data.source_buf
  if not source_buf and vim.api.nvim_win_is_valid(source_win) then
    source_buf = vim.api.nvim_win_get_buf(source_win)
  end
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    return
  end
  local source_path = vim.api.nvim_buf_get_name(source_buf)
  aside_data.source_path = source_path

  -- Filter annotations for current family and source path.
  local all_annotations = require("aside.annotations").get_by_file(source_path)
  local family_annotations = {}
  for _, ann in ipairs(all_annotations) do
    if ann.family == aside_data.family then
      table.insert(family_annotations, ann)
    end
  end

  -- Resolve family config (with global fallback).
  local family = state.get_family(aside_data.family)
  local family_config = family and family:get_config() or {}
  local global = config.get() or {}

  local gutter_icon = family_config.gutter_icon
    or config.get_value("default_gutter_icon", "\226\151\143")
  local spill_direction = family_config.spill_direction
    or config.get_value("spill_direction", "below")
  local solver_name = family_config.layout_solver
    or config.get_value("layout_solver", "greedy")
  local hl_groups = family_config.highlight_groups or global.highlight_groups or {}

  -- Resolve wrap_width. Allow test override via aside_data.wrap_width.
  local wrap_width
  if aside_data.wrap_width then
    wrap_width = aside_data.wrap_width
  else
    local ok, win_width = pcall(vim.api.nvim_win_get_width, aside_data.win)
    if ok and type(win_width) == "number" then
      -- 2 gutter cols + 1 safety col for cursor / wrap
      wrap_width = math.max(1, win_width - 2 - 1)
    else
      wrap_width = 37
    end
  end

  local source_line_count = vim.api.nvim_buf_line_count(source_buf)

  -- Solve layout.
  local layout = require("aside.layout").get(solver_name).solve(
    family_annotations,
    source_line_count,
    {
      spill_direction = spill_direction,
      wrap_width = wrap_width,
      gutter_icon = gutter_icon,
    }
  )

  -- Apply source-side virt_lines for crowded annotations
  if layout.virt_lines_by_source_line and next(layout.virt_lines_by_source_line) then
    M.apply_source_virt_lines(source_buf, layout.virt_lines_by_source_line)
  else
    -- Clear any existing padding
    if vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_clear_namespace(source_buf, source_padding_ns, 0, -1)
    end
  end

  -- Build buffer text from rows.
  local lines = {}
  for i, row in ipairs(layout.rows) do
    lines[i] = row.text or ""
  end

  -- Write buffer.
  local aside_buf = aside_data.buf
  if not vim.api.nvim_buf_is_valid(aside_buf) then
    return
  end
  vim.bo[aside_buf].modifiable = true
  vim.api.nvim_buf_set_lines(aside_buf, 0, -1, false, lines)

  -- Reset highlight namespace before re-applying.
  vim.api.nvim_buf_clear_namespace(aside_buf, hl_ns, 0, -1)

  local gutter_prefix_bytes = #gutter_icon + 1 -- gutter_icon + " "

  for i, row in ipairs(layout.rows) do
    local line_idx = i - 1
    local line_bytes = #lines[i]
    if row.row_kind == "title" then
      -- Highlight the gutter prefix (icon + space) and the title separately.
      if gutter_prefix_bytes > 0 and gutter_prefix_bytes <= line_bytes then
        pcall(vim.api.nvim_buf_set_extmark, aside_buf, hl_ns, line_idx, 0, {
          end_col = math.min(gutter_prefix_bytes, line_bytes),
          hl_group = hl_groups.gutter or "AsideGutter",
        })
      end
      if line_bytes > gutter_prefix_bytes then
        pcall(vim.api.nvim_buf_set_extmark, aside_buf, hl_ns, line_idx, gutter_prefix_bytes, {
          end_col = line_bytes,
          hl_group = hl_groups.title or "AsideTitle",
        })
      end
    elseif row.row_kind == "content" then
      if line_bytes > 0 then
        pcall(vim.api.nvim_buf_set_extmark, aside_buf, hl_ns, line_idx, 0, {
          end_col = line_bytes,
          hl_group = hl_groups.contents or "AsideContents",
        })
      end
    end
  end

  -- Place edit-region extmarks (seg_start / wrap_cont / ann_end).
  require("aside.display.aside_extmarks").place(aside_buf, layout)

  -- Persist layout for statuscolumn callback and scroll sync.
  aside_data.layout = layout

  -- Buffer stays editable (no modifiable = false here).
  vim.bo[aside_buf].modifiable = true
end

--- Statuscolumn callback for the aside buffer.
--- Called per-row with `vim.v.lnum` set (1-indexed). Returns the 2-column
--- glyph string composed of the outer box glyph and inner anchor glyph.
---@param buf integer Aside buffer handle
---@return string statuscolumn content
function M.statuscolumn_for_buf(buf)
  local aside_data = nil
  for _, data in pairs(aside_windows) do
    if data.buf == buf then
      aside_data = data
      break
    end
  end
  if not aside_data or not aside_data.layout then
    return "  "
  end

  local lnum = vim.v.lnum -- 1-indexed
  local row = aside_data.layout.rows[lnum]
  if not row then
    return "  "
  end

  local outer_glyph = ({
    top = "\226\148\140",     -- ┌
    middle = "\226\148\130",  -- │
    bottom = "\226\148\148",  -- └
    single = "\226\148\128",  -- ─
    none = " ",
  })[row.box_position] or " "

  local inner_glyph = ({
    top = "\226\148\144",     -- ┐
    middle = "\226\148\156",  -- ├
    bottom = "\226\148\152",  -- ┘
    single = "\226\148\164",  -- ┤
    none = " ",
  })[row.anchor_position] or " "

  return "%#AsideBorder#" .. outer_glyph .. inner_glyph
end

function M.refresh_if_visible(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  for source_win, aside_data in pairs(aside_windows) do
    if aside_data.source_path == path then
      if aside_data.in_insert then
        aside_data.deferred_render = true
        return
      else
        M.render(source_win)
      end
    end
  end
end

function M.get_aside_data(source_win)
  return aside_windows[resolve_source_win(source_win)]
end

return M
