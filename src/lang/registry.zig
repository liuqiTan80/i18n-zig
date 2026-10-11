//! 语言包注册表（台账 R9，第 52 轮：最小多包加载面）。
//!
//! 把「按名选包」的加载缝集中到一处：新增一门方言只需
//!   1) 在 `packs/` 放一份包文件；
//!   2) 在下方 `entries` 登记一行（选择名 / 别名 / 码 / 内嵌字节）。
//! 引擎与 CLI 零改动。当前仅内置中文包，结构为多语言扩展预留（注册表/加载器面）。
//!
//! 本模块刻意保持纯数据 + 纯查询（不碰磁盘、不分配），进 zzc_core 测试图可单测。

const std = @import("std");

pub const Entry = struct {
    /// CLI `--lang` 的稳定选择名（小写 ASCII 码，不随显示名变动）
    key: []const u8,
    /// 别名（方言自称/中文名），`--lang` 亦可命中
    aliases: []const []const u8,
    /// ISO 语言码（供 version / lang 展示）
    code: []const u8,
    /// 注册表层显示名（包内 `$name` 会进一步覆盖，这里作展示/兜底）
    display: []const u8,
    /// 内嵌包字节（编译期进二进制，与工具同版本发布）——基包（base）。
    bytes: []const u8,
    /// 叠加的补充层/适配层字节（R11，第 53 轮）：按序累积解析到 `bytes` 之上，后层覆盖同键、
    /// 白名单取并集。默认空即单包（无补充层）；本字段仅为数据，合并在 `Pack.loadWithOverlays` 完成。
    overlays: []const []const u8 = &.{},
};

/// 已登记的包。第一项恒为默认包（未指定 `--lang` 时选用）。
pub const entries = [_]Entry{
    .{
        .key = "zh",
        .aliases = &.{ "中文", "简体", "汉" },
        .code = "zh",
        .display = "简体中文",
        .bytes = @embedFile("packs/中文.txt"),
    },
};

/// 默认包（未指定 `--lang` 时）。约定 `entries[0]` 恒为默认。
pub fn defaultEntry() Entry {
    return entries[0];
}

/// ASCII 大小写不敏感的整串比较（对 CJK 等多字节序列退化为逐字节精确比较：
/// 非字母字节须原样相等，故别名「中文」等按字节精确命中，不会误折）。
fn nameMatch(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |a, b| {
        if (a == b) continue;
        if (a >= 'A' and a <= 'Z' and a + 32 == b) continue;
        if (b >= 'A' and b <= 'Z' and b + 32 == a) continue;
        return false;
    }
    return true;
}

/// 按名查包：`name` 命中某项的 `key` 或任一 `alias`（大小写不敏感、去首尾空白）即返回该注册项；未命中 null。
pub fn lookup(name: []const u8) ?Entry {
    const t = std.mem.trim(u8, name, " \t");
    if (t.len == 0) return null;
    for (entries) |p| {
        if (nameMatch(t, p.key)) return p;
        for (p.aliases) |a| {
            if (nameMatch(t, a)) return p;
        }
    }
    return null;
}

test "registry：默认包为中文；按 key/别名/大小写命中；未知名返回 null" {
    // 默认项（entries[0]）即中文包，字节非空。
    try std.testing.expectEqualStrings("zh", defaultEntry().key);
    try std.testing.expect(defaultEntry().bytes.len > 0);

    // 选择名命中。
    try std.testing.expectEqualStrings("zh", lookup("zh").?.key);
    // 大小写不敏感。
    try std.testing.expectEqualStrings("zh", lookup("ZH").?.key);
    // 去首尾空白。
    try std.testing.expectEqualStrings("zh", lookup("  zh ").?.key);
    // 中文别名命中。
    try std.testing.expectEqualStrings("zh", lookup("中文").?.key);
    // 未登记名 → null。
    try std.testing.expectEqual(@as(?Entry, null), lookup("ja"));
    try std.testing.expectEqual(@as(?Entry, null), lookup(""));
    try std.testing.expectEqual(@as(?Entry, null), lookup("   "));
}

test "registry：登记的包字节可被 Pack 解析并通过 B6 契约校验（注册表与包不漂移）" {
    const Pack = @import("pack.zig").Pack;
    const gpa = std.testing.allocator;
    for (entries) |p| {
        var pack = try Pack.loadWithOverlays(gpa, p.bytes, p.overlays);
        defer pack.deinit();
        try pack.validate();
        // 注册表 code 应与包内 $code 一致（防两处漂移；不一致即展示/选择名与实际包脱节）。
        try std.testing.expectEqualStrings(p.code, pack.code);
    }
}
