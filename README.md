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
The default dashboard places one clock in each font, in that order from top to
bottom. Options also include local/UTC time, a custom format, color, and an opt-in
date. Edit `widgets/clock.lua` while Haunt runs to see it reload. Restart Haunt after
editing the layout file to load new instances or options.

The normal workspace shows widget content across the entire terminal, with no
title bars or footer. Controls are available when you need them:

- Press `e` to toggle layout editing and reveal temporary outlines.
- Drag inside a tile to move it; drag its edges/corners to resize it.
- Release to save the layout. Overlapping placements are rejected.
- Escape cancels a drag; otherwise it leaves layout editing.
- Press `b` while editing to toggle dashboard-wide borders. This saves
  `"appearance": { "borders": true }` (or `false`) in the layout.
- `Tab` selects a widget, `r` reloads source, and `q` / `Ctrl+C` exits.

Invalid widget revisions preserve the working content with a small error marker;
enter layout editing to see the diagnostic in the affected tile.

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
