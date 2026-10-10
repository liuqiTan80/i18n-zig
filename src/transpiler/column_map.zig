//! 方言源码 <-> 标准源码 的位置映射。
//!
//! 翻译器逐词元替换、**逐字节保留换行**，两端的行号与「行内第几个
//! 词元」完全一致，仅字节偏移因词元宽度不同而漂移。因此映射表只需
//! 记录发生替换的词元的两端（偏移, 长度），其余位置按漂移量线性还原。

const std = @import("std");

pub const ColumnMap = @This();

pub const Entry = struct {
    nat_off: usize,
    nat_len: usize,
    std_off: usize,
    std_len: usize,
};

entries: std.ArrayList(Entry),

pub fn init(gpa: std.mem.Allocator) ColumnMap {
    _ = gpa; // entries 惰性持有分配器，append 时传入
    return .{ .entries = .empty };
}

pub fn deinit(self: *ColumnMap, gpa: std.mem.Allocator) void {
    self.entries.deinit(gpa);
}

pub fn add(self: *ColumnMap, gpa: std.mem.Allocator, e: Entry) !void {
    try self.entries.append(gpa, e);
}

/// 字节偏移 -> 1 based 行列。**列按 UTF-8 码点（字符）数计**，面向人读（编辑器里一个汉字算一列）。
/// 注意：zig 自身报的是**字节列**（一个汉字算 3 字节）；二者经 `toNative` 的字节偏移链路衔接后，
/// 在此把已正确的方言字节偏移转成字符列展示，故给用户的 `path:line:col` 是字符列而非字节列。
pub fn lineColOf(src: []const u8, off: usize) struct { line: usize, col: usize } {
    const clamped = @min(off, src.len);
    var line: usize = 1;
    var line_start: usize = 0;
    for (src[0..clamped], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const col = std.unicode.utf8CountCodepoints(src[line_start..clamped]) catch 0;
    return .{ .line = line, .col = col + 1 };
}

/// 取偏移所在整行（不含换行符）。
pub fn lineText(src: []const u8, off: usize) []const u8 {
    const clamped = @min(off, src.len);
    const nl = std.mem.lastIndexOfScalar(u8, src[0..clamped], '\n');
    const start = if (nl) |n| n + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
    return src[start..end];
}

/// 标准偏移 -> 方言偏移。未映射位置按前方累计漂移（可为负）线性还原。
pub fn toNative(self: ColumnMap, std_off: usize) usize {
    var delta: isize = 0; // 累计字节长度差（方言端 − 标准端）
    for (self.entries.items) |e| {
        if (std_off < e.std_off) break;
        if (std_off < e.std_off + e.std_len) return e.nat_off; // 落在被替换的词元区间内
        delta = @as(isize, @intCast(e.nat_off + e.nat_len)) - @as(isize, @intCast(e.std_off + e.std_len));
    }
    const result = @as(isize, @intCast(std_off)) + delta;
    return if (result < 0) 0 else @intCast(result);
}

/// 方言偏移 -> 标准偏移（eject / 正向提示用）。
pub fn toStd(self: ColumnMap, nat_off: usize) usize {
    var delta: isize = 0; // 累计字节长度差（标准端 − 方言端）
    for (self.entries.items) |e| {
        if (nat_off < e.nat_off) break;
        if (nat_off < e.nat_off + e.nat_len) return e.std_off;
        delta = @as(isize, @intCast(e.std_off + e.std_len)) - @as(isize, @intCast(e.nat_off + e.nat_len));
    }
    const result = @as(isize, @intCast(nat_off)) + delta;
    return if (result < 0) 0 else @intCast(result);
}

test "往返一致" {
    const gpa = std.testing.allocator;
    var map = init(gpa);
    defer map.deinit(gpa);
    // 方言 "常数"(6B) -> 标准 "const"(5B)；第二词元同样缩 1 字节
    try map.add(gpa, .{ .nat_off = 0, .nat_len = 6, .std_off = 0, .std_len = 5 });
    try map.add(gpa, .{ .nat_off = 10, .nat_len = 12, .std_off = 11, .std_len = 5 });

    // 词元内直接命中：标准 0 落在第一个被替换词元 -> 方言 0
    try std.testing.expectEqual(@as(usize, 0), map.toStd(0));
    try std.testing.expectEqual(@as(usize, 0), map.toNative(0));
    // 标准 11 落在第二个被替换词元 -> 方言 10
    try std.testing.expectEqual(@as(usize, 10), map.toNative(11));
    // 未映射位置的往返一致：标准 16（紧跟第二个词元）<-> 方言 22
    try std.testing.expectEqual(@as(usize, 22), map.toNative(16));
    try std.testing.expectEqual(@as(usize, 16), map.toStd(22));
}
