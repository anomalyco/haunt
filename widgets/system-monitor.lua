local h = require("haunt")
local box, text = h.ui.box, h.ui.text

return h.widget {
  title = "System monitor",
  options = {
    refreshInterval = h.field.number(1000, "Milliseconds between samples"),
    cpuColor = h.field.string("#9ccfd8", "CPU chart color"),
    memoryColor = h.field.string("#f6c177", "Memory chart color"),
    foreground = h.field.string("#f5f5f7", "Label color"),
    history = h.field.number(600, "Maximum samples retained"),
  },

  setup = function(ctx)
    local cpu, memory = 0, 0
    local memory_used, memory_total = 0, 0
    local cpu_history, memory_history = {}, {}
    local previous_total, previous_idle
    local blocks = { " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

    local function push(history, value)
      history[#history + 1] = value
      if #history > ctx.options.history then table.remove(history, 1) end
    end

    local function read_cpu()
      local file = io.open("/proc/stat", "r")
      if not file then return end
      local line = file:read("l")
      file:close()
      local values = {}
      for value in line:gmatch("%d+") do values[#values + 1] = tonumber(value) end
      local total = 0
      for _, value in ipairs(values) do total = total + value end
      local idle = (values[4] or 0) + (values[5] or 0)
      if previous_total and total > previous_total then
        cpu = math.max(0, math.min(1, 1 - (idle - previous_idle) / (total - previous_total)))
        push(cpu_history, cpu)
      end
      previous_total, previous_idle = total, idle
    end

    local function read_memory()
      local file = io.open("/proc/meminfo", "r")
      if not file then return end
      local available = 0
      for line in file:lines() do
        local name, value = line:match("^(%w+):%s+(%d+)")
        if name == "MemTotal" then memory_total = tonumber(value) * 1024 end
        if name == "MemAvailable" then available = tonumber(value) * 1024 end
      end
      file:close()
      memory_used = math.max(0, memory_total - available)
      memory = memory_total > 0 and memory_used / memory_total or 0
      push(memory_history, memory)
    end

    local function refresh()
      read_cpu()
      read_memory()
      ctx:update()
    end

    local function format_bytes(value)
      local gib = value / 1024 / 1024 / 1024
      return string.format("%.1f GiB", gib)
    end

    local function chart(history, width, height)
      width, height = math.max(1, width), math.max(1, height)
      local rows = {}
      local offset = #history - width
      for row = 1, height do
        local cells = {}
        local level = height - row
        for column = 1, width do
          local source = offset + column
          local value = source >= 1 and history[source] or 0
          local fill = math.max(0, math.min(1, value * height - level))
          cells[column] = blocks[math.floor(fill * 8 + 0.5) + 1]
        end
        rows[row] = table.concat(cells)
      end
      return table.concat(rows, "\n")
    end

    read_cpu()
    read_memory()
    ctx:every(ctx.options.refreshInterval, refresh)

    return function()
      local chart_height = math.max(1, math.floor((ctx.size.height - 2) / 2))
      return box {
        flexDirection = "column",
        alignItems = "flex-start",
        width = "100%",
        height = "100%",
        text {
          key = "cpu-label",
          fg = ctx.options.foreground,
          wrapMode = "none",
          string.format("CPU  %3d%%", math.floor(cpu * 100 + 0.5)),
        },
        text {
          key = "cpu-chart",
          width = ctx.size.width,
          height = chart_height,
          fg = ctx.options.cpuColor,
          wrapMode = "none",
          chart(cpu_history, ctx.size.width, chart_height),
        },
        text {
          key = "memory-label",
          fg = ctx.options.foreground,
          wrapMode = "none",
          string.format("MEM  %s / %s  %3d%%", format_bytes(memory_used), format_bytes(memory_total), math.floor(memory * 100 + 0.5)),
        },
        text {
          key = "memory-chart",
          width = ctx.size.width,
          height = chart_height,
          fg = ctx.options.memoryColor,
          wrapMode = "none",
          chart(memory_history, ctx.size.width, chart_height),
        },
      }
    end
  end,
}
