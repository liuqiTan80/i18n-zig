//! LSP 客户端接线契约族单一真值（第 216 轮 · D84）：客户端 `editors/vscode/extension.js` 拉起
//! 语言服务器时消费的**配置命名空间**（`getConfiguration('zzc')`）、**键名**（`lspPath`／`lang`）、
//! **回落二进制程序名**（`'zzc'`）、**spawn 子命令词**（`['lsp']`）与**方言旗标**（`'--lang'`），
//! 与清单 `package.json` 声明侧（`configuration.title`／`zzc.lspPath`／`zzc.lang` 属性名）和
//! `src/` 侧族真值（`zzc_paths.prog_name`·210 轮、`cli.sub_lsp`·206 轮、`cli.flag_lang`·207 轮）
//! 互为手抄、互不引用。改任一点的产品后果都是**语言服务器整体失联**：命名空间或键名分道 → 用户
//! 设置静默不生效（改 `zzc.lspPath` 仍找不到二进制、改方言不重启）；`'lsp'` 或 `'--lang'` 分道 →
//! spawn 即报「未知子命令/未知旗标」，编辑器只剩零诊断的空壳。
//!
//! 本族既有防线只存在于 `tools/check-demos.ps1` 的「lsp client guard」节（第 157 轮），而本机与
//! CI 的 `zig build test` 链皆 NO_PWSH 不可跑——t2 探针 P1–P6／P8 七路 568/568 全绿实证这条防线
//! 对本构建链等于零；对照 P7（改 `cli.sub_lsp` 真值）4 测红，坐实 src 侧已锈、唯 js 侧不接。
//!
//! 设计原则（承 200/203/208/210/214/215 轮形制）：
//!   - 派生优先：命名空间＝程序名真值，键前缀／回落二进制名／清单属性全名皆自它再派生；
//!     子命令词与旗标名直接取 `cli` 族真值，src 侧改名即令守卫报错——把「改名须同步 js」变成硬闸；
//!   - 判据入 hub：对面逐字节 needle 与后果说明全在本模块，守卫步只做 I/O 与退出码；
//!   - 不可越的边界：对面文件在 `src/` 包路径之外，`@embedFile` 拦死（202 轮硬约束），跨文件对账
//!     只能由声明了 `addFileArg` 的守卫步承担（两文件 203/214/215 轮皆已声明，本轮零新增 I/O）。

const std = @import("std");
const paths = @import("../zzc_paths.zig");
const cli = @import("../cli/args.zig");

/// 配置命名空间：`getConfiguration('<本名>')` 与清单 `configuration.title`／属性键前缀共用，
/// 由程序名单一真值派生（承 210 轮 D78——改名即全族同动）。
pub const namespace: []const u8 = paths.prog_name;

/// 键名·可执行文件路径（清单属性 = `namespace ++ "." ++ key_lsp_path`）。
pub const key_lsp_path: []const u8 = "lspPath";
/// 键名·方言包（清单属性 = `namespace ++ "." ++ key_lang`）。
pub const key_lang: []const u8 = "lang";
/// 键名·第三方叠加层（清单属性 = `namespace ++ "." ++ key_overlay`，第 286 轮 D145）。
pub const key_overlay: []const u8 = "langOverlay";

/// 清单里的完整属性名（`contributes.configuration.properties` 的键）。
pub const pkg_key_lsp_path: []const u8 = namespace ++ "." ++ key_lsp_path;
/// 同上，方言包键。
pub const pkg_key_lang: []const u8 = namespace ++ "." ++ key_lang;
/// 同上，叠加层键（第 286 轮 D145）。
pub const pkg_key_overlay: []const u8 = namespace ++ "." ++ key_overlay;

/// 客户端「语言服务器启动失败」人读提示里教用户「装哪个二进制／改哪个设置键」的那句文案
/// （第 250 轮 · D117）：其中程序名 `zzc` 与设置键全名 `zzc.lspPath` 系 `extension.js` 手抄的第二份，
/// 与 hub `namespace`／`pkg_key_lsp_path` 互不引用——改名而提示不随动即误导用户设一个不存在的键、
/// 装一个不叫这名的二进制（`extension.js` 非测图 source dep、旧无针覆盖此句 → `zig build test` 恒绿静默·
/// t2 探针实锤漂 `zzc.lspPath`→`zzc.lspPatX` fresh 642/642 全绿＋check-machine-matcher success）。本常量由
/// 两枚真值 comptime 拼出，`client_face` 据此逐字节钉 `extension.js` 的书写形（一侧改名即分道转锚·D105 文案族）。
pub const launch_hint: []const u8 = "请把 " ++ namespace ++ " 装入 PATH，或将 " ++ pkg_key_lsp_path ++ " 设置为其可执行文件路径";

/// 客户端输出面板 tab 名（`OUTPUT_CHANNEL`）与 boot 就绪提示里的 `zzc lsp` 文案（第 252 轮 · D119）：由
/// namespace（程序名）与 cli.sub_lsp（子命令词）两真值派生·系二者复合手抄，`extension.js` 的 OUTPUT_CHANNEL 定义
/// 与 appendLine 就绪语两处各持一份而互不引用——改 prog_name 或 sub_lsp 而文案不随动即 tab 名/就绪提示仍显旧命令串、
/// 误导用户以为是另一工具或旧版残留（extension.js 非测图 source dep·旧无针·t2 漂 OUTPUT_CHANNEL fresh 644/644 全绿静默坐实）。
pub const output_channel: []const u8 = namespace ++ " " ++ cli.sub_lsp;

// ———————————————————— 客户端日志文案族（第 284 轮 · D143）————————————————————
//
// `extension.js` 往输出面板写的四条人读提示，与 `tools/extension-smoke.js` 断言这些提示的针，是同一
// 句话的两份手抄（写侧 appendLine／断言侧 includes·两文件互不引用）。此前 hub 只锚了写侧的「就绪语」
// 一枚（client_face[10]），**断言侧四枚全无锚**，而其中一枚是**反向针**（`!includes('lsp 帧解析错误')`）：
// 写侧把文案改名，反向针即永真——「帧解析无错误」这条断言形存实亡。t2 探针 P1 实锤：写侧漂
// `帧解析错误`→`帧解码错误` → `node tools/extension-smoke.js` 照旧 `PASS：89 项断言全过` 退 0，且
// `zig build test` 17/17 全绿（运行时与构建链双静默，D139/D140 同族）；真宿主里帧解析报错将被这条
// 永真针放过。本轮把四枚文案核收为 hub 单源，正/反两形皆入面，两面同数对账（D142 的恒真闸只盯
// `ok(true,` 形，抓不到这种「针漂致永真」的退化）。

/// 文案核·输出面板就绪提示的尾段（承 252 轮 D119：写侧整句为 `output_channel ++ " " ++ log_ready`，
/// 断言侧则是正则形 `/就绪（能力：/g`——同一句话的两种书写，本轮起二者同骨）。
pub const log_ready: []const u8 = "就绪（能力：";
/// 文案核·帧解析失败提示（前缀 `lsp` 取子命令真值派生；断言侧拿它做**反向针**，故入面形含极性）。
pub const log_parse_err: []const u8 = cli.sub_lsp ++ " 帧解析错误";
/// 文案核·激活横幅（版本号系运行期取自 `package.json`，故只入前缀不入针）。
pub const log_activated: []const u8 = namespace ++ " 扩展已激活（v";
/// 文案核·拉起命令记录（本句无其它 hub 真值可派生，故本常量即单源）。
pub const log_spawn: []const u8 = "启动语言服务器：";

/// 一次对面核对项：逐字节 needle 与「分道即何为」的说明（守卫据此报错，判据不另立）。
pub const FaceCheck = struct {
    needle: []const u8,
    why: []const u8,
};

/// 对面·清单 `package.json`：设置面板抬头与两枚属性全名。
pub const pkg_face = [_]FaceCheck{
    .{ .needle = "\"title\": \"" ++ namespace ++ "\"", .why = "contributes.configuration.title 须等于配置命名空间真值（由程序名派生）" },
    .{ .needle = "\"" ++ pkg_key_lsp_path ++ "\": {", .why = "configuration.properties 须以「<命名空间>.lspPath」声明二进制路径键，客户端据此取值" },
    .{ .needle = "\"" ++ pkg_key_lang ++ "\": {", .why = "configuration.properties 须以「<命名空间>.lang」声明方言键，客户端据此重启换包" },
    .{ .needle = "\"" ++ pkg_key_overlay ++ "\": {", .why = "configuration.properties 须以「<命名空间>.langOverlay」声明叠加层键，客户端据此取值与重启监听——改 namespace 而此处不随动即用户设置叠加层永不生效（第 286 轮 D145·同族二员 lspPath/lang 皆有钉而本键零销）" },
};

/// 对面四十一·扩展 README 配置键面（第 305 轮 D164）：`editors/vscode/README.md` 设置章手抄
/// 三枚配置全名（反引号形 3/5/3 处），而全仓守卫从不读本文件——t2 探针（`zzc lsp→zzc Ips`＋
/// `` `zzc.lang`→`zzc.lng` `` 后重打 vsix 消除字节形信号）fmt/build/test/matcher/demos-smoke/e2e
/// 六道零信号实锤：包线只锁「包↔盘」同形，不锁「README↔真值」语义——开发者照README配 `zzc.lng`
/// 即设置静默不生效。needle 取**反引号全形**：`zzc.lang` 裸形会被 `zzc.langOverlay` 超集污染，
/// 反引号三面形互斥（判据独立手设于此，非从 README 抽取）。
pub const ext_readme_cfg_face = [_]FaceCheck{
    .{ .needle = "`" ++ pkg_key_lsp_path ++ "`", .why = "扩展 README 设置章须按 hub 真值书写全名——改名即开发者照文档配错键（第 305 轮 D164）" },
    .{ .needle = "`" ++ pkg_key_lang ++ "`", .why = "方言键全名同上形制（反引号形避开超集污染）" },
    .{ .needle = "`" ++ pkg_key_overlay ++ "`", .why = "叠加层键全名同上形制（第 305 轮 D164）" },
};

/// 对面·客户端 `extension.js`：命名空间／三枚取值键／回落程序名／spawn 子命令词／方言旗标／
/// 叠加层旗标（第 286 轮 D145）／启动失败提示里的程序名与设置键全名（第 250 轮 D117）／重启监听器 `affectsConfiguration` 监听的
/// 三枚配置全名（第 251 轮 D118／第 286 轮 D145）／`OUTPUT_CHANNEL` 与就绪语里的
/// `zzc lsp` 复合命令串（第 252 轮 D119——namespace＋cli.sub_lsp 的显示文案族）。
pub const client_face = [_]FaceCheck{
    .{ .needle = "getConfiguration('" ++ namespace ++ "')", .why = "客户端 getConfiguration 的命名空间须等于程序名派生真值，分道即用户设置一律读空（lspPath/lang/langOverlay 静默失效）" },
    .{ .needle = ".get('" ++ key_lsp_path ++ "')", .why = "客户端取值键须与清单属性尾段同名，分道即二进制路径设置永不生效" },
    .{ .needle = ".get('" ++ key_lang ++ "')", .why = "客户端取值键须与清单属性尾段同名，分道即方言选择永不生效" },
    .{ .needle = ": '" ++ namespace ++ "';", .why = "留空回落的二进制名须等于程序名真值，分道即 PATH 上的 zzc 寻不到、语言服务器起不来" },
    .{ .needle = "['" ++ cli.sub_lsp ++ "']", .why = "spawn 参数首词须等于子命令真值 `cli.sub_lsp`，src 改名而 js 不随动即「未知子命令」——语言服务器整体失联" },
    .{ .needle = "push('" ++ cli.flag_lang ++ "'", .why = "拉起参数追加的方言旗标须等于 `cli.flag_lang` 真值，分道即非默认方言静默永不生效（js 传旧名、服务端按新名解析）" },
    .{ .needle = launch_hint, .why = "启动失败提示教用户装的二进制名（namespace 派生）与要改的设置键全名（pkg_key_lsp_path 派生）须逐字节等于 hub 真值——改名而提示不随动即误导用户设不存在的键、装错名二进制而构建链恒绿（第 250 轮 D117·t2 漂提示 fresh 642/642 全绿坐实）" },
    .{ .needle = "affectsConfiguration('" ++ pkg_key_lang ++ "')", .why = "重启监听器 e.affectsConfiguration 监听的方言配置项须等于清单全名 pkg_key_lang——改 namespace 而此处不随动即用户换 zzc.lang 后 restartServer 永不触发、--lang 静默失效（第 251 轮 D118·t2 漂全名 fresh 全绿＋check-machine-matcher success 坐实）" },
    .{ .needle = "affectsConfiguration('" ++ pkg_key_lsp_path ++ "')", .why = "重启监听器监听的二进制路径配置项须等于清单全名 pkg_key_lsp_path——改 namespace 而此处不随动即用户改 zzc.lspPath 后不重启、新路径静默不生效；本键全名与 launch_hint 尾段同字，但删本句时提示针 occ=1 仍命中 L79 故须独立立针（第 251 轮 D118）" },
    .{ .needle = "OUTPUT_CHANNEL = '" ++ output_channel ++ "';", .why = "输出面板 tab 名须等于 namespace＋cli.sub_lsp 派生的命令串——改 prog_name 或 sub_lsp 而此处不随动即 tab 名仍显旧命令、误导用户（第 252 轮 D119·t2 漂 OUTPUT_CHANNEL fresh 644/644 全绿静默坐实）" },
    .{ .needle = "'" ++ output_channel ++ " " ++ log_ready, .why = "boot 成功拉起后 appendLine 就绪语里的命令串须同源派生——与 OUTPUT_CHANNEL 同字、独立第二处消费者，改真值不随动即就绪提示仍显旧名（第 252 轮 D119·系 namespace＋cli.sub_lsp 复合文案族）" },
    .{ .needle = ".get('" ++ key_overlay ++ "')", .why = "客户端叠加层取值键须与清单属性尾段同名，分道即用户设置的叠加层路径永不读到——探针 P1 实锤 cfg.get('langOverlay') 漂为 'langOvelray' 时 node_rc=0 test_rc=0（双静默）——第 286 轮 D145" },
    .{ .needle = "push('" ++ cli.flag_lang_overlay ++ "'", .why = "拉起参数追加的叠加层旗标须等于 `cli.flag_lang_overlay` 真值，分道即第三方叠加层永不传递到服务端——与 flag_lang 同骨同形制（第 286 轮 D145）" },
    .{ .needle = "affectsConfiguration('" ++ pkg_key_overlay ++ "')", .why = "重启监听器监听的叠加层配置项须等于清单全名 pkg_key_overlay——改 namespace 而此处不随动即用户改 zzc.langOverlay 后 restartServer 永不触发、叠加层静默失效（第 286 轮 D145）" },
};

/// 对面·写侧 `extension.js` 的另三条日志文案（第 284 轮 D143）：就绪语已由 client_face[10] 钉住，
/// 故本面只补三枚尚无锚的 appendLine 字面（不重复入面免得 hub 内自抄两份）。
pub const log_writer_face = [_]FaceCheck{
    .{ .needle = "appendLine('" ++ log_spawn ++ "'", .why = "客户端记录拉起命令的那句提示须等于 hub 真值——写侧改名而 hub 不随动即断言侧的正针在构建链上零信号，而用户看不到「怎么拉起的」这条唯一可诊断线索（第 284 轮 D143）" },
    .{ .needle = "appendLine('" ++ log_parse_err, .why = "帧解析失败的提示字面须等于 hub 真值（本针不收尾引号：写侧在该串后还接全角冒号才闭合字面，而断言侧无冒号——两形各按其中一种书写钉住，冒号属文案外装）——它是断言侧唯一**反向针**的靶，写侧漂名而针不漂即永真（「帧解析无错误」永远成立），真宿主里的帧流损坏被静默放过（第 284 轮 D143·t2 探针 P1 实锤双静默）" },
    .{ .needle = "appendLine('" ++ log_activated ++ "'", .why = "激活横幅前缀须等于 hub 由 namespace 派生的值——改 prog_name 而文案不随动即横幅与产品名分道，e2e 的版本断言亦当场落空（第 284 轮 D143）" },
};

/// 对面·断言侧 `tools/extension-smoke.js` 的四枚日志针（第 284 轮 D143）：形制逐枚钉死——
/// 正则形含 `/…/g` 边界、反向针含 `!` 极性（翻转成顺向针即缺针），免「针在而断言已死」。
pub const log_assert_face = [_]FaceCheck{
    .{ .needle = "/" ++ log_ready ++ "/g", .why = "readyCount() 的正则须与写侧就绪语同骨——漂形即计数永归 0，第 283 轮的两条握手断言会红，但红因是「判据恒假」而非真缺陷，病因无人报（第 284 轮 D143）" },
    .{ .needle = "!state.output.join('').includes('" ++ log_parse_err ++ "')", .why = "帧解析错误的反向针须逐字节含 `!` 极性——写侧漂名而此处不漂即永真（P1 实锤：运行时 PASS 89 退 0＋构建链全绿），本针同时钉住字符串与极性（第 284 轮 D143）" },
    .{ .needle = "log.includes('" ++ log_activated ++ "'", .why = "激活横幅的断言前缀须等于 hub 真值——与写侧同骨方能让「宿主里看到的版本」与「断言里校的版本」同源（版本号本体运行期取自 package.json·不入针）（第 284 轮 D143）" },
    .{ .needle = "log.includes('" ++ log_spawn ++ "')", .why = "拉起命令记录的断言针须等于 hub 真值——写侧漂名而针不漂即在唯一能验此道的 Linux e2e 里静默失去覆盖（第 284 轮 D143）" },
};

/// `text`（运行时对面全文）是否缺 `needle`（命中即已同步；缺失即分道）。守卫据此循环报错、不自立判据。
pub fn missing(text: []const u8, comptime needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) == null;
}

// ———————————————————————————— 测试（216 T0）————————————————————————————

const testing = std.testing;

test "第 216 轮 T0 LSP 客户端接线族派生与对面 needle 形钉：命名空间派生／属性全名拼装／needle 形制／判据小样" {
    // A1 命名空间派生钉：本族根值由程序名真值派生（改 prog_name 即全族同动·非各写一份）。
    try testing.expectEqualStrings(paths.prog_name, namespace);
    try testing.expectEqualStrings("zzc", namespace);
    // A2 键值钉：两枚键名与清单属性全名的拼装形（点分分隔是 VSCode 配置寻址的唯一形制）。
    try testing.expectEqualStrings("lspPath", key_lsp_path);
    try testing.expectEqualStrings("lang", key_lang);
    try testing.expectEqualStrings("zzc.lspPath", pkg_key_lsp_path);
    try testing.expectEqualStrings("zzc.lang", pkg_key_lang);
    try testing.expectEqualStrings(namespace ++ "." ++ key_lang, pkg_key_lang);
    // A3 CLI 真值同源钉：子命令词与旗标名直接取 `cli` 族（src↔js 方向自此有硬闸）。
    try testing.expectEqualStrings(cli.sub_lsp, "lsp");
    try testing.expectEqualStrings(cli.flag_lang, "--lang");
    // A4 needle 形钉：六枚客户端面与三枚清单面的逐字节形（形改即守卫与对面两头猜）。
    try testing.expectEqualStrings("getConfiguration('zzc')", client_face[0].needle);
    try testing.expectEqualStrings(".get('lspPath')", client_face[1].needle);
    try testing.expectEqualStrings(".get('lang')", client_face[2].needle);
    try testing.expectEqualStrings(": 'zzc';", client_face[3].needle);
    try testing.expectEqualStrings("['lsp']", client_face[4].needle);
    try testing.expectEqualStrings("push('--lang'", client_face[5].needle);
    try testing.expectEqualStrings("\"title\": \"zzc\"", pkg_face[0].needle);
    try testing.expectEqualStrings("\"zzc.lspPath\": {", pkg_face[1].needle);
    try testing.expectEqualStrings("\"zzc.lang\": {", pkg_face[2].needle);
    // A5 判据正反小样：命中为不缺、改名/近名为缺（含 P1–P6 探针形，坐实本轮把静默面逐一转有锚）。
    try testing.expect(!missing("const args = ['lsp'];", client_face[4].needle));
    try testing.expect(missing("const args = ['lsq'];", client_face[4].needle));
    try testing.expect(missing("args.push('--lng', l);", client_face[5].needle));
    try testing.expect(missing("getConfiguration('zzc2')", client_face[0].needle));
    try testing.expect(missing("cfg.get('lspPat2')", client_face[1].needle));
    try testing.expect(missing("? p.trim() : 'zzq';", client_face[3].needle));
    try testing.expect(missing("\"zzc.lspPathX\": {", pkg_face[1].needle));
    try testing.expect(!missing("\"zzc.lang\": {", pkg_face[2].needle));
    // A6 面清单覆盖钉：四／十四枚——新增配置键或接线点须在此随动（防只加常量不加对账面）。
    try testing.expectEqual(@as(usize, 4), pkg_face.len);
    try testing.expectEqual(@as(usize, 14), client_face.len);
}

// ———————————————————————————— 测试（250 T0）————————————————————————————

test "第 250 轮 T0 客户端启动失败提示面单源钉：launch_hint 派生值／入面 needle 形钉／漂键反证（D117）" {
    // A1 派生值钉：提示句由 namespace 与 pkg_key_lsp_path 两枚真值 comptime 拼出（独立手抄期望与之对拍·改名即随动）。
    try testing.expectEqualStrings(
        "请把 zzc 装入 PATH，或将 zzc.lspPath 设置为其可执行文件路径",
        launch_hint,
    );
    // A2 入面钉：client_face 第 7 枚（index 6）即本提示 needle（后因 251 轮 D118 追加两枚全名针、252 轮 D119 追加两枚输出文案针、286 轮 D145 追加三枚叠加层针至 14 枚·launch_hint 恒居 index 6 位形不变），守卫据此对账 extension.js。
    try testing.expectEqual(@as(usize, 14), client_face.len);
    try testing.expectEqualStrings(launch_hint, client_face[6].needle);
    // A3 同源反证：提示须内嵌 hub 派生的设置键全名子串；漂键名（zzc.lspPatX）即 missing 真（旧针落空→守卫红）。
    try testing.expect(std.mem.indexOf(u8, launch_hint, pkg_key_lsp_path) != null);
    try testing.expect(missing("请把 zzc 装入 PATH，或将 zzc.lspPatX 设置为其可执行文件路径", launch_hint));
    // A4 程序名派生钉：提示首枚程序名由 namespace（=prog_name）派生，与回落二进制名同字一源。
    try testing.expectEqualStrings(paths.prog_name, namespace);
    try testing.expect(missing("请把 zzq 装入 PATH，或将 zzc.lspPath 设置为其可执行文件路径", launch_hint));
}

// ———————————————————————————— 测试（251 T0）————————————————————————————

test "第 251 轮 T0 客户端重启监听器配置全名面单源钉：affectsConfiguration 两枚 needle 派生形／入面位钉／漂全名反证（D118）" {
    // A1 派生形钉：两枚 needle 由清单全名 pkg_key_lang／pkg_key_lsp_path 内联拼装（改名即随动·非另抄）。
    try testing.expectEqualStrings("affectsConfiguration('zzc.lang')", client_face[7].needle);
    try testing.expectEqualStrings("affectsConfiguration('zzc.lspPath')", client_face[8].needle);
    // A2 入面覆盖钉：client_face 共 14 枚，两枚全名针居 index 7/8（252 轮 D119 又在其后追加两枚输出文案针、286 轮 D145 再追加三枚叠加层针·新增接线点须在此随动）。
    try testing.expectEqual(@as(usize, 14), client_face.len);
    // A3 同源反证：命中形不缺、t2 漂全名（zzc.lanq／zzc.lspPatX）即 missing（旧零针→守卫红的转锚证据）。
    try testing.expect(!missing("if (e.affectsConfiguration('zzc.lang')) restartServer();", client_face[7].needle));
    try testing.expect(missing("if (e.affectsConfiguration('zzc.lanq')) restartServer();", client_face[7].needle));
    try testing.expect(!missing("e.affectsConfiguration('zzc.lspPath')", client_face[8].needle));
    try testing.expect(missing("e.affectsConfiguration('zzc.lspPatX')", client_face[8].needle));
}

// ———————————————————————————— 测试（252 T0）————————————————————————————

test "第 252 轮 T0 客户端输出文案族单源钉：output_channel 派生值／两枚 needle 形钉／漂命令串反证（D119）" {
    // A1 派生值钉：`zzc lsp` 文案由 namespace 与 cli.sub_lsp 两真值派生（改 prog_name 或 sub_lsp 即随动·非手抄）。
    try testing.expectEqualStrings("zzc lsp", output_channel);
    try testing.expectEqualStrings(namespace ++ " " ++ cli.sub_lsp, output_channel);
    // A2 入面位钉：client_face 第 10/11 枚（index 9/10）即输出面板 tab 与就绪语 needle（286 轮后共 14 枚）。
    try testing.expectEqual(@as(usize, 14), client_face.len);
    try testing.expectEqualStrings("OUTPUT_CHANNEL = 'zzc lsp';", client_face[9].needle);
    try testing.expectEqualStrings("'zzc lsp 就绪（能力：", client_face[10].needle);
    // A3 同源反证：命中形不缺、漂命令串（t2 的 'zzc lxp'／就绪旧名）即 missing（旧零针→守卫红的转锚证据）。
    try testing.expect(!missing("const OUTPUT_CHANNEL = 'zzc lsp';", client_face[9].needle));
    try testing.expect(missing("const OUTPUT_CHANNEL = 'zzc lxp';", client_face[9].needle));
    try testing.expect(!missing("channel.appendLine('zzc lsp 就绪（能力：' + x);", client_face[10].needle));
    try testing.expect(missing("channel.appendLine('zzq lsp 就绪（能力：' + x);", client_face[10].needle));
}

// ———————————————————————————— 测试（284 T0）————————————————————————————

test "第 284 轮 T0 客户端日志文案族两面单源钉：四枚文案核派生形／写侧三枚与断言侧四枚 needle 形钉／漂名与翻极性反证（D143）" {
    // A1 文案核钉：四枚核值逐字钉住，且可派生的两枚须由 hub 真值派生而非另抄（改 prog_name／sub_lsp 即随动）。
    try testing.expectEqualStrings("就绪（能力：", log_ready);
    try testing.expectEqualStrings(cli.sub_lsp ++ " 帧解析错误", log_parse_err);
    try testing.expectEqualStrings("lsp 帧解析错误", log_parse_err);
    try testing.expectEqualStrings(namespace ++ " 扩展已激活（v", log_activated);
    try testing.expectEqualStrings("zzc 扩展已激活（v", log_activated);
    try testing.expectEqualStrings("启动语言服务器：", log_spawn);
    // A2 写侧面形钉（三枚）：appendLine 字面的逐字节形（形改即守卫与对面两头猜）。
    try testing.expectEqual(@as(usize, 3), log_writer_face.len);
    try testing.expectEqualStrings("appendLine('启动语言服务器：'", log_writer_face[0].needle);
    try testing.expectEqualStrings("appendLine('lsp 帧解析错误", log_writer_face[1].needle);
    try testing.expectEqualStrings("appendLine('zzc 扩展已激活（v'", log_writer_face[2].needle);
    // A3 断言侧面形钉（四枚）：止 A2 不重复覆盖就绪语——写侧整句仍只由 client_face[10] 一枚钉住，
    //   而断言侧的正则形系另一书写，旧面管不到它（本轮新增的实质价值）。
    try testing.expectEqual(@as(usize, 4), log_assert_face.len);
    try testing.expectEqualStrings("/就绪（能力：/g", log_assert_face[0].needle);
    try testing.expectEqualStrings("!state.output.join('').includes('lsp 帧解析错误')", log_assert_face[1].needle);
    try testing.expectEqualStrings("log.includes('zzc 扩展已激活（v'", log_assert_face[2].needle);
    try testing.expectEqualStrings("log.includes('启动语言服务器：')", log_assert_face[3].needle);
    // A4 探针 P1 形反证（本轮立面的实锤因）：写侧漂 `解析→解码` 即缺针——旧形下构建链全绿而反向针永真，
    //   转锚后守卫当场红；真形则不缺。
    try testing.expect(!missing("channel.appendLine('lsp 帧解析错误：' + e.message);", log_writer_face[1].needle));
    try testing.expect(missing("channel.appendLine('lsp 帧解码错误：' + e.message);", log_writer_face[1].needle));
    // A5 极性反证：断言侧把反向针翻成顺向针（删 `!`）即缺针——本针同时钉住字符串与极性，
    //   斗不过「针在而断言已死」的另一种拆法就不是好针。
    try testing.expect(missing("ok(state.output.join('').includes('lsp 帧解析错误'), '帧解析无错误');", log_assert_face[1].needle));
    try testing.expect(!missing("ok(!state.output.join('').includes('lsp 帧解析错误'), '帧解析无错误');", log_assert_face[1].needle));
    // A6 正则形反证：断言侧将全角括号漂成半角（或丢 `/g`）即缺针——此时 readyCount() 永归 0，
    //   第 283 轮的两条握手断言会红但病因（针形漂）无人报。
    try testing.expect(!missing("return (state.output.join('').match(/就绪（能力：/g) || []).length;", log_assert_face[0].needle));
    try testing.expect(missing("return (state.output.join('').match(/就绪(能力:/g) || []).length;", log_assert_face[0].needle));
    try testing.expect(missing("return (state.output.join('').match(/就绪（能力：/) || []).length;", log_assert_face[0].needle));
    // A7 同骨反证：写侧与断言侧共用的文案核一旦分家（一侧改字），两面各自缺针即两面皆红——
    //   而非「另一侧仍绿」的静默分道（本轮要消除的正是这个）。
    try testing.expect(missing("channel.appendLine('zzc 扩展已激活（v' + version + '）');", log_writer_face[0].needle));
    try testing.expect(!missing("channel.appendLine('zzc 扩展已激活（v' + version + '）');", log_writer_face[2].needle));
}

// ──────────────────────────────────────── 测试（286 T0）────────────────────────────────────────

test "第 286 轮 T0 叠加层配置键三面单源钉：key_overlay/pkg_key_overlay 派生形＋4 枚 needle 形钉＋P1 探针反证（D145）" {
    // A1 派生值钉：key_overlay 与 pkg_key_overlay 由 namespace 派生，与同族二员（lspPath/lang）同形制。
    try testing.expectEqualStrings("langOverlay", key_overlay);
    try testing.expectEqualStrings("zzc.langOverlay", pkg_key_overlay);
    try testing.expectEqualStrings(namespace ++ "." ++ key_overlay, pkg_key_overlay);
    // A2 cli 旗标同源钉：叠加层旗标取 `cli.flag_lang_overlay` 真值（不另抄）。
    try testing.expectEqualStrings("--lang-overlay", cli.flag_lang_overlay);
    // A3 needle 形钉：四枚新针的逐字节形（与 js/package.json 实文对拍）。
    try testing.expectEqualStrings(".get('langOverlay')", client_face[11].needle);
    try testing.expectEqualStrings("push('--lang-overlay'", client_face[12].needle);
    try testing.expectEqualStrings("affectsConfiguration('zzc.langOverlay')", client_face[13].needle);
    try testing.expectEqualStrings("\"zzc.langOverlay\": {", pkg_face[3].needle);
    // A4 探针 P1 反证：js 取值键漂 `langOverlay`→`langOvelray` 即缺针（本轮立面的实锤因）。
    try testing.expect(missing("const p = cfg.get('langOvelray');", client_face[11].needle));
    try testing.expect(!missing("const p = cfg.get('langOverlay');", client_face[11].needle));
    // A5 旗标漂反证：`--lang-overlay` 改为 `--lang-overlayr` 即缺针。
    try testing.expect(missing("args.push('--lang-overlayr', o);", client_face[12].needle));
    try testing.expect(!missing("if (o) args.push('--lang-overlay', o);", client_face[12].needle));
    // A6 全名漂反证：重启监听器的 namespace 漂（zzc→zzq）即缺针。
    try testing.expect(missing("e.affectsConfiguration('zzq.langOverlay')", client_face[13].needle));
    try testing.expect(!missing("|| e.affectsConfiguration('zzc.langOverlay')) restartServer();", client_face[13].needle));
    // A7 清单漂反证：package.json 的属性名漂即缺针。
    try testing.expect(missing("\"zzc.langOvelray\": {", pkg_face[3].needle));
    try testing.expect(!missing("\"zzc.langOverlay\": {", pkg_face[3].needle));
}

test "第 305 轮 T0 扩展 README 配置键面：反引号三面形 want 对拍＋基数＋超集污染反形（D164）" {
    // A1 want 独立手抄逐字节对拍＋基数钉（三面形反引号全名，判据非从 README 抽取）。
    const want = [_][]const u8{ "`zzc.lspPath`", "`zzc.lang`", "`zzc.langOverlay`" };
    try testing.expectEqual(want.len, ext_readme_cfg_face.len);
    inline for (ext_readme_cfg_face, 0..) |c, i| {
        try testing.expectEqualStrings(want[i], c.needle);
    }
    // A2 超集污染反形：`zzc.lang` 全形（含尾反引号）不匹 overlay 反引号形——裸键前缀形在此避开。
    try testing.expect(missing("`zzc.langOverlay`", ext_readme_cfg_face[1].needle));
    try testing.expect(!missing("`zzc.lang`", ext_readme_cfg_face[1].needle));
    // A3 探针鬼词形缺针反证：漂形 `zzc.lng` 不含真值针。
    try testing.expect(missing("设置 `zzc.lng`（第 163 轮）", ext_readme_cfg_face[1].needle));
    try testing.expect(!missing("设置 `zzc.lang`（第 163 轮）", ext_readme_cfg_face[1].needle));
}
