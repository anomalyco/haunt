local h = require("haunt")
local box, text, ascii = h.ui.box, h.ui.text, h.ui.ascii_font

return h.widget {
  title = "Clock",
  options = {
    timezone = h.field.enum({ "local", "UTC" }, "local", "Time zone"),
    format = h.field.string("%I:%M %p", "Lua os.date time format"),
    font = h.field.enum({ "auto", "tiny", "block", "shade", "slick", "huge", "grid", "pallet" }, "auto", "OpenTUI ASCII font"),
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
      if font == "auto" then
        font = "tiny"
        local size = h.ascii.measure { text = digits, font = "block" }
        if size.width + (period and 3 or 0) <= ctx.size.width and size.height <= ctx.size.height then
          font = "block"
        end
      end
      local size = h.ascii.measure { text = digits, font = font }
      local fits = size.width + (period and 3 or 0) <= ctx.size.width and size.height <= ctx.size.height

      return box {
        flexDirection = "column",
        justifyContent = "center",
        alignItems = "center",
        gap = 1,

        fits and box {
          key = "time",
          flexDirection = "row",
          alignItems = "flex-end",
          flexShrink = 0,
          gap = 1,
          ascii { text = digits, font = font, color = ctx.options.color },
          period and text { fg = ctx.options.color, wrapMode = "none", period },
        } or text { key = "time-compact", fg = ctx.options.color, wrapMode = "none", time },
        ctx.options.showDate and ctx.size.height >= size.height + 2 and ctx.size.width >= 24
          and text { key = "date", fg = "#9696a6", wrapMode = "none", date },
      }
    end
  end,
}
