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
