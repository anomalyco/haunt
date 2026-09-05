# Haunt

Status: accepted product design baseline, 2026-09-05.

The first native clock prototype is now implemented. See [README.md](README.md)
for running and build commands, and [the Lua API](docs/lua.md) for the
currently implemented framework surface. The broader milestones below remain the
product direction.

Haunt is an Anomaly project: a full-screen terminal workspace for programmable
widgets. Users describe widgets in natural language, then place, configure, and
use them in saved dashboards. A terminal can itself be a widget; the product's
primary unit is a widget with its own content and interaction.

## Core decisions

- A stable, directly editable grid. Users click, drag, and resize widgets.
- All widget regions fit within one terminal viewport. Workspace scrolling is
  deferred.
- The workspace is content-only in normal and edit modes. Host frames, application
  headers, widget title bars, and footer/help text are absent. Edit-mode hover uses
  a low-opacity white overlay; brighter one-cell edge strips act as resize handles.
- Data updates preserve widget positions and allocated sizes. Spatial memory is
  a core part of the experience.
- Layouts are file-backed, serializable, and switchable. Widget instances have
  their own options and stable identities.
- Widgets are authored in plain Lua using compact, declarative constructors.
- UI updates are explicit, following the general Remix 3 setup/render model.
- OpenTUI provides the rendering foundation and the semantics of the UI primitives.
  Flexbox is used inside widgets; the workspace has a direct grid-placement model.
- Filesystem access, HTTP, subprocesses, and other general-purpose operations are
  part of the widget runtime.
- Hot reload, reliable diagnostics, and efficient operation on low-spec machines
  are central requirements.

## Workspace and sizing

The workspace owns every widget instance's position and allocation. Each widget
receives a content rectangle in terminal columns and rows and controls its internal
presentation through the OpenTUI primitive API. The usable rectangle is the entire
allocation. Editing overlays preserve content dimensions. The grid uses the full
viewport, including the first and last terminal rows.

Direct manipulation snaps to individual terminal cells: one column horizontally
and one row vertically. Gesture coordinates and collision checks use rendered cell
rectangles, independently of the saved layout's grid density.

The layout stores integer positions and spans against a reference grid. Older
coarse grids are resolved against the viewport as before. When an edit is committed,
Haunt records the displayed cell rectangles and current terminal dimensions as the
new reference grid, preserving the exact edit and the other widgets' displayed
placement. Canceling a gesture or failing to save preserves the original layout.
Resizing the terminal resolves shared track edges proportionally from that saved
reference, with consistent cell rounding.

Widgets can provide minimum usable dimensions and preferred initial dimensions.
Basic text/box measurement should come from the layout machinery. Preferences
inform initial placement; the user's allocation governs subsequent operation.
Two instances of the same widget can have different sizes.

Additional space can expose more rows or columns, reduce wrapping, expand a chart,
or enable a different arrangement of information. Compact widgets can remain close
to their useful natural size. Normal content changes use the established rectangle.

On terminal resize, retain logical placement and recompute physical bounds. Widget
logic receives new bounds and requests/runs the appropriate render without
restarting its background work. The exact minimum-terminal-size and compact-view
policy remains an implementation design question.

### Direct manipulation

The interaction target is immediate, discoverable mouse-based editing:

1. Click a widget to focus/select it while preserving its content's own interactions.
2. Enter layout-edit mode (`e`) and hover to brighten a widget with a white overlay.
3. Drag inside the widget to move it. Hover an edge for a brighter one-cell-wide
   resize handle; dragging a corner resizes both dimensions.
4. Preview the actual content at the cell-aligned destination; tint invalid
   destinations red.
5. Commit a valid placement on release; Escape cancels the gesture or exits editing.
6. Press `D` to delete the highlighted or dragged widget instance.
7. Save completed moves, resizes, and deletions automatically.

The host owns drag/resize input capture so a gesture can continue across widget
boundaries. Widget code handles content-area input. Moving and resizing preserve
the running widget's identity and state.

The workspace enforces bounds and non-overlap. Content changes do not trigger
automatic repacking. The occupied-cell interaction, including whether a drop
previews a swap, still needs to be finalized. Empty grid space is allowed.

### Edit-mode presentation

The host has no border setting or edit outlines. Hovering places an absolute white
layer at low opacity over the full widget, brightening its text and background
without changing glyphs, dimensions, or widget state. Hovered edges get an additional
brighter one-cell strip. A corner combines its adjacent strips without double
applying opacity to the corner cell.

Hover redraws occur when the highlighted widget or edge changes; movement within
one region does not continually redraw an otherwise idle dashboard. Gesture
previews reuse these overlays and move/resize the actual content.

Errors use an affected widget's marker/hover diagnostic. Deleting an instance
disposes its resource scope and native nodes after the layout is saved. A failed
save preserves the instance. Legacy `appearance` metadata is discarded when loading
older layouts and omitted from new saves.

## Saved layouts and widget instances

Use versioned JSON layout documents. A document contains a stable layout ID, a
display name, grid dimensions, and configured widget instances. Each instance has:

- A stable instance ID.
- A reference to its Lua widget module/package.
- A grid rectangle.
- JSON-serializable options.

Illustrative schema using a coarse reference grid:

```json
{
  "version": 1,
  "id": "work",
  "name": "Work",
  "grid": { "columns": 12, "rows": 12 },
  "widgets": [
    {
      "id": "pull-requests",
      "widget": "./widgets/github.lua",
      "rect": { "x": 0, "y": 0, "width": 8, "height": 12 },
      "options": { "repository": "anomalyco/haunt" }
    },
    {
      "id": "clock",
      "widget": "./widgets/clock.lua",
      "rect": { "x": 8, "y": 0, "width": 4, "height": 3 },
      "options": { "timezone": "UTC" }
    }
  ]
}
```

Coordinates are zero-based and spans are positive integers. Relative widget paths
resolve from the layout file's directory. Validate schema versions, identities,
options, bounds, and overlap before applying an edited layout.

Widget source is separate from the layout document. Multiple instances can share
an implementation while using different options, such as repository or timezone.
A widget declares an options schema with types, defaults, and descriptions; the
host exposes validated values as ordinary Lua data through `ctx.options`.

Persist explicitly retained runtime state separately, keyed by layout and widget
instance identity. Layout files describe arrangement and configuration. Duplicating
a dashboard creates a new layout identity.

### Opening, switching, and live editing

- Open a layout by path, such as `haunt ./work.json`, or through an in-app picker.
- Save completed layout and options edits with atomic file replacement. Pointer
  movement updates a preview rather than repeatedly saving to disk.
- Watch layout files for external and agent edits. Keep the working layout when a
  candidate is invalid and expose source-located diagnostics.
- Reconcile valid edits by instance ID. Placement-only changes update geometry;
  options or implementation changes use the widget reload lifecycle.
- Coordinate autosaves with external file revisions to avoid overwriting newer
  edits with stale UI state.
- Run the active layout's widgets. On switching, save explicitly retained state,
  dispose the previous layout's scoped work, and load the selected layout.

Default discovery paths and startup layout selection remain to be specified.

## Lua widget framework

The framework has a small, explicit model: setup, render, update, and cleanup.
Simple widgets can be single Lua modules; larger widgets compose modules and
ordinary Lua functions.

### UI primitives and syntax

Expose low-level OpenTUI concepts, starting with boxes, text, styling, layout, and
input/focus handling. Preserve upstream property names and semantics where
practical, including dimensions, positioning, Flexbox, spacing, borders, colors,
text attributes, wrapping, and clipping.

Named constructor fields are properties; sequential entries are ordered children.
The host normalizes these tables into its node representation. Text constructors
can accept string children. Conditional and nested child-collection conventions
must be documented consistently, including Lua array behavior around `nil`.

Reusable controls are Lua compositions of those primitives. For example, a button
can combine a styled box, text, and mouse/keyboard activation. Additional native
capabilities can be exposed through the same binding layer.

Plain Lua keeps parsing, formatting, annotations, and error locations compatible
with standard tooling. The internal node representation remains independent of
authoring syntax.

Illustrative SDK shape; exact helper signatures will be validated in the prototype:

```lua
local h = require("haunt")
local box, text = h.ui.box, h.ui.text

return h.widget {
  options = { directory = h.field.path("~/Downloads") },

  setup = function(ctx)
    local files = {}

    ctx.fs:watch(ctx.options.directory, function()
      files = ctx.fs:list(ctx.options.directory)
      ctx:update()
    end, { initial = true })

    return function()
      return box {
        flexDirection = "column",
        padding = 1,

        text { fg = "#ffffff", "Downloads" },
        text { fg = "#999999", #files .. " files" },
      }
    end
  end,
}
```

### Explicit update loop

```text
input / timer / completed I/O
  -> change ordinary Lua values
  -> ctx:update()
  -> enqueue the component for the next UI flush
  -> run its render function
  -> reconcile its retained UI subtree
  -> OpenTUI renders and emits changed terminal cells
```

- Setup runs once per instance/revision and returns the render function. Closure
  variables survive ordinary renders.
- Assignments have ordinary Lua semantics. Updates are explicitly requested;
  rendering does not depend on tracked reads or reactive proxies.
- Coalesce repeated updates and avoid duplicate ancestor/descendant work.
- Retain nodes and use stable keys to preserve identity during reconciliation.
- Mounting, relevant size/theme changes, and prop changes are host update triggers.
- Render functions describe UI; event handlers and scoped tasks own background work.
- Provide an explicit post-commit facility for actions such as focusing a new input.
- Idle widgets do not continually run their render functions. Expensive renders
  still need appropriate component boundaries and bounded content.

UI updates, data refresh, and code reload are distinct operations. State that
survives code replacement or layout switching is explicitly retained/serialized;
captured locals are not automatically migrated. Retained data does not gain implicit
rendering behavior.

### General-purpose services and lifecycle

The SDK supplies asynchronous filesystem operations/watchers, HTTP and streaming,
subprocesses, timers, structured data helpers, configuration, state, and logging.
Widgets can implement arbitrary application logic using these primitives, Lua
modules, and external programs.

Each widget instance has a resource scope. Managed watchers, timers, subscriptions,
subprocesses, and requests are canceled or disposed on reload/removal. Resources
created outside this scope require explicit cleanup by widget code.

SDK I/O yields managed Lua coroutines while native services perform the work.
Coroutines alone do not make blocking calls asynchronous. CPU-heavy work needs a
worker/subprocess path; scheduling budgets and error containment must keep widget
work from monopolizing the UI loop.

Shared infrastructure limits per-widget overhead. Per-instance environments and
scopes provide ownership boundaries; process isolation is a separate capability.

## Prompt authoring and hot reload

Users describe a new widget or a change to an existing one. A coding agent receives
the SDK contract, examples, current source, and relevant diagnostics, then produces
edits to a candidate revision. Ordinary widget execution runs as code; runtime AI
calls are available when the widget's functionality needs them.

The reload pipeline must:

1. Watch source and affected dependencies and validate a candidate revision.
2. Keep the working widget visible while the candidate is prepared.
3. Preserve layout identity, options, and compatible explicitly retained state.
4. Dispose old scoped work and prevent stale callbacks/results from reaching the
   replacement. Avoid overlapping active copies of background effects.
5. Activate the replacement and provide recovery to the prior revision on failure
   where the runtime can contain the error.
6. Keep diagnostics local to the affected widget and available to the editing agent.

Invalid source before activation keeps the existing revision. Incompatible state
requires migration or an explicit reset. Reload cannot undo completed filesystem or
API effects. Unaffected widgets and workspace controls remain mounted.

Option changes use this lifecycle so option-dependent watchers and requests are
recreated correctly. The agent provider/integration is still to be selected.

## Native architecture and efficiency

The working implementation target is a Zig host with embedded Lua and OpenTUI's
native core. The first integration spike must validate that target and pin the
compatible native dependencies, toolchain, and Lua implementation.

The host owns layout, identity, input routing, the renderer, scheduling, and native
services. Workspace geometry is resolved by the grid layer; each widget's internal
layout uses OpenTUI/Yoga.

OpenTUI's documented application-facing component packages are TypeScript. Native
source inspection during design found that JavaScript still owned the Renderable
tree and Yoga nodes, while the native API supplied rendering, buffers, text,
measurement, and preliminary Yoga access. Haunt needs a native tree/primitive/event
adapter; integration is more than directly exposing existing TypeScript classes.

Efficiency goals:

- Share the renderer, event loop, and runtime infrastructure.
- Use scoped asynchronous work and bounded workers where appropriate.
- Prefer event-driven updates and configurable polling; idle widgets should sleep.
- Reconcile requested UI work and let native rendering minimize terminal output.
- Measure cold start, idle memory/CPU, incremental widget cost, and reload
  latency/peak memory on representative low-spec hardware.

Target hardware and numeric performance budgets remain open. Native code alone
does not establish that these goals have been met.

## First implementation milestone

Validate an end-to-end native slice:

1. Render two Lua widgets through OpenTUI with explicit updates and working input.
2. Move and resize their grid allocations using the mouse.
3. Exercise filesystem watching and API polling through scoped asynchronous services.
4. Edit widget UI/logic while running, including invalid revisions; verify recovery,
   compatible state retention, and resource cleanup.
5. Save/reopen a layout, instantiate one widget with different options, and switch
   between two layouts.
6. Measure the native slice's idle footprint and reload behavior.

Implementation details still to resolve include initial placement defaults, occupied-cell
gestures, minimum-terminal-size handling, initial platform targets, the Lua/runtime
versions, dependency packaging, precise SDK signatures, and the agent integration.

## References

- [Mainstream widget systems](docs/widget-systems.md): Apple, Android, Windows,
  Grafana, and Rainmeter behaviors and sources.
- [Remix component model](https://guides.remix.run/rendering-ui/) and
  [scheduler](https://github.com/remix-run/remix/blob/main/packages/ui/src/runtime/scheduler.ts):
  setup/render separation and explicit batched updates.
- [OpenTUI layout](https://opentui.com/docs/core-concepts/layout/),
  [native renderable](https://github.com/anomalyco/opentui/blob/main/packages/native/src/native-renderable.zig),
  and [Zig module](https://github.com/anomalyco/opentui/blob/main/packages/native/src/opentui.zig).
- [Design discussion](docs/design-discussion.md): earlier options and reasoning.
