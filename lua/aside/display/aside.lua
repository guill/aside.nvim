--- Aside panel: a split next to a source window whose rows line up with the
--- source lines they annotate.
---
--- Alignment model. The aside buffer is split into one block per source line
--- (aside_extmarks tracks which rows belong to which block, also while the
--- user edits). Consecutive source lines inside a closed fold form one group;
--- otherwise each line is its own group. For every group:
---   source rows S_src = text rows (wrap) + foreign virt_lines
---   aside rows  S_asd = buffer rows + closer virt_lines (1 if folded)
---   S = max(S_src, S_asd); the shorter side gets virt_line padding.
--- Both windows then show exactly S rows per group, so a view in one window
--- maps to the same (group, row offset) in the other (see `sync`).

local M = {}

local state = require("aside.state")
local config = require("aside.config")
local extmarks = require("aside.display.aside_extmarks")
local layout_mod = require("aside.layout")

local windows = {} -- source_win -> panel window state
local pstate = {} -- aside buf -> { layout }
local orphans = {} -- panel key -> modified aside buf whose window was closed

local hl_ns = vim.api.nvim_create_namespace("aside_render_hl")
local virt_ns = vim.api.nvim_create_namespace("aside_virt")
local check_ns = vim.api.nvim_create_namespace("aside_check")
local gutter_ns = vim.api.nvim_create_namespace("aside_gutter")
local group = vim.api.nvim_create_augroup("AsidePanel", { clear = false })

local ANCHOR_GLYPH = {
  top = "\226\148\144", middle = "\226\148\130", bottom = "\226\148\152", -- ┐ │ ┘
  single = "\226\148\130", connector = "\226\148\156", none = " ", -- │ ├
}
local BOX_GLYPH = {
  top = "\226\148\140", middle = "\226\148\130", bottom = "\226\148\148", -- ┌ │ └
  single = "\226\148\128", connector = "\226\148\164", none = " ", -- ─ ┤
}
local VBAR = "\226\148\130"
local CLOSER_DASHES = string.rep("\226\148\128", 13)

local function valid_win(w)
  return type(w) == "number" and vim.api.nvim_win_is_valid(w)
end

local function valid_buf(b)
  return type(b) == "number" and vim.api.nvim_buf_is_valid(b)
end

local function panel_key(family, path)
  return family .. "\0" .. path
end

--- Source window owning the panel shown in `win` (or `win` itself).
local function resolve_source_win(win)
  win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
  if windows[win] then
    return win
  end
  for source_win, data in pairs(windows) do
    if data.win == win then
      return source_win
    end
  end
  return win
end

local function owner_of(buf)
  for source_win, W in pairs(windows) do
    if W.buf == buf then
      return source_win, W
    end
  end
end

local function is_modified(W)
  return W.modified == true or (valid_buf(W.buf) and vim.bo[W.buf].modified) or false
end

local function family_config(name)
  local family = state.get_family(name)
  return (family and family:get_config()) or {}
end

local function pad_ns(W)
  if not W.pad_ns then
    W.pad_ns = vim.api.nvim_create_namespace("aside_source_padding_" .. W.source_win)
    -- Scope to the source window: another window on the same buffer has its
    -- own panel and needs its own padding.
    pcall(vim.api.nvim__ns_set, W.pad_ns, { wins = { W.source_win } })
  end
  return W.pad_ns
end

--- Tell the opener which padding rows the source window got, so it can
--- mirror them into windows that must stay row-aligned with the source.
local function notify_padding(W)
  if W.on_padding then
    local ok, err = pcall(W.on_padding, vim.deepcopy(W.pad), W.pad_buf)
    if not ok then
      vim.notify("aside: on_padding failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function clear_padding(W)
  if valid_buf(W.pad_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, W.pad_buf, pad_ns(W), 0, -1)
  end
  W.pad, W.pad_buf = {}, nil
  notify_padding(W)
end

-- ---------------------------------------------------------------------------
-- Scroll sync
-- ---------------------------------------------------------------------------

local function view(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

local function view_key(win)
  local v = view(win)
  return v.topline .. ":" .. v.topfill .. ":" .. v.skipcol
end

--- Scroll `win` to (topline, topfill). Moves the cursor only when it would
--- leave the view (respecting 'scrolloff'), so Neovim does not scroll back.
local function set_view(win, topline, topfill)
  vim.api.nvim_win_call(win, function()
    local v = vim.fn.winsaveview()
    if v.topline == topline and v.topfill == topfill then
      return
    end
    vim.fn.winrestview({ topline = topline, topfill = topfill })
    local so = vim.wo.scrolloff >= 0 and vim.wo.scrolloff or vim.go.scrolloff
    local last, bot = vim.fn.line("$"), vim.fn.line("w$")
    local lo = topline == 1 and 1 or math.min(topline + so, last)
    local hi = bot >= last and last or math.max(bot - so, topline)
    local lnum = v.lnum
    if lo > hi then
      lnum = math.floor((topline + bot) / 2)
    elseif lnum < lo then
      lnum = lo
    elseif lnum > hi then
      lnum = hi
    end
    if lnum ~= v.lnum then
      vim.fn.winrestview({ topline = topline, topfill = topfill, lnum = lnum, col = 0, curswant = v.curswant })
    end
  end)
end

-- (group, offset) at the top of the source view.
local function source_pos(W)
  local v = view(W.source_win)
  local g = W.line_group[v.topline] or #W.groups
  if v.topfill > 0 and g > 1 then
    g = g - 1
    return g, math.max(0, W.groups[g].S - v.topfill)
  end
  return g, 0
end

-- (group, offset) at the top of the aside view.
local function aside_pos(W)
  local v = view(W.win)
  local idx
  if v.topfill > 0 then
    local row = v.topline - 2
    local n = W.virt_n[row] or 0
    idx = W.virt_item[row .. ":" .. (n - v.topfill + 1)]
  end
  idx = idx or W.row_item[v.topline]
  local item = idx and W.seq[idx]
  if not item then
    return nil
  end
  return item.g, idx - W.groups[item.g].first_item
end

local function aside_view_for(W, g, k)
  local grp = W.groups[g]
  if not grp then
    return nil
  end
  local item = W.seq[grp.first_item + math.max(0, math.min(k, grp.S - 1))]
  if not item then
    return nil
  end
  if item.row then
    return item.row, 0
  end
  local count = vim.api.nvim_buf_line_count(W.buf)
  local top = item.vrow + 2
  if top > count then
    return count, 0
  end
  return top, (W.virt_n[item.vrow] or 0) - item.vi + 1
end

-- `dir` picks the side to round to when the offset falls inside a wrapped
-- source line (a topline cannot start mid-line without 'smoothscroll').
local function source_view_for(W, g, k, dir)
  local grp = W.groups[g]
  if k < grp.text then
    if k == 0 or dir < 0 then
      return grp.first, 0
    end
    k = grp.text
  end
  local nxt = W.groups[g + 1]
  if not nxt then
    return grp.first, 0
  end
  return nxt.first, grp.S - k
end

--- Bring the two views back in line. `origin` names the window whose view
--- wins ("source" / "aside"); nil detects which one moved since last sync.
local function sync(W, origin)
  if not W.groups or not (valid_win(W.source_win) and valid_win(W.win)) then
    return
  end
  if vim.api.nvim_win_get_buf(W.win) ~= W.buf then
    return
  end
  if not origin then
    if not W.last or view_key(W.source_win) ~= W.last.src then
      origin = "source"
    elseif view_key(W.win) ~= W.last.aside then
      origin = "aside"
    else
      return
    end
  end
  if origin == "aside" then
    local g, k = aside_pos(W)
    if g then
      local dir = 1
      if W.pos and (g < W.pos[1] or (g == W.pos[1] and k < W.pos[2])) then
        dir = -1
      end
      set_view(W.source_win, source_view_for(W, g, k, dir))
      -- 'scrollbind' only propagates from the current window; carry the
      -- scroll on to the source's partners (e.g. the other side of a diff).
      if vim.wo[W.source_win].scrollbind then
        vim.api.nvim_win_call(W.source_win, function() vim.cmd("silent! syncbind") end)
      end
    end
  end
  local g, k = source_pos(W)
  local top, fill = aside_view_for(W, g, k)
  if top then
    set_view(W.win, top, fill)
  end
  W.pos = { g, k }
  W.last = { src = view_key(W.source_win), aside = view_key(W.win) }
end

-- ---------------------------------------------------------------------------
-- Alignment
-- ---------------------------------------------------------------------------

--- Measure the source window: fold groups, text rows per line (wrap) and
--- virt_lines placed by other plugins (all treated as below the line).
local function measure(W, source_buf)
  local src = W.source_win
  local n = vim.api.nvim_buf_line_count(source_buf)
  local pad = (W.pad_buf == source_buf and W.pad) or {}
  local groups, line_group = {}, {}
  vim.api.nvim_win_call(src, function()
    local spans, line = {}, 1
    while line <= n do
      local fe = vim.fn.foldclosedend(line)
      if fe > 0 then
        table.insert(spans, { line, fe, true })
        line = fe + 1
      else
        table.insert(spans, { line, line, false })
        line = line + 1
      end
    end
    local total = vim.api.nvim_win_text_height(src, {})
    local our = 0
    for _, c in pairs(pad) do our = our + c end
    -- Fast path: every visible line is one row and all fill is ours.
    local simple = total.fill == our and total.all - total.fill == #spans
    for _, sp in ipairs(spans) do
      local g = { first = sp[1], last = sp[2], fold = sp[3], text = 1, foreign = 0 }
      local prev = groups[#groups]
      if not simple then
        -- A line's "fill" is the filler drawn ABOVE it, i.e. virt_lines
        -- below the previous line: credit it to the previous group.
        local h = vim.api.nvim_win_text_height(src, { start_row = sp[1] - 1, end_row = sp[1] - 1 })
        if not sp[3] then g.text = h.all - h.fill end
        if prev then prev.foreign = math.max(0, h.fill - (pad[prev.last] or 0)) end
      end
      table.insert(groups, g)
      for l = sp[1], sp[2] do line_group[l] = #groups end
    end
  end)
  return { buf = source_buf, n = n, groups = groups, line_group = line_group }
end

-- Gutter glyphs for a filler row between two buffer rows.
local function filler_glyphs(prev, nxt)
  local inner, outer = " ", " "
  if prev and nxt and prev.ann_id and prev.ann_id == nxt.ann_id then
    inner = VBAR
  end
  local open = { top = true, middle = true, connector = true }
  local cont = { middle = true, bottom = true, connector = true }
  if prev and nxt and open[prev.anchor_position] and cont[nxt.anchor_position] then
    outer = VBAR
  end
  return outer .. inner
end

local function apply_folds(W, folds)
  local sig = vim.inspect(folds)
  if W.fold_sig == sig then
    return
  end
  W.fold_sig = sig
  vim.api.nvim_win_call(W.win, function()
    vim.cmd("silent! normal! zE")
    for _, f in ipairs(folds) do
      vim.cmd(("silent! %d,%dfold"):format(f[1], f[2]))
    end
  end)
end

--- A winbar takes the first screen row, so the panel needs one exactly when
--- the source has one, or every row is off by one. A winbar the opener put
--- on the panel is kept.
local function match_winbar(W)
  local want = vim.wo[W.source_win].winbar ~= ""
  local has = vim.wo[W.win].winbar ~= ""
  if want ~= has then
    vim.api.nvim_set_option_value("winbar", want and " " or "", { win = W.win, scope = "local" })
  end
end

--- Recompute padding on both sides from the live aside rows and the source
--- measurements, then re-sync the views. Never rewrites aside text.
local function realign(W, remeasure)
  local src, buf = W.source_win, W.buf
  if not (valid_win(src) and valid_win(W.win) and valid_buf(buf)) or not W.layout then
    return
  end
  if vim.api.nvim_win_get_buf(W.win) ~= buf then
    return
  end
  match_winbar(W)
  local source_buf = vim.api.nvim_win_get_buf(src)
  if remeasure or not W.measure or W.measure.buf ~= source_buf then
    W.measure = measure(W, source_buf)
  end
  local m = W.measure

  local live = extmarks.read(buf, W.layout)
  local anns = {}
  for _, a in ipairs(W.layout.annotations or {}) do
    local cur = state.get_annotation(a.id)
    table.insert(anns, cur and { id = a.id, start_line = cur.start_line, end_line = cur.end_line } or a)
  end
  layout_mod.decorate(live, anns)
  local rows, per_block = {}, {}
  for _, e in ipairs(live) do
    if e.lnum then rows[e.lnum] = e end
    local line = math.max(1, math.min(e.source_line, m.n))
    per_block[line] = per_block[line] or {}
    table.insert(per_block[line], e)
  end

  local seq, row_item, virt, virt_item, folds, pads = {}, {}, {}, {}, {}, {}
  local last_row = -1 -- 0-indexed buffer row new virt_lines attach below
  local function add_virt(g, item)
    virt[last_row] = virt[last_row] or {}
    table.insert(virt[last_row], item)
    table.insert(seq, { g = g, vrow = last_row, vi = #virt[last_row] })
    virt_item[last_row .. ":" .. #virt[last_row]] = #seq
  end
  local function add_row(g, lnum)
    table.insert(seq, { g = g, row = lnum })
    row_item[lnum] = #seq
    last_row = lnum - 1
  end

  for gi, grp in ipairs(m.groups) do
    grp.first_item = #seq + 1
    local visible = 0
    if grp.fold then
      local fold_rows = {}
      for line = grp.first, grp.last do
        for _, e in ipairs(per_block[line] or {}) do
          if e.lnum then table.insert(fold_rows, e.lnum) end
        end
      end
      if #fold_rows > 0 then
        add_row(gi, fold_rows[1])
        last_row = fold_rows[#fold_rows] - 1
        if #fold_rows > 1 then table.insert(folds, { fold_rows[1], fold_rows[#fold_rows] }) end
        visible = 1
      end
    else
      for _, e in ipairs(per_block[grp.first] or {}) do
        if e.lnum then
          add_row(gi, e.lnum)
        else
          add_virt(gi, { closer = e })
        end
        visible = visible + 1
      end
    end
    local src_rows = grp.text + grp.foreign
    grp.S = math.max(src_rows, visible)
    for _ = visible + 1, grp.S do
      add_virt(gi, { fill = true })
    end
    if grp.S > src_rows and not grp.fold then
      pads[grp.last] = grp.S - src_rows
    end
  end

  -- Source padding (window-scoped).
  local ns = pad_ns(W)
  if W.pad_buf and W.pad_buf ~= source_buf then
    clear_padding(W)
  end
  vim.api.nvim_buf_clear_namespace(source_buf, ns, 0, -1)
  for line, count in pairs(pads) do
    local lines = {}
    for _ = 1, count do table.insert(lines, { { "", "Normal" } }) end
    pcall(vim.api.nvim_buf_set_extmark, source_buf, ns, line - 1, 0, { virt_lines = lines })
  end
  W.pad, W.pad_buf = pads, source_buf
  notify_padding(W)

  -- Aside virt_lines: closers and filler, drawn over the gutter.
  vim.api.nvim_buf_clear_namespace(buf, virt_ns, 0, -1)
  local virt_n = {}
  for row, items in pairs(virt) do
    virt_n[row] = #items
    local lines = {}
    for _, it in ipairs(items) do
      local text
      if it.closer then
        text = ANCHOR_GLYPH[it.closer.anchor_position] .. BOX_GLYPH.bottom .. CLOSER_DASHES
      else
        text = filler_glyphs(rows[row + 1], rows[row + 2])
      end
      table.insert(lines, { { text, "AsideBorder" } })
    end
    local above = row < 0
    pcall(vim.api.nvim_buf_set_extmark, buf, virt_ns, above and 0 or row, 0, {
      virt_lines = lines, virt_lines_above = above, virt_lines_leftcol = true,
    })
  end

  -- Gutter glyphs as signs. ('statuscolumn' is evaluated with the previous
  -- line's v:lnum for a topline whose filler is scrolled off, which drew
  -- the wrong glyphs; signs are placed per line and do not have that bug.)
  vim.api.nvim_buf_clear_namespace(buf, gutter_ns, 0, -1)
  for lnum, e in pairs(rows) do
    local glyphs = ANCHOR_GLYPH[e.anchor_position] .. BOX_GLYPH[e.box_position]
    if glyphs ~= "  " then
      pcall(vim.api.nvim_buf_set_extmark, buf, gutter_ns, lnum - 1, 0, { sign_text = glyphs, sign_hl_group = "AsideBorder" })
    end
  end

  apply_folds(W, folds)

  W.rows, W.seq, W.row_item, W.virt_n, W.virt_item = rows, seq, row_item, virt_n, virt_item
  W.groups, W.line_group = m.groups, m.line_group
  sync(W, vim.api.nvim_get_current_win() == W.win and "aside" or "source")
end

-- Re-measure when what the source window shows (folds, wrapping, other
-- plugins' virt_lines) no longer matches the model in the visible range.
local function check(W)
  local src, m = W.source_win, W.measure
  if not m or not valid_win(src) or vim.api.nvim_win_get_buf(src) ~= m.buf then
    return
  end
  if vim.api.nvim_buf_line_count(m.buf) ~= m.n then
    return -- the source was edited; the pending re-render handles it
  end
  local stale, sig = false, {}
  vim.api.nvim_win_call(src, function()
    local line, bot = vim.fn.line("w0"), vim.fn.line("w$")
    while line <= bot do
      local fe = vim.fn.foldclosedend(line)
      local g = m.groups[m.line_group[line]]
      if fe > 0 then
        table.insert(sig, line .. "-" .. fe)
        stale = stale or not (g and g.fold and g.first == line and g.last == fe)
        line = fe + 1
      else
        local h = vim.api.nvim_win_text_height(src, { start_row = line - 1, end_row = line - 1 })
        local prev = g and m.groups[m.line_group[line] - 1]
        table.insert(sig, h.all .. "/" .. h.fill)
        stale = stale or not g or g.fold or h.all - h.fill ~= g.text
          or (prev ~= nil and h.fill ~= prev.foreign + ((W.pad or {})[prev.last] or 0))
        line = line + 1
      end
    end
  end)
  sig = table.concat(sig, ",")
  if stale and W.stale_sig ~= sig then
    W.stale_sig = sig -- never retry the same mismatch (no redraw loops)
    realign(W, true)
  end
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function set_layout(W, layout)
  W.layout = layout
  if valid_buf(W.buf) then
    pstate[W.buf] = { layout = layout }
  end
end

local function highlight(buf, layout, icon, hl_groups)
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  local prefix = icon .. " "
  local row = 0
  for _, r in ipairs(layout.rows) do
    if r.row_kind ~= "closer" then
      local text = r.text or ""
      local from = 0
      if r.row_kind == "title" and vim.startswith(text, prefix) then
        pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, row, 0, { end_col = #prefix, hl_group = hl_groups.gutter or "AsideGutter" })
        from = #prefix
      end
      local group_name = r.row_kind == "title" and (hl_groups.title or "AsideTitle")
        or r.row_kind == "content" and (hl_groups.contents or "AsideContents")
      if group_name and #text > from then
        pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, row, from, { end_col = #text, hl_group = group_name })
      end
      row = row + 1
    end
  end
end

--- Re-render the panel for `source_win`. While the panel has unsaved edits
--- (or is in insert mode) the text is kept and only alignment is refreshed;
--- the full render is deferred until `:w` / `:e!` (`force` overrides).
---@param source_win integer
---@param force? boolean
function M.render(source_win, force)
  local W = windows[source_win]
  if not W then
    return
  end
  if not force and (W.in_insert or is_modified(W)) then
    W.deferred_render = true
    return realign(W, true)
  end
  W.deferred_render = false
  if not (valid_win(source_win) and valid_buf(W.buf)) then
    return
  end
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local path = vim.api.nvim_buf_get_name(source_buf)

  local anns = {}
  if path ~= "" then
    for _, a in ipairs(require("aside.annotations").get_by_file(path)) do
      if a.family == W.family then table.insert(anns, a) end
    end
  end
  local fc = family_config(W.family)
  local icon = fc.gutter_icon or config.get_value("default_gutter_icon", "\226\151\143")
  local width = valid_win(W.win) and vim.api.nvim_win_get_width(W.win) or (fc.aside_width or config.get_value("aside_width", 40))
  W.width = width
  local layout = layout_mod.get(fc.layout_solver or config.get_value("layout_solver", "greedy")).solve(
    anns,
    vim.api.nvim_buf_line_count(source_buf),
    {
      spill_direction = fc.spill_direction or config.get_value("spill_direction", "below"),
      wrap_width = math.max(1, width - 2 - 1), -- 2 gutter cols + 1 for the cursor
      gutter_icon = icon,
    }
  )

  local lines = {}
  for _, r in ipairs(layout.rows) do
    if r.row_kind ~= "closer" then table.insert(lines, r.text or "") end
  end
  local buf = W.buf
  -- Writing with 'undolevels' -1 also clears undo history, so `u` cannot
  -- undo a render.
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.bo[buf].modified = false

  highlight(buf, layout, icon, fc.highlight_groups or config.get().highlight_groups or {})
  extmarks.place(buf, layout, source_buf)
  set_layout(W, layout)
  realign(W, true)
end

-- ---------------------------------------------------------------------------
-- Panel buffers
-- ---------------------------------------------------------------------------

local function save(source_win, W)
  local buf = W.buf
  require("aside.display.aside_save").handle_save(buf, W.source_path, W.family, W.layout, function()
    if windows[source_win] == W and W.buf == buf then
      M.render(source_win, true)
    end
  end)
end

local function attach_buffer_autocmds(buf)
  local function on(events, fn)
    vim.api.nvim_create_autocmd(events, {
      group = group,
      buffer = buf,
      callback = function()
        local source_win, W = owner_of(buf)
        if W then fn(source_win, W) end
      end,
    })
  end
  on("BufWriteCmd", save)
  on("BufReadCmd", function(source_win) M.render(source_win, true) end)
  on({ "TextChanged", "TextChangedI" }, function(_, W) realign(W) end)
  on("InsertEnter", function(_, W) W.in_insert = true end)
  on("InsertLeave", function(source_win, W)
    W.in_insert = false
    if W.pending_family then
      local pending = W.pending_family
      W.pending_family = nil
      return M.set_family(source_win, pending)
    end
    if W.deferred_render then
      M.render(source_win)
    end
  end)
end

local function wipe_panel(buf)
  pstate[buf] = nil
  extmarks.clear(buf)
  if valid_buf(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

-- Panel buffer for (W.family, path): reuse an unsaved one left behind by a
-- closed window, else create one.
local function get_panel(W, path)
  local key = panel_key(W.family, path)
  local buf = W.panels[key]
  if not valid_buf(buf) then
    buf = orphans[key]
    orphans[key] = nil
  end
  if not valid_buf(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "aside"
    local name = "aside://" .. W.family .. "/" .. path
    if not pcall(vim.api.nvim_buf_set_name, buf, name) then
      pcall(vim.api.nvim_buf_set_name, buf, name .. " #" .. W.source_win)
    end
    attach_buffer_autocmds(buf)
  end
  W.panels[key] = buf
  return buf
end

-- Show the panel for the current family/path in the aside window.
local function show_panel(W)
  W.buf = get_panel(W, W.source_path)
  local layout = pstate[W.buf] and pstate[W.buf].layout
  W.layout, W.measure, W.fold_sig, W.last = layout, nil, nil, nil
  if valid_win(W.win) and vim.api.nvim_win_get_buf(W.win) ~= W.buf then
    vim.api.nvim_win_set_buf(W.win, W.buf)
  end
end

-- Switch the aside window to the panel for (family, path). The previous
-- panel is wiped unless it holds unsaved edits; it is replaced in the window
-- first, since deleting a displayed buffer would close the window.
local function switch_panel(W, family, path)
  local old_buf, old_key = W.buf, panel_key(W.family, W.source_path)
  W.family, W.source_path = family, path
  show_panel(W)
  if old_buf ~= W.buf and valid_buf(old_buf) and not vim.bo[old_buf].modified then
    W.panels[old_key] = nil
    wipe_panel(old_buf)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Test helper: inject panel state for a (possibly fake) source window.
function M._test_set_data(source_win, data)
  data.source_win = data.source_win or source_win
  windows[source_win] = data
end

function M._test_get_data(source_win)
  return windows[source_win]
end

local function setup_aside_win(win)
  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "yes:1" -- one 2-cell sign: anchor bracket + box
  wo.foldcolumn = "0"
  wo.cursorline = false
  wo.list = false
  wo.spell = false
  wo.foldmethod = "manual"
  wo.foldenable = true
  wo.foldminlines = 0
  wo.scrolloff = 0
  wo.sidescrolloff = 0
  wo.winfixwidth = true
  wo.statuscolumn = ""
end

function M.setup()
  group = vim.api.nvim_create_augroup("AsidePanel", { clear = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      for source_win, W in pairs(windows) do
        if W.win == closed or source_win == closed then
          W.closing = true
          vim.schedule(function() M.close(source_win) end)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      for _, W in pairs(windows) do
        if not W.closing then sync(W) end
      end
      -- Neovim snapshots views before running WinScrolled and only compares
      -- again on its next main-loop pass. Views changed by the sync above
      -- would otherwise stay unrecorded until the next key, and a key that
      -- scrolls back to the stale snapshot would fire no WinScrolled at all.
      vim.schedule(function() end)
    end,
  })

  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for source_win, W in pairs(windows) do
        if not W.closing and valid_win(W.win) and valid_win(source_win) then
          local widths = vim.api.nvim_win_get_width(W.win) .. ":" .. vim.api.nvim_win_get_width(source_win)
          if W.widths ~= widths then
            W.widths = widths
            M.render(source_win)
          else
            sync(W)
          end
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function()
      for source_win in pairs(windows) do
        vim.schedule(function() M.handle_source_change(source_win) end)
      end
    end,
  })

  -- Source edits: re-render after tracking has moved the annotations.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(args)
      for source_win, W in pairs(windows) do
        if valid_win(source_win) and vim.api.nvim_win_get_buf(source_win) == args.buf and not W.render_queued then
          W.render_queued = true
          vim.defer_fn(function()
            W.render_queued = false
            M.render(source_win)
          end, 150)
        end
      end
    end,
  })

  vim.api.nvim_set_decoration_provider(check_ns, {
    on_win = function(_, winid)
      local W = windows[winid]
      if W and not W.check_queued then
        W.check_queued = true
        vim.schedule(function()
          W.check_queued = false
          if windows[winid] == W then check(W) end
        end)
      end
      return false
    end,
  })
end

---@param opts {family: string, win?: integer, buf?: integer, on_padding?: fun(pads: table<integer, integer>, source_buf: integer?)}
---@return integer? win
function M.open(opts)
  opts = opts or {}
  local family_name = opts.family
  if not family_name then
    vim.notify("aside: family is required for open_aside", vim.log.levels.ERROR)
    return
  end
  local source_win = resolve_source_win(opts.buf and 0 or opts.win)
  if windows[source_win] then
    windows[source_win].on_padding = opts.on_padding or windows[source_win].on_padding
    M.set_family(source_win, family_name)
    return windows[source_win] and windows[source_win].win
  end

  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local source_path = vim.api.nvim_buf_get_name(source_buf)
  if source_path == "" or vim.bo[source_buf].filetype == "aside" then
    vim.notify("aside: source buffer has no name; cannot open aside panel", vim.log.levels.ERROR)
    return
  end
  state.ensure_family(family_name)

  local W = {
    source_win = source_win,
    family = family_name,
    source_path = source_path,
    panels = {},
    in_insert = false,
    deferred_render = false,
    modified = false, -- forced "dirty" flag; the buffer's 'modified' also counts
    on_padding = opts.on_padding,
  }
  windows[source_win] = W
  W.buf = get_panel(W, source_path)
  W.layout = pstate[W.buf] and pstate[W.buf].layout
  local width = family_config(family_name).aside_width or config.get_value("aside_width", 40)
  W.win = vim.api.nvim_open_win(W.buf, false, { split = "right", win = source_win, width = width })
  setup_aside_win(W.win)
  W.widths = vim.api.nvim_win_get_width(W.win) .. ":" .. vim.api.nvim_win_get_width(source_win)
  M.render(source_win)
  return W.win
end

function M.close(win)
  win = resolve_source_win(win)
  local W = windows[win]
  if not W then
    return
  end
  windows[win] = nil
  clear_padding(W)
  if valid_win(W.win) then
    pcall(vim.api.nvim_win_close, W.win, true)
  end
  for key, buf in pairs(W.panels or {}) do
    if valid_buf(buf) and vim.bo[buf].modified then
      orphans[key] = buf -- keep unsaved edits for the next open
    else
      wipe_panel(buf)
    end
  end
end

--- Follow the source window to a different file.
function M.handle_source_change(source_win)
  local W = windows[source_win]
  if not W or W.closing or not valid_win(source_win) then
    return
  end
  local new_path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win))
  if new_path == W.source_path or vim.bo[vim.api.nvim_win_get_buf(source_win)].filetype == "aside" then
    return
  end
  if new_path == "" then
    vim.notify("aside: source buffer has no name, aside cleared", vim.log.levels.WARN)
  end
  clear_padding(W)
  switch_panel(W, W.family, new_path)
  M.render(source_win)
end

function M.refresh(win)
  local source_win = resolve_source_win(win)
  local W = windows[source_win]
  if not W or not valid_win(source_win) then
    return
  end
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win)) ~= W.source_path then
    return M.handle_source_change(source_win)
  end
  M.render(source_win)
end

function M.set_family(win, family_name)
  win = resolve_source_win(win)
  local W = windows[win]
  if not W then
    vim.notify("aside: no aside panel open for this window", vim.log.levels.ERROR)
    return
  end
  if is_modified(W) then
    vim.notify("aside: unsaved changes; :w or :e! before switching family", vim.log.levels.ERROR)
    return
  end
  if W.in_insert then
    W.pending_family = family_name
    W.deferred_render = true
    return
  end
  state.ensure_family(family_name)
  if family_name ~= W.family and W.panels then
    switch_panel(W, family_name, W.source_path)
  end
  W.family = family_name
  M.render(win)
end

--- Sync scroll between a source window and its panel; `scrolled_win` is
--- the window whose view should win (defaults to the source).
function M.sync_scroll(source_win, scrolled_win)
  local W = windows[source_win]
  if W then
    sync(W, scrolled_win == W.win and "aside" or "source")
  end
end

--- Gutter glyphs of an aside row as a statusline string: outer column =
--- source anchor bracket, inner column = annotation box. (The window draws
--- the same glyphs as signs.)
---@param buf integer
---@param lnum? integer 1-indexed row (defaults to v:lnum)
function M.statuscolumn_for_buf(buf, lnum)
  local W
  for _, data in pairs(windows) do
    if data.buf == buf then W = data break end
  end
  lnum = lnum or vim.v.lnum
  local row = W and ((W.rows and W.rows[lnum]) or (W.layout and W.layout.rows[lnum]))
  if not row then
    return "  "
  end
  return "%#AsideBorder#" .. (ANCHOR_GLYPH[row.anchor_position] or " ") .. (BOX_GLYPH[row.box_position] or " ")
end

--- Re-render every panel showing `buf`'s file (deferred while edited).
function M.refresh_if_visible(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  for source_win, W in pairs(windows) do
    if W.source_path == path then
      M.render(source_win)
    end
  end
end

--- Map a row of an aside buffer to its source file and line.
---@return string? path, integer? line
function M.map_to_source(buf, lnum)
  local _, W = owner_of(buf)
  local row = W and W.rows and W.rows[lnum]
  if W then
    return W.source_path, row and row.source_line or lnum
  end
end

function M.get_aside_data(source_win)
  return windows[resolve_source_win(source_win)]
end

return M
