local M = {}

-- Registry of solver implementations: name -> solver module table
local solvers = {}

--- Register a solver implementation by name.
--- The solver must implement the Aside.Layout.Solver interface:
---   solver.solve(annotations, source_line_count, options) -> Aside.Layout.Result
---@param name string Solver name (e.g. "greedy")
---@param solver table Solver module implementing Aside.Layout.Solver
function M.register(name, solver)
  solvers[name] = solver
end

--- Get a registered solver by name. Raises an error if not found.
--- If a solver is not yet registered, attempts to lazily require the
--- module at `aside.layout.<name>` which is expected to self-register.
---@param name string Solver name
---@return table solver The solver module
function M.get(name)
  local solver = solvers[name]
  if not solver then
    -- Lazy load: solver modules self-register via M.register on load.
    pcall(require, "aside.layout." .. name)
    solver = solvers[name]
  end
  if not solver then
    local registered = {}
    for k, _ in pairs(solvers) do
      table.insert(registered, k)
    end
    table.sort(registered)
    error("aside: unknown layout solver: " .. name .. " (registered: " .. table.concat(registered, ", ") .. ")")
  end
  return solver
end

--- Fill `box_position`, `anchor_position` and `is_anchor` on every row.
--- Shared by solvers (rendered layout) and the live view of an edited aside
--- buffer, so the gutter is drawn the same way in both.
---
--- Box: an annotation's rows are top / middle..., with its closer row as the
--- bottom; a lone row is "single". Anchor: spans the first row of each block
--- whose source line is inside [start_line, end_line]. A connector glyph sits
--- at the midpoint of the shorter of the two spans when both are >= 3 rows.
---@param rows table[] rows with source_line, ann_id, row_kind
---@param anns {id: string, start_line: integer, end_line: integer}[]
function M.decorate(rows, anns)
  local block_first, by_ann = {}, {}
  for i, r in ipairs(rows) do
    r.box_position, r.anchor_position = "none", "none"
    if r.row_kind ~= "closer" and not block_first[r.source_line] then
      block_first[r.source_line] = i
    end
    if r.ann_id then
      by_ann[r.ann_id] = by_ann[r.ann_id] or {}
      table.insert(by_ann[r.ann_id], i)
    end
  end

  for _, a in ipairs(anns) do
    local idx = by_ann[a.id] or {}
    local n = #idx
    for k, i in ipairs(idx) do
      rows[i].box_position = n == 1 and "single" or k == 1 and "top" or k == n and "bottom" or "middle"
    end

    local first, last
    for line = a.start_line, a.end_line do
      local i = block_first[line]
      if i then
        first = first or i
        last = i
      end
    end
    if first then
      for i = first, last do
        rows[i].anchor_position = (first == last) and "single" or i == first and "top" or i == last and "bottom"
          or "middle"
      end
      local box_rows = (n > 0 and rows[idx[n]].row_kind == "closer") and n - 1 or n
      local span = last - first + 1
      if span >= 3 and box_rows >= 3 and span ~= box_rows then
        local c = span < box_rows and first + math.floor((span - 1) / 2) or idx[1] + math.floor((box_rows - 1) / 2)
        if rows[c].anchor_position == "middle" then rows[c].anchor_position = "connector" end
        if rows[c].box_position == "middle" then rows[c].box_position = "connector" end
      end
    end
  end

  for _, r in ipairs(rows) do
    r.is_anchor = r.anchor_position ~= "none"
  end
  return rows
end

--- Convenience: solve directly using a named solver.
---@param name string Solver name
---@param annotations Aside.Annotation[] Annotations to lay out
---@param source_line_count number Total source buffer line count
---@param options Aside.Layout.SolverOptions Layout options
---@return Aside.Layout.Result
function M.solve(name, annotations, source_line_count, options)
  return M.get(name).solve(annotations, source_line_count, options)
end

return M
