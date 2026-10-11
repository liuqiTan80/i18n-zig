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
/// R6（第 52 轮）：真二分取代线性扫描。有序前提：翻译器按源码顺序逐词元 add，
/// entries 按 nat_off 与 std_off 双双升序且不重叠（两端行结构同构、逐词元追加）；
/// 此不变量由单测“差分对照线性基准”与真实工程 demos 4/4 回译全绿共同钉住。
/// 禁止旧 9.3.1 草案的 bogoSort+constCast 模式回归（台账 R6 更正记录）。
pub fn toNative(self: ColumnMap, std_off: usize) usize {
    // 不变量：k = 最后一个 std_off <= 目标的条目。若目标落在 k 的替换区间内即命中；
    // 否则 k 就是线性版“处理完最后一个条目”时的 delta 来源（不可能被更早条目命中：
    // 条目不重叠且升序，若 j<k 含目标则 k.std_off >= j.std_end > 目标，与 k.std_off <= 目标矛盾）。
    const items = self.entries.items;
    var lo: usize = 0;
    var hi: usize = items.len; // 循环不变量：答案在 [lo, hi)
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].std_off <= std_off) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return std_off; // 无任何条目在目标之前：delta 0（与线性版同形）
    const e = items[lo - 1];
    if (std_off < e.std_off + e.std_len) return e.nat_off; // 落在被替换的词元区间内
    const delta = @as(isize, @intCast(e.nat_off + e.nat_len)) - @as(isize, @intCast(e.std_off + e.std_len));
    const result = @as(isize, @intCast(std_off)) + delta;
    return if (result < 0) 0 else @intCast(result);
}

/// 方言偏移 -> 标准偏移（eject / 正向提示用）。R6：与 toNative 对称的二分版。
pub fn toStd(self: ColumnMap, nat_off: usize) usize {
    const items = self.entries.items;
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].nat_off <= nat_off) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return nat_off;
    const e = items[lo - 1];
    if (nat_off < e.nat_off + e.nat_len) return e.std_off;
    const delta = @as(isize, @intCast(e.std_off + e.std_len)) - @as(isize, @intCast(e.nat_off + e.nat_len));
    const result = @as(isize, @intCast(nat_off)) + delta;
    return if (result < 0) 0 else @intCast(result);
}

/// R6 差分参照（私有）：旧线性扫描版 toNative。仅用于单测「二分 == 线性」等价性，
/// 钉住有序不重叠前提；不进产品热路径。
fn toNativeLinear(entries: []const Entry, std_off: usize) usize {
    var delta: isize = 0;
    for (entries) |e| {
        if (std_off < e.std_off) break;
        if (std_off < e.std_off + e.std_len) return e.nat_off;
        delta = @as(isize, @intCast(e.nat_off + e.nat_len)) - @as(isize, @intCast(e.std_off + e.std_len));
    }
    const result = @as(isize, @intCast(std_off)) + delta;
    return if (result < 0) 0 else @intCast(result);
}

/// R6 差分参照（私有）：旧线性扫描版 toStd。
fn toStdLinear(entries: []const Entry, nat_off: usize) usize {
    var delta: isize = 0;
    for (entries) |e| {
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

test "R6：真二分与线性基准差分等价（长行 CJK 混排映射链、有序不重叠前提钉死）" {
    const gpa = std.testing.allocator;
    var map = init(gpa);
    defer map.deinit(gpa);
    // 确定性构造一段升序、不重叠、词元有增有减的映射链（模拟长行 CJK 逐词元替换）。
    // nat_cur / std_cur 各自独立递增，保证两端同时升序且词元间夹 >=1 字节间隙（不重叠）。
    var nat_cur: usize = 0;
    var std_cur: usize = 0;
    var lcg: u32 = 0xC0FFEE;
    const n = 64;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        lcg = lcg *% 1103515245 +% 12345;
        const nlen: usize = @intCast(1 + (lcg >> 8) % 6); // 1..6 字节方言词元（含多字节 CJK）
        lcg = lcg *% 1103515245 +% 12345;
        const slen: usize = @intCast(1 + (lcg >> 8) % 6); // 1..6 字节标准词元（有增有减）
        lcg = lcg *% 1103515245 +% 12345;
        const gap: usize = @intCast(1 + (lcg >> 8) % 3); // 1..3 字节间隙
        try map.add(gpa, .{ .nat_off = nat_cur, .nat_len = nlen, .std_off = std_cur, .std_len = slen });
        nat_cur += nlen + gap;
        std_cur += slen + gap;
    }
    const items = map.entries.items;
    // 覆盖两端 0..max 的每个偏移（含词元内命中、间隙还原、越首/越尾、负 delta 夹 0）做差分对照。
    const ub = @max(nat_cur, std_cur) + 3;
    var off: usize = 0;
    while (off <= ub) : (off += 1) {
        try std.testing.expectEqual(toNativeLinear(items, off), map.toNative(off));
        try std.testing.expectEqual(toStdLinear(items, off), map.toStd(off));
    }
}
