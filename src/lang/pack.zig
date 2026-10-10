//! 语言包：极简行式 `键 = 值` 数据格式（刻意不用 TOML，避免引第三方依赖）。
//!
//! 文件格式：
//!   - `#` 或 `//` 开头为注释行；空行跳过
//!   - `[段名]` 切换当前段：keywords / aliases / diagnostics
//!   - `键 = 值`：键值均去除首尾空白；值保留内部空白
//!   - diagnostics 段的值以 `|` 分隔三段：`匹配前缀|译文模板|教学提示`
//!
//! 引擎语言无关：新增日语/韩语方言只需新增一份包文件。

const std = @import("std");

pub const Pack = @This();

pub const Entry = struct {
    pattern: []const u8,
    message: []const u8,
    tip: []const u8,
};

name: []const u8 = "未知语言",
code: []const u8 = "??",
keywords: std.StringHashMap([]const u8),
aliases: std.StringHashMap([]const u8),
diagnostics: std.ArrayList(Entry),

pub fn init(gpa: std.mem.Allocator) Pack {
    return .{
        .keywords = std.StringHashMap([]const u8).init(gpa),
        .aliases = std.StringHashMap([]const u8).init(gpa),
        .diagnostics = .empty,
    };
}

pub fn deinit(self: *Pack) void {
    const gpa = self.keywords.allocator;
    self.keywords.deinit();
    self.aliases.deinit();
    self.diagnostics.deinit(gpa);
}

const Section = enum { keywords, aliases, diagnostics };

/// 解析一份语言包字节流。返回所有权由调用方以 deinit 释放。
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Pack {
    var self = init(gpa);
    errdefer self.deinit();

    var section: Section = .keywords;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;

        if (std.mem.startsWith(u8, line, "[")) {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse
                return error.InvalidLangPack;
            const tag = line[1..close];
            section = std.meta.stringToEnum(Section, tag) orelse return error.InvalidLangPack;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLangPack;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return error.InvalidLangPack;

        switch (section) {
            .keywords, .aliases => {
                const map = if (section == .keywords) &self.keywords else &self.aliases;
                if (std.mem.eql(u8, key, "$name")) {
                    self.name = value;
                    continue;
                }
                if (std.mem.eql(u8, key, "$code")) {
                    self.code = value;
                    continue;
                }
                try map.put(key, value);
            },
            .diagnostics => {
                // 值格式：`匹配前缀|母语译文|教学提示`（键仅作人类可读标识，不参与匹配）
                const p1 = std.mem.indexOfScalar(u8, value, '|') orelse return error.InvalidLangPack;
                const rest = value[p1 + 1 ..];
                const p2 = std.mem.indexOfScalar(u8, rest, '|') orelse return error.InvalidLangPack;
                try self.diagnostics.append(gpa, .{
                    .pattern = std.mem.trim(u8, value[0..p1], " "),
                    .message = std.mem.trim(u8, rest[0..p2], " "),
                    .tip = std.mem.trim(u8, rest[p2 + 1 ..], " "),
                });
            },
        }
    }
    return self;
}

test "语言包解析" {
    const gpa = std.testing.allocator;
    const src =
        \\# 测试包
        \\$name = 测试语
        \\[keywords]
        \\常数 = const
        \\[aliases]
        \\标准库.打印 = std.debug.print
    ;
    var pack = try gpa.create(Pack);
    defer gpa.destroy(pack);
    pack.* = try parse(gpa, src);
    defer pack.deinit();

    try std.testing.expectEqualStrings("测试语", pack.name);
    try std.testing.expectEqualStrings("const", pack.keywords.get("常数").?);
    try std.testing.expectEqualStrings("std.debug.print", pack.aliases.get("标准库.打印").?);
}
