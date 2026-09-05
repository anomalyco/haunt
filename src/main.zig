const std = @import("std");
const ot = @import("opentui");
const lua = @import("lua.zig");
const c = lua.c;
const ui = @import("ui.zig");
const layout_mod = @import("layout.zig");
const input = @import("input.zig");
const Rect = layout_mod.Rect;

var native_io: std.Io.Threaded = .init_single_threaded;
pub const io = native_io.io();

const Watch = struct { path: [:0]u8, stamp: i64 };
const Widget = struct {
    path: [:0]u8,
    tree: ui.Tree,
    version: i64 = -1,
    error_message: ?[]u8 = null,
    watches: []Watch = &.{},

    fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        self.tree.deinit();
        allocator.free(self.path);
        if (self.error_message) |message| allocator.free(message);
        for (self.watches) |watch| allocator.free(watch.path);
        allocator.free(self.watches);
    }
};

const Drag = struct {
    index: usize,
    // Gesture geometry and pointer deltas are always in terminal cells.
    original: Rect,
    candidate: Rect,
    start_x: i32,
    start_y: i32,
    edges: u4, // left, right, top, bottom; zero means move.
    valid: bool = true,
};

const App = struct {
    allocator: std.mem.Allocator,
    file_io: std.Io,
    layout: *layout_mod.Layout,
    vm: *lua.Vm,
    renderer: *ot.CliRenderer,
    widgets: []Widget,
    selected: ?usize = null,
    editing: bool = false,
    drag: ?Drag = null,
    message: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, file_io: std.Io, layout: *layout_mod.Layout, vm: *lua.Vm, renderer: *ot.CliRenderer, pool: *ot.GraphemePool, links: *ot.LinkPool) !App {
        const widgets = try allocator.alloc(Widget, layout.parsed.value.widgets.len);
        var initialized: usize = 0;
        errdefer {
            for (widgets[0..initialized]) |*widget| widget.deinit(allocator);
            allocator.free(widgets);
        }
        for (widgets, layout.parsed.value.widgets) |*widget, definition| {
            widget.* = .{
                .path = try layout.widgetPath(definition),
                .tree = .{ .allocator = allocator, .L = vm.L, .graphemes = pool, .links = links },
            };
            initialized += 1;
        }
        var app = App{ .allocator = allocator, .file_io = file_io, .layout = layout, .vm = vm, .renderer = renderer, .widgets = widgets };
        for (0..widgets.len) |index| try app.reload(index);
        return app;
    }

    fn deinit(self: *App) void {
        for (self.widgets) |*widget| widget.deinit(self.allocator);
        self.allocator.free(self.widgets);
        if (self.message) |message| self.allocator.free(message);
    }

    fn setMessage(self: *App, message: ?[]const u8) !void {
        const next = if (message) |value| try self.allocator.dupe(u8, value) else null;
        if (self.message) |previous| self.allocator.free(previous);
        self.message = next;
    }

    fn contentRect(self: *App, allocation: Rect) Rect {
        if (!self.layout.parsed.value.appearance.borders) return allocation;
        return .{ .x = allocation.x + 1, .y = allocation.y + 1, .width = allocation.width -| 2, .height = allocation.height -| 2 };
    }

    fn rect(self: *App, index: usize) Rect {
        const doc = self.layout.parsed.value;
        return doc.pixels(doc.widgets[index].rect, self.renderer.width, self.renderer.height);
    }

    fn reload(self: *App, index: usize) !void {
        const widget = &self.widgets[index];
        const definition = self.layout.parsed.value.widgets[index];
        const content = self.contentRect(self.rect(index));
        const ok = self.vm.load(definition.id, widget.path, definition.options, content.width, content.height) catch false;
        const next_error = if (ok) null else try self.allocator.dupe(u8, self.vm.last_error orelse "Unable to load widget");
        if (widget.error_message) |previous| self.allocator.free(previous);
        widget.error_message = next_error;
        try self.updateWatches(index);
    }

    fn updateWatches(self: *App, index: usize) !void {
        const widget = &self.widgets[index];
        const L = self.vm.L;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        self.vm.method("dependencies");
        lua.pushString(L, self.layout.parsed.value.widgets[index].id);
        try self.vm.call(1, 1);
        const count = c.lua_rawlen(L, -1);
        var watches: std.ArrayList(Watch) = .empty;
        errdefer {
            for (watches.items) |watch| self.allocator.free(watch.path);
            watches.deinit(self.allocator);
        }
        try watches.ensureTotalCapacity(self.allocator, count + 1);
        const root = try self.allocator.dupeZ(u8, widget.path);
        watches.appendAssumeCapacity(.{ .path = root, .stamp = c.haunt_file_stamp(root) });
        for (0..count) |i| {
            _ = c.lua_rawgeti(L, -1, @intCast(i + 1));
            const path = lua.string(L, -1);
            if (!std.mem.eql(u8, path, widget.path)) {
                const owned = try self.allocator.dupeZ(u8, path);
                watches.appendAssumeCapacity(.{ .path = owned, .stamp = c.haunt_file_stamp(owned) });
            }
            lua.pop(L, 1);
        }
        for (widget.watches) |watch| self.allocator.free(watch.path);
        self.allocator.free(widget.watches);
        widget.watches = try watches.toOwnedSlice(self.allocator);
    }

    fn checkSources(self: *App) !bool {
        var changed = false;
        for (self.widgets, 0..) |widget, index| {
            for (widget.watches) |watch| {
                if (c.haunt_file_stamp(watch.path) != watch.stamp) {
                    try self.reload(index);
                    changed = true;
                    break;
                }
            }
        }
        return changed;
    }

    fn drawDiagnostic(self: *App, buffer: *ot.OptimizedBuffer, index: usize, region: Rect, message: []const u8) !void {
        if (region.width == 0 or region.height == 0) return;
        const tree = &self.widgets[index].tree;
        const text = try ot.UnifiedTextBuffer.init(self.allocator, tree.graphemes, tree.links, .unicode);
        defer text.deinit();
        const view = try ot.UnifiedTextBufferView.init(self.allocator, text);
        defer view.deinit();
        const contents = try std.fmt.allocPrint(self.allocator, "Widget error\n{s}", .{message});
        defer self.allocator.free(contents);
        try text.setText(contents);
        text.setDefaultFg(ot.rgbColor(235, 111, 146, 255));
        text.setDefaultBg(ui.background);
        view.setWrapMode(.word);
        view.setViewport(.{ .x = 0, .y = 0, .width = region.width, .height = region.height });
        try buffer.pushScissorRect(@intCast(region.x), @intCast(region.y), region.width, region.height);
        defer buffer.popScissorRect();
        buffer.fillRect(region.x, region.y, region.width, region.height, ui.background);
        buffer.drawTextBuffer(view, @intCast(region.x), @intCast(region.y));
    }

    fn draw(self: *App) !void {
        const buffer = self.renderer.getNextBuffer();
        buffer.clear(ui.background, null);
        const L = self.vm.L;
        for (self.widgets, 0..) |*widget, index| {
            const outer = self.rect(index);
            const content = self.contentRect(outer);
            const top = c.lua_gettop(L);
            defer c.lua_settop(L, top);
            try self.vm.frame(self.layout.parsed.value.widgets[index].id, content.width, content.height);
            const message = (if (self.selected == index) self.message else null) orelse widget.error_message orelse
                if (c.lua_type(L, -2) != c.LUA_TNIL) lua.string(L, -2) else null;
            if (outer.width == 0 or outer.height == 0) continue;
            if (c.lua_type(L, -4) == c.LUA_TTABLE) {
                const version = c.lua_tointegerx(L, -3, null);
                if (widget.version != version) {
                    try widget.tree.sync(-4);
                    widget.version = version;
                }
                try widget.tree.draw(buffer, content);
            } else if (message) |value| {
                try self.drawDiagnostic(buffer, index, content, value);
            }
            if (self.editing or self.layout.parsed.value.appearance.borders) {
                try buffer.drawBox(@intCast(outer.x), @intCast(outer.y), outer.width, outer.height, &ui.rounded, .{ .top = true, .right = true, .bottom = true, .left = true }, if (message != null) ot.rgbColor(235, 111, 146, 255) else if (self.editing and self.selected == index) ui.accent else ot.rgbColor(65, 65, 80, 255), ui.transparent, ui.muted, false, null, 0, null, 0);
            }
            if (message) |value| {
                if (self.editing and outer.width > 2 and outer.height > 2) {
                    // Diagnostics belong to the affected tile, rather than permanent app chrome.
                    try self.drawDiagnostic(buffer, index, .{ .x = outer.x + 1, .y = outer.y + 1, .width = outer.width - 2, .height = outer.height - 2 }, value);
                } else {
                    try buffer.drawText("!", @intCast(outer.x + outer.width - 1), @intCast(outer.y), ot.rgbColor(235, 111, 146, 255), ui.background, ot.TextAttributes.BOLD);
                }
            }
        }
        if (self.drag) |drag| {
            const ghost = drag.candidate;
            try buffer.drawBox(@intCast(ghost.x), @intCast(ghost.y), ghost.width, ghost.height, &ui.rounded, .{ .top = true, .right = true, .bottom = true, .left = true }, if (drag.valid) ui.accent else ot.rgbColor(235, 111, 146, 255), ui.transparent, ui.accent, false, null, 0, null, 0);
        }
        _ = self.renderer.render(false);
    }

    fn handleMouse(self: *App, mouse: input.Mouse) !void {
        if (self.drag) |*drag| {
            const dx = @as(i32, @intCast(mouse.x)) - drag.start_x;
            const dy = @as(i32, @intCast(mouse.y)) - drag.start_y;
            const width = self.renderer.width;
            const height = self.renderer.height;
            const original = drag.original;
            var x: i32 = @intCast(original.x);
            var y_pos: i32 = @intCast(original.y);
            var right: i32 = @intCast(original.x + original.width);
            var bottom: i32 = @intCast(original.y + original.height);
            if (drag.edges == 0) {
                x = std.math.clamp(x + dx, 0, @as(i32, @intCast(width - original.width)));
                y_pos = std.math.clamp(y_pos + dy, 0, @as(i32, @intCast(height - original.height)));
                right = x + @as(i32, @intCast(original.width));
                bottom = y_pos + @as(i32, @intCast(original.height));
            } else {
                if (drag.edges & 1 != 0) x = std.math.clamp(x + dx, 0, right - 1);
                if (drag.edges & 2 != 0) right = std.math.clamp(right + dx, x + 1, @as(i32, @intCast(width)));
                if (drag.edges & 4 != 0) y_pos = std.math.clamp(y_pos + dy, 0, bottom - 1);
                if (drag.edges & 8 != 0) bottom = std.math.clamp(bottom + dy, y_pos + 1, @as(i32, @intCast(height)));
            }
            drag.candidate = .{ .x = @intCast(x), .y = @intCast(y_pos), .width = @intCast(right - x), .height = @intCast(bottom - y_pos) };
            const minimum: u32 = if (self.layout.parsed.value.appearance.borders) 3 else 1;
            drag.valid = self.layout.parsed.value.fitsCells(drag.candidate, drag.index, width, height) and drag.candidate.width >= minimum and drag.candidate.height >= minimum;
            if (mouse.kind == .up) {
                const completed = drag.*;
                self.drag = null;
                if (completed.valid) {
                    self.layout.placeCells(self.file_io, completed.index, completed.candidate, width, height) catch |err| {
                        try self.setMessage(@errorName(err));
                        return;
                    };
                    try self.setMessage(null);
                }
            }
            return;
        }
        for (self.widgets, 0..) |*widget, index| {
            const outer = self.rect(index);
            if (!outer.contains(mouse.x, mouse.y)) continue;
            if (mouse.kind == .down and mouse.button == 0) {
                self.selected = index;
                if (self.editing) {
                    var edges: u4 = 0;
                    if (mouse.x == outer.x) edges |= 1;
                    if (mouse.x == outer.x + outer.width - 1) edges |= 2;
                    if (mouse.y == outer.y) edges |= 4;
                    if (mouse.y == outer.y + outer.height - 1) edges |= 8;
                    self.drag = .{ .index = index, .original = outer, .candidate = outer, .start_x = @intCast(mouse.x), .start_y = @intCast(mouse.y), .edges = edges };
                    return;
                }
            }
            if (self.editing) return;
            const handler: [:0]const u8 = switch (mouse.kind) {
                .down => "onMouseDown",
                .up => "onMouseUp",
                .move => "onMouseMove",
            };
            if (widget.tree.root) |root| if (root.hit(@intCast(mouse.x), @intCast(mouse.y), handler)) |node| {
                const L = self.vm.L;
                const top = c.lua_gettop(L);
                defer c.lua_settop(L, top);
                self.vm.method("dispatch");
                lua.pushString(L, self.layout.parsed.value.widgets[index].id);
                _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, node.reference);
                _ = c.lua_getfield(L, -1, "props");
                _ = c.lua_getfield(L, -1, handler);
                c.lua_rotate(L, -3, 1);
                lua.pop(L, 2);
                c.lua_createtable(L, 0, 3);
                c.lua_pushinteger(L, mouse.x);
                c.lua_setfield(L, -2, "x");
                c.lua_pushinteger(L, mouse.y);
                c.lua_setfield(L, -2, "y");
                c.lua_pushinteger(L, mouse.button);
                c.lua_setfield(L, -2, "button");
                c.lua_pushinteger(L, widget.version);
                try self.vm.call(4, 0);
            };
            return;
        }
    }

    fn handleKey(self: *App, key: u32) !void {
        if (self.widgets.len == 0) return;
        const index = self.selected orelse 0;
        const root = self.widgets[index].tree.root orelse return;
        const node = root.firstHandler("onKeyDown") orelse return;
        const L = self.vm.L;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        self.vm.method("dispatch");
        lua.pushString(L, self.layout.parsed.value.widgets[index].id);
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, node.reference);
        _ = c.lua_getfield(L, -1, "props");
        _ = c.lua_getfield(L, -1, "onKeyDown");
        c.lua_rotate(L, -3, 1);
        lua.pop(L, 2);
        c.lua_createtable(L, 0, 3);
        var bytes: [4]u8 = undefined;
        const ctrl = key > 0 and key < 27 and key != 10 and key != 13;
        const length = try std.unicode.utf8Encode(@intCast(if (ctrl) key + 'a' - 1 else key), &bytes);
        lua.pushString(L, switch (key) {
            13, 10 => "enter",
            32 => "space",
            127 => "backspace",
            else => bytes[0..length],
        });
        c.lua_setfield(L, -2, "name");
        c.lua_pushinteger(L, key);
        c.lua_setfield(L, -2, "code");
        c.lua_pushboolean(L, @intFromBool(ctrl));
        c.lua_setfield(L, -2, "ctrl");
        c.lua_pushinteger(L, self.widgets[index].version);
        try self.vm.call(4, 0);
    }

    fn handle(self: *App, event: input.Event) !bool {
        switch (event) {
            .key => |key| switch (key) {
                'q', 3 => return false,
                27 => {
                    if (self.drag != null) self.drag = null else self.editing = false;
                },
                'e', 5 => {
                    self.drag = null;
                    self.editing = !self.editing;
                },
                'b' => {
                    if (self.editing) {
                        const previous = self.layout.parsed.value.appearance.borders;
                        self.layout.parsed.value.appearance.borders = !previous;
                        self.layout.save(self.file_io) catch |err| {
                            self.layout.parsed.value.appearance.borders = previous;
                            try self.setMessage(@errorName(err));
                        };
                    } else try self.handleKey(key);
                },
                'r', 18 => {
                    for (0..self.widgets.len) |index| try self.reload(index);
                },
                9 => {
                    if (self.widgets.len > 0) self.selected = if (self.selected) |index| (index + 1) % self.widgets.len else 0;
                },
                else => if (!self.editing) try self.handleKey(key),
            },
            .mouse => |mouse| try self.handleMouse(mouse),
        }
        return true;
    }
};

/// Text snapshot of the pinned OpenTUI buffer, preserving multi-cell grapheme starts.
fn snapshot(allocator: std.mem.Allocator, buffer: *ot.OptimizedBuffer, pool: *ot.GraphemePool) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (0..buffer.height) |row| {
        for (0..buffer.width) |column| {
            const char = buffer.get(@intCast(column), @intCast(row)).?.char;
            // OpenTUI's public buffer exposes packed cells; these tags are pinned with the dependency.
            switch (char & 0xc0000000) {
                0x80000000 => try output.appendSlice(allocator, try pool.get(char & 0x03ffffff)),
                0xc0000000 => {},
                0x40000000 => try output.append(allocator, ' '),
                else => {
                    var bytes: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(@intCast(if (char == 0) 32 else char), &bytes) catch 0;
                    try output.appendSlice(allocator, bytes[0..length]);
                },
            }
        }
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next();
    var path: []const u8 = "examples/clock.json";
    var snapshot_size: ?struct { width: u32, height: u32 } = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--snapshot")) {
            const size = args.next() orelse return error.ExpectedSnapshotSize;
            const split = std.mem.indexOfScalar(u8, size, 'x') orelse return error.ExpectedWidthXHeight;
            const width = try std.fmt.parseInt(u32, size[0..split], 10);
            const height = try std.fmt.parseInt(u32, size[split + 1 ..], 10);
            if (width == 0 or height == 0 or width > 1000 or height > 500) return error.InvalidSnapshotSize;
            snapshot_size = .{ .width = width, .height = height };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var out = std.Io.File.stdout().writer(init.io, &.{});
            try out.interface.writeAll("Usage: haunt [layout.json] [--snapshot WIDTHxHEIGHT]\n\nDefault: examples/clock.json\ne: edit layout; drag inside a tile to move, edges/corners to resize\nb: toggle saved borders while editing; Escape: cancel/leave editing\nr: reload widgets; q / Ctrl+C: quit\n");
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) return error.UnknownArgument else path = arg;
    }

    var layout = layout_mod.Layout.load(allocator, init.io, path) catch |err| {
        std.debug.print("Cannot open layout '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer layout.deinit();
    var vm = try lua.Vm.init(allocator);
    defer vm.deinit();
    var graphemes = ot.GraphemePool.init(allocator);
    defer graphemes.deinit();
    var links = ot.LinkPool.init(allocator);
    defer links.deinit();

    var width: u32 = 80;
    var height: u32 = 24;
    if (snapshot_size) |size| {
        width = size.width;
        height = size.height;
    } else {
        if (c.haunt_terminal_open() != 0) {
            std.debug.print("Haunt needs an interactive terminal. Use --snapshot 80x24 for a text preview.\n", .{});
            return error.NotATerminal;
        }
        c.haunt_terminal_size(&width, &height);
    }
    defer if (snapshot_size == null) c.haunt_terminal_close();
    const renderer = try ot.CliRenderer.createWithOptions(allocator, width, height, &graphemes, .{
        .output = if (snapshot_size != null) .memory else .stdout,
        .clearOnShutdown = true,
        .link_pool = &links,
        .env_map = init.environ_map,
    });
    defer renderer.destroy();
    renderer.terminal.caps.rgb = true;
    renderer.setBackgroundColor(ui.background);
    if (snapshot_size == null) {
        renderer.setupTerminal(true);
        renderer.enableMouse(false);
    }
    var app = try App.init(allocator, init.io, &layout, &vm, renderer, &graphemes, &links);
    defer app.deinit();
    _ = try vm.poll();
    try app.draw();

    if (snapshot_size != null) {
        const text = try snapshot(allocator, renderer.getCurrentBuffer(), &graphemes);
        defer allocator.free(text);
        var out = std.Io.File.stdout().writer(init.io, &.{});
        try out.interface.writeAll(text);
        for (app.widgets) |widget| if (widget.error_message) |message| {
            std.debug.print("{s}\n", .{message});
            return error.WidgetLoadFailed;
        };
        return;
    }

    var parser: input.Parser = .{};
    var next_source_check = c.haunt_now() + 500;
    var running = true;
    while (running and c.haunt_should_quit() == 0) {
        const until_check: c_int = @intFromFloat(@max(0, @ceil(next_source_check - c.haunt_now())));
        const timeout = @min(try vm.nextDelay(), if (parser.escapePending()) @min(until_check, 25) else until_check);
        const available = c.haunt_wait(timeout);
        if (available < 0) return error.TerminalReadFailed;
        var redraw = false;
        if (available > 0) {
            var bytes: [2048]u8 = undefined;
            const count = c.haunt_read(&bytes, bytes.len);
            parser.feed(bytes[0..@intCast(count)]);
            while (parser.next()) |event| {
                running = try app.handle(event);
                redraw = true;
                if (!running) break;
            }
        } else if (parser.flushEscape()) |event| {
            running = try app.handle(event);
            redraw = true;
        }
        if (c.haunt_was_resized() != 0) {
            c.haunt_terminal_size(&width, &height);
            try renderer.resize(width, height);
            app.drag = null;
            redraw = true;
        }
        if (c.haunt_now() >= next_source_check) {
            redraw = try app.checkSources() or redraw;
            next_source_check = c.haunt_now() + 500;
        }
        redraw = try vm.poll() or redraw;
        if (redraw and running) try app.draw();
    }
}
