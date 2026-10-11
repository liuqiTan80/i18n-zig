//! 语言包：极简行式 `键 = 值` 数据格式（刻意不用 TOML，避免引第三方依赖）。
//!
//! 文件格式：
//!   - `#` 或 `//` 开头为注释行；空行跳过
//!   - `[段名]` 切换当前段：keywords / aliases / diagnostics / whitelist
//!   - `键 = 值`：键值均去除首尾空白；值保留内部空白
//!   - diagnostics 段的值以 `|` 分隔三段：`匹配前缀|译文模板|教学提示`
//!   - whitelist 段每行即一条白名单规则（整行精确匹配、无需 `=`），供纯母语过滤器豁免（台账 F2）
//!
//! 引擎语言无关：新增一门方言只需新增一份包文件。
//!
//! 叠加层（补充包/适配层，台账 R11，第 53 轮）：一个逻辑包可由「基包 + 有序补充层」拼成，
//! 逐层 `parseInto` 累积到同一 Pack。合并语义——keywords/aliases/`$code`/`$name` 同键后写覆盖；
//! diagnostics 按 pattern 后写覆盖（原地替换、保持位置）；whitelist 取并集（幂等）。见 `loadWithOverlays`。

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
/// `[whitelist]` 段：允许保留的英文 token（整行精确匹配）。归属语言包而非工具硬编码（F2）。
whitelist: std.ArrayList([]const u8),

/// 契约值清单（台账 B6）：工具链在多处按“映射值”反查方言词形（`keywordFormsFor`：
/// `const`/`@embedFile`/`@import` 的预扫描豁免与 staging、`pub fn main` 入口探测），
/// 任何方言包若缺这些映射会在流程深处静默失能；在 parse 后立即校验、母语报错。
/// 清单只含 ASCII 值、不硬编码任何方言词（语言无关原则）。
pub const contract_values = [_][]const u8{
    "const",   // 声明半：撞词避让 / const 单跳数据流（D3）
    "var",
    "fn",      // `主函数`→main 入口链与声明位识别
    "if",
    "else",
    "return",
    "struct",
    "enum",
    "union",
    "switch",
    "@import",   // 导入词形预扫描（D2/D4）
    "@embedFile", // 嵌入词形预扫描与资产 staging（D2/D3）
    "main",     // 语义编译根判据（含 main 的文件）
};

pub const ValidationError = error{
    PackMissingConst,
    PackMissingVar,
    PackMissingFn,
    PackMissingIf,
    PackMissingElse,
    PackMissingReturn,
    PackMissingStruct,
    PackMissingEnum,
    PackMissingUnion,
    PackMissingSwitch,
    PackMissingImport,
    PackMissingEmbedFile,
    PackMissingMain,
    PackMissingCode,
};

/// 包内任一映射值（keywords ∪ aliases）等于 want 即命中。
fn hasMappedValue(self: Pack, want: []const u8) bool {
    var it = self.keywords.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*, want)) return true;
    }
    var it2 = self.aliases.iterator();
    while (it2.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*, want)) return true;
    }
    return false;
}

/// 格式完整面校验（B6）：parse 只保证行式语法合法，本函数补“语义契约”：
/// ① `$code` 必须显式给出（`未知语言`/`??` 默认值混入产品输出属静默降级）；
/// ② contract_values 逐项存在。错误值逐个命名，供调用方翻译成母语可操作提示。
pub fn validate(self: Pack) ValidationError!void {
    if (std.mem.eql(u8, self.code, "??")) return error.PackMissingCode;
    const err_for = [_]ValidationError{
        error.PackMissingConst, error.PackMissingVar, error.PackMissingFn, error.PackMissingIf, error.PackMissingElse,
        error.PackMissingReturn, error.PackMissingStruct, error.PackMissingEnum, error.PackMissingUnion, error.PackMissingSwitch,
        error.PackMissingImport, error.PackMissingEmbedFile, error.PackMissingMain,
    };
    for (contract_values, 0..) |want, i| {
        if (!self.hasMappedValue(want)) return err_for[i];
    }
}

pub fn init(gpa: std.mem.Allocator) Pack {
    return .{
        .keywords = std.StringHashMap([]const u8).init(gpa),
        .aliases = std.StringHashMap([]const u8).init(gpa),
        .diagnostics = .empty,
        .whitelist = .empty,
    };
}

pub fn deinit(self: *Pack) void {
    const gpa = self.keywords.allocator;
    self.keywords.deinit();
    self.aliases.deinit();
    self.diagnostics.deinit(gpa);
    for (self.whitelist.items) |rule| gpa.free(rule);
    self.whitelist.deinit(gpa);
}

const Section = enum { keywords, aliases, diagnostics, whitelist };

/// diagnostics 按 pattern 后写覆盖：命中同 pattern 就地替换（保持既有位置，不破坏
/// 「全等先于子串」的匹配序，见台账 D6/R1），否则追加。Entry 各字段为输入字节的视图、
/// 非本包拥有（内嵌资源/常量串生命周期长于 Pack），故替换无需释放旧值。
fn upsertDiagnostic(self: *Pack, gpa: std.mem.Allocator, entry: Entry) !void {
    for (self.diagnostics.items) |*have| {
        if (std.mem.eql(u8, have.pattern, entry.pattern)) {
            have.* = entry;
            return;
        }
    }
    try self.diagnostics.append(gpa, entry);
}

/// 把一份包字节流**累积**解析进已存在的 Pack（叠加层/补充包的底层，可多次调用）。
/// 后写覆盖：keywords/aliases/`$code`/`$name` 同键覆盖；diagnostics 按 pattern 覆盖；
/// whitelist 并集（幂等，已去重）。`bytes` 须比 `self` 存活更久（内嵌资源天然满足）。
pub fn parseInto(self: *Pack, gpa: std.mem.Allocator, bytes: []const u8) !void {
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

        switch (section) {
            .whitelist => {
                // 每行即一条规则（无 `键 = 值` 结构，`=` 检查不适用于本段）；
                // `|` 之后为人读备注、剥离后才是匹配体；重复行跳过（幂等，支持多层/多次加载）。
                const rule = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '|') orelse line.len], " ");
                if (rule.len == 0) return error.InvalidLangPack;
                var dup = false;
                for (self.whitelist.items) |have| {
                    if (std.mem.eql(u8, have, rule)) dup = true;
                }
                if (!dup) try self.whitelist.append(gpa, try gpa.dupe(u8, rule));
            },
            .keywords, .aliases => {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLangPack;
                const key = std.mem.trim(u8, line[0..eq], " \t");
                const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
                if (key.len == 0) return error.InvalidLangPack;
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
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLangPack;
                const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
                const p1 = std.mem.indexOfScalar(u8, value, '|') orelse return error.InvalidLangPack;
                const rest = value[p1 + 1 ..];
                const p2 = std.mem.indexOfScalar(u8, rest, '|') orelse return error.InvalidLangPack;
                try self.upsertDiagnostic(gpa, .{
                    .pattern = std.mem.trim(u8, value[0..p1], " "),
                    .message = std.mem.trim(u8, rest[0..p2], " "),
                    .tip = std.mem.trim(u8, rest[p2 + 1 ..], " "),
                });
            },
        }
    }
}

/// 解析一份语言包字节流为全新 Pack。返回所有权由调用方以 deinit 释放。
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Pack {
    var self = init(gpa);
    errdefer self.deinit();
    try self.parseInto(gpa, bytes);
    return self;
}

/// 叠加式加载（R11）：先解析 `base`，再按序把每个补充层 `overlays` 累积进同一 Pack。
/// 合并语义见文件头《叠加层》。`overlays` 为空时等价于 `parse(gpa, base)`。
/// 所有权由调用方以 deinit 释放；`validate` 应在整体合并后调用一次（补充层可补齐基包缺的契约值）。
pub fn loadWithOverlays(gpa: std.mem.Allocator, base: []const u8, overlays: []const []const u8) !Pack {
    var self = init(gpa);
    errdefer self.deinit();
    try self.parseInto(gpa, base);
    for (overlays) |ov| try self.parseInto(gpa, ov);
    return self;
}

/// 语言包中映射值恰为 `want` 的全部词形 + ASCII 直通形 `want` 本身（如 const → `const` + `常数`）。
/// 供原文预扫描与单跳变量实参解析（台账 D2/D3：方言词尚未翻译，只认 ASCII 形不够）。
/// 第 61 轮自 main.zig 下沉至本模块测试图（D7/D21：main.zig 的 test 块从不执行、此纯查询此前零有效覆盖）。
/// 返回数组经 `toOwnedSlice` 拥有（len==capacity），调用方 `gpa.free(本体)` 释放数组；
/// 元素是 `want` 与 keywords 键的借用视图（归 lang/常量字面量所有），勿逐项释放。
pub fn keywordFormsFor(gpa: std.mem.Allocator, lang: Pack, want: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    try list.append(gpa, want);
    var it = lang.keywords.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*, want)) try list.append(gpa, e.key_ptr.*);
    }
    return list.toOwnedSlice(gpa);
}

/// `@embedFile` 的全部词形（ASCII 直通形 + 方言词，如 `嵌入文件`）。供原文预扫描（D2）。
pub fn embedWordForms(gpa: std.mem.Allocator, lang: Pack) ![]const []const u8 {
    return keywordFormsFor(gpa, lang, "@embedFile");
}

test "keywordFormsFor/embedWordForms（第 61 轮下沉真测）：ASCII 直通形居首 + 真实 zh 包方言词形被枚举" {
    const gpa = std.testing.allocator;
    const zh = @embedFile("packs/中文.txt");
    var lang = try parse(gpa, zh);
    defer lang.deinit();

    // @embedFile：直通形必居首（确定性），且中文方言词「嵌入文件」(= @embedFile) 被枚举到。
    const forms = try keywordFormsFor(gpa, lang, "@embedFile");
    defer gpa.free(forms);
    try std.testing.expectEqualStrings("@embedFile", forms[0]);
    try std.testing.expect(forms.len >= 2);
    var hit_embed = false;
    for (forms) |f| {
        if (std.mem.eql(u8, f, "嵌入文件")) hit_embed = true;
    }
    try std.testing.expect(hit_embed);

    // const：方言词「常数」被枚举。
    const cs = try keywordFormsFor(gpa, lang, "const");
    defer gpa.free(cs);
    var hit_const = false;
    for (cs) |f| {
        if (std.mem.eql(u8, f, "常数")) hit_const = true;
    }
    try std.testing.expect(hit_const);

    // embedWordForms 即 @embedFile 词形的便捷别名，与上同。
    const ew = try embedWordForms(gpa, lang);
    defer gpa.free(ew);
    try std.testing.expectEqualStrings("@embedFile", ew[0]);
}

test "语言包解析" {
    const gpa = std.testing.allocator;
    const src =
        \\# 测试包
        \\$name = 测试语
        \\$code = te
        \\[keywords]
        \\常数 = const
        \\[aliases]
        \\标准库.打印 = std.debug.print
        \\[whitelist]
        \\@memcpy|内建拷贝
        \\MyType
        \\@memcpy|重复行被幂等跳过
    ;
    var pack = try gpa.create(Pack);
    defer gpa.destroy(pack);
    pack.* = try parse(gpa, src);
    defer pack.deinit();

    try std.testing.expectEqualStrings("测试语", pack.name);
    try std.testing.expectEqualStrings("const", pack.keywords.get("常数").?);
    try std.testing.expectEqualStrings("std.debug.print", pack.aliases.get("标准库.打印").?);
    // whitelist：`|` 备注剥离后入规则、重复幂等。
    try std.testing.expectEqual(@as(usize, 2), pack.whitelist.items.len);
    try std.testing.expectEqualStrings("@memcpy", pack.whitelist.items[0]);
    try std.testing.expectEqualStrings("MyType", pack.whitelist.items[1]);
}

test "B6 契约校验 - 缺映射值/缺 $code 逐个报错，内置中文包全量通过" {
    const gpa = std.testing.allocator;

    // 最小不完整包：只有 const 映射，无 $code。（raw string 不含换行，多行源用拼接写）
    var bad = try parse(gpa, "[keywords]\n" ++ "常数 = const\n");
    defer bad.deinit();
    try std.testing.expectError(error.PackMissingCode, bad.validate());
    bad.code = "te"; // 绕过 code 面，逐项验契约缺失
    try std.testing.expectError(error.PackMissingVar, bad.validate());

    // 同包补齐 var 后，下一个缺失项（fn）浮现——证明逐项而非首个吞全部。
    try bad.keywords.put("变量", "var");
    try std.testing.expectError(error.PackMissingFn, bad.validate());

    // @import 只出现在 aliases 也算命中（hasMappedValue 取并集）。
    var imp_only = try parse(gpa, "$code = ip\n" ++ "[aliases]\n" ++ "引入 = @import\n");
    defer imp_only.deinit();
    try std.testing.expect(imp_only.hasMappedValue("@import"));

    // 内置真实语言包必须全量通过（契约清单以实际包为真值源，防两处漂移）。
    const zh = @embedFile("packs/中文.txt");
    var real = try parse(gpa, zh);
    defer real.deinit();
    try real.validate();
}

test "R11 叠加层：基包+补充层——同键后写覆盖、diagnostics 按 pattern 覆盖、whitelist 并集" {
    const gpa = std.testing.allocator;
    const base =
        \\$code = zh
        \\[keywords]
        \\常数 = const
        \\[diagnostics]
        \\d1 = 未声明的标识符|基包译文|基包提示
        \\[whitelist]
        \\@memcpy|基包允许
    ;
    const overlay =
        \\$code = zh-x
        \\[keywords]
        \\常数 = let
        \\额外 = var
        \\[diagnostics]
        \\d1x = 未声明的标识符|补充层译文|补充层提示
        \\新错误 = 别的模式|新模式译文|新模式提示
        \\[whitelist]
        \\@memcpy|重复（幂等）
        \\MyType
    ;

    var pack = try Pack.loadWithOverlays(gpa, base, &.{overlay});
    defer pack.deinit();

    // keywords 同键后写覆盖；补充层新键并入。
    try std.testing.expectEqualStrings("let", pack.keywords.get("常数").?);
    try std.testing.expectEqualStrings("var", pack.keywords.get("额外").?);
    // $code 后写覆盖。
    try std.testing.expectEqualStrings("zh-x", pack.code);
    // diagnostics 按 pattern 覆盖：不新增条目、原条目译文/提示被换；新 pattern 追加。
    try std.testing.expectEqual(@as(usize, 2), pack.diagnostics.items.len);
    try std.testing.expectEqualStrings("未声明的标识符", pack.diagnostics.items[0].pattern);
    try std.testing.expectEqualStrings("补充层译文", pack.diagnostics.items[0].message);
    try std.testing.expectEqualStrings("补充层提示", pack.diagnostics.items[0].tip);
    try std.testing.expectEqualStrings("别的模式", pack.diagnostics.items[1].pattern);
    // whitelist 并集：@memcpy 幂等不重复、MyType 新增。
    try std.testing.expectEqual(@as(usize, 2), pack.whitelist.items.len);
    try std.testing.expectEqualStrings("@memcpy", pack.whitelist.items[0]);
    try std.testing.expectEqualStrings("MyType", pack.whitelist.items[1]);
}

test "R11 空补充层等价单包 parse（loadWithOverlays 不退化现有行为）" {
    const gpa = std.testing.allocator;
    const src = "$code = te\n" ++ "[keywords]\n" ++ "常数 = const\n";
    var a = try Pack.parse(gpa, src);
    defer a.deinit();
    var b = try Pack.loadWithOverlays(gpa, src, &.{});
    defer b.deinit();
    try std.testing.expectEqualStrings(a.code, b.code);
    try std.testing.expectEqual(a.keywords.count(), b.keywords.count());
    try std.testing.expectEqualStrings("const", b.keywords.get("常数").?);
}
