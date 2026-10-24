//! 反向渲染核：标准 Zig 源码 → 目标语言包的母语词形（`zzc relocalize` 的渲染面）。
//!
//! 正向 `translate` 是「词形 → 规范 Zig」，本模块是其**对偶**「规范 Zig → 词形」。之所以
//! 能成立而不必另写一套语法分析：方言与 Zig 逐 token 同构（方案书核心原则 1）——正向只换
//! 词元、不换结构，故反向只需按目标包把同一批词元换回去，结构与缩进逐字节不动。
//!
//! 三条不变量（各有测钉）：
//!   1. **零硬编码词表**：渲染面只由目标包的 keywords/aliases 反查表驱动，引擎不认任何具体
//!      语言（连 Zig 关键字表都不在本文件内）——新增方言＝新增包，与 pack.zig「语言包是
//!      数据」同源。
//!   2. **同值歧义有确定性主形**：同一 Zig 值对应多个母语词形时（如 `变量`/`让` 皆→`var`），
//!      取字节序最小者；故同一输入恒得同一输出，可复现、可逐字节钉。
//!   3. **标识符原样回归**：`z_<n>` 经符号表反解回作者原写的母语名——跨包渲染后仍是同一套
//!      名字，不产生「换个语言包名字就变了」的漂移。
//!
//! 边界：注释/字符串/多行串/`@"符号"` 一律原样保留（作者的文字不是语法）；导入实参的
//! `.zig` 后缀回写成 `.zz`（与正向只改导入实参的判据同源，复用 `translate.isImportOperand`）。

const std = @import("std");
const lexer = @import("lexer.zig");
const translate = @import("translate.zig");
const mangle = @import("mangle.zig");
const pack = @import("../lang/pack.zig");
const zzc = @import("../zzc_paths.zig");

const Pack = pack.Pack;
const Mangle = mangle.Mangle;

/// 渲染期的单条告警（行列为渲染目标内的位置，供人定位）。
/// `name` 借用源，调用方须让源活得够久。
pub const Warn = struct {
    line: usize,
    col: usize,
    name: []const u8,
};

pub const Result = struct {
    /// 目标包词形的源码（gpa 所有，调用方 free）。
    text: []const u8,
    /// 撞名告警（gpa 所有，调用方 free）。
    warnings: []Warn,
    /// 换成本包词形的词元枚数。
    rendered: usize,
    /// 原样保留的 ASCII 词元枚数（目标包未登记）。
    kept_ascii: usize,
};

/// 目标包的反查表：Zig 规范名（单词或点分链）→ 母语词形。
///
/// keywords 与 aliases 两段合流为一张表：正向翻译本就按「先别名链、后关键字」两跳查，
/// 反向时同一跳序由贪心最长匹配自然复现，故无须分表。值形不合（类型表达式 `[]const u8`、
/// 带空格/箭头的复合形）不入表——它们不是可定位的单个词元，硬渲染只会产碎码。
pub const RevIndex = struct {
    map: std.StringHashMap([]const u8),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, target: Pack) !RevIndex {
        var self = RevIndex{ .map = std.StringHashMap([]const u8).init(gpa), .gpa = gpa };
        errdefer self.map.deinit();
        var it_kw = target.keywords.iterator();
        while (it_kw.next()) |e| try self.consider(e.value_ptr.*, e.key_ptr.*);
        var it_al = target.aliases.iterator();
        while (it_al.next()) |e| try self.consider(e.value_ptr.*, e.key_ptr.*);
        return self;
    }

    pub fn deinit(self: *RevIndex) void {
        self.map.deinit();
    }

    /// 登记一条反查；不合形者跳过，同值时按字节序取最小者定主形（不变量 2）。
    fn consider(self: *RevIndex, value: []const u8, native: []const u8) !void {
        if (!isSingleTokenChain(value)) return;
        if (self.map.get(value)) |have| {
            if (std.mem.order(u8, native, have) != .lt) return;
        }
        try self.map.put(value, native);
    }
};

/// 值是否为「可定位的单个词元链」：由 `.` 分隔的若干段，每段全是 `[A-Za-z0-9_]`，或整段
/// 是 `@` 开头的内建名（`@import`/`@embedFile`/`@sin` …）。类型表达式与复合形在此出局。
fn isSingleTokenChain(value: []const u8) bool {
    if (value.len == 0) return false;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= value.len) : (i += 1) {
        const at_end = i == value.len;
        if (!at_end and value[i] != '.') continue;
        const seg = value[seg_start..i];
        if (seg.len == 0) return false;
        const body = if (seg[0] == '@') seg[1..] else seg;
        if (body.len == 0) return false;
        for (body) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        }
        seg_start = i + 1;
    }
    return true;
}

/// 把 `zig_src`（正向翻译产物）渲染成 `target` 的词形。
pub fn render(
    gpa: std.mem.Allocator,
    zig_src: []const u8,
    target: Pack,
    rev: *const RevIndex,
    table: Mangle,
) !Result {
    const toks = try lexer.scan(gpa, zig_src);
    defer gpa.free(toks);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var warns: std.ArrayList(Warn) = .empty;
    errdefer warns.deinit(gpa);

    var rendered: usize = 0;
    var kept_ascii: usize = 0;
    var prev_end: usize = 0;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        try copyVerbatim(gpa, &out, zig_src[prev_end..t.off]);
        prev_end = t.off + t.len;

        switch (t.kind) {
            .punct => {
                // `@` + 紧随其后的 ASCII 词须作为**一个**规范名查表：正向把 `导入` 译成
                // `@import`（两词元），反向若只查 `import` 就永远回不去。
                if (t.len == 1 and t.text(zig_src)[0] == '@' and i + 1 < toks.len and
                    toks[i + 1].kind == .ascii_word)
                {
                    const next = toks[i + 1];
                    const key = try std.fmt.allocPrint(gpa, "@{s}", .{next.text(zig_src)});
                    defer gpa.free(key);
                    if (rev.map.get(key)) |native| {
                        try out.appendSlice(gpa, native);
                        rendered += 1;
                        prev_end = next.off + next.len;
                        i += 1;
                        continue;
                    }
                }
                try copyVerbatim(gpa, &out, t.text(zig_src));
            },
            .ascii_word => {
                if (try matchChain(gpa, rev, zig_src, toks, i)) |hit| {
                    const last = toks[hit.last];
                    try out.appendSlice(gpa, hit.repl);
                    rendered += 1;
                    prev_end = last.off + last.len; // 链跨多词元：跳到末词元之后
                    i = hit.last;
                    continue;
                }
                const word = t.text(zig_src);
                if (table.unmangle(word)) |native| {
                    // 标识符回归原名（不变量 3）。若该名恰是目标包的关键字/别名词形，
                    // 渲染面读不出「这是名字不是关键字」——交目标包自检去否，此处先告警。
                    if (target.keywords.contains(native) or target.aliases.contains(native)) {
                        const lc = lineColOf(zig_src, t.off);
                        try warns.append(gpa, .{ .line = lc.line, .col = lc.col, .name = native });
                    }
                    try out.appendSlice(gpa, native);
                    rendered += 1;
                    continue;
                }
                if (std.ascii.isAlphabetic(word[0]) or word[0] == '_') kept_ascii += 1;
                try copyVerbatim(gpa, &out, word);
            },
            .string => {
                const text = t.text(zig_src);
                if (std.mem.endsWith(u8, text, zzc.std_import_suffix) and
                    translate.isImportOperand(target, zig_src, toks, i))
                {
                    const repl = try std.mem.replaceOwned(u8, gpa, text, zzc.std_import_suffix, zzc.dialect_import_suffix);
                    defer gpa.free(repl);
                    try out.appendSlice(gpa, repl);
                    continue;
                }
                try copyVerbatim(gpa, &out, text);
            },
            else => try copyVerbatim(gpa, &out, t.text(zig_src)),
        }
    }
    try copyVerbatim(gpa, &out, zig_src[prev_end..]);

    return .{
        .text = try out.toOwnedSlice(gpa),
        .warnings = try warns.toOwnedSlice(gpa),
        .rendered = rendered,
        .kept_ascii = kept_ascii,
    };
}

const ChainHit = struct { last: usize, repl: []const u8 };

/// 从第 idx 个词元起沿 `词(.词)*` 链贪心匹配反查表，取最长命中。单段值（`std`）与多段值
/// （`std.debug.print`）同表同判据——正向的两跳查序在此由「贪心最长」自然复现。
fn matchChain(
    gpa: std.mem.Allocator,
    rev: *const RevIndex,
    src: []const u8,
    toks: []const lexer.Token,
    idx: usize,
) !?ChainHit {
    if (toks[idx].kind != .ascii_word) return null;

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(gpa);

    try key.appendSlice(gpa, toks[idx].text(src));
    var best: ?ChainHit = if (rev.map.get(key.items)) |repl| .{ .last = idx, .repl = repl } else null;

    var j = idx + 1;
    while (j + 1 < toks.len) {
        const dot = toks[j];
        if (dot.kind != .punct or dot.len != 1 or dot.text(src)[0] != '.') break;
        const next = toks[j + 1];
        if (next.kind != .ascii_word) break;
        try key.append(gpa, '.');
        try key.appendSlice(gpa, next.text(src));
        if (rev.map.get(key.items)) |repl| best = .{ .last = j + 1, .repl = repl };
        j += 2;
    }
    return best;
}

/// 原样复制一段字节，丢弃 `\r`（与正向 `translate.copyVerbatim` 同规：渲染产物一律 LF）。
fn copyVerbatim(gpa: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    var start: usize = 0;
    for (bytes, 0..) |c, idx| {
        if (c == '\r') {
            try out.appendSlice(gpa, bytes[start..idx]);
            start = idx + 1;
        }
    }
    try out.appendSlice(gpa, bytes[start..]);
}

fn lineColOf(src: []const u8, off: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < off and i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = off - line_start + 1 };
}

// ---------------------------------------------------------------- 测

const t_target_pack =
    "$code = tgt\n$name = 测试目标\n" ++
    "[keywords]\n" ++
    "公開 = pub\n函數 = fn\n主関数 = main\n" ++
    "定数 = const\n変数 = var\n変数2 = var\n" ++
    "復帰 = return\n構造体 = struct\n列挙 = enum\n合併 = union\n選択 = switch\n" ++
    "もし = if\n他 = else\n空 = void\n" ++
    "[aliases]\n" ++
    "取込 = @import\n埋込 = @embedFile\n" ++
    "基庫 = std\n基庫.調試.印字 = std.debug.print\n";

fn mkTarget(gpa: std.mem.Allocator) !Pack {
    return Pack.parse(gpa, t_target_pack);
}

test "反向渲染：关键字/内建/点分链回写成目标包词形，结构逐字节不动" {
    const gpa = std.testing.allocator;
    var target = try mkTarget(gpa);
    defer target.deinit();
    var rev = try RevIndex.init(gpa, target);
    defer rev.deinit();

    var table = Mangle.init(gpa);
    defer table.deinit();
    const z_1 = try table.intern("数量");

    const zig_src = try std.fmt.allocPrint(gpa, "pub fn main() !void {{\n    var {s}: i64 = 1;\n    std.debug.print(\"值: {{}}\\n\", .{{{s}}});\n}}\n", .{ z_1, z_1 });
    defer gpa.free(zig_src);

    const res = try render(gpa, zig_src, target, &rev, table);
    defer gpa.free(res.text);
    defer gpa.free(res.warnings);

    const want =
        "公開 函數 主関数() !空 {\n" ++
        "    変数 数量: i64 = 1;\n" ++
        "    基庫.調試.印字(\"值: {}\\n\", .{数量});\n" ++
        "}\n";
    try std.testing.expectEqualStrings(want, res.text);
    try std.testing.expectEqual(@as(usize, 0), res.warnings.len);
}

test "零硬编码词表：目标包用纯 ASCII 自造词形时，输出照用自造词（引擎不认任何具体语言）" {
    const gpa = std.testing.allocator;
    // 只把三枚关键字改成 ASCII 自造词：若本模块内藏任何 Zig 关键字表，必在此翻红。
    var target = try Pack.parse(gpa, "[keywords]\nKONST = const\nFUNC = fn\nRET = return\n" ++
        "[aliases]\nIMP = @import\n");
    defer target.deinit();
    var rev = try RevIndex.init(gpa, target);
    defer rev.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const res = try render(gpa, "const z_1 = 1;\nfn f() void { return; }\n", target, &rev, table);
    defer gpa.free(res.text);
    defer gpa.free(res.warnings);
    try std.testing.expectEqualStrings("KONST z_1 = 1;\nFUNC f() void { RET; }\n", res.text);
    // 未登记的词形原样透传并计数（`void` 不在该包内）。
    try std.testing.expectEqual(@as(usize, 3), res.kept_ascii);
}

test "同值歧义定主形：多词形映射同一 Zig 值取字节序最小者，且逐次渲染全等（不变量 2）" {
    const gpa = std.testing.allocator;
    var target = try mkTarget(gpa); // `変数` 与 `変数2` 皆 → var
    defer target.deinit();
    var rev = try RevIndex.init(gpa, target);
    defer rev.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const first = try render(gpa, "var a = 1;\n", target, &rev, table);
    defer gpa.free(first.text);
    defer gpa.free(first.warnings);
    try std.testing.expectEqualStrings("変数 a = 1;\n", first.text); // 短者胜；哈希序不得影响
    // 连跑三遍恒等（HashMap 迭代序不稳定时此处翻红）。
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        const again = try render(gpa, "var a = 1;\n", target, &rev, table);
        defer gpa.free(again.text);
        defer gpa.free(again.warnings);
        try std.testing.expectEqualStrings(first.text, again.text);
    }
}

test "值形闸：类型表达式/复合形不入反查表（硬渲染只会产碎码）" {
    const gpa = std.testing.allocator;
    var target = try Pack.parse(gpa, "[keywords]\n文字列 = []u8\n整列 = []const u8\n巻数 = *const T\n名 = main\n");
    defer target.deinit();
    var rev = try RevIndex.init(gpa, target);
    defer rev.deinit();
    try std.testing.expect(rev.map.get("[]u8") == null);
    try std.testing.expect(rev.map.get("[]const u8") == null);
    try std.testing.expect(rev.map.get("*const T") == null);
    try std.testing.expect(rev.map.get("main") != null); // 单词形照常入表
    // 判据本身的正反形（含 `@` 内建、空段、尾点、非法字符）。
    try std.testing.expect(isSingleTokenChain("@import"));
    try std.testing.expect(isSingleTokenChain("std.debug.print"));
    try std.testing.expect(!isSingleTokenChain(""));
    try std.testing.expect(!isSingleTokenChain("a..b"));
    try std.testing.expect(!isSingleTokenChain("a."));
    try std.testing.expect(!isSingleTokenChain("@"));
    try std.testing.expect(!isSingleTokenChain("a b"));
    try std.testing.expect(!isSingleTokenChain("a-b"));
}

test "注释/字符串/多行串不参与渲染；导入实参 .zig 回写 .zz，普通串不动" {
    const gpa = std.testing.allocator;
    var target = try mkTarget(gpa);
    defer target.deinit();
    var rev = try RevIndex.init(gpa, target);
    defer rev.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 四个标识符先按正向规则 intern 同样的编号，渲染侧才能反解回原名（不变量 3）。
    _ = try table.intern("甲");
    _ = try table.intern("乙");
    _ = try table.intern("丙");
    _ = try table.intern("丁");

    const zig_src =
        "// 注释里的 const 不动\n" ++
        "const z_1 = \"字串 const 不动\";\n" ++
        "const z_2 = std.debug.print;\n" ++
        "const z_3 = @import(\"sub/mod.zig\");\n" ++
        "const z_4 = \"备份.zig\";\n";
    const res = try render(gpa, zig_src, target, &rev, table);
    defer gpa.free(res.text);
    defer gpa.free(res.warnings);
    const want =
        "// 注释里的 const 不动\n" ++
        "定数 甲 = \"字串 const 不动\";\n" ++
        "定数 乙 = 基庫.調試.印字;\n" ++
        "定数 丙 = 取込(\"sub/mod.zz\");\n" ++
        "定数 丁 = \"备份.zig\";\n";
    try std.testing.expectEqualStrings(want, res.text);
}

test "撞名告警：反解出的原名恰为目标包词形时报告（不静默产歧义码）" {
    const gpa = std.testing.allocator;
    var target = try mkTarget(gpa);
    defer target.deinit();
    var rev = try RevIndex.init(gpa, target);
    defer rev.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 作者把一个叫 `定数` 的名字转码成 z_1；渲染回 `定数` 就与目标包关键字撞形。
    const z_1 = try table.intern("定数");
    const src = try std.fmt.allocPrint(gpa, "const {s} = 1;\n", .{z_1});
    defer gpa.free(src);

    const res = try render(gpa, src, target, &rev, table);
    defer gpa.free(res.text);
    defer gpa.free(res.warnings);
    try std.testing.expectEqual(@as(usize, 1), res.warnings.len);
    try std.testing.expectEqualStrings("定数", res.warnings[0].name);
    try std.testing.expectEqual(@as(usize, 1), res.warnings[0].line);
    try std.testing.expectEqual(@as(usize, 7), res.warnings[0].col); // `const ` 之后
}

test "未闭合/截断源不 panic：渲染对畸形输入只求词元边界安全" {
    const gpa = std.testing.allocator;
    var target = try mkTarget(gpa);
    defer target.deinit();
    var rev = try RevIndex.init(gpa, target);
    defer rev.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const probes = [_][]const u8{
        "", "const", "std.debug.print", "@", "@import(\"x.zig",
        "// 注释",
        "\\\\ 多行",
        "const s = \"未闭合",
    };
    for (probes) |p| {
        const res = try render(gpa, p, target, &rev, table);
        gpa.free(res.text);
        gpa.free(res.warnings);
    }
}
