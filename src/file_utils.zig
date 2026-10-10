//! 文件操作工具函数

const std = @import("std");

/// 默认最大文件大小：100MB
pub const DEFAULT_MAX_FILE_SIZE: usize = 100 * 1024 * 1024;

/// 读取整个文件内容到内存（带大小限制）
pub fn readWhole(path: []const u8) ![]const u8 {
    return readWholeWithLimit(path, DEFAULT_MAX_FILE_SIZE);
}

/// 读取整个文件内容到内存（带自定义大小限制）
pub fn readWholeWithLimit(path: []const u8, max_size: usize) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    const size = try file.getEndPos();
    if (size > max_size) return error.FileTooLarge;

    const buf = try std.heap.page_allocator.alloc(u8, size);
    errdefer std.heap.page_allocator.free(buf);

    const bytes_read = try file.readAll(buf);
    if (bytes_read != size) return error.Unexpected;

    return buf;
}

/// 写入整个文件内容（自动创建父目录）
pub fn writeWhole(path: []const u8, data: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    std.fs.cwd().makePath(dir) catch |e| {
        std.debug.print("警告：无法创建目录 {s}：{s}\n", .{ dir, @errorName(e) });
        return e;
    };

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(data);
}

/// 检查路径是否存在
pub fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// 读取原始字节（不剥离 BOM）
pub fn readFileRaw(path: []const u8) ![]const u8 {
    return readWhole(path);
}

/// 生成目标文件路径
pub fn genPathFor(gpa: std.mem.Allocator, rel: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, rel, "src/")) {
        return std.fmt.allocPrint(gpa, ".zzc/gen/{s}", .{rel});
    }
    return std.fmt.allocPrint(gpa, ".zzc/gen/{s}", .{rel});
}

/// 路径比较（分隔符无关）
pub fn samePathRel(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const norm_a = std.mem.replaceScalar(u8, a, '\\', '/') catch a;
    const norm_b = std.mem.replaceScalar(u8, b, '\\', '/') catch b;
    return std.mem.eql(u8, norm_a, norm_b);
}