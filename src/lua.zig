const std = @import("std");
pub const c = @import("ffi");

pub fn pop(L: *c.lua_State, count: c_int) void {
    c.lua_settop(L, -count - 1);
}

pub fn string(L: *c.lua_State, index: c_int) []const u8 {
    var length: usize = 0;
    const pointer = c.lua_tolstring(L, index, &length) orelse return "";
    return pointer[0..length];
}

pub fn pushString(L: *c.lua_State, value: []const u8) void {
    _ = c.lua_pushlstring(L, value.ptr, value.len);
}

pub fn pushJson(L: *c.lua_State, value: std.json.Value) !void {
    switch (value) {
        .null => c.lua_pushnil(L),
        .bool => |v| c.lua_pushboolean(L, @intFromBool(v)),
        .integer => |v| c.lua_pushinteger(L, v),
        .float => |v| c.lua_pushnumber(L, v),
        .number_string => |v| c.lua_pushnumber(L, try std.fmt.parseFloat(f64, v)),
        .string => |v| pushString(L, v),
        .array => |array| {
            c.lua_createtable(L, @intCast(array.items.len), 0);
            for (array.items, 1..) |item, index| {
                try pushJson(L, item);
                c.lua_rawseti(L, -2, @intCast(index));
            }
        },
        .object => |object| {
            c.lua_createtable(L, 0, @intCast(object.count()));
            var it = object.iterator();
            while (it.next()) |entry| {
                pushString(L, entry.key_ptr.*);
                try pushJson(L, entry.value_ptr.*);
                c.lua_settable(L, -3);
            }
        },
    }
}

pub const Vm = struct {
    allocator: std.mem.Allocator,
    L: *c.lua_State,
    runtime: c_int,
    last_error: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) !Vm {
        const L = c.luaL_newstate() orelse return error.OutOfMemory;
        var self = Vm{ .allocator = allocator, .L = L, .runtime = c.LUA_NOREF };
        errdefer self.deinit();
        c.luaL_openlibs(L);
        c.lua_pushcclosure(L, c.haunt_lua_command, 0);
        c.lua_setglobal(L, "_haunt_command");
        try self.eval("@haunt-ascii.lua", @embedFile("lua/ascii.lua"), 1);
        c.lua_createtable(L, 0, 7);
        inline for (@import("font_data").names, @import("font_data").sources) |name, source| {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
            defer parsed.deinit();
            try pushJson(L, parsed.value);
            c.lua_setfield(L, -2, name);
        }
        try self.call(1, 1);
        c.lua_setglobal(L, "_haunt_ascii");
        try self.eval("@haunt.lua", @embedFile("lua/haunt.lua"), 1);
        c.lua_setglobal(L, "_haunt");
        try self.eval("@haunt-init", "package.loaded.haunt = _haunt", 0);
        try self.eval("@haunt-runtime.lua", @embedFile("lua/runtime.lua"), 1);
        _ = c.lua_getfield(L, -1, "new");
        c.lua_pushcclosure(L, c.haunt_lua_now, 0);
        try self.call(1, 1);
        self.runtime = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
        pop(L, 1);
        return self;
    }

    pub fn deinit(self: *Vm) void {
        if (self.runtime != c.LUA_NOREF) {
            self.method("close");
            self.call(0, 0) catch {};
        }
        c.lua_close(self.L);
        if (self.last_error) |message| self.allocator.free(message);
    }

    pub fn setError(self: *Vm, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        if (self.last_error) |previous| self.allocator.free(previous);
        self.last_error = owned;
    }

    pub fn call(self: *Vm, arguments: c_int, results: c_int) !void {
        if (c.haunt_lua_pcall(self.L, arguments, results) != c.LUA_OK) {
            try self.setError(string(self.L, -1));
            pop(self.L, 1);
            return error.LuaFailure;
        }
    }

    pub fn eval(self: *Vm, name: [:0]const u8, source: []const u8, results: c_int) !void {
        if (c.luaL_loadbufferx(self.L, source.ptr, source.len, name, "t") != c.LUA_OK) {
            try self.setError(string(self.L, -1));
            pop(self.L, 1);
            return error.LuaFailure;
        }
        try self.call(0, results);
    }

    pub fn method(self: *Vm, name: [:0]const u8) void {
        _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, self.runtime);
        _ = c.lua_getfield(self.L, -1, name);
        c.lua_rotate(self.L, -2, -1);
        pop(self.L, 1);
    }

    pub fn load(self: *Vm, id: []const u8, path: []const u8, options: ?std.json.Value, width: u32, height: u32) !bool {
        const top = c.lua_gettop(self.L);
        defer c.lua_settop(self.L, top);
        self.method("load");
        pushString(self.L, id);
        pushString(self.L, path);
        if (options) |value| try pushJson(self.L, value) else c.lua_createtable(self.L, 0, 0);
        c.lua_pushinteger(self.L, width);
        c.lua_pushinteger(self.L, height);
        try self.call(5, 2);
        if (c.lua_toboolean(self.L, -2) == 0) {
            try self.setError(string(self.L, -1));
            return false;
        }
        return true;
    }

    pub fn poll(self: *Vm) !bool {
        self.method("poll");
        try self.call(0, 1);
        defer pop(self.L, 1);
        return c.lua_toboolean(self.L, -1) != 0;
    }

    pub fn remove(self: *Vm, id: []const u8) !void {
        const top = c.lua_gettop(self.L);
        defer c.lua_settop(self.L, top);
        self.method("remove");
        pushString(self.L, id);
        try self.call(1, 0);
    }

    pub fn nextDelay(self: *Vm) !c_int {
        self.method("next_delay");
        try self.call(0, 1);
        defer pop(self.L, 1);
        return @intCast(std.math.clamp(c.lua_tointegerx(self.L, -1, null), 0, 1000));
    }

    /// Push scene, version, error, and title. The caller keeps them live during reconciliation.
    pub fn frame(self: *Vm, id: []const u8, width: u32, height: u32) !void {
        self.method("frame");
        pushString(self.L, id);
        c.lua_pushinteger(self.L, width);
        c.lua_pushinteger(self.L, height);
        try self.call(3, 4);
    }
};
