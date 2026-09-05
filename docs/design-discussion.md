# Haunt design discussion

Historical discussion notes, captured on 2026-09-05. The current design baseline is
in [DESIGN.md](../DESIGN.md).

## Concept

Haunt is an Anomaly project: a full-screen terminal workspace for widgets.
Users can load different widgets, resize them, and arrange them on a grid to suit
their workspace. The primary unit is a widget, with its own content and interaction.
A terminal could be one kind of widget; terminal multiplexing is not the core
product model.

## Direction established so far

- Name: **Haunt**.
- Full-screen terminal interface.
- Support loading different widgets.
- Let users resize and rearrange widgets interactively on a grid.
- Keep widget placement stable so users consistently know where to look.
- Keep every widget visible within one terminal screen in the initial version;
  workspace scrolling may be considered later.
- Dashboards/layouts must serialize to files that save their arrangement.
- Support multiple saved layouts and opening/switching between them.
- Widget instances accept options so the same widget code can serve different
  configurations and layouts.
- Build on OpenTUI.
- Users should be able to create and change their own widgets by prompting.
- Widgets support general-purpose logic, including filesystem operations and API
  calls, alongside their UI.
- Hot reload and a polished development experience are core requirements.
- Efficient operation on low-spec machines is a core requirement. Target hardware
  and concrete memory/CPU budgets are still to be defined.
- Start the widget UI surface with low-level OpenTUI primitives, styling, and input
  handling. Higher-level controls can be composed from those primitives in Lua.
- Author widgets in plain Lua with a compact constructor API. Keep the internal
  node representation independent of authoring syntax.

## Workspace layout

Decision: a stable, user-arrangeable grid contained within one terminal viewport.

- All widget regions are visible together. The initial workspace does not scroll;
  scrolling is a possible later consideration.
- Users explicitly move and resize widgets according to the grid structure.
- Ordinary data updates preserve each widget's allocated position and size. The
  workspace should support spatial memory: users know where to look consistently.
- Grid granularity, track sizing, collision handling, and behavior when terminal
  dimensions change remain to be designed.

### Mainstream widget research

See [Mainstream widget systems](widget-systems.md) for a comparison of Apple,
Android, Windows Widgets, Grafana, and Rainmeter, with primary sources.

The recurring OS/dashboard pattern is host-controlled placement and allocated
size, plus provider-defined contents, size support, and per-instance options.
Android provides particularly useful resize constraints; Grafana and Rainmeter
provide direct prior art for saved layouts and instance configuration. Rainmeter
also embeds Lua for scriptable widget behavior.

The research-informed recommendation is direct grid placement at the workspace
level, with OpenTUI/Yoga handling each widget's internal layout. A nested Flexbox
workspace remains a candidate if hierarchical divider-based arrangement is desired;
the engine's availability alone does not establish that interaction model. This
recommendation does not finalize the grid representation or sizing rules.

### Size ownership (proposal)

- The workspace layout owns each widget instance's final position and allocated
  rectangle. Users change that allocation by arranging/resizing the workspace.
- A widget may advertise a minimum usable size and a preferred initial size; these
  are constraints/hints rather than a right to resize the workspace. Minimum and
  preferred dimensions should be expressed in terminal columns/rows so they remain
  meaningful across different workspace grids.
- Layout state stores per-instance placement and size. Two instances of the same
  widget can receive different allocations.
- The widget fills its assigned content rectangle and controls its internal layout
  through the OpenTUI primitive API. It receives current bounds, independently of
  how the workspace computed them. Host chrome is accounted for before exposing
  the usable content bounds.
- Resizing changes bounds and schedules a render without re-running setup or
  replacing the widget's running background work. Content can wrap, scroll, or
  change presentation according to available space.
- Content changes do not automatically resize surrounding widgets. How to handle a
  terminal too small to meet all minimum sizes is still an open design question.

### Workspace structure (models considered)

**Flat dashboard grid:** a workspace defines grid tracks; each widget instance has
a row, column, and row/column span. Users can manipulate placements directly without
first constructing a hierarchy. Grid sizing and collision behavior need explicit
rules. This fits direct placement and resizing of independent widgets.

**Nested rows/columns:** a tree divides available space into regions, with widgets
in the leaves. Sizes can be proportional or fixed; users move dividers to redistribute
space. This naturally supports related groups and dense, space-filling layouts,
but moving a widget between groups changes tree structure and needs a clear UX.

**Masonry:** a workspace supplies column widths (and possibly column spans), while
widgets report natural heights at those widths. The host packs the resulting
rectangles. This suits compact, content-sized information widgets. Allowing widgets
to independently choose both dimensions requires a more general packing policy and
still needs host bounds. Live height changes can shift neighboring widgets, and
packing does not guarantee everything fits in the terminal viewport.

The selected product behavior is a stable, manually arrangeable grid with all
widgets visible at once. Live content-driven masonry was not selected. The exact
grid representation is still open; candidate implementations must preserve this
stability and single-viewport constraint.

### Content-aware sizing (proposal)

The user raised masonry and observed that ordinary terminal text has fixed cell
dimensions. Extra allocation can expose more rows/columns, reduce wrapping, enable
side-by-side presentation, or expand charts; it does not automatically make a clock
or a short status label more useful. Natural-sized and expandable widgets should
both be accommodated.

- Treat preferred size as content-aware where appropriate. In particular, natural
  height depends on assigned width, text wrapping, and content; a single permanent
  width/height pair is insufficient for every widget.
- Aim to derive ordinary text/box measurement from the primitive layout machinery,
  with optional explicit size hints and growth preferences. Widget authors should
  not need custom responsive logic for basic wrapping and alignment.
- Content-aware initial sizing remains a proposal within the selected stable grid.
  Packing may help choose initial placements or perform an explicit arrange
  operation, provided all widget regions fit inside the terminal viewport.
- Users can override suggested sizes. Expandable widgets, such as logs and tables,
  can use larger allocations; compact widgets can remain close to natural size.
- New content uses the established allocation. Terminal resizing and what happens
  when an additional widget cannot fit remain open; the initial design must keep
  all widget regions visible without workspace scrolling.

### Flexbox-backed workspace (proposal)

The user suggested reusing OpenTUI's Flexbox support for the workspace. The current
candidate is an explicit nested row/column layout backed by Yoga, provided this
matches the intended grid interaction. Subsequent mainstream-widget research favors
direct grid placement as the initial workspace recommendation. Neither candidate
has yet been selected as the final representation.

- Internal nodes are rows or columns; leaves reference widget instance IDs. The
  root fills the available terminal viewport. Each child uses a saved fixed size
  or a share of remaining space.
- Example: a row with a wide repository widget and a narrower column containing
  a fixed-height clock above a growing log viewer.
- Resolve these containers through the native Yoga engine. Haunt still supplies
  the native tree/primitive adapter and event integration discussed below.
- Use explicit allocation policies and no wrapping for workspace containers.
  Growing allocations use a zero flex basis and saved growth weights so changing
  content does not change the division of space. Fixed regions retain their
  configured dimensions. Minimum-size/overflow handling remains necessary.
- Dragging a divider adjusts adjacent allocations. Rearranging swaps widget
  assignments or moves a widget within the layout tree, with a preview of the
  resulting structure. Stable instance IDs preserve widget runtime identity.
- Serialize the tree, fixed sizes, and proportions; terminal-cell rectangles are
  computed runtime results. Widget options stay attached to instances rather than
  to their slots.
- Nested Flexbox gives aligned rectangular regions but does not provide shared
  two-dimensional tracks across independently nested rows or arbitrary row/column
  spanning. A true dashboard grid would still need a grid-specific placement layer.
  The choice should follow the desired interaction model, not only engine reuse.

### Flat-grid candidate (proposal)

- Use a flat logical grid with a saved column count and row count per layout.
  Logical grid units are independent of terminal character cells. For example,
  a 12-by-12 grid could divide the available viewport proportionally; this is an
  illustrative size, not a finalized default.
- Store integer row/column coordinates and spans. Resolve shared track edges to
  terminal-cell boundaries deterministically so adjacent allocations agree on
  their edges. Layout resolution accounts for workspace chrome and any gaps.
- Moving into empty space previews and commits the new rectangle. Moving onto one
  occupied slot can preview a swap of the two allocations, provided both widgets
  fit their destination. A drop overlapping multiple occupants is invalid.
- Resizing stops at occupied cells, the viewport edge, or the widget's minimum
  usable size. Other widgets remain in place. Cascading pushes/automatic compaction
  are not the proposed initial interaction.
- If a new widget cannot fit, let the user make room or choose another layout.
  Adding it should not silently move or shrink the existing workspace.
- When the terminal resizes, retain logical coordinates/spans and recompute the
  physical rectangles. A widget can use a compact presentation where supported;
  otherwise show a local minimum-size indicator while preserving its slot/state.
- Below the physical size needed to show even the grid's widget regions, present
  a resize-required screen with the required terminal dimensions and preserve the
  saved arrangement. This is a proposed fallback for physically impossible sizes,
  rather than a change to the single-screen workspace model.

## Saved dashboards and widget options

Requirements: layouts are serializable files; users can keep multiple layouts and
open different ones; each widget instance can have its own options.

### File model (proposal)

Use a versioned JSON document containing a stable layout ID, a display name, a
layout definition, and widget instances. Each instance has a stable ID, a reference
to its widget code, and JSON-serializable options. The flat-grid candidate stores
grid rectangles; the Flexbox candidate stores a row/column tree with sizing rules
and leaf references to those IDs. Widget source remains a separate Lua module/package.
Relative source paths resolve from the layout file's directory.

Flat-grid illustration; the format, layout representation, and defaults
are not finalized:

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

Coordinates in this proposal are zero-based; widths/heights are positive integer
grid spans. Empty grid space is allowed. Validate IDs, bounds, and non-overlap.
Duplicating a layout creates a new layout identity so retained widget state can
remain independent.

### Widget options (proposal)

- A widget declares an options schema with field types, defaults, descriptions,
  and validation. Instance values live in the layout file; the host can use the
  schema for agent documentation and an options editor.
- Expose validated options as ordinary Lua data through `ctx.options`. Two instances
  of a clock can have different timezones; two repository widgets can target
  different repositories while sharing their implementation.
- Apply option edits through the affected widget's scoped reload/reinitialization
  lifecycle, preserving its layout identity and compatible explicitly retained
  state. This ensures file watchers, polling, and other option-dependent work use
  the new configuration and the old resources are disposed.
- Layout data describes the workspace. Persist runtime snapshots/caches separately,
  namespaced by layout and widget instance IDs; functions and live resources are
  recreated when loading rather than serialized into the layout file.

### Saving, opening, and live editing (proposal)

- Save completed moves/resizes and accepted option edits automatically, using
  atomic replacement. Drag previews should not write the file on every pointer
  event.
- Support opening a path (for example, `haunt ./work.json`) and an in-app layout
  picker. Discovery paths and default-layout selection remain to be chosen.
- Watch layout files for external/agent edits. Validate a candidate before applying
  it, retain the current working layout on invalid edits, and reconcile valid edits
  by instance ID. A placement-only edit updates geometry without restarting widget
  logic. Coordinate saves with external revisions so a stale UI snapshot does not
  silently overwrite newer file edits.
- Initially run only the active layout's widgets. Switching saves layout and
  explicitly retained state, disposes its scoped work, and loads the selected
  layout. This keeps inactive dashboards from accumulating background cost.

## Implementation language (under discussion)

The host language is undecided. Rust and Zig were the initial candidates.

Development will be AI-led: the assistant will write the implementation. Language
selection should account for reliable code generation and debugging as well as
OpenTUI integration effort.

The initial recommendation was Zig for a native host, keeping Haunt close to
OpenTUI's native implementation. Rust offers a broader application ecosystem, but
would require an integration boundary with OpenTUI's Zig core.

OpenTUI's documented application-facing packages use TypeScript, including its
React and Solid integrations. Using its native core from either Zig or Rust should
not be assumed to provide the same high-level component API. Inspection of the
current native source confirms that JavaScript still owns the Renderable tree and
Yoga nodes; `NativeRenderable` currently connects native measurement. The Zig
module exports rendering, buffers, text, and preliminary Yoga access. A native Lua
host therefore needs a tree/layout/event integration layer, even if its public
primitive API mirrors OpenTUI. The implementation effort remains to be validated.

TypeScript/Bun was proposed for prompt-authored widgets and hot reload because it
uses OpenTUI's application-facing packages directly. It remains an implementation
option, but its runtime footprint needs measurement against the low-spec target.
One JavaScript runtime per widget is not the proposed default.

The current alternative to investigate is a native Zig host with an embedded Lua
runtime for widget code. Lua also requires a runtime, but is designed for small,
embedded scripting integrations. Haunt would provide native UI bindings and
asynchronous filesystem, HTTP, and process services. This is additional framework
work: OpenTUI's TypeScript component layer would not automatically be available.
The host language and embedding details remain undecided. Plain Lua has been
selected for widget authoring.

The widget authoring language and loading model are separate decisions from the
host language.

## Efficiency (design direction)

- Share the renderer, event loop, and runtime infrastructure across widgets.
- Avoid an OS process or heavyweight runtime per widget by default. Use bounded
  workers or dedicated subprocesses where a workload needs them.
- Prefer event-driven updates, changed-region rendering, and configurable polling
  over continuously updating every widget.
- Keep expensive widget tasks off the UI loop. Resource ownership and cancellation
  must remain explicit across reloads.
- Measure cold start, idle memory/CPU, incremental cost per widget, and reload
  latency/peak memory on representative low-spec hardware before finalizing the
  runtime architecture. Native code alone does not guarantee these properties.

## Prompt-authored widgets (proposed architecture)

Interpretation to confirm: users describe a widget or a change in natural language,
and an agent creates or edits its executable source. Widgets may also use AI at
runtime, but ordinary rendering and operation do not require repeated model calls.

### Widget package

Each widget is a local package with a manifest, UI code targeting Haunt's OpenTUI
integration, optional background logic, and configuration/state schemas. Source
remains inspectable and editable. Multiple instances can use the same widget code
with separate state and configuration. Dependency changes should be resolved as
part of building a new widget revision.

Generated widget code is plain Lua. Provide a small Haunt SDK for lifecycle,
state, configuration, logging, and interaction with background work. Widgets need
general-purpose filesystem access, HTTP, subprocesses, and other integrations; the
SDK should not limit widgets to a catalog of predefined actions.

### Runtime

- Haunt owns layout, widget instance identity, focus, and the OpenTUI renderer.
- UI components run in the UI host and render within their assigned region.
- Share runtime infrastructure for widget logic by default, with per-instance
  state and resource scopes. Scheduling and error containment need to be designed;
  per-widget environments in a shared process do not provide process isolation.
- Background work uses asynchronous host services and, when needed, workers or
  subprocesses. A separate backend process for every widget was an earlier proposal
  and is being reconsidered to reduce per-widget overhead.
- A widget scope tracks managed timers, watchers, subscriptions, subprocesses, and
  cancellation signals so reload and removal can dispose of them. Resources created
  outside the scope still require explicit cleanup by widget code.

### Lua framework (proposal)

Lua is the widget-authoring language, with Haunt supplying the application services
around it. A simple widget can be a single Lua
module; larger widgets can compose modules and reusable UI functions.

Proposed framework surfaces:

- **UI:** declarative Lua tables exposing low-level OpenTUI primitives and their
  supported styling/layout properties. Start with boxes and text, plus input/focus
  handling, to establish the binding and update loop. Reusable components are Lua
  functions. Reconcile keyed descriptions against retained host nodes, preserving
  identity where possible. Bind additional OpenTUI capabilities as needed; a
  separate high-level Haunt control library is not a prerequisite.
- **State and configuration:** ordinary Lua variables and tables, with explicit
  `ctx:update()` calls to request UI updates. Persistence is opt-in through an
  explicit state retention/serialization contract; state mutation itself does not
  trigger rendering. Configuration adds schema validation, defaults, generated
  settings UI, and migrations. Render functions describe UI and do not initiate
  background effects. This supersedes the earlier reactive-state-cell proposal.
- **Services:** asynchronous filesystem access/watchers, HTTP and streaming,
  subprocesses, timers, and structured-data helpers. Integrations can be built with
  these primitives, pure Lua modules, and external programs.
- **Scheduling and lifecycle:** scoped callbacks run in managed coroutines. SDK I/O
  yields while native services do the work; coroutines themselves do not make
  blocking operations asynchronous. CPU-heavy jobs need an explicit worker or
  subprocess path. Callback execution budgets should be investigated to keep a
  runaway script from monopolizing the UI thread.
- **Development:** Lua language-server annotations, validated UI properties,
  concise reference docs, runnable examples, per-widget logs and source-located
  errors, plus diagnostics consumable by the authoring agent.

#### Initial UI scope

- Preserve OpenTUI property names and value semantics where practical: dimensions,
  relative/absolute positioning, Flexbox layout, spacing, borders, colors, text
  attributes, wrapping, and clipping. Supported properties should be documented
  and validated against the actual binding implementation.
- Provide mouse/keyboard events, focus routing, and geometry needed to implement
  custom interactive elements within a widget's assigned region.
- A button can be a Lua composition of a styled box, text, and activation handlers.
  The same composition mechanism should support more elaborate controls without
  requiring changes to the native host for each control.
- The initial work is the primitive adapter, explicit update/reconciliation loop,
  lifecycle, and general-purpose services. The earlier lists/forms/charts catalog
  describes possible compositions, not required built-in controls.

Illustrative API only, not an implemented or finalized contract:

```lua
local h = require("haunt")

return h.widget {
  options = { directory = h.field.path("~/Downloads") },

  setup = function(ctx)
    local files = {}

    ctx.fs:watch(ctx.options.directory, function()
      files = ctx.fs:list(ctx.options.directory)
      ctx:update()
    end, { initial = true })

    return function()
      local children = {}
      for _, file in ipairs(files) do
        children[#children + 1] = h.ui.text {
          key = file.path,
          content = file.name,
        }
      end

      return h.ui.box {
        key = "downloads",
        flexDirection = "column",
        width = "100%",
        height = "100%",
        overflow = "hidden",
        children = children,
      }
    end
  end,
}
```

In this sketch, the watcher callback runs as a scoped task; directory listing can
yield without blocking rendering. The watcher is disposed on reload/removal. The
local `files` variable survives ordinary UI updates through its closure. It is
repopulated after a code reload unless explicitly included in retained state.

#### UI authoring syntax (plain Lua selected)

The user wants a less verbose tree-construction syntax than the initial explicit
`children`/`content` tables. Syntax ergonomics are independent of the explicit
update model and native primitive surface.

Relevant prior art:

- Ben Visness's LuaX embeds JSX-like markup in Lua and transforms tags into Lua
  tables. It is a custom implementation for his website, useful as design prior
  art rather than an assumed production-ready Haunt dependency.
- `syarul/luax` is a separate Lua implementation inspired by that work, providing
  `.luax` loading, an HTML-oriented runtime, and a syntax-highlighting extension.
  Adopting its ideas for Haunt would require native UI node output and evaluation
  of its parser and tooling limitations.
- Lapis's HTML builder uses tag functions and nested callbacks in Lua/MoonScript.
  It demonstrates tree-shaped authoring with ordinary language control flow, though
  its output is HTML and its builder uses a custom function environment.
- Roblox's Roact/React Lua and Fusion demonstrate declarative UI construction in
  Lua/Luau. Their update/state models are separate from Haunt's proposed model;
  their APIs and dependencies are not assumed to be portable to this host.

One plain-Lua candidate uses named table fields for properties and sequential
entries for children, removing the explicit `children` wrapper. A text node can
accept string content as a sequential entry:

```lua
local ui = require("haunt.ui")
local box, text = ui.box, ui.text

return box {
  flexDirection = "column",
  padding = 1,
  border = true,

  text { fg = "#ffffff", "Downloads" },
  text { fg = "#999999", #files .. " files" },
}
```

This is valid Lua syntax; constructors would normalize it to the renderer's node
representation. Child order, nested child collections, and conditional children
need a documented convention, especially because `nil` creates holes in Lua arrays.

A JSX-like Lua extension could compile to the same node-construction API at source
load/hot-reload time. It would keep the Lua runtime and `ctx:update()` semantics,
while adding parser, formatting, editor integration, and source-location mapping
work. No syntax extension or external builder library has been selected.

Decision: start with plain Lua and a compact, consistent constructor API for
agent-led authoring. Exact constructor conventions remain to be finalized.

- Standard Lua parsing, formatting, language-server annotations, and direct source
  locations support a straightforward generate/load/diagnose/repair loop.
- LuaX's strongest advantages are visual hierarchy and markup familiarity, which
  remain useful for human review and may help agents on complex trees. Familiarity
  with JSX does not by itself establish reliability with a custom Lua/markup dialect.
- A syntax transform can preserve the same Lua execution model, so rendering
  performance is not the main discriminator. Parsing adds load/reload work; the
  larger cost is maintaining the transform, diagnostics, and tooling.
- Prioritize precise SDK contracts, examples, validation, and fast feedback. Use a
  single documented convention for properties, ordered children, and conditions.
- Keep the internal node representation independent of authoring syntax. Revisit
  LuaX if real widget-editing tasks show that tree syntax is a recurring source of
  agent failures or a significant obstacle to review; compare working-output rate
  and repair effort rather than assuming either syntax produces better code.

### Explicit UI update loop (Remix 3-inspired proposal)

The user proposed Remix 3's general UI loop as a reference, particularly its
explicit updates and lack of implicit state tracking. The recommendation is to
adopt that model for the Lua framework; exact API names remain provisional.

Remix's current component docs describe a setup function that runs once and
returns a render function. Local state lives in ordinary closure variables, and
`handle.update()` schedules another render. Its scheduler deduplicates pending
component updates, flushes them through a microtask, and avoids separately updating
a child when its ancestor is already scheduled. Stable keys preserve component
and element identity during reconciliation. Frame `reload()` is a separate
operation that retrieves fresh frame content.

Proposed Haunt loop:

```text
input / timer / completed I/O
  -> change ordinary Lua values
  -> ctx:update()
  -> enqueue the component once for the next UI flush
  -> run its render function
  -> reconcile its native UI subtree
  -> OpenTUI renders and emits changed terminal cells
```

- Setup runs once per component instance/revision; ordinary updates call only its
  render function. Nested components can have their own update handles.
- `ctx:update()` marks work pending rather than synchronously repainting. Coalesce
  repeated requests before a flush and avoid duplicate ancestor/descendant work.
  Host-driven mount, prop/configuration changes, and relevant size/theme changes
  are explicit additional update triggers.
- Retain native nodes across updates and use stable keys for list identity. Update
  changed properties and children without rebuilding the workspace. Native layout
  and drawing may still cover a larger region when geometry changes.
- Mutating a variable or table has ordinary Lua semantics. There are no tracked
  reads, reactive proxies, hook-order rules, or inferred effect dependencies in the
  proposed core model. The event handler or asynchronous task owns its operations
  and explicitly requests each visible state transition.
- Pending updates are scheduled on demand. Idle widgets do not repeatedly execute
  their render functions. Rendering a requested subtree still has a cost; large
  widgets should use component boundaries and virtualized lists where appropriate.
- Keep UI updates, data refresh operations, and code hot reload distinct. Updating
  the UI does not automatically refetch data or re-run setup.
- Provide an explicit post-commit callback or awaitable commit primitive for work
  such as focusing a newly created input; exact API is undecided.
- Hot-reload persistence is orthogonal to updates: explicitly retain serializable
  data or supply snapshot/restore hooks. Captured local variables are not migrated
  automatically, and retained state does not acquire automatic rendering behavior.

This should make agent-authored code easier to inspect and diagnose: the path from
an external event to state mutation to rendering is visible in the source. The
efficiency comes from scheduling, reconciliation, and native rendering rather than
from the explicit update call by itself. Performance still needs measurement.

### Prompt workflow

1. Describe a new widget, or prompt a change to an existing widget.
2. Give the coding agent the SDK contract, examples, existing source, and relevant
   diagnostics.
3. Generate edits into a candidate revision and build/check it.
4. Load the valid revision into the workspace. Report errors in the widget's
   development UI and feed diagnostics back into the editing loop.

The agent integration/provider is undecided.

### Hot reload contract

- Watch widget source and affected dependencies; rebuild only affected widgets.
- Build and validate candidate revisions before replacing a working revision.
- Keep layout, stable instance identity, configuration, and explicitly managed
  serializable state across reloads. Arbitrary local component state is not promised
  to survive; incompatible state schemas require migration or an explicit reset.
- Dispose the old revision's resources and prevent late messages from it from
  updating the replacement. Avoid running two active copies of background effects
  during activation.
- Keep build/import errors local to the widget and retain the working revision when
  a candidate fails before activation. Provide recovery to the previous revision
  for activation/runtime failures, with widget-local diagnostics where possible.
- Reload does not undo external effects such as completed API calls or file writes.
- Workspace chrome and unaffected widgets stay mounted throughout reload.

Proposed first technical spike: two widgets, one with file watching and API polling;
edit UI and backend code while running, exercise failed revisions, and verify state
continuity and resource cleanup alongside interactive resizing.

## Design questions

- What should the first useful workspace contain?
- What low-spec hardware and memory/CPU budgets are we targeting?
- How is the workspace grid sized, and how does it adapt to terminal resizing?
- How should moving or resizing a widget handle occupied grid cells?
- How should adding widgets or shrinking the terminal handle insufficient space
  while preserving the single-viewport layout?
- How do users add, configure, move, resize, and interact with widgets?
- How are widgets authored and loaded?
- What layout, configuration, and widget state should persist?
- What belongs in the first version?

## References discussed

- [Ben Visness's LuaX](https://bvisness.me/luax/) and
  [syarul/luax](https://github.com/syarul/luax): JSX-like Lua syntax and transforms.
- [Lapis HTML generation](https://leafo.net/lapis/reference/html_generation.html):
  nested Lua/MoonScript builder syntax.
- [Roact elements](https://github.com/Roblox/roact/blob/master/docs/guide/elements.md)
  and [React Lua](https://github.com/Roblox/react-lua): declarative UI trees in the
  Roblox ecosystem; Roact is deprecated in favor of React Lua.
- [Fusion constructor discussion](https://github.com/dphfox/Fusion/issues/46):
  tradeoffs around Lua constructor syntax and child representation.
- [OpenTUI layout](https://opentui.com/docs/core-concepts/layout/): supported
  primitive layout properties and terminal-cell semantics.
- [OpenTUI native renderable](https://github.com/anomalyco/opentui/blob/main/packages/native/src/native-renderable.zig)
  and [Zig module](https://github.com/anomalyco/opentui/blob/main/packages/native/src/opentui.zig):
  current native integration boundary and ownership of the renderable tree.
- [Remix 3 rendering model](https://guides.remix.run/rendering-ui/) and
  [interactivity](https://guides.remix.run/interactivity/): setup/render separation,
  ordinary local state, explicit updates, and cancellation.
- [Remix UI scheduler](https://github.com/remix-run/remix/blob/main/packages/ui/src/runtime/scheduler.ts):
  update batching, deduplication, and ancestor/descendant scheduling.
- [Remix 3 beta announcement](https://remix.run/blog/remix-3-beta-preview): clear
  runtime concepts and agent-friendly application structure.
- [Sampler](https://github.com/sqshq/sampler): shell-command-driven widgets
  with interactive positioning and resizing.
- [Terminal Widgets](https://github.com/IceWizard7/terminal-widgets): custom
  Python widgets with rendering and input callbacks.
- [WTFutil](https://wtfutil.com/): a personal dashboard with many integrations.
- [XtermWM](https://xtermwm.sourceforge.io/): terminal window management and
  widget plugins.

These are references for the design discussion, not feature commitments.
