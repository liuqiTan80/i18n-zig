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
