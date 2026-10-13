//! 命令行参数解析：从 `[文件.zz] [zig 旗标…]` 里分离方言入口与透传给 zig 的其余参数。

const std = @import("std");
const Pack = @import("../lang/pack.zig").Pack; // 第 142 轮：模板生成器按包组词需 Pack 反查面

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
pub fn pickEntry(args: []const []const u8) EntryPick {
    for (args, 0..) |a, i| {
        if (std.mem.endsWith(u8, a, ".zz")) return .{ .entry = a, .idx = i };
    }
    return .{ .entry = "src/main.zz", .idx = null };
}

/// 方言入口相对路径 → 生成树内 .zig 落点。
/// 根目录文件直接 `.zzc/gen/<stem>.zig`；带子目录则保留层级 `.zzc/gen/<dir>/<stem>.zig`。
/// 第 60 轮自 main.zig 下沉至测试图（D7：main.zig 的 test 块从不执行、此纯函数此前零有效覆盖）；
/// 激活测时发现旧实现对根目录文件会因 `dirname orelse "."` 产出 `.zzc/gen/./main.zig` 的 `.` 段噪声，按测意图修正。
pub fn genPathFor(gpa: std.mem.Allocator, rel: []const u8) ![]const u8 {
    const stem = std.fs.path.stem(std.fs.path.basename(rel));
    if (std.fs.path.dirname(rel)) |dir_of| {
        return std.fmt.allocPrint(gpa, ".zzc/gen/{s}/{s}.zig", .{ dir_of, stem });
    }
    return std.fmt.allocPrint(gpa, ".zzc/gen/{s}.zig", .{stem});
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
    return findFlag(args, "--lang");
}

/// R9g（第 103 轮）：取 `--lang-file <路径>` 外部语言包文件旗标（第三方发行包运行时加载、免重编译）。
pub fn findLangFileFlag(args: []const []const u8) ?[]const u8 {
    return findFlag(args, "--lang-file");
}

/// 从参数列表剔离 `--lang <name>`（两参形）/`--lang=<name>`（一参形），返回新 ArrayList（元素借用自 args、仅本体分配）。
/// 目的：`--lang` 是 zzc 层旗标，不能透传给 zig。缺值的裸 `--lang`（末尾）一并剔离。无旗标时返回逐元素等长的原样副本。
pub fn stripLangFlag(gpa: std.mem.Allocator, args: []const []const u8) !std.ArrayList([]const u8) {
    return stripFlag(gpa, args, "--lang");
}

/// R9g：剔离 `--lang-file`（两参/等号形）——同不透传 zig 契约。
pub fn stripLangFileFlag(gpa: std.mem.Allocator, args: []const []const u8) !std.ArrayList([]const u8) {
    return stripFlag(gpa, args, "--lang-file");
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
        if (first_real and std.mem.eql(u8, seg, "src")) at_src_root = true;
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
    try A(gpa, &out, &.{"// zzc 方言工程模板 —— 进入目录后运行 `zzc run` 即可\n\n"});
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

/// CLI 帮助文本（无参/未知子命令时回显）。属 CLI 表面数据，放在测试图内的 cli 模块以便
/// “子命令列表完整性”回归单测能真正执行（main.zig 的 test 块不被 build.zig 汇总、从不执行）。
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
    \\  zzc lang               列出当前语言包与可注册包
    \\  zzc lang add <文件>   装入外部语言包到本工程（--as 注册名 可选；免重编译）
    \\  zzc version            版本与当前语言包
    \\选项：
    \\  --lang <名>            选择语言包（如 zh / 中文；缺省为中文；该旗标不透传 zig）
    \\  --lang-file <路径>     从外部文件加载语言包（第三方发行包、免重编译；与 --lang 互斥；不透传 zig）
    \\方言文件默认取 src/main.zz；错误标签与 std 错误名保持 ASCII 原样。
;

test "usage 文本列出全部子命令" {
    // 每个子命令名都必须出现在帮助文本里，避免新增命令忘更帮助、或改名后文本漏改。
    for ([_][]const u8{ "init", "check", "build", "run", "test", "eject", "lang" }) |sub| {
        try std.testing.expect(std.mem.indexOf(u8, usage_text, sub) != null);
    }
}

/// 从 `build.zig.zon` 文本里抽取 `.fingerprint = 0x....` 的十六进制串（含 `0x` 前缀）；
/// 仅当同文里声明的 `.name` 与 `expected_name` 一致时才返回（避免把旧包名的 fingerprint
/// 误留给改名后的工程，那会令 `zig build` 判 invalid）。无名字匹配/无该字段/`0x` 后无十六进制位返回 null。
/// 返回的切片**借用自入参**（调用方须保持入参存活）。
/// 供 `eject` 幂等复用：重复导出到同一目标时沿用既有 fingerprint（zig 每次探得的低半随机）。
pub fn parseFingerprintFromZone(text: []const u8, expected_name: []const u8) ?[]const u8 {
    // 先校包名一致：`    .name = .app,` 中的 `app` 须等于本次 app_name。
    const name_marker = ".name = .";
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
    const marker = ".fingerprint = 0x";
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
        if (std.mem.startsWith(u8, line, "pub fn main(")) return true;
        if (std.mem.startsWith(u8, line, "fn main(")) return true;
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
    if (!std.mem.endsWith(u8, p, ".zz")) return null; // 先筛后缀再拼接，省无谓 join
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
