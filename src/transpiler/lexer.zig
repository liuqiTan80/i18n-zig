//! Zig 词法扫描器：把源码切成词元流，供翻译引擎逐词元处理。
//!
//! 关键约束（Phase 1 验收项）：
//!   - 字符串 `"..."`、字符字面量 `'c'`、多行字符串 `\\ ...`、注释 `// ...`
//!     的内容**绝不参与翻译**，整体作为一个词元原样复制；
//!   - `@` 与其后 ASCII 词（`@import`、`@TypeOf` 等）分开成词元，
//!     `@"符号"` 整体保留；
//!   - 非 ASCII 字符序列（母语单词，含全角标点）各自成为一个词类词元，
//!     并吸收紧随其后的 ASCII 字母/数字/下划线（使 `变量1` 这类“CJK+ASCII 尾”成为单个标识符），由上层决定翻译/转码/报错；

const std = @import("std");
const zzc = @import("../zzc_paths.zig"); // 第 241 轮 D109：母语词字节集取单一真值（与 cli/args、lsp/server 同源）

pub const Kind = enum {
    /// [A-Za-z0-9_] 序列（含数字字面量、i7 等）
    ascii_word,
    /// 非 ASCII 字符序列（母语单词），含紧跟的 ASCII 字母/数字/下划线尾（如 `变量1`）
    nonascii_word,
    /// "..." 字符串字面量
    string,
    /// '...' 字符字面量（含转义）
    char,
    /// \\ 开头到行末的多行字符串
    multiline,
    /// // 开头的注释
    comment,
    /// @"..." 符号字面量（整体保留，不翻译）
    symbol,
    /// 单个标点字符
    punct,
};

pub const Token = struct {
    kind: Kind,
    /// 字节偏移与长度
    off: usize,
    len: usize,

    pub fn text(self: Token, src: []const u8) []const u8 {
        return src[self.off..][0..self.len];
    }
};

fn isAsciiWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// 扫描整段源码，返回词元流（跳过空白，空白由调用方按偏移原样复制）。
pub fn scan(gpa: std.mem.Allocator, src: []const u8) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        // 空白：不属于任何词元
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0B or c == 0x0C) {
            i += 1;
            continue;
        }

        const start = i;
        var kind: Kind = undefined;

        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            kind = .comment;
            i = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
            try out.append(gpa, .{ .kind = kind, .off = start, .len = i - start });
            continue;
        }
        if (c == '\\' and i + 1 < src.len and src[i + 1] == '\\') {
            kind = .multiline;
            i = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
            try out.append(gpa, .{ .kind = kind, .off = start, .len = i - start });
            continue;
        }
        if (c == '@' and i + 1 < src.len and src[i + 1] == '"') {
            // @"..." 符号：@ 与字符串整体成为一个词元，绝不参与翻译
            kind = .symbol;
            i += 2; // 跳过 @"
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\') {
                    i += 1; // 反斜杠吞掉下一个字节（转义对）
                    if (i >= src.len) break; // 转义对恰落在末字节 → 未闭合字面量止于 EOF，勿把游标推过尾（否则下游 t.text 切片越界 panic）
                    continue;
                }
                if (src[i] == '"' or src[i] == '\n') {
                    i += 1;
                    break;
                }
            }
            try out.append(gpa, .{ .kind = kind, .off = start, .len = i - start });
            continue;
        }
        if (c == '"') {
            kind = .string;
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\') {
                    i += 1; // 反斜杠吞掉下一个字节（转义对）
                    if (i >= src.len) break; // 转义对恰落在末字节 → 未闭合字面量止于 EOF，勿把游标推过尾（否则下游 t.text 切片越界 panic）
                    continue;
                }
                if (src[i] == '"' or src[i] == '\n') {
                    i += 1;
                    break;
                }
            }
            try out.append(gpa, .{ .kind = kind, .off = start, .len = i - start });
            continue;
        }
        if (c == '\'') {
            kind = .char;
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\') {
                    i += 1; // 反斜杠吞掉下一个字节（转义对）
                    if (i >= src.len) break; // 转义对恰落在末字节 → 未闭合字面量止于 EOF，勿把游标推过尾（否则下游 t.text 切片越界 panic）
                    continue;
                }
                if (src[i] == '\'' or src[i] == '\n') {
                    i += 1;
                    break;
                }
            }
            try out.append(gpa, .{ .kind = kind, .off = start, .len = i - start });
            continue;
        }
        if (isAsciiWordChar(c)) {
            kind = .ascii_word;
            while (i < src.len and isAsciiWordChar(src[i])) i += 1;
            try out.append(gpa, .{ .kind = kind, .off = start, .len = i - start });
            continue;
        }
        if (c >= 0x80) {
            // 母语标识符词元：非 ASCII 序列，并**吸收其后紧邻的 ASCII 字母/数字/下划线**。
            // 中文程序员极常见 `变量1`/`项A` 这类“CJK 名 + ASCII 尾”的**单个**标识符；若在此
            // 处切断（旧行为），翻译会把前缀单独 intern 成 z_N、再把 ASCII 尾原样拼接，产出
            // "z_N1"—— 既可能被误当整体编号与另一个 intern 结果 z_11 **撞名**（重复声明/静默
            // 改语义 + 误导诊断），也破坏了 `对象.字段1` 这类成员名的原子性。合并成一个词元后
            // `变量1` 被整体 intern，杜绝拼接撞名、且语义正确（它就是一整个名字）。
            kind = .nonascii_word;
            while (i < src.len and zzc.isWordByte(src[i])) i += 1;
            try out.append(gpa, .{ .kind = kind, .off = start, .len = i - start });
            continue;
        }
        // 其余单字节标点
        kind = .punct;
        i += 1;
        try out.append(gpa, .{ .kind = kind, .off = start, .len = 1 });
    }
    // 精确大小复制后释放 ArrayList：调用方对返回切片的 gpa.free
    // 必须与分配尺寸一致（capacity 可能大于 items.len，直接 free(items) 非法）。
    const result = try gpa.dupe(Token, out.items);
    out.deinit(gpa);
    return result;
}

test "token 边界：字符串/注释/多行串/字符/符号" {
    const gpa = std.testing.allocator;
    const src =
        \\常数 文本 = "字符串里的 常数 不翻译";
        \\// 注释里的 函数 不翻译
        \\常数 引 = @"";
        \\常数 多行 = 
        \\\\ 多行 常数 原样
        \\常数 字符 = '常';
    ;
    const toks = try scan(gpa, src);
    defer gpa.free(toks);

    var strings: usize = 0;
    var comments: usize = 0;
    var multilines: usize = 0;
    var chars: usize = 0;
    for (toks) |t| switch (t.kind) {
        .string => strings += 1,
        .comment => comments += 1,
        .multiline => multilines += 1,
        .char => chars += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), strings);
    try std.testing.expectEqual(@as(usize, 1), comments);
    try std.testing.expectEqual(@as(usize, 1), multilines);
    try std.testing.expectEqual(@as(usize, 1), chars);
}

test "非 ASCII 单词独立成 token" {
    const gpa = std.testing.allocator;
    const toks = try scan(gpa, "函数 主函数() void { 返回 0; }");
    defer gpa.free(toks);
    try std.testing.expectEqual(Kind.nonascii_word, toks[0].kind);
    try std.testing.expectEqualStrings("函数", toks[0].text("函数 主函数() void { 返回 0; }"));
}

test "CJK 名吸收紧邻的 ASCII 尾：变量1/甲10 各为一个非 ASCII 词元（防拼接撞名）" {
    const gpa = std.testing.allocator;
    const src = "常数 变量1: i64 = 甲10;";
    const toks = try scan(gpa, src);
    defer gpa.free(toks);
    // 非 ASCII 词元共 3 个：常数（关键字）、变量1、甲10（后两者含 ASCII 数字尾、已各合并为一词元）。
    var names: [4][]const u8 = .{ "", "", "", "" };
    var n: usize = 0;
    for (toks) |t| {
        if (t.kind == .nonascii_word) {
            if (n < names.len) names[n] = t.text(src);
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("常数", names[0]);
    try std.testing.expectEqualStrings("变量1", names[1]);
    try std.testing.expectEqualStrings("甲10", names[2]);
}

test "ASCII 开头的词元不被合并（12甲 仍拆为 ascii_word + 非 ASCII）" {
    const gpa = std.testing.allocator;
    const src = "12甲";
    const toks = try scan(gpa, src);
    defer gpa.free(toks);
    // '1' 为 ASCII 开头 → 走 ascii_word 分支消耗数字，再到 '甲' 才开非 ASCII 词元。
    try std.testing.expectEqual(Kind.ascii_word, toks[0].kind);
    try std.testing.expectEqualStrings("12", toks[0].text(src));
    try std.testing.expectEqual(Kind.nonascii_word, toks[1].kind);
    try std.testing.expectEqualStrings("甲", toks[1].text(src));
}

test "未闭合字面量以反斜杠结尾不得越出 src 尾（词元边界不变量）" {
    const gpa = std.testing.allocator;
    // 三种字面量各以「开引号 … 末字节反斜杠」结尾（模拟 Windows 路径串漏收尾引号 `p = "C:\Users\`）：
    // 转义分支曾把游标推至 src.len+1，使词元 off+len 越出缓冲 1 字节 → 下游 t.text(src) 的
    // src[off..][0..len] 切片越界 panic（ReleaseFast 更成越界读）。本测钉死「词元必落在 src 内」不变量。
    const malformed = [_][]const u8{
        "\"A\\", // 未闭合字符串
        "'A\\", // 未闭合字符
        "@\"A\\", // 未闭合符号
    };
    for (malformed) |src| {
        const toks = try scan(gpa, src);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(usize, 1), toks.len);
        for (toks) |t| {
            try std.testing.expect(t.off + t.len <= src.len); // 绝不越尾
            _ = t.text(src); // 不 panic 即证边界安全
        }
        try std.testing.expectEqual(src.len, toks[0].len); // 未闭合字面量吞至 EOF、整段成一词元
    }

    // 正常闭合的转义字面量不受影响：`"a\""`（内含被转义的闭引号）仍是单个串词元、含真实尾引号。
    const closed = "\"a\\\"\""; // 源码字节： " a \ " "（5 字节）
    const toks = try scan(gpa, closed);
    defer gpa.free(toks);
    try std.testing.expectEqual(@as(usize, 1), toks.len);
    try std.testing.expectEqualStrings(closed, toks[0].text(closed));
}

test "词元边界不变量：任意源在任意字节处截断，scan 皆不 panic、每词元 off+len <= 源长（D33 不变量向全词类与 EOF 截断点扩展）" {
    // 现有测仅钉特定完整词元、D33 测仅覆盖三种「末字节反斜杠」形；而任意源在任意偏移
    // 截断（EOF 可切在词元中段、源文件截断可达）对全体词类零覆盖。本测逐 probe 逐截断点
    // 扫一遍，钩住「词元必落在源内、不重叠、t.text 不 panic」不变量——日后任一分支删守卫即红。
    const gpa = std.testing.allocator;
    const probes = [_][]const u8{
        "// 注释到行尾没有换行",
        "\\\\ 多行串原样复制",
        "\"字符串里的 常数 不译\"",
        "'字'",
        "@\"符号 整体\"",
        "@",
        "变量1 = 甲10 ;",
        "std.debug.print",
        "嵌入文件(\"路径\") 到 EOF",
        "x = \"未闭合串",
        "@\"半闭合尾反斜杠\\",
    };
    for (probes) |probe| {
        var cut: usize = 0;
        while (cut <= probe.len) : (cut += 1) {
            const truncated = probe[0..cut];
            const toks = try scan(gpa, truncated);
            defer gpa.free(toks);
            var prev_end: usize = 0;
            for (toks) |t| {
                try std.testing.expect(t.off + t.len <= truncated.len); // 绝不越尾
                _ = t.text(truncated); // 切片不 panic 即边界安全
                try std.testing.expect(t.off >= prev_end); // 词元不重叠、按序
                prev_end = t.off + t.len;
            }
        }
    }
}

/// 护栏测专用：逐词元断言 kind 与原文（序列全等比对，防「数量对但种类错」的错位漏钉）。
fn expectTok(toks: []const Token, src: []const u8, i: usize, kind: Kind, txt: []const u8) !void {
    try std.testing.expect(i < toks.len); // 越界先拦截、不致 toks[i] panic
    try std.testing.expectEqual(kind, toks[i].kind);
    try std.testing.expectEqualStrings(txt, toks[i].text(src));
}

// 护栏（第 114 轮证伪落位）：两条模块头注声明行为此前从未在词法层被 kind 序列直接钉过——
// ① `@`+ASCII 词分开成词元：全库唯一消费点 translate.isImportOperand 回溯 `@import` 的前缀链
//   按 toks[i-3]==punct('@') 精确下标判定，若 `@` 误并入 ascii_word（如自造 `@ident` 词类）则整条
//   「.zz→.zig 字面量改写」静默失效（既有零测可挡）；② 换行终止未闭合 string/char/symbol：
//   D33 截断测只钉「不越界」边界不变量、从不断言 kind 序列，「删掉 `\n` 终止检查」在全部既有测
//   下仍全绿（串会吞至换行后下一闭引号、把整行代码并入串词元 → 不参与翻译 → 静默错译文）。
test "词类划分行为钉：@ 与后随 ASCII 词分开成词元；换行终止未闭合 string/char/symbol（第 114 轮）" {
    const gpa = std.testing.allocator;

    // ① `@import("std")`：@ 独立 punct、import 独立 ascii_word——isImportOperand 前缀链的坐标基。
    {
        const s = "@import(\"std\")";
        const toks = try scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(usize, 5), toks.len);
        try expectTok(toks, s, 0, .punct, "@");
        try expectTok(toks, s, 1, .ascii_word, "import");
        try expectTok(toks, s, 2, .punct, "(");
        try expectTok(toks, s, 3, .string, "\"std\"");
        try expectTok(toks, s, 4, .punct, ")");
    }
    // @"符号" 例外合并为 symbol；但裸 @ + CJK 词仍分开（吸收规则不向回吞前置 @）。
    {
        const s1 = "@\"符号\"";
        const t1 = try scan(gpa, s1);
        defer gpa.free(t1);
        try std.testing.expectEqual(@as(usize, 1), t1.len);
        try expectTok(t1, s1, 0, .symbol, "@\"符号\"");
        const s2 = "@甲";
        const t2 = try scan(gpa, s2);
        defer gpa.free(t2);
        try std.testing.expectEqual(@as(usize, 2), t2.len);
        try expectTok(t2, s2, 0, .punct, "@");
        try expectTok(t2, s2, 1, .nonascii_word, "甲");
    }

    // ② 未闭合串止于换行：串词元含行尾 \n、下一行另起词元（若删 `\n` 终止则第二行被并入串、此处翻红）。
    {
        const s = "x = \"abc\ndef;\n";
        const toks = try scan(gpa, s);
        defer gpa.free(toks);
        try expectTok(toks, s, 0, .ascii_word, "x");
        try expectTok(toks, s, 1, .punct, "=");
        try expectTok(toks, s, 2, .string, "\"abc\n");
        try expectTok(toks, s, 3, .ascii_word, "def");
        try expectTok(toks, s, 4, .punct, ";");
    }
    // 未闭合字符与未闭合 @"符号" 同规则止于换行。
    {
        const s = "'a\nb";
        const toks = try scan(gpa, s);
        defer gpa.free(toks);
        try expectTok(toks, s, 0, .char, "'a\n");
        try expectTok(toks, s, 1, .ascii_word, "b");
        const s2 = "@\"m\nn";
        const t2 = try scan(gpa, s2);
        defer gpa.free(t2);
        try expectTok(t2, s2, 0, .symbol, "@\"m\n");
        try expectTok(t2, s2, 1, .ascii_word, "n");
    }
}

// 护栏（第 128 轮）：空白集声明面（L56「空白：不属于任何词元」恰 6 成员）此前从未有测喂入
// 0x0B/0x0C——VT/FF 若从集中失守即落入 punct 分支，词元流凭空多出 punct 使上层
// isImportOperand 的 toks[i-1/i-2/i-3] 回溯下标链移位、`.zz→.zig` 改写静默失效（既有零测可挡）；
// 反向钉 NUL/0x7F 系集外成员须成 punct（不多吞）。test 内不可写 doc 注释，声明以 // 注释承载。
test "空白集精确成员行为钉：0x0B/0x0C 与常规空白同不吞词元，NUL/0x7F 则成 punct（第 128 轮）" {
    const gpa = std.testing.allocator;

    // VT/FF 夹在母语词与 ASCII 之间：不属于任何词元，两侧各自成词（与空格同形）。
    {
        const s = "甲\x0B\x0C乙";
        const toks = try scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(usize, 2), toks.len);
        try expectTok(toks, s, 0, .nonascii_word, "甲");
        try expectTok(toks, s, 1, .nonascii_word, "乙");
        const s2 = "a\x0Bb";
        const t2 = try scan(gpa, s2);
        defer gpa.free(t2);
        try std.testing.expectEqual(@as(usize, 2), t2.len);
        try expectTok(t2, s2, 0, .ascii_word, "a");
        try expectTok(t2, s2, 1, .ascii_word, "b"); // VT 断 ASCII 词（非词内字符）
    }
    // 全空白源零词元；集外单字节 NUL/0x7F 走 punct 分支各成一词元。
    {
        const ws = "\x0B\x0C \t\r\n";
        const toks = try scan(gpa, ws);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(usize, 0), toks.len);
        const s1 = "\x00";
        const t1 = try scan(gpa, s1);
        defer gpa.free(t1);
        try expectTok(t1, s1, 0, .punct, "\x00");
        const s2 = "\x7F";
        const t2 = try scan(gpa, s2);
        defer gpa.free(t2);
        try expectTok(t2, s2, 0, .punct, "\x7F");
    }
}

// 护栏（第 128 轮）：D33 测钉死 string/char/symbol 未闭合「吞至 EOF、len==src.len」，但
// comment/multiline 的 `orelse src.len` 同臂全库零值钉（截断测只钉边界不变量不钉 kind/len）；
// 且 CRLF 源形（Windows 外部工程真形）下「`\r` 在注释/多行串体内、`\n` 不入词元」零钉。
// 另钉 `i + 1 < src.len` 守卫界：裸 @、单反斜杠、\x 各落 punct。
test "comment/multiline 吞至 EOF 与 CRLF 包 \r 值钉；裸 @/单反斜杠守卫界 punct（第 128 轮）" {
    const gpa = std.testing.allocator;

    // 无换行尾：两类词元吞至 src 尾恰成一词元（与 D33 测 string/char/symbol 同形）。
    {
        const s = "// 到尾";
        const toks = try scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(usize, 1), toks.len);
        try std.testing.expectEqual(s.len, toks[0].len); // orelse src.len 臂值钉
        try expectTok(toks, s, 0, .comment, "// 到尾");
        const s2 = "\\\\ 到尾";
        const t2 = try scan(gpa, s2);
        defer gpa.free(t2);
        try std.testing.expectEqual(@as(usize, 1), t2.len);
        try std.testing.expectEqual(s2.len, t2[0].len);
        try expectTok(t2, s2, 0, .multiline, "\\\\ 到尾");
    }
    // CRLF 形：`\r` 属词元体、`\n` 终止且不入词元（剥 \r 即红——下行对照形钉死）。
    {
        const s = "// c\r\n";
        const toks = try scan(gpa, s);
        defer gpa.free(toks);
        try std.testing.expectEqual(@as(usize, 1), toks.len);
        try expectTok(toks, s, 0, .comment, "// c\r");
        const s2 = "\\\\ m\r\n甲";
        const t2 = try scan(gpa, s2);
        defer gpa.free(t2);
        try std.testing.expectEqual(@as(usize, 2), t2.len);
        try expectTok(t2, s2, 0, .multiline, "\\\\ m\r");
        try expectTok(t2, s2, 1, .nonascii_word, "甲");
    }
    // 守卫界：`@`/`\` 作末字节不再前瞻，各自落 punct；`\x` 不成 multiline 拆两词元。
    {
        const s1 = "@";
        const t1 = try scan(gpa, s1);
        defer gpa.free(t1);
        try expectTok(t1, s1, 0, .punct, "@");
        const s2 = "\\";
        const t2 = try scan(gpa, s2);
        defer gpa.free(t2);
        try expectTok(t2, s2, 0, .punct, "\\");
        const s3 = "\\x";
        const t3 = try scan(gpa, s3);
        defer gpa.free(t3);
        try std.testing.expectEqual(@as(usize, 2), t3.len);
        try expectTok(t3, s3, 0, .punct, "\\");
        try expectTok(t3, s3, 1, .ascii_word, "x");
    }
}

// 护栏（第 183 轮证伪撤号落位）：`isAsciiWordChar`（L43）零直调增量审计——词边界同族第五面
// （111 mangle.isIdentByte / 175 diag.translate.isIdentChar / 178 args.isWordCharByte /
// 179 translate.isAsciiAlphaByte）。L128/L130 词首词内与 L142 `src[i] >= 0x80 or` 组合后
// 恰为 178 所钉 `[0-9A-Za-z_] ∪ [0x80..0xFF]` 全等集（跨模块对称不变量，本文件不可直测、注此登记）。
// 关键盲点：既有 9 测皆经 scan 端到端形、**`_` 臂全库零喂入 scan**（demo `.zz` 无 `_`；
// translate 测 `[_]i64` 系 `[` 后置 `_` 不成词内形且 punct/word 重发文本同形；
// `zigHasMainFn` 纯行判不经词法器）——`_` 臂失守则 `变量_1`/`a_b` 被拆、CJK+ASCII 尾原子性
// 与防拼接撞名（L136-140 注）经 `_` 静默失能、无任何防线。另钉恰集边界逐格（ranges 界外一格）。
test "isAsciiWordChar 全 256 字节 iff 穷举 + 边界点名 + `_` 经 scan 词首/词内/CJK 尾吸收形钉（第 183 轮）" {
    const gpa = std.testing.allocator;

    // ① 独立 oracle（手写区间判据、与被审函数同款但独立书写）全 256 字节 iff 穷举钉恰集 [0-9A-Za-z_]。
    var c: u8 = 0;
    while (true) {
        const oracle = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or (c == '_');
        try std.testing.expectEqual(oracle, isAsciiWordChar(c));
        if (c == 0xFF) break;
        c += 1;
    }
    // ② 逐区间端点与界外一格点名（同 173/178/179 手法：每臂上下界各钉一格）。
    try std.testing.expect(isAsciiWordChar('0')); // 数字区间下界
    try std.testing.expect(isAsciiWordChar('9')); // 数字区间上界
    try std.testing.expect(isAsciiWordChar('A')); // 大写区间下界
    try std.testing.expect(isAsciiWordChar('Z')); // 大写区间上界
    try std.testing.expect(isAsciiWordChar('a')); // 小写区间下界
    try std.testing.expect(isAsciiWordChar('z')); // 小写区间上界
    try std.testing.expect(isAsciiWordChar('_')); // 独立字符臂
    try std.testing.expect(!isAsciiWordChar('/')); // 0x2F 数字下界外一格
    try std.testing.expect(!isAsciiWordChar(':')); // 0x3A 数字上界外一格
    try std.testing.expect(!isAsciiWordChar('@')); // 0x40 大写下界外一格
    try std.testing.expect(!isAsciiWordChar('[')); // 0x5B 大写上界外一格
    try std.testing.expect(!isAsciiWordChar('`')); // 0x60 小写下界外一格
    try std.testing.expect(!isAsciiWordChar('{')); // 0x7B 小写上界外一格
    try std.testing.expect(!isAsciiWordChar(0x7F)); // DEL 界外
    try std.testing.expect(!isAsciiWordChar(0x80)); // 高字节首格归 nonascii 分支、不入本集
    try std.testing.expect(!isAsciiWordChar(0xFF)); // 高字节末格同上
    // ③ `_` firing 面经 scan 钉（L128 词首 / L130 词内 / L142 CJK 后吸收尾）——全库此前零喂入形。
    {
        const s1 = "a_b"; // ASCII 词内 `_`：一个词元，断开即拆三
        const t1 = try scan(gpa, s1);
        defer gpa.free(t1);
        try std.testing.expectEqual(@as(usize, 1), t1.len);
        try expectTok(t1, s1, 0, .ascii_word, "a_b");
    }
    {
        const s2 = "_tmp x"; // `_` 词首（Zig 合法下划线开头标识符形）
        const t2 = try scan(gpa, s2);
        defer gpa.free(t2);
        try std.testing.expectEqual(@as(usize, 2), t2.len);
        try expectTok(t2, s2, 0, .ascii_word, "_tmp");
        try expectTok(t2, s2, 1, .ascii_word, "x");
    }
    {
        const s3 = "变量_1 甲_"; // CJK 名后 `_` 开吸收尾整体一词元（防拆名撞名）
        const t3 = try scan(gpa, s3);
        defer gpa.free(t3);
        try std.testing.expectEqual(@as(usize, 2), t3.len);
        try expectTok(t3, s3, 0, .nonascii_word, "变量_1");
        try expectTok(t3, s3, 1, .nonascii_word, "甲_");
    }
}
