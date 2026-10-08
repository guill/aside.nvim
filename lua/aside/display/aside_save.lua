--- BufWriteCmd save parser for the aside buffer.
---
--- Reads the live rows (see aside_extmarks.read), rebuilds each annotation's
--- title and contents, diffs against stored annotations and applies the
--- result. It never touches the source buffer and never re-renders.

local M = {}

local extmarks = require("aside.display.aside_extmarks")
local annotations_mod = require("aside.annotations")
local state = require("aside.state")
local config = require("aside.config")

-- "<icon> " prefix the renderer puts on the first title row.
local function title_prefix(family_name)
  local family = family_name and state.get_family(family_name)
  local icon = (family and family:get_config().gutter_icon) or config.get_value("default_gutter_icon", "\226\151\143")
  return icon .. " "
end

-- Join rows into logical lines: a wrap continuation re-inserts the
-- whitespace dropped at the wrap point, anything else starts a new line.
-- Empty rows that were not content (spill / user-inserted) are dropped.
local function join_rows(rows)
  local pieces = {}
  for _, e in ipairs(rows) do
    if e.sep and #pieces > 0 then
      pieces[#pieces] = pieces[#pieces] .. e.sep .. e.text
    elseif e.text ~= "" or e.row_kind == "content" then
      table.insert(pieces, e.text)
    end
  end
  return pieces
end

---@param buf integer
---@param layout table? Layout of the last render (fallback block info)
---@param family_name string?
---@return {updates: table<string, table>, deletions: string[], type_creates: {source_line: integer, contents: string}[]}
function M.parse(buf, layout, family_name)
  local result = { updates = {}, deletions = {}, type_creates = {} }
  local ok, valid = pcall(vim.api.nvim_buf_is_valid, buf)
  if not ok or not valid then
    return result
  end

  local entries = vim.tbl_filter(function(e) return e.lnum ~= nil end, extmarks.read(buf, layout))
  local by_ann = {}
  for _, e in ipairs(entries) do
    if e.ann_id then
      by_ann[e.ann_id] = by_ann[e.ann_id] or {}
      table.insert(by_ann[e.ann_id], e)
    end
  end

  -- Text of each annotation as last rendered. An annotation whose rows still
  -- match it was not edited, and saving must not write its (possibly stale)
  -- text over a newer stored version.
  local rendered, live = {}, {}
  for _, r in ipairs((layout and layout.rows) or {}) do
    if r.ann_id and r.row_kind ~= "closer" then
      rendered[r.ann_id] = (rendered[r.ann_id] or "") .. "\n" .. (r.text or "")
    end
  end
  for ann_id, rows in pairs(by_ann) do
    for _, e in ipairs(rows) do
      live[ann_id] = (live[ann_id] or "") .. "\n" .. e.text
    end
  end

  local prefix = title_prefix(family_name)
  for _, ann_id in ipairs(extmarks.placed_ann_ids(buf)) do
    local stored = state.get_annotation(ann_id)
    local rows = by_ann[ann_id]
    if rendered[ann_id] and live[ann_id] == rendered[ann_id] then
      stored = nil
    end
    if stored and rows and (stored.title ~= "" or stored.contents ~= "") then
      -- Every title/content row removed and only blank rows left: the user
      -- deleted the annotation's text, which is a deletion.
      local remaining = vim.tbl_filter(function(e)
        return e.row_kind == "title" or e.row_kind == "content" or vim.trim(e.text) ~= ""
      end, rows)
      if #remaining == 0 then rows = nil end
    end
    if stored and not rows then
      table.insert(result.deletions, ann_id)
    elseif stored then
      local title_rows, body_rows = {}, {}
      for _, e in ipairs(rows) do
        table.insert(e.row_kind == "title" and title_rows or body_rows, e)
      end
      local title = table.concat(join_rows(title_rows), " ")
      if vim.startswith(title, prefix) then
        title = title:sub(#prefix + 1)
      end
      local contents = table.concat(join_rows(body_rows), "\n")
      local changes = {}
      if title ~= (stored.title or "") then changes.title = title end
      if contents ~= (stored.contents or "") then changes.contents = contents end
      if next(changes) then
        result.updates[ann_id] = changes
      end
    end
  end

  -- Type-to-create: each run of non-empty rows outside any annotation
  -- becomes a new annotation on the source line of the run's first row.
  local run
  for _, e in ipairs(entries) do
    local text = vim.trim(e.text)
    if not e.ann_id and text ~= "" then
      if not run then
        run = { source_line = e.source_line, lines = {} }
        table.insert(result.type_creates, run)
      end
      table.insert(run.lines, text)
    else
      run = nil
    end
  end
  for _, tc in ipairs(result.type_creates) do
    tc.contents = table.concat(tc.lines, "\n")
    tc.lines = nil
  end

  return result
end

--- Apply a parse result to the annotation store.
---@return {ann_id: string, action: string}[]
function M.commit(parse_result, buf, source_path, family_name)
  local actions = {}
  for ann_id, changes in pairs(parse_result.updates or {}) do
    if annotations_mod.update(ann_id, changes) then
      table.insert(actions, { ann_id = ann_id, action = "update" })
    end
  end
  for _, ann_id in ipairs(parse_result.deletions or {}) do
    annotations_mod.delete(ann_id)
    table.insert(actions, { ann_id = ann_id, action = "delete" })
  end
  for _, tc in ipairs(parse_result.type_creates or {}) do
    if family_name and source_path then
      local id = annotations_mod.add({
        family = family_name,
        file = source_path,
        start_line = tc.source_line,
        end_line = tc.source_line,
        title = "",
        contents = tc.contents,
      })
      if id then
        table.insert(actions, { ann_id = id, action = "create" })
      end
    end
  end
  return actions
end

-- Ask about each deletion in turn; any answer but "Delete annotation"
-- cancels the whole save. Works with synchronous and async vim.ui.select.
local function confirm_deletions(ids, i, done)
  if i > #ids then
    return done(true)
  end
  local ann = state.get_annotation(ids[i])
  local label = (ann and ann.title ~= "") and ann.title or "<no title>"
  vim.ui.select({ "Delete annotation", "Cancel save" }, { prompt = 'Delete annotation "' .. label .. '"?' },
    function(choice)
      if choice == "Delete annotation" then
        confirm_deletions(ids, i + 1, done)
      else
        done(false)
      end
    end)
end

--- BufWriteCmd entry point. Calls `on_saved(parse_result)` once the changes
--- are committed; a cancelled deletion prompt commits nothing.
function M.handle_save(buf, source_path, family_name, layout, on_saved)
  local parse_result = M.parse(buf, layout, family_name)
  confirm_deletions(parse_result.deletions, 1, function(confirmed)
    if not confirmed then
      vim.notify("aside: save cancelled; nothing was written", vim.log.levels.WARN)
      return
    end
    M.commit(parse_result, buf, source_path, family_name)
    if on_saved then
      on_saved(parse_result)
    end
  end)
  return parse_result
end

return M
