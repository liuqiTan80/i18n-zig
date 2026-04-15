//! 机读诊断「种类 kind」词汇单一真值 hub（零依赖、纯 comptime 逻辑）。
//!
//! 第 208 轮 D76。靶面（t2 探针 `.scratch208` 实锤）：kind 词值面原有三份互不交叉的手抄——
//!   * 生成侧 `diag/translate.zig` 的私有 `const kind_zh`（英文 zig 种类名 → 母语 kind 词），
//!     机器单行的 kind 段直接取它的值渲染；
//!   * 消费侧 `main.zig` 的 `kindSeverity`（母语 kind 词 → LSP DiagnosticSeverity），
//!     用 Unicode 转义把「警告/说明/被引用于」三枚词独立硬编匹配；
//!   * `kindSeverity` 的既有 T2 测又用第三份明文字面量对照自身。
//! P1 把生成侧 `kind_zh` 的「警告」改成异值 → `zig build test` 全绿（无任何测把实际生成
//! 的 kind token 喂回消费侧），而运行期 LSP 侧 `kindSeverity` 因不再命中该词静默回落
//! severity=1（error），编辑器把 warning/note 一律降级为 error。
//!
//! 本表把 (英文种类名 en ↔ 母语 kind 词 zh ↔ LSP severity) 三元关系统一为唯一真值：
//! 生成侧读 `lookupZh`/`zh_values`、消费侧读 `severityOf`，三者恒派生自同一 `entries`，
//! 跨模块漂移在结构上不可能再现。
const std = @import("std");

/// 一条 kind 的三元真值：zig 英文种类名、母语机器 kind 段词、LSP DiagnosticSeverity(1..4)。
/// `bare_prefix` 标记该种类是否会以裸诊断行前缀 `<en>: <msg>` 形式出现于无 `file:line:col` 的
/// CLI 级 stderr（zig 只对 error/warning/note 三者这么打）——供 `translate.localizeRunner` 的前缀
/// 短语表据本表派生母语词，杜绝同概念词在 hub 与短语表两处各抄一份（第 209 轮 D77）。
pub const Entry = struct {
    en: []const u8,
    zh: []const u8,
    severity: u8,
    bare_prefix: bool = false,
};

/// 唯一真值表。新增/改词/调 severity 只动此处，生成与消费两侧自动同源。
pub const entries = [_]Entry{
    .{ .en = "error", .zh = "错误", .severity = 1, .bare_prefix = true },
    .{ .en = "warning", .zh = "警告", .severity = 2, .bare_prefix = true },
    .{ .en = "note", .zh = "说明", .severity = 3, .bare_prefix = true },
    .{ .en = "referenced by", .zh = "被引用于", .severity = 4 },
    .{ .en = "unknown", .zh = "内部错误", .severity = 1 },
};

/// 英文 zig 种类名 → 母语 kind 词（comptime 版·专供短语表等在编译期拼 `.{ en ++ ": ", zhOf(en) ++ ": " }` 派生前缀对）。
/// 与 `lookupZh` 同源读 `entries`，但键须编译期已知、未收录即 `@compileError`（拼错种类键在结构上不可达运行期）。
pub fn zhOf(comptime en: []const u8) []const u8 {
    inline for (entries) |e| {
        if (comptime std.mem.eql(u8, e.en, en)) return e.zh;
    }
    @compileError("kind.zhOf：未收录的种类键 " ++ en);
}

/// 英文 zig 种类名 → 母语 kind 词（由 `entries` 派生，非另立手抄）。
/// 未收录返回 null，原样透传由调用方 `orelse` 决定（如 zzc 原生 kind 不经本表）。
pub fn lookupZh(en: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.en, en)) return e.zh;
    }
    return null;
}

/// 母语 kind 词集合（供 machineHead 判据；由 `entries` 派生·按值返回避免指向 comptime var）。
pub const zh_values: [entries.len][]const u8 = blk: {
    var v: [entries.len][]const u8 = undefined;
    for (entries, 0..) |e, i| v[i] = e.zh;
    break :blk v;
};

/// 母语 kind 词 → LSP DiagnosticSeverity；未知退 1（错误）。消费侧 `kindSeverity` 委派至此。
pub fn severityOf(zh: []const u8) u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.zh, zh)) return e.severity;
    }
    return 1;
}

test "第 208 轮 T0 kind 词汇表自守：zh 词两两不同 + en 键两两不同（值面可作 machineHead 判据、键面可作 lookup 源）" {
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.zh, b.zh));
            try std.testing.expect(!std.mem.eql(u8, a.en, b.en));
        }
    }
    // zh_values 与 entries 等长且逐项对应（machineHead 判据不漏词）。
    try std.testing.expectEqual(entries.len, zh_values.len);
    for (entries, 0..) |e, i| try std.testing.expectEqualStrings(e.zh, zh_values[i]);
}

test "第 208 轮 T1 三元真值自洽：lookupZh(en)==zh 且 severityOf(zh)==severity（穷举每条 · 单源内部无矛盾）" {
    for (entries) |e| {
        try std.testing.expectEqualStrings(e.zh, lookupZh(e.en).?);
        try std.testing.expectEqual(e.severity, severityOf(e.zh));
    }
}

test "第 209 轮 T0 zhOf 与 lookupZh 同源 + bare_prefix 恰为 error/warning/note 三裸诊断前缀种类" {
    // zhOf（comptime）与 lookupZh（运行期）对每个已收录键必回同值。
    inline for (entries) |e| {
        try std.testing.expectEqualStrings(e.zh, zhOf(e.en));
    }
    // bare_prefix 恰圈定 zig 会以 `<kind>: ` 裸前缀打出的三种；其余（被引用于/内部错误）不应入前缀表。
    var n_prefix: usize = 0;
    for (entries) |e| {
        const want = std.mem.eql(u8, e.en, "error") or
            std.mem.eql(u8, e.en, "warning") or
            std.mem.eql(u8, e.en, "note");
        try std.testing.expectEqual(want, e.bare_prefix);
        if (e.bare_prefix) n_prefix += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n_prefix);
}
