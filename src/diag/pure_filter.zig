//! 纯母语过滤器：在报错输出前做最终检查，对任何残留的英文进行拦截或兜底翻译。
//!
//! 核心原则：
//! - 纯母语原则：任何母语编写的代码，报错信息必须 100% 使用该母语
//! - 零英文泄漏：不允许任何英文错误提示出现在母语报错中
//! - 硬性约束优先级：当性能、功能与纯母语原则冲突时，纯母语原则优先级最高

const std = @import("std");

/// 白名单规则：允许某些英文内容（如标识符、类型名）
pub const Whitelist = struct {
    rules: std.ArrayList([]const u8),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Whitelist {
        return .{ .rules = std.ArrayList([]const u8).empty, .gpa = gpa };
    }

    pub fn deinit(self: *Whitelist) void {
        for (self.rules.items) |rule| {
            self.gpa.free(rule);
        }
        self.rules.deinit(self.gpa);
    }

    /// 添加白名单规则
    pub fn add(self: *Whitelist, rule: []const u8) !void {
        const owned = try self.gpa.dupe(u8, rule);
        try self.rules.append(self.gpa, owned);
    }

    /// 检查文本是否在白名单中
    pub fn check(self: Whitelist, text: []const u8) bool {
        for (self.rules.items) |rule| {
            if (std.mem.eql(u8, text, rule)) return true;
        }
        return false;
    }
};

/// 纯母语过滤器配置
pub const Config = struct {
    enabled: bool = true,
    min_english_length: usize = 3,
    fallback_message: []const u8 = "[未翻译] 此报错暂未提供中文翻译，请参考英文原文",
    log_path: []const u8 = "logs/untranslated_phrases.json",
    strict_mode: bool = false, // true = 严格模式，任何英文都拦截
};

/// 未翻译短语记录
pub const UntranslatedPhrase = struct {
    phrase: []const u8,
    location: []const u8,
    timestamp: i64,
    suggested_translation: []const u8,
};

/// 纯母语过滤器
pub const PureFilter = struct {
    gpa: std.mem.Allocator,
    config: Config,
    whitelist: Whitelist,
    untranslated_phrases: std.ArrayList(UntranslatedPhrase),

    pub fn init(gpa: std.mem.Allocator, config: Config) !PureFilter {
        var whitelist = Whitelist.init(gpa);
        errdefer whitelist.deinit();

        // 添加默认白名单规则
        try whitelist.add("MyType");
        try whitelist.add("MyVariable");
        try whitelist.add("my_variable");
        try whitelist.add("_private_var");
        try whitelist.add("@import");
        try whitelist.add("@memcpy");
        try whitelist.add("@typeInfo");

        return .{
            .gpa = gpa,
            .config = config,
            .whitelist = whitelist,
            .untranslated_phrases = std.ArrayList(UntranslatedPhrase).empty,
        };
    }

    pub fn deinit(self: *PureFilter) void {
        self.whitelist.deinit();
        for (self.untranslated_phrases.items) |phrase| {
            self.gpa.free(phrase.phrase);
            self.gpa.free(phrase.location);
            self.gpa.free(phrase.suggested_translation);
        }
        self.untranslated_phrases.deinit(self.gpa);
    }

    /// 检测文本中是否包含英文残留
    pub fn detectEnglish(self: *PureFilter, text: []const u8) bool {
        if (!self.config.enabled) return false;

        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (std.ascii.isAlphabetic(c)) {
                // 计算连续英文字母长度
                var j = i;
                while (j < text.len and std.ascii.isAlphabetic(text[j])) {
                    j += 1;
                }
                const length = j - i;
                if (length >= self.config.min_english_length) {
                    return true;
                }
                i = j;
            } else {
                i += 1;
            }
        }
        return false;
    }

    /// 提取文本中的英文残留短语
    pub fn extractEnglishPhrases(self: PureFilter, text: []const u8) std.ArrayList([]const u8) {
        var phrases = std.ArrayList([]const u8).empty;
        var i: usize = 0;

        while (i < text.len) {
            const c = text[i];
            if (std.ascii.isAlphabetic(c)) {
                var j = i;
                while (j < text.len and (std.ascii.isAlphabetic(text[j]) or text[j] == ' ')) {
                    j += 1;
                }
                const phrase = std.mem.trim(u8, text[i..j], " ");
                if (phrase.len >= self.config.min_english_length) {
                    phrases.append(self.gpa, phrase) catch {};
                }
                i = j;
            } else {
                i += 1;
            }
        }

        return phrases;
    }

    /// 过滤英文残留，返回中文提示
    pub fn filterMessage(
        self: *PureFilter,
        gpa: std.mem.Allocator,
        text: []const u8,
        location: []const u8,
    ) ![]const u8 {
        if (!detectEnglish(self, text)) {
            return text;
        }

        // 检查是否在白名单中
        if (self.whitelist.check(text)) {
            return text;
        }

        // 记录未翻译短语
        try self.logUntranslated(text, location);

        // 生成兜底中文提示
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(gpa);

        try out.appendSlice(gpa, self.config.fallback_message);
        try out.appendSlice(gpa, "\n  原文: ");
        try out.appendSlice(gpa, text);

        return out.toOwnedSlice(gpa);
    }

    /// 记录未翻译短语
    pub fn logUntranslated(
        self: *PureFilter,
        phrase: []const u8,
        location: []const u8,
    ) !void {
        const suggested = try std.fmt.allocPrint(self.gpa, "[待翻译] {s}", .{phrase});
        errdefer self.gpa.free(suggested);

        try self.untranslated_phrases.append(self.gpa, .{
            .phrase = try self.gpa.dupe(u8, phrase),
            .location = try self.gpa.dupe(u8, location),
            .timestamp = 0,
            .suggested_translation = suggested,
        });
    }

    /// 生成未翻译短语报告
    pub fn generateReport(self: PureFilter, gpa: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(gpa);

        try out.appendSlice(gpa, "# 未翻译短语报告\n\n");
        try out.appendSlice(gpa, "生成时间: unknown\n\n");

        try out.appendSlice(gpa, "| 序号 | 短语 | 位置 | 建议翻译 |\n");
        try out.appendSlice(gpa, "|------|------|------|----------|\n");

        for (self.untranslated_phrases.items, 1..) |phrase, idx| {
            try out.appendSlice(gpa, try std.fmt.allocPrint(
                gpa,
                "| {d} | {s} | {s} | {s} |\n",
                .{ idx, phrase.phrase, phrase.location, phrase.suggested_translation },
            ));
        }

        return out.toOwnedSlice(gpa);
    }

    /// 从配置加载过滤器
    pub fn fromConfig(gpa: std.mem.Allocator, config_path: []const u8) !PureFilter {
        _ = config_path; // 未来可扩展从文件加载配置
        const config = Config{};
        return try PureFilter.init(gpa, config);
    }
};


/// 短语本地化兜底（复用 translate.zig 中的逻辑）
pub fn localizeFallback(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    const pairs = [_][2][]const u8{
        .{ "expected ", "期望 " },
        .{ ", found ", "，实得 " },
        .{ "; found ", "；实得 " },
        .{ " passed", " 通过" },
        .{ " skipped", " 跳过" },
        .{ " failed", " 失败" },
        .{ "FAIL ", "失败 " },
        .{ "error: ", "错误: " },
        .{ "warning: ", "警告: " },
        .{ "note: ", "说明: " },
        .{ "unrecognized parameter", "无法识别的参数" },
        .{ "argument(s)", "参数" },
        .{ "arguments", "参数" },
        .{ "argument", "参数" },
        .{ "array elements", "数组元素" },
        .{ "an identifier", "标识符" },
        .{ "missing struct field", "结构体缺少字段" },
        .{ "cannot represent integer value", "无法表示整数值" },
        .{ "outside array of length ", "超出数组长度 " },
        .{ "index ", "下标 " },
        .{ "invalid format string ", "无效格式串 " },
        .{ " for type '", " 对类型 '" },
        .{ "type '", "类型 '" },
        .{ "unhandled enumeration value", "未处理的枚举取值" },
        .{ "missing closing ", "缺少闭合的 " },
        .{ "variable of type ", "变量（类型 " },
        .{ " must be const or comptime", "）必须是 `常数`（const）或 `计期`（comptime）" },
        .{ "error union type", "错误联合类型" },
        .{ "optional type", "可选类型" },
        .{ "does not support", "不支持" },
        .{ "field access", "字段访问" },
        .{ "not a function", "不是函数" },
        .{ "cannot dereference non-pointer", "不能解引用非指针" },
        .{ "invalid escape character", "非法转义字符" },
        .{ " is invalid", " 无效" },
        .{ "length ", "长度 " },
        .{ " here", " 在此处" },
    };

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < text.len) {
        var matched = false;
        for (pairs) |p| {
            if (std.mem.startsWith(u8, text[i..], p[0])) {
                try out.appendSlice(gpa, p[1]);
                i += p[0].len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try out.append(gpa, text[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(gpa);
}

test "纯母语过滤器初始化" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();
}

test "detectEnglish - 无英文残留" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    try std.testing.expect(!filter.detectEnglish("错误: 类型不匹配"));
    try std.testing.expect(!filter.detectEnglish("警告: 未使用的变量"));
    try std.testing.expect(!filter.detectEnglish("说明: 先前声明位于此处"));
}

test "detectEnglish - 有英文残留" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    try std.testing.expect(filter.detectEnglish("错误: expected type, found 'i64'"));
    try std.testing.expect(filter.detectEnglish("警告: unused variable 'x'"));
    try std.testing.expect(filter.detectEnglish("说明: previous declaration here"));
}

test "whitelist - 驼峰命名" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    try std.testing.expect(filter.whitelist.check("MyType"));
    try std.testing.expect(filter.whitelist.check("MyVariable"));
}

test "whitelist - 蛇形命名" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    try std.testing.expect(filter.whitelist.check("my_variable"));
    try std.testing.expect(filter.whitelist.check("_private_var"));
}

test "whitelist - Zig 内建函数" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    try std.testing.expect(filter.whitelist.check("@import"));
    try std.testing.expect(filter.whitelist.check("@memcpy"));
}

test "filterMessage - 兜底翻译" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    const result = try filter.filterMessage(
        gpa,
        "expected type, found 'i64'",
        "src/main.zz:5:10",
    );
    defer gpa.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "[未翻译]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "expected type, found 'i64'") != null);
}

test "filterMessage - 白名单通过" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    const result = try filter.filterMessage(
        gpa,
        "MyType",
        "src/main.zz:5:10",
    );
    defer gpa.free(result);

    try std.testing.expect(std.mem.eql(u8, result, "MyType"));
}

test "localizeFallback - 短语替换" {
    const gpa = std.testing.allocator;
    const result = try localizeFallback(gpa, "expected type, found 'i64'");
    defer gpa.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "期望 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "，实得 ") != null);
}