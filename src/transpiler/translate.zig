//! 翻译主引擎：方言源码 -> 标准 Zig 源码 + 位置映射。
//!
//! 策略：逐词元扫描，词元之间的空白/换行**逐字节原样复制**，
//! 因此输出的行结构与输入一致，ColumnMap 只需记录被替换词元的偏移对。
//!
//! nonascii_word 的处理顺序：
//!   1. 点分路径别名链（贪心最长，跨多段，如 标准库.调试.打印 = std.debug.print）；
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
// 第 234 轮 D102：导入改写的扩展名对（匹配形 `.zz"`／替换形 `.zig"`）唯一真值下沉至 zzc_paths hub，
// 与 `cli/args.zig` 的 `genPathFor`（落盘名 `.zig`）同源——本模块此前根本不 import hub，故 `.zig` 系
// 跨模块手抄的第二份私货；接 hub 后改写侧与落盘侧结构性无法单边漂移（见 234 T0 值钉与 main 往返锚）。
const zzc = @import("../zzc_paths.zig");

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

/// 当前词元是否处于扩展的“被声明的名字”位（台账 D1b/D1c/D42）：
///  A. 参数名/字段名：prev ∈ {(, {, ,} 且 next == `:`（`名字: 类型` 只出现在参数/字段声明，
///     zig 调用实参与匿名字面量无此形）；
///  B. 枚举成员/union 变体/error 标签（含带值 `= n`、带载荷 `(T)`、裸名）：prev ∈ {{, ,}、
///     next ∈ {`,`, `}`, `=`, `(`}，回溯未配对组头 `{`，其首领词（跳一层 `(...)` 参数）
///     映射为 enum、union 或 error；
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
                            if (mappedIs(lang, src, lead, "enum") or mappedIs(lang, src, lead, "union") or mappedIs(lang, src, lead, "error")) return true;
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
                    // D47（第 103 轮）入口定义位例外：前词映射为 fn、本词形映射为 main、
                    // 后紧跟 `(` ——三条件全绑句法位、纯值判据不硬编码任何方言词。缺此例外则
                    // keywords 段的 `X = main` 词形（B6 契约两表皆可的合法形）被避让 intern 成
                    // z_N、生成物失去 `pub fn main(`、check 静默退化库形浅检假成功；中文先例
                    // `主函数 = main` 实属 aliases 段（第 1 步链免避让）才可用——两段皆须真生效。
                    const main_def_pos = decl_name_pos and std.mem.eql(u8, repl, "main") and
                        isPunctAt(toks, src, i + 1, '(') and mappedIs(lang, src, toks[i - 1], "fn");
                    const occupied = table.native_to_ascii.get(word) != null;
                    const ident_first = occupied and !prevIsColon(src, toks, i);
                    if ((!decl_name_pos or main_def_pos) and !ident_first) {
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
                // 第 234 轮 D102：匹配/替换后缀取自 hub（`dialect_import_suffix`/`std_import_suffix`），
                // 与 genPathFor 落盘名同源；旧此处两份手抄字面量 `.zz""`/`.zig""` 已收敛为委派（逐字节等价）。
                if (std.mem.endsWith(u8, text, zzc.dialect_import_suffix) and isImportOperand(lang, src, toks, i)) {
                    const repl = try std.mem.replaceOwned(u8, gpa, text, zzc.dialect_import_suffix, zzc.std_import_suffix);
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
        \\    标准库.调试.打印("hi {d}\n", .{数量});
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

test "D42 error 集标签撞词：error { } 组首领未入 case B 判定、标签被查表替换产碎码" {
    // 缺陷面：isExtendedDeclNamePos case B 的 braceGroupLeader 只检 "enum"/"union"，
    // 漏 "error"——用户写 `常数 E = 错误 { 文本, 整数 };` 时 `文本`(→[]const u8)、`整数`(→i64)
    // 在标签位被查表替换、产出非法码 `error { []const u8, i64 }`。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const src = "常数 错误集 = 错误 { 文本, 整数 };\n";
    // 修复后期望：标签名走转码（z_2, z_3）而非关键字替换。
    const expect = "const z_1 = error { z_2, z_3 };\n";
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);
    try std.testing.expectEqualStrings("文本", table.unmangle("z_2").?);
    try std.testing.expectEqualStrings("整数", table.unmangle("z_3").?);
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
        \\    标准库.调试.打印("{d}\n", .{值});
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
    // 别名 `标准库.调试.打印` 仍对完整词链（`标准库` `.` `调试` `.` `打印`）生效，展开为 std.debug.print。
    try std.testing.expect(std.mem.indexOf(u8, res.zig_str, "std.debug.print") != null);
    // 反查：函数名与变量名各自为一个完整符号，未被拆分。
    try std.testing.expectEqualStrings("打印数据", table.unmangle("z_1").?);
    try std.testing.expectEqualStrings("返回值", table.unmangle("z_3").?);
}

test "标准库全量别名：模块级名 + ASCII 成员全链展开与未列名逐段回退（第 141 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const src =
        \\公开 函数 主函数() 空 {
        \\    标准库.调试.print("hi", .{});
        \\    标准库.调试.assert(1 > 0);
        \\    常数 甲 = 标准库.网络;
        \\    常数 乙 = 标准库.交换文本;
        \\    常数 丙 = 标准库.联载格式;
        \\    常数 丁 = 标准库.mem.eql;
        \\    常数 戊 = 标准库.ArrayList;
        \\}
        \\
    ;
    const o = (try translate(gpa, src, lang, &table)).zig_str;
    // 模块级别名 + ASCII 成员：整链展开为 std.<模块>.<成员>（链止于 ASCII 成员、成员原样保留）
    try std.testing.expect(std.mem.indexOf(u8, o, "std.debug.print(\"hi\", .{})") != null);
    try std.testing.expect(std.mem.indexOf(u8, o, "std.debug.assert") != null);
    // 纯模块级名（无成员）：命中本轮新增的全量别名
    try std.testing.expect(std.mem.indexOf(u8, o, "= std.http;") != null);
    try std.testing.expect(std.mem.indexOf(u8, o, "= std.json;") != null);
    try std.testing.expect(std.mem.indexOf(u8, o, "= std.elf;") != null);
    // 未起中文名的原生路径：逐段回退（标准库 -> std，ASCII 成员原样透传）——中文别名是增益、非唯一路径
    try std.testing.expect(std.mem.indexOf(u8, o, "= std.mem.eql;") != null);
    try std.testing.expect(std.mem.indexOf(u8, o, "= std.ArrayList;") != null);
    // 反向不变量：母语模块名命中别名链第 1 步即短路，绝不会被 intern 成 std.z_（落标识符转码即别名失效）
    try std.testing.expect(std.mem.indexOf(u8, o, "std.z_") == null);
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

// 护栏（第 117 轮证伪落位）：`expectNoEnglishSentence` 系「防英文泄漏」词表规范守卫二的判定核，
// 仅经 L707-708 对 pack 每条 message/tip 间接调用、其自身边界此前零直调覆盖——≥ 3 恰等阈值、
// 反引号代码引用豁免、空白不断链 vs 标点/CJK 重置、单词只计一次（词首检测）全无人钉。若阈值/
// 豁免/重置被误改，守卫会静默假阴（放过真英文泄漏）或假阳（误杀合法反引号码引），而 pack 消息
// 测仍全绿。本测直调钉住。
test "expectNoEnglishSentence 边界：≥ 3 恰等阈值 + 反引号码引豁免 + 空白不断链 vs 标点/CJK 重置 + 单词计一（词表规范守卫二判定核，第 117 轮）" {
    // ① 恰三个空白分隔英文词 → 判为未译句（≥ 3 阈值下界命中；空白不重置计数）。
    try std.testing.expectError(error.UntranslatedEnglishSentence, expectNoEnglishSentence("foo bar baz"));
    // ② 恰两个英文词 → 放行（阈值须 >=3、证非 >=2）。
    try expectNoEnglishSentence("foo bar");
    // ③ 反引号包裹的代码引用即便含 ≥3 英文词亦豁免（合法码引不误杀）。
    try expectNoEnglishSentence("`unused local variable`");
    // ④ 单个多字母词只计一次（词首检测：仅字母且前非字母才 run+1）。
    try expectNoEnglishSentence("untranslatedsentence");
    // ⑤ 句点等标点重置计数（非字母且非空白 → run=0）：x.y.z 三段不误判为三词句。
    try expectNoEnglishSentence("x.y.z");
    // ⑥ 纯 CJK（含空格分隔）无 ASCII 字母 → 恒放行。
    try expectNoEnglishSentence("变量 数量 名称");
    // ⑦ CJK 夹在中间重置连词计数：foo 变量 bar baz 仅 tail 两词连、不达 3。
    try expectNoEnglishSentence("foo 变量 bar baz");
}

// ---------------------------------------------------------------------------
// 纯母语强制（第 99 轮）：.zz 方言源必须 100% 母语词形。
// AI 生成方言代码时常混入英文关键字/类型词（`const 数量 = 10;`、`主函数() !void`、
// `fn x()`、`@embedFile`），旧行为是 ASCII 词元原样透传——混搭源无声通过、方言纯度
// 静默降级。本检查在翻译前把「词形恰为语言包关键字段某键映射值」的 ASCII 词元坐实为
// 违例（如 `const`：存在 `常数 = const`）。判据全取自被检的包、不硬编码任何词表（F2
// 同源原则），任意语言包自动适配。
// 豁免位（词元级，字符串/注释/多行串/@"..." 符号整体是单词元、天然不拆解）：
//   - 数字字面量/含数字混合形：映射值皆纯字母词，全等判据天然放行；C ABI 领土名（`c_int`/`c_char`）
//     不属任何语言包的映射值（它们不是 Zig 关键字、是 C 生态符号），同一判据天然豁免；
//   - 无母语映射的 Zig 内建（`@as`/`@intCast`/`@add`…）：语言领土、无可反查对象，放行；
//   - 点号后的段（`a.true` 型字段访问）：Zig 的 `.` 后接关键字合法，不报；
//   - 声明名位（复用 prevIsDeclKeyword/isExtendedDeclNamePos 避让判据）：与 D1 哲学一致，
//     用户拿映射值当英文名时交下游更准的 zig 语法错，而非误导性的「请改母语」。
// `@` 前缀内建：词元拆为 punct `@` + ascii_word，故拼回 `@embedFile` 全形后反查（有母语映射的
// 内建如 `@import`/`@embedFile`/`@TypeOf`/`@max`/`@min`/`@sqrt`/`@abs`/`@floor`/`@ceil`/`@round`/`@trunc`/`@sin`/`@cos`/`@tan`/`@exp`/`@log`/`@exp2`/`@log2`/`@log10`/`@mod`/`@rem`/`@divFloor`/`@divTrunc`/`@clz`/`@ctz`/`@popCount`/`@byteSwap`/`@bitReverse`/`@divExact`/`@sizeOf`/`@alignOf`/`@bitSizeOf`/`@typeName`/`@tagName`/`@errorName`/`@divCeil`/`@shlExact`/`@shrExact`/`@typeInfo`/`@This` 同样强制（第 146–151 轮逐族登记）；无映射者如 @pow/@memberCount/@byteOffsetOf（0.17 不存在）/@Type（0.17 已移除、第 151 轮删其死映射）/@as/@intCast/@truncate（需已知结果类型、非自然裸值形）依旧放行。
// 只检 keywords 段值：aliases 段值（std/main 等库路径与入口名）属互操作面、不在本轮判据内。

pub const EnglishWord = struct {
    off: usize,
    /// 英文词形本体（包含 `@` 前缀；内存由 EnglishWords 容器持有）
    word: []const u8,
    /// 应改用的母语词形，多词形以 `/` 连接（如 `变量/让`；内存由 EnglishWords 容器持有）
    native: []const u8,
};

/// 违例列表：容器自持 word/native 字符串内存，`deinit` 一次性回收。
pub const EnglishWords = struct {
    gpa: std.mem.Allocator,
    items: []EnglishWord,

    pub fn deinit(self: *EnglishWords) void {
        for (self.items) |v| {
            self.gpa.free(v.word);
            self.gpa.free(v.native);
        }
        self.gpa.free(self.items);
        self.* = undefined;
    }
};

pub fn findEnglishWordForms(
    gpa: std.mem.Allocator,
    lang: Pack,
    src: []const u8,
) !EnglishWords {
    const body = stripBom(src);
    const toks = try lexer.scan(gpa, body);
    defer gpa.free(toks);

    var viol: std.ArrayList(EnglishWord) = .empty;
    errdefer {
        for (viol.items) |v| {
            gpa.free(v.word);
            gpa.free(v.native);
        }
        viol.deinit(gpa);
    }

    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (t.kind != .ascii_word) continue;
        const word = t.text(body);
        // `@` 紧邻前缀：拼回内建全形再反查（`@embedFile` 而非 `embedFile`）。
        const at_prefix = i > 0 and toks[i - 1].kind == .punct and
            std.mem.eql(u8, toks[i - 1].text(body), "@") and toks[i - 1].off + 1 == t.off;
        const full = if (at_prefix)
            try std.fmt.allocPrint(gpa, "@{s}", .{word})
        else
            try gpa.dupe(u8, word);

        // 反查：本词的词形是否恰为包内某关键字的映射值（O(关键词数)、词数极少）。
        var hits: std.ArrayList([]const u8) = .empty;
        defer hits.deinit(gpa);
        var it = lang.keywords.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.*, full)) {
                // D49（第 105 轮）：hits 增长 OOM 时 full 已分配、尚未移交——裸 try 返错即泄；
                // 与本函数 join/viol.append 的 catch 回滚同形（三处 OOM 路径须对称）。
                hits.append(gpa, kv.key_ptr.*) catch {
                    gpa.free(full);
                    return error.OutOfMemory;
                };
            }
        }
        // 未命中 / 命中但在豁免位：本词形无需报告，释放 full 后继续（命中且需报告时下方移交 viol 持有）。
        const dot_operand = i > 0 and toks[i - 1].kind == .punct and std.mem.eql(u8, toks[i - 1].text(body), ".");
        const decl_name = prevIsDeclKeyword(lang, body, toks, i) or isExtendedDeclNamePos(lang, body, toks, i);
        if (hits.items.len == 0 or dot_operand or decl_name) {
            gpa.free(full);
            continue;
        }

        const native = std.mem.join(gpa, "/", hits.items) catch {
            gpa.free(full);
            return error.OutOfMemory;
        };
        viol.append(gpa, .{ .off = if (at_prefix) toks[i - 1].off else t.off, .word = full, .native = native }) catch {
            gpa.free(native);
            gpa.free(full);
            return error.OutOfMemory;
        };
        // 成功移交后 full/native 由 viol 持有（函数顶 errdefer 与 EnglishWords.deinit 负责回收）。
    }
    return .{ .gpa = gpa, .items = try viol.toOwnedSlice(gpa) };
}

test "纯母语强制：英文关键字/类型词混入方言源被坐实（先红）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 混入形一：声明关键字英文（`常数 x: i32 = 10;` 型半中半英的同族反例）
    var v1 = try findEnglishWordForms(gpa, lang, "const 数量 = 10;\n");
    defer v1.deinit();
    try std.testing.expectEqual(@as(usize, 1), v1.items.len);
    try std.testing.expectEqualStrings("const", v1.items[0].word);
    try std.testing.expectEqual(@as(usize, 0), v1.items[0].off);
    try std.testing.expectEqualStrings("常数", v1.items[0].native);

    // 混入形二：返回值类型词英文（demo 曾在线使用的 `!void` 形也被强制）
    var v2 = try findEnglishWordForms(gpa, lang, "公开 函数 主函数() !void {\n}\n");
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 1), v2.items.len);
    try std.testing.expectEqualStrings("void", v2.items[0].word);

    // 混入形三：函数关键字英文 + 内建函数英文直通（`@embedFile` 有母语映射 `嵌入文件`、全形被拦）
    var v3 = try findEnglishWordForms(gpa, lang, "fn 主函数() 空 {\n    返回 @embedFile(\"t\");\n}\n");
    defer v3.deinit();
    try std.testing.expectEqual(@as(usize, 2), v3.items.len);
    try std.testing.expectEqualStrings("fn", v3.items[0].word);
    try std.testing.expectEqualStrings("@embedFile", v3.items[1].word);
    try std.testing.expectEqualStrings("嵌入文件", v3.items[1].native);
}

test "翻译 + 纯度门：最大/最小 方言词 ↔ 内建 @max/@min（第 144 轮·承 143 删死路径的活替代）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 方言 → Zig：`最大(甲,乙)`/`最小(甲,乙)` 编成 `@max(...)`/`@min(...)`（同 导入→@import 机制、声明名位不受累）。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\公开 函数 主函数() !空 {
        \\    变量 甲: 整数 = 3;
        \\    变量 乙: 整数 = 7;
        \\    变量 大: 整数 = 最大(甲, 乙);
        \\    变量 小: 整数 = 最小(甲, 乙);
        \\}
        \\
    ;
    const expect =
        \\pub fn main() !void {
        \\    var z_1: i64 = 3;
        \\    var z_2: i64 = 7;
        \\    var z_3: i64 = @max(z_1, z_2);
        \\    var z_4: i64 = @min(z_1, z_2);
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);

    // 反向：英文 `@max` 混入方言源被纯度门坐实（`@` 全形反查命中 keywords 映射值）、携母语建议形。
    var v = try findEnglishWordForms(gpa, lang, "变量 结果 = @max(1, 2);\n");
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 1), v.items.len);
    try std.testing.expectEqualStrings("@max", v.items[0].word);
    try std.testing.expectEqualStrings("最大", v.items[0].native);
}

test "翻译 + 纯度门：数学内建方言词 ↔ @sqrt/@floor/@abs（第 146 轮·承 144 同机制、与 143 前缀别名互不劫持）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 方言 → Zig：裸 `平方根(甲)`/`下取整(甲)`/`绝对值(甲)` 编成 `@sqrt/@floor/@abs`；
    // 而带前缀的 `标准库.数学.平方根` 仍走别名链→`std.math.sqrt`（证关键字层不劫持前缀形末段，
    // 否则会误产 `std.math.@sqrt`）。这是本轮 load-bearing 不变量。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\公开 函数 主函数() !空 {
        \\    变量 甲: 实数 = 4.0;
        \\    变量 根 = 平方根(甲);
        \\    变量 整 = 下取整(甲);
        \\    变量 对 = 绝对值(甲);
        \\    变量 标 = 标准库.数学.平方根(甲);
        \\}
        \\
    ;
    const expect =
        \\pub fn main() !void {
        \\    var z_1: f64 = 4.0;
        \\    var z_2 = @sqrt(z_1);
        \\    var z_3 = @floor(z_1);
        \\    var z_4 = @abs(z_1);
        \\    var z_5 = std.math.sqrt(z_1);
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);

    // 反向：英文 `@sqrt` 混入方言源被纯度门坐实（`@` 全形反查命中 keywords 映射值）、携母语建议形。
    var v = try findEnglishWordForms(gpa, lang, "变量 结果 = @sqrt(4.0);\n");
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 1), v.items.len);
    try std.testing.expectEqualStrings("@sqrt", v.items[0].word);
    try std.testing.expectEqualStrings("平方根", v.items[0].native);

    // 无母语映射且 0.17 不存在的 `@pow`（幂走 std.math.pow 别名、非内建）依旧放行——锁「强制面只盖真存在的内建」。
    var vp = try findEnglishWordForms(gpa, lang, "变量 结果 = @pow(2.0, 3.0);\n");
    defer vp.deinit();
    try std.testing.expectEqual(@as(usize, 0), vp.items.len);
}

test "翻译 + 纯度门：三角/指数/对数内建方言词全覆盖（第 147 轮·承 146 同机制、用户拍板全覆盖）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 方言 → Zig：八个新内建方言词（正弦/余弦/正切/自然指数/自然对数/二进制指数/二进制对数/常用对数）各走对应内建。
    // 此八个无同名 std 前缀别名（143 未注 std.math.sin/cos/tan/exp/log），故 146 的劫持面不适用、只需证正向与声明名避让。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\公开 函数 主函数() !空 {
        \\    变量 甲: 实数 = 4.0;
        \\    变量 弦 = 正弦(甲);
        \\    变量 余 = 余弦(甲);
        \\    变量 切 = 正切(甲);
        \\    变量 指 = 自然指数(甲);
        \\    变量 数 = 自然对数(甲);
        \\    变量 二指 = 二进制指数(甲);
        \\    变量 二数 = 二进制对数(甲);
        \\    变量 常 = 常用对数(甲);
        \\}
        \\
    ;
    const expect =
        \\pub fn main() !void {
        \\    var z_1: f64 = 4.0;
        \\    var z_2 = @sin(z_1);
        \\    var z_3 = @cos(z_1);
        \\    var z_4 = @tan(z_1);
        \\    var z_5 = @exp(z_1);
        \\    var z_6 = @log(z_1);
        \\    var z_7 = @exp2(z_1);
        \\    var z_8 = @log2(z_1);
        \\    var z_9 = @log10(z_1);
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);

    // 反向：英文 `@cos`/`@log10` 混入方言源被纯度门坐实、携母语建议形（底数写明口径：@log10→常用对数）。
    var v1 = try findEnglishWordForms(gpa, lang, "变量 结果 = @cos(1.0);\n");
    defer v1.deinit();
    try std.testing.expectEqual(@as(usize, 1), v1.items.len);
    try std.testing.expectEqualStrings("@cos", v1.items[0].word);
    try std.testing.expectEqualStrings("余弦", v1.items[0].native);
    var v2 = try findEnglishWordForms(gpa, lang, "变量 结果 = @log10(1.0);\n");
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 1), v2.items.len);
    try std.testing.expectEqualStrings("@log10", v2.items[0].word);
    try std.testing.expectEqualStrings("常用对数", v2.items[0].native);
}

test "翻译 + 纯度门：余除/位运算内建方言词全覆盖（第 149 轮·承 146/147 同机制、用户拍板全覆盖）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 方言 → Zig：九个新内建方言词（向下取余/截断取余/向下除法/截断除法/前导零计数/尾随零计数/置位计数/字节序翻转/位逆序）各走对应内建。
    // 此九个无同名 std 前缀别名，146 的裸形↔前缀劫持面不适用、只需证正向与声明名避让。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\公开 函数 主函数() !空 {
        \\    变量 甲 = 7;
        \\    变量 乙 = 3;
        \\    变量 戊 = 向下取余(甲, 乙);
        \\    变量 己 = 截断取余(甲, 乙);
        \\    变量 庚 = 向下除法(甲, 乙);
        \\    变量 辛 = 截断除法(甲, 乙);
        \\    变量 壬 = 前导零计数(乙);
        \\    变量 癸 = 尾随零计数(乙);
        \\    变量 子 = 置位计数(乙);
        \\    变量 丑 = 字节序翻转(乙);
        \\    变量 寅 = 位逆序(乙);
        \\}
        \\
    ;
    const expect =
        \\pub fn main() !void {
        \\    var z_1 = 7;
        \\    var z_2 = 3;
        \\    var z_3 = @mod(z_1, z_2);
        \\    var z_4 = @rem(z_1, z_2);
        \\    var z_5 = @divFloor(z_1, z_2);
        \\    var z_6 = @divTrunc(z_1, z_2);
        \\    var z_7 = @clz(z_2);
        \\    var z_8 = @ctz(z_2);
        \\    var z_9 = @popCount(z_2);
        \\    var z_10 = @byteSwap(z_2);
        \\    var z_11 = @bitReverse(z_2);
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);

    // 反向：英文 `@mod`/`@popCount` 混入方言源被纯度门坐实、携母语建议形（写明口径：@mod→向下取余）。
    var v1 = try findEnglishWordForms(gpa, lang, "变量 结果 = @mod(7, 3);\n");
    defer v1.deinit();
    try std.testing.expectEqual(@as(usize, 1), v1.items.len);
    try std.testing.expectEqualStrings("@mod", v1.items[0].word);
    try std.testing.expectEqualStrings("向下取余", v1.items[0].native);
    var v2 = try findEnglishWordForms(gpa, lang, "变量 结果 = @popCount(7);\n");
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 1), v2.items.len);
    try std.testing.expectEqualStrings("@popCount", v2.items[0].word);
    try std.testing.expectEqualStrings("置位计数", v2.items[0].native);
    // 未登记内建 `@fabs`（坐实不存在、绝对值统一走 @abs）混入仍放行 0 项——锁「强制面只盖真登记内建」。
    var v3 = try findEnglishWordForms(gpa, lang, "变量 结果 = @fabs(1.0);\n");
    defer v3.deinit();
    try std.testing.expectEqual(@as(usize, 0), v3.items.len);
}

test "翻译 + 纯度门：除法族补全与类型元内建方言词登记（第 150 轮·收官审计、用户拍板 @divExact + 全部 6 词）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 正向：@divExact（149 除法族漏登的第 5 个成员）+ 类型元六词各走对应内建。
    // 类型元 arg 为类型或返回字符串、属新领域（第 150 轮用户拍板开启）；本包为纯 token 替换、不跑 zig sema，
    // 故形如 `@sizeOf(i64)` 只需验证方言词→内建名的整词映射、无需产物语义合法。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\公开 函数 主函数() !空 {
        \\    变量 甲 = 6;
        \\    变量 乙 = 3;
        \\    变量 丙 = 精确整除(甲, 乙);
        \\    变量 丁 = 类型大小(整数);
        \\    变量 戊 = 对齐大小(整数);
        \\    变量 己 = 位大小(整数);
        \\    变量 庚 = 类型名(整数);
        \\    变量 辛 = 标签名(乙);
        \\    变量 壬 = 错误名(乙);
        \\}
        \\
    ;
    const expect =
        \\pub fn main() !void {
        \\    var z_1 = 6;
        \\    var z_2 = 3;
        \\    var z_3 = @divExact(z_1, z_2);
        \\    var z_4 = @sizeOf(i64);
        \\    var z_5 = @alignOf(i64);
        \\    var z_6 = @bitSizeOf(i64);
        \\    var z_7 = @typeName(i64);
        \\    var z_8 = @tagName(z_2);
        \\    var z_9 = @errorName(z_2);
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);

    // 反向：英文 `@divExact`/`@sizeOf` 混入方言源被纯度门坐实、携母语建议形。
    var v1 = try findEnglishWordForms(gpa, lang, "变量 结果 = @divExact(6, 3);\n");
    defer v1.deinit();
    try std.testing.expectEqual(@as(usize, 1), v1.items.len);
    try std.testing.expectEqualStrings("@divExact", v1.items[0].word);
    try std.testing.expectEqualStrings("精确整除", v1.items[0].native);
    var v2 = try findEnglishWordForms(gpa, lang, "变量 结果 = @sizeOf(整数);\n");
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 1), v2.items.len);
    try std.testing.expectEqualStrings("@sizeOf", v2.items[0].word);
    try std.testing.expectEqualStrings("类型大小", v2.items[0].native);
    // 坐实不存在的 `@memberCount`（0.17 无此内建、须走 std.meta）混入仍放行 0 项——锁「强制面只盖真登记内建」。
    var v3 = try findEnglishWordForms(gpa, lang, "变量 结果 = @memberCount(乙);\n");
    defer v3.deinit();
    try std.testing.expectEqual(@as(usize, 0), v3.items.len);
}

test "翻译 + 纯度门：除法族@divCeil·精确移位·类型元内建方言词登记（第 151 轮·编译器注册表系统审计续补、用户拍板全部 5 词）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 正向：除法族第 6 员 @divCeil（向上取整）+ 精确移位族 @shlExact/@shrExact + 类型元 @typeInfo/@This 逐字节快照。
    // 本包为纯 token 替换、不跑 zig sema，故只需验方言词→内建名的整词映射、无需产物语义合法。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\公开 函数 主函数() !空 {
        \\    变量 甲 = 6;
        \\    变量 乙 = 3;
        \\    变量 丙 = 向上除法(甲, 乙);
        \\    变量 丁 = 精确左移(甲, 乙);
        \\    变量 戊 = 精确右移(甲, 乙);
        \\    变量 己 = 类型信息(整数);
        \\    变量 庚 = 本类型();
        \\}
        \\
    ;
    const expect =
        \\pub fn main() !void {
        \\    var z_1 = 6;
        \\    var z_2 = 3;
        \\    var z_3 = @divCeil(z_1, z_2);
        \\    var z_4 = @shlExact(z_1, z_2);
        \\    var z_5 = @shrExact(z_1, z_2);
        \\    var z_6 = @typeInfo(i64);
        \\    var z_7 = @This();
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);

    // 反向：英文 `@divCeil`/`@typeInfo` 混入方言源被纯度门坐实、携母语建议形。
    var v1 = try findEnglishWordForms(gpa, lang, "变量 结果 = @divCeil(6, 3);\n");
    defer v1.deinit();
    try std.testing.expectEqual(@as(usize, 1), v1.items.len);
    try std.testing.expectEqualStrings("@divCeil", v1.items[0].word);
    try std.testing.expectEqualStrings("向上除法", v1.items[0].native);
    var v2 = try findEnglishWordForms(gpa, lang, "变量 结果 = @typeInfo(整数);\n");
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 1), v2.items.len);
    try std.testing.expectEqualStrings("@typeInfo", v2.items[0].word);
    try std.testing.expectEqualStrings("类型信息", v2.items[0].native);
    // 关键防回归：死映射 `类型=@Type` 已删，英文 `@Type` 混入不再被反查命中（放行 0 项）——
    // 若有人重建 @Type 映射，本断言即红（与 pack.zig「内建存在性不变量」护栏同治）。
    var v3 = try findEnglishWordForms(gpa, lang, "变量 结果 = @Type(整数);\n");
    defer v3.deinit();
    try std.testing.expectEqual(@as(usize, 0), v3.items.len);
}

test "翻译 + 纯度门：关键字方言词补登 测试块=test / 紧实=packed / 无别名=noalias（第 152 轮·关键字注册表审计、用户拍板避让既有键名）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 正向逐字节快照：三词各自在其句法位整词命中（紧实修饰 struct、无别名修饰参数、测试块开块）。
    // 本形与 152 轮 `zzc check` 端到端实跑（fresh cache 刷新内联字节后）逐字一致、且 zig 真编译退 0。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\常数 位域 = 紧实 结构 { 甲: u1, 乙: u3 };
        \\
        \\函数 加一(无别名 指针: *字节) 空 {
        \\    指针.* += 1;
        \\}
        \\测试块 "最小" {
        \\    变量 数: 字节 = 1;
        \\    加一(&数);
        \\    常数 值 = 位域{ .甲 = 1, .乙 = 2 };
        \\    _ = 值;
        \\}
        \\
    ;
    const expect =
        \\const z_1 = packed struct { z_2: u1, z_3: u3 };
        \\
        \\fn z_4(noalias z_5: *u8) void {
        \\    z_5.* += 1;
        \\}
        \\test "最小" {
        \\    var z_6: u8 = 1;
        \\    z_4(&z_6);
        \\    const z_7 = z_1{ .z_2 = 1, .z_3 = 2 };
        \\    _ = z_7;
        \\}
        \\
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);

    // 声明名避让：新词形被用户当名字用时不查表（与 D1 哲学一致、不然 `常数 测试块 = 1;` 产 `const test = 1;`）。
    var t2 = Mangle.init(gpa);
    defer t2.deinit();
    const avoided = try translate(gpa, "常数 测试块 = 1;\n", lang, &t2);
    try std.testing.expectEqualStrings("const z_1 = 1;\n", avoided.zig_str);

    // 反向：三个新登记词对应的英文关键字混入方言源均被纯度门坐实、携母语建议形
    //（登记生效的同时就把该英文形纳入强制面——这是补词的行为副产品、与 D44 机制同源）。
    var v1 = try findEnglishWordForms(gpa, lang, "常数 位域 = packed 结构 { 甲: u1 };\n");
    defer v1.deinit();
    try std.testing.expectEqual(@as(usize, 1), v1.items.len);
    try std.testing.expectEqualStrings("packed", v1.items[0].word);
    try std.testing.expectEqualStrings("紧实", v1.items[0].native);
    var v2 = try findEnglishWordForms(gpa, lang, "test \"赋值\" {}\n");
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 1), v2.items.len);
    try std.testing.expectEqualStrings("test", v2.items[0].word);
    try std.testing.expectEqualStrings("测试块", v2.items[0].native);
    var v3 = try findEnglishWordForms(gpa, lang, "函数 甲(noalias 乙: *字节) 空 {}\n");
    defer v3.deinit();
    try std.testing.expectEqual(@as(usize, 1), v3.items.len);
    try std.testing.expectEqualStrings("noalias", v3.items[0].word);
    try std.testing.expectEqualStrings("无别名", v3.items[0].native);

    // 关键防回归（D54）：死映射 `异步=async` / `等待=await` 已删，英文 `async`/`await` 混入
    // 不再被反查命中（放行 0 项）——若有人重建该两行映射，本断言即红（与 pack.zig
    // 「关键字存在性不变量」护栏同治；放行者系「无母语映射的合法直通词」口径、非缺陷）。
    var v4 = try findEnglishWordForms(gpa, lang, "变量 戊 = async 函数();\n");
    defer v4.deinit();
    try std.testing.expectEqual(@as(usize, 0), v4.items.len);
    var v5 = try findEnglishWordForms(gpa, lang, "变量 己 = await 戊;\n");
    defer v5.deinit();
    try std.testing.expectEqual(@as(usize, 0), v5.items.len);
}

test "翻译逐字节快照：复合多 token 类型表达式映射值 字符串=[]u8（第 153 轮·护栏盲区补齐，151/152 测均跳过的第三分区）" {
    // [keywords] 映射值三分区：@-前缀（151 测）、ASCII 单 token（152 测）、复合多 token 类型表达式。
    // 既有快照仅盖 `文本 = []const u8`（声明位测），`字符串 = []u8` 形零覆盖——值被改坏要到真编译才暴。
    // 本测以真编译坐实的形制（类型标注位整词展开）钉住两复合值的译出，与 pack.zig 分区不变量测同治。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    const src =
        \\变量 缓冲: 字符串 = 未定义;
        \\常数 名字: 文本 = "hi";
        \\缓冲 = 名字;
        \\_ = 缓冲;
    ;
    const expect =
        \\var z_1: []u8 = undefined;
        \\const z_2: []const u8 = "hi";
        \\z_1 = z_2;
        \\_ = z_1;
    ;
    const res = try translate(gpa, src, lang, &table);
    try std.testing.expectEqualStrings(expect, res.zig_str);
}

test "纯母语强制：母语全等豁免位不误拦（串/注释/数字/C ABI/@\"...\"/点后/声明名位）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 真实 demo 级纯母语源：零违例
    const clean =
        \\常数 标准库 = 导入("std");
        \\公开 函数 主函数() !空 {
        \\    变量 数量: 整数 = 10;
        \\    标准库.调试.打印("hello {d}\n", .{数量});
        \\}
        \\'
    ;
    var v0 = try findEnglishWordForms(gpa, lang, clean);
    defer v0.deinit();
    try std.testing.expectEqual(@as(usize, 0), v0.items.len);

    // 数字字面量与含字母混合形（非映射值）天然放行；C ABI 名不属映射值放行；
    // 字符串/注释/@"..."/点分链段不拆解、不检查；映射值恰作用户名时声明避让、交下游诊断。
    const exempt =
        \\常数 版本 = 12345;
        \\常数 十六 = 0xFF;
        \\常数 说明 = "constant 数量 and void";
        \\// const fn void 混入都不报错
        \\常数 符号 = @"true";
        \\公开 外部 函数 调用外部(x: c_int) 调用约定(.c) c_char {
        \\    返回 x;
        \\}
        \\常数 常量 = 1;
        \\常数 结构 = .{ .true = 1 };
        \\常数 路径 = "sub/mod";
        \\'
    ;
    var v1 = try findEnglishWordForms(gpa, lang, exempt);
    defer v1.deinit();
    if (v1.items.len > 0) std.debug.print("exempt misfires: {s}\n", .{v1.items[0].word});
    try std.testing.expectEqual(@as(usize, 0), v1.items.len);
}

test "纯母语强制：任意语言包泛化——反查映射值不硬编码中文表" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // 合成非 zh 包：值集合与 zh 不同，验证判据取自考的包而非硬编码清单
    const synthetic =
        \\$name = eo
        \\$code = eo
        \\[keywords]
        \\konstant = const
        \\funkcio = fn
        \\tipo = void
        \\[aliases]
        \\ĉefa = main
    ;
    var lang = try Pack.parse(gpa, synthetic);
    defer lang.deinit();
    var v = try findEnglishWordForms(gpa, lang, "const x = 1;\nfn main() void {}\n");
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 3), v.items.len); // const / fn / void；main 属 aliases 领土不在关键字判据内
    try std.testing.expectEqualStrings("const", v.items[0].word);
    try std.testing.expectEqualStrings("fn", v.items[1].word);
    try std.testing.expectEqualStrings("void", v.items[2].word);
}

test "纯母语强制：映射值恰作用户名时声明避让（与 D1 哲学一致、交下游更准诊断）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // `函数` 后的 `if` 居声明名位（方言词声明 + 英文名）：不报「请改母语」而交 zig 语法错
    // （更准：若报请改母语反而误导用户去改一个本就合法的位置）。
    const src = "函数 if() 空 {\n}\n";
    var v = try findEnglishWordForms(gpa, lang, src);
    defer v.deinit();
    try std.testing.expectEqual(@as(usize, 0), v.items.len);
}

test "D45 类型词覆盖补全：用户原型示例 `常数 x: i32 = 10;` 混入英文定宽类型词被拦（先红）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 用户判定原则的原型示例：声明位中文、类型词英文。此前 i32 不在包映射值集合、
    // 门无从坐实（端到端 EXIT=0 实锤）；补全词条后英文形即违例、携母语建议形。
    var v1 = try findEnglishWordForms(gpa, lang, "常数 x: i32 = 10;\n");
    defer v1.deinit();
    try std.testing.expectEqual(@as(usize, 1), v1.items.len);
    try std.testing.expectEqualStrings("i32", v1.items[0].word);
    try std.testing.expectEqualStrings("中整数", v1.items[0].native);

    // 同词族其余形：u32 被拦；母语形 `半精度` 不属违例（它就是被推荐的写法）。
    var v2 = try findEnglishWordForms(gpa, lang, "变量 a: u32 = 1;\n常数 b: 半精度 = 2;\n");
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 1), v2.items.len);
    try std.testing.expectEqualStrings("u32", v2.items[0].word);
    try std.testing.expectEqualStrings("中无符号整数", v2.items[0].native);

    // 避让面不受累：映射值恰作用户名时声明位照旧避让（交下游更准诊断）。
    var v3 = try findEnglishWordForms(gpa, lang, "常数 i32 = 1;\n");
    defer v3.deinit();
    try std.testing.expectEqual(@as(usize, 0), v3.items.len);
}

test "D45 类型词覆盖守卫：常用定宽类型词有母语词条且类型标注位命中翻译" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 覆盖守卫：iN/uN 常用位宽与 isize/f16/f128 逐值有母语词条——补一半漏一半正是
    // 「同词族半拦半放」不一致的根因；新增词条使纯度门对英文形自动坐实。
    const want = [_][2][]const u8{
        .{ "有符号字节", "i8" },
        .{ "中整数", "i32" },
        .{ "短无符号整数", "u16" },
        .{ "中无符号整数", "u32" },
        .{ "长无符号整数", "u128" },
        .{ "有符号字", "isize" },
        .{ "半精度", "f16" },
        .{ "四倍精度", "f128" },
    };
    for (want) |p| {
        try std.testing.expectEqualStrings(p[1], lang.keywords.get(p[0]).?);
    }

    // 翻译行为面：母语类型词在类型标注位命中新词条、产出标准定宽类型。
    var table = Mangle.init(gpa);
    defer table.deinit();
    const res = try translate(gpa, "常数 甲: 中整数 = 3;\n", lang, &table);
    try std.testing.expectEqualStrings("const z_1: i32 = 3;\n", res.zig_str);
}

test "D47 入口词形在 keywords 段：fn 声明位避让不得把 main 映射词形 intern 成 z_N（静默浅检陷阱）" {
    // 缺陷面：B6 契约 hasMappedValue 查 keywords∪aliases 两表、贡献者把 `X = main` 放 keywords
    // 完全合法；但入口定义位在 `函数`(→fn) 声明名位、避让规则使其 intern 成 z_1——生成物失去
    // `pub fn main(`，check 退化成库形浅检假成功。中文先例 `主函数 = main` 实属 aliases 段
    // （第 1 步链不受声明位避让）才可用——两段皆可的契约必须两段皆真生效（R9g 外部包开发探针坐实）。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa,
        \\    $code = ja
        \\    [keywords]
        \\    定数 = const
        \\    公開 = pub
        \\    関数 = fn
        \\    メイン関数 = main
    );
    defer lang.deinit();

    var table = Mangle.init(gpa);
    defer table.deinit();
    const res = try translate(gpa, "公開 関数 メイン関数() void { }\n", lang, &table);
    try std.testing.expectEqualStrings("pub fn main() void { }\n", res.zig_str);
    // 非入口形（声明动词语后无 `(`）不受特例：`関数 メイン関数` 之外的普通名仍走避让——
    // 若日后真有 `定数 メイン関数 = 5`（常量名叫入口词形）属包作者命名冲突，避让哲学不变。
}

test "D48（第 104 轮）/第 142 轮：init 模板按包生成——中外语两包皆零违例过自家门、产物皆真入口" {
    // 缺陷面（历两层）：99 轮 D44 纯度门升格后 dogfood 漏了旧模板 ASCII `void`（D48）；旧模板又是
    // 中文常量形，选外语包时中文词元全被 intern、出生即碎码（第 142 轮探针 T2：check 报
    // 「期望 ',' after field」退 1）——本测两包两面钉死：任何合格包下模板恒零违例且产 `pub fn main(`。
    const cli = @import("../cli/args.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // 面 A：中文包（默认路径，与 104 轮同断言面）。
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    const zh_tmpl = try cli.buildInitTemplate(gpa, lang);

    var v = try findEnglishWordForms(gpa, lang, zh_tmpl);
    defer v.deinit();
    if (v.items.len != 0) {
        std.debug.print("init 模板混入英文词形: {s}（母语形应为 {s}）\n", .{ v.items[0].word, v.items[0].native });
        return error.TestUnexpectedResult;
    }

    var table = Mangle.init(gpa);
    defer table.deinit();
    const res = try translate(gpa, zh_tmpl, lang, &table);
    try std.testing.expect(std.mem.indexOf(u8, res.zig_str, "pub fn main() !void {") != null);
    // 中文包全词形齐备（非降级路径）：方言形必在产物里、ASCII 兜底形不得泄漏。
    try std.testing.expect(std.mem.indexOf(u8, res.zig_str, "std.debug.print(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zh_tmpl, "常数") != null);
    try std.testing.expect(std.mem.indexOf(u8, zh_tmpl, "标准库.调试.打印") != null);
    // 串内 `\n` 必为字面两字符（第 142 轮实现期自捕：生成器误落真换行字节，zig 拒
    // 「string literal contains invalid byte」——模板串跨全部包共用，单点钉住即可）。
    try std.testing.expect(std.mem.indexOf(u8, zh_tmpl, "结果是 {d}\\n") != null);

    // 面 B：外语包——只具 B6 契约 13 值（无 pub/void/i64/std/打印 映射，第 142 轮探针包形）：
    // 降级链全走——产物仍合法零违例、仍经 main_def_pos/别名链两径产真入口。
    const ja_pack =
        "$format = 1\n" ++
        "$code = ja\n$name = 探针语\n[keywords]\n" ++
        "定数 = const\n変数 = var\n関数 = fn\n条件 = if\n代替 = else\n" ++
        "戻り = return\n構造 = struct\n列挙 = enum\n結合 = union\n選択 = switch\n" ++
        "取込 = @import\n埋込 = @embedFile\n契約 = main\n";
    var jlang = try Pack.parse(gpa, ja_pack);
    defer jlang.deinit();
    const ja_tmpl = try cli.buildInitTemplate(gpa, jlang);

    var v2 = try findEnglishWordForms(gpa, jlang, ja_tmpl);
    defer v2.deinit();
    try std.testing.expectEqual(@as(usize, 0), v2.items.len); // 降级 ASCII 形对本包不可坐实、天然零违例

    var table2 = Mangle.init(gpa);
    defer table2.deinit();
    const jres = try translate(gpa, ja_tmpl, jlang, &table2);
    // 真行为（第 142 轮探针复跑自捕二）：zig 硬要求 `pub fn main`（非公开入口编译拒
    // 「'main' is not marked 'pub'」）——ja 包无 `pub` 映射时 w_pub 降级 ASCII 直通，产物仍
    // `pub fn main() !void {`；入口词形取契约值 `契約`(=main)，修饰符/返回类型走 ASCII 兜底。
    try std.testing.expect(std.mem.indexOf(u8, jres.zig_str, "pub fn main() !void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, jres.zig_str, "契約") == null); // 契约值 main 被翻译、不外泄
    // 外语包侧必用包词形，且中文形不得泄漏（旧缺陷形：恒为中文常量）。
    try std.testing.expect(std.mem.indexOf(u8, ja_tmpl, "定数") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja_tmpl, "常数") == null);
    try std.testing.expect(std.mem.indexOf(u8, ja_tmpl, "std.debug.print(") != null); // 打印降级 ASCII 直通形
    // 探针复跑自捕三：ja 包无 `i64` 映射→类型注降级 ASCII 直通（缺注会产 `var 数 = 10` 零宽
    // comptime_int、再赋值 zig 拒「must be given an explicit fixed-size number type」）——钉住兜底形存在。
    try std.testing.expect(std.mem.indexOf(u8, ja_tmpl, ": i64 = 10;") != null);
    try std.testing.expect(std.mem.indexOf(u8, jres.zig_str, ": i64 = 10;") != null);
}

// TEMP-PROBE R105 已坐实假说并删除：全范围注入 k=0..7 仅 hits 桶槽（dupe 紧邻分配）产生
// leaked [len: 5]（= dupe("const") 的 full），join/viol.append 槽因既有 catch 零泄漏——
// 同一函数三处 OOM 路径唯独 hits.append 裸 try（不对称即铁证）。固定为下方正式测。

test "D49（第 105 轮）findEnglishWordForms hits 增长失败须回收 full（D26/D29/D37 泄漏族·可确定性注入）" {
    // 背景：违例词串 full（dupe/allocPrint）分配后、移交 viol 前有一段裸 try 窗口：`try hits.append`
    // 若 OOM 直接返错无人回收 full（生产走 arena 被整段回吞掩盖、历轮直测全用 arena 包裹故未暴——
    // 同 D27/D37 盲区先例）。修法 = 同函数 join/viol.append 已有的 catch 回滚同形。
    // 注入槽零魔法数：计数跑枚举全部分配，拿 len==违例词字节数的槽（即 dupe full），目标 = 紧邻其后
    // 的分配（hits 桶增长——dupe 后第一笔分配就是它）；槽形断言防漂移。
    const Counter = struct {
        backing: std.mem.Allocator,
        lens: [64]usize = undefined,
        count: usize = 0,
        fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.count < self.lens.len) self.lens[self.count] = len;
            self.count += 1;
            return self.backing.rawAlloc(len, a, ra);
        }
        fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawResize(m, a, nl, ra);
        }
        fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawRemap(m, a, nl, ra);
        }
        fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.backing.rawFree(m, a, ra);
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup = arena.allocator();
    var lang = try Pack.parse(setup, zh_pack);
    defer lang.deinit();

    const src = "const 数量 = 10;\n";
    const back = std.testing.allocator;
    var ca = Counter{ .backing = back };
    const cgpa = ca.allocator();
    var w0 = try findEnglishWordForms(cgpa, lang, src);
    w0.deinit();
    try std.testing.expect(ca.count <= ca.lens.len); // 计数数组未溢出（溢出则槽分析失真）

    // 唯一 len==5（"const"）的分配即 dupe full；违例词改长串须同步此锚，不属互操作面。
    var dupe_idx: ?usize = null;
    for (ca.lens[0..ca.count], 0..) |l, i| {
        if (l == 5) {
            try std.testing.expect(dupe_idx == null); // 锚须唯一，防多笔同长分配偷换槽位
            dupe_idx = i;
        }
    }
    const target = (dupe_idx orelse return error.AnchorNotFound) + 1;
    try std.testing.expect(target < ca.count); // 紧随其后的分配（hits 桶）必存在
    try std.testing.expect(ca.lens[target] >= 16); // 槽形：hits 存串切片，一槽至少 16 字节

    // 注入跑：full 成功、杀 hits 桶——旧形漏 full（测毕 testing.allocator 报 leaked 红，
    // 本轮探针实证 leaked len:5）；修复形回滚后无泄漏、错仍上传。
    var failing = std.testing.FailingAllocator.init(back, .{ .fail_index = target });
    try std.testing.expectError(error.OutOfMemory, findEnglishWordForms(failing.allocator(), lang, src));
}

test "护栏：转译声明位回扫谓词边界形——未闭合/畸形括号不崩、首领归属不漂移（第 109 轮证伪落位）" {
    // 承 108 轮方法论：`findOpenBracket`/`findMatchingOpen`/`braceGroupLeader` 三个回扫配对谓词
    // 决定 `isExtendedDeclNamePos` case B 的枚举成员/union 变体/error 标签避让，此前仅经
    // D1b/D1c/D42 端到端测间接触达、零直调覆盖（脚本实测测试区直调为 0）。逐例推演证伪皆
    // 安全（深度配对、未闭合扫到头返 null、`.{` 与 brace_idx==0 首领非词元返 null），本测把
    // 推演结论钉成回归防线：畸形输入不 panic、匹配归属不漂移（未来改动破配对/边界即红）。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const Find = struct {
        fn punct(toks: []const lexer.Token, src: []const u8, c: u8) usize {
            for (toks, 0..) |t, idx| {
                if (t.kind == .punct and t.text(src).len == 1 and t.text(src)[0] == c) return idx;
            }
            @panic("测试构造词流不含目标标点（护栏用例前提失真）");
        }
    };

    // braceGroupLeader：`枚举(u8) {` 首领跳一层参数括号认到 `枚举`（D42 修复面行为钉牢）
    {
        const s = "枚举(u8) { 文本 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        const lead = braceGroupLeader(toks, s, Find.punct(toks, s, '{'));
        try std.testing.expect(lead != null);
        try std.testing.expectEqualStrings("枚举", lead.?.text(s));
    }
    // braceGroupLeader：`.{ 文本 }` 结构字面量首领位是 `.`（非词元）→ null（成员照转码、不避让）
    {
        const s = ".{ 文本 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(null, braceGroupLeader(toks, s, Find.punct(toks, s, '{')));
    }
    // braceGroupLeader：`{` 为词流首元（brace_idx==0）→ null、不越界回读 toks[-1]
    {
        const s = "{ 文本 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(null, braceGroupLeader(toks, s, 0));
    }
    // findMatchingOpen：`枚举(u8)` 的 `)` 回跳匹配到对应 `(`
    {
        const s = "枚举(u8) { 文本 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        const open = findMatchingOpen(toks, s, Find.punct(toks, s, ')'));
        try std.testing.expect(open != null);
        try std.testing.expectEqualStrings("(", toks[open.?].text(s));
    }
    // findMatchingOpen：起始 `)` 无配对 → 扫到头 null、不 panic
    {
        const s = ") 文本";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(null, findMatchingOpen(toks, s, 0));
    }
    // findOpenBracket：`{ 文本 ,` 回溯命中未配对 `{`
    {
        const s = "{ 文本 ,";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        const ob = findOpenBracket(toks, s, Find.punct(toks, s, ','));
        try std.testing.expect(ob != null);
        try std.testing.expectEqual(@as(u8, '{'), ob.?.ch);
    }
    // findOpenBracket：`( 文本 ) ,` 先配平内层括号再回扫 → 该处无未配对开括号、null（深度配对不漂移）
    {
        const s = "( 文本 ) ,";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(null, findOpenBracket(toks, s, Find.punct(toks, s, ',')));
    }
    // findOpenBracket：全流无开括号 → null、不越界
    {
        const s = "文本 , 更多";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(null, findOpenBracket(toks, s, Find.punct(toks, s, ',')));
    }
}

// 护栏（第 179 轮增量审计·证伪撤号）：`isAsciiAlphaByte`（L750·`expectNoEnglishSentence` 的词内
// 字符判据）、`isDeclVerb`（L67·`prevIsDeclKeyword`/D1 声明位避让的声明动词判据）与 `isPunctAt`
// （L96·`prevIsColon`/`isExtendedDeclNamePos` 诸句法位标点核查的共享核）皆同文件私有纯谓词、
// 全库零直调。isAsciiAlphaByte 精确字节集从未被钉——它系 111 isIdentByte/175 isIdentChar/178
// isWordCharByte 同族的第四面且区别点恰在**数字与 `_` 于此非词字符**（`abc1def` 计两词、`a_b`
// 被下划线断开）：误扩成 alnum 形即静默改变守卫二计词粒度，而 117 测各例皆不喂数字/下划线相邻
// 形不受累；isDeclVerb 恰集 {const,var,fn} 之全等/大小写/前后缀 near-miss 从未被钉——误并一个
// 动词（如 `pub`）即令 D1 避让对「该词后声明名」静默过度保护、查表替换静默失效；isPunctAt 四
// 守卫（越界 k/词类门/单字符/字符全等）与 prevIsColon 的 i==0 下溢门 109 轮仅推演证伪从未落
// 形钉——尤其 `k >= toks.len` 臂背着 L198/L269 的 i+1 peek 词尾形态，而真 lexer 流永不产 len>1
// punct 或含冒号的非 punct 词元，防御形唯合成词元可钉。探针先行即以本测首跑承担（对独立
// oracle `std.ascii.isAlphabetic` 做 iff 对照 + 合成词元形实跑），一次绿坐实无在线缺陷→不占 D 号。
test "isAsciiAlphaByte：全字节 iff 穷举钉 ASCII 字母集恰 [A-Za-z]（数字/_ 非词字符·区别 111/175/178 同族集，第 179 轮）" {
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        // 独立 oracle 取 std.ascii.isAlphabetic（手写区间判据 vs 标准库），双向 iff 锁死恰集。
        try std.testing.expect(std.ascii.isAlphabetic(b) == isAsciiAlphaByte(b));
    }
    // 关键边界点名：字母放行；数字/下划线/DEL/高字节拒（与同族词字符集的定义性区别）。
    try std.testing.expect(isAsciiAlphaByte('a'));
    try std.testing.expect(isAsciiAlphaByte('Z'));
    try std.testing.expect(!isAsciiAlphaByte('0'));
    try std.testing.expect(!isAsciiAlphaByte('_'));
    try std.testing.expect(!isAsciiAlphaByte(0x7F));
    try std.testing.expect(!isAsciiAlphaByte(0x80));
}

test "isDeclVerb：声明动词恰集 {const,var,fn} 全等 + near-miss/大小写/空白形全拒（D1 避让判据核，第 179 轮）" {
    try std.testing.expect(isDeclVerb("const"));
    try std.testing.expect(isDeclVerb("var"));
    try std.testing.expect(isDeclVerb("fn"));
    // 全等非前缀：超串/子串/拼串形皆非声明动词。
    try std.testing.expect(!isDeclVerb(""));
    try std.testing.expect(!isDeclVerb("con"));
    try std.testing.expect(!isDeclVerb("constx"));
    try std.testing.expect(!isDeclVerb("xconst"));
    try std.testing.expect(!isDeclVerb("fnx"));
    try std.testing.expect(!isDeclVerb("var1"));
    // 超集防卫：pub/struct 等其它关键字非声明动词——误并一律即令 D1 避让对「该词后声明名」
    // 静默过度保护；大小写与带空白形亦拒（精确字节全等、无折叠无 trim）。
    try std.testing.expect(!isDeclVerb("pub"));
    try std.testing.expect(!isDeclVerb("struct"));
    try std.testing.expect(!isDeclVerb("Const"));
    try std.testing.expect(!isDeclVerb("VAR"));
    try std.testing.expect(!isDeclVerb(" fn"));
    try std.testing.expect(!isDeclVerb("fn "));
}

test "isPunctAt 四守卫 + prevIsColon i==0 下溢门：合成词元与真词流直钉（句法位标点共享核，第 179 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // 合成词元钉 isPunctAt 防御臂：真 lexer 流永不产这些形。
    {
        const s = ":->:"; // 0 ':' | 1..2 "->"（合成多字符 punct）| 3 ':'（合成 ascii_word 含冒号）
        const toks = [_]lexer.Token{
            .{ .kind = .punct, .off = 0, .len = 1 },
            .{ .kind = .punct, .off = 1, .len = 2 },
            .{ .kind = .ascii_word, .off = 3, .len = 1 },
        };
        // ① 基线命中：单字符 punct 全等。
        try std.testing.expect(isPunctAt(&toks, s, 0, ':'));
        // ② 字符不等拒。
        try std.testing.expect(!isPunctAt(&toks, s, 0, '-'));
        // ③ 多字符 punct len!=1 拒（首字符恰等亦不命中——len 门 load-bearing 形）。
        try std.testing.expect(!isPunctAt(&toks, s, 1, '-'));
        // ④ 词类门：文本为 ':' 的 ascii_word 非 punct。
        try std.testing.expect(!isPunctAt(&toks, s, 2, ':'));
        // ⑤ 越界 k>=toks.len 拒（L198/L269 i+1 peek 词尾形态、不越界读）。
        try std.testing.expect(!isPunctAt(&toks, s, 3, ':'));
        // ⑥ 空词流 k==0>=len 拒。
        const empty: []const lexer.Token = &.{};
        try std.testing.expect(!isPunctAt(empty, s, 0, ':'));
    }

    // 真词流钉 prevIsColon 三门：i==0 下溢防词门/非 punct 前词/异标点前词。
    {
        const s = "a : b";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        // ⓪ i==0：无 toks[-1]、 usize 下溢防御门返 false。
        try std.testing.expect(!prevIsColon(s, toks, 0));
        // 前词为 ascii_word → false；紧邻 punct ':' → true（类型标注位）。
        try std.testing.expect(!prevIsColon(s, toks, 1));
        try std.testing.expect(prevIsColon(s, toks, 2));
    }
    {
        const s = "a . b";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        // 前词为异 punct '.' → false（字符全等门而非仅词类门）。
        try std.testing.expect(!prevIsColon(s, toks, 2));
    }
}

// 护栏（第 180 轮增量审计·证伪撤号）：`isImportOperand`（L43·D2 `.zz`→`.zig` 改写只作用导入
// 参数面的判定核：`(` punct 三门 + 非 ASCII 词形 keywords→aliases **两级**回退 + 直通 `@` `import`
// 形 i>=3 门）、`prevIsDeclKeyword`（L76·D1 声明位避让上层：i==0 门 + 非 ASCII 查 keywords **单级**
// /ASCII 原文两路）、`mappedIs`（L127·D42 组首领 enum/union/error 与 D47 入口位前词 fn 的共享核，
// 同 keywords-only）与 `punctChar`（L138·179 轮 isPunctAt 同族四守卫的 `?u8` 返回变体，109 轮仅
// 推演证伪）皆同文件私有纯谓词、全库零直调（grep 坐实仅 L285/L261+L896/L207+L269/L154+L172+L202
// 生产位内部调用）。关键缺口：①`isImportOperand` 的 `orelse lang.aliases.get(hw)` fallback 臂——现网
// zh 包 `导入 = @import` 居 [keywords] 段（包 L110-111 明注「刻意为之」），此臂于任何现包/端到端测
// 恒不 fired，真隐缝，唯合成包 aliases 形可钉；②其与 prevIsDeclKeyword/mappedIs 的**查链不对称契约**
// （后二者 keywords-only、词在 aliases 亦拒）从未两面对钉——「顺手统一」三查链即让别名链吞掉声明位
// 避让语义；③直通形 i>=3 门（裸 `import("x")` 于 i==2 必拒、防 toks[i-3] 下溢回读）零钉；④punctChar
// 越界/词类/多字符/空文本四臂唯合成词元可 fired。探针先行即以本测首跑承担，一次绿坐实真形皆符
// 声明行为、无在线缺陷→不占 D 号（同 111/170-179 判例）。
test "isImportOperand：aliases fallback 臂（现包恒不 fired·真隐缝）+ 直通 i>=3 门 + `(` 三门（D2 改写判定核，第 180 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // 方言形 `导入("x")`：非 ASCII 词 keywords 命中 `@import` → 字符串词元位 true。
    {
        const s = "导入(\"x\")";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(usize, 4), toks.len); // 导入 | ( | "x" | )
        try std.testing.expect(isImportOperand(lang, s, toks, 2));
        // i<2 下溢门：前两词元不回读 toks[i-1]/toks[i-2]。
        try std.testing.expect(!isImportOperand(lang, s, toks, 0));
        try std.testing.expect(!isImportOperand(lang, s, toks, 1));
    }
    // `(` 词类门：字符串紧邻前词为非 punct 词元（`变量 导入 "x"`）→ false、不达查表。
    {
        const s = "变量 导入 \"x\"";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!isImportOperand(lang, s, toks, 2));
    }
    // 直通形 `@import("x")`（词流 @ | import | ( | "x" | )、与 114 轮分词护栏交叉）；裸 `import(`
    // 于 i==2 坠 i>=3 门拒（toks[i-3] 下溢防御）；`x import("s")` 的 i-3 位非 `@` 拒（词类+字符门）。
    {
        const s = "@import(\"x\")";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isImportOperand(lang, s, toks, 3));
        const s2 = "import(\"x\")";
        const toks2 = try lexer.scan(gpa, s2);
        defer gpa.free(toks2);
        try std.testing.expect(!isImportOperand(lang, s2, toks2, 2));
        const s3 = "x import(\"s\")";
        const toks3 = try lexer.scan(gpa, s3);
        defer gpa.free(toks3);
        try std.testing.expect(!isImportOperand(lang, s3, toks3, 3));
    }
    // aliases fallback 臂（真隐缝）：zh 包 `导入` 居 keywords 段、现网形恒不 fired 此臂——
    // 合成包词形只入 [aliases] 映射 `@import`，钉其被回退命中（非 zh 包合法形制、D2 改写门对该包生效）。
    {
        const synthetic =
            \\$name = eo
            \\$code = eo
            \\[aliases]
            \\导入 = @import
        ;
        var lang2 = try Pack.parse(gpa, synthetic);
        defer lang2.deinit();
        const s = "导入(\"x\")";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isImportOperand(lang2, s, toks, 2));
    }
    // 查表命中但映射值非 `@import`：全等门拒（`kusto = const`）。
    {
        const synthetic =
            \\$name = ii
            \\$code = ii
            \\[keywords]
            \\kusto = const
        ;
        var lang3 = try Pack.parse(gpa, synthetic);
        defer lang3.deinit();
        const s = "kusto(\"x\")";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!isImportOperand(lang3, s, toks, 2));
    }
}

test "prevIsDeclKeyword：D1 避让查链两形——非 ASCII keywords-only（与 isImportOperand 两级回退不对称）+ i==0 门 + ASCII 直通恰集流转（第 180 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // `常数 x 变量 y 函数 f`：三声明词后各 true；声明词自身居非 ASCII 词后（x）走 isDeclVerb("x")
    // 假；i==0 下溢门假。
    {
        const s = "常数 x 变量 y 函数 f";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(usize, 6), toks.len);
        try std.testing.expect(prevIsDeclKeyword(lang, s, toks, 1));
        try std.testing.expect(prevIsDeclKeyword(lang, s, toks, 3));
        try std.testing.expect(prevIsDeclKeyword(lang, s, toks, 5));
        try std.testing.expect(!prevIsDeclKeyword(lang, s, toks, 2));
        try std.testing.expect(!prevIsDeclKeyword(lang, s, toks, 0));
    }
    // ASCII 直通：`const x` true（原文进 isDeclVerb 同一恰集核）；`pub x` false（超集防卫流转）。
    {
        const s = "const x pub f";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(prevIsDeclKeyword(lang, s, toks, 1));
        try std.testing.expect(!prevIsDeclKeyword(lang, s, toks, 3));
    }
    // 前词 punct/其它词类 → 两 if 皆不中、末端 false。
    {
        const s = "= x";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!prevIsDeclKeyword(lang, s, toks, 1));
    }
    // keywords-only 不对称契约：词形只入 [aliases]（`甲 = const`）→ keywords 查空即返 false、
    // **不回退 aliases**（isImportOperand 反形）——若误加回退即吞掉声明位避让语义（别名链无条件先行）。
    {
        const synthetic =
            \\$name = eo
            \\$code = eo
            \\[aliases]
            \\甲 = const
        ;
        var lang2 = try Pack.parse(gpa, synthetic);
        defer lang2.deinit();
        const s = "甲 x";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!prevIsDeclKeyword(lang2, s, toks, 1));
    }
}

test "mappedIs：词元映射值目标词全等——非 ASCII keywords-only / ASCII 全等 / 非词类拒（D42·D47 共享核，第 180 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    {
        const s = "枚举 enumx";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        // 包内 `枚举 = enum`：命中目标词 true、异目标词/短前缀 false；ASCII 近邻超串全等拒。
        try std.testing.expect(mappedIs(lang, s, toks[0], "enum"));
        try std.testing.expect(!mappedIs(lang, s, toks[0], "union"));
        try std.testing.expect(!mappedIs(lang, s, toks[0], "enu"));
        try std.testing.expect(!mappedIs(lang, s, toks[1], "enum"));
    }
    {
        const s = "enum 枚举";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        // ASCII 直通原文全等 true（D42 形：直通 `enum` 首领亦入避让判定）。
        try std.testing.expect(mappedIs(lang, s, toks[0], "enum"));
    }
    // 词类门（合成方钉）：punct 词元指向 "enum" 字节 → false（仅词类可查、与文本碰巧相等无关）。
    {
        const s = "enum";
        const toks = [_]lexer.Token{.{ .kind = .punct, .off = 0, .len = 4 }};
        try std.testing.expect(!mappedIs(lang, s, toks[0], "enum"));
    }
    // keywords-only：词形只入 [aliases] → 不回退 aliases（与 isImportOperand 不对称契约同面二钉）。
    {
        const synthetic =
            \\$name = eo
            \\$code = eo
            \\[aliases]
            \\枚举 = enum
        ;
        var lang2 = try Pack.parse(gpa, synthetic);
        defer lang2.deinit();
        const s = "枚举";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!mappedIs(lang2, s, toks[0], "enum"));
    }
}

test "punctChar：?u8 返回形单 punct 判据——越界/词类/多字符/空文本四臂合成直钉 + 真词流基线（回扫配对共享核，第 180 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // 合成词元钉四防御臂（真 lexer 流永不产这些形、179 轮同族形）。
    {
        const s = ":->:"; // 0 ':' | 1..2 "->"（多字符 punct）| 3 ':'（ascii_word 含冒号）
        const toks = [_]lexer.Token{
            .{ .kind = .punct, .off = 0, .len = 1 },
            .{ .kind = .punct, .off = 1, .len = 2 },
            .{ .kind = .ascii_word, .off = 3, .len = 1 },
            .{ .kind = .punct, .off = 0, .len = 0 }, // 空文本 punct：s.len == 1 不满足
        };
        try std.testing.expectEqual(@as(?u8, ':'), punctChar(&toks, s, 0)); // 基线命中返字符本体
        try std.testing.expectEqual(@as(?u8, null), punctChar(&toks, s, 1)); // 多字符 len 门
        try std.testing.expectEqual(@as(?u8, null), punctChar(&toks, s, 2)); // 词类门
        try std.testing.expectEqual(@as(?u8, null), punctChar(&toks, s, 4)); // 越界 k>=len
        try std.testing.expectEqual(@as(?u8, null), punctChar(&toks, s, 3)); // 空文本
        const empty: []const lexer.Token = &.{};
        try std.testing.expectEqual(@as(?u8, null), punctChar(empty, s, 0)); // 空词流
    }
    // 真词流基线：单字符 punct 返字符、词元位 null；CJK 全角标点（多字节 punct 或其它词类）
    // 恒不落单字符语义——两面皆 null、如实登记非择一分支钉。
    {
        const s = "(x)";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(?u8, '('), punctChar(toks, s, 0));
        try std.testing.expectEqual(@as(?u8, ')'), punctChar(toks, s, 2));
        try std.testing.expectEqual(@as(?u8, null), punctChar(toks, s, 1));
    }
    {
        const s = "。";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(?u8, null), punctChar(toks, s, 0));
    }
}

// 护栏（第 184 轮增量审计·证伪撤号）：`isExtendedDeclNamePos`（L193·句法位避让分发核）系
// 109/179/180 历轮消费注反复点名、却从未被直调的判据合体——消费链已各自钉齐（回扫配对三谓词
// 109、isPunctAt/punctChar/mappedIs 等共享核与门 179/180），本测补第五面：四分支 A/B/C/D 真形、
// 首领 enum/union/error 三值白名单与 `)`/`;` 排除形、非末位实参形、i==0 与 i>=toks.len 双防御门。
// 零喂入坐实：D1b 首词皆 `常数`/`函数`（i==0 词元位全库零喂入）、`f(词)` 末位/非末位实参形与
// `;` 尾形从未入测、`i>=toks.len` 臂零调用者（生产两调用位 L262/L896 恒有界）；e2e 仅行为钉 C 分支
// 未声明词点后形（`x.文本` 整词查表替换）——其余真形皆间接触达。探针即测以本测首跑承担，
// 一次绿坐实真形皆符声明→证伪撤号不占 D 号。
test "isExtendedDeclNamePos：四分支分发核直调钉——真词流 A/B/C/D 形 + 首领三值白名单 + `)`/`;` 排除形 + 双防御门 + e2e 点后未声明词形（第 184 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const min_kw =
        "[keywords]\n" ++
        "常数 = const\n" ++
        "枚举 = enum\n" ++
        "联合 = union\n" ++
        "错误 = error\n" ++
        "结构 = struct\n" ++
        "文本 = []const u8\n";
    var lang = try Pack.parse(gpa, min_kw);
    defer lang.deinit();

    // 扫描小源并返回指定词元的下标（词元文本恰为 word 的第一个位置）。
    const T = struct {
        fn idx(toks: []const lexer.Token, src: []const u8, word: []const u8) usize {
            for (toks, 0..) |t, j| {
                if (std.mem.eql(u8, t.text(src), word)) return j;
            }
            unreachable; // 测内固定源，词元必在
        }
    };

    // ---- 真词流：分支 A（组开头 + `:`）----
    {
        const s = "枚举 { 甲: 乙 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "甲"))); // A
    }
    // ---- 分支 B：首领三值白名单（enum/union/error），裸/尾/值/载荷/逗号续形 ----
    {
        const s = "枚举 { 甲 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "甲")));
    }
    {
        const s = "枚举 { 甲, 乙 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "甲"))); // next=`,`
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "乙"))); // prev=`,`
    }
    {
        const s = "枚举(u8) { 甲 = 7 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "甲"))); // next=`=`、首领跳一层参数括号
    }
    {
        const s = "联合(枚举) { 甲(u8) }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "甲"))); // next=`(`、首领 联合→union
    }
    {
        const s = "错误 { 甲 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "甲"))); // D42 面：首领 error
    }
    // ---- 分支 B 首领白名单外与 next 排除形（皆假）----
    {
        const s = "结构 { 甲, 乙 }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "乙"))); // 首领 struct 非白名单
    }
    {
        const s = "枚举 { 甲; }";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "甲"))); // next=`;` ∉ 集合
    }
    {
        const s = "f(文本)";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "文本"))); // 观察点：next=`)` 排除形——末位实参恰为词表词仍须取词表义
    }
    {
        const s = "f(甲, 文本)";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "文本"))); // 非末位实参（prev=`,`、next=`)`）
    }
    // ---- 分支 C（prev=`.`）与 D（prev/next 同 `|`）----
    {
        const s = "x.文本";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "文本"))); // ASCII 词点后形（L896 调用位同核）
    }
    {
        const s = "for (v) |甲|";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(isExtendedDeclNamePos(lang, s, toks, T.idx(toks, s, "甲"))); // D
    }
    // ---- 双防御门直钉（真流零喂入形，179/180 同族手法）----
    {
        const s = "甲";
        const toks = try lexer.scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expect(!isExtendedDeclNamePos(lang, s, toks, 0)); // i==0 门：摘门即 toks[usize_max] 下溢 panic
        try std.testing.expect(!isExtendedDeclNamePos(lang, s, toks, 1)); // i>=toks.len 门：摘门即 toks[len] 越尾 panic
        const empty: []const lexer.Token = &.{};
        try std.testing.expect(!isExtendedDeclNamePos(lang, "", empty, 0)); // 空流 i==0 短路（len 门不可达、i==0 臂独防）
    }
    // 合成多字符 punct `->`：其 `-` 臂若被误并组开头，prev=`->` 词即假阳（真流不产 len>1 punct、180 同族形）。
    {
        const s = "甲 -> 乙"; // 0 甲 | 1 punct "->"(off 4,len 2) | 2 乙(off 7,len 3)
        const toks = [_]lexer.Token{
            .{ .kind = .nonascii_word, .off = 0, .len = 3 },
            .{ .kind = .punct, .off = 4, .len = 2 },
            .{ .kind = .nonascii_word, .off = 7, .len = 3 },
        };
        try std.testing.expect(!isExtendedDeclNamePos(lang, s, &toks, 2));
    }
    // ---- e2e 行为钉：C 分支未声明词点后形——避让整词查表替换（否则 文本→[]const u8 碎码）、
    // 走第 3 步转码名（与声明路径同名一致；D1b 仅以已声明 `戊.文本` 经 occupied 兜住、零占位形全库零喂入坐实）----
    {
        const src = "常数 甲 = 乙.文本;\n";
        var table = Mangle.init(gpa);
        defer table.deinit();
        const res = try translate(gpa, src, lang, &table);
        try std.testing.expectEqualStrings("const z_1 = z_2.z_3;\n", res.zig_str);
        try std.testing.expectEqualStrings("文本", table.unmangle("z_3").?); // 点后词整词登记为名、绝非类型残体
    }
}

// 护栏（第 185 轮增量审计·证伪撤号）：`matchAliasChain`（L307·翻译链第 1 步点分别名链贪心匹配核）
// 系本文件唯一从未被直调的翻译语义函数——109/179/180/184 历轮钉的都是其同分支避让/回扫谓词，
// 本体零直测直调（调用位仅 L244 nonascii_word 第 1 步）。零喂入坐实：空格分隔链形（doc 注 L305-306
// 声明「拼接键时忽略空白」）、回溯形（前缀命中+更长 miss 时 best 保留）、ASCII 成员断链（pack L72-73
// 声明「链止于 ASCII 成员、成员原样保留」）、字符串/非点 punct 断链、尾孤点、链尾恰在词元流末尾
// （j+1 < toks.len 边界）、初始 miss+扩展 hit（P.丁 形）——皆全库零喂入，既有 e2e 仅紧凑三段全链 hit。
// 探针即测以本测首跑承担，一次绿坐实真形皆符声明行为→证伪撤号不占 D 号。
test "matchAliasChain：链贪心匹配核直调钉——初始/扩展/回溯 best 保留 + 空格拼接 + ASCII·字符串·非点断链 + 流尾边界 + 首词防御门 + e2e 空格与回溯形（第 185 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const chain_pack =
        "[keywords]\n" ++
        "变量 = var\n" ++
        "[aliases]\n" ++
        "甲 = alpha\n" ++
        "甲.乙 = alpha.beta\n" ++
        "甲.乙.丙 = alpha.beta.gamma\n" ++
        "戊.丁 = pascal.q\n";
    var lang = try Pack.parse(gpa, chain_pack);
    defer lang.deinit();

    // 直调助手：scan 源后从词元 0（首词元必为非 ASCII 词）起匹配。
    const M = struct {
        fn match(g: std.mem.Allocator, l: Pack, s: []const u8) !?ChainMatch {
            const toks = try lexer.scan(g, s);
            defer g.free(toks);
            return matchAliasChain(g, l, s, toks, 0);
        }
        fn hit(g: std.mem.Allocator, l: Pack, s: []const u8, last: usize, repl: []const u8) !void {
            const m = (try match(g, l, s)).?;
            try std.testing.expectEqual(last, m.last);
            try std.testing.expectEqualStrings(repl, m.repl);
        }
        fn miss(g: std.mem.Allocator, l: Pack, s: []const u8) !void {
            try std.testing.expect((try match(g, l, s)) == null);
        }
    };

    // ---- 初始单段 hit（后继词元 `=` 非 `.`、链不扩展）----
    try M.hit(gpa, lang, "甲 = 1;", 0, "alpha");
    // ---- 初始 miss（表无此单段词、无扩展）----
    try M.miss(gpa, lang, "子 = 1;");
    // ---- 两段 hit（紧凑链·loop 内扩展更新 best）----
    try M.hit(gpa, lang, "甲.乙", 2, "alpha.beta"); // 链尾恰在流末尾：j+1<toks.len 边界形
    // ---- 三段全链 hit ----
    try M.hit(gpa, lang, "甲.乙.丙;", 4, "alpha.beta.gamma");
    // ---- 回溯形：更长 miss、前缀 best 保留（贪心最长命中的独防形·全库零喂入）----
    try M.hit(gpa, lang, "甲.乙.东", 2, "alpha.beta");
    try M.hit(gpa, lang, "甲.乙.丙.东", 4, "alpha.beta.gamma");
    // ---- 初始 miss + 扩展 hit（首段无键、两段有键）----
    try M.hit(gpa, lang, "戊.丁)", 2, "pascal.q");
    // ---- 空格分隔链形（doc 注声明「拼接键时忽略空白」·全库零喂入）----
    try M.hit(gpa, lang, "甲 . 乙", 2, "alpha.beta");
    // ---- 断链形：非 `.` punct / ASCII 成员 / 字符串词元 ----
    try M.hit(gpa, lang, "甲 + 乙", 0, "alpha");
    try M.hit(gpa, lang, "甲.乙.std)", 2, "alpha.beta"); // pack L72-73 声明形：链止于 ASCII 成员
    try M.hit(gpa, lang, "甲.\"令\"", 0, "alpha");
    // ---- 尾孤点（`j + 1 < toks.len` 假臂坠出、单段 best 保留）----
    try M.hit(gpa, lang, "甲.", 0, "alpha");
    // ---- 首词防御门：非 nonascii_word 直返 null（生产调用位不可达、防御形钉）----
    {
        const s = ".甲";
        const toks = [_]lexer.Token{
            .{ .kind = .punct, .off = 0, .len = 1 },
            .{ .kind = .nonascii_word, .off = 1, .len = 3 },
        };
        try std.testing.expect((try matchAliasChain(gpa, lang, s, &toks, 0)) == null);
    }
    {
        const s = "x.甲";
        const toks = [_]lexer.Token{
            .{ .kind = .ascii_word, .off = 0, .len = 1 },
            .{ .kind = .punct, .off = 1, .len = 1 },
            .{ .kind = .nonascii_word, .off = 2, .len = 3 },
        };
        try std.testing.expect((try matchAliasChain(gpa, lang, s, &toks, 0)) == null);
    }

    // ---- e2e 行为钉：回溯形（前缀链替换 + 尾段照旧走第 2/3 步）----
    {
        var table = Mangle.init(gpa);
        defer table.deinit();
        const res = try translate(gpa, "变量 n = 甲.乙.东;\n", lang, &table);
        try std.testing.expectEqualStrings("var n = alpha.beta.z_1;\n", res.zig_str);
        try std.testing.expectEqualStrings("东", table.unmangle("z_1").?);
    }
    // ---- e2e 行为钉：空格分隔链形（替换跨空白、链内空白被吞）----
    {
        var table = Mangle.init(gpa);
        defer table.deinit();
        const res = try translate(gpa, "变量 n = 甲 . 乙;\n", lang, &table);
        try std.testing.expectEqualStrings("var n = alpha.beta;\n", res.zig_str);
    }
}

// 第 191 轮审计注：preCheck（本文件 L34·`lexer.scan` + `fullwidth.check` 薄组合壳）
// 测面零直调——唯 main.zig L340 cmdCheck 快路与 lsp/server.zig L405 didSave 两生产直调；
// fullwidth.zig 各测手动「scan→check」两步钉尽下层本体，而组合壳自身（defer gpa.free(toks)
// 漏防臂、check 调用透传、错误集传播）全库零钉——删 defer 无任一测可抓（泄漏唯生产
// 调用路可见）。测面 gpa 皆 std.testing.allocator，泄漏由分配器自捕（删 defer 即红、
// load-bearing 成立）。探针即测：期望首跑自证。证伪撤号轮不占 D 号。

test "第 191 轮 T1 preCheck：组合壳透传契约钉（空源/合法形零违例/危险表字段逐项/手动形等价/双违例序）" {
    const gpa = std.testing.allocator;
    // P1 空源 → 0 项。
    {
        const v = try preCheck(gpa, "");
        defer gpa.free(v);
        try std.testing.expectEqual(@as(usize, 0), v.len);
    }
    // P2 纯 ASCII 合法源 → 0 项（BOM 面归 stripBom、preCheck 不处理）。
    {
        const v = try preCheck(gpa, "const a = 1;\nvar b = 2;\n");
        defer gpa.free(v);
        try std.testing.expectEqual(@as(usize, 0), v.len);
    }
    // P3 全角分号危险表命中 → 恰 1 项、六字段逐项钉（组合壳透传 fullwidth.check 字段的字节契约）。
    const src3 = "；\n";
    {
        const v = try preCheck(gpa, src3);
        defer gpa.free(v);
        try std.testing.expectEqual(@as(usize, 1), v.len);
        try std.testing.expectEqual(@as(usize, 0), v[0].off);
        try std.testing.expectEqual(@as(usize, 3), v[0].len); // UTF-8 三字节
        try std.testing.expectEqualStrings("；", v[0].word);
        try std.testing.expectEqualStrings("；", v[0].danger.?);
        try std.testing.expectEqualStrings(";", v[0].ascii);
        try std.testing.expectEqualStrings("全角分号", v[0].hint);
    }
    // P4 手动形等价：薄壳恒等于 scan→check 两步透传——违例逐项字段全等（钉组合语义，
    //   防参数预处理/调用次序静默改；fullwidth.zig 测试区的两步形与本壳输出同源同形）。
    {
        const toks = try lexer.scan(gpa, src3);
        defer gpa.free(toks);
        const manual = try fullwidth.check(gpa, src3, toks);
        defer gpa.free(manual);
        const auto = try preCheck(gpa, src3);
        defer gpa.free(auto);
        try std.testing.expectEqual(manual.len, auto.len);
        for (manual, auto) |m, a| {
            try std.testing.expectEqual(m.off, a.off);
            try std.testing.expectEqual(m.len, a.len);
            try std.testing.expectEqualStrings(m.word, a.word);
            if (m.danger) |md| {
                try std.testing.expectEqualStrings(md, a.danger.?);
            } else {
                try std.testing.expectEqual(@as(?[]const u8, null), a.danger);
            }
            try std.testing.expectEqualStrings(m.ascii, a.ascii);
            try std.testing.expectEqualStrings(m.hint, a.hint);
        }
    }
    // P5 双违例：条目数=命中词元数、序=词元扫描序（off 升序）——多违例聚合不吞不换序。
    {
        const v = try preCheck(gpa, "；\n＝\n");
        defer gpa.free(v);
        try std.testing.expectEqual(@as(usize, 2), v.len);
        try std.testing.expectEqual(@as(usize, 0), v[0].off);
        try std.testing.expectEqualStrings(";", v[0].ascii);
        try std.testing.expectEqual(@as(usize, 4), v[1].off); // "；\n" 占 4 字节
        try std.testing.expectEqualStrings("=", v[1].ascii);
        try std.testing.expectEqualStrings("全角等号", v[1].hint);
    }
}
