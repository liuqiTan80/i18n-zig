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

/// 清单里的完整属性名（`contributes.configuration.properties` 的键）。
pub const pkg_key_lsp_path: []const u8 = namespace ++ "." ++ key_lsp_path;
/// 同上，方言包键。
pub const pkg_key_lang: []const u8 = namespace ++ "." ++ key_lang;

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
};

/// 对面·客户端 `extension.js`：命名空间／两枚取值键／回落程序名／spawn 子命令词／方言旗标／
/// 启动失败提示里的程序名与设置键全名（第 250 轮 D117）／重启监听器 `affectsConfiguration` 监听的
/// 两枚配置全名（第 251 轮 D118——全名的第三处消费者，独立于取值键尾段与提示句）／`OUTPUT_CHANNEL` 与就绪语里的
/// `zzc lsp` 复合命令串（第 252 轮 D119——namespace＋cli.sub_lsp 的显示文案族）。
pub const client_face = [_]FaceCheck{
    .{ .needle = "getConfiguration('" ++ namespace ++ "')", .why = "客户端 getConfiguration 的命名空间须等于程序名派生真值，分道即用户设置一律读空（lspPath/lang 静默失效）" },
    .{ .needle = ".get('" ++ key_lsp_path ++ "')", .why = "客户端取值键须与清单属性尾段同名，分道即二进制路径设置永不生效" },
    .{ .needle = ".get('" ++ key_lang ++ "')", .why = "客户端取值键须与清单属性尾段同名，分道即方言选择永不生效" },
    .{ .needle = ": '" ++ namespace ++ "';", .why = "留空回落的二进制名须等于程序名真值，分道即 PATH 上的 zzc 寻不到、语言服务器起不来" },
    .{ .needle = "['" ++ cli.sub_lsp ++ "']", .why = "spawn 参数首词须等于子命令真值 `cli.sub_lsp`，src 改名而 js 不随动即「未知子命令」——语言服务器整体失联" },
    .{ .needle = "push('" ++ cli.flag_lang ++ "'", .why = "拉起参数追加的方言旗标须等于 `cli.flag_lang` 真值，分道即非默认方言静默永不生效（js 传旧名、服务端按新名解析）" },
    .{ .needle = launch_hint, .why = "启动失败提示教用户装的二进制名（namespace 派生）与要改的设置键全名（pkg_key_lsp_path 派生）须逐字节等于 hub 真值——改名而提示不随动即误导用户设不存在的键、装错名二进制而构建链恒绿（第 250 轮 D117·t2 漂提示 fresh 642/642 全绿坐实）" },
    .{ .needle = "affectsConfiguration('" ++ pkg_key_lang ++ "')", .why = "重启监听器 e.affectsConfiguration 监听的方言配置项须等于清单全名 pkg_key_lang——改 namespace 而此处不随动即用户换 zzc.lang 后 restartServer 永不触发、--lang 静默失效（第 251 轮 D118·t2 漂全名 fresh 全绿＋check-machine-matcher success 坐实）" },
    .{ .needle = "affectsConfiguration('" ++ pkg_key_lsp_path ++ "')", .why = "重启监听器监听的二进制路径配置项须等于清单全名 pkg_key_lsp_path——改 namespace 而此处不随动即用户改 zzc.lspPath 后不重启、新路径静默不生效；本键全名与 launch_hint 尾段同字，但删本句时提示针 occ=1 仍命中 L79 故须独立立针（第 251 轮 D118）" },
    .{ .needle = "OUTPUT_CHANNEL = '" ++ output_channel ++ "';", .why = "输出面板 tab 名须等于 namespace＋cli.sub_lsp 派生的命令串——改 prog_name 或 sub_lsp 而此处不随动即 tab 名仍显旧命令、误导用户（第 252 轮 D119·t2 漂 OUTPUT_CHANNEL fresh 644/644 全绿静默坐实）" },
    .{ .needle = "'" ++ output_channel ++ " 就绪（能力：", .why = "boot 成功拉起后 appendLine 就绪语里的命令串须同源派生——与 OUTPUT_CHANNEL 同字、独立第二处消费者，改真值不随动即就绪提示仍显旧名（第 252 轮 D119·系 namespace＋cli.sub_lsp 复合文案族）" },
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
    // A6 面清单覆盖钉：三／十一 枚——新增配置键或接线点须在此随动（防只加常量不加对账面）。
    try testing.expectEqual(@as(usize, 3), pkg_face.len);
    try testing.expectEqual(@as(usize, 11), client_face.len);
}

// ———————————————————————————— 测试（250 T0）————————————————————————————

test "第 250 轮 T0 客户端启动失败提示面单源钉：launch_hint 派生值／入面 needle 形钉／漂键反证（D117）" {
    // A1 派生值钉：提示句由 namespace 与 pkg_key_lsp_path 两枚真值 comptime 拼出（独立手抄期望与之对拍·改名即随动）。
    try testing.expectEqualStrings(
        "请把 zzc 装入 PATH，或将 zzc.lspPath 设置为其可执行文件路径",
        launch_hint,
    );
    // A2 入面钉：client_face 第 7 枚（index 6）即本提示 needle（后因 251 轮 D118 追加两枚全名针、252 轮 D119 追加两枚输出文案针至 11 枚·launch_hint 恒居 index 6 位形不变），守卫据此对账 extension.js。
    try testing.expectEqual(@as(usize, 11), client_face.len);
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
    // A2 入面覆盖钉：client_face 共 11 枚，两枚全名针居 index 7/8（252 轮 D119 又在其后追加两枚输出文案针·新增接线点须在此随动）。
    try testing.expectEqual(@as(usize, 11), client_face.len);
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
    // A2 入面位钉：client_face 第 10/11 枚（index 9/10）即输出面板 tab 与就绪语 needle。
    try testing.expectEqual(@as(usize, 11), client_face.len);
    try testing.expectEqualStrings("OUTPUT_CHANNEL = 'zzc lsp';", client_face[9].needle);
    try testing.expectEqualStrings("'zzc lsp 就绪（能力：", client_face[10].needle);
    // A3 同源反证：命中形不缺、漂命令串（t2 的 'zzc lxp'／就绪旧名）即 missing（旧零针→守卫红的转锚证据）。
    try testing.expect(!missing("const OUTPUT_CHANNEL = 'zzc lsp';", client_face[9].needle));
    try testing.expect(missing("const OUTPUT_CHANNEL = 'zzc lxp';", client_face[9].needle));
    try testing.expect(!missing("channel.appendLine('zzc lsp 就绪（能力：' + x);", client_face[10].needle));
    try testing.expect(missing("channel.appendLine('zzq lsp 就绪（能力：' + x);", client_face[10].needle));
}
