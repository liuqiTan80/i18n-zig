//! 语言包注册表（台账 R9，第 52 轮：最小多包加载面）。
//!
//! 把「按名选包」的加载缝集中到一处：新增一门方言只需
//!   1) 在 `packs/` 放一份包文件；
//!   2) 在该文件首部写 `# @` 注册头指令（key/code/display/aliases/default；补充层用 overlay-of）。
//! `entries` 由 build.zig 扫描上述头指令自动生成（R9续②）——引擎与 CLI 零改动。当前仅内置中文包
//! （附 `繁体.txt` 叠加层），结构为多语言扩展预留（注册表/加载器面）。
//!
//! 本模块刻意保持纯数据 + 纯查询（不碰磁盘、不分配），进 zzc_core 测试图可单测。
//!
//! R9续②（第 54 轮）：`Entry`/`entries` 不再手与，改由 `pack_registry` 模块（build.zig 扫
//! `src/lang/packs/` 的 `# @` 头指令自动生成）提供——新增方言/补充层 = 丢一份带头指令的 .txt，
//! 零改代码。选包/匹配逻辑仍在本模块。

const std = @import("std");
const registry_gen = @import("pack_registry");

/// 注册表条目：数据形状由生成模块定义（与 build.zig 一致），本模块只消数据不手与。
pub const Entry = registry_gen.Entry;

/// 已登记的包（自动生成）。第一项恒为默认包（未指定 `--lang` 时选用）。
pub const entries = registry_gen.entries;

/// 默认包（未指定 `--lang` 时）。生成器据 `# @default` 头指令把默认基包置首发射，故 `entries[0]` 恒为默认。
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

/// 叠加层命中结果（第 328 轮 D187）：`base_key` 是被叠加的基包，`label` 是该叠加层的首名（`# @display`）。
pub const OverlayHit = struct { base_key: []const u8, label: []const u8 };

/// 按名查「这是某基包的内置叠加层吗」（第 328 轮 D187）。
///
/// 叠加层没有 `# @key`、不进 `entries`，故 `lookup` 永远查不到它；而它所叠加的基包**默认就带着它**，
/// 于是 `--lang 繁體` 历史上只能落「未知语言包」——话术把人引向「是不是要另装/另选」，而正解是
/// 「什么都不用做」。本判据只回答「他是哪一层的名字」，话术与退出码仍由调用方决定。
pub fn overlayHint(name: []const u8) ?OverlayHit {
    const t = std.mem.trim(u8, name, " \t");
    if (t.len == 0) return null;
    for (entries) |p| {
        for (p.overlay_names) |names| {
            for (names) |nm| {
                if (nameMatch(t, nm)) {
                    return .{ .base_key = p.key, .label = if (names.len > 0) names[0] else p.key };
                }
            }
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

test "registry（R9续②③）：自动发现的繁体叠加层运行时真并入默认 zh，且不动简体基包" {
    const Pack = @import("pack.zig").Pack;
    const gpa = std.testing.allocator;

    const zh = lookup("zh") orelse return error.TestUnexpectedResult;
    // 自动发现应将 繁体.txt 作为补充层挂到 zh 基包上（非空 overlays）。
    try std.testing.expect(zh.overlays.len > 0);

    // 基包单独解析：不应含繁体形（证下面命中确来自叠加层、非基包）。
    {
        var base = try Pack.parse(gpa, zh.bytes);
        defer base.deinit();
        try std.testing.expect(base.keywords.get("常數") == null);
    }

    // 叠加后：繁体形命中且与简体孪生键同值；简体形不回退（纯并集、无覆盖）。
    var pack = try Pack.loadWithOverlays(gpa, zh.bytes, zh.overlays);
    defer pack.deinit();
    try std.testing.expectEqualStrings("const", pack.keywords.get("常數").?); // 繁体→叠加层
    try std.testing.expectEqualStrings("fn", pack.keywords.get("函數").?);
    try std.testing.expectEqualStrings("struct", pack.keywords.get("結構").?);
    try std.testing.expectEqualStrings("const", pack.keywords.get("常数").?); // 简体→基包、仍活
    try std.testing.expectEqualStrings("fn", pack.keywords.get("函数").?);
}

test "registry（第三方库翻译叠加包）：外部 [aliases]/[docs] 叠加层运行时并入 zh、后写不伤 B6 契约与 $code" {
    // 承 `--lang-overlay` 接缝语义的内存测（不依赖网络/httpz）：一份只带 [aliases]/[docs]、不含
    // $code/$name/关键字的外部叠加层（形同 contrib/packs/httpz-中文.txt）累积并入基包 zh 之后：
    //   ① 新别名生效；② 基包 B6 契约仍在（叠加层不供契约、validate 由基包撑）；③ $code 未被改写。
    // httpz 路径真存在性由 demo/httpz 真依赖 `zig build` 编译坐实（独立于本测图）；此处只钉合并语义形制。
    const Pack = @import("pack.zig").Pack;
    const gpa = std.testing.allocator;
    const zh = lookup("zh") orelse return error.TestUnexpectedResult;

    // 基包单独解析：不含拟叠加的第三方别名（证下面命中确来自叠加层、非基包）。
    {
        var base = try Pack.parse(gpa, zh.bytes);
        defer base.deinit();
        try std.testing.expect(base.aliases.get("网络服务") == null);
        try std.testing.expect(base.aliases.get("网络服务.请求") == null);
    }

    // 叠加层字节：形同 contrib 包（[aliases]+[docs]、无 $meta）；docs 键皆同现于 aliases（守 docs⊆alias 不变量）。
    const overlay =
        \\[aliases]
        \\网络服务 = httpz
        \\网络服务.请求 = httpz.Request
        \\[docs]
        \\网络服务 = httpz 服务端库总入口。
        \\网络服务.请求 = 入站请求对象。
        \\
    ;
    var merged = try Pack.loadWithOverlays(gpa, zh.bytes, &[_][]const u8{overlay});
    defer merged.deinit();
    // ① 新别名并入生效。
    try std.testing.expectEqualStrings("httpz", merged.aliases.get("网络服务").?);
    try std.testing.expectEqualStrings("httpz.Request", merged.aliases.get("网络服务.请求").?);
    // docs 同现（形同 contrib 包的 docs⊆alias 约定）。
    try std.testing.expect(merged.docs.get("网络服务.请求") != null);
    // ② B6 契约仍由基包供、validate 通过。
    try merged.validate();
    // ③ $code 未被叠加层改写（叠加层不含 $code）。
    try std.testing.expectEqualStrings("zh", merged.code);
}

// 护栏（第 116 轮证伪落位）：本模块零分配（纯数据+纯查询），D51 逐分配点对账真空闭合；转钉
// 私有 `nameMatch` 的双向大小写折叠真边界。两个纯防御/正确性面此前经任何公共路径零触达：
//   · b 侧大写分支（L36）——现行注册 key/alias 全小写或 CJK，输入大写形只走 a 侧分支（lookup("ZH")
//     已覆盖），注册项含大写形才触发 b 侧；若误删此支，将来登记大写别名的包会大小写不敏感静默失效。
//   · 非字母字节须原样相等——`a + 32 == b` 若不校验 `a`/`b` 落 A-Z/a-z，会把差 0x20 的非字母对（如
//     空格 0x20 与 @ 0x40）误折为「相等」。本测直调逐形钉住两向折叠、混合大小写、CJK 逐字节精确、
//     非字母差 0x20 不误折、长度不等先拒。
test "nameMatch 双向大小写折叠真边界：两向 ASCII 折叠 + 非字母逐字节精确 + 长度短路（b 侧大写分支现行数据零触达，第 116 轮）" {
    // ① 全等 / 双空串。
    try std.testing.expect(nameMatch("zh", "zh"));
    try std.testing.expect(nameMatch("", ""));
    // ② a 侧大写折叠（x 大写、y 小写；既有 lookup("ZH") 已间接走过此支）。
    try std.testing.expect(nameMatch("ZH", "zh"));
    // ③ b 侧大写折叠（x 小写、y 大写）——现行注册数据零触达的纯防御分支（本测独有价值）。
    try std.testing.expect(nameMatch("zh", "ZH"));
    // ④ 混合大小写逐位折叠。
    try std.testing.expect(nameMatch("ZhCk", "zHcK"));
    // ⑤ 非字母字节须原样相等：CJK 按字节精确命中、不误折。
    try std.testing.expect(nameMatch("中文", "中文"));
    // ⑥ 非字母但差 0x20 的对不得误折（空格 0x20 vs @ 0x40）——钉 a/b 两侧均非大写范围时不折叠。
    try std.testing.expect(!nameMatch(" ", "@"));
    // ⑦ 字母 vs 非字母同位不等 → 拒；长度不等先短路拒。
    try std.testing.expect(!nameMatch("zh", "zhh"));
    try std.testing.expect(!nameMatch("zh", "zx"));
}

// 第 328 轮 T0（D187）：叠加层名族「正形扩臂」。旧形：叠加层无 `# @display`/`# @aliases`，生成表里
// 只有字节没有名字，`registry.lookup("繁體")` 恒 null、诊断只能报「未知语言包」。
test "第 328 轮 T0 叠加层名族：与繁体.txt 头指令同源＋正反形（D187）" {
    // A1 同长不变量：overlay_names 与 overlays 同序同长（生成器漏发一组即红）。
    for (entries) |p| try std.testing.expectEqual(p.overlays.len, p.overlay_names.len);

    // A2 基包 zh 的叠加层有名且首名为 display 正形。
    const zh = lookup("zh").?;
    try std.testing.expect(zh.overlay_names.len > 0);
    try std.testing.expect(zh.overlay_names[0].len > 0);
    try std.testing.expectEqualStrings("繁体字形", zh.overlay_names[0][0]);

    // A3 正形全命中：简繁两体、全称、+字、正体皆指向基包 zh。
    for ([_][]const u8{ "繁体", "繁體", "繁体中文", "繁體中文", "繁体字", "繁體字", "正体字", "正體字", "繁体字形" }) |n| {
        const h = overlayHint(n) orelse return error.NoOverlayHit;
        try std.testing.expectEqualStrings("zh", h.base_key);
        try std.testing.expectEqualStrings("繁体字形", h.label);
    }

    // A4 反形：基包名、大小写变体、臆造名、空串/空白皆不得误判为叠加层。
    for ([_][]const u8{ "简体", "中文", "汉", "zh", "ZH", "zhh", "繁", "", "  " }) |n| {
        try std.testing.expectEqual(@as(?OverlayHit, null), overlayHint(n));
    }

    // A5 三源同源：繁体.txt 头指令的 `# @display` 与 `# @aliases` 逐项都必须被生成表覆盖——手改
    // 包文件而忘了重生成、或生成器漏发别名，此处即红（不靠人记「两个地方要一起改」）。
    const head = @embedFile("packs/繁体.txt");
    var lines = std.mem.splitScalar(u8, head, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "#")) break;
        if (std.mem.startsWith(u8, line, "# @display ")) {
            const v = std.mem.trim(u8, line["# @display ".len..], " ");
            try std.testing.expect(overlayHint(v) != null);
            seen += 1;
        } else if (std.mem.startsWith(u8, line, "# @aliases ")) {
            var it = std.mem.splitScalar(u8, line["# @aliases ".len..], ',');
            while (it.next()) |part| {
                const v = std.mem.trim(u8, part, " \t");
                if (v.len == 0) continue;
                try std.testing.expect(overlayHint(v) != null);
                seen += 1;
            }
        }
    }
    try std.testing.expect(seen >= 9); // display 1 ＋ aliases 8：少一条即证明扫描落空
}
