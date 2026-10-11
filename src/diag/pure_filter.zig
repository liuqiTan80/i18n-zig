//! 纯母语过滤器：在报错输出前做最终检查，对任何残留的英文进行拦截或兜底翻译。
//!
//! 核心原则：
//! - 纯母语原则：任何母语编写的代码，报错信息必须 100% 使用该母语
//! - 零英文泄漏：不允许任何英文错误提示出现在母语报错中
//! - 硬性约束优先级：当性能、功能与纯母语原则冲突时，纯母语原则优先级最高

const std = @import("std");
const Pack = @import("../lang/pack.zig").Pack;

const zh_pack = @embedFile("../lang/packs/中文.txt");

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

/// 未翻译短语记录（F3 落盘模型的单一真值形）。
/// 记录**不随过滤器实例走**：一个进程内 `zigCompile` 可能被调用多次（check 多根），每次新建
/// 过滤器，未翻译清单须跨调用累积、进程出口统一落盘——由调用方持有、经 `filterMessage`
/// 的 `log_list` 参数传入（所有权在调用方，本模块只写入其引用）。
pub const UntranslatedPhrase = struct {
    phrase: []const u8,
    location: []const u8,
    timestamp: i64, // epoch 秒；0 = 时间源不可用
};

/// 未翻译短语收集清单：去重（phrase+location 复合键）与 JSON 渲染均为**纯函数**
/// （不依赖 Io/全局状态，进测试图——台账 D7 可测性守则），落盘由 main 层在进程出口执行。
pub const UntranslatedList = struct {
    items: std.ArrayList(UntranslatedPhrase) = .empty,

    /// 记入一条；同 (phrase, location) 已存在则跳过（check 多根/多路会重复报同一错，防爆盘）。
    /// 字符串以 `gpa` dupe 自持。确定性时间戳由调用方注入（纯函数不摸时钟）。
    pub fn log(self: *UntranslatedList, gpa: std.mem.Allocator, phrase: []const u8, location: []const u8, timestamp: i64) !void {
        for (self.items.items) |have| {
            if (std.mem.eql(u8, have.phrase, phrase) and std.mem.eql(u8, have.location, location)) return;
        }
        const owned_phrase = try gpa.dupe(u8, phrase);
        errdefer gpa.free(owned_phrase);
        const owned_loc = try gpa.dupe(u8, location);
        errdefer gpa.free(owned_loc);
        try self.items.append(gpa, .{ .phrase = owned_phrase, .location = owned_loc, .timestamp = timestamp });
    }
};

/// JSON 条目形：字段名以 `_` 标在 comptime 层、值经匿名结构体给出（jsonStringify 约定）。
const JsonEntry = struct {
    phrase: []const u8 = "",
    location: []const u8 = "",
    timestamp: i64 = 0,
    suggested_translation: []const u8 = "",

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("phrase");
        try jw.write(self.phrase);
        try jw.objectField("location");
        try jw.write(self.location);
        try jw.objectField("timestamp");
        try jw.write(self.timestamp);
        try jw.objectField("suggested_translation");
        try jw.write(self.suggested_translation);
        try jw.endObject();
    }
};

const JsonDoc = struct {
    generated_at: i64 = 0,
    phrases: []const JsonEntry = &.{},

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("generated_at");
        try jw.write(self.generated_at);
        try jw.objectField("phrases");
        try jw.write(self.phrases);
        try jw.endObject();
    }
};

/// 渲染未翻译清单为 JSON 文本（UTF-8 字符串按原样写出、控制字符/引号/反斜杠由 stringify
/// 标准转义——CI 消费面必须产生合法 JSON，禁止手写拼接）。返回 `gpa` 所有权。
pub fn renderUntranslatedJson(gpa: std.mem.Allocator, items: []const UntranslatedPhrase, generated_at: i64) ![]u8 {
    const entries = try gpa.alloc(JsonEntry, items.len);
    errdefer gpa.free(entries);
    // 循环内 allocPrint 若失败，`try` 立即返回——此条 string-free 清理若在循环后才 defer 登记，
    // 便来不及登记，前若干已分配的 suggested_translation 会泄漏（第 64 轮 D22 坐实：mid-loop OOM 漏 1 块）。
    // 改以 filled 计数 + errdefer：只精确回滚「已填」部分；循环成功后 errdefer 仍兜住 valueAlloc 失败面。
    var filled: usize = 0;
    errdefer for (entries[0..filled]) |e| gpa.free(e.suggested_translation);
    for (items, entries) |it, *e| {
        e.* = .{
            .phrase = it.phrase,
            .location = it.location,
            .timestamp = it.timestamp,
            .suggested_translation = try std.fmt.allocPrint(gpa, "[待翻译] {s}", .{it.phrase}),
        };
        filled += 1;
    }
    const doc = JsonDoc{ .generated_at = generated_at, .phrases = entries };
    // 0.17 Stringify.Options 断代：旧 `pretty` 改 `whitespace` 枚举（D12 同族）；
    // `escape_unicode` 留默认 false——CJK 原文直接写出，人读/机读面都直观。
    const result = try std.json.Stringify.valueAlloc(gpa, doc, .{ .whitespace = .indent_2 });
    // valueAlloc 成功：entries 及其字符串均已读入 result，手动清理中间态（成功路径不触 errdefer，无重复释放）。
    for (entries) |e| gpa.free(e.suggested_translation);
    gpa.free(entries);
    return result;
}

/// 纯母语过滤器
pub const PureFilter = struct {
    gpa: std.mem.Allocator,
    config: Config,
    whitelist: Whitelist,
    /// F3 落盘收集清单（可 null：只拦不记）：由调用方在 init 时注入、跨过滤器实例存活——
    /// 一个进程内 `zigCompile` 可能多次新建过滤器（check 多根），清单须跨调用累积、进程出口统一落盘。
    log_list: ?*UntranslatedList = null,

    pub fn init(gpa: std.mem.Allocator, config: Config, log_list: ?*UntranslatedList) !PureFilter {
        var whitelist = Whitelist.init(gpa);
        errdefer whitelist.deinit();

        // 白名单零硬编码（台账 F2，51 轮）：规则属语言包领土，由包 `[whitelist]` 段供给、
        // 经 `applyPackRules` 加载；工具层不再内置任何 token。
        return .{
            .gpa = gpa,
            .config = config,
            .whitelist = whitelist,
            .log_list = log_list,
        };
    }

    /// 从语言包 `[whitelist]` 段加载豁免规则（调用方传包内切片，本函数 dupe 自持）。
    /// 重复规则跳过：多次调用幂等，不会爆规则表。
    pub fn applyPackRules(self: *PureFilter, rules: []const []const u8) !void {
        for (rules) |rule| {
            var dup = false;
            for (self.whitelist.rules.items) |have| {
                if (std.mem.eql(u8, have, rule)) dup = true;
            }
            if (!dup) try self.whitelist.add(rule);
        }
    }

    pub fn deinit(self: *PureFilter) void {
        self.whitelist.deinit();
    }

    /// 检测文本中是否包含英文残留。
    /// 默认（非严格）模式为**词链启发式**：仅当两个及以上“长词”（≥min_english_length 连续字母）
    /// 相邻——中间只隔空白/短虚词/数字/标点、无母语文字或标识符内部符号（-_.@/= 等）——才判英文句残留；
    /// 引号区（'...' / `...` / "..."）为操作数领土整体跳过。
    /// 与台账 B2（操作数保留）边界对称：孤立 ASCII 词（类型签名 'comptime_int'、参数名
    /// --release=fast、标识符 MyType、内建 @constCast）是诊断实体、不拦截；真实英文句子
    /// （"expected return type of main"、"not a function"）必含相邻长词对、被拦截。
    /// 严格模式（config.strict_mode）保留旧规则：任意 ≥3 连续字母即英文（CI 零英文扫描用）。
    pub fn detectEnglish(self: *PureFilter, text: []const u8) bool {
        if (!self.config.enabled) return false;
        if (self.config.strict_mode) return self.detectAnyRun(text);

        var i: usize = 0;
        var chain = false; // 已有长词在前且链未断：后续相邻长词即成英文句
        while (i < text.len) {
            const c = text[i];
            if (std.ascii.isAlphabetic(c)) {
                var j = i;
                while (j < text.len and std.ascii.isAlphabetic(text[j])) j += 1;
                if (j - i >= self.config.min_english_length) {
                    if (chain) return true;
                    chain = true;
                }
                // 短词（1-2 字母，如 not a function 的 a / value of 的 of）不另起链也不断链。
                i = j;
                continue;
            }
            // 空白/数字/句读标点：链保持（英文句里常夹数字与逗号）。
            if (c == ' ' or c == '\t' or std.ascii.isDigit(c) or
                c == ',' or c == ';' or c == ':' or c == '.' or c == '!' or c == '?' or
                c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}')
            {
                i += 1;
                continue;
            }
            // 引号区（操作数领土）：整段跳到闭引号，链保持（夹带操作数的英文句仍要被拦）；
            // 未闭合则按普通字符断链处理。
            if (c == '\'' or c == '`' or c == '"') {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, c)) |close| {
                    i = close + 1;
                    continue;
                }
            }
            // 其余（标识符内部符号 -_.@/=\、路径、母语文字的非 ASCII 字节）：断链。
            chain = false;
            i += 1;
        }
        return false;
    }

    /// 旧规则（严格模式）：任意 ≥min 连续字母即判英文。
    fn detectAnyRun(self: *PureFilter, text: []const u8) bool {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (std.ascii.isAlphabetic(c)) {
                var j = i;
                while (j < text.len and std.ascii.isAlphabetic(text[j])) {
                    j += 1;
                }
                if (j - i >= self.config.min_english_length) {
                    return true;
                }
                i = j;
            } else {
                i += 1;
            }
        }
        return false;
    }

    /// 提取文本中的英文残留短语（分配失败向上传播，不静默丢短语——台账 D16）
    pub fn extractEnglishPhrases(self: PureFilter, text: []const u8) !std.ArrayList([]const u8) {
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
                    try phrases.append(self.gpa, phrase);
                }
                i = j;
            } else {
                i += 1;
            }
        }

        return phrases;
    }

    /// 过滤消息：含英文残留且不在白名单时生成兜底译文，并记入 `self.log_list`（F3 落盘面）。
    /// 时间戳由调用方在记录边界注入（本模块不摸 Io，保持纯可测——D7；无产品时间语境传 0）。
    /// 所有路径均返回 `gpa` 分配的**拥有权副本**（调用方可无条件 `gpa.free`）。
    pub fn filterMessage(
        self: *PureFilter,
        gpa: std.mem.Allocator,
        text: []const u8,
        location: []const u8,
        timestamp_epoch_s: i64,
    ) ![]const u8 {
        if (!detectEnglish(self, text)) {
            return try gpa.dupe(u8, text); // 统一拥有权：旧版直返借用、调用方 free 非自有内存即崩溃
        }

        // 检查是否在白名单中
        if (self.whitelist.check(text)) {
            return try gpa.dupe(u8, text);
        }

        // 记录未翻译短语（去重与自持在清单纯函数内；时间戳来自调用方）
        if (self.log_list) |list| {
            try list.log(gpa, text, location, timestamp_epoch_s);
        }

        // 生成兜底中文提示
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(gpa);

        try out.appendSlice(gpa, self.config.fallback_message);
        try out.appendSlice(gpa, "\n  原文: ");
        try out.appendSlice(gpa, text);

        return out.toOwnedSlice(gpa);
    }

    /// 生成未翻译短语报告（Markdown 人类阅读面；CI 机读面走 `renderUntranslatedJson` 落盘）。
    /// 无 self 方法：渲染只吃清单、不需要过滤器状态（避免 unused-self）。
    pub fn renderReport(gpa: std.mem.Allocator, items: []const UntranslatedPhrase) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(gpa);

        try out.appendSlice(gpa, "# 未翻译短语报告\n\n");

        try out.appendSlice(gpa, "| 序号 | 短语 | 位置 | 建议翻译 |\n");
        try out.appendSlice(gpa, "|------|------|------|----------|\n");

        for (items, 1..) |phrase, idx| {
            // 行临时串必须逐行释放：旧写法 `appendSlice(gpa, try allocPrint(...))` 把 allocPrint 结果直接
            // 传递给 appendSlice（拷贝字节入 out）却从不 free 那块临时串 → 每行泄 1 块（第 65 轮 D23 坐实）。
            const row = try std.fmt.allocPrint(
                gpa,
                "| {d} | {s} | {s} | [待翻译] {s} |\n",
                .{ idx, phrase.phrase, phrase.location, phrase.phrase },
            );
            defer gpa.free(row);
            try out.appendSlice(gpa, row);
        }

        return out.toOwnedSlice(gpa);
    }

    /// 从配置加载过滤器（落盘清单由调用方后续注入；本入口暂无配置盘面）
    pub fn fromConfig(gpa: std.mem.Allocator, config_path: []const u8) !PureFilter {
        _ = config_path; // 未来可扩展从文件加载配置
        const config = Config{};
        return try PureFilter.init(gpa, config, null);
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
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();
}

test "detectEnglish - 无英文残留" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    try std.testing.expect(!filter.detectEnglish("错误: 类型不匹配"));
    try std.testing.expect(!filter.detectEnglish("警告: 未使用的变量"));
    try std.testing.expect(!filter.detectEnglish("说明: 先前声明位于此处"));
}

test "detectEnglish - 有英文残留" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    try std.testing.expect(filter.detectEnglish("错误: expected type, found 'i64'"));
    try std.testing.expect(filter.detectEnglish("警告: unused variable 'x'"));
    try std.testing.expect(filter.detectEnglish("说明: previous declaration here"));
    // 长-短-长链（not a function / value of declaration）：夹短虚词的英文句同样拦截。
    try std.testing.expect(filter.detectEnglish("类型 'i64' not a function"));
}

test "detectEnglish - B2 边界：孤立操作数不误拦" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 单个长词（类型签名/参数名/标识符/内建）是诊断实体、非英文句子，不得触发兜底。
    try std.testing.expect(!filter.detectEnglish("无法加载仅限编译期的类型 'comptime_int'"));
    try std.testing.expect(!filter.detectEnglish("无法识别的参数: --release=fast")); // = 断链，非相邻词
    try std.testing.expect(!filter.detectEnglish("MyType"));
    try std.testing.expect(!filter.detectEnglish("建议使用 @constCast 处理"));
    try std.testing.expect(!filter.detectEnglish("错误 FileNotFound 发生"));
    // 标识符内部符号（下划线/点号）断链：comptime_int、my_variable 各自孤立。
    try std.testing.expect(!filter.detectEnglish("值 comptime_int 无效"));
    try std.testing.expect(!filter.detectEnglish("字段 my_variable 缺失"));
}

test "detectEnglish - 严格模式保留旧规则" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{ .strict_mode = true }, null);
    defer filter.deinit();

    // 严格模式（CI 零英文扫描用）：任意 ≥3 字母即拦，含孤立操作数。
    try std.testing.expect(filter.detectEnglish("值 comptime_int 无效"));
    try std.testing.expect(!filter.detectEnglish("错误: 类型不匹配"));
}

test "whitelist - 驼峰命名（规则由包供给：applyPackRules 加载内置包后生效）" {
    const gpa = std.testing.allocator;
    var pack = try Pack.parse(gpa, zh_pack);
    defer pack.deinit();
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();
    try filter.applyPackRules(pack.whitelist.items);

    // 幂等：重复加载不爆表也不报错。
    try filter.applyPackRules(pack.whitelist.items);

    try std.testing.expect(filter.whitelist.check("MyType"));
    try std.testing.expect(filter.whitelist.check("MyVariable"));
    // 工具层自身不再内置任何 token：新过滤器未加载前必然 miss。
    var bare = try PureFilter.init(gpa, .{}, null);
    defer bare.deinit();
    try std.testing.expect(!bare.whitelist.check("MyType"));
}

test "whitelist - 蛇形命名" {
    const gpa = std.testing.allocator;
    var pack = try Pack.parse(gpa, zh_pack);
    defer pack.deinit();
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();
    try filter.applyPackRules(pack.whitelist.items);

    try std.testing.expect(filter.whitelist.check("my_variable"));
    try std.testing.expect(filter.whitelist.check("_private_var"));
}

test "whitelist - Zig 内建函数" {
    const gpa = std.testing.allocator;
    var pack = try Pack.parse(gpa, zh_pack);
    defer pack.deinit();
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();
    try filter.applyPackRules(pack.whitelist.items);

    try std.testing.expect(filter.whitelist.check("@import"));
    try std.testing.expect(filter.whitelist.check("@memcpy"));
}

test "filterMessage - 兜底翻译，且记入落盘清单（F3）" {
    const gpa = std.testing.allocator;
    var list = UntranslatedList{};
    defer {
        for (list.items.items) |it| {
            gpa.free(it.phrase);
            gpa.free(it.location);
        }
        list.items.deinit(gpa);
    }
    var filter = try PureFilter.init(gpa, .{}, &list);
    defer filter.deinit();

    const result = try filter.filterMessage(
        gpa,
        "expected type, found 'i64'",
        "src/main.zz:5:10",
        123,
    );
    defer gpa.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "[未翻译]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "expected type, found 'i64'") != null);
    try std.testing.expectEqual(@as(usize, 1), list.items.items.len);
    try std.testing.expectEqualStrings("expected type, found 'i64'", list.items.items[0].phrase);
    try std.testing.expectEqualStrings("src/main.zz:5:10", list.items.items[0].location);
    try std.testing.expectEqual(@as(i64, 123), list.items.items[0].timestamp);

    // 同一 (phrase, location) 再记一次：去重不爆盘（check 多根/多路重复报同一错）。
    {
        const r2 = try filter.filterMessage(gpa, "expected type, found 'i64'", "src/main.zz:5:10", 456);
        defer gpa.free(r2);
    }
    try std.testing.expectEqual(@as(usize, 1), list.items.items.len);
    // 同短语不同位置：另记一条。
    {
        const r3 = try filter.filterMessage(gpa, "expected type, found 'i64'", "src/other.zz:1:2", 789);
        defer gpa.free(r3);
    }
    try std.testing.expectEqual(@as(usize, 2), list.items.items.len);
}

test "filterMessage - 白名单通过" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    const result = try filter.filterMessage(
        gpa,
        "MyType",
        "src/main.zz:5:10",
        0,
    );
    defer gpa.free(result);

    try std.testing.expect(std.mem.eql(u8, result, "MyType"));
}

test "F3 - JSON 渲染：合法可解析、中文原样、特殊字符转义、空清单也合法" {
    const gpa = std.testing.allocator;

    // 空清单：仍须产出合法 JSON（`{}` 包裹、phrases 空数组）。
    const empty = try renderUntranslatedJson(gpa, &.{}, 0);
    defer gpa.free(empty);
    {
        var parsed = try std.json.parseFromSlice(JsonDoc, gpa, empty, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 0), parsed.value.phrases.len);
    }

    // 含中文、引号/换行/反斜杠的条目：转义合法性交给 std.json 往返验证。
    const items = [_]UntranslatedPhrase{
        .{ .phrase = "expected \"type\", found\n'i64'\\x", .location = "src/主程序.zz:5:10", .timestamp = 1762000000 },
    };
    const json = try renderUntranslatedJson(gpa, &items, 1762000001);
    defer gpa.free(json);
    var parsed = try std.json.parseFromSlice(JsonDoc, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.phrases.len);
    try std.testing.expectEqualStrings(items[0].phrase, parsed.value.phrases[0].phrase);
    try std.testing.expectEqualStrings("src/主程序.zz:5:10", parsed.value.phrases[0].location);
    try std.testing.expectEqual(@as(i64, 1762000000), parsed.value.phrases[0].timestamp);
    const want_suggested = try std.fmt.allocPrint(gpa, "[待翻译] {s}", .{items[0].phrase});
    defer gpa.free(want_suggested);
    try std.testing.expectEqualStrings(want_suggested, parsed.value.phrases[0].suggested_translation);
}

test "localizeFallback - 短语替换" {
    const gpa = std.testing.allocator;
    const result = try localizeFallback(gpa, "expected type, found 'i64'");
    defer gpa.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "期望 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "，实得 ") != null);
}

test "renderUntranslatedJson - mid-loop OOM 不得泄漏已分配字符串（D22 坐实）" {
    // fail_index=2（0 基）：entries 缓冲(第1次 alloc)成功、st[0](第2次)成功、st[1](第3次 allocPrint) 失败 → 循环内报错。
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const gpa = failing.allocator();
    const items = [_]UntranslatedPhrase{
        .{ .phrase = "alpha", .location = "main.zz:1:1", .timestamp = 1 },
        .{ .phrase = "beta", .location = "main.zz:2:2", .timestamp = 2 },
    };
    // 旧实现：string-free 清理 defer 登记在循环之后，mid-loop OOM 时 try 已返回、defer 未登记
    // → 已分配的 entries[0].suggested_translation（"[待翻译] alpha"，17 字节）泄漏（std.testing.allocator 会报）。
    // 期望：干净返回 OutOfMemory 且无泄漏（filled 计数 + errdefer 精确回滚已填部分）。
    try std.testing.expectError(error.OutOfMemory, renderUntranslatedJson(gpa, &items, 123));
}

test "renderReport - Markdown 渲染内容正确且不泄漏行临时串（D23 坐实）" {
    const gpa = std.testing.allocator;
    const items = [_]UntranslatedPhrase{
        .{ .phrase = "alpha", .location = "main.zz:1:1", .timestamp = 1 },
        .{ .phrase = "beta", .location = "src/主.zz:2:3", .timestamp = 2 },
    };
    const result = try PureFilter.renderReport(gpa, &items);
    defer gpa.free(result);

    // 内容正确性：表头 + 逐行（序号/短语/位置/建议翻译）。
    try std.testing.expectEqualStrings(
        "# 未翻译短语报告\n\n" ++
            "| 序号 | 短语 | 位置 | 建议翻译 |\n" ++
            "|------|------|------|----------|\n" ++
            "| 1 | alpha | main.zz:1:1 | [待翻译] alpha |\n" ++
            "| 2 | beta | src/主.zz:2:3 | [待翻译] beta |\n",
        result,
    );
    // 兼做泄漏回归：旧实现循环内 `try out.appendSlice(gpa, try allocPrint(...))` 的行临时串从不 free
    // → 每行泄 1 块（happy path 即泄），std.testing.allocator 会在测毕报 leaked——本测同钉此回归。
}
