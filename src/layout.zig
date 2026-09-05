const std = @import("std");

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn overlaps(a: Rect, b: Rect) bool {
        if (a.width == 0 or a.height == 0 or b.width == 0 or b.height == 0) return false;
        return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height;
    }

    pub fn fitsWithin(self: Rect, width: u32, height: u32) bool {
        if (self.width == 0 or self.height == 0 or self.width > width or self.height > height) return false;
        return self.x <= width - self.width and self.y <= height - self.height;
    }

    pub fn contains(self: Rect, x: u32, y: u32) bool {
        return x >= self.x and y >= self.y and x - self.x < self.width and y - self.y < self.height;
    }
};

pub const Grid = struct { columns: u32, rows: u32 };
pub const Appearance = struct { borders: bool = false };
pub const Widget = struct {
    id: []const u8,
    widget: []const u8,
    rect: Rect,
    options: ?std.json.Value = null,
};
pub const Document = struct {
    version: u32,
    id: []const u8,
    name: []const u8,
    grid: Grid,
    widgets: []Widget,
    appearance: Appearance = .{},

    pub fn fits(self: Document, rect: Rect, skip: ?usize) bool {
        if (!rect.fitsWithin(self.grid.columns, self.grid.rows)) return false;
        for (self.widgets, 0..) |widget, index| {
            if (skip != null and skip.? == index) continue;
            if (rect.overlaps(widget.rect)) return false;
        }
        return true;
    }

    pub fn fitsCells(self: Document, rect: Rect, skip: usize, width: u32, height: u32) bool {
        if (!rect.fitsWithin(width, height)) return false;
        for (self.widgets, 0..) |widget, index| {
            if (index == skip) continue;
            if (rect.overlaps(self.pixels(widget.rect, width, height))) return false;
        }
        return true;
    }

    pub fn validate(self: Document) !void {
        if (self.version != 1) return error.UnsupportedLayoutVersion;
        if (self.grid.columns == 0 or self.grid.rows == 0 or self.grid.columns > std.math.maxInt(u16) or self.grid.rows > std.math.maxInt(u16)) return error.InvalidGrid;
        if (self.id.len == 0 or self.name.len == 0 or self.widgets.len > 256) return error.InvalidLayout;
        // Validate bounds before overlap checks, so malformed integers cannot overflow.
        for (self.widgets) |widget| {
            const r = widget.rect;
            if (!r.fitsWithin(self.grid.columns, self.grid.rows)) return error.InvalidWidgetBounds;
            if (widget.id.len == 0 or widget.widget.len == 0 or std.mem.indexOfScalar(u8, widget.widget, 0) != null) return error.InvalidWidget;
            if (widget.options) |value| if (value != .object) return error.InvalidWidgetOptions;
        }
        for (self.widgets, 0..) |widget, index| {
            if (!self.fits(widget.rect, index)) return error.OverlappingWidgets;
            for (self.widgets[0..index]) |previous| if (std.mem.eql(u8, widget.id, previous.id)) return error.DuplicateWidgetId;
        }
    }

    pub fn pixels(self: Document, rect: Rect, width: u32, height: u32) Rect {
        const x = scale(rect.x, width, self.grid.columns);
        const right = scale(rect.x + rect.width, width, self.grid.columns);
        const y = scale(rect.y, height, self.grid.rows);
        const bottom = scale(rect.y + rect.height, height, self.grid.rows);
        return .{ .x = x, .y = y, .width = right - x, .height = bottom - y };
    }

    fn scale(value: u32, extent: u32, units: u32) u32 {
        return @intCast(@as(u64, value) * extent / units);
    }
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    source: []u8,
    parsed: std.json.Parsed(Document),
    disk_hash: u64,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Layout {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        const absolute = try std.fs.path.resolve(allocator, &.{ cwd, path });
        defer allocator.free(absolute);
        const owned_path = try allocator.dupeZ(u8, absolute);
        errdefer allocator.free(owned_path);
        const source = try std.Io.Dir.cwd().readFileAlloc(io, owned_path, allocator, .limited(1024 * 1024));
        errdefer allocator.free(source);
        const parsed = try std.json.parseFromSlice(Document, allocator, source, .{});
        errdefer parsed.deinit();
        try parsed.value.validate();
        return .{ .allocator = allocator, .path = owned_path, .source = source, .parsed = parsed, .disk_hash = std.hash.Wyhash.hash(0, source) };
    }

    pub fn deinit(self: *Layout) void {
        self.parsed.deinit();
        self.allocator.free(self.source);
        self.allocator.free(self.path);
    }

    pub fn widgetPath(self: Layout, widget: Widget) ![:0]u8 {
        const resolved = try std.fs.path.resolve(self.allocator, &.{ std.fs.path.dirname(self.path).?, widget.widget });
        defer self.allocator.free(resolved);
        return self.allocator.dupeZ(u8, resolved);
    }

    /// Save an exact terminal-cell placement while retaining the displayed
    /// rectangles of all other widgets. The grid becomes the reference viewport.
    pub fn placeCells(self: *Layout, io: std.Io, index: usize, rect: Rect, width: u32, height: u32) !void {
        const doc = &self.parsed.value;
        if (index >= doc.widgets.len or !doc.fitsCells(rect, index, width, height)) return error.InvalidWidgetBounds;
        const previous_grid = doc.grid;
        const previous_rects = try self.allocator.alloc(Rect, doc.widgets.len);
        defer self.allocator.free(previous_rects);
        for (doc.widgets, previous_rects) |widget, *previous| previous.* = widget.rect;
        errdefer {
            doc.grid = previous_grid;
            for (doc.widgets, previous_rects) |*widget, previous| widget.rect = previous;
        }

        for (doc.widgets) |*widget| widget.rect = doc.pixels(widget.rect, width, height);
        doc.grid = .{ .columns = width, .rows = height };
        doc.widgets[index].rect = rect;
        try doc.validate();
        try self.save(io);
    }

    pub fn save(self: *Layout, io: std.Io) !void {
        const current = try std.Io.Dir.cwd().readFileAlloc(io, self.path, self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(current);
        if (std.hash.Wyhash.hash(0, current) != self.disk_hash) return error.LayoutChangedOnDisk;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, self.parsed.value, .{ .whitespace = .indent_2 });
        defer self.allocator.free(encoded);
        const temporary = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(temporary);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = encoded });
        errdefer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        try std.Io.Dir.renameAbsolute(temporary, self.path, io);
        self.disk_hash = std.hash.Wyhash.hash(0, encoded);
    }
};
