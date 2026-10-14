//! 语言包：极简行式 `键 = 值` 数据格式（刻意不用 TOML，避免引第三方依赖）。
//!
//! 文件格式：
//!   - `#` 或 `//` 开头为注释行；空行跳过
//!   - `[段名]` 切换当前段：keywords / aliases / diagnostics / whitelist
//!   - `键 = 值`：键值均去除首尾空白；值保留内部空白；**空值一律拒绝**（D30：空值会被转译端
//!     把词元抹成空串／绕过 `$code` 校验／使空 pattern 吞掉全部诊断；唯 diagnostics 第三段 tip 可空）
//!   - diagnostics 段的值以 `|` 分隔三段：`匹配前缀|译文模板|教学提示`
//!   - whitelist 段每行即一条白名单规则（整行精确匹配、无需 `=`），供纯母语过滤器豁免（台账 F2）
//!   - `$format = 1` 包格式版本头（R9g，第 103 轮）：外部分发包声明其所依的包格式版本；
//!     高于当前工具支持值即拒载并提示升级 zzc（而非误译/崩溃），未声明缺省为 1（旧包向后兼容）
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

/// 当前工具支持的对外包格式版本（R9g）：行式格式自第三方独立发行起升格为**对外契约**，
/// 包内 `$format` 声明高于此值必须明确拒绝（旧包无 `$format` 行、缺省视为 1，永不破坏已流通的包）。
pub const supported_format: u32 = 1;

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
    "const", // 声明半：撞词避让 / const 单跳数据流（D3）
    "var",
    "fn", // `主函数`→main 入口链与声明位识别
    "if",
    "else",
    "return",
    "struct",
    "enum",
    "union",
    "switch",
    "@import", // 导入词形预扫描（D2/D4）
    "@embedFile", // 嵌入词形预扫描与资产 staging（D2/D3）
    "main", // 语义编译根判据（含 main 的文件）
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
        error.PackMissingConst,  error.PackMissingVar,       error.PackMissingFn,   error.PackMissingIf,    error.PackMissingElse,
        error.PackMissingReturn, error.PackMissingStruct,    error.PackMissingEnum, error.PackMissingUnion, error.PackMissingSwitch,
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
/// **同层冲突拒**（D36 mangle 撞号同族，第 93 轮）：同一次调用（单字节流）内同键/同 pattern
/// 第二次出现且**值不同** → `error.InvalidLangPack` 源头拒（手编包矛盾两行静默其一失效属数据编辑
/// 陷阱）；同值幂等放行（whitelist 先例对称）；跨层（多次调用）后写覆盖仍是 R11 文档化合并语义、
/// 不受此检影响——故判据绑「本次调用写过该键」而非「表里已存在该键」。
/// `$format` 版本头（R9g）：>supported_format → error.PackFormatTooNew；0/非十进制数 → InvalidLangPack；
/// 合法值吞进元数据不入 keywords/aliases 表（同 $name/$code 形制）。
pub fn parseInto(self: *Pack, gpa: std.mem.Allocator, bytes: []const u8) !void {
    var section: Section = .keywords;
    // 本次调用内已写键/值视图（key/value 均借 bytes，仅调用期内比较、不拥有）。
    // keywords 与 aliases 分集：同词跨段两表各有映射不属同表矛盾（翻译链第 1/2 步优先级确定）。
    const Seen = struct { key: []const u8, val: []const u8 };
    var seen_kw: std.ArrayList(Seen) = .empty;
    defer seen_kw.deinit(gpa);
    var seen_al: std.ArrayList(Seen) = .empty;
    defer seen_al.deinit(gpa);
    var seen_diag: std.ArrayList(Entry) = .empty;
    defer seen_diag.deinit(gpa);
    var seen_name: ?[]const u8 = null;
    var seen_code: ?[]const u8 = null;
    var seen_format: ?[]const u8 = null;
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
                if (!dup) {
                    const owned = try gpa.dupe(u8, rule);
                    // append 失败则 owned 未入列、无人回收→泄（D22/D24 同族错误路径缺口；
                    // 批量预留容量不可注入红 R10f，code-review 源头治理）。
                    errdefer gpa.free(owned);
                    try self.whitelist.append(gpa, owned);
                }
            },
            .keywords, .aliases => {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLangPack;
                const key = std.mem.trim(u8, line[0..eq], " \t");
                const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
                if (key.len == 0) return error.InvalidLangPack;
                // 空值条目一律拒（D30 源头治理）：keywords/aliases 空值命中转译端会把词元抹成
                // 空串产碎码；`$code =` 置空串恰绕过 validate 首关（只查 `== "??"`）；守卫置于
                // $name/$code 分支之前，三条路径一并封口，转译端无从见到空值。
                if (value.len == 0) return error.InvalidLangPack;
                const map = if (section == .keywords) &self.keywords else &self.aliases;
                // 包格式版本头（R9g，第 103 轮）：外部分发包的前向兼容契约。
                // 合法即吞不入表；高于 supported_format 拒并提示升级——否则新格式字段（如未来新段）
                // 会被旧工具当非法行拒或静默丢弃，造成半翻译；0 与非十进制数属手误形拒。
                if (std.mem.eql(u8, key, "$format")) {
                    if (seen_format) |old| {
                        if (!std.mem.eql(u8, old, value)) return error.InvalidLangPack;
                    }
                    seen_format = value;
                    const v = std.fmt.parseInt(u32, value, 10) catch return error.InvalidLangPack;
                    if (v == 0 or v > supported_format) {
                        if (v > supported_format) return error.PackFormatTooNew;
                        return error.InvalidLangPack;
                    }
                    continue;
                }
                if (std.mem.eql(u8, key, "$name")) {
                    // 同层元数据矛盾两行（$name/$code 不同值）同族封口；同值幂等照放。
                    if (seen_name) |old| {
                        if (!std.mem.eql(u8, old, value)) return error.InvalidLangPack;
                    }
                    seen_name = value;
                    self.name = value;
                    continue;
                }
                if (std.mem.eql(u8, key, "$code")) {
                    if (seen_code) |old| {
                        if (!std.mem.eql(u8, old, value)) return error.InvalidLangPack;
                    }
                    seen_code = value;
                    self.code = value;
                    continue;
                }
                // 同层同键异值 → 拒；同值 → 幂等放行（不新增拒绝面）。
                const seen = if (section == .keywords) &seen_kw else &seen_al;
                for (seen.items) |s| {
                    if (std.mem.eql(u8, s.key, key) and !std.mem.eql(u8, s.val, value)) {
                        return error.InvalidLangPack;
                    }
                }
                try seen.append(gpa, .{ .key = key, .val = value });
                try map.put(key, value);
            },
            .diagnostics => {
                // 值格式：`匹配前缀|母语译文|教学提示`（键仅作人类可读标识，不参与匹配）
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLangPack;
                const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
                const p1 = std.mem.indexOfScalar(u8, value, '|') orelse return error.InvalidLangPack;
                const rest = value[p1 + 1 ..];
                const p2 = std.mem.indexOfScalar(u8, rest, '|') orelse return error.InvalidLangPack;
                const pattern = std.mem.trim(u8, value[0..p1], " ");
                const message = std.mem.trim(u8, rest[0..p2], " ");
                // 空 pattern 使 matchDiag 的 `indexOf(msg, "")` 恒真、吞掉全部报错转成同一译文
                // （全局静默错译）；空 message 命中后输出空诊断。唯 tip 可空（`tip.len != 0`
                // 才渲染提示行是既有契约，见 D30）。
                if (pattern.len == 0 or message.len == 0) return error.InvalidLangPack;
                const tip = std.mem.trim(u8, rest[p2 + 1 ..], " ");
                // 同层同 pattern 不同内容 → 拒（键不参与匹配、冲突在 pattern 侧）；全等 → 幂等。
                for (seen_diag.items) |s| {
                    if (std.mem.eql(u8, s.pattern, pattern) and
                        (!std.mem.eql(u8, s.message, message) or !std.mem.eql(u8, s.tip, tip)))
                    {
                        return error.InvalidLangPack;
                    }
                }
                try seen_diag.append(gpa, .{ .pattern = pattern, .message = message, .tip = tip });
                try self.upsertDiagnostic(gpa, .{
                    .pattern = pattern,
                    .message = message,
                    .tip = tip,
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

/// 首个映射为 `want` 的方言词（先 keywords 后 aliases，多形并存时取先入表形、同包同构建确定）。
/// 供模板脚手架按包组词（第 142 轮）：工具侧不硬编码任何方言词，判据全取自包——与 D44
/// 反查同一语言无关原则。未命中 null（调用方自行降级：ASCII 直通形或整行省略）。
/// aliases 多段键（如 `标准库.调试.打印`）可整体作点分链使用——翻译第 1 步贪心链匹配跨非 ASCII 段。
pub fn firstKeywordFor(lang: Pack, want: []const u8) ?[]const u8 {
    var it = lang.keywords.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*, want)) return e.key_ptr.*;
    }
    var it2 = lang.aliases.iterator();
    while (it2.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*, want)) return e.key_ptr.*;
    }
    return null;
}

/// `@embedFile` 的全部词形（ASCII 直通形 + 方言词，如 `嵌入文件`）。供原文预扫描（D2）。
pub fn embedWordForms(gpa: std.mem.Allocator, lang: Pack) ![]const []const u8 {
    return keywordFormsFor(gpa, lang, "@embedFile");
}

test "firstKeywordFor（第 142 轮模板按包组词的地基）：keywords 优先、aliases 兼容多段链键、未命中 null" {
    const gpa = std.testing.allocator;
    var lang = try parse(gpa, @embedFile("packs/中文.txt"));
    defer lang.deinit();

    // keywords 段命中：结构词反查形与真包一致。
    try std.testing.expectEqualStrings("常数", lang.firstKeywordFor("const").?);
    try std.testing.expectEqualStrings("函数", lang.firstKeywordFor("fn").?);
    try std.testing.expectEqualStrings("导入", lang.firstKeywordFor("@import").?);
    // aliases 段命中（keywords 未映射时兼容）：单段入口名与多段叶子链键——多段键整体可作点分链用。
    try std.testing.expectEqualStrings("主函数", lang.firstKeywordFor("main").?);
    try std.testing.expectEqualStrings("标准库", lang.firstKeywordFor("std").?);
    try std.testing.expectEqualStrings("标准库.调试.打印", lang.firstKeywordFor("std.debug.print").?);
    // 未命中：包无任何映射值等于它——调用方自行降级，不得 panic。
    try std.testing.expectEqual(@as(?[]const u8, null), lang.firstKeywordFor("nonexistent.value"));
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
        \\标准库.调试.打印 = std.debug.print
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
    try std.testing.expectEqualStrings("std.debug.print", pack.aliases.get("标准库.调试.打印").?);
    // whitelist：`|` 备注剥离后入规则、重复幂等。
    try std.testing.expectEqual(@as(usize, 2), pack.whitelist.items.len);
    try std.testing.expectEqualStrings("@memcpy", pack.whitelist.items[0]);
    try std.testing.expectEqualStrings("MyType", pack.whitelist.items[1]);
}

test "内置中文包别名表不变量（第 141 轮）：键除 `.` 分隔外须纯非 ASCII、新模块名到位、全量覆盖" {
    const gpa = std.testing.allocator;
    const zh = @embedFile("packs/中文.txt");
    var p = try parse(gpa, zh);
    defer p.deinit();

    // 不变量一：别名键除 `.`（词元切分的句读分隔符）外不得含任何 ASCII 字节。
    // 依据：matchAliasChain 仅跨 `.nonascii_word` 词元；若键内混入 ASCII 字母段（如 `标准库.elf`），
    // 词法器会把 `elf` 切成 ascii_word、链永不命中——该别名将成为写了也永不生效的死词条（静默）。
    var it = p.aliases.iterator();
    var n: usize = 0;
    while (it.next()) |e| {
        n += 1;
        for (e.key_ptr.*) |b| {
            if (b == '.') continue;
            try std.testing.expect(b >= 0x80);
        }
    }
    // 不变量二：全量覆盖——std.zig 顶层 pub 名基本都应有母语别名（本轮由 ~32 扩至 ≥100）。
    try std.testing.expect(n >= 100);

    // 不变量三：代表性新模块别名确到位（值保留英文原路径不受限）。
    try std.testing.expectEqualStrings("std.debug", p.aliases.get("标准库.调试").?);
    try std.testing.expectEqualStrings("std.http", p.aliases.get("标准库.网络").?);
    try std.testing.expectEqualStrings("std.json", p.aliases.get("标准库.交换文本").?);
    try std.testing.expectEqualStrings("std.elf", p.aliases.get("标准库.联载格式").?);
    try std.testing.expectEqualStrings("std.ArrayListUnmanaged", p.aliases.get("标准库.列表裸").?);
    // 既有高频条目不得因重排而丢失（回归防线）。
    try std.testing.expectEqualStrings("std", p.aliases.get("标准库").?);
    try std.testing.expectEqualStrings("std.process", p.aliases.get("标准库.过程").?);
    try std.testing.expectEqualStrings("std.debug.print", p.aliases.get("标准库.调试.打印").?);
}

test "别名键段数不变量（第 143 轮逐段镜像）：每条 alias 中文键点分段数须等于英文值点分段数" {
    // 依据（用户口径 143）：叶子别名须逐段镜像英文点路径（std.debug.print→标准库.调试.打印），
    // 「段数相等」是「逐段一一对应」的可机械化形式。旧压扁形（标准库.打印 = std.debug.print 段数 2≠3）
    // 吞掉中间模块段，是「参数不知所云」这类迷惑的根源——本测把镜像定理钓死，任何人再写压扁形即红。
    const gpa = std.testing.allocator;
    const zh = @embedFile("packs/中文.txt");
    var p = try parse(gpa, zh);
    defer p.deinit();

    var it = p.aliases.iterator();
    while (it.next()) |e| {
        const k = std.mem.count(u8, e.key_ptr.*, ".") + 1;
        const v = std.mem.count(u8, e.value_ptr.*, ".") + 1;
        try std.testing.expectEqual(k, v);
    }
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

// 护栏（第 112 轮证伪落位）：`validate` 以循环指标 `i` 将 `contract_values[i]` 位置耦合到
// `err_for[i]`（两定长数组、纯下标对齐）——B6 测仅钉 const/var/fn 前三位，余十位重排/增删
// 无测可挡。本测依声明序逐项累积补值：每补一项，缺失报错须翻到对应的**下一个**具名错误，
// 全十三项齐后方放行；钉死两数组全序对齐——任一被单独重排即错报、红。
test "validate 契约清单与错误枚举逐项同序对齐（contract_values↔err_for 位置耦合，第 112 轮）" {
    const gpa = std.testing.allocator;
    // 期望序列：与 contract_values 声明序一一对应（const/var/fn/if/else/return/struct/enum/union/switch/@import/@embedFile/main）。
    const expect_seq = [_]ValidationError{
        error.PackMissingConst,  error.PackMissingVar,    error.PackMissingFn,
        error.PackMissingIf,     error.PackMissingElse,   error.PackMissingReturn,
        error.PackMissingStruct, error.PackMissingEnum,   error.PackMissingUnion,
        error.PackMissingSwitch, error.PackMissingImport, error.PackMissingEmbedFile,
        error.PackMissingMain,
    };
    // 等长前置守卫：contract_values 增项而 err_for 未同步即在此红（防越界读）。
    try std.testing.expectEqual(contract_values.len, expect_seq.len);

    var pack = Pack.init(gpa);
    defer pack.deinit();
    pack.code = "te"; // 绕开 PackMissingCode 首关，专走契约值循环
    for (expect_seq, 0..) |want_err, i| {
        try std.testing.expectError(want_err, pack.validate());
        // 以 contract_values[i] 自身作键与值（静态字面量、生命期长于 pack），逐项累积补齐。
        try pack.keywords.put(contract_values[i], contract_values[i]);
    }
    try pack.validate(); // 十三项齐 → 全序通过
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

test "R9g $format 版本头：合法值吞不入表、缺省兼容旧包；过高/0/非数/同层冲突各拒各形" {
    const gpa = std.testing.allocator;
    const minimal = "$code = te\n$name = 测试\n";

    // ① 合法声明：解析通过且 `$format` 被元数据分支吞掉——不入 keywords/aliases（翻译链摸不到它）。
    var p = try Pack.parse(gpa, minimal ++ "$format = 1\n[keywords]\n常数 = const\n");
    defer p.deinit();
    try std.testing.expect(p.keywords.get("$format") == null);
    try std.testing.expect(p.aliases.get("$format") == null);
    try std.testing.expectEqualStrings("const", p.keywords.get("常数").?);

    // ② 缺省兼容：无 $format 行的旧包照过（已流通包永不被新规则事后杀死）。
    var old = try Pack.parse(gpa, minimal ++ "[keywords]\n常数 = const\n");
    defer old.deinit();

    // ③ 同值幂等声明放行（D40 封口对称）；同层异值冲突 → InvalidLangPack。
    var idem = try Pack.parse(gpa, minimal ++ "$format = 1\n$format = 1\n[keywords]\n常数 = const\n");
    defer idem.deinit();
    try std.testing.expectError(error.InvalidLangPack, Pack.parse(gpa, minimal ++ "$format = 1\n$format = 2\n[keywords]\n常数 = const\n"));

    // ④ 高于支持值 → 专错 PackFormatTooNew（提示升级而非误译/崩）；不取未来支持值。
    try std.testing.expectError(error.PackFormatTooNew, Pack.parse(gpa, minimal ++ "$format = 99\n[keywords]\n常数 = const\n"));

    // ⑤ 手误形：0/负数/非十进制数 → InvalidLangPack（版本从 1 起）。
    try std.testing.expectError(error.InvalidLangPack, Pack.parse(gpa, minimal ++ "$format = 0\n[keywords]\n常数 = const\n"));
    try std.testing.expectError(error.InvalidLangPack, Pack.parse(gpa, minimal ++ "$format = -1\n[keywords]\n常数 = const\n"));
    try std.testing.expectError(error.InvalidLangPack, Pack.parse(gpa, minimal ++ "$format = 一\n[keywords]\n常数 = const\n"));

    // ⑥ 叠加层不受版本头约束：基包声明 1、补充层无头，合并照过（R11 语义不变）。
    var layered = try Pack.loadWithOverlays(gpa, minimal ++ "$format = 1\n[keywords]\n常数 = const\n", &.{"[keywords]\n函数 = fn\n"});
    defer layered.deinit();
    try std.testing.expectEqualStrings("fn", layered.keywords.get("函数").?);
}

test "空值条目拒绝（D30）：keywords/aliases/$code/diagnostics 空 pattern・空 message 均 InvalidLangPack" {
    // 缺陷面：parseInto 各分支只查键非空、值空串放行——①keywords/aliases 空值命中转译端
    // emitReplacement 把词元抹成空串（产碎码）；②`$code =` 置空串恰绕过 validate 首关
    // （`code == "??"`），B6 防的静默降级被空值开门；③diagnostics 空 pattern 使 matchDiag
    // 的 `indexOf(msg, "")` 恒真、吞掉全部报错转成空译文（全局静默错译）。修法源头治理：
    // parse 即拒，转译端无从见到空值。唯 tip 维持可空（`tip.len != 0` 才渲染提示行是既有契约）。
    const gpa = std.testing.allocator;

    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[keywords]\n常数 =\n"));
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[keywords]\n常数 = \n"));
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[aliases]\n标准库.打印 =\n"));
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code =\n[keywords]\n常数 = const\n"));
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[diagnostics]\nd = |译文|提示\n"));
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[diagnostics]\nd = 模式||提示\n"));

    // 对照：合法包照过；diagnostics 空 tip 仍合法（不渲染提示行、非缺陷面）。
    // 不对残包调 validate——它只验 parse 封口面，契约完整性由 B6 测以真实包把关。
    var ok = try parse(gpa, "$code = te\n[keywords]\n常数 = const\n[diagnostics]\nd = 模式|译文|\n");
    defer ok.deinit();
    try std.testing.expectEqualStrings("const", ok.keywords.get("常数").?);
    try std.testing.expectEqual(@as(usize, 1), ok.diagnostics.items.len);
    try std.testing.expectEqualStrings("", ok.diagnostics.items[0].tip);
}

test "parseInto 对抗/畸形段头与诊断元数不足：一律 InvalidLangPack 干净拒绝、不 panic（包文件系外部可编辑面）" {
    // 现有测（D30/R11/B6）只喂合法段头与三足诊断行；对抗/畸形形零覆盖。本测钉住各
    // `indexOfScalar(...) orelse return` 守卫兵实拦下越界、日后重构删任一 orelse 即红。
    const gpa = std.testing.allocator;

    // 段名畸形：未知段名 / 缺右方括号 / 空段名——均须拒而非 panic（不拿缺括号行去切片）。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[unknown]\n常数 = const\n"));
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[keywords\n常数 = const\n")); // 缺 ]
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[]\n常数 = const\n")); // 空段名

    // 诊断元数不足：零竖线（p1 orelse）/ 仅一竖线缺第三段（p2 orelse）——须拒、不得越界切 rest。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[diagnostics]\nd = 无竖线\n"));
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[diagnostics]\nd = 模式|译文\n"));

    // keywords/aliases 段行缺 `=`：indexOfScalar '=' 的 orelse 须命中拒错。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[keywords]\n常数 const\n"));

    // 白名单行仅备注（`|` 前为空）：rule.len==0 须拒。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[whitelist]\n|只有备注\n"));

    // 对照：行内 `#`/`//` 不剔离（注释系整行首字符，见文件头），值按原样保留——钉住“无行内注释”这一
    // by-design（真包 中文.txt 值行零行内注释），防未来“善意”加行内注释剔离而改坏含 # 的合法值。
    var okp = try parse(gpa, "$code = te\n[keywords]\n常数 = a#b//c\n");
    defer okp.deinit();
    try std.testing.expectEqualStrings("a#b//c", okp.keywords.get("常数").?);
}

test "同层重复键冲突源头拒（D36 mangle 撞号同族）：同一字节流内同键不同值即 InvalidLangPack；同值幂等放行；跨层覆盖照旧合法（R11）" {
    // 缺陷面：keywords/aliases 段 L187 `map.put` 对同键后行静默覆盖——手编包/插件包写错两行
    // 矛盾映射（`常数 = const` + `常数 = var`）时先行意图被无声丢弃、零诊断；diagnostics 同
    // pattern 不同内容经 upsert 同形；`$code`/`$name` 同层两行不同值同族。D30 先例（配置源头
    // 即拒）与 D36 先例（mangle 撞号 put 源头拒）的对称面。边界：R11 叠加层「跨层同键后写覆盖」
    // 是文件头明钉的合并语义，不得误伤——故判据绑「同一 parseInto 调用内第二次出现且值不同」；
    // 同层同键同值幂等放行（whitelist 重复行幂等先例对称）。
    const gpa = std.testing.allocator;

    // keywords / aliases 同层同键不同值 → 拒（对原始码：put 静默覆盖 → parse 成功 → 本断言红）。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[keywords]\n常数 = const\n常数 = var\n"));
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[aliases]\n标准库 = std\n标准库 = fmt\n"));
    // diagnostics 同层同 pattern 不同内容 → 拒（键不参与匹配、冲突在 pattern 侧）。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n[diagnostics]\nd1 = 模式|译文A|提示\nd2 = 模式|译文B|提示\n"));
    // $code/$name 同层两行不同值 → 拒（元数据同族）。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n$code = zz\n[keywords]\n常数 = const\n"));

    // 对照①：同层同键同值 → 幂等放行（不新增拒绝面，whitelist 先例对称）。
    var idem = try parse(gpa, "$code = te\n[keywords]\n常数 = const\n常数 = const\n[diagnostics]\nd1 = 模式|译文|提示\nd2 = 模式|译文|提示\n");
    defer idem.deinit();
    try std.testing.expectEqualStrings("const", idem.keywords.get("常数").?);
    try std.testing.expectEqual(@as(usize, 1), idem.diagnostics.items.len);

    // 对照②：R11 跨层同键不同值覆盖照旧合法（叠加层合并语义不得被误伤）。
    var layered = try Pack.loadWithOverlays(gpa, "$code = te\n[keywords]\n常数 = const\n[diagnostics]\nd1 = 模式|基包译文|基包提示\n", &.{"[keywords]\n常数 = let\n[diagnostics]\nd2 = 模式|补充译文|补充提示\n"});
    defer layered.deinit();
    try std.testing.expectEqualStrings("let", layered.keywords.get("常数").?);
    try std.testing.expectEqual(@as(usize, 1), layered.diagnostics.items.len);
    try std.testing.expectEqualStrings("补充译文", layered.diagnostics.items[0].message);
}

// 护栏（第 120 轮证伪落位）：L588 测注释声称覆盖「$code/$name 同层两行不同值 → 拒」，但 L589
// 实只喂 $code 一例——$name 的 seen_name 不同值封口分支（L220-221）从未被任何测 fired。若误删
// 该判据，手编包矛盾两行 $name 静默后写覆盖、零诊断（D40 同族元数据损坏）。本测钉住：①同名异
// 值拒（仅 $name 不因 $code 合法而漏拒）、②同值幂等放行、③$name/$code 各自独立封口、④缺省形。
test "$name 同层元数据封口：两行不同值拒、同值幂等放行、缺省落默认（D40 同族·既有测仅钉 $code 一侧、$name 分支此前零 fired，第 120 轮）" {
    const gpa = std.testing.allocator;

    // ① $name 同层两行不同值 → 拒（seen_name != eql 分支，此前从未 fired）。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$name = 甲\n$name = 乙\n$code = te\n[keywords]\n常数 = const\n"));
    // ② $name 同层同值 → 幂等放行（不新增拒绝面，对称 $code 先例）。
    var idem = try parse(gpa, "$name = 甲\n$name = 甲\n$code = te\n[keywords]\n常数 = const\n");
    defer idem.deinit();
    try std.testing.expectEqualStrings("甲", idem.name);
    // ③ $code/$name 各自独立：仅 $name 冲突不因 $code 合法而漏拒（seen_code 已置、seen_name 仍要检）。
    try std.testing.expectError(error.InvalidLangPack, parse(gpa, "$code = te\n$name = 甲\n$name = 乙\n[keywords]\n常数 = const\n"));
    // ④ 缺省形：无 $name 行照过、name 落默认「未知语言」（validate 只查 $code、不查 name）。
    var defname = try parse(gpa, "$code = te\n[keywords]\n常数 = const\n");
    defer defname.deinit();
    try std.testing.expectEqualStrings("未知语言", defname.name);
}

// 护栏（第 127 轮证伪落位）：头注 L4 声明「`#` 或 `//` 开头为注释行；空行跳过」，判据基于 L164
// trim 后的 line（先剥行首尾空白、L165 再查首字符）——故「带前导缩进的注释行、纯空白似空行」
// 同样被跳过。既有测注释恒居列 0、真包 中文.txt 零行首空白行（实测）——该声明线零直钉：若
// 注释/空行判据回退为基于 raw（整理判据时常见 mutation），keywords 段的缩进注释会被当正文行拒
// （误拒形）、whitelist 段的缩进注释会被当规则静默入表（误放形、不报错最危险）——两形旧测皆无测能拦。
test "缩进注释与纯空白似空行按声明跳过为注释行：判据基于 trim 后 line 而非 raw（头注 L4 声明面零直钉，第 127 轮）" {
    const gpa = std.testing.allocator;

    // ① keywords 段：缩进 # / 缩进 // / 纯空白行三形夹在有效行间——解析过、表内仅真条目。
    var pack = try parse(gpa, "$code = te\n" ++
        "[keywords]\n" ++
        "   # 缩进井号注释\n" ++
        "\t// 缩进双斜杠注释\n" ++
        "      \n" ++
        "常数 = const\n" ++
        "  \t # 混合缩进注释\n");
    defer pack.deinit();
    try std.testing.expectEqual(@as(usize, 1), pack.keywords.count());
    try std.testing.expectEqualStrings("const", pack.keywords.get("常数").?);

    // ② whitelist 段：缩进注释不得静默入表成规则（此形不报错、规则面被污染——误放形）。
    var wl = try parse(gpa, "$code = te\n" ++
        "[whitelist]\n" ++
        "   # 这是注释不是规则\n" ++
        "MyType\n");
    defer wl.deinit();
    try std.testing.expectEqual(@as(usize, 1), wl.whitelist.items.len);
    try std.testing.expectEqualStrings("MyType", wl.whitelist.items[0]);
}

// 护栏（第 127 轮证伪落位）：L164 trim 集 " \t\r" 的 `\r` 独力承担 CRLF（Windows 行尾）语言包
// 容错全链：空行 raw 为 "\r" 须剥后才跳（否则落入正段缺 `=` 误拒）、`$format = 1\r` 的 parseInt
// 须剥后才不被误拒非数（R9g）、key/value/pattern/message/tip/whitelist 规则值须剥后才无尾 \r。
// 本模块测题输入零 `\r`（grep 实锤全文件仅产品码一处）；既存「间接兜底」系环境依赖——本机工作树
// 中文.txt 为 w/crlf（@embedFile 含 232 个 CR）使 zh 包测顺带 fired trim，但 git 记录 i/lf，
// Linux/CI 检出即 LF 字节、兜底随之消失；且那些测从未断言值剥后确形。外部发行包（R9g
// --lang-file）经 Windows 记事本编辑成 CRLF 天然可达（同 121 轮 mangle CRLF 形）——本测全库
// 唯一确定性地钉住 CRLF 容错真行为。
test "CRLF 行尾语言包容错：空 \\r 行被跳、$format 不被误拒、各段值无尾 \\r 确形（外部发行包形，第 127 轮）" {
    const gpa = std.testing.allocator;

    var pack = try parse(gpa, "$name = 测试语\r\n" ++
        "$code = te\r\n" ++
        "$format = 1\r\n" ++
        "\r\n" ++
        "[keywords]\r\n" ++
        "常数 = const\r\n" ++
        "\r\n" ++
        "[diagnostics]\r\n" ++
        "d1 = 模式|译文|提示\r\n" ++
        "[whitelist]\r\n" ++
        "MyType\r\n" ++
        "@memcpy|备注\r\n");
    defer pack.deinit();
    // 元数据无尾 \r 确形（漏剥则 "te\r"!="te"；`$format` 的 "1\r" parseInt 误拒——上方 try parse 即红）。
    try std.testing.expectEqualStrings("测试语", pack.name);
    try std.testing.expectEqualStrings("te", pack.code);
    // keywords：段头尾 \r 不影响切段、值仅干净形。
    try std.testing.expectEqual(@as(usize, 1), pack.keywords.count());
    try std.testing.expectEqualStrings("const", pack.keywords.get("常数").?);
    // diagnostics：三段均无尾 \r（tip 居末段、直面行尾）。
    try std.testing.expectEqual(@as(usize, 1), pack.diagnostics.items.len);
    try std.testing.expectEqualStrings("模式", pack.diagnostics.items[0].pattern);
    try std.testing.expectEqualStrings("译文", pack.diagnostics.items[0].message);
    try std.testing.expectEqualStrings("提示", pack.diagnostics.items[0].tip);
    // whitelist：规则体与备注剥离后之体均无 \r。
    try std.testing.expectEqual(@as(usize, 2), pack.whitelist.items.len);
    try std.testing.expectEqualStrings("MyType", pack.whitelist.items[0]);
    try std.testing.expectEqualStrings("@memcpy", pack.whitelist.items[1]);

    // 混尾源（\n 与 \r\n 混排、autocrlf 半转换形）：两形行均正确解析。
    var mixed = try parse(gpa, "$code = te\n" ++
        "[keywords]\r\n" ++
        "常数 = const\r\n" ++
        "变量 = var\n");
    defer mixed.deinit();
    try std.testing.expectEqualStrings("const", mixed.keywords.get("常数").?);
    try std.testing.expectEqualStrings("var", mixed.keywords.get("变量").?);
}
