-- Regression tests for the aside panel: scroll alignment on long documents,
-- save/edit round-trips, and live realignment while editing.
--
-- Every test drives a real source + aside split in a child Neovim with real
-- keystrokes. Alignment is asserted on SCREEN rows (vim.fn.screenpos), so a
-- test only passes when what the user sees is actually lined up.
--
-- Run:
--   nvim --headless -u test/init_minimal.lua \
--     -c "lua require('mini.test').run_file('test/aside_panel_spec.lua')"

local MiniTest = require("mini.test")
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

-- Helpers installed into the child as _G.H.
local CHILD_HELPERS = [[
  _G.H = {}
  _G.prompts = {}
  -- Never block on the deletion prompt; record it and answer "cancel".
  vim.ui.select = function(_, opts, cb)
    table.insert(_G.prompts, opts.prompt)
    cb("Cancel save")
  end

  -- 400-line source file; line 120 is long enough to wrap.
  function H.make_file(n)
    local lines = {}
    for i = 1, (n or 400) do
      lines[i] = (i == 120) and ("local long_" .. i .. " = '" .. string.rep("a", 300) .. "'")
        or ("local line_" .. i .. " = " .. i)
    end
    local path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile(lines, path)
    vim.cmd("edit " .. path)
    H.path = path
    H.src = vim.api.nvim_get_current_win()
    H.src_buf = vim.api.nvim_get_current_buf()
    require("aside").ensure_family("f"):configure({ display = "hidden" })
    return path
  end

  function H.add(s, e, title, contents)
    return require("aside").add_annotation({
      family = "f", file = H.path, start_line = s, end_line = e,
      title = title, contents = contents,
    })
  end

  function H.open()
    require("aside").open_aside({ family = "f", win = H.src })
    H.d = require("aside.display.aside").get_aside_data(H.src)
    H.win, H.buf = H.d.win, H.d.buf
  end

  function H.srow(win, lnum)
    return vim.fn.screenpos(win, lnum, 1).row
  end

  -- Source lines whose FIRST aside row is on a different screen row than the
  -- source line itself (only checks pairs where both are on screen).
  function H.misaligned()
    vim.cmd("redraw")
    local bad, seen = {}, {}
    for i, r in pairs(H.d.rows) do
      if not seen[r.source_line] and H.d.row_item[i] then
        seen[r.source_line] = true
        local s, a = H.srow(H.src, r.source_line), H.srow(H.win, i)
        if s > 0 and a > 0 and s ~= a then
          table.insert(bad, string.format("src %d at row %d, aside row at %d", r.source_line, s, a))
        end
      end
    end
    return bad
  end

  -- Padding extmarks in any aside_source_padding_<win> namespace.
  function H.padding(buf)
    local n = 0
    for name, ns in pairs(vim.api.nvim_get_namespaces()) do
      if name:find("^aside_source_padding") then
        n = n + #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
      end
    end
    return n
  end

  function H.aside_lnum(text)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(H.buf, 0, -1, false)) do
      if l:find(text, 1, true) then return i end
    end
  end

  function H.view(win)
    return vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end

  function H.ann(id)
    local a = require("aside").get_annotation(id)
    return a and { title = a.title, contents = a.contents, start_line = a.start_line }
  end

  function H.anns()
    local out = {}
    for _, a in ipairs(require("aside").get_annotations_by_file(H.path)) do
      table.insert(out, { title = a.title, contents = a.contents, start_line = a.start_line })
    end
    return out
  end
]]

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
      child.lua("require('aside').setup({ persistence = { enabled = false }, data_dir = vim.fn.tempname() })")
      child.o.lines = 40
      child.o.columns = 140
      child.lua(CHILD_HELPERS)
    end,
    post_once = child.stop,
  },
})

-- Let the child sit idle in its main loop so WinScrolled / TextChanged /
-- scheduled callbacks / debounced tracking (100ms) fire exactly as they do
-- for a real user. (vim.wait inside an RPC call does not run normal_check,
-- so WinScrolled would never fire.)
local function settle(ms)
  vim.uv.sleep(ms or 250)
  child.cmd("redraw")
  vim.uv.sleep(50)
end

local function misaligned()
  return child.lua_get("H.misaligned()")
end

-- Scroll `keys` one keystroke at a time; return the first misalignment seen.
local function scroll_and_check(keys, n)
  for step = 1, n do
    child.type_keys(keys)
    settle(120)
    local bad = misaligned()
    if #bad > 0 then
      return { step = step, src = child.lua_get("H.view(H.src)"), aside = child.lua_get("H.view(H.win)"), bad = bad }
    end
  end
  return nil
end

-- ============================================================================
-- Scroll alignment on a long document
-- ============================================================================

T["scroll"] = MiniTest.new_set()

T["scroll"]["source showing a padding row at the top (topfill) keeps viewport aligned"] = function()
  -- Range annotation 10-12 gets a closer row => one virt_line under line 12.
  -- In the TUI, <C-e> from topline 12 lands on {topline=13, topfill=1}: the
  -- padding row is the first screen row. (Headless <C-e> skips the filler,
  -- so set that exact view and run the sync the WinScrolled handler runs.)
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  eq(misaligned(), {})
  child.lua([[
    vim.fn.winrestview({ lnum = 13, topline = 13, topfill = 1 })
    require("aside.display.aside").sync_scroll(H.src, H.src)
  ]])
  eq(child.lua_get("H.view(H.src).topfill"), 1)
  eq(misaligned(), {})
end

T["scroll"]["<C-y> in source back up across a padding row keeps viewport aligned"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.type_keys("25Gzt")
  settle()
  eq(scroll_and_check("<C-y>", 20), nil)
end

T["scroll"]["<C-e> in aside across a padding row keeps viewport aligned"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.type_keys("<C-w>l")
  eq(scroll_and_check("<C-e>", 20), nil)
end

T["scroll"]["jumps around a long document stay aligned"] = function()
  child.lua([[
    H.make_file()
    H.add(10, 12, "Range", "body")
    H.add(40, 40, "Crowded A", "one\ntwo\nthree\nfour\nfive")
    H.add(41, 41, "Crowded B", "b1\nb2\nb3")
    H.add(200, 200, "Mid", "mid body")
    H.add(300, 305, "Tall", "t1\nt2\nt3\nt4\nt5\nt6\nt7\nt8\nt9")
    H.open()
  ]])
  local failures = {}
  for _, keys in ipairs({ "G", "gg", "200Gzz", "<C-d>", "<C-d>", "<C-u>", "300Gzt", "<C-f>", "<C-b>", "44Gzt" }) do
    child.type_keys(keys)
    settle(120)
    local bad = misaligned()
    if #bad > 0 then
      table.insert(failures, { keys = keys, src = child.lua_get("H.view(H.src).topline"), bad = bad[1] })
    end
  end
  eq(failures, {})
end

T["scroll"]["'scrolloff' does not offset the aside"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.add(200, 200, "Mid", "x"); H.open()]])
  child.o.scrolloff = 5
  child.type_keys("150Gzt")
  settle()
  eq(misaligned(), {})
end

T["scroll"]["'scrolloff' + <C-e> scrolls down, not up (no feedback ladder)"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.o.scrolloff = 5
  child.type_keys("150Gzt")
  settle()
  local before = child.lua_get("H.view(H.src).topline")
  child.type_keys("<C-e>", "<C-e>", "<C-e>")
  settle()
  eq(child.lua_get("H.view(H.src).topline"), before + 3)
  eq(misaligned(), {})
end

T["scroll"]["wrapped source line keeps rows below it aligned"] = function()
  -- Line 120 wraps onto several screen rows in the source window.
  child.lua([[H.make_file(); H.add(125, 125, "At 125", ""); H.open()]])
  child.type_keys("115Gzt")
  settle()
  child.lua("_G.title_lnum = H.aside_lnum('At 125')")
  eq(child.lua_get("H.srow(H.win, _G.title_lnum)"), child.lua_get("H.srow(H.src, 125)"))
end

T["scroll"]["re-render that adds rows above the viewport re-syncs scroll"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.type_keys("150Gzt")
  settle()
  eq(misaligned(), {})
  -- New multi-row annotation above the viewport => one more padding row.
  child.lua([[H.add(50, 50, "New", "a\nb\nc")]])
  settle()
  eq(misaligned(), {})
end

T["scroll"]["jumping in the aside keeps the aside cursor where the user put it"] = function()
  -- The scroll-sync cascade (aside -> source -> aside) runs `NGzt` in the
  -- aside, yanking the cursor to the window's top row.
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.type_keys("<C-w>l", "205G")
  settle()
  child.type_keys("j")
  settle()
  eq(child.lua_get("vim.api.nvim_win_get_cursor(H.win)[1]"), 206)
end

T["scroll"]["scrolling the aside does not move the source cursor while it stays visible"] = function()
  -- Nice-to-have: syncing should only move the cursor to keep it on screen.
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.type_keys("20G")
  child.type_keys("<C-w>l", "<C-e>", "<C-e>", "<C-e>")
  settle()
  eq(child.lua_get("vim.api.nvim_win_get_cursor(H.src)[1]"), 20)
end

-- ============================================================================
-- Save round-trips
-- ============================================================================

T["save"] = MiniTest.new_set()

T["save"]["no-op :w does not prompt to delete a single-row annotation on the last line"] = function()
  child.lua([[H.make_file(); H.add(400, 400, "Last line", ""); H.open()]])
  child.type_keys("<C-w>l", ":w<CR>")
  settle()
  eq(child.lua_get("_G.prompts"), {})
end

T["save"]["no-op :w leaves a spilled-above annotation unchanged"] = function()
  -- B's anchor blocks A from spilling below, so A spills above its anchor.
  child.lua([[
    H.make_file()
    _G.a = H.add(40, 40, "Crowded A", "one\ntwo\nthree\nfour\nfive")
    H.add(41, 41, "Crowded B", "b1\nb2\nb3")
    H.open()
  ]])
  child.type_keys("<C-w>l", ":w<CR>")
  settle()
  child.type_keys(":w<CR>")
  settle()
  eq(child.lua_get("H.ann(_G.a)"), { title = "Crowded A", contents = "one\ntwo\nthree\nfour\nfive", start_line = 40 })
end

T["save"]["spilled-above annotation reads title first, then contents in order"] = function()
  child.lua([[
    H.make_file()
    H.add(40, 40, "Crowded A", "one\ntwo\nthree")
    H.add(41, 41, "Crowded B", "b1\nb2\nb3")
    H.open()
  ]])
  local title = child.lua_get("H.aside_lnum('Crowded A')")
  local one = child.lua_get("H.aside_lnum('one')")
  eq(title < one, true, "title at aside row " .. title .. " but first content line at row " .. one)
end

T["save"]["text typed on an empty row inside an annotation box is saved"] = function()
  -- Anchor 10-12, two rows of text => row for line 12 is an empty in-box row.
  child.lua([[H.make_file(); _G.a = H.add(10, 12, "Range", "body"); H.open()]])
  child.type_keys("<C-w>l", "12G", "ityped<Esc>", ":w<CR>")
  settle()
  eq(child.lua_get("H.ann(_G.a).contents"), "body\ntyped")
end

T["save"]["deleting the title row clears the title instead of promoting the body"] = function()
  child.lua([[H.make_file(); _G.a = H.add(200, 200, "Mid", "mid body"); H.open()]])
  child.type_keys("<C-w>l")
  -- Place the cursor twice: the first jump scrolls and the sync cascade moves
  -- the cursor (see "jumping in the aside..." above); the second is in view.
  child.lua("vim.api.nvim_win_set_cursor(0, { H.aside_lnum('Mid'), 0 })")
  settle()
  child.lua("vim.api.nvim_win_set_cursor(0, { H.aside_lnum('Mid'), 0 })")
  child.type_keys("dd", ":w<CR>")
  settle()
  eq(child.lua_get("H.ann(_G.a)"), { title = "", contents = "mid body", start_line = 200 })
end

-- ============================================================================
-- Unsaved edits must survive re-renders
-- ============================================================================

T["unsaved edits"] = MiniTest.new_set()

T["unsaved edits"]["survive an edit in the source buffer"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); H.open()]])
  child.type_keys("<C-w>l", ":%s/Title/EDITED/<CR>", "<C-w>h", "30G", "Ax<Esc>")
  settle(400)
  eq(child.lua_get("H.aside_lnum('EDITED') ~= nil"), true)
  eq(child.lua_get("vim.bo[H.buf].modified"), true)
end

T["unsaved edits"]["inserting a source line above keeps the annotation next to its code"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.type_keys("<C-w>l", ":%s/Range/EDITED/<CR>", "<C-w>h", "5G", "Oinserted<Esc>")
  settle(400)
  eq(child.lua_get("vim.bo[H.buf].modified"), true)
  -- The annotated code ("local line_10") is now buffer line 11.
  eq(child.lua_get("H.srow(H.win, H.aside_lnum('EDITED'))"), child.lua_get("H.srow(H.src, 11)"))
end

T["unsaved edits"]["deleting source lines above keeps the annotation next to its code"] = function()
  child.lua([[H.make_file(); H.add(30, 30, "At 30", "x"); H.open()]])
  child.type_keys("<C-w>l", ":%s/At 30/EDITED/<CR>", "<C-w>h", "5G", "3dd")
  settle(400)
  eq(child.lua_get("H.srow(H.win, H.aside_lnum('EDITED'))"), child.lua_get("H.srow(H.src, 27)"))
end

T["unsaved edits"]["survive an annotation update through the API"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); _G.other = H.add(50, 50, "Other", "x"); H.open()]])
  child.type_keys("<C-w>l", ":%s/Title/EDITED/<CR>")
  child.lua([[require("aside").update_annotation(_G.other, { contents = "changed" })]])
  settle()
  eq(child.lua_get("H.aside_lnum('EDITED') ~= nil"), true)
end

-- ============================================================================
-- Live realignment while editing the aside buffer
-- ============================================================================

T["live realign"] = MiniTest.new_set()

local function setup_two_annotations()
  child.lua([[
    H.make_file()
    H.add(10, 10, "First", "f1\nf2")
    H.add(20, 20, "Next", "n1")
    H.open()
  ]])
end

T["live realign"]["adding a content line keeps later annotations aligned"] = function()
  setup_two_annotations()
  child.type_keys("<C-w>l")
  child.lua("vim.api.nvim_win_set_cursor(0, { H.aside_lnum('f1'), 0 })")
  child.type_keys("onew line<Esc>")
  settle()
  eq(child.lua_get("H.srow(H.win, H.aside_lnum('Next'))"), child.lua_get("H.srow(H.src, 20)"))
end

T["live realign"]["deleting a content line keeps later annotations aligned"] = function()
  setup_two_annotations()
  child.type_keys("<C-w>l")
  child.lua("vim.api.nvim_win_set_cursor(0, { H.aside_lnum('f2'), 0 })")
  child.type_keys("dd")
  settle()
  eq(child.lua_get("H.srow(H.win, H.aside_lnum('Next'))"), child.lua_get("H.srow(H.src, 20)"))
end

T["live realign"]["box glyphs follow the text after adding a line"] = function()
  setup_two_annotations()
  child.type_keys("<C-w>l")
  child.lua("vim.api.nvim_win_set_cursor(0, { H.aside_lnum('f1'), 0 })")
  child.type_keys("onew line<Esc>")
  settle()
  child.lua([[
    local d = require("aside.display.aside")
    local glyphs = function(l) return (d.statuscolumn_for_buf(H.buf, l):gsub("%%#[^#]*#", "")) end
    _G.f2_glyph = glyphs(H.aside_lnum("f2"))
  ]])
  -- f2 is still a middle row of the box; the bottom corner belongs to the closer.
  eq(child.lua_get("_G.f2_glyph"), " \xe2\x94\x82") -- " │"
end

T["live realign"]["deleting the first row of a source line's block keeps the rest next to that line"] = function()
  -- X, Y, Z on consecutive lines: all three rows of Y ("● Y", y1, y2) sit in
  -- the block of line 90. Deleting Y's title row must not move y1/y2 up to
  -- line 89.
  child.lua([[H.make_file(); H.add(89, 89, "X", ""); H.add(90, 90, "Y", "y1\ny2"); H.add(91, 91, "Z", ""); H.open()]])
  child.type_keys("<C-w>l")
  child.lua("vim.api.nvim_win_set_cursor(0, { H.aside_lnum('Y'), 0 })")
  child.type_keys("dd")
  settle()
  eq(child.lua_get("H.srow(H.win, H.aside_lnum('y1'))"), child.lua_get("H.srow(H.src, 90)"))
end

T["live realign"]["type-to-create after an inserted line anchors to the visually adjacent source line"] = function()
  setup_two_annotations()
  child.type_keys("<C-w>l")
  child.lua("vim.api.nvim_win_set_cursor(0, { H.aside_lnum('f1'), 0 })")
  child.type_keys("onew line<Esc>")
  settle()
  child.lua([[
    -- Find the aside row the user sees next to source line 30 and type there.
    for l = 1, vim.api.nvim_buf_line_count(H.buf) do
      if H.srow(H.win, l) == H.srow(H.src, 30) then _G.target = l break end
    end
    vim.api.nvim_win_set_cursor(H.win, { _G.target, 0 })
  ]])
  child.type_keys("icreated<Esc>", ":w<CR>")
  settle()
  local created
  for _, a in ipairs(child.lua_get("H.anns()")) do
    if a.contents == "created" then created = a end
  end
  eq(created and created.start_line, 30)
end

-- ============================================================================
-- Source buffer hygiene
-- ============================================================================

T["source"] = MiniTest.new_set()

T["source"]["switching the source file clears padding from the previous buffer"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.lua([[
    _G.old_buf = H.src_buf
    _G.before = H.padding(_G.old_buf)
    vim.cmd("edit " .. vim.fn.tempname() .. ".lua")
  ]])
  settle()
  child.lua("_G.after = H.padding(_G.old_buf)")
  eq(child.lua_get("_G.before") > 0, true)
  eq(child.lua_get("_G.after"), 0)
  eq(child.lua_get("vim.api.nvim_win_is_valid(H.win)"), true)
end

T["source"]["closing the aside window with :q clears source padding"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.open()]])
  child.type_keys("<C-w>l", ":q<CR>")
  settle()
  child.lua("_G.n = H.padding(H.src_buf)")
  eq(child.lua_get("_G.n"), 0)
end

T["source"]["editing a source line keeps a scrolled viewport aligned"] = function()
  child.lua([[H.make_file(); H.add(10, 12, "Range", "body"); H.add(200, 200, "Mid", "x"); H.open()]])
  child.type_keys("190Gzt", "195G", "Ax<Esc>")
  settle(400)
  eq(misaligned(), {})
end

T["source"]["inserting source lines above an annotation keeps it next to its code"] = function()
  child.lua([[H.make_file(); H.add(30, 30, "At 30", "x"); H.open()]])
  child.type_keys("5G", "oinserted<Esc>")
  settle(400)
  -- The annotated code ("local line_30") is now buffer line 31.
  eq(child.lua_get("H.srow(H.win, H.aside_lnum('At 30'))"), child.lua_get("H.srow(H.src, 31)"))
end

T["source"]["closed fold in the source keeps rows below it aligned"] = function()
  child.lua([[H.make_file(); H.add(40, 40, "At 40", ""); H.open()]])
  child.type_keys("20G", "zf10j")
  settle()
  eq(child.lua_get("vim.fn.foldclosed(20)"), 20)
  eq(child.lua_get("H.srow(H.win, H.aside_lnum('At 40'))"), child.lua_get("H.srow(H.src, 40)"))
end

-- ============================================================================
-- Layout edge cases
-- ============================================================================

T["layout"] = MiniTest.new_set()

T["layout"]["two annotations on the same line both render"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "First", "a"); H.add(10, 10, "Second", "b"); H.open()]])
  eq(child.lua_get("{ H.aside_lnum('First') ~= nil, H.aside_lnum('Second') ~= nil }"), { true, true })
end

T["layout"]["annotation nested inside a larger range both render"] = function()
  child.lua([[H.make_file(); H.add(5, 15, "Outer", "o"); H.add(10, 10, "Inner", "i"); H.open()]])
  eq(child.lua_get("{ H.aside_lnum('Outer') ~= nil, H.aside_lnum('Inner') ~= nil }"), { true, true })
end

T["layout"]["annotation past the end of the file still shows its title"] = function()
  -- e.g. the file was shortened outside Neovim and relocation failed.
  child.lua([[H.make_file(20); H.add(50, 50, "Orphan", "body"); H.open()]])
  eq(child.lua_get("H.aside_lnum('Orphan') ~= nil"), true)
end

T["layout"]["long title is wrapped, not clipped"] = function()
  child.lua([[H.make_file(); H.add(10, 10, string.rep("word ", 20), ""); H.open()]])
  child.lua([[
    local width = vim.api.nvim_win_get_width(H.win) - 2
    _G.too_wide = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(H.buf, 0, -1, false)) do
      if vim.fn.strdisplaywidth(l) > width then table.insert(_G.too_wide, i) end
    end
  ]])
  eq(child.lua_get("_G.too_wide"), {})
end

T["layout"]["multibyte content wraps on character boundaries within the panel width"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "T", string.rep("é", 60) .. " " .. string.rep("日本", 20)); H.open()]])
  child.lua([[
    local width = vim.api.nvim_win_get_width(H.win) - 2
    _G.bad = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(H.buf, 0, -1, false)) do
      -- strtrans renders a split UTF-8 sequence as "<c3>".
      if vim.fn.strtrans(l) ~= l or vim.fn.strdisplaywidth(l) > width then table.insert(_G.bad, i) end
    end
  ]])
  eq(child.lua_get("_G.bad"), {})
end

T["layout"]["resizing the aside window rewraps content"] = function()
  local long = string.rep("word ", 20)
  child.lua(string.format([[H.make_file(); H.add(10, 10, "T", %q); H.open()]], long))
  child.lua("vim.api.nvim_win_set_width(H.win, 25)")
  settle()
  child.lua([[
    local width = vim.api.nvim_win_get_width(H.win) - 2
    _G.too_wide = 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(H.buf, 0, -1, false)) do
      if vim.fn.strdisplaywidth(l) > width then _G.too_wide = _G.too_wide + 1 end
    end
  ]])
  eq(child.lua_get("_G.too_wide"), 0)
end

-- ============================================================================
-- Save / edit edge cases
-- ============================================================================

T["save edge"] = MiniTest.new_set()

T["save edge"]["no-op :w keeps wrapped content as one logical line"] = function()
  local long = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron"
  child.lua(string.format([[H.make_file(); _G.a = H.add(10, 10, "T", %q); H.open()]], long))
  child.type_keys("<C-w>l", ":w<CR>")
  settle()
  eq(child.lua_get("H.ann(_G.a).contents"), long)
end

T["save edge"]["editing one wrapped row keeps the spaces between rows"] = function()
  local long = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron"
  child.lua(string.format([[H.make_file(); _G.a = H.add(10, 10, "T", %q); H.open()]], long))
  child.type_keys("<C-w>l")
  child.lua("vim.api.nvim_win_set_cursor(0, { H.aside_lnum('alpha'), 0 })")
  child.type_keys("cwALPHA<Esc>", ":w<CR>")
  settle()
  eq(child.lua_get("H.ann(_G.a).contents"), (long:gsub("^alpha", "ALPHA")))
end

T["save edge"]["text typed on an annotation with no title or contents is saved"] = function()
  child.lua([[H.make_file(); _G.a = H.add(10, 10, "", ""); H.open()]])
  child.type_keys("<C-w>l", "10G", "itext<Esc>", ":w<CR>")
  settle()
  eq(child.lua_get("H.ann(_G.a).contents"), "text")
  eq(#child.lua_get("H.anns()"), 1)
end

T["save edge"]["joining the title and body rows with J does not duplicate text"] = function()
  child.lua([[H.make_file(); _G.a = H.add(10, 10, "Title", "body"); H.open()]])
  child.type_keys("<C-w>l", "10G", "J", ":w<CR>")
  settle()
  local a = child.lua_get("H.ann(_G.a)")
  eq(select(2, (a.title .. "\n" .. a.contents):gsub("body", "")), 1)
end

T["save edge"]["cancelling the delete prompt does not commit the rest of the save"] = function()
  child.lua([[
    H.make_file()
    _G.a = H.add(10, 10, "Keep", "")
    _G.b = H.add(20, 20, "Doomed", "")
    H.open()
  ]])
  child.type_keys("<C-w>l", ":%s/Keep/Edited/<CR>", "20Gdd", ":w<CR>")
  settle()
  -- _G.prompts answers "Cancel save".
  eq(#child.lua_get("_G.prompts"), 1)
  eq(child.lua_get("H.ann(_G.a).title"), "Keep")
  eq(child.lua_get("H.ann(_G.b) ~= nil"), true)
end

T["save edge"]["deleting every text row of an annotation asks to delete it"] = function()
  -- Anchor 5-7 leaves an empty spacer row after the text rows.
  child.lua([[H.make_file(); _G.a = H.add(5, 7, "Gone", "body"); H.open()]])
  child.type_keys("<C-w>l", "5G", "2dd", ":w<CR>")
  settle()
  eq(child.lua_get("_G.prompts"), { 'Delete annotation "Gone"?' })
end

T["save edge"][":w after an API update to an annotation the user did not touch keeps the API update"] = function()
  -- The aside has an unsaved edit, so the API update's re-render is deferred
  -- and the panel still shows the old text of "Other". Saving must not write
  -- that stale text back over the update.
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); _G.other = H.add(50, 50, "Other", "x"); H.open()]])
  child.type_keys("<C-w>l", ":%s/Title/EDITED/<CR>")
  child.lua([[require("aside").update_annotation(_G.other, { contents = "changed" })]])
  settle()
  child.type_keys(":w<CR>")
  settle()
  eq(child.lua_get("H.ann(_G.other).contents"), "changed")
end

T["save edge"]["type-to-create while a re-render is deferred anchors to the code it was typed next to"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); H.open()]])
  child.type_keys("<C-w>l")
  child.lua([[
    for l = 1, vim.api.nvim_buf_line_count(H.buf) do
      if H.srow(H.win, l) == H.srow(H.src, 30) then _G.target = l break end
    end
    vim.api.nvim_win_set_cursor(H.win, { _G.target, 0 })
  ]])
  child.type_keys("icreated<Esc>")
  -- Insert a source line above: the code typed next to ("local line_30")
  -- moves to line 31.
  child.type_keys("<C-w>h", "5G", "oinserted<Esc>")
  settle(400)
  child.type_keys("<C-w>l", ":w<CR>")
  settle()
  local created
  for _, a in ipairs(child.lua_get("H.anns()")) do
    if a.contents == "created" then created = a end
  end
  eq(created and created.start_line, 31)
end

T["save edge"]["undo right after opening does not blank the panel"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); H.open()]])
  child.type_keys("<C-w>l", "u")
  settle()
  eq(child.lua_get("H.aside_lnum('Title') ~= nil"), true)
end

T["save edge"][":e! discards unsaved edits and restores the panel"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); H.open()]])
  child.type_keys("<C-w>l", ":%s/Title/EDITED/<CR>", ":e!<CR>")
  settle()
  eq(child.lua_get("{ H.aside_lnum('Title') ~= nil, H.aside_lnum('EDITED') == nil, vim.bo[H.buf].modified }"),
    { true, true, false })
end

T["save edge"]["text typed in insert mode survives a deferred re-render on <Esc>"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); _G.other = H.add(50, 50, "Other", "x"); H.open()]])
  child.type_keys("<C-w>l", "30G", "ityped")
  child.lua([[require("aside").update_annotation(_G.other, { contents = "changed" })]])
  settle()
  child.type_keys("<Esc>")
  settle()
  eq(child.lua_get("H.aside_lnum('typed') ~= nil"), true)
end

T["save edge"]["switching the source file with unsaved aside edits keeps them"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); H.open()]])
  child.type_keys("<C-w>l", ":%s/Title/EDITED/<CR>", "<C-w>h")
  child.lua([[vim.cmd("edit " .. vim.fn.tempname() .. ".lua")]])
  settle()
  -- Either refused (still showing the edit) or the edit is preserved somewhere.
  child.lua([[vim.cmd("buffer " .. H.src_buf)]])
  settle()
  eq(child.lua_get("H.aside_lnum('EDITED') ~= nil"), true)
end

-- ============================================================================
-- Panel lifecycle
-- ============================================================================

T["lifecycle"] = MiniTest.new_set()

T["lifecycle"]["reopening after :q gives a writable panel"] = function()
  child.lua([[H.make_file(); _G.a = H.add(10, 10, "Title", "body"); H.open()]])
  child.type_keys("<C-w>l", ":q<CR>")
  settle()
  child.lua("H.open()")
  child.type_keys("<C-w>l", ":%s/Title/Again/<CR>", ":w<CR>")
  settle()
  eq(child.lua_get("H.ann(_G.a).title"), "Again")
end

T["lifecycle"]["open_aside from inside the aside window does not nest a panel"] = function()
  child.lua([[H.make_file(); H.add(10, 10, "Title", "body"); H.open()]])
  child.type_keys("<C-w>l")
  child.lua([[require("aside").open_aside({ family = "f", win = 0 })]])
  settle()
  eq(#child.lua_get("vim.api.nvim_tabpage_list_wins(0)"), 2)
end

T["lifecycle"][":AsideAdd from the aside window does not annotate the aside buffer"] = function()
  child.lua([[H.make_file(); H.open()]])
  child.type_keys("<C-w>l", ":AsideAdd f Oops<CR>")
  settle()
  child.lua([[
    _G.files = {}
    for _, a in ipairs(require("aside").get_annotations_by_family("f")) do table.insert(_G.files, a.file) end
  ]])
  for _, f in ipairs(child.lua_get("_G.files")) do
    eq(f:find("^aside://") == nil, true, "annotation created on " .. f)
  end
end

T["lifecycle"]["two windows on the same file with different panel widths both stay aligned"] = function()
  local long = string.rep("word ", 30)
  child.lua(string.format([[
    H.make_file(); H.add(10, 10, "T", %q); H.add(20, 20, "After", "")
    H.open()
    _G.first = { src = H.src, win = H.win, d = H.d }
    vim.cmd("tabnew " .. H.path)
    H.src = vim.api.nvim_get_current_win()
    H.open()
    vim.api.nvim_win_set_width(H.win, 25)
    require("aside.display.aside").render(H.src)
  ]], long))
  settle()
  eq(misaligned(), {})
  child.lua([[vim.cmd("tabprevious"); H.src, H.win, H.d = _G.first.src, _G.first.win, _G.first.d; H.buf = H.d.buf]])
  settle()
  eq(misaligned(), {})
end

return T
