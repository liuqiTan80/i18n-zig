//! 翻译主引擎：方言源码 -> 标准 Zig 源码 + 位置映射。
//!
//! 策略：逐词元扫描，词元之间的空白/换行**逐字节原样复制**，
//! 因此输出的行结构与输入一致，ColumnMap 只需记录被替换词元的偏移对。
//!
//! nonascii_word 的处理顺序：
//!   1. 点分路径别名链（贪心最长，含单词形式，如 主函数 = std.process.main）；
//!   2. 关键字/类型表（常数 -> const）；
//!   3. 用户标识符转码（数量 -> z_1，工程级符号表保证跨文件一致）。
//! 字符串词元里的导入路径扩展名 `.zz` 改写为 `.zig`；
//! 其余词元（ASCII 词/注释/多行串/字符/@/标点）原样透传。

const std = @import("std");
const lexer = @import("lexer.zig");
const Mangle = @import("mangle.zig");
const Pack = @import("../lang/pack.zig");
const ColumnMap = @import("column_map.zig");
const fullwidth = @import("../diag/fullwidth.zig");

pub const Result = struct {
    zig_str: []const u8,
    map: ColumnMap,
};

/// 剔除起始 UTF-8 BOM（`EF BB BF`）。Windows 编辑器常自动写入 BOM，
/// 若不剔除，它会被归入首个非 ASCII 词元，导致行首母语标识符被误判为非法字符。
pub fn stripBom(src: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    return if (std.mem.startsWith(u8, src, bom)) src[bom.len..] else src;
}

/// 词法/全角层面的前置检查；返回违规列表（调用方负责渲染母语报错）。
pub fn preCheck(gpa: std.mem.Allocator, src: []const u8) ![]fullwidth.Violation {
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    return fullwidth.check(gpa, src, toks);
}

/// 该 `string` 词元是否为 `导入`/`@import` 的直接参数（形如 `导入("…")` 或 `@import("…")`）。
/// 仅导入参数里的 `.zz` 扩展名该改写为 `.zig`；普通字符串字面量（如文件名 `"备份.zz"`、
/// 展示文本、甚至 `@embedFile("模板.zz")` 的资产路径）必须原样保留，否则发生静默数据损坏。
/// 语言无关：不把 `导入` 硬编码，而是查关键字/别名表看前一个词元的映射值是否恰为 `@import`。
fn isImportOperand(lang: Pack, src: []const u8, toks: []const lexer.Token, i: usize) bool {
    if (i < 2) return false;
    const open = toks[i - 1];
    const open_txt = open.text(src);
    if (!(open.kind == .punct and open_txt.len == 1 and open_txt[0] == '(')) return false;
    const head = toks[i - 2];
    // 方言写法：`导入` 是非 ASCII 词元，经关键字/别名表映射为 `@import`。
    if (head.kind == .nonascii_word) {
        const hw = head.text(src);
        const mapped = lang.keywords.get(hw) orelse lang.aliases.get(hw) orelse return false;
        return std.mem.eql(u8, mapped, "@import");
    }
    // 直通写法：`@` `import` `(`（@ 与 import 分属两词元，且均为原始 ASCII）。
    if (head.kind == .ascii_word and std.mem.eql(u8, head.text(src), "import")) {
        if (i >= 3) {
            const at = toks[i - 3];
            const at_txt = at.text(src);
            if (at.kind == .punct and at_txt.len == 1 and at_txt[0] == '@') return true;
        }
    }
    return false;
}

/// 该词元的映射值是否为声明动词（const/var/fn）：用于识别“声明关键字”。
fn isDeclVerb(mapped: []const u8) bool {
    return std.mem.eql(u8, mapped, "const") or
        std.mem.eql(u8, mapped, "var") or
        std.mem.eql(u8, mapped, "fn");
}

/// 当前词元是否处于“被声明的名字”位置：前一词元是声明关键字（`常数`/`变量`/`函数`
/// 的映射值恰为 const/var/fn，或直通 ASCII 写法）。该位置的母语词即便恰与关键字/
/// 类型别名词全等，也必须按标识符转码而非查表替换，否则产出非法代码（台账 D1）。
fn prevIsDeclKeyword(lang: Pack, src: []const u8, toks: []const lexer.Token, i: usize) bool {
    if (i == 0) return false;
    const prev = toks[i - 1];
    const pt = prev.text(src);
    if (prev.kind == .nonascii_word) {
        if (lang.keywords.get(pt)) |mapped| return isDeclVerb(mapped);
        return false;
    }
    if (prev.kind == .ascii_word) return isDeclVerb(pt);
    return false;
}

/// 紧邻前词元是否为 punct `:`（类型标注位）：`名字: 类型` 的类型侧仍应取词表义，
/// 即便同名词已在工程内被声明为标识符。
fn prevIsColon(src: []const u8, toks: []const lexer.Token, i: usize) bool {
    if (i == 0) return false;
    return isPunctAt(toks, src, i - 1, ':');
}

/// 第 i 个词元是否为单字符 punct `c`。
fn isPunctAt(toks: []const lexer.Token, src: []const u8, k: usize, c: u8) bool {
    if (k >= toks.len) return false;
    const t = toks[k];
    if (t.kind != .punct) return false;
    const s = t.text(src);
    return s.len == 1 and s[0] == c;
}

/// 从 `from`（含）向前扫描未被闭合的最近开括号（跳过已配对的内层括号），
/// 返回其词元下标与括号字符；扫到词头未命中则返回 null。
fn findOpenBracket(toks: []const lexer.Token, src: []const u8, from: usize) ?struct { idx: usize, ch: u8 } {
    var depth: usize = 0;
    var k = from + 1;
    while (k > 0) {
        k -= 1;
        const t = toks[k];
        if (t.kind != .punct) continue;
        const s = t.text(src);
        if (s.len != 1) continue;
        const c = s[0];
        if (c == ')' or c == '}' or c == ']') {
            depth += 1;
        } else if (c == '(' or c == '{' or c == '[') {
            if (depth == 0) return .{ .idx = k, .ch = c };
            depth -= 1;
        }
    }
    return null;
}

/// 该词元的映射值是否为目标关键字（非 ASCII 查表或直通 ASCII 词）。
fn mappedIs(lang: Pack, src: []const u8, t: lexer.Token, want: []const u8) bool {
    const s = t.text(src);
    if (t.kind == .nonascii_word) {
        if (lang.keywords.get(s)) |mapped| return std.mem.eql(u8, mapped, want);
        return false;
    }
    if (t.kind == .ascii_word) return std.mem.eql(u8, s, want);
    return false;
}

/// 该 punct 词元的单字符（非 punct 或多字符 operator 返回 null）。
fn punctChar(toks: []const lexer.Token, src: []const u8, k: usize) ?u8 {
    if (k >= toks.len) return null;
    const t = toks[k];
    if (t.kind != .punct) return null;
    const s = t.text(src);
    return if (s.len == 1) s[0] else null;
}

/// 从 `close_idx`（含，应为闭括号） backward 找与它配对的那个开括号下标：
/// 起点计入深度，嵌套先配平；扫到头未配对则 null。用于 `enum(u8) {`/`union(enum) {`
/// 尾巴 `)` 回跳到匹配的 `(`。
fn findMatchingOpen(toks: []const lexer.Token, src: []const u8, close_idx: usize) ?usize {
    var depth: usize = 0;
    var k = close_idx + 1;
    while (k > 0) {
        k -= 1;
        const c = punctChar(toks, src, k) orelse continue;
        if (c == ')' or c == '}' or c == ']') {
            depth += 1;
        } else if (c == '(' or c == '{' or c == '[') {
            if (depth == 0) return null; // 越过了未配对的其它开括号：本串括号不闭合
            depth -= 1;
            if (depth == 0) return k;
        }
    }
    return null;
}

/// 花括号组体的“首领词元”（决定组内名字是不是枚举成员/union 变体）：
/// 组头 `{` 紧邻一词元（裸 `枚举 {`）；或 `)` 时跳到其匹配 `(` 的前一词元
///（`枚举(u8) {`、`联合(枚举) {`）。首领位非词元（如 `.{` 的 `.`）返回 null。
fn braceGroupLeader(toks: []const lexer.Token, src: []const u8, brace_idx: usize) ?lexer.Token {
    if (brace_idx == 0) return null;
    const p = toks[brace_idx - 1];
    if (punctChar(toks, src, brace_idx - 1)) |c| {
        if (c != ')') return null;
        const open = findMatchingOpen(toks, src, brace_idx - 1) orelse return null;
        if (open == 0) return null;
        const q = toks[open - 1];
        if (q.kind == .punct) return null;
        return q;
    }
    if (p.kind == .punct) return null;
    return p;
}

/// 当前词元是否处于扩展的“被声明的名字”位（台账 D1b/D1c）：
///  A. 参数名/字段名：prev ∈ {(, {, ,} 且 next == `:`（`名字: 类型` 只出现在参数/字段声明，
///     zig 调用实参与匿名字面量无此形）；
///  B. 枚举成员/union 变体（含带值 `= n`、带载荷 `(T)`、裸名）：prev ∈ {{, ,}、
///     next ∈ {`,`, `}`, `=`, `(`}，回溯未配对组头 `{`，其首领词（跳一层 `(...)` 参数）
///     映射为 enum 或 union；
///  C. 字段访问/成员路径：prev == `.`——点后必是名字（点分别名链已在第 1 步先行消化，
///     能走到这里的都是非链词），查表会把字段名误替成类型词；
///  D. for 捕获名：prev 与 next 同为 `|`。
fn isExtendedDeclNamePos(lang: Pack, src: []const u8, toks: []const lexer.Token, i: usize) bool {
    if (i == 0 or i >= toks.len) return false;
    if (isPunctAt(toks, src, i - 1, '.')) return true; // C
    const prev_in_group = isPunctAt(toks, src, i - 1, '{') or isPunctAt(toks, src, i - 1, ',') or
        isPunctAt(toks, src, i - 1, '(');
    const next_colon = isPunctAt(toks, src, i + 1, ':');
    if (prev_in_group and next_colon) return true; // A
    if (isPunctAt(toks, src, i - 1, '|') and isPunctAt(toks, src, i + 1, '|')) return true; // D
    if (prev_in_group and !next_colon) { // B：枚举成员/union 变体（裸、带值、带载荷）
        if (punctChar(toks, src, i + 1)) |nx| {
            if (nx == ',' or nx == '}' or nx == '=' or nx == '(') {
                if (findOpenBracket(toks, src, i - 1)) |ob| {
                    if (ob.ch == '{') {
                        if (braceGroupLeader(toks, src, ob.idx)) |lead| {
                            if (mappedIs(lang, src, lead, "enum") or mappedIs(lang, src, lead, "union")) return true;
                        }
                    }
                }
            }
        }
    }
    return false;
}

/// 翻译单个文件。`table` 为工程级共享（跨文件符号转码一致）。
pub fn translate(
    gpa: std.mem.Allocator,
    src: []const u8,
    lang: Pack,
    table: *Mangle,
) !Result {
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var map = ColumnMap.init(gpa);
    errdefer map.deinit(gpa);

    var prev_end: usize = 0;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];

        // 词元间空白原样复制（保证行结构不变；CRLF 归一为 LF）
        try copyVerbatim(gpa, &out, src[prev_end..t.off]);
        prev_end = t.off + t.len;

        switch (t.kind) {
            .nonascii_word => {
                // 1) 点分路径别名链（贪心最长）
                if (try matchAliasChain(gpa, lang, src, toks, i)) |chain| {
                    const last = toks[chain.last];
                    const nat_len = last.off + last.len - t.off;
                    try emitReplacement(gpa, &out, &map, t.off, nat_len, chain.repl);
                    // 链跨越多个词元：prev_end 必须跳到末词元之后，
                    // 否则中间原文（如 `.` 与其后的词）会被重新复制
                    prev_end = last.off + last.len;
                    i = chain.last;
                    continue;
                }
                // 2) 关键字/类型表（绑句法位置）：
                //    a. 声明名位（紧随 const/var/fn）跳过查表——名字撞词表词时走转码保留；
                //    b. 该母语词已被本工程声明为标识符时，除类型标注位（`:` 右侧）外
                //       引用处标识符优先——否则 `常数 文本 = "x"` 的引用会被翻译成 `[]const u8`。
                //    点分别名链在第 1 步先行、不受影响（`标准库 = std` 的声明位单链照旧生效）。
                const word = t.text(src);
                if (lang.keywords.get(word)) |repl| {
                    const decl_name_pos = prevIsDeclKeyword(lang, src, toks, i) or
                        isExtendedDeclNamePos(lang, src, toks, i);
                    const occupied = table.native_to_ascii.get(word) != null;
                    const ident_first = occupied and !prevIsColon(src, toks, i);
                    if (!decl_name_pos and !ident_first) {
                        try emitReplacement(gpa, &out, &map, t.off, word.len, repl);
                        continue;
                    }
                }
                // 3) 用户标识符转码
                const ascii = try table.intern(word);
                try emitReplacement(gpa, &out, &map, t.off, word.len, ascii);
            },
            .string => {
                const text = t.text(src);
                // 导入路径扩展名改写：`导入("foo.zz")` 里的 "foo.zz" -> "foo.zig"。
                // 仅当该字符串确为导入参数时才改，避免误伤任意以 `.zz` 结尾的普通字符串字面量。
                if (std.mem.endsWith(u8, text, ".zz\"") and isImportOperand(lang, src, toks, i)) {
                    const repl = try std.mem.replaceOwned(u8, gpa, text, ".zz\"", ".zig\"");
                    defer gpa.free(repl);
                    try emitReplacement(gpa, &out, &map, t.off, text.len, repl);
                    continue;
                }
                try copyVerbatim(gpa, &out, text);
            },
            else => try copyVerbatim(gpa, &out, t.text(src)),
        }
    }
    // 收尾：最后一个词元之后的内容（含末尾换行）
    try copyVerbatim(gpa, &out, src[prev_end..]);

    return .{ .zig_str = out.items, .map = map };
}

const ChainMatch = struct { last: usize, repl: []const u8 };

/// 从第 idx 个词元起沿 `词(.词)*` 链贪心匹配别名表，返回最长匹配。
/// 注意：链中相邻词元之间必须只隔空白（拼接键时忽略空白，
/// 但词元序列中遇到非 `.`/非词即终止）。
fn matchAliasChain(
    gpa: std.mem.Allocator,
    lang: Pack,
    src: []const u8,
    toks: []const lexer.Token,
    idx: usize,
) !?ChainMatch {
    if (toks[idx].kind != .nonascii_word) return null;

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(gpa);

    try key.appendSlice(gpa, toks[idx].text(src));
    var best: ?ChainMatch = null;
    if (lang.aliases.get(key.items)) |repl| best = .{ .last = idx, .repl = repl };

    var j = idx + 1;
    while (j + 1 < toks.len) {
        if (toks[j].kind != .punct or toks[j].text(src)[0] != '.') break;
        const next = toks[j + 1];
        if (next.kind != .nonascii_word) break;

        try key.append(gpa, '.');
        try key.appendSlice(gpa, next.text(src));
        if (lang.aliases.get(key.items)) |repl| best = .{ .last = j + 1, .repl = repl };
        j += 2;
    }
    return best;
}

/// 原样复制一段源码字节到输出，但丢弃 `\r`（CRLF -> LF）：
/// 真实 Zig 源码与 `zig fmt` 均以 LF 为规范，翻译输出应直接 fmt-clean。
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

/// 写替换文本并登记映射。
fn emitReplacement(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    map: *ColumnMap,
    nat_off: usize,
    nat_len: usize,
    repl: []const u8,
) !void {
    const std_off = out.items.len;
    try out.appendSlice(gpa, repl);
    if (nat_len == repl.len and nat_off == std_off) return; // 位置未漂移，免登记
    try map.add(gpa, .{
        .nat_off = nat_off,
        .nat_len = nat_len,
        .std_off = std_off,
        .std_len = repl.len,
    });
}

const zh_pack = @embedFile("../lang/packs/中文.txt");

test "翻译快照：hello 方言 -> 标准 Zig（逐字节）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const src =
        \\常数 标准库 = 导入("std");
        \\
        \\公开 函数 主函数() !void {
        \\    变量 数量: 整数 = 10;
        \\    数量 = 数量 + 1;
        \\    标准库.打印("hi {d}\n", .{数量});
        \\}
        \\
    ;
    const expect =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    var z_1: i64 = 10;
        \\    z_1 = z_1 + 1;
        \\    std.debug.print("hi {d}\n", .{z_1});
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);
    // 符号表：唯一用户标识符 `数量` 被转码为 z_1。
    try std.testing.expectEqualStrings("数量", table.unmangle("z_1").?);
}

test "翻译：`.zz`→`.zig` 改写只作用于导入参数，不误伤普通字符串字面量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const src =
        \\常数 库 = 导入("lib.zz");
        \\常数 文件名 = "备份.zz";
        \\
    ;
    // 导入参数的 `lib.zz` 该改写为 `lib.zig`；而普通字符串 `备份.zz` 必须原样保留。
    const expect =
        \\const z_1 = @import("lib.zig");
        \\const z_2 = "备份.zz";
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);
}

test "D1 声明名撞词：声明位跳过关键字表、引用处标识符优先、类型标注位保留词表义" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const src =
        \\常数 文本 = "hello";
        \\常数 甲: 文本 = 文本;
        \\变量 整数: 整数 = 5;
        \\整数 = 整数 + 1;
        \\const 联合 = 1;
        \\常数 乙: 整数 = 3;
    ;
    const expect =
        \\const z_1 = "hello";
        \\const z_2: []const u8 = z_1;
        \\var z_3: i64 = 5;
        \\z_3 = z_3 + 1;
        \\const z_4 = 1;
        \\const z_5: i64 = 3;
    ;
    const res = try translate(gpa, src, lang, &table);
    // 文本/整数/联合都是词表词，但在声明名位必须转码保留；引用处用已登记的转码名；
    // `:` 右侧类型标注（文本→[]const u8、整数→i64）仍取词表义。
    try std.testing.expectEqualStrings(expect, res.zig_str);
    // 反查：声明名整词登记，未被拆成类型词残体。
    try std.testing.expectEqualStrings("文本", table.unmangle("z_1").?);
    try std.testing.expectEqualStrings("整数", table.unmangle("z_3").?);
}

test "D1b 组上下文声明名：字段/枚举成员/参数/捕获名/字段引用撞词均不破码" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const src =
        \\常数 甲 = 结构 { 文本: 整数 };
        \\常数 乙 = 枚举 { 文本, 丙 };
        \\函数 丁(戊: 甲) 整数 { 返回 戊.文本; }
        \\变量 己: 整数 = 0;
        \\常数 庚 = [_]i64{ 1, 2 };
        \\for (庚) |文本| { 己 += 文本; }
    ;
    const expect =
        \\const z_1 = struct { z_2: i64 };
        \\const z_3 = enum { z_2, z_4 };
        \\fn z_5(z_6: z_1) i64 { return z_6.z_2; }
        \\var z_7: i64 = 0;
        \\const z_8 = [_]i64{ 1, 2 };
        \\for (z_8) |z_2| { z_7 += z_2; }
    ;
    const res = try translate(gpa, src, lang, &table);
    // 字段名/参数名（`( `{ `,` 后跟 `:`）、枚举成员（enum 组内）、
    // for 捕获名（`|…|`）、`.` 后字段引用：`文本` 全链路同一转码名、类型标注照旧取词表义。
    try std.testing.expectEqualStrings(expect, res.zig_str);
    try std.testing.expectEqualStrings("文本", table.unmangle("z_2").?);
}

test "D1c tagged union 变体名/带值枚举成员撞词：首领词跳一层参数括号" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const src =
        \\常数 状态 = 枚举(u8) { 文本 = 7, 成功 = 9 };
        \\常数 结果 = 联合(枚举) { 文本(u8), 整数, 空(void) };
        \\fn 用(r: 结果) void { 匹配 (r) { .文本 => {}, .整数 => {} } }
        \\变量 引用 = 结果.整数;
    ;
    const expect =
        \\const z_1 = enum(u8) { z_2 = 7, z_3 = 9 };
        \\const z_4 = union(enum) { z_2(u8), z_5, z_6(void) };
        \\fn z_7(r: z_4) void { switch (r) { .z_2 => {}, .z_5 => {} } }
        \\var z_8 = z_4.z_5;
    ;
    const res = try translate(gpa, src, lang, &table);
    // 带值枚举成员（prev=`{`/`,`、next=`=`，首领 `枚举(u8)` 跳括号认 enum）、
    // 带载荷变体（next=`(`）、裸变体（union 尾是 `)` 非 enum 词也能命中）、
    // `.名字` 引用与 switch 捕获位由既有 C/occupied 规则接管——全链路同名 z_2/z_5。
    try std.testing.expectEqualStrings(expect, res.zig_str);
    try std.testing.expectEqualStrings("文本", table.unmangle("z_2").?);
    try std.testing.expectEqualStrings("整数", table.unmangle("z_5").?);
}

test "关键字/别名超串标识符：整词不拆分，别名仅对完整词链生效" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // `打印数据` 包含打印别名尾词 `打印`，`返回值` 包含关键字 `返回`，`整数倍` 含 `整数`。
    const src =
        \\常数 标准库 = 导入("std");
        \\函数 打印数据(值: 整数) void {
        \\    标准库.打印("{d}\n", .{值});
        \\}
        \\公开 函数 主函数() !void {
        \\    常数 返回值: 整数 = 3;
        \\    打印数据(返回值);
        \\}
        \\
    ;
    const expect =
        \\const std = @import("std");
        \\fn z_1(z_2: i64) void {
        \\    std.debug.print("{d}\n", .{z_2});
        \\}
        \\pub fn main() !void {
        \\    const z_3: i64 = 3;
        \\    z_1(z_3);
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    // 关键：这些超串名必须各自整词转码，而非被拆成“关键字片段+残体”。
    try std.testing.expectEqualStrings(expect, res.zig_str);
    // 别名 `标准库.打印` 仍对完整词链（`标准库` `.` `打印`）生效，展开为 std.debug.print。
    try std.testing.expect(std.mem.indexOf(u8, res.zig_str, "std.debug.print") != null);
    // 反查：函数名与变量名各自为一个完整符号，未被拆分。
    try std.testing.expectEqualStrings("打印数据", table.unmangle("z_1").?);
    try std.testing.expectEqualStrings("返回值", table.unmangle("z_3").?);
}

test "CRLF 归一：Windows 行尾的方言源 -> 纯 LF 标准 Zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 以 \r\n 行尾书写的源码（多份编辑器在 Windows 下会如此保存）。
    const src_crlf = "常数 数量 = 1;\r\n常数 标题 = \"值\";\r\n";
    const res = try translate(gpa, src_crlf, lang, &table);
    // 输出必须已剔除 \r（归一为 LF），且逐行内容与 LF 源一致。
    try std.testing.expect(std.mem.indexOfScalar(u8, res.zig_str, '\r') == null);
    try std.testing.expectEqualStrings("const z_1 = 1;\nconst z_2 = \"值\";\n", res.zig_str);
    // 字符串字面量内容不受行尾归一影响。
    try std.testing.expectEqualStrings("标题", table.unmangle("z_2").?);
}

test "stripBom：仅剔除起始 UTF-8 BOM，无 BOM 与正文内出现均不变" {
    const bom = "\xEF\xBB\xBF";
    // 起始 BOM 被剔除。
    try std.testing.expectEqualStrings("常数 甲 = 1;", stripBom(bom ++ "常数 甲 = 1;"));
    // 无 BOM 输入原样返回。
    try std.testing.expectEqualStrings("常数 甲 = 1;", stripBom("常数 甲 = 1;"));
    // 仅在起始处剔除；正文中的 U+FEFF 字节保持原样。
    try std.testing.expectEqualStrings("甲\u{FEFF}乙", stripBom("甲\u{FEFF}乙"));
}

test "跨文件符号一致：共享转码表使同一母语名在多文件映射到同一 ASCII 名" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 模拟两个文件：定义侧与调用侧，各自单独 translate，但共用同一 table。
    const def = try translate(gpa, "公开 函数 加一(值: 整数) 整数 { 返回 值 + 1; }", lang, &table);
    const use = try translate(gpa, "常数 结果 = 加一(41);", lang, &table);

    // `加一` 在两侧必须得到完全相同的 ASCII 名（跨模块引用才成立）。
    const fname = table.native_to_ascii.get("加一") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, def.zig_str, fname) != null);
    try std.testing.expect(std.mem.indexOf(u8, use.zig_str, fname) != null);
    // 关键字不受转码影响。
    try std.testing.expect(std.mem.indexOf(u8, def.zig_str, "i64") != null);
    // 不同母语名分配不同 ASCII 名（加一 vs 值）。
    const vname = table.native_to_ascii.get("值") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, fname, vname));
}

test "语言包词元规范：方言侧键全纯中文，且 不透明类型/取类型 翻译生效" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 规范守卫：关键字与别名的方言侧（左键）一律不得含英文字母——
    // 禁止 `opaque类型`/`类型of` 这类中英混合形态重新回到语言包。
    var kit = lang.keywords.keyIterator();
    while (kit.next()) |k| {
        for (k.*) |c| try std.testing.expect(!std.ascii.isAlphabetic(c));
    }
    var ait = lang.aliases.keyIterator();
    while (ait.next()) |k| {
        for (k.*) |c| try std.testing.expect(!std.ascii.isAlphabetic(c));
    }

    // 改名后的两个纯中文词走通翻译：整词替换、不碰其他词元。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\const O = 不透明类型 {};
        \\const T = 取类型(3);
    ;
    const expect =
        \\const O = opaque {};
        \\const T = @TypeOf(3);
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);
}

test "语言包词元规范：诊断译文/提示禁含内部维护注释词与非反引号英文句子" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 守卫一：用户可见的译文/提示（message/tip）不得含“描述语言包自身”的元注释词——
    // 这类词是开发者维护备注（如“需单独登记”“分属不同措辞”），泄漏到终端即成噪音（台账 D6）。
    const meta_words = [_][]const u8{ "登记", "备注", "措辞", "需单独", "分属", "历史上", "曾经", "TODO", "FIXME", "维护者" };
    for (lang.diagnostics.items) |e| {
        for (meta_words) |w| {
            try std.testing.expect(std.mem.indexOf(u8, e.message, w) == null);
            try std.testing.expect(std.mem.indexOf(u8, e.tip, w) == null);
        }
    }

    // 守卫二：剥去反引号包裹的代码引用后，译文/提示不得残留 ≥3 连续 ASCII 词组成的英文句子
    //（pattern 段是 zig 英文匹配短语、正当英文，不在此列；合法单标识符须用反引号包裹）。
    for (lang.diagnostics.items) |e| {
        try expectNoEnglishSentence(e.message);
        try expectNoEnglishSentence(e.tip);
    }
}

/// 判断字节是否为 ASCII 字母（词内字符，用于英文句子检测）。
fn isAsciiAlphaByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// 扫描一段可见文本：跳过反引号 `...` 内的代码引用后，统计连续被空白分隔的纯 ASCII 字母词个数；
/// 若出现 ≥3 个相邻英文词（如 `unused local variable`）即视为未译句子、报错。
fn expectNoEnglishSentence(text: []const u8) !void {
    var in_tick = false;
    var run: usize = 0; // 当前连续英文词计数
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '`') {
            in_tick = !in_tick;
            run = 0;
            i += 1;
            continue;
        }
        if (in_tick) {
            i += 1;
            continue;
        }
        if (isAsciiAlphaByte(c)) {
            // 词首：前一字符非字母（或行首）则开一词
            const prev_is_alpha = i > 0 and isAsciiAlphaByte(text[i - 1]);
            if (!prev_is_alpha) run += 1;
            if (run >= 3) return error.UntranslatedEnglishSentence;
            i += 1;
            continue;
        }
        // 非字母且非空白才重置（空白不算断开，否则 "foo bar baz" 会被拆散）；中文/标点重置
        if (c != ' ' and c != '\t') run = 0;
        i += 1;
    }
}
