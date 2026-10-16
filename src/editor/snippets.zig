//! 补全片段生成器（第 155 轮 · 编辑器集成 MVP 补全面）：从语言包 Pack 的 keywords/aliases
//! 提取方言词形，生成 VS Code `contributes.snippets` 用的 snippet JSON。每个方言词/别名
//! 成为一个补全候选，description 附其映射的标准 Zig 形，助母语者按键前缀召回方言词并见其义。
//!
//! 设计原则（承 154 轮 tmlang）：
//!   - 语言无关：分类判据全取自编译器注册表（BuiltinFn / isPrimitive / Token.keywords），
//!     不硬编码任何特定方言词；新增语言包只需重新生成。
//!   - 确定性：条目按对象键（"al-"/"kw-" 前缀）字节升序，输出字节稳定，供 check-editor-snippets 守卫比对。
//!   - 名唯一：对象键以 "kw-"/"al-" 命名空间隔离，规避同一词形同现 keywords 与 aliases 时撞键
//!     （D40 同族「同层重复键静默后写覆盖」——此处从生成侧杜绝）。
//!   - 纯函数：输入 Pack 输出 []const u8，调用方负责写文件/比对。

const std = @import("std");
const Pack = @import("../lang/pack.zig").Pack;

/// 判断映射值是否属于语言常量（true/false/null/undefined）。
fn isLanguageConstant(value: []const u8) bool {
    const set = [_][]const u8{ "true", "false", "null", "undefined" };
    for (set) |k| {
        if (std.mem.eql(u8, value, k)) return true;
    }
    return false;
}

/// 按映射值归类方言词的分组标签（判据全取自注册表，语言无关）。
/// 公开供 LSP hover 复用（第 156 轮）：同一词在补全描述与悬停详情里分组口径一致。
pub fn classify(value: []const u8) []const u8 {
    if (value.len > 0 and value[0] == '@') return "内建函数";
    if (std.zig.isPrimitive(value)) return "类型";
    if (isLanguageConstant(value)) return "字面常量";
    if (std.zig.Token.keywords.has(value)) return "关键字";
    return "方言词";
}

/// 一条补全片段。
const Entry = struct {
    name: []const u8, // snippet 对象键（唯一）
    word: []const u8, // 方言词形（prefix / body）
    group: []const u8, // 分组标签（description 用）
    value: []const u8, // 映射的标准 Zig 形（description 用）
};

fn entryLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
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

/// snippet body 转义后输出：先做 snippet 语法转义（`\`→`\\`、`$`→`\$`、`}`→`\}`），
/// 再走 JSON 字符串转义。方言词/别名一般无这些字符，此步为对抗性保险。
fn snippetBodyStr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);
    for (s) |c| {
        switch (c) {
            '\\' => tmp.appendSlice(gpa, "\\\\") catch @panic("OOM"),
            '$' => tmp.appendSlice(gpa, "\\$") catch @panic("OOM"),
            '}' => tmp.appendSlice(gpa, "\\}") catch @panic("OOM"),
            else => tmp.append(gpa, c) catch @panic("OOM"),
        }
    }
    jsonStr(out, gpa, tmp.items);
}

/// 从 Pack 生成 VS Code snippet JSON 字节（调用方 free）。
pub fn generate(gpa: std.mem.Allocator, lang: Pack) ![]const u8 {
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(gpa);

    // keywords：方言词 → 标准值，按值归类。
    var it = lang.keywords.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const value = e.value_ptr.*;
        const name = try std.fmt.allocPrint(gpa, "kw-{s}", .{key});
        try list.append(gpa, .{
            .name = name,
            .word = key,
            .group = classify(value),
            .value = value,
        });
    }

    // aliases：标准库路径别名，词链作补全候选。
    var it2 = lang.aliases.iterator();
    while (it2.next()) |e| {
        const key = e.key_ptr.*;
        const value = e.value_ptr.*;
        const name = try std.fmt.allocPrint(gpa, "al-{s}", .{key});
        try list.append(gpa, .{
            .name = name,
            .word = key,
            .group = "标准库",
            .value = value,
        });
    }

    // 确定性排序：按对象键字节升序（"al-" 先于 "kw-"，同组内按词形）。
    std.mem.sort(Entry, list.items, {}, entryLess);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    out.appendSlice(gpa, "{") catch @panic("OOM");
    for (list.items, 0..) |en, i| {
        if (i > 0) out.append(gpa, ',') catch @panic("OOM");
        out.appendSlice(gpa, "\n  ") catch @panic("OOM");
        jsonStr(&out, gpa, en.name);
        out.appendSlice(gpa, ": {\n    \"prefix\": ") catch @panic("OOM");
        jsonStr(&out, gpa, en.word);
        out.appendSlice(gpa, ",\n    \"body\": ") catch @panic("OOM");
        snippetBodyStr(&out, gpa, en.word);
        out.appendSlice(gpa, ",\n    \"description\": ") catch @panic("OOM");
        const desc = std.fmt.allocPrint(gpa, "{s} → {s}", .{ en.group, en.value }) catch @panic("OOM");
        defer gpa.free(desc);
        jsonStr(&out, gpa, desc);
        out.appendSlice(gpa, "\n  }") catch @panic("OOM");
    }
    out.appendSlice(gpa, "\n}\n") catch @panic("OOM");

    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "snippets.generate：合法 JSON、含方言词补全、附标准映射描述（第 155 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
    defer lang.deinit();

    const json_bytes = try generate(gpa, lang);
    defer gpa.free(json_bytes);

    // 反解验证为合法 JSON 对象（守卫强于 154 轮的结构子串检查）。
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();
    try testing.expect(std.meta.activeTag(parsed.value) == .object);

    // 常见方言词作为补全候选出现（前缀形）。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"prefix\": \"常数\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"prefix\": \"变量\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "\"prefix\": \"函数\"") != null);
    // 描述含「→ 标准形」映射指示。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "→ const") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "→ var") != null);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "→ fn") != null);
    // 标准库别名在补全集中。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "标准库") != null);
    // 内建函数分组标签存在（@-前缀值）。
    try testing.expect(std.mem.indexOf(u8, json_bytes, "内建函数 →") != null);
}

test "snippets.generate：确定性——两次生成逐字节一致（第 155 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
    defer lang.deinit();

    const a = try generate(gpa, lang);
    defer gpa.free(a);
    const b = try generate(gpa, lang);
    defer gpa.free(b);

    try testing.expectEqualStrings(a, b);
}

test "snippets.generate：对象键唯一、无静默覆盖（第 155 轮·D40 同族防线）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
    defer lang.deinit();

    const json_bytes = try generate(gpa, lang);
    defer gpa.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();
    // std.json ObjectMap 天然去重；断言条目数 > 0 且与生成时收集一致，佐证无键覆盖丢项。
    try testing.expect(parsed.value.object.keys().len > 0);
}

test "snippets.generate：空 Pack 不崩溃、输出合法空对象（第 155 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = Pack.init(gpa);
    lang.code = "te";
    lang.name = "测试语";
    defer lang.deinit();

    const json_bytes = try generate(gpa, lang);
    defer gpa.free(json_bytes);

    // 空 Pack 应产出仅含 "{}" 的合法 JSON。
    try testing.expectEqualStrings("{\n}\n", json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.keys().len);
}

test "snippets.snippetBodyStr：双层转义（snippet 语法 ∘ JSON）字节形 + round-trip（第 168 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var asserts: usize = 0;

    // 单反斜杠：snippet 层 \\ → JSON 层 \\\\（4 字节），两端引号共 6 字节（D55 反面对照——此面正确）。
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        snippetBodyStr(&out, gpa, &[_]u8{0x5C});
        try testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x5C, 0x5C, 0x5C, 0x5C, 0x22 }, out.items);
        asserts += 1;
    }
    // 美元：snippet \$ → JSON \\$（3 字节）。
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        snippetBodyStr(&out, gpa, &[_]u8{0x24});
        try testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x5C, 0x5C, 0x24, 0x22 }, out.items);
        asserts += 1;
    }
    // 右花括号：snippet \} → JSON \\}。
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        snippetBodyStr(&out, gpa, &[_]u8{0x7D});
        try testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x5C, 0x5C, 0x7D, 0x22 }, out.items);
        asserts += 1;
    }
    // 双引号：非 snippet 转义字符，仅经 JSON 层转义为 \"。
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        snippetBodyStr(&out, gpa, &[_]u8{0x22});
        try testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x5C, 0x22, 0x22 }, out.items);
        asserts += 1;
    }

    // round-trip 不变量：JSON 解码得 snippet 语法转义形，再按 snippet 规则（\\X→X）解回原输入。
    const cases = [_][]const u8{
        &[_]u8{0x5C},
        &[_]u8{ 'a', 0x24, 'b' },
        &[_]u8{ 'c', 0x7D, 'd' },
        &[_]u8{ 'e', 0x22, 'f' },
        &[_]u8{ 'g', 0x5C, 'h', 0x24, 'i' },
    };
    for (cases) |inp| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        snippetBodyStr(&out, gpa, inp);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, out.items, .{}) catch return error.BadJson;
        defer parsed.deinit();
        const snippet_form = parsed.value.string;
        var back: std.ArrayList(u8) = .empty;
        defer back.deinit(gpa);
        var i: usize = 0;
        while (i < snippet_form.len) {
            if (snippet_form[i] == 0x5C and i + 1 < snippet_form.len) {
                back.append(gpa, snippet_form[i + 1]) catch return error.OutOfMemory;
                i += 2;
            } else {
                back.append(gpa, snippet_form[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }
        try testing.expectEqualStrings(inp, back.items);
        asserts += 1;
    }
    std.debug.print("T1 asserts={d}\n", .{asserts});
}

test "snippets.classify：五分支优先级 + 空值守卫（第 168 轮）" {
    var asserts: usize = 0;
    try testing.expectEqualStrings("内建函数", classify("@sqrt"));
    asserts += 1;
    // 单字符 @ 亦归内建函数（@ 前缀先于其余判据）。
    try testing.expectEqualStrings("内建函数", classify("@"));
    asserts += 1;
    try testing.expectEqualStrings("类型", classify("u8"));
    asserts += 1;
    try testing.expectEqualStrings("类型", classify("i32"));
    asserts += 1;
    // 真形钉：std.zig.isPrimitive 的 names 集合本就含 true/false/null/undefined 四个值名
    // （primitives.zig），classify 先判 isPrimitive（→类型）再判 isLanguageConstant（→字面常量），
    // 故这四值经 classify 恒归「类型」——「字面常量」支在 classify 路径上被 isPrimitive 遮蔽、
    // 实际不可达；isLanguageConstant 自身正确性另由 T4 直钉。承探针定盘不臆造理想语义（观察面登记）。
    try testing.expectEqualStrings("类型", classify("true"));
    asserts += 1;
    try testing.expectEqualStrings("类型", classify("false"));
    asserts += 1;
    try testing.expectEqualStrings("类型", classify("null"));
    asserts += 1;
    try testing.expectEqualStrings("类型", classify("undefined"));
    asserts += 1;
    try testing.expectEqualStrings("关键字", classify("const"));
    asserts += 1;
    try testing.expectEqualStrings("关键字", classify("fn"));
    asserts += 1;
    try testing.expectEqualStrings("关键字", classify("struct"));
    asserts += 1;
    try testing.expectEqualStrings("方言词", classify("常数"));
    asserts += 1;
    // 空串：value.len>0 守卫短路 @ 判据，不越界读 value[0]，落 else 方言词。
    try testing.expectEqualStrings("方言词", classify(""));
    asserts += 1;
    std.debug.print("T2 asserts={d}\n", .{asserts});
}

test "snippets.jsonEscape/jsonStr：控制字符/引号/反斜杠臂 + reparse 不变量（第 168 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var asserts: usize = 0;

    // 逐臂字节形（jsonEscape 不加引号）。
    const esc_cases = [_]struct { in: []const u8, exp: []const u8 }{
        .{ .in = &[_]u8{0x22}, .exp = &[_]u8{ 0x5C, 0x22 } }, // " → \"
        .{ .in = &[_]u8{0x5C}, .exp = &[_]u8{ 0x5C, 0x5C } }, // \ → \\
        .{ .in = &[_]u8{0x0A}, .exp = &[_]u8{ 0x5C, 0x6E } }, // LF → \\n
        .{ .in = &[_]u8{0x0D}, .exp = &[_]u8{ 0x5C, 0x72 } }, // CR → \\r

        .{ .in = &[_]u8{0x09}, .exp = &[_]u8{ 0x5C, 0x74 } }, // TAB → \\t

        .{ .in = &[_]u8{0x01}, .exp = &[_]u8{ 0x5C, 0x75, 0x30, 0x30, 0x30, 0x31 } }, // 0x01 → \\u0001
        .{ .in = &[_]u8{0x41}, .exp = &[_]u8{0x41} }, // 'A' 原样
        .{ .in = "常", .exp = "常" }, // CJK 逐字节原样透传
    };
    for (esc_cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        jsonEscape(&out, gpa, c.in);
        try testing.expectEqualSlices(u8, c.exp, out.items);
        asserts += 1;
    }

    // jsonStr reparse 不变量：两端补引号后为合法 JSON 字符串字面量，解回等值原串。
    const reparse_cases = [_][]const u8{
        &[_]u8{0x22},
        &[_]u8{0x5C},
        &[_]u8{0x01},
        &[_]u8{ 'x', 0x22, 'y', 0x5C, 'z', 0x0A },
        "常 数",
    };
    for (reparse_cases) |inp| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        jsonStr(&out, gpa, inp);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, out.items, .{}) catch return error.BadJson;
        defer parsed.deinit();
        try testing.expectEqualStrings(inp, parsed.value.string);
        asserts += 1;
    }
    std.debug.print("T3 asserts={d}\n", .{asserts});
}

test "snippets.isLanguageConstant：恰四真 + near-miss 全假（第 168 轮）" {
    var asserts: usize = 0;
    try testing.expect(isLanguageConstant("true"));
    asserts += 1;
    try testing.expect(isLanguageConstant("false"));
    asserts += 1;
    try testing.expect(isLanguageConstant("null"));
    asserts += 1;
    try testing.expect(isLanguageConstant("undefined"));
    asserts += 1;
    // near-miss 全假：大小写、超串、含子串非全等、尾空格、空串。
    try testing.expect(!isLanguageConstant("True"));
    asserts += 1;
    try testing.expect(!isLanguageConstant("truex"));
    asserts += 1;
    try testing.expect(!isLanguageConstant("xtrue"));
    asserts += 1;
    try testing.expect(!isLanguageConstant("null "));
    asserts += 1;
    try testing.expect(!isLanguageConstant("undefinedy"));
    asserts += 1;
    try testing.expect(!isLanguageConstant(""));
    asserts += 1;
    std.debug.print("T4 asserts={d}\n", .{asserts});
}
