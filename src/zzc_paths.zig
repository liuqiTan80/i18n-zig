//! zzc **内部状态/产物路径族的唯一真值**（第 200 轮 D68）。
//!
//! 旧形制下同一 `.zzc` 目录族由 4 个模块 6 处字面量各持一份：生成树 `cli/args.zig` 的 `gen_dir`（199 轮
//! 已收）、符号表 `main.zig` 的 `symbols_path_default`、产物目录 `main.zig` 的 `.zzc/bin` 两枚（发射路径 +
//! `createDirPath`）、深检临时发射物 `main.zig` 的 `-femit-bin=.zzc/tmp_check_root`、外置语言包
//! `lang/userpack.zig` 的 `default_dir`。而**消费这些路径的隐藏判据** `diag/translate.zig` 的
//! `isInternalPath` 只以裸子串 `".zzc"` 硬编在另一个模块里——族与判据之间没有任何引用关系。
//!
//! 后果：族改名（或新增内部目录）时，zig 报出的生成路径不再被隐藏，直接把与机器相关的内部位置
//! 泄给方言用户（台账 B1 同族泄漏面）。t2 探针实锤（`.scratch200/probe200.sh`）：
//! - P1 把写侧族名整体改为 `_zzc/gen`（含本模块全部字面量钉，34 处）而隐藏判据不动 → **502/502 全绿**；
//! - P2 只把隐藏判据的字面量 `".zzc"` 改一个字符 → 500/502 红（族**值**侧确有独立钉，197 轮推论一的旁证）；
//! - P3 把判据收窄为只认 `".zzc/gen"`（符号表/产物/包目录/临时发射物就此不再隐藏）→ **502/502 全绿**。
//! 即：族内成员是否被隐藏、以及写侧与隐藏侧的耦合，两条都无测可抓。
//!
//! 治法：族成员一律由本模块的 `root` 派生（拼接在编译期完成、产物字节不变），消费侧（隐藏判据）改取
//! `root`；跨模块耦合面由 `diag/translate.zig` 的「写侧产物 → 隐藏判据」组合锚钉住（同 199 轮 D67 的
//! 形制：配对契约经函数组合可锚，纯同值引用不可锚）。
//!
//! 第 201 轮 D69 并入**方言工程布局族**（`src` 目录段 / `main` 入口词干 / `.zz` 扩展名 / 默认入口全串）：
//! 与 `.zzc` 族同属「一名多点硬编、失配不报错只错位」的字面量族，只是域不同——上族是**我方内部落盘**，
//! 本族是**用户工程约定**。旧形制七处字面量散在 3 模块：入口选择 `cli.pickEntry` 的后缀判据与默认入口
//! 两枚、embed 资产豁免判据一枚（以上 199/200 前后皆有钉）、`main.cmdInit` 写盘入口名 `"{s}/src/main.zz"`、
//! `main.cmdEject` 硬编入口 `"src/main.zz"`、`main` 采集器后缀判据 `".zz"` 三枚 **零钉**（t2 探针 P2/P3/P4
//! 单点破坏后 505/505 全绿）。后果面是写/读配对契约断裂：`cmdInit` 按自己的字面量建工程、`pickEntry`
//! 按另一枚字面量认工程，两者一旦漂移，新建工程跑 `zzc run`/`zzc check` 即报「找不到工程目录/未找到
//! 方言源文件」——报错指向目录而非指向失配的字面量，用户无从看出是自己用法问题还是工具坏了。

const std = @import("std");

/// zzc 内部状态/产物目录的根（相对当前工作目录）。正斜杠形，Windows 亦接受（`userpack` 旧注已证）。
pub const root: []const u8 = ".zzc";

/// 生成树目录：方言源转译为 .zig 的落点根（`cli.genPathFor` 的产出前缀、`stageEmbedAssets` 的镜像根）。
pub const gen_dir: []const u8 = root ++ "/gen";

/// 生成树内路径的前缀（含尾分隔符）：剥侧据此切掉目录段，「前缀串」与「前缀长度」自此同源。
pub const gen_dir_prefix: []const u8 = gen_dir ++ "/";

/// 产物目录：`zzc build` 的可执行文件落点（zig 不自建目录，发射前须 `createDirPath` 同一真值）。
pub const bin_dir: []const u8 = root ++ "/bin";

/// 外置语言包安装目录（`--lang-file` 装包后的落点，`userpack.default_dir` 即本值的公开面）。
pub const lang_dir: []const u8 = root ++ "/lang";

/// 符号表文件：跨会话稳定的母语名 → ASCII 名映射（D16/D36 语义，恢复失败须传播）。
pub const symbols_file: []const u8 = root ++ "/symbols.txt";

/// `check` 深检时各根的临时发射物（用后即弃、固定同名串行覆盖）。
pub const check_root: []const u8 = root ++ "/tmp_check_root";

/// 上者的完整 zig 旗标形（`-femit-bin=` 前缀与路径同源，不另立字面量）。
pub const check_root_flag: []const u8 = "-femit-bin=" ++ check_root;

/// 方言源码扩展名（采集器筛源文件、入口选择判据、embed 资产豁免判据三处共用的唯一真值，第 201 轮 D69）。
pub const dialect_ext: []const u8 = ".zz";

/// 方言工程的源码目录段（相对工程根）。
pub const src_dir: []const u8 = "src";

/// 默认入口的文件词干（`zzc init` 建的就是它，`pickEntry` 缺省也认它）。
pub const entry_stem: []const u8 = "main";

/// 默认入口全串 = `src/main.zz`：由上三枚派生，故 `cmdInit` 的写侧与 `pickEntry` 的读侧自此同源。
pub const default_entry: []const u8 = src_dir ++ "/" ++ entry_stem ++ dialect_ext;

/// 路径是否为方言源文件（采集器筛源、入口选择、embed 资产豁免三处判据的唯一真值，第 201 轮 D69）。
/// 纯后缀比较，与旧形制 `std.mem.endsWith(u8, p, ".zz")` 逐字节等价——本轮只收敛真值、不改判据宽度。
/// （故 `.zz` 这种「只有扩展名没有词干」的怪名仍算命中，与漂移前行为一致，非本轮引入。）
pub fn isDialectSource(p: []const u8) bool {
    return std.mem.endsWith(u8, p, dialect_ext);
}

/// `zzc init <name>` 建的入口路径 = `<name>/src/main.zz`（第 201 轮 D69）：写侧由本函数持唯一构造，
/// 读侧（`pickEntry`/采集器）由 `default_entry`/`isDialectSource` 持同一真值，两侧不再各写字面量。
pub fn initEntryPathFor(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ name, default_entry });
}

test "第 200 轮 T0 .zzc 族单一真值：八枚字面量全员钉 + 形制契约（相对、正斜杠、前缀多一个分隔符）" {
    // A1 族真值逐枚字面量钉（判据不复用常量，遵 196/197 通则）：改本模块任一枚即本钉红，
    //    连带要求消费/生产两侧与 `diag/translate.zig` 的组合锚同步复跑。
    try std.testing.expectEqualStrings(".zzc", root);
    try std.testing.expectEqualStrings(".zzc/gen", gen_dir);
    try std.testing.expectEqualStrings(".zzc/gen/", gen_dir_prefix);
    try std.testing.expectEqualStrings(".zzc/bin", bin_dir);
    try std.testing.expectEqualStrings(".zzc/lang", lang_dir);
    try std.testing.expectEqualStrings(".zzc/symbols.txt", symbols_file);
    try std.testing.expectEqualStrings(".zzc/tmp_check_root", check_root);
    try std.testing.expectEqualStrings("-femit-bin=.zzc/tmp_check_root", check_root_flag);

    // A2 形制契约（独立 oracle、不引常量）：族成员必须是**相对**路径且用正斜杠——
    //    绝对形会让 `isInternalPath` 走前导分隔符臂而掩盖真实判据、反斜杠形在 Windows 上与
    //    zig 归一后的路径比较错位；`gen_dir_prefix` 必为 `gen_dir` 加一个分隔符。
    for ([_][]const u8{ root, gen_dir, gen_dir_prefix, bin_dir, lang_dir, symbols_file, check_root }) |p| {
        try std.testing.expect(!std.fs.path.isAbsolute(p));
        try std.testing.expect(std.mem.indexOfScalar(u8, p, '\\') == null);
    }
    try std.testing.expectEqual(@as(usize, 1), gen_dir_prefix.len - gen_dir.len);
}

test "第 201 轮 T0 方言工程布局族：四枚字面量全员钉 + 入口构造真形 + 形制契约" {
    // A1 族真值逐枚字面量钉（判据不复用常量，遵 196/197 通则）：任一枚漂移即本钉红，
    //    连带要求 `cli.pickEntry`/`main` 采集器/`cmdInit` 与 201 T1 的往返锚同步复跑。
    try std.testing.expectEqualStrings(".zz", dialect_ext);
    try std.testing.expectEqualStrings("src", src_dir);
    try std.testing.expectEqualStrings("main", entry_stem);
    try std.testing.expectEqualStrings("src/main.zz", default_entry);

    // A2 写侧构造真形（独立字面量、不引常量）：`zzc init myapp` 落在 `myapp/src/main.zz`。
    const gpa = std.testing.allocator;
    const p = try initEntryPathFor(gpa, "myapp");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("myapp/src/main.zz", p);

    // A3 形制契约（独立 oracle）：布局族成员是**用户工程内**的相对路径，绝不含我方内部根——
    //    若 `src` 或 `default_entry` 被误改成 `.zzc/…` 形，`isInternalPath` 会把用户源码路径整体隐藏。
    for ([_][]const u8{ dialect_ext, src_dir, entry_stem, default_entry }) |q| {
        try std.testing.expect(!std.fs.path.isAbsolute(q));
        try std.testing.expect(std.mem.indexOfScalar(u8, q, '\\') == null);
        try std.testing.expect(std.mem.indexOf(u8, q, root) == null);
    }
}
