//! LSP 文本坐标 / 词与声明查询族（第 341 轮 D200·自 `lsp/server.zig` 整簇下沉）。
//!
//! 为什么单独成模块：`server.zig` 曾同时装三件事——协议词汇 hub（`m_*`／`k_*`／`f_*`／`cap_*`）、
//! 12 张面表、以及这 60 枚**与协议无关**的纯查询判据（UTF-16 坐标换算、词/声明/点链定位、顶层声明
//! 扫描、函数签名解析、JSON 字段取值）。第三件事只吃 `std` 与转译侧模块，对本文件的引用只有 11 个
//! 词汇常量（`k_line`／`k_start`／`f_range_json` 之类，共 13 处），是天然的分离点：hub 与面表留在
//! `server.zig`（面表须与词汇同源），会话实现读起来不再被半屏的字节扫描函数淹没。
//!
//! 表面不断：`server.zig` 以 60 行 `const X = server_query.X;` 逐名转回，`Server` 结构与全部既有
//! 测块的调用形一字未动（下沉只改定义处，不改调用处，同 `cli/embed_scan.zig` 的处理）。
//!
//! 本模块**不得**声明任何 `*_face` 面表——面表一律留在所属 hub 文件，清单由 `zzc_paths.zig` 的
//! 323 T0 在册核（下沉模块登记为零枚，长出一张即红）。

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const Pack = @import("../lang/pack.zig").Pack;
const lexer = @import("../transpiler/lexer.zig");
const snippets = @import("../editor/snippets.zig");
const srv = @import("server.zig"); // 协议词汇取 hub 单源（本轮下沉只搬判据，不搬词汇）

// ---------------------------------------------------------------------------
// UTF-16 坐标换算（LSP 默认 positionEncoding）
// ---------------------------------------------------------------------------

/// 首字节 @ i 的 UTF-8 序列字节长（坏字节按 1）。
pub fn seqLen(s: []const u8, i: usize) usize {
    const l = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + l > s.len) return 1;
    _ = std.unicode.utf8Decode(s[i .. i + l]) catch return 1;
    return l;
}

/// 码点 @ i 的 UTF-16 宽度（1 或 2；坏字节按 1）。
pub fn cpWidth(s: []const u8, i: usize) usize {
    const l = seqLen(s, i);
    if (l == 1) return 1;
    const cp = std.unicode.utf8Decode(s[i .. i + l]) catch return 1;
    return if (cp >= 0x10000) 2 else 1;
}

/// 0 基行 + UTF-16 码元列（LSP Position）；line = 偏移之前的 '\n' 数。
pub fn positionOfOffset(text: []const u8, off: usize) struct { line: usize, character: usize } {
    const clamped = @min(off, text.len);
    var line: usize = 0;
    var line_start: usize = 0;
    for (text[0..clamped], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    var character: usize = 0;
    var i = line_start;
    while (i < clamped) {
        character += cpWidth(text, i);
        i += seqLen(text, i);
    }
    return .{ .line = line, .character = character };
}

/// LSP Position → 字节偏移；越界返 null（调用方按「无结果」处理，不 clamp 到别处）。
pub fn byteOfPosition(text: []const u8, line: usize, character: usize) ?usize {
    var l: usize = 0;
    var i: usize = 0;
    while (l < line) : (l += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return null;
        i = nl + 1;
    }
    var chars: usize = 0;
    while (i < text.len and text[i] != '\n') {
        if (chars >= character) return i;
        chars += cpWidth(text, i);
        i += seqLen(text, i);
    }
    return if (chars <= character) i else null;
}

/// 请求 Range → 字节区间；越界/逆序返 null（与 `byteOfPosition` 的「无结果」策略一致）。
pub const ByteSpan = struct { start: usize, end: usize };

pub fn rangeSpan(text: []const u8, r: std.json.ObjectMap) ?ByteSpan {
    const s = objIn(r.get(srv.k_start)) orelse return null;
    const e = objIn(r.get(srv.k_end)) orelse return null;
    const sl = intField(s, srv.k_line) orelse return null;
    const sc = intField(s, srv.k_character) orelse return null;
    const el = intField(e, srv.k_line) orelse return null;
    const ec = intField(e, srv.k_character) orelse return null;
    if (sl < 0 or sc < 0 or el < 0 or ec < 0) return null;
    const start = byteOfPosition(text, @intCast(sl), @intCast(sc)) orelse return null;
    const end = byteOfPosition(text, @intCast(el), @intCast(ec)) orelse return null;
    if (end < start) return null;
    return .{ .start = start, .end = end };
}

/// 字节区间 [start,end) → LSP Range JSON 文本（调用方 free）。
pub fn rangeJson(gpa: std.mem.Allocator, text: []const u8, start: usize, end: usize) ![]const u8 {
    const a = positionOfOffset(text, start);
    const b = positionOfOffset(text, end);
    return std.fmt.allocPrint(gpa, srv.f_range_json, .{ a.line, a.character, b.line, b.character });
}

/// URI + 字节区间 → LSP Location JSON（调用方 free）。
pub fn locationJson(gpa: std.mem.Allocator, text: []const u8, uri: []const u8, start: usize, end: usize) ![]const u8 {
    const range = try rangeJson(gpa, text, start, end);
    defer gpa.free(range);
    const uri_js = try jsonrpc.jsonString(gpa, uri);
    defer gpa.free(uri_js);
    return std.fmt.allocPrint(gpa, srv.f_location_json, .{ uri_js, range });
}

// ---------------------------------------------------------------------------
// 文档大纲（documentSymbol）：顶层声明扫描
// ---------------------------------------------------------------------------

/// 大纲项：kind 取 LSP SymbolKind（Function=12 / Variable=13 / Constant=14 / Enum=10 / Struct=23）。
pub const Decl = struct {
    kind: u32,
    name: []const u8,
    name_start: usize,
    name_end: usize,
};

/// 声明词 → LSP SymbolKind；词表取当前语言包 keywords（不硬编码方言词）。
pub fn declKind(lang: *const Pack, word: []const u8) ?u32 {
    const zig = lang.keywords.get(word) orelse return null;
    if (std.mem.eql(u8, zig, "fn")) return sk_function;
    if (std.mem.eql(u8, zig, "struct")) return sk_struct;
    if (std.mem.eql(u8, zig, "enum")) return sk_enum;
    if (std.mem.eql(u8, zig, "union")) return sk_struct;
    if (std.mem.eql(u8, zig, "const")) return sk_constant;
    if (std.mem.eql(u8, zig, "var")) return sk_variable;
    return null;
}

/// 声明前的修饰词（公开/导出/外部/内联/计期/紧实等）跳过，继续找声明词。
pub fn isDeclModifier(lang: *const Pack, word: []const u8) bool {
    const zig = lang.keywords.get(word) orelse return false;
    const mods = [_][]const u8{
        "pub",         "export",    "extern",   "inline",   "noinline",
        "threadlocal", "comptime",  "packed",   "callconv", "linksection",
        "align",       "allowzero", "volatile",
    };
    for (mods) |m| if (std.mem.eql(u8, zig, m)) return true;
    return false;
}

pub fn isSymbolDelim(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '(', ')', '{', '}', '[', ']', ':', ';', ',', '=', '!', '?', '*', '&', '|', '<', '>', '+', '-', '/', '%', '^', '~', '.' => true,
        else => false,
    };
}

/// 行内找「[修饰词]* 声明词 名称」；不是声明行/名称为关键字 → null。
pub fn findDecl(lang: *const Pack, line: []const u8) ?Decl {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) return null;
        const start = i;
        while (i < line.len and !isSymbolDelim(line[i])) i += 1;
        if (start == i) return null; // 行首标点：注释 `//`、闭合括号等
        const word = line[start..i];
        if (word[0] == '#') return null; // 行式注释/指令
        if (isDeclModifier(lang, word)) continue;
        const kind = declKind(lang, word) orelse return null;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const name_start = i;
        while (i < line.len and !isSymbolDelim(line[i])) i += 1;
        if (name_start == i) return null;
        const name = line[name_start..i];
        if (lang.keywords.get(name) != null) return null; // 关键字不能作声明名
        return .{ .kind = kind, .name = name, .name_start = name_start, .name_end = i };
    }
    return null;
}

/// 声明名范围是否落在真实词元上（排除注释/字符串等非代码文本里伪造的零缩进行）。
pub fn isCodeWord(toks: []const lexer.Token, start: usize, end: usize) bool {
    for (toks) |t| {
        if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
        if (t.off == start and t.off + t.len == end) return true;
    }
    return false;
}

/// 光标处代码词（词内或词尾回退）；注释/字符串/标点 → null。
pub fn wordTokenAt(toks: []const lexer.Token, text: []const u8, off: usize) ?[]const u8 {
    for (toks) |t| {
        if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
        if (t.off <= off and off < t.off + t.len) return text[t.off..][0..t.len];
    }
    // 光标停在词尾（无后续词元）时回退取前一词元——编辑器 F12 常把位置落在末字符之后。
    if (off > 0) {
        for (toks) |t| {
            if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
            if (t.off < off and t.off + t.len == off) return text[t.off..][0..t.len];
        }
    }
    return null;
}

/// 光标前最近一个未闭合的 `(` 词元下标（括号配对向后回扫）；无 → null。
/// 嵌套调用时取最内层：回扫遇 `)` 计深度、遇 `(` 先抵深度，深度 0 的 `(` 即目标。
pub fn callParenBefore(toks: []const lexer.Token, text: []const u8, off: usize) ?usize {
    var depth: usize = 0;
    var i = toks.len;
    while (i > 0) {
        i -= 1;
        const t = toks[i];
        if (t.off >= off) continue; // 光标处/之后的词元不算（光标在 `(` 上时不当作已进括号）
        if (t.kind != .punct or t.len != 1) continue;
        switch (text[t.off]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// 调用括号后到光标之间的顶层逗号数（即活动参数序）。嵌套括号/方括号/花括号里的
/// 逗号不计；字符串整体是一个词元，故字符串里的逗号天然不切参数。
pub fn activeParamAt(toks: []const lexer.Token, text: []const u8, open_off: usize, off: usize) usize {
    var depth: usize = 0;
    var n: usize = 0;
    for (toks) |t| {
        if (t.off <= open_off or t.off >= off) continue;
        if (t.kind != .punct or t.len != 1) continue;
        switch (text[t.off]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) n += 1;
            },
            else => {},
        }
    }
    return n;
}

pub const NameRange = struct { start: usize, end: usize };

/// 光标处代码词的绝对字节范围（词内或词尾回退）；注释/字符串/标点 → null。
/// 与 `wordTokenAt` 同判据，供需要位置而非切片的调用方使用（第 274 轮 prepareRename）。
pub fn wordRangeAt(toks: []const lexer.Token, off: usize) ?NameRange {
    for (toks) |t| {
        if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
        if (t.off <= off and off < t.off + t.len) return .{ .start = t.off, .end = t.off + t.len };
    }
    if (off > 0) {
        for (toks) |t| {
            if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
            if (t.off < off and t.off + t.len == off) return .{ .start = t.off, .end = t.off + t.len };
        }
    }
    return null;
}

/// 光标所在整行的绝对字节范围（不含 `\n`，行尾剥 `\r`）；越界 → null。
/// 与折叠/词元同源：扩选区链的第二层是「整行」，换行符不入选。
pub fn lineRangeAt(text: []const u8, off: usize) ?NameRange {
    if (off > text.len) return null;
    var start = off;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = off;
    while (end < text.len and text[end] != '\n') end += 1;
    if (end > start and text[end - 1] == '\r') end -= 1;
    return .{ .start = start, .end = end };
}

/// 扩选区链的一节（绝对字节区间）。
pub const SelRange = struct { start: usize, end: usize };

/// `outer` 是否严格包含 `inner`（相等不算——链节须逐级外扩，同区去重）。
pub fn selRangeContains(outer: SelRange, inner: SelRange) bool {
    return outer.start <= inner.start and outer.end >= inner.end and
        (outer.start < inner.start or outer.end > inner.end);
}

/// 只收严格包含当前末节的更大区间，保证 parent 链逐级外扩且无重复；首节（无末节）直收。
pub fn pushContaining(gpa: std.mem.Allocator, list: *std.ArrayList(SelRange), r: SelRange) !void {
    if (list.items.len > 0 and !selRangeContains(r, list.items[list.items.len - 1])) return;
    try list.append(gpa, r);
}

/// 按跨度升序（内层先）；同跨度时起点大者先（同区内层）。
pub fn selRangeLessThan(_: void, a: SelRange, b: SelRange) bool {
    const a_len = a.end - a.start;
    const b_len = b.end - b.start;
    if (a_len != b_len) return a_len < b_len;
    return a.start > b.start;
}

/// 按名称找首个顶层声明名称的绝对字节范围；无 → null。
pub fn findTopLevelDecl(lang: *const Pack, toks: []const lexer.Token, text: []const u8, name: []const u8) ?NameRange {
    var line_start: usize = 0;
    while (line_start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        var line_end = nl orelse text.len;
        if (line_end > line_start and text[line_end - 1] == '\r') line_end -= 1;
        const line = text[line_start..line_end];
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        if (indent == 0) {
            if (findDecl(lang, line)) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    const start = line_start + d.name_start;
                    const end = line_start + d.name_end;
                    if (isCodeWord(toks, start, end)) return .{ .start = start, .end = end };
                }
            }
        }
        line_start = if (nl) |n| n + 1 else text.len;
    }
    return null;
}

/// —— LSP 枚举基址（第 290 轮 D149）：LSP 的 `CompletionItemKind`／`SymbolKind` 以 **1** 起编
/// （Text/File = 1），而 vscode 同名枚举以 **0** 起编（vscode.d.ts：CompletionItemKind.Function=2、
/// SymbolKind.Function=11）——两侧数值差即此基址，客户端把 LSP 码直传 `new vscode.*(..., kind)`
/// 就整体错位一格（函数图标成构造器/变量、常量成字符串、关键字成片段）。同文件的 severity
/// （`sev()` 1↔Error）与 DocumentHighlightKind（3↔Write）早已各自做此换算，kind 族漏网。
pub const lsp_kind_base: u32 = 1;

/// —— 大纲/工作区符号的 LSP `SymbolKind` 码值（Function=12／Variable=13／Constant=14／
/// Enum=10／Struct=23，union 同归 Struct）：由 `declKind` 写侧、`completionKindForSymbol` 二次
/// 映射、客户端换算断言三处共此一份（第 290 轮 D149 收编，此前 declKind 与 switch 各拄一把 magic number）。
pub const sk_enum: u32 = 10;
pub const sk_function: u32 = 12;
pub const sk_variable: u32 = 13;
pub const sk_constant: u32 = 14;
pub const sk_struct: u32 = 23;

/// —— 上下文补全（第 279 轮）：LSP `CompletionItemKind` 码值（3 Function／6 Variable／
/// 7 Class／9 Module／13 Enum／14 Keyword／21 Constant／22 Struct）。码值为协议标准真值；
/// 客户端不得直传构造器，须减 `lsp_kind_base` 换到 vscode 0 基枚举空间（第 290 轮 D149）。
pub const ck_function: u32 = 3;
pub const ck_variable: u32 = 6;
pub const ck_class: u32 = 7;
pub const ck_module: u32 = 9;
pub const ck_enum: u32 = 13;
pub const ck_keyword: u32 = 14;
pub const ck_constant: u32 = 21;
pub const ck_struct: u32 = 22;

/// 光标处已输入链（可含 `.`）：start 为链首字节偏移，chain 为 text[start..off]。
pub const ChainPrefix = struct { start: usize, chain: []const u8 };

/// 从光标向前取“词/点链”前缀；光标落在标点/空白后时返 null（不弹空补全）。
pub fn chainPrefixAt(text: []const u8, off: usize) ?ChainPrefix {
    var s = off;
    while (s > 0) {
        const c = text[s - 1];
        const ok = c == '.' or c == '_' or (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= 0x80;
        if (!ok) break;
        s -= 1;
    }
    if (s == off) return null;
    return .{ .start = s, .chain = text[s..off] };
}

/// 一条补全候选（label/detail/doc 借用语言包或文档文本，不拥有内存）。
pub const CompletionHit = struct {
    label: []const u8,
    kind: u32,
    detail: []const u8,
    doc: ?[]const u8 = null,
    /// 点链候选：需要替换的链首字节偏移（null → 客户端按默认词范围插入）。
    edit_start: ?usize = null,
    /// 排序档：0 本文件声明 > 1 关键字/类型 > 2 标准库。
    rank: u8,
};

pub fn completionHitLess(_: void, a: CompletionHit, b: CompletionHit) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    return std.mem.lessThan(u8, a.label, b.label);
}

/// 词类分组（snippets.classify 六值）→ CompletionItemKind。
pub fn completionKindForGroup(group: []const u8) u32 {
    if (std.mem.eql(u8, group, snippets.g_builtin)) return ck_function;
    if (std.mem.eql(u8, group, snippets.g_type)) return ck_class;
    if (std.mem.eql(u8, group, snippets.g_constant)) return ck_constant;
    if (std.mem.eql(u8, group, snippets.g_keyword)) return ck_keyword;
    if (std.mem.eql(u8, group, snippets.g_alias)) return ck_module;
    return ck_variable;
}

/// LSP SymbolKind（Decl.kind）→ CompletionItemKind。
pub fn completionKindForSymbol(kind: u32) u32 {
    return switch (kind) {
        sk_function => ck_function,
        sk_struct => ck_struct,
        sk_enum => ck_enum,
        sk_constant => ck_constant,
        sk_variable => ck_variable,
        else => ck_variable,
    };
}

/// 顶层声明项（第 275 轮从 collectSymbolsJson 抽出）：带整行范围，供大纲与工作区符号共用。
pub const TopDecl = struct {
    kind: u32,
    name: []const u8,
    name_start: usize,
    name_end: usize,
    line_start: usize,
    line_end: usize,
};

/// 扫顶层（零缩进）声明；空文档/无声明 → 空切片。注释/字符串里的伪声明由词元校验排除。
pub fn scanTopLevelDecls(gpa: std.mem.Allocator, lang: *const Pack, text: []const u8) ![]TopDecl {
    const toks = try lexer.scan(gpa, text);
    defer gpa.free(toks);
    var items: std.ArrayList(TopDecl) = .empty;
    errdefer items.deinit(gpa);
    var line_start: usize = 0;
    while (line_start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        var line_end = nl orelse text.len;
        if (line_end > line_start and text[line_end - 1] == '\r') line_end -= 1;
        const line = text[line_start..line_end];
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        if (indent == 0) {
            if (findDecl(lang, line)) |d| {
                if (isCodeWord(toks, line_start + d.name_start, line_start + d.name_end)) {
                    try items.append(gpa, .{
                        .kind = d.kind,
                        .name = d.name,
                        .name_start = line_start + d.name_start,
                        .name_end = line_start + d.name_end,
                        .line_start = line_start,
                        .line_end = line_end,
                    });
                }
            }
        }
        line_start = if (nl) |n| n + 1 else text.len;
    }
    return items.toOwnedSlice(gpa);
}

/// 顶层函数签名（第 276 轮）：展示标签（声明词起至参数右括号）与逐参标签；均借用文档文本。
pub const FnSig = struct {
    label: []const u8,
    params: []const []const u8,
};

/// 切单行函数声明的参数表：名称后 `(` 到配对 `)`，按顶层逗号分割并去两端空白；
/// 无参数表/行内无配对右括号（跨行形不猜）→ null。标签从声明词起（保留「函数」等方言词）。
pub fn parseFnSignature(gpa: std.mem.Allocator, line: []const u8, d: Decl) !?FnSig {
    var i = d.name_end;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '(') return null;
    const open = i;
    var depth: usize = 0;
    var close: ?usize = null;
    while (i < line.len) : (i += 1) {
        if (line[i] == '(') {
            depth += 1;
        } else if (line[i] == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const cp = close orelse return null;
    // 声明词起点：从名称回退跳过空白再取前一词（`公开 函数 名(…)` 的标签以「函数」起）。
    var kw_start = d.name_start;
    while (kw_start > 0 and (line[kw_start - 1] == ' ' or line[kw_start - 1] == '\t')) kw_start -= 1;
    const kw_end = kw_start;
    while (kw_start > 0 and !isSymbolDelim(line[kw_start - 1])) kw_start -= 1;
    if (kw_start == kw_end) return null;
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(gpa);
    var seg_start = open + 1;
    var seg_depth: usize = 0;
    var j = open + 1;
    while (j <= cp) : (j += 1) {
        const at_end = j == cp;
        if (!at_end) {
            const c = line[j];
            if (c == '(' or c == '[' or c == '{') seg_depth += 1;
            if ((c == ')' or c == ']' or c == '}') and seg_depth > 0) seg_depth -= 1;
            if (!(c == ',' and seg_depth == 0)) continue;
        }
        var a = seg_start;
        var b = j;
        while (a < b and (line[a] == ' ' or line[a] == '\t')) a += 1;
        while (b > a and (line[b - 1] == ' ' or line[b - 1] == '\t')) b -= 1;
        if (b > a) try items.append(gpa, line[a..b]);
        seg_start = j + 1;
    }
    return .{ .label = line[kw_start .. cp + 1], .params = try items.toOwnedSlice(gpa) };
}

/// 按名称找同文件顶层函数声明并切参数表（kind 12 = LSP SymbolKind Function）；
/// 非函数声明/名称是注释或字符串伪造/跨行参数表 → null（词元校验同大纲）。
pub fn findFnSignature(gpa: std.mem.Allocator, lang: *const Pack, toks: []const lexer.Token, text: []const u8, name: []const u8) !?FnSig {
    var line_start: usize = 0;
    while (line_start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        var line_end = nl orelse text.len;
        if (line_end > line_start and text[line_end - 1] == '\r') line_end -= 1;
        const line = text[line_start..line_end];
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        if (indent == 0) {
            if (findDecl(lang, line)) |d| {
                if (d.kind == 12 and std.mem.eql(u8, d.name, name) and
                    isCodeWord(toks, line_start + d.name_start, line_start + d.name_end))
                {
                    if (try parseFnSignature(gpa, line, d)) |sig| return sig;
                }
            }
        }
        line_start = if (nl) |n| n + 1 else text.len;
    }
    return null;
}

/// 工作区符号命中项：文档 uri/全文 + 声明（名切片借用文档表文本）。
pub const WsHit = struct { uri: []const u8, text: []const u8, decl: TopDecl };

/// 工作区符号稳定序：先 uri 字典序，再声明位置（HashMap 迭代序不固定）。
pub fn wsHitLessThan(_: void, a: WsHit, b: WsHit) bool {
    switch (std.mem.order(u8, a.uri, b.uri)) {
        .lt => return true,
        .gt => return false,
        .eq => return a.decl.name_start < b.decl.name_start,
    }
}

/// 扫顶层（零缩进）声明，产出 LSP DocumentSymbol 数组；空文档/无声明 → `[]`。
pub fn collectSymbolsJson(gpa: std.mem.Allocator, lang: *const Pack, text: []const u8) ![]const u8 {
    const decls = try scanTopLevelDecls(gpa, lang, text);
    defer gpa.free(decls);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (decls, 0..) |d, i| {
        if (i > 0) try buf.append(gpa, ',');
        const name_js = try jsonrpc.jsonString(gpa, d.name);
        defer gpa.free(name_js);
        const range = try rangeJson(gpa, text, d.line_start, d.line_end);
        defer gpa.free(range);
        const sel = try rangeJson(gpa, text, d.name_start, d.name_end);
        defer gpa.free(sel);
        const item = try std.fmt.allocPrint(gpa, srv.f_document_symbol, .{ name_js, d.kind, range, sel });
        defer gpa.free(item);
        try buf.appendSlice(gpa, item);
    }
    try buf.append(gpa, ']');
    return buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// JSON-RPC 报文骨架（入向 0.17 std.json 动态值、出向手拼）
// ---------------------------------------------------------------------------

pub fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn objIn(v: ?std.json.Value) ?std.json.ObjectMap {
    const x = v orelse return null;
    return asObject(x);
}

/// 快速修复的 kind 过滤器（第 269 轮）：`context.only` 缺省 → 保持第 268 轮的
/// 「光标处 quickfix」默认行为；一旦出现，则按成员分道（空数组/未知 kind → 空结果，
/// 与 LSP「只在请求的 kind 内返回」一致）。`source.fixAll` 与 `quickfix` 可同时命中。
pub const ActionFilter = struct { quickfix: bool, fix_all: bool };

pub fn actionFilter(params_obj: ?std.json.ObjectMap) ActionFilter {
    const p = params_obj orelse return .{ .quickfix = true, .fix_all = false };
    const ctx = objIn(p.get(srv.k_context)) orelse return .{ .quickfix = true, .fix_all = false };
    const only_v = ctx.get(srv.k_only) orelse return .{ .quickfix = true, .fix_all = false };
    const arr = switch (only_v) {
        .array => |a| a,
        else => return .{ .quickfix = true, .fix_all = false },
    };
    var f: ActionFilter = .{ .quickfix = false, .fix_all = false };
    for (arr.items) |it| {
        const s = switch (it) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, s, srv.v_quickfix)) f.quickfix = true;
        if (std.mem.eql(u8, s, srv.v_source_fix_all)) f.fix_all = true;
    }
    return f;
}

pub fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const x = obj.get(key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

pub fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const x = obj.get(key) orelse return null;
    return switch (x) {
        .integer => |n| n,
        else => null,
    };
}

pub fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const x = obj.get(key) orelse return null;
    return switch (x) {
        .bool => |b| b,
        else => null,
    };
}

// ---------------------------------------------------------------- 下沉后的直调护栏（第 341 轮 D200）
// 本模块的坐标判据此前只被 `Server` 的会话测**间接**触及（端到端喂整帧 JSON，看不见单函数的边界形）。
// 拆出来当独立模块，就得有直指它的单位测——否则「会话测仍绿而换算已漂」无通道可拦（292/293 轮
// 「单文件绿≠入图绿」的对偶形：入图绿≠判据有钉）。以下两枚小样全部独立手设，不借被测函数互推。

const std_testing = std.testing;

test "D200 T0 坐标换算：CJK 1 单元／astral 2 单元／行界与越界钳制／往返自洽" {
    // 语料：第一行「甲」(3B)，换行在第 3 字节；第二行 a b c 各 1B，😀 4B（UTF-16 占 2 单元），乙 3B。
    const text = "甲\nabc\u{1F600}乙";
    // A1 起行与跨行：行号按 `\n` 计，列号从 0 起。
    try std_testing.expectEqual(@as(usize, 0), positionOfOffset(text, 0).line);
    try std_testing.expectEqual(@as(usize, 0), positionOfOffset(text, 0).character);
    try std_testing.expectEqual(@as(usize, 1), positionOfOffset(text, 4).line);
    try std_testing.expectEqual(@as(usize, 0), positionOfOffset(text, 4).character);
    // A2 astral 计两单元：emoji 首字节 (1,3) → 其后 (1,5)，尾「乙」后 (1,6)。
    try std_testing.expectEqual(@as(usize, 3), positionOfOffset(text, 7).character);
    try std_testing.expectEqual(@as(usize, 5), positionOfOffset(text, 11).character);
    try std_testing.expectEqual(@as(usize, 6), positionOfOffset(text, text.len).character);
    // A3 越界钳制：off 超尾不 panic，按 text.len 计（客户端可给陈旧坐标，此处不得越界读）。
    try std_testing.expectEqual(@as(usize, 1), positionOfOffset(text, 9_999).line);
    try std_testing.expectEqual(@as(usize, 6), positionOfOffset(text, 9_999).character);
    // A4 往返自洽：坐标→字节→坐标逐枚回原（第一行 0、第二行四个入口字节位）。
    for ([_]usize{ 0, 4, 7, 11 }) |off| {
        const p = positionOfOffset(text, off);
        const back = byteOfPosition(text, p.line, p.character) orelse return error.TestUnexpectedResult;
        try std_testing.expectEqual(off, back);
    }
    // A5 行号越界 → null（不是 0 也不是钳制——调用方据此判「坐标无效」）。
    try std_testing.expectEqual(@as(?usize, null), byteOfPosition(text, 5, 0));
}

test "D200 T0 序列宽度：坏字节按 1 不越界、astral 四字节解码成功" {
    // seqLen：ASCII 1；CJK 3；astral 4；截断序列（尾字节被切）按 1 而非 panic。
    try std_testing.expectEqual(@as(usize, 1), seqLen("a", 0));
    try std_testing.expectEqual(@as(usize, 3), seqLen("甲", 0));
    try std_testing.expectEqual(@as(usize, 4), seqLen("\u{1F600}", 0));
    // 截断形（四字节序列只喂前三字节）不能写成字面量：Zig 要求字符串字面量本身是合法 UTF-8，
    // `\xNN` 拼出的残缺序列在编译期就被拒——非法字节一律以 `[N]u8` 数组直给。
    const cut: [3]u8 = .{ 0xF0, 0x9F, 0x98 };
    try std_testing.expectEqual(@as(usize, 1), seqLen(&cut, 0));
    // cpWidth：单元数与字节数是两回事（LSP 的 character 以前者计）。
    try std_testing.expectEqual(@as(usize, 1), cpWidth("a", 0));
    try std_testing.expectEqual(@as(usize, 1), cpWidth("甲", 0));
    try std_testing.expectEqual(@as(usize, 2), cpWidth("\u{1F600}", 0));
    const bad: [1]u8 = .{0xFF}; // 裸 0xFF 非法 UTF-8 首字节 → 1
    try std_testing.expectEqual(@as(usize, 1), cpWidth(&bad, 0));
}
