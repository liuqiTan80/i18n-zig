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

test "lineColOf/lineText 防御边界：越尾夹取、截于多字节字符中段列退化 1、行切分各形均不 panic（e2e 只盖常规路径）" {
    // e2e「报错列映射」测只经全管线覆盖常规字符列；本模块两展示函数的三道防御边界零直覆盖：
    // ① `@min(off, src.len)` 夹越尾 off（删则 src[0..off] 越尾 panic）；② utf8CountCodepoints
    // 对截在多字节字符中段的切片报错 → catch 0 退化列 1（删则错误无处去了）；③ lineText 行切分
    // start≤end 恒成立（尾换行后空行/越尾/空源）。本测钉住「任意 off 不 panic、切片恒合法」。
    // 越尾：@min 夹到 src.len，按全源计、不 panic。
    try std.testing.expectEqual(@as(usize, 1), lineColOf("abc", 10).line);
    try std.testing.expectEqual(@as(usize, 4), lineColOf("abc", 10).col);
    // 空源：(1,1)；换行后行号进、列重新起算。
    try std.testing.expectEqual(@as(usize, 1), lineColOf("", 0).col);
    try std.testing.expectEqual(@as(usize, 2), lineColOf("a\nbb", 2).line);
    try std.testing.expectEqual(@as(usize, 1), lineColOf("a\nbb", 2).col);
    // 字符列：CJK 一个汉字算一列（单元面直测，与 e2e 同据）。
    try std.testing.expectEqual(@as(usize, 3), lineColOf("你好", 6).col);
    // 截在多字节字符中段：计数报错 → catch 0 → 列退化 1、不 panic。
    try std.testing.expectEqual(@as(usize, 1), lineColOf("你好", 1).col);
    // lineText：越尾/空源/行中/末行越尾/尾换行后空行——切片恒合法。
    try std.testing.expectEqualStrings("abc", lineText("abc", 10));
    try std.testing.expectEqualStrings("", lineText("", 0));
    try std.testing.expectEqualStrings("bb", lineText("a\nbb\nccc", 2));
    try std.testing.expectEqualStrings("ccc", lineText("a\nbb\nccc", 100));
    try std.testing.expectEqualStrings("", lineText("a\n", 2));
}

// 护栏（第 123 轮证伪落位）：toNative/toStd 的 lo==0 零漂移恒等支（L75/L92「无任何条目在目标之前」）此前零覆盖——
// 既有两测（往返一致 / R6 差分）首条目两端偏移皆 0，任何查询必得 lo≥1，恒不触达此支；而空 map（无任何替换词元的
// 源文件，diag 回映链真调用面）与「查询落在首个被替换词元之前」两形从未钉。此支 load-bearing：删则 items[lo-1]
// 在 lo==0 时 usize 下溢即 panic（线性参照版空 map 下跳循环天然安全、二分页独此一道防线）；误写成 return 0
// 则首词元前的诊断偏移全被压 0、行列错乱。
test "toNative/toStd lo==0 恒等：空 map 与首条目之前查询原样返回不 panic（第 123 轮证伪落位）" {
    const gpa = std.testing.allocator;

    // ① 空 map（无任何替换词元的文件）：任意偏移恒等，含 0 / 中间值 / 越尾。
    var empty = init(gpa);
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty.toNative(0));
    try std.testing.expectEqual(@as(usize, 0), empty.toStd(0));
    try std.testing.expectEqual(@as(usize, 7), empty.toNative(7));
    try std.testing.expectEqual(@as(usize, 7), empty.toStd(7));

    // ② 查询落在首个被替换词元之前：零漂移原样返回；恰击首条目起点则映至其 nat_off（含起点命中语义对照锤）。
    var map = init(gpa);
    defer map.deinit(gpa);
    try map.add(gpa, .{ .nat_off = 12, .nat_len = 6, .std_off = 10, .std_len = 5 });
    try std.testing.expectEqual(@as(usize, 5), map.toNative(5));
    try std.testing.expectEqual(@as(usize, 9), map.toStd(9));
    try std.testing.expectEqual(@as(usize, 12), map.toNative(10));
}
