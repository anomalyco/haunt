const std = @import("std");
const builtin = @import("builtin");

const lua_sources = [_][]const u8{
    "lapi.c",    "lauxlib.c",  "lbaselib.c", "lcode.c",    "lcorolib.c", "lctype.c",
    "ldblib.c",  "ldebug.c",   "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
    "linit.c",   "liolib.c",   "llex.c",     "lmathlib.c", "lmem.c",     "loadlib.c",
    "lobject.c", "lopcodes.c", "loslib.c",   "lparser.c",  "lstate.c",   "lstring.c",
    "lstrlib.c", "ltable.c",   "ltablib.c",  "ltm.c",      "lundump.c",  "lutf8lib.c",
    "lvm.c",     "lzio.c",
};

pub fn build(b: *std.Build) void {
    var default_target = b.graph.host.query;
    if (builtin.os.tag == .linux) {
        // Match OpenTUI's native executable target, avoiding host glibc startup ABI drift.
        default_target.abi = .musl;
        default_target.glibc_version = null;
    }
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const opentui = b.dependency("opentui", .{ .target = target, .optimize = optimize });

    // Embed the exact font assets used by OpenTUI's ASCIIFont renderable.
    const font_files = b.addWriteFiles();
    const font_names = .{ "tiny", "block", "shade", "slick", "huge", "grid", "pallet" };
    comptime var font_source: []const u8 = "pub const names = .{";
    inline for (font_names) |name| {
        _ = font_files.addCopyFile(b.path(".deps/opentui/packages/core/src/lib/fonts/" ++ name ++ ".json"), name ++ ".json");
        font_source = font_source ++ "\"" ++ name ++ "\",";
    }
    font_source = font_source ++ "};\npub const sources = .{";
    inline for (font_names) |name| font_source = font_source ++ "@embedFile(\"" ++ name ++ ".json\"),";
    font_source = font_source ++ "};\n";
    const font_data = b.createModule(.{ .root_source_file = font_files.add("fonts.zig", font_source) });

    const lua = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    lua.addIncludePath(b.path(".deps/lua/src"));
    lua.addIncludePath(b.path("src"));
    const flags: []const []const u8 = if (target.result.os.tag == .linux)
        &.{ "-std=c99", "-DLUA_USE_LINUX" }
    else
        &.{ "-std=c99", "-DLUA_USE_MACOSX" };
    lua.addCSourceFiles(.{ .root = b.path(".deps/lua/src"), .files = &lua_sources, .flags = flags });
    lua.addCSourceFile(.{ .file = b.path("src/platform.c"), .flags = &.{"-std=c99"} });
    lua.linkSystemLibrary("m", .{});
    if (target.result.os.tag == .linux) lua.linkSystemLibrary("dl", .{});
    const lua_lib = b.addLibrary(.{ .name = "haunt-lua", .root_module = lua, .linkage = .static });

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/ffi.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path(".deps/lua/src"));
    const ffi = translate.createModule();

    const main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main.addImport("opentui", opentui.module("opentui"));
    main.addImport("ffi", ffi);
    main.addImport("font_data", font_data);
    main.linkLibrary(lua_lib);
    const exe = b.addExecutable(.{ .name = "haunt", .root_module = main });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Haunt (default: examples/clock.json)").dependOn(&run.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("opentui", opentui.module("opentui"));
    test_module.addImport("ffi", ffi);
    test_module.addImport("font_data", font_data);
    test_module.linkLibrary(lua_lib);
    const tests = b.addTest(.{ .root_module = test_module });
    const test_run = b.addRunArtifact(tests);
    test_run.setCwd(b.path("."));
    b.step("test", "Test the Lua lifecycle and native layout/rendering").dependOn(&test_run.step);
}
