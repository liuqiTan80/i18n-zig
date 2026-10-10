//! 输出工具函数

const std = @import("std");

/// 标准输出
pub fn printOut(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt ++ "\n", args) catch |e| {
        std.io.getStdErr().writer().print("标准输出失败：{s}\n", .{@errorName(e)}) catch {};
    };
}

/// 错误输出
pub fn printErr(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print(fmt ++ "\n", args) catch {};
}