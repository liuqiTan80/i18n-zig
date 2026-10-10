//! 嵌入资源文件处理

const std = @import("std");
const Pack = @import("lang/pack.zig");

/// 提取 @embedFile 路径列表
pub fn extractEmbedPaths(gpa: std.mem.Allocator, zig_str: []const u8) std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).init(gpa);
    var i: usize = 0;

    while (i < zig_str.len) {
        const idx = std.mem.indexOf(u8, zig_str[i..], "@embedFile(") orelse break;
        const start = i + idx + "@embedFile(".len;
        const end = std.mem.indexOf(u8, zig_str[start..], ")") orelse break;
        const path = std.mem.trim(u8, zig_str[start..][0..end], " \"'");
        list.append(gpa, path) catch {};
        i = start + end + 1;
    }

    return list;
}

/// 获取嵌入文件词形列表
pub fn embedWordForms(gpa: std.mem.Allocator, lang: Pack) ![]const []const u8 {
    var forms = std.ArrayList([]const u8).init(gpa);
    try forms.append(gpa, "@embedFile");

    var iter = lang.keywords.iterator();
    while (iter.next()) |entry| {
        if (std.mem.indexOf(u8, entry.value_ptr.*, "@embedFile") != null) {
            try forms.append(gpa, entry.key_ptr.*);
        }
    }

    return forms.toOwnedSlice();
}

/// 获取关键字词形列表
pub fn keywordFormsFor(gpa: std.mem.Allocator, lang: Pack, want: []const u8) ![]const []const u8 {
    var forms = std.ArrayList([]const u8).init(gpa);
    try forms.append(gpa, want);

    var iter = lang.aliases.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, want)) {
            try forms.append(gpa, entry.key_ptr.*);
        }
    }

    return forms.toOwnedSlice();
}

/// 检查嵌入路径是否保持在镜像根内
pub fn embedPathStaysWithin(gpa: std.mem.Allocator, root: []const u8, dst_dir: []const u8, p: []const u8) bool {
    const dstp = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dst_dir, p }) catch return false;
    defer gpa.free(dstp);

    const resolved = std.fs.path.join(gpa, &.{ root, dstp }) catch return false;
    defer gpa.free(resolved);

    return std.mem.startsWith(u8, resolved, root);
}

/// 解析嵌入文件相对路径
pub fn resolveEmbedZzRel(gpa: std.mem.Allocator, src_dir: []const u8, p: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(p)) return null;

    const joined = std.fs.path.join(gpa, &.{ src_dir, p }) catch return null;
    defer gpa.free(joined);

    const normalized = std.fs.path.join(gpa, &.{ ".", std.fs.path.basename(joined) }) catch return null;
    defer gpa.free(normalized);

    if (!std.mem.endsWith(u8, normalized, ".zz")) return null;

    return gpa.dupe(u8, normalized) catch null;
}