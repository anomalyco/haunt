local h = require("haunt")
local box, text, ascii = h.ui.box, h.ui.text, h.ui.ascii_font

return h.widget {
  title = "Clock",
  options = {
    timezone = h.field.enum({ "local", "UTC" }, "local", "Time zone"),
    format = h.field.string("%I:%M:%S %p", "Lua os.date time format"),
    font = h.field.enum({ "tiny", "block", "shade", "slick", "huge", "grid", "pallet" }, "tiny", "OpenTUI ASCII font"),
    color = h.field.string("#c4a7e7", "Clock color"),
    showDate = h.field.boolean(false, "Show the calendar date"),
  },

  setup = function(ctx)
    local time, date = "", ""

    local function tick()
      local prefix = ctx.options.timezone == "UTC" and "!" or ""
      local next_time = os.date(prefix .. ctx.options.format):gsub("^0", "")
      local next_date = ctx.options.showDate and os.date(prefix .. "%A, %d %B %Y") or ""
      if next_time ~= time or next_date ~= date then
        time, date = next_time, next_date
        ctx:update()
      end
    end

    tick()
    ctx:every(1000, tick)

    return function()
      local digits, period = time:match("^(.-)%s+([AP]M)$")
      digits = digits or time
      local font = ctx.options.font
      local size = h.ascii.measure { text = digits, font = font }
      local width = size.width + (period and 3 or 0)
      local height = size.height + (ctx.options.showDate and 2 or 0)

      return box {
        flexDirection = "column",
        justifyContent = height <= ctx.size.height and "center" or "flex-start",
        alignItems = width <= ctx.size.width and "center" or "flex-start",
        gap = 1,

        box {
          key = "time",
          width = width,
          height = size.height,
          flexDirection = "row",
          alignItems = "flex-end",
          flexShrink = 0,
          gap = 1,
          ascii { key = "digits", text = digits, font = font, color = ctx.options.color },
          period and text { key = "period", fg = ctx.options.color, wrapMode = "none", period },
        },
        ctx.options.showDate and text { key = "date", fg = "#9696a6", wrapMode = "none", date },
      }
    end
  end,
}
