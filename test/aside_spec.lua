local MiniTest = require("mini.test")
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
      child.lua("require('aside').setup({ persistence = { enabled = false } })")
    end,
    post_once = child.stop,
  },
})

T["setup()"] = MiniTest.new_set()

T["setup()"]["creates default config"] = function()
  local display = child.lua_get("require('aside.config').get().default_display")
  eq(display, "hover")

  local context_lines = child.lua_get("require('aside.config').get().context_lines")
  eq(context_lines, 3)
end

T["setup()"]["accepts custom config"] = function()
  child.lua("require('aside').setup({ default_display = 'below', context_lines = 5 })")

  local display = child.lua_get("require('aside.config').get().default_display")
  eq(display, "below")

  local context_lines = child.lua_get("require('aside.config').get().context_lines")
  eq(context_lines, 5)
end

T["families"] = MiniTest.new_set()

T["families"]["ensure_family creates new family"] = function()
  child.lua("require('aside').ensure_family('test_family')")
  local exists = child.lua_get("require('aside.state').family_exists('test_family')")
  eq(exists, true)
end

T["families"]["list_families returns all families"] = function()
  child.lua("require('aside').ensure_family('family_a')")
  child.lua("require('aside').ensure_family('family_b')")

  local families = child.lua_get("require('aside').list_families()")
  eq(vim.tbl_contains(families, "family_a"), true)
  eq(vim.tbl_contains(families, "family_b"), true)
end

T["families"]["family configuration"] = function()
  child.lua("require('aside').ensure_family('custom_family'):configure({ display = 'aside' })")

  local display = child.lua_get("require('aside.state').get_family('custom_family'):get_config().display")
  eq(display, "aside")
end

T["annotations"] = MiniTest.new_set()

T["annotations"]["add_annotation returns id"] = function()
  child.lua([[
    _G.test_id = require("aside").add_annotation({
      family = "test_family",
      file = "/tmp/test.lua",
      start_line = 10,
      end_line = 15,
      title = "Test Title",
      contents = "Test Contents",
    })
  ]])

  local id = child.lua_get("_G.test_id")
  eq(type(id), "string")
  eq(#id > 0, true)
end

T["annotations"]["get_annotation retrieves by id"] = function()
  child.lua([[
    _G.test_id = require("aside").add_annotation({
      family = "test_family",
      file = "/tmp/test.lua",
      start_line = 10,
      end_line = 15,
      title = "Test Title",
    })
  ]])

  local title = child.lua_get("require('aside').get_annotation(_G.test_id).title")
  eq(title, "Test Title")

  local start_line = child.lua_get("require('aside').get_annotation(_G.test_id).start_line")
  eq(start_line, 10)
end

T["annotations"]["get_by_file returns file annotations"] = function()
  child.lua([[
    require("aside").add_annotation({
      family = "test_family",
      file = "/tmp/file_a.lua",
      start_line = 1,
      end_line = 1,
      title = "Ann A",
    })
  ]])

  local count = child.lua_get("#require('aside').get_annotations_by_file('/tmp/file_a.lua')")
  eq(count, 1)
end

T["annotations"]["get_by_family returns family annotations"] = function()
  child.lua([[
    require("aside").add_annotation({
      family = "family_x",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
      title = "X1",
    })
  ]])

  local count = child.lua_get("#require('aside').get_annotations_by_family('family_x')")
  eq(count, 1)
end

T["annotations"]["update_annotation modifies annotation"] = function()
  child.lua([[
    _G.test_id = require("aside").add_annotation({
      family = "test_family",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
      title = "Original",
    })
  ]])

  child.lua("require('aside').update_annotation(_G.test_id, { title = 'Updated' })")

  local title = child.lua_get("require('aside').get_annotation(_G.test_id).title")
  eq(title, "Updated")
end

T["annotations"]["delete_annotation removes annotation"] = function()
  child.lua([[
    _G.test_id = require("aside").add_annotation({
      family = "test_family",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
      title = "To Delete",
    })
  ]])

  child.lua("require('aside').delete_annotation(_G.test_id)")

  local ann = child.lua_get("require('aside').get_annotation(_G.test_id)")
  eq(ann, vim.NIL)
end

T["state"] = MiniTest.new_set()

T["state"]["events are emitted"] = function()
  child.lua([[
    _G.events = {}
    require("aside.state").on("annotation_added", function(data)
      table.insert(_G.events, "added")
    end)
    require("aside.state").on("annotation_deleted", function(data)
      table.insert(_G.events, "deleted")
    end)
  ]])

  child.lua([[
    _G.test_id = require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
    })
  ]])
  child.lua("require('aside').delete_annotation(_G.test_id)")

  local events = child.lua_get("_G.events")
  eq(#events, 2)
  eq(events[1], "added")
  eq(events[2], "deleted")
end

T["state"]["event unsubscribe works"] = function()
  child.lua([[
    _G.count = 0
    _G.unsub = require("aside.state").on("annotation_added", function()
      _G.count = _G.count + 1
    end)
  ]])

  child.lua([[
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
    })
  ]])
  eq(child.lua_get("_G.count"), 1)

  child.lua("_G.unsub()")

  child.lua([[
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test2.lua",
      start_line = 1,
      end_line = 1,
    })
  ]])
  eq(child.lua_get("_G.count"), 1)
end

T["state"]["delete_family removes all annotations"] = function()
  child.lua([[ 
    require("aside").add_annotation({
      family = "to_delete",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
    })
    require("aside").add_annotation({
      family = "to_delete",
      file = "/tmp/test2.lua",
      start_line = 5,
      end_line = 10,
    })
  ]])

  local count_before = child.lua_get("#require('aside').get_annotations_by_family('to_delete')")
  eq(count_before, 2)

  child.lua("require('aside').delete_family('to_delete')")

  local count_after = child.lua_get("#require('aside').get_annotations_by_family('to_delete')")
  eq(count_after, 0)

  local exists = child.lua_get("require('aside').family_exists('to_delete')")
  eq(exists, false)
end

T["aside.set_family"] = MiniTest.new_set()

T["aside.set_family"]["refuses when buffer has unsaved edits"] = function()
  child.lua([[ 
    local d = require("aside.display.aside")
    d._test_set_data(999, {
      win = 999,
      buf = 999,
      family = "family_a",
      source_path = "/test/file.lua",
      layout = nil,
      in_insert = false,
      deferred_render = false,
      modified = true,
      augroup_name = "test_augroup",
    })
    d.set_family(999, "family_b")
    _G.result_family = d._test_get_data(999).family
  ]])

  local result = child.lua_get("_G.result_family")
  eq(result, "family_a")
end

T["aside.set_family"]["allows switch when buffer is clean"] = function()
  child.lua([[ 
    local d = require("aside.display.aside")
    d._test_set_data(998, {
      win = 998,
      buf = 998,
      family = "family_a",
      source_path = "/test/file.lua",
      layout = nil,
      in_insert = false,
      deferred_render = false,
      modified = false,
      augroup_name = "test_augroup2",
    })
    require("aside.state").ensure_family("family_b")
    d.set_family(998, "family_b")
    _G.result_family2 = d._test_get_data(998).family
  ]])

  local result = child.lua_get("_G.result_family2")
  eq(result, "family_b")
end

T["annotations"]["missing family returns nil"] = function()
  child.lua([[ 
    _G.result = require("aside").add_annotation({
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
    })
  ]])

  local result = child.lua_get("_G.result")
  eq(result, vim.NIL)
end

T["annotations"]["missing file returns nil"] = function()
  child.lua([[
    _G.result = require("aside").add_annotation({
      family = "test",
      start_line = 1,
      end_line = 1,
    })
  ]])

  local result = child.lua_get("_G.result")
  eq(result, vim.NIL)
end

T["annotations"]["invalid start_line returns nil"] = function()
  child.lua([[
    _G.result = require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = -5,
      end_line = 1,
    })
  ]])

  local result = child.lua_get("_G.result")
  eq(result, vim.NIL)
end

T["annotations"]["end_line < start_line auto-swaps"] = function()
  child.lua([[
    _G.test_id = require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 10,
      end_line = 5,
    })
  ]])

  local start_line = child.lua_get("require('aside').get_annotation(_G.test_id).start_line")
  local end_line = child.lua_get("require('aside').get_annotation(_G.test_id).end_line")
  eq(start_line, 5)
  eq(end_line, 10)
end

T["annotations"]["update nonexistent returns false"] = function()
  local result = child.lua_get("require('aside').update_annotation('nonexistent-id', { title = 'New' })")
  eq(result, false)
end

T["annotations"]["update ignores disallowed fields"] = function()
  child.lua([[
    _G.test_id = require("aside").add_annotation({
      family = "test",
      file = "/tmp/original.lua",
      start_line = 1,
      end_line = 5,
      title = "Original",
    })
  ]])

  child.lua([[
    require("aside").update_annotation(_G.test_id, {
      file = "/tmp/hacked.lua",
      start_line = 100,
      end_line = 200,
      title = "Updated",
    })
  ]])

  local file = child.lua_get("require('aside').get_annotation(_G.test_id).file")
  local start_line = child.lua_get("require('aside').get_annotation(_G.test_id).start_line")
  local title = child.lua_get("require('aside').get_annotation(_G.test_id).title")

  eq(file, "/tmp/original.lua")
  eq(start_line, 1)
  eq(title, "Updated")
end

T["annotations"]["delete nonexistent returns false"] = function()
  local result = child.lua_get("require('aside').delete_annotation('nonexistent-id')")
  eq(result, false)
end

T["annotations"]["get_by_metadata filters correctly"] = function()
  child.lua([[
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
      metadata = { pr_id = 123, author = "alice" },
    })
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 5,
      end_line = 5,
      metadata = { pr_id = 456, author = "bob" },
    })
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 10,
      end_line = 10,
      metadata = { pr_id = 123, author = "charlie" },
    })
  ]])

  local count = child.lua_get([[
    #require("aside").get_annotations_by_metadata(function(m)
      return m and m.pr_id == 123
    end)
  ]])
  eq(count, 2)
end

T["annotations"]["sorting by sort_key first"] = function()
  child.lua([[
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
      title = "C",
      sort_key = 3,
    })
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
      title = "A",
      sort_key = 1,
    })
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 1,
      title = "B",
      sort_key = 2,
    })
  ]])

  local titles = child.lua_get([[
    vim.tbl_map(function(a) return a.title end, require("aside").get_annotations_by_file("/tmp/test.lua"))
  ]])
  eq(titles, { "A", "B", "C" })
end

T["annotations"]["sorting by end_line when no sort_key"] = function()
  child.lua([[
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 20,
      title = "Third",
    })
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 5,
      title = "First",
    })
    require("aside").add_annotation({
      family = "test",
      file = "/tmp/test.lua",
      start_line = 1,
      end_line = 10,
      title = "Second",
    })
  ]])

  local titles = child.lua_get([[
    vim.tbl_map(function(a) return a.title end, require("aside").get_annotations_by_file("/tmp/test.lua"))
  ]])
  eq(titles, { "First", "Second", "Third" })
end

T["context"] = MiniTest.new_set()

T["context"]["read_file_lines returns nil for nonexistent file"] = function()
  local result = child.lua_get("require('aside.context').read_file_lines('/nonexistent/path/file.lua')")
  eq(result, vim.NIL)
end

T["context"]["capture returns nil for nonexistent file"] = function()
  local result = child.lua_get("require('aside.context').capture('/nonexistent/path/file.lua', 1, 5, 3)")
  eq(result, vim.NIL)
end

T["context"]["capture clamps lines to file bounds"] = function()
  child.lua([[
    local file = io.open("/tmp/test_context.lua", "w")
    file:write("line1\nline2\nline3\nline4\nline5\n")
    file:close()
  ]])

  child.lua([[
    _G.ctx = require("aside.context").capture("/tmp/test_context.lua", 10, 15, 2)
  ]])

  local marked = child.lua_get("_G.ctx.marked_content")
  eq(#marked, 1)
  eq(marked[1], "line5")
end

T["context"]["capture handles empty context_lines"] = function()
  child.lua([[
    local file = io.open("/tmp/test_ctx2.lua", "w")
    file:write("line1\nline2\nline3\nline4\nline5\n")
    file:close()
  ]])

  child.lua([[
    _G.ctx = require("aside.context").capture("/tmp/test_ctx2.lua", 3, 3, 0)
  ]])

  local before = child.lua_get("_G.ctx.context_before")
  local after = child.lua_get("_G.ctx.context_after")
  local marked = child.lua_get("_G.ctx.marked_content")

  eq(#before, 0)
  eq(#after, 0)
  eq(marked, { "line3" })
end

T["context"]["has_context returns false for nil annotation"] = function()
  local result = child.lua_get("require('aside.context').has_context(nil)")
  eq(result, false)
end

T["context"]["has_context returns false for empty marked_content"] = function()
  local result = child.lua_get("require('aside.context').has_context({ marked_content = {} })")
  eq(result, false)
end

T["context"]["has_context returns true for valid content"] = function()
  local result = child.lua_get("require('aside.context').has_context({ marked_content = { 'line1' } })")
  eq(result, true)
end

T["relocator"] = MiniTest.new_set()

T["relocator"]["returns unchanged for nonexistent file"] = function()
  child.lua([[
    _G.results = require("aside.relocator").relocate_annotations_for_file(
      "/nonexistent/file.lua",
      {{ id = "test", start_line = 1, end_line = 5 }}
    )
  ]])

  local status = child.lua_get("_G.results[1].status")
  eq(status, "unchanged")
end

T["relocator"]["returns unchanged for annotation without context"] = function()
  child.lua([[
    local file = io.open("/tmp/test_reloc.lua", "w")
    file:write("line1\nline2\nline3\n")
    file:close()
  ]])

  child.lua([[
    _G.results = require("aside.relocator").relocate_annotations_for_file(
      "/tmp/test_reloc.lua",
      {{ id = "test", start_line = 1, end_line = 1, marked_content = nil }}
    )
  ]])

  local status = child.lua_get("_G.results[1].status")
  eq(status, "unchanged")
end

T["relocator"]["exact match when full sequence found"] = function()
  child.lua([[
    local file = io.open("/tmp/test_exact.lua", "w")
    file:write("before1\nbefore2\nTARGET\nafter1\nafter2\n")
    file:close()
  ]])

  child.lua([[
    _G.results = require("aside.relocator").relocate_annotations_for_file(
      "/tmp/test_exact.lua",
      {{
        id = "test",
        start_line = 100,  -- Wrong position
        end_line = 100,
        marked_content = { "TARGET" },
        context_before = { "before1", "before2" },
        context_after = { "after1", "after2" },
      }}
    )
  ]])

  local status = child.lua_get("_G.results[1].status")
  local new_start = child.lua_get("_G.results[1].new_start")

  eq(status, "exact")
  eq(new_start, 3)
end

T["relocator"]["content_only match when context changed"] = function()
  child.lua([[
    local file = io.open("/tmp/test_content.lua", "w")
    file:write("changed_before\nUNIQUE_TARGET_LINE\nchanged_after\n")
    file:close()
  ]])

  child.lua([[
    _G.results = require("aside.relocator").relocate_annotations_for_file(
      "/tmp/test_content.lua",
      {{
        id = "test",
        start_line = 100,
        end_line = 100,
        marked_content = { "UNIQUE_TARGET_LINE" },
        context_before = { "old_before" },
        context_after = { "old_after" },
      }}
    )
  ]])

  local status = child.lua_get("_G.results[1].status")
  local new_start = child.lua_get("_G.results[1].new_start")

  eq(status, "content_only")
  eq(new_start, 2)
end

T["relocator"]["unchanged when multiple matches exist"] = function()
  child.lua([[
    local file = io.open("/tmp/test_multi.lua", "w")
    file:write("DUPLICATE\nother\nDUPLICATE\n")
    file:close()
  ]])

  child.lua([[
    _G.results = require("aside.relocator").relocate_annotations_for_file(
      "/tmp/test_multi.lua",
      {{
        id = "test",
        start_line = 1,
        end_line = 1,
        marked_content = { "DUPLICATE" },
        context_before = {},
        context_after = {},
      }}
    )
  ]])

  local status = child.lua_get("_G.results[1].status")
  eq(status, "unchanged")
end

T["relocator"]["relocates multiple annotations in batch"] = function()
  child.lua([[
    local file = io.open("/tmp/test_batch.lua", "w")
    file:write("header\nFIRST_UNIQUE\nmiddle\nSECOND_UNIQUE\nfooter\n")
    file:close()
  ]])

  child.lua([[
    _G.results = require("aside.relocator").relocate_all_annotations({
      {
        id = "ann1",
        file = "/tmp/test_batch.lua",
        start_line = 100,
        end_line = 100,
        marked_content = { "FIRST_UNIQUE" },
        context_before = { "header" },
        context_after = { "middle" },
      },
      {
        id = "ann2",
        file = "/tmp/test_batch.lua",
        start_line = 200,
        end_line = 200,
        marked_content = { "SECOND_UNIQUE" },
        context_before = { "middle" },
        context_after = { "footer" },
      },
    })
  ]])

  local count = child.lua_get("#_G.results")
  eq(count, 2)

  local r1 = child.lua_get("vim.tbl_filter(function(r) return r.annotation_id == 'ann1' end, _G.results)[1]")
  local r2 = child.lua_get("vim.tbl_filter(function(r) return r.annotation_id == 'ann2' end, _G.results)[1]")

  eq(r1.new_start, 2)
  eq(r2.new_start, 4)
end

T["tracking"] = MiniTest.new_set()

T["tracking"]["attach_extmark returns nil for unloaded buffer"] = function()
  local result = child.lua_get([[
    require("aside.tracking").attach_extmark({
      id = "test",
      file = "/nonexistent/buffer.lua",
      start_line = 1,
      end_line = 1,
    })
  ]])
  eq(result, vim.NIL)
end

T["tracking"]["extmarks track line movements"] = function()
  child.lua([[
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, "/tmp/track_test.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "line1",
      "line2",
      "line3",
      "line4",
      "line5",
    })
    _G.test_buf = buf
  ]])

  child.lua([[
    _G.test_id = require("aside").add_annotation({
      family = "track_test",
      file = "/tmp/track_test.lua",
      start_line = 3,
      end_line = 3,
      title = "Track me",
    })
  ]])

  child.lua([[
    vim.api.nvim_buf_set_lines(_G.test_buf, 0, 0, false, { "new1", "new2" })
  ]])

  child.lua("require('aside.tracking').sync_extmarks(_G.test_buf)")

  local new_start = child.lua_get("require('aside').get_annotation(_G.test_id).start_line")
  eq(new_start, 5)
end

T["persistence"] = MiniTest.new_set()

T["persistence"]["save and load roundtrip preserves all fields"] = function()
  child.lua([[
    require("aside").setup({
      persistence = { enabled = true },
      data_dir = "/tmp/aside_test_persist",
    })
  ]])

  child.lua([[
    require("aside").add_annotation({
      family = "persist_test",
      file = "/tmp/test.lua",
      start_line = 10,
      end_line = 20,
      title = "Test Title",
      contents = "Test Contents",
      sort_key = 42,
      metadata = { key = "value", nested = { a = 1 } },
    })
  ]])

  child.lua("require('aside.persistence').save_family('persist_test')")

  child.lua("require('aside.state').clear()")

  local cleared_count = child.lua_get("#require('aside').get_annotations_by_family('persist_test')")
  eq(cleared_count, 0)

  child.lua("require('aside.persistence').load_family('persist_test')")

  child.lua("_G.loaded = require('aside').get_annotations_by_family('persist_test')[1]")

  eq(child.lua_get("_G.loaded.file"), "/tmp/test.lua")
  eq(child.lua_get("_G.loaded.start_line"), 10)
  eq(child.lua_get("_G.loaded.end_line"), 20)
  eq(child.lua_get("_G.loaded.title"), "Test Title")
  eq(child.lua_get("_G.loaded.contents"), "Test Contents")
  eq(child.lua_get("_G.loaded.sort_key"), 42)
  eq(child.lua_get("_G.loaded.metadata.key"), "value")
  eq(child.lua_get("_G.loaded.metadata.nested.a"), 1)
end

T["persistence"]["load returns false for nonexistent file"] = function()
  local result = child.lua_get("require('aside.persistence').load_family('nonexistent_family_xyz')")
  eq(result, false)
end

T["persistence"]["load handles corrupted JSON gracefully"] = function()
  child.lua([[
    vim.fn.mkdir("/tmp/aside_corrupt_test", "p")
    local file = io.open("/tmp/aside_corrupt_test/broken.json", "w")
    file:write("{ this is not valid json }")
    file:close()
  ]])

  child.lua([[
    require("aside").setup({
      data_dir = "/tmp/aside_corrupt_test",
    })
  ]])

  local result = child.lua_get("require('aside.persistence').load_family('broken')")
  eq(result, false)
end

T["families"]["config inherits from global defaults"] = function()
  child.lua([[
    require("aside").setup({
      default_display = "below",
      context_lines = 7,
    })
    require("aside").ensure_family("inherit_test")
  ]])

  local display = child.lua_get("require('aside.state').get_family('inherit_test'):get_config().display")
  local context = child.lua_get("require('aside.state').get_family('inherit_test'):get_config().context_lines")

  eq(display, "below")
  eq(context, 7)
end

T["families"]["family config overrides global defaults"] = function()
  child.lua([[
    require("aside").setup({
      default_display = "hover",
      context_lines = 3,
    })
    require("aside").ensure_family("override_test"):configure({
      display = "aside",
      context_lines = 10,
    })
  ]])

  local display = child.lua_get("require('aside.state').get_family('override_test'):get_config().display")
  local context = child.lua_get("require('aside.state').get_family('override_test'):get_config().context_lines")

  eq(display, "aside")
  eq(context, 10)
end

-- ============================================================================
-- Spec Set 1: layout.greedy — Greedy solver
-- ============================================================================

T["layout.greedy"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
    end,
  },
})

T["layout.greedy"]["empty annotations returns source_line_count rows"] = function()
  child.lua([[
    local g = require("aside.layout").get("greedy")
    local r = g.solve({}, 10, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    _G.row_count = #r.rows
    _G.virt_count = vim.tbl_count(r.virt_lines_by_source_line)
  ]])
  eq(child.lua_get("_G.row_count"), 10)
  eq(child.lua_get("_G.virt_count"), 0)
end

T["layout.greedy"]["single annotation fits anchor span"] = function()
  child.lua([[
    local g = require("aside.layout").get("greedy")
    local ann = { id = "a1", family = "f", file = "f", start_line = 3, end_line = 5, title = "T", contents = "", sort_key = nil, created_at = 1 }
    local r = g.solve({ ann }, 10, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    _G.row3_ann = r.rows[3].ann_id
    _G.row3_anchor = r.rows[3].is_anchor
    _G.row5_anchor = r.rows[5].is_anchor
  ]])
  eq(child.lua_get("_G.row3_ann"), "a1")
  eq(child.lua_get("_G.row3_anchor"), true)
  eq(child.lua_get("_G.row5_anchor"), true)
end

T["layout.greedy"]["annotation spills below anchor when content exceeds span"] = function()
  child.lua([[
    local g = require("aside.layout").get("greedy")
    local ann = { id = "a1", family = "f", file = "f", start_line = 5, end_line = 5, title = "T", contents = "l1\nl2\nl3", sort_key = nil, created_at = 1 }
    local r = g.solve({ ann }, 10, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    local span = 0
    for _, row in ipairs(r.rows) do
      if row.ann_id == "a1" then span = span + 1 end
    end
    _G.span = span
  ]])
  -- title (1) + 3 content lines = 4 rows minimum
  eq(child.lua_get("_G.span >= 4"), true)
end

T["layout.greedy"]["single-line anchor has single positions"] = function()
  child.lua([[
    local g = require("aside.layout").get("greedy")
    local ann = { id = "a1", family = "f", file = "f", start_line = 5, end_line = 5, title = "T", contents = "", sort_key = nil, created_at = 1 }
    local r = g.solve({ ann }, 10, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    _G.ap = r.rows[5].anchor_position
    _G.bp = r.rows[5].box_position
  ]])
  eq(child.lua_get("_G.ap"), "single")
  eq(child.lua_get("_G.bp"), "single")
end

T["layout.greedy"]["multi-line anchor produces top/middle/bottom positions"] = function()
  child.lua([[
    local g = require("aside.layout").get("greedy")
    local ann = { id = "a1", family = "f", file = "f", start_line = 3, end_line = 5, title = "T", contents = "", sort_key = nil, created_at = 1 }
    local r = g.solve({ ann }, 10, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    _G.top = r.rows[3].anchor_position
    _G.middle = r.rows[4].anchor_position
    _G.bottom = r.rows[5].anchor_position
  ]])
  eq(child.lua_get("_G.top"), "top")
  eq(child.lua_get("_G.middle"), "middle")
  eq(child.lua_get("_G.bottom"), "bottom")
end

T["layout.greedy"]["spill_direction above claims rows above anchor"] = function()
  child.lua([[
    local g = require("aside.layout").get("greedy")
    local ann = { id = "a1", family = "f", file = "f", start_line = 10, end_line = 10, title = "T", contents = "l1\nl2\nl3", sort_key = nil, created_at = 1 }
    local r = g.solve({ ann }, 15, { spill_direction = "above", wrap_width = 30, gutter_icon = "*" })
    -- spill above: row at line 7,8,9 should belong to a1 (anchor at 10)
    _G.line7 = r.rows[7].ann_id
    _G.line9 = r.rows[9].ann_id
    _G.line10_anchor = r.rows[10].is_anchor
  ]])
  eq(child.lua_get("_G.line7"), "a1")
  eq(child.lua_get("_G.line9"), "a1")
  eq(child.lua_get("_G.line10_anchor"), true)
end

T["layout.greedy"]["all non-conflicting annotations appear in result"] = function()
  child.lua([[
    local g = require("aside.layout").get("greedy")
    local anns = {
      { id = "X", family = "f", file = "f", start_line = 1, end_line = 1, title = "X", contents = "", sort_key = 2, created_at = 100 },
      { id = "Y", family = "f", file = "f", start_line = 5, end_line = 5, title = "Y", contents = "", sort_key = 1, created_at = 200 },
      { id = "Z", family = "f", file = "f", start_line = 10, end_line = 10, title = "Z", contents = "", sort_key = nil, created_at = 50 },
    }
    local r = g.solve(anns, 20, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    local seen = {}
    for _, row in ipairs(r.rows) do
      if row.ann_id then seen[row.ann_id] = true end
    end
    _G.has_X = seen.X == true
    _G.has_Y = seen.Y == true
    _G.has_Z = seen.Z == true
  ]])
  eq(child.lua_get("_G.has_X"), true)
  eq(child.lua_get("_G.has_Y"), true)
  eq(child.lua_get("_G.has_Z"), true)
end

-- ============================================================================
-- Spec Set 2: display.aside_extmarks — Extmark role manager
-- ============================================================================

T["display.aside_extmarks"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
    end,
  },
})

T["display.aside_extmarks"]["clear on empty buffer is no-op"] = function()
  child.lua([[
    local e = require("aside.display.aside_extmarks")
    local buf = vim.api.nvim_create_buf(false, true)
    e.clear(buf)
    _G.ok = true
  ]])
  eq(child.lua_get("_G.ok"), true)
end

T["display.aside_extmarks"]["place with empty layout adds no extmarks"] = function()
  child.lua([[
    local e = require("aside.display.aside_extmarks")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1" })
    e.place(buf, {
      rows = { { source_line = 1, ann_id = nil, row_kind = "empty", text = "", is_anchor = false, box_position = "none", anchor_position = "none" } },
      virt_lines_by_source_line = {},
    })
    local ns = vim.api.nvim_create_namespace("aside_edit_regions")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    _G.mark_count = #marks
  ]])
  eq(child.lua_get("_G.mark_count"), 0)
end

T["display.aside_extmarks"]["get_role_at returns none for unmarked row"] = function()
  child.lua([[
    local e = require("aside.display.aside_extmarks")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1" })
    _G.role = e.get_role_at(buf, 0)
  ]])
  eq(child.lua_get("_G.role"), "none")
end

T["display.aside_extmarks"]["place title row creates seg_start mark"] = function()
  child.lua([[
    local e = require("aside.display.aside_extmarks")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* Title" })
    e.place(buf, {
      rows = {
        { source_line = 1, ann_id = "x1", row_kind = "title", segment_idx = 0, text = "* Title", is_anchor = true, box_position = "single", anchor_position = "single" },
      },
      virt_lines_by_source_line = {},
    })
    _G.role = e.get_role_at(buf, 0)
  ]])
  eq(child.lua_get("_G.role"), "seg_start")
end

T["display.aside_extmarks"]["get_namespace_id returns a number"] = function()
  child.lua([[
    local e = require("aside.display.aside_extmarks")
    local ns = e.get_namespace_id()
    _G.is_number = type(ns) == "number"
  ]])
  eq(child.lua_get("_G.is_number"), true)
end

-- ============================================================================
-- Spec Set 3: display.aside_save — Save parser
-- ============================================================================

T["display.aside_save"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
    end,
  },
})

T["display.aside_save"]["parse on empty layout returns empty result"] = function()
  child.lua([[
    local s = require("aside.display.aside_save")
    local buf = vim.api.nvim_create_buf(false, true)
    local r = s.parse(buf, { rows = {}, virt_lines_by_source_line = {} }, "test")
    _G.updates = vim.tbl_count(r.updates)
    _G.deletions = #r.deletions
    _G.type_creates = #r.type_creates
  ]])
  eq(child.lua_get("_G.updates"), 0)
  eq(child.lua_get("_G.deletions"), 0)
  eq(child.lua_get("_G.type_creates"), 0)
end

T["display.aside_save"]["type_creates field is always present"] = function()
  child.lua([[
    local s = require("aside.display.aside_save")
    local buf = vim.api.nvim_create_buf(false, true)
    local r = s.parse(buf, { rows = {}, virt_lines_by_source_line = {} }, "test")
    _G.has_type_creates = type(r.type_creates) == "table"
  ]])
  eq(child.lua_get("_G.has_type_creates"), true)
end

T["display.aside_save"]["parse with invalid buffer returns empty result"] = function()
  child.lua([[
    local s = require("aside.display.aside_save")
    local r = s.parse(999999, { rows = {}, virt_lines_by_source_line = {} }, "test")
    _G.updates = vim.tbl_count(r.updates)
    _G.deletions = #r.deletions
    _G.type_creates = #r.type_creates
  ]])
  eq(child.lua_get("_G.updates"), 0)
  eq(child.lua_get("_G.deletions"), 0)
  eq(child.lua_get("_G.type_creates"), 0)
end

T["display.aside_save"]["parse detects type-to-create on out-of-region line"] = function()
  child.lua([[
    local s = require("aside.display.aside_save")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new annotation here" })
    local layout = {
      rows = {
        { source_line = 1, ann_id = nil, row_kind = "empty", text = "", is_anchor = false, box_position = "none", anchor_position = "none" },
      },
      virt_lines_by_source_line = {},
    }
    local r = s.parse(buf, layout, "test")
    _G.tc_count = #r.type_creates
    if #r.type_creates > 0 then
      _G.tc_contents = r.type_creates[1].contents
      _G.tc_source_line = r.type_creates[1].source_line
    end
  ]])
  eq(child.lua_get("_G.tc_count"), 1)
  eq(child.lua_get("_G.tc_contents"), "new annotation here")
  eq(child.lua_get("_G.tc_source_line"), 1)
end

T["display.aside_save"]["commit no-op for empty parse_result"] = function()
  child.lua([[
    local s = require("aside.display.aside_save")
    local actions = s.commit({ updates = {}, deletions = {}, type_creates = {} }, 1, nil, nil)
    _G.action_count = #actions
  ]])
  eq(child.lua_get("_G.action_count"), 0)
end

-- ============================================================================
-- Spec Set 4: display.aside lifecycle
-- ============================================================================

T["display.aside lifecycle"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
    end,
  },
})

T["display.aside lifecycle"]["set_family refuses when modified"] = function()
  child.lua([[
    local d = require("aside.display.aside")
    d._test_set_data(7777, {
      win = 7777, buf = 7777, family = "family_a", source_path = "/test/file.lua",
      layout = nil, in_insert = false, deferred_render = false, modified = true, augroup_name = "test_ag_life1",
    })
    d.set_family(7777, "family_b")
    _G.family = d._test_get_data(7777).family
  ]])
  eq(child.lua_get("_G.family"), "family_a")
end

T["display.aside lifecycle"]["set_family allows switch when clean"] = function()
  child.lua([[
    local d = require("aside.display.aside")
    require("aside.state").ensure_family("family_b")
    d._test_set_data(7778, {
      win = 7778, buf = 7778, family = "family_a", source_path = "/test/file.lua",
      layout = nil, in_insert = false, deferred_render = false, modified = false, augroup_name = "test_ag_life2",
    })
    d.set_family(7778, "family_b")
    _G.family = d._test_get_data(7778).family
  ]])
  eq(child.lua_get("_G.family"), "family_b")
end

T["display.aside lifecycle"]["refresh_if_visible defers when in_insert"] = function()
  child.lua([[
    local d = require("aside.display.aside")
    d._test_set_data(7779, {
      win = 7779, buf = 7779, family = "f", source_path = "/test/f.lua",
      layout = nil, in_insert = true, deferred_render = false, modified = false, augroup_name = "test_ag_life3",
    })
    local buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, "/test/f.lua")
    d.refresh_if_visible(buf)
    _G.deferred = d._test_get_data(7779).deferred_render
  ]])
  eq(child.lua_get("_G.deferred"), true)
end

T["display.aside lifecycle"]["close on unknown source_win is no-op"] = function()
  child.lua([[
    local d = require("aside.display.aside")
    d.close(123456)
    _G.ok = true
  ]])
  eq(child.lua_get("_G.ok"), true)
end

-- ============================================================================
-- Spec Set 5: config validation
-- ============================================================================

T["config validation"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
    end,
  },
})

T["config validation"]["aside_width default is 40"] = function()
  child.lua([[ _G.val = require("aside.config").get_value("aside_width", nil) ]])
  eq(child.lua_get("_G.val"), 40)
end

T["config validation"]["spill_direction default is below"] = function()
  child.lua([[ _G.val = require("aside.config").get_value("spill_direction", nil) ]])
  eq(child.lua_get("_G.val"), "below")
end

T["config validation"]["invalid spill_direction is rejected by family configure"] = function()
  child.lua([[
    local f = require("aside").ensure_family("test_cfg_spill")
    _G.before = f:get_config().spill_direction
    f:configure({ spill_direction = "sideways" })
    _G.after = f:get_config().spill_direction
  ]])
  -- Should be unchanged (rejected)
  eq(child.lua_get("_G.after"), child.lua_get("_G.before"))
end

T["config validation"]["gutter_icon width 2 is rejected by family configure"] = function()
  child.lua([[
    local f = require("aside").ensure_family("test_cfg_icon")
    _G.before = f:get_config().gutter_icon
    f:configure({ gutter_icon = "AB" })
    _G.after = f:get_config().gutter_icon
  ]])
  eq(child.lua_get("_G.after"), child.lua_get("_G.before"))
end

T["config validation"]["valid spill_direction 'above' is accepted"] = function()
  child.lua([[
    local f = require("aside").ensure_family("test_cfg_above")
    f:configure({ spill_direction = "above" })
    _G.dir = f:get_config().spill_direction
  ]])
  eq(child.lua_get("_G.dir"), "above")
end

-- ============================================================================
-- Spec Set 6: layout.types
-- ============================================================================

T["layout.types"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
    end,
  },
})

T["layout.types"]["module loads without errors"] = function()
  child.lua([[
    require("aside.layout.types")
    _G.ok = true
  ]])
  eq(child.lua_get("_G.ok"), true)
end

T["layout.types"]["module exports empty table (no public methods)"] = function()
  child.lua([[
    local t = require("aside.layout.types")
    _G.is_table = type(t) == "table"
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    _G.method_count = count
  ]])
  eq(child.lua_get("_G.is_table"), true)
  eq(child.lua_get("_G.method_count"), 0)
end

-- ============================================================================
-- Spec Set 7: layout.solver interface (registry)
-- ============================================================================

T["layout.solver interface"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
    end,
  },
})

T["layout.solver interface"]["greedy solver is registered"] = function()
  child.lua([[
    local solver = require("aside.layout").get("greedy")
    _G.has_solve = type(solver.solve) == "function"
  ]])
  eq(child.lua_get("_G.has_solve"), true)
end

T["layout.solver interface"]["unknown solver raises error"] = function()
  child.lua([[
    local ok, err = pcall(require("aside.layout").get, "nonexistent_xyz")
    _G.ok = ok
    _G.err_has_msg = err ~= nil and err:find("aside: unknown layout solver") ~= nil
  ]])
  eq(child.lua_get("_G.ok"), false)
  eq(child.lua_get("_G.err_has_msg"), true)
end

T["layout.solver interface"]["solve convenience delegates to registered solver"] = function()
  child.lua([[
    local layout = require("aside.layout")
    local r = layout.solve("greedy", {}, 5, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    _G.row_count = #r.rows
  ]])
  eq(child.lua_get("_G.row_count"), 5)
end

-- ============================================================================
-- Spec Set 8: display.aside scroll sync (Bug #1)
--
-- These tests build a REAL source + aside split pair, populate annotations,
-- and call sync_scroll directly. WinScrolled does not fire reliably in
-- headless Neovim, so the tests bypass the autocmd and exercise the sync
-- logic by invoking the public sync_scroll API with an explicit scrolled-win
-- argument (after the source-of-truth fix that adds that argument).
-- ============================================================================

T["display.aside scroll sync"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
      child.lua("require('aside').setup({ persistence = { enabled = false } })")
      -- Give the child UI enough lines for meaningful scrolling.
      child.o.lines = 30
      child.o.columns = 120
    end,
  },
})

-- Common setup helper executed inside child: long source buffer + one
-- annotation around the middle + opened aside panel anchored to the source.
local function setup_long_source_with_aside(child)
  child.lua([[
    local lines = {}
    for i = 1, 300 do lines[i] = "source line " .. i end
    local tmp = vim.fn.tempname() .. ".txt"
    vim.fn.writefile(lines, tmp)
    vim.cmd("edit " .. tmp)
    _G.source_win = vim.api.nvim_get_current_win()
    _G.source_buf = vim.api.nvim_get_current_buf()
    _G.source_path = tmp

    require("aside").ensure_family("scroll_fam")
    _G.ann_id = require("aside").add_annotation({
      family = "scroll_fam",
      file = tmp,
      start_line = 150,
      end_line = 150,
      title = "Mid annotation",
      contents = "Just one line",
    })
    require("aside").open_aside({ family = "scroll_fam", win = _G.source_win })
    _G.aside_data = require("aside.display.aside")._test_get_data(_G.source_win)
    _G.aside_win = _G.aside_data.win
    _G.aside_buf = _G.aside_data.buf
  ]])
end

T["display.aside scroll sync"]["source scroll moves aside (baseline)"] = function()
  setup_long_source_with_aside(child)
  child.lua([[
    vim.fn.win_execute(_G.source_win, "normal! 100Gzt", true)
    require("aside.display.aside").sync_scroll(_G.source_win, _G.source_win)
    _G.aside_topline = vim.fn.line("w0", _G.aside_win)
    _G.source_topline = vim.fn.line("w0", _G.source_win)
    _G.aside_line_count = vim.api.nvim_buf_line_count(_G.aside_buf)
  ]])
  local topline = child.lua_get("_G.aside_topline")
  local src_top = child.lua_get("_G.source_topline")
  local n = child.lua_get("_G.aside_line_count")
  eq(
    topline >= 95 and topline <= 105,
    true,
    "expected aside topline near 100, got aside=" .. tostring(topline)
      .. " source=" .. tostring(src_top)
      .. " aside_lines=" .. tostring(n)
  )
end

T["display.aside scroll sync"]["open_aside performs initial sync to pre-scrolled source"] = function()
  child.lua([[
    local lines = {}
    for i = 1, 300 do lines[i] = "source line " .. i end
    local tmp = vim.fn.tempname() .. ".txt"
    vim.fn.writefile(lines, tmp)
    vim.cmd("edit " .. tmp)
    _G.source_win = vim.api.nvim_get_current_win()

    require("aside").ensure_family("init_fam")
    require("aside").add_annotation({
      family = "init_fam", file = tmp, start_line = 150, end_line = 150,
      title = "T", contents = "c",
    })

    -- Pre-scroll source BEFORE opening the aside panel.
    vim.fn.win_execute(_G.source_win, "normal! 80Gzt", true)
    _G.src_before = vim.fn.line("w0", _G.source_win)

    require("aside").open_aside({ family = "init_fam", win = _G.source_win })
    local d = require("aside.display.aside")._test_get_data(_G.source_win)
    _G.aside_top = vim.fn.line("w0", d.win)
    _G.src_after = vim.fn.line("w0", _G.source_win)
  ]])
  eq(child.lua_get("_G.src_before"), 80)
  eq(child.lua_get("_G.src_after"), 80)
  local at = child.lua_get("_G.aside_top")
  eq(at >= 75 and at <= 85, true,
     "expected aside topline near 80 after initial sync, got " .. tostring(at))
end

T["display.aside scroll sync"]["round-trip sync is stable (no drift)"] = function()
  setup_long_source_with_aside(child)
  child.lua([[
    local mod = require("aside.display.aside")
    -- Move source to a stable position, sync to aside, then sync back.
    -- A correct implementation produces source==initial after the roundtrip.
    vim.fn.win_execute(_G.source_win, "normal! 60Gzt", true)
    _G.src_initial = vim.fn.line("w0", _G.source_win)

    mod.sync_scroll(_G.source_win, _G.source_win)
    _G.aside_after_first_sync = vim.fn.line("w0", _G.aside_win)

    -- Now sync from aside back to source. Source must NOT drift.
    mod.sync_scroll(_G.source_win, _G.aside_win)
    _G.src_after_roundtrip = vim.fn.line("w0", _G.source_win)
  ]])
  local initial = child.lua_get("_G.src_initial")
  local roundtrip = child.lua_get("_G.src_after_roundtrip")
  eq(roundtrip, initial,
     "round-trip drifted: source went from " .. tostring(initial)
       .. " to " .. tostring(roundtrip))
end

T["display.aside scroll sync"]["foreign virt_lines on source do not skew aside"] = function()
  setup_long_source_with_aside(child)
  child.lua([[
    -- Another plugin places virt_lines on the source buffer. The aside sync
    -- must IGNORE these (they aren't part of our layout) so source line N
    -- still aligns with aside row N + (our virt count below N).
    local foreign_ns = vim.api.nvim_create_namespace("foreign_plugin")
    for line = 9, 0, -1 do
      pcall(vim.api.nvim_buf_set_extmark, _G.source_buf, foreign_ns, line, 0, {
        virt_lines = { { { "FOREIGN", "Comment" } }, { { "FOREIGN2", "Comment" } } },
        virt_lines_above = false,
      })
    end

    local mod = require("aside.display.aside")
    vim.fn.win_execute(_G.source_win, "normal! 100Gzt", true)
    mod.sync_scroll(_G.source_win, _G.source_win)
    _G.src_top = vim.fn.line("w0", _G.source_win)
    _G.aside_top = vim.fn.line("w0", _G.aside_win)
  ]])
  local src = child.lua_get("_G.src_top")
  local aside = child.lua_get("_G.aside_top")
  eq(src, 100)
  -- Without the fix, foreign virt_lines (20 of them above source line 100)
  -- would shift aside_top to ~120. With the fix, only our own virt_lines
  -- matter; the annotation is at line 150 so there are no virt_lines above
  -- line 100, and aside_top must equal source_top.
  eq(aside, 100,
     "aside skewed by foreign virt_lines: expected 100, got " .. tostring(aside))
end

T["display.aside scroll sync"]["repeated ping-pong syncs do not ladder"] = function()
  setup_long_source_with_aside(child)
  child.lua([[
    local mod = require("aside.display.aside")
    vim.fn.win_execute(_G.source_win, "normal! 100Gzt", true)
    _G.src_initial = vim.fn.line("w0", _G.source_win)
    -- 10 alternating syncs simulate aggressive WinScrolled feedback.
    for _ = 1, 10 do
      mod.sync_scroll(_G.source_win, _G.source_win)
      mod.sync_scroll(_G.source_win, _G.aside_win)
    end
    _G.src_after = vim.fn.line("w0", _G.source_win)
    _G.aside_after = vim.fn.line("w0", _G.aside_win)
  ]])
  local initial = child.lua_get("_G.src_initial")
  local after = child.lua_get("_G.src_after")
  eq(after, initial,
     "laddered after 10 cycles: source went from " .. tostring(initial)
       .. " to " .. tostring(after))
end

T["display.aside scroll sync"]["aside scroll moves source (BUG #1)"] = function()
  setup_long_source_with_aside(child)
  child.lua([[
    -- Pin source at top, then scroll aside down.
    vim.fn.win_execute(_G.source_win, "normal! 1Gzt", true)
    vim.fn.win_execute(_G.aside_win, "normal! 200Gzt", true)
    -- Sync as though WinScrolled fired for the aside window.
    require("aside.display.aside").sync_scroll(_G.source_win, _G.aside_win)
    _G.source_topline = vim.fn.line("w0", _G.source_win)
    _G.aside_topline = vim.fn.line("w0", _G.aside_win)
  ]])
  local source_topline = child.lua_get("_G.source_topline")
  local aside_topline = child.lua_get("_G.aside_topline")
  -- After the fix, source should follow aside. Allow modest slack for
  -- visual-row vs buffer-row arithmetic around the annotation virt rows.
  eq(source_topline >= 190 and source_topline <= 210,
     true,
     "expected source_topline near aside_topline (~200), got source="
       .. source_topline .. " aside=" .. aside_topline)
end

-- ============================================================================
-- Spec Set 9: display.aside statuscolumn glyphs (Bug #2)
--
-- The statuscolumn presents two columns:
--   * outer (left, far from text)   -> ANCHOR position glyphs
--   * inner (right, adjacent to text) -> BOX (full annotation span) glyphs
--
-- Expected per-row glyphs (matching the user's expected output):
--
--   anchor_position    -> outer column
--     top    -> "┐"   bottom -> "┘"   middle -> "│"   single -> "│"
--     none   -> " "
--
--   box_position       -> inner column
--     top    -> "┌"   bottom -> "└"   middle -> "│"   single -> "─"
--     none   -> " "
--
-- Additionally, a `connector` accent glyph "├┤" appears on a single row
-- representing the midpoint of the SHORTER of (anchor span, box span).
-- ============================================================================

T["display.aside statuscolumn"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "test/init_minimal.lua" })
      child.lua("require('aside').setup({ persistence = { enabled = false } })")
    end,
  },
})

-- Helper executed in the child to build an aside_data fixture with a
-- precomputed layout, then read the statuscolumn value for a given lnum.
-- Returns the rendered string after stripping highlight prefixes "%#GROUP#".
-- vim.v.lnum is read-only, so we pass lnum as an explicit second argument
-- to statuscolumn_for_buf (test seam) and fall back to vim.v.lnum at runtime.
local function statuscolumn_at(child, source_lines, anns, lnum)
  child.lua(string.format([[
    local d = require("aside.display.aside")
    local layout = require("aside.layout").get("greedy").solve(
      %s, %d, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    local buf = vim.api.nvim_create_buf(false, true)
    d._test_set_data(424242, {
      win = 424242, buf = buf, family = "f", source_path = "/x",
      layout = layout, in_insert = false, deferred_render = false,
      modified = false, augroup_name = "test_statuscol",
    })
    _G.test_buf = buf
    _G.test_layout = layout
  ]], anns, source_lines))
  child.lua(string.format([[
    _G.statuscol = require("aside.display.aside").statuscolumn_for_buf(_G.test_buf, %d)
  ]], lnum))
  local raw = child.lua_get("_G.statuscol")
  -- strip "%#Group#" highlight prefixes for stable assertions
  local glyphs = (raw or ""):gsub("%%#[^#]*#", "")
  return glyphs
end

T["display.aside statuscolumn"]["single-line anchor uses single+single"] = function()
  local anns = '{ { id="a1", family="f", file="/x", start_line=3, end_line=3, title="T", contents="", sort_key=nil, created_at=1 } }'
  -- Row 3 is the only anchor row, also the only annotation row → both single.
  -- For an annotation with no contents the title row IS the whole annotation.
  -- box_position="single" (only one row) and anchor_position="single".
  local g = statuscolumn_at(child, 10, anns, 3)
  -- Outer column = anchor single = "│"; inner column = box single = "─".
  eq(g, "\xe2\x94\x82\xe2\x94\x80") -- "│─"
end

T["display.aside statuscolumn"]["multi-row annotation: anchor outer, box inner"] = function()
  -- start_line=1, end_line=6 → anchor spans aside rows 1..6.
  -- contents is long enough to extend below the anchor.
  local anns = [[{ {
      id="a1", family="f", file="/x", start_line=1, end_line=6,
      title="T", contents="c1\nc2\nc3\nc4\nc5\nc6\nc7\nc8\nc9\nc10",
      sort_key=nil, created_at=1
  } }]]

  -- Row 1: anchor top, box top → outer="┐", inner="┌"
  eq(statuscolumn_at(child, 20, anns, 1), "\xe2\x94\x90\xe2\x94\x8c") -- ┐┌
  -- Row 6: anchor bottom, box middle → outer="┘", inner="│"
  eq(statuscolumn_at(child, 20, anns, 6), "\xe2\x94\x98\xe2\x94\x82") -- ┘│
  -- Row 7: past anchor (none), still inside box (middle) → outer=" ", inner="│"
  eq(statuscolumn_at(child, 20, anns, 7), " \xe2\x94\x82")
end

T["display.aside statuscolumn"]["anchor middle uses plain vertical, not tee"] = function()
  -- 6-line anchor, content long enough to make box larger than anchor.
  -- Pick a row that is NOT the connector midpoint of the anchor (row 3 or 4),
  -- so the anchor-middle glyph is the plain vertical "│" rather than the tee.
  local anns = [[{ {
      id="a1", family="f", file="/x", start_line=1, end_line=6,
      title="T", contents="c1\nc2\nc3\nc4\nc5\nc6\nc7\nc8\nc9\nc10",
      sort_key=nil, created_at=1
  } }]]
  -- Row 2 is anchor middle but not the midpoint connector → plain "│".
  local g = statuscolumn_at(child, 20, anns, 2)
  eq(g, "\xe2\x94\x82\xe2\x94\x82") -- "││"
  -- Row 5 likewise: anchor middle, box middle, plain.
  local g5 = statuscolumn_at(child, 20, anns, 5)
  eq(g5, "\xe2\x94\x82\xe2\x94\x82")
end

T["display.aside statuscolumn"]["connector tee at midpoint of shorter box"] = function()
  -- Source anchor span = 6, annotation span > 6, so anchor is the shorter
  -- box. The connector "├┤" should land at the midpoint of the anchor
  -- (row 3 for a 6-row anchor: floor((1+6)/2) = 3).
  local anns = [[{ {
      id="a1", family="f", file="/x", start_line=1, end_line=6,
      title="T", contents="c1\nc2\nc3\nc4\nc5\nc6\nc7\nc8\nc9\nc10",
      sort_key=nil, created_at=1
  } }]]
  local g = statuscolumn_at(child, 20, anns, 3)
  eq(g, "\xe2\x94\x9c\xe2\x94\xa4") -- ├┤
end

T["display.aside statuscolumn"]["closer row: └ in gutter, dashes in text"] = function()
  -- Multi-row annotation gets a synthetic closer row at the very bottom.
  -- The closer row's statuscolumn shows " └" (no anchor + box-bottom).
  -- Its text content is a run of horizontal box-drawing chars ("─...").
  local anns = [[{ {
      id="a1", family="f", file="/x", start_line=1, end_line=6,
      title="T", contents="c1\nc2\nc3\nc4\nc5\nc6\nc7\nc8\nc9\nc10",
      sort_key=nil, created_at=1
  } }]]
  child.lua(string.format([[
    local layout = require("aside.layout").get("greedy").solve(
      %s, 20, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    local closer_idx
    for i, r in ipairs(layout.rows) do
      if r.row_kind == "closer" then closer_idx = i; break end
    end
    _G.closer_idx = closer_idx
    if closer_idx then
      _G.closer_row = layout.rows[closer_idx]
      _G.prev_row = layout.rows[closer_idx - 1]
    end
  ]], anns))
  -- A closer row must exist; box=bottom, anchor=none, text starts with "─".
  eq(type(child.lua_get("_G.closer_idx")), "number")
  eq(child.lua_get("_G.closer_row.row_kind"), "closer")
  eq(child.lua_get("_G.closer_row.box_position"), "bottom")
  eq(child.lua_get("_G.closer_row.anchor_position"), "none")
  local text = child.lua_get("_G.closer_row.text")
  eq(text:sub(1, #"\xe2\x94\x80"), "\xe2\x94\x80") -- "─"
  -- The prior row (last content row) is now box=middle, not bottom.
  eq(child.lua_get("_G.prev_row.box_position"), "middle")
end

T["display.aside statuscolumn"]["single-row annotation has no closer"] = function()
  -- A single-line annotation (anchor=1 line, no contents overflow) should
  -- NOT receive a closer row.
  local anns = '{ { id="a1", family="f", file="/x", start_line=3, end_line=3, title="T", contents="", sort_key=nil, created_at=1 } }'
  child.lua(string.format([[
    local layout = require("aside.layout").get("greedy").solve(
      %s, 10, { spill_direction = "below", wrap_width = 30, gutter_icon = "*" })
    local has_closer = false
    for _, r in ipairs(layout.rows) do
      if r.row_kind == "closer" then has_closer = true end
    end
    _G.has_closer = has_closer
  ]], anns))
  eq(child.lua_get("_G.has_closer"), false)
end

return T
