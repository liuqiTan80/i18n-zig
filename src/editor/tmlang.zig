//! tmLanguage 生成器（第 154 轮 · 编辑器集成 MVP）：从语言包 Pack 的 keywords/aliases
//! 提取方言词形，按映射值分类为 TextMate scope，输出可被 VS Code / TextMate 兼容编辑器
//! 加载的 tmLanguage JSON。
//!
//! 设计原则：
//!   - 语言无关：分类判据全取自编译器注册表（BuiltinFn / Token.keywords / isPrimitive），
//!     不硬编码任何特定方言词；新增语言包只需重新生成。
//!   - 贪心最长匹配：同组词按字节长度降序排入 alternation，保证 `无符号整数` 不被 `整数` 截。
//!   - 纯函数：输入 Pack 输出 []const u8，调用方负责写文件/比对。

const std = @import("std");
const Pack = @import("../lang/pack.zig").Pack;
const lang_id = @import("lang_identity.zig"); // 第 215 轮 D83：scopeName／fileTypes 取语言标识族真值

/// 词形条目：方言词 + 长度（排序用）。
const Word = struct { text: []const u8, len: usize };

fn wordLess(_: void, a: Word, b: Word) bool {
    // 字节长度降序；同长度按字典序升序（确定性）。
    if (a.len != b.len) return a.len > b.len;
    return std.mem.lessThan(u8, a.text, b.text);
}

/// 把词列表排成贪心最长匹配序并拼入 Oniguruma alternation。
/// CJK 词无词边界问题（不同于 ASCII），无需 \b；但对 ASCII 值（如 `main`）需要负向前查。
fn emitAlternation(out: *std.ArrayList(u8), gpa: std.mem.Allocator, words: []const Word) !void {
    if (words.len == 0) return;
    const sorted = try gpa.dupe(Word, words);
    defer gpa.free(sorted);
    std.mem.sort(Word, sorted, {}, wordLess);
    out.appendSlice(gpa, "(?:") catch @panic("OOM");
    for (sorted, 0..) |w, i| {
        if (i > 0) out.append(gpa, '|') catch @panic("OOM");
        escapeRegex(out, gpa, w.text);
    }
    out.appendSlice(gpa, ")") catch @panic("OOM");
}

/// 转义 Oniguruma 正则特殊字符并输出 JSON 安全形：正则元字符前缀一个反斜杠、
/// 该反斜杠在 JSON 里再翻倍为 `\\`（故输出 3 字节 `\.` 形）；但字面反斜杠 `\`
/// 本身在正则里须先转义成 `\\`、再按 JSON 每根翻倍 → 4 字节 `\\\\`（D55：旧通用臂
/// 对反斜杠只产 3 字节成奇数、破坏 JSON）。
fn escapeRegex(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '.', '*', '+', '?', '{', '}', '(', ')', '[', ']', '|', '^', '$' => {
                out.appendSlice(gpa, "\\\\") catch @panic("OOM"); // JSON: 一根正则转义反斜杠 = 两字节
                out.append(gpa, c) catch @panic("OOM");
            },
            '\\' => {
                // 字面反斜杠：正则 `\\` 的 JSON 编码 = 4 字节 `\\\\`。
                out.appendSlice(gpa, "\\\\\\\\") catch @panic("OOM");
            },
            '"' => {
                out.appendSlice(gpa, "\\\"") catch @panic("OOM");
            },
            else => {
                out.append(gpa, c) catch @panic("OOM");
            },
        }
    }
}

/// JSON 字符串转义（`"` → `\"`, `\` → `\\`, 控制字符）。
fn jsonEscape(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice(gpa, "\\\"") catch @panic("OOM"),
            '\\' => out.appendSlice(gpa, "\\\\") catch @panic("OOM"),
            '\n' => out.appendSlice(gpa, "\\n") catch @panic("OOM"),
            '\r' => out.appendSlice(gpa, "\\r") catch @panic("OOM"),
            '\t' => out.appendSlice(gpa, "\\t") catch @panic("OOM"),
            else => {
                if (c < 0x20) {
                    var buf: [8]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    out.appendSlice(gpa, esc) catch @panic("OOM");
                } else {
                    out.append(gpa, c) catch @panic("OOM");
                }
            },
        }
    }
}

/// 对 JSON 字符串值输出（含两端双引号）。
fn jsonStr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    out.append(gpa, '"') catch @panic("OOM");
    jsonEscape(out, gpa, s);
    out.append(gpa, '"') catch @panic("OOM");
}

/// 判断映射值是否属于语言常量（true/false/null/undefined）。
fn isLanguageConstant(value: []const u8) bool {
    const set = [_][]const u8{ "true", "false", "null", "undefined" };
    for (set) |k| {
        if (std.mem.eql(u8, value, k)) return true;
    }
    return false;
}

/// 从 Pack 生成 tmLanguage JSON 字节（调用方 free）。
pub fn generate(gpa: std.mem.Allocator, lang: Pack) ![]const u8 {
    // 按分类收集词形。
    var kw_builtin: std.ArrayList(Word) = .empty;
    defer kw_builtin.deinit(gpa);
    var kw_type: std.ArrayList(Word) = .empty;
    defer kw_type.deinit(gpa);
    var kw_control: std.ArrayList(Word) = .empty;
    defer kw_control.deinit(gpa);
    var kw_literal: std.ArrayList(Word) = .empty;
    defer kw_literal.deinit(gpa);
    var kw_other: std.ArrayList(Word) = .empty;
    defer kw_other.deinit(gpa);
    var alias_words: std.ArrayList(Word) = .empty;
    defer alias_words.deinit(gpa);

    // 遍历 keywords：按映射值分类。
    var it = lang.keywords.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const value = e.value_ptr.*;
        const w = Word{ .text = key, .len = key.len };
        if (value.len > 0 and value[0] == '@') {
            try kw_builtin.append(gpa, w);
        } else if (std.zig.isPrimitive(value)) {
            try kw_type.append(gpa, w);
        } else if (isLanguageConstant(value)) {
            try kw_literal.append(gpa, w);
        } else if (std.zig.Token.keywords.has(value)) {
            try kw_control.append(gpa, w);
        } else {
            try kw_other.append(gpa, w);
        }
    }

    // 遍历 aliases。
    var it2 = lang.aliases.iterator();
    while (it2.next()) |e| {
        const key = e.key_ptr.*;
        try alias_words.append(gpa, Word{ .text = key, .len = key.len });
    }

    // 生成 JSON。
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    out.appendSlice(gpa,
        \\{
        \\  "$schema": "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
    ) catch @panic("OOM");
    // scopeName 由语言标识族真值派生（第 215 轮 D83：与清单 `grammars[].scopeName` 同源——
    //   两边各写一份时任一枚漂移即编辑器寻不到 grammar、高亮静默全废，t2 探针 P1/P2 实锤）。
    out.appendSlice(gpa, "\n  \"scopeName\": \"" ++ lang_id.scope_name ++ "\",\n  \"name\": ") catch @panic("OOM");
    jsonStr(&out, gpa, lang.name);
    out.appendSlice(gpa,
        \\,
    ) catch @panic("OOM");
    // fileTypes 同源派生（清单 `extensions` 与 `zzc_paths.dialect_ext` 同族）。
    out.appendSlice(gpa, "\n  \"fileTypes\": [\"" ++ lang_id.file_type_stem ++ "\"],\n") catch @panic("OOM");
    out.appendSlice(gpa,
        \\  "patterns": [
        \\    { "include": "#comments" },
        \\    { "include": "#strings" },
        \\    { "include": "#builtins" },
        \\    { "include": "#types" },
        \\    { "include": "#literals" },
        \\    { "include": "#keywords" },
        \\    { "include": "#aliases" },
        \\    { "include": "#numbers" }
        \\  ],
        \\  "repository": {
        \\    "comments": {
        \\      "patterns": [
        \\        { "name": "comment.line.double-slash.zz", "match": "//.*$" },
        \\        { "name": "comment.block.zz", "begin": "/\\*", "end": "\\*/" }
        \\      ]
        \\    },
        \\    "strings": {
        \\      "patterns": [
        \\        { "name": "string.quoted.double.zz", "begin": "\"", "end": "\"", "patterns": [{ "name": "constant.character.escape.zz", "match": "\\\\." }] }
        \\      ]
        \\    },
        \\    "numbers": {
        \\      "patterns": [
        \\        { "name": "constant.numeric.zz", "match": "\\b0[xX][0-9a-fA-F]+\\b|\\b\\d+\\.?\\d*\\b" }
        \\      ]
        \\    },
    ) catch @panic("OOM");

    // 内建函数 scope。
    out.append(gpa, '\n') catch @panic("OOM");
    try emitPatternEntry(&out, gpa, "builtins", "support.function.builtin.zz", kw_builtin.items);
    out.appendSlice(gpa, ",\n") catch @panic("OOM");

    // 类型 scope。
    try emitPatternEntry(&out, gpa, "types", "support.type.primitive.zz", kw_type.items);
    out.appendSlice(gpa, ",\n") catch @panic("OOM");

    // 字面常量 scope。
    try emitPatternEntry(&out, gpa, "literals", "constant.language.zz", kw_literal.items);
    out.appendSlice(gpa, ",\n") catch @panic("OOM");

    // 关键字 scope（控制流 + 声明 + 其他合并为一组 keyword.other.zz）。
    var all_keywords: std.ArrayList(Word) = .empty;
    defer all_keywords.deinit(gpa);
    try all_keywords.appendSlice(gpa, kw_control.items);
    try all_keywords.appendSlice(gpa, kw_other.items);
    try emitPatternEntry(&out, gpa, "keywords", "keyword.other.zz", all_keywords.items);
    out.appendSlice(gpa, ",\n") catch @panic("OOM");

    // 别名 scope（标准库路径等）。
    try emitPatternEntry(&out, gpa, "aliases", "entity.name.namespace.zz", alias_words.items);

    out.appendSlice(gpa, "\n  }\n}\n") catch @panic("OOM");

    return out.toOwnedSlice(gpa);
}

fn emitPatternEntry(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, scope: []const u8, words: []const Word) !void {
    try out.appendSlice(gpa, "    \"");
    jsonEscape(out, gpa, name);
    try out.appendSlice(gpa, "\": {\n      \"patterns\": [\n        { \"name\": \"");
    jsonEscape(out, gpa, scope);
    try out.appendSlice(gpa, "\", \"match\": \"");
    if (words.len == 0) {
        // 空组不产生死匹配：用永不命中的占位正则。
        try out.appendSlice(gpa, "(?!)");
    } else {
        // 负向前查防 ASCII 词被截（CJK 词天然安全）。
        try out.appendSlice(gpa, "(?<![\\\\p{L}\\\\p{N}_])");
        try emitAlternation(out, gpa, words);
        try out.appendSlice(gpa, "(?![\\\\p{L}\\\\p{N}_])");
    }
    try out.appendSlice(gpa, "\" }\n      ]\n    }");
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tmlang.generate：合法 JSON、包含方言词、分类正确（第 154 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
    defer lang.deinit();

    const json_bytes = try generate(gpa, lang);
    defer gpa.free(json_bytes);

    // 基本结构检查（第 215 轮 D83：scopeName／fileTypes 由语言标识族真值派生，不再测内手抄自照）。
    try testing.expectEqualStrings("{", json_bytes[0..1]);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"scopeName\": \"" ++ lang_id.scope_name ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"fileTypes\": [\"" ++ lang_id.file_type_stem ++ "\"]") != null);
    // 方言词出现在正确 scope 中。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "常数") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "变量") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "导入") != null);
    // 内建函数 scope。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "support.function.builtin.zz") != null);
    // 类型 scope。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "support.type.primitive.zz") != null);
    // 别名 scope。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "entity.name.namespace.zz") != null);
    // 字面常量。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "constant.language.zz") != null);
    // 标准库别名在 aliases 组中。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "标准库") != null);
    // 贪心最长匹配：`无符号整数` 应排在 `整数` 之前（字节长度更长）。
    const usi_pos = std.mem.indexOf(u8, json_bytes, "无符号整数") orelse return error.TestUnexpectedResult;
    const zi_pos = std.mem.indexOf(u8, json_bytes, "整数") orelse return error.TestUnexpectedResult;
    // 无符号整数 是 整数 的超串，如果排序正确应先出现。
    try testing.expect(usi_pos < zi_pos or usi_pos == zi_pos); // 同组内超串先出
}

test "tmlang.generate：空 Pack 不崩溃、输出有效 JSON 骨架（第 154 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = Pack.init(gpa);
    lang.code = "te";
    lang.name = "测试语";
    defer lang.deinit();

    const json_bytes = try generate(gpa, lang);
    defer gpa.free(json_bytes);

    // 至少包含 scopeName 和空模式组。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"scopeName\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "(?!)") != null); // 空组占位
}

test "tmlang.wordLess：长度降序 + 同长字节字典序升序 tie-break（第 167 轮）" {
    var arr = [_]Word{
        .{ .text = "bb", .len = 2 },
        .{ .text = "ab", .len = 2 },
        .{ .text = "ccc", .len = 3 },
        .{ .text = "a", .len = 1 },
    };
    std.mem.sort(Word, &arr, {}, wordLess);
    // 长者优先。
    try testing.expectEqualStrings("ccc", arr[0].text);
    // 同长按字节字典序升序（确定性）。
    try testing.expectEqualStrings("ab", arr[1].text);
    try testing.expectEqualStrings("bb", arr[2].text);
    try testing.expectEqualStrings("a", arr[3].text);
    // 严格弱序：同元素不自反（保 alternation 排序稳定前提）。
    try testing.expect(!wordLess({}, .{ .text = "x", .len = 1 }, .{ .text = "x", .len = 1 }));
}

test "tmlang.escapeRegex：正则元字符 JSON 转义 + 反斜杠 4 字节 + 引号 + 透传（第 167 轮·D55）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    inline for ([_]struct { in: []const u8, exp: []const u8 }{
        .{ .in = "\\", .exp = "\\\\\\\\" }, // 单反斜杠 → 4 字节（D55：旧形仅 3 字节）
        .{ .in = "a.b", .exp = "a\\\\.b" }, // 点号 → \\. （3 字节正则转义）
        .{ .in = "c*d", .exp = "c\\\\*d" }, // 星号同理
        .{ .in = "a\"b", .exp = "a\\\"b" }, // 引号 → \"
        .{ .in = "\u{5e38}\u{6570}", .exp = "\u{5e38}\u{6570}" }, // CJK 透传
        .{ .in = "abc", .exp = "abc" }, // ASCII 透传
    }) |c| {
        var out: std.ArrayList(u8) = .empty;
        escapeRegex(&out, gpa, c.in);
        try testing.expectEqualStrings(c.exp, out.items);
    }
}

test "tmlang.jsonEscape：控制字符/引号/反斜杠转义臂 + reparse 不变量（第 167 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    inline for ([_]struct { in: []const u8, exp: []const u8 }{
        .{ .in = "\n", .exp = "\\n" },
        .{ .in = "\t", .exp = "\\t" },
        .{ .in = "\r", .exp = "\\r" },
        .{ .in = "\x01", .exp = "\\u0001" }, // c < 0x20 → \u00XX
        .{ .in = "\"", .exp = "\\\"" },
        .{ .in = "\\", .exp = "\\\\" }, // 单反斜杠 → 2 字节（jsonEscape 本就正确，区 escapeRegex）
        .{ .in = "abc", .exp = "abc" },
        .{ .in = "\u{5e38}\u{6570}", .exp = "\u{5e38}\u{6570}" },
    }) |c| {
        var out: std.ArrayList(u8) = .empty;
        jsonEscape(&out, gpa, c.in);
        try testing.expectEqualStrings(c.exp, out.items);
    }

    // reparse 不变量：转义串包进 JSON 字符串值后能解回原串。
    const src = "a\"b\\c\nd";
    var esc: std.ArrayList(u8) = .empty;
    jsonEscape(&esc, gpa, src);
    const wrapped = try std.fmt.allocPrint(gpa, "\"{s}\"", .{esc.items});
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, wrapped, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(src, parsed.value.string);
}

test "tmlang.isLanguageConstant：恰四常量 + near-miss 判 false（第 167 轮）" {
    try testing.expect(isLanguageConstant("true"));
    try testing.expect(isLanguageConstant("false"));
    try testing.expect(isLanguageConstant("null"));
    try testing.expect(isLanguageConstant("undefined"));
    // near-miss 全 false：大小写 / 超串 / 前缀 / 尾空格 / 空串。
    try testing.expect(!isLanguageConstant("True"));
    try testing.expect(!isLanguageConstant("truex"));
    try testing.expect(!isLanguageConstant("nulll"));
    try testing.expect(!isLanguageConstant("undefined "));
    try testing.expect(!isLanguageConstant("un"));
    try testing.expect(!isLanguageConstant(""));
}

// 护栏（第 186 轮增量审计·证伪撤号）：`emitAlternation`（L25·贪心最长匹配 alternation
// 发射器）系 167 轮钉尽同文件 wordLess/escapeRegex/jsonEscape/isLanguageConstant 后、本体
// 仍唯余 154 轮 generate e2e 子串断言间接触达的接线核——排序调用接线、`|` 分隔与 `(?:`…`)`
// 包装对称、逐词 escapeRegex 转义接线皆零直测直调；且空组早退臂系生产不可达形（唯一调用位
// emitPatternEntry L221 已先分 words.len == 0 走 `(?!)` 占位、永不传入空表）。零喂入坐实：
// check-editor-syntax 系独立 CI step 不入 zig build test，形态变异（捕获组化/剔闭括号/去转义）
// 于既有测试面皆漏抓——154 测仅 indexOf 子串存在断言，`标准库` 无论转义与否皆命中。
// 探针即测以本测首跑承担，一次绿坐实真形皆符声明→证伪撤号不占 D 号。
test "tmlang.emitAlternation：直调钉——空组早退 + 排序接线 + 分隔/包装对称 + 元字符转义接线 + e2e pattern-entry 耦合（第 186 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // 直调助手：构造词表并返回 alternation 输出字节。
    const T = struct {
        fn w(s: []const u8) Word {
            return .{ .text = s, .len = s.len };
        }
        fn emit(alloc: std.mem.Allocator, words: []const Word) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            try emitAlternation(&out, alloc, words);
            return out.toOwnedSlice(alloc);
        }
    };

    // ---- 空表早退：输出零字节（生产不可达臂·直调面独防）----
    try testing.expectEqualStrings("", try T.emit(gpa, &.{}));

    // ---- 单词：仅包装、无分隔符 ----
    try testing.expectEqualStrings("(?:甲)", try T.emit(gpa, &.{T.w("甲")}));

    // ---- 乱序输入 -> 贪心最长匹配序（钉 std.mem.sort + wordLess 接线）----
    try testing.expectEqualStrings(
        "(?:无符号整数|整数|乙)",
        try T.emit(gpa, &.{ T.w("整数"), T.w("无符号整数"), T.w("乙") }),
    );

    // ---- 同长按字典序升序 tie-break（乱序喂入）----
    try testing.expectEqualStrings("(?:ab|bb)", try T.emit(gpa, &.{ T.w("bb"), T.w("ab") }));

    // ---- 元字符逐词转义接线：`.` -> JSON 3 字节 `\\.` 形（escapeRegex 核 167 已钉、
    //      但 emitAlternation 是否「调用它」零测——去接线后 154 子串断言照绿，真隐缝）----
    try testing.expectEqualStrings("(?:标准库\\\\.调试)", try T.emit(gpa, &.{T.w("标准库.调试")}));

    // ---- ASCII 词原样入组：边界符属调用方 emitPatternEntry、本核不添加 ----
    try testing.expectEqualStrings("(?:main)", try T.emit(gpa, &.{T.w("main")}));

    // ---- 同长混合转义序：`+`(0x2B) < `.`(0x2E) 字典序 + 两词皆转义（`+`/`.` 俱元字符、
    //      各经 JSON 3 字节 `\\X` 形——首跑自捕登册：初版期望误给 `+` 单反斜杠形）----
    try testing.expectEqualStrings(
        "(?:a\\\\+b|a\\\\.b)",
        try T.emit(gpa, &.{ T.w("a.b"), T.w("a+b") }),
    );

    // ---- 重复词不脱重（现行为钉：脱重非本核职责）----
    try testing.expectEqualStrings("(?:甲|甲)", try T.emit(gpa, &.{ T.w("甲"), T.w("甲") }));

    // ---- e2e：经 generate -> emitPatternEntry 耦合位钉完整 match 值
    //      （负向前查 + 包装转义体 + 后查三段一体形——子串级即整串钉死）----
    var lang = try Pack.parse(gpa,
        \\ [keywords]
        \\ 甲 = var
        \\ [aliases]
        \\ 标准库.调试 = std.debug
        \\
    );
    defer lang.deinit();
    const json_bytes = try generate(gpa, lang);
    defer gpa.free(json_bytes);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"(?<![\\\\p{L}\\\\p{N}_])(?:标准库\\\\.调试)(?![\\\\p{L}\\\\p{N}_])\"") != null);
    // keywords 组（控制流类）同形钉：`甲` 无元字符透传。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"(?<![\\\\p{L}\\\\p{N}_])(?:甲)(?![\\\\p{L}\\\\p{N}_])\"") != null);
}
