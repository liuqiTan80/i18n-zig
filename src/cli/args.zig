//! 命令行参数解析：从 `[文件.zz] [zig 旗标…]` 里分离方言入口与透传给 zig 的其余参数。

const std = @import("std");
const Pack = @import("../lang/pack.zig").Pack; // 第 142 轮：模板生成器按包组词需 Pack 反查面
const zzc = @import("../zzc_paths.zig"); // 第 200 轮 D68：.zzc 内部路径族改由该模块持唯一真值
const mcon = @import("../machine_contract.zig"); // 第 203 轮 D71：机读旗标名与单行形制的契约 hub
const kdiag = @import("../diag/kind.zig"); // 第 227 轮 D95：ps1 码点断言 needle 由 kind 词汇真值派生（错误）
const snippets_hub = @import("../editor/snippets.zig"); // 第 227 轮 D95：hover 词类标签真值派生（关键字）

pub const EntryPick = struct {
    /// 方言入口文件路径（缺省为 src/main.zz）
    entry: []const u8,
    /// 入口在 args 中的下标；未显式给出（全为旗标/为空）时为 null
    idx: ?usize,
};

/// 从 `[文件.zz] [zig 旗标…]` 里挑出方言入口文件。
/// 判据用「以 `.zz` 结尾」而非「首个非 `-` 参数」：因为 `zig build-exe` 很多旗标
/// 带空格分隔的值（如 `-O ReleaseFast` 中的 `ReleaseFast` 不以 `-` 开头），若按非旗标
/// 位置取入口会误把旗标值当文件，导致 `zzc build -O ReleaseFast` 之类合法透传失败。
/// 没有任何 `.zz` 参数时，入口取默认 `src/main.zz`，全部参数都作为透传旗标。
/// 第 201 轮 D69：后缀判据与默认入口改取 `zzc_paths` 的族真值——旧形制下同一 `.zz`/`src/main.zz`
/// 由本函数与 `main.cmdInit`（建工程写盘）、`main.cmdEject`（硬编入口）、`main` 采集器（筛后缀）
/// 各持一份字面量，写/读是配对契约；探针 P2/P3/P4 单点破坏 main 侧三处均 505/505 全绿（零钉），
/// 漂移后 `zzc init x && zzc run` 报的是「找不到工程目录」而非字面量失配，用户无从归因。
/// 跨模块耦合由本文件尾部「201 T1」的写→读往返锚钉住。
pub fn pickEntry(args: []const []const u8) EntryPick {
    for (args, 0..) |a, i| {
        if (zzc.isDialectSource(a)) return .{ .entry = a, .idx = i };
    }
    return .{ .entry = zzc.default_entry, .idx = null };
}

/// 生成树目录（第 199 轮 D67 抽单一真值、第 200 轮 D68 并入 `.zzc` 族 hub）：旧形制下 `.zzc/gen` 由七处
/// 生产字面量各自硬编——写侧 `genPathFor` 两枚拼串、剥侧 `cmdEject` 两站点各持「前缀串 + 前缀.len」两枚、
/// 镜像根 `collect` 传参一枚。写与剥是一对须字节相等的契约，失配时剥侧走 `else basename` 静默降级、把
/// 导出树的子目录拉平（正是 `cmdEject` 原注释警告的 `@import("sub/mod.zig")` 断链形）。t2 探针实锤本漂移
/// 无测可抓：改剥侧任一点位（前缀串、切长、镜像根）500/500 全绿，唯改写侧目录名被 `genPathFor`
/// 自身的字面量钉抓到（P1–P5，详见 199 轮审计注）。
/// 本名系 `zzc_paths.gen_dir` 的公开面（值与形制一字未改、全员钉在 `zzc_paths` 的 200 T0）。
pub const gen_dir: []const u8 = zzc.gen_dir;

/// 生成树内路径的前缀（含尾分隔符）：由 `gen_dir` 派生，故「前缀串」与「前缀长度」自此同源——
/// 旧形制两枚各自硬编的字面量（其一改动即错位切头）属探针 P3 点位，抽真值后该类漂移不可表示。
pub const gen_dir_prefix: []const u8 = zzc.gen_dir_prefix;

/// 方言入口相对路径 → 生成树内 .zig 落点。
/// 根目录文件直接 `.zzc/gen/<stem>.zig`；带子目录则保留层级 `.zzc/gen/<dir>/<stem>.zig`。
/// 第 60 轮自 main.zig 下沉至测试图（D7：main.zig 的 test 块从不执行、此纯函数此前零有效覆盖）；
/// 激活测时发现旧实现对根目录文件会因 `dirname orelse "."` 产出 `.zzc/gen/./main.zig` 的 `.` 段噪声，按测意图修正。
/// 第 199 轮 D67：目录段改取 `gen_dir` 真值（拼接仍在编译期完成、产物字节不变）。
/// 第 234 轮 D102：落盘名扩展名 `.zig` 改取 `zzc.std_ext` 真值（仍编译期拼接、产物字节不变）——
/// 与 `transpiler/translate.zig` 导入改写的替换形 `std_import_suffix` 同源，两侧不再各写 `.zig` 字面量。
pub fn genPathFor(gpa: std.mem.Allocator, rel: []const u8) ![]const u8 {
    const stem = std.fs.path.stem(std.fs.path.basename(rel));
    if (std.fs.path.dirname(rel)) |dir_of| {
        return std.fmt.allocPrint(gpa, gen_dir ++ "/{s}/{s}" ++ zzc.std_ext, .{ dir_of, stem });
    }
    return std.fmt.allocPrint(gpa, gen_dir ++ "/{s}" ++ zzc.std_ext, .{stem});
}

/// 生成树内相对路径 → 剥掉 `gen_dir_prefix` 后的相对路径（保层级）；前缀失配者回退 basename。
/// 第 199 轮 D67 自 `cmdEject` 下沉：原为两份同体内联逻辑（各持一枚前缀串 + 一枚 `.len`），抽取后
/// 写/剥共用同一真值、两站点合并为单一函数。回退臂系防御面——`gen_rel` 恒由 `genPathFor` 产出，
/// 正常不可达；不可达≠可删（删臂即令任何非本树产物被无条件切掉头 9 字节）故直钉。
pub fn stripGenDir(gen_rel: []const u8) []const u8 {
    if (std.mem.startsWith(u8, gen_rel, gen_dir_prefix)) return gen_rel[gen_dir_prefix.len..];
    return std.fs.path.basename(gen_rel);
}

/// 分隔符无关的相对路径比较（`/` 与 `\` 视为同）。第 60 轮自 main.zig 下沉至测试图。
pub fn samePathRel(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const sa = if (ca == '\\') '/' else ca;
        const sb = if (cb == '\\') '/' else cb;
        if (sa != sb) return false;
    }
    return true;
}

test "genPathFor - 生成文件路径" {
    const gpa = std.testing.allocator;

    // 测试根目录文件
    const path1 = try genPathFor(gpa, "main.zz");
    defer gpa.free(path1);
    try std.testing.expectEqualStrings(".zzc/gen/main.zig", path1);

    // 测试子目录文件
    const path2 = try genPathFor(gpa, "src/sub/mod.zz");
    defer gpa.free(path2);
    try std.testing.expectEqualStrings(".zzc/gen/src/sub/mod.zig", path2);
}

test "samePathRel - 分隔符无关路径比较" {
    // 相同路径
    try std.testing.expect(samePathRel("src/main.zz", "src/main.zz"));

    // 分隔符不同但等价
    try std.testing.expect(samePathRel("src/main.zz", "src\\main.zz"));

    // 不同路径
    try std.testing.expect(!samePathRel("src/main.zz", "src/lib.zz"));
}

test "pickEntry：带值旗标不被误当入口，仅 .zz 作为文件" {
    // 纯旗标带空格值：`-O ReleaseFast` 都不该被当入口，入口回落默认。
    const a = [_][]const u8{ "-O", "ReleaseFast" };
    const pa = pickEntry(&a);
    try std.testing.expectEqualStrings("src/main.zz", pa.entry);
    try std.testing.expectEqual(@as(?usize, null), pa.idx);

    // 文件在首位：入口命中下标 0。
    const b = [_][]const u8{ "src/main.zz", "--strip" };
    const pb = pickEntry(&b);
    try std.testing.expectEqualStrings("src/main.zz", pb.entry);
    try std.testing.expectEqual(@as(?usize, 0), pb.idx);

    // 旗标在前、文件在后（合法透传顺序）：入口应命中下标 1，而非把 `-O`/值误当文件。
    const c = [_][]const u8{ "-O", "ReleaseFast", "src/sub/mod.zz" };
    const pc = pickEntry(&c);
    try std.testing.expectEqualStrings("src/sub/mod.zz", pc.entry);
    try std.testing.expectEqual(@as(?usize, 2), pc.idx);

    // 无参数：默认入口、无下标。
    const d: []const []const u8 = &.{};
    const pd = pickEntry(d);
    try std.testing.expectEqualStrings("src/main.zz", pd.entry);
    try std.testing.expectEqual(@as(?usize, null), pd.idx);
}

/// 旗标解析真相源（R9g，第 103 轮泛化）：取 `--<name> <值>`（两参形）或 `--<name>=<值>`（等号形）的值；
/// 纯查询、不改入参；无则 null。缺值裸旗标（末尾无后继）视为 null（由调用方处置）。
/// 全等匹配 + 等号前缀匹配：`--lang` 不会误匹 `--lang-file`（非全等且非 `--lang=` 前缀）。
pub fn findFlag(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, name)) {
            return if (i + 1 < args.len) args[i + 1] else null;
        }
        // 等号形无堆分配：直接按字节位置判 `=`（`--lang=x` 不会被 `--lang-file` 误匹）。
        if (a.len > name.len and a[name.len] == '=' and std.mem.startsWith(u8, a, name)) {
            return a[name.len + 1 ..];
        }
    }
    return null;
}

/// 剔离 `--<name> <值>`（两参形）/`--<name>=<值>`（一参形），返回新 ArrayList（元素借用自 args、仅本体分配）。
/// 目的：zzc 层旗标不得透传给 zig。缺值裸旗标（末尾）一并剔离。无旗标时返回逐元素等长的原样副本。
pub fn stripFlag(gpa: std.mem.Allocator, args: []const []const u8, name: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, name)) {
            i += 2; // 连同其值一起剔离（末尾裸旗标时 i+=2 自然出循环）
            continue;
        }
        if (a.len > name.len and a[name.len] == '=' and std.mem.startsWith(u8, a, name)) {
            i += 1;
            continue;
        }
        try out.append(gpa, a);
        i += 1;
    }
    return out;
}

/// R9：从 zzc 层参数里取 `--lang <name>` 或 `--lang=<name>` 的语言名（纯查询、不改入参；无则 null）。
/// 语言名缺值（`--lang` 处于末尾且无后继）视为 null（由调用方按未选包处理）。
pub fn findLangFlag(args: []const []const u8) ?[]const u8 {
    return findFlag(args, flag_lang);
}

/// R9g（第 103 轮）：取 `--lang-file <路径>` 外部语言包文件旗标（第三方发行包运行时加载、免重编译）。
pub fn findLangFileFlag(args: []const []const u8) ?[]const u8 {
    return findFlag(args, flag_lang_file);
}

// ---------------------------------------------------------------------------
// 布尔旗标（第 154 轮 · 编辑器/CI 机读集成）
// 与带值旗标的分野：布尔旗标只认**单元素形** `--machine`。等号形 `--machine=1` 故意不识别、
// 也不剔离——半截布尔语义（`0`/`false`/`no` 要不要算关？）无权威判据，交由下游 zig 明确报
// 「未知参数」比 zzc 自作主张更诚实（同 R9g「旗标不得透传 zig」契约仅覆盖 zzc 真实消费的形）。
// ---------------------------------------------------------------------------

/// 布尔旗标在场判定：仅当参数列表里有**恰等于** `name` 的单元素时为真（纯查询、不改入参）。
/// 全等匹配：`--machine` 不会误匹 `--machine-x`，也不会误匹 `--machine=1`（后者非全等、按上注不识别）。
pub fn hasBoolFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// 剔离布尔旗标单元素形（zzc 层旗标不得透传 zig 契约）。无该旗标时返回逐元素等长的原样副本。
pub fn stripBoolFlag(gpa: std.mem.Allocator, args: []const []const u8, name: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) continue;
        try out.append(gpa, a);
    }
    return out;
}

/// 从参数列表剔离 `--lang <name>`（两参形）/`--lang=<name>`（一参形），返回新 ArrayList（元素借用自 args、仅本体分配）。
/// 目的：`--lang` 是 zzc 层旗标，不能透传给 zig。缺值的裸 `--lang`（末尾）一并剔离。无旗标时返回逐元素等长的原样副本。
pub fn stripLangFlag(gpa: std.mem.Allocator, args: []const []const u8) !std.ArrayList([]const u8) {
    return stripFlag(gpa, args, flag_lang);
}

/// R9g：剔离 `--lang-file`（两参/等号形）——同不透传 zig 契约。
pub fn stripLangFileFlag(gpa: std.mem.Allocator, args: []const []const u8) !std.ArrayList([]const u8) {
    return stripFlag(gpa, args, flag_lang_file);
}

test "findLangFlag / stripLangFlag：两参与等号形都识别，剔离后不透传 zig" {
    const gpa = std.testing.allocator;
    const a = [_][]const u8{ "check", "src/main.zz", "--lang", "zh", "-O", "Debug" };
    try std.testing.expectEqualStrings("zh", findLangFlag(&a).?);
    var s = try stripLangFlag(gpa, &a);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), s.items.len);
    try std.testing.expectEqualStrings("src/main.zz", s.items[1]);
    try std.testing.expectEqualStrings("-O", s.items[2]);

    const e = [_][]const u8{ "--lang=中文", "src/main.zz" };
    try std.testing.expectEqualStrings("中文", findLangFlag(&e).?);
    var s2 = try stripLangFlag(gpa, &e);
    defer s2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s2.items.len);
    try std.testing.expectEqualStrings("src/main.zz", s2.items[0]);

    // 无旗标：null + 原样副本。
    const n = [_][]const u8{ "build", "-Doptimize=Release" };
    try std.testing.expectEqual(@as(?[]const u8, null), findLangFlag(&n));
    var s3 = try stripLangFlag(gpa, &n);
    defer s3.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), s3.items.len);

    // 缺值裸 --lang（末尾）：findLangFlag null、仍剔离。
    const d = [_][]const u8{ "run", "--lang" };
    try std.testing.expectEqual(@as(?[]const u8, null), findLangFlag(&d));
    var s4 = try stripLangFlag(gpa, &d);
    defer s4.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s4.items.len);
}

test "R9g findFlag/stripFlag：--lang-file 两参/等号形识别；同族前缀旗标互不误匹" {
    const gpa = std.testing.allocator;
    const a = [_][]const u8{ "check", "--lang-file", "包/外.txt", "--lang", "zh" };
    // --lang 查询不得误匹 --lang-file（全等形取后继、等号形需 `=` 位）；两旗标各取所得。
    try std.testing.expectEqualStrings("包/外.txt", findLangFileFlag(&a).?);
    try std.testing.expectEqualStrings("zh", findLangFlag(&a).?);
    var s = try stripLangFlag(gpa, &a);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), s.items.len); // 仅剔 --lang zh，--lang-file 照留
    try std.testing.expectEqualStrings("--lang-file", s.items[1]);
    var s2 = try stripLangFileFlag(gpa, s.items);
    defer s2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s2.items.len); // 串接剔离：两 zzc 旗标都连值不透传，仅剩 check
    try std.testing.expectEqualStrings("check", s2.items[0]);

    // 等号形 + 裸尾缺值形。
    const e = [_][]const u8{ "--lang-file=/tmp/外.zzpack", "src/main.zz" };
    try std.testing.expectEqualStrings("/tmp/外.zzpack", findLangFileFlag(&e).?);
    const d = [_][]const u8{ "build", "--lang-file" };
    try std.testing.expectEqual(@as(?[]const u8, null), findLangFileFlag(&d));
    var s3 = try stripLangFileFlag(gpa, &d);
    defer s3.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s3.items.len);
}

test "护栏：旗标等号空值形边界——`--lang=`/`--lang-file=` 返回空串非 null、与裸尾缺值形语义相反（第 110 轮证伪落位）" {
    // 承 108/109 轮方法论：findFlag 的「等号空值」形（`--name=`）此前零覆盖——既有测只钉
    // 两参形、等号非空形、无旗标 null、裸尾缺值 null。本形语义微妙：`--lang=` 令 findLangFlag
    // 返回空串 ""（非 null），caller 据此按「未知语言包『』」母语提示 exit 2（非回落默认包）；
    // 而裸尾 `--lang`（无 `=`）才 null→回落默认。二者语义相反、须钉住防重构漂移（若 findFlag
    // 被改成对空值也返回 null，`--lang=` 会静默改用默认包、用户显式空输入被无声吞掉）。
    const gpa = std.testing.allocator;

    // 等号空值：返回 ""（空切片、非 null）。
    const l = [_][]const u8{"--lang="};
    const lr = findLangFlag(&l);
    try std.testing.expect(lr != null); // 关键：非 null
    try std.testing.expectEqualStrings("", lr.?);
    // 末位等号空值亦 ""（等号形自含、不要求后继元素）。
    const l2 = [_][]const u8{ "check", "--lang=" };
    try std.testing.expectEqualStrings("", findLangFlag(&l2).?);

    // --lang-file= 同形。
    const lf = [_][]const u8{"--lang-file="};
    try std.testing.expectEqualStrings("", findLangFileFlag(&lf).?);

    // 裸尾缺值（无 `=`）：null（与等号空值形语义相反）——补 findLangFileFlag 同形对照。
    const d = [_][]const u8{ "build", "--lang-file" };
    try std.testing.expectEqual(@as(?[]const u8, null), findLangFileFlag(&d));

    // strip 侧：等号空值形仍须剔离（不透传给 zig）。
    var s = try stripLangFlag(gpa, &[_][]const u8{ "check", "--lang=" });
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s.items.len);
    try std.testing.expectEqualStrings("check", s.items[0]);

    // 等号值内含 `=`：取首个 `=` 后全部（非只到第二个 `=`）。
    const v = [_][]const u8{"--lang=a=b"};
    try std.testing.expectEqualStrings("a=b", findLangFlag(&v).?);
}

/// 判断 `eject` 目标 `dest` 是否会与方言源码树 `src` 重叠、或越出当前工程根——
/// 命中即危险：`eject` 重写前会先清空 `dest/src`，若该路径就是真实 `src`（或包含它），
/// 会直接删除用户的 `.zz` 源文件（数据丢失）。按分隔符分段比较（避免 `src2` 误判为 `src` 之下）、
/// 忽略 `./` 噪声与多余斜杠。危险情形：空/根相对绝对路径/盘符绝对（`X:` 起头，D39 补齐）、等价于 cwd（`.`）、上溯出 cwd（`..`）、
/// 或 dest 就是 `src`/其子目录。eject 的本意是导出到独立子目录，故这些都拒绝。
pub fn ejectDestHitsSourceTree(dest: []const u8) bool {
    if (dest.len == 0) return true; // 空目标 → `dest/src` 形如 `/src`，行为不定
    if (dest[0] == '/' or dest[0] == '\\') return true; // 根相对/绝对，非工程子目录
    // D39（第 90 轮）：盘符绝对形 `C:/out`、`D:\work\src` 旧形漏检被放行——guard 是 cmdEject
    // 对 dest/src 无条件 deleteTree 前的唯一闸门，漏检即真实删除工程外目录（不可逆数据销毁）。
    // 段扫判据也拦不住：首实段是 `D:` 而非 `src`，at_src_root/has_escaped 双落空——须头检 `:`。
    // 孪生 initNameIsUnsafe/embedPathStaysWithin 均有同款检查，本轮补齐对称。
    if (dest.len >= 2 and dest[1] == ':') return true; // 盘符绝对（含非法目录名形，拒绝从严）
    var any_real_seg = false;
    var has_escaped = false;
    var at_src_root = false;
    var first_real = true;
    var it = std.mem.tokenizeAny(u8, dest, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue; // `./x` 里的当前目录噪声
        any_real_seg = true;
        if (std.mem.eql(u8, seg, "..")) has_escaped = true;
        if (first_real and std.mem.eql(u8, seg, zzc.src_dir)) at_src_root = true; // 第 204 轮 D72：毁源闸门比的是族真值，非本模块另抄的 "src"
        first_real = false;
    }
    if (!any_real_seg) return true; // 全是 `.`/斜杠 → 等价于 cwd → `dest/src == src`
    if (has_escaped) return true; // 上溯出 cwd，可能删/写兄弟项目的 src
    if (at_src_root) return true; // dest 就是 src 或其子目录 → 覆盖源码树
    return false;
}

test "ejectDestHitsSourceTree：拒绝会毁源的目标，放行独立子目录" {
    // 危险（会导致 deleteTree 误删源码或写进源码树）：
    try std.testing.expect(ejectDestHitsSourceTree(".")); // dest/src == src
    try std.testing.expect(ejectDestHitsSourceTree("")); // 空目标
    try std.testing.expect(ejectDestHitsSourceTree("src")); // 直接写进源码目录
    try std.testing.expect(ejectDestHitsSourceTree("src/sub")); // 源码树子目录
    try std.testing.expect(ejectDestHitsSourceTree("..")); // 上溯出 cwd
    try std.testing.expect(ejectDestHitsSourceTree("../x")); // 上溯出 cwd
    try std.testing.expect(ejectDestHitsSourceTree("/abs/out")); // 根相对/绝对
    // D39（第 90 轮）盘符绝对形：旧实现只拦前导 `/` `\`，`C:/out` 被放行 → cmdEject 随后
    // 对 dest/src 无条件 deleteTree → 真实删除工程外目录（不可逆数据销毁）；
    // 孪生 initNameIsUnsafe/embedPathStaysWithin 均有 `:` 检查，独此缺失。
    try std.testing.expect(ejectDestHitsSourceTree("C:/out")); // 盘符绝对（Windows）
    try std.testing.expect(ejectDestHitsSourceTree("D:/work/src")); // 盘符+恰名 src 子目录（首实段是 `D:` 非 src、旧形双漏）
    try std.testing.expect(ejectDestHitsSourceTree("./")); // 归一后等价于 cwd
    try std.testing.expect(ejectDestHitsSourceTree(".\\src\\")); // Windows 分隔符同义
    // 安全（工程根下的独立子目录）：
    try std.testing.expect(!ejectDestHitsSourceTree("standard"));
    try std.testing.expect(!ejectDestHitsSourceTree("out"));
    try std.testing.expect(!ejectDestHitsSourceTree("./build-out")); // `./` 噪声不影响判定
    try std.testing.expect(!ejectDestHitsSourceTree("a/b")); // 多级子目录
    try std.testing.expect(!ejectDestHitsSourceTree("src2")); // 前缀相似但非 src 之下
    try std.testing.expect(!ejectDestHitsSourceTree("my/src")); // src 不是首段 → 与源码树不相交
}

/// 模板逐段 emit 助手：zig 0.17 禁局部 fn，而 `串 ++ 运行期切片` 又不可编译（++ 要两侧
/// comptime 已知）——本模块唯一的运行期拼接通道，按片段序列依序 append。
fn appendTemplateSegs(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), segs: []const []const u8) !void {
    for (segs) |seg| try buf.appendSlice(gpa, seg);
}

/// `zzc init` 写出的脚手架入口模板生成器（按所选语言包组词）。
/// D48（第 104 轮）：模板自 main.zig cmdInit 下沉至此进测试图——模板恒须通过自家
/// 纯母语门（findEnglishWordForms 零违例，有测钉住）；旧位在 main（不入图）历轮 dogfood
/// 清单漏网，模板硬编码 ASCII `void` 被 99 轮纯度门拒——工具自建脚手架出生即自检不过。
///
/// 第 142 轮（拍板项⑤模板脚手架 i18n）：常量 `initTemplate` 改为生成器 `buildInitTemplate(lang)`。
/// 缺陷形：旧常量恒为中文词形，选非中文包时 `zzc init` 出生即碎码（探针实锤：`zzc init pj
/// --lang-file 外语包` 后 `zzc check` 报「期望 ',' after field」退 1——中文词元全被 intern、
/// `const z_1 z_2 = ...` 非法）——D48 同根因跨包另一形。原则：**工具侧不硬编码任何方言词、
/// 判据全取自包**（与 D44 反查同一语言无关原则）：结构词只用 B6 契约 13 值（必可反查）；
/// 非契约词缺则降级——`pub` 缺则 ASCII 直通（zig 硬性要求 `pub fn main`，探针实锤非公开入口
/// 编译拒「'main' is not marked 'pub'」——降级 ASCII 是唯一合法兜底，而纯度门对其天然不拦）；
/// `void` 缺则 ASCII 直通（无映射即不可坐实、纯度门天然不拦）；名字/入口/打印词反查
/// `std`/`main`/`std.debug.print`（keywords ∪ aliases，多段 alias 键整体作点分链可用），
/// 未命中落 ASCII 直通形/逐段回退链。演示文案取大白话（用户口径 142）；注释/串不参与翻译。
/// 降级到 ASCII 属可用性优先：碎码不是合法兜底项（探针 T2 坐实旧行为即碎码）。
pub fn buildInitTemplate(gpa: std.mem.Allocator, lang: Pack) ![]const u8 {
    // 非 ASCII 词元可直通 intern 成名（跨文件一致）——名字槽位用方言词兜 ASCII 皆合法。
    const w_const = Pack.firstKeywordFor(lang, "const") orelse "const";
    const w_var = Pack.firstKeywordFor(lang, "var") orelse w_const; // 无 var 词形则退常宣声明（literal 推导合法）
    const w_fn = Pack.firstKeywordFor(lang, "fn") orelse "fn";
    const w_import = Pack.firstKeywordFor(lang, "@import") orelse "@import";
    const w_pub = Pack.firstKeywordFor(lang, "pub") orelse "pub"; // 入口必 pub（zig 硬要求），缺则 ASCII 直通
    const w_main = Pack.firstKeywordFor(lang, "main") orelse "main";
    const w_std = Pack.firstKeywordFor(lang, "std") orelse "std";
    const w_void = Pack.firstKeywordFor(lang, "void") orelse "void";
    // 类型注必存在：`var 名 = 10` 无显式定宽类型→zig 视其为 comptime_int、再赋值拒
    // 「must be given an explicit fixed-size number type」（探针复跑自捕三）——缺则 ASCII
    // 直通 `i64`（与 pub/void 同定③：降级 ASCII 是唯一合法兜底、纯度门对其天然不拦）。
    const w_i64 = Pack.firstKeywordFor(lang, "i64") orelse "i64";
    // 打印调用三形择优：叶子别名（值恰为 std.debug.print）> 模块链（std→std.debug 两段皆方言、
    // 链止于 ASCII 成员 print 逐段回退）> ASCII 全链。注意 w_std 已兑 ASCII、不可用作「包真有
    // std 方言名」判据——初版以 `w_std != null` 判系把已 orelse 兑底的量当可选比较，编译即拒。
    const opt_std = Pack.firstKeywordFor(lang, "std");
    const opt_std_dbg = Pack.firstKeywordFor(lang, "std.debug");
    const print_callee = if (Pack.firstKeywordFor(lang, "std.debug.print")) |w| w else if (opt_std != null and opt_std_dbg != null)
        std.fmt.allocPrint(gpa, "{s}.{s}", .{ opt_std.?, opt_std_dbg.? }) catch return error.OutOfMemory
    else
        "std.debug.print";
    const count_name = "数"; // 大白话名（任意包的合法方言标识符，intern 稳定）

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const A = appendTemplateSegs;
    try A(gpa, &out, &.{"// " ++ zzc.prog_name ++ " 方言工程模板 —— 进入目录后运行 `" ++ zzc.prog_name ++ " " ++ sub_run ++ "` 即可\n\n"});
    try A(gpa, &out, &.{ w_const, " ", w_std, " = ", w_import, "(\"std\");\n\n" });
    try A(gpa, &out, &.{ w_pub, " ", w_fn, " ", w_main, "() !", w_void, " {\n" });
    try A(gpa, &out, &.{ "    ", w_var, " ", count_name, ": ", w_i64, " = 10;\n" });
    try A(gpa, &out, &.{ "    ", count_name, " = ", count_name, " + 1;\n" });
    // 串内 `{d}\n` 必为**字面两字符**（旧模板多行字面量形即如此；zig 拒绝串字面量里的真换行字节——
    // 初版误写 `\n` 落成真换行，探针复跑 check 坐实「string literal contains invalid byte: '\n'」自捕）。
    try A(gpa, &out, &.{ "    ", print_callee, "(\"结果是 {d}\\n\", .{", count_name, "});\n" });
    try A(gpa, &out, &.{"}\n"});
    return out.toOwnedSlice(gpa);
}

/// 判断 `init` 的工程名是否不安全（会在预期之外的位置建目录/写文件）。
/// 不安全：空、以分隔符开头（根相对/绝对）、含 `:`（盘符或非法目录名）、任一 `.` 或 `..` 段
/// （包括裸 `.`/`..` 与上溯 `../x`）。放行普通名字与多级子目录 `a/b`（均为真实段名）。
/// 与 ejectDestHitsSourceTree 同为“命令入参路径策略”，放同一模块便于单测。
pub fn initNameIsUnsafe(name: []const u8) bool {
    if (name.len == 0) return true; // 空名 → `name/src/main.zz` 形如 `/src/…`，行为不定
    if (name[0] == '/' or name[0] == '\\') return true; // 根相对/绝对
    if (std.mem.indexOfScalar(u8, name, ':') != null) return true; // 盘符/含冒号的非法目录名
    var it = std.mem.tokenizeAny(u8, name, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

test "initNameIsUnsafe：拒绝空/绝对/上溯/裸点，放行普通名与多级子目录" {
    try std.testing.expect(initNameIsUnsafe("")); // 空
    try std.testing.expect(initNameIsUnsafe(".")); // 当前目录
    try std.testing.expect(initNameIsUnsafe("..")); // 上溯
    try std.testing.expect(initNameIsUnsafe("../x")); // 上溯到外部
    try std.testing.expect(initNameIsUnsafe("a/../b")); // 中部上溯
    try std.testing.expect(initNameIsUnsafe("/abs")); // 根相对/绝对
    try std.testing.expect(initNameIsUnsafe("C:\\out")); // Windows 盘符
    try std.testing.expect(initNameIsUnsafe("./x")); // 含 `.` 段
    // 安全：
    try std.testing.expect(!initNameIsUnsafe("myapp"));
    try std.testing.expect(!initNameIsUnsafe("a/b")); // 多级子目录（均真实段）
    try std.testing.expect(!initNameIsUnsafe("中文工程名")); // 非 ASCII 名字合法
}

/// 把常见的文件系统/内存类错误映射成母语可操作提示；未收录者返回 null（由调用方走
/// 通用兜底）。存在的理由：`bail` 的 `else` 分支旧版直接 `内部错误: {英文错误名}`（实测
/// `zzc eject <已存在文件>` → `内部错误: NotDir`），把与方言用户无关的 Zig 内部英文标识符
/// 和盘符/路径细节原样泄漏，违背“母语报错”的核心承诺。放测试图内的 cli 模块以便
/// 单测真正执行。此处只按错误码归类措辞，不重复具体路径（路径细节由上文命令自身已给出）。
pub fn localizeFsErr(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.FileNotFound, error.PathNotFound => "找不到所需的文件或目录；请确认已在方言工程根目录运行、且路径/名称拼写正确。",
        error.AccessDenied, error.PermissionDenied => "权限不足，无法读写所需位置；请检查文件/目录权限，或换一个可写目录。",
        error.NotDir => "路径中本应是目录的一段其实是一个文件，无法在其下创建目录；输出/导出目标名请勿与已存在的文件同名（删掉同名文件或换个目标名）。",
        error.IsDir => "要写成的目标位置其实是一个目录；请改用不同的文件名或输出目录。",
        error.NoSpaceLeft => "磁盘空间不足，无法写出；请清理磁盘后重试。",
        error.DiskQuota => "磁盘配额已满，无法写出；请清理文件或联系管理员。",
        error.NameTooLong => "文件或目录名过长；请缩短工程名/输出路径。",
        error.ReadOnly => "目标位于只读文件系统，无法写入；请换一个可写目录。",
        error.DeviceBusy, error.FileBusy => "文件正被其他程序占用；请关闭占用它的程序（编辑器/杀毒软件等）后重试。",
        error.SymLinkLoop => "遇到相互指向的符号链接（路径成环）；请避免在工程目录使用符号链接。",
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "系统资源或文件句柄不足；请关闭其他程序后重试。",
        error.InputOutput => "发生底层输入/输出错误（磁盘或系统故障）；请检查存储设备后重试。",
        error.OutOfMemory => "内存不足，无法完成本次编译；请关闭其他程序后重试。",
        else => null,
    };
}

test "localizeFsErr：常见错误给母语提示、未收录返回 null 走兜底" {
    // 常见文件系统/内存错误应命中并返回非空中文提示（绝不泄漏英文标识符）。
    for ([_]anyerror{
        error.FileNotFound,
        error.PathNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.NotDir,
        error.IsDir,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.NameTooLong,
        error.ReadOnly,
        error.DeviceBusy,
        error.FileBusy,
        error.SymLinkLoop,
        error.SystemResources,
        error.InputOutput,
        error.OutOfMemory,
    }) |e| {
        const zh = localizeFsErr(e);
        try std.testing.expect(zh != null);
        try std.testing.expect(zh.?.len > 0);
    }
    // 未收录的错误返回 null，交调用方走通用兜底（不在此表里穷举所有 anyerror）。
    try std.testing.expect(localizeFsErr(error.StreamTooLong) == null);
    try std.testing.expect(localizeFsErr(error.OutOfMemory) != null); // 反向确认已收录
}

// ── 用户可见子命令名的单一真值（第 206 轮 D74）───────────────────────────────
// main.zig dispatch 的路由字面量、下方 usage_text 帮助行、完备性单测三面的共同出处。
// 旧态三处脱钩：roster 手抄 8 名已静默漏 version；usage 检查走 indexOf 宽松子串、被
// build-exe 之类附带出现蒙混（P3 探针：改名帮助命令词仍全绿）；dispatch 与名表无对账
// （P2 探针：改 dispatch 的 eject 臂名，运行期 `zzc eject` 落未知兜底而 527/527 恒绿）。
// 自此一名一处定义：改名须动本表，usage 与 dispatch 各自转红。
pub const sub_init: []const u8 = "init";
pub const sub_check: []const u8 = mcon.sub_check; // 与机读契约 hub 同源（LSP 自调用 argv）
pub const sub_build: []const u8 = "build";
pub const sub_run: []const u8 = "run";
pub const sub_test: []const u8 = "test";
pub const sub_eject: []const u8 = "eject";
pub const sub_lsp: []const u8 = "lsp";
pub const sub_lang: []const u8 = "lang";
pub const sub_version: []const u8 = "version";

/// 受支持子命令名的穷举表：dispatch 各臂、帮助行命令词、完备测三者对账的单一真值。
pub const subcommands = [_][]const u8{
    sub_init, sub_check, sub_build, sub_run, sub_test, sub_eject, sub_lsp, sub_lang, sub_version,
};

/// cmd 是否为受支持的用户子命令（未知子命令兜底与完备测的共同判据）。
pub fn isKnownSubcommand(cmd: []const u8) bool {
    for (subcommands) |sub| {
        if (std.mem.eql(u8, cmd, sub)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// CLI 旗标名单一真值（第 207 轮 · D75）：zzc 层消费的旗标此前散成多副本——`--machine`
// 独归 mcon.flag_machine，`--lang`/`--lang-file` 在 args 的 find 站与 strip 站各存裸字面量
// （两副本），`--as` 是 main.zig 的一枚孤裸字面量且全仓零测覆盖（P1 探针：改 `--as` 臂字面量，
// 运行期 `zzc lang add f --as mykey` 静默按 $code 注册成 tst-ja.txt 而 530/530 恒绿、退 0）。
// 自此一旗一名一定义：find/strip/help 三方读同表，改名须动本表、各转红。
// ---------------------------------------------------------------------------

/// `--lang <名>`：选择语言包（zzc 层旗标、不透传 zig，须与 strip 站同源）。
pub const flag_lang: []const u8 = "--lang";
/// `--lang-file <路径>`：从外部文件加载语言包（R9g 第二档、免重编译）。
pub const flag_lang_file: []const u8 = "--lang-file";
/// `--machine`：把母语报错压成单行机读形制（与机读契约 hub 同源）。
pub const flag_machine: []const u8 = mcon.flag_machine;
/// `--as <注册名>`：`zzc lang add` 指定装入工程的注册名（此前全仓零测覆盖的孤点，D75 主靶）。
pub const flag_as: []const u8 = "--as";

/// zzc 层真实消费的旗标穷举表：find/strip 站与帮助行正向对账的单一真值。
pub const zzc_flags = [_][]const u8{ flag_lang, flag_lang_file, flag_machine, flag_as };

/// name 是否为 zzc 层旗标（帮助行正向对账与判据的共同真值）。
pub fn isZzcFlag(name: []const u8) bool {
    for (zzc_flags) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

test "第 207 轮 T0 旗标单一真值自守：名两两不同 + machine 与 hub 同源 + isZzcFlag 正反 + --as 在册" {
    // 真值表自守：任一旗标名与另一枚相等（手抄/复制漏改）即红。
    for (zzc_flags, 0..) |a, i| {
        for (zzc_flags[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
    // --machine 与机读契约 hub 同源（防两处各写一份漂移）。
    try std.testing.expectEqualStrings(mcon.flag_machine, flag_machine);
    // 在册判据正反：真旗标命中、漂移名与近名不误入。
    try std.testing.expect(isZzcFlag(flag_as));
    try std.testing.expect(isZzcFlag(flag_lang));
    try std.testing.expect(isZzcFlag(flag_lang_file));
    try std.testing.expect(!isZzcFlag("--aat")); // P1 探针漂移名不得算真旗标
    try std.testing.expect(!isZzcFlag("--lng")); // P2/P3 探针漂移名
    try std.testing.expect(!isZzcFlag("--machine-x")); // 近名不误入（宽度未放宽）
}

test "第 207 轮 T1 --as 往返：findFlag 按常量取注册名（此前 --as 零测覆盖的回归钉）" {
    // D75 主锚：`--as <名>` 此前全仓无任何测覆盖其解析，P1 探针坐实改名静默失效。
    // 自此以常量组 argv 验 findFlag 取到值、缺省取 null（回落 $code 的判据）。
    const argv = [_][]const u8{ "add", "包/外.txt", flag_as, "mykey" };
    const got = findFlag(&argv, flag_as) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("mykey", got);
    const none = [_][]const u8{ "add", "包/外.txt" };
    try std.testing.expectEqual(@as(?[]const u8, null), findFlag(&none, flag_as));
}

test "第 207 轮 T2 帮助行正向对账：zzc 消费的每枚旗标都须在 usage 文档化（漏文档即红）" {
    // 正向：代码真实消费的旗标必在帮助文本出现——新加旗标忘写帮助 / 改名漏改帮助 即红。
    // 反向（帮助里的幽灵旗标）因 usage 含说明性近名（--machine-x 等）与示例（--summary/--system）
    //   无法逐 token 干净枚举，形等价面登为在册续项、本测不覆盖。
    for (zzc_flags) |f| {
        try std.testing.expect(std.mem.indexOf(u8, usage_text, f) != null);
    }
}

/// CLI 帮助文本（无参/未知子命令时回显）。属 CLI 表面数据，放在测试图内的 cli 模块以便
/// "子命令列表完整性"回归单测能真正执行（第 181 轮起 main.zig 亦入 main 测试图，见 build.zig）。
pub const usage_text =
    \\zzc —— 用母语编写真正的 Zig（方言编译器 v0.1.0）
    \\
    \\用法：
    \\  zzc init <项目名>      创建母语工程（src/main.zz 模板）
    \\  zzc check [文件.zz]    翻译 + 词法/编译检查（母语报错）
    \\  zzc build  [文件.zz]   翻译 -> zig build-exe（其余参数透传 zig）
    \\  zzc run    [文件.zz]   编译并运行；`--` 之后传给程序
    \\  zzc test   [文件.zz]   翻译 -> zig test
    \\  zzc eject  [目录]      导出标准 Zig 工程（默认 standard/）
    \\  zzc lsp                启动 LSP 服务器（JSON-RPC over stdio：悬停/快路诊断/文档同步；stdout 专供协议帧）
    \\  zzc lang               列出当前语言包与可注册包
    \\  zzc lang add <文件>   装入外部语言包到本工程（--as 注册名 可选；免重编译）
    \\  zzc version            版本与当前语言包
    \\选项：
    \\  --lang <名>            选择语言包（如 zh / 中文；缺省为中文；该旗标不透传 zig）
    \\  --lang-file <路径>     从外部文件加载语言包（第三方发行包、免重编译；与 --lang 互斥；不透传 zig）
    \\  --machine              把母语报错压成单行机读形制 `路径:行:列: 种类: 消息（提示：…）`（编辑器/CI 逐行正则消费；不透传 zig）
    \\方言文件默认取 src/main.zz；错误标签与 std 错误名保持 ASCII 原样。
;

test "usage 帮助命令词与子命令单一真值表双向对账（第 206 轮 D74）" {
    // 旧测用 indexOf(usage_text, sub) 宽松子串：命令名可在 build-exe、路径等处附带
    // 出现而假绿。此处逐行解析形如 `  zzc <词>` 的命令词行做集合双向对账——正向钉「每个
    // 真值表名必有帮助命令词行」（P1 删 version 行→红），反向钉「帮助命令词不含表外名」
    // （P4 加幽灵 frob 行→红）；行首锚定使改名（P3 build→buil 留 build-exe 子串）→红。
    var hit: [subcommands.len]bool = std.mem.zeroes([subcommands.len]bool);
    var unknown_words: usize = 0;
    var it = std.mem.splitScalar(u8, usage_text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  zzc ")) continue;
        const word = std.mem.sliceTo(line["  zzc ".len..], ' ');
        var found = false;
        for (subcommands, 0..) |sub, i| {
            if (std.mem.eql(u8, sub, word)) {
                hit[i] = true;
                found = true;
            }
        }
        if (!found) unknown_words += 1;
    }
    for (hit, subcommands) |h, sub| {
        if (!h) std.debug.print("子命令 {s} 在 usage_text 缺帮助命令词行\n", .{sub});
        try std.testing.expect(h);
    }
    try std.testing.expectEqual(@as(usize, 0), unknown_words);
}

test "第 210 轮 T1 帮助命令词与程序名单一真值耦合：每枚子命令都有 `  <prog_name> <子命令>` 行（防 prog_name 改名而帮助仍写旧名）" {
    // usage_text 大串里的程序名手抄点不便逐处重构，此处以 `prog_name` 拼出命令词行前缀、要求每枚子命令都有
    // 一条命中行——若 prog_name 改名而 usage 字面量未跟（旧名残留），预期前缀无任何命中 → 红；反之若改
    // 了程序名而忘改某行命令词，该子命令无命中 → 红。把「帮助里的程序名」从静默手抄转为受真值表耦合的锚。
    const cmd_prefix = "  " ++ zzc.prog_name ++ " ";
    var cmd_line_words: usize = 0;
    var hit: [subcommands.len]bool = std.mem.zeroes([subcommands.len]bool);
    var it = std.mem.splitScalar(u8, usage_text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, cmd_prefix)) continue;
        cmd_line_words += 1;
        const word = std.mem.sliceTo(line[cmd_prefix.len..], ' ');
        for (subcommands, 0..) |sub, i| {
            if (std.mem.eql(u8, sub, word)) hit[i] = true;
        }
    }
    // prog_name 改名而 usage 字面量未跟 → cmd_prefix 无命中行（cmd_line_words==0、hit 全未置）→ 红。
    try std.testing.expect(cmd_line_words > 0);
    for (hit, subcommands) |h, sub| {
        if (!h) std.debug.print("子命令 {s} 缺以程序名「{s}」起头的帮助命令词行\n", .{ sub, zzc.prog_name });
        try std.testing.expect(h);
    }
    // 抬头行 `zzc —— …` 亦以程序名起头（改名而抬头不跟 → 红）。
    try std.testing.expect(std.mem.indexOf(u8, usage_text, zzc.prog_name ++ " ——") != null);
}

test "第 211 轮 T1 帮助抬头版本记号与产品版本族耦合：抬头含「方言编译器 v<zzc_version>」（防升代而抬头仍写旧版）" {
    // usage 抬头里 `v0.1.0` 系产品版本的手抄点之一（t2 探针 P4 实锤改它而 549/549 恒绿），与 210 T1
    // 同形制不重构大串、以族真值拼出完整记号段要求命中：升代（改 hub）而抬头不跟 → 红。
    const want = "（方言编译器 " ++ zzc.zzc_version_token ++ "）";
    try std.testing.expect(std.mem.indexOf(u8, usage_text, want) != null);
}

test "第 212 轮 T0 init 模板头注释与程序名×子命令名单源耦合：直调 buildInitTemplate 产物头含派生段（防落盘文案手抄漂移误导用户）" {
    // 模板头写进用户工程 src/main.zz（第 212 轮 D80：t2 探针 P2 实锤旧手抄形改它而 553/553 恒绿、
    // 真跑 init 落盘 `zzq run` 误导行而全链无感）：委派后产物必随族真值同动，此处钉两份派生段。
    const registry = @import("../lang/registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, registry.defaultEntry().bytes);
    defer lang.deinit();
    const text = try buildInitTemplate(gpa, lang);
    try std.testing.expect(std.mem.indexOf(u8, text, "// " ++ zzc.prog_name ++ " 方言工程模板") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "运行 `" ++ zzc.prog_name ++ " " ++ sub_run ++ "` 即可") != null);
}

test "子命令单一真值表自守：名无重复、check 与机读 hub 同源、判据正反（第 206 轮 D74）" {
    // 真值表内部一致性：九名两两不同（防手滑重复）。
    for (subcommands, 0..) |a, i| {
        for (subcommands[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
    // check 臂与机读契约 hub 同源：改任一必转红。
    try std.testing.expectEqualStrings(mcon.sub_check, sub_check);
    // isKnownSubcommand 正/反：表内皆真、表外（幽灵名与空串）皆假。
    for (subcommands) |sub| try std.testing.expect(isKnownSubcommand(sub));
    try std.testing.expect(!isKnownSubcommand("frobnicate"));
    try std.testing.expect(!isKnownSubcommand(""));
    // version 曾被旧 roster 静默漏掉——此处显式钉住其在真值表内。
    try std.testing.expect(isKnownSubcommand(sub_version));
}

test "布尔旗标 hasBoolFlag/stripBoolFlag：单元素形识别与剔离、等号形与长名不误匹、usage 同步（第 154 轮）" {
    const gpa = std.testing.allocator;
    // ① 单元素形：在场即真，剔离后其余元素逐位不变。
    const a = [_][]const u8{ "check", "src/main.zz", "--machine" };
    try std.testing.expect(hasBoolFlag(&a, "--machine"));
    var s = try stripBoolFlag(gpa, &a, "--machine");
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), s.items.len);
    try std.testing.expectEqualStrings("check", s.items[0]);
    try std.testing.expectEqualStrings("src/main.zz", s.items[1]);
    // ② 不误匹：更长的同前缀名与等号形均不算布尔旗标在场（等号形按设记不识别、不剔离）。
    const b = [_][]const u8{ "--machine-x", "--machine=1" };
    try std.testing.expect(!hasBoolFlag(&b, "--machine"));
    var s2 = try stripBoolFlag(gpa, &b, "--machine");
    defer s2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), s2.items.len); // 两元素原样透传
    // ③ 无旗标：逐元素等长副本（不改变行为了可无条件调用）。
    const c = [_][]const u8{ "build", "-O", "ReleaseFast" };
    var s3 = try stripBoolFlag(gpa, &c, "--machine");
    defer s3.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), s3.items.len);
    try std.testing.expect(!hasBoolFlag(&c, "--machine"));
    // ④ usage 文本同步防漂移：加了旗标却漏更帮助即红。
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--machine") != null);
}

/// 从 `build.zig.zon` 文本里抽取 `.fingerprint = 0x....` 的十六进制串（含 `0x` 前缀）；
/// 仅当同文里声明的 `.name` 与 `expected_name` 一致时才返回（避免把旧包名的 fingerprint
/// 误留给改名后的工程，那会令 `zig build` 判 invalid）。无名字匹配/无该字段/`0x` 后无十六进制位返回 null。
/// 返回的切片**借用自入参**（调用方须保持入参存活）。
/// 供 `eject` 幂等复用：重复导出到同一目标时沿用既有 fingerprint（zig 每次探得的低半随机）。
pub fn parseFingerprintFromZone(text: []const u8, expected_name: []const u8) ?[]const u8 {
    // 先校包名一致：`    .name = .app,` 中的 `app` 须等于本次 app_name。
    const name_marker = zzc.zon_name_marker; // 第 232 轮 D100：与写侧 ejectZoneText 同一 token 真值，两侧不再分抄
    const ni = std.mem.indexOf(u8, text, name_marker) orelse return null;
    const ns = ni + name_marker.len;
    if (!std.mem.startsWith(u8, text[ns..], expected_name)) return null;
    const after = ns + expected_name.len;
    if (after >= text.len) return null;
    switch (text[after]) {
        ',', ' ', '\n', '\r', '\t' => {}, // 名字后紧跟分隔符，避免 `.app` 与 `.apple` 前缀误配
        else => return null,
    }
    // 再取 fingerprint 十六进制串。
    const marker = zzc.zon_fingerprint_prefix ++ "0x"; // 第 232 轮 D100：字段前缀取 hub 真值、再拼 `0x` 定位十六进制值起点
    const idx = std.mem.indexOf(u8, text, marker) orelse return null;
    const ds = idx + marker.len; // 指向第一个十六进制位（0x 之后）
    var end = ds;
    while (end < text.len and std.ascii.isHex(text[end])) end += 1;
    if (end == ds) return null; // 0x 后无十六进制位
    const zs = idx + (marker.len - 2); // “0x” 起始位置，连同前缀一并返回
    return text[zs..end];
}

test "parseFingerprintFromZone：名字匹配才抽取，改名/缺字段/无十六进制返回 null" {
    // 名字匹配：取到含 0x 前缀、止于逗号的十六进制串。
    const ok = parseFingerprintFromZone(".{\n    .name = .app,\n    .fingerprint = 0xc96e70cf6540f2a7,\n}", "app");
    try std.testing.expectEqualStrings("0xc96e70cf6540f2a7", ok.?);
    // 名字不匹配（旧工程改名场景）：不复用。
    try std.testing.expectEqual(@as(?[]const u8, null), parseFingerprintFromZone(".{\n    .name = .other,\n    .fingerprint = 0xc96e70cf6540f2a7,\n}", "app"));
    // 名字前缀误配：`.apple` 不应被当作 `app`。
    try std.testing.expectEqual(@as(?[]const u8, null), parseFingerprintFromZone(".name = .apple,\n.fingerprint = 0xdeadbeef,\n", "app"));
    // 不含 fingerprint 字段。
    try std.testing.expectEqual(@as(?[]const u8, null), parseFingerprintFromZone(".{\n    .name = .app,\n}", "app"));
    // `0x` 后无十六进制位。
    try std.testing.expectEqual(@as(?[]const u8, null), parseFingerprintFromZone(".name = .app,\n.fingerprint = 0x,\n", "app"));
    // 只取前缀后的连续十六进制串。
    const trunc = parseFingerprintFromZone(".name = .app,\n.fingerprint = 0xabcdef0012 extra\n", "app");
    try std.testing.expectEqualStrings("0xabcdef0012", trunc.?);
}

// ---------------------------------------------------------------------------
// R11（第 164 轮）：Zig 版本漂移早警。
// 诊断措辞表（[diagnostics]）系按标定工具链版本采集：zig 升版后错误串措辞可能漂移、
// 使回译词条静默不可达（台账 R11 的两「未做」缺口之一）。此处置一处轻量早警面（纯函数、入测试图）：
// 解析 `zig version` 取前两级、与内置包标定基线比对，非标定即产母语告警。真实回放全部错形语料
// 的 e2e 面工程量大、登记为在册边界（见台账/CHANGELOG 第 164 轮）；本告警即其轻量替代早警。
// 外部包 per-pack 基线登记为后续边界（当前仅内置包有标定值）。
// ---------------------------------------------------------------------------

/// 诊断措辞表标定的工具链基线（内置中文包真相源；`zigDriftNote` 据此判漂移）。
/// 第 205 轮 D73：两枚数取族真值——标定、eject 模板写给毕业工程的 `.minimum_zig_version`、
/// 「无法启动 zig」提示里的版本下限、本仓 `build.zig.zon` 与 CI 安装版本自此同源，标定升代不再三处滞后。
pub const diag_baseline_zig = .{ .major = zzc.zig_major, .minor = zzc.zig_minor };

/// 解析 `zig version` 文本（`M.m.p` / `M.m.p-dev.N+hash` 等形）取前两级 major/minor；
/// 垃圾/缺第二段/非数字段返回 null（调用方据此静默、不误报）。按 `.` 分段后取前两段 parseInt，
/// 第三段（patch/dev/hash 后缀）不参与判定，故 `0.18.1-dev.421+afb31` 得 { 0, 18 }。
pub fn parseZigVersion(text: []const u8) ?struct { major: u32, minor: u32 } {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    var it = std.mem.splitScalar(u8, t, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch return null;
    return .{ .major = major, .minor = minor };
}

/// 非基线时把母语告警写入调用方给的 `buf` 并返回之；基线内返回 null。
/// `buf` 不足以容纳时也返回 null（宁可不提醒也不 panic——告警属辅面、不得反噬主流程）。
pub fn zigDriftNote(major: u32, minor: u32, buf: []u8) ?[]const u8 {
    if (major == diag_baseline_zig.major and minor == diag_baseline_zig.minor) return null;
    return std.fmt.bufPrint(buf, zzc.prog_prefix ++ "注意：本机 zig 为 {d}.{d}.x，与报错回译标定基线 {d}.{d} 不同——回译词条可能不完整，欢迎反馈。", .{
        major, minor, diag_baseline_zig.major, diag_baseline_zig.minor,
    }) catch null;
}

// ---------------------------------------------------------------------------
// 第 224 轮 D92：工具链 spawn argv 词族单一真值。
// main.zig 五处活路径（check 深检/浅检、run/build/test、eject 探纹/验建、版本漂警）共 13 处
// 旧形制各自持字面量：测面零钉（全仓唯 zzc_paths:293 钉自家派生形）、守卫 15 面对象皆
// editors/build.zig 文件词从未核 zig argv——t2 探针 P1–P7 七路词漂 583/583 全绿静默，真跑
// 坐实变异版 `zzc run` 即 `unknown command: build-exx` 功级断裂而构建链恒绿。本段收编。
// ---------------------------------------------------------------------------

/// zig 可执行文件名（PATH 查找，六处 spawn 首词同源）。
pub const tl_zig: []const u8 = "zig";
/// 深检/产物臂子命令词（check ① 臂与 cmdBuild 非 test 臂）。
pub const tl_build_exe: []const u8 = "build-exe";
/// 浅检臂子命令词（check ② 臂：不含 main 的模块只解名字）。
pub const tl_ast_check: []const u8 = "ast-check";
/// `zzc test` 臂子命令词（cmdBuild 的 .test_ 分支）。
pub const tl_test: []const u8 = "test";
/// eject 探纹/验建两臂子命令词（probeFingerprint 与 verifyBuild）。
pub const tl_build: []const u8 = "build";
/// 版本漂警子命令词（maybeWarnZigDrift）。
pub const tl_version: []const u8 = "version";

/// `cmdBuild` 非 test 臂的产物发射旗标模板：与 `zzc_paths.emit_bin_prefix` 同源派生，
/// 不另立第二枚 `-femit-bin=` 手抄（旧形制 allocPrint 模板内另持整串前缀）。
pub const tl_emit_bin_fmt: []const u8 = zzc.emit_bin_prefix ++ "{s}";

/// 对面十六（src/main.zig 委派形清单）：守卫读 main.zig 文本逐字节对账，防字面量回退——
/// 消费侧若改回手抄字面量，委派形 needle 即消失、守卫红；`count` 由 224 T0 在测试图内
/// 以 @embedFile 直接钉死（同一 needle 形可能多处同形，如 `zig build` 两臂）。
pub const tl_face = .{
    .{ .needle = "&.{ cli.tl_zig, cli.tl_build_exe, u.gen_rel, bin }", .count = @as(usize, 1), .why = "check 深检臂：含 main 的根走 build-exe 传递性语义深检，漂即 check 入口断裂" },
    .{ .needle = "&.{ cli.tl_zig, cli.tl_ast_check, u.gen_rel }", .count = @as(usize, 1), .why = "check 浅检臂：不含 main 的模块只 ast-check，漂即库模块检查断裂" },
    .{ .needle = "try argv.append(gpa_, cli.tl_zig);", .count = @as(usize, 1), .why = "cmdBuild spawn 首词：run/build/test 三入口共用，漂即三入口全断" },
    .{ .needle = "if (mode == .test_) cli.tl_test else cli.tl_build_exe", .count = @as(usize, 1), .why = "cmdBuild 模式分支词：test 与 build-exe 两臂同源，漂即对应入口断" },
    .{ .needle = "cli.tl_emit_bin_fmt, .{bin_full}", .count = @as(usize, 1), .why = "cmdBuild 发射旗标模板：前缀由 zzc_paths 派生，漂即产物落点失控" },
    .{ .needle = "&.{ cli.tl_zig, cli.tl_build }", .count = @as(usize, 2), .why = "eject 探纹/验建两臂：毕业工程 fingerprint 探测与独立构建验证，漂即 eject 断裂" },
    .{ .needle = "&.{ cli.tl_zig, cli.tl_version }", .count = @as(usize, 1), .why = "版本漂警臂：升代早警面，漂即静默失效（不回译告警永不发）" },
};

test "224 T0：工具链 spawn argv 词族单一真值＋委派形双向钉（第 224 轮）——D92" {
    // A1：六枚词值钉＋发射旗标模板与 zzc_paths 前缀同源钉（hub 本体漂移即红）。
    try std.testing.expectEqualStrings("zig", tl_zig);
    try std.testing.expectEqualStrings("build-exe", tl_build_exe);
    try std.testing.expectEqualStrings("ast-check", tl_ast_check);
    try std.testing.expectEqualStrings("test", tl_test);
    try std.testing.expectEqualStrings("build", tl_build);
    try std.testing.expectEqualStrings("version", tl_version);
    try std.testing.expectEqualStrings("-femit-bin=", zzc.emit_bin_prefix);
    try std.testing.expectEqualStrings("-femit-bin={s}", tl_emit_bin_fmt);
    // A2：对面十六清单自身钉（成员数与对面十五形制同骨：一面对多针）。
    try std.testing.expectEqual(@as(usize, 7), tl_face.len);
    // A3：委派形双向钉——@embedFile 直读 src/main.zig（真 source dependency：改 main.zig
    // 必重编本测），逐 needle 命中且频次全等：消费侧改回手抄字面量（委派形消失）或
    // hub 改名而接线不随动，皆在测试图直接红，不必等守卫步。
    const main_src = @embedFile("../main.zig");
    inline for (tl_face) |c| {
        var n: usize = 0;
        var i: usize = 0;
        while (std.mem.indexOf(u8, main_src[i..], c.needle)) |k| : ({
            i += k + c.needle.len;
            n += 1;
        }) {}
        try std.testing.expectEqual(c.count, n);
    }
}

test "parseZigVersion：取前两级、dev/hash 后缀容忍、垃圾输入 null（第 164 轮 R11）" {
    const v1 = parseZigVersion("0.17.0\n");
    try std.testing.expect(v1 != null);
    try std.testing.expectEqual(@as(u32, 0), v1.?.major);
    try std.testing.expectEqual(@as(u32, 17), v1.?.minor);

    const v2 = parseZigVersion("0.18.1-dev.421+afb312\n");
    try std.testing.expect(v2 != null);
    try std.testing.expectEqual(@as(u32, 0), v2.?.major);
    try std.testing.expectEqual(@as(u32, 18), v2.?.minor);

    // 大版本跨度亦取前两级。
    const v3 = parseZigVersion("1.0.0");
    try std.testing.expect(v3 != null);
    try std.testing.expectEqual(@as(u32, 1), v3.?.major);
    try std.testing.expectEqual(@as(u32, 0), v3.?.minor);

    // 垃圾/缺第二段/非数字段/空 → null（不误报）。
    try std.testing.expect(parseZigVersion("garbage") == null);
    try std.testing.expect(parseZigVersion("0") == null);
    try std.testing.expect(parseZigVersion("") == null);
    try std.testing.expect(parseZigVersion("x.y.z") == null);
    try std.testing.expect(parseZigVersion("zig version 0.17") == null); // 非纯版本起头 → 首段非数字
}

test "zigDriftNote：基线内 null、非基线产母语告警、buf 过小静默（第 164 轮 R11）" {
    var buf: [256]u8 = undefined;
    // 基线 0.17 → null（本机恒此形、既有 stdout 契约不破）。
    try std.testing.expect(zigDriftNote(0, 17, &buf) == null);
    // 0.18 / 0.16 / 1.0 → 有告警串，且含母语关键指引。
    const drifts = [_]struct { major: u32, minor: u32 }{
        .{ .major = 0, .minor = 18 },
        .{ .major = 0, .minor = 16 },
        .{ .major = 1, .minor = 0 },
    };
    for (drifts) |v| {
        const note = zigDriftNote(v.major, v.minor, &buf);
        try std.testing.expect(note != null);
        try std.testing.expect(std.mem.indexOf(u8, note.?, "回译") != null);
        try std.testing.expect(std.mem.indexOf(u8, note.?, "标定基线") != null);
    }
    // buf 过小 → null（宁缺毋滥、不 panic）。
    var tiny: [1]u8 = undefined;
    try std.testing.expect(zigDriftNote(0, 99, &tiny) == null);
}

/// 入口检测形（读侧单一真值，第 235 轮 D103）：`zigHasMainFn` 认出「生成 Zig 顶层入口」所依据的
/// 两枚行首前缀——公开形 `pub fn main(`、非公开形 `fn main(`。二者皆是 transpiler 逐 token 翻译
/// 方言 `公开 函数 主函数(` 的**涌现产物形**（写侧无此字面量），本模块仅按串面识别；写侧生成形与
/// 读侧识别形此前各测各钉同一串、互不引用，任一侧漂移即静默错检语义根（D47 类假过）。收编为常量后
/// 由 main.zig 的 235 T1 往返锚（真 `buildInitTemplate`→`translate` 产物喂进本函数）钉死两侧必同形。
/// 后缀形制契约：公开形 `pub fn main(` 以非公开形 `fn main(` 结尾（`pub ` 前缀差异），235 T0 钉之。
pub const entry_pub_prefix: []const u8 = "pub fn main(";
pub const entry_prefix: []const u8 = "fn main(";

/// 判断一段**生成 Zig 源码**是否含顶层入口函数 `main`（无论是否公开）。
/// 只认同同行首（无缩进）且紧跟 `(` 的 `pub fn main(` 或 `fn main(`——要求行首无缩进（入口必为顶层）、
/// 紧跟 `(` 以免误配 `fn main_helper(` 等含 main 前缀的非入口函数。非公开的 `fn main(` 也算入口：
/// Zig 0.17 要求根入口带 `pub`，若入口写成非公开 `函数 主函数`，`check` 仍应 build-exe 它、让 zig
/// 暴露 `'main' is not marked 'pub'`，使 `check` 与 `build` 结果一致、不再对编不过的工程假过。
/// 用于 `check` 选“语义编译根”时按**是否真有 main**（而非仅按文件名 stem=="main"）判定。
pub fn zigHasMainFn(zig_src: []const u8) bool {
    var it = std.mem.splitScalar(u8, zig_src, '\n');
    while (it.next()) |line| {
        // 顶层入口无论是否 pub 都算“可执行根”（`pub fn main(` 不满足第二个判定，二者互斥）。
        if (std.mem.startsWith(u8, line, entry_pub_prefix)) return true;
        if (std.mem.startsWith(u8, line, entry_prefix)) return true;
    }
    return false;
}

/// `zzc run` 拿到子进程退出状态后，决定是否把用户程序的退出码忠实回传。
/// 入参 code：正常退出时的退出码；null 表示异常终止（信号/停止/未知，无正常码）。
/// 返回：需强制以该码结束进程时返回该码；正常退出码 0、或异常终止时返回 null
/// （前者“成功继续”、后者由调用方回落 error.Failed→1）。
pub fn runPropagateExitCode(code: ?u8) ?u8 {
    if (code) |c| {
        if (c != 0) return c; // 忠实透传用户程序的非零退出码
        return null; // 0：正常成功，继续主流程
    }
    return null; // 异常终止：无可靠退出码，交调用方按失败处理
}

test "runPropagateExitCode：非零正常退出忠实透传，零或异常回落 null" {
    // 用户程序 exit(5) → 透传 5（而非被压成 1）。
    try std.testing.expectEqual(@as(?u8, 5), runPropagateExitCode(5));
    // 常见错误码 1、2、127 都原样透传。
    try std.testing.expectEqual(@as(?u8, 1), runPropagateExitCode(1));
    try std.testing.expectEqual(@as(?u8, 127), runPropagateExitCode(127));
    // 最大 u8 码仍透传。
    try std.testing.expectEqual(@as(?u8, 255), runPropagateExitCode(255));
    // exit(0) → null（成功继续，不强制结束）。
    try std.testing.expectEqual(@as(?u8, null), runPropagateExitCode(0));
    // 异常终止（信号等，无正常码）→ null（调用方走 error.Failed）。
    try std.testing.expectEqual(@as(?u8, null), runPropagateExitCode(null));
}

test "zigHasMainFn：认顶层 pub/非公开 fn main(，不缩进、不被 main_ 前缀误判" {
    // 顶层入口（同行首、紧跟 (）→ true。
    try std.testing.expect(zigHasMainFn("pub fn main() !void {\n}\n"));
    // 非公开的顶层入口 `fn main(`（无 pub）也算可执行根→ true（使 check 对“main 未标 pub”也与 build 一致）。
    try std.testing.expect(zigHasMainFn("fn main() void {}\n"));
    // 前置声明后出现 main → true。
    try std.testing.expect(zigHasMainFn("const x: i64 = 1;\npub fn main(args []const []const u8) !void {}\n"));
    // 空源码 → false。
    try std.testing.expect(!zigHasMainFn(""));
    // 普通库（无 main）→ false。
    try std.testing.expect(!zigHasMainFn("pub const z_2: i64 = 21;\nfn helper() void {}\n"));
    // 含 main 前缀但非入口（main_helper）→ false（紧跟 ( 要满足）。
    try std.testing.expect(!zigHasMainFn("pub fn main_helper() void {}\n"));
    // 缩进的 pub fn main（非顶层）→ false。
    try std.testing.expect(!zigHasMainFn("    pub fn main() void {}\n"));
    // 缩进的非公开 fn main（非顶层）→ false。
    try std.testing.expect(!zigHasMainFn("    fn main() void {}\n"));
    // 字符串里含 pub fn main 但不在行首 → false（逐行行首才判）。
    try std.testing.expect(!zigHasMainFn("const s = \"pub fn main(\";\n"));
}

test "235 T0（第 235 轮 D103）：入口检测形常量值钉＋后缀形制契约＋识别判据" {
    // ① 两枚常量值钉（独立字面量·承消缺测内判据不复用常量）：
    //    读侧识别形必须恰为 transpiler 逐 token 翻译方言入口的涌现产物串首段。
    try std.testing.expectEqualStrings("pub fn main(", entry_pub_prefix);
    try std.testing.expectEqualStrings("fn main(", entry_prefix);
    // ② 后缀形制契约：公开形 `pub fn main(` 必以非公开形 `fn main(` 结尾（仅差 `pub ` 前缀），
    //    两枚不可各自漂成无关串——漂则本契约红（捕获单侧被改成不同词形）。
    try std.testing.expect(std.mem.endsWith(u8, entry_pub_prefix, entry_prefix));
    try std.testing.expectEqual(
        entry_pub_prefix.len - entry_prefix.len,
        std.mem.indexOf(u8, entry_pub_prefix, entry_prefix).?,
    ); // 公开形内 `fn main(` 必居首（偏移==`pub ` 长度==4）
    // ③ 识别判据：zigHasMainFn 必认这两枚常量拼出的行首形、不认缺 `(` 或缩进形（与常量同源行为）。
    try std.testing.expect(zigHasMainFn(entry_pub_prefix ++ ") void {}\n"));
    try std.testing.expect(zigHasMainFn(entry_prefix ++ ") void {}\n"));
    try std.testing.expect(!zigHasMainFn("pub fn main) void {}\n")); // 缺紧跟 `(`
}

/// 跳过空白（空格/制表/换行），返回首个非空白下标（越界则返回 src.len）。
fn skipWs(src: []const u8, from: usize) usize {
    var k = from;
    while (k < src.len) {
        const c = src[k];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') k += 1 else break;
    }
    return k;
}

/// 收集 `X = "字面串";` 形的单跳数据流：`const_leads` 里的关键词（如 `const`/`常数`）后接标识符、
/// 再直接绑定字符串字面量时，登记 标识符→字面值（值为 src 子串）。供 embed 实参为变量名时解析（台账 D3）。
/// 近似词法：仅认“紧跟字面量”的单跳形（`const b = a;` 间接链/拼接/函数返回不登记）；
/// 字符串正文里恰含 `const x = "…"` 形可能轻微污染映射表——仅当该名字真被 @embedFile 引用才生效，风险可忽。
fn collectConstStringBindings(
    map: *std.StringHashMap([]const u8),
    src: []const u8,
    const_leads: []const []const u8,
) !void {
    for (const_leads) |lead| {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, src, idx, lead)) |pos| : (idx = pos + lead.len) {
            // 词边界：`myconst`/超串不认（lead 前一字节是词内字符即跳过）
            if (pos > 0 and isWordCharByte(src[pos - 1])) continue;
            var k = pos + lead.len;
            // lead 与名字之间允许空白（方言形 `常数 名字` 必隔空格；ASCII `const名字` 非法）
            k = skipWs(src, k);
            const name_start = k;
            // 名字可含非 ASCII：原文侧变量名是母语词（如 `名字`），生成侧是 ASCII；统一按词内字符扫描
            while (k < src.len and isWordCharByte(src[k])) k += 1;
            if (k == name_start) continue;
            const name = src[name_start..k];
            k = skipWs(src, k);
            if (k >= src.len or src[k] != '=') continue;
            // Zig 的 `=` 不能接在 `==`/`=>` 里；单 `=` 后若又是 `=` 则是比较式，不登记
            if (k + 1 < src.len and src[k + 1] == '=') continue;
            k = skipWs(src, k + 1);
            if (k >= src.len or src[k] != '\"') continue;
            k += 1;
            const vstart = k;
            while (k < src.len and src[k] != '\"') {
                if (src[k] == '\\') k += 1;
                k += 1;
            }
            if (k >= src.len) continue;
            try map.put(name, src[vstart..k]); // key 同为 src 子串：随 src 生命期，不额外拷贝
        }
    }
}

/// 从生成后的 Zig 源码里扫出全部 `@embedFile(…)` 的路径实参（元素为指向 src 的子串）。
/// 用途：把被嵌入的资源文件一并落到生成树 / eject 目标——zig 的 `@embedFile` 相对**当前 .zig 所在目录**解析，
/// 而 zzc 把源码生成到 `.zzc/gen/…`，若不搬运资源就会报 `failed opening …: FileNotFound`。
/// 认两种实参：字面字符串；以及单跳 const 变量（`const 名 = "字面";` 后 `@embedFile(名)`，台账 D3）。
/// 其余计算式实参（拼接/函数/间接链）zig 虽可能在 comptime 求出，zzc 仍无法静态预知 → 跳过，
/// 由诊断提示的**条件表述**说明“可能未被自动拷贝”而非断言不存在；跳过 `\"` 转义。
pub fn extractEmbedPaths(gpa: std.mem.Allocator, src: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    // out 元素皆 src 借用子串（含 consts.get 值）→ 错误回滚只 deinit 本体、不逐项 free（R7f ⑤）；
    // 孪生 findReferencedRels 已有本 errdefer，此处补齐对称（D22 族底衬回滚缺口，R10f 不可注入红·源头治理）。
    errdefer out.deinit(gpa);
    var consts = std.StringHashMap([]const u8).init(gpa);
    defer consts.deinit();
    const one_const = [_][]const u8{"const"};
    try collectConstStringBindings(&consts, src, &one_const);
    const lead = "@embedFile";
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] != '@') continue;
        if (!std.mem.startsWith(u8, src[i..], lead)) continue;
        var j = skipWs(src, i + lead.len);
        if (j >= src.len or src[j] != '(') continue;
        j = skipWs(src, j + 1);
        if (j < src.len and (std.ascii.isAlphabetic(src[j]) or src[j] == '_')) {
            // 变量实参：单跳解析到 const 绑定的字面值；未登记则跳过（留给 zig 报错/提示）
            const s = j;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
            if (consts.get(src[s..j])) |v| try out.append(gpa, v);
            continue;
        }
        if (j >= src.len or src[j] != '\"') continue; // 非字面串（其它计算式）→ 不处理
        j += 1;
        const start = j;
        while (j < src.len and src[j] != '\"') {
            if (src[j] == '\\') j += 1; // 跳过被转义的下一字符
            j += 1;
        }
        if (j >= src.len) break; // 字符串未闭合
        try out.append(gpa, src[start..j]);
        i = j; // 从右引号处继续（循环尾会再 +1）
    }
    return out;
}

test "extractEmbedPaths：扫出 @embedFile 字面路径、忽略非字面实参" {
    const src =
        \\const a = @embedFile("note.txt");
        \\const b = @embedFile("sub/数据.bin");
        \\const c = @embedFile(n);
        \\const d = @embedFile (  "带空格.txt" );
    ;
    var list = try extractEmbedPaths(std.testing.allocator, src);
    defer list.deinit(std.testing.allocator);
    // 三个合法字面（含 `@embedFile (` 带空白形）；未登记变量 `n` 不计。
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("note.txt", list.items[0]);
    try std.testing.expectEqualStrings("sub/数据.bin", list.items[1]);
    try std.testing.expectEqualStrings("带空格.txt", list.items[2]);
}

test "extractEmbedPaths：单跳 const 变量实参解析（D3），间接链/未登记名跳过" {
    const src =
        \\const name = "note.txt";
        \\const blob = @embedFile(name);
        \\pub const p2 = "sub/数据.bin";
        \\const b2 = @embedFile(p2);
        \\const chain = name; // 间接链：RHS 非字面量，不登记
        \\const b3 = @embedFile(chain);
        \\const b4 = @embedFile(未知名);
    ;
    var list = try extractEmbedPaths(std.testing.allocator, src);
    defer list.deinit(std.testing.allocator);
    // 只解析两跳：name→note.txt、p2→sub/数据.bin；chain/未知名不纳入。
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("note.txt", list.items[0]);
    try std.testing.expectEqualStrings("sub/数据.bin", list.items[1]);
}

test "extractEmbedPaths：无 embedFile 时为空、不报错" {
    var list = try extractEmbedPaths(std.testing.allocator, "const x: i64 = 1;\n");
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

/// 字节是否为“词内字符”（ASCII 字母数字/下划线或非 ASCII 字节）：用于词边界判定，
/// 防止方言词 lead 被超串拆分命中（如 `我的嵌入文件`、`嵌入文件1` 都不算独立词）。
fn isWordCharByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// 从**方言原文**里扫出全部 `lead(路径实参)` 形（lead 取词列表：ASCII 直通形 + 语言包词表形）。
/// 与 extractEmbedPaths 的区别：那边只认生成后的 ASCII `@embedFile`；这边要认尚未翻译的原文，
/// 且 lead 两侧须为词边界。用途：采集前预扫描出被当数据嵌入的 `.zz` 资产、从编译单元豁免（台账 D2）。
/// `const_leads`（如 `{"const", "常数"}`）启用与 D3 同构的单跳变量实参解析：原文里
/// `常数 名字 = "模板.zz"; 常数 内容 = 嵌入文件(名字);` 的变量引用同样能命中豁免（台账 D3 组合面）。
pub fn extractEmbedPathsForms(
    gpa: std.mem.Allocator,
    src: []const u8,
    leads: []const []const u8,
    const_leads: []const []const u8,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    // out 元素皆 src 借用子串 → 错误回滚只 deinit 本体、不逐项 free（R7f ⑤，同 extractEmbedPaths）。
    errdefer out.deinit(gpa);
    var consts = std.StringHashMap([]const u8).init(gpa);
    defer consts.deinit();
    if (const_leads.len > 0) try collectConstStringBindings(&consts, src, const_leads);
    for (leads) |lead| {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, src, idx, lead)) |pos| : (idx = pos + lead.len) {
            if (pos > 0 and isWordCharByte(src[pos - 1])) continue;
            const after = pos + lead.len;
            if (after < src.len and isWordCharByte(src[after])) continue;
            var j = skipWs(src, after);
            if (j >= src.len or src[j] != '(') continue;
            j = skipWs(src, j + 1);
            if (j < src.len and isWordCharByte(src[j])) {
                // 变量实参：仅在启用 const_leads 且能单跳解析时纳入（名字可为母语词）
                const s = j;
                while (j < src.len and isWordCharByte(src[j])) j += 1;
                if (consts.get(src[s..j])) |v| try out.append(gpa, v);
                continue;
            }
            if (j >= src.len or src[j] != '\"') continue; // 非字面串（变量未登记/计算式）→ 不处理
            j += 1;
            const start = j;
            while (j < src.len and src[j] != '\"') {
                if (src[j] == '\\') j += 1; // 跳过被转义的下一字符
                j += 1;
            }
            if (j >= src.len) break; // 字符串未闭合
            try out.append(gpa, src[start..j]);
        }
    }
    return out;
}

/// 把 embed 字面参 p（相对引用文件所在目录 referrer_dir）解析成归一化的源树相对路径；
/// 返回 null：p 为空/绝对（前导 `/` `\` 或盘符）/解析后越出源根/不以 `.zz` 结尾
///（非方言后缀资产不与 .zz 源采集相碰，无需豁免）。
pub fn resolveEmbedZzRel(gpa: std.mem.Allocator, referrer_dir: []const u8, p: []const u8) !?[]const u8 {
    if (p.len == 0) return null;
    if (p[0] == '/' or p[0] == '\\') return null;
    if (p.len >= 2 and p[1] == ':') return null;
    if (!zzc.isDialectSource(p)) return null; // 先筛后缀再拼接，省无谓 join（第 201 轮 D69：后缀真值同源）
    const joined = try std.fs.path.join(gpa, &.{ referrer_dir, p });
    defer gpa.free(joined);
    const norm = try normalizeRelPath(gpa, joined);
    if (std.mem.startsWith(u8, norm, "..") and (norm.len == 2 or norm[2] == '/')) {
        gpa.free(norm);
        return null; // 越出源根：不属于工程内资产
    }
    return norm;
}

test "extractEmbedPathsForms：原文方言词/直通词都认，超串不拆，变量实参跳过" {
    const src =
        \\常数 a = 嵌入文件("模板.zz");
        \\const b = @embedFile("note.txt");
        \\常数 我的嵌入文件 = 1; // 超串名：不当函数词
        \\常数 c = 嵌入文件1("坏.zz"); // lead 后接词字符：非独立词
        \\常数 d = 嵌入文件(n);
    ;
    const leads = [_][]const u8{ "@embedFile", "嵌入文件" };
    var list = try extractEmbedPathsForms(std.testing.allocator, src, &leads, &.{});
    defer list.deinit(std.testing.allocator);
    // 只收到两条字面参：超串 `我的嵌入文件`/`嵌入文件1` 被词边界拦截，变量实参跳过。
    // 注意：按 lead 分组扫描，先扫完全部 @embedFile 再扫方言词，顺序为 note → 模板。
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("note.txt", list.items[0]);
    try std.testing.expectEqualStrings("模板.zz", list.items[1]);
}

test "extractEmbedPathsForms：原文单跳变量实参也能命中（D2×D3 组合面）" {
    const src =
        \\常数 名字 = "模板.zz";
        \\常数 内容 = 嵌入文件(名字);
        \\常数 其它 = 嵌入文件("直接.zz");
        \\常数 无关 = "没被引用.zz";
    ;
    const leads = [_][]const u8{ "@embedFile", "嵌入文件" };
    const cs_leads = [_][]const u8{ "const", "常数" };
    var list = try extractEmbedPathsForms(std.testing.allocator, src, &leads, &cs_leads);
    defer list.deinit(std.testing.allocator);
    // 变量形与字面形都纳入；未被引用的常量不算资产。
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("模板.zz", list.items[0]);
    try std.testing.expectEqualStrings("直接.zz", list.items[1]);
}

test "三处字面串扫描器：末字节反斜杠未闭合串不越界 panic（D33 同族双自增，靠循环后置守卫兜住）" {
    // collectConstStringBindings：`const 名 = "...\` 串体以反斜杠收尾且无右引号，
    // while 内 `if (src[k]=='\\') k+=1; k+=1;` 双自增令 k 越至 src.len+1，
    // 靠 473 行 `if (k >= src.len) continue;` 拦下——越界值绝不用于切片。
    {
        const src = "const name = \"abc\\"; // 末字节为反斜杠，字符串未闭合
        var consts = std.StringHashMap([]const u8).init(std.testing.allocator);
        defer consts.deinit();
        const leads = [_][]const u8{"const"};
        try collectConstStringBindings(&consts, src, &leads);
        try std.testing.expectEqual(@as(usize, 0), consts.count());
    }
    // extractEmbedPaths：前一条合法、后一条末字节反斜杠未闭合——合法的照常收，畸形的靠 516 行 break 跳过。
    {
        const src = "const ok = @embedFile(\"good.txt\"); const y = @embedFile(\"abc\\";
        var list = try extractEmbedPaths(std.testing.allocator, src);
        defer list.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), list.items.len);
        try std.testing.expectEqualStrings("good.txt", list.items[0]);
    }
    // extractEmbedPathsForms：方言词 lead，同样末字节反斜杠未闭合 → 靠 609 行 break 跳过、不 panic。
    {
        const src = "嵌入文件(\"abc\\";
        const leads = [_][]const u8{"嵌入文件"};
        var list = try extractEmbedPathsForms(std.testing.allocator, src, &leads, &.{});
        defer list.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), list.items.len);
    }
}

test "resolveEmbedZzRel：同目录/子目录/包内 .. 解析，非 .zz/绝对/越根返回 null" {
    const gpa = std.testing.allocator;
    const a = try resolveEmbedZzRel(gpa, "src", "模板.zz");
    try std.testing.expectEqualStrings("src/模板.zz", a.?);
    gpa.free(a.?);
    const b = try resolveEmbedZzRel(gpa, "src/sub", "../共享.zz");
    try std.testing.expectEqualStrings("src/共享.zz", b.?);
    gpa.free(b.?);
    const c = try resolveEmbedZzRel(gpa, "src/sub", "深层\\嵌套.zz"); // 反斜杠归一
    try std.testing.expectEqualStrings("src/sub/深层/嵌套.zz", c.?);
    gpa.free(c.?);
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "../../坏.zz")); // 越根
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "/etc/x.zz")); // 绝对
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "C:/x.zz")); // 盘符
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "数据.bin")); // 非 .zz 不碰采集
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "")); // 空
}

/// 词法规范化路径（无系统调用）：反斜杠归一为正斜杠、折叠重复分隔符、去除 `.`、解析 `..`（越出起点则保留前导 `..`）。
/// 仅用于判包含性（不要求访问磁盘），统一分隔符后拿到的段逐个入栈。
pub fn normalizeRelPath(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, raw, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0 and !std.mem.eql(u8, segs.items[segs.items.len - 1], "..")) {
                _ = segs.pop();
            } else {
                try segs.append(gpa, seg); // 越出起点：保留前导 ..
            }
            continue;
        }
        try segs.append(gpa, seg);
    }
    return std.mem.join(gpa, "/", segs.items);
}

/// 拼接相对路径并归一分隔符（台账 D9：采集侧/walker 与 stage 侧四处同形 `join`+`replaceScalar` 的单一真值）：
/// `base` 为空或 `.` 时直取 `sub`；结果恒为正斜杠形（与文档/用法示例一致，也保证 findUnit
/// 的精确匹配不因 Windows 反斜杠而退化到 stem 兜底）。返回 `gpa` 所有权。
pub fn joinRelNorm(gpa: std.mem.Allocator, base: []const u8, sub: []const u8) ![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return gpa.dupe(u8, sub);
    const joined = try std.fs.path.join(gpa, &.{ base, sub });
    std.mem.replaceScalar(u8, joined, '\\', '/');
    return joined;
}

/// 扫描一段源码里的引用词形（`leads` 函数词 + `const_leads` 单跳变量绑定词形，D2/D3 同一识别面），
/// 逐个按 `resolveEmbedZzRel` 解析为归一化的工程内 `.zz` 相对路径。台账 D9/D10：
/// 采集阶段“资产豁免预扫描”与“D4 编译单元优先”两趟同形循环的单一真值；纯函数（不碰磁盘），
/// 进 zzc_core 测试图可单测（D7：原逻辑困在 exe 图内从未被单元级覆盖）。
/// 列表元素与本体均为 `gpa` 所有权，由调用方逐个释放。
pub fn findReferencedRels(
    gpa: std.mem.Allocator,
    src: []const u8,
    src_dir: []const u8,
    leads: []const []const u8,
    const_leads: []const []const u8,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |it| gpa.free(it);
        out.deinit(gpa);
    }
    var list = try extractEmbedPathsForms(gpa, src, leads, const_leads);
    // list 元素是 src 子串（借用、非 gpa 分配），只 deinit 本体、不逐项 free。
    defer list.deinit(gpa);
    for (list.items) |p| {
        if (try resolveEmbedZzRel(gpa, src_dir, p)) |rel| {
            // rel 为新分配、尚未入列（入列后由顶部 errdefer/调用方回收）：append 失败则泄 rel（D22 族）。
            // 批量预留容量不可注入红（R10f），code-review 源头治理。
            errdefer gpa.free(rel);
            try out.append(gpa, rel);
        }
    }
    return out;
}

/// 判断“将嵌入资浅相对路径 p 拼到 base_dir 后、词法解析 `..` 结果仍严格处于镜像根 root 之内”。
/// 用于 stageEmbedAssets 的越界写守卫：若 p 为绝对（前导 `/` `\` 或盘符 `X:`）或解析后越出 root → 返回 false（不 stage）。
pub fn embedPathStaysWithin(gpa: std.mem.Allocator, root: []const u8, base_dir: []const u8, p: []const u8) !bool {
    if (p.len == 0) return false;
    if (p[0] == '/' or p[0] == '\\') return false; // 绝对（unix/unc 起头）
    if (p.len >= 2 and p[1] == ':') return false; // 盘符绝对 C:/…
    const joined = try std.fs.path.join(gpa, &.{ base_dir, p });
    defer gpa.free(joined);
    const nfull = try normalizeRelPath(gpa, joined);
    defer gpa.free(nfull);
    const nroot = try normalizeRelPath(gpa, root);
    defer gpa.free(nroot);
    // 严格处于 root 之下：前缀等于 root 且下一字符为分隔符（而非同名目录/相等）。
    return nfull.len > nroot.len and std.mem.startsWith(u8, nfull, nroot) and nfull[nroot.len] == '/';
}

test "normalizeRelPath：解 ./../、统一分隔、越界保留前导 .." {
    const a = try normalizeRelPath(std.testing.allocator, ".zzc/gen/src/../共享.bin");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings(".zzc/gen/共享.bin", a);
    const b = try normalizeRelPath(std.testing.allocator, "src\\sub\\..\\..\\..\\x");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("../x", b); // 从 src/sub 上溯三段→越过项目根、保留前导 ..
    const c = try normalizeRelPath(std.testing.allocator, "a//./b/");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("a/b", c);
}

// 护栏（第 119 轮证伪落位）：normalizeRelPath 的「连续多级前导 `..` 逐级保留」分支
// （L840 else 之「segs 非空且末段已是 .. → 追加」子路）此前零直调——既有测 L913
// `src\sub\..\..\..\x` 只在 segs 被清空后经 `len==0` 支追加单个 ..，从未走到「末段
// 已 .. 再追加 ..」的多级累加。此支是 resolveEmbedZzRel 越根判定、embedPathStaysWithin
// 越界写守卫赖以识别「逃出 N 层」的不变量：若误改判据去掉 `!eql(末段,"..")` → `../../x`
// 塌成 `x`，多级上溯被下报、越界路径伪装成工程内相对路径。本测钉死任意多个前导 .. 全数保留。
test "normalizeRelPath：连续多级前导 .. 逐级保留不折叠（越界深度即安全边界，第 119 轮证伪落位）" {
    const gpa = std.testing.allocator;
    // 双 .. 起头、无先行真实段：两段 .. 皆保留（命中「末段已是 .. → 追加」子路）。
    const a = try normalizeRelPath(gpa, "../../x");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("../../x", a);
    // 三连 .. 亦全数保留。
    const b = try normalizeRelPath(gpa, "../../../y");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("../../../y", b);
    // 真实段先被抵消、余下两级 .. 保留（混合形）。
    const c = try normalizeRelPath(gpa, "src/../../../z");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("../../z", c);
    // 纯 `../..`（无尾段）两级都留，不退化。
    const d = try normalizeRelPath(gpa, "../..");
    defer gpa.free(d);
    try std.testing.expectEqualStrings("../..", d);
}

test "embedPathStaysWithin：同目录/子目录/包内 ../ 允许，越出镜像根与绝对路径拒绝" {
    const gpa = std.testing.allocator;
    // base=.zzc/gen/src、root=.zzc/gen：
    try std.testing.expect(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "note.txt")); // 同目录
    try std.testing.expect(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "sub/数据.bin")); // 子目录
    try std.testing.expect(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "../共享.bin")); // 单 ../仍在镜像根内
    try std.testing.expect(!(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "../../evil.txt"))); // 越出 .zzc/gen
    try std.testing.expect(!(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "/etc/passwd"))); // 绝对
    try std.testing.expect(!(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "C:/Windows/x"))); // 盘符
    try std.testing.expect(!(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", ""))); // 空
}

test "joinRelNorm：拼接归一正斜杠、`.` 基座直取子路" {
    const gpa = std.testing.allocator;
    const a = try joinRelNorm(gpa, "src", "sub\\mod.zz"); // Windows 混入反斜杠→归一
    defer gpa.free(a);
    try std.testing.expectEqualStrings("src/sub/mod.zz", a);
    const b = try joinRelNorm(gpa, ".", "main.zz"); // 当前目录基座：不prepend `./`
    defer gpa.free(b);
    try std.testing.expectEqualStrings("main.zz", b);
    const c = try joinRelNorm(gpa, "", "x/y.zz");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("x/y.zz", c);
}

test "findReferencedRels：方言/ASCII 两形都解、非 .zz 与越根跳过、单跳变量实参命中" {
    const gpa = std.testing.allocator;
    const leads = [_][]const u8{ "嵌入文件", "@embedFile" };
    const cs = [_][]const u8{ "常数", "const" };
    const src =
        \\常数 模板名 = "共享/模板.zz";
        \\常数 a = 嵌入文件(模板名); // 单跳变量实参
        \\const b = @embedFile("note.txt"); // 非 .zz：不碰采集
        \\常数 c = 嵌入文件("../../外.zz"); // 从 src 上溯两段→越出源根（归一后带前导 ..）
        \\常数 d = 嵌入文件("正文.zz");
    ;
    var list = try findReferencedRels(gpa, src, "src", &leads, &cs);
    defer {
        for (list.items) |it| gpa.free(it);
        list.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("src/共享/模板.zz", list.items[0]);
    try std.testing.expectEqualStrings("src/正文.zz", list.items[1]);
}

// ---------------------------------------------------------------- 第 178 轮证伪撤号增量审计
//
// 承 111/175 词边界对称不变量方法论，转审本文件两个**私有零直调谓词**——全仓仅经
// `collectConstStringBindings`/`extractEmbedPaths`/`extractEmbedPathsForms` 间接触达，其精确字节集
// 从未被任一端到端测钉住（既有测只喂：超串尾随 ASCII 数字 `嵌入文件1`、超串前导 CJK `我的嵌入文件`、
// 空格空白形 `@embedFile (  ".." )`）：
//   · `isWordCharByte`（L863）——D2「超串不拆分命中」词边界判据，`_` 下划线臂与高字节 `>=0x80`
//     边界端（0x7F 界外 vs 0x80 界内）现行数据/测试零触达；误删 `_` 臂即令 `foo_嵌入文件`/
//     `嵌入文件_x` 形超串被误拆为独立 lead 命中、错误采集路径；`>=0x80` 收窄一格即令 UTF-8 续字节
//     0x80 被当词边界、母语超串静默漏检。
//   · `skipWs`（L728）——刻意只认 `{' ','\t','\r','\n'}` **四字节**空白集（异于 `std.ascii.isWhitespace`
//     另含 0x0B 垂直制表/0x0C 进纸），lead 与 `(`、`=` 与字面量间跨 CRLF 源换行的空白全靠此跳过；
//     误摘 `\r` 臂即令 CRLF 源里 `嵌入文件\r\n(..)` 跳过停在 `\r`、非 `(` 而漏采资产。
// 探针先行以独立 oracle（不借 `std.ascii.isAlphanumeric`、显式字节区间）对全 256 字节 iff 穷举坐实
// `isWordCharByte` 真形恰为 `[0-9A-Za-z_] ∪ [0x80..0xFF]`、`skipWs` 四字节集与越界/停位边界皆自洽，
// 无在线缺陷 → 证伪撤号不占 D 号（同 111/116/170-176 判例）。落 T1+T2 两组直钉护栏测。

test "isWordCharByte：全字节 iff 穷举钉词边界集 [0-9A-Za-z_] ∪ [0x80..0xFF]（独立 oracle·第 178 轮）" {
    // 独立 oracle：显式字节区间，不复用被测函数依赖的 std.ascii.isAlphanumeric——两侧同写即失却对账意义。
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        const word = (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or
            (b >= 'a' and b <= 'z') or (b == '_') or (b >= 0x80);
        try std.testing.expect(word == isWordCharByte(b));
    }
    // 关键边界逐例点名（把 iff 穷举里最易被误改的四形固化为可读锚）。
    try std.testing.expect(isWordCharByte('_')); // 下划线臂——现行任何端到端测零喂，本测独防
    try std.testing.expect(isWordCharByte(0x80)); // 高字节含端下界（UTF-8 续字节可为 0x80）
    try std.testing.expect(!isWordCharByte(0x7F)); // DEL：紧邻 0x80 之下、系词边界非词内字符
    try std.testing.expect(!isWordCharByte('-')); // 连字符：蛇形/中划线名两侧须为词边界
}

test "skipWs：钉四字节空白集 {' ','\\t','\\r','\\n'} 跳过 + 非空白停位 + 越界/末段边界（第 178 轮）" {
    // 四类空白一并跳过——单测即钉 `\r`/`\n` 两臂（CRLF 源跨行 lead 与 `(` 间空白的跳过依赖）。
    try std.testing.expectEqual(@as(usize, 4), skipWs(" \t\r\nx", 0));
    // 非空白字节绝不跳：0x0B 垂直制表/0x0C 进纸刻意不在集内（异于 std.ascii.isWhitespace），
    // 若有人「顺手扩大」空白集即本断言红——钉住四字节显式集的定义性边界。
    try std.testing.expectEqual(@as(usize, 0), skipWs("\x0B\x0C", 0));
    // 首字节即非空白 → 原位返回（lead 紧接 `(` 的常见形）。
    try std.testing.expectEqual(@as(usize, 0), skipWs("(abc", 0));
    // from 落在非空白字节 → 不越位（即便其后有空白）。
    try std.testing.expectEqual(@as(usize, 2), skipWs("a b", 2));
    // 连续空白后停在首个非空白（lead 与字面量间多空白跳过至 `"`）。
    try std.testing.expectEqual(@as(usize, 3), skipWs("a  (", 1));
    // 末段全空白 → 返回 src.len（不越界，跳过整尾）。
    try std.testing.expectEqual(@as(usize, 4), skipWs("ab  ", 2));
    try std.testing.expectEqual(@as(usize, 4), skipWs(" \t\n\r", 0));
    // from == src.len 边界 → 恒返回 len（空尾不越界）。
    try std.testing.expectEqual(@as(usize, 2), skipWs("ab", 2));
    try std.testing.expectEqual(@as(usize, 0), skipWs("", 0));
}

// 第 199 轮审计注（D67）：`.zzc/gen` 曾系跨模块**七处生产字面量**的双源族——写侧 `genPathFor` 两枚拼串、
// 剥侧 `cmdEject` 两站点各持「前缀串 + 前缀 `.len`」两枚、镜像根 `collect` 传参一枚。写与剥须字节相等，
// 失配即走 `else basename` 静默降级、把 eject 导出树的子目录拉平（正是该处注释自己警告的
// `@import("sub/mod.zig")` 断链形）——漂移不报错，只把产物写歪。
// t2 探针（`.scratch199/mutate199.sh`：每路单点破坏后 `zig build test --summary all` 实测红绿）：
//   P1 剥站点1 前缀串改 → 全绿；P2 剥站点2 前缀串改 → 全绿；P3 剥站点1 的 `.len` 单独漂移 → 全绿；
//   P4 镜像根字面量改 → 全绿；P5 写侧目录名改 → 498/500 红（`genPathFor` 自身的字面量钉抓到）。
//   即写侧有钉、剥侧四处零钉，P1/P3 两路恰是把「保层级」契约改成「拉平/错位切头」的路径。生产后果面
//   由 `tools/check-demos.ps1` 的 multi/nested demo 守卫覆盖，唯本机 `which pwsh` 无（NO_PWSH）不可跑，
//   属在册观察（同 196–198 各轮口径：e2e 面不在本轮四绿之内）。
// 修法：抽 `gen_dir`/`gen_dir_prefix` 单一真值 + `stripGenDir` 下沉合并两站点（同 60 轮 D7 的
// 「纯逻辑下沉 cli 进测试图」先例），本块钉契约：A1 真值字面量钉（判据不引用被测常量，遵 196/197
// 「判据独立性通则」）；A2 写→剥组合往返——两侧经函数耦合而非仅经常量引用，故这是 197 轮所记
// 「同源形制本身无可运行判据」缺的那枚**行为锚**：任一侧脱离真值即断；A3 深度层级保真（P3 类长度漂移
// 的显式靶面，切长多一少一皆改此结果）；A4 前缀失配回退臂直钉（防御面，正常不可达≠可删）。
// 不可锚登册：`collect` 的镜像根实参改用 `cli.gen_dir` 后，「同值改写回字面量」的行为完全等价、无可运行
// 判据（反证 M5/M6 实测皆绿）——如实登记、不占钉，同 197 M5 判例。

test "第 199 轮 T1 gen_dir 单一真值：真值字面量钉 + 写→剥组合往返 + 层级保真 + 失配回退臂" {
    const gpa = std.testing.allocator;
    // A1 真值字面量钉：改 `gen_dir` 即本钉红（真值漂移显式化，与 A2 的行为锚互补）。
    try std.testing.expectEqualStrings(".zzc/gen", gen_dir);
    try std.testing.expectEqualStrings(".zzc/gen/", gen_dir_prefix);

    // A2 写→剥组合往返（根目录形 + 子目录形）：剥侧结果由字面量给定。写侧脱离真值 → 剥侧前缀失配 →
    //   回退 basename（`mod.zig` ≠ `src/sub/mod.zig`）；剥侧脱离真值同理。两站点共用一函数即不再漂移。
    const g_root = try genPathFor(gpa, "main.zz");
    defer gpa.free(g_root);
    try std.testing.expectEqualStrings(".zzc/gen/main.zig", g_root);
    try std.testing.expectEqualStrings("main.zig", stripGenDir(g_root));
    const g_sub = try genPathFor(gpa, "src/sub/mod.zz");
    defer gpa.free(g_sub);
    try std.testing.expectEqualStrings(".zzc/gen/src/sub/mod.zig", g_sub);
    try std.testing.expectEqualStrings("src/sub/mod.zig", stripGenDir(g_sub));

    // A3 深度层级保真：四段名对 9 字节前缀的切长最敏感，前缀串与切长不一致必然在此现形。
    const g_deep = try genPathFor(gpa, "a/b/c/d.zz");
    defer gpa.free(g_deep);
    try std.testing.expectEqualStrings("a/b/c/d.zig", stripGenDir(g_deep));

    // A4 失配回退臂（防御面）：非本树产物一律回退 basename——同前缀但目录名多一字符、绝对形、
    //   目录名本身（无尾分隔符故不命中前缀）、空串。删臂即令这些形被无条件切掉头 9 字节。
    try std.testing.expectEqualStrings("main.zig", stripGenDir("src/main.zig"));
    try std.testing.expectEqualStrings("a.zig", stripGenDir(".zzc/genv/src/a.zig"));
    try std.testing.expectEqualStrings("x.zig", stripGenDir("/tmp/deep/dir/x.zig"));
    try std.testing.expectEqualStrings("gen", stripGenDir(".zzc/gen"));
    try std.testing.expectEqualStrings("", stripGenDir(""));
}

// 第 201 轮 T1（D69 · 方言工程布局族 的写→读配对锚）。旧形制下 `.zz`/`src`/`main` 三枚真值被生产侧
// `main.cmdInit`（建工程写盘）、`main.cmdEject`（硬编入口）与消费侧 `pickEntry`、`main` 采集器各持一份：
// 探针 P2/P3/P4 单点破坏 main 侧三处均 505/505 全绿（零钉），且失配不报错、只让用户在错位置找不到工程。
// 形制同 199 轮 D67 推论二：配对契约经函数组合（init 产物喂入口判据）转为行为锚，纯同值引用不可锚。
test "第 201 轮 T1 布局族写→读往返：init 产物可被入口判据认下 + 缺省入口同址 + 后缀宽度真形" {
    const gpa = std.testing.allocator;
    // A1 写→读往返：`zzc init myapp` 建的入口须被入口选择判据认下（显式传参形），且字面量侧钉死
    //    为 `myapp/src/main.zz`——改 `initEntryPathFor` 的格式串（丢目录段、换反斜杠）即本钉红。
    const created = try zzc.initEntryPathFor(gpa, "myapp");
    defer gpa.free(created);
    try std.testing.expectEqualStrings("myapp/src/main.zz", created);
    const picked = pickEntry(&.{created});
    try std.testing.expectEqualStrings(created, picked.entry);
    try std.testing.expectEqual(@as(?usize, 0), picked.idx);

    // A2 落回工程根即默认入口：用户进目录后不带文件运行 `zzc run`，读侧缺省必须指向 init 写出的那个
    //    文件（去掉 `<name>/` 前缀后逐字节相等）——init 建完能否直接跑通就是这条契约。
    try std.testing.expectEqualStrings("src/main.zz", zzc.default_entry);
    try std.testing.expectEqualStrings(zzc.default_entry, created["myapp/".len..]);
    try std.testing.expectEqualStrings(zzc.default_entry, pickEntry(&.{ "-O", "Debug" }).entry);

    // A3 采集器同判据（配对消费面）：入口名进得来、我方生成物与临时备份名进不来——
    //    `collectAndTranslate` 的筛后缀与 `cmdInit` 的写盘共用 `isDialectSource`，此处钉住其宽度。
    try std.testing.expect(zzc.isDialectSource(zzc.default_entry));
    try std.testing.expect(!zzc.isDialectSource("src/main.zig")); // 生成树产物不得被当方言源采集
    try std.testing.expect(!zzc.isDialectSource("src/main.zz.bak")); // 备份/临时名不得混入编译单元

    // A4 真形坐实（非期望）：判据是纯后缀比较，故「只有扩展名没有词干」的 `.zz` 也命中——与本轮收敛前的
    //    `std.mem.endsWith(u8, p, ".zz")` 完全一致（纯重构、不改判据宽度），钉住防「顺手加词干校验」。
    try std.testing.expect(zzc.isDialectSource(".zz"));
}

test "第 203 轮 T2 usage 文案↔契约 hub 对偶钉：旗标名／子命令名／机读形制提示逐字现形于帮助文本" {
    // 文案是说给编辑器/CI 作者听的第二份契约面：既有测只判旗标名在场（202 轮前形制），本轮补
    // 「机读形制描述」与真值的对偶——探针 P7（把 `路径:行:列: 种类: 消息` 改成分号形）实测全绿，
    // 本钉使其转红。期望串一律取 hub 派生真值（`shape_hint` 由 field_names+sep_after 拼出），非手抄。
    try std.testing.expect(std.mem.indexOf(u8, usage_text, mcon.flag_machine) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, mcon.sub_check) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, mcon.shape_hint) != null);
    // 负例钉（独立写死的期望形）：文案不得被改写成与真值骨分隔符不相干的形（P7 的变异体）。
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "路径;行;列") == null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "路径,行,列") == null);
}

test "第 204 轮 T2 毁源闸门吃布局族真值：拒绝面与放行面都按 src_dir 构造，而非本模块另抄的字面量" {
    // 本闸是 cmdEject 无条件 deleteTree(`dest`/`src_dir`) 前的唯一防线（D39 在册）。旧形制此处自持一枚
    // "src"，与 hub 的 `src_dir` 各写一份（同 D68 的隐藏判据硬编形制）：真值一改，闸门照旧拦旧名而
    // 写侧已换新名——毁源防线静默失效。三臂全部**经真值**构造路径，漂移即刻现形。
    try std.testing.expect(ejectDestHitsSourceTree(zzc.src_dir)); // dest 就是源码目录名本身
    try std.testing.expect(ejectDestHitsSourceTree(zzc.src_dir ++ "/sub")); // 其子目录
    try std.testing.expect(ejectDestHitsSourceTree("./" ++ zzc.src_dir)); // 带 `./` 噪声的同义形
    // 放行面须按真值的**邻域**构造：前缀相似不算源码树、真值非首段也不重叠。
    try std.testing.expect(!ejectDestHitsSourceTree(zzc.src_dir ++ "2"));
    try std.testing.expect(!ejectDestHitsSourceTree("my/" ++ zzc.src_dir));
    // 毕业包清单必须收录导出树目录：清单与写侧/清理侧同取族集合，漏 `src_dir` 即导出的 `.zig` 树
    // 不在毕业包内（`zig build --system` 型取用会缺文件），故此臂跨「闸门」与「清单」两面。
    var found = false;
    for (zzc.out_paths_family) |n| {
        if (std.mem.eql(u8, n, zzc.src_dir)) found = true;
    }
    try std.testing.expect(found);
}
test "第 205 轮 T1 标定基线吃工具链族真值：同源断言 + 漂移告警文案现形族系列串 + 完整串可解析回两级" {
    // A1 同源断言（异值锚：本模块另抄异值即红；同值内联不可锚，205 反证 M1 如实登册）。
    try std.testing.expectEqual(zzc.zig_major, diag_baseline_zig.major);
    try std.testing.expectEqual(zzc.zig_minor, diag_baseline_zig.minor);
    var buf: [256]u8 = undefined;
    // A2 基线内静默：把族真值本身喂进去须 null（告警判据与族真值同点）。
    try std.testing.expectEqual(@as(?[]const u8, null), zigDriftNote(zzc.zig_major, zzc.zig_minor, &buf));
    // A3 非基线告警须现形族系列串（文案里的标定值与族同源，否则升代后告警说谎）。
    const note = zigDriftNote(zzc.zig_major, zzc.zig_minor + 1, &buf) orelse {
        std.debug.print("T1 A3：非基线应产告警", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOfScalar(u8, note, 0) == null); // bufPrint 留尾脏，值段须无 NUL
    try std.testing.expect(std.mem.indexOf(u8, note, zzc.zig_series) != null);
    // A4 往返：族完整串可被 parseZigVersion 解析回族两级（本仓 zon/CI 用的正是这一形）。
    const parsed = parseZigVersion(zzc.zig_version ++ "\n") orelse {
        std.debug.print("T1 A4：完整串应可解析", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(zzc.zig_major, parsed.major);
    try std.testing.expectEqual(zzc.zig_minor, parsed.minor);
}
test "第 213 轮 T1 usage eject 行默认目录名与族 hub 耦合：字面量宣示段要求命中派生形（防 usage 与缺省 dest 分道）" {
    // usage_text 系 `\\` 逐行字面量（210/211 先例：不改写文本、以测耦合）——此处钉
    // 「（默认 <eject_default_dest>/）」派生段必须命中；缺省 dest 或 usage 任一侧漂移即红。
    const want = "（默认 " ++ zzc.eject_default_dest ++ "/）";
    try std.testing.expect(std.mem.indexOf(u8, usage_text, want) != null);
}

// ── CI e2e 基线脚本命令词族单一真值（第 226 轮 · D94）────────────────────────
// `tools/check-demos.ps1` 是本仓 CI（ci.yml 末步）与 Windows 用户本地的端到端基线守卫：
// 它以 PowerShell 字面量直接敲 `zzc` 的子命令、旗标与落盘路径——本 hub 的 sub_*/flag_*
// 与 zzc_paths 的目录族在那份脚本里各持第二份手抄。ps1 非测试图 source dependency、
// 也不在任何 addFileArg 清单（226 t2 探针 P1–P4 四路字面漂 fresh 587/587 全绿静默实锤），
// 且 GitCode 从不执行 Actions（D17 在册）＋本机 NO_PWSH 构成双盲区——词族漂移即基线脚本
// 打向不存在的命令/路径：清理循环静默漏删（残留污染）或守卫节 [FAIL] 错报（防线失信）。
// 第 213 轮 D81 判例为实证：`standard` 收编四源当时未含 ps1 两处（`eject standard` 与
// `@(".zzc", "standard")`），若彼轮真改名，ps1 即静默分道。本段把 ps1 活路径的逐字节
// 形制由既有真值派生成 needle 清单，交守卫步对面十八对账（ps1 经 addFileArg 入文件依赖）。

/// 对面十八核对项（needle/why 对；判据入 hub，守卫只做 I/O）。
pub const Ps1Needle = struct { needle: []const u8, why: []const u8 };

/// 由既有真值 comptime 派生的 ps1 活路径 needle 十七枚——改任一真值，needle 随动、
/// ps1 旧字面即失配红；改 ps1 字面，needle 不落空而守卫红。双向耦合自此单源。
pub const ps1_face = [_]Ps1Needle{
    .{ .needle = "\"zig-out/bin/" ++ zzc.prog_name ++ "\"", .why = "ps1 取用的 CLI exe 路径含程序名真值——改名即基线脚本找不到 exe（第 226 轮 D94）" },
    .{ .needle = "@(\"" ++ zzc.root ++ "\", \"" ++ zzc.eject_default_dest ++ "\")", .why = "demo 前置清理对含 .zzc 根与 eject 缺省落点两枚族真值——漂即清理静默漏删、残留污染（D81 判例面）" },
    .{ .needle = "\"" ++ zzc.symbols_file ++ "\"", .why = "D38 守卫节读写的符号表路径由落盘族派生——漂即守卫读空假绿或错红" },
    .{ .needle = "\"" ++ zzc.gen_dir ++ "/" ++ zzc.src_dir ++ "/\"", .why = "embed 镜像面路径由 gen 族派生——漂即 e2e A/B 两半失配" },
    .{ .needle = "\"" ++ zzc.default_entry ++ "\"", .why = "工程入口路径由布局族派生（多路活点位）——漂即守卫节打向不存在的入口" },
    .{ .needle = sub_eject ++ " " ++ zzc.eject_default_dest, .why = "活调用行 `& $zzc eject standard` 同含子命令名与缺省落点两枚真值——D81 时漏收编的成员（第 226 轮补）" },
    .{ .needle = "\"" ++ zzc.eject_default_dest ++ "/zig-out/bin\"", .why = "毕业产物查找路径首段=缺省落点真值——漂即 [FAIL] no eject artifact 错红" },
    .{ .needle = "-ArgumentList \"" ++ sub_run ++ "\"", .why = "demo 活路 run 调用词由子命令族派生——漂即全 demo [FAIL]" },
    .{ .needle = "-ArgumentList \"" ++ sub_check ++ "\"", .why = "check 活路调用词同族（多点位共用一 needle）——漂即 multi-file 回归守卫失联" },
    .{ .needle = "@(\"" ++ sub_init ++ "\"", .why = "init 守卫节 argv 首词同族——漂即 init e2e 错红" },
    .{ .needle = "-ArgumentList \"" ++ sub_version ++ "\"", .why = "version 活路调用词同族——漂即版本面守卫失联" },
    .{ .needle = "@(\"" ++ sub_lang ++ "\"", .why = "lang add 族活路首词同族——漂即 R140 系守卫错红" },
    .{ .needle = "@(\"" ++ sub_build ++ "\"", .why = "build 活路首词同族——漂即 R9g 外部包 build 路径守卫失联" },
    .{ .needle = "-ArgumentList \"" ++ sub_lsp ++ "\"", .why = "lsp 活路子进程调用词同族——漂即 R156 客户端守卫节失联" },
    .{ .needle = "\"" ++ flag_lang ++ "\"", .why = "--lang 旗标带引号形命中（与 --lang-file 以尾引号区分）——漂即选包守卫错红" },
    .{ .needle = "\"" ++ flag_lang_file ++ "\"", .why = "--lang-file 旗标形由旗标族派生——漂即 R9g 外部包三路透传守卫失联" },
    .{ .needle = "\"" ++ flag_as ++ "\"", .why = "--as 旗标形同族（207 轮孤字面量收编的消费对面）——漂即 lang add 别名面守卫错红" },
};

test "第 226 轮 T0 ps1 命令词族 needle 派生形：逐字节独立手抄对拍 + 基数钉（守卫对面十八的测试图备份）" {
    // A1 派生形钉：十七枚 needle 与 ps1 活路径的期望字面逐字节对拍——本 want 表独立
    // 手抄（ps1 非测试图 source dep、@embedFile 越不出 src 包路径·202 轮硬约束），与守卫
    // 对面十八双向互备：hub 派生漂（真值被改而未同步手抄期望面）即此测红；ps1 字面漂即守卫红。
    const want_needles = [_][]const u8{
        "\"zig-out/bin/zzc\"",
        "@(\".zzc\", \"standard\")",
        "\".zzc/symbols.txt\"",
        "\".zzc/gen/src/\"",
        "\"src/main.zz\"",
        "eject standard",
        "\"standard/zig-out/bin\"",
        "-ArgumentList \"run\"",
        "-ArgumentList \"check\"",
        "@(\"init\"",
        "-ArgumentList \"version\"",
        "@(\"lang\"",
        "@(\"build\"",
        "-ArgumentList \"lsp\"",
        "\"--lang\"",
        "\"--lang-file\"",
        "\"--as\"",
    };
    // A2 基数钉：新增/删除族成员须同时动 want 表（单边增删即此钉红）。
    try std.testing.expectEqual(want_needles.len, ps1_face.len);
    for (ps1_face, want_needles) |f, w| {
        try std.testing.expectEqualStrings(w, f.needle);
    }
    // A3 语义分工钉：`--lang` needle 不得是 `--lang-file` 的子串形（两者以尾引号区分，
    // 防派生退化后宽松伪钉——207 轮同族判例）。
    try std.testing.expect(std.mem.indexOf(u8, "\"--lang-file\"", "\"--lang\"") == null);
}

// ═════════════════════════ 第 227 轮 D95：ps1 码点构造文案断言族单一真值 ═══════════════════════════
// `tools/check-demos.ps1` 为保持脚本纯 ASCII（第 91 轮形制：`Native 0xXXXX,…` 码点构造中文），
// 其 21 处 Contains 断言的本体子串是 src 出口文案字面的第二份跨文件手抄——码点形正好绕过
// 了第 226 轮 D94 的字面量普查（当时只收命令词族 ASCII 形）。t2 探针实锤：src 文案漂（P1
// 「已创建→已落成」）与 ps1 码点漂（P2）双双 fresh 589/589 全绿静默——文案一改，e2e 基线
// 本机静默 [FAIL] 错红、GitCode 不跑 Actions（D17）＋ NO_PWSH 双盲，防线失信无人知。
// 本段把 18 枚文案段提为真值常量（main/server/translate 输出点委派），「错误」「关键字」
// 分别由 kind.zig/snippets.zig 既有真值派生，「类型」由本 hub 持真值供 translate 回译表委派；
// needle 由码点转换 comptime 派生（带 `Native ` 前缀形防子串宽松伪钉），交守卫对面十八
// 第二清单对账（ps1 已经 addFileArg 入文件依赖·零新增 I/O）。
// 不纳针面如实登册：方言关键字构造形 14 员（$N_const 等）真值源在语言包数据文件——pack 漂向
// 测试图已有 29 枚 fixture 间接钉捕获（t2 P6 坐实），ps1 自身漂向属数据面双盲、同 226 M8 形制；
// 「中文」系 pack $name 数据面（同族）；usage_text 同词系人约文本面（ps1 断言不命中帮助文本）。

/// UTF-8 串 → PowerShell 码点参数列（大写 hex、逗号无空格——ps1 全点位统一形制）。
/// 仅供 comptime 拼 needle；非 ASCII 字节序列直接编译拒（文案真值必为 CJK/全角形）。
fn cps(comptime s: []const u8) []const u8 {
    const DIGITS = "0123456789ABCDEF";
    var buf: [s.len * 11]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch @compileError("cps：非 UTF-8 字节");
        const cp: u21 = std.unicode.utf8Decode(s[i .. i + l]) catch @compileError("cps：坏 UTF-8 序列");
        // 手写大写 hex 转换（comptime 不借 std.fmt——bufPrint 在编译期超反向分支配额）。
        var tmp: [6]u8 = undefined;
        var dn: usize = 0;
        var d = cp;
        while (true) {
            tmp[dn] = DIGITS[d & 0xF];
            dn += 1;
            d >>= 4;
            if (d == 0) break;
        }
        buf[n] = '0';
        buf[n + 1] = 'x';
        var k: usize = 0;
        while (k < dn) : (k += 1) buf[n + 2 + k] = tmp[dn - 1 - k];
        n += 2 + dn;
        if (i + l < s.len) {
            buf[n] = ',';
            n += 1;
        }
        i += l;
    }
    return buf[0..n];
}

/// 码点断言 needle（`Native 0x…` 前缀形：防「语言包」⊂「当前语言包」类包含关系宽松伪钉）。
fn nativeAssert(comptime phrase: []const u8) []const u8 {
    return "Native " ++ cps(phrase);
}

// —— 文案段真值（main.zig/server.zig/translate.zig 输出口委派至此；ps1 断言 needle 由此派生）——
pub const np_not_detected = "未检测到"; // eject 无 zig 提示（main cmdEject）
pub const np_could_not_query = "未能向"; // fingerprint 查询失败提示（main）
pub const np_upgrade = "请升级"; // $format 过新提示（main lang add）
pub const np_created = "已创建"; // init 成功行（main cmdInit）
pub const np_no_overwrite = "未覆盖"; // init 入口已存在提示（main）
pub const np_unsafe = "不安全"; // init 工程名拒绝（main）
pub const np_subcmd = "子命令"; // 未知子命令提示（main dispatch）+ lang verb 拒绝行
pub const np_artifact = "产物"; // build 成功行（main）+ eject 验证成功消息
pub const np_pass = "通过"; // 检查通过行（main cmdCheck）+ eject 验证消息
pub const np_dialect_files = "方言文件"; // 检查通过行量词宾语（main）
pub const np_cur_pack = "当前语言包"; // lang 详情头（main）
pub const np_reg_packs = "可注册包"; // lang 详情列表头（main）+ lang verb 拒绝行
pub const np_pack_word = "语言包"; // version 行回显（main）
pub const np_installed = "已装入"; // lang add 成功行（main）
pub const np_dup_installed = "本工程内已装有"; // lang add 重复拒绝（main）
pub const np_reg_key_open = "注册名「"; // lang add 非法注册名拒绝（main）
pub const np_unknown_pack = "未知语言包"; // --lang 未知包拒绝（main）
pub const np_lexical = "词法"; // 词法诊断 kind 前缀（main 机读出口 + server 诊断体）
pub const np_type = "类型"; // zig 报错回译短语段（diag/translate 回译表）

// —— 全角/纯母语拦截文案模板族（第 233 轮 D101）——
// main `cmdCheck` 与 lsp `server.appendFastItems` 两出口对同一违例的提示正文必须逐字同形
//（server.zig 顶注所声明的不变量）。旧形制两处各持整串字面量手抄、任一侧重措另一侧静默失联，
// 全仓无测捕获（233 t2 P1：独漂 server 正文 fresh 601•601 全绿）。此处立正文单一真值，两出口
// 各自 ++ 坐标前缀（main 加 mcon.line_head、server 走 LSP range）后共用同一 msg body。fw_* 三枚
// 沿用 np_lexical 作 kind 前缀（前缀段 D95 已有 ps1 针，此处连带正文入源、共一份真值）。
pub const msg_fw_space: []const u8 = np_lexical ++ ": {s}，请改用半角空格作缩进/分隔";
pub const msg_fw_symbol: []const u8 = np_lexical ++ ": {s}，请改用半角 `{s}`（Zig 语法符号不翻译）";
pub const msg_fw_other: []const u8 = np_lexical ++ ": {s}（`{s}`）";
pub const msg_pure_native: []const u8 = "纯母语: 方言源须全用母语词形，英文 `{s}` 请改用 `{s}`";

/// ps1 码点断言 needle 二十一枚——改任一真值，needle 随动、ps1 旧码点即失配红；
/// 改 ps1 码点，needle 不落空而守卫红。双向耦合自此单源（守卫对面十八第二清单）。
pub const ps1_native_face = [_]Ps1Needle{
    .{ .needle = nativeAssert(np_not_detected), .why = "init/eject 出口文案「未检测到」码点断言——漂即 nozig 守卫静默错红（第 227 轮 D95）" },
    .{ .needle = nativeAssert(np_could_not_query), .why = "fingerprint 查询失败提示「未能向」——漂即 nozig stderr 守卫错红" },
    .{ .needle = nativeAssert(np_upgrade), .why = "外部包过新提示「请升级」——漂即 r9g B 守卫错红" },
    .{ .needle = nativeAssert(np_created), .why = "init 成功行「已创建」——漂即 init A 守卫错红（t2 P1/P2 双静默主证）" },
    .{ .needle = nativeAssert(np_no_overwrite), .why = "init 防覆盖提示「未覆盖」——漂即 init B 守卫错红" },
    .{ .needle = nativeAssert(np_unsafe), .why = "init 工程名拒绝「不安全」——漂即 init C 守卫错红" },
    .{ .needle = nativeAssert(np_subcmd), .why = "未知子命令提示「子命令」——漂即 dispatch A 守卫错红" },
    .{ .needle = nativeAssert(np_artifact), .why = "build 成功行「产物」——漂即 build A / flag C 两守卫错红" },
    .{ .needle = nativeAssert(kdiag.zhOf("error")), .why = "裸诊断前缀「错误」由 kind 词汇 hub 派生（D77）——非 args 另立手抄" },
    .{ .needle = nativeAssert(np_pass), .why = "检查通过「通过」——漂即 test A / check A 守卫错红" },
    .{ .needle = nativeAssert(np_dialect_files), .why = "「方言文件」量词宾语——漂即 check A 措辞降级守卫错红" },
    .{ .needle = nativeAssert(np_cur_pack), .why = "lang 详情头「当前语言包」——漂即 lang 守卫错红" },
    .{ .needle = nativeAssert(np_reg_packs), .why = "lang 列表头「可注册包」——漂即 lang 守卫错红（用户失行动面）" },
    .{ .needle = nativeAssert(np_pack_word), .why = "version 行「语言包」回显——Native 前缀形防其为当前/未知语言包 needle 子串" },
    .{ .needle = nativeAssert(np_unknown_pack), .why = "--lang 未知包拒绝「未知语言包」——漂即 flag B 守卫错红" },
    .{ .needle = nativeAssert(np_installed), .why = "lang add 成功行「已装入」——漂即 langadd A 守卫错红" },
    .{ .needle = nativeAssert(np_reg_key_open), .why = "非法注册名拒绝含全开引号「注册名「」——漂即 langadd E 守卫错红" },
    .{ .needle = nativeAssert(np_dup_installed), .why = "重复拒绝行「本工程内已装有」——漂即 langadd C 守卫错红" },
    .{ .needle = nativeAssert(np_lexical), .why = "词法诊断 kind「词法」（main 机读出口 + server 委派）——漂即 lsp 守卫错红" },
    .{ .needle = nativeAssert(snippets_hub.g_keyword), .why = "hover 词类标签「关键字」由 snippets 真值派生（D87）——非 args 另立手抄" },
    .{ .needle = nativeAssert(np_type), .why = "回译短语「类型」段（translate 回译表委派）——漂即 on-save 语义守卫错红" },
};

test "第 227 轮 T0 ps1 码点文案断言 needle：逐字节独立手抄对拍 + 基数钉 + Native 前缀互斥钉" {
    // A1 派生形钉：廿一枚 needle 与 ps1 码点断言的期望字面逐字节对拍——本 want 表独立手抄
    //（ps1 非测试图 source dep·202 轮硬约束），与守卫对面十八第二清单双向互备。
    const want_native = [_][]const u8{
        "Native 0x672A,0x68C0,0x6D4B,0x5230",
        "Native 0x672A,0x80FD,0x5411",
        "Native 0x8BF7,0x5347,0x7EA7",
        "Native 0x5DF2,0x521B,0x5EFA",
        "Native 0x672A,0x8986,0x76D6",
        "Native 0x4E0D,0x5B89,0x5168",
        "Native 0x5B50,0x547D,0x4EE4",
        "Native 0x4EA7,0x7269",
        "Native 0x9519,0x8BEF",
        "Native 0x901A,0x8FC7",
        "Native 0x65B9,0x8A00,0x6587,0x4EF6",
        "Native 0x5F53,0x524D,0x8BED,0x8A00,0x5305",
        "Native 0x53EF,0x6CE8,0x518C,0x5305",
        "Native 0x8BED,0x8A00,0x5305",
        "Native 0x672A,0x77E5,0x8BED,0x8A00,0x5305",
        "Native 0x5DF2,0x88C5,0x5165",
        "Native 0x6CE8,0x518C,0x540D,0x300C",
        "Native 0x672C,0x5DE5,0x7A0B,0x5185,0x5DF2,0x88C5,0x6709",
        "Native 0x8BCD,0x6CD5",
        "Native 0x5173,0x952E,0x5B57",
        "Native 0x7C7B,0x578B",
    };
    // A2 基数钉：成员单边增删即红（与 226 T0 同族形制）。
    try std.testing.expectEqual(want_native.len, ps1_native_face.len);
    for (ps1_native_face, want_native) |f, w| {
        try std.testing.expectEqualStrings(w, f.needle);
    }
    // A3 Native 前缀互斥钉：短词 needle 不得为长词 needle 子串（「语言包」⊂「当前语言包」、
    // 「注册包」∈「可注册包」类包含关系以 `Native ` 前缀形消解——207/226 轮宽松伪钉判例同族）。
    for (ps1_native_face) |a| {
        for (ps1_native_face) |b| {
            if (a.needle.len < b.needle.len) {
                try std.testing.expect(std.mem.indexOf(u8, b.needle, a.needle) == null);
            }
        }
    }
}

test "第 233 轮 T0 全角/纯母语拦截文案模板族单源＋两出口委派源级锚＋真渲染同形——D101" {
    // A1 四枚正文值锚（把「逐字同形」文案升为刻意、有测的单一真值；hub 自身漂移即红）。
    try std.testing.expectEqualStrings("词法: {s}，请改用半角空格作缩进/分隔", msg_fw_space);
    try std.testing.expectEqualStrings("词法: {s}，请改用半角 `{s}`（Zig 语法符号不翻译）", msg_fw_symbol);
    try std.testing.expectEqualStrings("词法: {s}（`{s}`）", msg_fw_other);
    try std.testing.expectEqualStrings("纯母语: 方言源须全用母语词形，英文 `{s}` 请改用 `{s}`", msg_pure_native);
    // A2 fw_ 三枚 kind 前缀仍由 np_lexical 派生（前缀段与正文段共源、不各立手抄）。
    try std.testing.expect(std.mem.startsWith(u8, msg_fw_space, np_lexical));
    try std.testing.expect(std.mem.startsWith(u8, msg_fw_symbol, np_lexical));
    try std.testing.expect(std.mem.startsWith(u8, msg_fw_other, np_lexical));

    // A3 两出口委派源级锚：@embedFile 直读消费文件真源（真 source dep、改其委派形必重编本测），
    // 逐 needle 命中且频次为 1：任一出口回退手抄字面量（委派形消失）即红——跨模块「逐字同形」
    // 不变量自此有真锚（承 224 T0 A3 委派形双向锚形制）。
    const main_src = @embedFile("../main.zig");
    const server_src = @embedFile("../lsp/server.zig");
    const countNeedle = struct {
        fn f(hay: []const u8, ndl: []const u8) usize {
            var n: usize = 0;
            var i: usize = 0;
            while (std.mem.indexOf(u8, hay[i..], ndl)) |k| {
                i += k + ndl.len;
                n += 1;
            }
            return n;
        }
    }.f;
    const main_face = [_][]const u8{
        "mcon.line_head ++ cli.msg_fw_space",
        "mcon.line_head ++ cli.msg_fw_symbol",
        "mcon.line_head ++ cli.msg_fw_other",
        "mcon.line_head ++ cli.msg_pure_native",
    };
    for (main_face) |nd| try std.testing.expectEqual(@as(usize, 1), countNeedle(main_src, nd));
    const server_face = [_][]const u8{
        "allocPrint(gpa, cli.msg_fw_space",
        "allocPrint(gpa, cli.msg_fw_symbol",
        "allocPrint(gpa, cli.msg_fw_other",
        "allocPrint(gpa, cli.msg_pure_native",
    };
    for (server_face) |nd| try std.testing.expectEqual(@as(usize, 1), countNeedle(server_src, nd));
    // A4 反锚：正文整串只应存于本 hub（args.zig）、两消费文件不得再持字面量（回退手抄即命中→红）。
    const bodies = [_][]const u8{
        "请改用半角空格作缩进/分隔",
        "Zig 语法符号不翻译",
        "方言源须全用母语词形",
    };
    for (bodies) |b| {
        try std.testing.expectEqual(@as(usize, 0), countNeedle(main_src, b));
        try std.testing.expectEqual(@as(usize, 0), countNeedle(server_src, b));
    }

    // A5 两出口真渲染同形：同一违例经 CLI 形（line_head ++ msg）与 LSP 形（msg 独用）分别渲染，
    // 剥坐标前缀后正文逐字节相等——把 server.zig 顶注的人约不变量升为运行期真锚。
    var cb: [256]u8 = undefined;
    const cli_line = std.fmt.bufPrint(&cb, mcon.line_head ++ msg_fw_symbol, .{ "src/main.zz", @as(usize, 4), @as(usize, 21), "全角分号", ";" }) catch return error.TestUnexpectedResult;
    var lb: [256]u8 = undefined;
    const lsp_line = std.fmt.bufPrint(&lb, msg_fw_symbol, .{ "全角分号", ";" }) catch return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, cli_line, lsp_line));
}
