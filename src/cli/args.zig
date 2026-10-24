//! 命令行参数解析：从 `[文件.zz] [zig 旗标…]` 里分离方言入口与透传给 zig 的其余参数。

const std = @import("std");
const Pack = @import("../lang/pack.zig").Pack; // 第 142 轮：模板生成器按包组词需 Pack 反查面
const zzc = @import("../zzc_paths.zig"); // 第 200 轮 D68：.zzc 内部路径族改由该模块持唯一真值
const mcon = @import("../machine_contract.zig"); // 第 203 轮 D71：机读旗标名与单行形制的契约 hub
const userpack = @import("../lang/userpack.zig"); // 第 316 轮 D175：注册名长度上限取该模块真值，话术零手数
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
    // 第 325 轮 D184：扫描逻辑归并到 `scanFlag` 单源；本函数只保留旧语义（缺值→null，由调用方
    // 按未选包处置），需要区分「缺值/无旗标」的诊断路径改用三态版本。
    return switch (scanFlag(args, name)) {
        .value => |v| v,
        else => null,
    };
}

/// 旗标取值扫描三态（第 325 轮 D184）：`findFlag` 只答「值是多少」，把**缺值**与**无旗标**都折成
/// null——调用方无从区分，于是 `check --lang` 尾随缺值被静默按默认包跑（活体真值：RC=0 全绿）。
/// 这里把两种 null 拆开：无旗标＝absent、有旗标无值＝missing（末尾缺后继／`--lang=` 空值／值形似
/// zzc 自有旗标如 `--lang --machine`）。
pub const FlagScan = union(enum) { absent, missing, value: []const u8 };

pub fn scanFlag(args: []const []const u8, name: []const u8) FlagScan {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, name)) {
            if (i + 1 >= args.len) return .missing;
            const v = args[i + 1];
            // 值位置若是 zzc 自有旗标（`--lang --machine`），说明用户漏了取值且多打一枚旗标——
            // 不得把它吞成包名（旧形报「未知语言包「--machine」」，把诊断引向包名而非缺值）。
            if (isZzcFlag(v)) return .missing;
            return .{ .value = v };
        }
        // 等号形无堆分配：直接按字节位置判 `=`（`--lang=x` 不会被 `--lang-file` 误匹）。
        if (a.len > name.len and a[name.len] == '=' and std.mem.startsWith(u8, a, name)) {
            const v = a[name.len + 1 ..];
            return if (v.len == 0) .missing else .{ .value = v }; // `--lang=` 空取值同缺值
        }
    }
    return .absent;
}

/// 该旗标在参数里的**出现次数**（两参形＋等号形皆计；第 325 轮 D184）。旧形重复即前者胜、静默
/// 丢弃后者——`check --lang zh --lang 繁体` 实测 RC=0 全绿，取值来源无从追问，故改为重复即拒。
pub fn countFlag(args: []const []const u8, name: []const u8) usize {
    var n: usize = 0;
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) {
            n += 1;
            continue;
        }
        if (a.len > name.len and a[name.len] == '=' and std.mem.startsWith(u8, a, name)) n += 1;
    }
    return n;
}

/// 取值旗标清单（第 325 轮 D184）：缺值/重复闸只对这些旗标有意义（布尔旗标无取值可缺）。三枚
/// 括注各自取值语义，缺值话术据此给用法示例。
pub const flag_value_takers = [_]struct { flag: []const u8, hint: []const u8 }{
    .{ .flag = flag_lang, .hint = "语言包名" },
    .{ .flag = flag_lang_file, .hint = "外部语言包文件路径" },
    .{ .flag = flag_lang_overlay, .hint = "叠加层语言包文件路径" },
    .{ .flag = flag_to, .hint = "目标语言包名" },
};

/// `arg` 若本身是 zzc 自有旗标（全等或 `<旗标>=` 前缀），返回该旗标名（第 325 轮 D184）。用途：
/// `zzc --lang zh check` 的 all_args[1] 是旗标而非子命令，旧兜底报「未知或不完整的子命令」——
/// 用户给的是旗标，诊断却指向子命令，属误诊；据此改报「旗标须写在子命令之后」。
pub fn ownFlagName(arg: []const u8) ?[]const u8 {
    for (zzc_flags) |f| {
        if (std.mem.eql(u8, arg, f)) return f;
        if (arg.len > f.len and arg[f.len] == '=' and std.mem.startsWith(u8, arg, f)) return f;
    }
    return null;
}

/// 子命令第一参数位的分类（第 326 轮 D185）。活体真值：`--fuzz check`／`--unknown check`／
/// `--langx zh check`／`-O check`／`--`／`-x`／`--check src/main.zz` 八形**一律**报「未知或不完整的
/// 子命令」——用户打的是旗标（自有/近似/zig 透传皆有），诊断却让他们去查子命令名。
/// 四分类各自给对应话术：自有旗标→位置指引；近似名→笔误建议＋位置；`--`→分隔符不能打头；
/// 其余旗标形→「是旗标不是子命令」＋透传指引。zzc 子命令均不以 `-` 开头，故以 `-` 开头即非子命令。
pub const CmdSlot = union(enum) {
    ok,
    own: []const u8,
    near: []const u8,
    separator,
    flag_shaped,
};

/// 子命令名清单话术（第 327 轮 D186；`subcommands` comptime 派生、顿号相连——添/删子命令文案随动）。
/// 注意：本文件下方已有 `subcommands` 穷举表＋`isKnownSubcommand`＋完备测（dispatch/帮助行/文档词
/// 三源对账），此轮**不另立第二套清单**——即 324 轮「禁两套计数语义」同一纪律：真值只此一份。
pub const subcmd_list_text = blk: {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (subcommands, 0..) |c, i| {
        if (i > 0) {
            const sep = "、";
            if (n + sep.len + c.len > buf.len) @compileError("subcmd_list_text 缓冲不足：扩子命令须随动 buf");
            @memcpy(buf[n..][0..sep.len], sep);
            n += sep.len;
        }
        if (n + c.len > buf.len) @compileError("subcmd_list_text 缓冲不足：扩子命令须随动 buf");
        @memcpy(buf[n..][0..c.len], c);
        n += c.len;
    }
    break :blk buf[0..n] ++ "";
};

/// 编辑距离是否 **≤1**（第 327 轮 D186；受限 Damerau：单处替换／单处增删／一处相邻换位）。
/// 不分配、不看代价表——子命令名都短，逐形判定即可；距离 ≥2 不给建议（避免瞎猜比不猜更糟）。
fn withinOneEdit(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const la = a.len;
    const lb = b.len;
    if (la > lb + 1 or lb > la + 1) return false;
    if (la == lb) {
        var first: ?usize = null;
        var i: usize = 0;
        while (i < la) : (i += 1) {
            if (a[i] != b[i]) {
                if (first) |f| {
                    // 第二处差异只允许是「与第一处构成相邻换位」：ab ↔ ba 且其后全等。
                    if (i != f + 1 or a[f] != b[i] or a[i] != b[f]) return false;
                    var j: usize = i + 1;
                    while (j < la) : (j += 1) {
                        if (a[j] != b[j]) return false;
                    }
                    return true;
                }
                first = i;
            }
        }
        return first != null; // 仅一处替换
    }
    // 长度差 1：短串与长串去掉某一个字符后全等（一处增/删）。
    const short = if (la < lb) a else b;
    const long = if (la < lb) b else a;
    var i: usize = 0;
    while (i < short.len and short[i] == long[i]) : (i += 1) {}
    // 跳过 long 的第 i 个字符后，余下须全等。
    var j: usize = i;
    while (j < short.len) : (j += 1) {
        if (short[j] != long[j + 1]) return false;
    }
    return true;
}

/// 最近的合法子命令（第 327 轮 D186）：`chek`→check、`biuld`→build、`testt`→test、`ejct`→eject、
/// `initx`→init。合法子命令本身返回 null（调用方只在未知分支用）；多处等距取表内前者。
pub fn nearSubcmd(name: []const u8) ?[]const u8 {
    return nearWord(name, &subcommands);
}

/// 通用「近似词」判据（第 329 轮 D188）：精确命中返 null（那是合法词而非笔误），长度 ≤1 的笔误才
/// 返表内首枚；空串不判（否则任何单字词都会被「空串距离 1」错命中）。一级子命令与 lang 的二级动词
/// 共用本判据——两处各写一套编辑距离，迟早分道。
pub fn nearWord(name: []const u8, words: []const []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    for (words) |w| {
        if (std.mem.eql(u8, name, w)) return null;
    }
    for (words) |w| {
        if (withinOneEdit(name, w)) return w;
    }
    return null;
}

pub fn classifyCmdSlot(arg: []const u8) CmdSlot {
    if (std.mem.eql(u8, arg, "--")) return .separator;
    if (ownFlagName(arg)) |f| return .{ .own = f };
    if (arg.len > 0 and arg[0] == '-') { // 含单破折号 `-`：同样不可能是子命令
        if (nearZzcFlag(arg)) |n| return .{ .near = n };
        return .flag_shaped;
    }
    return .ok;
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

/// 第三方库翻译（本次）：取 `--lang-overlay <路径>` 外部叠加层语言包旗标（把叠加层累积并入
/// 所选基包之上、免重编译）。与 `--lang`/`--lang-file` 可合用（overlay 叠在所选基包上，非互斥）。
pub fn findLangOverlayFlag(args: []const []const u8) ?[]const u8 {
    return findFlag(args, flag_lang_overlay);
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

/// 第三方库翻译（本次）：剔离 `--lang-overlay`（两参/等号形）——同不透传 zig 契约。
pub fn stripLangOverlayFlag(gpa: std.mem.Allocator, args: []const []const u8) !std.ArrayList([]const u8) {
    return stripFlag(gpa, args, flag_lang_overlay);
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

test "第三方库翻译：--lang-overlay 两参/等号形识别、与 --lang/--lang-file 前缀互不误匹、连剔不透传 zig" {
    const gpa = std.testing.allocator;
    // 三枚同族前缀旗标并存：各取所得，--lang 不误匹 --lang-file/--lang-overlay（全等形取后继、等号形需 `=` 位）。
    const a = [_][]const u8{ "run", "src/main.zz", "--lang", "zh", "--lang-file", "包.txt", "--lang-overlay", "contrib/httpz.txt" };
    try std.testing.expectEqualStrings("zh", findLangFlag(&a).?);
    try std.testing.expectEqualStrings("包.txt", findLangFileFlag(&a).?);
    try std.testing.expectEqualStrings("contrib/httpz.txt", findLangOverlayFlag(&a).?);
    // 串接剔离三枚 zzc 旗标（连值）后仅剩 run + 文件——皆不透传 zig。
    var s1 = try stripLangFlag(gpa, &a);
    defer s1.deinit(gpa);
    var s2 = try stripLangFileFlag(gpa, s1.items);
    defer s2.deinit(gpa);
    var s3 = try stripLangOverlayFlag(gpa, s2.items);
    defer s3.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), s3.items.len);
    try std.testing.expectEqualStrings("run", s3.items[0]);
    try std.testing.expectEqualStrings("src/main.zz", s3.items[1]);
    // 等号形 + 裸尾缺值形。
    const e = [_][]const u8{"--lang-overlay=contrib/httpz.txt"};
    try std.testing.expectEqualStrings("contrib/httpz.txt", findLangOverlayFlag(&e).?);
    const d = [_][]const u8{ "check", "--lang-overlay" };
    try std.testing.expectEqual(@as(?[]const u8, null), findLangOverlayFlag(&d));
    var s4 = try stripLangOverlayFlag(gpa, &d);
    defer s4.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s4.items.len);
}

test "护栏：旗标等号空值形边界——`--lang=`/`--lang-file=` 归「缺值」而非空包名（第 325 轮 D184 升级）" {
    // 承 108/109 轮方法论：findFlag 的「等号空值」形（`--name=`）此前零覆盖。旧契约（第 321 轮前）
    // 是本测原本钉的：`--lang=` 令 findLangFlag 返回空串 ""（非 null），caller 据此报「未知语言包
    // 『』」——用户显式给了空值，诊断却让他去查包名（其实包名是空的）。第 325 轮 D184 收口：
    // 空取值与裸尾缺值同属**缺值**，真跑层报「旗标「--lang」缺少取值」并给用法形；查询层
    // `findFlag` 一律 null（诊断路径改用 `scanFlag` 三态区分 absent/missing）。
    const gpa = std.testing.allocator;

    // 等号空值：findFlag 层 null；三态层须是 missing（不得混同 absent）。
    const l = [_][]const u8{"--lang="};
    try std.testing.expectEqual(@as(?[]const u8, null), findLangFlag(&l));
    try std.testing.expect(scanFlag(&l, flag_lang) == .missing);
    const lf = [_][]const u8{"--lang-file="};
    try std.testing.expectEqual(@as(?[]const u8, null), findLangFileFlag(&lf));
    try std.testing.expect(scanFlag(&lf, flag_lang_file) == .missing);

    // 裸尾缺值：同为 missing（两形区别只在有无 `=`，诊断话术已统一）。
    const bare = [_][]const u8{ "check", "--lang" };
    try std.testing.expectEqual(@as(?[]const u8, null), findLangFlag(&bare));
    try std.testing.expect(scanFlag(&bare, flag_lang) == .missing);

    // 无旗标：absent——诊断路径据此不报缺值（否则每条命令都会误报）。
    const none = [_][]const u8{ "check", "src/main.zz" };
    try std.testing.expect(scanFlag(&none, flag_lang) == .absent);

    // strip 侧不受影响：空值形仍整枚剔离，不得把 `--lang=` 透传 zig。
    var s = try stripLangFlag(gpa, &l);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), s.items.len);
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
    const w_const = Pack.firstKeywordFor(lang, Pack.zig_const) orelse Pack.zig_const;
    const w_var = Pack.firstKeywordFor(lang, Pack.zig_var) orelse w_const; // 无 var 词形则退常宣声明（literal 推导合法）
    const w_fn = Pack.firstKeywordFor(lang, Pack.zig_fn) orelse Pack.zig_fn;
    const w_import = Pack.firstKeywordFor(lang, Pack.zig_import) orelse Pack.zig_import;
    const w_pub = Pack.firstKeywordFor(lang, "pub") orelse "pub"; // 入口必 pub（zig 硬要求），缺则 ASCII 直通
    const w_main = Pack.firstKeywordFor(lang, Pack.zig_main) orelse Pack.zig_main;
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
    // 第 257 轮 D124：多段回退支（opt_std 与 opt_std_dbg 皆在、却无 `std.debug.print` 叶）以 allocPrint 造
    // `"<std 名>.<std.debug 名>"` 临时串，下方 appendTemplateSegs 只把其字节拷入 out、该临时串自身从不 free
    // （承 D23/D60/D121/D122/D123 守则：接住命名临时串 + defer free·覆盖 A()/toOwnedSlice 失败的全返回路径·
    //   生产侧 gpa_ 为进程 arena、历轮测皆 arena 包裹故双侧掩盖·叶形/ASCII 兜底两支为借用不 free）。
    var print_callee_owned: ?[]const u8 = null;
    defer if (print_callee_owned) |s| gpa.free(s);
    const print_callee = if (Pack.firstKeywordFor(lang, "std.debug.print")) |w| w else if (opt_std != null and opt_std_dbg != null) blk: {
        const s = std.fmt.allocPrint(gpa, "{s}.{s}", .{ opt_std.?, opt_std_dbg.? }) catch return error.OutOfMemory;
        print_callee_owned = s;
        break :blk s;
    } else "std.debug.print";
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
/// `zzc relocalize`：把本工程重生为另一语言包词形的孪生工程（`translate` 的对偶面，
/// 第 331 轮 D190）——方言面入、方言面出，源树不改。
pub const sub_relocalize: []const u8 = "relocalize";
pub const sub_lsp: []const u8 = "lsp";
pub const sub_lang: []const u8 = "lang";
pub const sub_version: []const u8 = "version";

/// 受支持子命令名的穷举表：dispatch 各臂、帮助行命令词、完备测三者对账的单一真值。
pub const subcommands = [_][]const u8{
    sub_init, sub_check, sub_build, sub_run, sub_test, sub_eject, sub_relocalize, sub_lsp, sub_lang, sub_version,
};

/// cmd 是否为受支持的用户子命令（未知子命令兜底与完备测的共同判据）。
pub fn isKnownSubcommand(cmd: []const u8) bool {
    for (subcommands) |sub| {
        if (std.mem.eql(u8, cmd, sub)) return true;
    }
    return false;
}

/// 惯例帮助旗标族单一真值（第 302 轮 D161）：main 的帮助兜底此前以四枚裸字面量手抄
/// （`--help`/`-h`/`-?`/`help`），而文档面（README/书稿/方案书/contributing）的命令样例同样
/// 手抄这些词——297/301 轮在册的「受支持词全集」判据缺此四员，文档逆向鬼词普查把合法的
/// `zzc help` 误报即须豁免手抄，双源互踩。自此 main 读表驱动、守卫合法集同源派生。
pub const help_words = [_][]const u8{ "--help", "-h", "-?", "help" };

/// 对面三十八·`src/main.zig` 委派形针：main 须以 `cli.help_words` 表驱动而非回退四枚手抄字面
///（承 224 轮 `tl_face` 委派形形制）——改回手抄即文档面合法集与运行期兜底分道的起点。
pub const help_main_face = [_]zzc.BuildFace{
    .{ .needle = "for (cli.help_words)", .why = "main 帮助兜底须读 hub 表驱动——手抄回潮即两源分道（第 302 轮 D161）" },
};

/// 文档命令词的合法集判据（第 302 轮 D161）：`subcommands` 九枚 ∪ `help_words` 四枚——
/// 文档面（README/书稿/方案书/contributing）出现的 `zzc <词>` 必须落在此集，否则读者照敲
/// 即 UnknownSubcommand EXIT=2。抽取器只收连续小写段，`--help`/`-h`/`-?` 非小写段不入集，
/// 故实际参集的文档面合法词为九子命令＋`help`。
pub fn isDocWordLegal(word: []const u8) bool {
    if (isKnownSubcommand(word)) return true;
    for (help_words) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

// —— 对面四十·文档旗标逆向鬼词面（第 304 轮 D163）——
//
// 303 轮正向五针只拦「该在的不在」，文档自增/误改出新旗标（`--verbose`/`--zzcghost` 形）仍
// 无从捕——t2 探针两面添鬼词五通道零信号实锤。合法集 = `zzc_flags` 五枚 ∪ `--help` ∪ 外部工具
// 豁免四枚；豁免表为**独立手设**（现盘上四面全普查实测归类：zig 原生 `--check`/`--fuzz`/`--save`
// 与 code CLI `--install-extension`；禁自动抽取定集——新文档引新外部旗标须先审豁免表面，故意摩擦）。
// 册边界：单破折短旗（`-h`/`-p`/`-Doptimize`/`-ffuzz`）不入抽取器词法（规则只认 `--` 双破折头）——
// 假阳面宽于收益，挂面入候选；CHANGELOG/台账不挂（承 302 演漂引文形册边界）。

/// 外部工具旗标豁免全表（zig 官方与 VS Code CLI 真值，非 zzc 消费面）：逐枚带出处。
pub const doc_flag_exempt = [_][]const u8{
    "--check", // `zig fmt --check`（方案书/contributing 实见）
    "--fuzz", // `zig build --fuzz`（书稿测试章实见）
    "--save", // `zig fetch --save`（contributing 实见）
    "--install-extension", // `code` CLI 装扩展（README 实见）
    "--summary", // `zig build test --summary all`（AGENTS.md 门禁章实见，第 306 轮 D165）
};

/// 旗标全形合法集判据：`zzc_flags` 五枚 ∪ `--help` ∪ `doc_flag_exempt` 全表（逐轮添枚带出处）。
pub fn isDocFlagLegal(flag: []const u8) bool {
    if (isZzcFlag(flag)) return true;
    if (std.mem.eql(u8, flag, "--help")) return true; // help_words 唯 `--` 双破折头形参与本面
    for (doc_flag_exempt) |f| {
        if (std.mem.eql(u8, f, flag)) return true;
    }
    return false;
}

/// 从文本逐处抽「`--`＋以 ASCII 小写开头的 [a-z0-9-]* 段」的旗标全形（含尾 `-` 剔除；纯函数零 I/O，
/// 第 304 轮 D163）。空段/非小写头（`---` 分隔形/`-D` 短旗/中文破折）不入集只推进一位；
/// 处理后扫描起点推至段尾之后（确定性推进承 299 抽取器教训）。上限共用 `book_zzc_word_cap`。
pub fn collectDocFlagWords(text: []const u8) BookZzcWords {
    var out = BookZzcWords{};
    var pos: usize = 0;
    while (pos + 1 < text.len) {
        if (text[pos] != '-' or text[pos + 1] != '-') {
            pos += 1;
            continue;
        }
        // `--` 命中：段头须小写才成旗标词形。
        var end = pos + 2;
        while (end < text.len and ((text[end] >= 'a' and text[end] <= 'z') or (text[end] >= '0' and text[end] <= '9') or text[end] == '-')) : (end += 1) {}
        var seg_end = end;
        while (seg_end > pos + 2 and text[seg_end - 1] == '-') : (seg_end -= 1) {} // 剔尾破折
        const head_ok = end > pos + 2 and text[pos + 2] >= 'a' and text[pos + 2] <= 'z';
        if (head_ok and seg_end > pos + 2) {
            if (out.count < book_zzc_word_cap) {
                out.words[out.count] = text[pos..seg_end];
                out.count += 1;
            } else {
                out.overflow = true;
            }
        }
        pos = if (end > pos + 1) end else pos + 2; // 确定性推进：段尾优前；空段跨过双破折
    }
    return out;
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
/// `--lang-overlay <路径>`：把外部叠加层语言包累积并入所选基包之上（第三方库翻译发行包，本次新增）。
/// 承 R11 叠加语义：后写覆盖、overlay 无须自含 B6 契约（契约由基包供、合并后统一 validate）。
pub const flag_lang_overlay: []const u8 = "--lang-overlay";
/// `--machine`：把母语报错压成单行机读形制（与机读契约 hub 同源）。
pub const flag_machine: []const u8 = mcon.flag_machine;
/// `--as <注册名>`：`zzc lang add` 指定装入工程的注册名（此前全仓零测覆盖的孤点，D75 主靶）。
pub const flag_as: []const u8 = "--as";
/// `--to <目标包>`：`zzc relocalize` 的目标语言包（第 331 轮 D190）。与 `--lang` 分工明确：
/// `--lang` 始终是**源**包（读这堆 .zz 用的词表），`--to` 才是**产出**包——两枚同轴会让
/// 「读用哪本词表」随命令漂移，诊断与产出两头不清。
pub const flag_to: []const u8 = "--to";

/// zzc 层真实消费的旗标穷举表：find/strip 站与帮助行正向对账的单一真值。
pub const zzc_flags = [_][]const u8{ flag_lang, flag_lang_file, flag_lang_overlay, flag_machine, flag_as, flag_to };

/// name 是否为 zzc 层旗标（帮助行正向对账与判据的共同真值）。
pub fn isZzcFlag(name: []const u8) bool {
    for (zzc_flags) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

// —— 第 321 轮·自家旗标近似名（笔误）判据面（D180）——
//
// 活体真值：`--langx zh`／`--language zh`／`-lang zh`／`--lang-filex a.txt`／`--machin` 一律
// **静默吞**（RC=0、按默认包跑），用户与 AI 皆以为旗标生效——错包名有第 314 轮闸（退 2），错
// **旗标名**却零反馈。unit 层早已钉住 `findFlag` 匹配严格性（25/26/42/207 轮四枚测；本轮吞并探针
// 即被它们×双图拦红），缺的是真跑层的拦阻与话术。判据入 hub（纯函数零 I/O）、main 只做扫描与退出。
// 册边界：只与 zzc 自有旗标名比近似，余者照旧原样透传 zig——假阳面以 321 T0 的反形钉住。

/// zzc 自有旗标＋帮助旗标的合法全形集（近似判据的比对域；`help_words` 含 `--help`/`-h`/`-?`/`help`）。
pub const legal_flag_words = zzc_flags ++ help_words;

/// 合法旗标名清单话术（由 `zzc_flags` comptime 派生、顿号相连——改名/添枚即随话术走，不手抄）。
pub const flag_list_text = blk: {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    for (zzc_flags, 0..) |f, i| {
        if (i > 0) {
            const sep = "、";
            if (n + sep.len + f.len > buf.len) @compileError("flag_list_text 缓冲不足：扩旗标须随动 buf");
            @memcpy(buf[n..][0..sep.len], sep);
            n += sep.len;
        }
        if (n + f.len > buf.len) @compileError("flag_list_text 缓冲不足：扩旗标须随动 buf");
        @memcpy(buf[n..][0..f.len], f);
        n += f.len;
    }
    break :blk buf[0..n] ++ "";
};

/// 词核：旗标名笔误面（话术模板、face 针、烟测臂三处共用，单源闸）。
pub const np_flag_typo = "笔误";

/// 近似旗标话术：点名错形＋最近合法名＋合法全集（派生）＋透传逃生口（`--` 之后）。
pub const msg_flag_near: []const u8 = "旗标「{s}」疑似「{s}」" ++ np_flag_typo ++
    "。zzc 自有旗标只有：" ++ flag_list_text ++
    "；其余旗标原样透传 zig，确要透传请置于 -- 之后。";

/// 取值旗标缺值话术（第 325 轮 D184）：点名旗标＋用法形＋取值语义。旧形三条路皆误导——
/// 末尾缺值静默 RC=0、`--lang=` 报「未知语言包「」」、`--lang --machine` 把旗标吞成包名。
pub const msg_flag_missing_value: []const u8 = "旗标「{s}」缺少取值；用法：{s} <{s}>。";

/// 取值旗标重复话术（第 325 轮 D184）：旧形前者胜、后者静默丢弃（实测 RC=0 全绿）。
pub const msg_flag_repeat: []const u8 = "旗标「{s}」出现 {d} 次——重复即取值有歧义，请只保留一次。";

/// 旗标前置于子命令话术（第 325 轮 D184）：`zzc --lang zh check` 的子命令位被旗标占据，旧兜底
/// 报「未知或不完整的子命令」，把诊断引向「子命令错了」——实则位置错。
pub const msg_flag_before_cmd: []const u8 = "旗标「{s}」须写在子命令之后——子命令是第一个参数，如「check {s} …」。";

/// 近似名＋位置错（第 326 轮 D185）：`--langx zh check` 两个错叠在一起——名是笔误、位也在子命令前。
/// 旧形只报「未知或不完整的子命令」，两错都不点名。
pub const msg_flag_near_before_cmd: []const u8 = "旗标「{s}」疑似「{s}」" ++ np_flag_typo ++
    "，且须写在子命令之后——子命令是第一个参数，如「check {s} …」。";

/// `--` 占子命令位（第 326 轮 D185）：透传分隔符只能出现在子命令之后，旧形报「未知子命令」。
pub const msg_dashdash_first: []const u8 = "「--」之前缺少子命令——透传分隔符只能放在子命令之后，如「check -- …」。";

/// 旗标形参数占子命令位（第 326 轮 D185）：`--fuzz`／`-O`／`--check`／`-x` 等皆属 zig 侧旗标，
/// 旧形与错子命令名混为一句话术；此处点名「是旗标不是子命令」并给透传位置指引。
pub const msg_not_subcmd_flag: []const u8 = "「{s}」是旗标，不能当子命令——子命令是第一个参数（check／run／build／test 等）；" ++
    "zig 透传旗标写在子命令之后，需要时置于 -- 之后。";

/// 近似子命令建议（第 327 轮 D186）：旧形 `zzc chek` 只说「未知或不完整的子命令」，既不说哪个词
/// 错，也不说最可能是哪条——用户只能去翻用法。此处点名原词＋最近似＋全集（派生）。
pub const msg_subcmd_near: []const u8 = "未知子命令「{s}」——是否想用「{s}」？可用子命令：" ++ subcmd_list_text ++ "。";

/// 完全无近似（第 327 轮 D186）：仍点名原词并给全集，替代旧的「未知或不完整的子命令」泛称。
pub const msg_unknown_subcmd: []const u8 = "未知子命令「{s}」；可用子命令：" ++ subcmd_list_text ++ "。";

/// 去前导破折取旗标核（`--lang`/`-lang`/`lang` 同核；纯破折形得空核）。
fn flagCore(name: []const u8) []const u8 {
    var i: usize = 0;
    while (i < name.len and name[i] == '-') i += 1;
    return name[i..];
}

/// arg 是否为 zzc 自有旗标的近似名？是则返回那个合法旗标（供话术点名），否则 null。
/// 规则（纯函数零 I/O，第 321 轮 D180）：①非 `-` 头/`--` 分隔符/空核一律放过；②等号形先取 `=` 左侧
/// 再判；③与任一合法旗标全等 → 放过（先于近似，避 `--lang-file` 被 `--lang` 误吞）；④同核不同形
/// （破折数不符，如 `-lang`）、超集形（`langx` ⊃ `lang`）、截断形（`machin` ⊂ `machine`，且核长 ≥3
/// 以免 `-l`/`--m` 这类链接短旗误判）皆判近似。
pub fn nearZzcFlag(arg: []const u8) ?[]const u8 {
    if (arg.len < 2 or arg[0] != '-') return null;
    const head = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
    const form = arg[0..head];
    const core = flagCore(form);
    if (core.len == 0) return null;
    for (legal_flag_words) |m| {
        if (std.mem.eql(u8, form, m)) return null; // 合法全等：整枚 arg 早退
    }
    var best: ?[]const u8 = null;
    var best_gap: usize = std.math.maxInt(usize);
    for (legal_flag_words) |m| {
        const mc = flagCore(m);
        if (mc.len == 0) continue;
        // 三形皆算近似：同核不同形（破折数不符）／超集（多打尾缀）／截断（少打尾缀，核长 ≥3）。
        const hit = std.mem.eql(u8, core, mc) or
            std.mem.startsWith(u8, core, mc) or
            (core.len >= 3 and std.mem.startsWith(u8, mc, core));
        if (!hit) continue;
        // 取「长度差最小」的合法名做建议：`--lang-filex` 与 `--lang`(差4)/`--lang-file`(差0+?) 皆近似，
        // 应指更贴切的 `--lang-file`；`--lan` 则指最短的 `--lang`。同差取表内前者（zzc_flags 先于 help_words）。
        const gap = if (mc.len >= core.len) mc.len - core.len else core.len - mc.len;
        if (gap < best_gap) {
            best = m;
            best_gap = gap;
        }
    }
    return best;
}

// —— 对面三十九·文档旗标词面（第 303 轮 D162）——
//
// 三面命令样例手抄 `zzc_flags` 真值共 36 处（README 11／方案书 5／contributing 17），而从无
// 针入任何通道——t2 探针形B（README `--machine→--mchine` 全量 6 处＋`--lang-overlay→
// --lng-overlay` 3 处）fmt/build/test/matcher/demos-smoke 五通道零信号实锤；形A（hub 侧
// `--lang→--lng`）则由既有 usage 对账接住 9 红——两侧不对称：hub 漂会带动行为与文档分道，
// 而文档侧独漂（最常见的人改错字/手抄走样）方向零防御——本面补位。
// 「哪枚旗标出现在哪个文档面」为**独立手设子集**（禁从文档文本抽取定集——避自证循环承 297/301）；
// needle 全由 `zzc_flags` 真值 comptime 派生，改名即双向拦。册边界：`--lang` 针的 presence 语义
// 会被超集词形（`--lang-file`/`--lang-overlay`）污染——半漂混排同 298 册边界，全量漂必拦。

/// README 旗标面：五枚全在（机读旗标/选包/外部包/叠加层/注册名皆用户可见主面）。
pub const readme_flag_face = [_]zzc.BuildFace{
    .{ .needle = flag_machine, .why = "README 机读旗标须按 hub 真值演示——漂即读者敲未知旗标（第 303 轮 D162）" },
    .{ .needle = flag_lang, .why = "README 选包旗标——同上形制（超集污染形册边界见顶注）" },
    .{ .needle = flag_lang_file, .why = "README 外部语言包旗标——同上形制（第 303 轮 D162）" },
    .{ .needle = flag_lang_overlay, .why = "README 叠加层旗标——探针实锤独漂 `--lng-overlay` 五通道零信号之形（第 303 轮 D162）" },
    .{ .needle = flag_as, .why = "README lang add 注册名旗标——207 轮孤字面量收编的文档侧延伸（第 303 轮 D162）" },
    .{ .needle = flag_to, .why = "README relocalize 产出包旗标——与 `--lang` 源包分工是本章主要讲点（第 331 轮 D190）" },
};

/// 方案书旗标面：仅选包一枚（现盘上 --lang×5；两面未出现的旗标不入面免误报）。
pub const plan_flag_face = [_]zzc.BuildFace{
    .{ .needle = flag_lang, .why = "方案书选包叙述须按 hub 真值——同上形制（第 303 轮 D162）" },
};

/// contributing 指南旗标面：选包/外部包/叠加层三枚（语言包工作流全在此面）。
pub const contrib_flag_face = [_]zzc.BuildFace{
    .{ .needle = flag_lang, .why = "contributing 选包旗标——同上形制（第 303 轮 D162）" },
    .{ .needle = flag_lang_file, .why = "contributing 外部包旗标——同上形制（第 303 轮 D162）" },
    .{ .needle = flag_lang_overlay, .why = "contributing 叠加层旗标——第三方库翻译主流程旗标，漂即贡献者按指南产出发行包失败（第 303 轮 D162）" },
};

// —— 对面四十二·AGENTS.md（AI 编码操作手册）两面针（第 306 轮 D165）——
//
// AGENTS.md 是 AI 工具消费 zzc 的唯一入口面：命令词/旗标写错即 AI 照手册敲错命令而不自知
// （与 301–304 文档面同族，但读者是自动化工具——静默漂的代价是 AI 产出不可编译代码）。
// t2 探针（`zzc build→zzc bild`＋`--machine→--machinX`）五通道零信号实锤——文件本不存在于任何面。
// 子集独立手设（判据非从 AGENTS.md 抽取）：命令面取九子命令全集（手册主流程全演示），旗标面取
// zzc 五旗标全集（均实见）；正向 presence ＋命令/旗标两面逆向皆挂。

/// AGENTS.md 命令词面：九子命令全集针（needle 由 `sub_*` 真值 comptime 派生）。
pub const agents_cmd_face = [_]zzc.BuildFace{
    .{ .needle = zzc.prog_name ++ " " ++ sub_init, .why = "手册 scaffold 章须按 hub 真值演示 init（第 306 轮 D165）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_check, .why = "自检闭环主命令——漂即 AI 无从验纯" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_build, .why = "编译章真值针（探针实注漂形 bild 即此针靶）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_run, .why = "运行章真值针" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_test, .why = "测试章真值针（本机实测存在）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_eject, .why = "交付上游章真值针" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_relocalize, .why = "双语言共享章真值针（方言面出、方言面入）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_lsp, .why = "LSP 环境事实章真值针" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_lang, .why = "指定语言章真值针（lang/lang add 两形共用前缀）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_version, .why = "查包途径章真值针" },
};

/// AGENTS.md 旗标面：zzc 五旗标全集针（needle 直接 = 旗标真值）。
pub const agents_flag_face = [_]zzc.BuildFace{
    .{ .needle = flag_machine, .why = "机读闭环核心旗标——漂即 AI 逐行正则消费落空（探针实注形）" },
    .{ .needle = flag_lang, .why = "指定语言主旗标（超集形污染由反引号全形规避不了，presence 沿 303 册）" },
    .{ .needle = flag_lang_file, .why = "外部包直载旗标" },
    .{ .needle = flag_lang_overlay, .why = "叠加层旗标——第三方库母语化入口" },
    .{ .needle = flag_as, .why = "lang add 注册名旗标" },
    .{ .needle = flag_to, .why = "relocalize 产出包旗标——与 --lang 源包分工" },
};

// —— 对面四十三·纯母语行为面脚本话术对账（第 307 轮 D166）——
//
// AGENTS.md 铁律「混写英文关键词必拦并给改词候选」的行为面此前无真跑防线：探针实锤
// 拆去 main.zig 强制臂（`false and`）后 fmt/build/test/matcher/demos-smoke 五通道全绿，
// 而混写源的报错错位成后端假语法错——手册变虚假广告无人知。修法：demos-smoke 添第七臂
// 真跑验反形（混写必 RC≠0 且输出含改词话术）；脚本手抄的两枚话术词形在此与模板真值胶合。

/// 脚本断言须手抄的话术词形：皆须为 `msg_pure_native` 模板子串（307 T0 关系钉坐实，模板漂字即红）。
pub const pure_native_smoke_face = [_]zzc.BuildFace{
    .{ .needle = "纯母语", .why = "报错种类名前缀——脚本 grep 侧与模板同源，分道即文案改版漏随脚本（第 307 轮 D166）" },
    .{ .needle = "请改用", .why = "改词指引词——无此即 AI 无从自修，脚本必断此词" },
};

// —— 对面四十五·CLI 叠加轴行为面（第 309 轮 D168）——
//
// `--lang-overlay` 的消费链有 lsp-live hover 一臂（267 轮），但 **CLI 侧失败形无防线**：
// 探针实锤——拆去 applyOverlayPack 的 FileNotFound 报错臂（静默回退基包）后
// fmt/build/test/matcher/smoke/lsp-live 五通道全绿而缺包命令 RC 1→0 静默通过；坏包
// （语法错）同臂。另正形差分入档：overlay 生效时 eject 产物含包映射值形 `httpz.Server`，
// 无 overlay 同产落 mangle 形——两形互验锁住「叠加真并入译表」不只「命令不炸」。

/// 叠加包文件缺失报错模板（第 309 轮自 main.zig 迁入 hub，承 D101 文案单源形制）。
pub const msg_overlay_missing: []const u8 = "外部叠加语言包文件不存在：{s}";

/// 外部包行式语法错报错模板（同上迁入；main 侧 loadExternalPack/applyOverlayPack 共消费）。
pub const msg_pack_syntax_hint: []const u8 = "外部语言包「{s}」解析失败：行式语法错（未知段头/空键或值/同层键冲突/" ++ Pack.meta_format ++ " 非数等），请按 docs/contributing-lang-pack.md 检查。";

/// --lang 与 --lang-file 双源同指的互斥拒绝模板（第 310 轮 D169 迁 hub 单源，承 309 形制）：
/// 行为面由 demos-smoke 第十臂真跑；话术入面 needle 取「互斥」短形（脚本 grep 侧同形）。
pub const msg_lang_mutex: []const u8 = "--lang 与 --lang-file 互斥：内置选包、外部包文件二选一。";

/// 行为面断言话术（第 310 轮 D169）：--lang 内置选包轴三形——脚本十臂真跑断言，
/// needle 由本 hub 真值派生/选取；同文漂→310 T0 全等/子串钉红＋守卫对面红。
pub const lang_axis_face = [_]zzc.BuildFace{
    .{ .needle = np_unknown_pack, .why = "未知包报错种类名——派生自本 hub 真值零手抄（脚本 grep 侧同形）" },
    .{ .needle = "互斥", .why = "双源同指拒绝指引词——须为 msg_lang_mutex 模板子串，漂即测图红" },
    .{ .needle = "EXPECT_USAGE_RC=" ++ std.fmt.comptimePrint("{d}", .{usage_exit_code}), .why = "usage 退码数锚——由 usage_exit_code 派生，脚本字面随动；值漂即对面红" },
};

/// lang 二级动词点名面（第 329 轮 D188）：判据与词表另有 329 T0 钉；本表只核「main 真接了」——
/// 判据留着而分支被删时，`lang ad` 会退回「lang 只有 add 子命令」的泛称（不点名错词）。
pub const lang_verb_face = [_]zzc.BuildFace{
    .{ .needle = "cli.nearWord(verb, &cli.lang_verbs)", .why = "二级动词近似判据接线（第 329 轮 D188）" },
    .{ .needle = "cli.lang_verb_add", .why = "分派臂吃同一真值（第 329 轮 D188）——手抄字面量即在此红" },
    .{ .needle = "cli.msg_lang_verb_near", .why = "近似动词话术使用点——零使用即退回泛称" },
};

/// lang remove 面（第 330 轮 D189）：动词分派臂＋三类回执（回执/未装/内置）各有使用点——
/// 任一枚脱离 main 即成死话术（用户永远看不到那句话），故逐枚钉。
pub const lang_remove_face = [_]zzc.BuildFace{
    .{ .needle = "cli.lang_verb_remove", .why = "remove 分派臂吃同一真值（第 330 轮 D189）" },
    .{ .needle = "cli.msg_lang_remove_ok", .why = "卸载回执使用点——零使用即装得卸不掉" },
    .{ .needle = "cli.msg_lang_remove_absent", .why = "未装拒绝使用点——静默成功比报错更糟" },
    .{ .needle = "cli.msg_lang_remove_builtin", .why = "内置不可删使用点——否则误报「未安装」" },
    .{ .needle = "cli.msg_lang_remove_overlay", .why = "叠加层不可单独卸使用点——否则报「注册名不可用」" },
};

/// 叠加层点名面（第 328 轮 D187）：判据（`registry.overlayHint`）与名族真值另有 328 T0 钉；本表只
/// 核「main 真接了」——判据留着而分支被删时，`--lang 繁體` 会退回「未知语言包」的错路（让人另装/另选）。
pub const overlay_name_face = [_]zzc.BuildFace{
    .{ .needle = "registry.overlayHint(n)", .why = "叠加层判据接线（第 328 轮 D187）——零调用即退回未知包话术" },
    .{ .needle = "cli.msg_pack_is_overlay", .why = "叠加层点名话术使用点——同上" },
};
/// 旗标形制闸接线面（第 325 轮 D184）：缺值／重复／前置三闸的**真跑接线**与三条话术使用点。
/// hub 判据（`scanFlag`／`countFlag`／`ownFlagName`）另由 325 T0 钉值；本表只核「main 真接了」——
/// 判据留着而闸被搬走/删掉时，话术在对面 main.zig 里消失即红（判据存在≠闸生效）。
pub const flag_arity_face = [_]zzc.BuildFace{
    .{ .needle = "cli.scanFlag(args, taker.flag)", .why = "缺值闸接线：三态扫描逐取值旗标跑" },
    .{ .needle = "cli.msg_flag_missing_value", .why = "缺值话术使用点——零使用则闸失效而静默" },
    .{ .needle = "cli.msg_flag_repeat", .why = "重复话术使用点——同上" },
    .{ .needle = "cli.msg_flag_before_cmd", .why = "自有旗标前置话术使用点——同上" },
    .{ .needle = "cli.classifyCmdSlot(cmd)", .why = "子命令位四分类分派接线（第 326 轮 D185）" },
    .{ .needle = "cli.msg_flag_near_before_cmd", .why = "近似名＋位置双错话术使用点——零使用即静默" },
    .{ .needle = "cli.msg_dashdash_first", .why = "「--」占子命令位话术使用点——同上" },
    .{ .needle = "cli.msg_not_subcmd_flag", .why = "旗标形参数占子命令位话术使用点——同上" },
};

/// 未知子命令点名面（第 327 轮 D186）：判据（`nearSubcmd`／既有 `subcommands` 表）另有 327 T0 订值；本表只核
/// 「main 真接了」——判据留着而建议分支被删/被短路时，话术在对面 main.zig 里消失即红。
pub const subcmd_face = [_]zzc.BuildFace{
    .{ .needle = "cli.nearSubcmd(cmd)", .why = "近似子命令建议接线——判据在而调用被删即静默" },
    .{ .needle = "cli.msg_subcmd_near", .why = "近似建议话术使用点——零使用则退回泛称" },
    .{ .needle = "cli.msg_unknown_subcmd", .why = "未知子命令点名话术使用点——同上" },
};

/// 第九臂手抄话术两枚与 hub 模板胶合（须为上述模板子串，T0 关系钉）；另脚本源侧/期望侧
/// 两枚映射词形由 `overlay_pack_face` 对叠加包活线胶合（守卫对面四十五读包文本，第 24 片新读）。
pub const overlay_smoke_face = [_]zzc.BuildFace{
    .{ .needle = "叠加语言包文件不存在", .why = "缺包话术——脚本 grep 侧与模板同源（第 309 轮 D168）" },
    .{ .needle = "解析失败", .why = "坏包话术——同上" },
    .{ .needle = "过新", .why = "版本闸话术——须为 msg_fmt_too_new 模板子串，漂即测图红（第 311 轮 D170）" },
    .{ .needle = np_upgrade, .why = "升级指引词——派生自本 hub 真值零手抄（脚本 grep 侧同形，第 311 轮 D170）" },
    .{ .needle = "选包轴", .why = "第十二臂标识词——脚本 ok/FAIL 回声侧与注释侧双在，锁住两臂分轴不互替（第 312 轮 D171）" },
};

/// 包 `$format` 高于支持值的专错模板（第 311 轮 D170 自 main.fmt_too_new_hint 全形迁 hub，
/// 承 309 形制）：版本闸与语法错两话术分流——过新必指升级，塌成「解析失败」即误导 AI 修没坏的包。
pub const msg_fmt_too_new: []const u8 = "外部语言包「{s}」声明的 " ++ Pack.meta_format ++ " 过新（当前 " ++ zzc.prog_name ++ " 仅支持格式 {d}）。" ++ np_upgrade ++ " " ++ zzc.prog_name ++ "。";

/// `zzc lang <未知动词>` 拒绝模板（第 313 轮 D172 迁 hub 单源，承 311 形制）：
/// 含 np_subcmd/np_reg_packs 两处派生＋未知动词占位；行为面由第十三臂真跑。
/// `lang <动词>` 的用法段（第 329 轮 D188 从拒绝模板抽出）：兜底与近似建议两话术共用同一串——
/// 否则「zzc lang add …」在 hub 里各抄一份，改一处即分道。
pub const lang_verbs_usage: []const u8 = "`zzc lang add <文件> [--as 注册名]`／`zzc lang remove <注册名>`（不带参数则列当前包与" ++ np_reg_packs ++ "）";

pub const msg_lang_bad_verb: []const u8 = "lang 只有 " ++ lang_verb_list_text ++ " " ++ np_subcmd ++ "：" ++ lang_verbs_usage ++ "；「{s}」不是有效" ++ np_subcmd ++ "。";

/// lang 的动词全集（第 329 轮 D188）：目前只有 add。`lang ad`／`addd`／`lst` 原只回「lang 只有 add
/// 子命令：…」——点名了合法词却不说「你打的哪个词错、最可能想打哪条」。
/// 唯一动词的真值常量（第 329 轮 D188）：main 的分派臂改吃它——否则「add」在词表与分派臂
/// 两处手抄，改一处即「建议一个不存在的动词」或「真动词不进词表」。
pub const lang_verb_add: []const u8 = "add";

pub const lang_verb_remove: []const u8 = "remove"; // 第 330 轮 D189：卸载动词（与 add 同族）

pub const lang_verbs = [_][]const u8{ lang_verb_add, lang_verb_remove };

/// 动词清单文本（第 330 轮 D189）：由 `lang_verbs` comptime 派生。扩表时兜底话术里的「只有 add
/// 子命令」会变成假话——派生后加动词只改表，两张话术自动随动。
pub const lang_verb_list_text: []const u8 = blk: {
    var out: []const u8 = "";
    for (lang_verbs, 0..) |v, i| {
        if (i != 0) out = out ++ "／";
        out = out ++ v;
    }
    break :blk out;
};

/// 近似动词建议（第 329 轮 D188）：与兜底共用 `lang_add_usage`；`lang ad` → 「是否想用「add」？」。
pub const msg_lang_verb_near: []const u8 = "lang " ++ np_subcmd ++ "「{s}」不存在——是否想用「{s}」？" ++ lang_verbs_usage ++ "。";

/// `lang remove` 缺参（第 330 轮 D189）：卸载需要点名哪个包——与 add 缺文件同形制。
pub const msg_lang_remove_usage: []const u8 = "lang remove 需要注册名：`zzc lang remove <注册名>`（`zzc lang` 列当前包与已装包）。";

/// 卸载回执（第 330 轮 D189）：与 add 的落位回执对称展示「目录/名 ++ 扩展名」，扩展名取
/// `zzc.pack_ext` 单源——手抄 `.txt` 会在扩展名改动时指错文件名。
pub const msg_lang_remove_ok: []const u8 = "✔ 已移除语言包「{s}」（{s}/{s}" ++ zzc.pack_ext ++ "）。";

/// 没装却要删（第 330 轮 D189）：与 add 的撞名拒绝对称——不许静默成功，也不能吐 fs 生话。
pub const msg_lang_remove_absent: []const u8 = "未安装语言包「{s}」；`zzc lang` 可列当前包与已装包。";

/// 卸叠加层（第 330 轮 D189）：`繁体`/`繁體` 是基包 zh 的内置叠加层名，不在用户目录里、也不该
/// 被当成「注册名打错了」——与 D187 的 `--lang 繁體` 同源，判据复用 `registry.overlayHint`。
pub const msg_lang_remove_overlay: []const u8 = "「{s}」是基包「{s}」的内置叠加层「{s}」——随基包提供，不能单独移除。";

/// 卸内置包（第 330 轮 D189）：内置包不在用户目录里，若不先判会误报「未安装」，把人引向
/// 「是不是没装上」的错路——它永远删不掉，得直接说清。
pub const msg_lang_remove_builtin: []const u8 = "「{s}」是内置包（注册名 {s}），不能移除；只有 `zzc lang add` 装上的用户包可移除。";

/// `lang add` 非法注册名拒绝全形（第 316 轮 D175：由 main 内联迁入本 hub 单一真值，承
/// 311/313 形制——迁移无损以新旧 stderr **字节全等**坐实）。三处原手抄全部派生：`--as` 取
/// `flag_as`、`$name` 取 `Pack.meta_name`、上限数取 `userpack.max_key_len`（comptime 印数，
/// 改白名单长度即话术随动，禁得住 main 侧手数与真值分道）。占位仅余 `{s}`（用户传入名）。
/// 坏包族话术词核（第 317 轮 D176）：「不完整」三字散在 main 五址内联手抄（add 硬门/
/// --lang-file/已装被改坏/裸包兜底四形＋文件不存在形各持一份），漂一字即四处指引分道——
/// 立词核单源，四模板各自派生，行为面由第十七臂真跑胶合（对面四十九）。
pub const np_incomplete = "不完整";

/// 外部包文件读不到（loadExternalPack 一址两消费：基包轴与 `--lang-file` 轴同话术）。
pub const msg_ext_missing: []const u8 = "外部" ++ np_pack_word ++ "文件不存在：{s}";
/// B6 契约硬门拒绝全形（装前即拒——装进来只会在流程深处报缺，属定时炸弹形）。
pub const msg_pack_incomplete: []const u8 = "外部" ++ np_pack_word ++ "「{s}」" ++ np_incomplete ++ "：{s}";
/// 已装包运行期被改坏（userpack 落盘后再选用的第二道门，与上者同词核异形）。
/// 「装后又被改坏了？」疑问提示词（第 318 轮 D177）：已装包形独有的第二道门标记——
/// 外部/裸两形不带此词（三形分工不重叠），故立单源供 hub 模板与第十八臂话术针胶合。
pub const np_corrupt_hint = "装后又被改坏了？";

pub const msg_installed_pack_incomplete: []const u8 = "已装" ++ np_pack_word ++ "「{s}」" ++ np_incomplete ++ "（" ++ np_corrupt_hint ++ "）：{s}";
/// 无路径可点名时的兜底形（内置包恒过契约，此形正常不可达——保留同词核派生防分道）。
pub const msg_bare_pack_incomplete: []const u8 = np_pack_word ++ np_incomplete ++ "：{s}";

/// 「遮蔽」词核（第 319 轮 D178）：注册名撞内置表键/别名 → 选用侧永远命不中已装包。
/// 面针与脚本 grep 同形胶合，漂字即双通道红。
pub const np_shadow = "遮蔽";

/// 内置同名遮蔽拒绝模板：装上后 `--lang` 仍走内置（表先查），文件成幽灵态、回执承诺成假——
/// 故装前即拒（承 316 坏名/317 坏包的「失能态装前拦」同策略）。
pub const msg_reg_key_shadow: []const u8 = "注册名「{s}」与内置" ++ np_pack_word ++ "同名，选用时会被内置表" ++ np_shadow ++ "（永远选不中，落盘只成幽灵文件）。可 " ++ flag_as ++ " 另起；若本意是用内置包，直接 " ++ flag_lang ++ " 选它即可。";

pub const msg_reg_key_bad: []const u8 = np_reg_key_open ++ "{s}」不可用——须为 ASCII 字母/数字/-/_，不以 . 或 - 开头，至多 " ++ std.fmt.comptimePrint("{d}", .{userpack.max_key_len}) ++ " 字（注册名会直接成为文件名与命令行选择名）。可 " ++ flag_as ++ " 另起；展示名仍用包内 " ++ Pack.meta_name ++ "，不受此限。";

/// 行为面断言话术（第 313 轮 D172）：`zzc lang` 列播轴三形——脚本十三臂真跑，
/// 前三枚全/半派生零手抄，尾枚列播内容针独立手设（registry 改名/掏空即红）。
pub const lang_list_face = [_]zzc.BuildFace{
    .{ .needle = np_cur_pack, .why = "详情头——派生自本 hub 真值（脚本 grep 侧同形）" },
    .{ .needle = np_reg_packs, .why = "可注册段头——同上派生（列播两行头缺一即选包用户无从所指）" },
    .{ .needle = "不是有效", .why = "未知动词拒绝词——须为 msg_lang_bad_verb 模板子串，漂即测图红" },
    .{ .needle = "zh(", .why = "列播内容针——内置注册表唯一 entry 键形，独立手设（掏空体/改名即空列表红；313 T0 对 registry 真值交叉）" },
    .{ .needle = "收录列播", .occ = 3, .why = "第十五臂标识词——已装用户包收录形独立指认；三址（臂首注释／注释内引述／[ok] echo）逐址删一即红，旧形 occ 缺省只核存在性（第 322 轮 D181 收紧）" },
};

/// 行为面断言话术（第 314 轮 D173）：`zzc lang add` 注册链四形闭环——脚本第十四臂真跑。
/// 既有防线仅 237 T2 静态源形计数（摘整臂 pack_ext 2→1 接住），退码/回执内容/新键可用
/// 皆零通道；前三枚全派生零手抄，尾枚 fixture $code 独立手设（314 T0 对包文交叉）。
pub const lang_add_face = [_]zzc.BuildFace{
    .{ .needle = np_installed, .why = "成功回执词——派生自本 hub（静默安装/漂字即捕；237 静态针只数委派形不验真输出）" },
    .{ .needle = np_dup_installed, .why = "防覆盖拒绝词——同上派生（DUP 臂话术/退码真跑侧首次入线）" },
    .{ .needle = zzc.lang_dir ++ "/", .why = "落位目录针——由 hub lang_dir 派生（回执指路目录与真实落盘同源的脚本侧投影）" },
    .{ .needle = flag_as, .why = "另起注册名旗——本 hub flag 真值（--as 形键名行为面由十四臂 D 步真跑）" },
    .{ .needle = "tst-ja", .why = "缺省注册名内容针——fixture 包 $code，独立手设（314 T0 对包文交叉：缺省键与 $code 同源形）" },
    .{ .needle = "不可用", .why = "坏名拒绝短形——须为 msg_reg_key_bad 模板子串（hub 漂字即测图红；第 316 轮 D175）" },
    .{ .needle = "越界零写盘", .occ = 4, .why = "第十六臂标识词——坏名拦截＋零写盘形独立指认；四址（注释／[FAIL] 两形解释／[ok] echo）逐址删一即红（第 322 轮 D181 收紧）" },
    .{ .needle = np_incomplete, .why = "坏包词核——派生自本 hub（三模板共有子串，脚本十七臂话术针随动；第 317 轮 D176）" },
    .{ .needle = "EXPECT_FAIL_RC=" ++ std.fmt.comptimePrint("{d}", .{failure_exit_code}), .why = "失败退码数锚——由 failure_exit_code 派生，脚本字面随动；值漂即对面红（第 317 轮 D176）" },
    .{ .needle = "坏包族零落盘", .occ = 4, .why = "第十七臂标识词——坏包四形拒装且不落盘独立指认；四址（注释／[FAIL]／[ok] echo 等）逐址删一即红（第 322 轮 D181 收紧）" },
    .{ .needle = np_corrupt_hint, .why = "已装包第二道门疑问提示词——派生自本 hub（脚本十八臂话术针随动；第 318 轮 D177）" },
    .{ .needle = "已装坏包点名路径", .occ = 3, .why = "第十八臂标识词——三步链退码/点名/疑形独立指认；三址（注释／[FAIL]／[ok] echo）逐址删一即红（第 322 轮 D181 收紧）" },
    .{ .needle = np_shadow, .why = "同名遮蔽词核——派生自本 hub（脚本十九臂话术针随动；第 319 轮 D178）" },
    .{ .needle = "同名遮蔽真相", .occ = 2, .why = "第十九臂标识词——装前拒＋内置优先序独立指认；两址（臂首注释／[ok] echo）缺一即红（第 322 轮 D181 收紧）" },
    .{ .needle = np_flag_typo, .occ = 2, .why = "旗标名笔误词核——派生自本 hub；两址（二十臂话术判据 grep 址／FAIL 文案址）皆须在：判据在而文案漂、或文案在而判据漂，皆说明臂与 hub 分道（第 321 轮 D180，措辞第 322 轮 D181 对齐「址」字公约）" },
    .{ .needle = "旗标笔误装前即拒", .occ = 3, .why = "第二十臂标识词——typo 三形退码＋最近名点名＋透传区反断独立指认，注释／[FAIL]／[ok] 三址各计一枚（旧形 occ 缺省 1，改一处即漂看不住；第 321 轮 D180 演漂形⑤ 所逼）" },
};

/// 第九臂正形源侧/期望侧词形对叠加包文本胶合：两枚须为包映射活线（键侧/值侧），
/// 逐枚 presence 对包文；全线形键值配对由 309 T0 独立手设对拍（包漂字而面/脚本漏随即红）。
pub const overlay_pack_face = [_]zzc.BuildFace{
    .{ .needle = "网络服务.服务器", .why = "正形源侧方言全形——须为叠加包映射活线键侧（第 309 轮 D168）" },
    .{ .needle = "httpz.Server", .why = "产物期望形——须为同映射线值侧——分道即包改版漏随脚本" },
};

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
    \\  zzc relocalize --to <包> [目录]
    \\                         把本工程重生为另一语言包词形的孪生工程（默认 relocalized/<包>/；源树不改）
    \\  zzc lsp                启动 LSP 服务器（JSON-RPC over stdio：悬停/快路诊断/文档同步；stdout 专供协议帧）
    \\  zzc lang               列出当前语言包与可注册包
    \\  zzc lang add <文件>   装入外部语言包到本工程（--as 注册名 可选；免重编译）
    \\  zzc version            版本与当前语言包
    \\选项：
    \\  --lang <名>            选择语言包（如 zh / 中文；缺省为中文；该旗标不透传 zig）
    \\  --lang-file <路径>     从外部文件加载语言包（第三方发行包、免重编译；与 --lang 互斥；不透传 zig）
    \\  --lang-overlay <路径>  把外部叠加层语言包累积并入所选基包之上（第三方库翻译包；可与 --lang/--lang-file 合用；不透传 zig）
    \\  --machine              把母语报错压成单行机读形制 `路径:行:列: 种类: 消息（提示：…）`（编辑器/CI 逐行正则消费；不透传 zig）
    \\  --to <包>              relocalize 的目标语言包（`--lang` 选源包、`--to` 选产出包；仅 relocalize 消费）
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

test "第 257 轮 T0 buildInitTemplate 多段回退链 print_callee 临时串逐项释放：直喂裸 testing.allocator 坐实 std→std.debug 回退串无泄（D124·D23/D60/D121/D122/D123 同族）" {
    // 造一枚含 `= std` 与 `= std.debug` 两段、却无 `= std.debug.print` 叶的合法包：命中 buildInitTemplate
    // L413 的多段回退 allocPrint 支（`库.库调` 由 opt_std/opt_std_dbg 两段拼出）——旧形该临时串拷入 out
    // 字节缓冲后即被覆盖，从不 free。以裸 testing.allocator（非 arena）直喂 gpa 破生产侧 arena 掩盖。
    var lang_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer lang_arena.deinit();
    const pack_src =
        "$format = 1\n" ++
        "$code = d124\n$name = 回退语\n[keywords]\n" ++
        "定 = const\n变 = var\n函 = fn\n若 = if\n否 = else\n" ++
        "返 = return\n构 = struct\n枚 = enum\n结 = union\n选 = switch\n" ++
        "取 = @import\n嵌 = @embedFile\n主 = main\n" ++
        "库 = std\n库调 = std.debug\n";
    var lang = try Pack.parse(lang_arena.allocator(), pack_src);
    defer lang.deinit();
    const raw = std.testing.allocator; // 裸 leak-checking 分配器（非 arena）：旧形内泄的 print_callee 于作用域退出即报 leaked
    const tmpl = try buildInitTemplate(raw, lang);
    defer raw.free(tmpl);
    // 确证确走回退支：print_callee 系两段拼出的 `库.库调`（既非叶形 `标准库.调试.打印`、亦非 ASCII 兜底）。
    try std.testing.expect(std.mem.indexOf(u8, tmpl, "库.库调(") != null);
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
/// 深检臂「只查不发」旗标（D129）：check 只需语义分析，产物零发射零残留。
pub const tl_no_emit_bin: []const u8 = "-fno-emit-bin";

/// `cmdBuild` 非 test 臂的产物发射旗标模板：与 `zzc_paths.emit_bin_prefix` 同源派生，
/// 不另立第二枚 `-femit-bin=` 手抄（旧形制 allocPrint 模板内另持整串前缀）。
pub const tl_emit_bin_fmt: []const u8 = zzc.emit_bin_prefix ++ "{s}";

/// 对面十六（src/main.zig 委派形清单）：守卫读 main.zig 文本逐字节对账，防字面量回退——
/// 消费侧若改回手抄字面量，委派形 needle 即消失、守卫红；`occ` 由 224 T0 在测试图内
/// 以 @embedFile 直接钉死（同一 needle 形可能多处同形，如 `zig build` 两臂）。
pub const tl_face = [_]zzc.BuildFace{
    .{ .needle = "&.{ cli.tl_zig, cli.tl_build_exe, u.gen_rel, cli.tl_no_emit_bin }", .occ = 1, .why = "check 深检臂：含 main 的根走 build-exe 传递性语义深检且 -fno-emit-bin 零残留，漂即 check 入口断裂" },
    .{ .needle = "&.{ cli.tl_zig, cli.tl_ast_check, u.gen_rel }", .occ = 1, .why = "check 浅检臂：不含 main 的模块只 ast-check，漂即库模块检查断裂" },
    .{ .needle = "try argv.append(gpa_, cli.tl_zig);", .occ = 1, .why = "cmdBuild spawn 首词：run/build/test 三入口共用，漂即三入口全断" },
    .{ .needle = "if (mode == .test_) cli.tl_test else cli.tl_build_exe", .occ = 1, .why = "cmdBuild 模式分支词：test 与 build-exe 两臂同源，漂即对应入口断" },
    .{ .needle = "cli.tl_emit_bin_fmt, .{bin_full}", .occ = 1, .why = "cmdBuild 发射旗标模板：前缀由 zzc_paths 派生，漂即产物落点失控" },
    .{ .needle = "&.{ cli.tl_zig, cli.tl_build }", .occ = 2, .why = "eject 探纹/验建两址：毕业工程 fingerprint 探测与独立构建验证，漂即 eject 断裂" },
    .{ .needle = "&.{ cli.tl_zig, cli.tl_version }", .occ = 1, .why = "版本漂警臂：升代早警面，漂即静默失效（不回译告警永不发）" },
};

test "224 T0：工具链 spawn argv 词族单一真值＋委派形双向钉（第 224 轮）——D92" {
    // A1：七枚词值钉＋发射旗标模板与 zzc_paths 前缀同源钉（hub 本体漂移即红）。
    try std.testing.expectEqualStrings("zig", tl_zig);
    try std.testing.expectEqualStrings("build-exe", tl_build_exe);
    try std.testing.expectEqualStrings("ast-check", tl_ast_check);
    try std.testing.expectEqualStrings("test", tl_test);
    try std.testing.expectEqualStrings("build", tl_build);
    try std.testing.expectEqualStrings("version", tl_version);
    try std.testing.expectEqualStrings("-fno-emit-bin", tl_no_emit_bin);
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
        try std.testing.expectEqual(c.occ, n);
    }
}

// ---------------------------------------------------------------------------
// CLI 退码契约单一真值（第 236 轮 · D104）
//
// 用法错（未知子命令/旗标、非法注册名、互斥参数等）退 `usage_exit_code`、一般
// 编译/运行失败退 `failure_exit_code`（POSIX 惯例：usage=2、fail=1）。此二枚值此前
// 全仓无共同真值：`src/main.zig` 七处直接 `std.process.exit(2)` 臂与 `bail` 的
// `if (e == error.Usage) 2 else 1` 各自手抄字面量；外部消费者 `tools/check-demos.ps1`
// 又以 PowerShell 字面量 `ExitCode -ne 2` 断言同一契约（≥7 处）。`process.exit` 在
// `zig build test` 门内不可观测（noreturn、测试进程无法捕获）、ps1 非测试图 source dep
// 且本机 NO_PWSH——t2 探针坐实：漂 bail 规范 `2`→`3`、漂单点裸 `exit(2)`→`exit(3)`，
// fresh 609/609 皆全绿静默。修法：本对二枚常量为单一真值，main.zig 八点位全委派；
// `exit_code_face` 交守卫对面（读 main.zig 验委派形＋236 T0 @embedFile 反锚裸字面 0 处）、
// `exit_code_ps1_face` 交守卫对面（读 ps1 验 `-ne 2` 断言与 usage_exit_code comptime 同源）。
// ---------------------------------------------------------------------------

/// 用法错退出码（未知子命令/旗标、非法名、互斥参数等，与 error.Usage 同码）。
pub const usage_exit_code: u8 = 2;
/// 一般失败退出码（编译/运行/IO 等非用法类失败，与 error.Usage 相异码）。
pub const failure_exit_code: u8 = 1;

/// 数 needle 在 hay 中的非重叠出现次数（236 T0 反锚/频次钉共用）。
fn countOccurrences(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, hay[i..], needle)) |k| {
        i += k + needle.len;
        n += 1;
    }
    return n;
}

/// 对面（src/main.zig 退码委派形清单·第 236 轮 D104）：守卫读 main.zig 文本逐字节对账，
/// 消费侧若改回手抄字面量、委派形 needle 即消失、守卫红；`occ` 由 236 T0 以 @embedFile 钉死（第 324 轮 D183 收编 `.count`→`occ`，与七族同形、matcher 侧不再回落核 1 枚）。
pub const exit_code_face = [_]zzc.BuildFace{
    .{ .needle = "std.process.exit(cli.usage_exit_code);", .occ = 24, .why = "main.zig 二十四址 usage 直接退出臂皆委派单源，漂即某路 usage 退码分道（外部脚本 misjudge；第 319 轮 D178 撞名拦截臂 +1、第 321 轮 D180 近似旗标拦截臂 +1、第 330 轮 D189 lang remove 五臂 +5、第 331 轮 D190 relocalize 缺 `--to` 与 `--to` 串台两臂 +2）" },
    .{ .needle = "if (e == error.Usage) cli.usage_exit_code else cli.failure_exit_code", .occ = 1, .why = "bail 规范映射臂：error.Usage→usage 码、余→fail 码同源，漂即经 bail 的退码分道" },
};

/// 对面（tools/check-demos.ps1 退码断言 needle·第 236 轮 D104）：由 usage_exit_code comptime
/// 派生——改常量 needle 随动、ps1 旧字面 `-ne 2` 即失配红；承 D94 ps1_face presence 形制。
pub const exit_code_ps1_face = [_]Ps1Needle{
    .{ .needle = "ExitCode -ne " ++ std.fmt.comptimePrint("{d}", .{usage_exit_code}), .why = "ps1 usage 错退码断言与 usage_exit_code 同源——漂即外部基线守卫对退码契约失保（第 236 轮 D104）" },
};

test "236 T0：CLI 退码契约单一真值＋main 委派反锚＋ps1 消费对拍（第 236 轮）——D104" {
    // A1 值钉（独立字面量，防 hub 本体漂移）：POSIX usage=2、fail=1。
    try std.testing.expectEqual(@as(u8, 2), usage_exit_code);
    try std.testing.expectEqual(@as(u8, 1), failure_exit_code);
    // A2 反锚：@embedFile 直读 main.zig，裸 exit(2)/exit(1) 字面量必 0 处（全委派单源）。
    const main_src = @embedFile("../main.zig");
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(main_src, "std.process.exit(2);"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(main_src, "std.process.exit(1);"));
    // A3 委派形频次钉：七处 usage 臂 + bail 映射各恰其数（消费侧回退手抄即此红）。
    inline for (exit_code_face) |c| {
        try std.testing.expectEqual(c.occ, countOccurrences(main_src, c.needle));
    }
    // A4 ps1 消费 needle 独立手抄对拍：派生形须逐字节等于旧 ps1 断言字面 `ExitCode -ne 2`。
    try std.testing.expectEqual(@as(usize, 1), exit_code_ps1_face.len);
    try std.testing.expectEqualStrings("ExitCode -ne 2", exit_code_ps1_face[0].needle);
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
    // 第 241 轮 D109：词边界字节集取单一真值（与 lsp/server 链式词字节、transpiler/lexer 非 ASCII 续读同源）。
    return zzc.isWordByte(c);
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
/// 一次 ps1 对面核对项。`occ`：应现枚数（缺省 1＝presence）。第 323 轮 D182 补齐——旧形缺此字段，
/// 守卫靠 `@hasField` 静默回落，与 `BuildFace` 等六族不一致（本族即第七族，统一直至名实闸全覆盖）。
pub const Ps1Needle = struct { needle: []const u8, why: []const u8, occ: usize = 1 };

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

/// 叠加层被当成基包（第 328 轮 D187）：`--lang 繁體`／`--lang 繁体` 原报「未知语言包」，而繁体字形
/// 叠加层**默认已叠进 zh**——旧话术让人以为要另装或另选，实际什么都不用做。名字族来自叠加层自己的
/// `# @display`／`# @aliases`（经生成器 → registry.overlayHint），此处零手抄。
pub const msg_pack_is_overlay: []const u8 = "「{s}」不是独立语言包，而是基包「{s}」的内置叠加层「{s}」——默认已叠加，无需选择；" ++
    "直接 `--lang {s}`（或不写 `--lang`）即可。";
pub const np_lexical = "词法"; // 词法诊断 kind 前缀（main 机读出口 + server 诊断体）
pub const np_type = "类型"; // zig 报错回译短语段（diag/translate 回译表）

/// `zzc version` 出口行形串（第 296 轮 D155·对面三十二样例行臂）：main 出口与 README 样例对拍
/// 共用的唯一形制。旧形制 main 内联拼装（`prog_name ++ " {s}（" ++ np_pack_word ++ "：{s}）`）而
/// README 手抄成品行「zzc 0.1.0（语言包：中文）」互不引用——t2 探针 P4 实锤独漂 README 样例行
/// 三门禁零信号，真跑 `zzc version` 与文档样例实地分道。两枚 {s} 顺位：产品版本／语言包显示名。
pub const version_line_fmt: []const u8 = zzc.prog_name ++ " {s}（" ++ np_pack_word ++ "：{s}）";

/// 对面三十二·main 侧委派形清单（第 296 轮 D155）：守卫读 main.zig 文本逐字节对账，消费侧若改回
/// 内联拼装（委派形消失）即红；频次全等钉与旧形反锚另由 296 T0 以 @embedFile 在测试图守
/// （承 224/236 轮「守卫面＋测图面双向互备」形制）。
pub const version_main_face = [_]zzc.BuildFace{
    .{ .needle = "printOut(cli.version_line_fmt", .occ = 1, .why = "version 出口行须委派 hub 形串——改回内联拼装则 README 对拍与真机出口形制分道（第 296 轮 D155）" },
};

/// 对面三十四·README 命令词面（第 298 轮 D157）：快跑道 29 处命令样例手抄八枚 `sub_*` 真值，
/// 此前零针——needle 全由 `prog_name ++ " " ++ sub_*` comptime 派生（presence ≥1 枚形制）：
/// hub 改名而 README 仍旧词→派生 needle 落空红；README 独改样例→旧词仍在盘而 needle 已换新——
/// 两向分道皆拦。`sub_test` 不在 README（走 `zig build test`），不入面；同一词多处出现只需
/// 一枚命中（改名类缺陷只要盘上一枚新形皆无即红，无需锁份数）。
pub const readme_cmd_face = [_]zzc.BuildFace{
    .{ .needle = zzc.prog_name ++ " " ++ sub_init, .why = "README 快跑/教程须按 hub 真值展示 init 命令——改名即用户照抄报未知子命令（第 298 轮 D157）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_check, .why = "README 深检指引的 check 词须与 hub 同源（D71 机读契约入口也拖于此词，第 298 轮 D157）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_build, .why = "README 构建样例的 build 词——同上形制（第 298 轮 D157）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_run, .why = "README 运行样例的 run 词——同上形制（第 298 轮 D157）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_eject, .why = "README 毕业章节的 eject 词——探针实锤独漂 `zzc emit` 三门禁零信号之形（第 298 轮 D157）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_relocalize, .why = "README 共享面章节的 relocalize 词——两向道主命令，漂即读者照敲未知子命令（第 331 轮 D190）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_lang, .why = "README 语言包章节的 lang 词——同上形制（第 298 轮 D157）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_lsp, .why = "README 编辑器接入的 lsp 词——同上形制（第 298 轮 D157）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_version, .why = "README 认代入口的 version 词——对面三十二样例行针只管成品行不管命令形，此针补位（第 298 轮 D157）" },
};

/// 对面三十七·书稿命令词面（第 301 轮 D160）：《母语编写Zig》快跑/毕业/构建章 24 处命令样例手抄
/// 五枚 `sub_*` 真值，298 轮只钉 README 面——t2 探针两形（书稿 `zzc eject→emit`、`zzc build→bild` 全量
/// 12 行）fmt/build/test/matcher/demos-smoke 五通道零信号实锤。书稿只演示教学主线五词（lang/lsp/
/// test/version 不在书稿命令面）——此子集为**独立手设**（禁从书稿文本抽取，避自证循环，承 297 形制）；
/// needle 全由 `prog_name ++ " " ++ sub_*` 派生，改名即双向拦。
pub const book_cmd_face = [_]zzc.BuildFace{
    .{ .needle = zzc.prog_name ++ " " ++ sub_init, .why = "书稿建章须按 hub 真值演示 init——改名即读者敲未知子命令（第 301 轮 D160）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_run, .why = "书稿快跑道的 run 词——同上形制（第 301 轮 D160）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_build, .why = "书稿构建章的 build 词——探针实锤独漂 `zzc bild` 五通道零信号之形（第 301 轮 D160）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_check, .why = "书稿深检面的 check 词——同上形制（第 301 轮 D160）" },
    .{ .needle = zzc.prog_name ++ " " ++ sub_eject, .why = "书稿毕业章的 eject 词——同上形制（第 301 轮 D160）" },
};

/// 文档面 `zzc <词>` 逆向抽取上限（现盘上 README 36 处最多、书稿 24 处；第 331 轮 D190 relocalize
/// 四行并入后越过旧上限 32，故抬至 48 留余量；防异常灌入兼防静默吞尾）。
pub const book_zzc_word_cap: usize = 48;

pub const BookZzcWords = struct {
    words: [book_zzc_word_cap][]const u8 = undefined,
    count: usize = 0,
    overflow: bool = false,
};

/// 从文本逐处抽「`<prefix>`＋连续 ASCII 字母段（大小写皆收，第 305 轮 D164 扩形——探针实锤只收小写
/// 即 `zzc Ips` 大写鬼词形零信号，而五面活体大写接尾形普查皆零——）」的词段（prefix 形如 "zzc " ；纯函数零 I/O，
/// 第 301 轮 D160）。段为空（后跟非字母：中文/数字/连字符/反引号等叙述形）不入集只推进；
/// 调用方以 `subcommands` 全集做鬼词普查——书稿自增非 hub 词即红。
pub fn collectWordsAfter(text: []const u8, prefix: []const u8) BookZzcWords {
    var out = BookZzcWords{};
    var rest = text;
    var rest_base: usize = 0;
    while (std.mem.indexOf(u8, rest, prefix)) |pos| {
        const start = rest_base + pos + prefix.len;
        var end = start;
        while (end < text.len and ((text[end] >= 'a' and text[end] <= 'z') or (text[end] >= 'A' and text[end] <= 'Z'))) : (end += 1) {}
        if (end > start) {
            if (out.count < book_zzc_word_cap) {
                out.words[out.count] = text[start..end];
                out.count += 1;
            } else {
                out.overflow = true;
            }
        }
        rest_base = end;
        rest = text[end..];
    }
    return out;
}

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

// ── CI e2e 基线脚本 → `extension.js` 的 Contains 针族对账（第 280 轮 · D138）───────
//
// `tools/check-demos.ps1` 的「client guard」节以 `$extSrc.Contains("<js 书写形>")` 断言
// 客户端实文——那是 `extension.js` 的第三份手抄面（方法词／参数键／结果字段已收对面十一／
// 十二／十三）。该节只在 Windows PowerShell 可跑：本机 NO_PWSH ＋ GitCode 从不执行
// Actions（D17 在册）构成双盲，第 279 轮人工普查坐实两枚针早已与 js 实文分道——D136 把
// `cp.spawn(zzcBinary(), lspSpawnArgs())` 拆成先取 bin/args 再 spawn，signatureHelp 的
// 活动参数是赋值形 `help.activeParameter = res.activeParameter` 而非对象 shorthand——
// 即 pwsh 下必假红、Linux 上零信号（D94/D98/D113 同族判例）。
// 本段把「抽取—定极性—回对」的判据入 hub，交守卫对面十八第四清单执行（两文件皆已
// addFileArg·零新增 I/O），此类跨侧分道自此在 `zig build test` 门内转红。

/// ps1 客户端节的一枚 Contains 针。`raw` 系 ps1 实文中双引号之间的**原始**片段（`""`
/// 未折叠，可直接 grep 回脚本定位）；`positive` 为极性：true = 该串须出现在
/// `extension.js`（`-not` 守门形），false = 该串不得出现（英文泄漏类反向针）。
pub const JsPin = struct {
    raw: []const u8,
    positive: bool,
};

/// 针的抓取前缀（收尾双引号之后即 raw 起点）。
const ext_contains_prefix = "$extSrc.Contains(\"";

/// 括号帧：`inherited_not` = 入括号时父层正在生效的取反奇偶（`-not (a -and b)` 让括号内
/// 两针同极性）；`clause_not` = 本层当前子句已见的取反奇偶（`-and`/`-or` 复位，不跨子句传）。
const JsPinFrame = struct { inherited_not: bool, clause_not: bool };

fn jsPinEffNot(frames: []const JsPinFrame, depth: usize) bool {
    return frames[depth].inherited_not != frames[depth].clause_not;
}

/// 大小写不敏感地匹配 PowerShell 逻辑词元（`-not`/`-and`/`-or`）；命中返回其字节长。
/// 尾字节须不是标识字符，免得把 `-nothing` 误认成 `-not`。
fn ps1KwAt(s: []const u8, comptime kw: []const u8) ?usize {
    if (s.len < kw.len) return null;
    if (!std.ascii.eqlIgnoreCase(s[0..kw.len], kw)) return null;
    if (s.len > kw.len and (std.ascii.isAlphanumeric(s[kw.len]) or s[kw.len] == '_')) return null;
    return kw.len;
}

/// 联结词元（`-and`/`-or`）：命中即终结当前子句。
fn ps1JoinKwAt(s: []const u8) ?usize {
    return ps1KwAt(s, "-and") orelse ps1KwAt(s, "-or");
}

/// 跳过一段 PowerShell 字符串字面量（`at` 指向开引号），返回闭合引号之后下标。
/// `""`/`''` 系字面引号而非收尾；反引号续行在本脚本针体内不存在，不入理（如实标注）。
fn skipPs1String(s: []const u8, at: usize) usize {
    const q = s[at];
    var i = at + 1;
    while (i < s.len) {
        if (s[i] == q) {
            if (i + 1 < s.len and s[i + 1] == q) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    return s.len;
}

/// 从 raw 起点找未折叠的收尾双引号下标；`""` 视作字面引号跳过。找不到返回 null。
fn ps1QuoteEnd(s: []const u8, start: usize) ?usize {
    var i = start;
    while (i < s.len) {
        if (s[i] == '"') {
            if (i + 1 < s.len and s[i + 1] == '"') {
                i += 2;
                continue;
            }
            return i;
        }
        i += 1;
    }
    return null;
}

/// 抽取 `ps1_txt` 全部 `$extSrc.Contains("…")` 针及其极性（逐行独立扫描，见 `findJsPinsInLine`）。
pub fn findJsPins(gpa: std.mem.Allocator, ps1_txt: []const u8) ![]JsPin {
    var out: std.ArrayList(JsPin) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, ps1_txt, '\n');
    while (it.next()) |line| {
        try findJsPinsInLine(gpa, line, &out);
    }
    return out.toOwnedSlice(gpa);
}

/// 单行扫描：字符串外的 `-not` 翻转本子句奇偶、`-and`/`-or` 复位、`(`/`)` 进出括号层并继承
/// 当层取反（`-not (a -and b)` 的分配形）。**引号态与括号栈皆以行为界**——PowerShell 字符串
/// 不跨行（本脚本客户端节无 here-string/反引号续行），整文件连扫会让一处行尾孤引号把后续
/// 大段代码当字符串吞掉（第 280 轮首版实锤：63 枚针只抽出 41 枚、反向针极性亦失真）。
fn findJsPinsInLine(gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList(JsPin)) !void {
    var frames: [32]JsPinFrame = undefined;
    frames[0] = .{ .inherited_not = false, .clause_not = false };
    var depth: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        switch (line[i]) {
            '"', '\'' => i = skipPs1String(line, i),
            '(' => {
                const eff = jsPinEffNot(frames[0 .. depth + 1], depth);
                if (depth + 1 >= frames.len) return error.Ps1ParenTooDeep;
                depth += 1;
                frames[depth] = .{ .inherited_not = eff, .clause_not = false };
                i += 1;
            },
            ')' => {
                if (depth > 0) depth -= 1;
                i += 1;
            },
            '-' => {
                if (ps1KwAt(line[i..], "-not")) |n| {
                    frames[depth].clause_not = !frames[depth].clause_not;
                    i += n;
                } else if (ps1JoinKwAt(line[i..])) |n| {
                    frames[depth].clause_not = false;
                    i += n;
                } else {
                    i += 1;
                }
            },
            '$' => {
                if (std.mem.startsWith(u8, line[i..], ext_contains_prefix)) {
                    const start = i + ext_contains_prefix.len;
                    const end = ps1QuoteEnd(line, start) orelse return error.Ps1UnterminatedString;
                    const eff = jsPinEffNot(frames[0 .. depth + 1], depth);
                    try out.append(gpa, .{ .raw = line[start..end], .positive = eff });
                    // `Contains(` 的左括号已被前缀吞掉：同层入栈，好让针后的 `)` 恰好弹回，
                    // 否则该右括号会错弹外层帧、把其后的 `-and`/`-or` 记到别的子句上（A3 演漂实锤）。
                    if (depth + 1 >= frames.len) return error.Ps1ParenTooDeep;
                    depth += 1;
                    frames[depth] = .{ .inherited_not = eff, .clause_not = false };
                    i = end + 1;
                } else {
                    i += 1;
                }
            },
            else => i += 1,
        }
    }
}

/// 按 PowerShell 双引号串语义判断 `raw`（`""` 表一个字面引号）是否作为子串出现在 `hay`。
/// 等价于「先折叠 `""`→`"` 再 indexOf」而不额外分配；针体内无引号时走 indexOf 快路。
pub fn jsPinHits(hay: []const u8, raw: []const u8) bool {
    if (raw.len == 0) return true;
    if (std.mem.indexOfScalar(u8, raw, '"') == null) return std.mem.indexOf(u8, hay, raw) != null;
    var start: usize = 0;
    while (start <= hay.len) : (start += 1) {
        if (jsPinMatchAt(hay[start..], raw)) return true;
    }
    return false;
}

fn jsPinMatchAt(hay: []const u8, raw: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (j < raw.len) : (j += 1) {
        const c = raw[j];
        if (c == '"' and j + 1 < raw.len and raw[j + 1] == '"') {
            if (i >= hay.len or hay[i] != '"') return false;
            i += 1;
            j += 1;
            continue;
        }
        if (i >= hay.len or hay[i] != c) return false;
        i += 1;
    }
    return true;
}

/// 两面对账的审计报告：`total`/`positive` 为 ps1 客户端节抽到的针族基数（守卫 OK 文案据此
/// 运行时真报，不硬写枚数——文案过期本身就是一种漂），`drifts` 为分道清单（空即全对账通过）：
/// 正向针在 `ext_txt` 缺失、或反向针在 `ext_txt` 出现者入列。
pub const JsPinAudit = struct {
    total: usize,
    positive: usize,
    drifts: []JsPin,
};

pub fn jsPinAudit(gpa: std.mem.Allocator, ps1_txt: []const u8, ext_txt: []const u8) !JsPinAudit {
    const pins = try findJsPins(gpa, ps1_txt);
    defer gpa.free(pins);
    var drifts: std.ArrayList(JsPin) = .empty;
    errdefer drifts.deinit(gpa);
    var pos: usize = 0;
    for (pins) |p| {
        if (p.positive) pos += 1;
        if (jsPinHits(ext_txt, p.raw) != p.positive) try drifts.append(gpa, p);
    }
    return .{ .total = pins.len, .positive = pos, .drifts = try drifts.toOwnedSlice(gpa) };
}

test "第 280 轮 T0 ps1 客户端针抽取：极性（-not／括号继承／子句复位）+ 引号折叠 + 漂移判定" {
    const gpa = std.testing.allocator;
    // A1 单枚正向针：`-not` 守门形要求 js 实文含此串。
    {
        const src = "if (-not $extSrc.Contains(\"alpha\")) { $lcOk = $false }\n";
        const pins = try findJsPins(gpa, src);
        defer gpa.free(pins);
        try std.testing.expectEqual(@as(usize, 1), pins.len);
        try std.testing.expectEqualStrings("alpha", pins[0].raw);
        try std.testing.expect(pins[0].positive);
    }
    // A2 反向针：无 `-not` 的 `-or` 链（英文泄漏守卫），两枚皆要求 js 不得含。
    {
        const src = "if ($extSrc.Contains(\"failed to start\") -or $extSrc.Contains(\"Install zzc\")) { $lcOk = $false }\n";
        const pins = try findJsPins(gpa, src);
        defer gpa.free(pins);
        try std.testing.expectEqual(@as(usize, 2), pins.len);
        for (pins) |p| try std.testing.expect(!p.positive);
    }
    // A3 括号继承：`-not (a -and b)` 两枚同正向（缺任一即脚本假红）。
    {
        const src = "if (-not ($extSrc.Contains(\"a\") -and $extSrc.Contains(\"b\"))) { x }\n";
        const pins = try findJsPins(gpa, src);
        defer gpa.free(pins);
        try std.testing.expectEqual(@as(usize, 2), pins.len);
        for (pins) |p| try std.testing.expect(p.positive);
    }
    // A4 子句复位：`-not $a -and $b` 里取反不跨 `-and`——a 正向、b 反向。
    {
        const src = "if (-not $extSrc.Contains(\"a\") -and $extSrc.Contains(\"b\")) { x }\n";
        const pins = try findJsPins(gpa, src);
        defer gpa.free(pins);
        try std.testing.expectEqual(@as(usize, 2), pins.len);
        try std.testing.expect(pins[0].positive);
        try std.testing.expect(!pins[1].positive);
    }
    // A5 字符串内的联结词不改极性（needle 本体含 `-and` 时不得被当子句边界）。
    {
        const src = "if ($extSrc.Contains(\"x -and y\") -or $extSrc.Contains(\"z\")) { x }\n";
        const pins = try findJsPins(gpa, src);
        defer gpa.free(pins);
        try std.testing.expectEqual(@as(usize, 2), pins.len);
        try std.testing.expectEqualStrings("x -and y", pins[0].raw);
        try std.testing.expect(!pins[0].positive and !pins[1].positive);
    }
    // A6 非 Contains 的 `$extSrc` 用法不入针（`Get-Content`/`-split`/`-match` 三形）。
    {
        const src = "$extSrc = Get-Content -Raw x\n$saveLine = ($extSrc -split \"nl\" | Where-Object { $_ -match 'textDocument/didSave' })\n";
        const pins = try findJsPins(gpa, src);
        defer gpa.free(pins);
        try std.testing.expectEqual(@as(usize, 0), pins.len);
    }
    // A7 引号折叠：raw 里的 `""` 在实文侧是单个字面引号，快路／慢路同判。
    {
        try std.testing.expect(jsPinHits("say \"hi\"", "say \"\"hi\"\""));
        try std.testing.expect(!jsPinHits("say hi", "say \"\"hi\"\""));
        try std.testing.expect(jsPinHits("plain", "plain"));
        try std.testing.expect(!jsPinHits("plain", "nope"));
    }
    // A8 漂移判定两面：正向缺、反向有皆入清单；换形后清单为空。
    {
        const src = "if (-not $extSrc.Contains(\"must\")) { x }\nif ($extSrc.Contains(\"leak\")) { x }\n";
        const bad = try jsPinAudit(gpa, src, "has leak here");
        defer gpa.free(bad.drifts);
        try std.testing.expectEqual(@as(usize, 2), bad.total);
        try std.testing.expectEqual(@as(usize, 1), bad.positive);
        try std.testing.expectEqual(@as(usize, 2), bad.drifts.len);
        const ok = try jsPinAudit(gpa, src, "must present, the forbidden word nowhere");
        defer gpa.free(ok.drifts);
        try std.testing.expectEqual(@as(usize, 0), ok.drifts.len);
    }
    // A9 未闭合引号硬失败（静默吞针正是 D138 的失保形，宁可红不可默）。
    {
        try std.testing.expectError(error.Ps1UnterminatedString, findJsPins(gpa, "if (-not $extSrc.Contains(\"abc\n\")) ;"));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// 第 282 轮（D140）：客户端 e2e 冒烟 `tools/extension-smoke.js` 的断言条数锚真值。
//   该套件是 extension.js 在 Linux 上的唯一端到端防线（CI 第 5) 步），而它的覆盖面**就是断言条数本身**：
//   删一条 `ok(...)` 不会让失败变多，只让 PASS 的数字变小而仍退 0。第 282 轮探针实锤——从 capability
//   键名数组删一枚 `'hoverProvider'` 再删一条独立断言，`node tools/extension-smoke.js` 仍报
//   `PASS：87 项断言全过` 退 0，且 `zig build test` 17/17 全绿（运行时与构建链双静默，D139 同族）。
//   修形为三道门：①js 内 `const EXPECT_CHECKS = <n>;` ②js 内 `if (checks !== EXPECT_CHECKS) throw`
//   （精确等号：退坡与增坡皆红，杜绝「改松成 `<`」的弱闸形）③本处 `smoke_js_floor` 独立手设真值，
//   由守卫对面二十四把 ①② 的形串按本值 comptime 派生后回 js 实文逐字节对账。
//   纪律（沿用「护栏数量下限须手设独立、不可从被测侧抽取」判例）：`smoke_js_floor` 绝不可改为从
//   extension-smoke.js 读取——那会让「删断言 + 同步下调锚」自成自洽的绿。上调锚须三处同数。
// ═══════════════════════════════════════════════════════════════════════════

/// 客户端 e2e 冒烟应有的断言条数（独立手设真值；只许上调，下调须人工审）。
pub const smoke_js_floor: usize = 96;

/// js 侧条数锚声明形（数字随 `smoke_js_floor` 派生——锚值与本值分道即针落空，守卫即红）。
pub fn jsAnchorDecl(comptime floor: usize) []const u8 {
    return "const EXPECT_CHECKS = " ++ std.fmt.comptimePrint("{d}", .{floor}) ++ ";";
}

/// js 侧退坡闸形：必须是**精确等号**判定（`<`、`<=`、不判定皆为弱化闸，针落空即红）。
pub const js_anchor_guard = "if (checks !== EXPECT_CHECKS)";

pub const JsAnchorAudit = struct {
    decl: bool,
    guard: bool,
};

/// 对账 js 实文的两枚锚形：声明（含锚数）与退坡闸。二者缺一即防线不完整。
pub fn jsAnchorOk(js_txt: []const u8) JsAnchorAudit {
    return .{
        .decl = jsAnchorHas(js_txt, smoke_js_floor),
        .guard = std.mem.indexOf(u8, js_txt, js_anchor_guard) != null,
    };
}

/// 以给定锚数派生声明针并回 js 实文查命中——独立于 `smoke_js_floor` 的注入形，供测面正反小样复用
/// （同一判据换真值即知「锚数分道」是否真被拦，而非只验一次巧合命中）。
pub fn jsAnchorHas(js_txt: []const u8, comptime floor: usize) bool {
    return std.mem.indexOf(u8, js_txt, jsAnchorDecl(floor)) != null;
}

test "第 282 轮 T0 客户端 e2e 断言条数锚：派生形钉＋下限钉＋删锚/分道/改松三形负例（D140）" {
    // B1 派生形钉：声明针含锚数，且随锚值同动（改 hub 值而不改 js 即针落空）。
    try std.testing.expectEqualStrings("const EXPECT_CHECKS = 89;", jsAnchorDecl(89));
    try std.testing.expectEqualStrings("const EXPECT_CHECKS = 7;", jsAnchorDecl(7));
    // B2 下限钉：hub 真值只许上调（加断言时同步上调即免改测），下调即红——拦「锚数被悄悄降级」。
    try std.testing.expect(smoke_js_floor >= 89);
    // B3 完整形：两枚锚俱在。
    const good =
        \\const EXPECT_CHECKS = 96;
        \\let checks = 0;
        \\if (checks !== EXPECT_CHECKS) {
        \\  throw new Error('x');
        \\}
        \\
    ;
    const a = jsAnchorOk(good);
    try std.testing.expect(a.decl);
    try std.testing.expect(a.guard);
    // B4 负例一：声明被删（只留闸）→ decl 落空。
    const no_decl =
        \\let checks = 0;
        \\if (checks !== EXPECT_CHECKS) {}
        \\
    ;
    try std.testing.expect(!jsAnchorOk(no_decl).decl);
    try std.testing.expect(jsAnchorOk(no_decl).guard);
    // B5 负例二：js 锚数与 hub 真值分道（改小一格即落空——「删断言 + 同步改小 js」仍被 hub 值拦下）。
    const small =
        \\const EXPECT_CHECKS = 88;
        \\if (checks !== EXPECT_CHECKS) {}
        \\
    ;
    try std.testing.expect(jsAnchorHas(small, 88));
    try std.testing.expect(!jsAnchorHas(small, 89));
    try std.testing.expect(!jsAnchorHas(small, smoke_js_floor));
    // B6 负例三：闸被改松（`!==` → `<`，退坡不再红）→ guard 落空。
    const loose =
        \\const EXPECT_CHECKS = 96;
        \\if (checks < EXPECT_CHECKS) {}
        \\
    ;
    try std.testing.expect(jsAnchorOk(loose).decl);
    try std.testing.expect(!jsAnchorOk(loose).guard);
    // B7 负例四：整道闸被删 → guard 落空（探针 E-b 的「PASS：87 仍退 0」形）。
    const no_guard =
        \\const EXPECT_CHECKS = 96;
        \\console.log('PASS');
        \\
    ;
    try std.testing.expect(jsAnchorOk(no_guard).decl);
    try std.testing.expect(!jsAnchorOk(no_guard).guard);
    // B8 闸形与声明必须成对：只给声明不给闸、或只给闸不给声明，皆不得判为完整防线。
    try std.testing.expect(jsAnchorOk("").decl == false and jsAnchorOk("").guard == false);
}

// ───────────────────────────────────────────────────────────────────────────
// 第 283 轮（D142）：客户端 e2e 冒烟的**谓词退化**普查（承 D140 条数锚的极限形）。
//   条数锚拦得住「少一条断言」，拦不住「断言还在、判据被掏空」：把 `ok(x > 0, '…')` 改成
//   `ok(true, '…')`，条数不降、label 不改、PASS 行一字不变，而该条覆盖面已归零。
//   第 283 轮普查见 `tools/extension-smoke.js` 原有三处恒真形（握手生效／didChange 清空／重启握手），
//   皆已换成与 `waitFor` 同骨的实质判据（`ok(readyCount() >= 1, …)`、
//   `ok((state.diagnostics.get(uri) || []).length === 0, …)`），并把该表达式改永假实测可红——
//   证新判据非另一种恒真。本普查把「字面量真」这条路永久封死：上限 0，一处即红。
// ───────────────────────────────────────────────────────────────────────────

/// 恒真谓词的允许上限：**0**（调高须人工审并在消缺台账记形制理由）。
pub const js_tautology_ceiling: usize = 0;

/// 扫 js 实文数出「`ok(` 之后跳空白即字面量 `true`」的调用数。
/// 只认字面量真，故实质表达式（含 `!!x`、`a === b`、`Array.isArray(x)`）皆不计；函数定义
/// `function ok(cond, label)` 的形是 `ok(cond`，也不计——判据退化无处藏。
pub fn jsTautCount(js_txt: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 <= js_txt.len) : (i += 1) {
        if (!std.mem.startsWith(u8, js_txt[i..], "ok(")) continue;
        var j = i + 3;
        while (j < js_txt.len and (js_txt[j] == ' ' or js_txt[j] == '\t')) : (j += 1) {}
        if (std.mem.startsWith(u8, js_txt[j..], "true")) n += 1;
    }
    return n;
}

test "第 283 轮 T0 恒真谓词普查：字面量真计数／空白形／实质表达式零误报／上限钉 0（D142）" {
    // C1 空文本与纯噪声：0。
    try std.testing.expectEqual(@as(usize, 0), jsTautCount(""));
    try std.testing.expectEqual(@as(usize, 0), jsTautCount("no predicates here\n"));
    // C2 单处退化：1。
    try std.testing.expectEqual(@as(usize, 1), jsTautCount("  ok(true, '握手生效');\n"));
    // C3 空白与制表形不放过：`ok( true`、`ok(\ttrue`。
    try std.testing.expectEqual(@as(usize, 1), jsTautCount("ok(  true, 'x');"));
    try std.testing.expectEqual(@as(usize, 1), jsTautCount("ok(\ttrue, 'x');"));
    // C4 多处累加（退化的典型是整批替换）。
    try std.testing.expectEqual(@as(usize, 3), jsTautCount("ok(true, 'a'); ok(true, 'b'); ok(true, 'c');"));
    // C5 实质表达式零误报：本轮换上手的三形 + 常见等价写法。
    const real =
        \\ok(readyCount() >= 1, 'initialize 应答并打日志（客户端握手）');
        \\ok((state.diagnostics.get(uri) || []).length === 0, 'didChange 全文同步生效（诊断清空）');
        \\ok(!state.output.join('').includes('lsp 帧解析错误'), '帧解析无错误');
        \\ok(Array.isArray(def2) && def2.length === 1, '重启后 provider 仍可应答');
        \\function ok(cond, label) { if (!cond) throw new Error(cond); }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), jsTautCount(real));
    // C6 上限钉死为 0：本判据只许收紧不许放宽（放宽须人工审）。
    try std.testing.expectEqual(@as(usize, 0), js_tautology_ceiling);
    // C7 与条数锚同骨的联合判据形：退化后的文本仍满足「条数不减」，唯本普查可拦（自证二者不同职）。
    const degraded = "ok(true, 'a');\nok(readyCount() >= 2, 'b');\n";
    try std.testing.expectEqual(@as(usize, 1), jsTautCount(degraded));
}

test "第 296 轮 T0 version 出口行形串单一真值：渲染钉＋main 委派频次钉＋旧内联形反锚（对面三十二样例行臂·D155）" {
    // A1 渲染钉（独立字面量、不复用族常量）：以哨兵实参渲染形串，验两枚 {s} 顺位与固定段
    //    （prog/语言包词/全角括号冒号）逐字节同骨——形串改形（半角括号/漏冒号/换词）在此现形。
    const gpa = std.testing.allocator;
    const shown = try std.fmt.allocPrint(gpa, version_line_fmt, .{ "9.9.9", "试验田" });
    defer gpa.free(shown);
    try std.testing.expectEqualStrings("zzc 9.9.9（语言包：试验田）", shown);
    // A2 委派频次钉＋旧形反锚：@embedFile 直读 src/main.zig（真 source dependency），version 出口
    //    恰一处委派 hub 形串；旧内联拼装形必为 0 处——消费侧改回手抄字面量即红（承 224/236 形制）。
    const main_src = @embedFile("../main.zig");
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(main_src, "printOut(cli.version_line_fmt"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(main_src, "cli.np_pack_word ++ \"：{s}）\""));
    // A3 清单自身钉：委派形基数 1（增删臂须同步本钉）。
    try std.testing.expectEqual(@as(usize, 1), version_main_face.len);
}

test "第 298 轮 T0 README 命令词面：八枚 needle 与独立手抄 want 表逐字节对拍＋基数钉（D157）" {
    // A1 派生形对拍：want 表独立手抄（与 README 盘上同源而不经 hub）——hub 侧 `prog_name`/`sub_*`
    //    任一改动即此钉红；盘上 README 侧独漂由守卫对面三十四捕（双向互备，承 296 T0 形制；
    //    README 在仓根越出模块包路径不可 @embedFile——202 轮硬约束判例）。
    const want = [_][]const u8{
        "zzc init",
        "zzc check",
        "zzc build",
        "zzc run",
        "zzc eject",
        "zzc relocalize",
        "zzc lang",
        "zzc lsp",
        "zzc version",
    };
    try std.testing.expectEqual(want.len, readme_cmd_face.len); // A2 基数钉：增删子命令面须同步 want 表与本钉
    inline for (readme_cmd_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(want[i], c.needle);
    }
    // A3 词源钉：八枚 sub_* 真值本体（面由它们派生，双层皆钉防 hub 漂移与针形改写）。
    try std.testing.expectEqualStrings("init", sub_init);
    try std.testing.expectEqualStrings("check", sub_check);
    try std.testing.expectEqualStrings("build", sub_build);
    try std.testing.expectEqualStrings("run", sub_run);
    try std.testing.expectEqualStrings("eject", sub_eject);
    try std.testing.expectEqualStrings("relocalize", sub_relocalize);
    try std.testing.expectEqualStrings("lang", sub_lang);
    try std.testing.expectEqualStrings("lsp", sub_lsp);
    try std.testing.expectEqualStrings("version", sub_version);
}

test "第 301 轮 T0 书稿命令词面：五枚派生针 want 对拍＋抽取器合成小样正反形（D160）" {
    // A1 派生形对拍：want 表独立手抄（与书稿盘上同源而不经 hub）——hub 侧 prog_name/sub_* 任一改动即红；
    //    盘上书稿独漂由守卫对面三十七双向捕（针落空＋鬼词），承 296–300 T0 形制。
    const want = [_][]const u8{ "zzc init", "zzc run", "zzc build", "zzc check", "zzc eject" };
    try std.testing.expectEqual(want.len, book_cmd_face.len); // A2 基数钉：教学主线子集增删须同步本钉
    inline for (book_cmd_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(want[i], c.needle);
    }
    // A3 子集合法性钉：五枚皆须属 subcommands 全集（防书稿面子集拖出幽灵词自证）。
    for (want) |w| {
        const word = w[4..]; // 去 "zzc " 前缀取词段
        var found = false;
        for (subcommands) |sub| {
            if (std.mem.eql(u8, sub, word)) found = true;
        }
        try std.testing.expect(found);
    }
    // A4 抽取器正反形：连续小写段入集；空段（中文/数字/连字符/反引号尾随）不入；多词只取首词。
    const sample = "zzc run` 说明 zzc 工具 zzc 0.1.0 然 zzc check --machine 与 zzc build-exe";
    const got = collectWordsAfter(sample, "zzc ");
    try std.testing.expectEqual(@as(usize, 3), got.count); // run / check / build（build-exe 取首段 build）
    try std.testing.expectEqualStrings("run", got.words[0]);
    try std.testing.expectEqualStrings("check", got.words[1]);
    try std.testing.expectEqualStrings("build", got.words[2]);
    try std.testing.expect(!got.overflow);
    // A5 上限值钉与关系钉：cap 现盘上 README 36 处最多（书稿 24 处）——第 331 轮 D190 relocalize
    //    四行并入越过旧上限 32，故抬至 48 留余量；禁 0 退坡。
    try std.testing.expectEqual(@as(usize, 48), book_zzc_word_cap);
    try std.testing.expect(book_zzc_word_cap > want.len);
}

test "第 302 轮 T0 help 旗标族单源与文档合法词集：want 对拍＋正反形＋委派针形钉（D161）" {
    // A1 help 旗标族 want 表独立手抄逐字节对拍＋基数钉：四枚任何增删改形即红。
    const hwant = [_][]const u8{ "--help", "-h", "-?", "help" };
    try std.testing.expectEqual(hwant.len, help_words.len);
    inline for (help_words, 0..) |w, i| {
        try std.testing.expectEqualStrings(hwant[i], w);
    }
    // A2 合法集判据正反形：九子命令＋help 皆真；鬼词/漂移词/大写形皆假。
    for (subcommands) |sub| {
        try std.testing.expect(isDocWordLegal(sub));
    }
    try std.testing.expect(isDocWordLegal("help"));
    try std.testing.expect(!isDocWordLegal("wizard")); // 探针鬼词形
    try std.testing.expect(!isDocWordLegal("emit")); // 改名漂移形（eject→emit）
    try std.testing.expect(!isDocWordLegal("RUN")); // 大写形：CLI 分发读小写真值，大小写不一律
    // A3 main 委派针形钉：needle 恰为表驱动委派形，基数一枚（防面膨手抄回潮位）。
    try std.testing.expectEqual(@as(usize, 1), help_main_face.len);
    try std.testing.expectEqualStrings("for (cli.help_words)", help_main_face[0].needle);
}

test "第 303 轮 T0 文档旗标词面：三族 want 对拍＋基数钉＋子集合法性钉（D162）" {
    // A1 三面 want 表皆独立手抄（与文档盘上同源而不经 hub）——hub 侧 flag_* 任一改动即红；
    //    盘上文档独漂由守卫对面三十九 checkFace 捕，承 296–302 T0 形制。
    try std.testing.expectEqual(@as(usize, 6), readme_flag_face.len);
    try std.testing.expectEqual(@as(usize, 1), plan_flag_face.len);
    try std.testing.expectEqual(@as(usize, 3), contrib_flag_face.len);
    const want5 = [_][]const u8{ "--machine", "--lang", "--lang-file", "--lang-overlay", "--as", "--to" };
    inline for (readme_flag_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(want5[i], c.needle);
    }
    try std.testing.expectEqualStrings("--lang", plan_flag_face[0].needle);
    const want3 = [_][]const u8{ "--lang", "--lang-file", "--lang-overlay" };
    inline for (contrib_flag_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(want3[i], c.needle);
    }
    // A2 子集合法性钉：九枚针全须属 zzc_flags 全集（防面子集拖出幽灵旗标自证）。
    inline for (readme_flag_face ++ plan_flag_face ++ contrib_flag_face) |c| {
        try std.testing.expect(isZzcFlag(c.needle));
    }
    // A3 关系钉：方案书/contributing 面皆须为 README 面子集（README 为用户全可见主面，
    //    子面不得拖出 README 未演示的新旗标）；基数 5 为全集基数（zzc_flags 五枚一一对应）。
    inline for (plan_flag_face ++ contrib_flag_face) |c| {
        var in_readme = false;
        for (readme_flag_face) |r| {
            if (std.mem.eql(u8, r.needle, c.needle)) in_readme = true;
        }
        try std.testing.expect(in_readme);
    }
    try std.testing.expectEqual(zzc_flags.len, readme_flag_face.len); // README 面即全集
}

test "第 304 轮 T0 旗标逆向面：豁免表 want 对拍＋合法集正反形＋抽取器合成小样（D163）" {
    // A1 豁免表 want 独立手抄逐字节对拍＋基数钉：外部工具旗标增删须同步本钉并附出处审。
    const wext = [_][]const u8{ "--check", "--fuzz", "--save", "--install-extension", "--summary" };
    try std.testing.expectEqual(wext.len, doc_flag_exempt.len);
    inline for (doc_flag_exempt, 0..) |f, i| {
        try std.testing.expectEqualStrings(wext[i], f);
    }
    // A2 合法集正反形：zzc 五旗标/--help/五豁免皆真；探针鬼词与短旗裸形皆假。
    for (zzc_flags) |f| {
        try std.testing.expect(isDocFlagLegal(f));
    }
    try std.testing.expect(isDocFlagLegal("--help"));
    for (doc_flag_exempt) |f| {
        try std.testing.expect(isDocFlagLegal(f));
    }
    try std.testing.expect(!isDocFlagLegal("--verbose")); // 探针鬼词形
    try std.testing.expect(!isDocFlagLegal("--zzcghost")); // 探针鬼词形二
    try std.testing.expect(!isDocFlagLegal("--machinX")); // 探针鬼词形三（第 306 轮实注形）
    try std.testing.expect(!isDocFlagLegal("--langg")); // 手抄走样形（近合法而不合法）
    try std.testing.expect(!isDocFlagLegal("lang")); // 无破折头裸形不入集面
    // A3 抽取器合成小样正反形：双破折头小写段全形入集（含连字符内部段）；尾破折剔除；
    //    `---` 分隔形/单短旗/中文破折/数字头不入。
    const s = "zig build --fuzz 与 --lang-overlay 然 --- |----| 及 -Doptimize --2fast --x- 完 --";
    const got = collectDocFlagWords(s);
    try std.testing.expectEqual(@as(usize, 3), got.count); // --fuzz / --lang-overlay / --x（尾破折剔）
    try std.testing.expectEqualStrings("--fuzz", got.words[0]);
    try std.testing.expectEqualStrings("--lang-overlay", got.words[1]);
    try std.testing.expectEqualStrings("--x", got.words[2]);
    try std.testing.expect(!got.overflow);
    // A4 中文破折（U+2014 双份）字节形不匹 ASCII 双破折：独立小样验零入集。
    const zh = "——不是旗标——";
    try std.testing.expectEqual(@as(usize, 0), collectDocFlagWords(zh).count);
    // A5 全集无重叠钉：豁免表与 zzc_flags 交集空（防同形两源自证）。
    for (doc_flag_exempt) |e| {
        try std.testing.expect(!isZzcFlag(e));
    }
    // A6 第 305 轮 D164 命令抽取器扩形正反形：大写鬼词形入集（探针实锤原只收小写即零信号），
    //    大小写混合形亦入集；合法小写形行为不变。
    const up = collectWordsAfter("跑 zzc Ips 与 zzc CHECK 及 zzc check 完", "zzc ");
    try std.testing.expectEqual(@as(usize, 3), up.count);
    try std.testing.expectEqualStrings("Ips", up.words[0]);
    try std.testing.expectEqualStrings("CHECK", up.words[1]);
    try std.testing.expectEqualStrings("check", up.words[2]);
    try std.testing.expect(!isDocWordLegal(up.words[0])); // 大写鬼词形不在合法集（判据大小写敏感）
}

test "第 306 轮 T0 AGENTS.md 两面针：want 对拍＋基数＋子集合法性/关系钉（D165）" {
    // A1 命令面九枚全集：want 独立手抄逐字节对拍＋基数钉（与 subcommands 全集同数）。
    const wcmd = [_][]const u8{ "zzc init", "zzc check", "zzc build", "zzc run", "zzc test", "zzc eject", "zzc relocalize", "zzc lsp", "zzc lang", "zzc version" };
    try std.testing.expectEqual(wcmd.len, agents_cmd_face.len);
    try std.testing.expectEqual(subcommands.len, agents_cmd_face.len); // 全集形制钉：命令面即九子命令
    inline for (agents_cmd_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(wcmd[i], c.needle);
    }
    // A2 命令面needle皆 = prog_name＋空格＋某子命令（关系钉：禁脱钩形）。
    inline for (agents_cmd_face, 0..) |c, i| {
        const sub = c.needle[zzc.prog_name.len + 1 ..];
        try std.testing.expectEqualStrings(subcommands[i], sub);
    }
    // A3 旗标面五枚全集：want 对拍＋基数＋子集合法性钉（皆 ∈ zzc_flags）。
    const wflag = [_][]const u8{ "--machine", "--lang", "--lang-file", "--lang-overlay", "--as", "--to" };
    try std.testing.expectEqual(wflag.len, agents_flag_face.len);
    try std.testing.expectEqual(zzc_flags.len, agents_flag_face.len); // 本面即全集
    inline for (agents_flag_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(wflag[i], c.needle);
        try std.testing.expect(isZzcFlag(c.needle));
    }
    // A4 探针鬼词形反证：手册漂形不在任何合法集。
    try std.testing.expect(!isDocWordLegal("bild")); // 探针命令形（第 306 轮实注）
    try std.testing.expect(!isDocFlagLegal("--machinX")); // 探针旗标形（同轮实注）
}

test "第 307 轮 T0 纯母语话术面：两枚基数＋模板子串关系钉（D166）" {
    // A1 基数钉：两枚（种类名＋改词指引词），防面膨/降臂。
    try std.testing.expectEqual(@as(usize, 2), pure_native_smoke_face.len);
    // A2 关系钉：两枚 needle 皆须为 msg_pure_native 模板子串——模板漂字而面不随动即红，
    //    脚本手抄侧经守卫对面四十三与模板胶合（三处同源：模板/面/脚本）。
    for (pure_native_smoke_face) |c| {
        try std.testing.expect(std.mem.indexOf(u8, msg_pure_native, c.needle) != null);
    }
    // A3 反形：非模板词形不得入面（防近形手抄走样）。
    try std.testing.expect(std.mem.indexOf(u8, msg_pure_native, "纯麦语") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_pure_native, "请改月") == null);
}

test "第 309 轮 T0 叠加轴行为面：话术模板子串钉＋包映射全线手设对拍（D168）" {
    // A1 基数钉：话术五（第 311 轮版本闸两枚＋312 轮选包轴标识一枚入面）＋映射两。
    try std.testing.expectEqual(@as(usize, 5), overlay_smoke_face.len);
    try std.testing.expectEqual(@as(usize, 2), overlay_pack_face.len);
    // A2 话术关系钉：两枚须为迁入模板的子串（模板漂字而面不随即红）。
    try std.testing.expect(std.mem.indexOf(u8, msg_overlay_missing, overlay_smoke_face[0].needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_pack_syntax_hint, overlay_smoke_face[1].needle) != null);
    // A3 映射全线关系钉：键侧 ++ " = " ++ 值侧 须等于独立手设的包映射活线全形（盘上对包文本
    //    的 presence 由守卫对面四十五跑时执行——@embedFile 不可越包路径，296 自守形制在此不适用）。
    const map_line = "网络服务.服务器 = httpz.Server";
    const joined = overlay_pack_face[0].needle ++ " = " ++ overlay_pack_face[1].needle;
    try std.testing.expectEqualStrings(map_line, joined);
    // A4 反形：臆造映射/话术形不在任何真值。
    try std.testing.expect(std.mem.indexOf(u8, map_line, "httpz.Socket") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_overlay_missing, "堆叠语言包") == null);
}

// 第 310 轮 T0（D169）：--lang 内置选包轴三形面——基数钉；话术全等/子串关系钉
// （针[0]=np_unknown_pack 全等零手抄、针[1]「互斥」必为互斥模板子串）；退码数锚
// 与 usage_exit_code 派生对拍；臆造反形独立成测。
test "第 310 轮 T0 --lang 选包轴面：话术全等/子串钉＋退码数锚与 usage_exit_code 同源（D169）" {
    // A1 基数钉：三枚（未知包话术/互斥话术/退码数锚）。
    try std.testing.expectEqual(@as(usize, 3), lang_axis_face.len);
    // A2 全等/对拍：want 独立手抄（盘上实测话术，与上方定义非同一表达式）。
    try std.testing.expectEqualStrings("未知语言包", lang_axis_face[0].needle);
    try std.testing.expectEqualStrings("互斥", lang_axis_face[1].needle);
    try std.testing.expectEqualStrings("EXPECT_USAGE_RC=2", lang_axis_face[2].needle);
    // A3 关系钉：针[0] 与 hub 真值全等；针[1] 须为互斥模板子串（模板漂字即红）。
    try std.testing.expectEqualStrings(np_unknown_pack, lang_axis_face[0].needle);
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_mutex, lang_axis_face[1].needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_mutex, "互斥相干") == null); // 近形反形
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_mutex, "矛盾") == null);
    // A4 退码同源：数锚随 usage_exit_code；臆造退码反形。
    try std.testing.expectEqual(@as(u8, 2), usage_exit_code);
    try std.testing.expect(std.mem.indexOf(u8, lang_axis_face[2].needle, "RC=3") == null);
}

// 第 311 轮 T0（D170）：版本闸模板全形字节钉（独立手抄拼装形）＋新两枚关系钉
// （「过新」⊂模板、升级词与 np_upgrade 全等零手抄）＋误导极性反形。
test "第 311 轮 T0 版本闸模板：全形字节钉＋新针关系/全等钉＋误导反形（D170）" {
    // A1 全形独立手抄（盘上实测输出同骨；模板拼装任一段漂即此钉红）。
    const want_full = "外部语言包「{s}」声明的 $format 过新（当前 zzc 仅支持格式 {d}）。请升级 zzc。";
    try std.testing.expectEqualStrings(want_full, msg_fmt_too_new);
    // A2 基数随动：面五枚（第 312 轮选包轴标识入面）；新两枚关系钉。
    try std.testing.expectEqual(@as(usize, 5), overlay_smoke_face.len);
    try std.testing.expect(std.mem.indexOf(u8, msg_fmt_too_new, overlay_smoke_face[2].needle) != null); // 过新⊂模板
    try std.testing.expectEqualStrings(np_upgrade, overlay_smoke_face[3].needle); // 升级词全等派生
    // A3 分流极性钉：版本闸话术与语法错话术互不含对方极形（塌臂误导形的测图侧投影）。
    try std.testing.expect(std.mem.indexOf(u8, msg_fmt_too_new, "解析失败") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_pack_syntax_hint, "过新") == null);
    // A4 臆造反形：近形词不在模板。
    try std.testing.expect(std.mem.indexOf(u8, msg_fmt_too_new, "过旧") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_fmt_too_new, "请降级") == null);
}

// 第 312 轮 T0（D171）：选包轴标识针入面——基数五钉＋全等对拍（独立手抄）＋
// 臆造反形；两臂分轴胶合关系：十一/十二臂共用话术四枚，本针独指本臂。
test "第 312 轮 T0 选包轴标识针：基数五钉＋全等对拍＋反形（D171）" {
    try std.testing.expectEqual(@as(usize, 5), overlay_smoke_face.len);
    try std.testing.expectEqualStrings("选包轴", overlay_smoke_face[4].needle); // want 独立手抄
    try std.testing.expect(std.mem.indexOf(u8, overlay_smoke_face[4].needle, "叠加轴") == null); // 分轴互斥形
    try std.testing.expect(std.mem.indexOf(u8, overlay_smoke_face[4].needle, "选包抽") == null); // 近形反形
}

// 第 313 轮 T0（D172）：`zzc lang` 列播轴面——基数四钉；三枚全/半派生关系钉
// （两 header 与 np_* 全等、「不是有效」⊂拒绝模板）；内容针对 registry 真值交叉
// （entry 首键必为 "zh"，模板拼装与独立手抄全形对拍）；臆造反形。
test "第 313 轮 T0 列播轴面：派生全等钉＋模板子串钉＋registry 内容交叉（D172）" {
    const reg = @import("../lang/registry.zig");
    // A1 基数钉：五枚（第 315 轮收录列播标识入面，随动；313 轮旧值四）。
    try std.testing.expectEqual(@as(usize, 5), lang_list_face.len);
    // A2 派生全等：两 header 针与 hub 真值同骨（独立手抄 want 对拍）。
    try std.testing.expectEqualStrings("当前语言包", lang_list_face[0].needle);
    try std.testing.expectEqualStrings("可注册包", lang_list_face[1].needle);
    try std.testing.expectEqualStrings(np_cur_pack, lang_list_face[0].needle);
    try std.testing.expectEqualStrings(np_reg_packs, lang_list_face[1].needle);
    // A3 子串关系钉：拒绝词必为迁入模板子串（模板漂字即红）；全形独立手抄对拍。
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_bad_verb, lang_list_face[2].needle) != null);
    // 第 330 轮 D189：动词清单改由 `lang_verbs` 派生——钉派生形而非死字面（加动词即此断言随动）。
    try std.testing.expectEqualStrings("add／remove", lang_verb_list_text);
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_bad_verb, "lang 只有 add／remove 子命令") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_bad_verb, "不是有效子命令。") != null);
    // A4 内容交叉：列播针必命中 registry 首 entry 键形（键改而针不改即红；反之亦然）。
    try std.testing.expect(registry_first_key_shape(reg, lang_list_face[3].needle));
    // A5 臆造反形：近形/非本轴词不在真值。
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_bad_verb, "不是合法") == null); // 近形
    try std.testing.expect(std.mem.indexOf(u8, lang_list_face[3].needle, "tw(") == null); // 臆造列形
}

/// A4 辅助：needle 形如 "zh(" 须等于 registry 首 entry 的 key ++ "("（comptime 拼装比对）。
fn registry_first_key_shape(comptime r: type, comptime needle: []const u8) bool {
    const expect = r.entries[0].key ++ "(";
    return std.mem.eql(u8, needle, expect);
}

// 第 314 轮 T0（D173）：`zzc lang add` 注册链面——基数五钉；三枚全派生对拍（含
// lang_dir 拼装形）；内容针独立手抄全形钉（包文活线交叉交 matcher 对面四十八——
// @embedFile 不可越包路径，309 在册形制）；臆造反形。
test "第 314 轮 T0 注册链面：派生全等钉＋内容手抄钉＋反形（D173）" {
    // A1 基数钉：五枚。
    try std.testing.expectEqual(@as(usize, 16), lang_add_face.len); // 第 321 轮 D180 两枚随动（旧值 14） // 第 319 轮 D178 两枚随动（旧值 12） // 第 318 轮 D177 两枚随动（旧值 10） // 第 317 轮 D176 三枚随动（旧值 7） // 第 316 轮 D175 两枚随动（旧值 5）
    // A2 全派生对拍：回执/拒绝词与 hub 真值同骨（独立手抄 want 一并钉）。
    try std.testing.expectEqualStrings("已装入", lang_add_face[0].needle);
    try std.testing.expectEqualStrings(np_installed, lang_add_face[0].needle);
    try std.testing.expectEqualStrings("本工程内已装有", lang_add_face[1].needle);
    try std.testing.expectEqualStrings(np_dup_installed, lang_add_face[1].needle);
    try std.testing.expectEqualStrings("--as", lang_add_face[3].needle);
    try std.testing.expectEqualStrings(flag_as, lang_add_face[3].needle);
    // A3 目录拼装钉：落位针恰为 lang_dir 加尾斜杠（回执指路与真实落盘同源）。
    try std.testing.expectEqualStrings(".zzc/lang/", lang_add_face[2].needle);
    try std.testing.expectEqualStrings(zzc.lang_dir ++ "/", lang_add_face[2].needle);
    // A4 内容针独立手抄全形钉（fixture 包文侧交叉由对面四十八 run 时读承担）。
    try std.testing.expectEqualStrings("tst-ja", lang_add_face[4].needle);
    // A5 臆造反形：近形词不在真值。
    try std.testing.expect(std.mem.indexOf(u8, np_installed, "已加载") == null);
    try std.testing.expect(std.mem.indexOf(u8, lang_add_face[4].needle, "tst-jb") == null);
}

// 第 315 轮 T0（D174）：收录列播标识针入面——基数五钉＋全等对拍（独立手抄）＋
// 与 313 轮「zh(」内容针互不含（各司两臂）；十五臂三形之守卫侧胶合。
test "第 315 轮 T0 收录列播标识针：基数五钉＋全等对拍＋分针反形（D174）" {
    try std.testing.expectEqual(@as(usize, 5), lang_list_face.len);
    try std.testing.expectEqualStrings("收录列播", lang_list_face[4].needle); // want 独立手抄＝第五枚（面原四枚加一）
    try std.testing.expect(std.mem.indexOf(u8, lang_list_face[4].needle, "zh(") == null); // 分针互斥形
    try std.testing.expect(std.mem.indexOf(u8, lang_list_face[3].needle, "收录") == null); // 反向互斥
    try std.testing.expect(std.mem.indexOf(u8, lang_list_face[4].needle, "收绿列播") == null); // 近形反形
}

// 第 316 轮 T0（D175）：坏注册名话术模板入 hub 单源——三处原手抄改派生后逐关系钉：
// 起首＝np_reg_key_open、`--as`/`$name`/上限数皆派生在场、脚本短形「不可用」⊂ 模板；
// 臆造异引号形反证（同族 313：针只认全形，改引号即不命中）。基数七钉随 face 扩枚。
test "第 316 轮 T0 坏名话术模板：派生三在场＋子串⊂＋反形（D175）" {
    try std.testing.expectEqual(@as(usize, 16), lang_add_face.len); // 第 321 轮 D180 两枚随动（旧值 14） // 第 319 轮 D178 两枚随动（旧值 12） // 第 318 轮 D177 两枚随动（旧值 10） // 第 317 轮 D176 三枚随动（旧值 7）
    // A1 起首全等：模板首段即 hub 开引号词（main 不再自拼前缀）。
    try std.testing.expectEqual(@as(usize, 0), std.mem.indexOf(u8, msg_reg_key_bad, np_reg_key_open).?);
    // A2 三处派生在场：旗名、展示名键、上限数（comptime 印数与 userpack 真值同骨）。
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_bad, flag_as) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_bad, Pack.meta_name) != null);
    const len_pin = std.fmt.comptimePrint("至多 {d} 字", .{userpack.max_key_len});
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_bad, len_pin) != null);
    // A3 脚本面短形⊂模板：十六臂 grep 的「不可用」须仍在 hub 全形内（模板删词即测图红）。
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_bad, "不可用") != null);
    try std.testing.expectEqualStrings("不可用", lang_add_face[5].needle);
    try std.testing.expectEqualStrings("越界零写盘", lang_add_face[6].needle); // 独立手抄
    // A4 反形：异体引号/漂字不在模板（臆造形不得自证）。
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_bad, "注册名『") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_bad, "不可用铀") == null);
}

// 第 317 轮 T0（D176）：坏包族话术词核单源——「不完整」须同时嵌进三形模板（异形同核），
// 外部/已装/裸三址前缀各异而词核共骨；退码数锚由 failure_exit_code comptime 派生（脚本
// 字面随动）；母语出口铁律反形：模板内不得泄 error 名（InvalidLangPack/PackMissing* 等）。
test "第 317 轮 T0 坏包词核三模板同骨＋数锚派生＋反形（D176）" {
    try std.testing.expectEqual(@as(usize, 16), lang_add_face.len); // 第 321 轮 D180 两枚随动（旧值 14） // 第 319 轮 D178 两枚随动（旧值 12） // 第 318 轮 D177 两枚随动（旧值 10）
    // A1 词核⊂三模板（异形同核；改词核即三址同动，脚本十七臂针随 hub 漂而不脱真值）。
    try std.testing.expect(std.mem.indexOf(u8, msg_pack_incomplete, np_incomplete) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_installed_pack_incomplete, np_incomplete) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_bare_pack_incomplete, np_incomplete) != null);
    // A2 包名词派生在场：四模板皆取 np_pack_word（"语言包"三字不得分道）。
    try std.testing.expect(std.mem.indexOf(u8, msg_ext_missing, np_pack_word) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_pack_incomplete, np_pack_word) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_installed_pack_incomplete, np_pack_word) != null);
    // A3 数锚针全等派生：脚本面 EXPECT_FAIL_RC=<hub 值>（值漂即对面红，零新手抄）。
    try std.testing.expectEqualStrings(
        "EXPECT_FAIL_RC=" ++ std.fmt.comptimePrint("{d}", .{failure_exit_code}),
        lang_add_face[8].needle,
    );
    try std.testing.expectEqualStrings("坏包族零落盘", lang_add_face[9].needle); // 独立手抄
    // A4 反形：error 名与漂核字面不在模板（母语出口铁律＋同骨性守门）。
    try std.testing.expect(std.mem.indexOf(u8, msg_pack_incomplete, "PackMissing") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_installed_pack_incomplete, "InvalidLangPack") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_bare_pack_incomplete, "不完备") == null);
}

// 第 318 轮 T0（D177）：已装包第二道门话术分工——疑形提示词只属 installed 模板（外部/裸二形
// 皆不含，三形不重叠即不致把「装配期拒收」与「运行期被改坏」混成一条指引）；模板须持双插值
// （路径点名＋缺项说明），探针摘掉插值即退化成裸形；基数十二枚随动。
test "第 318 轮 T0 已装包疑形提示词分工＋双插值＋反形（D177）" {
    try std.testing.expectEqual(@as(usize, 16), lang_add_face.len); // 第 321 轮 D180 两枚随动（旧值 14） // 第 319 轮 D178 两枚随动（旧值 12）
    // A1 疑形提示词⊂已装模板（派生在场），且模板以其为骨（改词即臂针随 hub 漂不脱真值）。
    try std.testing.expect(std.mem.indexOf(u8, msg_installed_pack_incomplete, np_corrupt_hint) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_installed_pack_incomplete, np_incomplete) != null);
    // A2 三形分工不重叠：外部形与裸形皆不带疑形提示词（混形即把两种成因指引成一处）。
    try std.testing.expect(std.mem.indexOf(u8, msg_pack_incomplete, np_corrupt_hint) == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_bare_pack_incomplete, np_corrupt_hint) == null);
    // A3 双插值形制：已装模板须有两个 {s}（路径＋缺项说明）——探针摘掉路径插值即退化成裸形。
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, msg_installed_pack_incomplete, "{s}"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, msg_bare_pack_incomplete, "{s}"));
    // A4 反形：臂标识独立手抄钉＋漂字面不在模板。
    try std.testing.expectEqualStrings("已装坏包点名路径", lang_add_face[11].needle); // 独立手抄
    try std.testing.expect(std.mem.indexOf(u8, np_corrupt_hint, "装后又被改坏了!") == null);
}

// 第 319 轮 T0（D178）：撞内置名与坏名两闸分工不重叠（坏名管形状、撞名管失能——互相不含对方
// 词核即不会把「另起注册名」的同一指引糊成一条）；遮蔽模板以 np_reg_key_open 起头（与坏名形
// 共用注册名引号骨）并派生 flag_as/flag_lang 两枚旗标真值；臂标识独立手抄。
test "第 319 轮 T0 遮蔽话术派生＋两闸分工＋反形（D178）" {
    try std.testing.expectEqual(@as(usize, 16), lang_add_face.len); // 第 321 轮 D180 两枚随动（旧值 14） // 独立基数钉
    // A1 词核与起头骨：遮蔽模板以 np_reg_key_open 起头（与坏名形同骨）。
    try std.testing.expectEqual(@as(usize, 0), std.mem.indexOf(u8, msg_reg_key_shadow, np_reg_key_open).?);
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_shadow, np_shadow) != null);
    // A2 两枚旗标真值派生在场：指引里的 --as / --lang 皆取 hub，漂旗标即话术随动。
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_shadow, flag_as) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_shadow, flag_lang) != null);
    // A3 两闸分工不重叠：坏名形不含遮蔽词核、撞名形不含坏名词核（混床即一条指引两种成因）。
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_bad, np_shadow) == null);
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_shadow, "不可用") == null);
    // A4 反形：臂标识独立手抄＋模板内不泄 error 名/内部英文标识符。
    try std.testing.expectEqualStrings("同名遮蔽真相", lang_add_face[13].needle); // 独立手抄
    try std.testing.expect(std.mem.indexOf(u8, msg_reg_key_shadow, "AlreadyInstalled") == null);
}

// 第 320 轮 T0（D179）：选包「内置先查、已装兜底」的**调用序本身**入静态钉。
// 缘起：第 319 轮第十九臂形二用输出文本（内置名正断＋已装名反断）代理钉序，探针把
// 已装查询提到内置之前求值而两分支都回 `registry.lookup(n)`——输出字面不动，形二看不见，
// test/matcher/smoke 三通道全绿（序改而输出不变型零信号）。序是遮蔽语义的骨架：今日同输出，
// 明日把兜底支一改即反客为主。故以 @embedFile main 直读选包段，钉「首现序＋出现次数＋兜底
// 同源＋装前拦臂同真相源」，把代理判据升级为序判据。
test "第 320 轮 T0 选包调用序静态钉＋装前拦臂同 lookup 源（D179）" {
    const main_src = @embedFile("../main.zig"); // 真 source dependency：改 main.zig 即此红
    // A1 取窗：选包段起点/终点两枚锚各自恰一枚（锚漂即此红，不用全文件噪声序）。
    const seg_open = "const chosen: registry.Entry = if (lang_name) |n|";
    const seg_close = "const bp = Pack.loadWithOverlays";
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(main_src, seg_open));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(main_src, seg_close));
    const i = std.mem.indexOf(u8, main_src, seg_open).?;
    const j = std.mem.indexOf(u8, main_src, seg_close).?;
    try std.testing.expect(i < j);
    const seg = main_src[i..j];
    // A2 序针：段内内置表查询首现早于已装包查询首现（内置先查）。
    const a = std.mem.indexOf(u8, seg, "registry.lookup(n)").?;
    const b = std.mem.indexOf(u8, seg, "userpack.installedFile(").?;
    try std.testing.expect(a < b);
    // A3 计数针：段内已装查询恰一枚——多一枚即「预查再回内置」形（探针实锤形，输出不变而序已改）。
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(seg, "userpack.installedFile("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(seg, "registry.lookup(n)"));
    // A4 兜底同源：命中已装包须归位来源（供 317/318 的疑形话术）并交回同一装载真相源。
    try std.testing.expect(std.mem.indexOf(u8, seg, "installed_src = ip;") != null);
    try std.testing.expect(std.mem.indexOf(u8, seg, "loadExternalPack(ip)") != null);
    // A5 全图计数钉：main 内 lookup 恰四枚（选用侧＋装前拦截臂＋装后内置不可删臂·第 330 轮 D189＋`--to` 目标包解析臂·第 331 轮 D190）、installedFile 恰两枚（选用臂＋目标包臂；A8 验两臂同序，不构成双源）。
    try std.testing.expectEqual(@as(usize, 4), countOccurrences(main_src, "registry.lookup("));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(main_src, "userpack.installedFile("));
    // A6 装前拦截臂取同一 lookup 真相源且住在 cmdLangAdd 内（另起判据表即与遮蔽语义分道）。
    const add_open = "fn cmdLangAdd(args: []const []const u8) void {";
    const add_close = "fn cmdLangRemove(args: []const []const u8) void {"; // D189 起 add 段以 remove 为界（别把新函数算进来）
    const k = std.mem.indexOf(u8, main_src, add_open).?;
    const l = std.mem.indexOf(u8, main_src, add_close).?;
    try std.testing.expect(k < l);
    const add_seg = main_src[k..l];
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(add_seg, "if (registry.lookup(key)) |_| {"));
    try std.testing.expect(std.mem.indexOf(u8, add_seg, "cli.msg_reg_key_shadow") != null);
    // A7 反形：段内不得出现「先查已装再弃其值」的预查字面。
    try std.testing.expect(std.mem.indexOf(u8, seg, "|_| registry.lookup") == null);
    // A8 `--to` 目标包臂同序（第 331 轮 D190）：辅路也不得「先查已装再回内置」——两臂同形同序，
    //    否则「装了同名用户包就选中」的真值会随命令面分道（此臂与 A2 同一判据，只是座落在另一函数）。
    const tgt_open = "fn loadTargetPack(name: []const u8) !Pack {";
    const tgt_close = "const RelocalizeVerify = enum";
    const tk = std.mem.indexOf(u8, main_src, tgt_open).?;
    const tl = std.mem.indexOf(u8, main_src, tgt_close).?;
    try std.testing.expect(tk < tl);
    const tgt_seg = main_src[tk..tl];
    try std.testing.expect(std.mem.indexOf(u8, tgt_seg, "registry.lookup(name)").? < std.mem.indexOf(u8, tgt_seg, "userpack.installedFile(").?);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(tgt_seg, "userpack.installedFile("));
}

// 第 321 轮 T0（D180）：自家旗标近似名判据的正反形＋透传假阳反形＋main 拦阻臂委派钉。
// 缘起：活体真值实测 `--langx zh`／`--language zh`／`-lang zh`／`--machin` 一律静默吞（RC=0 按默认
// 包跑），而错**包名**早在 314 轮设闸退 2——错旗标名比错包名更隐蔽（用户与 AI 皆以为旗标生效）。
// unit 层已钉 findFlag 严格匹配（本轮吞并探针即被 25/26/42/207 轮四枚测×双图拦红），缺的是判据本体
// 与真跑层拦阻；判据入 hub 纯函数，main 只扫描＋退出（承「判据入 hub、守卫只做 I/O」形制）。
test "第 321 轮 T0 近似旗标判据正反形＋透传假阳反形＋main 拦阻臂委派钉（D180）" {
    // A1 近似三形各自点名合法名：超集（多打尾缀）／截断（少打尾缀）／破折数不符。
    try std.testing.expectEqualStrings("--lang", nearZzcFlag("--langx").?);
    try std.testing.expectEqualStrings("--lang", nearZzcFlag("--language").?);
    try std.testing.expectEqualStrings("--lang", nearZzcFlag("-lang").?);
    try std.testing.expectEqualStrings("--machine", nearZzcFlag("--machin").?);
    // A2 最近匹配打分：同族多枚皆近似时取长度差最小者（非表内首个命中——错建议比无建议更害人）。
    try std.testing.expectEqualStrings("--lang-file", nearZzcFlag("--lang-filex").?);
    try std.testing.expectEqualStrings("--lang-overlay", nearZzcFlag("--lang-overlayx").?);
    try std.testing.expectEqualStrings("--lang", nearZzcFlag("--lan").?);
    // A3 等号形先取 `=` 左侧再判（值体不得污染名判据）。
    try std.testing.expectEqualStrings("--lang", nearZzcFlag("--langx=zh").?);
    try std.testing.expectEqualStrings("--help", nearZzcFlag("--hel").?);
    // A4 合法集全等一律放过（含同族前缀枚 `--lang-file`/`--lang-overlay` 与 help 四形）。
    for (legal_flag_words) |m| {
        if (nearZzcFlag(m) != null) std.debug.print("合法枚被误判：{s}\n", .{m});
        try std.testing.expect(nearZzcFlag(m) == null);
    }
    // A5 假阳反形（本轮最要紧的一钉）：zig 原生/透传常见旗标绝不判近似——拦错真命令即伤透传契约。
    const passthrough = [_][]const u8{
        "-Doptimize=ReleaseSafe", "--cache-dir=p", "--summary=all",
        "--check",                "--fuzz",        "--save",
        "--install-extension",    "-lc",           "-l",
        "-O",                     "--mod",         "--name=x",
        "--verbose",              "--no-emit-bin", "-Mroot=./g",
        "--strip",                "--test-name=t", "--lang=zh",
    };
    for (passthrough) |q| {
        if (nearZzcFlag(q)) |bad| std.debug.print("假阳：{s} 被疑作 {s}\n", .{ q, bad });
        try std.testing.expect(nearZzcFlag(q) == null);
    }
    // A6 非旗标/分隔符/空串一律放过（`--` 之后属透传区，main 侧另有 break 闸）。
    try std.testing.expect(nearZzcFlag("--") == null);
    try std.testing.expect(nearZzcFlag("-") == null);
    try std.testing.expect(nearZzcFlag("") == null);
    try std.testing.expect(nearZzcFlag("lang") == null);
    try std.testing.expect(nearZzcFlag("src/main.zz") == null);
    // A7 话术单源：模板含词核、合法名清单由 zzc_flags comptime 派生且逐字节等于独立手抄形。
    try std.testing.expect(std.mem.indexOf(u8, msg_flag_near, np_flag_typo) != null);
    try std.testing.expectEqualStrings("--lang、--lang-file、--lang-overlay、--machine、--as、--to", flag_list_text);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, flag_list_text, "、")); // 六枚相连→五分隔
    for (zzc_flags) |f| try std.testing.expect(std.mem.indexOf(u8, flag_list_text, f) != null);
    // A8 main 消费面委派钉：拦阻臂、话术、`--` 逃生口 break 各恰一枚（手抄/多址即此红）。
    const main_src = @embedFile("../main.zig");
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(main_src, "cli.nearZzcFlag(a)"));
    // 针带尾逗号：`cli.msg_flag_near` 是 `cli.msg_flag_near_before_cmd` 的前缀，不带逗号会把
    // 第 326 轮新增的近近似话术一起计入（首打 expected 1, found 2）。
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(main_src, "cli.msg_flag_near,"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(main_src, "if (std.mem.eql(u8, a, \"--\")) break;")); // 第 331 轮 D190：`--to` 串台闸同样在 `--` 处收手，两处逃生口
    // A9 面基数 16 独立钉＋标识针手抄对拍（削面即编译期/运行时双拦）。
    try std.testing.expectEqual(@as(usize, 16), lang_add_face.len);
    try std.testing.expectEqualStrings("旗标笔误装前即拒", lang_add_face[15].needle);
    try std.testing.expectEqualStrings(np_flag_typo, lang_add_face[14].needle);
    // A10 双址计数闸（演漂形⑤ 所逼）：旧形 occ 缺省=1，注释与 echo 只改一处亦过——两枚新针各要 2 枚。
    try std.testing.expectEqual(@as(usize, 2), lang_add_face[14].occ); // 词核：判据址＋文案址
    try std.testing.expectEqual(@as(usize, 3), lang_add_face[15].occ); // 标识：注释＋[FAIL]＋[ok] 三址
}

// 判据本体已提为 `zzc_paths.declaredAddrCount`（第 323 轮 D182 从本模块迁出，供六族面型的名实闸共用；
// 本表元判据仍在此处对拍，守「判据入 hub、守卫只做 I/O」与 322 轮形制的连续性）。

// 第 322 轮 T0（D181）：面针「名实相符」元判据——第 321 轮演漂形⑤ 揭出结构性病灶：`.why` 自称
// 「双址」而 `BuildFace.occ` 缺省只核存在性（守只看「在不在」），改掉一处仍绿。本轮把 5 枚自称双址
// 的标识针按**实测址数**收紧（3/4/4/3/2），且立元判据自动覆盖今后添针：自称多址者 occ 必 ≥2、
// occ>1 者 .why 必写址（双向，防「收紧后忘写址数」「写址数却仍 occ=1」两向漂）。元判据只遍历下面
// 清单内的表——清单漏表即整表失守，故另钉清单枚数与各表基数（独立手抄）。
test "第 322 轮 T0 面针名实相符元判据＋面表清单基数钉（D181）" {
    const tables = .{ lang_list_face[0..], lang_add_face[0..] };
    // A1 清单基数钉：入清单的表恰两张、各自基数独立手抄（添表/掏表即此红）。
    try std.testing.expectEqual(@as(usize, 2), tables.len);
    try std.testing.expectEqual(@as(usize, 5), lang_list_face.len);
    try std.testing.expectEqual(@as(usize, 16), lang_add_face.len);
    // A2 名实相符双向（判据本体＝文字声明的址数）：声明几址就必须几址；已收紧（occ>1）而 why 未声明
    // 址数亦红——首版只认「双址」字样，删 .occ 后 why 写「四址」竟不红，故改为数字解析等值对拍。
    inline for (tables) |tab| {
        inline for (tab) |c| {
            if (zzc.declaredAddrCount(c.why)) |n| {
                if (c.occ != n) std.debug.print("名实不符：{s} 声明 {d} 址而 occ={d}\n", .{ c.needle, n, c.occ });
                try std.testing.expectEqual(n, c.occ);
            } else if (c.occ > 1) {
                std.debug.print("occ 已收紧而 why 未声明址数：{s}\n", .{c.needle});
                try std.testing.expect(false);
            }
        }
    }
    // A3 收紧实况值钉（独立手抄，不复用被测常量）：针文本与实址数双钉——纯索引钉在表序调整时
    // 会张冠李戴（本轮首打即把「同名遮蔽真相」写成 [12]（实为词核 [12]）、靠针文本才能立刻定位）。
    const occ_pins = .{
        .{ lang_list_face[4], "收录列播", @as(usize, 3) },
        .{ lang_add_face[6], "越界零写盘", @as(usize, 4) },
        .{ lang_add_face[9], "坏包族零落盘", @as(usize, 4) },
        .{ lang_add_face[11], "已装坏包点名路径", @as(usize, 3) },
        .{ lang_add_face[13], "同名遮蔽真相", @as(usize, 2) },
        .{ lang_add_face[14], "笔误", @as(usize, 2) },
        .{ lang_add_face[15], "旗标笔误装前即拒", @as(usize, 3) },
    };
    inline for (occ_pins) |pin| {
        try std.testing.expectEqualStrings(pin[1], pin[0].needle);
        try std.testing.expectEqual(pin[2], pin[0].occ);
    }
    // A4 反形：occ 缺省仍为 1（未收紧的针不得被误当多址——presence 语义保持不变）。
    try std.testing.expectEqual(@as(usize, 1), lang_add_face[0].occ);
    try std.testing.expectEqual(@as(usize, 1), lang_list_face[0].occ);
}

// 第 324 轮 T0（D183）：`.count` 形收编为 `occ`。第 323 轮把三张匿名 tuple 表（`tl_face`／
// `exit_code_face`／`version_main_face`）登记为豁免，理由是字段名与七族不同；但真跑侧
// `checkFace` 只读 `occ` 并回落 1——声明「九址」「两址」的针在守卫步只被要求 1 枚，测试图按
// `count` 精确、守卫步却宽松，**两套语义并存**。本轮统一为 `[_]zzc.BuildFace`＋`occ`，豁免撤销。
test "第 324 轮 T0 .count 收编 occ：三表值钉＋形制回流反形（D183）" {
    // A1 三表基数与收紧值钉（针文本＋occ 双钉，防表序调整张冠李戴）。
    try std.testing.expectEqual(@as(usize, 7), tl_face.len);
    try std.testing.expectEqual(@as(usize, 2), exit_code_face.len);
    try std.testing.expectEqual(@as(usize, 1), version_main_face.len);
    try std.testing.expectEqualStrings("&.{ cli.tl_zig, cli.tl_build }", tl_face[5].needle);
    try std.testing.expectEqual(@as(usize, 2), tl_face[5].occ); // eject 探纹/验建两址
    try std.testing.expectEqualStrings("std.process.exit(cli.usage_exit_code);", exit_code_face[0].needle);
    // D184 三闸各一处（9→12）；D185 前置闸扩为四分类分派（12→15）；D186 未知子命令分支改直退（15→16）。
    // D187 叠加层点名分支再增一处 usage 退出臂（16→17）。
    try std.testing.expectEqual(@as(usize, 24), exit_code_face[0].occ); // 第 330 轮 D189：lang remove 五臂 +5；第 331 轮 D190：relocalize 两臂 +2
    try std.testing.expectEqualStrings("if (e == error.Usage) cli.usage_exit_code else cli.failure_exit_code", exit_code_face[1].needle);
    try std.testing.expectEqual(@as(usize, 1), exit_code_face[1].occ);
    try std.testing.expectEqual(@as(usize, 1), version_main_face[0].occ);
    // A2 形制回流反形：本 hub 源码里旧字段名赋值形（点 count 后接等号）必须 0 处——三表若被改回
    // 该形（或新增面表沿用旧字段名），守卫侧 `checkFace` 会重新静默回落 1 枚，测试图看不出差别。
    // 注：本注释不得写出该字面量（注释亦在自嵌源码内），故只作描述。
    const self_src = @embedFile("args.zig"); // 相对本源文件目录（承 224 T0 的 "../main.zig" 形）
    // 拼接避开自指：直写字面量会让 needle 自身计入自嵌源码（首打即「expected 0, found 2」）。
    const legacy_field = ".count" ++ " = ";
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(self_src, legacy_field));
    // A3 反向：三表形制确为 `[_]zzc.BuildFace`（非匿名 tuple）——匿名 tuple 无法被守卫按字段取 occ。
    try std.testing.expectEqual(@as(usize, 7 * @sizeOf(zzc.BuildFace)), @sizeOf(@TypeOf(tl_face)));
}

// 第 325 轮 T0（D184）：旗标形制三闸判据。活体真值（改前）：`check --lang` 尾随缺值 RC=0 静默按默认
// 包跑；`check --lang=` 报「未知语言包「」」；`check --lang --machine` 把旗标吞成包名；
// `check --lang zh --lang 繁体` 前者胜、后者静默丢弃；`zzc --lang zh check`／`--lang=zh check`／
// `--machine check` 一律报「未知或不完整的子命令」（误诊：用户给的是旗标，不是子命令）。
test "第 325 轮 T0 旗标形制三闸：三态扫描／重复计数／前置点名（D184）" {
    // A1 scanFlag 三态：absent 与 missing 必须可区分（旧 findFlag 把两者都折成 null）。
    const none = [_][]const u8{ "check", "src/main.zz" };
    try std.testing.expect(scanFlag(&none, flag_lang) == .absent);
    const tail = [_][]const u8{ "check", flag_lang };
    try std.testing.expect(scanFlag(&tail, flag_lang) == .missing);
    const empty = [_][]const u8{"--lang="};
    try std.testing.expect(scanFlag(&empty, flag_lang) == .missing);
    // 值形似自有旗标：不得吞成取值（旧形报「未知语言包「--machine」」）。
    const flagv = [_][]const u8{ "check", flag_lang, flag_machine };
    try std.testing.expect(scanFlag(&flagv, flag_lang) == .missing);
    // 正常两参形／等号形。
    const two = [_][]const u8{ "check", flag_lang, "zh" };
    try std.testing.expectEqualStrings("zh", scanFlag(&two, flag_lang).value);
    const eq = [_][]const u8{"--lang=zh"};
    try std.testing.expectEqualStrings("zh", scanFlag(&eq, flag_lang).value);
    // 同族前缀互不误匹：`--lang-file a` 不得让 `--lang` 得值。
    const sib = [_][]const u8{ "check", "--lang-file", "包/外.txt" };
    try std.testing.expect(scanFlag(&sib, flag_lang) == .absent);
    try std.testing.expectEqualStrings("包/外.txt", scanFlag(&sib, flag_lang_file).value);
    // findFlag 旧语义保持：缺值/空值皆 null（调用方按未选包处置），有值才返回。
    try std.testing.expectEqual(@as(?[]const u8, null), findLangFlag(&tail));
    try std.testing.expectEqualStrings("zh", findLangFlag(&two).?);

    // A2 countFlag：两参形＋等号形混合计次（重复闸的分母）。
    try std.testing.expectEqual(@as(usize, 0), countFlag(&none, flag_lang));
    try std.testing.expectEqual(@as(usize, 1), countFlag(&two, flag_lang));
    const dup = [_][]const u8{ "check", flag_lang, "zh", "--lang=繁体" };
    try std.testing.expectEqual(@as(usize, 2), countFlag(&dup, flag_lang));
    try std.testing.expectEqual(@as(usize, 0), countFlag(&sib, flag_lang)); // 前缀旗标不计入

    // A3 ownFlagName：子命令位的旗标点名（含等号形——`--lang=zh` 旧形漏网于 nearZzcFlag）。
    try std.testing.expectEqualStrings(flag_lang, ownFlagName(flag_lang).?);
    try std.testing.expectEqualStrings(flag_lang, ownFlagName("--lang=zh").?);
    try std.testing.expectEqualStrings(flag_machine, ownFlagName(flag_machine).?);
    try std.testing.expectEqual(@as(?[]const u8, null), ownFlagName("check"));
    try std.testing.expectEqual(@as(?[]const u8, null), ownFlagName("--langx")); // 近似名归 nearZzcFlag

    // A4 取值旗标清单：四枚且与 find* 家族一一对应（漏登即缺值闸漏一旗标）。
    try std.testing.expectEqual(@as(usize, 4), flag_value_takers.len);
    try std.testing.expectEqualStrings(flag_lang, flag_value_takers[0].flag);
    try std.testing.expectEqualStrings(flag_lang_file, flag_value_takers[1].flag);
    try std.testing.expectEqualStrings(flag_lang_overlay, flag_value_takers[2].flag);
    try std.testing.expectEqualStrings(flag_to, flag_value_takers[3].flag);
    for (flag_value_takers) |t| try std.testing.expect(t.hint.len > 0);

    // A5 话术可插值且点名旗标（三条各含定位词；模板写坏即在此红，不必等真跑）。
    const gpa = std.testing.allocator;
    const m1 = try std.fmt.allocPrint(gpa, msg_flag_missing_value, .{ flag_lang, flag_lang, "语言包名" });
    defer gpa.free(m1);
    try std.testing.expect(std.mem.indexOf(u8, m1, "缺少取值") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, "语言包名") != null);
    const m2 = try std.fmt.allocPrint(gpa, msg_flag_repeat, .{ flag_lang, @as(usize, 2) });
    defer gpa.free(m2);
    try std.testing.expect(std.mem.indexOf(u8, m2, "2 次") != null);
    const m3 = try std.fmt.allocPrint(gpa, msg_flag_before_cmd, .{ flag_lang, flag_lang });
    defer gpa.free(m3);
    try std.testing.expect(std.mem.indexOf(u8, m3, "子命令之后") != null);
}

// 第 326 轮 T0（D185）：子命令位四分类。活体真值（改前）：`--fuzz check`／`--unknown check`／
// `--langx zh check`／`-O check`／`--`／`-x`／`--check src/main.zz` 八形一律报「未知或不完整的子命令」。
test "第 326 轮 T0 子命令位四分类：自有／近似／分隔符／旗标形（D185）" {
    // A1 自有旗标（含 `=` 形）：位置错，点名旗标。取 payload 一律走 switch——直接 `.own` 在
    // tag 不符时是 panic（unsafe access），演漂会崩成无信息输出而非清晰断言失败。
    try std.testing.expectEqualStrings(flag_lang, switch (classifyCmdSlot(flag_lang)) {
        .own => |n| n,
        else => "",
    });
    try std.testing.expectEqualStrings(flag_lang, switch (classifyCmdSlot("--lang=zh")) {
        .own => |n| n,
        else => "",
    });
    try std.testing.expectEqualStrings(flag_machine, switch (classifyCmdSlot(flag_machine)) {
        .own => |n| n,
        else => "",
    });
    // A2 近似名：笔误建议＋位置双错（`--langx` 指 `--lang`）。
    try std.testing.expectEqualStrings(flag_lang, switch (classifyCmdSlot("--langx")) {
        .near => |n| n,
        else => "",
    });
    try std.testing.expectEqualStrings(flag_lang, switch (classifyCmdSlot("--language")) {
        .near => |n| n,
        else => "",
    });
    // A3 `--` 分隔符占位：与「未知子命令」分开报。
    try std.testing.expect(classifyCmdSlot("--") == .separator);
    // A4 其余旗标形（zig 透传侧）：`--fuzz`／`-O`／`--check`／`-x` 皆非 zzc 自有、也非近似。
    try std.testing.expect(classifyCmdSlot("--fuzz") == .flag_shaped);
    try std.testing.expect(classifyCmdSlot("-O") == .flag_shaped);
    try std.testing.expect(classifyCmdSlot("--check") == .flag_shaped);
    try std.testing.expect(classifyCmdSlot("-x") == .flag_shaped);
    // A5 正常子命令与普通参数：ok（不得误报）。
    try std.testing.expect(classifyCmdSlot("check") == .ok);
    try std.testing.expect(classifyCmdSlot("run") == .ok);
    try std.testing.expect(classifyCmdSlot("lang") == .ok);
    try std.testing.expect(classifyCmdSlot("src/main.zz") == .ok);
    // 单破折号 `-` 本身不含旗标核，仍属旗标形（不会是子命令）。
    try std.testing.expect(classifyCmdSlot("-") == .flag_shaped);

    // A6 三话术可插值且含定位词（模板写坏即在此红）。
    const gpa = std.testing.allocator;
    const m1 = try std.fmt.allocPrint(gpa, msg_flag_near_before_cmd, .{ "--langx", flag_lang, flag_lang });
    defer gpa.free(m1);
    try std.testing.expect(std.mem.indexOf(u8, m1, "--langx") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, "笔误") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, "子命令之后") != null);
    const m2 = try std.fmt.allocPrint(gpa, msg_dashdash_first, .{});
    defer gpa.free(m2);
    try std.testing.expect(std.mem.indexOf(u8, m2, "子命令之后") != null);
    // A7 declaredAddrCount 长匹配优先（第 326 轮 D185 自纠）：`十五址` 含 `五址`、`十三址` 含
    // `三址`——短档在前会抢先命中，扩档后守卫立刻报「声明十五址而 occ=15 不符」（实际解析成 5）。
    try std.testing.expectEqual(@as(?usize, 24), zzc.declaredAddrCount("二十四址")); // 第 331 轮 D190：relocalize 两臂
    try std.testing.expectEqual(@as(?usize, 22), zzc.declaredAddrCount("二十二址"));
    try std.testing.expectEqual(@as(?usize, 21), zzc.declaredAddrCount("二十一址"));
    try std.testing.expectEqual(@as(?usize, 15), zzc.declaredAddrCount("十五址"));
    try std.testing.expectEqual(@as(?usize, 14), zzc.declaredAddrCount("十四址"));
    try std.testing.expectEqual(@as(?usize, 11), zzc.declaredAddrCount("十一址"));
    try std.testing.expectEqual(@as(?usize, 13), zzc.declaredAddrCount("十三址"));
    try std.testing.expectEqual(@as(?usize, 12), zzc.declaredAddrCount("十二址"));
    try std.testing.expectEqual(@as(?usize, 10), zzc.declaredAddrCount("十址"));
    try std.testing.expectEqual(@as(?usize, 5), zzc.declaredAddrCount("五址"));
    try std.testing.expectEqual(@as(?usize, 2), zzc.declaredAddrCount("两址"));
    try std.testing.expectEqual(@as(?usize, 2), zzc.declaredAddrCount("双址"));
    try std.testing.expectEqual(@as(?usize, null), zzc.declaredAddrCount("三处")); // 非「址」措辞不解析
    const m3 = try std.fmt.allocPrint(gpa, msg_not_subcmd_flag, .{"--fuzz"});
    defer gpa.free(m3);
    try std.testing.expect(std.mem.indexOf(u8, m3, "--fuzz") != null);
    try std.testing.expect(std.mem.indexOf(u8, m3, "不能当子命令") != null);
}

// 第 327 轮 T0（D186）：未知子命令点名＋最近似建议。活体真值（改前）：`chek`／`biuld`／`testt`／
// `ejct`／`initx`／`xyz` 一律只说「未知或不完整的子命令」——不说哪个词错，也不说可能是哪条。
test "第 327 轮 T0 未知子命令：点名＋编辑距离≤1 建议＋派生全集（D186）" {
    // A1 同源：近似判据与文案都吃既有 `subcommands` 穷举表（其枚数/首尾/唯一性另有完备测），此
    // 处只钉「本轮的文案与建议都从这张表派生」——另立第二套清单即在此红（324 轮同纪律）。
    try std.testing.expect(subcommands.len >= 9);
    for (subcommands) |c| try std.testing.expect(isKnownSubcommand(c));

    // A2 合法名自身不给建议（否则合法命令也会被"建议"改掉）；空串非近似。
    for (subcommands) |c| try std.testing.expectEqual(@as(?[]const u8, null), nearSubcmd(c));
    for (subcommands) |c| try std.testing.expect(!withinOneEdit(c, ""));
    try std.testing.expectEqual(@as(?[]const u8, null), nearSubcmd(""));

    // A3 单处替换／增／删／相邻换位四形皆命中（换位属 Damerau 距离 1：`chekc`／`biuld`）。
    try std.testing.expectEqualStrings(sub_check, nearSubcmd("chek").?); // 单处删
    try std.testing.expectEqualStrings(sub_test, nearSubcmd("testt").?); // 单处增
    try std.testing.expectEqualStrings(sub_eject, nearSubcmd("ejct").?); // 单处删
    try std.testing.expectEqualStrings(sub_init, nearSubcmd("initx").?); // 单处替换
    try std.testing.expectEqualStrings(sub_build, nearSubcmd("biuld").?); // 相邻换位
    try std.testing.expectEqualStrings(sub_check, nearSubcmd("chekc").?); // 相邻换位（末两字）

    // A4 距离 ≥2 不给建议（瞎猜比不猜更糟）。
    try std.testing.expectEqual(@as(?[]const u8, null), nearSubcmd("xyz"));
    try std.testing.expectEqual(@as(?[]const u8, null), nearSubcmd("biuldsx"));
    try std.testing.expectEqual(@as(?[]const u8, null), nearSubcmd("che"));
    try std.testing.expectEqual(@as(?[]const u8, null), nearSubcmd("checkout"));

    // A5 话术：点名原词＋建议＋派生全集（模板/清单写坏即在此红）。
    const gpa = std.testing.allocator;
    const m1 = try std.fmt.allocPrint(gpa, msg_subcmd_near, .{ "chek", sub_check });
    defer gpa.free(m1);
    try std.testing.expect(std.mem.indexOf(u8, m1, "chek") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, sub_check) != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, sub_version) != null);
    const m2 = try std.fmt.allocPrint(gpa, msg_unknown_subcmd, .{"xyz"});
    defer gpa.free(m2);
    try std.testing.expect(std.mem.indexOf(u8, m2, "xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, m2, sub_eject) != null);
    // 全集文案与清单同源：每枚子命令都出现在派生文案里（漏枚即文案缺项）。
    for (subcommands) |c| try std.testing.expect(std.mem.indexOf(u8, msg_unknown_subcmd, c) != null);
}

// 第 328 轮 T0（D187）：叠加层点名话术。活体真值（改前）：`--lang 繁體`／`繁体`／`正体字`／`繁體中文`
// 一律只说「未知语言包「繁體」。当前可用：zh(简体中文)」——把「默认已叠加」误报成「没有这个东西」。
test "第 328 轮 T0 叠加层点名面：话术插值＋反形（D187）" {
    try std.testing.expectEqual(@as(usize, 2), overlay_name_face.len);

    const gpa = std.testing.allocator;
    const m = try std.fmt.allocPrint(gpa, msg_pack_is_overlay, .{ "繁體", "zh", "繁体字形", "zh" });
    defer gpa.free(m);
    try std.testing.expect(std.mem.indexOf(u8, m, "繁體") != null); // 点名原词
    try std.testing.expect(std.mem.indexOf(u8, m, "繁体字形") != null); // 点名声明的叠加层名
    try std.testing.expect(std.mem.indexOf(u8, m, "默认已叠加") != null); // 正解：无需选择
    try std.testing.expect(std.mem.indexOf(u8, m, "--lang zh") != null); // 给出确切写法
    // 反形：不得再走「未知语言包」话术（否则等于本轮白改）。
    try std.testing.expect(std.mem.indexOf(u8, m, np_unknown_pack) == null);
}

// 第 329 轮 T0（D188）：lang 二级动词点名＋近似建议。活体真值（改前）：`lang ad`／`addd`／`lst`／
// `removes`／`安装`／`install`／`-h` 一律只回「lang 只有 add 子命令：…」——不点名错词、不提最可能想打的那条。
test "第 329 轮 T0 lang 动词：点名＋近似建议＋用法串单源（D188）" {
    // A1 词表：add＋remove（第 330 轮扩表），且精确命中不算近似（否则合法动词也会被"建议"改掉）。
    try std.testing.expectEqual(@as(usize, 2), lang_verbs.len);
    try std.testing.expectEqualStrings("add", lang_verbs[0]);
    try std.testing.expectEqualStrings("remove", lang_verbs[1]);
    try std.testing.expectEqual(@as(?[]const u8, null), nearWord("add", &lang_verbs));
    try std.testing.expectEqual(@as(?[]const u8, null), nearWord("", &lang_verbs));

    // A2 近似四形：缺字/多字/替换皆命中 add。
    try std.testing.expectEqualStrings("add", nearWord("ad", &lang_verbs).?);
    try std.testing.expectEqualStrings("add", nearWord("addd", &lang_verbs).?);
    try std.testing.expectEqualStrings("add", nearWord("asd", &lang_verbs).?);
    try std.testing.expectEqualStrings("add", nearWord("adds", &lang_verbs).?); // 单处增亦距离 1
    try std.testing.expectEqualStrings("remove", nearWord("removes", &lang_verbs).?); // 330 扩表后转正形
    try std.testing.expectEqualStrings("remove", nearWord("remov", &lang_verbs).?);

    // A3 反形：距离 ≥2 或语义无关者一律不建议（瞎猜比不猜更糟）。
    for ([_][]const u8{ "lst", "install", "-h", "安装", "ax", "rm" }) |w| {
        try std.testing.expectEqual(@as(?[]const u8, null), nearWord(w, &lang_verbs));
    }

    // A4 话术：点名原词＋建议＋用法串（用法串与兜底同源，两处各抄即在此红）。
    const gpa = std.testing.allocator;
    const m = try std.fmt.allocPrint(gpa, msg_lang_verb_near, .{ "ad", "add" });
    defer gpa.free(m);
    try std.testing.expect(std.mem.indexOf(u8, m, "「ad」") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "「add」") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, lang_verbs_usage) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_bad_verb, lang_verbs_usage) != null); // 同源
    try std.testing.expect(std.mem.indexOf(u8, m, "addd") == null); // 臆造反形
}

// 第 330 轮 T0（D189）：`lang remove` 卸载。活体真值（改前五形）：`lang remove`／`lang remove x`／
// `lang uninstall`／`lang del zh`／`lang rm` 一律只回「lang 只有 add 子命令：…」——装上的用户包
// 只能自己猜路径去删文件。
test "第 330 轮 T0 lang remove：四类回执＋词表＋扩展名单源（D189）" {
    const gpa = std.testing.allocator;

    // A1 词表：remove 进表且精确命中不算近似；`removes`/`remov` 走建议。
    try std.testing.expectEqual(@as(?[]const u8, null), nearWord(lang_verb_remove, &lang_verbs));
    try std.testing.expectEqualStrings(lang_verb_remove, nearWord("removes", &lang_verbs).?);

    // A2 四类回执：各自插值到自己的位置（张冠李戴即在此红）。
    const ok_msg = try std.fmt.allocPrint(gpa, msg_lang_remove_ok, .{ "mine", "dir", "mine" });
    defer gpa.free(ok_msg);
    try std.testing.expect(std.mem.indexOf(u8, ok_msg, "「mine」") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok_msg, "dir/mine" ++ zzc.pack_ext) != null);
    const abs_msg = try std.fmt.allocPrint(gpa, msg_lang_remove_absent, .{"mine"});
    defer gpa.free(abs_msg);
    try std.testing.expect(std.mem.indexOf(u8, abs_msg, "未安装") != null);
    try std.testing.expect(std.mem.indexOf(u8, abs_msg, "zzc lang") != null);
    const bi_msg = try std.fmt.allocPrint(gpa, msg_lang_remove_builtin, .{ "简体", "zh" });
    defer gpa.free(bi_msg);
    try std.testing.expect(std.mem.indexOf(u8, bi_msg, "「简体」") != null);
    try std.testing.expect(std.mem.indexOf(u8, bi_msg, "内置包") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_remove_usage, "zzc lang remove") != null);

    // A3 三话术语义不得混：回执含「✔」/未装含「未安装」/内置含「不能移除」，互不越界。
    try std.testing.expect(std.mem.indexOf(u8, ok_msg, "未安装") == null);
    try std.testing.expect(std.mem.indexOf(u8, abs_msg, "✔") == null);
    try std.testing.expect(std.mem.indexOf(u8, bi_msg, "✔") == null);

    // A4 面表五针：分派＋四类拒绝（回执/未装/内置/叠加层）。
    try std.testing.expectEqual(@as(usize, 5), lang_remove_face.len);

    // A5 用法串与动词清单同源自证：扩表后建议话术若仍只教 add，此二断言即红（真跑曾实测
    // `lang remov` 建议 remove 却给出 add 的用法）。清单文本亦须逐字派生于表。
    try std.testing.expect(std.mem.indexOf(u8, lang_verbs_usage, "zzc lang add") != null);
    try std.testing.expect(std.mem.indexOf(u8, lang_verbs_usage, "zzc lang remove") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg_lang_verb_near, lang_verbs_usage) != null);
    try std.testing.expectEqualStrings("add／remove", lang_verb_list_text);

    // A6 叠加层话术：与 D187 的 `--lang` 提示同源（同一 overlayHint 判据），且不得混成「未安装」。
    const ov_msg = try std.fmt.allocPrint(gpa, msg_lang_remove_overlay, .{ "繁體", "zh", "繁体字形" });
    defer gpa.free(ov_msg);
    try std.testing.expect(std.mem.indexOf(u8, ov_msg, "「繁體」") != null);
    try std.testing.expect(std.mem.indexOf(u8, ov_msg, "「zh」") != null);
    try std.testing.expect(std.mem.indexOf(u8, ov_msg, "繁体字形") != null);
    try std.testing.expect(std.mem.indexOf(u8, ov_msg, "不能单独移除") != null);
}
