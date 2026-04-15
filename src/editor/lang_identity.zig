//! 编辑器语言标识族单一真值（第 215 轮 · D82 之后续族）：一门方言在编辑器侧的**身份令牌**——
//! 语言 id、TextMate scopeName、problemMatcher 名、生成资产路径——散在 `src/editor/`（生成器写侧）
//! 与 `editors/vscode/`（清单 `package.json`、客户端 `extension.js`、示例 `tasks.json`）两侧互为
//! 手抄。这类字面量的产品后果是**功能级静默断裂**：scopeName 分道 → 编辑器寻不到 grammar（高亮全废）、
//! language id 分道 → 客户端 `doc.languageId !== LANGUAGE_ID` 一律早退（LSP 全废）、matcher 名分道 →
//! Problems 面板不填、资产路径分道 → 装完插件即 404。第 215 轮 t2 探针 P2/P3/P4/P6/P7/P8 六路实锤
//! 改任一点皆 **567/567 全绿**（唯 P1 改生成侧被测内字面量自照捕获），而 214 轮的假锚注释
//! （`extension.js` 自称 guard-pinned）在 language id 上**再次复现**——守卫读该文件却只核图例。
//!
//! 设计原则（承 200/203/208/210/214 轮形制）：
//!   - 派生优先：词元名段由 `zzc_paths.dialect_ext` 剥前导点而得，`scope_name`／资产路径／matcher
//!     引用名皆自它再派生，`matcher_name` 更自 `zzc_paths.prog_name` 派生——扩名或改名即全族同动；
//!   - 判据入 hub：对面核对用的逐字节 needle 与「缺失即分道」判据全在本模块，守卫步只做 I/O 与退出码；
//!   - 不可越的边界：对面在 `src/` 包路径之外，`@embedFile` 拦死（202 轮硬约束），跨文件对账只能由
//!     声明了 `addFileArg` 的守卫步承担（203/210/214 轮判例）。

const std = @import("std");
const paths = @import("../zzc_paths.zig");

/// 编辑器语言 id：`contributes.languages[0].id`、`activationEvents`、`grammars[].language`、
/// `problemMatchers[].owner` 与客户端 `LANGUAGE_ID` 共用的一名（改此名而清单/客户端不随动即 LSP 静默失效）。
pub const language_id: []const u8 = "zig-dialect";

/// 词元名段（`fileTypes`／资产文件名／scopeName 尾段共用）：由方言扩展名真值剥前导点派生。
pub const file_type_stem: []const u8 = blk: {
    const ext = paths.dialect_ext;
    if (ext.len < 2 or ext[0] != '.') @compileError("dialect_ext 须以「.」起头且至少一枚名段字符");
    break :blk ext[1..];
};

/// TextMate 语法作用域名：清单 `grammars[].scopeName` 必须与生成的 tmLanguage 内 `scopeName` 逐字节一致。
pub const scope_name: []const u8 = "source." ++ file_type_stem;

/// problemMatcher 定义名：由程序名真值派生（承 210 轮 D78），`tasks.json` 以 `$`＋本名引用。
pub const matcher_name: []const u8 = paths.prog_name ++ "-machine";

/// 清单/示例里的 matcher 引用形（VSCode 约定：`$` 前缀）。
pub const matcher_ref: []const u8 = "$" ++ matcher_name;

/// 生成资产在 `editors/vscode/` 下的相对路径（清单 `path` 字段去 `./` 后之形）。
pub const grammar_asset_path: []const u8 = "syntaxes/" ++ file_type_stem ++ ".tmLanguage.json";
/// 同上，补全片段资产。
pub const snippets_asset_path: []const u8 = "snippets/" ++ file_type_stem ++ ".json";

/// 仓根相对的写出路径（生成工具 `emit` 缺省落点·与清单所指同一文件）。
pub const grammar_emit_path: []const u8 = "editors/vscode/" ++ grammar_asset_path;
/// 同上，补全片段。
pub const snippets_emit_path: []const u8 = "editors/vscode/" ++ snippets_asset_path;

/// 一次对面核对项：逐字节 needle 与「分道即何为」的说明（守卫据此报错，判据不另立）。
pub const FaceCheck = struct {
    needle: []const u8,
    why: []const u8,
};

/// 对面·清单 `package.json`：语言 id／扩展名／scopeName／owner／matcher 定义名／两枚资产路径。
pub const pkg_face = [_]FaceCheck{
    .{ .needle = "\"id\": \"" ++ language_id ++ "\"", .why = "contributes.languages[0].id 须等于语言 id 真值" },
    .{ .needle = "\"onLanguage:" ++ language_id ++ "\"", .why = "activationEvents 须按同一语言 id 激活" },
    .{ .needle = "\"" ++ paths.dialect_ext ++ "\"", .why = "contributes.languages[0].extensions 须等于方言扩展名真值" },
    .{ .needle = "\"language\": \"" ++ language_id ++ "\"", .why = "grammars/snippets 的 language 须等于语言 id 真值" },
    .{ .needle = "\"scopeName\": \"" ++ scope_name ++ "\"", .why = "grammars[].scopeName 须与生成侧 tmLanguage 同源，分道即编辑器寻不到 grammar（高亮全废）" },
    .{ .needle = "\"path\": \"./" ++ grammar_asset_path ++ "\"", .why = "grammars[].path 须指向生成器实际写出的 tmLanguage 资产" },
    .{ .needle = "\"path\": \"./" ++ snippets_asset_path ++ "\"", .why = "snippets[].path 须指向生成器实际写出的片段资产" },
    .{ .needle = "\"name\": \"" ++ matcher_name ++ "\"", .why = "problemMatchers[].name 须等于 matcher 名真值（由程序名派生）" },
    .{ .needle = "\"owner\": \"" ++ language_id ++ "\"", .why = "problemMatchers[].owner 须等于语言 id 真值" },
};

/// 对面·客户端 `extension.js`：语言 id 常量声明（214 轮假锚注释的第二枚面）。
pub const client_face = [_]FaceCheck{
    .{ .needle = "const LANGUAGE_ID = '" ++ language_id ++ "';", .why = "客户端 LANGUAGE_ID 须逐字节声明语言 id 真值，分道即所有 doc.languageId 早退、LSP 静默全废" },
};

/// 对面·示例 `tasks.json`：problemMatcher 引用名。
pub const tasks_face = [_]FaceCheck{
    .{ .needle = "\"" ++ matcher_ref ++ "\"", .why = "示例任务的 problemMatcher 须以 \"$\"＋matcher 名引用清单定义，分道即 Problems 面板不填" },
};

/// `text`（运行时对面全文）是否缺 `needle`（命中即已同步；缺失即分道）。守卫据此循环报错、不自立判据。
pub fn missing(text: []const u8, comptime needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) == null;
}

// ———————————————————————————— 测试（215 T0）————————————————————————————

const testing = std.testing;

test "第 215 轮 T0 语言标识族派生与对面 needle 形钉：值钉／剥点派生／prog_name 派生／路径派生（防 hub 自身失真）" {
    // A1 值钉：语言 id 与 matcher 名的字面真形（改名须同时过守卫与清单，此处先钉住本族基线）。
    try testing.expectEqualStrings("zig-dialect", language_id);
    try testing.expectEqualStrings("zzc-machine", matcher_name);
    try testing.expectEqualStrings("$zzc-machine", matcher_ref);
    // A2 剥点派生钉：词元名段确由方言扩展名真值派生（改 dialect_ext 即全族同动·非各写一份）。
    try testing.expectEqualStrings("zz", file_type_stem);
    try testing.expectEqualStrings("source.zz", scope_name);
    try testing.expectEqualStrings(".zz", paths.dialect_ext);
    try testing.expectEqualStrings(scope_name, "source." ++ paths.dialect_ext[1..]);
    // A3 程序名派生钉：matcher 名随 210 轮程序名真值动（脱钩即此处红）。
    try testing.expectEqualStrings(matcher_name, paths.prog_name ++ "-machine");
    // A4 资产路径派生钉：清单所指与生成器所写同址（两枚 emit 路径皆 editors/vscode/ 下相对形）。
    try testing.expectEqualStrings("syntaxes/zz.tmLanguage.json", grammar_asset_path);
    try testing.expectEqualStrings("snippets/zz.json", snippets_asset_path);
    try testing.expectEqualStrings("editors/vscode/syntaxes/zz.tmLanguage.json", grammar_emit_path);
    try testing.expectEqualStrings("editors/vscode/snippets/zz.json", snippets_emit_path);
    // A5 needle 形钉：三面对账用的逐字节形（形改即守卫与对面两头猜，故此钉为守卫判据自身的锚）。
    try testing.expectEqualStrings("\"scopeName\": \"source.zz\"", pkg_face[4].needle);
    try testing.expectEqualStrings("const LANGUAGE_ID = 'zig-dialect';", client_face[0].needle);
    try testing.expectEqualStrings("\"$zzc-machine\"", tasks_face[0].needle);
    // A6 判据小样：命中为不缺、改名/错序为缺（含近名负例，防子串假命中）。
    try testing.expect(!missing("\"scopeName\": \"source.zz\"", pkg_face[4].needle));
    try testing.expect(missing("\"scopeName\": \"source.zq\"", pkg_face[4].needle));
    try testing.expect(missing("\"scopeName\": \"source.zz2\"", pkg_face[4].needle));
    try testing.expect(missing("", client_face[0].needle));
    try testing.expect(!missing("problemMatcher: [\"$zzc-machine\"]", tasks_face[0].needle));
    try testing.expect(missing("problemMatcher: [\"$zzc-machine2\"]", tasks_face[0].needle));
    // A7 面清单覆盖钉：九/一/一 枚——新增对面字段须在此随动（防只加常量不加对账面）。
    try testing.expectEqual(@as(usize, 9), pkg_face.len);
    try testing.expectEqual(@as(usize, 1), client_face.len);
    try testing.expectEqual(@as(usize, 1), tasks_face.len);
}
