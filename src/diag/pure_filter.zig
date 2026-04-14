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
        // owned 尚未入列（append 会把它交给 deinit 回收）：若 append 失败则无人回收→泄 owned。
        // 与 D22/D24 同族的错误路径回滚缺口；append 增长走批量预留容量、不可确定性注入红（R10f），
        // 故 code-review 驱动的源头治理（成功路径不触 errdefer、行为不变）。
        errdefer self.gpa.free(owned);
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

/// 未翻译清单落盘路径的**单一真值**（第 197 轮 D64）：此前 `Config.log_path` 默认值与 `main.zig`
/// 落盘点的字面量各写一份、互不引用——改任一侧都无人报警（探针实锤：只改 `Config.log_path` 默认值，
/// 全库测试仍绿，因该字段零消费者；而改 main 侧字面量则 192 块抓红），同时
/// `docs/纯母语过滤器架构设计.md` 又把该字段作为可配项公开。现两侧同取本常量，双源漂移面消除；
/// 实例级生效边界见 `Config.log_path` 注。
pub const default_log_path: []const u8 = "logs/untranslated_phrases.json";

/// 纯母语过滤器配置
pub const Config = struct {
    enabled: bool = true,
    min_english_length: usize = 3,
    fallback_message: []const u8 = "[未翻译] 此报错暂未提供中文翻译，请参考英文原文",
    /// 落盘路径默认值（= `default_log_path`，与 main 层落盘点同源）。生效边界：实际落盘由 main 层按
    /// `default_log_path` 执行，本字段传非默认值**不改变**落盘点位——filter 系 `zigCompile` 帧内局部
    /// （`main.zig` L444）、进程出口 `flushUntranslated` 拿不到它；要按实例生效须把 filter 或路径
    /// 提到进程级（同 `machine_mode` 先例），当前无此需求，字段只承载默认形制（第 197 轮 T1 钉）。
    log_path: []const u8 = default_log_path,
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
    /// 相邻——中间只隔空白/短虚词/数字/句读标点（含点号 `.`）、且无母语文字或标识符内部符号
    /// （`_` `@` `/` `=` `-` `\`）——才判英文句残留；
    /// 点号 `.` 刻意归句读标点（保持链）而非标识符内部符号（断链）：本模块顶规「零英文泄漏优先」，
    /// 若按 `.` 断链会漏判含小数/句号的真实英文句（如 `delay 1.5 seconds`、`failed. try again`）；
    /// 代价是极少数裸夹在中文里的点分路径（如 `std.debug`）被过度判定——偏保守可接受，已知放行者交白名单。
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
            // 空白/数字/句读标点（含点号 `.`）：链保持——英文句里常夹数字、逗号乃至小数/句号；
            // 点号按本行归入标点（保持链）系刻意取舍，详见 detectEnglish 顶注「零英文泄漏优先」。
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
            // 其余（标识符内部符号 -_@/=\、路径分隔、母语文字的非 ASCII 字节）：断链。
            // 注：`.` 属句读标点（保持链），见上方 L223；旧注误列于此系 D34 同族残余，第 94 轮更正。
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

test "detectEnglish - 引号保链不变量守卫（两长词被引号隔开仍须判英文；未闭合引号断链）" {
    // 零覆盖对抗面：L357 测 "unused variable 'x'" 两长词均在引号之前、检测在触及引号前即完成；
    // L360 "'i64' not a function" 引号在链首之前（非"词-引-词"形）。
    // 若引号处理器误改为断链（chain=false），以下"词-引-词"形即漏检——本测钉住当前设计意图。
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 词-引-词：chain 跨越引号保持 → expected…found 判英文（zig 实报 "expected 'X' found Y" 形）
    try std.testing.expect(filter.detectEnglish("expected 'identifier' found something"));
    try std.testing.expect(filter.detectEnglish("value `x` cannot be assigned"));
    // 引号内操作数、引号外单长词 → 不触发（词-引-孤立，无第二长词）
    try std.testing.expect(!filter.detectEnglish("无法转换 'comptime_int' 类型"));
    // 未闭合引号：按普通字符断链（开引号后无闭引号 → 落到 chain=false）
    // 断链后两侧孤立长词各自不成链 → 不判英文
    try std.testing.expect(!filter.detectEnglish("first 'unclosed"));
    // 但断链后若又出现两个相邻长词 → 新链完成、仍判英文
    try std.testing.expect(filter.detectEnglish("first 'unclosed second third"));
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
    // 标识符内部符号（下划线 @ = - 等）断链：comptime_int、my_variable 各自孤立。
    // 注：点号 `.` 属句读标点、保持链（非断链），行为与用例见下方「点号保持链」专项测。
    try std.testing.expect(!filter.detectEnglish("值 comptime_int 无效"));
    try std.testing.expect(!filter.detectEnglish("字段 my_variable 缺失"));
}

test "detectEnglish - 点号属句读标点·保持链（刻意·零英文泄漏优先；防按旧误注改码致漏检回归）" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 点号被当作句读标点保持词链：夹在其中的两段 ≥3 字母视为相邻、判英文句残留。
    // 这是刻意为之（本模块顶规：冲突时纯母语/零英文泄漏优先）——过度判定仍附「原文」不丢信息，
    // 反之若把 `.` 改判为断链会漏掉含小数/句号的真实英文句，泄漏英文更违背初衷。
    try std.testing.expect(filter.detectEnglish("请检查 std.debug 调用"));
    try std.testing.expect(filter.detectEnglish("请调用 std.debug.print 输出"));
    // 对照断链族（下划线/@）：孤立操作数不误拦。
    try std.testing.expect(!filter.detectEnglish("参考 comptime_int 类型"));
    try std.testing.expect(!filter.detectEnglish("使用 @constCast 转换"));
}

test "detectEnglish - 严格模式保留旧规则" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{ .strict_mode = true }, null);
    defer filter.deinit();

    // 严格模式（CI 零英文扫描用）：任意 ≥3 字母即拦，含孤立操作数。
    try std.testing.expect(filter.detectEnglish("值 comptime_int 无效"));
    try std.testing.expect(!filter.detectEnglish("错误: 类型不匹配"));
}

// 护栏（第 113 轮证伪落位）：严格模式入口 detectAnyRun 的 `>= min` 连字母长度边界此前
// 仅在非严格词链模式（detectEnglish，见下方 min 恰等边界测）钉过；严格测只用了
// 远超 min 的 comptime_int(8) 与纯 CJK，从未钉 `=min`/`<min` 恰等边界——两入口共享
// 同一 config.min_english_length 常量却只一侧被钉。本测补钉严格模式 min 长度边界，
// 并证门槛随 config 移动（非硬编码 3）：严格只去掉「需两长词成链」、保留连字母长度门槛。
test "detectEnglish 严格模式 detectAnyRun min 连字母长度边界（与词链模式共享 >= min 常量，第 113 轮）" {
    const gpa = std.testing.allocator;
    var fs = try PureFilter.init(gpa, .{ .strict_mode = true }, null); // 默认 min=3
    defer fs.deinit();
    try std.testing.expect(!fs.detectEnglish("fo ba")); // 2+2 字母均 < min → 不拦
    try std.testing.expect(fs.detectEnglish("foo")); // 恰等 min 的单长词 → 拦（严格模式形）
    try std.testing.expect(!fs.detectEnglish("值 ab 无效")); // 区内仅 2 字母 < min、CJK 字节不计 → 不拦
    try std.testing.expect(fs.detectEnglish("值 int 无效")); // int=3 = min → 拦

    var fs5 = try PureFilter.init(gpa, .{ .strict_mode = true, .min_english_length = 5 }, null);
    defer fs5.deinit();
    // 门槛随 config 移动：min=5 时 4 字母不拦、5 字母恰等拦——钉 >= min 常量非硬编码 3。
    try std.testing.expect(!fs5.detectEnglish("hell")); // 4 < 5 → 不拦
    try std.testing.expect(fs5.detectEnglish("hello")); // 5 = 5 → 拦
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

test "fromConfig 构造默认过滤器（第 66 轮：文档面公开 API 此前从不被编译，补测钉住并防断代）" {
    const gpa = std.testing.allocator;
    var f = try PureFilter.fromConfig(gpa, "config/pure_filter.json"); // 当前入口不摸盘、路径被忽略（_ = config_path）
    defer f.deinit();
    // 钉住构造出的对象状态自洽：默认配置、未注入落盘清单、白名单空——防该未接线公开 API 静默腐坏。
    const default_config = Config{};
    try std.testing.expectEqual(default_config.min_english_length, f.config.min_english_length);
    try std.testing.expect(f.log_list == null);
    try std.testing.expectEqual(@as(usize, 0), f.whitelist.rules.items.len);
}

// 护栏（第 89 轮、pure_filter 全量通读对抗面：证伪·无在线缺陷，钉 stated-behavior 族）：
// detectEnglish 顶注声明「引号区为操作数领土整体跳过」与「未闭合则按普通字符断链处理」，
// 两契约及其连带代价形（缩写孤撇号断链、min 长度恰等边界、enabled 总闸）历轮零测——
// 本测钉住现状防静默漂移（D34 同族：注释与代码的自洽一旦断链，后来者按误注改码即酿漏检）。
test "detectEnglish 护栏：引号区隔离、孤撇号断链、min 长度与 enabled 边界" {
    const gpa = std.testing.allocator;
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // ① 引号区隔离：操作数内整段英文不进入词链（顶注声明的现行契约）。
    try std.testing.expect(!filter.detectEnglish("无法加载仅限编译期类型 'expected type found'"));
    // 三种引号（' " `）均跳区，区外长词照常成链——夹带操作数的英文句仍必须被拦。
    try std.testing.expect(filter.detectEnglish("failed \"foo bar\" here again"));
    try std.testing.expect(filter.detectEnglish("check `aaa bbb` cccc done"));

    // ② 未闭合引号：按普通字符断链，其后长词重新成链（保守形、不漏拦）。
    try std.testing.expect(filter.detectEnglish("\"foo bar baz"));
    // 孤撇号（缩写 it's 形）：无配对引号→断链；剩余词不构成链即漏判——declared 代价
    //（zig 正式消息无缩写、生产链不可达漏判面；若未来消息形变化，本行为即已知缺口）。
    try std.testing.expect(!filter.detectEnglish("expected it's wrong"));

    // ③ min 长度恰等边界：恰好 min 字母即成链，min-1 字母不成链不断链。
    try std.testing.expect(filter.detectEnglish("foo bar")); // 默认 min=3：两 3 字母词相邻成链
    var f5 = try PureFilter.init(gpa, .{ .min_english_length = 5 }, null);
    defer f5.deinit();
    try std.testing.expect(f5.detectEnglish("hello world")); // 5+5 恰等边界成链
    try std.testing.expect(!f5.detectEnglish("hello wor")); // 3 字母词低于 5、不另起链

    // ④ enabled=false 总闸：一切放行。
    var foff = try PureFilter.init(gpa, .{ .enabled = false }, null);
    defer foff.deinit();
    try std.testing.expect(!foff.detectEnglish("expected type, found 'i64'"));
}

// 第 197 轮审计注（D64）：`Config.log_path` 系**零消费者**死字段（全仓仅 L53 定义处一枚命中），
// 真实落盘路径另由 `main.zig` 字面量硬编——两处同值字面量双源。探针实锤：只改本字段默认值
// 为别的路径、全库测试仍绿；只改 main 侧字面量则 192 T1 转红（写侧早有**字面量**判据钉住——
// 该钉独立于真值常量、非自证循环，承 196 轮 t3 通则）。修：抽 `default_log_path` 为单一真值、
// Config 默认与 main 写侧同取。同源形制本身无可运行判据（值相等即可、指针身份测不稳），靠注释
// 与本块 A1/A2 双侧字面量钉兼顾：改真值→A1 红与 192 红、改 Config 默认偏离真值→A2 红。

test "第 197 轮 T1 未翻译落盘路径单一真值：真值字面量钉 + Config 默认同源 + 路径形制契约 + init 忠实透传" {
    const gpa = std.testing.allocator;

    // A1 真值本身（判据用**字面量**、不复用 `default_log_path`——同源判据怎么改都自洽，即 196 轮
    //   t3 现形的自证循环伪钉）。与 F3 历史落盘位一致，改名即红（CI/语言包作者消费面在仓外，不可跟改）。
    try std.testing.expectEqualStrings("logs/untranslated_phrases.json", default_log_path);

    // A2 Config 默认与真值同源：有人把默认写回独立字面量且值不同即红（双源漂移面的运行侧防线）。
    try std.testing.expectEqualStrings(default_log_path, (Config{}).log_path);

    // A3 路径形制契约：相对 cwd、正斜杠、`logs/` 目录段——三条各有跨面依赖：`.gitignore` 以 `logs/`
    //   条目兼容、`file_io.writeWhole` 自动建父目录只对**相对**路径与正斜杠分段成立、`main.zig` 192 T1
    //   的回清走 `cwd().deleteTree("logs")`。真值被改成绝对路径/反斜杠/换目录则此处先红。
    try std.testing.expect(std.mem.startsWith(u8, default_log_path, "logs/"));
    try std.testing.expect(std.mem.indexOfScalar(u8, default_log_path, '\\') == null);
    try std.testing.expect(!std.fs.path.isAbsolute(default_log_path));

    // A4 init 忠实透传：字段随 config 存入、本模块不抹平也不默认化（钉住「可传但仅透传」的现状契约：
    //   若日后把它接成真效面或干脆删字段，此处转红即为改动须同步登记 D64 的信号）。
    var f = try PureFilter.init(gpa, .{ .log_path = "自定义/路径.json" }, null);
    defer f.deinit();
    try std.testing.expectEqualStrings("自定义/路径.json", f.config.log_path);
}
