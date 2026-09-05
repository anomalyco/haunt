const std = @import("std");
const ot = @import("opentui");
const lua = @import("lua.zig");
const ui = @import("ui.zig");
const layout = @import("layout.zig");
const input = @import("input.zig");
var native_io: std.Io.Threaded = .init_single_threaded;
pub const io = native_io.io();

test "Lua lifecycle, options, and failed hot reload retain a working widget" {
    var vm = try lua.Vm.init(std.testing.allocator);
    defer vm.deinit();
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/framework.lua", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source);
    vm.eval("@tests/framework.lua", source, 0) catch |err| {
        std.debug.print("{s}\n", .{vm.last_error orelse "Lua test failed"});
        return err;
    };
}

test "OpenTUI lays out Lua text in terminal cells and retains keyed nodes" {
    const a = std.testing.allocator;
    var vm = try lua.Vm.init(a);
    defer vm.deinit();
    var pool = ot.GraphemePool.init(a);
    defer pool.deinit();
    var links = ot.LinkPool.init(a);
    defer links.deinit();
    const buffer = try ot.OptimizedBuffer.init(a, 30, 10, .{ .pool = &pool, .link_pool = &links, .width_method = .unicode, .id = "test" });
    defer buffer.deinit();
    var tree = ui.Tree{ .allocator = a, .L = vm.L, .graphemes = &pool, .links = &links };
    defer tree.deinit();
    try vm.eval("@test", "local u=require('haunt').ui; return u.box{alignItems='center',justifyContent='center',u.text{key='time','12:34'}}", 1);
    try tree.sync(-1);
    lua.pop(vm.L, 1);
    try tree.draw(buffer, .{ .x = 0, .y = 0, .width = 30, .height = 10 });
    const child = tree.root.?.children[0];
    try std.testing.expectEqual(@as(u32, 5), child.width);
    try std.testing.expect(child.x >= 12 and child.x <= 13);
    try std.testing.expectEqual(@as(u32, '1'), buffer.get(@intCast(child.x), @intCast(child.y_pos)).?.char);
    try vm.eval("@test", "local u=require('haunt').ui; return u.box{u.text{key='time','12:35'}}", 1);
    try tree.sync(-1);
    lua.pop(vm.L, 1);
    try std.testing.expectEqual(child, tree.root.?.children[0]);
    try tree.draw(buffer, .{ .x = 0, .y = 0, .width = 8, .height = 3 });
    try std.testing.expectEqualStrings("12:35", child.content.?);
}

test "grid rejects overflowing and overlapping rectangles and shares rounded edges" {
    var widgets = [_]layout.Widget{
        .{ .id = "a", .widget = "a.lua", .rect = .{ .x = 0, .y = 0, .width = 6, .height = 12 } },
        .{ .id = "b", .widget = "b.lua", .rect = .{ .x = 6, .y = 0, .width = 6, .height = 12 } },
    };
    const doc = layout.Document{ .id = "test", .name = "Test", .version = 1, .grid = .{ .columns = 12, .rows = 12 }, .widgets = &widgets };
    try doc.validate();
    const left = doc.pixels(widgets[0].rect, 81, 25);
    const right = doc.pixels(widgets[1].rect, 81, 25);
    try std.testing.expectEqual(@as(u32, 0), left.y);
    try std.testing.expectEqual(@as(u32, 25), left.height);
    try std.testing.expectEqual(left.x + left.width, right.x);
    try std.testing.expectEqual(@as(u32, 81), right.x + right.width);
    widgets[1].rect.x = 5;
    try std.testing.expectError(error.OverlappingWidgets, doc.validate());
    widgets[1].rect.x = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidWidgetBounds, doc.validate());
}

test "text measurement uses Unicode display cells rather than byte or codepoint counts" {
    const a = std.testing.allocator;
    var vm = try lua.Vm.init(a);
    defer vm.deinit();
    var pool = ot.GraphemePool.init(a);
    defer pool.deinit();
    var links = ot.LinkPool.init(a);
    defer links.deinit();
    const buffer = try ot.OptimizedBuffer.init(a, 20, 5, .{ .pool = &pool, .link_pool = &links, .width_method = .unicode, .id = "unicode" });
    defer buffer.deinit();
    var tree = ui.Tree{ .allocator = a, .L = vm.L, .graphemes = &pool, .links = &links };
    defer tree.deinit();
    try vm.eval("@unicode", "local u=require('haunt').ui; return u.box{alignItems='flex-start',u.text{key='unicode',wrapMode='char',width=4,'你好é🙂'}}", 1);
    try tree.sync(-1);
    lua.pop(vm.L, 1);
    try tree.draw(buffer, .{ .x = 0, .y = 0, .width = 20, .height = 5 });
    const child = tree.root.?.children[0];
    const natural = try child.view.?.measureForDimensions(0, 0);
    try std.testing.expectEqual(@as(u32, 7), natural.width_cols_max);
    try std.testing.expectEqual(@as(u32, 4), child.width);
    try std.testing.expectEqual(@as(u32, 2), child.height);
}

test "pointer grid coordinates invert rendered track boundaries all the way to screen edges" {
    const doc = layout.Document{ .id = "test", .name = "Test", .version = 1, .grid = .{ .columns = 12, .rows = 12 }, .widgets = &.{} };
    for (0..12) |row| {
        for (0..12) |column| {
            const allocation = doc.pixels(.{ .x = @intCast(column), .y = @intCast(row), .width = 1, .height = 1 }, 83, 25);
            const point = doc.point(allocation.x, allocation.y, 83, 25);
            try std.testing.expectEqual(@as(i32, @intCast(column)), point.x);
            try std.testing.expectEqual(@as(i32, @intCast(row)), point.y);
            const last = doc.point(allocation.x + allocation.width - 1, allocation.y + allocation.height - 1, 83, 25);
            try std.testing.expectEqual(point, last);
        }
    }
    try std.testing.expectEqual(layout.Point{ .x = 0, .y = 0 }, doc.point(0, 0, 83, 25));
    try std.testing.expectEqual(layout.Point{ .x = 11, .y = 11 }, doc.point(82, 24, 83, 25));
    try std.testing.expectEqual(layout.Point{ .x = 11, .y = 11 }, doc.point(100, 100, 83, 25));
}

test "mouse input survives fragmentation and terminal replies do not become quit keys" {
    var parser: input.Parser = .{};
    parser.feed("\x1b[<0;12;");
    try std.testing.expect(parser.next() == null);
    parser.feed("4M\x1bP1+rquery\x1b\\q");
    const mouse = parser.next().?.mouse;
    try std.testing.expectEqual(@as(u32, 11), mouse.x);
    try std.testing.expectEqual(@as(u32, 3), mouse.y);
    try std.testing.expectEqual(@as(u32, 'q'), parser.next().?.key);
    try std.testing.expect(parser.next() == null);
}

test "a runaway Lua call returns an error across the C boundary" {
    var vm = try lua.Vm.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectError(error.LuaFailure, vm.eval("@runaway.lua", "while true do end", 0));
    try std.testing.expect(std.mem.indexOf(u8, vm.last_error.?, "time budget") != null);
    try vm.eval("@after-error.lua", "return 42", 1);
    try std.testing.expectEqual(@as(i64, 42), lua.c.lua_tointegerx(vm.L, -1, null));
    lua.pop(vm.L, 1);
}
