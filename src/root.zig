//! zzc_core 模块门面：暴露翻译引擎与报错回译，供测试与第三方嵌入。
pub const lexer = @import("transpiler/lexer.zig");
pub const translate = @import("transpiler/translate.zig");
pub const Mangle = @import("transpiler/mangle.zig");
pub const ColumnMap = @import("transpiler/column_map.zig");
pub const relocalize = @import("transpiler/relocalize.zig"); // 第 333 轮：反向渲染核（relocalize 的对偶面）
pub const Pack = @import("lang/pack.zig");
pub const registry = @import("lang/registry.zig");
pub const pack_discover = @import("lang/pack_discover.zig"); // 第 260 轮 D126：语言包发现/注册表生成单源内核（build run 步与本测图共用）
pub const userpack = @import("lang/userpack.zig");
pub const fullwidth = @import("diag/fullwidth.zig");
pub const diag = @import("diag/translate.zig");
pub const kind = @import("diag/kind.zig"); // 第 208 轮 D76：机读 kind 词汇单一真值 hub
pub const cli = @import("cli/args.zig");
pub const cli_embed_scan = @import("cli/embed_scan.zig"); // 第 341 轮 D200：@embedFile 静态扫描族自 args.zig 下沉（`cli.*` 表面逐名转出不变）
pub const file_io = @import("file_io.zig");
pub const tmlang = @import("editor/tmlang.zig");
pub const snippets = @import("editor/snippets.zig");
pub const lsp_jsonrpc = @import("lsp/jsonrpc.zig");
pub const lsp_server = @import("lsp/server.zig");
pub const lsp_server_query = @import("lsp/server_query.zig"); // 第 341 轮 D200：文本坐标／词与声明查询族自 server.zig 下沉（面表留 hub）
pub const paths = @import("zzc_paths.zig");
pub const machine = @import("machine_contract.zig");
pub const vsix = @import("vsix.zig"); // 第 292 轮 D151：VSIX 包内元数据读侧与产物对账判据单一真值（守卫步据此核本机包是否与源树同源）
pub const lsp_legend = @import("lsp/server.zig"); // 第 214 轮 D82：语义 token 图例单一真值（守卫步据此对账 extension.js 对面）
pub const lang_id = @import("editor/lang_identity.zig"); // 第 215 轮 D83：编辑器语言标识族单一真值（守卫步据此对账清单/客户端/示例三面）
pub const lsp_cfg = @import("editor/lsp_config.zig"); // 第 216 轮 D84：LSP 客户端接线族单一真值（守卫步据此对账清单/客户端两面）

pub const zh_pack_bytes = @embedFile(paths.builtin_pack_embed_src); // 第 238 轮 D106：内置默认包文件名由 hub 单源派生（旧硬编 `lang/packs/中文.txt`）

test "第 238 轮 T1 内置默认包一致性锚：按名 embed 的字节 == 按内容 `# @default` 发现的默认包字节" {
    // 这是 D106 的牙：旧形制下 `zh_pack_bytes`（按文件名 embed）导出后零消费、与
    // `registry.defaultEntry().bytes`（按包内 `# @default` 内容指令发现）无任何交叉——
    // t2 探针 P1 实锤将本 embed 目标改 `繁体.txt` 而 fresh 615/615 全绿（静默失联）。
    // 本锚坐实两个出口的默认包字节逐字节相同：一旦移动 `# @default` 或换名，立即转红。
    std.testing.expectEqualStrings(zh_pack_bytes, registry.defaultEntry().bytes) catch |e| {
        std.debug.print("zh_pack_bytes 与 registry.defaultEntry() 分道（内置默认包名↔内容失联）\\n", .{});
        return e;
    };
}

test {
    _ = lexer;
    _ = translate;
    _ = Mangle;
    _ = ColumnMap;
    _ = Pack;
    _ = registry;
    _ = pack_discover;
    _ = userpack;
    _ = fullwidth;
    _ = diag;
    _ = kind;
    _ = cli;
    _ = cli_embed_scan; // 第 341 轮 D200：下沉模块亦须入聚合器——其 14 枚测不得只靠「被 `cli` 引到」蹭图
    _ = file_io;
    _ = tmlang;
    _ = snippets;
    _ = lsp_jsonrpc;
    _ = lsp_server;
    _ = lsp_server_query; // 第 341 轮 D200：同上，下沉的查询判据模块自有测须入图
    _ = lsp_legend; // 第 293 轮 D152：与 `lsp_server` 同指 `lsp/server.zig`，本行不增测数，只为门面名↔聚合器名集一一对齐
    _ = paths;
    _ = machine;
    _ = vsix; // 第 292 轮 D151：新 hub 模块**必须**入本聚合器，否则其 test 在 zzc_core 测图里静默不跑——探针实锤：接线前后 core 皆 393，而 `zig test src/vsix.zig` 独跑 1/1 绿（单文件绿≠入图绿）
    _ = lang_id;
    _ = lsp_cfg;
    _ = relocalize;
}

// ─── 第 293 轮 D152：门面声明 ↔ 测聚合器 名集对账（编译期自守） ────────────────

/// 本文件源文本（编译期自嵌）。`root.zig` 是 source dependency——改一行必重编本模块，故不存在
/// 203/214/292 轮「非 source dep 的内联字节陈旧假绿」那形风险（那几轮的判据只能交守卫步 `addFileArg`）。
const std = @import("std"); // 第 293 轮 D152：容器级判据取 mem/ascii/fmt（本文件此前只在测内局部 import）
const self_src: []const u8 = @embedFile("root.zig");

/// 门面 `pub const X = @import(…)` 的枚数**基线**——独立手设：不可从 `self_src` 反抽后回填，
/// 否则抽取器漂成 0 枚时锚随其同漂，成空转伪钉（同 240 轮 pack 下限／292 轮 `member_floor` 判例）。
/// 新增模块须同时抬本数，否则 293 T0 的等值钉当场红。
pub const facade_floor: usize = 26; // 第 341 轮 D200：24→26（巨型 hub 拆出的两枚下沉模块入门面）

/// 取 `src` 中第 `nth`（0 起）枚**门面名**：行首 `pub const <名> = @import`。
/// 只认 `@import`，故 `pub const zh_pack_bytes = @embedFile(…)` 那类数据门面不入本面（它无测可拉）。
fn facadeNameAt(src: []const u8, nth: usize) ?[]const u8 {
    @setEvalBranchQuota(4_000_000); // 判据须在 comptime 扫全文（KB 级），默认 1000 分支预算不够
    const head = "pub const ";
    var i: usize = 0;
    var seen: usize = 0;
    while (i + head.len <= src.len) : (i += 1) {
        if (i != 0 and src[i - 1] != '\n') continue; // 必须行首，免得把注释/字符串里的形串当门面
        if (!std.mem.eql(u8, src[i .. i + head.len], head)) continue;
        var j = i + head.len;
        // Zig 标识符含下划线——漏它即把 `lsp_jsonrpc` 截成 `lsp` 而整枚跳出面（首轮实跑踩到）
        while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
        if (j == i + head.len) continue; // 空名
        const name = src[i + head.len .. j];
        // 名后须恰为 ` = @import`，才算引模块的门面（` = @embedFile`／` = struct` 等不入面）
        const tail = " = @import";
        if (j + tail.len > src.len or !std.mem.eql(u8, src[j .. j + tail.len], tail)) continue;
        if (seen == nth) return name;
        seen += 1;
    }
    return null;
}

fn countFacades(src: []const u8) usize {
    @setEvalBranchQuota(4_000_000); // 判据须在 comptime 扫全文（KB 级），默认 1000 分支预算不够
    var n: usize = 0;
    while (facadeNameAt(src, n) != null) n += 1;
    return n;
}

/// `src` 的 `test { _ = <名>; }` 聚合器里是否登记了 `name`（前后界须是行首缩进与 `;`）。
fn hasAggRef(src: []const u8, name: []const u8) bool {
    @setEvalBranchQuota(4_000_000); // 判据须在 comptime 扫全文（KB 级），默认 1000 分支预算不够
    const lead = "_ = ";
    var i: usize = 0;
    while (i + lead.len + name.len + 1 <= src.len) : (i += 1) {
        if (!std.mem.eql(u8, src[i .. i + lead.len], lead)) continue; // `"_ = "` 逐字节比——第 3 位是空格不是 `=`
        if (!std.mem.eql(u8, src[i + lead.len .. i + lead.len + name.len], name)) continue;
        if (src[i + lead.len + name.len] != ';') continue;
        if (i != 0 and src[i - 1] != '\n' and src[i - 1] != ' ' and src[i - 1] != '\t') continue;
        return true;
    }
    return false;
}

/// 已声明门面却**未入聚合器**的枚数——本数 > 0 即该模块的 test 在 zzc_core 测图里静默不跑
/// （292 轮 P3 实锤形：`zig test src/vsix.zig` 独跑 1/1 绿而整图计数纹丝不动）。
fn missingAggRefs(src: []const u8) usize {
    @setEvalBranchQuota(4_000_000); // 判据须在 comptime 扫全文（KB 级），默认 1000 分支预算不够
    var miss: usize = 0;
    var n: usize = 0;
    while (facadeNameAt(src, n)) |name| : (n += 1) {
        if (!hasAggRef(src, name)) miss += 1;
    }
    return miss;
}

// 编译期自守：任何编译 zzc_core 的目标（exe／两测图／守卫步）都先过这道闸——比守卫更硬，
// 因为「漏登记」在编译阶段即拦，无须等 `zig build test` 的退码或人记得跑守卫。
comptime {
    @setEvalBranchQuota(4_000_000); // 同上：门面↔聚合器名集对拍在编译期跑
    const miss = missingAggRefs(self_src);
    if (miss > 0) {
        @compileError(std.fmt.comptimePrint(
            "zzc_core 门面有 {d} 枚模块未入本文件的 `test {{ _ = …; }}` 聚合器——其 test 在测图里静默不跑（293 轮 D152 判据）。请为每枚漏登记的 `pub const` 补一行 `_ = <名>;`。",
            .{miss},
        ));
    }
    if (countFacades(self_src) < facade_floor) {
        @compileError("self_src 抽取到的门面少于 facade_floor——抽取器形制漂了（293 轮 D152），不是模块变少。");
    }
}

test "293 T0 门面↔聚合器名集判据：抽取器正反漂形、下限值钉与实文零外悬" {
    // A1：正形——两枚门面皆登记，抽取数与缺登记数俱对。
    const ok_src = "pub const aaa = @import(\"aaa.zig\");\n" ++
        "pub const Bbb = @import(\"sub/bbb.zig\").Bbb;\n" ++
        "test {\n    _ = aaa;\n    _ = Bbb;\n}\n";
    try std.testing.expectEqual(@as(usize, 2), countFacades(ok_src));
    try std.testing.expectEqual(@as(usize, 0), missingAggRefs(ok_src));
    try std.testing.expectEqualStrings("Bbb", facadeNameAt(ok_src, 1).?); // 子字段门面同样入面（其名须登记）

    // A2：漂形一——门面声明了却漏登记聚合器 → 恰缺 1 枚（这是本轮的靶形）。
    const drift = "pub const aaa = @import(\"aaa.zig\");\npub const ccc = @import(\"ccc.zig\");\ntest {\n    _ = aaa;\n}\n";
    try std.testing.expectEqual(@as(usize, 2), countFacades(drift));
    try std.testing.expectEqual(@as(usize, 1), missingAggRefs(drift));
    try std.testing.expect(hasAggRef(drift, "aaa"));
    try std.testing.expect(!hasAggRef(drift, "ccc"));

    // A3：抽取器不空转也不误吞——数据门面（@embedFile）与注释里的同名形串皆不入面。
    const nodata = "pub const bytes = @embedFile(\"x.txt\");\n// pub const fake = @import(\"fake.zig\");\n";
    try std.testing.expectEqual(@as(usize, 0), countFacades(nodata));
    try std.testing.expectEqual(@as(usize, 0), missingAggRefs(nodata));
    // A3b：聚合器名后无 `;`／名不完整皆不算登记（防把 `_ = aaa;` 写成 `_ = aaa` 仍判绿）。
    try std.testing.expect(!hasAggRef("test {\n    _ = aaa\n}\n", "aaa"));
    try std.testing.expect(!hasAggRef("test {\n    _ = aab;\n}\n", "aa"));

    // A4：下限值钉 + 实文恰等基线（新增模块须同步抬 `facade_floor`，否则等值钉红）。
    try std.testing.expectEqual(@as(usize, 26), facade_floor);
    try std.testing.expectEqual(facade_floor, countFacades(self_src));
    try std.testing.expectEqual(@as(usize, 0), missingAggRefs(self_src));
}
