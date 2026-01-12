local M = {}

local state = require("aside.state")
local relocator = require("aside.relocator")

local ns_id = vim.api.nvim_create_namespace("aside_tracking")
local extmark_to_annotation = {}

function M.attach_extmark(annotation)
  local buf = vim.fn.bufnr(annotation.file)
  if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
    return nil
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_line = math.min(annotation.start_line, line_count)
  local end_line = math.min(annotation.end_line, line_count)
  local extmark_opts = {
    strict = false,
    right_gravity = true,
  }
  if start_line ~= end_line then
    extmark_opts.end_line = end_line - 1
    extmark_opts.end_col = 0
    extmark_opts.end_right_gravity = true
  end
  local ok, extmark_id = pcall(function()
    return vim.api.nvim_buf_set_extmark(buf, ns_id, start_line - 1, 0, extmark_opts)
  end)
  if ok and extmark_id then
    annotation.extmark_id = extmark_id
    annotation.extmark_buf = buf
    extmark_to_annotation[buf .. ":" .. extmark_id] = annotation.id
    return extmark_id
  end
  return nil
end

function M.detach_extmark(annotation)
  if annotation.extmark_id and annotation.extmark_buf then
    local buf = annotation.extmark_buf
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns_id, annotation.extmark_id)
    end
    extmark_to_annotation[buf .. ":" .. annotation.extmark_id] = nil
    annotation.extmark_id = nil
    annotation.extmark_buf = nil
  end
end

function M.sync_extmarks(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then
    return
  end
  local annotations_mod = require("aside.annotations")
  local annotations = annotations_mod.get_by_file(path)
  for _, annotation in ipairs(annotations) do
    local real_ann = state.get_annotation(annotation.id)
    if real_ann and real_ann.extmark_id then
      local ok, pos = pcall(function()
        return vim.api.nvim_buf_get_extmark_by_id(buf, ns_id, real_ann.extmark_id, { details = true })
      end)
      if ok and pos and #pos >= 2 then
        local new_start = pos[1] + 1
        local details = pos[3] or {}
        local new_end = details.end_row and (details.end_row + 1) or new_start
        if new_start ~= real_ann.start_line or new_end ~= real_ann.end_line then
          state.relocate_annotation(real_ann.id, new_start, new_end, false)
        end
      end
    end
  end
end

function M.refresh_extmarks(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
  local annotations_mod = require("aside.annotations")
  local annotations = annotations_mod.get_by_file(path)
  for _, annotation in ipairs(annotations) do
    local real_ann = state.get_annotation(annotation.id)
    if real_ann then
      M.attach_extmark(real_ann)
    end
  end
end

function M.relocate_buffer_annotations(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return { relocated = 0, total = 0 }
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then
    return { relocated = 0, total = 0 }
  end
  local annotations_mod = require("aside.annotations")
  local annotations = annotations_mod.get_by_file(path)
  if #annotations == 0 then
    return { relocated = 0, total = 0 }
  end
  local relocation_results = relocator.relocate_annotations_for_file(path, annotations)
  local relocated_count = 0
  for _, result in ipairs(relocation_results) do
    if result.status ~= "unchanged" then
      local annotation = state.get_annotation(result.annotation_id)
      if annotation then
        state.relocate_annotation(result.annotation_id, result.new_start, result.new_end, true)
        if result.status ~= "exact" then
          state.update_annotation(result.annotation_id, { verified = false })
        end
        relocated_count = relocated_count + 1
      end
    end
  end
  M.refresh_extmarks(buf)
  return { relocated = relocated_count, total = #annotations }
end

function M.setup_buffer_tracking(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local group = vim.api.nvim_create_augroup("AsideTracking_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    group = group,
    callback = function()
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
          M.sync_extmarks(buf)
          require("aside.display").refresh_buffer(buf)
        end
      end, 100)
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = buf,
    group = group,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

function M.setup_global_tracking()
  local group = vim.api.nvim_create_augroup("AsideGlobalTracking", { clear = true })
  vim.api.nvim_create_autocmd({ "BufRead", "BufEnter" }, {
    group = group,
    callback = function(args)
      local buf = args.buf
      if vim.api.nvim_buf_is_valid(buf) then
        local path = vim.api.nvim_buf_get_name(buf)
        if path and path ~= "" then
          local annotations_mod = require("aside.annotations")
          local annotations = annotations_mod.get_by_file(path)
          if #annotations > 0 then
            M.setup_buffer_tracking(buf)
            M.refresh_extmarks(buf)
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    group = group,
    callback = function(args)
      local buf = args.buf
      if vim.api.nvim_buf_is_valid(buf) then
        M.relocate_buffer_annotations(buf)
      end
    end,
  })
end

function M.get_namespace_id()
  return ns_id
end

return M
