local h = require("haunt")
local box, text = h.ui.box, h.ui.text

return h.widget {
  title = "Audio outputs",
  options = {
    refreshInterval = h.field.number(2000, "Milliseconds between output refreshes"),
    activeBackground = h.field.string("#40334f", "Selected output background"),
    activeForeground = h.field.string("#f5f5f7", "Selected output text"),
    foreground = h.field.string("#9696a6", "Unselected output text"),
  },

  setup = function(ctx)
    local outputs = {}
    local error_message

    local function refresh()
      local output, status = ctx:command { "wpctl", "status" }
      if status ~= 0 then
        error_message = output ~= "" and output or "Unable to read PipeWire outputs"
        ctx:update()
        return
      end

      local next_outputs = {}
      local in_sinks = false
      for line in output:gmatch("[^\r\n]+") do
        if line:match("Sinks:%s*$") then
          in_sinks = true
        elseif in_sinks and line:match("Sources:%s*$") then
          break
        elseif in_sinks then
          local selected, id, label = line:match("│%s+([%* ]?)%s*(%d+)%.%s+(.+)%s+%[vol:")
          if id then
            next_outputs[#next_outputs + 1] = {
              id = tonumber(id),
              label = label:gsub("%s+$", ""),
              selected = selected == "*",
            }
          end
        end
      end
      outputs, error_message = next_outputs, nil
      ctx:update()
    end

    local function select_output(id)
      return function()
        local output, status = ctx:command { "wpctl", "set-default", tostring(id) }
        if status ~= 0 then error_message = output ~= "" and output or "Unable to select output" end
        refresh()
      end
    end

    refresh()
    ctx:every(ctx.options.refreshInterval, refresh)

    return function()
      local rows = {}
      for _, output in ipairs(outputs) do
        rows[#rows + 1] = box {
          key = tostring(output.id),
          width = "100%",
          height = 1,
          flexShrink = 0,
          paddingLeft = 1,
          backgroundColor = output.selected and ctx.options.activeBackground or "#121217",
          onMouseDown = select_output(output.id),
          text {
            fg = output.selected and ctx.options.activeForeground or ctx.options.foreground,
            wrapMode = "none",
            output.label,
          },
        }
      end

      return box {
        flexDirection = "column",
        alignItems = "flex-start",
        width = "100%",
        height = "100%",
        error_message and text { key = "error", fg = "#eb6f92", error_message },
        rows,
      }
    end
  end,
}
