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

/// 清单中以字面形 `"language": "<id>"` 携语言 id 的贡献块数（第 248 轮 · D115）：`grammars[]`＋`snippets[]`
/// 各一枚。此二块同形字面量互不引用，若对面只用 presence（`indexOf != null`）判据即坍缩到首现（grammars）、
/// 漏核次现（snippets）——248 t2 探针实锤漂 snippets[0].language 为近名异值 **638/638 全绿静默**（snippets
/// 从此不再关联 .zz 文件、补全片段静默熄灭）。故 language 那枚 needle 以本数作 `occ` 计数下界，两处皆须命中。
pub const language_block_count: usize = 2;

/// 词元名段（`fileTypes`／资产文件名／scopeName 尾段共用）：由方言扩展名真值剥前导点派生。
pub const file_type_stem: []const u8 = blk: {
    const ext = paths.dialect_ext;
    if (ext.len < 2 or ext[0] != '.') @compileError("dialect_ext 须以「.」起头且至少一枚名段字符");
    break :blk ext[1..];
};

/// TextMate 语法作用域名：清单 `grammars[].scopeName` 必须与生成的 tmLanguage 内 `scopeName` 逐字节一致。
pub const scope_name: []const u8 = "source." ++ file_type_stem;

/// 类别 scope 名：TextMate 各高亮条目的 `"<基名>.<词元名段>"` 形（承第 246 轮 D114）。
///   `tmlang.zig` 八枚类别 scope（string.quoted.double／constant.character.escape／constant.numeric／
///   support.function.builtin／support.type.primitive／constant.language／keyword.other／entity.name.namespace）
///   此前皆把 `.zz` 后缀手抄，绕过 `file_type_stem` 真值——第 215 轮 D83 收编 root `scope_name`／fileTypes、
///   第 229 轮 D97 收编注释 scope 时皆漏此八枚（漏员）。t2 探针 P3 实锤：把三处（生成侧模板＋committed＋测内自照）
///   的 `.zz` 同漂为 `.zq` 而 root／fileTypes 不动，**635/635 全绿静默**（同步守卫只核「生成字节==磁盘字节」，从不核派生）。
///   改由本助手单源派生，扩名/改方言扩展名即全体随动；测内手抄字面量随之改读派生形，杜绝自照假锚。
pub fn cat_scope(comptime base: []const u8) []const u8 {
    return base ++ "." ++ file_type_stem;
}

/// problemMatcher 定义名：由程序名真值派生（承 210 轮 D78），`tasks.json` 以 `$`＋本名引用。
pub const matcher_name: []const u8 = paths.prog_name ++ "-machine";

/// 清单/示例里的 matcher 引用形（VSCode 约定：`$` 前缀）。
pub const matcher_ref: []const u8 = "$" ++ matcher_name;

/// 生成资产在 `editors/vscode/` 下的相对路径（清单 `path` 字段去 `./` 后之形）。
pub const grammar_asset_path: []const u8 = "syntaxes/" ++ file_type_stem ++ ".tmLanguage.json";
/// 同上，补全片段资产。
pub const snippets_asset_path: []const u8 = "snippets/" ++ file_type_stem ++ ".json";

/// 客户端入口资产相对路径（清单 `main` 去 `./` 后之形）：`extension.js` 系手编资产（非生成物），
/// 与 grammar/snippets 两枚生成资产同类——皆由 `editors/vscode/` 下的一枚文件承接，守卫逐内容对账
/// （对面四/十一～十五读它核图例/标识/方法/参数/结果/严重度/错误码诸面），却从无针核清单 `main` 是否
/// 指向它（第 249 轮 D116·D83 收 grammar/snippets `path` 针时的漏员）。
pub const client_entry_asset_path: []const u8 = "extension.js";
/// 语言配置资产相对路径（清单 `languages[0].configuration` 去 `./` 后之形）：`language-configuration.json`
/// 由对面十九（`langconf_face`）逐字节核其注释标记内容，却从无针核清单是否指向它（同 D116 漏员）。
pub const langconf_asset_path: []const u8 = "language-configuration.json";

/// 仓根相对的写出路径（生成工具 `emit` 缺省落点·与清单所指同一文件）。
pub const grammar_emit_path: []const u8 = "editors/vscode/" ++ grammar_asset_path;
/// 同上，补全片段。
pub const snippets_emit_path: []const u8 = "editors/vscode/" ++ snippets_asset_path;

// ———————————————————— 语言常量词集与词类判序（第 231 轮 · D99）————————————————————————————
//   「哪些映射值属语言字面常量」与「一个词形归哪一类」的判序，曾在 `src/editor/tmlang.zig`
//   （语法高亮生成侧）与 `src/editor/snippets.zig`（补全/hover 分类侧）各写一份同体手抄、且判序
//   不同。`std.zig.isPrimitive` 的 names 集合本就含 true/false/null/undefined 四枚值名，故必须
//   先判「语言常量」再判「原始类型」，否则四词被 isPrimitive 先吞、误归「类型」。第 169 轮 D56
//   只在 snippets 侧修了此判序，tmlang 侧漏修——231 t2 探针 P1 实锤：改正 tmlang 判序并重生成
//   committed，真/假/空值/未定义 由 types 组移入 literals 组而 **595/595 全绿静默**（语法侧路由
//   语义此前零锚，唯 P1b 的「生成字节==committed 字节」同步守卫可感），而 snippets 侧判序被 server
//   D56 测钉住（P2 改 snippets 判序→6 测红）——一侧有锚一侧零锚的跨模块不对称。本 hub 立词集与
//   判序单一真值，令 tmlang/snippets/server 测三处皆委派之，从结构上杜绝「修一侧漏一侧」。

/// 语言字面常量映射值集：四枚标准 Zig 值名（与 `std.zig.isPrimitive` 的交集即 D56 判序陷阱源）。
pub const language_constants = [_][]const u8{ "true", "false", "null", "undefined" };

/// 映射值是否语言字面常量（供高亮/补全/hover 三侧共判·词集单源）。
pub fn is_language_constant(value: []const u8) bool {
    for (language_constants) |k| {
        if (std.mem.eql(u8, value, k)) return true;
    }
    return false;
}

/// 词类枚举：`classify_kind` 判序的输出；两侧据各自需要映射到 scope（tmlang）/标签（snippets）。
pub const Kind = enum { builtin, constant, type_, keyword, other };

/// 单一判序真值：`@` 前缀→内建，语言常量→字面常量（**必先于原始类型·D56**），原始类型→类型，
/// Zig 关键字→控制流/声明关键字，其余→方言/其他。判序漂移（常量后于 primitive）即四词误入类型。
pub fn classify_kind(value: []const u8) Kind {
    if (value.len > 0 and value[0] == '@') return .builtin;
    if (is_language_constant(value)) return .constant;
    if (std.zig.isPrimitive(value)) return .type_;
    if (std.zig.Token.keywords.has(value)) return .keyword;
    return .other;
}

// ———————————————————— 注释标记族（第 229 轮 · D97）————————————————————————————
//   同一门方言的注释标记散在两处手抄：`src/editor/tmlang.zig` 的 comptime 模板（高亮正则）与
//   `editors/vscode/language-configuration.json`（VSCode 注释快捷键/折叠行为）。229 t2 探针 P1 实锤
//   改后者 `//`→`##`、`/*`→`<<` fresh 592/592 全绿静默（该文件既非 source dep 也不在任何对面），
//   而真编译器（`lexer`）只认 `//` 行注释——`/*` `*/` 属编辑器侧单边声明（blockComment 不支持，已登册）。

/// 行注释标记：真编译器 `lexer` 唯一认得的注释词法（高亮正则与 langconf `lineComment` 共用）。
pub const line_comment: []const u8 = "//";
/// 块注释起始标记（仅编辑器侧声明；`lexer` 不识别，列此为主从同源的词形锚）。
pub const block_begin: []const u8 = "/*";
/// 块注释结束标记（同上）。
pub const block_end: []const u8 = "*/";

/// 转义星的 tmLanguage JSON 文本形：正则 `\*` 经 JSON 字符串编码后为双反斜杠加星（文件内字节）。
/// 标记族里唯一需转义的元字符即 `*`（本版 Zig 禁全局常量引 comptime 局部，故不写成循环转义函数，
/// 而由真值字符拼接派生——改标记真字符即随动，转义位置由标记形状定，229 T0 A2 逐字节钉死其形）。
const esc_star: []const u8 = "\\\\*";

/// 块标记的正则 JSON 文本形（tmLanguage 生成物内字节：`/\\*` 与 `\\*/`）。
pub const tm_block_begin_regex: []const u8 = block_begin[0..1] ++ esc_star;
pub const tm_block_end_regex: []const u8 = esc_star ++ block_end[1..2];

/// 对面·`editors/vscode/language-configuration.json`：注释配置四针（行/块/折叠起止）。
pub const langconf_face = [_]FaceCheck{
    .{ .needle = "\"lineComment\": \"" ++ line_comment ++ "\"", .why = "VSCode 行注释Toggle 须用行注释真值，分道即 Ctrl+/ 注错字符" },
    .{ .needle = "\"blockComment\": [\"" ++ block_begin ++ "\", \"" ++ block_end ++ "\"]", .why = "块注释对须与块标记真值同形（虽 lexer 不识别块注释，声明漂即误导用户写编译器不认的注释）" },
    .{ .needle = "\"start\": \"^\\\\s*" ++ line_comment ++ "\\\\s*#region\\\\b\"", .why = "折叠起点须嵌行注释真值，分道即 #region 折叠静默失效" },
    .{ .needle = "\"end\": \"^\\\\s*" ++ line_comment ++ "\\\\s*#endregion\\\\b\"", .why = "折叠终点同上（另一端）" },
};

/// 对面·生成的 `zz.tmLanguage.json`：注释高亮两针（与 langconf 面同源——两面皆吃 hub 真值即互洽）。
pub const tm_face = [_]FaceCheck{
    .{ .needle = "\"match\": \"" ++ line_comment ++ ".*$\"", .why = "tmLanguage 行注释高亮正则须由行注释真值派生，分道即注释不高亮" },
    .{ .needle = "\"begin\": \"" ++ tm_block_begin_regex ++ "\", \"end\": \"" ++ tm_block_end_regex ++ "\"", .why = "tmLanguage 块注释高亮须由块标记真值派生，与 langconf 声明互洽" },
};

/// 一次对面核对项：逐字节 needle、「分道即何为」的说明与「该 needle 在对面至少应现的枚数」`occ`
/// （守卫据此报错，判据不另立）。`occ` 缺省 1＝presence 语义（承旧 `!missing`）；>1 用于同形多枚 token
/// 的逐枚对账（如清单 grammars/snippets 两处 language），把 presence 首现坍缩面转为计数下界。
pub const FaceCheck = struct {
    needle: []const u8,
    why: []const u8,
    occ: usize = 1,
};

/// 对面·清单 `package.json`：语言 id／扩展名／scopeName／owner／matcher 定义名／四枚资产指针
/// （grammar/snippets 两枚生成物 `path`＋249 D116 补的 main 入口与 languages[].configuration 两枚）。
pub const pkg_face = [_]FaceCheck{
    .{ .needle = "\"id\": \"" ++ language_id ++ "\"", .why = "contributes.languages[0].id 须等于语言 id 真值" },
    .{ .needle = "\"onLanguage:" ++ language_id ++ "\"", .why = "activationEvents 须按同一语言 id 激活" },
    .{ .needle = "\"" ++ paths.dialect_ext ++ "\"", .why = "contributes.languages[0].extensions 须等于方言扩展名真值" },
    .{ .needle = "\"language\": \"" ++ language_id ++ "\"", .why = "grammars/snippets 两处 language 皆须等于语言 id 真值（逐枚计数≥" ++ std.fmt.comptimePrint("{d}", .{language_block_count}) ++ "·漂任一枚即少一枚→红）", .occ = language_block_count },
    .{ .needle = "\"scopeName\": \"" ++ scope_name ++ "\"", .why = "grammars[].scopeName 须与生成侧 tmLanguage 同源，分道即编辑器寻不到 grammar（高亮全废）" },
    .{ .needle = "\"path\": \"./" ++ grammar_asset_path ++ "\"", .why = "grammars[].path 须指向生成器实际写出的 tmLanguage 资产" },
    .{ .needle = "\"path\": \"./" ++ snippets_asset_path ++ "\"", .why = "snippets[].path 须指向生成器实际写出的片段资产" },
    .{ .needle = "\"main\": \"./" ++ client_entry_asset_path ++ "\"", .why = "清单 main 须指向守卫对面四/十一～十五逐内容对账的那枚客户端入口资产，指针漂即 VSCode 加载另一/缺失文件、LSP 整体死而守卫仍绿（D116）" },
    .{ .needle = "\"configuration\": \"./" ++ langconf_asset_path ++ "\"", .why = "清单 languages[0].configuration 须指向守卫对面十九（langconf_face）核其注释标记内容的那枚语言配置资产，指针漂即 VSCode 不加载真 langconf、注释切换/折叠静默失效而守卫读旧路仍绿（D116）" },
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

/// `needle` 在 `text` 中非重叠出现次数（0 即缺）。多枚同形 token 的逐枚对账判据：presence（`!missing`）
/// 只核首现、漏核次现，本函数按枚计数——守卫以 `countOccurrences(text, needle) >= occ` 取代 `!missing`，
/// `occ == 1` 时二者语义全等（计数 0 ⟺ indexOf 落空），仅多枚面（occ > 1）收紧为计数下界。
pub fn countOccurrences(text: []const u8, comptime needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, text[i..], needle)) |k| {
        n += 1;
        i += k + needle.len;
    }
    return n;
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
    // A7 面清单覆盖钉：十一/一/一 枚——新增对面字段须在此随动（防只加常量不加对账面·249 D116 补 main/configuration 两枚资产指针）。
    try testing.expectEqual(@as(usize, 11), pkg_face.len);
    try testing.expectEqual(@as(usize, 1), client_face.len);
    try testing.expectEqual(@as(usize, 1), tasks_face.len);
}

test "第 229 轮 T0 注释标记族派生与双对面 needle 形钉：三枚真值／正则 JSON 文本形／折叠嵌值／近名负例（防 hub 自身失真）" {
    // A1 值钉：注释标记字面真形（与 `lexer` 行注释词法、VSCode 声明三方共用，改形须同时过守卫与两对面）。
    try testing.expectEqualStrings("//", line_comment);
    try testing.expectEqualStrings("/*", block_begin);
    try testing.expectEqualStrings("*/", block_end);
    // A2 派生钉：块标记的正则 JSON 文本形确由真值转义而得（`*`→`\\*` 经 JSON 编码后为双反斜杠），
    //    脱钩（转义形重写/漏逃）即此处红；行注释正则串直接嵌真值（`/` 无需转义）。
    try testing.expectEqualStrings("/\\\\*", tm_block_begin_regex);
    try testing.expectEqualStrings("\\\\*/", tm_block_end_regex);
    try testing.expectEqualStrings("//.*$", line_comment ++ ".*$");
    // A3 needle 形钉：两对面逐字节形（即守卫判据自身的锚）；折叠两针内嵌行注释真值（串位即红）。
    try testing.expectEqualStrings("\"lineComment\": \"//\"", langconf_face[0].needle);
    try testing.expectEqualStrings("\"blockComment\": [\"/*\", \"*/\"]", langconf_face[1].needle);
    try testing.expectEqualStrings("\"start\": \"^\\\\s*//\\\\s*#region\\\\b\"", langconf_face[2].needle);
    try testing.expectEqualStrings("\"end\": \"^\\\\s*//\\\\s*#endregion\\\\b\"", langconf_face[3].needle);
    try testing.expectEqualStrings("\"match\": \"//.*$\"", tm_face[0].needle);
    try testing.expectEqualStrings("\"begin\": \"/\\\\*\", \"end\": \"\\\\*/\"", tm_face[1].needle);
    // A4 判据小样：真面对命中、改名/近名皆缺（防子串假命中：`//`→`///`、`/*`→`<*`）。
    try testing.expect(!missing(langconf_face[0].needle, langconf_face[0].needle));
    try testing.expect(missing("\"lineComment\": \"##\"", langconf_face[0].needle));
    try testing.expect(missing("\"lineComment\": \"///\",", langconf_face[0].needle));
    try testing.expect(missing("\"blockComment\": [\"<<\", \">>\"]", langconf_face[1].needle));
    try testing.expect(missing("\"match\": \"##.*$\"", tm_face[0].needle));
    try testing.expect(missing("\"begin\": \"/\\\\+\", \"end\": \"\\\\+/\"", tm_face[1].needle));
    // A5 面清单基数钉：四/二 枚——新增注释相关对面字段须在此随动（防只加常量不加对账面）。
    try testing.expectEqual(@as(usize, 4), langconf_face.len);
    try testing.expectEqual(@as(usize, 2), tm_face.len);
}

test "第 231 轮 T0 语言常量词集与 classify_kind 判序单源钉：四枚值钉／is_language_constant 行为／判序回归（常量先于 primitive）／基数（防 hub 自身失真与 D56 判序回潮）" {
    // A1 词集值钉 + 基数钉：四枚标准值名逐字节钉住、长度为四（扩充/改名须同时过本钉与两侧委派消费面）。
    try testing.expectEqual(@as(usize, 4), language_constants.len);
    try testing.expectEqualStrings("true", language_constants[0]);
    try testing.expectEqualStrings("false", language_constants[1]);
    try testing.expectEqualStrings("null", language_constants[2]);
    try testing.expectEqualStrings("undefined", language_constants[3]);
    // A2 is_language_constant 行为钉：恰四真 + near-miss（大小写/缀词/尾空/空串）皆假。
    for (language_constants) |k| try testing.expect(is_language_constant(k));
    try testing.expect(!is_language_constant("True"));
    try testing.expect(!is_language_constant("truex"));
    try testing.expect(!is_language_constant("null "));
    try testing.expect(!is_language_constant("undefinedy"));
    try testing.expect(!is_language_constant(""));
    // A3 判序回归钉（D56 核心）：四枚常量必须先于 primitive 归 .constant（若回潮为 primitive 先判即误归 .type_）。
    for (language_constants) |k| try testing.expectEqual(Kind.constant, classify_kind(k));
    // A4 判序不过度捕获钉：真原始类型名（非语言常量）仍归 .type_；@前缀→.builtin；Zig 关键字→.keyword；余者→.other。
    try testing.expectEqual(Kind.type_, classify_kind("bool"));
    try testing.expectEqual(Kind.type_, classify_kind("u8"));
    try testing.expectEqual(Kind.type_, classify_kind("void"));
    try testing.expectEqual(Kind.builtin, classify_kind("@import"));
    try testing.expectEqual(Kind.keyword, classify_kind("fn"));
    try testing.expectEqual(Kind.keyword, classify_kind("if"));
    try testing.expectEqual(Kind.other, classify_kind("常数"));
    try testing.expectEqual(Kind.other, classify_kind(""));
    // A5 交集形状钉（陷阱源实锤）：四枚常量皆同时在 isPrimitive 集内——这正是必须常量先判的根因（若某枚不在交集则本判序修复对该枚多余）。
    for (language_constants) |k| try testing.expect(std.zig.isPrimitive(k));
}

test "第 246 轮 T0 类别 scope 派生助手 cat_scope：单源形钉（基名 + 「.」 + file_type_stem）与八枚类别基名逐字节（防 hub 自身失真）" {
    // 派生形钉：cat_scope 一律以「.」连接基名与词元名段（若 hub 自漂为别的分隔符则全体高亮 scope 失联）。
    try testing.expectEqualStrings("string.quoted.double." ++ file_type_stem, cat_scope("string.quoted.double"));
    // 八枚类别基名（与 tmlang 生成侧一一对应）逐字节以派生形出现——任一枚基名拼错即本钉红（真值面自守）。
    const bases = [_][]const u8{
        "string.quoted.double",
        "constant.character.escape",
        "constant.numeric",
        "support.function.builtin",
        "support.type.primitive",
        "constant.language",
        "keyword.other",
        "entity.name.namespace",
    };
    inline for (bases) |b| {
        const s = cat_scope(b);
        try testing.expectEqualStrings(b, s[0..b.len]);
        try testing.expectEqualStrings(".", s[b.len .. b.len + 1]);
        try testing.expectEqualStrings(file_type_stem, s[b.len + 1 ..]);
    }
}

test "第 248 轮 T0 snippets language 逐枚对账：countOccurrences 计数下界防 presence 首现坠缩（grammars/snippets 两处皆须命中）" {
    // A1 needle 形钉：清单 language 那枚的逐字节形（防 hub 自身失真）。
    const needle = pkg_face[3].needle;
    try testing.expectEqualStrings("\"language\": \"zig-dialect\"", needle);
    // A2 计数判据小样：真形两处齐全→计数=2；漂 snippets 那枚为近名异值→计数降为 1。
    const both =
        \\{ "grammars": [ { "language": "zig-dialect", "scopeName": "source.zz" } ],
        \\  "snippets": [ { "language": "zig-dialect", "path": "./snippets/zz.json" } ] }
    ;
    const drift =
        \\{ "grammars": [ { "language": "zig-dialect", "scopeName": "source.zz" } ],
        \\  "snippets": [ { "language": "zig", "path": "./snippets/zz.json" } ] }
    ;
    try testing.expectEqual(@as(usize, 2), countOccurrences(both, needle));
    try testing.expectEqual(@as(usize, 1), countOccurrences(drift, needle));
    // A3 反锈（本轮假锚形制）：对漂移样 presence 老判据 `missing` 判「不缺」（首现仍在）而计数判据拦下。
    try testing.expect(!missing(drift, needle));
    try testing.expect(countOccurrences(drift, needle) < pkg_face[3].occ);
    // A4 occ 形钉：language 那枚 occ = grammars+snippets 两块（漏块即少一枚→假锚回潮）。
    try testing.expectEqual(@as(usize, 2), pkg_face[3].occ);
    try testing.expectEqual(language_block_count, pkg_face[3].occ);
    // A5 其余八枚 needle 默认 occ=1（presence 语义不变，防误扩计数面）。
    inline for (pkg_face, 0..) |c, i| {
        if (i == 3) continue;
        try testing.expectEqual(@as(usize, 1), c.occ);
    }
    // A6 非重叠计数边界：针首尾相接仍逐枚计（防重叠窗错位漏计）。
    try testing.expectEqual(@as(usize, 2), countOccurrences("abab", "ab"));
    try testing.expectEqual(@as(usize, 0), countOccurrences("a b", "ab"));
}

test "第 249 轮 T0 清单资产指针两枚 needle 形钉：main→extension.js／configuration→language-configuration.json（D116·D83 grammar/snippets path 针漏员）" {
    // A1 真值钉：两枚资产路径 hub 单源字面形（清单指针去 `./` 后之形与守卫所读外部文件名共此一源）。
    try testing.expectEqualStrings("extension.js", client_entry_asset_path);
    try testing.expectEqualStrings("language-configuration.json", langconf_asset_path);
    // A2 needle 形钉：逐字节拼出清单书写形（含键名与 `./` 前缀·形改即守卫与对面两头猜）。
    try testing.expectEqualStrings("\"main\": \"./extension.js\"", pkg_face[7].needle);
    try testing.expectEqualStrings("\"configuration\": \"./language-configuration.json\"", pkg_face[8].needle);
    // A3 判据小样：命中为不缺、近名漂移为缺（防子串假命中·坐实 t2 P1 漂 ext.js/language-config.json 的静默面）。
    try testing.expect(!missing(pkg_full_sample, pkg_face[7].needle));
    try testing.expect(!missing(pkg_full_sample, pkg_face[8].needle));
    try testing.expect(missing("\"main\": \"./ext.js\",", pkg_face[7].needle));
    try testing.expect(missing("\"configuration\": \"./language-config.json\"", pkg_face[8].needle));
    // A4 面清单覆盖钉：两枚新针位于 snippets path 针后、name/owner 针前（防序位漂移误他针）。
    try testing.expectEqualStrings("\"path\": \"./snippets/zz.json\"", pkg_face[6].needle);
    try testing.expectEqualStrings("\"name\": \"zzc-machine\"", pkg_face[9].needle);
    try testing.expectEqual(@as(usize, 11), pkg_face.len);
}

const pkg_full_sample: []const u8 =
    \\{ "main": "./extension.js",
    \\  "contributes": { "languages": [ { "configuration": "./language-configuration.json" } ] } }
;
