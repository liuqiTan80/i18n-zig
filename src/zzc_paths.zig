//! zzc **内部状态/产物路径族的唯一真值**（第 200 轮 D68）。
//!
//! 旧形制下同一 `.zzc` 目录族由 4 个模块 6 处字面量各持一份：生成树 `cli/args.zig` 的 `gen_dir`（199 轮
//! 已收）、符号表 `main.zig` 的 `symbols_path_default`、产物目录 `main.zig` 的 `.zzc/bin` 两枚（发射路径 +
//! `createDirPath`）、历史深检临时发射物路径（D129 起 check 改 `-fno-emit-bin`，不再落盘）、外置语言包
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
//!
//! 第 202 轮 D70 再并**忽略面**一维：族根（`.zzc`、`logs`）改名、或仓根 `.gitignore` 删掉对应条目，两侧都
//! 不报错也不转红，只让我方落盘的产物从此出现在 `git status` 里（脏工作树、易被误提交）。旧形制下该耦合
//! 仅在 197 轮 T1 的注释里被**口头声明**为既有依赖（「`.gitignore` 以 `logs/` 条目兼容」）而全仓无任何测读过
//! 该文件。t2 探针实锤（`.scratch202/probe202.sh`）：P1 把 `logs` 整体改名（含 5 枚字面量钉同步）→ 509/509
//! 全绿；P2 删 `.gitignore` 的 `logs/` 条目 → 全绿；P3 把 `**/.zzc/` 改名 → 全绿且测数行为**空**（该文件不是
//! source dependency，`zig build test` 直接复用旧测试二进制、根本不重跑）；P4 只改真值 → 3 红（值侧原有钉）。
//!
//! 治法分两段（受一条硬约束所迫，本轮实跑坐实）：`@embedFile` 在 zig 0.17 里被 module **包路径**拦住——包路径
//! 即模块根源文件所在目录（`src/`），`@embedFile("../.gitignore")` 无论走 build 系统还是直跑 `zig test` 都报
//! `embed of file outside package path`，故「编译期内嵌忽略面」不可行；而测试图内 `cwd()` 运行期读盘虽能读到，
//! 却复制 P3 的失效形制（运行期偷读的文件不入步骤清单，改它不会触发重跑＝假绿）。于是：
//! - **值与形制**入测试图：本模块持落盘族清单 `disk_family` 与纯判据 `dirIgnored`，T0 钉住族根值、清单形制
//!   （全员相对、正斜杠、首段必落在族根集内）与判据边界（三形目录规则各一枚命中、注释/无尾斜杠/近名/空输入不命中）；
//!   `main.zig` 的 202 T1 钉住「真实落盘默认路径的目录段 ∈ `disk_family`」——生产侧产物入清单，不留漏项通道。
//! - **跨文件覆盖**入构建守卫：`zig build check-ignore-coverage`（并挂在 `test` 步上，CI 即跑）以
//!   `Run.addFileArg(b.path(".gitignore"))` 声明文件依赖——内容变更进步骤清单、必重跑；程序吃真忽略面对
//!   `disk_family` 全员assert覆盖、并对源码目录 assert 不被覆盖。此即本仓既有的「跨文件同步守卫」形制
//!   （154/155 轮 `check-editor-syntax`/`check-editor-snippets` 同构），探针 P2/P3 从此在该通道转红。

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

/// 语言包文件扩展名（第 237 轮 D105）：`userpack.fileRel` 拼出的安装落点名 `<dir>/<key>.txt`
/// 与 `main.cmdLangAdd` 成功/已存在两处提示文案里宣称的落点路径形共用的唯一真值。旧形制下
/// 这枚 `.txt` 分散内联硬编在 `lang/userpack.zig` 的 `fileRel`（`"{s}/{s}.txt"`·写/读侧唯一变换）
/// 与 `main.zig` 两枚 `printOut`/`printErr` 文案（`{s}/{s}.txt`·用户照此定位/删除文件）三处互不引用：
/// t2 探针 P1 实锤独漂 main 两文案路径形（`.txt`→`.PACKEXT`）而 fileRel 不动 → 整清缓存 fresh
/// 611/611 全绿静默，真跑 `zzc lang add` 成功文案宣称落点 `…/tst-ja.PACKEXT`、实际写入（且 `--lang`
/// 经 fileRel 读取）却是 `…/tst-ja.txt`——文案指错文件名的活路径可观测断裂（P2 对照：独漂 fileRel
/// 值 → 其自照形制测转红，证值侧本有钉而文案↔落盘耦合面零锚）。本枚落地后三处皆由它派生、
/// 单边漂移不可能（`--lang` 选用仍走 fileRel 精确路径·无 glob 枚举，扩展名漂移不改读侧命中）。
pub const pack_ext: []const u8 = ".txt";

/// 内置默认语言包（`zh` 包·包内 `# @default` 所指）的**词干**（第 238 轮 D106）。
/// 旧形制下这枚文件名 `中文.txt` 被 **42 处** `@embedFile`（`src/root.zig`/`main.zig` 的 src 形、
/// `diag`/`transpiler`/`editor`/`lsp` 各模块的 child 形、`lang/pack.zig` 测试的 lang 形）连同
/// `build.zig` 两枚 `addFileArg` 与两枚 `gen-*-main` 的 emit 缺省包路径共 **46 处**按**文件名**各自
/// 内联手抄、无一共同真值；而 `registry` 依包内 `# @default` **内容指令**发现默认包（`build.zig` 扫描
/// 生成 `pack_registry` 模块、默认包恒置 `entries[0]`），与上述**按名认包**的 embed/资产面**无对拍**。
/// 后果：移动 `# @default`（或增第二基包设默认）时，产品默认（走 registry 内容）与编辑器资产/内嵌默认
/// （走 build.zig/`@embedFile` 硬编文件名）**静默分道**——`root.zig` 导出的 `zh_pack_bytes`（按名 embed）
/// 与 `registry.defaultEntry().bytes`（按内容发现）一旦不等也无任何测交叉。t2 探针实锤（`.scratch238/`）：
/// P1 把 `root.zig` 的 embed 目标 `中文.txt`→`繁体.txt` → 整清缓存 fresh 615/615 全绿（导出零消费·无锚）；
/// P3 把 `gen_tmlang_main` 的 emit 缺省包路径改 `繁体.txt` → CI 不可见绿（check 模式吃 build.zig `addFileArg`
/// 传参、缺省值不被触发；emit 手工活路才读错包）。本族落地后文件名只存于此处、四形 embed 与 cwd 形皆派生，
/// 并由 `root.zig` 的 238 T1 内容↔名字一致性锚 + `build.zig` 对面十一 needle 双向钉死，名字默认与内容默认
/// 不再可能单边漂移。
pub const builtin_pack_stem: []const u8 = "中文";

/// 内置默认语言包文件名 = 词干 + 包扩展名（`zh` 包·`# @default` 所指·与 `pack_ext` 同源）。
pub const builtin_pack_file: []const u8 = builtin_pack_stem ++ pack_ext;

/// 语言包目录相对 `src/` 的路径段（`src/root.zig`、`src/main.zig` 层的 embed 前缀）。
const packs_subpath_from_src: []const u8 = "lang/packs/";

/// `src/` 层 embed 相对形（`src/root.zig`、`src/main.zig` 的 `@embedFile`）：`lang/packs/中文.txt`。
pub const builtin_pack_embed_src: []const u8 = packs_subpath_from_src ++ builtin_pack_file;

/// `src/*/` 子层 embed 相对形（`diag`/`transpiler`/`editor`/`lsp` 各模块）：`../lang/packs/中文.txt`。
pub const builtin_pack_embed_child: []const u8 = "../" ++ builtin_pack_embed_src;

/// `src/lang/` 层 embed 相对形（`lang/pack.zig` 测试）：`packs/中文.txt`。
pub const builtin_pack_embed_lang: []const u8 = "packs/" ++ builtin_pack_file;

/// 仓根 cwd 相对形（`build.zig` 的 `addFileArg`／`gen-*-main` 的 emit 缺省包路径）：`src/lang/packs/中文.txt`。
pub const builtin_pack_cwd_rel: []const u8 = src_dir ++ "/" ++ builtin_pack_embed_src;

/// 一次对面核对项（needle 与「分道即何为」说明）：`machine_matcher` 的 `checkFace` 以 anytype 只读
/// `.needle`/`.why` 两字段、跨 hub 复用同一判据（同 `lang_identity.FaceCheck` 形制，不另立第三套搜索逻辑）。
/// 应现枚数 `occ` 缺省 1（presence 语义不变）；第 321 轮 D180 与 pack.FaceCheck／jsonrpc／lang_identity／
/// vsix 四面族对齐补上该字段——双址以上之针可显式要 2、3 枚，守卫不再只看「在不在」。
pub const BuildFace = struct { needle: []const u8, why: []const u8, occ: usize = 1 };

/// 从面针 `.why` 文里解析**声明的址数**（「双址/两址」→2、「三址」→3、「四址」→4…；未声明返
/// null 即 presence 语义 1）。第 322 轮 D181 立、第 323 轮 D182 从 `cli.args` 提到本 hub——六个面型
/// 族（`BuildFace`／`lsp_config.FaceCheck`／`pack.FaceCheck`／`lang_identity`／`jsonrpc`／`vsix`）的
/// 名实闸由同一判据核；判据本体放此处而不放守卫，守 203 轮「判据入 hub、守卫只做 I/O」。
/// 为何解析数字而非检固定字样：措辞从「四址」改「三址」而 `occ` 未随动必须红，只认「双址」会漏。
pub fn declaredAddrCount(why: []const u8) ?usize {
    // 数组＋具名字段（元组的 `pr[0]` 是 comptime 索引，运行期循环里取报 "unable to resolve comptime value"）。
    // 长形优先（第 326 轮 D185 自纠）：`十五址` 含子串 `五址`、`十三址` 含 `三址`，若按短形在前
    // 逐条 indexOf，多址声明会被短档抢先命中——扩到十五址时守卫报「声明十五址而 occ=15 不符」
    // （实际解析成 5）。故按字数从多到少排列，长形先匹。
    const pairs = [_]struct { word: []const u8, n: usize }{
        .{ .word = "二十四址", .n = 24 }, // 第 331 轮 D190：relocalize 两臂并入（且须先于「十四址」——否则 24 被解成 14）
        .{ .word = "二十二址", .n = 22 }, // 第 330 轮 D189：lang remove 五臂并入（长形仍须先匹）
        .{ .word = "二十一址", .n = 21 },
        .{ .word = "十七址", .n = 17 },
        .{ .word = "十六址", .n = 16 },
        .{ .word = "十五址", .n = 15 },
        .{ .word = "十四址", .n = 14 },
        .{ .word = "十三址", .n = 13 },
        .{ .word = "十二址", .n = 12 },
        .{ .word = "十一址", .n = 11 },
        .{ .word = "十址", .n = 10 },
        .{ .word = "九址", .n = 9 },
        .{ .word = "八址", .n = 8 },
        .{ .word = "七址", .n = 7 },
        .{ .word = "六址", .n = 6 },
        .{ .word = "五址", .n = 5 },
        .{ .word = "四址", .n = 4 },
        .{ .word = "三址", .n = 3 },
        .{ .word = "双址", .n = 2 },
        .{ .word = "两址", .n = 2 },
    };
    for (pairs) |pr| {
        if (std.mem.indexOf(u8, why, pr.word) != null) return pr.n;
    }
    return null;
}

/// 对面二十一·`build.zig` 的内置默认包 `addFileArg` 路径（第 238 轮 D106）：`build.zig` 系构建脚本独立
/// 编译单元、无法 `@import` 本 hub，故 needle 由 `builtin_pack_cwd_rel` 派生、守卫读 `build.zig` 逐字节对账——
/// 把两枚 `addFileArg(b.path("src/lang/packs/中文.txt"))` 钉到 hub 真值，改任一侧即分道转红（同 D78
/// `buildDeclaresExe`／D94 `ps1_face` 的「读 build.zig/外部文件、needle 派生自 hub」形制）。
pub const build_pack_face = [_]BuildFace{
    .{ .needle = "addFileArg(b.path(\"" ++ builtin_pack_cwd_rel ++ "\"))", .why = "build.zig 声明给编辑器生成物守卫的语言包输入路径须与内置默认包真值同源，分道即 committed 资产按旧包名生成而产品默认已换包（资产与默认包静默失联）" },
};

/// 符号表文件：跨会话稳定的母语名 → ASCII 名映射（D16/D36 语义，恢复失败须传播）。
pub const symbols_file: []const u8 = root ++ "/symbols.txt";
/// 符号缓存首行头前缀（第 332 轮 D191）：紧跟词表指纹的十六进制。旧缓存无此头即视为
/// 与当前词表不配、整表作废——见 `main.loadSymbols` 与 `Pack.fingerprint`。
pub const symbols_pack_head: []const u8 = "# @pack ";

/// 历史深检临时发射物路径（D129 起 `check` 改 `-fno-emit-bin`，不再落盘；保留在隐藏判据/族清单中，
/// 旧工程遗留的该路径仍不得外泄为诊断）。
pub const check_root: []const u8 = root ++ "/tmp_check_root";

/// zig 产物发射旗标前缀（第 224 轮 D92：`cmdBuild` 的 `-femit-bin={s}` argv 拼装模板由它
/// 派生；旧完整旗标派生形随 D129 改 `-fno-emit-bin` 删除）。
pub const emit_bin_prefix: []const u8 = "-femit-bin=";

/// 未翻译清单落盘目录的根（相对当前工作目录）——与 `root` 并列的**第二族根**（第 202 轮 D70）：
/// `root` 树是我方内部状态/产物（对用户隐藏），本树是**用户/CI 可见的产出面**（语言包作者与 CI 在仓外
/// 读该清单）。旧形制下该目录段只存于 `pure_filter.default_log_path` 一枚字面量里，而它与仓根
/// `.gitignore` 的 `logs/` 条目构成跨文件耦合：改目录段（或删忽略条目）都不报错，只让我方落盘产物
/// 从此出现在 `git status` 里（脏工作树、易被误提交）。t2 探针实锤（`.scratch202/probe202.sh`）：
/// P1 把 `logs` 整体改为 `logz`（连同 197/198 四轮共 5 枚字面量钉同步）→ **509/509 全绿**；
/// P2 删除 `.gitignore` 的 `logs/` 条目 → **全绿**；P3 把 `**/.zzc/` 改名为 `**/zzcx/` → **全绿**；
/// P4 只改真值不改钉 → 3 红（值侧原有钉，本轮新增的是**忽略面耦合**防线）。
/// 即：两侧任一脱离都不报错、不转红，全仓无任何测试读过 `.gitignore`。
pub const logs_dir: []const u8 = "logs";

/// 未翻译清单文件名（`logs_dir` 下的落点名；`pure_filter.default_log_path` 自此派生，第 197 轮 D64 的公开面位置不动）。
pub const log_file_name: []const u8 = "untranslated_phrases.json";

/// eject 缺省导出目录名（不带 `[目录]` 参数时的落点，第 213 轮 D81）：同值字面量散在
/// `main.zig` 缺省 dest 与报错文案示例、`cli/args.zig` usage「默认 standard/」与仓根
/// `.gitignore` 的 `**/standard/` 条目四处互不引用——t2 探针 P1 改缺省 dest → 559/559 全绿
/// （真跑 eject 落 `stan-d/` 而 usage/忽略面分道）、P3 删忽略条目 → 守卫恒 OK（旧清单不含本员）。
pub const eject_default_dest: []const u8 = "standard";

/// `zzc relocalize` 缺省输出目录名（不带 `[目录]` 参数时的落点）：与 `eject_default_dest`
/// 同形同治——写出面必登 `disk_family`，否则守卫核对集漏掉该产物、忽略面独漂零信号。
pub const relocalize_default_dest: []const u8 = "relocalized";

/// 我方**落盘族**全员（第 202 轮 D70）：凡我方会在工程根写出的目录/文件路径都须列在此处，
/// 由 `zig build check-ignore-coverage` 逐个核对是否被仓根 `.gitignore` 覆盖——清单本身是守卫的输入，
/// 故新增成员即自动进入覆盖核对；测试图另以「首段必落在族根集内」钉住其形制（202 T0 A2）。
pub const disk_family = [_][]const u8{
    root,
    gen_dir,
    gen_dir_prefix,
    bin_dir,
    lang_dir,
    symbols_file,
    check_root,
    logs_dir,
    logs_dir ++ "/" ++ log_file_name,
    // 第 213 轮 D81：在工程根跑不带参数的 `zzc eject` 会写出本目录——旧形制下它只在
    // `.gitignore` 里以 `**/standard/` 孤立存在、不在核对集内，删该行守卫恒绿而产物入 `git status`。
    eject_default_dest,
    // `zzc relocalize` 的缺陷落点（同形同治：他方方言的工程副本，可由命令再生）。
    relocalize_default_dest,
};

/// 源码面（忽略面**不得**吞掉的成员，第 202 轮 D70）：我方自己仓里的源码目录与语言包目录——与方言布局族
/// 同名同形（我方吃自己的狗食），若有人为「消脏」把它们加进忽略条目，源码/语言包就不再入库。
pub const source_family = [_][]const u8{
    src_dir,
    src_dir ++ "/lang/packs",
};

/// 方言源码扩展名（采集器筛源文件、入口选择判据、embed 资产豁免判据三处共用的唯一真值，第 201 轮 D69）。
pub const dialect_ext: []const u8 = ".zz";

/// 标准 Zig 源扩展名——转译后 `@import` 目标与 `genPathFor` 落盘文件名的两处共用唯一真值（第 234 轮 D102）。
/// 旧形制下这枚 `.zig` 分散硬编在 `transpiler/translate.zig`（导入改写的替换形 `.zig"`，而该模块根本不 import 本 hub）
/// 与 `cli/args.zig` 的 `genPathFor`（`{s}.zig` 输出名）两处，与 `dialect_ext` 无任何引用关系。t2 探针 P1 实锤：
/// 合规重命名 `dialect_ext`（`.zz`→`.zv`）后，12 枚 hub 消费测红、而改写侧与落盘侧因不引 hub **恒绿**——真跑
/// `导入("lib.zv")` 不被改写（仍找旧 `.zz"`）而 `genPathFor` 落盘 `lib.zig`，生成码 `@import("lib.zv")`「找不到要导入的模块」。
/// 本枚与下面两枚派生后缀落地后，两侧皆由 hub 单源派生、扩展名对不再可能单边漂移。
pub const std_ext: []const u8 = ".zig";

/// 导入参数字符串 token 里的方言扩展名后缀（= `dialect_ext` 并入闭引号 `"`）：改写**匹配形**唯一真值。
pub const dialect_import_suffix: []const u8 = dialect_ext ++ "\"";

/// 导入参数改写后的标准扩展名后缀（= `std_ext` 并入闭引号 `"`）：改写**替换形**唯一真值，与 `genPathFor` 落盘名同源。
pub const std_import_suffix: []const u8 = std_ext ++ "\"";

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

/// 毕业工程（`zzc eject`）写侧产物名：标准 Zig 构建脚本（第 204 轮 D72）。旧形制在写侧、提示文案、
/// `.paths` 清单三处各持一枚同值字面量，而写侧那枚**全仓零钉**（t2 探针 P1 实测：改名后 226/226 全绿、
/// 真跑 eject 产出的毕业树里根本没有 `build.zig`，`zig build` 验证随即失败）。
pub const out_build_zig: []const u8 = "build.zig";

/// 毕业工程包清单名（写侧、读 fingerprint 的读侧、提示文案、`.paths` 清单四处共用的唯一真值，第 204 轮 D72）。
/// 写侧与读侧原系两份同体字面量：任一侧单独漂移就静默打断「重复 eject 复用既有 fingerprint」的幂等路径。
pub const out_build_zon: []const u8 = "build.zig.zon";

/// 毕业包 `.paths` 须收录的 dest 顶层成员集（由族真值派生，第 204 轮 D72）：写侧落盘名与清单条目取自
/// 同一集合，杜绝「文件写成了 A 而清单列的是 B」；`src_dir` 入列即导出树目录（亦是 eject 清理侧的目标）。
pub const out_paths_family = [_][]const u8{ out_build_zig, out_build_zon, src_dir };

/// 毕业工程 dest 下的产物路径构造（写侧、读侧、陈旧清理侧共用的唯一变换，第 204 轮 D72）。
pub fn ejectPathFor(alloc: std.mem.Allocator, dest: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest, name });
}

/// 毕业工程 `build.zig.zon` 的 `.name` 字段赋值前缀 token（第 232 轮 D100）：写侧 `ejectZoneText` 落的
/// `    .name = .<app>` 行与读侧 `parseFingerprintFromZone` 认读的 `.name = .` 前缀共用的唯一真值。旧形制
/// 跨 main↔args≥5 处同体手抄（写侧 emit、读侧 name_marker、189 T2 want、204 A2 fixture、parse 自测各一）、
/// 互不引用，且全仓无真 writer→parser 往返锚（t2 探针 P1 实测：协同改写侧 emit 与其 189 T2 want、独不动读侧
/// marker，`zig build test` 恒 600/600 全绿，而生产 eject 落盘 zon 与读侧认读形制静默脱钩——readExistingFingerprint
/// 恒 null、fingerprint 每次重探、build.zig.zon 逐次漂移，破坏 eject 幂等复现）。本枚为该 token 的唯一真值。
pub const zon_name_marker: []const u8 = ".name = .";

/// 毕业工程 `build.zig.zon` 的 `.fingerprint` 字段赋值前缀 token（第 232 轮 D100）：写侧 emit 的
/// `    .fingerprint = <0x..>` 与读侧认读的 `.fingerprint = 0x` 共用的字段前缀唯一真值（读侧再拼 `0x`
/// 定位十六进制值起点）。与 `zon_name_marker` 同族同治。
pub const zon_fingerprint_prefix: []const u8 = ".fingerprint = ";

/// 工具链标定基线的两级真值（第 205 轮 D73）：诊断回译标定（`cli.diag_baseline_zig`）、eject 模板写进
/// 每个毕业工程的 `.minimum_zig_version`、「无法启动 zig」提示里的版本下限、本仓 `build.zig.zon` 与 CI
/// 安装版本共用的唯一真值。旧形制四处各抄一份同值字面量、互不引用（t2 探针 P3/P4 实锤改对面与本仓 zon
/// 而 `zig build test` 恒绿），标定升代时三处静默停在旧版——毕业工程声明的下限低于生成它的工具链标定，
/// 用户按声明在旧版上构建才拿到 zig 的失败而非 zzc 的说明。
pub const zig_major: u32 = 0;

/// 标定基线次级（与 `zig_major` 同族，第 205 轮 D73）。
pub const zig_minor: u32 = 17;

/// 系列串 `0.17`（人读提示用「Zig {s}+」的版本下限形，第 205 轮 D73）：由上两枚派生，不再手抄。
pub const zig_series: []const u8 = std.fmt.comptimePrint("{d}.{d}", .{ zig_major, zig_minor });

/// 完整串 `0.17.0`（zon 的 `.minimum_zig_version` 与 CI 下载 URL 的版本形，第 205 轮 D73）：
/// 由同一对真值派生，故与 `zig_series` 不可能分道。
pub const zig_version: []const u8 = std.fmt.comptimePrint("{d}.{d}.0", .{ zig_major, zig_minor });

/// CI 安装段的定位标记 `download/0.17.0/`（对面判据的唯一形制来源，第 205 轮 D73）。
pub const zig_download_marker: []const u8 = "download/" ++ zig_version ++ "/";

/// 程序（CLI 可执行文件）名（第 210 轮 D78）：`build.zig` 的 `addExecutable(.name)`、编辑器 `tasks_command`
/// 首词、LSP 诊断的 `source` 标注、以及全部 `zzc: ` 报错前缀共用的唯一真值。旧形制跨 build↔src 手抄多处、
/// 互不引用（t2 探针 P1 实锤：改 `build.zig` 的 exe 名 → `zig build test` 恒绿，而产出的二进制随之更名，
/// 编辑器照示例运行的 `zzc …` 与帮助/诊断里的程序名全部指向不存在的旧名——静默的功能级断裂）。
pub const prog_name: []const u8 = "zzc";

/// 报错/提示行的程序名前缀 `zzc: `（由 `prog_name` 派生，第 210 轮 D78）：全部 stderr/stdout 提示的固定
/// 起手即此一枚，杜绝「改了程序名而某条提示仍写旧名」的散点漂移。
pub const prog_prefix: []const u8 = prog_name ++ ": ";

/// `build.zig` 文本是否声明了名字恰为 `prog_name` 的可执行文件（第 210 轮 D78 的守卫判据，纯函数）。
/// 以 `.name = "<prog_name>"` 精确子串命中（尾随闭引号防 `"zzc_core"` 之类模块依赖名误算作 CLI exe）。
pub fn buildDeclaresExe(text: []const u8) bool {
    const needle = ".name = \"" ++ prog_name ++ "\"";
    return std.mem.indexOf(u8, text, needle) != null;
}

/// 产品版本真值（第 211 轮 D79）：`build.zig.zon` 的 `.version`、`zzc version` 输出、usage 抬头
/// 「方言编译器 v…」与 eject 模板写给毕业工程的 `.version` 行共用的唯一真值。旧形制四处各抄
/// 同值字面量互不引用（t2 探针 P1 改 `version_str`、P3 改本仓 zon、P4 改 usage 抬头皆恒绿静默，
/// 唯 P2 改 eject 模板被测试 want 形 literals 自照），升代时三枚出口与毕业工程继承件分道。
pub const zzc_version: []const u8 = "0.1.0";

/// usage 抬头的版本记号 `v0.1.0`（由 `zzc_version` 派生，第 211 轮 D79）：抬头「方言编译器 v…」形的唯一来源。
pub const zzc_version_token: []const u8 = "v" ++ zzc_version;

/// 本仓 `build.zig.zon` 文本是否声明了 `.version` 逐字节等于产品版本族真值（第 211 轮 D79 的守卫判据，
/// 纯函数）。首点锚定（`.version`）令其不假命中 `.minimum_zig_version` 的子串；尾引号严格全等。
pub fn zonDeclaresVersion(text: []const u8) bool {
    const needle = ".version = \"" ++ zzc_version ++ "\"";
    return std.mem.indexOf(u8, text, needle) != null;
}

/// 仓根 README（用户第一眼读的入口文档）的相对路径（第 296 轮 D155）：守卫的 addFileArg
/// needle 由此派生，文档改名不留第二处手抄。
pub const readme_path: []const u8 = "README.md";

/// 对面三十二·`README.md` 版本族 needle 清单（第 296 轮 D155）：README 以多点位手抄产品版本
/// （本模块 `zzc_version`）与工具链版本（`zig_version`/`zig_series`），而全仓门禁从不读 README——
/// t2 探针（落码前）五形注入（当前版本 0.1.0→0.2.0／基线 0.17.0→0.16.0 两处／环境表行／
/// `zzc version` 样例行／扩展 `v0.5.0`→`v0.4.0`）后 `zig fmt` 0／`zig build` 0／`zig build test`
/// 17/17／matcher OK 一律零信号，活体 `zzc version` 与 README 样例行实地分道（文档宣称 0.2.0、
/// 真跑报 0.1.0）。判据全数在此：needle 由族真值 comptime 派生，升代（改 hub）与文档独漂皆在
/// 对面转红；守卫只读文件与计枚（承 203/205/210 轮「判据入 hub、守卫只做 I/O」形制）。
/// 扩展版本族（`v0.5.0`／`zzc-dialect-0.5.0.vsix`）真值在 `package.json`，判据入 `src/vsix.zig`；
/// `zzc version` 样例行形制入 `cli/args.zig` 的 `version_line_fmt`（皆同属本对面三十二）。
pub const readme_face = [_]BuildFace{
    .{ .needle = "当前版本：`" ++ prog_name ++ " " ++ zzc_version ++ "`", .why = "README 首屏宣称的产品版本须等于 `zzc version` 出口真值——分道即用户照文档认代，看到的却是另一版号（第 296 轮 D155）" },
    .{ .needle = "**Zig `" ++ zig_version ++ "`**", .why = "工具链基线首屏声明须等于标定族真值——漂即用户装错代 zig，回译标定早警失真（D73 同族的文档侧漏员）" },
    .{ .needle = "minimum_zig_version = \"" ++ zig_version ++ "\"", .why = "README 引用本仓 zon 的声明形须与 zon 面同源——一侧改代另一侧即指错契约" },
    .{ .needle = "| **" ++ zig_version ++ "** |", .why = "环境要求表版本列——用户照表装机的落点，漂即装到不匹配版本而构建失败" },
    .{ .needle = "应输出 " ++ zig_version, .why = "`zig version` 确认行注释——自检指引的版本面，漂即自检永远对不上" },
    .{ .needle = "Zig " ++ zig_series ++ " 实测", .why = "「经本机实测」系列串声明——文档信誉锚，升代而未复测即在此转红" },
    .{ .needle = "（" ++ zig_series ++ "）", .why = "扩展前置条件里的运行期 zig 系列版本——与 PATH 上真机版本对账的第三形，漂即扩展用户备错工具链" },
};

/// 对面三十二·`build.zig` 侧命名针：README 须以 `addFileArg(b.path("<readme_path>"))` 声明为
/// 守卫的文件依赖——不声明即改 README 不触发守卫重跑（203/210/238 轮同族假绿形制）。
pub const readme_build_face = [_]BuildFace{
    .{ .needle = "addFileArg(b.path(\"" ++ readme_path ++ "\"))", .why = "README 输入路径须由 hub 的 readme_path 派生并与 build.zig 的 addFileArg 同源——分道即守卫吃旧文件名，改文档不触发重跑（文档侧恒绿静默）" },
};

/// 对面三十八·工程方案书与语言包贡献指南的路径单源（第 302 轮 D161）：两面命令样例手抄
/// `sub_*` 真值而从无针入任何通道——t2 探针（方案书 `zzc eject→emit` 全量 3 行＋README 添鬼词
/// `zzc wizard`）fmt/build/test/matcher/demos-smoke 五通道零信号实锤；守卫新增读物面须同声明
/// 文件依赖（203/210/238 轮假绿形制）。
pub const plan_doc_path: []const u8 = "docs/方案书.md";
pub const contrib_doc_path: []const u8 = "docs/contributing-lang-pack.md";

/// 对面三十八·`build.zig` 侧两枚命名针：两面皆须 `addFileArg(b.path("<hub 路径>"))` 形入 matcher 步
///——needle 由路径真值 comptime 派生，文档改名/降片两道皆红。
pub const doc38_build_face = [_]BuildFace{
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ plan_doc_path ++ "\"))", .why = "方案书须声明为守卫步文件依赖——不声明即改方案书不触发重跑，假绿形制重播（第 302 轮 D161）" },
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ contrib_doc_path ++ "\"))", .why = "contributing 指南同上形制（第 302 轮 D161）" },
};

/// 对面四十一·VS Code 扩展 README 路径单源（第 305 轮 D164）：全仓守卫从不读本文件，
/// 包线（vsix 字节同源）只锁「包↔盘」不锁「README↔真值」语义——命令词/配置键/旗标三面零针，
/// t2 探针漂后重打包即六道全绿实锤。本面新读入守卫：命令/旗标两面逆向普查添第五面。
pub const ext_readme_path: []const u8 = "editors/vscode/README.md";

/// 对面四十一·`build.zig` 侧命名针：扩展 README 须声明为 matcher 步文件依赖（步名限定形承 D73）。
pub const doc41_build_face = [_]BuildFace{
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ ext_readme_path ++ "\"))", .why = "扩展 README 须声明为守卫步文件依赖——不声明即改文档不触发重跑（第 305 轮 D164）" },
};

/// 对面四十二·AGENTS.md（AI 编码操作手册）路径单源（第 306 轮 D165）：读者是自动化工具，
/// 命令词/旗标静默漂的代价是 AI 照手册产出不可编译代码——两面九+五枚正向针与命令/旗标逆向第七面。
pub const agents_doc_path: []const u8 = "AGENTS.md";

/// 对面四十二·`build.zig` 侧命名针：AGENTS.md 须声明为 matcher 步文件依赖（步名限定形承 D73）。
pub const doc42_build_face = [_]BuildFace{
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ agents_doc_path ++ "\"))", .why = "AGENTS.md 须声明为守卫步文件依赖——不声明即改手册不触发重跑（第 306 轮 D165）" },
};

// —— demo 冒烟防线（第 297 轮 D156）——
//
// `tools/check-demos.ps1`（1265 行）的 demo↔eject 基线只在 Windows PowerShell 跑：本机
// NO_PWSH（D98/D104 判例）、GitCode CI（Euler Linux）亦无 pwsh 步——t2 探针实锤把
// `demo/hello` 的 `常数` 漂成坏词（活体 `zzc run` RC=1）后 fmt/build/test/matcher 四通道
// 一律零信号。`tools/demos-smoke.sh` 把「六枚 demo 全量可编可跑、输出逐字节对拍」落成
// bash/CI 常驻防线；下列单源面把脚本的覆盖面钉死（加 demo 忘接线、删断言臂皆转红）。

/// demo 冒烟脚本路径（CI 与守卫步共用单源）。
pub const demos_smoke_path: []const u8 = "tools/demos-smoke.sh";

/// 六枚 demo 入口全量表。**独立手设**——不可运行时自动枚举 `demo/` 生成：删一枚 demo
/// 若表随之自动缩，删除面即空转（同 240 轮 pack 护栏下限判例）；盘上目录与表的双向
/// 对账由守卫对面三十三完成（盘有表无＝ghost，表有盘无＝hidden）。
pub const demo_entries = [_][]const u8{
    "demo/hello/src/main.zz",
    "demo/multi/src/main.zz",
    "demo/nested/src/main.zz",
    "demo/syntax/src/main.zz",
    "demo/errors/src/main.zz",
    "demo/fullwidth/src/main.zz",
};

/// demo 枚数下限（独立手设，与 `demo_entries` 基数、脚本 `EXPECT_CHECKS` 锚三处互锁，
/// 承 D140 条数锚形制——任一分道即红）。
pub const demo_count_floor: usize = 6;

/// 冒烟脚本断言条数下限（第 307 轮 D166 解耦新设）：断言数与 demo 入口数是两个量——
/// 本锚 = 六枚 demo 断言（4 run＋2 diag）＋纯母语行为面 1 臂（AGENTS.md 铁律真跑验，
/// 探针实锤：拆去 main.zig 纯母语强制臂后五通道全绿而混写源报错错位成后端假语法错）
/// ＋指定语言行为面 1 臂（第 308 轮 D167：选包链被吞则恒落默认包，763 门禁全绿——
/// r9g 断言只在 ps1 通道、本机/CI 从未验证；三形互验计一臂）。
/// ＋relocalize 回程 1 臂（第 331 轮 D190：双向道的回程此前零真跑——正向 translate 有二十臂护着。
/// render 退化成恒等复制时 render 单测可全绿而产出不改词形；四断见第二十一臂注）。
/// 加臂/削臂须两处同动；与 `demo_count_floor`（入口表基数）各司两轴。
pub const smoke_assert_floor: usize = 21;

/// 不入冒烟网的 demo 目录豁免清单（独立手设，第 297 轮 D156 本闸首跑即抓到真 ghost）：
/// `demo/httpz` 系第 265 轮叠加层真依赖验证工程——`zig fetch` 外析依赖不入库（`.gitignore` 册）、
/// 直接 `zzc run` 即常驻监听 8801，不宜入 CI 冒烟；其翻译面由 `tools/lsp-live-smoke.sh` 的
/// `contrib/packs/httpz-中文.txt` overlay 悬停链钉住。本清单只免 ghost 普查，未免入口验在。
pub const demo_exempt_dirs = [_][]const u8{"httpz"};

/// 对面三十三·脚本面清单：`demo_entries` 逐枚须被冒烟脚本点名——新增 demo 忘接线
/// （盘上有、脚本无）或脚本改名分道即红；needle 全由 `demo_entries` comptime 派生。
pub const demos_smoke_face = blk: {
    var faces: [demo_entries.len]BuildFace = undefined;
    for (demo_entries, 0..) |entry, i| {
        faces[i] = .{ .needle = entry, .why = "demo 入口「" ++ entry ++ "」须被冒烟脚本点名接线——盘有表无即新增 demo 静默脱闸（第 297 轮 D156）" };
    }
    break :blk faces;
};

/// 对面三十三·脚本条数锚针：`EXPECT_CHECKS` 的值段由 `demo_entries` 基数 comptime 派生
/// ——削一条断言臂而锚不动即脚本自身退坡闸红，改锚不改臂亦红（守卫面再交叉对账）。
pub const demos_smoke_count_face = [_]BuildFace{
    .{ .needle = "EXPECT_CHECKS=" ++ std.fmt.comptimePrint("{d}", .{smoke_assert_floor}), .why = "脚本条数锚须等于 hub 断言下限——分道即断言臂被削或臂数脱钩（承 D140 空转防线判例，第 297 轮 D156；第 307 轮 D166 解耦：断言数不再等同入口表基数，纯母语行为面添臂）" },
};

// —— 对面四十四·指定语言行为面 fixture 路径单源（第 308 轮 D167）——
//
// 第八臂（语言指定三形互验）须手抄两枚 fixture 路径；r9g 旧形只在 ps1 里写死，而 ps1 本机/CI
// 从不跑（D156 判例）——Linux 通道首次接此行为面即在 paths 立单源，脚本手抄侧由守卫胶合。

/// 日语最小方言工程源（对应 `ja_fixture_pack_path` 的映射；ps1 r9g 同用此件）。
pub const ja_fixture_src_path: []const u8 = "tools/fixtures/proj-ja/src/main.zz";

/// 最小合规外部发行包（B6 契约 13 值，`$code = tst-ja`；不入 packs 扫描面）。
pub const ja_fixture_pack_path: []const u8 = "tools/fixtures/external-min.txt";

/// 第三方库叠加包（`--lang-overlay` 轴真值件；第 309 轮 D168 第九臂正形/映射源；lsp-live 亦用此件）。
pub const overlay_pack_path: []const u8 = "contrib/packs/httpz-中文.txt";

/// 对面四十五·`build.zig` 侧第 24 片命名针：叠加包须声明为守卫步文件依赖（run 时读盘对映射）。
pub const doc45_build_face = [_]BuildFace{
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ overlay_pack_path ++ "\"))", .why = "叠加包须声明为守卫步文件依赖——不声明即改包不触发重跑、对面四十五吃旧文（第 309 轮 D168）" },
};

/// 第八/九臂手抄路径与 hub 单源胶合：脚本文本须逐枚含三枚路径字面——fixture/叠加包改名而脚本漏随即红。
pub const lang_smoke_face = [_]BuildFace{
    .{ .needle = ja_fixture_src_path, .why = "第八臂正形源路径须与 hub 单源同形——分道即 cp 吃旧路径、臂假红/假绿（第 308 轮 D167）" },
    .{ .needle = ja_fixture_pack_path, .why = "第八臂包文件路径须与 hub 单源同形——同上" },
    .{ .needle = overlay_pack_path, .why = "第九臂叠加包路径须与 hub 单源同形（第 309 轮 D168）——分道即 eject 吃旧包、四形假绿" },
};

/// 对面三十三·`build.zig` 侧命名针：脚本须以 `addFileArg(b.path("<demos_smoke_path>"))` 声明
/// 为守卫步文件依赖（同 202/203/210/238/296 轮跨文件判例）。
pub const demos_build_face = [_]BuildFace{
    .{ .needle = "addFileArg(b.path(\"" ++ demos_smoke_path ++ "\"))", .why = "冒烟脚本输入路径须由 hub 的 demos_smoke_path 派生并与 build.zig 的 addFileArg 同源——分道即守卫吃旧文件名，改脚本不触发重跑（第 297 轮 D156）" },
};

// —— CI 调用面与 README 命令词面（第 298 轮 D157）——
//
// `.gitcode/workflows/ci.yml` 以字面路径调用三枚仓内工具脚本，而 ci.yml 此前只被 D73 步（版本
// 族）读——matcher 步不读它：改脚本名而忘改 ci.yml，盘上文件在、各 addFileArg 皆不触 ci.yml，
// 本地全绿而 CI 到推即断（`tools/lsp-live-smoke.sh` 顶注自警在册：「改路径不同步 ci.yml＝恒绿
// 假守卫」）；同理 README 快跑道 29 处命令样例手抄八枚 `cli.sub_*` 真值，改名即指引静默失效。

/// 仓根 CI 工作流（matcher 步新输入·第 18 片）。
/// 第 334 轮 D193：本仓自此有**两个** CI 面——本值仍是 GitCode 侧，GitHub 侧见 `github_ci_path`，
/// 两面用同一组 `ci_tools_face` 针与同一张 `ci_gate_cmds` 命令核表逐面对拍（镜像面）。
pub const ci_path: []const u8 = ".gitcode/workflows/ci.yml";

/// GitHub Actions 侧 CI 工作流（第 334 轮 D193·镜像面，matcher 步第 25 片）。
/// 升它入面的动因：GitHub 仓此前**零 CI**——`ci_path` 只被 GitCode 读，GitHub 从不执行
/// `.gitcode/workflows/`，公开仓的绿标与门禁皆无；新增后若不入面，便成「第二份无人核的命令清单」
/// （跨侧手抄漂移族，D157 同根）。
pub const github_ci_path: []const u8 = ".github/workflows/ci.yml";

/// LSP 长连接冒烟脚本路径（守卫对面二十三输入·此常量收编 matcher fallback 手抄字面）。
pub const smoke_sh_path: []const u8 = "tools/lsp-live-smoke.sh";

/// 客户端 e2e 套件路径（守卫对面二十四输入·同上收编）。
pub const esm_js_path: []const u8 = "tools/extension-smoke.js";

/// VSIX 打包器路径（第 335 轮 D194）：本仓无 npm 依赖的离线打包入口，`build.zig` 已声明为
/// matcher 步输入（对面二十九）；发布 job 也靠它产出可安装件，故提到 hub 作单源——三处
/// （脚本本身、build 步、CI 发布 job）共用一枚真值，改名须同动。
pub const vsix_py_path: []const u8 = "tools/build-vsix.py";

/// 双远端同步助手路径（第 335 轮 D194）：本仓两枚远端（gitcode 主仓 + GitHub 镜像），靠手敲
/// 两条 `git push` 时漏一侧无任何信号，故落一枚自验脚本（推完逐仓回读 sha 对本地 HEAD）。
pub const push_both_path: []const u8 = "tools/push-both.sh";

/// 诊断语料根目录（第 336 轮 D195）：每族一个 case 目录，内含 `src/main.zz`（触发源码）与
/// `expect.txt`（期望输出子串）。语料是「真跑造形」的沉淀——探针工作区用完即删，若连触发源码
/// 都不留，下一轮补族仍要重新摸「什么写法能逼出这条报文」。
pub const diag_corpus_dir: []const u8 = "tools/diag-corpus";

/// 语料回放器路径（同上）：逐 case 跑 `zzc check`，断言报错极性 + 期望译文 + 条数锚。
pub const diag_corpus_sh: []const u8 = "tools/diag-corpus.sh";

/// 语料条数锚（**手设**，不从目录数抽取——抽取即自证）：脚本内 `EXPECT_CASES` 与本节面针、
/// 以及 `323 T0` 的目录实计三处互锁；删/增 case 只改一处即分道转红。
pub const diag_corpus_floor: usize = 3;

/// 对面三十四·ci.yml 调用面：三枚脚本的执行针形（解释器词＋空格＋路径）全由 hub 路径常量
/// comptime 派生——脚本改名/移位而 ci.yml 不随动（或反之）即分道转红。
pub const ci_tools_face = [_]BuildFace{
    .{ .needle = "sh " ++ smoke_sh_path, .why = "CI 须按 hub 路径调用 LSP 长连接冒烟脚本——分道即本地防线与 CI 防线脱钩，CI 到推即断而本地恒绿（281 轮顶注自警在册，第 298 轮 D157）" },
    .{ .needle = "node " ++ esm_js_path, .why = "CI 须按 hub 路径调用客户端 e2e——同上形制（D98 Linux 盲区的唯一客户端通道，失联即双盲回潮，第 298 轮 D157）" },
    .{ .needle = "bash " ++ demos_smoke_path, .why = "CI 须按 hub 路径调用 demo 冒烟——上轮（D156）刚落地的编译防线若改名不随动即静默断链（第 298 轮 D157）" },
};

/// 对面三十四·`build.zig` 侧命名针：ci.yml 须被 **matcher 步**（而非只 D73 步）声明为文件依赖——
/// 针形含步名限定，防 D73 同路径片顶针而 matcher 步实未挂（addFileArg 逐 step 生效）。
pub const ci_build_face = [_]BuildFace{
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ ci_path ++ "\"))", .why = "ci.yml 须对 matcher 步声明文件依赖——改面不触发重跑即假绿形制（202/203/210/238 轮判例，第 298 轮 D157）" },
};

// —— CI 镜像面（第 334 轮 D193）——
//
// GitHub 仓加建后出现第二个 CI 面：`.gitcode/` 在 GitHub 上从不被执行，`.github/` 又不被任何
// 本地守卫读到——两面各持一份「该跑哪些门禁命令」的手抄清单，改一面忘另一面即「本地全绿、
// 推到某侧才发现漏步」，正是 D157 的同一根因（那时只有一个面，所以只钉了一个）。
// 本面把「命令核」收编为单源表：两面逐条必须各含一份，缺一即红；判据是纯函数，守卫只做 I/O。

/// GitHub 侧两个构建步的命名针（与 `ci_build_face` 同形制）：matcher 步与 D73 版本步
/// 都必须把 GitHub 面声明为文件依赖——前者管命令/脚本针，后者管 `download/<ver>/` 版本对账；
/// 只挂一处即另一半静静脱钩（同路径两片各管一事，不可互顶）。
pub const github_ci_build_face = [_]BuildFace{
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ github_ci_path ++ "\"))", .why = "GitHub 面须对 matcher 步声明文件依赖——不声明即改 CI 不触发重跑，镜像面对拍吃陈旧文本（第 334 轮 D193）" },
    .{ .needle = "check_ver_run.addFileArg(b.path(\"" ++ github_ci_path ++ "\"))", .why = "GitHub 面须对 D73 版本步声明文件依赖——`download/<ver>/` 版本对账逐面进行，漏一面即那面可静默换代（第 334 轮 D193）" },
};

// —— GitHub 发布面（第 335 轮 D194）——
//
// 门禁盖好了却没有「成品出口」：仓里零 tag、零 Release、产物无人上传，改 tag 会不会带上
// 正确版本、扩展包会不会漏打、发布权限给没给——全靠人记。与 D193 同一根因（清单手抄在
// CI 里，本地无守卫读），故同样收编为单源面针：四枚针各管一件事，缺一即红。
// 刻意不用第三方 release action：`gh` 是 ubuntu 运行器自带件，少一枚供应链就等于少一处
// 「上游改接口→发版静默失败」的通道。
pub const github_release_face = [_]BuildFace{
    .{ .needle = "tags: [\"v*\"]", .why = "发布 job 须由 tag 触发——只挂分支推送即发版路径永不进入，改版本号后无人能产出发行件（第 335 轮 D194）" },
    .{ .needle = "contents: write", .why = "发布 job 须显式给 contents: write——默认只读，创建 Release 必 403，且日志在读权限处才红（第 335 轮 D194）" },
    .{ .needle = "gh release create", .why = "成品出口须走 gh CLI 而非第三方 action——供应链面收窄到运行器自带件（第 335 轮 D194）" },
    .{ .needle = "python3 " ++ vsix_py_path, .why = "扩展包须由 hub 里那枚打包器路径产出——与 build 步（对面二十九）同源，改名不同动即发布件里塞旧码（第 335 轮 D194）" },
};

// —— 诊断语料回放面（第 336 轮 D195）——
//
// 诊断译文早就补到 96 条，但「哪段源码会逼出这条报文」只活在人脑与一次性探针里：补下一族仍要
// 从头摸。语料把「触发源码 + 期望子串」固化下来，回放器每轮重跑；本面只钉两件最容易静默的事——
// 条数锚与语料根目录，两处都由 hub 真值派生（改锚不改脚本、或改目录不改脚本，皆红）。
pub const diag_corpus_face = [_]BuildFace{
    .{ .needle = "EXPECT_CASES=" ++ std.fmt.comptimePrint("{d}", .{diag_corpus_floor}), .why = "语料条数锚须与 hub `diag_corpus_floor` 同源——删 case 只动脚本即两侧分道，回放退化成抽样（第 336 轮 D195）" },
    .{ .needle = "cases_dir=\"$root/" ++ diag_corpus_dir ++ "\"", .why = "回放器须读 hub 声明的同一语料根——针钉**赋值行**（只钉裸路径会被脚本顶注里的同名字面垫住：本轮 M2 演漂实证，注释命中而赋值已漂）（第 336 轮 D195）" },
};

/// 回放器在 build.zig 侧的依赖针：不声明 `addFileArg` 即改脚本不触发 matcher 重跑，面针吃旧文本
/// （D157 同族：面文本变了而守卫不重跑＝恒绿）。
pub const diag_corpus_build_face = [_]BuildFace{
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ diag_corpus_sh ++ "\"))", .why = "语料回放器须对 matcher 步声明文件依赖——不声明即改脚本不重跑，两条面针吃陈旧文本（第 336 轮 D195）" },
};

/// 第 337 轮 D196：`zzc check|build <工程根>` 的解析链面（对 `src/main.zig` 消费面）。
/// 存在动因（落码前真值）：`cli.pickEntry` 只认 `.zz` 结尾实参，其余实参被**静默无视**并回落
/// 相对当前目录的缺省入口——`zzc check demo/hello` 于是报「目录 `src` 下未找到任何方言源文件」，
/// 报错里的路径与用户给的路径毫不相干（本仓在册边界，被真跑撞过两次：语料回放与 demo 校验各一次）。
/// 修后 main 侧两入口都须委派 `pickEntryOrRoot`（漂回手抄 `cli.pickEntry(args).entry` 即本面红），
/// 且两支候选（工程根形→源目录形）各一枚判盘针——序颠倒或摘臂即 e2e 冒烟红。
pub const entry_root_face = [_]BuildFace{
    .{ .needle = "const entry = (try pickEntryOrRoot(args)).entry;", .why = "cmdCheck 的入口解析须走工程根形——漂回 pickEntry 即 `zzc check <目录>` 又静默无视实参（第 337 轮 D196）" },
    .{ .needle = "const pick = try pickEntryOrRoot(zig_args);", .why = "cmdBuild/run/test 的入口解析同走一支——各走一套则目录形只修一半（第 337 轮 D196）" },
    .{ .needle = "if (file_io.pathExists(io_, as_root)) return .{ .entry = as_root", .why = "工程根形候选的判盘留在 I/O 层、cli 侧只纯拼串——把存在性判断塞进 cli 即纯函数面失守（第 337 轮 D196）" },
    .{ .needle = "if (file_io.pathExists(io_, as_src)) return .{ .entry = as_src", .why = "「实参即源目录」形候选须在工程根形之后判——e2e 冒烟两例用 `zzc check src`，判序颠倒或摘臂即该形转红（第 337 轮 D196）" },
};

// —— 第 338 轮 D197：许可证面（LICENSE 正文 + 三处声明面）——
//
// 活体真值（补前）：全仓零 LICENSE——发布链（第 335 轮 D194 的 `gh release`）与 VSIX 清单都在
// 对外分发产物，而产物无许可声明即「默认保留所有权利」，下游嵌入无从判断义务；`build.zig.zon`
// 的 `.paths` 注释本身写着「should list files required for compilation plus any license(s)」，
// 而清单里没有 license。本轮把「许可」从人脑里的一条常识变成四处可对账的声明面：正文一份
// （`LICENSE`）、声明三份（README／`editors/vscode/package.json` 的 `license` 字段／
// `build.zig.zon` 的 `.paths`），四者共吃下面五枚真值，任一处独漂即 matcher 红。

/// 仓根许可证正文的路径（也是 `build.zig.zon` `.paths` 里应收录的名字）。
pub const license_path: []const u8 = "LICENSE";
/// SPDX 短名：README 与 `package.json` 的 `license` 字段皆据此声明。
pub const license_spdx: []const u8 = "MIT";
/// 版权署名（与 git 提交作者显示名一致；改署名只动本枚，正文与面针同随）。
pub const license_holder: []const u8 = "tan80";
/// 版权年份（首 commits 年份；独立手设，防「正文年份与 hub 年份各抄一份」）。
pub const license_year: []const u8 = "2026";
/// 署名行唯一构造：LICENSE 正文与 `license_face` 首针共用，形制不再两处手抄。
pub const license_copyright: []const u8 = "Copyright (c) " ++ license_year ++ " " ++ license_holder;

/// 仓根自身清单 `build.zig.zon`（对面四十九新读第 28 片；`out_build_zon` 系毕业工程用，二者不同义）。
pub const root_zon_path: []const u8 = "build.zig.zon";

/// `LICENSE` 正文面：署名行由 hub 派生，另三枚是 MIT 正文的三段义务句（授权／免责／责任上限）。
pub const license_face = [_]BuildFace{
    .{ .needle = license_copyright, .why = "署名行须由 hub `license_copyright` 派生——改署名只动 hub 一枚，正文与守卫同动；独改正文即声明面与义务面分道（第 338 轮 D197）" },
    .{ .needle = "Permission is hereby granted, free of charge", .why = "MIT 授权句首段在场——缺则正文不是 MIT，而三处声明面仍写着 MIT（第 338 轮 D197）" },
    .{ .needle = "THE SOFTWARE IS PROVIDED \"AS IS\"", .why = "大写免责句在场——许可义务的下界；漂字即声明与正文分道（第 338 轮 D197）" },
    .{ .needle = "IN NO EVENT SHALL THE", .why = "责任上限句在场——MIT 三段结构（授权/免责/责任）缺任一即非标准许可文本（第 338 轮 D197）" },
};

/// README 的许可声明面：以 markdown 链接形把 SPDX 短名与正文路径胶合在同一串里。
pub const license_readme_face = [_]BuildFace{
    .{ .needle = "[" ++ license_spdx ++ "](" ++ license_path ++ ")", .why = "README 须以 `[SPDX](路径)` 形指向正文——短名或路径任一处改名而 README 不随动即对外指空（第 338 轮 D197）" },
};

/// `package.json` 的 license 字段面（VSIX/Marketplace 读这里，缺字段即产物无许可元数据）。
pub const license_pkg_face = [_]BuildFace{
    .{ .needle = "\"license\": \"" ++ license_spdx ++ "\"", .why = "扩展清单的 `license` 字段值须等于 hub `license_spdx`——打包器与商店据此对外声明，与正文分道即虚假广告（第 338 轮 D197）" },
};

/// `build.zig.zon` 的 `.paths` 收录面：包发布时 LICENSE 须随包走（zon 注释自陈「plus any license(s)」）。
pub const license_zon_face = [_]BuildFace{
    .{ .needle = "\"" ++ license_path ++ "\",", .why = "许可证正文须被 `.paths` 收录——不收录则 `zig build` 之外的包消费者拿到的树里没有许可文本（第 338 轮 D197）" },
};

// —— 第 339 轮 D198：上游漂移周检面（回放脚本 + 独立 workflow + build 侧依赖声明）——
//
// 活体真值（建前）：两面 CI 装的都是钉死的 Zig，于是「下一版上游会不会把回译打回裸英文」这件事
// 没有任何通道——母语回译按上游报文逐条对齐，上游改文案则译文命中不了，而这种退化在钉死版上
// 零信号（`zig build test` 永远只测已知会绿的那侧）。本轮把它变成每周一次的有信号通道：脚本
// 对拍「钉死版 ↔ 上游最新稳定版」，有漂移就现装新版、重编本仓、用 D195 那批触发源码做逐字同构
// 对比。守卫面只管三件会静默的事：版本源漂了（周检永远免跑）、workflow 不再调用脚本（周检无人跑）、
// 脚本没被声明为文件依赖（改了不重跑）。

/// 周检脚本路径（workflow 与守卫共用同一枚，改脚本名即两侧同动）。
pub const upstream_watch_sh: []const u8 = "tools/upstream-watch.sh";
/// 周检 workflow 路径（不进 CI 镜像面的门禁命令单源——它按周触发、与推送门禁是两件事）。
pub const upstream_watch_yml: []const u8 = ".github/workflows/upstream-watch.yml";
/// 周检频率（每周一 03:17 UTC；分钟取非零散点，避开整点扎堆的定时任务）。
pub const upstream_watch_cron: []const u8 = "17 3 * * 1";
/// 上游版本真值通道——脚本据此判「最新稳定版」；曾用 GitHub `releases/latest`，实测它返 0.15.1
/// （落后于 index.json 的 0.17.0），据此判漂移会天天假红，故弃用。
pub const zig_index_url: []const u8 = "https://ziglang.org/download/index.json";
/// 漂移报告的行首标记——报告文案与「判定是否漂移」共用同一枚，改标记即两侧同动。
pub const drift_marker: []const u8 = "DRIFT(上游漂移)";

/// 周检脚本面：四枚皆钉**赋值行**（裸字面会被脚本顶注里的同名字面垫住——D195 的 M2 判例沿用）。
pub const upstream_watch_face = [_]BuildFace{
    .{ .needle = "index_url=\"" ++ zig_index_url ++ "\"", .why = "版本源须是 hub 声明的那枚 index.json——漂向别处（如 releases/latest 实测落后两版）即周检天天假红或恒免跑（第 339 轮 D198）" },
    .{ .needle = "drift_marker=\"" ++ drift_marker ++ "\"", .why = "漂移标记由 hub 单源——报告与判定共用一枚，独改其一即红了却读不出是哪类红（第 339 轮 D198）" },
    .{ .needle = "corpus_sh=\"$root/" ++ diag_corpus_sh ++ "\"", .why = "周检复跑的须是 hub 那枚语料回放器——换回放器即比的是别的东西，上游文案漂移照样绿（第 339 轮 D198）" },
    .{ .needle = "gh_ci=\"$root/" ++ github_ci_path ++ "\"", .why = "钉死版本取自 GitHub CI 面的 `download/<ver>/` 字面（与 D73 版本守卫同面）——脚本另存一份版本即第三处手抄，升钉必漏改（第 339 轮 D198）" },
};

/// 周检 workflow 面：周频、版本单源取版、周检本体执行三枚。
pub const upstream_watch_yml_face = [_]BuildFace{
    .{ .needle = "cron: \"" ++ upstream_watch_cron ++ "\"", .why = "触发频率须与 hub 同源——改 cron 而守卫不认，则「多久检一次」重新回到人脑台账（第 339 轮 D198）" },
    .{ .needle = "bash " ++ upstream_watch_sh ++ " --print-pinned", .why = "装工具链那步须向脚本取钉死版本，而非在此再抄一枚字面量——此处抄第三份即升钉时三处不同步（第 339 轮 D198）" },
    .{ .needle = "run: bash " ++ upstream_watch_sh, .why = "周检本体须真被执行（行首形针不被上一枚 --print-pinned 的插值行垫住）——只留取版步即每周空转一次工具链安装（第 339 轮 D198）" },
};

/// 周检两面在 build.zig 侧的依赖针：不声明 `addFileArg` 即改脚本/workflow 不触发 matcher 重跑，
/// 面针吃陈旧文本（D157/D195 同族）。
pub const upstream_watch_build_face = [_]BuildFace{
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ upstream_watch_sh ++ "\"))", .why = "周检脚本须对 matcher 步声明文件依赖——不声明即改判据不重跑，四枚面针吃陈旧文本（第 339 轮 D198）" },
    .{ .needle = "check_matcher_run.addFileArg(b.path(\"" ++ upstream_watch_yml ++ "\"))", .why = "周检 workflow 须对 matcher 步声明文件依赖——不声明即摘掉周检步也本地全绿，防线只剩文档里的空话（第 339 轮 D198）" },
};

// —— 第 340 轮 D199：量化收益面（测试映射覆盖闸 + 翻译吞吐基准）——
//
// 活体真值（建前）：仓里测试占了一半体量，却没有任何可对账的量——既不知道「哪个文件有测、测了多少行」
// （新文件零测入图只能靠人目测，292/293 轮反复吃过这形亏），也不知道「翻译一次要多少钱」（回归到
// 十倍慢也没人知道）。另：Zig 0.17 发行包既无 `zig build test --coverage` 亦无 `llvm-cov`，行覆盖率
// 这台机器根本不存在，故取**可实装口径**：文件级测块/测行账（非行覆盖率）+ 固定语料的墙钟基准。
// 判据全在本 hub（`measureTestMap` 纯函数零 I/O），读盘与扫目录在 `src/check/test_map_main.zig`。

/// 测映闸扫描的源码根（相对仓根；与 build 步 `addDirectoryArg` 那片同一枚真值）。
pub const test_map_dir: []const u8 = "src";
/// 命名 test 块总数下限（独立手设：不可从盘上反抽后回填，否则抽取器漂成 0 枚时锚同漂成空转伪钉）。
pub const test_block_floor: usize = 480;
/// test 行占比下限（千分比）——「测试占比」从人眼估算变成周周可对账的数字，退化即红。
pub const test_share_floor_permille: usize = 460;
/// 允许零命名 test 块的文件（守卫/生成器的一次性程序：判据在 hub、本件只做 I/O，故本身无测）。
/// 盘上新增零测文件而不在此登记即红——「新文件静默零测入图」就是本闸要堵的那形。
pub const test_zero_exempt = [_][]const u8{
    "src/check/bench_main.zig",
    "src/check/ignore_coverage_main.zig",
    "src/check/machine_matcher_main.zig",
    "src/check/test_map_main.zig",
    "src/check/zon_baseline_main.zig",
    "src/editor/gen_snippets_main.zig",
    "src/editor/gen_tmlang_main.zig",
    "src/gen/pack_registry_main.zig",
};

/// 吞吐基准的单位模板（`{d}` 取单位序号，保证行间不同形——防同形重复被任何跳同优化拉低读数）。
/// 模板本体是方言合法形（导入/函数/循环/返回均走词法改写主路），行首尾由模板自带。
pub const bench_unit_fmt: []const u8 = "公开 函数 处理{d}(值: 整数) 整数 {{\n    变量 计: 整数 = 0;\n    当 (计 < 值) {{\n        计 = 计 + 1;\n    }}\n    返回 计;\n}}\n";
/// 模板单位行数（与 `bench_unit_fmt` 同行数——语料总行 = `bench_units` × 本数，手设而不运行时反抽）。
pub const bench_unit_lines: usize = 7;
/// 语料单位数（语料规模本身由 hub 定：改小即基准不再是同一件事，面针与基准步同吃本数）。
/// 14 万行量级的计时区约耗百毫秒；再小的语料会被进程启动与时钟粒度吞掉，读数不可信。
pub const bench_units: usize = 20_000;
/// 每千行墙钟上限（毫秒）：这是**量级闸**而非微优化追踪——只拦「多打了个 O(n²)」这类十倍级退化；
/// 读数本身逐轮记入台账成趋势（基准跑在 ReleaseSafe，档位与 `-Doptimize` 解耦，否则读数不可比）。
/// 上限可为整数毫秒（展示口径），但比较必在纳秒位上做：实读数 0.9 ms／千行截断成整数即 0，
/// 拿截断值比较则「上限调到 0」也咬不着（第 340 轮演漂 M5 实测教训，判据见 bench_main.zig）。
pub const bench_ms_per_kilo_ceiling: usize = 20;

/// 两面在 build.zig 侧的钩子针：摘掉任一「挂在 test 上」的依赖即量化防线静默退化成手动跑的附件。
pub const metric_build_face = [_]BuildFace{
    .{ .needle = "check_test_map_run.addDirectoryArg(b.path(\"src\"))", .why = "测映闸须把整面 src/ 声明为输入依赖——不声明即新增文件/改动测块不触发重跑，读数吃旧树（第 340 轮 D199）" },
    .{ .needle = "test_step.dependOn(&check_test_map_run.step);", .why = "测映闸须挂在 test 上——不挂即两面 CI 永不跑它，上下限沦为本地可选项（第 340 轮 D199）" },
    .{ .needle = "test_step.dependOn(&check_bench_run.step);", .why = "吞吐基准须挂在 test 上——不挂即没有逐轮同坐标的读数，趋势曲线无数据源（第 340 轮 D199）" },
};

/// 一行是否为「行首 `test "`」（命名 test 块的起行）。
fn isTestBlockStart(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "test \"");
}

/// test 映射读数（单文件）：总行数、命名 test 块数、test 行数。
/// 测行计法：从行首 `test "` 起，到其后首个**行首 `}`** 止（含首尾）——`zig fmt` 恒把顶层块收尾
/// 花括号归零列，故本计法与仓内既有形制同骨；嵌套括号皆带缩进，不会提前终止计数。
pub const TestMap = struct {
    lines: usize = 0,
    test_lines: usize = 0,
    blocks: usize = 0,
};

/// 扫一文件源码得 `TestMap`（纯函数零 I/O，可被 T0 用小样直钉）。
pub fn measureTestMap(src: []const u8) TestMap {
    var m: TestMap = .{};
    var in_block = false;
    var pos: usize = 0;
    while (pos < src.len) {
        const end = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const line = src[pos..end];
        m.lines += 1;
        if (!in_block and isTestBlockStart(line)) {
            in_block = true;
            m.blocks += 1;
        }
        if (in_block) m.test_lines += 1;
        if (in_block and std.mem.startsWith(u8, line, "}")) in_block = false;
        pos = end + 1; // 末尾无换行时 end == src.len，下一轮自然退出（不将尾换行计成额外空行）
    }
    return m;
}

/// 两面共用的门禁命令核（单源）：**表序即最长匹配优先**，故裸 `zig build` 必须排在
/// 三条带参数的 `zig build …` 之后，否则它会把它们全部截胡、使缺步不被发现。
pub const ci_gate_cmds = [_][]const u8{
    "zig fmt --check src/ build.zig",
    "zig build test --summary all",
    "zig build -Doptimize=ReleaseSafe",
    "zig build -Dtarget=x86_64-windows",
    "zig build -Dtarget=aarch64-macos",
    "bash " ++ demos_smoke_path,
    "sh " ++ smoke_sh_path,
    "node " ++ esm_js_path,
    "zig build", // 裸构建：必须最后（见上「表序即最长匹配优先」）
};

/// 单行归一：去首尾空白；剥掉 YAML 步前缀（`- ` 列表符与 `run:` 键——GitHub Actions 每步都是
/// `- run: <命令>`，GitCode 面则在 `run: |` 块内平铺，两面归一后同形才谈得上逐条对拍）；再剥
/// `timeout <秒> `（两面都靠 timeout 控时但秒数各不同）；注释行与空行返回空串。纯函数，无 I/O。
fn ciGateLine(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r");
    if (std.mem.startsWith(u8, s, "- ")) s = std.mem.trim(u8, s[2..], " \t\r");
    if (std.mem.startsWith(u8, s, "run:")) s = std.mem.trim(u8, s[4..], " \t\r");
    const tmo = "timeout ";
    if (std.mem.startsWith(u8, s, tmo)) {
        const rest = s[tmo.len..];
        var i: usize = 0;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i > 0 and i < rest.len and rest[i] == ' ') s = std.mem.trim(u8, rest[i + 1 ..], " \t\r");
    }
    if (s.len == 0 or s[0] == '#') return "";
    return s;
}

/// 命中位图：逐行归一后按表序认首领（`startsWith`，首中即停），一面里同一条命令出现多次也只记
/// 一次。`ciGateMissing`（枚数）与 `ciGateMiss`（逐条点名）共用本判据，不另立第二套。纯函数。
fn ciGateHits(txt: []const u8) [ci_gate_cmds.len]bool {
    var hit: [ci_gate_cmds.len]bool = @splat(false); // 0.17 无 `**` 重复形（`"x" ** n` 判单侧空格硬拒），改 @splat
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |raw| {
        const line = ciGateLine(raw);
        if (line.len == 0) continue;
        for (ci_gate_cmds, 0..) |cmd, idx| {
            if (std.mem.startsWith(u8, line, cmd)) {
                hit[idx] = true;
                break;
            }
        }
    }
    return hit;
}

/// 一个 CI 面里缺失的命令核枚数（0 = 九条俱全）。纯函数，供守卫与 T0 共用。
pub fn ciGateMissing(txt: []const u8) usize {
    var miss: usize = 0;
    for (ciGateHits(txt)) |h| {
        if (!h) miss += 1;
    }
    return miss;
}

/// 缺失命令逐条点名（守卫报错用）：未命中的命令按 `ci_gate_cmds` 表序写入 `out` 前缀并返回枚数。
/// 只点名不自己判「几条算不及格」——闸值由守卫与 T0 各自对 `0` 比较，判据留在本 hub。
pub fn ciGateMiss(txt: []const u8, out: *[ci_gate_cmds.len][]const u8) usize {
    var miss: usize = 0;
    for (ciGateHits(txt), 0..) |h, idx| {
        if (h) continue;
        out[miss] = ci_gate_cmds[idx];
        miss += 1;
    }
    return miss;
}

// —— 书稿图片引用面（第 299 轮 D158）——
//
// 《母语编写Zig》以 `![题](images/<名>.svg)` 引用 docs/images 下九插图，全仓门禁从不校引用名与
// 盘上文件的双向存在——落码前探针实锤：书稿引用改漂名（盘上断链，印刷即破图）＋盘上新增未被
// 引用的孤立 svg，fmt/build/test/matcher 四道零信号。本面判据为纯关系式双向普查（无名值手抄面），
// hub 持四枚形态常量＋抽取/判定纯函数，守卫只做 I/O（复用对面三十一已读书稿·零新增读文件）。

/// 书稿图片所在目录（相对仓根，守卫普查 walk 基准）。
pub const book_images_dir: []const u8 = "docs/images";

/// 书稿 markdown 引用的固定前缀段（抽取器切点；`images/` 是相对书稿所在 docs/ 的子目录路径）。
pub const book_images_ref_prefix: []const u8 = "](images/";

/// 图片扩展名（盘上普查过滤＋引用名尾验共用）。
pub const book_images_suffix: []const u8 = ".svg";

/// 独立手设下限（承 D140/297 条数锚形制，禁从书稿或盘运行时抽取）：增删插图须此处同动。
pub const book_images_floor: usize = 9;

/// 引用抽取上限：超出即视为异常灌入（如误把非图片链接卷入），防静默吞尾。
pub const book_images_cap: usize = 32;

/// 书稿图片引用收集结果：`names` 为引用名段（含扩展名，指向 `text` 内部切片），`count` 实计，
/// `overflow` 表示超出上限（此时 names 只填至 cap）。
pub const BookImageRefs = struct {
    names: [book_images_cap][]const u8 = undefined,
    count: usize = 0,
    overflow: bool = false,
};

/// 从书稿文本逐处抽取 `](images/<名>)` 引用名段（纯函数、零 I/O；第 299 轮 D158）。
/// 每处处理后扫描起点推进至闭括号之后；若名段跨入后续文本（引用未闭合的病态形），
/// 抽出的含空白/括号串将在守卫侧 access 验在时以 hidden 现形——抽取器不自作容错。
pub fn collectBookImageRefs(text: []const u8) BookImageRefs {
    var out = BookImageRefs{};
    var rest = text;
    var rest_base: usize = 0; // rest 在 text 中的绝对起点，使 names 直指 text 内部切片
    while (std.mem.indexOf(u8, rest, book_images_ref_prefix)) |pos| {
        const start = rest_base + pos + book_images_ref_prefix.len;
        const after = text[start..];
        const end = std.mem.indexOfScalar(u8, after, ')') orelse break; // 后再无闭括号即止
        if (out.count < book_images_cap) {
            out.names[out.count] = after[0..end];
            out.count += 1;
        } else {
            out.overflow = true;
        }
        rest_base = start + end + 1;
        rest = text[rest_base..];
    }
    return out;
}

/// 书稿是否声明了某枚图片引用（盘上→书稿方向的逐枚判定；runtime 名段经 bufPrint 组形，
/// 承 296 轮 `++` 只吃 comptime 的约束）。形如 `](images/<名>.svg)` 全串命中才算。
pub fn bookDeclaresImage(text: []const u8, stem: []const u8) bool {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "{s}{s}{s})", .{ book_images_ref_prefix, stem, book_images_suffix }) catch return false;
    return std.mem.indexOf(u8, text, needle) != null;
}

// —— 书稿 demo 引用面（第 300 轮 D159）——
//
// 书稿附录 L1477 以反引号点名六枚 demo 目录（`demo/hello` 等）——hub 表与冒烟脚本之外的**第三份手抄**；
// 快跑道 L100～L134 又逐字节引 hello 源码体与输出串（「数量是：11」）——297 轮冒烟只钉盘上实跑，
// 书稿侧独漂即印刷变谎。落码前探针实锤：书稿输出改「十一」＋`demo/syntax→synta` 两形同注，
// fmt/build/test/matcher/demos-smoke 五通道零信号。本面判据：正向 hub 表逐枚反引号形 needle 派生（书稿
// 须点名）＋逆向抽取器防 ghost 名＋hello 源体（去首行注释）与冒烟期望串逐字节在场。

/// 书稿反引号点名的目录前缀段（抽取器切点：`` `demo/<名>` ``）。
pub const book_demo_ref_prefix: []const u8 = "`demo/";

/// 书稿 demo 名抽取上限（防异常灌入；现盘上恰六枚）。
pub const book_demo_cap: usize = 16;

pub const BookDemoRefs = struct {
    names: [book_demo_cap][]const u8 = undefined,
    count: usize = 0,
    overflow: bool = false,
};

/// 从书稿文本逐处抽取 `` `demo/<名>` `` 反引号形目录名段（纯函数零 I/O；第 300 轮 D159）。
/// 段为空（`` `demo/` `` 泛引用）或含 '/'、'*'（子路径/通配形）者视为泛指不入集——只集具体目录名。
pub fn collectBookDemoRefs(text: []const u8) BookDemoRefs {
    var out = BookDemoRefs{};
    var rest = text;
    var rest_base: usize = 0;
    while (std.mem.indexOf(u8, rest, book_demo_ref_prefix)) |pos| {
        const start = rest_base + pos + book_demo_ref_prefix.len;
        const after = text[start..];
        const end = std.mem.indexOfScalar(u8, after, '`') orelse break;
        const seg = after[0..end];
        if (seg.len > 0 and std.mem.indexOfScalar(u8, seg, '/') == null and
            std.mem.indexOfScalar(u8, seg, '*') == null)
        {
            if (out.count < book_demo_cap) {
                out.names[out.count] = seg;
                out.count += 1;
            } else {
                out.overflow = true;
            }
        }
        rest_base = start + end + 1;
        rest = text[rest_base..];
    }
    return out;
}

/// 去首行取体（hello 引用对拍用：书稿引文首行为缩短注释、源码首行为指引全注——有意差异面，
/// 其余行须逐字节同形；无换行符即整文件为一行，回 null）。纯函数零 I/O（第 300 轮 D159）。
pub fn stripFirstLine(text: []const u8) ?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    return text[nl + 1 ..];
}

/// 从冒烟脚本抽 `assert_run <entry> "<期望>"` 行的期望串（双引号间段）——期望真值单源在脚本
/// 期望表（297 轮独立手抄面），本判据只抽不造；无此行/无成对引号回 null（第 300 轮 D159）。
pub fn smokeExpectFor(script: []const u8, entry: []const u8) ?[]const u8 {
    var rest = script;
    while (std.mem.indexOf(u8, rest, "assert_run ")) |pos| {
        const line = rest[pos + "assert_run ".len ..];
        rest = if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line[nl + 1 ..] else "";
        if (std.mem.startsWith(u8, line, entry)) {
            const q1 = std.mem.indexOfScalar(u8, line, '"') orelse return null;
            const q2 = std.mem.indexOfScalar(u8, line[q1 + 1 ..], '"') orelse return null;
            return line[q1 + 1 .. q1 + 1 + q2];
        }
    }
    return null;
}

/// 对面三十六·正向点名针：六枚 demo 目录须以反引号形现于书稿——needle 由 `demo_entries` 首两段
/// comptime 派生（表改名即书稿旧名针落空红；书稿独改名由抽取器 ghost 闸捕——双向互拦）。
pub const book_demo_face = blk: {
    var faces: [demo_entries.len]BuildFace = undefined;
    for (demo_entries, 0..) |entry, i| {
        const first = std.mem.indexOfScalar(u8, entry, '/').?;
        const second = std.mem.indexOfScalar(u8, entry[first + 1 ..], '/').?;
        const dir = entry[0 .. first + 1 + second]; // 「demo/<名>」前两段
        faces[i] = .{ .needle = "`" ++ dir ++ "`", .why = "书稿附录/推荐面须以反引号点名枚枚 demo 目录（与 hub 表同源）——目录改名/删除而书稿不随动即读者照抄报不存在路径（第 300 轮 D159）" };
    }
    break :blk faces;
};

/// 对面三十六·hello 引用体对拍的盘上读取面：守卫需**全文**读 demo 源（非 297 轮限读 1 字节的验在形），
/// 故该源文件须对 matcher 步声明文件依赖（承 202/203/210/238 轮跨文件判例）。
pub const bookdemo_build_face = [_]BuildFace{
    .{ .needle = "addFileArg(b.path(\"" ++ demo_entries[0] ++ "\"))", .why = "hello 源须被 matcher 步 addFileArg 声明——逐字节对拍读的改面不触发重跑即假绿（第 300 轮 D159）" },
};

/// 从文本中抽 `.minimum_zig_version = "…"` 引号之间的值段（第 205 轮 D73 的守卫判据，纯函数）。
/// 字段名缺、值非字符串形（无成对引号）皆 null；本仓只用单层引号形，故不实现转义与多行串。
pub fn minimumZigVersionIn(text: []const u8) ?[]const u8 {
    const key = ".minimum_zig_version";
    const k = std.mem.indexOf(u8, text, key) orelse return null;
    var i = k + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i >= text.len or text[i] != '=') return null;
    i += 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i >= text.len or text[i] != '"') return null;
    const start = i + 1;
    const end = std.mem.indexOfScalar(u8, text[start..], '"') orelse return null;
    return text[start .. start + end];
}

/// 本仓 `build.zig.zon` 文本声明的工具链下限是否逐字节等于族真值（第 205 轮 D73 的守卫判据）。
/// 取严格全等而非「不低于」：本仓只标定一个版本，`dev`/`+hash` 后缀或另起 patch 都须显式改族真值。
pub fn zonDeclaresBaseline(text: []const u8) bool {
    const v = minimumZigVersionIn(text) orelse return false;
    return std.mem.eql(u8, v, zig_version);
}

/// CI 工作流文本是否安装族真值所指的那一版（第 205 轮 D73 的守卫判据）：以 `zig_download_marker` 定位。
pub fn ciInstallsBaseline(text: []const u8) bool {
    return std.mem.indexOf(u8, text, zig_download_marker) != null;
}

/// 目录路径 `dir` 是否被 `.gitignore` 内容 `rules` 的某条**目录规则**覆盖（第 202 轮 D70 的守卫判据）。///
/// 取首段比较：族成员的落盘根总在第一位（`.zzc/gen` → `.zzc`、`logs/x.json` → `logs`），而 git 的语义
/// 正是「目录被忽略则整棵子树被忽略」，故子段随根。
///
/// 生效边界（刻意不做全 gitignore 语义）：本仓只用 `name/`、`**/name/`、`/name/` 三形目录规则，本判据只
/// 认那三形且要求**尾斜杠**（无尾斜杠当文件规则处理、不覆盖目录）；`*` 通配族、`!` 否定规则、字符类均不实现——
/// 忽略面若改用那些形制，本守卫会报红即提示须同步扩展判据（202 T0 A4 负例钉守此边界）。
pub fn dirIgnored(rules: []const u8, dir: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, dir, '/');
    const seg = if (slash) |i| dir[0..i] else dir;
    if (seg.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, rules, '\n');
    while (it.next()) |raw0| {
        var line = std.mem.trim(u8, raw0, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '!') continue; // 空行/注释/否定规则不在守卫边界
        if (std.mem.startsWith(u8, line, "**/")) line = line[3..];
        if (line.len > 0 and line[0] == '/') line = line[1..];
        if (!std.mem.endsWith(u8, line, "/")) continue; // 文件规则不覆盖目录
        if (std.mem.eql(u8, line[0 .. line.len - 1], seg)) return true;
    }
    return false;
}

/// `disk_family` 中首个**未被**忽略面 `rules` 覆盖的成员（全盖则 null）——守卫步与测试图共用同一判据，
/// 避免「守卫自持一套判断」的第二真值（第 202 轮 D70）。
pub fn firstUncovered(rules: []const u8) ?[]const u8 {
    for (disk_family) |p| {
        if (!dirIgnored(rules, p)) return p;
    }
    return null;
}

/// `source_family` 中首个**被**忽略面 `rules` 误吞的成员（全未吞则 null）——上者的对偶臂。
pub fn firstFalselyIgnored(rules: []const u8) ?[]const u8 {
    for (source_family) |p| {
        if (dirIgnored(rules, p)) return p;
    }
    return null;
}

/// 第 241 轮 D109：母语「词内字符」字节集单一真值 = `[0-9A-Za-z_] ∪ [0x80..0xFF]`。
/// 旧形制下 `cli/args.isWordCharByte`、`lsp/server.isChainWordByte`、`transpiler/lexer` 非 ASCII
/// 词元续读三处各自内联同一判据（高字节并入 + ASCII 字母数字 + 下划线），系跨模块手抄、无共同真值：
/// 任一单边漂移（如误并入 `-`）即词边界判定分道，而三处各只有自测、无跨模块一致性锚（server 仅 6 点
/// 采样，未覆盖字节漂移即静默全绿）。收敛于此，三点委派本函数即结构同源、杜绝单边漂。
pub fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c >= 0x80;
}

test "第 200 轮 T0 .zzc 族单一真值：七枚字面量全员钉 + 形制契约（相对、正斜杠、前缀多一个分隔符）" {
    // A1 族真值逐枚字面量钉（判据不复用常量，遵 196/197 通则）：改本模块任一枚即本钉红，
    //    连带要求消费/生产两侧与 `diag/translate.zig` 的组合锚同步复跑。
    try std.testing.expectEqualStrings(".zzc", root);
    try std.testing.expectEqualStrings(".zzc/gen", gen_dir);
    try std.testing.expectEqualStrings(".zzc/gen/", gen_dir_prefix);
    try std.testing.expectEqualStrings(".zzc/bin", bin_dir);
    try std.testing.expectEqualStrings(".zzc/lang", lang_dir);
    try std.testing.expectEqualStrings(".zzc/symbols.txt", symbols_file);
    try std.testing.expectEqualStrings(".zzc/tmp_check_root", check_root);

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

test "第 202 轮 T0 落盘族 ↔ .gitignore 忽略面：族根值钉 + 清单形制契约 + 判据小样 + 超边界负例" {
    // A1 第二族根与落点名逐枚字面量钉（判据不复用常量，遵 196/197 通则）。
    try std.testing.expectEqualStrings("logs", logs_dir);
    try std.testing.expectEqualStrings("untranslated_phrases.json", log_file_name);
    try std.testing.expectEqualStrings("logs/untranslated_phrases.json", logs_dir ++ "/" ++ log_file_name);

    // A2 落盘族清单形制契约（独立字面量 oracle、不引常量）：全员必须是**相对**路径、正斜杠形，且首段
    //    只能落在两枚族根上（`.zzc` 内部树 / `logs` 可见产出面）——新增成员若落到第三个目录（或族根被
    //    改名而清单未同步），`check-ignore-coverage` 的核对集与真忽略面就此脱钩，本钉先红。
    for (disk_family) |p| {
        try std.testing.expect(!std.fs.path.isAbsolute(p));
        try std.testing.expect(std.mem.indexOfScalar(u8, p, '\\') == null);
        const seg = if (std.mem.indexOfScalar(u8, p, '/')) |i| p[0..i] else p;
        try std.testing.expect(std.mem.eql(u8, ".zzc", seg) or std.mem.eql(u8, "logs", seg) or std.mem.eql(u8, "standard", seg) or std.mem.eql(u8, "relocalized", seg)); // 第 213 轮 D81：eject 缺省落点入第三族根；relocalize 缺陷落点入第四族根
    }
    try std.testing.expectEqual(@as(usize, 11), disk_family.len); // 第 213 轮收编 eject_default_dest；relocalize 落点随行

    // A3 判据形制小样（字面量给定、独立于真文件）：三形各一枚命中，注释行/无尾斜杠（文件规则）/近名/
    //    空 rules/空段一律不覆盖——判据若被放宽（如「子串含即覆盖」）即在此现形。
    try std.testing.expect(dirIgnored("logs/\n", "logs"));
    try std.testing.expect(dirIgnored("**/.zzc/\n", ".zzc/gen/x"));
    try std.testing.expect(dirIgnored("/logs/", "logs/x.json"));
    try std.testing.expect(!dirIgnored("# logs/\n", "logs")); // 注释行不算规则
    try std.testing.expect(!dirIgnored("logs\n", "logs")); // 无尾斜杠＝文件规则、不覆盖目录
    try std.testing.expect(!dirIgnored("logz/\n", "logs")); // 近名不混
    try std.testing.expect(!dirIgnored("logs/\n", "logsx"));
    try std.testing.expect(!dirIgnored("", "logs"));
    try std.testing.expect(!dirIgnored("logs/\n", ""));

    // A4 超出生效边界的负例（守「判据只做本仓实用三形」的约定）：通配形不实现——忽略面若改用该形，守卫
    //    会报覆盖不足而不是默默放过，本钉坐实这条边界不被当作已实现能力。
    try std.testing.expect(!dirIgnored("build*/\n", "build"));
    try std.testing.expect(!dirIgnored("logs/*\n", "logs/x.json"));

    // A5 守卫两臂的组合判据（小样 rules、不读真文件）：缺一条条目即报那个成员、多一条源码规则即报被误
    //    吞的成员——守卫步只负责读真 `.gitignore` 并报结果，判断全在此钉住。
    try std.testing.expectEqualStrings(".zzc", firstUncovered("logs/\n").?); // 缺 `**/.zzc/` → 内部族报缺
    try std.testing.expectEqualStrings("logs", firstUncovered("**/.zzc/\n").?); // 缺 `logs/` → 产出面报缺
    try std.testing.expectEqual(@as(?[]const u8, null), firstUncovered(
        \\logs/
        \\**/.zzc/
        \\**/standard/
        \\**/relocalized/
    ));
    try std.testing.expectEqualStrings("src", firstFalselyIgnored("logs/\n**/.zzc/\nsrc/\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), firstFalselyIgnored("logs/\n**/.zzc/\n"));
}

test "第 204 轮 T0 毕业工程产物族：值钉／清单派生钉／dest 构造形制／层级负例" {
    // A1 值钉：三枚名是与**所有既有毕业工程**对外的契约，改名即断裂（旧形制写侧那枚零钉，204 t2 P1 实测
    // 改名后 226/226 全绿而毕业树里没有 build.zig——本轮起值侧与派生侧皆有钉）。
    try std.testing.expectEqualStrings("build.zig", out_build_zig);
    try std.testing.expectEqualStrings("build.zig.zon", out_build_zon);
    try std.testing.expectEqualStrings("src", src_dir);
    // A2 清单派生钉：恰三枚且顺序即 `.paths` 落盘形制——漏一项＝毕业包缺文件，多一项＝清单指错名。
    try std.testing.expectEqual(@as(usize, 3), out_paths_family.len);
    try std.testing.expectEqualStrings(out_build_zig, out_paths_family[0]);
    try std.testing.expectEqualStrings(out_build_zon, out_paths_family[1]);
    try std.testing.expectEqualStrings(src_dir, out_paths_family[2]);
    // A3 构造形制：`dest` 前缀 + 单斜杠 + 名，写侧／读侧／陈旧清理侧共用同一变换（三处旧各持一枚字面量）。
    const gpa = std.testing.allocator;
    const p1 = try ejectPathFor(gpa, "standard", out_build_zig);
    defer gpa.free(p1);
    try std.testing.expectEqualStrings("standard/build.zig", p1);
    const p2 = try ejectPathFor(gpa, "a/b", out_build_zon);
    defer gpa.free(p2);
    try std.testing.expectEqualStrings("a/b/build.zig.zon", p2);
    const p3 = try ejectPathFor(gpa, "out", src_dir);
    defer gpa.free(p3);
    try std.testing.expectEqualStrings("out/src", p3); // 清理侧目标（导出树目录）与清单条目同一构造
    // A4 层级负例：族成员都是**单层名**——带斜杠即清单指错层级（`.paths` 会收录路径而非顶层成员），
    // 以 `.` 起头即把隐藏文件打进毕业包，空段即清单有洞。三条各守一处可达漂移形。
    for (out_paths_family) |name| {
        try std.testing.expect(name.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, name, '/') == null);
        try std.testing.expect(!std.mem.startsWith(u8, name, "."));
    }
}
test "第 205 轮 T0 工具链版本族：两枚数与两枚串的值钉／派生一致性／zon 与 CI 判据小样 + 负例" {
    // A1 值钉：判据不复用被测常量（196/197 通则），四枚形各自写死。
    try std.testing.expectEqual(@as(u32, 0), zig_major);
    try std.testing.expectEqual(@as(u32, 17), zig_minor);
    try std.testing.expectEqualStrings("0.17", zig_series);
    try std.testing.expectEqualStrings("0.17.0", zig_version);
    try std.testing.expectEqualStrings("download/0.17.0/", zig_download_marker);
    // A2 派生一致：完整串＝系列串 + ".0"；两级数可从系列串反解回真值；系列串恰一枚点。
    try std.testing.expectEqualStrings(zig_series ++ ".0", zig_version);
    const back = std.fmt.parseInt(u32, zig_series[std.mem.indexOfScalar(u8, zig_series, '.').? + 1 ..], 10) catch unreachable;
    try std.testing.expectEqual(zig_minor, back);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, zig_series, "."));
    // A3 minimumZigVersionIn：标准形／前空格形／同行后置内容形；缺字段、值非引号、引号不闭合皆 null。
    try std.testing.expectEqualStrings("0.17.0", minimumZigVersionIn(".{\n    .minimum_zig_version = \"0.17.0\",\n}").?);
    try std.testing.expectEqualStrings("0.18.1", minimumZigVersionIn(".minimum_zig_version   =   \"0.18.1\"").?);
    try std.testing.expectEqualStrings("1.2.3", minimumZigVersionIn(".minimum_zig_version = \"1.2.3\", .paths = .{}").?);
    try std.testing.expectEqual(@as(?[]const u8, null), minimumZigVersionIn(".{\n    .version = \"0.1.0\",\n}"));
    try std.testing.expectEqual(@as(?[]const u8, null), minimumZigVersionIn(".minimum_zig_version = 17"));
    try std.testing.expectEqual(@as(?[]const u8, null), minimumZigVersionIn(".minimum_zig_version = \"未闭合"));
    // A4 zonDeclaresBaseline：真值命中；异值／缺字段／带后缀 皆假（本仓只标定一版，严格全等）。
    try std.testing.expect(zonDeclaresBaseline(".minimum_zig_version = \"" ++ zig_version ++ "\","));
    try std.testing.expect(!zonDeclaresBaseline(".minimum_zig_version = \"0.16.0\","));
    try std.testing.expect(!zonDeclaresBaseline(".minimum_zig_version = \"" ++ zig_version ++ "-dev.1\","));
    try std.testing.expect(!zonDeclaresBaseline(".{ .name = .zzc }"));
    // A5 ciInstallsBaseline：含下载标记为真；只含系列串、只含裸版本号、空文本 皆假。
    try std.testing.expect(ciInstallsBaseline("curl -LO https://ziglang.org/" ++ zig_download_marker ++ "zig.tar.xz"));
    try std.testing.expect(!ciInstallsBaseline("安装 Zig " ++ zig_series ++ "（本机）"));
    try std.testing.expect(!ciInstallsBaseline("download/0.16.0/zig.tar.xz"));
    try std.testing.expect(!ciInstallsBaseline(""));
}

test "第 210 轮 T0 程序名族：值钉／prog_prefix 派生钉／buildDeclaresExe 正反小样（防跨 build↔src 手抄漂移）" {
    // A1 值钉：程序名是对外的 CLI 契约（用户照此名敲命令），改名即断裂——不复用常量、直接写死（196/197 通则）。
    try std.testing.expectEqualStrings("zzc", prog_name);
    // A2 派生一致：报错前缀恰为程序名 + ": "（改 prog_name 则前缀随动，杜绝某条提示仍写旧名的散点漂移）。
    try std.testing.expectEqualStrings("zzc: ", prog_prefix);
    try std.testing.expectEqualStrings(prog_name ++ ": ", prog_prefix);
    // A3 buildDeclaresExe：CLI exe 声明 `.name = "<prog_name>"` 命中为真；异名／缺引号／空文本 皆假。
    try std.testing.expect(buildDeclaresExe("const exe = b.addExecutable(.{\n    .name = \"" ++ prog_name ++ "\",\n});"));
    try std.testing.expect(!buildDeclaresExe(".name = \"zzq\"")); // 改名后（P1 探针形）CLI exe 声明消失
    try std.testing.expect(!buildDeclaresExe(".name = \"" ++ prog_name ++ "_core\"")); // 模块依赖名不误算作 CLI exe
    try std.testing.expect(!buildDeclaresExe(""));
}

test "第 211 轮 T0 产品版本族：值钉／zzc_version_token 派生钉／zonDeclaresVersion 正反小样（防 zon↔src 四源手抄静默升代）" {
    // A1 值钉：产品版本是对外出口（`zzc version`、zon、usage 抬头、毕业工程继承件共此一枚），
    // 不复用常量、直接写死（196/197 通则）。
    try std.testing.expectEqualStrings("0.1.0", zzc_version);
    // A2 派生一致：抬头记号恰为 "v" + 版本（升代随动，杜绝「改了版本而抬头仍写旧版」）。
    try std.testing.expectEqualStrings("v0.1.0", zzc_version_token);
    try std.testing.expectEqualStrings("v" ++ zzc_version, zzc_version_token);
    // A3 zonDeclaresVersion：本仓形制命中为真；异值／只有同值的 minimum_zig_version／缺尾引号／空文本 皆假。
    try std.testing.expect(zonDeclaresVersion(".{\n    .version = \"" ++ zzc_version ++ "\",\n}"));
    try std.testing.expect(!zonDeclaresVersion(".version = \"9.9.9\",")); // 异值（P3 探针形）
    try std.testing.expect(!zonDeclaresVersion(".minimum_zig_version = \"0.1.0\",")); // 首点锚防子串假命中
    try std.testing.expect(!zonDeclaresVersion(".version = \"0.1.0")); // 缺尾引号不算声明
    try std.testing.expect(!zonDeclaresVersion("")); // 空文本
}
test "第 213 轮 T0 eject 缺省目录名族：值钉＋收编落盘族＋忽略判据正反小样（防 dest↔usage↔.gitignore 四源手抄静默脱钩）" {
    // A1 值钉：缺省导出目录名是对外的 CLI 契约（usage 与报错文案照此宣示、用户 .gitignore 照此配置），
    // 不复用常量、直接写死（196/197 通则）。
    try std.testing.expectEqualStrings("standard", eject_default_dest);
    // A2 收编钉：本员必在 disk_family 核对集内——守卫据此要求忽略面覆盖它（删 `**/standard/` 即 FAIL、
    // P3 探针盲区自此有关闸通道）。
    var found = false;
    for (disk_family) |p| found = found or std.mem.eql(u8, p, eject_default_dest);
    try std.testing.expect(found);
    // A3 判据正反小样：仓根实用形 `**/standard/` 命中；近名／无尾斜杠／裸名异形 皆不覆盖。
    try std.testing.expect(dirIgnored("**/standard/\n", eject_default_dest));
    try std.testing.expect(dirIgnored("**/standard/\n", eject_default_dest ++ "/build.zig")); // 首段命中即盖整树
    try std.testing.expect(!dirIgnored("**/standar-d/\n", eject_default_dest)); // 近名不混（P1 探针形）
    try std.testing.expect(!dirIgnored("standard\n", eject_default_dest)); // 无尾斜杠＝文件规则
    try std.testing.expect(!dirIgnored("standard/\n", "stan-d")); // 反向：异名产物不被本条目冒充覆盖
    // A4 `zzc relocalize` 落点同族同治（第 331 轮 D190）：值钉＋收编钉＋忽略判据正反小样，
    //    与 eject 缺省落点同一套三道闸——写出面与忽略面分道即产物入 `git status` 而守卫零信号。
    try std.testing.expectEqualStrings("relocalized", relocalize_default_dest);
    var rfound = false;
    for (disk_family) |p| rfound = rfound or std.mem.eql(u8, p, relocalize_default_dest);
    try std.testing.expect(rfound);
    try std.testing.expect(dirIgnored("**/relocalized/\n", relocalize_default_dest));
    try std.testing.expect(!dirIgnored("**/relocalize/\n", relocalize_default_dest)); // 近名不混
}

test "第 234 轮 T0 源扩展名对族：std_ext 值钉 + 两枚改写后缀派生钉与独立字面量钉（防 .zz↔.zig 跨模块手抄单边漂移）" {
    // A1 std_ext 值钉：标准扩展名是 `@import` 目标与 genPathFor 落盘名两处共用的对外契约（生成的
    // zig 码要能被 zig 工具链解析），不复用常量、直接写死（196/197 通则）。改本枚即本钉红，连带要求
    // 改写侧（transpiler/translate.zig）与落盘侧（cli/args.zig genPathFor）同步复跑。
    try std.testing.expectEqualStrings(".zig", std_ext);
    // A2 派生一致性钉：两枚改写后缀必恰为对应扩展名并入闭引号——改写匹配形/替换形的唯一真值。
    try std.testing.expectEqualStrings(dialect_ext ++ "\"", dialect_import_suffix);
    try std.testing.expectEqualStrings(std_ext ++ "\"", std_import_suffix);
    // A3 独立字面量钉（不复用 dialect_ext/std_ext，遵判据不复用常量通则）：与 285-286 旧硬编形逐字节同。
    try std.testing.expectEqualStrings(".zz\"", dialect_import_suffix);
    try std.testing.expectEqualStrings(".zig\"", std_import_suffix);
    // A4 成对形制契约（独立 oracle）：两枚后缀同为「扩展名 + 一个引号」，长度差必等于两扩展名长度差——
    //    若一侧漏引号或多引号，改写会把非法 token 落进生成码。
    try std.testing.expectEqual(
        @as(isize, @intCast(dialect_import_suffix.len - dialect_ext.len)),
        @as(isize, @intCast(std_import_suffix.len - std_ext.len)),
    );
}

test "第 237 轮 T0 语言包扩展名族：pack_ext 值钉＋形制契约（防 fileRel↔cmdLangAdd 两文案三处手抄单边漂移）" {
    // A1 值钉：`.txt` 是对外可见的安装落名形（`zzc lang add` 两文案照此宣示、用户照此定位/删除
    // 文件、`--lang` 经 fileRel 拼此名取盘），不复用常量、直接写死（196/197 通则）。改本枚即
    // 本钉红，连带要求 `userpack.fileRel`（写/读侧）与 `main.cmdLangAdd`（两文案）同步复跑。
    try std.testing.expectEqualStrings(".txt", pack_ext);
    // A2 形制契约（独立 oracle）：包扩展名必以 `.` 起手且不含路径分隔——若误改为带目录段或漏点，
    //    fileRel 拼出的落名与文案宣示的落名将结构失形（用户照文案找不到文件）。
    try std.testing.expect(std.mem.startsWith(u8, pack_ext, "."));
    try std.testing.expect(std.mem.indexOfScalar(u8, pack_ext, '/') == null);
    try std.testing.expect(pack_ext.len > 1); // 不接受裸一个点（`<dir>/<key>.` 非合法落名）
    // A3 与符号表同尾不同源（防错用）：`symbols_file` 的 `.txt` 尾是自身落名、不属 pack_ext 族，
    //    本锚仅坐实两者恰同尾而互不引用（pack_ext 漂移不改 symbols_file 形）。
    try std.testing.expect(std.mem.endsWith(u8, symbols_file, ".txt"));
    try std.testing.expectEqualStrings(".zzc/symbols.txt", symbols_file);
}

test "第 238 轮 T0 内置默认包身份族：四形 embed + cwd 形的值钉与层间派生互洽（防 中文.txt 跨 46 处文件名手抄单边漂移）" {
    // A1 值钉：文件名 = 词干 + pack_ext（与 D105 pack_ext 同源）；改词干或改 pack_ext 皆动本钉。
    try std.testing.expectEqualStrings("中文", builtin_pack_stem);
    try std.testing.expectEqualStrings("中文.txt", builtin_pack_file);
    // A2 四形 embed 逐字节钉（旧形制散在各模块的内联字面量，本轮收敛后由独立硬编字面量钉住其真形）。
    try std.testing.expectEqualStrings("lang/packs/中文.txt", builtin_pack_embed_src);
    try std.testing.expectEqualStrings("../lang/packs/中文.txt", builtin_pack_embed_child);
    try std.testing.expectEqualStrings("packs/中文.txt", builtin_pack_embed_lang);
    try std.testing.expectEqualStrings("src/lang/packs/中文.txt", builtin_pack_cwd_rel);
    // A3 层间派生互洽（独立 oracle）：child = "../" + src；cwd = src_dir + "/" + src；lang 与 src 尾同名。
    //    若某一层漏写分隔符或错拼目录，四形会不一致——embed 相对形是相对各调用文件解析的，层间错位即编译期找不到文件。
    try std.testing.expectEqualStrings("../" ++ builtin_pack_embed_src, builtin_pack_embed_child);
    try std.testing.expectEqualStrings(src_dir ++ "/" ++ builtin_pack_embed_src, builtin_pack_cwd_rel);
    try std.testing.expect(std.mem.endsWith(u8, builtin_pack_embed_src, builtin_pack_embed_lang));
    // A4 内置默认包文件名尾必与 pack_ext 同（防错用非包扩展名）：build.zig 扫描器只收 `.txt` 结尾的包。
    try std.testing.expect(std.mem.endsWith(u8, builtin_pack_file, pack_ext));
}

test "第 241 轮 T0 母语词字节集单一真值：全 256 字节 iff 穷举 oracle 钉 [0-9A-Za-z_] ∪ [0x80..0xFF]（跨 args/server/lexer 委派同源·D109）" {
    // 独立 oracle：显式字节区间，不复用 isWordByte 的短路组合——两侧同写即失却对账意义（承 178 轮通则）。
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        const word = (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or
            (b >= 'a' and b <= 'z') or (b == '_') or (b >= 0x80);
        try std.testing.expect(word == isWordByte(b));
    }
    try std.testing.expect(isWordByte('_'));
    try std.testing.expect(isWordByte(0x80));
    try std.testing.expect(isWordByte(0xFF));
    try std.testing.expect(!isWordByte(0x7F));
    try std.testing.expect(!isWordByte('-'));
}

test "第 296 轮 T0 README 版本族对面：readme_path 值钉＋七枚 needle 独立字面量对拍＋基数钉＋build 针形钉（D155）" {
    // A1 路径值钉：README 文件名是守卫 addFileArg 与本族 needle 的入口，不复用常量、直接写死（196/197 通则）。
    try std.testing.expectEqualStrings("README.md", readme_path);

    // A2 七枚 needle 与独立手抄的期望字面逐字节对拍（want 表不引用族常量：族真值漂则 needle 随漂、
    //    与 want 失配即红；README 侧独漂则由守卫对面三十二红——双向互备，承 227 T0 want 表形制）。
    const want = [_][]const u8{
        "当前版本：`zzc 0.1.0`",
        "**Zig `0.17.0`**",
        "minimum_zig_version = \"0.17.0\"",
        "| **0.17.0** |",
        "应输出 0.17.0",
        "Zig 0.17 实测",
        "（0.17）",
    };
    try std.testing.expectEqual(want.len, readme_face.len); // A3 基数钉：增删 needle 须同步 want 表与本钉
    inline for (readme_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(want[i], c.needle);
    }

    // A4 build 侧命名针形钉：addFileArg 声明形由 readme_path 派生，与 build.zig 实文对账在守卫面；
    //    此处钉住派生形本身——路径拼接改形（漏引号/漏括号）在此现形。
    try std.testing.expectEqual(@as(usize, 1), readme_build_face.len);
    try std.testing.expectEqualStrings("addFileArg(b.path(\"README.md\"))", readme_build_face[0].needle);
}

test "第 297 轮 T0 demo 冒烟防线单源：路径/入口表独立字面量对拍＋三处互锁＋脚本面针形钉（D156）" {
    // A1 路径与枚数值钉（独立手抄，不从派生式自证）。
    try std.testing.expectEqualStrings("tools/demos-smoke.sh", demos_smoke_path);
    try std.testing.expectEqual(@as(usize, 6), demo_count_floor);
    // A2 入口表与独立手抄 want 表逐字节对拍（增删 demo 须三处同动：表、want、下限）。
    const want = [_][]const u8{
        "demo/hello/src/main.zz",
        "demo/multi/src/main.zz",
        "demo/nested/src/main.zz",
        "demo/syntax/src/main.zz",
        "demo/errors/src/main.zz",
        "demo/fullwidth/src/main.zz",
    };
    try std.testing.expectEqual(want.len, demo_entries.len); // 基数钉
    inline for (demo_entries, 0..) |entry, i| {
        try std.testing.expectEqualStrings(want[i], entry);
    }
    // A3 三处互锁（承 D140）：表基数 == 独立下限——同删同缩即此钉红，盘上双向对账在守卫面。
    try std.testing.expectEqual(demo_count_floor, demo_entries.len);
    // A4 脚本面清单派生钉：逐枚 needle 等于入口表、条数锚针形钉、build 命名针形钉。
    try std.testing.expectEqual(demo_entries.len, demos_smoke_face.len);
    inline for (demos_smoke_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(demo_entries[i], c.needle);
    }
    try std.testing.expectEqual(@as(usize, 1), demos_smoke_count_face.len);
    try std.testing.expectEqualStrings("EXPECT_CHECKS=21", demos_smoke_count_face[0].needle); // 逐轮随动：锚跟断言下限（旧值 6→…→19→20→21）
    try std.testing.expectEqual(@as(usize, 1), demos_build_face.len);
    try std.testing.expectEqualStrings("addFileArg(b.path(\"tools/demos-smoke.sh\"))", demos_build_face[0].needle);
    // A5 豁免清单值钉（独立手抄）：本闸首跑抓到的真 ghost `demo/httpz` 须显式在册未免——
    //    新增豁免须同时动表与此钉，禁默默扩网。
    try std.testing.expectEqual(@as(usize, 1), demo_exempt_dirs.len);
    try std.testing.expectEqualStrings("httpz", demo_exempt_dirs[0]);
}

test "第 298 轮 T0 CI 调用面：三枚路径值钉＋执行针与独立 want 表对拍＋matcher 步命名针形钉（D157）" {
    // A1 路径值钉（独立手抄）：ci 工作流与两枚新收编脚本路径——改名须此处同动。
    try std.testing.expectEqualStrings(".gitcode/workflows/ci.yml", ci_path);
    try std.testing.expectEqualStrings("tools/lsp-live-smoke.sh", smoke_sh_path);
    try std.testing.expectEqualStrings("tools/extension-smoke.js", esm_js_path);
    // A2 执行针派生形对拍：want 表独立手抄（与 ci.yml 盘上调用行同源而不经 hub）——
    //    hub 路径/解释器词任一分道即此钉红；盘上 ci.yml 独漂由守卫对面三十四捕。
    const want = [_][]const u8{
        "sh tools/lsp-live-smoke.sh",
        "node tools/extension-smoke.js",
        "bash tools/demos-smoke.sh",
    };
    try std.testing.expectEqual(want.len, ci_tools_face.len); // A3 基数钉
    inline for (ci_tools_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(want[i], c.needle);
    }
    // A4 matcher 步命名针形钉：含步名限定，防 D73 同路径片顶针而 matcher 步实未挂。
    try std.testing.expectEqual(@as(usize, 1), ci_build_face.len);
    try std.testing.expectEqualStrings(
        "check_matcher_run.addFileArg(b.path(\".gitcode/workflows/ci.yml\"))",
        ci_build_face[0].needle,
    );
}

test "第 299 轮 T0 书稿图片面：形态常量值钉＋抽取器/声明判据合成小样正反形（D158）" {
    // A1 形态常量值钉（独立手抄）：目录/引用前缀/扩展名/下限/上限——任一改动须此处同动。
    try std.testing.expectEqualStrings("docs/images", book_images_dir);
    try std.testing.expectEqualStrings("](images/", book_images_ref_prefix);
    try std.testing.expectEqualStrings(".svg", book_images_suffix);
    try std.testing.expectEqual(@as(usize, 9), book_images_floor);
    try std.testing.expect(book_images_floor < book_images_cap); // A2 关系钉：下限必低于上限，否则溢出闸与下限闸重叠吞形
    // A3 抽取器正形：合成小样两枚引用，名段含扩展名逐字节钉；非图链接（无 images/ 前缀）不入。
    const sample = "![甲](images/a.svg) 正文 [跳](other/b.md) ![乙](images/c.svg)";
    const got = collectBookImageRefs(sample);
    try std.testing.expectEqual(@as(usize, 2), got.count);
    try std.testing.expect(!got.overflow);
    try std.testing.expectEqualStrings("a.svg", got.names[0]);
    try std.testing.expectEqualStrings("c.svg", got.names[1]);
    // A4 未闭合跨段正形：首引用缺自身 ')' 时名段跨吸入后续直至下个 ')' 的病态串——抽取器不
    // 自作容错，该病态名必在守卫侧 access 验在时以 hidden 现形（推进点只认闭括号，不重复卷入）。
    const broken = "![甲](images/a.svg ![乙](images/c.svg)";
    const bgot = collectBookImageRefs(broken);
    try std.testing.expectEqual(@as(usize, 1), bgot.count);
    try std.testing.expectEqualStrings("a.svg ![乙](images/c.svg", bgot.names[0]);
    // A5 溢出正形：超过 cap 枚时 overflow 置位且 names 只填至 cap，禁静默吞尾。
    var many: [1024]u8 = undefined;
    var mlen: usize = 0;
    var mi: usize = 0;
    while (mi < book_images_cap + 2) : (mi += 1) {
        const seg = std.fmt.bufPrint(many[mlen..], "![x](images/{d}.svg)", .{mi}) catch unreachable;
        mlen += seg.len;
    }
    const mgot = collectBookImageRefs(many[0..mlen]);
    try std.testing.expect(mgot.overflow);
    try std.testing.expectEqual(book_images_cap, mgot.count);
    // A6 声明判据正反形：全串 `](images/<名>.svg)` 命中才算；近似名（前缀包含）不得误命中。
    try std.testing.expect(bookDeclaresImage(sample, "a"));
    try std.testing.expect(bookDeclaresImage(sample, "c"));
    try std.testing.expect(!bookDeclaresImage(sample, "b")); // 非图链接名不入
    try std.testing.expect(!bookDeclaresImage(sample, "a2")); // 反锚：若引用形改为无名尾验的宽匹配，此钉即红
}

test "第 300 轮 T0 书稿 demo 引用面：六枚点名针 want 对拍＋三枚纯函数合成小样正反形（D159）" {
    // A1 点名针派生形对拍：want 表独立手抄（反引号形全串）——hub 表/前两段切形任一改动即此钉红。
    const want = [_][]const u8{
        "`demo/hello`",
        "`demo/multi`",
        "`demo/nested`",
        "`demo/syntax`",
        "`demo/errors`",
        "`demo/fullwidth`",
    };
    try std.testing.expectEqual(want.len, book_demo_face.len); // A2 基数钉：与 hub 入口表同骨
    inline for (book_demo_face, 0..) |c, i| {
        try std.testing.expectEqualStrings(want[i], c.needle);
    }
    // A3 build 针形钉：hello 源须被 matcher 步 addFileArg（派生形与独立手拄全串对拍）。
    try std.testing.expectEqual(@as(usize, 1), bookdemo_build_face.len);
    try std.testing.expectEqualStrings(
        "addFileArg(b.path(\"demo/hello/src/main.zz\"))",
        bookdemo_build_face[0].needle,
    );
    try std.testing.expectEqual(@as(usize, 16), book_demo_cap);
    // A4 抽取器正形：具体名入集；泛引用 `demo/`、通配 `demo/*`、子路径 `demo/a/b` 皆不入。
    const sample = "文本 `demo/hello`、`demo/` 、`demo/*` 与 `demo/a/b` 尾 `demo/multi`";
    const got = collectBookDemoRefs(sample);
    try std.testing.expectEqual(@as(usize, 2), got.count);
    try std.testing.expectEqualStrings("hello", got.names[0]);
    try std.testing.expectEqualStrings("multi", got.names[1]);
    // A5 去首行正反形：多行回体（不含首行）；单行无换行回 null。
    try std.testing.expectEqualStrings("b\nc", stripFirstLine("a\nb\nc").?);
    try std.testing.expectEqual(null, stripFirstLine("single"));
    // A6 期望抽取正反形：命中行取双引号间串；非目标 entry/无引号形回 null。
    const script = "其他行\nassert_run demo/hello/src/main.zz \"数量是：11\"\nassert_run demo/multi/src/main.zz \"结果=42\"\n";
    try std.testing.expectEqualStrings("数量是：11", smokeExpectFor(script, "demo/hello/src/main.zz").?);
    try std.testing.expectEqualStrings("结果=42", smokeExpectFor(script, "demo/multi/src/main.zz").?);
    try std.testing.expectEqual(null, smokeExpectFor(script, "demo/nested/src/main.zz"));
    try std.testing.expectEqual(null, smokeExpectFor("assert_run x 无引号", "x"));
}

test "第 302 轮 T0 两面文档路径单源：值钉＋doc38_build_face 基数/形钉（D161）" {
    // 路径值钉：want 独立手抄——hub 侧改名即红，守卫 fallback 与 build 片同此真值。
    try std.testing.expectEqualStrings("docs/方案书.md", plan_doc_path);
    try std.testing.expectEqualStrings("docs/contributing-lang-pack.md", contrib_doc_path);
    try std.testing.expectEqual(@as(usize, 2), doc38_build_face.len); // 基数钉：两面各一枚，防面膨/降臂
    // 针形钉：want 逐字节对拍（含步名限定形——D73 同路径片不顶 matcher 步的教训沿形）。
    try std.testing.expectEqualStrings(
        "check_matcher_run.addFileArg(b.path(\"docs/方案书.md\"))",
        doc38_build_face[0].needle,
    );
    try std.testing.expectEqualStrings(
        "check_matcher_run.addFileArg(b.path(\"docs/contributing-lang-pack.md\"))",
        doc38_build_face[1].needle,
    );
}

test "第 305 轮 T0 扩展 README 路径单源：值钉＋doc41 步名针 want 对拍（D164）" {
    // A1 路径值独立手抄对拍——hub 侧改名即红，守卫 fallback 与 build 第 22 片同此真值。
    try std.testing.expectEqualStrings("editors/vscode/README.md", ext_readme_path);
    // A2 一枚针基数＋want 逐字节对拍（步名限定形沿 D73）。
    try std.testing.expectEqual(@as(usize, 1), doc41_build_face.len);
    try std.testing.expectEqualStrings(
        "check_matcher_run.addFileArg(b.path(\"editors/vscode/README.md\"))",
        doc41_build_face[0].needle,
    );
}

test "第 306 轮 T0 AGENTS.md 路径单源：值钉＋doc42 步名针 want 对拍（D165）" {
    try std.testing.expectEqualStrings("AGENTS.md", agents_doc_path);
    try std.testing.expectEqual(@as(usize, 1), doc42_build_face.len);
    try std.testing.expectEqualStrings(
        "check_matcher_run.addFileArg(b.path(\"AGENTS.md\"))",
        doc42_build_face[0].needle,
    );
}

test "第 307 轮 T0 断言条数锚解耦：值钉＋两轴关系钉＋count 针随动（D166）" {
    // A1 独立值钉：断言下限逐轮随臂（8→9 第 309 轮第九臂）与入口下限 6 各司两轴。
    try std.testing.expectEqual(@as(usize, 21), smoke_assert_floor);
    try std.testing.expectEqual(@as(usize, 6), demo_count_floor);
    try std.testing.expectEqual(demo_entries.len, demo_count_floor); // 入口轴仍与表基数同数
    try std.testing.expect(smoke_assert_floor > demo_entries.len); // 断言轴已解耦：添臂后必大于入口数
    // A2 条数针随动：needle 值跟断言下限（漂值即脚本对账红）。
    try std.testing.expectEqualStrings("EXPECT_CHECKS=21", demos_smoke_count_face[0].needle); // 第 331 轮 D190 第二十一臂添臂随动（旧值 20）
}

test "第 308 轮 T0 指定语言行为面：fixture 两路径值钉＋面对账基数（D167）" {
    // A1 独立手抄对拍：两枚 fixture 路径字面（判据不取自盘上文件，盘上存在性由第八臂真跑坐实）。
    try std.testing.expectEqualStrings("tools/fixtures/proj-ja/src/main.zz", ja_fixture_src_path);
    try std.testing.expectEqualStrings("tools/fixtures/external-min.txt", ja_fixture_pack_path);
    // A2 面基数与 needle 同源钉：三枚（第 309 轮扩叠加包路径），needle 逐枚等对应路径常量。
    try std.testing.expectEqual(@as(usize, 3), lang_smoke_face.len);
    try std.testing.expectEqualStrings(ja_fixture_src_path, lang_smoke_face[0].needle);
    try std.testing.expectEqualStrings(ja_fixture_pack_path, lang_smoke_face[1].needle);
    try std.testing.expectEqualStrings(overlay_pack_path, lang_smoke_face[2].needle);
    // A3 反形：臆造改名形不在单源。
    try std.testing.expect(!std.mem.eql(u8, ja_fixture_pack_path, "tools/fixtures/external-min2.txt"));
}

test "第 309 轮 T0 叠加包路径单源：值钉＋doc45 步名针 want 对拍（D168）" {
    try std.testing.expectEqualStrings("contrib/packs/httpz-中文.txt", overlay_pack_path);
    try std.testing.expectEqual(@as(usize, 1), doc45_build_face.len);
    try std.testing.expectEqualStrings(
        "check_matcher_run.addFileArg(b.path(\"contrib/packs/httpz-中文.txt\"))",
        doc45_build_face[0].needle,
    );
}

/// 统计源码中 `pub const <名>_face` 的声明数（第 323 轮 D182）：本 hub 属 `src/` 包路径，可
/// `@embedFile` 各 hub 源码；`src/check/machine_matcher_main.zig` 的包路径是 `src/check/`，
/// 跨目录 `@embedFile` 会「embed of file outside package path」编译拒（203 轮硬约束），故那边
/// 改用手抄分项数字、由本测自嵌统计与它对拍——两侧同一批数字即双源夹逼。
pub fn countFaceDecls(src: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    const key = "pub const ";
    while (std.mem.indexOfPos(u8, src, i, key)) |k| {
        var j = k + key.len;
        const start = j;
        while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
        if (std.mem.endsWith(u8, src[start..j], "_face")) n += 1;
        i = if (j > start) j else start + 1;
    }
    return n;
}

// 第 323 轮 T0（D182）：面表清单双源夹逼。guard 侧（matcher）以手抄分项数字 + 「审计＋豁免＝声明数」
// 自校；本测则以 @embedFile 自嵌九个 hub 源码**实测声明数**，与同一批数字对拍——hub 添/删一张
// `*_face` 表而只顾一侧，必在这两侧之一红，堵 322/323 轮反复出现的「清单漏表＝整表静默失守」。
test "第 323 轮 T0 面表声明数双源夹逼（D182）" {
    const specs = [_]struct { path: []const u8, src: []const u8, n: usize }{
        .{ .path = "cli/args.zig", .src = @embedFile("cli/args.zig"), .n = 25 },
        .{ .path = "zzc_paths.zig", .src = @embedFile("zzc_paths.zig"), .n = 28 }, // 第 340 轮 D199：27→28（量化收益两步步名钩子面）
        .{ .path = "lsp/server.zig", .src = @embedFile("lsp/server.zig"), .n = 12 },
        .{ .path = "editor/lsp_config.zig", .src = @embedFile("editor/lsp_config.zig"), .n = 5 },
        .{ .path = "editor/lang_identity.zig", .src = @embedFile("editor/lang_identity.zig"), .n = 5 },
        .{ .path = "vsix.zig", .src = @embedFile("vsix.zig"), .n = 1 },
        .{ .path = "lang/pack.zig", .src = @embedFile("lang/pack.zig"), .n = 4 },
        .{ .path = "lsp/jsonrpc.zig", .src = @embedFile("lsp/jsonrpc.zig"), .n = 1 },
        .{ .path = "machine_contract.zig", .src = @embedFile("machine_contract.zig"), .n = 1 },
    };
    var total: usize = 0;
    for (specs) |sp| {
        const got = countFaceDecls(sp.src);
        if (got != sp.n) std.debug.print("面表声明数分道：{s} 实测 {d} ≠ 手抄 {d}\n", .{ sp.path, got, sp.n });
        try std.testing.expectEqual(sp.n, got);
        total += got;
    }
    // 第 341 轮 D200：自巨型 hub 下沉的**实现模块**不得持面表——面表须与其词汇同源，否则「谁持针」
    // 失去单源（matcher 侧的 `checkFace` 只能按文件读文本）。下沉模块在此逐枚登记为零枚：长出第一张
    // 未审面表即本测红，而不需同步改 matcher 的分项清单（两边仍共 9 hub／82 表）。
    const split_impls = [_]struct { path: []const u8, src: []const u8 }{
        .{ .path = "cli/embed_scan.zig", .src = @embedFile("cli/embed_scan.zig") },
        .{ .path = "lsp/server_query.zig", .src = @embedFile("lsp/server_query.zig") },
    };
    for (split_impls) |im| {
        const got = countFaceDecls(im.src);
        if (got != 0) std.debug.print("面表漂位：下沉实现模块 {s} 持有 {d} 张——须迁回其词汇所属 hub\n", .{ im.path, got });
        try std.testing.expectEqual(@as(usize, 0), got);
    }
    // 总数钉：与 matcher 侧 `expectTableCount` 分项之和（25+19+12+5+5+1+4+1+1）独立手抄对拍。
    try std.testing.expectEqual(@as(usize, 82), total); // 第 340 轮 D199：81→82（zzc_paths 增量化收益钩子面）
}

// 第 340 轮 T0（D199）：量化收益面。上下限与语料形制皆独立手抄值钉（改 hub 必同动本测，否则
// 「闸值被人顺手改小」这类静默松闸无人看）；`measureTestMap` 是本闸的唯一判据，正反小样在此直钉
// ——测映闸程序本身零测（它只做扫目录与读盘），判据漂形只能靠本测接住。
test "第 340 轮 T0 量化收益面：测映判据小样与上下限值钉（D199）" {
    // A1 上下限与扫描根独立手抄（盘上实计低于此即红；抬下限须同动本测）。第 340 轮实计：490 块 / 483‰。
    try std.testing.expectEqualStrings("src", test_map_dir);
    try std.testing.expectEqual(@as(usize, 480), test_block_floor);
    try std.testing.expectEqual(@as(usize, 460), test_share_floor_permille);
    try std.testing.expectEqual(@as(usize, 20_000), bench_units);
    try std.testing.expectEqual(@as(usize, 7), bench_unit_lines);
    try std.testing.expectEqual(@as(usize, 20), bench_ms_per_kilo_ceiling);
    // A2 零测豁免清单：八枚、逐枚以 `src/` 开头且 `.zig` 收尾、彼此互不相同（查重即防同一文件登两行）。
    try std.testing.expectEqual(@as(usize, 8), test_zero_exempt.len);
    for (test_zero_exempt, 0..) |ex, i| {
        try std.testing.expect(std.mem.startsWith(u8, ex, "src/"));
        try std.testing.expect(std.mem.endsWith(u8, ex, ".zig"));
        for (test_zero_exempt[0..i]) |prior| {
            try std.testing.expect(!std.mem.eql(u8, prior, ex));
        }
    }
    // A3 正样：命名 test 块计数与测行计数逐枚对拍（含嵌套缩进括号不提前终止计数）。
    const ok_src = "const x = 1;\ntest \"甲\" {\n    if (a) {\n        try y;\n    }\n}\ntest \"乙\" {\n}\n";
    const m = measureTestMap(ok_src);
    try std.testing.expectEqual(@as(usize, 8), m.lines);
    try std.testing.expectEqual(@as(usize, 2), m.blocks);
    try std.testing.expectEqual(@as(usize, 7), m.test_lines); // 除首行 `const x = 1;` 外皆在测块内
    // A4 反形：匿名聚合器 `test {` 不算命名测块；注释里的同名字串不算；空文零行；无尾换行不多计一行。
    try std.testing.expectEqual(@as(usize, 0), measureTestMap("test {\n    _ = a;\n}\n").blocks);
    try std.testing.expectEqual(@as(usize, 0), measureTestMap("// test \"x\" {\n// }\n").blocks);
    try std.testing.expectEqual(@as(usize, 0), measureTestMap("").lines);
    try std.testing.expectEqual(@as(usize, 2), measureTestMap("a\nb").lines);
    try std.testing.expectEqual(@as(usize, 1), measureTestMap("a\n").lines);
    // A5 语料形制：模板换行数必等于 `bench_unit_lines`（两者失配即行数计量与语料本体分道），
    //     且模板零 ASCII 字母（纯母语形——基准里的极性闸靠的就是这一前提）。
    try std.testing.expectEqual(bench_unit_lines, std.mem.count(u8, bench_unit_fmt, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, bench_unit_fmt, "{d}") != null); // 逐单位序号形（防同形重复）
    var tpl_letters: usize = 0;
    for (bench_unit_fmt) |c| {
        if (std.ascii.isAlphabetic(c)) tpl_letters += 1;
    }
    // 模板零 ASCII 字母——唯一例外是占位符 `{d}` 里那枚 `d`（运行时被序号顶掉，故语料恒纯母语；
    // 基准里的极性闸靠的正是这一前提，模板一旦长出 ASCII 关键字即语料不再纯母语）。
    try std.testing.expectEqual(@as(usize, 1), tpl_letters);
    // A6 步名钩子面：三枚、逐针 occ==1、why 非空；首针由 `test_map_dir` 派生，后两枚是挂 test 的步名形。
    try std.testing.expectEqual(@as(usize, 3), metric_build_face.len);
    for (metric_build_face) |f| {
        try std.testing.expectEqual(@as(usize, 1), f.occ);
        try std.testing.expect(f.why.len > 0);
    }
    try std.testing.expectEqualStrings(
        "check_test_map_run.addDirectoryArg(b.path(\"" ++ test_map_dir ++ "\"))",
        metric_build_face[0].needle,
    );
    try std.testing.expect(std.mem.startsWith(u8, metric_build_face[1].needle, "test_step.dependOn(&"));
    try std.testing.expect(std.mem.startsWith(u8, metric_build_face[2].needle, "test_step.dependOn(&"));
}

// 第 339 轮 T0（D198）：上游漂移周检面。五枚真值（脚本路径／workflow 路径／cron／版本源 URL／
// 漂移标记）+ 三张表基数 + 「针必须是赋值行形」的形制钉（D195 的 M2 判例：只钉裸字面会被脚本
// 顶注里的同名字面垫住，matcher 假绿）+ 反形钉（workflow 不得再抄一份版本字面量——那正是本轮要
// 消灭的第三处手抄）。真跑对账在 matcher 的对面五十；本测只钉「清单本身不漂」。
test "第 339 轮 T0 上游漂移周检面：五枚真值与三面九针派生（D198）" {
    // A1 真值独立手抄（改任一须连同脚本／workflow 同动，否则对面五十红）。
    try std.testing.expectEqualStrings("tools/upstream-watch.sh", upstream_watch_sh);
    try std.testing.expectEqualStrings(".github/workflows/upstream-watch.yml", upstream_watch_yml);
    try std.testing.expectEqualStrings("17 3 * * 1", upstream_watch_cron);
    try std.testing.expectEqualStrings("https://ziglang.org/download/index.json", zig_index_url);
    try std.testing.expectEqualStrings("DRIFT(上游漂移)", drift_marker);
    // A2 脚本面基数四针，且逐针是**赋值行**形：含 `=`、以引号收尾、首字符为字母（不允裸字面）。
    try std.testing.expectEqual(@as(usize, 4), upstream_watch_face.len);
    for (upstream_watch_face) |f| {
        try std.testing.expectEqual(@as(usize, 1), f.occ);
        try std.testing.expect(f.why.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, f.needle, '=') != null);
        try std.testing.expect(std.mem.endsWith(u8, f.needle, "\""));
        try std.testing.expect(std.ascii.isAlphabetic(f.needle[0]));
    }
    // A3 四针逐枚由 hub 真值派生（换源／换回放器／换钉版面皆需同动 hub）。
    try std.testing.expectEqualStrings("index_url=\"" ++ zig_index_url ++ "\"", upstream_watch_face[0].needle);
    try std.testing.expectEqualStrings("drift_marker=\"" ++ drift_marker ++ "\"", upstream_watch_face[1].needle);
    try std.testing.expect(std.mem.indexOf(u8, upstream_watch_face[2].needle, diag_corpus_sh) != null);
    try std.testing.expect(std.mem.indexOf(u8, upstream_watch_face[3].needle, github_ci_path) != null);
    // A4 workflow 面三针的分工：周频针含 cron，取版针含 `--print-pinned`，本体针以 `run: ` 开头。
    try std.testing.expectEqual(@as(usize, 3), upstream_watch_yml_face.len);
    try std.testing.expect(std.mem.indexOf(u8, upstream_watch_yml_face[0].needle, upstream_watch_cron) != null);
    try std.testing.expect(std.mem.indexOf(u8, upstream_watch_yml_face[1].needle, "--print-pinned") != null);
    try std.testing.expect(std.mem.startsWith(u8, upstream_watch_yml_face[2].needle, "run: "));
    // 取版针与本体针皆须点名那枚脚本（周频针只钉 cron 形，不涉脚本名）。
    try std.testing.expect(std.mem.indexOf(u8, upstream_watch_yml_face[1].needle, upstream_watch_sh) != null);
    try std.testing.expect(std.mem.indexOf(u8, upstream_watch_yml_face[2].needle, upstream_watch_sh) != null);
    for (upstream_watch_yml_face) |f| {
        try std.testing.expect(f.why.len > 0);
    }
    // A5 反形：workflow 面不得出现任何版本字面量/发行位 URL（此处自己拼一份，升钉时三处不同步）。
    for (upstream_watch_yml_face) |f| {
        try std.testing.expect(std.mem.indexOf(u8, f.needle, "0.17.") == null);
        try std.testing.expect(std.mem.indexOf(u8, f.needle, "download/") == null);
    }
    // A6 build 依赖面两针皆为 matcher 步的 addFileArg 形，且逐枚对应一面。
    try std.testing.expectEqual(@as(usize, 2), upstream_watch_build_face.len);
    try std.testing.expect(std.mem.indexOf(u8, upstream_watch_build_face[0].needle, upstream_watch_sh) != null);
    try std.testing.expect(std.mem.indexOf(u8, upstream_watch_build_face[1].needle, upstream_watch_yml) != null);
    for (upstream_watch_build_face) |f| {
        try std.testing.expect(std.mem.startsWith(u8, f.needle, "check_matcher_run.addFileArg(b.path(\""));
        try std.testing.expect(f.why.len > 0);
    }
}

// 第 338 轮 T0（D197）：许可证面。真值五枚（路径/SPDX/署名/年份/署名行）+ 四张表基数 +
// 「声明面三针皆由真值派生」的关系钉——三张声明面各自把短名或路径写进了 markdown/JSON/ZON 三种
// 不同形制，形制不可互代，但**值**必须同源，故本测既钉派生也钉独漂的反形（改 hub 值而不改声明面，
// 派生式针与真跑 matcher 同红；改声明面而不改 hub，本测的独立手抄值钉先红）。
test "第 338 轮 T0 许可证面：五枚真值与四张表派生（D197）" {
    // A1 真值独立手抄（改任一须连同 `LICENSE` 正文同动）。
    try std.testing.expectEqualStrings("LICENSE", license_path);
    try std.testing.expectEqualStrings("MIT", license_spdx);
    try std.testing.expectEqualStrings("tan80", license_holder);
    try std.testing.expectEqualStrings("2026", license_year);
    // A2 署名行派生：全等 + 首尾形制（不可写成 `Copyright 2026` 之类缺 `(c)` 的变体）。
    try std.testing.expectEqualStrings("Copyright (c) 2026 tan80", license_copyright);
    try std.testing.expect(std.mem.startsWith(u8, license_copyright, "Copyright (c) "));
    try std.testing.expect(std.mem.endsWith(u8, license_copyright, license_holder));
    // A3 正文面基数与针形：四针、逐针 occ==1、why 非空，且首针逐字节等于署名行。
    try std.testing.expectEqual(@as(usize, 4), license_face.len);
    try std.testing.expectEqualStrings(license_copyright, license_face[0].needle);
    for (license_face) |f| {
        try std.testing.expectEqual(@as(usize, 1), f.occ);
        try std.testing.expect(f.why.len > 0);
    }
    // A4 三张声明面各一枚针，且针值皆由 hub 真值派生（含短名或路径子串）。
    try std.testing.expectEqual(@as(usize, 1), license_readme_face.len);
    try std.testing.expectEqual(@as(usize, 1), license_pkg_face.len);
    try std.testing.expectEqual(@as(usize, 1), license_zon_face.len);
    try std.testing.expect(std.mem.indexOf(u8, license_readme_face[0].needle, license_spdx) != null);
    try std.testing.expect(std.mem.indexOf(u8, license_readme_face[0].needle, license_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, license_pkg_face[0].needle, license_spdx) != null);
    try std.testing.expect(std.mem.indexOf(u8, license_zon_face[0].needle, license_path) != null);
    // A5 反形：README 针是 markdown 链接形，不可与 JSON/ZON 形互代（三形制互不包含）。
    try std.testing.expect(std.mem.indexOf(u8, license_pkg_face[0].needle, "](") == null);
    try std.testing.expect(std.mem.indexOf(u8, license_zon_face[0].needle, "](") == null);
    try std.testing.expect(std.mem.endsWith(u8, license_zon_face[0].needle, ","));
    // A6 三张声明面的 why 非空（名实闸要求逐针有由）。
    for (license_readme_face ++ license_pkg_face ++ license_zon_face) |f| {
        try std.testing.expect(f.why.len > 0);
    }
}

// 第 337 轮 T0（D196）：工程根解析面。判据侧（`cli.firstPositional`／`cli.entryForRoot`／
// `cli.entryForSourceDir`）的跳过律与拼串律由 cli 内的 337 T0 直钉；本测补 hub 侧的**清单基数**
// 与**针形**——四针皆 main.zig 的委派/判盘形，且针内不得出现手抄入口全串（入口真值唯 `default_entry`）。
test "第 337 轮 T0 工程根解析面：基数四针与委派形针面（D196）" {
    try std.testing.expectEqual(@as(usize, 4), entry_root_face.len);
    for (entry_root_face) |f| {
        try std.testing.expectEqual(@as(usize, 1), f.occ);
        try std.testing.expect(f.why.len > 0);
        // 针形须落在「解析链」上：要么委派 pickEntryOrRoot，要么委派 I/O 层存在性判定。
        const hit = std.mem.indexOf(u8, f.needle, "pickEntryOrRoot") != null or
            std.mem.indexOf(u8, f.needle, "pathExists") != null;
        try std.testing.expect(hit);
        // 入口全串唯 hub `default_entry` 持真值：面针里手抄入口全串即分道（判据取整串，
        // 不取 `src_dir` 短名——候选变量名 `as_src` 里就含 "src"，短名判据会假红）。
        try std.testing.expect(std.mem.indexOf(u8, f.needle, default_entry) == null);
    }
}

// 第 334 轮 T0（D193）：CI 镜像面。GitHub 仓加建后本仓出现**第二个** CI 面，两面各持一份「该跑哪
// 些门禁」的手抄清单——改一面忘另一面即「本地全绿、推到某侧才发现少跑」，根因与 D157 同族（那时
// 只有一个面，所以只钉了一个）。本测钉单源命令核（值＋表序不变量）、归一器正反小样与镜像面针形。
test "第 334 轮 T0 CI 镜像面：命令核表序不变量＋归一器正反小样＋镜像面命名针（D193）" {
    // A1 路径值钉（独立手抄）：两面各属一侧宿主（GitCode 只读 .gitcode/、GitHub 只读 .github/），
    //    不可互代；改名须此处同动。
    try std.testing.expectEqualStrings(".github/workflows/ci.yml", github_ci_path);
    try std.testing.expect(!std.mem.eql(u8, ci_path, github_ci_path));
    // A2 命令核逐字节对拍（独立手抄 want 表）：增删一条须两处同动。
    const want = [_][]const u8{
        "zig fmt --check src/ build.zig",
        "zig build test --summary all",
        "zig build -Doptimize=ReleaseSafe",
        "zig build -Dtarget=x86_64-windows",
        "zig build -Dtarget=aarch64-macos",
        "bash tools/demos-smoke.sh",
        "sh tools/lsp-live-smoke.sh",
        "node tools/extension-smoke.js",
        "zig build",
    };
    try std.testing.expectEqual(want.len, ci_gate_cmds.len); // 基数钉
    inline for (ci_gate_cmds, 0..) |cmd, i| {
        try std.testing.expectEqualStrings(want[i], cmd);
    }
    // A3 表序不变量（前缀劫持防）：靠前条目不得是靠后条目的**严格前缀**——否则后者所在行恒被
    //    前者认领，该命令永远「缺」，守卫会把齐全的面误判为缺步（裸 `zig build` 必须垫底即此因）。
    for (ci_gate_cmds, 0..) |a, i| {
        for (ci_gate_cmds[i + 1 ..]) |b| {
            try std.testing.expect(!(a.len < b.len and std.mem.startsWith(u8, b, a)));
        }
    }
    // A4 归一器正形：九条俱全且在带 timeout 前缀/尾参数的现实形下 → 0 缺。
    const all = "zig fmt --check src/ build.zig\n" ++
        "timeout 900 zig build test --summary all\n" ++
        "zig build -Doptimize=ReleaseSafe --prefix /tmp/ci-rel\n" ++
        "zig build -Dtarget=x86_64-windows --prefix /tmp/ci-win\n" ++
        "zig build -Dtarget=aarch64-macos --prefix /tmp/ci-mac\n" ++
        "timeout 120 bash tools/demos-smoke.sh\n" ++
        "timeout 30 sh tools/lsp-live-smoke.sh\n" ++
        "timeout 300 node tools/extension-smoke.js\n" ++
        "zig build\n";
    try std.testing.expectEqual(@as(usize, 0), ciGateMissing(all));
    var out: [ci_gate_cmds.len][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), ciGateMiss(all, &out));
    // A5 反形：抽掉 test 行 → 恰 1 缺且点名恰为该条（只报枚数的闸说不出少了哪步，故点名器同测）。
    const no_test = "zig fmt --check src/ build.zig\n" ++
        "zig build -Doptimize=ReleaseSafe --prefix /tmp/ci-rel\n" ++
        "zig build -Dtarget=x86_64-windows --prefix /tmp/ci-win\n" ++
        "zig build -Dtarget=aarch64-macos --prefix /tmp/ci-mac\n" ++
        "timeout 120 bash tools/demos-smoke.sh\n" ++
        "timeout 30 sh tools/lsp-live-smoke.sh\n" ++
        "timeout 300 node tools/extension-smoke.js\n" ++
        "zig build\n";
    try std.testing.expectEqual(@as(usize, 1), ciGateMissing(no_test));
    try std.testing.expectEqual(@as(usize, 1), ciGateMiss(no_test, &out));
    try std.testing.expectEqualStrings("zig build test --summary all", out[0]);
    // A6 边界钉①：注释里提到命令不算执行（CI 注释铺满而实步删掉即假绿形）；裸 `zig build` 也不
    //    被带参数的构建行顶替（表序首中即停，裸条目须自占一行）。
    try std.testing.expectEqual(
        ci_gate_cmds.len - 1,
        ciGateMissing("# zig build test --summary all\nzig build\n"),
    );
    // A6b 两面宿主形制归一：GitHub 面的 `- run: <命令>` 与 GitCode `run: |` 块内的平铺行归一后同形
    //     （不剥这两层，镜像面会被误报「九条全缺」——本轮首跑即撞）。
    try std.testing.expectEqual(
        ci_gate_cmds.len - 2,
        ciGateMissing("      - run: timeout 900 zig build test --summary all\n        run: zig build\n"),
    );
    // A7 边界钉②：只剥 `timeout <数字> ` 前缀——`timeout --foreground …` 等非数字形不剥，故不
    //    算命中（两面现实形皆为数字秒；若某面改此形，本闸与守卫同时红，逼其显式在册）。
    try std.testing.expectEqual(
        ci_gate_cmds.len,
        ciGateMissing("timeout --foreground zig build test --summary all\n"),
    );
    // A8 换行容错：CRLF 行尾与行首尾空白不影响命中（工作区须 LF，但守卫不因脏行尾误红）；
    //    两行命中⇒缺 len-2（仅裸构建与格式门禁两枚）。
    try std.testing.expectEqual(
        ci_gate_cmds.len - 2,
        ciGateMissing("  zig build  \r\nzig fmt --check src/ build.zig\r\n"),
    );
    // A9 镜像面命名针：两枚步名限定针（matcher 步管命令针、D73 版本步管 download/<ver>/ 对账），
    //    同路径两片各管一事——只挂一处即另一半静静脱钩。
    try std.testing.expectEqual(@as(usize, 2), github_ci_build_face.len);
    try std.testing.expectEqualStrings(
        "check_matcher_run.addFileArg(b.path(\".github/workflows/ci.yml\"))",
        github_ci_build_face[0].needle,
    );
    try std.testing.expectEqualStrings(
        "check_ver_run.addFileArg(b.path(\".github/workflows/ci.yml\"))",
        github_ci_build_face[1].needle,
    );
}

// 第 335 轮 T0（D194）：GitHub 发布面。判据仍是「四枚针各管一件事、值逐字节对拍」，但
// 这里多钉一层**派生关系**：第四枚针必须由 `vsix_py_path` 拼出——只改常量不改针（或反过来）
// 即红，防的正是 D151/对面二十九那次「打包器改名、发布件还在塞旧码」的同一类漂移。
test "第 335 轮 T0 发布面：四针值钉＋触发/权限/出口/派生四要素（D194）" {
    // A1 打包器路径值钉（独立手抄，不从被测者取）：release 面第四针与 build 步共用此真值。
    try std.testing.expectEqualStrings("tools/build-vsix.py", vsix_py_path);
    // A2 双推助手路径值钉：README 与操作手册都靠它指路，改名即文档指向不存在的文件。
    try std.testing.expectEqualStrings("tools/push-both.sh", push_both_path);

    // A3 四枚针逐字节对拍（want 独立手抄，禁从 face 表回抄）。
    const want = [_][]const u8{
        "tags: [\"v*\"]",
        "contents: write",
        "gh release create",
        "python3 tools/build-vsix.py",
    };
    try std.testing.expectEqual(want.len, github_release_face.len);
    for (github_release_face, 0..) |c, i| try std.testing.expectEqualStrings(want[i], c.needle);

    // A4 派生关系钉：第四针以 hub 路径收尾（反向：只改 const 则针不同步，A3 与 A4 至少一红）。
    try std.testing.expect(std.mem.endsWith(u8, github_release_face[3].needle, vsix_py_path));
    // A5 触发面钉：首针必须是 tag 过滤（`tags:` 起头）——换成 `branches:` 即发版路径永不进入。
    try std.testing.expect(std.mem.startsWith(u8, github_release_face[0].needle, "tags:"));
    // A6 权限面钉：次针须含写权限词（只读默认值下创建 Release 必 403）。
    try std.testing.expect(std.mem.indexOf(u8, github_release_face[1].needle, "write") != null);
    // A7 出口面钉：第三针须是 gh CLI 动词（第三方 action 形式 `uses:` 不进此针）。
    try std.testing.expect(std.mem.startsWith(u8, github_release_face[2].needle, "gh release "));
    // A8 每针都得有 why（实名面：无理由的针等于没人知道它防什么，删了也无从判断）。
    for (github_release_face) |c| try std.testing.expect(c.why.len > 0);
}

// 第 336 轮 T0（D195）：诊断语料回放的两张面表。与 335 轮同一骨架——值钉 + 派生关系；另加一条
// 「锚点可独立读」：`EXPECT_CASES=3` 必须以字面量在针里可见（人改 floor 而忘改脚本时，A2 与脚本
// 实跑两处同时红，而不是靠派生式自证）。
test "第 336 轮 T0 语料面：条数锚＋语料根＋build 依赖三钉与派生关系（D195）" {
    // A1 条数锚值钉（独立手抄）：hub 的 floor 就是脚本必须写的那个数。
    try std.testing.expectEqual(@as(usize, 3), diag_corpus_floor);
    // A2 条数锚针：字面量可读形 + 派生式同源（两种写法都得对得上，防「只有派生式」时改锚不易发现）。
    try std.testing.expectEqualStrings("EXPECT_CASES=3", diag_corpus_face[0].needle);
    try std.testing.expectEqualStrings(
        "EXPECT_CASES=" ++ std.fmt.comptimePrint("{d}", .{diag_corpus_floor}),
        diag_corpus_face[0].needle,
    );
    // A3 语料根：路径值钉 + 针值对拍（改名不同动即红，防「目录恒空、逐条全绿」）。
    try std.testing.expectEqualStrings("tools/diag-corpus", diag_corpus_dir);
    // 语料根针钉的是**赋值行**而非裸路径：裸路径在脚本注释里也出现，M2 演漂实证会被垫住（注释命中、赋值已漂）。
    try std.testing.expectEqualStrings("cases_dir=\"$root/" ++ diag_corpus_dir ++ "\"", diag_corpus_face[1].needle);
    // A4 回放器路径与 build 侧依赖针（逐字对拍：addFileArg 漏挂即改脚本不重跑）。
    try std.testing.expectEqualStrings("tools/diag-corpus.sh", diag_corpus_sh);
    try std.testing.expectEqualStrings(
        "check_matcher_run.addFileArg(b.path(\"tools/diag-corpus.sh\"))",
        diag_corpus_build_face[0].needle,
    );
    // A5 形态钉：回放器必须落在 tools/ 下（否则语料根与之的相对位置改写，脚本里 `../..` 推断失效）。
    try std.testing.expect(std.mem.startsWith(u8, diag_corpus_sh, "tools/"));
    try std.testing.expect(std.mem.endsWith(u8, diag_corpus_sh, ".sh"));
    // A6 实名面：三枚针都得写清防什么（无理由的针删了也无从判断）。
    for (diag_corpus_face) |c| try std.testing.expect(c.why.len > 0);
    for (diag_corpus_build_face) |c| try std.testing.expect(c.why.len > 0);
}
