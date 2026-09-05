# Haunt

A full-screen terminal home for programmable widgets. An Anomaly project.

Arrange Lua widgets on a content-only, drag-and-resize grid. Haunt uses native
OpenTUI rendering, explicit UI updates, and JSON layout files with per-widget
options.

## Run

```sh
./dev
./dev examples/clocks.json
```

The bootstrap downloads checksum-pinned Zig 0.16.0, OpenTUI, and Lua 5.4.9 into
ignored local directories. Python 3.12+ is needed for bootstrap. The application is
a native executable with embedded Lua. The current prototype targets POSIX
terminals, with Linux x86_64 as the initial development platform.

The clock displays twelve-hour time with seconds using a fixed OpenTUI ASCII font.
Its `font` option chooses `tiny`, `block`, `shade`, `slick`, `huge`, `grid`, or
`pallet`; resizing keeps that font unchanged and clips content that does not fit.
Multiple instances can use different fonts and timezones. Options also include a
custom format, color, and an opt-in date. Edit `widgets/clock.lua` while Haunt runs
to see it reload. Restart Haunt after editing the layout file to load new instances
or options.

The normal workspace shows widget content across the entire terminal, with no
title bars or footer. Controls are available when you need them:

- Press `e` to toggle layout editing.
- Hover over a widget to brighten it with a low-opacity white overlay.
- Hover over an edge to reveal a brighter, one-cell-wide resize handle; corners
  highlight both adjacent edges.
- Drag inside a widget to move it, or drag a highlighted edge/corner to resize it,
  one terminal column or row at a time.
- Press `D` to delete the highlighted widget and save the layout.
- Release to save the layout. Overlapping placements are rejected.
- Escape cancels a drag; otherwise it leaves layout editing.
- `Tab` selects a widget, `r` reloads source, and `q` / `Ctrl+C` exits.

Dragging and resizing use terminal-cell precision regardless of the layout's
stored grid density. Saving an edit records exact cell rectangles with the current
viewport as the reference grid. Existing layouts retain their displayed placement,
and terminal resizing still scales the saved arrangement proportionally.

Both modes use the full content surface. The editor's white overlays brighten text
and backgrounds without adding frame characters or changing the allocation. Moving
or resizing previews the actual widget content. Deleting an instance cleans up its
timers and resources and leaves its source available for reuse.

Invalid widget revisions preserve the working content with a small error marker;
hover over the affected widget in edit mode to read its diagnostic.

The default dashboard also contains `widgets/audio-outputs.lua`. It lists PipeWire
audio outputs through `wpctl`, left-aligns each row, highlights the current default,
and switches the default when another row is clicked.

`widgets/calendar.lua` shows the current month in a compact seven-column calendar,
with the current day using an active background. Its options control the week start
and calendar colors.

`widgets/media-controls.lua` shows the current MPRIS track and artist with clickable
Play, Pause, and Next controls through `playerctl`. The playing/paused action uses
the active background color.

`widgets/system-monitor.lua` reads Linux `/proc` directly and renders CPU and memory
history as btop-style vertical block charts. It retains a bounded sample history and
does not spawn a process for each refresh.

After building, run `zig-out/bin/haunt [layout.json]` directly. For an optimized build:

```sh
.tools/zig/zig build -Doptimize=ReleaseSafe -j4
zig-out/bin/haunt examples/clock.json
```

## Develop

```sh
python3 scripts/setup.py
.tools/zig/zig fmt --check build.zig build.zig.zon src
.tools/zig/zig build -j4
zig-out/bin/haunt examples/clock.json --snapshot 80x24
```

The Lua framework provides box/text/ASCII-font constructors, Yoga layout, explicit updates,
scoped timers, options validation, per-instance state, and source hot reload. The
next runtime milestones are asynchronous filesystem/HTTP services and live
dashboard-file reconciliation/switching.

- [Design](DESIGN.md)
- [Lua widget API](docs/lua.md)
- [Widget-system research](docs/widget-systems.md)
- [Design discussion](docs/design-discussion.md)
