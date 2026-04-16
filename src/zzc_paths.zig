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

/// 符号表文件：跨会话稳定的母语名 → ASCII 名映射（D16/D36 语义，恢复失败须传播）。
pub const symbols_file: []const u8 = root ++ "/symbols.txt";

/// `check` 深检时各根的临时发射物（用后即弃、固定同名串行覆盖）。
pub const check_root: []const u8 = root ++ "/tmp_check_root";

/// zig 产物发射旗标前缀（第 224 轮 D92：旧形制下此前缀在两处手抄——本 `check_root_flag`
/// 派生形与 `cmdBuild` 的 `-femit-bin={s}` argv 拼装模板；改持唯一真值后两处皆由它派生）。
pub const emit_bin_prefix: []const u8 = "-femit-bin=";

/// 上者的完整 zig 旗标形（前缀与路径同源，不另立字面量）。
pub const check_root_flag: []const u8 = emit_bin_prefix ++ check_root;

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
};

/// 源码面（忽略面**不得**吞掉的成员，第 202 轮 D70）：我方自己仓里的源码目录与语言包目录——与方言布局族
/// 同名同形（我方吃自己的狗食），若有人为「消脏」把它们加进忽略条目，源码/语言包就不再入库。
pub const source_family = [_][]const u8{
    src_dir,
    src_dir ++ "/lang/packs",
};

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
        try std.testing.expect(std.mem.eql(u8, ".zzc", seg) or std.mem.eql(u8, "logs", seg) or std.mem.eql(u8, "standard", seg)); // 第 213 轮 D81：eject 缺省落点入第三族根
    }
    try std.testing.expectEqual(@as(usize, 10), disk_family.len); // 第 213 轮收编 eject_default_dest

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
}
