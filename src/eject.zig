//! eject 相关功能

const std = @import("std");
const Mangle = @import("transpiler/mangle.zig");
const cli = @import("cli/args.zig");

/// 构建模式
pub const BuildMode = enum { build, run, test_ };

/// 构建验证结果
pub const BuildVerify = enum { ok, fail, no_zig };

/// 生成 eject 的 build.zig.zon 文本
pub fn ejectZoneText(gpa: std.mem.Allocator, app_name: []const u8, fp: ?[]const u8) ![]const u8 {
    var z = std.ArrayList(u8).init(gpa);
    errdefer z.deinit();

    try z.appendSlice(gpa, "// 由 zzc eject 生成；可独立 `zig build` 构建。\n.{\n");
    try z.appendSlice(gpa, try std.fmt.allocPrint(gpa, "    .name = .{s},\n", .{app_name}));
    try z.appendSlice(gpa, "    .version = \"0.1.0\",\n");
    if (fp) |t| try z.appendSlice(gpa, try std.fmt.allocPrint(gpa, "    .fingerprint = {s},\n", .{t}));
    try z.appendSlice(gpa, "    .minimum_zig_version = \"0.17.0\",\n");
    try z.appendSlice(gpa, "    .dependencies = .{},\n");
    try z.appendSlice(gpa, "    .paths = .{\n        \"build.zig\",\n        \"build.zig.zon\",\n        \"src\",\n    },\n}\n");

    return z.toOwnedSlice();
}

/// 探测 fingerprint
pub fn probeFingerprint(gpa: std.mem.Allocator, dest: []const u8) ?[]const u8 {
    const res = std.process.run(gpa, &.{ "zig", "build" }, .{
        .cwd = .{ .path = dest },
        .create_no_window = true,
    }) catch return null;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const marker = "value: 0x";
    const idx = std.mem.indexOf(u8, res.stderr, marker) orelse return null;
    const digits_start = idx + marker.len;
    var end = digits_start;
    while (end < res.stderr.len and std.ascii.isHex(res.stderr[end])) end += 1;
    if (end == digits_start) return null;

    const zero_x = idx + (marker.len - 2);
    return gpa.dupe(u8, res.stderr[zero_x..end]) catch null;
}

/// 读取现有 fingerprint
pub fn readExistingFingerprint(gpa: std.mem.Allocator, dest: []const u8, app_name: []const u8) ?[]const u8 {
    const zon_path = std.fmt.allocPrint(gpa, "{s}/build.zig.zon", .{dest}) catch return null;
    defer gpa.free(zon_path);

    const text = std.fs.cwd().readFileAlloc(gpa, zon_path, 1024 * 1024) catch return null;
    defer gpa.free(text);

    return cli.parseFingerprintFromZone(text, app_name) catch null;
}

/// 验证构建
pub fn verifyBuild(gpa: std.mem.Allocator, dest: []const u8) BuildVerify {
    const res = std.process.run(gpa, &.{ "zig", "build" }, .{
        .cwd = .{ .path = dest },
        .create_no_window = true,
    }) catch return .no_zig;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    return if (res.term.success()) .ok else .fail;
}