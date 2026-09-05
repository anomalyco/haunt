const std = @import("std");
const ot = @import("opentui");
const y = ot.yoga_c;
const lua = @import("lua.zig");
const c = lua.c;
const Rect = @import("layout.zig").Rect;

pub const background = ot.rgbColor(18, 18, 23, 255);
pub const foreground = ot.rgbColor(245, 245, 247, 255);
pub const muted = ot.rgbColor(140, 140, 157, 255);
pub const accent = ot.rgbColor(196, 167, 231, 255);
pub const transparent = ot.rgbColor(0, 0, 0, 0);
pub const rounded = [_]u32{ '╭', '╮', '╰', '╯', '─', '│', '┬', '┴', '├', '┤', '┼' };
const single = [_]u32{ '┌', '┐', '└', '┘', '─', '│', '┬', '┴', '├', '┤', '┼' };
const double = [_]u32{ '╔', '╗', '╚', '╝', '═', '║', '╦', '╩', '╠', '╣', '╬' };
const all_sides: ot.buffer.BorderSides = .{ .top = true, .right = true, .bottom = true, .left = true };

fn fieldString(L: *c.lua_State, index: c_int, name: [:0]const u8, fallback: []const u8) []const u8 {
    _ = c.lua_getfield(L, index, name);
    defer lua.pop(L, 1);
    return if (c.lua_type(L, -1) == c.LUA_TNIL) fallback else lua.string(L, -1);
}

fn number(L: *c.lua_State, index: c_int, name: [:0]const u8, fallback: f32) f32 {
    _ = c.lua_getfield(L, index, name);
    defer lua.pop(L, 1);
    return if (c.lua_type(L, -1) == c.LUA_TNUMBER) @floatCast(c.lua_tonumberx(L, -1, null)) else fallback;
}

fn boolean(L: *c.lua_State, index: c_int, name: [:0]const u8) bool {
    _ = c.lua_getfield(L, index, name);
    defer lua.pop(L, 1);
    return c.lua_toboolean(L, -1) != 0;
}

pub fn parseColor(value: []const u8) !ot.RGBA {
    if (value.len == 0 or value[0] != '#') return error.InvalidColor;
    if (value.len == 4) {
        return ot.rgbColor(
            (try std.fmt.charToDigit(value[1], 16)) * 17,
            (try std.fmt.charToDigit(value[2], 16)) * 17,
            (try std.fmt.charToDigit(value[3], 16)) * 17,
            255,
        );
    }
    if (value.len != 7 and value.len != 9) return error.InvalidColor;
    return ot.rgbColor(
        try std.fmt.parseInt(u8, value[1..3], 16),
        try std.fmt.parseInt(u8, value[3..5], 16),
        try std.fmt.parseInt(u8, value[5..7], 16),
        if (value.len == 9) try std.fmt.parseInt(u8, value[7..9], 16) else 255,
    );
}

fn color(L: *c.lua_State, index: c_int, name: [:0]const u8) !?ot.RGBA {
    _ = c.lua_getfield(L, index, name);
    defer lua.pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return null;
    return try parseColor(lua.string(L, -1));
}

fn dimension(node: y.YGNodeRef, L: *c.lua_State, props: c_int, comptime name: [:0]const u8, comptime suffix: []const u8) !void {
    _ = c.lua_getfield(L, props, name);
    defer lua.pop(L, 1);
    const set = @field(y, "YGNodeStyleSet" ++ suffix);
    if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
        set(node, @floatCast(c.lua_tonumberx(L, -1, null)));
    } else {
        const value = lua.string(L, -1);
        if (std.mem.endsWith(u8, value, "%")) {
            @field(y, "YGNodeStyleSet" ++ suffix ++ "Percent")(node, try std.fmt.parseFloat(f32, value[0 .. value.len - 1]));
        } else if (@hasDecl(y, "YGNodeStyleSet" ++ suffix ++ "Auto")) {
            @field(y, "YGNodeStyleSet" ++ suffix ++ "Auto")(node);
        } else {
            set(node, std.math.nan(f32));
        }
    }
}

fn edge(node: y.YGNodeRef, L: *c.lua_State, props: c_int, comptime name: [:0]const u8, comptime suffix: []const u8, which: y.YGEdge) !void {
    _ = c.lua_getfield(L, props, name);
    defer lua.pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return;
    if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
        @field(y, "YGNodeStyleSet" ++ suffix)(node, which, @floatCast(c.lua_tonumberx(L, -1, null)));
    } else {
        const value = lua.string(L, -1);
        if (std.mem.endsWith(u8, value, "%")) {
            @field(y, "YGNodeStyleSet" ++ suffix ++ "Percent")(node, which, try std.fmt.parseFloat(f32, value[0 .. value.len - 1]));
        } else if (@hasDecl(y, "YGNodeStyleSet" ++ suffix ++ "Auto")) {
            @field(y, "YGNodeStyleSet" ++ suffix ++ "Auto")(node, which);
        }
    }
}

fn enumValue(value: []const u8, comptime names: anytype, comptime values: anytype, fallback: c_uint) c_uint {
    inline for (names, values) |name, result| if (std.mem.eql(u8, value, name)) return result;
    return fallback;
}

pub const Node = struct {
    allocator: std.mem.Allocator,
    L: *c.lua_State,
    yoga: y.YGNodeRef,
    kind: enum { box, text },
    key: ?[]u8 = null,
    reference: c_int = c.LUA_NOREF,
    children: []*Node = &.{},
    text: ?*ot.UnifiedTextBuffer = null,
    view: ?*ot.UnifiedTextBufferView = null,
    content: ?[]u8 = null,
    fg: ?ot.RGBA = null,
    bg: ?ot.RGBA = null,
    border_color: ?ot.RGBA = null,
    border: bool = false,
    border_chars: *const [11]u32 = &rounded,
    attributes: u32 = 0,
    clip: bool = false,
    x: i32 = 0,
    y_pos: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    fn create(tree: *Tree, kind: @FieldType(Node, "kind")) !*Node {
        const self = try tree.allocator.create(Node);
        errdefer tree.allocator.destroy(self);
        const yoga_node = y.YGNodeNew() orelse return error.OutOfMemory;
        errdefer y.YGNodeFree(yoga_node);
        self.* = .{ .allocator = tree.allocator, .L = tree.L, .yoga = yoga_node, .kind = kind };
        y.YGNodeSetContext(yoga_node, self);
        if (kind == .text) {
            const text = try ot.UnifiedTextBuffer.init(tree.allocator, tree.graphemes, tree.links, .unicode);
            errdefer text.deinit();
            self.view = try ot.UnifiedTextBufferView.init(tree.allocator, text);
            self.text = text;
            y.YGNodeSetMeasureFunc(yoga_node, measure);
        }
        return self;
    }

    pub fn destroy(self: *Node) void {
        for (self.children) |child| child.destroy();
        self.allocator.free(self.children);
        if (self.view) |view| view.deinit();
        if (self.text) |text| text.deinit();
        if (self.key) |key| self.allocator.free(key);
        if (self.content) |text| self.allocator.free(text);
        if (self.reference != c.LUA_NOREF) c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, self.reference);
        y.YGNodeFree(self.yoga);
        self.allocator.destroy(self);
    }

    fn measure(node: y.YGNodeConstRef, width: f32, width_mode: y.YGMeasureMode, height: f32, height_mode: y.YGMeasureMode) callconv(.c) y.YGSize {
        _ = height;
        _ = height_mode;
        const context = y.YGNodeGetContext(node) orelse return .{ .width = 0, .height = 0 };
        const self: *Node = @ptrCast(@alignCast(context));
        const constraint: u32 = if (width_mode == y.YGMeasureModeUndefined or !std.math.isFinite(width)) 0 else @intFromFloat(@max(0, width));
        const result = self.view.?.measureForDimensions(constraint, 0) catch return .{ .width = 0, .height = 0 };
        const measured: f32 = @floatFromInt(result.width_cols_max);
        return .{
            .width = if (width_mode == y.YGMeasureModeAtMost) @min(width, measured) else measured,
            .height = @floatFromInt(result.line_count),
        };
    }

    fn sync(self: *Node, tree: *Tree, index: c_int, depth: usize, count: *usize) anyerror!void {
        if (depth > 64 or count.* >= 8192) return error.WidgetTreeTooLarge;
        count.* += 1;
        const L = self.L;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        const absolute = c.lua_absindex(L, index);
        if (c.lua_type(L, absolute) != c.LUA_TTABLE) return error.InvalidNode;
        _ = c.lua_getfield(L, absolute, "props");
        const props = c.lua_absindex(L, -1);
        if (c.lua_type(L, props) != c.LUA_TTABLE) return error.InvalidNode;

        const key = fieldString(L, props, "key", "");
        if (self.key == null or !std.mem.eql(u8, self.key.?, key)) {
            const next = try self.allocator.dupe(u8, key);
            if (self.key) |previous| self.allocator.free(previous);
            self.key = next;
        }
        c.lua_pushvalue(L, absolute);
        const next_reference = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
        if (self.reference != c.LUA_NOREF) c.luaL_unref(L, c.LUA_REGISTRYINDEX, self.reference);
        self.reference = next_reference;
        self.fg = try color(L, props, "fg");
        self.bg = (try color(L, props, "backgroundColor")) orelse try color(L, props, "bg");
        self.border_color = try color(L, props, "borderColor");
        self.attributes = @intFromFloat(number(L, props, "attributes", 0));
        self.border = boolean(L, props, "border");
        self.clip = std.mem.eql(u8, fieldString(L, props, "overflow", "visible"), "hidden");
        const border_style = fieldString(L, props, "borderStyle", "rounded");
        self.border_chars = if (std.mem.eql(u8, border_style, "single")) &single else if (std.mem.eql(u8, border_style, "double")) &double else &rounded;

        const node = self.yoga;
        inline for (.{ "Width", "Height", "MinWidth", "MinHeight", "MaxWidth", "MaxHeight", "FlexBasis" }, .{ "width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight", "flexBasis" }) |suffix, name| {
            try dimension(node, L, props, name, suffix);
        }
        y.YGNodeStyleSetFlexGrow(node, number(L, props, "flexGrow", 0));
        y.YGNodeStyleSetFlexShrink(node, number(L, props, "flexShrink", 1));
        y.YGNodeStyleSetFlexDirection(node, enumValue(fieldString(L, props, "flexDirection", "column"), .{ "column", "row", "column-reverse", "row-reverse" }, .{ y.YGFlexDirectionColumn, y.YGFlexDirectionRow, y.YGFlexDirectionColumnReverse, y.YGFlexDirectionRowReverse }, y.YGFlexDirectionColumn));
        y.YGNodeStyleSetJustifyContent(node, enumValue(fieldString(L, props, "justifyContent", "flex-start"), .{ "flex-start", "center", "flex-end", "space-between", "space-around", "space-evenly" }, .{ y.YGJustifyFlexStart, y.YGJustifyCenter, y.YGJustifyFlexEnd, y.YGJustifySpaceBetween, y.YGJustifySpaceAround, y.YGJustifySpaceEvenly }, y.YGJustifyFlexStart));
        inline for (.{ "alignItems", "alignSelf" }, .{ y.YGNodeStyleSetAlignItems, y.YGNodeStyleSetAlignSelf }, .{ y.YGAlignStretch, y.YGAlignAuto }) |name, set, default| {
            set(node, enumValue(fieldString(L, props, name, ""), .{ "auto", "stretch", "flex-start", "center", "flex-end", "baseline" }, .{ y.YGAlignAuto, y.YGAlignStretch, y.YGAlignFlexStart, y.YGAlignCenter, y.YGAlignFlexEnd, y.YGAlignBaseline }, default));
        }
        y.YGNodeStyleSetFlexWrap(node, enumValue(fieldString(L, props, "flexWrap", "no-wrap"), .{ "no-wrap", "wrap", "wrap-reverse" }, .{ y.YGWrapNoWrap, y.YGWrapWrap, y.YGWrapWrapReverse }, y.YGWrapNoWrap));
        y.YGNodeStyleSetPositionType(node, if (std.mem.eql(u8, fieldString(L, props, "position", "relative"), "absolute")) y.YGPositionTypeAbsolute else y.YGPositionTypeRelative);
        y.YGNodeStyleSetOverflow(node, if (self.clip) y.YGOverflowHidden else y.YGOverflowVisible);
        y.YGNodeStyleSetBorder(node, y.YGEdgeAll, if (self.border) 1 else 0);

        inline for (.{ "Padding", "Margin" }, .{ "padding", "margin" }) |suffix, name| {
            inline for (.{ y.YGEdgeAll, y.YGEdgeHorizontal, y.YGEdgeVertical, y.YGEdgeTop, y.YGEdgeRight, y.YGEdgeBottom, y.YGEdgeLeft }, 0..) |which, i| {
                @field(y, "YGNodeStyleSet" ++ suffix)(node, which, if (i == 0) 0 else std.math.nan(f32));
                const ending = .{ "", "X", "Y", "Top", "Right", "Bottom", "Left" }[i];
                try edge(node, L, props, name ++ ending, suffix, which);
            }
        }
        inline for (.{ "top", "right", "bottom", "left" }, .{ y.YGEdgeTop, y.YGEdgeRight, y.YGEdgeBottom, y.YGEdgeLeft }) |name, which| {
            y.YGNodeStyleSetPosition(node, which, std.math.nan(f32));
            try edge(node, L, props, name, "Position", which);
        }
        inline for (.{ "gap", "rowGap", "columnGap" }, .{ y.YGGutterAll, y.YGGutterRow, y.YGGutterColumn }, 0..) |name, which, i| {
            _ = c.lua_getfield(L, props, name);
            if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
                y.YGNodeStyleSetGap(node, which, @floatCast(c.lua_tonumberx(L, -1, null)));
            } else {
                const value = lua.string(L, -1);
                if (std.mem.endsWith(u8, value, "%")) {
                    y.YGNodeStyleSetGapPercent(node, which, try std.fmt.parseFloat(f32, value[0 .. value.len - 1]));
                } else y.YGNodeStyleSetGap(node, which, if (i == 0) 0 else std.math.nan(f32));
            }
            lua.pop(L, 1);
        }

        if (self.text) |text| {
            const content = fieldString(L, props, "content", "");
            if (self.content == null or !std.mem.eql(u8, self.content.?, content)) {
                const owned = try self.allocator.dupe(u8, content);
                errdefer self.allocator.free(owned);
                try text.setText(content);
                if (self.content) |previous| self.allocator.free(previous);
                self.content = owned;
                y.YGNodeMarkDirty(node);
            }
            const wrap = fieldString(L, props, "wrapMode", "word");
            const mode: ot.text_buffer.WrapMode = if (std.mem.eql(u8, wrap, "none")) .none else if (std.mem.eql(u8, wrap, "char")) .char else .word;
            self.view.?.setWrapMode(mode);
            y.YGNodeMarkDirty(node);
            return;
        }

        _ = c.lua_getfield(L, absolute, "children");
        if (c.lua_type(L, -1) != c.LUA_TTABLE) return error.InvalidNode;
        const children_index = c.lua_absindex(L, -1);
        const length = c.lua_rawlen(L, children_index);
        if (length > 4096) return error.WidgetTreeTooLarge;
        const children = try self.allocator.alloc(*Node, length);
        var initialized: usize = 0;
        errdefer {
            for (children[0..initialized]) |child| {
                var existing = false;
                for (self.children) |previous| if (child == previous) {
                    existing = true;
                    break;
                };
                if (!existing) child.destroy();
            }
            self.allocator.free(children);
        }
        const used = try self.allocator.alloc(bool, self.children.len);
        defer self.allocator.free(used);
        @memset(used, false);
        for (0..length) |i| {
            _ = c.lua_rawgeti(L, children_index, @intCast(i + 1));
            const kind = try nodeKind(L, -1);
            _ = c.lua_getfield(L, -1, "props");
            const child_key = fieldString(L, -1, "key", "");
            var found: ?*Node = null;
            for (self.children, 0..) |previous, old_index| {
                if (used[old_index] or previous.kind != kind) continue;
                const matches = if (child_key.len > 0)
                    std.mem.eql(u8, previous.key orelse "", child_key)
                else
                    old_index == i and (previous.key == null or previous.key.?.len == 0);
                if (matches) {
                    used[old_index] = true;
                    found = previous;
                    break;
                }
            }
            lua.pop(L, 1);
            children[i] = found orelse try Node.create(tree, kind);
            initialized += 1;
            try children[i].sync(tree, -1, depth + 1, count);
            lua.pop(L, 1);
        }
        var same = children.len == self.children.len;
        if (same) for (children, self.children) |a, b| {
            if (a != b) {
                same = false;
                break;
            }
        };
        if (!same) {
            y.YGNodeRemoveAllChildren(node);
            for (children, 0..) |child, i| y.YGNodeInsertChild(node, child.yoga, @intCast(i));
        }
        for (self.children, used) |previous, retained| if (!retained) previous.destroy();
        self.allocator.free(self.children);
        self.children = children;
    }

    fn paint(self: *Node, buffer: *ot.OptimizedBuffer, parent_x: i32, parent_y: i32, inherited_fg: ot.RGBA) anyerror!void {
        self.x = parent_x + @as(i32, @intFromFloat(@round(y.YGNodeLayoutGetLeft(self.yoga))));
        self.y_pos = parent_y + @as(i32, @intFromFloat(@round(y.YGNodeLayoutGetTop(self.yoga))));
        self.width = @intFromFloat(@max(0, @round(y.YGNodeLayoutGetWidth(self.yoga))));
        self.height = @intFromFloat(@max(0, @round(y.YGNodeLayoutGetHeight(self.yoga))));
        if (self.width == 0 or self.height == 0) return;
        const fg = self.fg orelse inherited_fg;
        if (self.bg != null or self.border) {
            try buffer.drawBox(self.x, self.y_pos, self.width, self.height, self.border_chars, if (self.border) all_sides else .{}, self.border_color orelse fg, self.bg orelse transparent, fg, self.bg != null, null, 0, null, 0);
        }
        if (self.clip) try buffer.pushScissorRect(self.x, self.y_pos, self.width, self.height);
        defer if (self.clip) buffer.popScissorRect();
        if (self.text) |text| {
            const left = y.YGNodeLayoutGetPadding(self.yoga, y.YGEdgeLeft) + y.YGNodeLayoutGetBorder(self.yoga, y.YGEdgeLeft);
            const right = y.YGNodeLayoutGetPadding(self.yoga, y.YGEdgeRight) + y.YGNodeLayoutGetBorder(self.yoga, y.YGEdgeRight);
            const top = y.YGNodeLayoutGetPadding(self.yoga, y.YGEdgeTop) + y.YGNodeLayoutGetBorder(self.yoga, y.YGEdgeTop);
            const bottom = y.YGNodeLayoutGetPadding(self.yoga, y.YGEdgeBottom) + y.YGNodeLayoutGetBorder(self.yoga, y.YGEdgeBottom);
            const w = self.width -| @as(u32, @intFromFloat(@max(0, left + right)));
            const h = self.height -| @as(u32, @intFromFloat(@max(0, top + bottom)));
            if (w == 0 or h == 0) return;
            text.setDefaultFg(fg);
            text.setDefaultBg(self.bg orelse transparent);
            text.setDefaultAttributes(self.attributes);
            self.view.?.setViewport(.{ .x = 0, .y = 0, .width = w, .height = h });
            buffer.drawTextBuffer(self.view.?, self.x + @as(i32, @intFromFloat(left)), self.y_pos + @as(i32, @intFromFloat(top)));
        }
        for (self.children) |child| try child.paint(buffer, self.x, self.y_pos, fg);
    }

    pub fn firstHandler(self: *Node, handler: [:0]const u8) ?*Node {
        if (self.hasHandler(handler)) return self;
        for (self.children) |child| if (child.firstHandler(handler)) |found| return found;
        return null;
    }

    fn hasHandler(self: *Node, handler: [:0]const u8) bool {
        const top = c.lua_gettop(self.L);
        defer c.lua_settop(self.L, top);
        _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, self.reference);
        _ = c.lua_getfield(self.L, -1, "props");
        _ = c.lua_getfield(self.L, -1, handler);
        return c.lua_type(self.L, -1) == c.LUA_TFUNCTION;
    }

    pub fn hit(self: *Node, x: i32, y_pos: i32, handler: [:0]const u8) ?*Node {
        const inside = x >= self.x and y_pos >= self.y_pos and x - self.x < self.width and y_pos - self.y_pos < self.height;
        if (self.clip and !inside) return null;
        var index = self.children.len;
        while (index > 0) {
            index -= 1;
            if (self.children[index].hit(x, y_pos, handler)) |child| return child;
        }
        if (!inside) return null;
        return if (self.hasHandler(handler)) self else null;
    }
};

fn nodeKind(L: *c.lua_State, index: c_int) !@FieldType(Node, "kind") {
    if (c.lua_type(L, index) != c.LUA_TTABLE) return error.InvalidNode;
    const kind = fieldString(L, index, "kind", "");
    if (std.mem.eql(u8, kind, "box")) return .box;
    if (std.mem.eql(u8, kind, "text")) return .text;
    return error.InvalidNode;
}

pub const Tree = struct {
    allocator: std.mem.Allocator,
    L: *c.lua_State,
    graphemes: *ot.GraphemePool,
    links: *ot.LinkPool,
    root: ?*Node = null,

    pub fn deinit(self: *Tree) void {
        if (self.root) |root| root.destroy();
    }

    pub fn sync(self: *Tree, index: c_int) !void {
        const kind = try nodeKind(self.L, index);
        if (self.root == null or self.root.?.kind != kind) {
            const next = try Node.create(self, kind);
            errdefer next.destroy();
            var count: usize = 0;
            try next.sync(self, index, 0, &count);
            if (self.root) |previous| previous.destroy();
            self.root = next;
        } else {
            var count: usize = 0;
            try self.root.?.sync(self, index, 0, &count);
        }
    }

    pub fn draw(self: *Tree, buffer: *ot.OptimizedBuffer, rect: Rect) !void {
        const root = self.root orelse return;
        if (rect.width == 0 or rect.height == 0) return;
        y.YGNodeStyleSetWidth(root.yoga, @floatFromInt(rect.width));
        y.YGNodeStyleSetHeight(root.yoga, @floatFromInt(rect.height));
        y.YGNodeCalculateLayout(root.yoga, @floatFromInt(rect.width), @floatFromInt(rect.height), y.YGDirectionLTR);
        try buffer.pushScissorRect(@intCast(rect.x), @intCast(rect.y), rect.width, rect.height);
        defer buffer.popScissorRect();
        try root.paint(buffer, @intCast(rect.x), @intCast(rect.y), foreground);
    }
};
