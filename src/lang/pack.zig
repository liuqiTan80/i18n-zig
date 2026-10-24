//! 语言包：极简行式 `键 = 值` 数据格式（刻意不用 TOML，避免引第三方依赖）。
//!
//! 文件格式：
//!   - `#` 或 `//` 开头为注释行；空行跳过
//!   - `[段名]` 切换当前段：keywords / aliases / diagnostics / whitelist / docs
//!   - `键 = 值`：键值均去除首尾空白；值保留内部空白；**空值一律拒绝**（D30：空值会被转译端
//!     把词元抹成空串／绕过 `$code` 校验／使空 pattern 吞掉全部诊断；唯 diagnostics 第三段 tip 可空）
//!   - diagnostics 段的值以 `|` 分隔三段：`匹配前缀|译文模板|教学提示`
//!   - docs 段：`方言链键 = 大白话用法`，供 LSP 悬停「怎么用」教学（键须同现于 aliases/keywords，
//!     否则悬停永不命中=死词条）；值是人读自由文本（可含 `.`/空格/反引号，首个 `=` 后整段为值），不受
//!     aliases 段的「纯非 ASCII 键 / 段数镜像」契约约束（该契约只管转译可达性，docs 只供人读）
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

const zzc_paths = @import("../zzc_paths.zig"); // 第 238 轮 D106：测试内嵌内置默认包文件名取 hub 单源真值

pub const Pack = @This();

pub const Entry = struct {
    pattern: []const u8,
    message: []const u8,
    tip: []const u8,
};

/// 当前工具支持的对外包格式版本（R9g）：行式格式自第三方独立发行起升格为**对外契约**，
/// 包内 `$format` 声明高于此值必须明确拒绝（旧包无 `$format` 行、缺省视为 1，永不破坏已流通的包）。
pub const supported_format: u32 = 1;

/// 第 242 轮 D110：R9g 语言包对外契约词法的**单一真值**——元数据键三枚 + 未设哨兵两枚。
/// 这五枚是「解析器读的 token」与「报错文案告诉包作者去写的 token」必须恒等的对外契约；
/// 旧形制下 main.describePackError/loadExternalPack 的用户可见指引把 `$code`/`??`/`$format`
/// 各手抄一份，与本源解析器分支（下方 meta_* 比较）互不交叉、全库无锚（P1 探针：改指引 token
/// 且同步其自照测 189 T1 → fresh 626•626 全绿，二进制却对真实用户虚报解析器根本不认的 token）。
/// 解析器分支、字段缺省、validate 三处内部用一并委派本组常量；main 指引 comptime 拼接引用；
/// 242 T0/T1 双向钉住「解析器认的 == 指引写的」。
pub const meta_format = "$format"; // 包格式版本头键（R9g）
pub const meta_name = "$name"; // 展示名键
pub const meta_code = "$code"; // 语言代码键
pub const unset_code = "??"; // 代码未设哨兵：validate 首关即查此值
pub const unset_name = "未知语言"; // 展示名未设缺省

/// Zig 规范名反查键单源（第 243 轮 D111）：同一批 ASCII 规范名此前在四处各自内联字面量——
/// `contract_values` 清单、`buildInitTemplate` 模板组词键与 `orelse` 兜底、main staging 的
/// const/@import 词形、transpiler 的导入判定。任一处漂移即静默产碎码（t2 探针坐实 `@import`→
/// `@impxrt` 全库 629/629 绿而 `zzc check` 拒自家 init 产物）。收编为命名常量后四处结构上不可分道。
/// 只收编**跨模块**手抄的六枚；`pub`/`std`/`void`/`i64`/`std.debug`/`std.debug.print` 仅 buildInitTemplate
/// 单模块内联、非跨模块手抄，不在本族（D111 面界）。
pub const zig_const = "const"; // 声明半：撞词避让 / const 单跳数据流（D3）
pub const zig_var = "var";
pub const zig_fn = "fn"; // `主函数`→main 入口链与声明位识别
pub const zig_import = "@import"; // 导入词形预扫描（D2/D4）+ init 模板 + 入口链
pub const zig_embed_file = "@embedFile"; // 嵌入词形预扫描与资产 staging（D2/D3）
pub const zig_main = "main"; // 语义编译根判据（含 main 的文件）

name: []const u8 = unset_name,
code: []const u8 = unset_code,
keywords: std.StringHashMap([]const u8),
aliases: std.StringHashMap([]const u8),
/// `[docs]` 段：方言链键 → 大白话用法说明，供 LSP 悬停展示「怎么用」。键值均借 `bytes`（内嵌资源
/// 视图）、非本包拥有，故 deinit 只释表底衬。与 aliases/keywords 分集、不参与转译，仅供人读。
docs: std.StringHashMap([]const u8),
diagnostics: std.ArrayList(Entry),
/// `[whitelist]` 段：允许保留的英文 token（整行精确匹配）。归属语言包而非工具硬编码（F2）。
whitelist: std.ArrayList([]const u8),

/// 契约值清单（台账 B6）：工具链在多处按“映射值”反查方言词形（`keywordFormsFor`：
/// `const`/`@embedFile`/`@import` 的预扫描豁免与 staging、`pub fn main` 入口探测），
/// 任何方言包若缺这些映射会在流程深处静默失能；在 parse 后立即校验、母语报错。
/// 清单只含 ASCII 值、不硬编码任何方言词（语言无关原则）。
pub const contract_values = [_][]const u8{
    zig_const, // 声明半：撞词避让 / const 单跳数据流（D3）
    zig_var,
    zig_fn, // `主函数`→main 入口链与声明位识别
    "if",
    "else",
    "return",
    "struct",
    "enum",
    "union",
    "switch",
    zig_import, // 导入词形预扫描（D2/D4）
    zig_embed_file, // 嵌入词形预扫描与资产 staging（D2/D3）
    zig_main, // 语义编译根判据（含 main 的文件）
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
    if (std.mem.eql(u8, self.code, unset_code)) return error.PackMissingCode;
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
        .docs = std.StringHashMap([]const u8).init(gpa),
        .diagnostics = .empty,
        .whitelist = .empty,
    };
}

pub fn deinit(self: *Pack) void {
    const gpa = self.keywords.allocator;
    self.keywords.deinit();
    self.aliases.deinit();
    self.docs.deinit();
    self.diagnostics.deinit(gpa);
    for (self.whitelist.items) |rule| gpa.free(rule);
    self.whitelist.deinit(gpa);
}

const Section = enum { keywords, aliases, diagnostics, whitelist, docs };

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
    // 本次调用内「已写键→值」索引，供同层冲突检测：以 StringHashMap（与本 Pack 的
    // keywords/aliases/docs 同族）取代早前 ArrayList 逐行线性扫，把查重由 O(N²) 降为 O(N)。
    // 键/值皆借 `bytes` 视图、仅调用期内比对；map 尾 defer 释底衬，不涉所有权移交。
    const DiagSeen = struct { message: []const u8, tip: []const u8 };
    var seen_kw: std.StringHashMap([]const u8) = .init(gpa);
    defer seen_kw.deinit();
    var seen_al: std.StringHashMap([]const u8) = .init(gpa);
    defer seen_al.deinit();
    var seen_diag: std.StringHashMap(DiagSeen) = .init(gpa);
    defer seen_diag.deinit();
    var seen_docs: std.StringHashMap([]const u8) = .init(gpa);
    defer seen_docs.deinit();
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
                if (std.mem.eql(u8, key, meta_format)) {
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
                if (std.mem.eql(u8, key, meta_name)) {
                    // 同层元数据矛盾两行（$name/$code 不同值）同族封口；同值幂等照放。
                    if (seen_name) |old| {
                        if (!std.mem.eql(u8, old, value)) return error.InvalidLangPack;
                    }
                    seen_name = value;
                    self.name = value;
                    continue;
                }
                if (std.mem.eql(u8, key, meta_code)) {
                    if (seen_code) |old| {
                        if (!std.mem.eql(u8, old, value)) return error.InvalidLangPack;
                    }
                    seen_code = value;
                    self.code = value;
                    continue;
                }
                // 同层同键异值 → 拒；同值 → 幂等放行（不新增拒绝面）。
                const seen = if (section == .keywords) &seen_kw else &seen_al;
                if (seen.get(key)) |old| {
                    if (!std.mem.eql(u8, old, value)) return error.InvalidLangPack;
                } else try seen.put(key, value);
                try map.put(key, value);
            },
            .docs => {
                // 方言链键 = 大白话用法（供 hover 展示「怎么用」）。键非空、值非空（空值无教学信息、
                // D30 同族拒）；值取首个 `=` 后整段（仅去首尾空白、保留内部空格与后续 `=`），比 aliases 宽松——
                // docs 只供人读、不参与转译，不受别名「纯非 ASCII 键 / 段数镜像」契约约束。
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLangPack;
                const key = std.mem.trim(u8, line[0..eq], " \t");
                const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
                if (key.len == 0 or value.len == 0) return error.InvalidLangPack;
                // 同层同键异值 → 拒（手编矛盾两行静默其一失效属数据陷阱，与 keywords/aliases 对称）；同值幂等放行。
                if (seen_docs.get(key)) |old| {
                    if (!std.mem.eql(u8, old, value)) return error.InvalidLangPack;
                } else try seen_docs.put(key, value);
                try self.docs.put(key, value);
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
                if (seen_diag.getPtr(pattern)) |old| {
                    if (!std.mem.eql(u8, old.message, message) or !std.mem.eql(u8, old.tip, tip))
                        return error.InvalidLangPack;
                } else try seen_diag.put(pattern, .{ .message = message, .tip = tip });
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
    return keywordFormsFor(gpa, lang, zig_embed_file);
}

// ==================== 第 294 轮 D153：对照表 ↔ 包内映射的两侧手抄（判据面）====================
//
// `docs/关键字对照表.md` 是包内 `[keywords]`／`[aliases]` 两段的**第二份手抄**，而包自己的报错文案
// （`未知标识符` 诊断的第三段提示语）正把用户指向该表——母语关键字拼错的人照表核对，表若过期即核对到
// 根本不存在的词。旧形制全库零锚：探针 P1 实锤在真表上同时注入三形（值漂 `const`→`konst`、删掉整行
// `如果 / 否则`、凭空加鬼词 `假键`），`zig fmt`／`zig build test`（17/17 succeeded）／
// `zig build check-machine-matcher` 三门禁一律零信号、退码皆 0。
//
// 治法分两段（沿用 203/210/292 轮形制）：**判据**入本模块（纯函数、零 I/O，可被小样直调），
// **跨文件覆盖**入 `check-machine-matcher` 的对面三十——表与包皆以 `addFileArg` 声明为文件依赖
// （表在 `docs/`、越出模块包路径，`@embedFile` 不可达：202 轮硬约束判例；测试内 `cwd()` 偷读又不入
// 步骤清单＝假绿形制），故只有声明了依赖的守卫步能改一面即转红。
//
// 路径与域路由一律单源：表文件名由 `kwtable_ref` 派生（文案词干与文件名不再各写一份）、
// 「哪一域比对哪一段」由 `kwtable_alias_heading` 一处声明；抽取器只认 hub 声明的形制，
// 形制漂成 0 行由**独立手设**下限拦（不可从 doc 反抽回填，否则即空转伪锚，同 240/292/293 轮判例）。

/// 报错文案里指向对照表的**路径词干**单源（包内诊断提示语写的就是它，`kwtable_pack_face` 逐字节核）。
pub const kwtable_ref: []const u8 = "docs/关键字对照表";

/// 对照表的仓根相对路径——由词干派生，全仓第二处手抄自此不存在。
pub const kwtable_path: []const u8 = kwtable_ref ++ ".md";

/// 域路由标记：markdown 中含此串的 `## ` 二级标题之下，表格行比对 `[aliases]` 段；其余各域比对
/// `[keywords]` 段。一张表两个域，路由判据必须单源（守卫里另写一份即分道）。
pub const kwtable_alias_heading: []const u8 = "标准库路径别名";

/// 对照表 `[aliases] 域应列出的最少行数——**独立手设**下限（真值现为 127，本轮探针实测）。
/// 下限只管一件事：抽取器/路由形制漂成 0 行时不许一路静默。
pub const kwtable_alias_floor: usize = 127;

/// 一次对面核对项（needle／后果／应现枚数）：与 `lang_identity`／`jsonrpc`／`vsix` 三 hub 同形制，
/// `machine_matcher.checkFace` 以 `@hasField` 兼容，不另立第四套搜索逻辑。
pub const FaceCheck = struct { needle: []const u8, why: []const u8, occ: usize = 1 };

/// 对面三十·`build.zig` 侧命名针：对照表须以 `addFileArg(b.path("<kwtable_path>"))` 声明为守卫的
/// 文件依赖——不声明则改表不触发守卫重跑（203/210/238 轮同族假绿形制）。needle 由 hub 路径派生。
pub const kwtable_build_face = [_]FaceCheck{
    .{
        .needle = "addFileArg(b.path(\"" ++ kwtable_path ++ "\"))",
        .why = "对照表输入路径须由 hub 的 kwtable_path 派生并与 build.zig 的 addFileArg 同源——分道即守卫吃旧文件名，改表不触发重跑（表侧恒绿静默）",
    },
};

/// 对面三十·包侧指针针：报错文案指向本表，故文案里的路径词干须等于 hub 真值。
pub const kwtable_pack_face = [_]FaceCheck{
    .{
        .needle = kwtable_ref,
        .why = "内置默认包的 `未知标识符` 提示语须以 hub 词干指向对照表——分道即报错把用户指向不存在的文件（指路文案与真表失联）",
    },
};

/// markdown 抽出的一枚对照关系：母语名 → ASCII 值，并带该行所属域（`true` 即 `[aliases]` 段）。
pub const KwRow = struct {
    name: []const u8,
    value: []const u8,
    alias_domain: bool,
};

/// 值列须是**恰好一对**反引号包裹的代码形（`` `const` `` → `const`）；无反引号、只有一枚、或内部
/// 还含反引号者皆判「非映射列」返 null（表头行、分隔行、152 轮那张 5 列注表由此自然出局）。
fn kwBacktick(cell: []const u8) ?[]const u8 {
    if (cell.len < 3 or cell[0] != '`' or cell[cell.len - 1] != '`') return null;
    const inner = cell[1 .. cell.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '`') != null) return null;
    return inner;
}

/// 遍历对照表的每一枚 `母语名 → ASCII 值`：`## ` 换域（域标题含 `kwtable_alias_heading` 者归
/// `[aliases]`），`#`/`###` 等其它标题**继承**当前域；一行的两对单元格（1-2 列、3-4 列）各出对，
/// 名列容 `甲 / 乙` 同义并列（逐枚出对，故 `变量 / 让` 出两枚）；非四列行整行跳过。
/// `cb` 取 comptime：与 `eachLine` 族同形制，零堆分配、零闭包捕获。
pub fn eachKwRow(
    doc: []const u8,
    comptime cb: fn (ctx: *anyopaque, row: KwRow) void,
    ctx: *anyopaque,
) void {
    var alias_domain = false;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r"); // 行尾 CR（CRLF 表亦可扫）
        if (std.mem.startsWith(u8, line, "## ")) {
            alias_domain = std.mem.indexOf(u8, line, kwtable_alias_heading) != null;
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue; // 其它级标题：继承当前域
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] != '|') continue;
        const inner = std.mem.trim(u8, t, "|");
        var cells: [4][]const u8 = .{ "", "", "", "" };
        var n: usize = 0;
        var wide = false; // 多于四列的行不属映射表（152 轮注表即此形）
        var cit = std.mem.splitScalar(u8, inner, '|');
        while (cit.next()) |c| {
            const cell = std.mem.trim(u8, c, " \t");
            if (n < 4) {
                cells[n] = cell;
                n += 1;
            } else if (cell.len != 0) wide = true;
        }
        if (wide or n != 4) continue;
        for ([_][]const u8{ cells[0], cells[2] }, [_][]const u8{ cells[1], cells[3] }) |name_cell, value_cell| {
            const value = kwBacktick(value_cell) orelse continue;
            var names = std.mem.splitScalar(u8, name_cell, '/');
            while (names.next()) |nm| {
                const name = std.mem.trim(u8, nm, " \t");
                if (name.len == 0) continue;
                cb(ctx, .{ .name = name, .value = value, .alias_domain = alias_domain });
            }
        }
    }
}

/// 对照表 ↔ 包映射的双向对拍结果（计数 + 每类首个 offender，供守卫把漂形**指名**打印）。
pub const KwAudit = struct {
    kw_rows: usize = 0,
    alias_rows: usize = 0,
    ghost: usize = 0,
    wrong: usize = 0,
    hidden: usize = 0,
    unpaired: usize = 0, // 仅书稿侧有意义：值枚数与名枚数配不上的槽位数
    heading_hit: bool = false,
    first_ghost: []const u8 = "",
    first_wrong: []const u8 = "",
    first_wrong_doc: []const u8 = "",
    first_wrong_pack: []const u8 = "",
    first_hidden: []const u8 = "",
};

const KwRowCtx = struct { pack: *const Pack, a: KwAudit };

fn auditRowCb(ctx: *anyopaque, row: KwRow) void {
    const cx: *KwRowCtx = @ptrCast(@alignCast(ctx));
    if (row.alias_domain) cx.a.alias_rows += 1 else cx.a.kw_rows += 1;
    const table = if (row.alias_domain) &cx.pack.aliases else &cx.pack.keywords;
    const have = table.get(row.name) orelse {
        cx.a.ghost += 1;
        if (cx.a.first_ghost.len == 0) cx.a.first_ghost = row.name;
        return;
    };
    if (!std.mem.eql(u8, have, row.value)) {
        cx.a.wrong += 1;
        if (cx.a.first_wrong.len == 0) {
            cx.a.first_wrong = row.name;
            cx.a.first_wrong_doc = row.value;
            cx.a.first_wrong_pack = have;
        }
    }
}

const HideCtx = struct { want: []const u8, hit: bool = false };

fn hideRowCb(ctx: *anyopaque, row: KwRow) void {
    const hc: *HideCtx = @ptrCast(@alignCast(ctx));
    if (!hc.hit and !row.alias_domain and std.mem.eql(u8, row.name, hc.want)) hc.hit = true;
}

/// 判据本体（纯、零 I/O）：正向逐枚查「表里有而包内无（ghost）／同名而值漂（wrong）」，
/// 反向逐枚查「包内 `[keywords]` 有而表全不见（hidden）」。`[aliases]` 侧**只做正向**——表对该段
/// 是有意精选（头注已册「低频者可用逐段回退 `标准库.<英文>`」），反向即把设计选择判成缺陷（伪锚）。
pub fn auditKwTable(pack: *const Pack, doc: []const u8) KwAudit {
    var cx = KwRowCtx{
        .pack = pack,
        .a = .{ .heading_hit = std.mem.indexOf(u8, doc, kwtable_alias_heading) != null },
    };
    eachKwRow(doc, auditRowCb, @ptrCast(&cx));
    var it = pack.keywords.iterator();
    while (it.next()) |e| {
        var hc = HideCtx{ .want = e.key_ptr.* };
        eachKwRow(doc, hideRowCb, @ptrCast(&hc));
        if (!hc.hit) {
            cx.a.hidden += 1;
            if (cx.a.first_hidden.len == 0) cx.a.first_hidden = e.key_ptr.*;
        }
    }
    return cx.a;
}

// ── D154（第 295 轮）：书稿《字典篇》＝包映射面的**第三份手抄**，判据与 294 轮同制 ──────────
// 《字典篇》头注自称「想知道某个中文词……在这里按主题查」，故它对 `[keywords]` 是**全量**承诺
// （漏一枚即读者按自己的书查无此词）；`[aliases]` 段则系有意精选（尾注引对照表看全量），只做正向。
// 区段起止、路径、下限一律 hub 单源。书在 `docs/` 越出模块包路径不可 `@embedFile`（202 轮判例），
// 覆盖只能走 build.zig 的 addFileArg ＋ 守卫读文件（同 294 轮形制）。

/// 书稿的仓根相对路径：守卫的 addFileArg needle 由此派生，改文件名不留第二处手抄。
pub const book_path: []const u8 = "docs/母语编写zig-中文版.md";

/// 区段起点：**一级标题**（`# ` 行）中含此串者才开区——正文交叉引用（`### …（详见《字典篇》）`）
/// 不得开区，否则各章示例表全被当映射面对拍。
pub const bookdict_heading: []const u8 = "《字典篇》";

/// 区段终点：首个以此串开头的 `## ` 标题即出区——附录 A/B 的表是「坑」与「术语」，非映射表。
pub const bookdict_stop_heading: []const u8 = "附录";

/// 全量承诺的下限（**独立手设**，真值现为 113＝内置包 `[keywords]` 枚数）：专拦「抽取器或区段
/// 形制漂成 0 行、却仍自称与包零漂」的空转假绿（同 240/292/293/294 轮判例，不可从书稿反抽回填）。
pub const bookdict_kw_floor: usize = 113;

/// `aliases` 域下限（**独立手设**，真值现为 11）：该段只做正向对拍，此针只防整段被删空。
pub const bookdict_alias_floor: usize = 11;

/// 对面三十一·`build.zig` 侧命名针：书稿须以 `addFileArg(b.path("<book_path>"))` 声明为文件依赖
/// ——不声明即改书不触发守卫重跑（203/210/238 轮同族假绿形制）。
pub const bookdict_build_face = [_]FaceCheck{
    .{
        .needle = "addFileArg(b.path(\"" ++ book_path ++ "\"))",
        .why = "书稿输入路径须由 hub 的 book_path 派生并与 build.zig 的 addFileArg 同源——分道即守卫吃旧文件名，改书不触发重跑（书侧恒绿静默）",
    },
};

/// 对面三十一·书稿侧指针针：书稿共**五处**指向全量对照表（第 555/1135/1325/1428/1475 行），
/// 逐处皆须写 hub 词干——`occ=5` 即把「五处指路」本身也钉住：改指他处或漏写一处即转红
/// （新加第六处指路需同步上抬此枚数，属有意识改动而非静默漂）。演漂形⑥实锤：`occ=1` 时
/// 改掉其中一处仍一路绿，因余下四处同词——针的强度必须匹配手抄的真实份数。
pub const bookdict_book_face = [_]FaceCheck{
    .{
        .needle = kwtable_ref,
        .occ = 5,
        .why = "书稿五处指路皆须以 hub 词干指向对照表——分道即书把读者指向不存在的文件，「本篇已列全」的声明也就失去可核对的落点",
    },
};

/// 值格须**整体由反引号片段构成**，片段之间只容空白、`/`、「、」；逐枚填入 `out` 并返枚数。
/// 返 0 即「此格非映射值」——表头行、分隔行、大白话说明、八章符号行由此自然出局；反引号不成对、
/// 片段为空、枚数越上限亦返 0（宁可不抽：漏抽不静默，由 hidden 全量承诺与下限针转响）。
fn btTokens(cell: []const u8, out: *[4][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < cell.len) {
        const rest = cell[i..];
        if (rest[0] == ' ' or rest[0] == '\t' or rest[0] == '/') {
            i += 1;
            continue;
        }
        if (rest.len >= 3 and std.mem.eql(u8, rest[0..3], "、")) {
            i += 3;
            continue;
        }
        if (rest[0] != '`') return 0;
        const end = std.mem.indexOfScalar(u8, rest[1..], '`') orelse return 0;
        if (end == 0 or n >= out.len) return 0;
        out[n] = rest[1 .. 1 + end];
        n += 1;
        i += end + 2;
    }
    return n;
}

/// 遍历《字典篇》的每一枚 `母语名 → ASCII 值`（沿用上文的 `KwRow`，两侧判据共用同一套回调）。
/// 与对照表三处形制差：①只认 `bookdict_heading` → `bookdict_stop_heading` 区段内的行；②名列含
/// 反引号者整槽出局（八章「保留符号」那类讲符号的行不当它是键）；③行格满 6 列者系「一行两对」
/// 排版（六章 `@` 族两栏并排），除 0-1 列外再取 3-4 列。名列容 `甲 / 乙` 并列：值仅一枚即广播给
/// 各名，否则枚数须相等——配不出对的行**不静默出局**，计入返回值由审计侧当 FAIL 拦。
pub fn eachBookRow(
    book: []const u8,
    comptime cb: fn (ctx: *anyopaque, row: KwRow) void,
    ctx: *anyopaque,
) usize {
    var odd: usize = 0;
    var in_region = false;
    var alias_domain = false;
    var lines = std.mem.splitScalar(u8, book, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r"); // 行尾 CR（CRLF 书稿亦可扫）
        if (line.len > 0 and line[0] == '#') {
            // 起点只认**一级标题**行：正文里的 `### 3.2 常用类型速查（详见《字典篇》）` 也含篇名，
            // 若任其开区则整本书的示例表都成了手抄面（第 295 轮本闸首跑即抓到此形）。
            if (std.mem.startsWith(u8, line, "# ") and std.mem.indexOf(u8, line, bookdict_heading) != null) {
                in_region = true;
                alias_domain = false;
            } else if (in_region and std.mem.startsWith(u8, std.mem.trim(u8, line, "# "), bookdict_stop_heading)) {
                in_region = false; // 附录起，后表皆非映射表
            } else if (in_region and std.mem.startsWith(u8, line, "## ")) {
                alias_domain = std.mem.indexOf(u8, line, kwtable_alias_heading) != null; // 域标记与 294 轮同源
            }
            continue;
        }
        if (!in_region) continue;
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] != '|') continue;
        var cells: [6][]const u8 = .{ "", "", "", "", "", "" };
        var n: usize = 0;
        var cit = std.mem.splitScalar(u8, std.mem.trim(u8, t, "|"), '|');
        while (cit.next()) |c| {
            if (n < cells.len) {
                cells[n] = std.mem.trim(u8, c, " \t");
                n += 1;
            }
        }
        var slot: usize = 0;
        while (slot < 2) : (slot += 1) {
            if (slot == 1 and n < cells.len) break; // 非「一行两对」形，第二槽不看
            var vals: [4][]const u8 = undefined;
            const nv = btTokens(cells[slot * 3 + 1], &vals);
            if (nv == 0) continue; // 值格不是纯反引号词 → 该行非映射行
            const name_cell = cells[slot * 3];
            if (name_cell.len == 0 or std.mem.indexOfScalar(u8, name_cell, '`') != null) continue;
            var names: [4][]const u8 = undefined;
            var nn: usize = 0;
            var nit = std.mem.splitScalar(u8, name_cell, '/');
            while (nit.next()) |nm| {
                const name = std.mem.trim(u8, nm, " \t");
                if (name.len == 0) continue;
                if (nn >= names.len) {
                    nn += 1;
                    continue;
                }
                names[nn] = name;
                nn += 1;
            }
            if (nn == 0 or nn > names.len) {
                odd += 1;
                continue;
            }
            if (nv != nn and nv != 1) {
                odd += 1; // 看着像映射行却配不出对：静默即盲区，转响交守卫
                continue;
            }
            var k: usize = 0;
            while (k < nn) : (k += 1) {
                cb(ctx, .{ .name = names[k], .value = vals[if (nv == 1) 0 else k], .alias_domain = alias_domain });
            }
        }
    }
    return odd;
}

/// 书稿 ↔ 包映射对拍（与 `auditKwTable` 同构：正向 ghost/wrong，反向 hidden 即「全量承诺」）。
/// `unpaired` 为形制异常槽位数；`heading_hit` 为区段起点标记是否命中（书稿改题即在此转红）。
pub fn auditBookDict(pack: *const Pack, book: []const u8) KwAudit {
    var cx = KwRowCtx{
        .pack = pack,
        .a = .{ .heading_hit = std.mem.indexOf(u8, book, bookdict_heading) != null },
    };
    cx.a.unpaired = eachBookRow(book, auditRowCb, @ptrCast(&cx));
    var it = pack.keywords.iterator();
    while (it.next()) |e| {
        var hc = HideCtx{ .want = e.key_ptr.* };
        _ = eachBookRow(book, hideRowCb, @ptrCast(&hc));
        if (!hc.hit) {
            cx.a.hidden += 1;
            if (cx.a.first_hidden.len == 0) cx.a.first_hidden = e.key_ptr.*;
        }
    }
    return cx.a;
}

test "294 T0 对照表↔包映射判据：域路由继承、正反三形漂、抽取器形制边界（合成小样独立于真表）" {
    const gpa = std.testing.allocator;
    const pack_src =
        \\$code = zh
        \\[keywords]
        \\常数 = const
        \\变量 = var
        \\让 = var
        \\[aliases]
        \\标准库.调试.打印 = std.debug.print
        \\标准库.内存.拷贝 = std.mem.copyForwards
    ;
    var pack = try parse(gpa, pack_src);
    defer pack.deinit();

    // 正形：keywords 域三枚名（`变量 / 让` 出两枚）＋ aliases 域两枚，四类计数与三形漂移皆零。
    const ok_doc =
        \\# 中文关键字对照表
        \\
        \\## 声明与函数
        \\
        \\| 中文 | 标准 Zig | 中文 | 标准 Zig |
        \\|---|---|---|---|
        \\| 常数 | `const` | 变量 / 让 | `var` |
        \\
        \\### 子节继承父域
        \\
        \\| Zig 词 | 在关键字表 | ast-check | build-obj | 处置 |
        \\|---|---|---|---|---|
        \\| `test` / `packed` | ✅ | 绿 | 绿 | 152 轮补登 |
        \\
        \\## 标准库路径别名（点分链贪心最长匹配）
        \\
        \\| 中文 | 标准 Zig | 中文 | 标准 Zig |
        \\|---|---|---|---|
        \\| 标准库.调试.打印 | `std.debug.print` | 标准库.内存.拷贝 | `std.mem.copyForwards` |
    ;
    const a0 = auditKwTable(&pack, ok_doc);
    try std.testing.expectEqual(@as(usize, 3), a0.kw_rows);
    try std.testing.expectEqual(@as(usize, 2), a0.alias_rows);
    try std.testing.expect(a0.heading_hit);
    try std.testing.expectEqual(@as(usize, 0), a0.ghost);
    try std.testing.expectEqual(@as(usize, 0), a0.wrong);
    try std.testing.expectEqual(@as(usize, 0), a0.hidden);

    // 漂形一（值漂）：表把 `const` 写成 `konst` → wrong 恰 1，且指名到名与两侧值。
    const w_doc =
        \\## 声明与函数
        \\| 常数 | `konst` | 变量 / 让 | `var` |
    ;
    const a1 = auditKwTable(&pack, w_doc);
    try std.testing.expectEqual(@as(usize, 1), a1.wrong);
    try std.testing.expectEqualStrings("常数", a1.first_wrong);
    try std.testing.expectEqualStrings("konst", a1.first_wrong_doc);
    try std.testing.expectEqualStrings("const", a1.first_wrong_pack);
    try std.testing.expectEqual(@as(usize, 0), a1.ghost);

    // 漂形二（表删行）：整行不见 → 包内该名的 hidden 恰 1（这是「照表核对却查无此词」的反侧）。
    const d_doc =
        \\## 声明与函数
        \\| 变量 / 让 | `var` |  |  |
    ;
    const a2 = auditKwTable(&pack, d_doc);
    try std.testing.expectEqual(@as(usize, 1), a2.hidden);
    try std.testing.expectEqualStrings("常数", a2.first_hidden);
    try std.testing.expectEqual(@as(usize, 0), a2.ghost);
    try std.testing.expectEqual(@as(usize, 0), a2.wrong);

    // 漂形三（鬼词）：表里凭空多一枚包内不存在的键 → ghost 恰 1。
    const g_doc =
        \\## 声明与函数
        \\| 常数 | `const` | 假键 | `fn` |
        \\| 变量 / 让 | `var` |  |  |
    ;
    const a3 = auditKwTable(&pack, g_doc);
    try std.testing.expectEqual(@as(usize, 1), a3.ghost);
    try std.testing.expectEqualStrings("假键", a3.first_ghost);

    // 形制边界一（域路由漂）：把 aliases 段的标题改名，那些行即落进 keywords 域——alias_rows 归 0、
    // ghost 起（演漂④在测面的对应形；真表侧另有 heading_hit 与 kwtable_alias_floor 两道）。
    const r_doc =
        \\## 声明与函数
        \\| 常数 | `const` | 变量 / 让 | `var` |
        \\## 标准库别名表（标题被改，路由判据不再命中）
        \\| 标准库.调试.打印 | `std.debug.print` | 标准库.内存.拷贝 | `std.mem.copyForwards` |
    ;
    const a4 = auditKwTable(&pack, r_doc);
    try std.testing.expect(!a4.heading_hit);
    try std.testing.expectEqual(@as(usize, 0), a4.alias_rows);
    try std.testing.expectEqual(@as(usize, 2), a4.ghost);

    // 形制边界二（抽取器出局形）：表头行／分隔行／值列不带反引号／列数不足或超出／普通段落**皆不出
    // 对**（全零）——若这些形被误抽，判据就不可能在真表上保持零漂。
    var nb: usize = 0;
    eachKwRow(
        \\## 声明与函数
        \\| 中文 | 标准 Zig | 中文 | 标准 Zig |
        \\|---|---|---|---|
        \\| 常数 | const |  |  |
        \\| 变量 | `var` |  |
        \\| a | b | c | d | e |
        \\普通段落不成行
    ,
        struct {
            fn cb(ctx: *anyopaque, row: KwRow) void {
                _ = row;
                const p: *usize = @ptrCast(@alignCast(ctx));
                p.* += 1;
            }
        }.cb,
        @ptrCast(&nb),
    );
    try std.testing.expectEqual(@as(usize, 0), nb); // 六行全出局：4 列但值无反引号、3 列、5 列、段落行

    // 下限值钉：`kwtable_alias_floor` 系独立手设，不可从 doc 反抽——此处以字面量锁死。
    try std.testing.expectEqual(@as(usize, 127), kwtable_alias_floor);
}

test "294 T1 对照表路径族单源与真包指路文案：词干/路径/域标记值钉 + 内置包文案确含词干" {
    // 值钉（判据独立于被校文本，同 240/292/293 轮形制）：三枚字面量漂任一即红。
    try std.testing.expectEqualStrings("docs/关键字对照表", kwtable_ref);
    try std.testing.expectEqualStrings("docs/关键字对照表.md", kwtable_path);
    try std.testing.expectEqualStrings("标准库路径别名", kwtable_alias_heading);
    try std.testing.expectEqualStrings("docs/关键字对照表.md", kwtable_ref ++ ".md"); // 派生式与手写形同值

    // 指路文案：内置默认包的 `未知标识符` 提示语必须真的指向本表——包是 source dep，
    // 删掉这句即在此转红（守卫面另有 kwtable_pack_face 同针，两侧不可分道）。
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
    try std.testing.expect(std.mem.indexOf(u8, zh, kwtable_ref) != null);
    try std.testing.expect(std.mem.indexOf(u8, zh, "对照表") != null);

    // 面清单形制钉：两面对各 1 枚 needle，且 needle 由 hub 路径/词干派生（非第二处手抄字面量）。
    try std.testing.expectEqual(@as(usize, 1), kwtable_build_face.len);
    try std.testing.expectEqualStrings("addFileArg(b.path(\"" ++ kwtable_path ++ "\"))", kwtable_build_face[0].needle);
    try std.testing.expectEqual(@as(usize, 1), kwtable_pack_face.len);
    try std.testing.expectEqualStrings(kwtable_ref, kwtable_pack_face[0].needle);
}

test "295 T0 字典篇↔包映射判据：区段起止、一行两对、广播与出局形、四形漂＋形制异常（合成小样独立于真书）" {
    const gpa = std.testing.allocator;
    var pack = try parse(gpa,
        \\$code = zh
        \\[keywords]
        \\甲 = a
        \\乙 = b
        \\丙 = b
        \\丁 = d
        \\正弦 = s
        \\余弦 = c
        \\[aliases]
        \\标准库 = std
    );
    defer pack.deinit();

    // 正形：区段外一行不入对；三/四列行、六列「一行两对」、`甲 / 乙` 广播一名值、符号行出局皆中；
    // 附录起的表不入对（末两行若误入即 ghost 非 0）。
    const ok_src =
        \\# 前言
        \\| 甲 | `zzz` | 区段外，不入对 |
        \\### 3.2 常用类型速查（详见《字典篇》）
        \\| 甲 | `nope` | 三级标题不开区，不入对 |
        \\# 《字典篇》——像查字典一样查每个中文词
        \\## 一、声明与函数
        \\| 中文 | 标准 Zig | 大白话/比喻 | 小例 |
        \\|---|---|---|---|
        \\| 甲 | `a` | 说 | `甲;` |
        \\| 乙 / 丙 | `b` | 两名同值 | 进阶 |
        \\| 丁 | `d` | 说 | 进阶 |
        \\| 符号 | 大白话 |
        \\| `;` | 句号：一句话说完 |
        \\## 六、内置函数（`@` 系）
        \\| 中文 | 标准 | 作用 | 中文 | 标准 | 作用 |
        \\|---|---|---|---|---|---|
        \\| 正弦/余弦 | `s`/`c` | 三角 | 丁 | `d` | 重复一枚 |
        \\## 七、标准库路径别名（点分链、贪心最长匹配）
        \\| 中文长名 | 标准 Zig | 常用度 |
        \\|---|---|---|
        \\| 标准库 | `std` | 极高 |
        \\## 附录 A：新手最容易踩的坑
        \\| 甲 | `zzz` | 出区，不入对 |
        \\| 戊 | `e` | 出区，不入对 |
    ;
    const a0 = auditBookDict(&pack, ok_src);
    try std.testing.expect(a0.heading_hit);
    try std.testing.expectEqual(@as(usize, 7), a0.kw_rows);
    try std.testing.expectEqual(@as(usize, 1), a0.alias_rows);
    try std.testing.expectEqual(@as(usize, 0), a0.ghost);
    try std.testing.expectEqual(@as(usize, 0), a0.wrong);
    try std.testing.expectEqual(@as(usize, 0), a0.hidden);
    try std.testing.expectEqual(@as(usize, 0), a0.unpaired);

    // 漂形一（值漂）：书把 `const` 形写作 `z` → wrong 恰 1，指名两侧值。
    const w_src =
        \\# 《字典篇》
        \\## 一、声明与函数
        \\| 甲 | `z` | 说 | 进阶 |
    ;
    const a1 = auditBookDict(&pack, w_src);
    try std.testing.expectEqual(@as(usize, 1), a1.wrong);
    try std.testing.expectEqualStrings("甲", a1.first_wrong);
    try std.testing.expectEqualStrings("z", a1.first_wrong_doc);
    try std.testing.expectEqualStrings("a", a1.first_wrong_pack);

    // 漂形二（书删行）：全量承诺反侧——包内有名而书查无 → hidden 计数并指名（本轮真书即此形，缺 27 枚）。
    const d_src =
        \\# 《字典篇》
        \\## 一、声明与函数
        \\| 乙 / 丙 | `b` | 说 | 进阶 |
    ;
    const a2 = auditBookDict(&pack, d_src);
    try std.testing.expectEqual(@as(usize, 4), a2.hidden);
    try std.testing.expect(std.mem.indexOf(u8, "甲丁正弦余弦", a2.first_hidden) != null); // 名必属缺席集；hash 序不锁（锁序即伪钉）
    try std.testing.expectEqual(@as(usize, 0), a2.ghost);
    try std.testing.expectEqual(@as(usize, 0), a2.wrong);

    // 漂形三（鬼词）：书里凭空一枚包内不存在的键 → ghost 恰 1。
    const g_src =
        \\# 《字典篇》
        \\## 一、声明与函数
        \\| 甲 | `a` | 说 | 进阶 |
        \\| 假键 | `fn` | 说 | 进阶 |
    ;
    const a3 = auditBookDict(&pack, g_src);
    try std.testing.expectEqual(@as(usize, 1), a3.ghost);
    try std.testing.expectEqualStrings("假键", a3.first_ghost);

    // 漂形四（区段漂）：篇名改掉，整区不认——hidden 起而抽取器一行不抽（下限针即为此设）。
    const r_src =
        \\# 词汇表（篇名已改）
        \\## 一、声明与函数
        \\| 甲 | `a` | 说 | 进阶 |
    ;
    const a4 = auditBookDict(&pack, r_src);
    try std.testing.expect(!a4.heading_hit);
    try std.testing.expectEqual(@as(usize, 0), a4.kw_rows);
    try std.testing.expectEqual(@as(usize, 6), a4.hidden);

    // 形制异常：值枚数与名枚数不等且非「一值广播」→ 不静默出局，转 unpaired 由守卫拦。
    const u_src =
        \\# 《字典篇》
        \\## 六、内置函数
        \\| 甲 | `a` `b` `c` | 三角 | 乙 | `b` | 说 |
    ;
    const a5 = auditBookDict(&pack, u_src);
    try std.testing.expectEqual(@as(usize, 1), a5.unpaired);
    try std.testing.expectEqual(@as(usize, 1), a5.kw_rows);

    // 出局形复钉：表头行／分隔行／值格无反引号／名格带反引号／区段外 一律不出对。
    var nb: usize = 0;
    _ = eachBookRow(
        \\# 《字典篇》
        \\## 三、错误与可选
        \\| 中文 | 标准 Zig | 意思 |
        \\|---|---|---|
        \\| 甲 | a | 值格无反引号 |
        \\| `?` | `x` | 名格带反引号
        \\正文一句 `甲`
    ,
        struct {
            fn cb(ctx: *anyopaque, row: KwRow) void {
                _ = row;
                const p: *usize = @ptrCast(@alignCast(ctx));
                p.* += 1;
            }
        }.cb,
        @ptrCast(&nb),
    );
    try std.testing.expectEqual(@as(usize, 0), nb);

    // 下限值钉：两枚皆**独立手设**，不可从书稿反抽回填——此处以字面量锁死。
    try std.testing.expectEqual(@as(usize, 113), bookdict_kw_floor);
    try std.testing.expectEqual(@as(usize, 11), bookdict_alias_floor);
}

test "295 T1 书稿路径族与两面对单源：路径/区段标记值钉 + needle 派生式等值钉" {
    try std.testing.expectEqualStrings("docs/母语编写zig-中文版.md", book_path);
    try std.testing.expectEqualStrings("《字典篇》", bookdict_heading);
    try std.testing.expectEqualStrings("附录", bookdict_stop_heading);
    // 书与对照表同栖 docs/，且书侧指路针必须复用 294 轮的词干（另写一份即第四处手抄）。
    try std.testing.expect(std.mem.startsWith(u8, book_path, "docs/"));
    try std.testing.expectEqualStrings(kwtable_ref, bookdict_book_face[0].needle);

    // 面清单形制钉：两面对各 1 枚 needle，build 侧 needle 由 hub 路径派生。
    try std.testing.expectEqual(@as(usize, 1), bookdict_build_face.len);
    try std.testing.expectEqualStrings("addFileArg(b.path(\"" ++ book_path ++ "\"))", bookdict_build_face[0].needle);
    try std.testing.expectEqual(@as(usize, 1), bookdict_book_face.len);
    // 指路枚数钉：书稿对对照表的指路实为五处（演漂形⑥），逐处皆须同词干。
    try std.testing.expectEqual(@as(usize, 5), bookdict_book_face[0].occ);
}

test "firstKeywordFor（第 142 轮模板按包组词的地基）：keywords 优先、aliases 兼容多段链键、未命中 null" {
    const gpa = std.testing.allocator;
    var lang = try parse(gpa, @embedFile(zzc_paths.builtin_pack_embed_lang));
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

test "第 243 轮 T0 Zig 规范名反查键单源锈（D111）：值钉 + contract_values 一致性 + 真包反查对齐" {
    const gpa = std.testing.allocator;
    // A1 值钉：六枚命名常量逐字节 == 原内联字面量（收编不得改值，行为等价的前提）。
    try std.testing.expectEqualStrings("const", zig_const);
    try std.testing.expectEqualStrings("var", zig_var);
    try std.testing.expectEqualStrings("fn", zig_fn);
    try std.testing.expectEqualStrings("@import", zig_import);
    try std.testing.expectEqualStrings("@embedFile", zig_embed_file);
    try std.testing.expectEqualStrings("main", zig_main);
    // A2 一致性钉：contract_values 必含这六枚（单源后清单与常量不可分道：任一处漂即本钉红）。
    for ([_][]const u8{ zig_const, zig_var, zig_fn, zig_import, zig_embed_file, zig_main }) |k| {
        var found = false;
        for (contract_values) |want| {
            if (std.mem.eql(u8, want, k)) found = true;
        }
        try std.testing.expect(found); // 若清单退回手抄字面量而常量另漂，此钉翻红
    }
    // A3 真包对齐钉：中文包确有词映射到 zig_import 的规范名（常量值与包数据逐字节同，
    //   否则 buildInitTemplate 以本常量作反查键会落 null → 降级碎码）。
    var lang = try parse(gpa, @embedFile(zzc_paths.builtin_pack_embed_lang));
    defer lang.deinit();
    try std.testing.expectEqualStrings("导入", lang.firstKeywordFor(zig_import).?);
    // A4 反证防恒真：若把反查键换为碎名（如 @impxrt）真包必无映射 → null（坐实 A3 非绿于任意键）。
    try std.testing.expectEqual(@as(?[]const u8, null), lang.firstKeywordFor("@impxrt"));
}

test "keywordFormsFor/embedWordForms（第 61 轮下沉真测）：ASCII 直通形居首 + 真实 zh 包方言词形被枚举" {
    const gpa = std.testing.allocator;
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
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
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
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
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
    var p = try parse(gpa, zh);
    defer p.deinit();

    var it = p.aliases.iterator();
    while (it.next()) |e| {
        const k = std.mem.count(u8, e.key_ptr.*, ".") + 1;
        const v = std.mem.count(u8, e.value_ptr.*, ".") + 1;
        try std.testing.expectEqual(k, v);
    }
}

test "docs 段解析（悬停「怎么用」）：键入表、值为首个 `=` 后整段、空键/空值/同层异值拒" {
    const gpa = std.testing.allocator;
    // 正常：docs 键值入表；值可含 `.`/空格/反引号/后续 `=`（首个 `=` 为分隔）。
    var ok = try parse(gpa,
        \\ [keywords]
        \\ 常数 = const
        \\ [aliases]
        \\ 标准库.调试.打印 = std.debug.print
        \\ [docs]
        \\ 标准库.调试.打印 = 往屏幕打印。示例：`标准库.调试.打印("{d}={d}", .{1, 1});`
    );
    defer ok.deinit();
    try std.testing.expectEqualStrings(
        "往屏幕打印。示例：`标准库.调试.打印(\"{d}={d}\", .{1, 1});`",
        ok.docs.get("标准库.调试.打印").?,
    );

    // 空值拒（D30 同族）。
    try std.testing.expectError(
        error.InvalidLangPack,
        parse(gpa,
            \\ [aliases]
            \\ 标准库.调试 = std.debug
            \\ [docs]
            \\ 标准库.调试 =
        ),
    );
    // 同层同键异值拒；同值幂等放行。
    try std.testing.expectError(
        error.InvalidLangPack,
        parse(gpa,
            \\ [aliases]
            \\ 标准库.调试 = std.debug
            \\ [docs]
            \\ 标准库.调试 = 甲
            \\ 标准库.调试 = 乙
        ),
    );
    var idem = try parse(gpa,
        \\ [aliases]
        \\ 标准库.调试 = std.debug
        \\ [docs]
        \\ 标准库.调试 = 同一句
        \\ 标准库.调试 = 同一句
    );
    defer idem.deinit();
    try std.testing.expectEqualStrings("同一句", idem.docs.get("标准库.调试").?);
}

test "内置中文包 docs 可达性不变量：每条 docs 键必同现于 aliases∪keywords（防悬停死词条）+ 覆盖下限" {
    // hoverAt 取词口径：整链先查 aliases、再退 keywords；docs 只按同一链取回。若某 docs 键两处
    // 皆无，则那段大白话永远不会被悬停命中（写了也白写）——本测把该死词条钓死，任何人
    // 写了链不在译名表里的 docs 即红（同时间接验证文档链与别名链一一对应）。
    const gpa = std.testing.allocator;
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
    var p = try parse(gpa, zh);
    defer p.deinit();

    var it = p.docs.iterator();
    var n: usize = 0;
    while (it.next()) |e| {
        n += 1;
        const key = e.key_ptr.*;
        if (p.aliases.get(key) == null and p.keywords.get(key) == null) {
            std.debug.print("dead docs key (no alias/keyword): {s}\n", .{key});
            return error.DocsKeyUnreachable;
        }
    }
    // 覆盖下限：std 全量教学批量，docs 至少 120 条。
    try std.testing.expect(n >= 120);
}

test "内置中文包 keywords 内建存在性不变量（第 151 轮·D53 防回归）：每个 @-前缀映射值必为 Zig 真实内建" {
    // 依据（用户口径 151）：以编译器自带内建注册表 std.zig.BuiltinFn.list 为唯一真相源，
    // 逐个反查语言包 keywords 段所有 `@`-前缀单 token 值；任一登记值不在注册表即红。
    // 本测无硬编码词表、不随内建增删漂移，长效钉死「死内建映射」（如曾误登的 `类型 = @Type`，
    // @Type 系旧 Zig 匿名类型构造内建、0.17 已移除），任何人再写不存在的内建映射即被此门拦下。
    const gpa = std.testing.allocator;
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
    var p = try parse(gpa, zh);
    defer p.deinit();

    const BuiltinFn = std.zig.BuiltinFn;
    var checked: usize = 0;
    var it = p.keywords.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        if (v.len < 2 or v[0] != '@') continue;
        // 只检纯内建标识符（@ 后全为字母/数字/下划线）；带点分链或多 token 的非本轮面，跳过。
        var single_token = true;
        for (v[1..]) |b| {
            const ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
            if (!ok) {
                single_token = false;
                break;
            }
        }
        if (!single_token) continue;
        checked += 1;
        if (!BuiltinFn.list.has(v)) {
            std.debug.print("dead builtin mapping: {s} = {s}\n", .{ e.key_ptr.*, v });
        }
        try std.testing.expect(BuiltinFn.list.has(v));
    }
    // 覆盖面下限：内建登记族至少 35 员（146/147/149/150/151 累积），防误清空 keywords。
    try std.testing.expect(checked >= 35);
    // D53 精确锚点：死映射键 `类型` 必须已删（get 返 null）；近义 `取类型` 仍指向真实内建 @TypeOf。
    try std.testing.expect(p.keywords.get("类型") == null);
    try std.testing.expectEqualStrings("@TypeOf", p.keywords.get("取类型").?);
}

test "内置中文包 keywords 关键字存在性不变量（第 152 轮·D54 防回归）：每个 ASCII 单 token 映射值必为 Zig 真实关键字或预声明名" {
    // 依据（用户口径 152·承 151 注册表方法论从内建面扩到关键字面）：以编译器自带的**两个**真相源
    // `std.zig.Token.keywords`（0.17 共 46 员）⊕`std.zig.isPrimitive`（预声明类型/值名、含 iN/uN）
    // 逐个反查 keywords 段所有「纯 ASCII 单 token、非 @-前缀」映射值；两者皆不命中即红。
    // （只用单一关键字表会假红：`整数 = i64`、`数据类型 = type` 等系预声明名、不在关键字表——
    // 152 轮审计探针首轮就实捕此形、70 项候选收敲为恰好 2 项真死映射。）
    // 本测无硬编码词表、不随 Zig 关键字/预声明名增删漂移，长效钉死「死关键字映射」——曾误登的
    // `异步 = async` / `等待 = await`（async/await 不在 0.17 关键字注册表、且语法层直接拒 parse），
    // 保留即端到端产 `var z_1 = async f();` 非法码（D53 同族、该拒绝未拒绝）。
    const gpa = std.testing.allocator;
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
    var p = try parse(gpa, zh);
    defer p.deinit();

    const Kw = std.zig.Token.keywords;
    var checked: usize = 0;
    var it = p.keywords.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        if (v.len == 0 or v[0] == '@') continue; // @-前缀内建面由 151 轮测把关
        // 只检单 token ASCII 标识符形；带空格/点分/括号的复合值（如 `[]const u8`）系类型表达式、
        // 非单词关键字映射，本轮面外，跳过。
        var single_token = true;
        for (v) |b| {
            const ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
            if (!ok) {
                single_token = false;
                break;
            }
        }
        if (!single_token) continue;
        checked += 1;
        if (!Kw.has(v) and !std.zig.isPrimitive(v)) {
            std.debug.print("dead keyword mapping: {s} = {s}\n", .{ e.key_ptr.*, v });
        }
        try std.testing.expect(Kw.has(v) or std.zig.isPrimitive(v));
    }
    // 覆盖面下限：声明/控制流/类型族登记至少 60 员，防误清空 keywords 使本测空转永真。
    try std.testing.expect(checked >= 60);
    // D54 精确锚点：两死映射键必须已删（get 返 null）；同族活词 `挂起外` 仍指真实关键字 nosuspend。
    try std.testing.expect(p.keywords.get("异步") == null);
    try std.testing.expect(p.keywords.get("等待") == null);
    try std.testing.expectEqualStrings("nosuspend", p.keywords.get("挂起外").?);
    // 152 轮补登锚点：三个此前漏登记的真实关键字到位（注册表在场 + ast-check 0 + build-obj 0 三证皆活）。
    try std.testing.expectEqualStrings("test", p.keywords.get("测试块").?);
    try std.testing.expectEqualStrings("packed", p.keywords.get("紧实").?);
    try std.testing.expectEqualStrings("noalias", p.keywords.get("无别名").?);
}

test "内置中文包 whitelist 存在性不变量（第 153 轮·护栏盲区补齐）：@-前缀豁免 token 必为真实内建，标识符 token 须合词法" {
    // 依据（153 轮盲区盘点）：whitelist 段是纯母语过滤器的整行精确豁免面（F2），独立于
    // keywords 段——151 轮 BuiltinFn 不变量只扫 keywords，本段 @-值（@import/@memcpy/@typeInfo）
    // 从未经任何存在性把关；写错一字节即「该豁免不生效」的静默漏拦。另拦非 @ token 的
    // 空白/非法词法形（含空格即永不命中、纯占位死条目）。
    const gpa = std.testing.allocator;
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
    var p = try parse(gpa, zh);
    defer p.deinit();

    var at_checked: usize = 0;
    var ident_checked: usize = 0;
    for (p.whitelist.items) |rule| {
        if (rule.len >= 2 and rule[0] == '@') {
            // @ 后须全为标识符字符（本包 whitelist 无 @"..." 形，出现即新面、须显式更新本测）。
            for (rule[1..]) |b| {
                const ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
                try std.testing.expect(ok);
            }
            at_checked += 1;
            if (!std.zig.BuiltinFn.list.has(rule)) {
                std.debug.print("dead whitelist builtin: {s}\n", .{rule});
            }
            try std.testing.expect(std.zig.BuiltinFn.list.has(rule));
        } else {
            // 非 @ token：合 Zig 标识符词法且不得含空白（「整行精确匹配」语义下任一模糊形永不生效）。
            ident_checked += 1;
            for (rule, 0..) |b, i| {
                const ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
                if (!ok) {
                    std.debug.print("malformed whitelist token: {s}\n", .{rule});
                }
                try std.testing.expect(ok);
                _ = i;
            }
        }
    }
    // 覆盖面与锚点：三条 @-内建豁免在场（与 keywords 段 `导入`/`嵌入文件`/`类型信息` 的映射值形互为
    // 独立登记面，值若被编译器移除即此处拦下）；标识符示例 token 至少 4 条，防段被误清空使本测空转。
    try std.testing.expect(at_checked >= 3);
    try std.testing.expect(ident_checked >= 4);
}

test "内置中文包 keywords 复合多 token 类型表达式值不变量（第 153 轮·护栏盲区补齐）：151/152 测均跳过的第三分区不再裸奔" {
    // 依据（153 轮盲区盘点）：[keywords] 映射值三分区——@-前缀（151 测）、ASCII 单 token（152 测）、
    // 复合多 token 类型表达式（`文本 = []const u8`、`字符串 = []u8`）。前两区有注册表真相源把关，
    // 第三区 151/152 测仅记「跳过」而无任何覆盖——值被手滑改坏（如 []cosnt u8）要到真编译才暴。
    // 本测钉分区计数下限与两锚点值；新增复合值须同步 translate.zig 逐字节快照测（153 轮已备）。
    const gpa = std.testing.allocator;
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
    var p = try parse(gpa, zh);
    defer p.deinit();

    var composite: usize = 0;
    var it = p.keywords.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        if (v.len == 0 or v[0] == '@') continue; // @-前缀由 151 轮测把关
        var single_token = true;
        for (v) |b| {
            const ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
            if (!ok) {
                single_token = false;
                break;
            }
        }
        if (single_token) continue; // 单 token 由 152 轮测把关
        composite += 1;
    }
    try std.testing.expect(composite >= 2);
    try std.testing.expectEqualStrings("[]const u8", p.keywords.get("文本").?);
    try std.testing.expectEqualStrings("[]u8", p.keywords.get("字符串").?);
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
    const zh = @embedFile(zzc_paths.builtin_pack_embed_lang);
    var real = try parse(gpa, zh);
    defer real.deinit();
    try real.validate();
}

// 第 242 轮 D110 单源↔解析器往返锚：用契约常量 meta_code/meta_name/meta_format 拼出的包必须
// 被解析器识别（code/name 落真值、非落未设哨兵）；反向缺 meta_code 行则 code 落 unset_code、
// validate 拒。若有人把某条解析分支重内联成与 meta_* 不同的字面量（旁通单源），本测喂常量键拼出
// 的包将不再被认 → code 落 unset_code → 红。与 main 侧 242 T1 双向锁死「解析器认的 == 指引写的」。
test "第 242 轮 T0 契约 token 单源↔解析器往返（meta_* 拼包即被认·D110）" {
    const gpa = std.testing.allocator;
    var p = try parse(gpa, meta_code ++ " = qq\n" ++ meta_name ++ " = 假名\n" ++ meta_format ++ " = 1\n[keywords]\n常数 = const\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("qq", p.code);
    try std.testing.expectEqualStrings("假名", p.name);
    // meta_format 系元数据头、被吞不入 keywords/aliases（翻译链摸不到它）。
    try std.testing.expect(p.keywords.get(meta_format) == null);
    try std.testing.expect(p.aliases.get(meta_format) == null);
    var q = try parse(gpa, "[keywords]\n常数 = const\n");
    defer q.deinit();
    try std.testing.expectEqualStrings(unset_code, q.code);
    try std.testing.expectError(error.PackMissingCode, q.validate());
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

test "R2 diagnostics 段数契约：4+ 竖线不新增条目、多余段原样折入 tip（定义行为钉·非静默丢弃）" {
    // 核验面（第 164 轮守则核验）：parseInto 对 diagnostics 行只切前两个 `|`（p1/p2），
    // tip = rest[p2+1..] 把第三段之后的全部竖线原样折入 tip。既有测仅钉「元数不足」（<3 段拒）
    // 与「空 tip 合法」，4+ 段的处置零直钉——若未来改成 split 全段并弃第 4+ 段（或整行拒），
    // 手编包多竖线 tip 会被静默降级、无回归信号。本测钉住当前定义行为：条目保留、pattern/message
    // 正确、tip 原样含其余竖线。非静默丢弃整条目，故不占缺陷号（守则面 R2）。
    const gpa = std.testing.allocator;
    var p = try parse(gpa, "$code = te\n[diagnostics]\nd = 模式|译文|提示一|提示二|提示三\n");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.diagnostics.items.len);
    try std.testing.expectEqualStrings("模式", p.diagnostics.items[0].pattern);
    try std.testing.expectEqualStrings("译文", p.diagnostics.items[0].message);
    try std.testing.expectEqualStrings("提示一|提示二|提示三", p.diagnostics.items[0].tip);
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

// 护栏（第 182 轮证伪撤号落位）：`upsertDiagnostic`（L129）系 diagnostics 段跨层后写覆盖
// （R11）的唯一上游，其「命中同 pattern → 就地替换、保持位置」分支的 firing 源唯有叠加层
// 场景（同层内 D40 封口先拒、替换臂于单次 parseInto 恒不 fired）。既有 R11 叠加测（L678）的
// overlay 行序恰为「同模式 d1x 在前、新模式在后」：此序下把替换sabotage成「摘旧元素再追加到
// 尾」，列表只含基包单条、摘后追加位仍居首——len/序/逐条目字段逐字节不变、R11 测不红。
// 即「保持位置」不变量在 R11 特定行序下全库隐形，而 matchDiag（diag/translate.zig L91）
// 「表序即优先级」（D6/R1/D41 族）恰依赖条目位置——误改让叠加覆盖把被覆盖条目甩到表尾，
// 匹配优先级静默重排、无任何自动防线。本测于三条目列表中位/首位/末位命中形直接钉住，
// 另钉空表追加、异 pattern 保序追加、三字段整体换、换后再换链式覆盖、唯 tip 可空（D30）诸臂。
// Entry 字段系输入字节借用视图、非本包拥有（L126-128 注）：替换路径无释放——本测以
// std.testing.allocator 全程跑替，替换零分配/释放即行为性钉住「不得释放旧字段」契约
// （误加 gpa.free(old) 对常量串视图释放即 abort）。
test "upsertDiagnostic 直调：就地替换保持位置/首末中三命中位/异 pattern 追加/换后再换/tip 可空（第 182 轮）" {
    const gpa = std.testing.allocator;
    var pack = Pack.init(gpa);
    defer pack.deinit();

    // ① 空表首追加 + 异 pattern 保序追加（未命中臂走 for 全扫后 append）。
    try pack.upsertDiagnostic(gpa, .{ .pattern = "A", .message = "a出", .tip = "a提" });
    try pack.upsertDiagnostic(gpa, .{ .pattern = "B", .message = "b出", .tip = "b提" });
    try pack.upsertDiagnostic(gpa, .{ .pattern = "C", .message = "c出", .tip = "c提" });
    try std.testing.expectEqual(@as(usize, 3), pack.diagnostics.items.len);
    try std.testing.expectEqualStrings("A", pack.diagnostics.items[0].pattern);
    try std.testing.expectEqualStrings("B", pack.diagnostics.items[1].pattern);
    try std.testing.expectEqualStrings("C", pack.diagnostics.items[2].pattern);

    // ② 中位命中→就地替换：len 不变、A/C 不动、B 的 message/tip 整体换（pattern 命中键不变形）。
    try pack.upsertDiagnostic(gpa, .{ .pattern = "B", .message = "b覆", .tip = "" });
    try std.testing.expectEqual(@as(usize, 3), pack.diagnostics.items.len);
    try std.testing.expectEqualStrings("A", pack.diagnostics.items[0].pattern);
    try std.testing.expectEqualStrings("C", pack.diagnostics.items[2].pattern);
    try std.testing.expectEqualStrings("B", pack.diagnostics.items[1].pattern);
    try std.testing.expectEqualStrings("b覆", pack.diagnostics.items[1].message);
    // 唯 tip 可空（D30 契约：`tip.len != 0` 才渲染提示行）：替换后空 tip 照位写入。
    try std.testing.expectEqualStrings("", pack.diagnostics.items[1].tip);

    // ③ 换后再换（链式覆盖）：第二次叠加层仍中位就地、不增殖条目。
    try pack.upsertDiagnostic(gpa, .{ .pattern = "B", .message = "b再覆", .tip = "b再提" });
    try std.testing.expectEqual(@as(usize, 3), pack.diagnostics.items.len);
    try std.testing.expectEqualStrings("b再覆", pack.diagnostics.items[1].message);
    try std.testing.expectEqualStrings("b再提", pack.diagnostics.items[1].tip);

    // ④ 首位命中就地（for 首步即中）：B/C 不动。
    try pack.upsertDiagnostic(gpa, .{ .pattern = "A", .message = "a覆", .tip = "a提" });
    try std.testing.expectEqual(@as(usize, 3), pack.diagnostics.items.len);
    try std.testing.expectEqualStrings("a覆", pack.diagnostics.items[0].message);
    try std.testing.expectEqualStrings("B", pack.diagnostics.items[1].pattern);
    try std.testing.expectEqualStrings("C", pack.diagnostics.items[2].pattern);

    // ⑤ 末位命中就地：A/B 不动。
    try pack.upsertDiagnostic(gpa, .{ .pattern = "C", .message = "c覆", .tip = "c提" });
    try std.testing.expectEqual(@as(usize, 3), pack.diagnostics.items.len);
    try std.testing.expectEqualStrings("a覆", pack.diagnostics.items[0].message);
    try std.testing.expectEqualStrings("b再覆", pack.diagnostics.items[1].message);
    try std.testing.expectEqualStrings("c覆", pack.diagnostics.items[2].message);
}
