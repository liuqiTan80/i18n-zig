//! Zig 词法扫描器：把源码切成词元流，供翻译引擎逐词元处理。
//!
//! 关键约束（Phase 1 验收项）：
//!   - 字符串 `"..."`、字符字面量 `'c'`、多行字符串 `\\ ...`、注释 `// ...`
//!     的内容**绝不参与翻译**，整体作为一个词元原样复制；
//!   - `@` 与其后 ASCII 词（`@import`、`@Type` 等）分开成词元，
//!     `@"符号"` 整体保留；
//!   - 非 ASCII 字符序列（母语单词，含全角标点）各自成为一个词类词元，
//!     并吸收紧随其后的 ASCII 字母/数字/下划线（使 `变量1` 这类“CJK+ASCII 尾”成为单个标识符），由上层决定翻译/转码/报错；

const std = @import("std");

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
            while (i < src.len and (src[i] >= 0x80 or isAsciiWordChar(src[i]))) i += 1;
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
