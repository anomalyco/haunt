local h = require("haunt")
local box, text = h.ui.box, h.ui.text

return h.widget {
  title = "Media controls",
  options = {
    refreshInterval = h.field.number(1000, "Milliseconds between media refreshes"),
    foreground = h.field.string("#f5f5f7", "Primary text and controls"),
    muted = h.field.string("#9696a6", "Secondary text"),
    controlBackground = h.field.string("#272733", "Control background"),
    activeBackground = h.field.string("#40334f", "Active control background"),
  },

  setup = function(ctx)
    local status = "Stopped"
    local artist, title = "", "Nothing playing"

    local function refresh()
      local status_output, status_code = ctx:command { "playerctl", "status" }
      if status_code == 0 then
        status = status_output:gsub("%s+$", "")
        local metadata, metadata_code = ctx:command {
          "playerctl", "metadata", "--format", "{{artist}}\t{{title}}",
        }
        if metadata_code == 0 then
          artist, title = metadata:match("^([^\t]*)\t([^\r\n]*)")
          artist = artist or ""
          title = title ~= "" and title or "Unknown track"
        end
      else
        status, artist, title = "Stopped", "", "Nothing playing"
      end
      ctx:update()
    end

    local function action(name)
      return function()
        ctx:command { "playerctl", name }
        refresh()
      end
    end

    local function control(label, name, active)
      return box {
        key = name,
        height = 1,
        paddingX = 1,
        flexShrink = 0,
        backgroundColor = active and ctx.options.activeBackground or ctx.options.controlBackground,
        onMouseDown = action(name),
        text { fg = ctx.options.foreground, wrapMode = "none", label },
      }
    end

    refresh()
    ctx:every(ctx.options.refreshInterval, refresh)

    return function()
      return box {
        flexDirection = "column",
        alignItems = "flex-start",
        width = "100%",
        height = "100%",
        text { key = "title", fg = ctx.options.foreground, wrapMode = "none", title },
        artist ~= "" and text { key = "artist", fg = ctx.options.muted, wrapMode = "none", artist },
        box {
          key = "controls",
          flexDirection = "row",
          flexShrink = 0,
          gap = 1,
          control("Play", "play", status == "Playing"),
          control("Pause", "pause", status == "Paused"),
          control("Next", "next", false),
        },
      }
    end
  end,
}
