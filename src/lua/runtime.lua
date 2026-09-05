local h = require("haunt")
local M = {}

local function copy(value, seen)
  local kind = type(value)
  if kind ~= "table" then
    assert(kind == "nil" or kind == "boolean" or kind == "string" or kind == "number", "retained state must contain plain data")
    return value
  end
  seen = seen or {}
  assert(not seen[value], "retained state cannot contain cycles")
  seen[value] = true
  local result = {}
  for key, child in pairs(value) do
    assert(type(key) == "string" or type(key) == "number", "invalid retained state key")
    result[key] = copy(child, seen)
  end
  seen[value] = nil
  return result
end

function M.new(now)
  local widgets, order, pending = {}, {}, false
  local api = {}

  local function cleanup(entry)
    if not entry then return end
    entry.alive = false
    entry.timers = {}
    for index = #entry.cleanups, 1, -1 do
      local ok, message = xpcall(entry.cleanups[index], debug.traceback)
      if not ok then entry.error = message end
    end
    entry.cleanups = {}
  end

  local function context(entry, options, width, height)
    local ctx = { options = options, size = { width = width, height = height } }
    function ctx:update()
      if not entry.alive then return end
      assert(not entry.rendering, "request updates in handlers/tasks, not during render")
      entry.dirty, pending = true, true
    end
    function ctx:every(milliseconds, callback)
      assert(type(milliseconds) == "number" and milliseconds >= 1 and milliseconds < math.huge, "timer interval must be positive milliseconds")
      assert(type(callback) == "function", "timer callback must be a function")
      assert(entry.alive, "widget has been disposed")
      local timer = { interval = milliseconds, next = now() + milliseconds, callback = callback, active = true }
      entry.timers[#entry.timers + 1] = timer
      return function() timer.active = false end
    end
    function ctx:on_cleanup(callback)
      assert(type(callback) == "function", "cleanup callback must be a function")
      entry.cleanups[#entry.cleanups + 1] = callback
    end
    function ctx:retain(key, initial)
      assert(type(key) == "string", "retained state needs a stable string key")
      if entry.retained[key] == nil then entry.retained[key] = copy(initial) end
      return entry.retained[key]
    end
    function ctx:log(...)
      local values = table.pack(...)
      for index = 1, values.n do values[index] = tostring(values[index]) end
      entry.log = table.concat(values, " ")
    end
    function ctx:command(arguments)
      assert(type(arguments) == "table", "command expects an argument array")
      local output, status = _haunt_command(arguments)
      assert(output, status)
      return output, status
    end
    return ctx
  end

  local function render(entry)
    entry.dirty = false
    entry.rendering = true
    local ok, result = xpcall(function() return h.validate_scene(entry.render()) end, debug.traceback)
    entry.rendering = false
    if not ok then entry.error = result; return false, result end
    if type(result) ~= "table" or (result.kind ~= "box" and result.kind ~= "text") then
      entry.error = "render must return a box or text node"
      return false, entry.error
    end
    entry.scene, entry.error = result, nil
    entry.version = entry.version + 1
    return true
  end

  function api.load_source(id, path, source, options, width, height)
    local old = widgets[id]
    local candidate = { alive = true, timers = {}, cleanups = {}, retained = {}, dirty = true,
      title = id, version = old and old.version or 0, dependencies = { path } }
    local ok, message = xpcall(function()
      candidate.retained = copy(old and old.retained or {})
      local environment = setmetatable({}, { __index = _G })
      environment._G = environment
      local modules = { haunt = h, math = math, string = string, table = table, utf8 = utf8,
        coroutine = coroutine, os = os, io = io, debug = debug }
      local directory = path:match("^(.*[/\\])") or "./"
      environment.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        assert(type(name) == "string", "module name must be a string")
        local filename = assert(package.searchpath(name, directory .. "?.lua;" .. directory .. "?/init.lua"))
        local chunk = assert(loadfile(filename, "t", environment))
        modules[name] = true
        local value = chunk()
        if value ~= nil then modules[name] = value end
        candidate.dependencies[#candidate.dependencies + 1] = filename
        return modules[name]
      end
      environment.print = function(...)
        local values = table.pack(...)
        for index = 1, values.n do values[index] = tostring(values[index]) end
        candidate.log = table.concat(values, " ")
      end
      local definition = assert(load(source, "@" .. path, "t", environment))()
      h.widget(definition)
      candidate.title = definition.title or id
      candidate.ctx = context(candidate, h.validate_options(definition.options or {}, options or {}), width, height)
      candidate.render = definition.setup(candidate.ctx)
      assert(type(candidate.render) == "function", "setup must return a render function")
      local rendered, reason = render(candidate)
      assert(rendered, reason)
    end, debug.traceback)
    if not ok then
      cleanup(candidate)
      if old then old.error = message end
      pending = true
      return false, message
    end
    cleanup(old)
    if not old then order[#order + 1] = id end
    widgets[id] = candidate
    pending = true
    return true
  end

  function api.load(id, path, options, width, height)
    local file, message = io.open(path, "rb")
    if not file then
      if widgets[id] then widgets[id].error = message end
      pending = true
      return false, message
    end
    local source = file:read("a")
    file:close()
    return api.load_source(id, path, source, options, width, height)
  end

  function api.poll()
    local time = now()
    for _, id in ipairs(order) do
      local entry = widgets[id]
      if entry then
        local limit = #entry.timers
        for index = 1, limit do
          local timer = entry.timers[index]
          if timer.active and time >= timer.next then
            timer.next = time + timer.interval
            local ok, message = xpcall(timer.callback, debug.traceback)
            if not ok then
              timer.active = false
              entry.error, pending = message, true
            end
          end
        end
      end
    end
    local result = pending
    pending = false
    return result
  end

  function api.next_delay()
    local time, delay = now(), 1000
    for _, entry in pairs(widgets) do
      for _, timer in ipairs(entry.timers) do
        if timer.active then delay = math.min(delay, math.max(0, timer.next - time)) end
      end
    end
    return math.ceil(delay)
  end

  function api.frame(id, width, height)
    local entry = widgets[id]
    if not entry then return nil, 0, nil, id end
    if entry.ctx.size.width ~= width or entry.ctx.size.height ~= height then
      entry.ctx.size.width, entry.ctx.size.height = width, height
      entry.dirty = true
    end
    if entry.dirty then render(entry) end
    return entry.scene, entry.version, entry.error, entry.title
  end

  function api.dispatch(id, handler, event, version)
    local entry = widgets[id]
    if not entry then return end
    if version ~= nil and version ~= entry.version then return end
    local ok, message = xpcall(handler, debug.traceback, event)
    if not ok then entry.error, pending = message, true end
  end

  function api.dependencies(id) return widgets[id] and widgets[id].dependencies or {} end
  function api.inspect(id) return widgets[id] end
  function api.remove(id)
    cleanup(widgets[id])
    widgets[id] = nil
    for index = #order, 1, -1 do if order[index] == id then table.remove(order, index) end end
    pending = true
  end
  function api.close()
    for _, entry in pairs(widgets) do cleanup(entry) end
    widgets, order = {}, {}
  end
  return api
end

return M
