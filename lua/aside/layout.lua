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
