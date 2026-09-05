# Writing a Haunt widget

The first native slice embeds Lua 5.4.9. Widgets use ordinary Lua modules and
OpenTUI-backed box/text primitives and ASCII fonts. See `widgets/clock.lua` for a
complete example.

## Setup, render, update

```lua
local h = require("haunt")

return h.widget {
  title = "Counter",
  options = { label = h.field.string("Ticks") },
  setup = function(ctx)
    local count = 0
    ctx:every(1000, function()
      count = count + 1
      ctx:update()
    end)

    return function()
      return h.ui.text { ctx.options.label .. ": " .. count }
    end
  end,
}
```

Setup runs once for each instance/revision and returns a render function. Local
variables survive renders. Assigning a variable does not schedule a render;
`ctx:update()` does. Multiple requests before a host flush are coalesced. Changing
the widget's allocation updates `ctx.size.width` and `ctx.size.height` and renders
with the new dimensions.

Render describes UI. Start timers and other work in setup or event handlers.
Calling `ctx:update()` during render is an error.

## Options

A layout instance's `options` object is checked against the widget's schema.
Defaults are applied before setup. Unknown options and invalid values produce
widget-local errors.

- `h.field.string(default, description?)`
- `h.field.number(default, description?)`
- `h.field.boolean(default, description?)`
- `h.field.enum(values, default, description?)`

Use `ctx.options` to read the resulting plain Lua table. The clock supports
`timezone` (`"local"` or `"UTC"`), `format` (default `%I:%M:%S %p`), `font` (default
`tiny`), `color`, and `showDate` (default `false`). The font is a fixed per-instance
choice: resizing never substitutes another font or a plain-text presentation.

## Timers and lifecycle

- `ctx:every(milliseconds, callback)` creates a scoped repeating timer and returns
  a cancellation function. Missed ticks coalesce rather than running a catch-up
  loop. A failing callback stops its timer and reports its error.
- `ctx:on_cleanup(callback)` registers cleanup. Callbacks run in reverse order on
  replacement/removal, including when a partially initialized candidate fails.
- `ctx:retain(key, initial)` returns explicitly retained plain data. Use a table for
  mutable state. A reload receives a copy, so a failing candidate cannot mutate the
  working revision's retained state. This currently preserves data across code
  reloads within the running process.
- `ctx:log(...)` captures a diagnostic value for the instance. Widget `print` calls
  use the same capture rather than writing into the terminal UI.

The host owns timers. Replacing a widget disposes the previous scope; callbacks from
it cannot request further UI updates. The initial native call boundary also has an
execution-time guard for accidental runaway Lua loops. Blocking operations and
native calls need separate scheduling; the design's asynchronous filesystem/HTTP
services are a subsequent framework milestone.

## UI constructors

`h.ui.box { ... }` and `h.ui.text { ... }` return node descriptions. Named fields
are properties. Numeric fields are ordered children; nested child arrays flatten,
and `false`/`nil` children are omitted. Child order is numeric even if there are
holes. Use stable `key` values for reorderable children.

```lua
local box, text = h.ui.box, h.ui.text

return box {
  flexDirection = "column",
  padding = 1,
  gap = 1,
  backgroundColor = "#16161e",

  text { key = "title", fg = "#c4a7e7", "My widget" },
  text { key = "value", attributes = h.attributes.bold, "42" },
}
```

The first binding supports:

- Dimensions: `width`, `height`, `minWidth`, `minHeight`, `maxWidth`, `maxHeight`.
- Flexbox: `flexDirection`, `flexGrow`, `flexShrink`, `flexBasis`, `flexWrap`,
  `alignItems`, `alignSelf`, `justifyContent`, `gap`, `rowGap`, `columnGap`.
- Spacing: `padding`/`margin`, their `X`/`Y` variants, and individual sides.
- Position: `position` (`relative`/`absolute`), `top`, `right`, `bottom`, `left`.
- Clipping: `overflow` (`visible`/`hidden`). Widget boundaries always clip content.
- Styling: `fg`, `bg`/`backgroundColor`, `border`, `borderColor`, `borderStyle`
  (`single`/`rounded`/`double`), and `attributes`.
- Text: string/number children or `content`, and `wrapMode` (`none`/`word`/`char`).
- Identity: `key`.
- Mouse handlers: `onMouseDown`, `onMouseUp`, `onMouseMove`. Events have zero-based
  screen `x`/`y` and `button` (`0` is left). Layout-edit mode captures these gestures
  for moving/resizing; normal mode routes them to widget content.
- `onKeyDown` receives printable/control keys on the selected widget (the first
  handler in its tree). Events have `name`, `code`, and `ctrl`. The host reserves
  its quit/reload/selection/layout-edit keys. Individual element keyboard focus is a later
  addition; mouse hit testing already targets the deepest applicable node.

Dimensions use terminal columns/rows, percentages where supported, or `auto` for
intrinsic dimensions. The root occupies the widget's allocated content rectangle.
Colors accept `#RGB`, `#RRGGBB`, and `#RRGGBBAA`. Attribute constants are
`h.attributes.bold`, `dim`, `italic`, and `underline`; combine flags with Lua's `|`.

Yoga calculates layout; OpenTUI measures and draws text in display cells, including
Unicode. Existing keyed nodes and text buffers are retained between updates.
Unsupported properties fail with a diagnostic rather than being silently ignored.

## ASCII fonts

`h.ui.ascii_font` renders the same glyph assets as OpenTUI's ASCIIFont component,
originally sourced from [cfonts](https://github.com/dominikwilkowski/cfonts). The
assets are embedded in Haunt from its pinned OpenTUI dependency.

```lua
return h.ui.ascii_font {
  text = "4:07",
  font = "block",
  color = "#c4a7e7",
}
```

Fonts are `tiny`, `block`, `shade`, `slick`, `huge`, `grid`, and `pallet`. Each has
intrinsic terminal-cell dimensions; choose a font rather than specifying a pixel
font size. Other layout properties and stable keys work as on a text primitive.
The initial binding applies a single foreground color to the font's segments.

`h.ascii.measure { text = "4:07", font = "block" }` returns `{ width, height }`.
Use those measurements and `ctx.size` for sizing and alignment.
`h.ascii.render` returns the same dimensions plus the rendered `content` string.

## Host presentation

The normal canvas is content-only. The entire terminal, including row zero and the
last row, belongs to the grid. `ctx.size` is the full widget allocation unless the
layout enables `appearance.borders`, in which case the border consumes one cell
on each side. Widget `title` is metadata and does not produce a title bar.

Press `e` to enter layout-edit mode. Temporary outlines overlay the existing
content without changing its size; drag inside a tile to move or its edges to
resize in individual terminal cells. Saved edits use the current viewport as the
reference grid, preserving exact cell placement when reopened at the same size.
Press `b` while editing to persistently toggle borders for the dashboard.
Escape cancels a gesture or exits editing. Widget code can also draw internal
borders using ordinary box primitives.

## Local modules and hot reload

`require("haunt")` loads the SDK. Other module names resolve relative to the widget
source directory (`?.lua` and `?/init.lua`) and are cached per revision. Standard Lua
libraries remain available. Each instance has its own top-level global environment.

The host checks widget files and successfully loaded local dependencies for changes
every 500 ms, including atomic editor replacements. Press `r` to reload immediately.
A candidate must pass loading, options validation, setup, and its first render
before it replaces the working revision. Invalid edits preserve the prior widget
and show a small error marker; enter layout-edit mode to read the diagnostic.
Retained data survives successful replacement; ordinary
captured locals initialize again.
