local h = require("haunt")
local box, text = h.ui.box, h.ui.text

return h.widget {
  title = "Calendar",
  options = {
    weekStartsMonday = h.field.boolean(true, "Start weeks on Monday"),
    foreground = h.field.string("#9696a6", "Day text"),
    heading = h.field.string("#c4a7e7", "Month and weekday text"),
    activeBackground = h.field.string("#40334f", "Current day background"),
    activeForeground = h.field.string("#f5f5f7", "Current day text"),
  },

  setup = function(ctx)
    local today = {}
    local months = {
      "January", "February", "March", "April", "May", "June",
      "July", "August", "September", "October", "November", "December",
    }

    local function refresh()
      local next_day = os.date("*t")
      if next_day.year ~= today.year or next_day.month ~= today.month or next_day.day ~= today.day then
        today = next_day
        ctx:update()
      end
    end

    refresh()
    ctx:every(60000, refresh)

    local function cell(day)
      local current = day == today.day
      return box {
        width = 4,
        height = 1,
        flexShrink = 0,
        alignItems = "flex-start",
        day and text {
          fg = current and ctx.options.activeForeground or ctx.options.foreground,
          backgroundColor = current and ctx.options.activeBackground or nil,
          wrapMode = "none",
          string.format("%02d", day),
        },
      }
    end

    return function()
      local first = os.date("*t", os.time { year = today.year, month = today.month, day = 1, hour = 12 })
      local days = os.date("*t", os.time { year = today.year, month = today.month + 1, day = 0, hour = 12 }).day
      local start = ctx.options.weekStartsMonday and 2 or 1
      local offset = (first.wday - start + 7) % 7
      local labels = ctx.options.weekStartsMonday
          and { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }
        or { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }

      local children = {
        box {
          key = "month",
          width = 28,
          height = 1,
          flexShrink = 0,
          alignItems = "center",
          text {
            fg = ctx.options.heading,
            wrapMode = "none",
            months[today.month],
          },
        },
        box {
          key = "weekdays",
          flexDirection = "row",
          flexShrink = 0,
          (function()
            local headers = {}
            for _, label in ipairs(labels) do
              headers[#headers + 1] = box {
                width = 4,
                height = 1,
                flexShrink = 0,
                text { fg = ctx.options.heading, wrapMode = "none", label },
              }
            end
            return headers
          end)(),
        },
      }

      local day = 1
      for week = 1, 6 do
        local cells = {}
        for weekday = 1, 7 do
          local position = (week - 1) * 7 + weekday - 1
          if position >= offset and day <= days then
            cells[#cells + 1] = cell(day)
            day = day + 1
          else
            cells[#cells + 1] = cell(nil)
          end
        end
        children[#children + 1] = box {
          key = "week-" .. week,
          flexDirection = "row",
          flexShrink = 0,
          cells,
        }
        if day > days then break end
      end

      return box {
        flexDirection = "column",
        alignItems = "center",
        justifyContent = "center",
        width = "100%",
        height = "100%",
        gap = 1,
        children,
      }
    end
  end,
}
