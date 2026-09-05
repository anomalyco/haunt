# Mainstream widget systems: design research

Reviewed 2026-09-05 using official product and developer documentation.

The comparison covers the built-in Apple, Android, and Windows widget experiences,
plus Grafana and Rainmeter as particularly relevant configurable dashboard systems.
These are documented behaviors and APIs; their internal placement algorithms have
not been established by this review.

## Main finding

The mainstream OS widget model separates the host's placement and size allocation
from the widget's internal presentation. Providers declare supported sizes or
constraints, users choose an arrangement, and the widget renders inside the space
the host allocates. Content size is usually not permission to expand the workspace.

This supports Haunt's stable placement decision. It also distinguishes two uses of
layout: positioning widgets in the dashboard and laying out content inside one
widget. Reusing Flexbox for the second does not determine the first.

## iOS and iPadOS: widget families on a Home Screen

- Users add widgets through a gallery, choose an available size/style, and move
  them on a Home Screen page. Configuration can be edited on an existing widget.
- WidgetKit providers declare supported families. Common Home Screen families are
  small, medium, and large; extra-large is available on supported platforms such
  as iPadOS and macOS. The system supplies the selected family to the view.
- A provider can render different information/layouts for each supported family.
  Supporting a larger family does not mean merely magnifying the smaller view.
- Configurable widgets use parameters such as a location or tracked item. The
  implementation can be reused with different selections.
- WidgetKit separates timeline data from SwiftUI rendering and uses snapshots.
  Timelines and reload policies help schedule content work; special dynamic views
  and interactive features also exist.
- Home Screen pages and widget stacks provide additional organization. Stacks hide
  some members at a given time, so they are not a direct fit for Haunt's initial
  requirement that all widget regions remain visible.

Useful for Haunt: a simple add/configure/place workflow, sensible supported sizes,
preview data, and meaningful compact presentations.

Sources:
- [Add, edit, and remove widgets on iPhone](https://support.apple.com/guide/iphone/add-edit-and-remove-widgets-iphb8f1bf206/ios)
- [Creating a widget extension](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)

## macOS: desktop placement and Notification Center

- Modern macOS supports widgets on the desktop and in Notification Center.
- Desktop widgets can be positioned automatically from the gallery or dragged to
  a chosen location. The documented desktop interaction is freer than a mandatory
  shared row/column grid.
- Notification Center supports vertical rearrangement of widgets.
- Context menus expose available sizes and widget-specific options, such as which
  reminders list to show.
- WidgetKit supplies the same family/configuration concepts as other Apple
  platforms, while the host surface controls placement.

Useful for Haunt: consistent per-widget configuration and context actions across
different content types. Desktop placement itself is not the chosen Haunt model.

Source:
- [Add and customize widgets on Mac](https://support.apple.com/guide/mac-help/add-and-customize-widgets-mchl52be5da5/mac)

## Android: grid spans with explicit resize constraints

- Home Screen launchers place widgets into a grid. Cell sizes and grid dimensions
  vary with the launcher/device.
- A provider can declare a target size in cells, minimum/maximum resize dimensions,
  and supported resize axes. Fixed-size widgets are also supported.
- The launcher owns the final allocation and informs the provider of size changes.
  Providers can supply a small set of responsive layouts or exact-size layouts.
- Android's guidance explicitly recommends size buckets. Compact information
  widgets show essentials; larger versions add context. Collection widgets may
  instead use the space to expose more of a scrollable collection.
- Configuration is part of adding a widget and can be exposed again for existing
  widgets. Usable defaults can make the initial configuration step optional.

Useful for Haunt: the clearest sizing contract of the reviewed systems. A default
size and minimum usable size can coexist with user resizing and flexible content.

Sources:
- [App widgets overview](https://developer.android.com/develop/ui/views/appwidgets/overview)
- [Provide flexible widget layouts](https://developer.android.com/develop/ui/views/appwidgets/layouts)
- [Enable widget configuration](https://developer.android.com/develop/ui/views/appwidgets/configuration)

## Windows Widgets: host-managed cards

- The Widgets Board owns the grid and placement of cards. Users can drag widgets
  and choose from supported small, medium, and large sizes.
- A widget may support fewer than all three sizes. Microsoft recommends preserving
  the widget's purpose while increasing the information shown at larger sizes.
- Widget customization includes values such as a weather location or stock list.
- Providers send visual templates and associated data to the host using JSON and
  Adaptive Cards. The provider owns the contents; the board owns the outer layout.

Useful for Haunt: a clear host/content boundary and predictable per-widget actions.

Sources:
- [Windows Widgets design overview](https://learn.microsoft.com/en-us/windows/apps/design/widgets/)
- [Customize the Widgets Board](https://support.microsoft.com/en-us/windows/experience/personalization/stay-up-to-date-with-widgets-in-windows)
- [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)

## Grafana: serializable dashboards and panel instances

- Dashboards are JSON documents containing metadata, panels, variables, and
  settings. Users can inspect/edit the JSON and export/import dashboards.
- In the Classic schema, a panel has an ID, visualization-specific configuration,
  and `gridPos` containing `x`, `y`, `w`, and `h`.
- Classic layout uses 24 horizontal columns and fixed pixel-based height units.
  It also has upward compaction into empty space. Those mechanics are not a direct
  match for a stable, single-terminal-viewport workspace.
- Current documentation distinguishes Classic, V1 Resource, and V2 Resource
  schemas; V2 supports advanced layouts and conditional rendering. The Classic
  `gridPos` example is useful prior art, not a description of every current layout.
- Panel type and per-panel configuration are distinct from their placement. That
  is close to Haunt's module reference, instance options, and saved layout model.

Useful for Haunt: versioned data documents with stable identities and per-instance
configuration. Haunt needs its own bounded row/column sizing and collision policy.

Source:
- [Dashboard JSON model](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/view-dashboard-json-model/)

## Rainmeter: saved layouts and embedded Lua

- Skins are file-defined desktop widgets with configurable positions, dragging,
  edge snapping, keep-on-screen settings, and explicit refresh controls.
- Named layouts save/restore active and inactive skin state, positions, and other
  Rainmeter settings. They are editable files, and layouts can be loaded from the
  command line. The skin source files themselves are separate from layout files.
- Lua script measures support initialization, updates, and command-driven calls.
  The same script can have multiple instances with independent globals and
  user-defined options.
- Lua can inspect/manipulate native meters and measures. Rainmeter supplies an
  application-specific Lua API; its scripting restrictions and INI/meter model are
  its own design choices rather than requirements for Haunt.

Useful for Haunt: strong prior art for a native widget application with Lua
extensions, per-instance configuration, and switchable file-backed layouts.

Sources:
- [Manage: skins and layouts](https://docs.rainmeter.net/manual/user-interface/manage/)
- [Lua scripting](https://docs.rainmeter.net/manual/lua-scripting/)

## Recommendations for Haunt

These are proposals informed by the review, not additional accepted requirements.

1. **Keep the host in charge of widget geometry.** Providers can declare preferred
   and minimum usable sizes and optional size presets. Users choose placement and
   size, and data updates operate within that allocation.
2. **Prefer direct grid placement for the workspace.** It matches the selected
   product behavior and the reviewed launcher/dashboard interfaces. A nested
   Flexbox tree remains an alternative if hierarchical partitioning is the desired
   interaction, but engine availability alone should not choose that interface.
3. **Use OpenTUI/Yoga for internal widget layout.** Reuse its spacing, wrapping,
   alignment, and native measurement. A workspace grid can hand each widget a
   bounded rectangle, including through absolute positioning at its root.
4. **Make one widget implementation reusable.** Keep the definition/module, the
   configured instance, and the saved dashboard distinct. Layout files reference
   code and contain instance options plus placement; runtime snapshots remain a
   separate persistence concern.
5. **Provide a consistent editing experience.** A picker/preview, options editing,
   move, resize, duplicate, and remove are useful candidate host actions. Schema
   defaults should let an already-useful widget be added quickly.
6. **Adapt information density deliberately.** Small widgets can show essentials;
   larger widgets can show more detail or rearrange content. Basic wrapping and
   alignment should work through the primitive layout system. Every widget need
   not implement a mandatory set of three separate presentations.
7. **Schedule content work separately from drawing.** WidgetKit timelines and
   host-rendered Windows cards are examples of that boundary. Haunt can keep its
   general-purpose Lua tasks and explicit updates while rendering only when needed.

The sources do not decide Haunt's grid granularity, collision behavior, or handling
of terminals too small for a saved layout. Those still need product decisions under
the accepted stable-placement, all-visible, no-workspace-scrolling constraints.
