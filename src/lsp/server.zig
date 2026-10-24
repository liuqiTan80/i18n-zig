//! LSP 服务器分发核（第 156 轮 · 编辑器 LSP 面）：JSON-RPC 报文 → 应答/通知报文。
//! 纯函数核、不触 IO——stdin/stdout 环流与帧收发留在 main.zig 薄接线（不入测试图），
//! 本模块全量进测试图（承 154/155 轮「纯逻辑下沉、编排薄接线」范式）。
//!
//! 能力面（MVP）：
//!   - 生命周期：`initialize`（capabilities：全量文本同步 + hover / 文档大纲 / 跳转定义 / 查找引用 / 同名高亮 / 重命名（含预检）/ 工作区符号 / 参数提示）、`initialized`、
//!     `shutdown`、`exit`（置停旗标由环流侧结束）；
//!   - 文档同步：`didOpen`/`didChange`（全量形）/`didClose`，服务端自持文档表；
//!   - 快路诊断：didOpen/didChange/didClose 后 `publishDiagnostics`——判据取纯函数面
//!     （`translate.preCheck` 全角/词法 + `findEnglishWordForms` 纯母语强制），
//!     消息措辞与 `zzc check` 逐字同形（去路径前缀、坐标改 LSP 0 基）；语义级编译诊断
//!     仍走 154 轮 task/problemMatcher 通道（每次键击起 zig 编译既慢又与 symbols.txt 竞争）；
//!   - 悬停：`textDocument/hover`——光标词（含 `标准库.调试.打印` 点链整体取词）反查
//!     语言包 keywords/aliases，详情分组与 155 轮补全描述同口径（`snippets.classify` 复用）。
//!   - 文档大纲：`textDocument/documentSymbol`——按当前语言包的声明词（fn/struct/enum/union/
//!     const/var）扫描顶层声明，供编辑器大纲/面包屑；词表与 hover 同取 `lang.keywords`，不另立。
//!   - 跳转定义：`textDocument/definition`——光标词命中顶层声明名时返回该声明位置；词元经
//!     lexer 过滤（注释/字符串不参与），当前限同文件、不做作用域消歧。
//!   - 查找引用：`textDocument/references`——光标词解析到同文件顶层声明后，返回全部同名
//!     代码词元（`includeDeclaration` 控制声明项去留）；同名局部变量/字段暂不消歧。
//!   - 同名高亮：`textDocument/documentHighlight`——同上述声明解析，声明位标 Write、其余标
//!     Read；字符串/注释不参与，未解析到声明返空；与引用同界、不做作用域消歧。
//!   - 重命名：`textDocument/rename`——同文件顶层声明全量改名（`WorkspaceEdit.changes`）；
//!     字符串/注释不参与，非法新名/非声明光标返 null；与引用同界、不做作用域消歧。
//!   - 重命名预检：`textDocument/prepareRename`——返回光标词范围与占位符；非声明词/
//!     字符串/注释/未打开文档返 null，F2 在不可改名处不开输入框。
//!   - 工作区符号：`workspace/symbol`——按 `query` 子串过滤服务端文档表内各文档的顶层
//!     声明，返回 `SymbolInformation[]`（name/kind/location{uri,range}）；只搜已打开文档，
//!     不做全盘扫描、不做作用域消歧。
//!   - 参数提示：`textDocument/signatureHelp`——光标落在调用括号内时，按被调名解析同文件
//!     顶层函数声明，返回声明参数标签与按顶层逗号计的活动参数；非调用处/成员调用/未知
//!     被调返 null（不猜跨行参数表）。
//!
//! 坐标制：LSP Position 为 0 基行 + UTF-16 码元列（默认协商制、不声明 positionEncoding）；
//! 换算集中于 positionOfOffset/byteOfPosition 两处纯函数。第 165 轮起有直接边界单测钉往返不变量
//! 与 null/行越界/行尾钳位/astral 代理四支（此前仅经诊断坐标测 (0,8) 间接碰 BMP 形，astral、
//! 行越界 `nl orelse return null`、 astral 独占行低代理查询 else 尾 null 三真支零 fired）。

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const Pack = @import("../lang/pack.zig").Pack;
const lexer = @import("../transpiler/lexer.zig");
const translate = @import("../transpiler/translate.zig");
const fullwidth = @import("../diag/fullwidth.zig");
const snippets = @import("../editor/snippets.zig");
const lang_id = @import("../editor/lang_identity.zig"); // 第 231 轮 D99：字面常量词集取单一真值（与 classify/高亮侧同源）
const paths = @import("../zzc_paths.zig"); // 第 210 轮 D78：诊断 source 标注的程序名取单一真值（与 CLI/编辑器同源）
const cli = @import("../cli/args.zig"); // 第 227 轮 D95：词法诊断 kind 前缀取文案真值 hub（与 CLI 机读出口/ps1 断言同源）

/// 语义 token 图例（第 214 轮 D82 单一真值）：initialize 应答 `tokenTypes`、`tokenTypeOf`/
/// `classToTokenType` 的索引值、客户端 `editors/vscode/extension.js` 的 `SEMANTIC_TOKEN_TYPES`
/// 共此一份——四点位此前各抄 magic number/同名数组且互不引用（t2 探针 P1 改图例序仅 156 测的
/// 手抄副本自照红、P2 改名与 P3 改客户端序恒绿静默），图例改序/改名而索引随动失配即客户端
/// 静默错色。值钉见本文件 214 T0；客户端对面由守卫步 check-machine-matcher 读文件对账（非
/// source dependency，202/203 轮判例）＋ 214 T1 的 @embedFile 字节耦合双保险。
pub const legend_types = [_][]const u8{ "keyword", "type", "function", "variable", "string", "comment", "number" };

/// 词元类型名 → 图例索引（找不到即编译期失败：新增类型名忘配索引无处遁形）。
fn legendIndexOf(comptime name: []const u8) u8 {
    for (legend_types, 0..) |t, i| {
        if (std.mem.eql(u8, t, name)) return @intCast(i);
    }
    @compileError("词元类型「" ++ name ++ "」不在语义图例 legend_types 中");
}

pub const ty_keyword: u8 = legendIndexOf("keyword");
pub const ty_type: u8 = legendIndexOf("type");
pub const ty_function: u8 = legendIndexOf("function");
pub const ty_variable: u8 = legendIndexOf("variable");
pub const ty_string: u8 = legendIndexOf("string");
pub const ty_comment: u8 = legendIndexOf("comment");
pub const ty_number: u8 = legendIndexOf("number");

/// initialize 应答 JSON 中图例段的逐字节形（与 `respond` 拼接形同骨，测钉用同一派生）。
pub const legend_json: []const u8 = "\"tokenTypes\":[" ++ blk: {
    var s: []const u8 = "";
    for (legend_types, 0..) |t, i| {
        if (i > 0) s = s ++ ",";
        s = s ++ "\"" ++ t ++ "\"";
    }
    break :blk s;
} ++ "]";

/// 客户端 `extension.js` 必须逐字节声明的字面量形（守卫步判据的构造也在 hub，
/// 守卫视仅只读 I/O——同 210 轮 `buildDeclaresExe` 形制）。
pub const client_legend_needle: []const u8 = "const SEMANTIC_TOKEN_TYPES = [" ++ blk: {
    var s: []const u8 = "";
    for (legend_types, 0..) |t, i| {
        if (i > 0) s = s ++ ", ";
        s = s ++ "'" ++ t ++ "'";
    }
    break :blk s;
} ++ "]";

/// 从 `extension.js` 文本判「客户端图例逐字节等于服务端真值」（第 214 轮 D82 守卫判据，纯函数）。
pub fn extensionDeclaresLegend(text: []const u8) bool {
    return std.mem.indexOf(u8, text, client_legend_needle) != null;
}

/// 抽 JS 单引号数组字面量 `'a', 'b', …` 的词元序列（第 214 轮 D82 的 214 T1 判据，comptime 纯函数）。
/// 形不合规（引号不配对、数组未闭合）返 null，调用侧据此判失败。现形注：本仓 extension.js 在 `src/`
/// 包路径之外，`@embedFile` 不可越（202/214 轮双重判例），跨文件对账留守卫步唯一通道；本抽取器
/// 供测内小样与守卫侧将来收紧书写形（现守卫用 `extensionDeclaresLegend` 逐字节 needle 形）两用。
pub fn parseClientLegendArray(comptime body: []const u8) ?[legend_types.len][]const u8 {
    var out: [legend_types.len][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] != '\'') return null; // 只认单引号词元形（本仓 extension.js 的既成书写形制）
        var j = i + 1;
        while (j < body.len and body[j] != '\'') j += 1;
        if (j >= body.len) return null;
        if (n >= out.len) return null; // 词元多于图例成员数
        out[n] = body[i + 1 .. j];
        n += 1;
        i = j + 1;
        while (i < body.len and (body[i] == ',' or std.ascii.isWhitespace(body[i]))) i += 1;
    }
    if (n != out.len) return null;
    return out;
}

/// LSP 方法名族（第 218 轮 D86 单一真值）：服务端 dispatch 十七臂、`publishDiagnostics` 通知
/// 写侧（`publishRaw`）与客户端 `editors/vscode/extension.js` 的十八处发起/消费面共此一份——
/// 此前两侧互不引用（t2 探针 P1–P4 实锤 js 侧改名对构建链零信号、真跑 P7 坐实漂形 `didSave`
/// 不发诊断且无任何应答——通知形失联静默），方法词分道即握手不成/诊断冻结/悬停永空，
/// 功能级断裂而测试恒绿。值钉与对面 needle 形钉见本文件 218 T0；客户端对面由守卫步
/// check-machine-matcher 的对面十四对账（复用已读 `extension.js`，零新增 I/O；
/// 202/203 轮判例）。FaceCheck/missing 判据复用 `jsonrpc.zig` 的 217 形制，不另立第二套。
pub const m_initialize = "initialize";
pub const m_initialized = "initialized";
pub const m_shutdown = "shutdown";
pub const m_exit = "exit";
pub const m_didOpen = "textDocument/didOpen";
pub const m_didChange = "textDocument/didChange";
pub const m_didClose = "textDocument/didClose";
pub const m_didSave = "textDocument/didSave";
pub const m_hover = "textDocument/hover";
pub const m_semanticTokensFull = "textDocument/semanticTokens/full";
pub const m_documentSymbol = "textDocument/documentSymbol";
pub const m_definition = "textDocument/definition";
pub const m_references = "textDocument/references";
pub const m_documentHighlight = "textDocument/documentHighlight";
pub const m_codeAction = "textDocument/codeAction";
pub const m_foldingRange = "textDocument/foldingRange";
pub const m_rename = "textDocument/rename";
pub const m_prepareRename = "textDocument/prepareRename";
pub const m_workspaceSymbol = "workspace/symbol";
pub const m_signatureHelp = "textDocument/signatureHelp";
pub const m_selectionRange = "textDocument/selectionRange";
/// 第 279 轮：上下文补全（关键词/类型/别名点链/本文件顶层声明），触发字符 `.`。
pub const m_completion = "textDocument/completion";
pub const m_publishDiagnostics = "textDocument/publishDiagnostics";

/// 对面·`extension.js` 二十三枚 needle（守卫判据的构造也在 hub，守卫视仅只读 I/O——
/// 同 215/216/217 形制；序：生命周期四 → 文档同步四 → 请求十四 → 服务端通知消费一）。
pub const methods_face = [_]jsonrpc.FaceCheck{
    .{ .needle = "request('" ++ m_initialize ++ "', initialize)", .why = "客户端握手发起词须逐字节等于服务端 dispatch 真值——分道即 initialize 应答都收不了，LSP 全废（真跑 P7 坐实漂形零应答）" },
    .{ .needle = "method: '" ++ m_initialized ++ "', params: {} }", .why = "初始化完毕通知词须等于服务端真值——通知形无应答，分道即服务端静默丢弃、无人感知" },
    .{ .needle = "id: ++seq, method: '" ++ m_shutdown ++ "' }", .why = "关闭请求发起词须等于服务端真值——分道即收到 -32601 而非 null 应答，退出序列退化为强杀" },
    .{ .needle = "method: '" ++ m_exit ++ "' })", .why = "退出通知词须等于服务端真值——分道即服务端不置停旗标，只能等管道 EOF 兜底（附 ` })` 尾防误配进程级 child.on('exit') 面）" },
    .{ .needle = "method: '" ++ m_didOpen ++ "',", .why = "打开同步发起词须等于服务端真值——分道即文档不入表，诊断/悬停/语义 token 全空" },
    .{ .needle = "method: '" ++ m_didChange ++ "',", .why = "全文变更同步词须等于服务端真值——分道即诊断冻结在打开一刻，键击零波形" },
    .{ .needle = "method: '" ++ m_didClose ++ "',", .why = "关闭清理词须等于服务端真值——分道即服务端文档表泄漏且波浪线不清空" },
    .{ .needle = "method: '" ++ m_didSave ++ "',", .why = "保存触发 on-save 语义诊断的词须等于服务端真值——分道即语义编译失联（t2 P1 静默 + 真跑 P7 坐实漂形不发诊断）" },
    .{ .needle = "request('" ++ m_hover ++ "', {", .why = "悬停请求词须等于服务端真值——分道即悬停永空（t2 P3 静默面）" },
    .{ .needle = "request('" ++ m_semanticTokensFull ++ "', {", .why = "语义 token 请求词须等于服务端真值——分道即母语高亮退白底" },
    .{ .needle = "request('" ++ m_documentSymbol ++ "', {", .why = "文档大纲请求词须等于服务端真值——分道即大纲恒空（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_definition ++ "', {", .why = "跳转定义请求词须等于服务端真值——分道即定义永空（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_references ++ "', {", .why = "查找引用请求词须等于服务端真值——分道即引用恒空（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_documentHighlight ++ "', {", .why = "同名符号高亮请求词须等于服务端真值——分道即光标处同名高亮恒空（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_codeAction ++ "', {", .why = "快速修复请求词须等于服务端真值——分道即灯泡永不出现（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_foldingRange ++ "', {", .why = "代码折叠请求词须等于服务端真值——分道即折叠区恒空（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_rename ++ "', {", .why = "重命名请求词须等于服务端真值——分道即 F2 改名恒空（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_prepareRename ++ "', {", .why = "重命名预检请求词须等于服务端真值——分道即 F2 不弹输入框（客户端注册了 prepareRename 却永无结果）" },
    .{ .needle = "request('" ++ m_workspaceSymbol ++ "', {", .why = "工作区符号请求词须等于服务端真值——分道即项目符号恒空（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_signatureHelp ++ "', {", .why = "参数提示请求词须等于服务端真值——分道即调用括号提示恒空（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_selectionRange ++ "', {", .why = "智能扩选请求词须等于服务端真值——分道即扩选停在词/行、永不外扩到包围块与整文档（客户端注册了 provider 却永无结果）" },
    .{ .needle = "request('" ++ m_completion ++ "', {", .why = "上下文补全请求词须等于服务端真值——分道即候选恒空（客户端注册了 provider 与 `.` 触发字符却永无结果，补全静默退化为纯 snippets）" },
    .{ .needle = "msg.method === '" ++ m_publishDiagnostics ++ "'", .why = "服务端发布诊断通知的消费订阅词须等于 publishRaw 写侧真值——分道即服务端照发、客户端全瞎，诊断面板恒空（t2 P2 静默面）" },
};

/// LSP 消息本体键族（第 220 轮 D88 单一真值）：`method`/`id`/`params`/`result` 等 JSON 键
/// 系服务端 dispatch 解析臂、应答/通知写侧形串与客户端 `extension.js` 发起/消费面**三份手抄**
/// 共用词——此前互不引用（t2 探针 P1–P3 实锤 js 侧漂键对构建链零信号、真跑 P4 坐实漂形 `td:`
/// 文档不入表、诊断/悬停全空而 575/575 恒绿），键词分道即整条消息静默坠空，功能级断裂。
/// `ek_*` 为写侧形串的转义形（`std.fmt` 模板内 `\"key\"`），与解析臂同字一源——改任一处即两侧
/// 同漂，漂形由 220 T0 的 fixture 同骨钉与 js 面 needle 形钉双向捕获。
pub const k_jsonrpc = "jsonrpc";
pub const k_method = "method";
pub const k_id = "id";
pub const k_params = "params";
pub const k_result = "result";
pub const k_textDocument = "textDocument";
pub const k_uri = "uri";
pub const k_text = "text";
pub const k_contentChanges = "contentChanges";
pub const k_position = "position";
pub const k_line = "line";
pub const k_character = "character";
pub const k_context = "context";
pub const k_includeDeclaration = "includeDeclaration";
pub const k_diagnostics = "diagnostics";
pub const k_start = "start";
pub const k_end = "end";
pub const k_startLine = "startLine";
pub const k_endLine = "endLine";

/// —— D89 诊断项/悬停/错误对象字段族（第 221 轮）：写侧 `semItem`/`diagItem`/`hoverAt`/
/// `errorResponse` 形串的字段词（range/severity/source/message/contents/kind/value/error/
/// code ＋ `markdown` 值），同客户端 `editors/vscode/extension.js` 消费面属性读
/// （`d.range`/`d.message`/`sev(d.severity)`/`d.code`/`res.contents.value`/`contentFormat`
/// 之 `'markdown'`）互为跨侧手抄、互不引用——守卫 214–220 核过帧形/方法词/参数键而
/// 从未核结果体字段；js 非 source dep（t2 探针 P1–P4 字段漂全绿静默），P6 写侧 kind 漂
/// 连测面亦零锚——字段分道即诊断波浪线/悬停渲染/错误码映射静默熄灭。
pub const k_range = "range";
pub const k_selectionRange = "selectionRange";
pub const k_severity = "severity";
pub const k_source = "source";
pub const k_message = "message";
pub const k_contents = "contents";
pub const k_kind = "kind";
pub const k_value = "value";
pub const k_error = "error";
pub const k_code = "code";
pub const v_markdown = "markdown";

/// —— 快速修复键族（第 268 轮）：CodeAction 结果体字段（title/edit/changes/newText，值 quickfix）
/// ——服务端写侧形串与客户端 `extension.js` 消费面（item.title/item.edit.changes/e.newText）
/// 跨侧手抄，随 codeAction 接线一并登记为单一真值。第 269 轮增补 `only`（CodeActionContext
/// 的 kind 过滤器）与 `source.fixAll` 值：客户端把 `context.only` 映射为字符串数组，服务端据此
/// 在「单点 quickfix」与「全文批量修复」两臂间分道——键或值漂即批量臂永不触发。
pub const k_title = "title";
pub const k_edit = "edit";
pub const k_changes = "changes";
pub const k_newText = "newText";
pub const k_only = "only";
/// 第 272 轮：重命名新名（`RenameParams.newName`）与客户端请求体同键。
pub const k_newName = "newName";
/// 第 274 轮：重命名预检占位符（`PrepareRenameResult.placeholder`）与客户端读取同键。
pub const k_placeholder = "placeholder";
/// 第 275 轮：工作区符号（`workspace/symbol`）请求过滤键与结果字段键——客户端写
/// `{ query }`，读 `s.name`/`s.kind`/`s.location.uri`/`s.location.range`。
pub const k_name = "name";
pub const k_location = "location";
pub const k_query = "query";
/// 第 276 轮：参数提示（`SignatureHelp`）结果字段——服务端写 `signatures[].label` /
/// `parameters[].label` / `activeSignature` / `activeParameter`，客户端逐一同键读取。
pub const k_signatures = "signatures";
pub const k_parameters = "parameters";
pub const k_label = "label";
pub const k_activeSignature = "activeSignature";
pub const k_activeParameter = "activeParameter";
/// 第 277 轮：智能扩选（`TextDocumentSelectionRangeParams` / `SelectionRange`）——客户端写
/// `positions[]` 并在递归映射里读 `range` 与 `parent`。
pub const k_positions = "positions";
pub const k_parent = "parent";
/// 第 279 轮：上下文补全（`CompletionList` / `CompletionItem`）——服务端写
/// `isIncomplete`/`items[]`，每项写 `label`/`kind`/`detail`/可选 `documentation` 与
/// `textEdit{range,newText}`（点链补全用于替换整条链前缀）；客户端逐一同键读取。
pub const k_items = "items";
pub const k_isIncomplete = "isIncomplete";
pub const k_detail = "detail";
pub const k_documentation = "documentation";
pub const k_textEdit = "textEdit";
pub const v_quickfix = "quickfix";
pub const v_source_fix_all = "source.fixAll";
/// 第 271 轮：折叠区间 kind 值（LSP `FoldingRangeKind.Comment`）——客户端据此映射
/// `vscode.FoldingRangeKind.Comment`，与注释块折叠写侧同源。
pub const v_comment = "comment";

/// —— D90 诊断严重度码值族（第 222 轮）：LSP `DiagnosticSeverity` 四枚数值码语义映射
/// （1=Error／2=Warning／3=Information／4=Hint）——src 侧 clamp 边界（`semItem` 的
/// `>= 1 and <= 4 else 1`）、快路恒码（`f_fast_item` 之 `:1`）、测侧数值钉，同客户端
/// `extension.js` `sev()` 四支硬编（`s === 1 ? ...Error : s === 2 ? ...Warning :
/// s === 3 ? ...Information : ...Hint`）互为跨侧手抄、互不引用——守卫 214–221 核过
/// 结果体键词而从未核码值语义；t2 探针 P1/P2/P6 js 映射漂／对调全绿静默，P3 clamp
/// 上界 4→3 亦全绿静默（测面对边界 4 零采样钉——Hint 级语义项被钳成 Error、分级虚报）。
/// `sv_*` 四枚为唯一真值，clamp 界、快路渲染、`sv_face` needle 数值与测侧数值钉全由此派生。
pub const sv_error: u8 = 1;
pub const sv_warning: u8 = 2;
pub const sv_information: u8 = 3;
pub const sv_hint: u8 = 4;

/// —— 同名符号高亮种类码值族（第 273 轮）：LSP `DocumentHighlightKind` 三枚协议数值
/// （1=Text／2=Read／3=Write）——写侧 `highlightAt` 分类、测侧值钉与客户端
/// `results_face` 映射针（`h.kind === 3 ? ...Write : ...Read`）全由此源派生。
pub const hk_text: u8 = 1;
pub const hk_read: u8 = 2;
pub const hk_write: u8 = 3;

/// —— D91 JSON-RPC 错误码族（第 223 轮）：协议标准错误码三员（-32700 解析失败／-32600 请求非法／
/// -32601 方法不支持）——src 写侧 handle 三臂内联数值字面、测侧值钉与宽松子串钉，同客户端
/// `extension.js` dispatch 对服务端发起请求的应答臂 `error: { code: -32601, ... }` 互为跨侧手抄、
/// 互不引用——守卫 214–222 核过参数键/结果字段/严重度码值而从未核错误码；t2 探针 P1 js 同码支
/// 漂全绿静默，P4 写侧 `-32601`→`-326011` 加尾亦全绿（宽松子串伪钉——键前缀与完整数值测面零钉）。
/// `ec_*` 三枚为唯一真值，写侧臂、改严形钉、`errors_face` needle 与测侧数值钉全由此派生。
pub const ec_parse_error: i64 = -32700;
pub const ec_invalid_request: i64 = -32600;
pub const ec_method_not_found: i64 = -32601;

/// —— D98 LSP initialize capability 协商串族（第 230 轮）：服务端 `initialize` 应答声明的
/// capability 对象形串（`textDocumentSync` 对象形／`hoverProvider`／`semanticTokensProvider`／
/// `serverInfo`）在三处各持一份手抄——写侧 `handle` 应答字面串、服务端自测 `out.items[0]` 的
/// indexOf 钉、e2e 基线 `check-demos.ps1` LSP 守卫段的 Contains 断言——互不引用；守卫对面
/// 十八／十九只核 ps1 命令词族与码点文案族，从未核这些 JSON capability 形串。t2 探针 P1 独漂
/// ps1 断言 fresh 593/593 全绿静默、P3 写侧＋自测同步演进而 ps1 落单亦 fresh 593/593 全绿静默
/// （ps1 断言与真应答形串已分道，唯 NO_PWSH＋GitCode 双盲此守卫从不触发→静默腐坏·同 D82/D84/D96 假锚族）。
/// `cap_*` 诸枚为唯一真值：写侧应答拼接、自测 indexOf、`cap_face` ps1 needle 全由此派生。
const cap_open_close = "\"openClose\":true";
const cap_change_full = "\"change\":1"; // 全量同步 kind=1（TextDocumentSyncKind.Full）
const cap_save_no_text = "\"save\":{\"includeText\":false}";
const cap_sync_obj = "\"textDocumentSync\":{" ++ cap_open_close ++ "," ++ cap_change_full ++ "," ++ cap_save_no_text ++ "}";
const cap_hover = "\"hoverProvider\":true";
const cap_docsym = "\"documentSymbolProvider\":true";
const cap_def = "\"definitionProvider\":true";
const cap_refs = "\"referencesProvider\":true";
const cap_document_highlight = "\"documentHighlightProvider\":true";
const cap_codeaction = "\"codeActionProvider\":true";
const cap_folding = "\"foldingRangeProvider\":true";
const cap_rename = "\"renameProvider\":{\"prepareProvider\":true}";
const cap_workspace_symbol = "\"workspaceSymbolProvider\":true";
/// 第 276 轮：参数提示能力——触发字符 `(` 与 `,`（键入即弹；能力缺席则客户端不发起请求）。
const cap_signature_help = "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}";
/// 第 277 轮：智能扩选能力——布尔形（客户端据此注册 SelectionRangeProvider）。
const cap_selection_range = "\"selectionRangeProvider\":true";
/// 第 279 轮：上下文补全能力——触发字符 `.`（点链续写即弹；普通词按前缀补全）。
const cap_completion = "\"completionProvider\":{\"triggerCharacters\":[\".\"]}";
const cap_semtok_key = "\"semanticTokensProvider\"";
const cap_semtok = cap_semtok_key ++ ":{\"legend\":{" ++ legend_json ++ ",\"tokenModifiers\":[]},\"full\":true}";
const cap_server_info = "\"serverInfo\":{\"name\":\"" ++ paths.prog_name ++ "-lsp\"}";

/// 对面·`tools/check-demos.ps1` LSP 握手断言 capability 族 needle（守卫对面二十——同 `methods_face`
/// 形制，判据入 hub、守卫视只读 I/O，复用对面十八已读的 ps1 实文、零新增 I/O）。写侧应答形串与
/// ps1 Contains 断言同源：一侧漂形即分道（t2 P1/P3 静默面转锚）。`serverInfo` ps1 零消费不入针（登册）。
pub const cap_face = [_]jsonrpc.FaceCheck{
    .{ .needle = cap_sync_obj, .why = "ps1 断言应答含 save-对象形 sync 形串——与写侧 cap_sync_obj 分道即 e2e LSP 守卫静默失的（双盲从不跑·t2 P1/P3 形）" },
    .{ .needle = cap_hover, .why = "ps1 断言 hoverProvider 在——与写侧漂即能力协商断言与实际应答分道、守卫形同虚设" },
    .{ .needle = cap_semtok_key, .why = "ps1 断言 semanticTokensProvider 在——与写侧键漂即语义高亮供给能力无人核验" },
    .{ .needle = cap_docsym, .why = "ps1 断言 documentSymbolProvider 在——与写侧漂即大纲能力协商断言与实际应答分道" },
    .{ .needle = cap_def, .why = "ps1 断言 definitionProvider 在——与写侧漂即定义能力协商断言与实际应答分道" },
    .{ .needle = cap_refs, .why = "ps1 断言 referencesProvider 在——与写侧漂即引用能力协商断言与实际应答分道" },
    .{ .needle = cap_document_highlight, .why = "ps1 断言 documentHighlightProvider 在——与写侧漂即同名高亮能力协商断言与实际应答分道" },
    .{ .needle = cap_codeaction, .why = "ps1 断言 codeActionProvider 在——与写侧漂即快速修复能力协商断言与实际应答分道" },
    .{ .needle = cap_folding, .why = "ps1 断言 foldingRangeProvider 在——与写侧漂即代码折叠能力协商断言与实际应答分道" },
    .{ .needle = cap_rename, .why = "ps1 断言 renameProvider 在——与写侧漂即重命名能力协商断言与实际应答分道" },
    .{ .needle = cap_workspace_symbol, .why = "ps1 断言 workspaceSymbolProvider 在——与写侧漂即工作区符号能力协商断言与实际应答分道" },
    .{ .needle = cap_signature_help, .why = "ps1 断言 signatureHelpProvider 触发字符形在——与写侧漂即参数提示能力协商断言与实际应答分道" },
    .{ .needle = cap_selection_range, .why = "ps1 断言 selectionRangeProvider 在——与写侧漂即智能扩选能力协商断言与实际应答分道" },
    .{ .needle = cap_completion, .why = "ps1 断言 completionProvider 触发字符形在——与写侧漂即上下文补全能力协商断言与实际应答分道" },
};

/// 写侧转义形（`\"key\"`）：与解析臂同字一源，杜绝两份手抄。
const ek_jsonrpc = "\"" ++ k_jsonrpc ++ "\"";
const ek_id = "\"" ++ k_id ++ "\"";
const ek_params = "\"" ++ k_params ++ "\"";
const ek_result = "\"" ++ k_result ++ "\"";
const ek_uri = "\"" ++ k_uri ++ "\"";
const ek_text = "\"" ++ k_text ++ "\"";
const ek_diagnostics = "\"" ++ k_diagnostics ++ "\"";
const ek_position = "\"" ++ k_position ++ "\"";
const ek_line = "\"" ++ k_line ++ "\"";
const ek_character = "\"" ++ k_character ++ "\"";
const ek_textDocument = "\"" ++ k_textDocument ++ "\"";
const ek_start = "\"" ++ k_start ++ "\"";
const ek_end = "\"" ++ k_end ++ "\"";
const ek_startLine = "\"" ++ k_startLine ++ "\"";
const ek_endLine = "\"" ++ k_endLine ++ "\"";
const ek_range = "\"" ++ k_range ++ "\"";
const ek_selectionRange = "\"" ++ k_selectionRange ++ "\"";
const ek_severity = "\"" ++ k_severity ++ "\"";
const ek_source = "\"" ++ k_source ++ "\"";
const ek_message = "\"" ++ k_message ++ "\"";
const ek_contents = "\"" ++ k_contents ++ "\"";
const ek_kind = "\"" ++ k_kind ++ "\"";
const ek_value = "\"" ++ k_value ++ "\"";
const ek_error = "\"" ++ k_error ++ "\"";
const ek_code = "\"" ++ k_code ++ "\"";
const ek_title = "\"" ++ k_title ++ "\"";
const ek_edit = "\"" ++ k_edit ++ "\"";
const ek_changes = "\"" ++ k_changes ++ "\"";
const ek_newText = "\"" ++ k_newText ++ "\"";
const ek_placeholder = "\"" ++ k_placeholder ++ "\"";
const ek_name = "\"" ++ k_name ++ "\"";
const ek_location = "\"" ++ k_location ++ "\"";
const ek_signatures = "\"" ++ k_signatures ++ "\"";
const ek_parameters = "\"" ++ k_parameters ++ "\"";
const ek_label = "\"" ++ k_label ++ "\"";
const ek_activeSignature = "\"" ++ k_activeSignature ++ "\"";
const ek_activeParameter = "\"" ++ k_activeParameter ++ "\"";
const ek_parent = "\"" ++ k_parent ++ "\"";
const ek_items = "\"" ++ k_items ++ "\"";
const ek_isIncomplete = "\"" ++ k_isIncomplete ++ "\"";
const ek_detail = "\"" ++ k_detail ++ "\"";
const ek_documentation = "\"" ++ k_documentation ++ "\"";
const ek_textEdit = "\"" ++ k_textEdit ++ "\"";
const em_markdown = "\"" ++ v_markdown ++ "\"";
const eq_prog_name = "\"" ++ paths.prog_name ++ "\"";
const ek_v20 = "\"" ++ jsonrpc.version_value ++ "\"";
const ek_method = "\"" ++ k_method ++ "\"";
const f_result_response = "{{" ++ ek_jsonrpc ++ ":" ++ ek_v20 ++ "," ++ ek_id ++ ":{s}," ++ ek_result ++ ":{s}}}";
const f_error_response = "{{" ++ ek_jsonrpc ++ ":" ++ ek_v20 ++ "," ++ ek_id ++ ":{s}," ++ ek_error ++ ":{{" ++ ek_code ++ ":{d}," ++ ek_message ++ ":{s}}}}}";
const f_range_json = "{{" ++ ek_start ++ ":{{" ++ ek_line ++ ":{d}," ++ ek_character ++ ":{d}}}," ++ ek_end ++ ":{{" ++ ek_line ++ ":{d}," ++ ek_character ++ ":{d}}}}}";
/// LSP `Location` 对象 `{"uri":"…","range":{…}}`——定义/引用/高亮跳转共用（第 288 轮 D147 收编，
/// 原先 `locationJson` 内联 raw literal 不随 `k_uri`/`k_range` 联动）。
const f_location_json = "{{" ++ ek_uri ++ ":{s}," ++ ek_range ++ ":{s}}}";
/// LSP `DocumentSymbol` 对象——大纲/面包屑消费（第 289 轮 D148 收编，
/// 原 `documentSymbol` 内联 raw literal 不随 `k_name`/`k_kind`/`k_range`/`k_selectionRange` 联动）。
const f_document_symbol = "{{" ++ ek_name ++ ":{s}," ++ ek_kind ++ ":{d}," ++ ek_range ++ ":{s}," ++ ek_selectionRange ++ ":{s}}}";
const f_publish_diagnostics = "{{" ++ ek_jsonrpc ++ ":" ++ ek_v20 ++ "," ++ ek_method ++ ":\"" ++ m_publishDiagnostics ++ "\"," ++ ek_params ++ ":{{" ++ ek_uri ++ ":{s}," ++ ek_diagnostics ++ ":{s}}}}}";
const f_sem_item = "{{" ++ ek_range ++ ":{s}," ++ ek_severity ++ ":{d}," ++ ek_source ++ ":" ++ eq_prog_name ++ "," ++ ek_message ++ ":{s}}}";
const f_fast_item = "{{" ++ ek_range ++ ":{s}," ++ ek_severity ++ ":{d}," ++ ek_source ++ ":" ++ eq_prog_name ++ "," ++ ek_message ++ ":{s}}}";
const f_hover_result = "{{" ++ ek_contents ++ ":{{" ++ ek_kind ++ ":" ++ em_markdown ++ "," ++ ek_value ++ ":{s}}}," ++ ek_range ++ ":{s}}}";
const f_code_action = "{{" ++ ek_title ++ ":{s}," ++ ek_kind ++ ":\"" ++ v_quickfix ++ "\"," ++ ek_edit ++ ":{{" ++ ek_changes ++ ":{{{s}:[" ++ "{{" ++ ek_range ++ ":{s}," ++ ek_newText ++ ":{s}}}]}}}}}}";
/// 第 269 轮：批量修复的单条 edit 与整条 `source.fixAll` 动作骨架（changes 内多枚 edit 由调用方拼好）。
const f_code_action_edit = "{{" ++ ek_range ++ ":{s}," ++ ek_newText ++ ":{s}}}";
/// 第 278 轮：`{s}` 是 itemsJoinAndFree 已带方括号的数组文本——旧模板再套一层 `[]`
/// 成 `[[{...}]]`，文本断言全绿而真实客户端读 `c.range` 抛错（保存时修复失效）。
const f_fix_all_action = "{{" ++ ek_title ++ ":{s}," ++ ek_kind ++ ":\"" ++ v_source_fix_all ++ "\"," ++ ek_edit ++ ":{{" ++ ek_changes ++ ":{{{s}:{s}}}}}}}";
/// 第 270 轮：折叠区间项骨架（LSP `FoldingRange` 只取行号两键；客户端直接读同名属性）。
const f_fold_item = "{{" ++ ek_startLine ++ ":{d}," ++ ek_endLine ++ ":{d}}}";
/// 第 271 轮：注释块折叠项——多带一枚 `kind:"comment"`，客户端映射为注释色标。
const f_fold_comment = "{{" ++ ek_startLine ++ ":{d}," ++ ek_endLine ++ ":{d}," ++ ek_kind ++ ":\"" ++ v_comment ++ "\"}}";
/// 第 272 轮：重命名 WorkspaceEdit 骨架（edits 已是 JSON 数组文本，单条 edit 复用 f_code_action_edit）。
const f_workspace_edit = "{{" ++ ek_changes ++ ":{{{s}:{s}}}}}";
/// 第 273 轮：同名符号高亮项（LSP `DocumentHighlight`：range + kind 数值码）。
const f_highlight_item = "{{" ++ ek_range ++ ":{s}," ++ ek_kind ++ ":{d}}}";
/// 第 274 轮：重命名预检结果（`{range, placeholder}`；range 为光标词范围，placeholder 为新名初值）。
const f_prepare_rename = "{{" ++ ek_range ++ ":{s}," ++ ek_placeholder ++ ":{s}}}";
/// 第 275 轮：工作区符号项骨架（LSP `SymbolInformation`：name + kind + location{uri,range}）。
const f_workspace_symbol = "{{" ++ ek_name ++ ":{s}," ++ ek_kind ++ ":{d}," ++ ek_location ++ ":{s}}}";
/// 第 276 轮：参数提示骨架（LSP `SignatureHelp`：signatures[].label/parameters[].label +
/// 活动签名/活动参数）。活动签名恒 0（每个被调名只返回一条声明签名）。
const f_signature_param = "{{" ++ ek_label ++ ":{s}}}";
const f_signature_item = "{{" ++ ek_label ++ ":{s}," ++ ek_parameters ++ ":[{s}]}}";
const f_signature_help = "{{" ++ ek_signatures ++ ":[{s}]," ++ ek_activeSignature ++ ":0," ++ ek_activeParameter ++ ":{d}}}";
/// 第 277 轮：智能扩选区骨架（LSP `SelectionRange`：range + 可选 parent，parent 为更大一层的
/// 同一链节；叶节无 parent 键）。链由内到外折叠：叶先落，逐层外包成 node。
const f_selection_leaf = "{{" ++ ek_range ++ ":{s}}}";
const f_selection_node = "{{" ++ ek_range ++ ":{s}," ++ ek_parent ++ ":{s}}}";
/// 第 279 轮：补全结果骨架——`{s}` 为 items 已拼好的数组文本，`{s}` 为 "true"/"false"；
/// 单项 = label/kind/detail 三必键（detail 可为空串），可选 documentation 与 textEdit 由调用方
/// 追加（点链补全带 textEdit 以替换整条链前缀，避免客户端默认只替换末段词）。
const f_completion_list = "{{" ++ ek_isIncomplete ++ ":{s}," ++ ek_items ++ ":{s}}}";
const f_completion_base = "{{" ++ ek_label ++ ":{s}," ++ ek_kind ++ ":{d}," ++ ek_detail ++ ":{s}";
const f_completion_doc = "," ++ ek_documentation ++ ":{s}";
const f_completion_text_edit = "," ++ ek_textEdit ++ ":{{" ++ ek_range ++ ":{s}," ++ ek_newText ++ ":{s}}}";
const f_empty_completion = "{{" ++ ek_isIncomplete ++ ":false," ++ ek_items ++ ":[]}}";
/// 空表的**已渲染**形：应答体里插的是值而非格式串，直接取 `f_empty_completion` 会把
/// `{{`/`}}` 原样写进 JSON（真实客户端 parse 即抛）。此处 comptime 渲染一次，仍单源。
const json_empty_completion = std.fmt.comptimePrint(f_empty_completion, .{});
/// 补全单次返回的**候选上限**（第 291 轮 D150 收编：原为写侧臂内的裸魔数 200）：超过即截断并置
/// `isIncomplete:true`——该旗标是告知宿主「表未列全、继续输入须回问」的唯一信号，一侧漂键名或此路
/// 径整体空转，皆使长前缀补全静默停更。截断测块与本值同骨（测面不得另抄 200）。
pub const completion_item_limit: usize = 200;
/// 测面针脚：`isIncomplete:false` 的**已渲染**形（由 `k_isIncomplete` 派生，键漂则针脚随漂）——第 291 轮
/// D150 收编测内 raw literal，消「hub 改键名 → 测面硬编另说一套」的双源（那时真静默的是 js 读侧）。
const needle_incomplete_false = "\"" ++ k_isIncomplete ++ "\":false";
const needle_empty_completion = ek_result ++ ":" ++ json_empty_completion;

/// 消息本体形串骨架（写侧拼接与测内 fixture 共用派生——同 214 `legend_json` 同骨形制：
/// 键词漂则 fixture 随漂、解析臂随漂，两侧不可能分道）。
pub const f_didOpen_params = "{{" ++ ek_textDocument ++ ":{{" ++ ek_uri ++ ":{s}," ++ ek_text ++ ":{s}}}}}";
pub const f_hover_params = "{{" ++ ek_textDocument ++ ":{{" ++ ek_uri ++ ":{s}}}," ++ ek_position ++ ":{{" ++ ek_line ++ ":{d}," ++ ek_character ++ ":{d}}}}}";

/// —— D113 e2e 基线脚本内嵌 LSP 帧协议词族（第 245 轮）：`tools/check-demos.ps1` 以内嵌 JSON
/// 帧字面量向 `zzc lsp` 发起 initialize／initialized／didOpen／didSave／hover／semanticTokens-full／
/// shutdown／exit 八方法、并携 `"jsonrpc":"2.0"` 与 `"languageId":"zig-dialect"`——此系协议词汇的
/// 第三处手抄（前两处：server.zig dispatch 单源 `m_*`／`jsonrpc.version_value`／`lang_identity.language_id`
/// 的写侧，及 `extension.js` 客户端面已收对面十一/十二/二十）。ps1 非测图 source dep、D94 `ps1_face` 只核
/// 命令词/路径/旗标、D98 `cap_face` 只核 capability Contains 断言形串——皆从不核帧内 method 词/版本值/语言 id；
/// 且本机 NO_PWSH＋GitCode 不跑 Actions 双盲。t2 探针独漂 ps1 帧方法词 fresh 633/633 全绿静默、活体喂漂形帧
/// `init2` 予真 lsp → 服务端回 `-32601`「不支持的方法」零 initialize 应答坐实握手失联。本 face 的 needle 值段
/// 全由 `m_*`／`version_value`／`language_id` 三单源 comptime 派生（键段复用既有 `ek_jsonrpc`/`ek_method`/`ek_v20`），
/// 一侧漂形即分道转锚（守卫对面二十二·复用对面十八已读 ps1 实文，零新增 I/O）。
pub const ps1_frame_face = [_]jsonrpc.FaceCheck{
    .{ .needle = ek_jsonrpc ++ ":" ++ ek_v20, .why = "ps1 每帧携的协议版本值须逐字节等于 jsonrpc.version_value——漂即服务端按版本判据拒帧（D108 版本族 ps1 漏员·t2 P1 静默形）" },
    .{ .needle = ek_method ++ ":\"" ++ m_initialize ++ "\"", .why = "ps1 握手发起方法词须等于服务端 dispatch 真值 m_initialize——漂即收到 -32601 零应答、LSP 全废（活体 init2 坐实）" },
    .{ .needle = ek_method ++ ":\"" ++ m_initialized ++ "\"", .why = "ps1 初始化完毕通知词须等于 m_initialized——通知形无应答，漂即服务端静默丢弃、无人感知" },
    .{ .needle = ek_method ++ ":\"" ++ m_didOpen ++ "\"", .why = "ps1 打开同步发起词须等于 m_didOpen——漂即文档不入表，诊断/悬停/语义 token 全空" },
    .{ .needle = ek_method ++ ":\"" ++ m_didSave ++ "\"", .why = "ps1 on-save 语义触发词须等于 m_didSave——漂即语义编译失联（第二帧块 L1035 面）" },
    .{ .needle = ek_method ++ ":\"" ++ m_hover ++ "\"", .why = "ps1 悬停请求词须等于 m_hover——漂即悬停永空（t2 探针 hovr 形）" },
    .{ .needle = ek_method ++ ":\"" ++ m_semanticTokensFull ++ "\"", .why = "ps1 语义 token 请求词须等于 m_semanticTokensFull——漂即母语高亮退白底" },
    .{ .needle = ek_method ++ ":\"" ++ m_shutdown ++ "\"", .why = "ps1 关闭请求词须等于 m_shutdown——漂即收到 -32601 而非 null 应答、退出序列退化为强杀" },
    .{ .needle = ek_method ++ ":\"" ++ m_exit ++ "\"", .why = "ps1 退出通知词须等于 m_exit——漂即服务端不置停旗标，只能等管道 EOF 兜底" },
    .{ .needle = "\"languageId\":\"" ++ lang_id.language_id ++ "\"", .why = "ps1 didOpen 语言标识须等于 lang_identity.language_id——漂即服务端按 id 分派文档不入表（D83 语言标识族 ps1 漏员）" },
};

/// —— D139 长连接冒烟脚本内嵌的 LSP 帧词族与 capability 断言族（第 281 轮）：
/// `tools/lsp-live-smoke.sh` 以 FIFO 保持写端常开，逐帧向 `zzc lsp` 发起十八个方法并轮询应答，
/// 又把 initialize 应答的十三枚 capability 形串逐枚 `grep -Fq` 断言——这是协议词汇的第四处手抄
/// （前三处：server.zig 写侧单源、`extension.js` 客户端面〔对面十一／十二／十三〕、ps1 内嵌帧〔对面二十二〕）。
/// 该脚本本身是运行时防线（本地四绿与 CI 第 4) 步皆真跑），但它不在 `zig build test` 门内、也不是
/// 测图 source dependency：第 281 轮 t2 探针 P1 实锤——**删掉 completion 的 capability 断言一行**，
/// `zig build test` 17/17 全绿且 `sh tools/lsp-live-smoke.sh` 仍 PASS（少一条断言不会失败），
/// 覆盖静默消失而构建链与 e2e 双双零信号（D94/D113「空转防线」同族）。本二 face 的 needle 值段全由
/// `m_*`／`jsonrpc.version_value`／`lang_identity.language_id`／`cap_*` 单源 comptime 派生，交守卫
/// 对面二十三对脚本实文逐枚对账：断言被删／被改松／服务端改词，皆在 `zig build test` 门内即红。
/// 边界（如实登册）：`cap_sync_obj`（textDocumentSync 对象形）脚本从不断言、`cap_server_info` 亦无，
/// 故不入本面针（同 ps1 `cap_face` 对 serverInfo 的处置）。
pub const smoke_frame_face = [_]jsonrpc.FaceCheck{
    .{ .needle = ek_jsonrpc ++ ":" ++ ek_v20, .why = "冒烟脚本每帧携的协议版本值须等于 jsonrpc.version_value——漂即服务端按版本判据拒帧，整条 e2e 恒时无应答（D108 版本族形）" },
    .{ .needle = ek_method ++ ":\"" ++ m_initialize ++ "\"", .why = "握手发起词须等于 m_initialize——漂即 -32601 零应答，脚本首步即 fail（断言被删则覆盖静默消失·P1 形）" },
    .{ .needle = ek_method ++ ":\"" ++ m_initialized ++ "\"", .why = "初始化完毕通知词须等于 m_initialized——通知形无应答，漂即服务端静默丢弃而脚本仍绿" },
    .{ .needle = ek_method ++ ":\"" ++ m_didOpen ++ "\"", .why = "文档打开同步词须等于 m_didOpen——漂即文档不入表，诊断/悬停/补全断言全塌" },
    .{ .needle = ek_method ++ ":\"" ++ m_hover ++ "\"", .why = "悬停请求词须等于 m_hover——漂即脚本 hover 步拿不到应答，overlay 断言失联" },
    .{ .needle = ek_method ++ ":\"" ++ m_documentSymbol ++ "\"", .why = "大纲请求词须等于 m_documentSymbol——漂即「主函数/标准库」两枚名字断言失保" },
    .{ .needle = ek_method ++ ":\"" ++ m_definition ++ "\"", .why = "跳转请求词须等于 m_definition——漂即声明定位断言（行0字符3）失联" },
    .{ .needle = ek_method ++ ":\"" ++ m_references ++ "\"", .why = "引用请求词须等于 m_references——漂即声明＋引用两处断言失保" },
    .{ .needle = ek_method ++ ":\"" ++ m_codeAction ++ "\"", .why = "快速修复请求词须等于 m_codeAction——漂即 quickfix 与 source.fixAll 两步断言全塌" },
    .{ .needle = ek_method ++ ":\"" ++ m_foldingRange ++ "\"", .why = "折叠请求词须等于 m_foldingRange——漂即折叠区形串断言失联" },
    .{ .needle = ek_method ++ ":\"" ++ m_rename ++ "\"", .why = "改名请求词须等于 m_rename——漂即声明＋引用两处编辑断言失保" },
    .{ .needle = ek_method ++ ":\"" ++ m_documentHighlight ++ "\"", .why = "同名高亮请求词须等于 m_documentHighlight——漂即 Write/Read 码值断言失联" },
    .{ .needle = ek_method ++ ":\"" ++ m_prepareRename ++ "\"", .why = "改名预检词须等于 m_prepareRename——漂即占位符形与 null 两断言失保（F2 死框回归无信号）" },
    .{ .needle = ek_method ++ ":\"" ++ m_workspaceSymbol ++ "\"", .why = "工作区符号词须等于 m_workspaceSymbol——漂即 query 过滤与空数组两断言失联" },
    .{ .needle = ek_method ++ ":\"" ++ m_signatureHelp ++ "\"", .why = "参数提示词须等于 m_signatureHelp——漂即活动参数随逗号递增的两枚关键断言失保（字符串内逗号误计回归无信号）" },
    .{ .needle = ek_method ++ ":\"" ++ m_selectionRange ++ "\"", .why = "智能扩选词须等于 m_selectionRange——漂即 词元→整行→块→整文档 嵌套链断言失联" },
    .{ .needle = ek_method ++ ":\"" ++ m_completion ++ "\"", .why = "上下文补全词须等于 m_completion——漂即点链 textEdit／本文件声明候选／空表三形断言全塌（第 279 轮接入面）" },
    .{ .needle = ek_method ++ ":\"" ++ m_shutdown ++ "\"", .why = "关闭请求词须等于 m_shutdown——漂即退出序列退化为强杀，脚本 rc 仍可能为 0" },
    .{ .needle = ek_method ++ ":\"" ++ m_exit ++ "\"", .why = "退出通知词须等于 m_exit——漂即服务端不置停旗标，仅靠管道 EOF 兜底（收尾断言失保）" },
    .{ .needle = "\"languageId\":\"" ++ lang_id.language_id ++ "\"", .why = "didOpen 的语言标识须等于 lang_identity.language_id——漂即服务端按 id 分派拒收文档，全链静默空（D83 面）" },
};

/// 冒烟脚本对 initialize 应答逐枚 `grep -Fq` 的 capability 形串十三枚（值段全取 `cap_*` 单源）。
/// 断言删一行即少一枚针——守卫对面二十三当场红（P1 静默面转锚）。
pub const smoke_cap_face = [_]jsonrpc.FaceCheck{
    .{ .needle = cap_hover, .why = "脚本须断言 hoverProvider 形串在应答里——漂即能力协商与声明分道而无人核验（悬停能力静默消失）" },
    .{ .needle = cap_semtok_key, .why = "脚本须断言 semanticTokensProvider 键在——漂即母语高亮供给能力无人核验" },
    .{ .needle = cap_docsym, .why = "脚本须断言 documentSymbolProvider 在——漂即大纲能力静默消失" },
    .{ .needle = cap_def, .why = "脚本须断言 definitionProvider 在——漂即跳转能力静默消失" },
    .{ .needle = cap_refs, .why = "脚本须断言 referencesProvider 在——漂即引用能力静默消失" },
    .{ .needle = cap_document_highlight, .why = "脚本须断言 documentHighlightProvider 在——漂即同名高亮能力静默消失" },
    .{ .needle = cap_codeaction, .why = "脚本须断言 codeActionProvider 在——漂即一键修复能力静默消失" },
    .{ .needle = cap_folding, .why = "脚本须断言 foldingRangeProvider 在——漂即折叠能力静默消失" },
    .{ .needle = cap_rename, .why = "脚本须断言 renameProvider{prepareProvider:true} 嵌套形在——漂即预检协商形退化而 F2 死框回归无信号" },
    .{ .needle = cap_workspace_symbol, .why = "脚本须断言 workspaceSymbolProvider 在——漂即工作区符号能力静默消失" },
    .{ .needle = cap_signature_help, .why = "脚本须断言 signatureHelpProvider 触发字符 `[\"(\",\",\"]` 形在——漂即参数提示触发面分道" },
    .{ .needle = cap_selection_range, .why = "脚本须断言 selectionRangeProvider 在——漂即智能扩选能力静默消失" },
    .{ .needle = cap_completion, .why = "脚本须断言 completionProvider 触发字符 `[\".\"]` 形在——漂即上下文补全能力静默消失（第 279 轮接入面·P1 实锤删此行零信号）" },
};

/// 从 capability 形串常量里取**键名段**（首个双引号对之间的字串）：`"hoverProvider":true` → `hoverProvider`。
/// 无形可抽（无引号对）时原样返回——派生针随即在对面落空，宁红不假绿。
fn capKeyOf(comptime lit: []const u8) []const u8 {
    var i: usize = 0;
    while (i < lit.len and lit[i] != '"') : (i += 1) {}
    var j = i + 1;
    while (j < lit.len and lit[j] != '"') : (j += 1) {}
    if (i >= lit.len or j >= lit.len) return lit;
    return lit[i + 1 .. j];
}

/// —— D141 客户端 e2e 冒烟里的 capability 键名族（第 282 轮）：`tools/extension-smoke.js` 以
/// `for (const cap of ['hoverProvider', 'completionProvider', …]) ok(log.includes('"' + cap + '"'), …)`
/// 逐枚核验 initialize 握手日志里的 provider 键——这是 capability **键名**的又一处手抄（形串面已收
/// 对面二十/二十三，键名段此前无锚）。服务端增/改/删 provider 时，js 侧只会「少验一枚而仍绿」，
/// 从不红：第 282 轮探针实锤把 `'hoverProvider'` 从数组删掉，`node tools/extension-smoke.js` 照旧
/// `PASS` 退 0（基数锚补齐前）。本面 needle 的键段全由 `cap_*` 单源 comptime 抽取（`capKeyOf`），
/// 一侧漂形即分道转锚（守卫对面二十四，与 D140 条数锚同片实文、零新增 I/O）。
/// 边界（如实登册）：`cap_sync_obj`／`cap_server_info` 脚本从不断言（同对面二十三的处置），不入本面。
pub const smoke_js_cap_face = [_]jsonrpc.FaceCheck{
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_hover)}), .why = "脚本须核验 hoverProvider 键在握手日志里——键段与写侧 cap_hover 分道即少验一枚能力而仍绿（探针实锤形）" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_completion)}), .why = "脚本须核验 completionProvider 键在——漂即上下文补全能力协商无人核验（第 279 轮接入面）" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_selection_range)}), .why = "脚本须核验 selectionRangeProvider 键在——漂即智能扩选能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_signature_help)}), .why = "脚本须核验 signatureHelpProvider 键在——漂即参数提示能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_workspace_symbol)}), .why = "脚本须核验 workspaceSymbolProvider 键在——漂即工作区符号能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_docsym)}), .why = "脚本须核验 documentSymbolProvider 键在——漂即大纲能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_def)}), .why = "脚本须核验 definitionProvider 键在——漂即跳转能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_refs)}), .why = "脚本须核验 referencesProvider 键在——漂即引用能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_document_highlight)}), .why = "脚本须核验 documentHighlightProvider 键在——漂即同名高亮能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_codeaction)}), .why = "脚本须核验 codeActionProvider 键在——漂即一键修复能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_folding)}), .why = "脚本须核验 foldingRangeProvider 键在——漂即折叠能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_rename)}), .why = "脚本须核验 renameProvider 键在——漂即重命名（含 prepareProvider 嵌套形）能力无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyOf(cap_semtok_key)}), .why = "脚本须核验 semanticTokensProvider 键在——漂即母语高亮能力无人核验" },
};

/// 客户端 provider 短名抽取（第 285 轮 D144）：`extension-smoke.js` 逐枚断言 `!!state.providers[name]`，
/// 而 `state.providers` 的键名即 capability 键名剥掉 `Provider` 尾段的形（hover↔hoverProvider）——
/// 故短名不另抄，由同一批 `cap_*` 真值再派生一层。无尾段可剥时原样返回（派生针必落空，继宁红不假绿）。
fn capKeyShort(comptime lit: []const u8) []const u8 {
    const key = capKeyOf(lit);
    const suffix = "Provider";
    if (key.len > suffix.len and std.mem.endsWith(u8, key, suffix)) return key[0 .. key.len - suffix.len];
    return key;
}

/// —— D144 客户端 e2e 的 provider 注册核验名集（第 285 轮）：js 以
/// `for (const name of ['hover', 'completion', …]) ok(!!P[name], '已注册 provider：' + name)` 逐枚验客户端注册，
/// 这十三枚短名是 capability 键名的**第二套词汇**（上一面钉的是 `'hoverProvider'` 形串，本面钉 `'hover'` 形），
/// 旧无锚。两路探针实锤的静默形：P1 把 'completion' 换成重复的 'hover' → 条数 89 不变、`node` 退 0 且
/// `zig build test` 全绿（注册断言静默掉一枚）；P2 把判据去下标 `!!P[name]`→`!!P` → 十三枚注册断言全空转而
/// 仍逐枚打 `[ok] 已注册 provider：…`（D142 的恒真闸只盯 `ok(true,` 形，此形字面上不是恒真）。
/// 本面因此含三族针：十三枚名针（同 282 形制逐字节）＋循环头形针＋判据体形针。
pub const smoke_js_provider_face = [_]jsonrpc.FaceCheck{
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_hover)}), .why = "脚本须断言客户端 hover provider 已注册——短名与写侧 cap_hover 分道即少验一枚注册而仍绿（探针 P1 形）" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_completion)}), .why = "脚本须断言 completion provider 已注册——探针 P1 正是拿本枚做替换实锤的：名集被重复项顶替时，条数与 PASS 行一字不变而注册覆盖面归零" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_signature_help)}), .why = "脚本须断言 signatureHelp provider 已注册——漂即参数提示的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_selection_range)}), .why = "脚本须断言 selectionRange provider 已注册——漂即智能扩选的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_docsym)}), .why = "脚本须断言 documentSymbol provider 已注册——漂即大纲的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_workspace_symbol)}), .why = "脚本须断言 workspaceSymbol provider 已注册——漂即工作区符号的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_def)}), .why = "脚本须断言 definition provider 已注册——漂即跳转定义的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_refs)}), .why = "脚本须断言 references provider 已注册——漂即查找引用的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_document_highlight)}), .why = "脚本须断言 documentHighlight provider 已注册——漂即同名高亮的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_codeaction)}), .why = "脚本须断言 codeAction provider 已注册——漂即快速修复的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_folding)}), .why = "脚本须断言 foldingRange provider 已注册——漂即代码折叠的客户端接线无人核验" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_rename)}), .why = "脚本须断言 rename provider 已注册——漂即重命名的客户端接线无人核验（本枚的派生还顺带钉住「剥尾段只剥一次」：renameProvider 含 prepareProvider 嵌套形而键段仅一尾）" },
    .{ .needle = std.fmt.comptimePrint("'{s}'", .{capKeyShort(cap_semtok_key)}), .why = "脚本须断言 semanticTokens provider 已注册——漂即母语高亮的客户端接线无人核验" },
    .{ .needle = "for (const name of [", .why = "十三枚注册断言须由本循环头生成——改成逐项硬编或删循环即名集与条数脱钩（第 285 轮 D144）" },
    .{ .needle = "ok(!!P[name], ", .why = "注册断言的判据体须含**循环变量下标** `P[name]`——探针 P2 实锤把判据改成 `!!P`（对象整体恒真）后，十三条注册断言全空转而仍逐枚打 `[ok]` 并 PASS 退 0；D142 的恒真闸只识别 `ok(true,` 形，此形靠本针拦（第 285 轮 D144）" },
};

/// 对面·`extension.js` 消息本体键族 needle 清单（守卫对面十二——同 218 `methods_face` 形制，
/// 判据入 hub、守卫视只读 I/O）。js 非 source dependency（203/214 轮判例：改 js 不触发测图重跑），
/// 而 t2 探针 P1–P3 实锤漂键对构建链零信号、真跑 P4 坐实功能级断裂——逐字节钉住客户端书写形。
pub const params_face = [_]jsonrpc.FaceCheck{
    .{ .needle = "send({ " ++ k_jsonrpc ++ ": '" ++ jsonrpc.version_value ++ "', " ++ k_id ++ ", " ++ k_method ++ ", " ++ k_params ++ " });", .why = "请求封装的消息骨四键 shorthand 须与服务端解析臂同名——漂则应答无 id/方法失踪，整条请求静默坠空（t2 P2 形）" },
    .{ .needle = "msg." ++ k_params, .why = "诊断通知参数体的读侧属性须等于服务端写侧键——漂则客户端取到 undefined，applyDiagnostics 首行短路、诊断面板恒空（t2 P2 静默面）" },
    .{ .needle = "msg." ++ k_result ++ " === undefined", .why = "应答体读侧属性须等于 respond 写侧键——漂则所有请求 resolve(null)，悬停/语义 token/握手全瞎（218 P2 同骨）" },
    .{ .needle = "!params." ++ k_uri, .why = "通知体 uri 守门读须等于 publishRaw 写侧键——漂即丢弃合法发布" },
    .{ .needle = "params." ++ k_diagnostics, .why = "诊断数组读须等于写侧键——漂即恒空数组，波浪线全灭" },
    .{ .needle = "params: { " ++ k_textDocument ++ ": { uri: doc.uri.toString(), languageId", .why = "didOpen 写侧嵌套形须逐字节等于解析臂——t2 P1 静默 + 真跑 P4 坐实漂形文档不入表、诊断/悬停全空" },
    .{ .needle = "      " ++ k_textDocument ++ ": { uri: doc.uri.toString(), version", .why = "didChange 写侧 textDocument 键——漂即变更失联，诊断冻结在打开一刻" },
    .{ .needle = "      " ++ k_contentChanges ++ ": [{ " ++ k_text ++ ":", .why = "didChange 全文同步数组键——服务端取末项全文的入口，漂即变更被拒（t2 P3 静默面）" },
    .{ .needle = "      " ++ k_position ++ ": { " ++ k_line ++ ": pos.line, " ++ k_character ++ ": pos.character }", .why = "hover 坐标子对象键族——漂即 intField 拒、悬停永空（t2 P4 同骨）" },
    .{ .needle = "only: codeActionOnly(context.only),", .why = "codeAction 的 kind 过滤器键须等于服务端 k_only 解析面——漂即 context.only 永不送达，source.fixAll 批量臂与保存时修复全静默" },
    .{ .needle = "      " ++ k_newName ++ ",", .why = "重命名请求的新名键须等于服务端 k_newName 解析面——漂即新名取不到、F2 改名恒 null" },
    .{ .needle = "request('" ++ m_workspaceSymbol ++ "', { " ++ k_query ++ " });", .why = "工作区符号请求的过滤键须等于服务端 k_query 解析面——漂即 query 丢弃、项目符号恒返回全量（过滤静默失效）" },
    .{ .needle = k_positions ++ ": positions.map((p) => ({ " ++ k_line ++ ": p." ++ k_line ++ ", " ++ k_character ++ ": p." ++ k_character ++ " })),", .why = "智能扩选的 positions 逐位置映射键须等于服务端 k_positions/k_line/k_character 解析面——漂即位置丢失、扩选区链错位" },
};

/// 对面·`extension.js` 结果体字段族 needle 清单（守卫对面十三——同 220 `params_face` 形制，
/// 判据入 hub）。t2 探针 P1–P4 js 消费面字段漂全绿静默、P6 写侧 kind 漂连测面亦零锚——
/// 逐字节钉住客户端属性读面，写/读/清单三面同源。
pub const results_face = [_]jsonrpc.FaceCheck{
    .{ .needle = "const r = d." ++ k_range ++ ";", .why = "诊断项 range 读侧属性须等于写侧键——漂即 r undefined、构造 Range 抛错、整批诊断被吞（t2 P1 静默面）" },
    .{ .needle = "r." ++ k_start ++ ".line, r." ++ k_start ++ ".character, r." ++ k_end ++ ".line, r." ++ k_end ++ ".character", .why = "range 子对象四读须等于 f_range_json 写侧键族——漂即波浪线坐标塌缩到文件头/整项作废" },
    .{ .needle = "d." ++ k_message ++ ", sev(d." ++ k_severity ++ "));", .why = "消息与severity消费读须等于写侧键——severity 漂即恒落 Hint 灰字，错误降级不可见（t2 P2 静默面）" },
    .{ .needle = "diag." ++ k_source ++ " = '" ++ paths.prog_name ++ "';", .why = "source 标注值与写侧同源词——漂即归属过滤/状态栏计数失配" },
    .{ .needle = "if (d." ++ k_code ++ " !== undefined", .why = "code 为诊断项可选写侧键的防御读——漂即 code 永不移交" },
    .{ .needle = "if (!res || !res." ++ k_contents ++ ")", .why = "hover 结果 contents 守门读——漂即悬停恒 null（t2 P3 静默面）" },
    .{ .needle = "res." ++ k_contents ++ "." ++ k_value ++ " ||", .why = "contents.value 读须等于 f_hover_result 写侧键——漂即悬停正文坠空串" },
    .{ .needle = "contentFormat: ['" ++ v_markdown ++ "'", .why = "hover 声明的 contentFormat 值须等于 f_hover_result 写侧 kind 值——漂即声明面与供给面格式分道（t2 P4 静默面）" },
    .{ .needle = "new vscode.FoldingRange(r." ++ k_startLine ++ ", r." ++ k_endLine ++ ", r." ++ k_kind ++ " === '" ++ v_comment ++ "' ? vscode.FoldingRangeKind.Comment : undefined)", .why = "折叠区间读侧属性与 comment kind 映射须等于 f_fold_*/v_comment 写侧键值——漂即行号 undefined 或注释块丢色标、折叠静默全灭" },
    .{ .needle = "Object.entries(res." ++ k_changes ++ ")", .why = "重命名结果 changes 表读侧键须等于写侧键——漂即编辑表取不到、F2 确认后零改动（静默未改最劣形）" },
    .{ .needle = "h." ++ k_kind ++ " === " ++ std.fmt.comptimePrint("{d}", .{hk_write}) ++ " ? vscode.DocumentHighlightKind.Write : vscode.DocumentHighlightKind.Read", .why = "高亮项的 kind 读侧映射须等于写侧 hk_write 码值——漂即声明位与引用位同色，高亮语义静默塌陷" },
    .{ .needle = k_placeholder ++ ": res." ++ k_placeholder, .why = "重命名预检的占位符读侧须等于写侧键——漂即 F2 输入框初值为空（预检形同虚设）" },
    .{ .needle = "!Array.isArray(res." ++ k_signatures ++ ")", .why = "参数提示结果 signatures 数组守门读须等于写侧键——漂即每次请求恒 null，调用括号提示静默失效" },
    .{ .needle = "(p) => new vscode.ParameterInformation(p." ++ k_label, .why = "逐参标签读侧属性须等于写侧 parameters[].label——漂即提示框只渲染签名、参数说明恒空" },
    .{ .needle = "help." ++ k_activeParameter ++ " = res." ++ k_activeParameter, .why = "活动参数回写读侧键须等于写侧键——漂即永远高亮首个参数（多参调用提示错位）" },
    .{ .needle = "s." ++ k_location ++ "." ++ k_uri ++ "), new vscode.Range(s." ++ k_location ++ "." ++ k_range ++ "." ++ k_start ++ ".line", .why = "工作区符号的 location.uri/range 读侧须等于写侧 f_workspace_symbol 字段——漂即 SymbolInformation 落错文件/错行" },
    .{ .needle = "new vscode.SelectionRange(", .why = "扩选区链节重建须用 vscode.SelectionRange——漂即客户端丢弃整条链、扩选不生效" },
    .{ .needle = "r." ++ k_parent ++ " ? toSelectionRange(r." ++ k_parent ++ ") : undefined", .why = "扩选区 parent 递归读侧须等于写侧 f_selection_node 键——漂即只扩到第一层，包围块/整文档永不入选" },
    .{ .needle = "!Array.isArray(res." ++ k_items ++ ")", .why = "补全结果 items 数组守门读须等于写侧键——漂即每次补全恒 null，候选表静默全空（客户端已注册 provider、能力已协商，唯读侧分道不可见）" },
    .{ .needle = "item." ++ k_textEdit ++ " = new vscode.TextEdit(", .why = "点链候选的 textEdit 重建须等于写侧键——漂即 VS Code 只替换光标下末段词，`标准库.调` 插成 `标准库.标准库.调试.打印`（补全结果错字而非空，最劣形）" },
    .{ .needle = "new vscode.CodeAction(item." ++ k_title ++ ",", .why = "快速修复动作标题读侧键须等于写侧 `k_title`——漂即菜单条目显示 undefined、用户无法辨别操作意图；探针 P1 实锤 item.title→item.titl 时 check-machine-matcher=OK 且 extension-smoke=PASS（双静默·第 287 轮 D146）" },
    .{ .needle = "vscode.Uri.parse(loc." ++ k_uri ++ ")", .why = "定义/引用 Location 构造的 uri 读侧属性须等于写侧 `f_location_json` 输出键——漂即跳转落点为 undefined、'Go to Definition' 打开不存在标签页；探针 P1 实锤 loc.uri→loc.ur 时 check-machine-matcher=OK 且 extension-smoke=PASS 且 zig build test 全绿（三静默·第 288 轮 D147）" },
    .{ .needle = "s." ++ k_selectionRange ++ " ||", .why = "大纲 selectionRange 读侧属性须等于写侧 `f_document_symbol` 输出键——漂即 js 回退 `|| r`（整声明范围）导致大纲点击高亮整行而非仅名称，UX 静默降级；探针 P1 实锤 s.selectionRange→s.selectionRang 时三门禁全绿（双静默·第 289 轮 D148）" },
    .{ .needle = std.fmt.comptimePrint("function toVscodeKind(k) {{ return Math.max(k - {d}, 0); }}", .{lsp_kind_base}), .why = "kind 换算的减数须等于 LSP 枚举基址真值——抄成 0/+1 即图标整体错位一格，探针 P1 实锤 s.kind→s.kind + 5 时守卫与 e2e 皆一字不变（双静默·第 290 轮 D149）" },
    .{ .needle = std.fmt.comptimePrint("toVscodeKind(c.kind || {d})", .{lsp_kind_base}), .why = "补全项构造器须吃换算后的 vscode 码——回退直传即 LSP 3(Function) 落进 vscode 3(Constructor)；探针 P2 实锤旧断言 `eq(decl.kind, 3)` 把本换算判为红（反向假锚·第 290 轮 D149）" },
    .{ .needle = "toVscodeSymbolKind(s.kind)", .occ = 2, .why = "大纲与工作区符号两址 kind 读面皆须走换算（同形两址手抄，presence 只核首现故以计数下界逐枚对账；措辞第 323 轮 D182 对齐「址」公约）——漏一处即那一族图标错位（第 290 轮 D149）" },
    .{ .needle = "!!res." ++ k_isIncomplete, .why = "客户端读补全完整性旗标须经 hub 键 `k_isIncomplete`（js 写 `!!res.isIncomplete`）——旗标只在候选超上限截断时为 true，而 e2e 固定文档永不触发截断，旧形 `!!res.isIncomplet` 读 undefined 落 false 恰与被测期望全等 → 探针 P1 实锤守卫与 e2e 皆一字不变（双静默·第 291 轮 D150）" },
};

/// 对面·`tools/extension-smoke.js` 的 kind 值域断言面（守卫对面二十七——同 `smoke_js_provider_face`
/// 形制，判据入 hub、守卫视只读 I/O，复用已读的 esm 实文零新增 I/O）。本面钉住「枚举空间换算」
/// 的三件事：宿主枚举的 0 基数值（由 hub `sk_*`/`ck_*` 减基址派生，不再靠注释自证）、三处 provider
/// 断言的落点形（symbolic 形而非写侧同照形）——第 290 轮 D149 探针 P2 实锤旧断言 `eq(decl.kind, 3)`
/// 以 LSP 数自照并把正确换算判为失败，属「断言把 bug 当预期钉住」的反向假锚形。
pub const kinds_smoke_face = [_]jsonrpc.FaceCheck{
    .{ .needle = std.fmt.comptimePrint("eq(vscode.SymbolKind.Function, {d}", .{sk_function - lsp_kind_base}), .why = "脚本须核验宿主 SymbolKind 为 0 基（Function=" ++ std.fmt.comptimePrint("{d}", .{sk_function - lsp_kind_base}) ++ "）——桩枚举漂回 1 基即换算断言全成自照，本针把 LSP↔vscode 差锁到 hub" },
    .{ .needle = std.fmt.comptimePrint("eq(vscode.CompletionItemKind.Function, {d}", .{ck_function - lsp_kind_base}), .why = "脚本须核验宿主 CompletionItemKind 为 0 基（Function=" ++ std.fmt.comptimePrint("{d}", .{ck_function - lsp_kind_base}) ++ "）——同上，本针是补全图标不错位的数值地基" },
    .{ .needle = "eq(sym.kind, vscode.SymbolKind.Function", .why = "大纲断言须吃宿主枚举形而非写侧原数——写侧数自照正是 D149 的静默面，改回 `eq(sym.kind, 12)` 即断言与换算分道" },
    .{ .needle = "eq(decl.kind, vscode.CompletionItemKind.Function", .why = "补全断言须吃宿主枚举形——旧形 `eq(decl.kind, 3)` 把 LSP 数当 vscode Function 期望，钉住了 bug 本身（探针 P2 实锤）" },
    .{ .needle = "eq(ws.kind, vscode.SymbolKind.Function", .why = "工作区符号断言须吃宿主枚举形——此前 kind 在工作区面完全无断言，漂即 SymbolInformation 图标错位而 e2e 零信号" },
};

/// 对面·`extension.js` severity 码值映射面 needle 清单（守卫对面十四——同 `results_face`
/// 形制）。四支硬编的数值由 `sv_*` 派生 comptime 拼出：js 映射表与 src clamp/快路码值
/// 分道即诊断分级静默错色（t2 P1/P2/P3/P6 全绿静默面转锚）。
pub const sv_face = [_]jsonrpc.FaceCheck{
    .{ .needle = std.fmt.comptimePrint("s === {d} ? vscode.DiagnosticSeverity.Error", .{sv_error}), .why = "sev() 首支数值＋落点词逐字节钉——1↔Error 对调即错误降级红报（t2 P1/P2 静默面）" },
    .{ .needle = std.fmt.comptimePrint(": s === {d} ? vscode.DiagnosticSeverity.Warning", .{sv_warning}), .why = "sev() 第二支——2↔Warning 漂即警告错渲染" },
    .{ .needle = std.fmt.comptimePrint(": s === {d} ? vscode.DiagnosticSeverity.Information", .{sv_information}), .why = "sev() 第三支——3↔Information 漂即信息级错渲染" },
    .{ .needle = ": vscode.DiagnosticSeverity.Hint);", .why = "sev() 兜底支落点词形钉——VS Code 枚举名系 js 侧单面词（src 无同概念真值），此枚为码值族穷尽后的兜底臂锚，漂即未知码虚报灰字（t2 P6 静默面）" },
};

/// 对面·`extension.js` 错误码应答面 needle 清单（守卫对面十五——同 `sv_face` 形制）。
/// js dispatch 对 window/ 发起请求的应答臂手抄 JSON-RPC 标准 -32601，数值由
/// `ec_method_not_found` 派生 comptime 拼出——跨侧同码分道即协议错误语义塌陷（t2 P1 静默面转锚）。
pub const errors_face = [_]jsonrpc.FaceCheck{
    .{ .needle = "error: { code: " ++ std.fmt.comptimePrint("{d}", .{ec_method_not_found}), .why = "客户端应答臂错误码逐字节钉=协议标准真值——js 侧另立码值即错误语义跨侧塌陷（t2 P1 -32601→-32602 全绿静默实锤）" },
};

pub const OutList = std.ArrayList([]const u8);

/// 语义诊断项（第 159 轮 · on-save 语义接入）：坐标已是文档 text 的 0 基行 + 0 基
/// UTF-16 码元列（与 LSP 展示口径一致、BMP 母语一字一码元），核内据此直拼 range。
pub const SemanticItem = struct {
    line: usize,
    character: usize,
    char_len: usize, // 跨度（码元）；0 视作 1（单字符下划）
    severity: u8, // LSP DiagnosticSeverity：1 错误 / 2 警告 / 3 信息 / 4 提示
    message: []const u8,
};

/// 语义供给器钩子：把「重、触 IO、按项目全量真编译」的语义诊断源从纯核解耦。
/// 纯核据它把语义项并入 publishDiagnostics，本体不触 IO（承 156 轮「纯函数核、不触 IO」）。
/// 实现方契约：返回的 items 与其 message 均为「本次调用期内有效」的借用切片——
/// 由实现方自持的暂存 arena 分配、下次调用前重置，核内只读不还（不 free、不跨调用持有）。
pub const SemanticProvider = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, uri: []const u8, text: []const u8) []SemanticItem,
};

// ---------------------------------------------------------------------------
// UTF-16 坐标换算（LSP 默认 positionEncoding）
// ---------------------------------------------------------------------------

/// 首字节 @ i 的 UTF-8 序列字节长（坏字节按 1）。
fn seqLen(s: []const u8, i: usize) usize {
    const l = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + l > s.len) return 1;
    _ = std.unicode.utf8Decode(s[i .. i + l]) catch return 1;
    return l;
}

/// 码点 @ i 的 UTF-16 宽度（1 或 2；坏字节按 1）。
fn cpWidth(s: []const u8, i: usize) usize {
    const l = seqLen(s, i);
    if (l == 1) return 1;
    const cp = std.unicode.utf8Decode(s[i .. i + l]) catch return 1;
    return if (cp >= 0x10000) 2 else 1;
}

/// 0 基行 + UTF-16 码元列（LSP Position）；line = 偏移之前的 '\n' 数。
fn positionOfOffset(text: []const u8, off: usize) struct { line: usize, character: usize } {
    const clamped = @min(off, text.len);
    var line: usize = 0;
    var line_start: usize = 0;
    for (text[0..clamped], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    var character: usize = 0;
    var i = line_start;
    while (i < clamped) {
        character += cpWidth(text, i);
        i += seqLen(text, i);
    }
    return .{ .line = line, .character = character };
}

/// LSP Position → 字节偏移；越界返 null（调用方按「无结果」处理，不 clamp 到别处）。
fn byteOfPosition(text: []const u8, line: usize, character: usize) ?usize {
    var l: usize = 0;
    var i: usize = 0;
    while (l < line) : (l += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return null;
        i = nl + 1;
    }
    var chars: usize = 0;
    while (i < text.len and text[i] != '\n') {
        if (chars >= character) return i;
        chars += cpWidth(text, i);
        i += seqLen(text, i);
    }
    return if (chars <= character) i else null;
}

/// 请求 Range → 字节区间；越界/逆序返 null（与 `byteOfPosition` 的「无结果」策略一致）。
const ByteSpan = struct { start: usize, end: usize };

fn rangeSpan(text: []const u8, r: std.json.ObjectMap) ?ByteSpan {
    const s = objIn(r.get(k_start)) orelse return null;
    const e = objIn(r.get(k_end)) orelse return null;
    const sl = intField(s, k_line) orelse return null;
    const sc = intField(s, k_character) orelse return null;
    const el = intField(e, k_line) orelse return null;
    const ec = intField(e, k_character) orelse return null;
    if (sl < 0 or sc < 0 or el < 0 or ec < 0) return null;
    const start = byteOfPosition(text, @intCast(sl), @intCast(sc)) orelse return null;
    const end = byteOfPosition(text, @intCast(el), @intCast(ec)) orelse return null;
    if (end < start) return null;
    return .{ .start = start, .end = end };
}

/// 字节区间 [start,end) → LSP Range JSON 文本（调用方 free）。
fn rangeJson(gpa: std.mem.Allocator, text: []const u8, start: usize, end: usize) ![]const u8 {
    const a = positionOfOffset(text, start);
    const b = positionOfOffset(text, end);
    return std.fmt.allocPrint(gpa, f_range_json, .{ a.line, a.character, b.line, b.character });
}

/// URI + 字节区间 → LSP Location JSON（调用方 free）。
fn locationJson(gpa: std.mem.Allocator, text: []const u8, uri: []const u8, start: usize, end: usize) ![]const u8 {
    const range = try rangeJson(gpa, text, start, end);
    defer gpa.free(range);
    const uri_js = try jsonrpc.jsonString(gpa, uri);
    defer gpa.free(uri_js);
    return std.fmt.allocPrint(gpa, f_location_json, .{ uri_js, range });
}

// ---------------------------------------------------------------------------
// 文档大纲（documentSymbol）：顶层声明扫描
// ---------------------------------------------------------------------------

/// 大纲项：kind 取 LSP SymbolKind（Function=12 / Variable=13 / Constant=14 / Enum=10 / Struct=23）。
const Decl = struct {
    kind: u32,
    name: []const u8,
    name_start: usize,
    name_end: usize,
};

/// 声明词 → LSP SymbolKind；词表取当前语言包 keywords（不硬编码方言词）。
fn declKind(lang: *const Pack, word: []const u8) ?u32 {
    const zig = lang.keywords.get(word) orelse return null;
    if (std.mem.eql(u8, zig, "fn")) return sk_function;
    if (std.mem.eql(u8, zig, "struct")) return sk_struct;
    if (std.mem.eql(u8, zig, "enum")) return sk_enum;
    if (std.mem.eql(u8, zig, "union")) return sk_struct;
    if (std.mem.eql(u8, zig, "const")) return sk_constant;
    if (std.mem.eql(u8, zig, "var")) return sk_variable;
    return null;
}

/// 声明前的修饰词（公开/导出/外部/内联/计期/紧实等）跳过，继续找声明词。
fn isDeclModifier(lang: *const Pack, word: []const u8) bool {
    const zig = lang.keywords.get(word) orelse return false;
    const mods = [_][]const u8{
        "pub",         "export",    "extern",   "inline",   "noinline",
        "threadlocal", "comptime",  "packed",   "callconv", "linksection",
        "align",       "allowzero", "volatile",
    };
    for (mods) |m| if (std.mem.eql(u8, zig, m)) return true;
    return false;
}

fn isSymbolDelim(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '(', ')', '{', '}', '[', ']', ':', ';', ',', '=', '!', '?', '*', '&', '|', '<', '>', '+', '-', '/', '%', '^', '~', '.' => true,
        else => false,
    };
}

/// 行内找「[修饰词]* 声明词 名称」；不是声明行/名称为关键字 → null。
fn findDecl(lang: *const Pack, line: []const u8) ?Decl {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) return null;
        const start = i;
        while (i < line.len and !isSymbolDelim(line[i])) i += 1;
        if (start == i) return null; // 行首标点：注释 `//`、闭合括号等
        const word = line[start..i];
        if (word[0] == '#') return null; // 行式注释/指令
        if (isDeclModifier(lang, word)) continue;
        const kind = declKind(lang, word) orelse return null;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const name_start = i;
        while (i < line.len and !isSymbolDelim(line[i])) i += 1;
        if (name_start == i) return null;
        const name = line[name_start..i];
        if (lang.keywords.get(name) != null) return null; // 关键字不能作声明名
        return .{ .kind = kind, .name = name, .name_start = name_start, .name_end = i };
    }
    return null;
}

/// 声明名范围是否落在真实词元上（排除注释/字符串等非代码文本里伪造的零缩进行）。
fn isCodeWord(toks: []const lexer.Token, start: usize, end: usize) bool {
    for (toks) |t| {
        if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
        if (t.off == start and t.off + t.len == end) return true;
    }
    return false;
}

/// 光标处代码词（词内或词尾回退）；注释/字符串/标点 → null。
fn wordTokenAt(toks: []const lexer.Token, text: []const u8, off: usize) ?[]const u8 {
    for (toks) |t| {
        if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
        if (t.off <= off and off < t.off + t.len) return text[t.off..][0..t.len];
    }
    // 光标停在词尾（无后续词元）时回退取前一词元——编辑器 F12 常把位置落在末字符之后。
    if (off > 0) {
        for (toks) |t| {
            if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
            if (t.off < off and t.off + t.len == off) return text[t.off..][0..t.len];
        }
    }
    return null;
}

/// 光标前最近一个未闭合的 `(` 词元下标（括号配对向后回扫）；无 → null。
/// 嵌套调用时取最内层：回扫遇 `)` 计深度、遇 `(` 先抵深度，深度 0 的 `(` 即目标。
fn callParenBefore(toks: []const lexer.Token, text: []const u8, off: usize) ?usize {
    var depth: usize = 0;
    var i = toks.len;
    while (i > 0) {
        i -= 1;
        const t = toks[i];
        if (t.off >= off) continue; // 光标处/之后的词元不算（光标在 `(` 上时不当作已进括号）
        if (t.kind != .punct or t.len != 1) continue;
        switch (text[t.off]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// 调用括号后到光标之间的顶层逗号数（即活动参数序）。嵌套括号/方括号/花括号里的
/// 逗号不计；字符串整体是一个词元，故字符串里的逗号天然不切参数。
fn activeParamAt(toks: []const lexer.Token, text: []const u8, open_off: usize, off: usize) usize {
    var depth: usize = 0;
    var n: usize = 0;
    for (toks) |t| {
        if (t.off <= open_off or t.off >= off) continue;
        if (t.kind != .punct or t.len != 1) continue;
        switch (text[t.off]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) n += 1;
            },
            else => {},
        }
    }
    return n;
}

const NameRange = struct { start: usize, end: usize };

/// 光标处代码词的绝对字节范围（词内或词尾回退）；注释/字符串/标点 → null。
/// 与 `wordTokenAt` 同判据，供需要位置而非切片的调用方使用（第 274 轮 prepareRename）。
fn wordRangeAt(toks: []const lexer.Token, off: usize) ?NameRange {
    for (toks) |t| {
        if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
        if (t.off <= off and off < t.off + t.len) return .{ .start = t.off, .end = t.off + t.len };
    }
    if (off > 0) {
        for (toks) |t| {
            if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
            if (t.off < off and t.off + t.len == off) return .{ .start = t.off, .end = t.off + t.len };
        }
    }
    return null;
}

/// 光标所在整行的绝对字节范围（不含 `\n`，行尾剥 `\r`）；越界 → null。
/// 与折叠/词元同源：扩选区链的第二层是「整行」，换行符不入选。
fn lineRangeAt(text: []const u8, off: usize) ?NameRange {
    if (off > text.len) return null;
    var start = off;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = off;
    while (end < text.len and text[end] != '\n') end += 1;
    if (end > start and text[end - 1] == '\r') end -= 1;
    return .{ .start = start, .end = end };
}

/// 扩选区链的一节（绝对字节区间）。
const SelRange = struct { start: usize, end: usize };

/// `outer` 是否严格包含 `inner`（相等不算——链节须逐级外扩，同区去重）。
fn selRangeContains(outer: SelRange, inner: SelRange) bool {
    return outer.start <= inner.start and outer.end >= inner.end and
        (outer.start < inner.start or outer.end > inner.end);
}

/// 只收严格包含当前末节的更大区间，保证 parent 链逐级外扩且无重复；首节（无末节）直收。
fn pushContaining(gpa: std.mem.Allocator, list: *std.ArrayList(SelRange), r: SelRange) !void {
    if (list.items.len > 0 and !selRangeContains(r, list.items[list.items.len - 1])) return;
    try list.append(gpa, r);
}

/// 按跨度升序（内层先）；同跨度时起点大者先（同区内层）。
fn selRangeLessThan(_: void, a: SelRange, b: SelRange) bool {
    const a_len = a.end - a.start;
    const b_len = b.end - b.start;
    if (a_len != b_len) return a_len < b_len;
    return a.start > b.start;
}

/// 按名称找首个顶层声明名称的绝对字节范围；无 → null。
fn findTopLevelDecl(lang: *const Pack, toks: []const lexer.Token, text: []const u8, name: []const u8) ?NameRange {
    var line_start: usize = 0;
    while (line_start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        var line_end = nl orelse text.len;
        if (line_end > line_start and text[line_end - 1] == '\r') line_end -= 1;
        const line = text[line_start..line_end];
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        if (indent == 0) {
            if (findDecl(lang, line)) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    const start = line_start + d.name_start;
                    const end = line_start + d.name_end;
                    if (isCodeWord(toks, start, end)) return .{ .start = start, .end = end };
                }
            }
        }
        line_start = if (nl) |n| n + 1 else text.len;
    }
    return null;
}

/// —— LSP 枚举基址（第 290 轮 D149）：LSP 的 `CompletionItemKind`／`SymbolKind` 以 **1** 起编
/// （Text/File = 1），而 vscode 同名枚举以 **0** 起编（vscode.d.ts：CompletionItemKind.Function=2、
/// SymbolKind.Function=11）——两侧数值差即此基址，客户端把 LSP 码直传 `new vscode.*(..., kind)`
/// 就整体错位一格（函数图标成构造器/变量、常量成字符串、关键字成片段）。同文件的 severity
/// （`sev()` 1↔Error）与 DocumentHighlightKind（3↔Write）早已各自做此换算，kind 族漏网。
pub const lsp_kind_base: u32 = 1;

/// —— 大纲/工作区符号的 LSP `SymbolKind` 码值（Function=12／Variable=13／Constant=14／
/// Enum=10／Struct=23，union 同归 Struct）：由 `declKind` 写侧、`completionKindForSymbol` 二次
/// 映射、客户端换算断言三处共此一份（第 290 轮 D149 收编，此前 declKind 与 switch 各拄一把 magic number）。
pub const sk_enum: u32 = 10;
pub const sk_function: u32 = 12;
pub const sk_variable: u32 = 13;
pub const sk_constant: u32 = 14;
pub const sk_struct: u32 = 23;

/// —— 上下文补全（第 279 轮）：LSP `CompletionItemKind` 码值（3 Function／6 Variable／
/// 7 Class／9 Module／13 Enum／14 Keyword／21 Constant／22 Struct）。码值为协议标准真值；
/// 客户端不得直传构造器，须减 `lsp_kind_base` 换到 vscode 0 基枚举空间（第 290 轮 D149）。
pub const ck_function: u32 = 3;
pub const ck_variable: u32 = 6;
pub const ck_class: u32 = 7;
pub const ck_module: u32 = 9;
pub const ck_enum: u32 = 13;
pub const ck_keyword: u32 = 14;
pub const ck_constant: u32 = 21;
pub const ck_struct: u32 = 22;

/// 光标处已输入链（可含 `.`）：start 为链首字节偏移，chain 为 text[start..off]。
const ChainPrefix = struct { start: usize, chain: []const u8 };

/// 从光标向前取“词/点链”前缀；光标落在标点/空白后时返 null（不弹空补全）。
fn chainPrefixAt(text: []const u8, off: usize) ?ChainPrefix {
    var s = off;
    while (s > 0) {
        const c = text[s - 1];
        const ok = c == '.' or c == '_' or (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= 0x80;
        if (!ok) break;
        s -= 1;
    }
    if (s == off) return null;
    return .{ .start = s, .chain = text[s..off] };
}

/// 一条补全候选（label/detail/doc 借用语言包或文档文本，不拥有内存）。
const CompletionHit = struct {
    label: []const u8,
    kind: u32,
    detail: []const u8,
    doc: ?[]const u8 = null,
    /// 点链候选：需要替换的链首字节偏移（null → 客户端按默认词范围插入）。
    edit_start: ?usize = null,
    /// 排序档：0 本文件声明 > 1 关键字/类型 > 2 标准库。
    rank: u8,
};

fn completionHitLess(_: void, a: CompletionHit, b: CompletionHit) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    return std.mem.lessThan(u8, a.label, b.label);
}

/// 词类分组（snippets.classify 六值）→ CompletionItemKind。
fn completionKindForGroup(group: []const u8) u32 {
    if (std.mem.eql(u8, group, snippets.g_builtin)) return ck_function;
    if (std.mem.eql(u8, group, snippets.g_type)) return ck_class;
    if (std.mem.eql(u8, group, snippets.g_constant)) return ck_constant;
    if (std.mem.eql(u8, group, snippets.g_keyword)) return ck_keyword;
    if (std.mem.eql(u8, group, snippets.g_alias)) return ck_module;
    return ck_variable;
}

/// LSP SymbolKind（Decl.kind）→ CompletionItemKind。
fn completionKindForSymbol(kind: u32) u32 {
    return switch (kind) {
        sk_function => ck_function,
        sk_struct => ck_struct,
        sk_enum => ck_enum,
        sk_constant => ck_constant,
        sk_variable => ck_variable,
        else => ck_variable,
    };
}

/// 顶层声明项（第 275 轮从 collectSymbolsJson 抽出）：带整行范围，供大纲与工作区符号共用。
const TopDecl = struct {
    kind: u32,
    name: []const u8,
    name_start: usize,
    name_end: usize,
    line_start: usize,
    line_end: usize,
};

/// 扫顶层（零缩进）声明；空文档/无声明 → 空切片。注释/字符串里的伪声明由词元校验排除。
fn scanTopLevelDecls(gpa: std.mem.Allocator, lang: *const Pack, text: []const u8) ![]TopDecl {
    const toks = try lexer.scan(gpa, text);
    defer gpa.free(toks);
    var items: std.ArrayList(TopDecl) = .empty;
    errdefer items.deinit(gpa);
    var line_start: usize = 0;
    while (line_start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        var line_end = nl orelse text.len;
        if (line_end > line_start and text[line_end - 1] == '\r') line_end -= 1;
        const line = text[line_start..line_end];
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        if (indent == 0) {
            if (findDecl(lang, line)) |d| {
                if (isCodeWord(toks, line_start + d.name_start, line_start + d.name_end)) {
                    try items.append(gpa, .{
                        .kind = d.kind,
                        .name = d.name,
                        .name_start = line_start + d.name_start,
                        .name_end = line_start + d.name_end,
                        .line_start = line_start,
                        .line_end = line_end,
                    });
                }
            }
        }
        line_start = if (nl) |n| n + 1 else text.len;
    }
    return items.toOwnedSlice(gpa);
}

/// 顶层函数签名（第 276 轮）：展示标签（声明词起至参数右括号）与逐参标签；均借用文档文本。
const FnSig = struct {
    label: []const u8,
    params: []const []const u8,
};

/// 切单行函数声明的参数表：名称后 `(` 到配对 `)`，按顶层逗号分割并去两端空白；
/// 无参数表/行内无配对右括号（跨行形不猜）→ null。标签从声明词起（保留「函数」等方言词）。
fn parseFnSignature(gpa: std.mem.Allocator, line: []const u8, d: Decl) !?FnSig {
    var i = d.name_end;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '(') return null;
    const open = i;
    var depth: usize = 0;
    var close: ?usize = null;
    while (i < line.len) : (i += 1) {
        if (line[i] == '(') {
            depth += 1;
        } else if (line[i] == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const cp = close orelse return null;
    // 声明词起点：从名称回退跳过空白再取前一词（`公开 函数 名(…)` 的标签以「函数」起）。
    var kw_start = d.name_start;
    while (kw_start > 0 and (line[kw_start - 1] == ' ' or line[kw_start - 1] == '\t')) kw_start -= 1;
    const kw_end = kw_start;
    while (kw_start > 0 and !isSymbolDelim(line[kw_start - 1])) kw_start -= 1;
    if (kw_start == kw_end) return null;
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(gpa);
    var seg_start = open + 1;
    var seg_depth: usize = 0;
    var j = open + 1;
    while (j <= cp) : (j += 1) {
        const at_end = j == cp;
        if (!at_end) {
            const c = line[j];
            if (c == '(' or c == '[' or c == '{') seg_depth += 1;
            if ((c == ')' or c == ']' or c == '}') and seg_depth > 0) seg_depth -= 1;
            if (!(c == ',' and seg_depth == 0)) continue;
        }
        var a = seg_start;
        var b = j;
        while (a < b and (line[a] == ' ' or line[a] == '\t')) a += 1;
        while (b > a and (line[b - 1] == ' ' or line[b - 1] == '\t')) b -= 1;
        if (b > a) try items.append(gpa, line[a..b]);
        seg_start = j + 1;
    }
    return .{ .label = line[kw_start .. cp + 1], .params = try items.toOwnedSlice(gpa) };
}

/// 按名称找同文件顶层函数声明并切参数表（kind 12 = LSP SymbolKind Function）；
/// 非函数声明/名称是注释或字符串伪造/跨行参数表 → null（词元校验同大纲）。
fn findFnSignature(gpa: std.mem.Allocator, lang: *const Pack, toks: []const lexer.Token, text: []const u8, name: []const u8) !?FnSig {
    var line_start: usize = 0;
    while (line_start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        var line_end = nl orelse text.len;
        if (line_end > line_start and text[line_end - 1] == '\r') line_end -= 1;
        const line = text[line_start..line_end];
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        if (indent == 0) {
            if (findDecl(lang, line)) |d| {
                if (d.kind == 12 and std.mem.eql(u8, d.name, name) and
                    isCodeWord(toks, line_start + d.name_start, line_start + d.name_end))
                {
                    if (try parseFnSignature(gpa, line, d)) |sig| return sig;
                }
            }
        }
        line_start = if (nl) |n| n + 1 else text.len;
    }
    return null;
}

/// 工作区符号命中项：文档 uri/全文 + 声明（名切片借用文档表文本）。
const WsHit = struct { uri: []const u8, text: []const u8, decl: TopDecl };

/// 工作区符号稳定序：先 uri 字典序，再声明位置（HashMap 迭代序不固定）。
fn wsHitLessThan(_: void, a: WsHit, b: WsHit) bool {
    switch (std.mem.order(u8, a.uri, b.uri)) {
        .lt => return true,
        .gt => return false,
        .eq => return a.decl.name_start < b.decl.name_start,
    }
}

/// 扫顶层（零缩进）声明，产出 LSP DocumentSymbol 数组；空文档/无声明 → `[]`。
fn collectSymbolsJson(gpa: std.mem.Allocator, lang: *const Pack, text: []const u8) ![]const u8 {
    const decls = try scanTopLevelDecls(gpa, lang, text);
    defer gpa.free(decls);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '[');
    for (decls, 0..) |d, i| {
        if (i > 0) try buf.append(gpa, ',');
        const name_js = try jsonrpc.jsonString(gpa, d.name);
        defer gpa.free(name_js);
        const range = try rangeJson(gpa, text, d.line_start, d.line_end);
        defer gpa.free(range);
        const sel = try rangeJson(gpa, text, d.name_start, d.name_end);
        defer gpa.free(sel);
        const item = try std.fmt.allocPrint(gpa, f_document_symbol, .{ name_js, d.kind, range, sel });
        defer gpa.free(item);
        try buf.appendSlice(gpa, item);
    }
    try buf.append(gpa, ']');
    return buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// JSON-RPC 报文骨架（入向 0.17 std.json 动态值、出向手拼）
// ---------------------------------------------------------------------------

fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn objIn(v: ?std.json.Value) ?std.json.ObjectMap {
    const x = v orelse return null;
    return asObject(x);
}

/// 快速修复的 kind 过滤器（第 269 轮）：`context.only` 缺省 → 保持第 268 轮的
/// 「光标处 quickfix」默认行为；一旦出现，则按成员分道（空数组/未知 kind → 空结果，
/// 与 LSP「只在请求的 kind 内返回」一致）。`source.fixAll` 与 `quickfix` 可同时命中。
const ActionFilter = struct { quickfix: bool, fix_all: bool };

fn actionFilter(params_obj: ?std.json.ObjectMap) ActionFilter {
    const p = params_obj orelse return .{ .quickfix = true, .fix_all = false };
    const ctx = objIn(p.get(k_context)) orelse return .{ .quickfix = true, .fix_all = false };
    const only_v = ctx.get(k_only) orelse return .{ .quickfix = true, .fix_all = false };
    const arr = switch (only_v) {
        .array => |a| a,
        else => return .{ .quickfix = true, .fix_all = false },
    };
    var f: ActionFilter = .{ .quickfix = false, .fix_all = false };
    for (arr.items) |it| {
        const s = switch (it) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, s, v_quickfix)) f.quickfix = true;
        if (std.mem.eql(u8, s, v_source_fix_all)) f.fix_all = true;
    }
    return f;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const x = obj.get(key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const x = obj.get(key) orelse return null;
    return switch (x) {
        .integer => |n| n,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const x = obj.get(key) orelse return null;
    return switch (x) {
        .bool => |b| b,
        else => null,
    };
}

/// 回显请求 id（原样 JSON 文本；调用方 free）。缺 id/非常见形 → "null"。
fn idJson(gpa: std.mem.Allocator, idv: ?std.json.Value) ![]const u8 {
    const v = idv orelse return try gpa.dupe(u8, "null");
    return switch (v) {
        .integer => |n| std.fmt.allocPrint(gpa, "{d}", .{n}),
        .number_string => |s| gpa.dupe(u8, s),
        .string => |s| jsonrpc.jsonString(gpa, s),
        .bool => |b| gpa.dupe(u8, if (b) "true" else "false"),
        else => gpa.dupe(u8, "null"),
    };
}

fn resultResponse(gpa: std.mem.Allocator, id_json: []const u8, result_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, f_result_response, .{ id_json, result_json });
}

fn errorResponse(gpa: std.mem.Allocator, id_json: []const u8, code: i64, message: []const u8) ![]const u8 {
    const msg_js = try jsonrpc.jsonString(gpa, message);
    defer gpa.free(msg_js);
    return std.fmt.allocPrint(gpa, f_error_response, .{ id_json, code, msg_js });
}

/// 字符串数组拼成 JSON 数组文本并接管各元素（join 后元素即释；调用方 free 返回值）。
fn itemsJoinAndFree(gpa: std.mem.Allocator, items: *std.ArrayList([]const u8)) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '[');
    for (items.items, 0..) |it, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, it);
    }
    try out.append(gpa, ']');
    const joined = try out.toOwnedSlice(gpa);
    for (items.items) |s| gpa.free(s);
    items.clearAndFree(gpa);
    return joined;
}

/// 行首到 `off` 之间是否只有水平空白（判 `//` 是否独占行首——尾随注释不成块）。
fn blankBefore(text: []const u8, begin: usize, off: usize) bool {
    for (text[begin..off]) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// 注释块落盘：单行块不出（无可隐藏行），多行块带 `kind:"comment"`。
fn appendCommentFold(gpa: std.mem.Allocator, items: *std.ArrayList([]const u8), s: usize, e: usize) !void {
    if (e <= s) return;
    const item = try std.fmt.allocPrint(gpa, f_fold_comment, .{ s, e });
    items.append(gpa, item) catch |err| {
        gpa.free(item);
        return err;
    };
}

/// 重命名新名合法性（第 272 轮）：lexer 扫出恰一个代码词且覆盖全串（空格/点/引号/标点即拒）；
/// ASCII 首字节不可为数字；全角/不可见字符复用 `translate.preCheck` 危险表（单一真值）。
/// 关键字冲突不在本轮（与声明名同口径，编译期报错兜底）。
fn validRenameName(gpa: std.mem.Allocator, name: []const u8) bool {
    if (name.len == 0) return false;
    const toks = lexer.scan(gpa, name) catch return false;
    defer gpa.free(toks);
    if (toks.len != 1) return false;
    const t = toks[0];
    if (t.off != 0 or t.len != name.len) return false;
    if (t.kind != .ascii_word and t.kind != .nonascii_word) return false;
    if (t.kind == .ascii_word and name[0] >= '0' and name[0] <= '9') return false;
    const vs = translate.preCheck(gpa, name) catch return false;
    defer gpa.free(vs);
    return vs.len == 0;
}

// ---------------------------------------------------------------------------
// 服务器
// ---------------------------------------------------------------------------

pub const Server = struct {
    gpa: std.mem.Allocator,
    lang: *const Pack,
    /// uri → 文档全文（自持 dupe）
    docs: std.StringHashMap([]const u8),
    /// 语义诊断供给器（第 159 轮）：null 时 didSave 仅重发快路诊断；接上真编译供给方后
    /// didSave 把语义项并入发布。纯核不造，由 IO 侧（cmdLsp）注入；单测注入假供给器。
    semantic: ?SemanticProvider = null,
    /// 收到 exit 通知：环流侧据此结束。
    stop: bool = false,

    pub fn init(gpa: std.mem.Allocator, lang: *const Pack) Server {
        return .{
            .gpa = gpa,
            .lang = lang,
            .docs = std.StringHashMap([]const u8).init(gpa),
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            // D60（第 195 轮）：键系 upsertDoc 里 `gpa.dupe` 的自持堆串，原码只 free 值——
            // 在表键串全数漏收（会话结束时的兜底回收面亦缺，与 D58/D59 同族）。
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.docs.deinit();
    }

    /// 处理一条 JSON-RPC 报文体；产出零或多条出站报文体（应答 + 通知），归调用方逐条 free。
    pub fn handle(self: *Server, body: []const u8, out: *OutList) !void {
        const gpa = self.gpa;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch {
            const id_null = try gpa.dupe(u8, "null");
            defer gpa.free(id_null);
            try out.append(gpa, try errorResponse(gpa, id_null, ec_parse_error, "解析失败：不是合法 JSON 报文"));
            return;
        };
        defer parsed.deinit();

        const root = asObject(parsed.value) orelse {
            const id_null = try gpa.dupe(u8, "null");
            defer gpa.free(id_null);
            try out.append(gpa, try errorResponse(gpa, id_null, ec_invalid_request, "解析失败：报文根不是对象"));
            return;
        };
        const method = strField(root, k_method) orelse return; // 应答形（无 method）：本服务器不发请求，忽略
        const idv = root.get(k_id);
        const params_obj = objIn(root.get(k_params));

        if (std.mem.eql(u8, method, m_initialize)) {
            // textDocumentSync 升级为对象形（第 159 轮）：声明 openClose + 全量 change + save（includeText:false，
            // didSave 时服务端用自持文档表文本），据以让客户端知晓可发 textDocument/didSave。
            // semanticTokensProvider（第 161 轮）：声明语义 token 图例（token 类型索引即下表顺序）+ full 供给，
            // 把方言母语词汇的语义高亮据 LSP 标准面供任意客户端（编辑端渲染留 162）。
            const res = "{\"capabilities\":{" ++ cap_sync_obj ++ "," ++ cap_hover ++ "," ++ cap_semtok ++ "," ++ cap_docsym ++ "," ++ cap_def ++ "," ++ cap_refs ++ "," ++ cap_document_highlight ++ "," ++ cap_codeaction ++ "," ++ cap_folding ++ "," ++ cap_rename ++ "," ++ cap_workspace_symbol ++ "," ++ cap_signature_help ++ "," ++ cap_selection_range ++ "," ++ cap_completion ++ "}," ++ cap_server_info ++ "}";
            try self.respond(out, idv, res);
            return;
        }
        if (std.mem.eql(u8, method, m_initialized)) return; // 通知、无应答
        if (std.mem.eql(u8, method, m_shutdown)) {
            try self.respond(out, idv, "null");
            return;
        }
        if (std.mem.eql(u8, method, m_exit)) {
            self.stop = true;
            return;
        }
        if (std.mem.eql(u8, method, m_didOpen)) {
            const p = params_obj orelse return;
            const td = objIn(p.get(k_textDocument)) orelse return;
            const uri = strField(td, k_uri) orelse return;
            const text = strField(td, k_text) orelse return;
            try self.upsertDoc(uri, text);
            try self.publish(out, uri, text);
            return;
        }
        if (std.mem.eql(u8, method, m_didChange)) {
            const p = params_obj orelse return;
            const td = objIn(p.get(k_textDocument)) orelse return;
            const uri = strField(td, k_uri) orelse return;
            if (!self.docs.contains(uri)) return; // 未 open 的文档不接变更
            // 全量同步（textDocumentSync=1）：contentChanges 末项必带全文 text
            const changes = switch (p.get(k_contentChanges) orelse .null) {
                .array => |a| a.items,
                else => return,
            };
            if (changes.len == 0) return;
            const last = objIn(changes[changes.len - 1]) orelse return;
            const text = strField(last, k_text) orelse return;
            try self.upsertDoc(uri, text);
            try self.publish(out, uri, text);
            return;
        }
        if (std.mem.eql(u8, method, m_didClose)) {
            const p = params_obj orelse return;
            const td = objIn(p.get(k_textDocument)) orelse return;
            const uri = strField(td, k_uri) orelse return;
            // D60（第 195 轮）：`fetchRemove` 取回的键同为自持堆串，须与值一并回收（原码只 free 值）。
            if (self.docs.fetchRemove(uri)) |kv| {
                gpa.free(kv.key);
                gpa.free(kv.value);
            }
            // 规范：文档关闭后清波浪线——发布空诊断数组
            try self.publishRaw(out, uri, "[]");
            return;
        }
        if (std.mem.eql(u8, method, m_didSave)) {
            const p = params_obj orelse return;
            const td = objIn(p.get(k_textDocument)) orelse return;
            const uri = strField(td, k_uri) orelse return;
            // includeText:false → 取服务端自持文档表文本（已由 didChange 同步至最新）；未 open 则不处理。
            const text = self.docs.get(uri) orelse return;
            try self.publishSave(out, uri, text);
            return;
        }
        if (std.mem.eql(u8, method, m_hover)) {
            try self.hover(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_completion)) {
            try self.completion(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_documentSymbol)) {
            try self.documentSymbol(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_definition)) {
            try self.definition(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_references)) {
            try self.references(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_documentHighlight)) {
            try self.documentHighlight(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_codeAction)) {
            try self.codeAction(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_foldingRange)) {
            try self.foldingRange(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_rename)) {
            try self.rename(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_prepareRename)) {
            try self.prepareRename(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_workspaceSymbol)) {
            try self.workspaceSymbol(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_signatureHelp)) {
            try self.signatureHelp(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_selectionRange)) {
            try self.selectionRange(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, m_semanticTokensFull)) {
            try self.semanticTokensFull(out, idv, params_obj);
            return;
        }

        if (idv != null) {
            const id_json = try idJson(gpa, idv);
            defer gpa.free(id_json);
            const msg = try std.fmt.allocPrint(gpa, "不支持的方法：{s}", .{method});
            defer gpa.free(msg);
            try out.append(gpa, try errorResponse(gpa, id_json, ec_method_not_found, msg));
        }
        // 不支持的通知（无 id）：静默丢弃——JSON-RPC 对通知不发 error 应答
    }

    fn respond(self: *Server, out: *OutList, idv: ?std.json.Value, result_json: []const u8) !void {
        const id_json = try idJson(self.gpa, idv);
        defer self.gpa.free(id_json);
        try out.append(self.gpa, try resultResponse(self.gpa, id_json, result_json));
    }

    fn upsertDoc(self: *Server, uri: []const u8, text: []const u8) !void {
        const gpa = self.gpa;
        // D60（第 195 轮）：docs 的键是下面 dupe 出的自持堆串，原码替换臂只 free 值、从不 free
        // 旧键——LSP 为长驻进程且 textDocumentSync=1 全量同步，didChange 随键击成交，每换一次
        // 文本即泄一只旧 uri 串（与 D58/D59 同族，然面在长驻进程、系全库累积最快的一处）。
        if (self.docs.fetchRemove(uri)) |old| {
            gpa.free(old.key);
            gpa.free(old.value);
        }
        // 两只 dupe 拆开各挂 errdefer：原码挤在同一表达式里，第二只失败即第一只无人回收。
        const key = try gpa.dupe(u8, uri);
        errdefer gpa.free(key);
        const val = try gpa.dupe(u8, text);
        errdefer gpa.free(val);
        try self.docs.put(key, val);
    }

    fn publish(self: *Server, out: *OutList, uri: []const u8, text: []const u8) !void {
        const gpa = self.gpa;
        const diags = try self.diagnosticsJson(text);
        defer gpa.free(diags);
        try self.publishRaw(out, uri, diags);
    }

    /// didSave 发布（第 159 轮）：快路诊断 + 语义供给器产出（若已注入）合并为一个数组。
    /// 未注入供给器时退化为与 publish 同形（仅快路）；语义项 message 为借用切片、核内不 free。
    fn publishSave(self: *Server, out: *OutList, uri: []const u8, text: []const u8) !void {
        const gpa = self.gpa;
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| gpa.free(s);
            items.deinit(gpa);
        }
        try self.appendFastItems(text, &items);
        if (self.semantic) |prov| {
            for (prov.call(prov.ctx, uri, text)) |s| {
                try items.append(gpa, try self.semItem(s));
            }
        }
        const arr = try itemsJoinAndFree(gpa, &items);
        defer gpa.free(arr);
        try self.publishRaw(out, uri, arr);
    }

    /// 语义项 → Diagnostic JSON（坐标已是 0 基行/码元列、直拼 range、免经字节换算）。
    fn semItem(self: *Server, s: SemanticItem) ![]const u8 {
        const gpa = self.gpa;
        const w = if (s.char_len == 0) 1 else s.char_len;
        const sev = if (s.severity >= sv_error and s.severity <= sv_hint) s.severity else sv_error;
        const range = try std.fmt.allocPrint(gpa, f_range_json, .{ s.line, s.character, s.line, s.character + w });
        defer gpa.free(range);
        const msg_js = try jsonrpc.jsonString(gpa, s.message);
        defer gpa.free(msg_js);
        return std.fmt.allocPrint(gpa, f_sem_item, .{ range, sev, msg_js });
    }

    fn publishRaw(self: *Server, out: *OutList, uri: []const u8, diags_json: []const u8) !void {
        const gpa = self.gpa;
        const uri_js = try jsonrpc.jsonString(gpa, uri);
        defer gpa.free(uri_js);
        try out.append(gpa, try std.fmt.allocPrint(gpa, f_publish_diagnostics, .{ uri_js, diags_json }));
    }

    /// 快路诊断：全角/词法 + 纯母语强制，消息与 `zzc check` 逐字同形（去路径前缀）。
    fn diagnosticsJson(self: *Server, text: []const u8) ![]const u8 {
        const gpa = self.gpa;
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| gpa.free(s);
            items.deinit(gpa);
        }
        try self.appendFastItems(text, &items);
        return itemsJoinAndFree(gpa, &items);
    }

    /// 快路诊断项追入 items（publish 与 publishSave 共用，单一真相源）。
    fn appendFastItems(self: *Server, text: []const u8, items: *std.ArrayList([]const u8)) !void {
        const gpa = self.gpa;

        // preCheck 错误集仅分配失败形；失败按零词法违例继续（诊断辅面不吞主面）。
        var maybe_vs: ?[]fullwidth.Violation = null;
        if (translate.preCheck(gpa, text)) |vs| {
            maybe_vs = vs;
        } else |_| {}
        defer if (maybe_vs) |vs| gpa.free(vs);
        for (maybe_vs orelse &.{}) |v| {
            const msg = if (v.ascii.len > 0 and v.ascii[0] == ' ')
                try std.fmt.allocPrint(gpa, cli.msg_fw_space, .{v.hint}) // 第 233 轮 D101：文案正文取 hub 单一真值（与 CLI cmdCheck 逐字同形）
            else if (v.ascii.len > 0)
                try std.fmt.allocPrint(gpa, cli.msg_fw_symbol, .{ v.hint, v.ascii }) // 第 233 轮 D101
            else
                try std.fmt.allocPrint(gpa, cli.msg_fw_other, .{ v.hint, v.word }); // 第 233 轮 D101
            defer gpa.free(msg);
            try items.append(gpa, try self.diagItem(text, v.off, v.off + v.len, msg));
        }

        var eng = translate.findEnglishWordForms(gpa, self.lang.*, text) catch return;
        defer eng.deinit();
        for (eng.items) |v| {
            const msg = try std.fmt.allocPrint(gpa, cli.msg_pure_native, .{ v.word, v.native }); // 第 233 轮 D101：纯母语提示正文取 hub 单一真值
            defer gpa.free(msg);
            try items.append(gpa, try self.diagItem(text, v.off, v.off + v.word.len, msg));
        }
    }

    fn diagItem(self: *Server, text: []const u8, start: usize, end: usize, msg: []const u8) ![]const u8 {
        const gpa = self.gpa;
        const range = try rangeJson(gpa, text, start, end);
        defer gpa.free(range);
        const msg_js = try jsonrpc.jsonString(gpa, msg);
        defer gpa.free(msg_js);
        return std.fmt.allocPrint(gpa, f_fast_item, .{ range, sv_error, msg_js });
    }

    /// 文档大纲：取服务端自持文档表文本，扫顶层声明；文档不在表 → 空数组。
    fn documentSymbol(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        result_json = try collectSymbolsJson(gpa, self.lang, text);
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "[]");
    }

    /// `textDocument/completion`（第 279 轮）：按光标前缀给出四源候选——语言包
    /// keywords（关键字/类型/字面常量/内建）、不含点的 aliases 根、aliases 点链（前缀含 `.`
    /// 时只补链）、当前文档顶层声明。字符串/注释/符号字面量内、空前缀、未打开文档 → 空表。
    /// 点链候选项带 `textEdit` 替换整条已输入链前缀（VS Code 默认只替换末段词）。
    fn completion(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (objIn(p.get(k_position))) |pos| {
                            const line = intField(pos, k_line) orelse -1;
                            const character = intField(pos, k_character) orelse -1;
                            if (line >= 0 and character >= 0) {
                                if (byteOfPosition(text, @intCast(line), @intCast(character))) |off| {
                                    result_json = try self.completionAt(text, off);
                                }
                            }
                        }
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse json_empty_completion);
    }

    fn emptyCompletion(self: *Server) ![]const u8 {
        return self.gpa.dupe(u8, json_empty_completion);
    }

    /// 光标前缀（含点链）→ 候选集；空/字面量内/无前缀时返回空表（调用方 free）。
    fn completionAt(self: *Server, text: []const u8, off: usize) ![]const u8 {
        const gpa = self.gpa;
        const toks = lexer.scan(gpa, text) catch return self.emptyCompletion();
        defer gpa.free(toks);
        for (toks) |t| {
            const inside = t.off <= off and off <= t.off + t.len;
            if (!inside) continue;
            switch (t.kind) {
                .string, .char, .multiline, .comment, .symbol => return self.emptyCompletion(),
                else => {},
            }
        }
        const pre = chainPrefixAt(text, off) orelse return self.emptyCompletion();
        var hits: std.ArrayList(CompletionHit) = .empty;
        defer hits.deinit(gpa);
        try self.collectCompletionHits(text, pre, &hits);
        if (hits.items.len == 0) return self.emptyCompletion();
        std.mem.sort(CompletionHit, hits.items, {}, completionHitLess);

        const limit: usize = completion_item_limit;
        const incomplete = hits.items.len > limit;
        const n = @min(hits.items.len, limit);
        var items: std.ArrayList([]const u8) = .empty;
        defer {
            for (items.items) |s| gpa.free(s);
            items.deinit(gpa);
        }
        var last: ?[]const u8 = null;
        for (hits.items[0..n]) |h| {
            if (last) |prev| {
                if (std.mem.eql(u8, prev, h.label)) continue;
            }
            last = h.label;
            try items.append(gpa, try self.completionItemJson(text, pre, h));
        }
        const joined = try itemsJoinAndFree(gpa, &items);
        defer gpa.free(joined);
        return std.fmt.allocPrint(gpa, f_completion_list, .{ if (incomplete) "true" else "false", joined });
    }

    fn collectCompletionHits(self: *Server, text: []const u8, pre: ChainPrefix, hits: *std.ArrayList(CompletionHit)) !void {
        const gpa = self.gpa;
        const chain = pre.chain;
        if (std.mem.indexOfScalar(u8, chain, '.') != null) {
            var it = self.lang.aliases.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                if (!std.mem.startsWith(u8, key, chain)) continue;
                try hits.append(gpa, .{
                    .label = key,
                    .kind = ck_module,
                    .detail = e.value_ptr.*,
                    .doc = self.lang.docs.get(key),
                    .edit_start = pre.start,
                    .rank = 2,
                });
            }
            return;
        }
        var it = self.lang.keywords.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (!std.mem.startsWith(u8, key, chain)) continue;
            try hits.append(gpa, .{
                .label = key,
                .kind = completionKindForGroup(snippets.classify(e.value_ptr.*)),
                .detail = e.value_ptr.*,
                .doc = self.lang.docs.get(key),
                .rank = 1,
            });
        }
        var it2 = self.lang.aliases.iterator();
        while (it2.next()) |e| {
            const key = e.key_ptr.*;
            if (std.mem.indexOfScalar(u8, key, '.') != null) continue;
            if (!std.mem.startsWith(u8, key, chain)) continue;
            try hits.append(gpa, .{
                .label = key,
                .kind = ck_module,
                .detail = e.value_ptr.*,
                .doc = self.lang.docs.get(key),
                .rank = 2,
            });
        }
        const decls = try scanTopLevelDecls(gpa, self.lang, text);
        defer gpa.free(decls);
        for (decls) |d| {
            if (!std.mem.startsWith(u8, d.name, chain)) continue;
            try hits.append(gpa, .{
                .label = d.name,
                .kind = completionKindForSymbol(d.kind),
                .detail = "本文件声明",
                .rank = 0,
            });
        }
    }

    fn completionItemJson(self: *Server, text: []const u8, pre: ChainPrefix, h: CompletionHit) ![]const u8 {
        const gpa = self.gpa;
        const label_js = try jsonrpc.jsonString(gpa, h.label);
        defer gpa.free(label_js);
        const detail_js = try jsonrpc.jsonString(gpa, h.detail);
        defer gpa.free(detail_js);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const base = try std.fmt.allocPrint(gpa, f_completion_base, .{ label_js, h.kind, detail_js });
        defer gpa.free(base);
        try buf.appendSlice(gpa, base);
        if (h.doc) |doc| {
            const doc_js = try jsonrpc.jsonString(gpa, doc);
            defer gpa.free(doc_js);
            const seg = try std.fmt.allocPrint(gpa, f_completion_doc, .{doc_js});
            defer gpa.free(seg);
            try buf.appendSlice(gpa, seg);
        }
        if (h.edit_start) |start| {
            const range = try rangeJson(gpa, text, start, pre.start + pre.chain.len);
            defer gpa.free(range);
            const seg = try std.fmt.allocPrint(gpa, f_completion_text_edit, .{ range, label_js });
            defer gpa.free(seg);
            try buf.appendSlice(gpa, seg);
        }
        try buf.append(gpa, '}');
        return buf.toOwnedSlice(gpa);
    }

    /// 工作区符号（第 275 轮）：按 `query` 子串过滤服务端文档表内各文档的顶层声明，
    /// 返回 `SymbolInformation[]`（name/kind/location{uri,range}）；空 query 返回全部。
    fn workspaceSymbol(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        const query = if (params_obj) |p| strField(p, k_query) orelse "" else "";
        const res = try self.collectWorkspaceSymbolsJson(query);
        defer gpa.free(res);
        try self.respond(out, idv, res);
    }

    fn collectWorkspaceSymbolsJson(self: *Server, query: []const u8) ![]const u8 {
        const gpa = self.gpa;
        var hits: std.ArrayList(WsHit) = .empty;
        defer hits.deinit(gpa);
        var it = self.docs.iterator();
        while (it.next()) |e| {
            const uri = e.key_ptr.*;
            const text = e.value_ptr.*;
            const decls = try scanTopLevelDecls(gpa, self.lang, text);
            defer gpa.free(decls);
            for (decls) |d| {
                if (query.len > 0 and std.mem.indexOf(u8, d.name, query) == null) continue;
                try hits.append(gpa, .{ .uri = uri, .text = text, .decl = d });
            }
        }
        std.mem.sort(WsHit, hits.items, {}, wsHitLessThan);
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.append(gpa, '[');
        for (hits.items, 0..) |h, i| {
            if (i > 0) try buf.append(gpa, ',');
            const name_js = try jsonrpc.jsonString(gpa, h.decl.name);
            defer gpa.free(name_js);
            const loc = try locationJson(gpa, h.text, h.uri, h.decl.name_start, h.decl.name_end);
            defer gpa.free(loc);
            const item = try std.fmt.allocPrint(gpa, f_workspace_symbol, .{ name_js, h.decl.kind, loc });
            defer gpa.free(item);
            try buf.appendSlice(gpa, item);
        }
        try buf.append(gpa, ']');
        return buf.toOwnedSlice(gpa);
    }

    /// 参数提示（第 276 轮）：光标落在调用括号内时，按被调名找到同文件顶层函数声明，
    /// 返回声明参数表与按顶层逗号计的活动参数；非调用处/成员调用/未知被调 → null。
    fn signatureHelp(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (objIn(p.get(k_position))) |pos| {
                            const line = intField(pos, k_line) orelse -1;
                            const character = intField(pos, k_character) orelse -1;
                            if (line >= 0 and character >= 0) {
                                if (byteOfPosition(text, @intCast(line), @intCast(character))) |off| {
                                    result_json = try self.signatureHelpAt(text, off);
                                }
                            }
                        }
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "null");
    }

    /// 光标处调用括号 → 被调名 → 同文件顶层函数签名；未命中一律 null（不猜）。
    fn signatureHelpAt(self: *Server, text: []const u8, off: usize) !?[]const u8 {
        const gpa = self.gpa;
        const toks = try lexer.scan(gpa, text);
        defer gpa.free(toks);
        const pi = callParenBefore(toks, text, off) orelse return null;
        if (pi == 0) return null;
        const callee = toks[pi - 1];
        if (callee.kind != .nonascii_word and callee.kind != .ascii_word) return null;
        const name = text[callee.off..][0..callee.len];
        // 成员调用（`接收者.名(`）不提示：同文件函数声明不候选成员解析，宁缺不错。
        if (pi >= 2) {
            const dot = toks[pi - 2];
            if (dot.kind == .punct and dot.off + dot.len == callee.off and text[dot.off] == '.') return null;
        }
        const sig = (try findFnSignature(gpa, self.lang, toks, text, name)) orelse return null;
        defer gpa.free(sig.params);

        var params_buf: std.ArrayList(u8) = .empty;
        defer params_buf.deinit(gpa);
        for (sig.params, 0..) |p, i| {
            if (i > 0) try params_buf.append(gpa, ',');
            const p_js = try jsonrpc.jsonString(gpa, p);
            defer gpa.free(p_js);
            const item = try std.fmt.allocPrint(gpa, f_signature_param, .{p_js});
            defer gpa.free(item);
            try params_buf.appendSlice(gpa, item);
        }
        const label_js = try jsonrpc.jsonString(gpa, sig.label);
        defer gpa.free(label_js);
        const sig_item = try std.fmt.allocPrint(gpa, f_signature_item, .{ label_js, params_buf.items });
        defer gpa.free(sig_item);
        const active = activeParamAt(toks, text, toks[pi].off, off);
        const clamped = if (sig.params.len == 0) 0 else @min(active, sig.params.len - 1);
        return try std.fmt.allocPrint(gpa, f_signature_help, .{ sig_item, clamped });
    }

    /// 智能扩选（第 277 轮）：每个 position 返回一条由内到外的扩选链——词元 → 整行 →
    /// 包围花括号块（由内到外）→ 整文档；位置非法时只回整文档（一条结果不缺）。
    fn selectionRange(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        result_json = try self.selectionRangesJson(text, p.get(k_positions));
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "null");
    }

    /// `positions[]` → 逐位置同序的 `SelectionRange[]`；缺 positions/非数组 → null，空数组 → `[]`。
    fn selectionRangesJson(self: *Server, text: []const u8, positions: ?std.json.Value) !?[]const u8 {
        const gpa = self.gpa;
        const arr = switch (positions orelse return null) {
            .array => |a| a.items,
            else => return null,
        };
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.append(gpa, '[');
        for (arr, 0..) |v, i| {
            if (i > 0) try buf.append(gpa, ',');
            var off: ?usize = null;
            if (asObject(v)) |m| {
                const line = intField(m, k_line) orelse -1;
                const character = intField(m, k_character) orelse -1;
                if (line >= 0 and character >= 0) {
                    off = byteOfPosition(text, @intCast(line), @intCast(character));
                }
            }
            const chain = try self.selectionChainJson(text, off);
            defer gpa.free(chain);
            try buf.appendSlice(gpa, chain);
        }
        try buf.append(gpa, ']');
        return try buf.toOwnedSlice(gpa);
    }

    /// 单位置扩选链：词元（词内/词尾才收）→ 整行 → 包围块（词元配对栈，按跨度内→外）→
    /// 整文档。字符串/注释整体成词元，故其中的括号不参与配对；每步只收严格包含前节者。
    fn selectionChainJson(self: *Server, text: []const u8, off0: ?usize) ![]const u8 {
        const gpa = self.gpa;
        var ranges: std.ArrayList(SelRange) = .empty;
        defer ranges.deinit(gpa);
        if (off0) |off| {
            const toks = try lexer.scan(gpa, text);
            defer gpa.free(toks);
            if (wordRangeAt(toks, off)) |wr| {
                try pushContaining(gpa, &ranges, .{ .start = wr.start, .end = wr.end });
            }
            if (lineRangeAt(text, off)) |lr| {
                if (lr.start < lr.end) try pushContaining(gpa, &ranges, .{ .start = lr.start, .end = lr.end });
            }
            var opens: std.ArrayList(usize) = .empty; // 待配对开括号的绝对字节偏移
            defer opens.deinit(gpa);
            var blocks: std.ArrayList(SelRange) = .empty;
            defer blocks.deinit(gpa);
            for (toks) |t| {
                if (t.kind != .punct or t.len != 1) continue;
                switch (text[t.off]) {
                    '{' => try opens.append(gpa, t.off),
                    '}' => {
                        const open = opens.pop() orelse continue;
                        if (open < off and off <= t.off) {
                            try blocks.append(gpa, .{ .start = open, .end = t.off + 1 });
                        }
                    },
                    else => {},
                }
            }
            std.mem.sort(SelRange, blocks.items, {}, selRangeLessThan);
            for (blocks.items) |b| try pushContaining(gpa, &ranges, b);
        }
        try pushContaining(gpa, &ranges, .{ .start = 0, .end = text.len });
        var chain: ?[]const u8 = null;
        errdefer if (chain) |c| gpa.free(c);
        // 链根须是最内层（词元），parent 逐级外扩：故从最外层向内折叠，后包者成新根。
        var ri = ranges.items.len;
        while (ri > 0) {
            ri -= 1;
            const r = ranges.items[ri];
            const st = positionOfOffset(text, r.start);
            const en = positionOfOffset(text, r.end);
            const rj = try std.fmt.allocPrint(gpa, f_range_json, .{ st.line, st.character, en.line, en.character });
            defer gpa.free(rj);
            const old = chain;
            chain = null;
            const next = if (old) |inner| blk: {
                const node = std.fmt.allocPrint(gpa, f_selection_node, .{ rj, inner }) catch |e| {
                    gpa.free(inner);
                    return e;
                };
                gpa.free(inner);
                break :blk node;
            } else try std.fmt.allocPrint(gpa, f_selection_leaf, .{rj});
            chain = next;
        }
        return chain.?;
    }

    /// 跳转定义：同文件顶层声明名 → 声明位置；未命中/文档不在表 → null。
    fn definition(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (objIn(p.get(k_position))) |pos| {
                            const line = intField(pos, k_line) orelse -1;
                            const character = intField(pos, k_character) orelse -1;
                            if (line >= 0 and character >= 0) {
                                if (byteOfPosition(text, @intCast(line), @intCast(character))) |off| {
                                    result_json = self.definitionAt(text, uri, off);
                                }
                            }
                        }
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "null");
    }

    /// 光标词元 → 顶层声明位置（Location JSON）；注释/字符串/未命中 → null。
    /// 仅同文件、仅顶层声明、同名多声明取首个；不做作用域消歧（名遮蔽场景可能跳错，边界入台账）。
    fn definitionAt(self: *Server, text: []const u8, uri: []const u8, off: usize) ?[]const u8 {
        const gpa = self.gpa;
        const toks = lexer.scan(gpa, text) catch return null;
        defer gpa.free(toks);
        const w = wordTokenAt(toks, text, off) orelse return null;
        const d = findTopLevelDecl(self.lang, toks, text, w) orelse return null;
        return locationJson(gpa, text, uri, d.start, d.end) catch null;
    }

    /// 查找引用：同文件顶层声明名 → 全部词元位置；未命中 → []。
    fn references(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (objIn(p.get(k_position))) |pos| {
                            const line = intField(pos, k_line) orelse -1;
                            const character = intField(pos, k_character) orelse -1;
                            if (line >= 0 and character >= 0) {
                                if (byteOfPosition(text, @intCast(line), @intCast(character))) |off| {
                                    var include_decl = true;
                                    if (objIn(p.get(k_context))) |ctx| {
                                        if (boolField(ctx, k_includeDeclaration)) |b| include_decl = b;
                                    }
                                    result_json = self.referencesAt(text, uri, off, include_decl) catch null;
                                }
                            }
                        }
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "[]");
    }

    /// 同文件词元级引用收集；仅收与顶层声明同名的代码词元（字符串/注释自然排除）。
    /// 边界：不做作用域消歧——同名局部变量/字段也会被计入；include_decl 控制声明项去留。
    fn referencesAt(self: *Server, text: []const u8, uri: []const u8, off: usize, include_decl: bool) ![]const u8 {
        const gpa = self.gpa;
        const toks = try lexer.scan(gpa, text);
        defer gpa.free(toks);
        const w = wordTokenAt(toks, text, off) orelse return try gpa.dupe(u8, "[]");
        const d = findTopLevelDecl(self.lang, toks, text, w) orelse return try gpa.dupe(u8, "[]");
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| gpa.free(s);
            items.deinit(gpa);
        }
        for (toks) |t| {
            if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
            if (!std.mem.eql(u8, text[t.off..][0..t.len], w)) continue;
            const is_decl = t.off == d.start and t.off + t.len == d.end;
            if (is_decl and !include_decl) continue;
            const loc = try locationJson(gpa, text, uri, t.off, t.off + t.len);
            items.append(gpa, loc) catch |e| {
                gpa.free(loc);
                return e;
            };
        }
        return itemsJoinAndFree(gpa, &items);
    }

    /// `textDocument/documentHighlight`（第 273 轮）：光标词解析到同文件顶层声明后，
    /// 收集全部同名代码词元——声明位标 Write、其余标 Read；未解析到声明 → []。
    /// 边界：与 references/rename 同源同界，不做作用域消歧。
    fn documentHighlight(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (objIn(p.get(k_position))) |pos| {
                            const line = intField(pos, k_line) orelse -1;
                            const character = intField(pos, k_character) orelse -1;
                            if (line >= 0 and character >= 0) {
                                if (byteOfPosition(text, @intCast(line), @intCast(character))) |off| {
                                    result_json = self.highlightAt(text, off) catch null;
                                }
                            }
                        }
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "[]");
    }

    /// 顶层声明的全部同名代码词元 → DocumentHighlight JSON；非声明词 → []。
    fn highlightAt(self: *Server, text: []const u8, off: usize) ![]const u8 {
        const gpa = self.gpa;
        const toks = try lexer.scan(gpa, text);
        defer gpa.free(toks);
        const w = wordTokenAt(toks, text, off) orelse return try gpa.dupe(u8, "[]");
        const d = findTopLevelDecl(self.lang, toks, text, w) orelse return try gpa.dupe(u8, "[]");
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| gpa.free(s);
            items.deinit(gpa);
        }
        for (toks) |t| {
            if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
            if (!std.mem.eql(u8, text[t.off..][0..t.len], w)) continue;
            const kind: u8 = if (t.off == d.start and t.off + t.len == d.end) hk_write else hk_read;
            const range = try rangeJson(gpa, text, t.off, t.off + t.len);
            defer gpa.free(range);
            const item = try std.fmt.allocPrint(gpa, f_highlight_item, .{ range, kind });
            items.append(gpa, item) catch |e| {
                gpa.free(item);
                return e;
            };
        }
        return itemsJoinAndFree(gpa, &items);
    }

    /// `textDocument/rename`（第 272 轮）：同文件顶层声明的重命名——收集全部同名代码词元，
    /// 产 `WorkspaceEdit`（`changes{uri:[{range,newText}]}`）。非声明光标、注释/字符串、
    /// 非法新名 → null（编辑器不弹替换框）。
    /// 边界：与 references 同源同界——不做作用域消歧（同名局部变量/字段会一并改）；
    /// 新名不核关键字冲突（编译期报错兜底）。
    fn rename(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (strField(p, k_newName)) |new_name| {
                            if (objIn(p.get(k_position))) |pos| {
                                const line = intField(pos, k_line) orelse -1;
                                const character = intField(pos, k_character) orelse -1;
                                if (line >= 0 and character >= 0 and validRenameName(gpa, new_name)) {
                                    if (byteOfPosition(text, @intCast(line), @intCast(character))) |off| {
                                        result_json = try self.renameAt(text, uri, off, new_name);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "null");
    }

    /// 顶层声明的全部同名代码词元 → WorkspaceEdit JSON；光标词不是声明名 → null。
    fn renameAt(self: *Server, text: []const u8, uri: []const u8, off: usize, new_name: []const u8) !?[]const u8 {
        const gpa = self.gpa;
        const toks = try lexer.scan(gpa, text);
        defer gpa.free(toks);
        const w = wordTokenAt(toks, text, off) orelse return null;
        _ = findTopLevelDecl(self.lang, toks, text, w) orelse return null;
        const new_js = try jsonrpc.jsonString(gpa, new_name);
        defer gpa.free(new_js);
        const uri_js = try jsonrpc.jsonString(gpa, uri);
        defer gpa.free(uri_js);
        var edits: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (edits.items) |s| gpa.free(s);
            edits.deinit(gpa);
        }
        for (toks) |t| {
            if (t.kind != .nonascii_word and t.kind != .ascii_word) continue;
            if (!std.mem.eql(u8, text[t.off..][0..t.len], w)) continue;
            const range = try rangeJson(gpa, text, t.off, t.off + t.len);
            defer gpa.free(range);
            const item = try std.fmt.allocPrint(gpa, f_code_action_edit, .{ range, new_js });
            edits.append(gpa, item) catch |e| {
                gpa.free(item);
                return e;
            };
        }
        const edits_joined = try itemsJoinAndFree(gpa, &edits);
        defer gpa.free(edits_joined);
        return try std.fmt.allocPrint(gpa, f_workspace_edit, .{ uri_js, edits_joined });
    }

    /// `textDocument/prepareRename`（第 274 轮）：F2 预检——光标词解析到同文件顶层声明后，
    /// 返回光标词范围与占位符；非声明词/字符串/注释/未打开文档 → null（不弹输入框）。
    fn prepareRename(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (objIn(p.get(k_position))) |pos| {
                            const line = intField(pos, k_line) orelse -1;
                            const character = intField(pos, k_character) orelse -1;
                            if (line >= 0 and character >= 0) {
                                if (byteOfPosition(text, @intCast(line), @intCast(character))) |off| {
                                    result_json = try self.prepareRenameAt(text, off);
                                }
                            }
                        }
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "null");
    }

    /// 光标词 + 顶层声明同界校验 → `{range, placeholder}`；不满足 → null。
    fn prepareRenameAt(self: *Server, text: []const u8, off: usize) !?[]const u8 {
        const gpa = self.gpa;
        const toks = try lexer.scan(gpa, text);
        defer gpa.free(toks);
        const w = wordTokenAt(toks, text, off) orelse return null;
        _ = findTopLevelDecl(self.lang, toks, text, w) orelse return null;
        const span = wordRangeAt(toks, off) orelse return null;
        const range = try rangeJson(gpa, text, span.start, span.end);
        defer gpa.free(range);
        const name_js = try jsonrpc.jsonString(gpa, w);
        defer gpa.free(name_js);
        return try std.fmt.allocPrint(gpa, f_prepare_rename, .{ range, name_js });
    }

    /// 快速修复（第 268 轮）：选区/光标处的全角标点 → 建议半角 ASCII 的 CodeAction。
    /// 与快路诊断同源（`translate.preCheck` 复用 fullwidth 危险表），只对「有建议替换值」的
    /// 违规出灯泡；零宽空格等 `ascii` 为空者不出（删除类修复不在本轮范围）。
    fn codeAction(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        const f = actionFilter(p);
                        var items: std.ArrayList([]const u8) = .empty;
                        errdefer {
                            for (items.items) |s| gpa.free(s);
                            items.deinit(gpa);
                        }
                        // quickfix 臂需合法 range；source.fixAll 管全文，不依赖选区。
                        if (f.quickfix) {
                            if (objIn(p.get(k_range))) |r| {
                                if (rangeSpan(text, r)) |span| {
                                    try self.appendQuickfixes(text, uri, span.start, span.end, &items);
                                }
                            }
                        }
                        if (f.fix_all) {
                            if (try self.fixAllItem(text, uri)) |it| {
                                items.append(gpa, it) catch |e| {
                                    gpa.free(it);
                                    return e;
                                };
                            }
                        }
                        result_json = try itemsJoinAndFree(gpa, &items);
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "[]");
    }

    /// 选区内可替换的全角违规 → CodeAction JSON 数组；无可用修复时返回 `[]`。
    fn fixActionsJson(self: *Server, text: []const u8, uri: []const u8, sel_start: usize, sel_end: usize) ![]const u8 {
        const gpa = self.gpa;
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| gpa.free(s);
            items.deinit(gpa);
        }
        try self.appendQuickfixes(text, uri, sel_start, sel_end, &items);
        return itemsJoinAndFree(gpa, &items);
    }

    /// 把与选区/光标相交且有半角建议值的违规逐条追加为 quickfix 项。
    fn appendQuickfixes(self: *Server, text: []const u8, uri: []const u8, sel_start: usize, sel_end: usize, items: *std.ArrayList([]const u8)) !void {
        const gpa = self.gpa;
        const vs = translate.preCheck(gpa, text) catch return;
        defer gpa.free(vs);
        const uri_js = try jsonrpc.jsonString(gpa, uri);
        defer gpa.free(uri_js);
        for (vs) |v| {
            if (v.ascii.len == 0) continue; // 零宽空格等无建议替换值：不出「修复」
            // 选区相交；空选区（光标）取违规范围含右边界的那一条——光标停在字符右侧也能修。
            const hit = if (sel_start == sel_end)
                (v.off <= sel_start and sel_start <= v.off + v.len)
            else
                (v.off < sel_end and v.off + v.len > sel_start);
            if (!hit) continue;
            const title = if (std.mem.eql(u8, v.ascii, " "))
                try std.fmt.allocPrint(gpa, "{s}：替换为半角空格", .{v.hint})
            else
                try std.fmt.allocPrint(gpa, "{s}：替换为半角「{s}」", .{ v.hint, v.ascii });
            defer gpa.free(title);
            const title_js = try jsonrpc.jsonString(gpa, title);
            defer gpa.free(title_js);
            const range = try rangeJson(gpa, text, v.off, v.off + v.len);
            defer gpa.free(range);
            const new_js = try jsonrpc.jsonString(gpa, v.ascii);
            defer gpa.free(new_js);
            const item = try std.fmt.allocPrint(gpa, f_code_action, .{ title_js, uri_js, range, new_js });
            items.append(gpa, item) catch |e| {
                gpa.free(item);
                return e;
            };
        }
    }

    /// 全文可替换违规 → 单条 `source.fixAll` 动作；无可修项时 null（不出空动作）。
    fn fixAllItem(self: *Server, text: []const u8, uri: []const u8) !?[]const u8 {
        const gpa = self.gpa;
        const vs = translate.preCheck(gpa, text) catch return null;
        defer gpa.free(vs);
        var edits: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (edits.items) |s| gpa.free(s);
            edits.deinit(gpa);
        }
        var n: usize = 0;
        for (vs) |v| {
            if (v.ascii.len == 0) continue;
            const range = try rangeJson(gpa, text, v.off, v.off + v.len);
            defer gpa.free(range);
            const new_js = try jsonrpc.jsonString(gpa, v.ascii);
            defer gpa.free(new_js);
            const edit = try std.fmt.allocPrint(gpa, f_code_action_edit, .{ range, new_js });
            edits.append(gpa, edit) catch |e| {
                gpa.free(edit);
                return e;
            };
            n += 1;
        }
        if (n == 0) {
            for (edits.items) |s| gpa.free(s);
            edits.deinit(gpa);
            return null;
        }
        const edits_joined = try itemsJoinAndFree(gpa, &edits);
        defer gpa.free(edits_joined);
        const title = try std.fmt.allocPrint(gpa, "修复全文全角标点（{d} 处）", .{n});
        defer gpa.free(title);
        const title_js = try jsonrpc.jsonString(gpa, title);
        defer gpa.free(title_js);
        const uri_js = try jsonrpc.jsonString(gpa, uri);
        defer gpa.free(uri_js);
        return try std.fmt.allocPrint(gpa, f_fix_all_action, .{ title_js, uri_js, edits_joined });
    }

    /// `textDocument/foldingRange`（第 270/271 轮）：按 lexer 词元配对花括号，产结构化折叠区；
    /// 第 271 轮叠加连续行首注释块（`kind:"comment"`）。字符串/注释整体成词元，故其中的括号
    /// 不参与配对；单行块与单行注释不出折叠（无可隐藏行）。
    /// 边界：`// #region` 标记仍由客户端 language-configuration 折叠。
    fn foldingRange(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        result_json = self.foldingRangesJson(text) catch null;
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "[]");
    }

    /// 花括号配对＋连续行首注释块 → `FoldingRange` JSON 数组；未闭合的开括号静默丢弃。
    /// 行号单次扫进：词元按源码序排列，累计换行即可，不必逐括号重扫全文。
    /// 注释块＝行首（仅水平空白）且与上一条注释行号紧邻的连续 `//` 行；尾随注释不入块、
    /// 空行与代码行断开。块在遇到非注释词元或新块起点时落盘，次序即源码序。
    fn foldingRangesJson(self: *Server, text: []const u8) ![]const u8 {
        const gpa = self.gpa;
        const toks = try lexer.scan(gpa, text);
        defer gpa.free(toks);
        var opens: std.ArrayList(usize) = .empty; // 待配对开括号所在行
        defer opens.deinit(gpa);
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| gpa.free(s);
            items.deinit(gpa);
        }
        var line: usize = 0;
        var scanned: usize = 0;
        var line_begin: usize = 0; // 当前行首字节偏移：判注释是否独占行首
        var prev: ?struct { s: usize, e: usize } = null;
        var cblock: ?struct { s: usize, e: usize } = null;
        for (toks) |t| {
            while (scanned < t.off) : (scanned += 1) {
                if (text[scanned] == '\n') {
                    line += 1;
                    line_begin = scanned + 1;
                }
            }
            if (t.kind == .comment) {
                if (blankBefore(text, line_begin, t.off)) {
                    if (cblock) |b| {
                        if (b.e + 1 == line) {
                            cblock = .{ .s = b.s, .e = line };
                            continue;
                        }
                        try appendCommentFold(gpa, &items, b.s, b.e);
                    }
                    cblock = .{ .s = line, .e = line };
                } else if (cblock) |b| {
                    // 尾随注释打断块：先落已收块，本行不入任何块。
                    try appendCommentFold(gpa, &items, b.s, b.e);
                    cblock = null;
                }
                continue;
            }
            if (cblock) |b| {
                try appendCommentFold(gpa, &items, b.s, b.e);
                cblock = null;
            }
            if (t.kind != .punct or t.len != 1) continue;
            switch (text[t.off]) {
                '{' => try opens.append(gpa, line),
                '}' => {
                    const open_line = opens.pop() orelse continue;
                    if (line == open_line) continue; // 单行块无可隐藏行
                    // 嵌套同跨度的块（`{ if (x) { … } }` 共两行）去重，避免两个同区折叠标记。
                    if (prev) |p| {
                        if (p.s == open_line and p.e == line) continue;
                    }
                    prev = .{ .s = open_line, .e = line };
                    const item = try std.fmt.allocPrint(gpa, f_fold_item, .{ open_line, line });
                    items.append(gpa, item) catch |e| {
                        gpa.free(item);
                        return e;
                    };
                },
                else => {},
            }
        }
        if (cblock) |b| try appendCommentFold(gpa, &items, b.s, b.e);
        return itemsJoinAndFree(gpa, &items);
    }

    /// 悬停：光标词（含点链）反查语言包；未命中/越界/文档不在表 → result null。
    fn hover(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);

        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (objIn(p.get(k_position))) |pos| {
                            const line = intField(pos, k_line) orelse -1;
                            const character = intField(pos, k_character) orelse -1;
                            if (line >= 0 and character >= 0) {
                                if (byteOfPosition(text, @intCast(line), @intCast(character))) |off| {
                                    result_json = self.hoverAt(text, off);
                                }
                            }
                        }
                    }
                }
            }
        }
        try self.respond(out, idv, result_json orelse "null");
    }

    /// 光标处词（含点链整体取词）反查；命中返回 result JSON（调用方 free）、未命中 null。
    fn hoverAt(self: *Server, text: []const u8, off: usize) ?[]const u8 {
        const gpa = self.gpa;
        const toks = lexer.scan(gpa, text) catch return null;
        defer gpa.free(toks);

        var hit: ?lexer.Token = null;
        for (toks) |t| {
            if (t.kind == .nonascii_word and t.off <= off and off < t.off + t.len) {
                hit = t;
                break;
            }
        }
        const t = hit orelse return null;

        // 点链整体取词：`标准库.调试.打印` 系别名键本体、词元只到首段——向两侧跨 `.`+词段扩张。
        var start = t.off;
        var end = t.off + t.len;
        while (start > 0 and text[start - 1] == '.') {
            const seg = stepLeftChainSegment(text, start - 1) orelse break;
            start = seg;
        }
        while (end < text.len and text[end] == '.') {
            const seg = stepRightChainSegment(text, end + 1) orelse break;
            end = seg;
        }
        const chain = text[start..end];

        // 别名（点链）优先整链命中，再退 keywords；分组口径与 155 轮补全一致。
        const alias_val = self.lang.aliases.get(chain);
        const word_val = alias_val orelse self.lang.keywords.get(chain) orelse return null;
        const group = if (alias_val != null) snippets.g_alias else snippets.classify(word_val); // 第 219 轮 D87：与补全产物 .group 同源（原手抄第 2 份）

        // 悬停正文：首行 `**{分组}** \`{链}\`` 为 219 T0 A4 双出口同词锚（不可删）；其后附标准 Zig 形。
        // 若 [docs] 段命中该链，再追加一行大白话「怎么用」（教学面：翻译不止改名、还告诉新手怎么用）。
        const md = if (self.lang.docs.get(chain)) |usage|
            std.fmt.allocPrint(gpa, "**{s}** `{s}`\n\n- 标准 Zig 形：`{s}`\n- 怎么用：{s}", .{ group, chain, word_val, usage }) catch return null
        else
            std.fmt.allocPrint(gpa, "**{s}** `{s}`\n\n- 标准 Zig 形：`{s}`", .{ group, chain, word_val }) catch return null;
        defer gpa.free(md);
        const md_js = jsonrpc.jsonString(gpa, md) catch return null;
        defer gpa.free(md_js);
        const range = rangeJson(gpa, text, start, end) catch return null;
        defer gpa.free(range);
        return std.fmt.allocPrint(gpa, f_hover_result, .{ md_js, range }) catch return null;
    }

    /// `textDocument/semanticTokens/full`（第 161 轮）：对文档全文产语义 token 稀疏流。
    /// 语义高亮仅「被请求才返回」——编辑端未注册 provider 前不应用、无 tmLanguage 降级风险。
    fn semanticTokensFull(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var data_json: ?[]const u8 = null;
        if (params_obj) |p| {
            if (objIn(p.get(k_textDocument))) |td| {
                if (strField(td, k_uri)) |uri| {
                    if (self.docs.get(uri)) |text| {
                        data_json = self.semanticTokensData(text) catch null;
                    }
                }
            }
        }
        const dj = data_json orelse "{\"data\":[]}"; // 文档不在表/无参/分配失败 → 空流（与 hover 缺文本同策）
        try self.respond(out, idv, dj);
        if (data_json) |d| gpa.free(d);
    }

    /// 纯编码器：按源码序遍历可发词元，产 LSP `data` 五元组稀疏数组
    /// `[deltaLine, deltaStart, length, tokenType, tokenModifiers]`（坐标 0 基行 + UTF-16 码元列、
    /// modifiers 恒 0、token 均不跨行）。分类全取 `lexer`+`lang.keywords`+`classify`、不硬编码词表。
    fn semanticTokensData(self: *Server, text: []const u8) ![]const u8 {
        const gpa = self.gpa;
        const toks = try lexer.scan(gpa, text);
        defer gpa.free(toks);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "{\"data\":[");

        var prev_line: usize = 0;
        var prev_char: usize = 0;
        var first = true;
        for (toks) |t| {
            const tt = self.tokenTypeOf(t, text) orelse continue;
            const pos = positionOfOffset(text, t.off);
            var w: usize = 0;
            var i = t.off;
            while (i < t.off + t.len) : (i += seqLen(text, i)) w += cpWidth(text, i);
            const delta_line = pos.line - prev_line;
            const delta_start = if (delta_line == 0) pos.character - prev_char else pos.character;
            if (!first) try out.append(gpa, ',');
            first = false;
            const tup = try std.fmt.allocPrint(gpa, "{d},{d},{d},{d},0", .{ delta_line, delta_start, w, tt });
            defer gpa.free(tup);
            try out.appendSlice(gpa, tup);
            prev_line = pos.line;
            prev_char = pos.character;
        }
        try out.appendSlice(gpa, "]}");
        return out.toOwnedSlice(gpa);
    }

    /// 词元 → LSP tokenTypes 图例索引（null = 不发此 token）。
    /// 跳过策略：未命中 keywords 的母语词/标准库别名段/非数字 ascii 词/punct 一律不发——
    /// 保 tmLanguage 既有着色不被降级、且不越俾符号分析区分标识符作用域（超 MVP）。
    fn tokenTypeOf(self: *Server, t: lexer.Token, text: []const u8) ?u8 {
        return switch (t.kind) {
            .comment => ty_comment,
            .string, .char, .multiline, .symbol => ty_string,
            .nonascii_word => blk: {
                const word = text[t.off..][0..t.len];
                const v = self.lang.keywords.get(word) orelse break :blk null;
                break :blk classToTokenType(snippets.classify(v));
            },
            .ascii_word => blk: {
                const word = text[t.off..][0..t.len];
                break :blk if (word.len > 0 and std.ascii.isDigit(word[0])) ty_number else null;
            },
            .punct => null,
        };
    }
};

/// 从 `.` 位向左吃一个词段（词字节=非 ASCII 或 [0-9A-Za-z_]），返回段起点；空段 null。
fn stepLeftChainSegment(text: []const u8, dot_idx: usize) ?usize {
    if (dot_idx == 0) return null;
    var i = dot_idx - 1;
    if (!isChainWordByte(text[i])) return null;
    while (i > 0 and isChainWordByte(text[i - 1])) i -= 1;
    return i;
}

/// 从段起点（'.' 之后）向右吃一个词段，返回段尾（开区间）；空段 null。
fn stepRightChainSegment(text: []const u8, from: usize) ?usize {
    if (from >= text.len or !isChainWordByte(text[from])) return null;
    var i = from;
    while (i < text.len and isChainWordByte(text[i])) i += 1;
    return i;
}

fn isChainWordByte(c: u8) bool {
    // 第 241 轮 D109：词字节集取单一真值（与 cli/args isWordCharByte、transpiler/lexer 非 ASCII 续读同源）。
    return paths.isWordByte(c);
}

/// `snippets.classify` 词类标签 → LSP tokenTypes 图例索引（第 214 轮 D82：词元名与索引皆取
/// 图例 hub 派生常量，与 initialize 图例强制同序；新增词类须先在 legend_types 立名。
/// 第 219 轮 D87：比较词改引 `snippets.g_*` 单一真值——此前与生成侧各拄一份、改名静默）。
fn classToTokenType(group: []const u8) u8 {
    if (std.mem.eql(u8, group, snippets.g_keyword)) return ty_keyword;
    if (std.mem.eql(u8, group, snippets.g_constant)) return ty_keyword;
    if (std.mem.eql(u8, group, snippets.g_type)) return ty_type;
    if (std.mem.eql(u8, group, snippets.g_builtin)) return ty_function;
    return ty_variable; // 方言词 → variable
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn freeOut(gpa: std.mem.Allocator, out: *OutList) void {
    for (out.items) |m| gpa.free(m);
    out.clearAndFree(gpa);
}

test "lsp.server：initialize 应答含 hover/全量同步能力并回显 id（第 156 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_hover) != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_sync_obj) != null);
    // 第 161 轮：新增语义 token 供给能力（图例七类 + full），供任意 LSP 客户端语义高亮。
    // 第 214 轮 D82 手抄清剿：图例段断言改以 hub 派生的 legend_json 构造（改图例则断言随动，
    // 杜绝「应答与测各抄一份、一改两红」的自照形制）。
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_semtok) != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_docsym) != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_def) != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_refs) != null);
    // 第 273 轮：新增同文件同名符号高亮供给能力。
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_document_highlight) != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_codeaction) != null);
    // 第 270 轮：新增结构化折叠供给能力（花括号配对）。
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_folding) != null);
    // 第 272 轮：新增同文件顶层声明重命名供给能力。
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_rename) != null);
    // 第 275 轮：新增工作区符号供给能力。
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_workspace_symbol) != null);
    // 第 276 轮：新增参数提示供给能力（触发字符形）。
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_signature_help) != null);
    // 第 277 轮：新增智能扩选供给能力。
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_selection_range) != null);
    // 第 279 轮：新增上下文补全供给能力（触发字符 `.`）。
    try testing.expect(std.mem.indexOf(u8, out.items[0], cap_completion) != null);
}

test "第 230 轮 T0 LSP initialize capability 协商串族单源派生与 ps1 对面 needle 形钉：片段组合／值形／serverInfo 程序名派生／cap_face 同源基数／近名负例" {
    // A1 片段组合钉：sync 对象形由三子能力串拼成（写侧应答与 ps1 needle 同吃此组合，杜绝各抄一份）。
    try testing.expectEqualStrings("\"openClose\":true", cap_open_close);
    try testing.expectEqualStrings("\"change\":1", cap_change_full);
    try testing.expectEqualStrings("\"save\":{\"includeText\":false}", cap_save_no_text);
    try testing.expectEqualStrings(
        "\"textDocumentSync\":{\"openClose\":true,\"change\":1,\"save\":{\"includeText\":false}}",
        cap_sync_obj,
    );
    // A2 各 capability 值形钉（本族基线；改形须同时过写侧应答、自测、ps1 守卫对面二十）。
    try testing.expectEqualStrings("\"hoverProvider\":true", cap_hover);
    try testing.expectEqualStrings("\"documentSymbolProvider\":true", cap_docsym);
    try testing.expectEqualStrings("\"definitionProvider\":true", cap_def);
    try testing.expectEqualStrings("\"referencesProvider\":true", cap_refs);
    try testing.expectEqualStrings("\"documentHighlightProvider\":true", cap_document_highlight);
    try testing.expectEqualStrings("\"codeActionProvider\":true", cap_codeaction);
    try testing.expectEqualStrings("\"foldingRangeProvider\":true", cap_folding);
    try testing.expectEqualStrings("\"renameProvider\":{\"prepareProvider\":true}", cap_rename);
    try testing.expectEqualStrings("\"workspaceSymbolProvider\":true", cap_workspace_symbol);
    try testing.expectEqualStrings("\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}", cap_signature_help);
    try testing.expectEqualStrings("\"selectionRangeProvider\":true", cap_selection_range);
    try testing.expectEqualStrings("\"completionProvider\":{\"triggerCharacters\":[\".\"]}", cap_completion);
    try testing.expectEqualStrings("\"semanticTokensProvider\"", cap_semtok_key);
    try testing.expectEqualStrings("\"serverInfo\":{\"name\":\"zzc-lsp\"}", cap_server_info);
    // A3 serverInfo 名程序名派生钉：随 D78 prog_name 真值动（脱钩即此处红·承 matcher_name 形制）。
    try testing.expectEqualStrings("\"serverInfo\":{\"name\":\"" ++ paths.prog_name ++ "-lsp\"}", cap_server_info);
    // A4 cap_face 同源与基数钉：十四枚 needle 逐字节等于写侧 cap_* 常量（守卫据此对 ps1 实文，针源=写侧源）。
    try testing.expectEqual(@as(usize, 14), cap_face.len);
    try testing.expectEqualStrings(cap_sync_obj, cap_face[0].needle);
    try testing.expectEqualStrings(cap_hover, cap_face[1].needle);
    try testing.expectEqualStrings(cap_semtok_key, cap_face[2].needle);
    try testing.expectEqualStrings(cap_docsym, cap_face[3].needle);
    try testing.expectEqualStrings(cap_def, cap_face[4].needle);
    try testing.expectEqualStrings(cap_refs, cap_face[5].needle);
    try testing.expectEqualStrings(cap_document_highlight, cap_face[6].needle);
    try testing.expectEqualStrings(cap_codeaction, cap_face[7].needle);
    try testing.expectEqualStrings(cap_folding, cap_face[8].needle);
    try testing.expectEqualStrings(cap_rename, cap_face[9].needle);
    try testing.expectEqualStrings(cap_workspace_symbol, cap_face[10].needle);
    try testing.expectEqualStrings(cap_signature_help, cap_face[11].needle);
    try testing.expectEqualStrings(cap_selection_range, cap_face[12].needle);
    try testing.expectEqualStrings(cap_completion, cap_face[13].needle);
    // A5 判据小样：真形命中、change:1→2 漂形即缺（t2 P1/P3 消费侧漂形转锚·防子串假命中）。
    const ps1_good = "Contains('" ++ cap_sync_obj ++ "')";
    const ps1_drift = "Contains('\"textDocumentSync\":{\"openClose\":true,\"change\":2,\"save\":{\"includeText\":false}}')";
    try testing.expect(std.mem.indexOf(u8, ps1_good, cap_face[0].needle) != null);
    try testing.expect(std.mem.indexOf(u8, ps1_drift, cap_face[0].needle) == null);
}

test "第 245 轮 T0 e2e 基线脚本内嵌 LSP 帧协议词族单源派生与对面二十二 needle 形钉：八方法＋版本值＋语言 id 逐字节对拍／基数钉／正反小样（防 ps1 帧词独漂静默失联而测恒绿）" {
    // A1 派生形钉：十枚 needle 与 ps1 内嵌帧的期望字面逐字节对拍——本 want 表系独立手抄（ps1
    //   非测图 source dep、@embedFile 越不出 src 包路径·202 轮硬约束），与守卫对面二十二双向互备：
    //   hub 单源漂（m_*/version_value/language_id 被改而未同步手抄期望面）即此测红；ps1 字面漂即守卫红。
    const want = [_][]const u8{ "\"jsonrpc\":\"2.0\"", "\"method\":\"initialize\"", "\"method\":\"initialized\"", "\"method\":\"textDocument/didOpen\"", "\"method\":\"textDocument/didSave\"", "\"method\":\"textDocument/hover\"", "\"method\":\"textDocument/semanticTokens/full\"", "\"method\":\"shutdown\"", "\"method\":\"exit\"", "\"languageId\":\"zig-dialect\"" };
    // A2 基数钉：十枚（八方法 + 版本值 + 语言 id）——增删帧成员须同步 face 与本表，防漏收成员。
    try testing.expectEqual(@as(usize, 10), ps1_frame_face.len);
    try testing.expectEqual(want.len, ps1_frame_face.len);
    for (ps1_frame_face, &want) |f, w| {
        try testing.expectEqualStrings(w, f.needle);
    }
    // A3 正反小样（真帧形命中、方法词漂形即缺——防子串假命中、坐实守卫判据方向）：
    //   initialize→init2 漂形帧不得命中 m_initialize 派生 needle（t2 P1 静默面转锚·活体 init2 形）。
    const frame_good = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    const frame_drift = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"init2\",\"params\":{}}";
    try testing.expect(std.mem.indexOf(u8, frame_good, ps1_frame_face[1].needle) != null);
    try testing.expect(std.mem.indexOf(u8, frame_drift, ps1_frame_face[1].needle) == null);
    // A4 版本/语言 id 单源同步钉：needle 值段随 jsonrpc.version_value / lang_identity.language_id 动。
    try testing.expectEqualStrings("\"jsonrpc\":\"" ++ jsonrpc.version_value ++ "\"", ps1_frame_face[0].needle);
    try testing.expectEqualStrings("\"languageId\":\"" ++ lang_id.language_id ++ "\"", ps1_frame_face[9].needle);
}

test "第 281 轮 T0 冒烟脚本帧词族与 capability 断言族单源派生：三十枚 needle 独立手抄对拍＋基数钉＋删断言负例（D139）" {
    // A1 帧词族二十枚（18 方法词 + 版本值 + 语言 id）与脚本内嵌帧的期望字面逐字节对拍——
    //   本 want 表系独立手抄（脚本非测图 source dep、@embedFile 越不出 src 包路径·202 轮硬约束），
    //   与守卫对面二十三双向互备：hub 单源漂即此测红，脚本字面漂即守卫红。
    const want_frame = [_][]const u8{
        "\"jsonrpc\":\"2.0\"",
        "\"method\":\"initialize\"",
        "\"method\":\"initialized\"",
        "\"method\":\"textDocument/didOpen\"",
        "\"method\":\"textDocument/hover\"",
        "\"method\":\"textDocument/documentSymbol\"",
        "\"method\":\"textDocument/definition\"",
        "\"method\":\"textDocument/references\"",
        "\"method\":\"textDocument/codeAction\"",
        "\"method\":\"textDocument/foldingRange\"",
        "\"method\":\"textDocument/rename\"",
        "\"method\":\"textDocument/documentHighlight\"",
        "\"method\":\"textDocument/prepareRename\"",
        "\"method\":\"workspace/symbol\"",
        "\"method\":\"textDocument/signatureHelp\"",
        "\"method\":\"textDocument/selectionRange\"",
        "\"method\":\"textDocument/completion\"",
        "\"method\":\"shutdown\"",
        "\"method\":\"exit\"",
        "\"languageId\":\"zig-dialect\"",
    };
    try testing.expectEqual(@as(usize, 20), smoke_frame_face.len);
    try testing.expectEqual(want_frame.len, smoke_frame_face.len);
    for (smoke_frame_face, &want_frame) |f, w| try testing.expectEqualStrings(w, f.needle);
    // A2 capability 断言族十三枚（脚本对 initialize 应答逐枚 grep -Fq 的形串）。
    const want_cap = [_][]const u8{
        "\"hoverProvider\":true",
        "\"semanticTokensProvider\"",
        "\"documentSymbolProvider\":true",
        "\"definitionProvider\":true",
        "\"referencesProvider\":true",
        "\"documentHighlightProvider\":true",
        "\"codeActionProvider\":true",
        "\"foldingRangeProvider\":true",
        "\"renameProvider\":{\"prepareProvider\":true}",
        "\"workspaceSymbolProvider\":true",
        "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}",
        "\"selectionRangeProvider\":true",
        "\"completionProvider\":{\"triggerCharacters\":[\".\"]}",
    };
    try testing.expectEqual(@as(usize, 13), smoke_cap_face.len);
    try testing.expectEqual(want_cap.len, smoke_cap_face.len);
    for (smoke_cap_face, &want_cap) |f, w| try testing.expectEqualStrings(w, f.needle);
    // A3 值段单源同步钉：两族的形串随 cap_*／m_*／version_value／language_id 真值同动（防手抄表与派生形脱钩）。
    try testing.expectEqualStrings(cap_completion, smoke_cap_face[12].needle);
    try testing.expectEqualStrings(cap_signature_help, smoke_cap_face[10].needle);
    try testing.expectEqualStrings("\"method\":\"" ++ m_completion ++ "\"", smoke_frame_face[16].needle);
    try testing.expectEqualStrings("\"languageId\":\"" ++ lang_id.language_id ++ "\"", smoke_frame_face[19].needle);
    // A4 边界登册负例：脚本从不断言 textDocumentSync 对象形与 serverInfo，故二者不得入本面
    //   （入面即守卫红——如实记「不断言」比伪称全覆盖更诚实，同 ps1 cap_face 对 serverInfo 的处置）。
    for (smoke_cap_face) |f| {
        try testing.expect(std.mem.indexOf(u8, cap_sync_obj, f.needle) == null);
    }
    // A5 正反小样（P1 静默面转锚）：断言在位即命中，**整行断言被删**即缺针；方法词漂形亦不命中。
    const sh_with = "send '{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/completion\"}'\ngrep -Fq '\"completionProvider\":{\"triggerCharacters\":[\".\"]}' \"$out\" || fail \"x\"\n";
    const sh_minus = "send '{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/completion\"}'\n";
    try testing.expect(std.mem.indexOf(u8, sh_with, smoke_cap_face[12].needle) != null);
    try testing.expect(std.mem.indexOf(u8, sh_minus, smoke_cap_face[12].needle) == null);
    const sh_drift = "\"method\":\"textDocument/completionX\"";
    try testing.expect(std.mem.indexOf(u8, sh_drift, smoke_frame_face[16].needle) == null);
    // A6 收尾一致性：脚本发起的十八枚方法词，每一枚都须在 dispatch 真值面 m_* 上有同名针（漏收成员即此红）。
    var n: usize = 0;
    for (smoke_frame_face) |f| {
        if (std.mem.startsWith(u8, f.needle, "\"method\":\"")) n += 1;
    }
    try testing.expectEqual(@as(usize, 18), n);
}

test "第 282 轮 T0 capability 键名段单源抽取与对面二十四 needle 形钉：十三枚独立手抄对拍＋基数钉＋抽取边界（D141）" {
    // A1 独立手抄对拍：本 want 表照 `tools/extension-smoke.js` 的键名数组逐枚手抄（脚本非测图 source dep）。
    const want = [_][]const u8{
        "'hoverProvider'",
        "'completionProvider'",
        "'selectionRangeProvider'",
        "'signatureHelpProvider'",
        "'workspaceSymbolProvider'",
        "'documentSymbolProvider'",
        "'definitionProvider'",
        "'referencesProvider'",
        "'documentHighlightProvider'",
        "'codeActionProvider'",
        "'foldingRangeProvider'",
        "'renameProvider'",
        "'semanticTokensProvider'",
    };
    try testing.expectEqual(@as(usize, 13), smoke_js_cap_face.len);
    try testing.expectEqual(want.len, smoke_js_cap_face.len);
    for (smoke_js_cap_face, &want) |f, w| try testing.expectEqualStrings(w, f.needle);
    // A2 抽取函数边界：形串首键即键名段；无形可抽时原样返回（派生针必落空，宁红不假绿）。
    try testing.expectEqualStrings("hoverProvider", capKeyOf(cap_hover));
    try testing.expectEqualStrings("textDocumentSync", capKeyOf(cap_sync_obj));
    try testing.expectEqualStrings("semanticTokensProvider", capKeyOf(cap_semtok_key));
    try testing.expectEqualStrings("noquote-here", capKeyOf("noquote-here"));
    try testing.expectEqualStrings("unterminated\"", capKeyOf("unterminated\""));
    // A3 值段单源同步钉：改写侧 cap_* 的键名，needle 必随动（防手抄表与派生形脱钩成自证绿）。
    try testing.expect(std.mem.indexOf(u8, smoke_js_cap_face[1].needle, capKeyOf(cap_completion)) != null);
    // A4 正反小样：脚本数组实形命中；键名漂形（多一个 r）不命中——坐实守卫判据方向。
    const sh_good = "for (const cap of ['hoverProvider', 'completionProvider']) {";
    try testing.expect(std.mem.indexOf(u8, sh_good, smoke_js_cap_face[0].needle) != null);
    try testing.expect(std.mem.indexOf(u8, sh_good, smoke_js_cap_face[1].needle) != null);
    const sh_drift = "for (const cap of ['hoverrProvider']) {";
    try testing.expect(std.mem.indexOf(u8, sh_drift, smoke_js_cap_face[0].needle) == null);
    // A5 边界登册负例：脚本不断言 sync 对象形与 serverInfo，二者不得入本面。
    for (smoke_js_cap_face) |f| {
        try testing.expect(std.mem.indexOf(u8, cap_sync_obj, f.needle) == null);
    }
    // A6 键名族与方法面同骨：本面十三枚皆以 Provider 收尾（键名族形制自守，防误收非 provider 针）。
    for (smoke_js_cap_face) |f| {
        try testing.expect(std.mem.endsWith(u8, f.needle, "Provider'"));
    }
}

// ———————————————————————————— 测试（285 T0）————————————————————————————

test "第 285 轮 T0 provider 短名抽取与对面二十六 needle 形钉：十三枚名针独立手抄对拍＋循环头与判据体形针＋P1/P2 探针形反证（D144）" {
    // A1 名针与独立手抄表对拍（顺序照 js 的 provider 数组）＋基数钉 十五（13 名针 + 2 形针）。
    const want = [_][]const u8{
        "'hover'",           "'completion'", "'signatureHelp'",  "'selectionRange'",    "'documentSymbol'",
        "'workspaceSymbol'", "'definition'", "'references'",     "'documentHighlight'", "'codeAction'",
        "'foldingRange'",    "'rename'",     "'semanticTokens'",
    };
    try testing.expectEqual(@as(usize, 15), smoke_js_provider_face.len);
    for (smoke_js_provider_face[0..13], want) |f, w| try testing.expectEqualStrings(w, f.needle);
    // A2 形针本体钉：循环头与判据体（判据体含循环变量下标，P2 的拦截全在这一枚）。
    try testing.expectEqualStrings("for (const name of [", smoke_js_provider_face[13].needle);
    try testing.expectEqualStrings("ok(!!P[name], ", smoke_js_provider_face[14].needle);
    // A3 抽取器边界：剥尾段只剥一次（renameProvider 应答形含嵌套 prepareProvider，键段仍只一尾）；
    //   无尾段可剥时原样返回（派生针必落空，宁红不假绿）。
    try testing.expectEqualStrings("rename", capKeyShort(cap_rename));
    try testing.expectEqualStrings("textDocumentSync", capKeyShort(cap_sync_obj));
    try testing.expectEqualStrings("plainKey", capKeyOf("\"plainKey\":true"));
    // A4 值段同步钉：名针与写侧 cap_* 同源（改键名即名针随动，非手抄表自证）。
    try testing.expect(std.mem.indexOf(u8, smoke_js_provider_face[1].needle, capKeyShort(cap_completion)) != null);
    for (smoke_js_provider_face[0..13]) |f| {
        try testing.expect(std.mem.indexOf(u8, f.needle, "Provider") == null); // 短名不得再带尾段
    }
    // A5 探针 P1 形反证：把 'completion' 顶替为重复的 'hover' 后，名集仍得十三枚而本面缺针。
    const list_good = "for (const name of ['hover', 'completion', 'signatureHelp', 'selectionRange', " ++
        "'documentSymbol', 'workspaceSymbol', 'definition', 'references', 'documentHighlight', " ++
        "'codeAction', 'foldingRange', 'rename', 'semanticTokens']) {";
    for (smoke_js_provider_face[0..13]) |f| {
        try testing.expect(std.mem.indexOf(u8, list_good, f.needle) != null);
    }
    try testing.expect(std.mem.indexOf(u8, list_good, smoke_js_provider_face[13].needle) != null); // 循环头亦在实形里
    const list_dup = "for (const name of ['hover', 'hover', 'signatureHelp']) {";
    try testing.expect(std.mem.indexOf(u8, list_dup, smoke_js_provider_face[1].needle) == null);
    // A6 探针 P2 形反证：判据去下标（`!!P[name]`→`!!P`）即判据体针落空；而该形在 js 里依旧逐枚打
    //   `[ok]` 并 PASS 退 0，坐实本针是本静默形的唯一拦头。
    const body_dead = "ok(!!P, '已注册 provider：' + name);";
    try testing.expect(std.mem.indexOf(u8, body_dead, smoke_js_provider_face[14].needle) == null);
    const body_good = "ok(!!P[name], '已注册 provider：' + name);";
    try testing.expect(std.mem.indexOf(u8, body_good, smoke_js_provider_face[14].needle) != null);
    // A7 与 282 键名面不同职自证：同一 provider 在两面的 needle 形不同（短名 vs 键名），
    //   只收一面则另一形可被静默拆——两面并存才是全覆盖。
    try testing.expectEqualStrings("'hover'", smoke_js_provider_face[0].needle);
    try testing.expectEqualStrings("'hoverProvider'", smoke_js_cap_face[0].needle);
}

test "lsp.server：didOpen 坏源→publishDiagnostics 词法形、坐标 0 基 UTF-16（第 156 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    // 全角逗号 `，` 前恰有 8 个 BMP 码元（常数␣a␣=␣1）
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.zz\",\"text\":\"常数 a = 1，\\n\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
    defer parsed.deinit();
    const root = asObject(parsed.value).?;
    const mth = strField(root, k_method).?;
    try testing.expectEqualStrings("textDocument/publishDiagnostics", mth);
    const po = objIn(root.get(k_params)).?;
    const arr = switch (po.get(k_diagnostics).?) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(arr.len >= 1);
    const d0 = asObject(arr[0]).?;
    const rng = asObject(d0.get(k_range).?).?;
    const st = asObject(rng.get(k_start).?).?;
    try testing.expectEqual(@as(i64, 0), intField(st, k_line).?);
    try testing.expectEqual(@as(i64, 8), intField(st, k_character).?);
    const msg = strField(d0, k_message).?;
    try testing.expect(std.mem.indexOf(u8, msg, "词法") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "半角") != null);
}

test "lsp.server：hover 方言词命中 keywords、与补全描述同口径；未命中 null（第 156 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.zz\",\"text\":\"常数 甲 = 1;\\n\"}}}", &out);
    freeOut(gpa, &out);

    // 悬停 (0,0) 落在 `常数` 上
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.zz\"},\"position\":{\"line\":0,\"character\":0}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":3") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "const") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "**" ++ snippets.g_keyword ++ "**") != null); // 第 219 轮 D87 伪钉改严：锚 md 组词形，前缀扩展不可穿透

    freeOut(gpa, &out);
    // 悬停行尾越界列：无结果不崩（越界拒、不 clamp）
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.zz\"},\"position\":{\"line\":0,\"character\":99}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
}

test "lsp.server：didChange 全文替换后诊断更新；didClose 清空发布空数组（第 156 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///c.zz\",\"text\":\"常数 a = 1，\\n\"}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "词法") != null);
    freeOut(gpa, &out);

    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///c.zz\"},\"contentChanges\":[{\"text\":\"常数 a = 1;\\n\"}]}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"diagnostics\":[]") != null);
    freeOut(gpa, &out);

    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///c.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"diagnostics\":[]") != null);

    freeOut(gpa, &out);
    // 文档表已删：再悬停必 null
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///c.zz\"},\"position\":{\"line\":0,\"character\":0}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
}

test "lsp.server：exit 置停、未知请求 -32601、坏 JSON -32700、通知无应答（第 156 轮·协议面）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}", &out);
    try testing.expect(srv.stop);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"textDocument/implementation\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], ek_code ++ ":" ++ std.fmt.comptimePrint("{d}", .{ec_method_not_found})) != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":\"abc\"") != null); // 字符串 id 原样回显
    freeOut(gpa, &out);

    try srv.handle("not-json{{{", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], ek_code ++ ":" ++ std.fmt.comptimePrint("{d}", .{ec_parse_error})) != null);
    freeOut(gpa, &out);

    // 未知通知（无 id）：静默
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "lsp.server：hover 点链别名整体取词（标准库.调试.打印 形）（第 156 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    const doc_text = "标准库.调试.打印(\"甲\");\n";
    const text_js = try jsonrpc.jsonString(gpa, doc_text);
    const open = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///a.zz\",\"text\":{s}}}}}}}", .{text_js});
    defer gpa.free(open);
    try srv.handle(open, &out);
    freeOut(gpa, &out);

    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zz\"},\"position\":{\"line\":0,\"character\":0}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "**" ++ snippets.g_alias ++ "**") != null); // 第 219 轮 D87 伪钉改严：宽松子串曾被前缀扩展形穿透（t2 P1 主靶）
    try testing.expect(std.mem.indexOf(u8, out.items[0], "std.debug.print") != null);

    // 点链中段悬停（`调试` 上）亦整体取词到叶链
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zz\"},\"position\":{\"line\":0,\"character\":4}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "std.debug.print") != null);
}

test "lsp.server：codeAction 全角标点快速修复／选区不相交出空／无建议值不出修复（第 268 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);

    const doc_text = "常数 甲 = 1，\n常数 乙 = 2；\n";
    const text_js = try jsonrpc.jsonString(gpa, doc_text);
    const open = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///fix.zz\",\"text\":{s}}}}}}}", .{text_js});
    defer gpa.free(open);
    try srv.handle(open, &out);
    freeOut(gpa, &out);

    // 光标（空选区）落在全角逗号上：一条 quickfix，范围恰为逗号本身，newText 为半角逗号。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"file:///fix.zz\"},\"range\":{\"start\":{\"line\":0,\"character\":8},\"end\":{\"line\":0,\"character\":8}},\"context\":{\"diagnostics\":[]}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "全角逗号") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"kind\":\"quickfix\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"newText\":\",\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"range\":{\"start\":{\"line\":0,\"character\":8},\"end\":{\"line\":0,\"character\":9}}") != null);

    // 选区与违规不交叠（行首两字）：空数组，不给全局修复。
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"file:///fix.zz\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":2}},\"context\":{\"diagnostics\":[]}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":[]") != null);

    // 无建议替换值的违规（零宽空格）不出「修复」——先钉「确有此违规」，再验空数组。
    const zw = "常数 甲 = 1;\u{200B}";
    const vs = try translate.preCheck(gpa, zw);
    defer gpa.free(vs);
    var zero_ascii = false;
    for (vs) |v| {
        if (v.ascii.len == 0) zero_ascii = true;
    }
    try testing.expect(zero_ascii);
    const none = try srv.fixActionsJson(zw, "file:///fix.zz", 0, zw.len);
    defer gpa.free(none);
    try testing.expectEqualStrings("[]", none);

    // 文档级 source.fixAll（第 269 轮）：只在 context.only 请求时返回；单条动作
    // 批量覆盖全文两处违规，不混入单点 quickfix。
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"file:///fix.zz\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"context\":{\"diagnostics\":[],\"only\":[\"source.fixAll\"]}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"kind\":\"source.fixAll\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "修复全文全角标点（2 处）") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"newText\":\",\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"newText\":\";\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"kind\":\"quickfix\"") == null);

    // 结构面（第 278 轮）：changes[uri] 必须直接是 edit 数组。曾因模板多套一层 `[]`
    // 成 [[{...}]]——上面几条 newText 文本断言全绿，而真实客户端读 c.range 抛错。
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
        defer parsed.deinit();
        const root = asObject(parsed.value).?;
        const items_arr = switch (root.get("result").?) {
            .array => |a| a.items,
            else => return error.TestUnexpectedResult,
        };
        const first = objIn(items_arr[0]).?;
        const changes = objIn(objIn(first.get(k_edit)).?.get(k_changes)).?;
        const edits_arr = switch (changes.get("file:///fix.zz").?) {
            .array => |a| a.items,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(@as(usize, 2), edits_arr.len);
        const e0 = objIn(edits_arr[0]).?;
        try testing.expect(objIn(e0.get(k_range)) != null);
        try testing.expect(e0.get(k_newText) != null);
    }

    // only 只要 quickfix：仍只出单点臂，批量动作不混入。
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"file:///fix.zz\"},\"range\":{\"start\":{\"line\":0,\"character\":8},\"end\":{\"line\":0,\"character\":8}},\"context\":{\"diagnostics\":[],\"only\":[\"quickfix\"]}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"kind\":\"quickfix\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "source.fixAll") == null);

    // 空 only / 未知 kind：严格按 LSP「只在请求的 kind 内返回」→ 空数组。
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"file:///fix.zz\"},\"range\":{\"start\":{\"line\":0,\"character\":8},\"end\":{\"line\":0,\"character\":8}},\"context\":{\"diagnostics\":[],\"only\":[]}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":[]") != null);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"file:///fix.zz\"},\"range\":{\"start\":{\"line\":0,\"character\":8},\"end\":{\"line\":0,\"character\":8}},\"context\":{\"diagnostics\":[],\"only\":[\"source.organizeImports\"]}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":[]") != null);

    // 全文无可修项时不出空动作（零宽空格无建议值）。
    const no_fix_all = try srv.fixAllItem(zw, "file:///fix.zz");
    try testing.expect(no_fix_all == null);
}

test "lsp.server：foldingRange 花括号配对／单行块略过／字符串与注释内括号不误判（第 270 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);

    const doc_text = "公开 函数 主函数() !空 {\n" ++
        "    如果 (真) {\n" ++
        "        标准库.调试.打印(\"括号 { 与 } 不参与\\n\", .{});\n" ++
        "    }\n" ++
        "    // 注释里的 } 不参与\n" ++
        "}\n" ++
        "常数 单行 = .{ 1, 2 };\n" ++
        "}\n";
    const text_js = try jsonrpc.jsonString(gpa, doc_text);
    const open = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///fold.zz\",\"text\":{s}}}}}}}", .{text_js});
    defer gpa.free(open);
    try srv.handle(open, &out);
    freeOut(gpa, &out);

    // 内层块先闭合先出；字符串/注释内的括号不参与；单行块与孤立闭括号略过。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///fold.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":[{\"startLine\":1,\"endLine\":3},{\"startLine\":0,\"endLine\":5}]") != null);

    // 未打开文档 → 空数组（与 hover/semantic 同策）。
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///nope.zz\"}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":[]") != null);

    // 嵌套同跨度去重：两个 `{` 与两个 `}` 各居首尾两行，只出一个折叠区。
    const dedup = try srv.foldingRangesJson("公开 函数 甲() 空 { 如果 (真) {\n乙();\n} }\n");
    defer gpa.free(dedup);
    try testing.expectEqualStrings("[{\"startLine\":0,\"endLine\":2}]", dedup);

    // 未闭合开括号静默丢弃（词法级容错，不因半截源码拒绝其余块）。
    const unclosed = try srv.foldingRangesJson("公开 函数 乙() 空 {\n乙();\n");
    defer gpa.free(unclosed);
    try testing.expectEqualStrings("[]", unclosed);
}

test "第 279 轮 T0 lsp.server：上下文补全 completion——前缀四源（声明/关键字/别名根/点链）与 textEdit、字面量与前缀缺席皆空表" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    const doc = "常数 求和 = 1;\n" ++
        "公开 函数 求差(甲: 整数, 乙: 整数) 整数 {\n" ++
        "    返回 甲;\n" ++
        "}\n" ++
        "常数 文本 = \"常数 假词\";\n" ++
        "// 常数 注释词\n" ++
        "标准库.调\n";
    const uri = "file:///comp.zz";
    const uri_js = try jsonrpc.jsonString(gpa, uri);
    defer gpa.free(uri_js);
    const body_js = try jsonrpc.jsonString(gpa, doc);
    defer gpa.free(body_js);

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    const open = try std.fmt.allocPrint(gpa, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_method ++ "\":\"" ++ m_didOpen ++ "\",\"" ++ k_params ++ "\":" ++ f_didOpen_params ++ "}}", .{ uri_js, body_js });
    defer gpa.free(open);
    try srv.handle(open, &out); // 附一条诊断通知，不影响后续（每次请求前先清表）

    const Req = struct {
        srv: *Server,
        gpa: std.mem.Allocator,
        uri_js: []const u8,

        fn call(self: @This(), outlist: *OutList, line: usize, character: usize) !void {
            outlist.* = .empty;
            const req = try std.fmt.allocPrint(self.gpa, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_id ++ "\":9,\"" ++ k_method ++ "\":\"" ++ m_completion ++ "\",\"" ++ k_params ++ "\":" ++ f_hover_params ++ "}}", .{ self.uri_js, line, character });
            defer self.gpa.free(req);
            try self.srv.handle(req, outlist);
            try testing.expectEqual(@as(usize, 1), outlist.items.len);
        }
    };
    const rq = Req{ .srv = &srv, .gpa = gpa, .uri_js = uri_js };

    // A1 声明优先：光标在 `求` 后 → 本文件顶层声明 `求和`/`求差` 均入选，且排在前（detail 同词）。
    try rq.call(&out, 0, 4);
    const r1 = out.items[0];
    try testing.expect(std.mem.indexOf(u8, r1, "\"label\":\"求和\"") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "\"label\":\"求差\"") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "\"detail\":\"本文件声明\"") != null);
    try testing.expect(std.mem.indexOf(u8, r1, needle_incomplete_false) != null);
    try testing.expect(std.mem.indexOf(u8, r1, "\"textEdit\"") == null); // 非点链不换范围
    try testing.expect(std.mem.indexOf(u8, r1, "求和").? < std.mem.indexOf(u8, r1, "求差").?); // rank 同档按名序

    // A2 关键字：光标在 `常数` 后 → keyword 项（kind=14・detail=const），声明项不混入。
    try rq.call(&out, 0, 2);
    const r2 = out.items[0];
    try testing.expect(std.mem.indexOf(u8, r2, "\"label\":\"常数\"") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "\"kind\":14") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "\"detail\":\"const\"") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "本文件声明") == null);

    // A3 点链：光标在 `标准库.调` 后→ aliases 长链候选，带 textEdit 替换整链前缀。
    try rq.call(&out, 6, 5);
    const r3 = out.items[0];
    try testing.expect(std.mem.indexOf(u8, r3, "标准库.调试.打印") != null);
    try testing.expect(std.mem.indexOf(u8, r3, "\"textEdit\"") != null);
    try testing.expect(std.mem.indexOf(u8, r3, "\"newText\":\"标准库.调试.打印\"") != null);
    try testing.expect(std.mem.indexOf(u8, r3, "\"start\":{\"line\":6,\"character\":0}") != null);
    try testing.expect(std.mem.indexOf(u8, r3, "\"end\":{\"line\":6,\"character\":5}") != null);
    try testing.expect(std.mem.indexOf(u8, r3, "\"detail\":\"const\"") == null); // 点链臂不串关键字源
    try testing.expect(std.mem.indexOf(u8, r3, "\"documentation\"") != null); // docs 已接补全详情

    // A4 字面量与注释内不弹：光标在字符串中的 `假` 后、在注释词中 → 空表。
    try rq.call(&out, 4, 13);
    try testing.expect(std.mem.indexOf(u8, out.items[0], needle_empty_completion) != null);
    try rq.call(&out, 5, 7);
    try testing.expect(std.mem.indexOf(u8, out.items[0], needle_empty_completion) != null);

    // A5 无前缀（光标停在空白/标点后）与未打开文档 → 空表。
    try rq.call(&out, 0, 3);
    try testing.expect(std.mem.indexOf(u8, out.items[0], needle_empty_completion) != null);
    {
        const other = try jsonrpc.jsonString(gpa, "file:///never-opened.zz");
        defer gpa.free(other);
        const req = try std.fmt.allocPrint(gpa, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_id ++ "\":9,\"" ++ k_method ++ "\":\"" ++ m_completion ++ "\",\"" ++ k_params ++ "\":" ++ f_hover_params ++ "}}", .{ other, 0, 2 });
        defer gpa.free(req);
        out = .empty;
        try srv.handle(req, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expect(std.mem.indexOf(u8, out.items[0], needle_empty_completion) != null);
    }

    // A6 结构面：result.items 为数组、每项 label/kind/detail 三键俱在且 kind 为数值。
    {
        try rq.call(&out, 0, 4);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
        defer parsed.deinit();
        const res = objIn(asObject(parsed.value).?.get(k_result)).?;
        switch (res.get(k_isIncomplete).?) {
            .bool => |b| try testing.expect(!b),
            else => return error.TestUnexpectedResult,
        }
        const items = switch (res.get(k_items).?) {
            .array => |a| a.items,
            else => return error.TestUnexpectedResult,
        };
        try testing.expect(items.len >= 2);
        for (items) |it| {
            const o = objIn(it).?;
            try testing.expect(strField(o, k_label) != null);
            try testing.expect(intField(o, k_kind) != null);
            try testing.expect(strField(o, k_detail) != null);
        }
    }
}

test "lsp.server：foldingRange 注释块——连续行成块／空行与代码断开／尾随注释不入块（第 271 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    // 三行行首注释成块；空行断开后两行成第二块且不吸收尾随注释；
    // 函数体内注释块与花括号块并存，块先于其后的词元落盘（源码序）。
    const doc = "// 第一行\n" ++
        "// 第二行\n" ++
        "// 第三行\n" ++
        "\n" ++
        "// 甲\n" ++
        "// 乙\n" ++
        "常数 甲 = 1; // 尾随不入块\n" ++
        "公开 函数 主函数() 空 {\n" ++
        "    // 体内一\n" ++
        "    // 体内二\n" ++
        "    甲();\n" ++
        "}\n";
    const folds = try srv.foldingRangesJson(doc);
    defer gpa.free(folds);
    try testing.expectEqualStrings("[{\"startLine\":0,\"endLine\":2,\"kind\":\"comment\"}," ++
        "{\"startLine\":4,\"endLine\":5,\"kind\":\"comment\"}," ++
        "{\"startLine\":8,\"endLine\":9,\"kind\":\"comment\"}," ++
        "{\"startLine\":7,\"endLine\":11}]", folds);

    // 尾随注释不能自成块：两行尾随各自独立→无折叠。
    const trailing = try srv.foldingRangesJson("甲(); // 一\n乙(); // 二\n");
    defer gpa.free(trailing);
    try testing.expectEqualStrings("[]", trailing);

    // 单行注释不出折叠（无可隐藏行）。
    const single = try srv.foldingRangesJson("// 独占一行\n甲();\n");
    defer gpa.free(single);
    try testing.expectEqualStrings("[]", single);
}

test "lsp.server：rename 顶层声明全量改名／非法新名与非声明光标拒改（第 272 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);

    const doc = "常数 标准库 = 导入(\"std\");\n" ++
        "公开 函数 主函数() !空 {\n" ++
        "    标准库.调试.打印(\"标准库\", .{});\n" ++
        "}\n" ++
        "// 标准库\n";
    const text_js = try jsonrpc.jsonString(gpa, doc);
    const open = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///ren.zz\",\"text\":{s}}}}}}}", .{text_js});
    try srv.handle(open, &out);
    freeOut(gpa, &out);

    // A1 从引用处发起：声明与引用两处编辑；字符串/注释内的同名不参与。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///ren.zz\"},\"position\":{\"line\":2,\"character\":4},\"newName\":\"工具\"}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":{\"changes\":{\"file:///ren.zz\":[" ++
        "{\"range\":{\"start\":{\"line\":0,\"character\":3},\"end\":{\"line\":0,\"character\":6}},\"newText\":\"工具\"}," ++
        "{\"range\":{\"start\":{\"line\":2,\"character\":4},\"end\":{\"line\":2,\"character\":7}},\"newText\":\"工具\"}]}}") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items[0], "\"newText\":\"工具\""));

    // A2 从声明处发起：与引用处同集合（changes 表同键、编辑数仍为 2）。
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///ren.zz\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"工具\"}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"changes\":{\"file:///ren.zz\":[") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items[0], "\"newText\":\"工具\""));

    // A3 非法新名：空串/含空格/含点/数字开头 → null（编辑器不弹替换框）。
    const bad_names = [_][]const u8{ "", "工具 甲", "工具.调试", "1工具" };
    for (bad_names) |bad| {
        freeOut(gpa, &out);
        const req = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/rename\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///ren.zz\"}},\"position\":{{\"line\":2,\"character\":4}},\"newName\":\"{s}\"}}}}", .{bad});
        try srv.handle(req, &out);
        try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
    }

    // A4 非声明光标：成员调用词与字符串内词均拒改。
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///ren.zz\"},\"position\":{\"line\":2,\"character\":11},\"newName\":\"工具\"}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///ren.zz\"},\"position\":{\"line\":2,\"character\":15},\"newName\":\"工具\"}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);

    // A5 未打开文档 → null；新名合法性闸直接钉（含引号/注释/标点形态）。
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///none.zz\"},\"position\":{\"line\":0,\"character\":0},\"newName\":\"工具\"}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
    try testing.expect(validRenameName(gpa, "工具"));
    try testing.expect(validRenameName(gpa, "abc"));
    try testing.expect(validRenameName(gpa, "zh_1"));
    try testing.expect(!validRenameName(gpa, ""));
    try testing.expect(!validRenameName(gpa, "\"工具\""));
    try testing.expect(!validRenameName(gpa, "// 工具"));
    try testing.expect(!validRenameName(gpa, "工具；"));
}

test "第 273 轮 documentHighlight：声明位 Write／引用位 Read／字符串注释不混入／非声明词空数组" {
    const tg = testing.allocator;
    // A1 协议码值钉：LSP DocumentHighlightKind 1/2/3——客户端映射针由 hk_write 派生。
    try testing.expectEqual(@as(u8, 1), hk_text);
    try testing.expectEqual(@as(u8, 2), hk_read);
    try testing.expectEqual(@as(u8, 3), hk_write);
    // A2 模板 round-trip：range + kind 渲染后以 k_* 回读。
    {
        const rg = try std.fmt.allocPrint(tg, f_range_json, .{ @as(usize, 0), @as(usize, 1), @as(usize, 0), @as(usize, 3) });
        defer tg.free(rg);
        const one = try std.fmt.allocPrint(tg, f_highlight_item, .{ rg, hk_write });
        defer tg.free(one);
        var p = try std.json.parseFromSlice(std.json.Value, tg, one, .{});
        defer p.deinit();
        const o = asObject(p.value).?;
        try testing.expect(objIn(o.get(k_range)) != null);
        try testing.expectEqual(@as(i64, hk_write), intField(o, k_kind).?);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    const text =
        "常数 上限 = 1;\n" ++
        "函数 主函数() 空 {\n" ++
        "    返回 上限;\n" ++
        "}\n" ++
        "常数 提示 = \"上限\";\n" ++
        "// 上限\n";
    const uri = "file:///h.zz";
    const decl_off = std.mem.indexOf(u8, text, "上限").?;
    const ret_off = std.mem.indexOf(u8, text, "返回").?;
    const ref_off = std.mem.indexOfPos(u8, text, ret_off, "上限").?;

    // A3 从声明发起：声明位 Write(3)、函数体引用位 Read(2)；字符串/注释同名不混入。
    const from_decl = try srv.highlightAt(text, decl_off);
    defer gpa.free(from_decl);
    try testing.expectEqualStrings(
        "[{\"range\":{\"start\":{\"line\":0,\"character\":3},\"end\":{\"line\":0,\"character\":5}},\"kind\":3}," ++
            "{\"range\":{\"start\":{\"line\":2,\"character\":7},\"end\":{\"line\":2,\"character\":9}},\"kind\":2}]",
        from_decl,
    );
    // A4 从引用发起：与声明发起同集（同词元扫描，不因光标位置改归属）。
    const from_ref = try srv.highlightAt(text, ref_off);
    defer gpa.free(from_ref);
    try testing.expectEqualStrings(from_decl, from_ref);

    // A5 字符串/注释/非声明词（关键字）→ 空数组。
    const str_off = (std.mem.indexOf(u8, text, "\"上限\"") orelse return error.TestUnexpectedResult) + 1;
    const empty1 = try srv.highlightAt(text, str_off);
    defer gpa.free(empty1);
    try testing.expectEqualStrings("[]", empty1);
    const cmt_off = (std.mem.indexOf(u8, text, "// 上限") orelse return error.TestUnexpectedResult) + 3;
    const empty2 = try srv.highlightAt(text, cmt_off);
    defer gpa.free(empty2);
    try testing.expectEqualStrings("[]", empty2);
    const empty3 = try srv.highlightAt(text, ret_off);
    defer gpa.free(empty3);
    try testing.expectEqualStrings("[]", empty3);

    // A6 dispatch：打开文档后从声明处请求 → 真应答（两项、两种 kind）；未打开文档 → []。
    try srv.upsertDoc(uri, text);
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"textDocument/documentHighlight\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.zz\"},\"position\":{\"line\":0,\"character\":3}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":11") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items[0], "\"kind\":"));
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"kind\":3") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"kind\":2") != null);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"textDocument/documentHighlight\",\"params\":{\"textDocument\":{\"uri\":\"file:///none.zz\"},\"position\":{\"line\":0,\"character\":0}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":[]") != null);
}

test "第 274 轮 prepareRename：声明/引用/词尾三入口范围与占位符／字符串注释非声明词 null" {
    const tg = testing.allocator;
    // A1 模板 round-trip：range + placeholder 渲染后以 k_* 回读。
    {
        const rg = try std.fmt.allocPrint(tg, f_range_json, .{ @as(usize, 0), @as(usize, 3), @as(usize, 0), @as(usize, 5) });
        defer tg.free(rg);
        const name_js = try jsonrpc.jsonString(tg, "上限");
        defer tg.free(name_js);
        const one = try std.fmt.allocPrint(tg, f_prepare_rename, .{ rg, name_js });
        defer tg.free(one);
        var p = try std.json.parseFromSlice(std.json.Value, tg, one, .{});
        defer p.deinit();
        const o = asObject(p.value).?;
        try testing.expect(objIn(o.get(k_range)) != null);
        try testing.expectEqualStrings("上限", strField(o, k_placeholder).?);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    const text =
        "常数 上限 = 1;\n" ++
        "函数 主函数() 空 {\n" ++
        "    返回 上限;\n" ++
        "}\n" ++
        "常数 提示 = \"上限\";\n" ++
        "// 上限\n";
    const uri = "file:///p.zz";
    const decl_off = std.mem.indexOf(u8, text, "上限").?;
    const ret_off = std.mem.indexOf(u8, text, "返回").?;
    const ref_off = std.mem.indexOfPos(u8, text, ret_off, "上限").?;

    // A2 声明处：范围即声明词，占位符即旧名。
    const from_decl = (try srv.prepareRenameAt(text, decl_off)) orelse return error.TestUnexpectedResult;
    defer gpa.free(from_decl);
    try testing.expectEqualStrings("{\"range\":{\"start\":{\"line\":0,\"character\":3},\"end\":{\"line\":0,\"character\":5}},\"placeholder\":\"上限\"}", from_decl);
    // A3 引用处：范围为光标词本身（非声明位），占位符同旧名。
    const from_ref = (try srv.prepareRenameAt(text, ref_off)) orelse return error.TestUnexpectedResult;
    defer gpa.free(from_ref);
    try testing.expectEqualStrings("{\"range\":{\"start\":{\"line\":2,\"character\":7},\"end\":{\"line\":2,\"character\":9}},\"placeholder\":\"上限\"}", from_ref);
    // A4 词尾回退：光标停在末字符之后仍取前一词元。
    const tail = (try srv.prepareRenameAt(text, ref_off + "上限".len)) orelse return error.TestUnexpectedResult;
    defer gpa.free(tail);
    try testing.expectEqualStrings(from_ref, tail);

    // A5 字符串/注释/非声明词 → null（不可改名处不弹 F2 输入框）。
    const str_off = (std.mem.indexOf(u8, text, "\"上限\"") orelse return error.TestUnexpectedResult) + 1;
    try testing.expect((try srv.prepareRenameAt(text, str_off)) == null);
    const cmt_off = (std.mem.indexOf(u8, text, "// 上限") orelse return error.TestUnexpectedResult) + 3;
    try testing.expect((try srv.prepareRenameAt(text, cmt_off)) == null);
    try testing.expect((try srv.prepareRenameAt(text, ret_off)) == null);

    // A6 dispatch：打开文档后真应答；未打开文档 → null。
    try srv.upsertDoc(uri, text);
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"textDocument/prepareRename\",\"params\":{\"textDocument\":{\"uri\":\"file:///p.zz\"},\"position\":{\"line\":2,\"character\":7}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":13") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"placeholder\":\"上限\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"line\":2,\"character\":7") != null);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"textDocument/prepareRename\",\"params\":{\"textDocument\":{\"uri\":\"file:///none.zz\"},\"position\":{\"line\":0,\"character\":0}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
}

test "第 275 轮 workspace/symbol：多文档顶层声明聚合与 query 过滤／location 字段／关闭即出表" {
    const tg = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(tg);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    // 两份已打开文档；a.zz 内另含缩进声明与关键字引用，验顶层边界。
    try srv.upsertDoc("file:///b.zz", "常数 乙项 = 2;\n");
    try srv.upsertDoc("file:///a.zz", "常数 上限 = 1;\n" ++
        "函数 主函数() 空 {\n" ++
        "    常数 内层 = 3;\n" ++
        "    返回 上限;\n" ++
        "}\n");

    // A1 空 query：两份文档三枚顶层声明按 (uri, 声明位置) 稳定排序，location 带 name 范围。
    const all = try srv.collectWorkspaceSymbolsJson("");
    defer gpa.free(all);
    try testing.expectEqualStrings(
        "[{\"name\":\"上限\",\"kind\":14,\"location\":{\"uri\":\"file:///a.zz\",\"range\":{\"start\":{\"line\":0,\"character\":3},\"end\":{\"line\":0,\"character\":5}}}}," ++
            "{\"name\":\"主函数\",\"kind\":12,\"location\":{\"uri\":\"file:///a.zz\",\"range\":{\"start\":{\"line\":1,\"character\":3},\"end\":{\"line\":1,\"character\":6}}}}," ++
            "{\"name\":\"乙项\",\"kind\":14,\"location\":{\"uri\":\"file:///b.zz\",\"range\":{\"start\":{\"line\":0,\"character\":3},\"end\":{\"line\":0,\"character\":5}}}}]",
        all,
    );
    // A2 query 子串过滤：命中一枚；无匹配 → 空数组。
    const one = try srv.collectWorkspaceSymbolsJson("主");
    defer gpa.free(one);
    try testing.expectEqualStrings(
        "[{\"name\":\"主函数\",\"kind\":12,\"location\":{\"uri\":\"file:///a.zz\",\"range\":{\"start\":{\"line\":1,\"character\":3},\"end\":{\"line\":1,\"character\":6}}}}]",
        one,
    );
    const none = try srv.collectWorkspaceSymbolsJson("不存在");
    defer gpa.free(none);
    try testing.expectEqualStrings("[]", none);
    // A3 顶层边界：缩进声明与关键字引用都不入结果。
    const inner = try srv.collectWorkspaceSymbolsJson("内层");
    defer gpa.free(inner);
    try testing.expectEqualStrings("[]", inner);
    const kw = try srv.collectWorkspaceSymbolsJson("返回");
    defer gpa.free(kw);
    try testing.expectEqualStrings("[]", kw);

    // A4 dispatch：请求形真应答带 id；query 过滤后不混入另一文档的声明。
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"上\"}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":11") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"name\":\"上限\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "乙项") == null);
    freeOut(gpa, &out);
    // A5 关闭即出表：didClose 后同一 query 归空（只搜文档表，不做全盘扫描）。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zz\"}}}", &out);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"上\"}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":[]") != null);
}

test "第 276 轮 signatureHelp：调用括号定位/参数标签与活动参数／嵌套与字符串逗号不入／非调用处 null" {
    const tg = testing.allocator;
    // A1 模板 round-trip：signatures[].label/parameters[].label/活动参数以 k_* 回读。
    {
        const label_js = try jsonrpc.jsonString(tg, "函数 分类(值: 整数)");
        defer tg.free(label_js);
        const p_js = try jsonrpc.jsonString(tg, "值: 整数");
        defer tg.free(p_js);
        const one_param = try std.fmt.allocPrint(tg, f_signature_param, .{p_js});
        defer tg.free(one_param);
        const sig_item = try std.fmt.allocPrint(tg, f_signature_item, .{ label_js, one_param });
        defer tg.free(sig_item);
        const help = try std.fmt.allocPrint(tg, f_signature_help, .{ sig_item, @as(usize, 0) });
        defer tg.free(help);
        var p = try std.json.parseFromSlice(std.json.Value, tg, help, .{});
        defer p.deinit();
        const o = asObject(p.value).?;
        const sigs = switch (o.get(k_signatures).?) {
            .array => |a| a.items,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(@as(usize, 1), sigs.len);
        const s0 = asObject(sigs[0]).?;
        try testing.expectEqualStrings("函数 分类(值: 整数)", strField(s0, k_label).?);
        const ps = switch (s0.get(k_parameters).?) {
            .array => |a| a.items,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(@as(usize, 1), ps.len);
        try testing.expectEqualStrings("值: 整数", strField(asObject(ps[0]).?, k_label).?);
        try testing.expectEqual(@as(i64, 0), intField(o, k_activeParameter).?);
        try testing.expectEqual(@as(i64, 0), intField(o, k_activeSignature).?);
    }

    var arena = std.heap.ArenaAllocator.init(tg);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    // 行 0 是注释里的伪造声明（不得被当函数）；行 4 的「打印」只用于验成员调用不提示。
    const text =
        "// 函数 缺省(甲: 整数)\n" ++
        "函数 分类(值: 整数, 精度: 整数, 标记: 文本) 文本 {\n" ++
        "    返回 值;\n" ++
        "}\n" ++
        "函数 打印(值: 整数) 空 {\n" ++
        "}\n" ++
        "函数 主函数() 空 {\n" ++
        "    分类(1, 2);\n" ++
        "    分类(分类(1, 2), 3);\n" ++
        "    分类(1, \"甲,乙,丙\");\n" ++
        "    标准库.打印(1);\n" ++
        "}\n" ++
        "常数 上限 = 1;\n" ++
        "常数 调用 = 上限(1);\n" ++
        "常数 缺省 = 缺省(1);\n";
    const uri = "file:///s.zz";

    // A2 首个实参：签名标签从声明词起（略去公开等修饰词）、逐参标签去空白、活动参数 0。
    const first = (try srv.signatureHelpAt(text, std.mem.indexOf(u8, text, "分类(1, 2)").? + "分类(".len)) orelse return error.TestUnexpectedResult;
    defer gpa.free(first);
    try testing.expectEqualStrings(
        "{\"signatures\":[{\"label\":\"函数 分类(值: 整数, 精度: 整数, 标记: 文本)\",\"parameters\":[{\"label\":\"值: 整数\"},{\"label\":\"精度: 整数\"},{\"label\":\"标记: 文本\"}]}],\"activeSignature\":0,\"activeParameter\":0}",
        first,
    );
    // A3 第二个实参：活动参数随顶层逗号递增。
    const two_off = std.mem.indexOf(u8, text, "分类(1, 2)").? + "分类(1, ".len;
    const second = (try srv.signatureHelpAt(text, two_off)) orelse return error.TestUnexpectedResult;
    defer gpa.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "\"activeParameter\":1") != null);
    // A4 嵌套调用：光标在内层实参时仍取最内层未闭合括号（内层签名，活动参数 1）。
    const nested_off = std.mem.indexOf(u8, text, "分类(分类(1, 2), 3)").? + "分类(分类(1, 2), ".len;
    const nested = (try srv.signatureHelpAt(text, nested_off)) orelse return error.TestUnexpectedResult;
    defer gpa.free(nested);
    try testing.expect(std.mem.indexOf(u8, nested, "\"label\":\"函数 分类(值: 整数, 精度: 整数, 标记: 文本)\"") != null);
    try testing.expect(std.mem.indexOf(u8, nested, "\"activeParameter\":1") != null);
    // A5 字符串内逗号不切参数：`"甲,乙,丙"` 里两个逗号不算——光标在字符串之后
    //    仍是第二参数；若按字节数逗号（3 个）则得 2，在三参声明下不会被 clamp 掩盖。
    const str_end = std.mem.indexOf(u8, text, "\"甲,乙,丙\"").? + "\"甲,乙,丙\"".len;
    const in_str = (try srv.signatureHelpAt(text, str_end)) orelse return error.TestUnexpectedResult;
    defer gpa.free(in_str);
    try testing.expect(std.mem.indexOf(u8, in_str, "\"activeParameter\":1") != null);
    // A6 括号已闭合 / 成员调用（同名顶层函数仍不提示）/ 非函数声明被调 / 仅注释伪造 → null。
    try testing.expect((try srv.signatureHelpAt(text, std.mem.indexOf(u8, text, "分类(1, 2);").? + "分类(1, 2)".len + 1)) == null);
    try testing.expect((try srv.signatureHelpAt(text, std.mem.indexOf(u8, text, "标准库.打印(1)").? + "标准库.打印(".len)) == null);
    try testing.expect((try srv.signatureHelpAt(text, std.mem.indexOf(u8, text, "上限(1)").? + "上限(".len)) == null);
    try testing.expect((try srv.signatureHelpAt(text, std.mem.indexOf(u8, text, "缺省(1)").? + "缺省(".len)) == null);

    // A7 dispatch：打开文档后真应答带 id；未打开文档 → null。
    try srv.upsertDoc(uri, text);
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file:///s.zz\"},\"position\":{\"line\":7,\"character\":10}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":17") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"activeParameter\":1") != null);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file:///none.zz\"},\"position\":{\"line\":0,\"character\":0}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
}

test "第 277 轮 selectionRange：词元→整行→包围块→整文档链／多位置同序／非词与非法位置兜底／dispatch 真应答" {
    const tg = testing.allocator;
    // A1 模板 round-trip：叶节只携 range，node 节携 parent；按 k_range/k_parent 回读。
    {
        const r_in = try std.fmt.allocPrint(tg, f_range_json, .{ @as(usize, 2), @as(usize, 8), @as(usize, 2), @as(usize, 10) });
        defer tg.free(r_in);
        const r_line = try std.fmt.allocPrint(tg, f_range_json, .{ @as(usize, 2), @as(usize, 0), @as(usize, 2), @as(usize, 13) });
        defer tg.free(r_line);
        const leaf = try std.fmt.allocPrint(tg, f_selection_leaf, .{r_in});
        defer tg.free(leaf);
        var lp = try std.json.parseFromSlice(std.json.Value, tg, leaf, .{});
        defer lp.deinit();
        const lo = asObject(lp.value).?;
        try testing.expect(objIn(lo.get(k_range)) != null);
        try testing.expect(lo.get(k_parent) == null); // 叶节不携 parent（链尾）
        const node = try std.fmt.allocPrint(tg, f_selection_node, .{ r_line, leaf });
        defer tg.free(node);
        var p = try std.json.parseFromSlice(std.json.Value, tg, node, .{});
        defer p.deinit();
        const o = asObject(p.value).?;
        const rr = objIn(o.get(k_range)) orelse return error.TestUnexpectedResult;
        const rs = objIn(rr.get(k_start)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 2), intField(rs, k_line).?);
        try testing.expectEqual(@as(i64, 0), intField(rs, k_character).?);
        const par = objIn(o.get(k_parent)) orelse return error.TestUnexpectedResult;
        const pr = objIn(par.get(k_range)) orelse return error.TestUnexpectedResult;
        const ps = objIn(pr.get(k_start)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 8), intField(ps, k_character).?);
    }

    var arena = std.heap.ArenaAllocator.init(tg);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    // 行 2 的实参落在两层花括号里：链应为 词元→行→内块→外块→整文档。
    const text =
        "函数 外层() 空 {\n" ++
        "    如果 (真) {\n" ++
        "        返回 1;\n" ++
        "    }\n" ++
        "}\n" ++
        "常数 甲 = 1;\n";
    // A2 词内位置：完整链逐字节对拍（parent 嵌套由内到外）。
    const off = std.mem.indexOf(u8, text, "返回 1;").? + 1;
    const chain = try srv.selectionChainJson(text, off);
    defer gpa.free(chain);
    try testing.expectEqualStrings(
        "{\"range\":{\"start\":{\"line\":2,\"character\":8},\"end\":{\"line\":2,\"character\":10}}," ++
            "\"parent\":{\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":13}}," ++
            "\"parent\":{\"range\":{\"start\":{\"line\":1,\"character\":11},\"end\":{\"line\":3,\"character\":5}}," ++
            "\"parent\":{\"range\":{\"start\":{\"line\":0,\"character\":10},\"end\":{\"line\":4,\"character\":1}}," ++
            "\"parent\":{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":6,\"character\":0}}}}}}}",
        chain,
    );
    // A3 非词位置（行首缩进）：无词元节，链从整行开始；字符串/注释不入块配对。
    const indent_off = std.mem.indexOf(u8, text, "        返回").?;
    const from_line = try srv.selectionChainJson(text, indent_off);
    defer gpa.free(from_line);
    try testing.expectEqualStrings(
        "{\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":13}}," ++
            "\"parent\":{\"range\":{\"start\":{\"line\":1,\"character\":11},\"end\":{\"line\":3,\"character\":5}}," ++
            "\"parent\":{\"range\":{\"start\":{\"line\":0,\"character\":10},\"end\":{\"line\":4,\"character\":1}}," ++
            "\"parent\":{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":6,\"character\":0}}}}}}",
        from_line,
    );
    // A4 位置非法（off=null）：只回整文档一节，保证每个 position 必有一条结果。
    const doc_only = try srv.selectionChainJson(text, null);
    defer gpa.free(doc_only);
    try testing.expectEqualStrings("{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":6,\"character\":0}}}", doc_only);

    // A5 dispatch：多位置同序（首个带 3 层 parent，越界位置落整文档）；空数组/缺键/未打开文档分道。
    const uri = "file:///sel.zz";
    try srv.upsertDoc(uri, text);
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"textDocument/selectionRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///sel.zz\"},\"positions\":[{\"line\":2,\"character\":9},{\"line\":99,\"character\":0}]}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":21") != null);
    var parents: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, out.items[0], at, ek_parent)) |hit| : (at = hit + ek_parent.len) parents += 1;
    try testing.expectEqual(@as(usize, 4), parents); // 词元→行→内块→外块→整文档 = 5 节 4 层 parent
    try testing.expect(std.mem.indexOf(u8, out.items[0], ",{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":6,\"character\":0}}}]}") != null); // 第二个位置越界 → 只回整文档
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"textDocument/selectionRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///sel.zz\"},\"positions\":[]}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":[]") != null);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"textDocument/selectionRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///sel.zz\"}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"textDocument/selectionRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///none.zz\"},\"positions\":[{\"line\":0,\"character\":0}]}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"result\":null") != null);
}

// 假语义供给器（第 166 轮单测）：char_len=0 与 severity 越界归一化臂验证。
var fake_sem_boundary_marker: u8 = 0;
var fake_sem_boundary_items = [_]SemanticItem{
    .{ .line = 2, .character = 5, .char_len = 0, .severity = 99, .message = "boundary-zero-len" },
    .{ .line = 0, .character = 1, .char_len = 3, .severity = 0, .message = "boundary-sev-zero" },
};
fn fakeBoundarySemanticProvider(ctx: *anyopaque, uri: []const u8, text: []const u8) []SemanticItem {
    _ = ctx;
    _ = uri;
    _ = text;
    return &fake_sem_boundary_items;
}

// 假语义供给器（第 159 轮单测）：返回一个静态借用项，验核内合并与保存门控。
var fake_sem_marker: u8 = 0;
var fake_sem_items = [_]SemanticItem{
    .{ .line = 0, .character = 3, .char_len = 4, .severity = sv_error, .message = "错误: 假语义诊断XYZ" },
};
fn fakeSemanticProvider(ctx: *anyopaque, uri: []const u8, text: []const u8) []SemanticItem {
    _ = ctx;
    _ = uri;
    _ = text;
    return &fake_sem_items;
}

test "lsp.server：didSave 合并语义项、didOpen 不含语义（保存门控）（第 159 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();
    srv.semantic = .{ .ctx = @ptrCast(&fake_sem_marker), .call = &fakeSemanticProvider };

    var out: OutList = .empty;
    defer freeOut(gpa, &out);

    // didOpen 一个词法干净的文档：快路发布零诊断，且绝不含假语义串（语义仅在 didSave 触发）。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///s159.zz\",\"text\":\"常数 a = 1;\\n\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "假语义诊断XYZ") == null); // didOpen 不出语义
    freeOut(gpa, &out);

    // didSave：发布合并数组，含假语义项（severity/coords/source=zzc）。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file:///s159.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "假语义诊断XYZ") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], ek_severity ++ ":1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], ek_character ++ ":3") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], ek_source ++ ":" ++ eq_prog_name) != null); // 210：source 标注程序名同源（221：改引 hub ek_/eq_ 去手抄）
    freeOut(gpa, &out);

    // 未 open 的 uri：didSave 无文本可算，静默不发布。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file:///never.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "lsp.server：semanticTokens/full 基本映射 + delta 编码（第 161 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    // 常数(→const 关键字、type0) 甲(未入 keywords、不发) = (punct、不发) 1(数字、type6) // 注(注释、type5)
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///sem.zz\",\"text\":\"常数 甲 = 1 // 注\"}}}", &out);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file:///sem.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
    defer parsed.deinit();
    const root = asObject(parsed.value).?;
    try testing.expectEqual(@as(i64, 5), intField(root, k_id).?);
    const result = objIn(root.get(k_result)).?;
    const data = switch (result.get("data").?) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    // 3 个可发 token × 5 元组 = 15（甲/= 被跳过、故仅 3）
    try testing.expectEqual(@as(usize, 15), data.len);
    // token1 常数：[0,0,2,0,0]
    try testing.expectEqual(@as(i64, 0), data[0].integer);
    try testing.expectEqual(@as(i64, 0), data[1].integer);
    try testing.expectEqual(@as(i64, 2), data[2].integer); // length：两个 BMP  码元
    try testing.expectEqual(@as(i64, ty_keyword), data[3].integer); // type=keyword
    // token2 数字 1：同行、delta_start=7（常(0)数(1)空(2)甲(3)空(4)=(5)空(6)1(7)）、type=number(6)
    try testing.expectEqual(@as(i64, 0), data[5].integer); // delta_line
    try testing.expectEqual(@as(i64, 7), data[6].integer); // delta_start
    try testing.expectEqual(@as(i64, 1), data[7].integer); // length
    try testing.expectEqual(@as(i64, ty_number), data[8].integer); // type=number
    // token3 注释 // 注：同行、delta_start=2（自 1 后）、length=4、type=comment(5)
    try testing.expectEqual(@as(i64, 2), data[11].integer); // delta_start
    try testing.expectEqual(@as(i64, 4), data[12].integer); // length
    try testing.expectEqual(@as(i64, ty_comment), data[13].integer); // type=comment
}

test "lsp.server：semanticTokens 跳过未知母语词、空文档→空流（第 161 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    // 纯母语标识符（均未入 keywords）+ 空文档 → 无可发 token
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///id.zz\",\"text\":\"甲乙 丙\"}}}", &out);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file:///id.zz\"}}}", &out);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"data\":[]") != null);
    freeOut(gpa, &out);

    // 未 open 的 uri → 空流（不报错）
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file:///absent.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"data\":[]") != null);
}

// ---------------------------------------------------------------------------
// 第 165 轮：纯函数核直接边界护栏（此前九测全经 handle() 间接触达、下列面零直钉）
// ---------------------------------------------------------------------------

// T1：cpWidth/seqLen 的 UTF-16 码宽与退化边界。既有语义 token/坐标测全用 BMP，
// astral（≥ 0x10000 占 2 码元）与截断/非法字节退化面此前零覆盖。
test "lsp.server：cpWidth/seqLen UTF-16 码宽边界（astral/截断/非法）（第 165 轮）" {
    // seqLen：首字节声明的序列字节长；截断（i+l>len）/非法前导/坏续字节一律退化 1。
    try testing.expectEqual(@as(usize, 1), seqLen("a", 0)); // ASCII
    try testing.expectEqual(@as(usize, 2), seqLen("\u{00E9}", 0)); // é 二字节 C3 A9
    try testing.expectEqual(@as(usize, 3), seqLen("\u{5E38}", 0)); // 常 三字节
    try testing.expectEqual(@as(usize, 4), seqLen("\u{1F600}", 0)); // 😀 四字节 astral
    try testing.expectEqual(@as(usize, 4), seqLen("\u{10000}", 0)); // 四字节、恰等 0x10000 下界
    const t4 = "\u{10000}";
    try testing.expectEqual(@as(usize, 1), seqLen(t4[0..2], 0)); // 四字节序列仅喂前两字节 → 截断退化 1
    try testing.expectEqual(@as(usize, 1), seqLen("\xFF", 0)); // 非法前导字节
    try testing.expectEqual(@as(usize, 1), seqLen("\xF0x", 0)); // F0 声明四字节但长度不足
    // cpWidth：码点 ≥ 0x10000 占 2 UTF-16 码元、BMP/坏字节占 1。
    try testing.expectEqual(@as(usize, 1), cpWidth("a", 0));
    try testing.expectEqual(@as(usize, 1), cpWidth("\u{5E38}", 0)); // CJK 一码元
    try testing.expectEqual(@as(usize, 2), cpWidth("\u{10000}", 0)); // 恰等阈值 >= 0x10000 → 2（承 >=）
    try testing.expectEqual(@as(usize, 2), cpWidth("\u{1F600}", 0)); // astral → 2
    try testing.expectEqual(@as(usize, 1), cpWidth(t4[0..2], 0)); // 截断退化 1
    try testing.expectEqual(@as(usize, 1), cpWidth("\xFF", 0)); // 坏字节退化 1
}

// T2：positionOfOffset/byteOfPosition 往返不变量与行越界/行尾/astral 代理三 null 支。
// 文件头 L17「两处单测直钉」此前实为仅经诊断坐标测 (0,8) 间接碰 BMP 形，本轮坐实直钉。
test "lsp.server：positionOfOffset/byteOfPosition 往返与行越界/行尾/null 支（第 165 轮）" {
    // doc = 「常😀b\n」：常(3B,1元)😀(4B,2元)b(1B,1元)\n(1B)。字节 0..2 常、3..6 😀、7 b、8 \n、len=9。
    const doc = "\u{5E38}\u{1F600}b\n";
    // positionOfOffset：CJK 计 1 码元、astral 计 2、'\n' 后行+1 列复位、off>len 钳到 len。
    try testing.expectEqual(@as(usize, 0), positionOfOffset(doc, 0).line);
    try testing.expectEqual(@as(usize, 0), positionOfOffset(doc, 0).character);
    try testing.expectEqual(@as(usize, 1), positionOfOffset(doc, 3).character); // 常 之后 = 列1（😀 起点）
    try testing.expectEqual(@as(usize, 3), positionOfOffset(doc, 7).character); // 😀(2元) 之后 b 在列3
    try testing.expectEqual(@as(usize, 4), positionOfOffset(doc, 8).character); // b 之后 = 列4（行尾）
    try testing.expectEqual(@as(usize, 1), positionOfOffset(doc, 9).line); // \n 后行1
    try testing.expectEqual(@as(usize, 0), positionOfOffset(doc, 9).character);
    try testing.expectEqual(@as(usize, 1), positionOfOffset(doc, 9999).line); // off>len 钳到 len
    try testing.expectEqual(@as(usize, 0), positionOfOffset(doc, 9999).character);
    // byteOfPosition 命中 + astral 中段查询前向钳到下一码元起点。
    try testing.expectEqual(@as(usize, 0), byteOfPosition(doc, 0, 0).?);
    try testing.expectEqual(@as(usize, 3), byteOfPosition(doc, 0, 1).?); // 列1 = 😀 起点
    try testing.expectEqual(@as(usize, 7), byteOfPosition(doc, 0, 2).?); // 列2 落 😀 低代理 → 前向钳到 b(字节7)
    try testing.expectEqual(@as(usize, 7), byteOfPosition(doc, 0, 3).?); // 列3 = b
    // 列恰等行尾 / 列越行尾 → 均钳到 '\n' 偏移 8（尾支 chars<=character → i、非 null）。
    try testing.expectEqual(@as(usize, 8), byteOfPosition(doc, 0, 4).?);
    try testing.expectEqual(@as(usize, 8), byteOfPosition(doc, 0, 99).?);
    // 行越界（超出 '\n' 数）→ null（nl orelse return null 真支）。
    try testing.expectEqual(@as(?usize, null), byteOfPosition(doc, 5, 0));
    // 单 astral 独占行、查低代理 → 尾 else null 真支（doc2 = 「😀\n」）。
    const doc2 = "\u{1F600}\n";
    try testing.expectEqual(@as(?usize, null), byteOfPosition(doc2, 0, 1));
    try testing.expectEqual(@as(usize, 0), byteOfPosition(doc2, 0, 0).?);
    try testing.expectEqual(@as(usize, 4), byteOfPosition(doc2, 0, 2).?); // 列2 = astral 之后 = EOL('\n' 偏移4)
    // 往返不变量：对每个码点边界偏移 o，byteOfPosition(o 的 position) 精确回得 o。
    for ([_]usize{ 0, 3, 7, 8 }) |ob| {
        const p = positionOfOffset(doc, ob);
        try testing.expectEqual(ob, byteOfPosition(doc, p.line, p.character).?);
    }
}

// T3：点链段助手空段/首点/尾点/isChainWordByte 边界。既有链测仅「标准库.调试.打印」
// 单点干净链，相邻点空段、buffer 首点、尾点越界三边界此前零直测。
test "lsp.server：点链段助手空段/首点/尾点/isChainWordByte 边界（第 165 轮）" {
    // stepLeftChainSegment(text, dot_idx)：从 '.' 向左吃一个词段返段起点、空段/越界 null。
    try testing.expectEqual(@as(?usize, 0), stepLeftChainSegment("a..b", 1)); // 常规左段：首 '.'(idx1) 左吃 'a' → 起点0
    try testing.expectEqual(@as(?usize, null), stepLeftChainSegment(".foo", 0)); // 首点：dot_idx==0 → null
    try testing.expectEqual(@as(?usize, null), stepLeftChainSegment("a .c", 2)); // 点前非词字节（空格）→ 空段 null
    try testing.expectEqual(@as(?usize, 0), stepLeftChainSegment("\u{7532}.\u{4E59}", 3)); // CJK 词段整体左吃（甲占 0..2）
    // stepRightChainSegment(text, from)：从段起点向右吃一个词段返开区间尾、空段/越界 null。
    try testing.expectEqual(@as(?usize, null), stepRightChainSegment("a..b", 2)); // 相邻点：from 指向另一 '.' → null
    try testing.expectEqual(@as(?usize, null), stepRightChainSegment("foo.", 4)); // 尾点越界：from>=text.len → null
    try testing.expectEqual(@as(?usize, 3), stepRightChainSegment("a.b", 2)); // 常规右段：from2='b' → 开区间尾3
    // isChainWordByte：≥0x80（非 ASCII）、字母数字、下划线为词字节；空格/点非。
    try testing.expect(isChainWordByte(0x80));
    try testing.expect(isChainWordByte('_'));
    try testing.expect(isChainWordByte('a'));
    try testing.expect(isChainWordByte('9'));
    try testing.expect(!isChainWordByte(' '));
    try testing.expect(!isChainWordByte('.'));
}

// T4：classToTokenType 图例索引全分支钉。承第 162 轮「客户端↔服务端图例同序、错序即静默
// 错色」共享真相源的服务端一侧——既有语义 token 测仅触发 keyword(0)/comment(5)/number(6)，
// type(1)/function(2)/variable(3) 三索引此前全库零防线。
test "lsp.server：classToTokenType 图例索引全分支钉（承 162 共享真相源·第 165 轮·第 219 轮 D87 标签改引 hub 真值）" {
    try testing.expectEqual(@as(u8, 0), classToTokenType(snippets.g_keyword)); // 关键字 → keyword
    try testing.expectEqual(@as(u8, 0), classToTokenType(snippets.g_constant)); // 字面常量 → keyword
    try testing.expectEqual(@as(u8, 1), classToTokenType(snippets.g_type)); // 类型 → type
    try testing.expectEqual(@as(u8, 2), classToTokenType(snippets.g_builtin)); // 内建函数 → function
    try testing.expectEqual(@as(u8, 3), classToTokenType(snippets.g_dialect)); // 方言词 → variable
    try testing.expectEqual(@as(u8, 3), classToTokenType("未知标签")); // 兜底 → variable
}

// D56 真数据路由钉（第 169 轮）：中文包 真/假/空值/未定义 映射 true/false/null/undefined——
// D56 前 classify 先判 isPrimitive 把四值遮蔽成「类型」→classToTokenType→1（类型色，且字面常量支为死）；
// 修后 classify 先判 isLanguageConstant→「字面常量」→classToTokenType→0（keyword）。坐实设计意图支由死变活。
test "lsp.server：classify→classToTokenType 字面量四值经图例归 keyword(0)（承 162/165 共享真相源·第 169 轮 D56）" {
    var asserts: usize = 0;
    for (lang_id.language_constants) |v| {
        try testing.expectEqualStrings(snippets.g_constant, snippets.classify(v));
        asserts += 1;
        try testing.expectEqual(@as(u8, 0), classToTokenType(snippets.classify(v))); // 字面常量 → keyword
        asserts += 1;
    }
    // 对照：真类型名仍走 isPrimitive→「类型」→token 1（坐实判序调整未过度捕获）。
    try testing.expectEqualStrings(snippets.g_type, snippets.classify("bool"));
    asserts += 1;
    try testing.expectEqual(@as(u8, 1), classToTokenType(snippets.classify("bool")));
    asserts += 1;
    std.debug.print("D56 route asserts={d}\n", .{asserts});
}

// T5：semanticTokensData 跨行 delta（delta_line>0 时 delta_start 取本行绝对列而非 prev_char 差）。
// 第 161 轮语义 token 测全单行、delta_line 恒 0、跨行 else 支此前零 fired。
test "lsp.server：semanticTokensData 跨行 delta_line/delta_start 复位（第 165 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();
    // 两行：line0「 常数」(keyword、列1、2 码元) + line1「 5」(number、列1)。空格/换行不发 token。
    const txt = " \u{5E38}\u{6570}\n 5";
    const out = try srv.semanticTokensData(txt);
    defer gpa.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const root = asObject(parsed.value).?;
    const data = switch (root.get("data").?) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 10), data.len); // 2 token × 5 元组
    // token1 常数：[0,1,2,0,0]（首 token、同行、delta_start=1-0）
    try testing.expectEqual(@as(i64, 0), data[0].integer); // delta_line
    try testing.expectEqual(@as(i64, 1), data[1].integer); // delta_start
    try testing.expectEqual(@as(i64, 2), data[2].integer); // length（两个 BMP  码元）
    try testing.expectEqual(@as(i64, ty_keyword), data[3].integer); // type=keyword
    // token2 数字 5（第二行）：[1,1,1,6,0]——delta_line=1、delta_start 取本行绝对列 1
    // （非「1 - prev_char(1) = 0」；若跨行漏复位即坠 0、本断言精确抓红）
    try testing.expectEqual(@as(i64, 1), data[5].integer); // delta_line=1（跨行）
    try testing.expectEqual(@as(i64, 1), data[6].integer); // delta_start=本行绝对列
    try testing.expectEqual(@as(i64, 1), data[7].integer); // length
    try testing.expectEqual(@as(i64, ty_number), data[8].integer); // type=number
}

test "lsp.server：semItem char_len/severity 归一化臂（第 166 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();
    srv.semantic = .{ .ctx = @ptrCast(&fake_sem_boundary_marker), .call = &fakeBoundarySemanticProvider };

    var out: OutList = .empty;
    defer freeOut(gpa, &out);

    // didOpen 干净文档（无快路诊断）
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///b166.zz\",\"text\":\"常数 a = 1;\\n\"}}}", &out);
    freeOut(gpa, &out);

    // didSave 触发 publishSave + 假供给器
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file:///b166.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // 反解 publishDiagnostics
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
    defer parsed.deinit();
    const root = asObject(parsed.value).?;
    const prm = objIn(root.get(k_params)).?;
    const diags = switch (prm.get(k_diagnostics).?) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), diags.len);

    // item 0: char_len=0 → w=1, severity=99 → clamp 1
    const d0 = asObject(diags[0]).?;
    const r0 = asObject(d0.get(k_range).?).?;
    const s0 = asObject(r0.get(k_start).?).?;
    const e0 = asObject(r0.get(k_end).?).?;
    try testing.expectEqual(@as(i64, 2), intField(s0, k_line).?);
    try testing.expectEqual(@as(i64, 5), intField(s0, k_character).?);
    try testing.expectEqual(@as(i64, 1), intField(e0, k_character).? - intField(s0, k_character).?); // w=1
    try testing.expectEqual(@as(i64, sv_error), intField(d0, k_severity).?); // 99→sv_error 兜底

    // item 1: char_len=3, severity=0 → clamp 1
    const d1 = asObject(diags[1]).?;
    const r1 = asObject(d1.get(k_range).?).?;
    const s1 = asObject(r1.get(k_start).?).?;
    const e1 = asObject(r1.get(k_end).?).?;
    try testing.expectEqual(@as(i64, 3), intField(e1, k_character).? - intField(s1, k_character).?); // w=3
    try testing.expectEqual(@as(i64, sv_error), intField(d1, k_severity).?); // 0→sv_error 兜底

    // 断言数： 10
}

test "lsp.server：handle 未 open 退/空数组退/重复 open 覆盖（第 166 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);

    // A: didChange 对未 open URI → 静默不发布
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///no.zz\"},\"contentChanges\":[{\"text\":\"a\"}]}}", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // B: didChange contentChanges=[] → 静默不发布
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///e166.zz\",\"text\":\"OK\"}}}", &out);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///e166.zz\"},\"contentChanges\":[]}}", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // C: 同 URI 二次 didOpen 不同文本（第一次含全角违例、第二次干净）
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///dup.zz\",\"text\":\"常数 a = 1，\\n\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"diagnostics\":[]") == null); // 有违例
    freeOut(gpa, &out);

    // 第二次 open 同 URI、干净文本：覆盖后诊断空
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///dup.zz\",\"text\":\"常数 a = 1;\\n\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"diagnostics\":[]") != null); // 已覆盖无违例

    // 断言数： 5
}

test "lsp.server：idJson 对字符串 id 特殊字符做 JSON 转义（第 166 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);

    // 字符串 id 含嵌入引号： JSON 原文 "id":"a\"b" → 解析后 .string 值为 a"b
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"initialize\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // 应答必须是合法 JSON（若转义缺失则 id 含裸引号破坏结构）
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
    defer parsed.deinit();
    const root = asObject(parsed.value).?;
    const id_val = root.get(k_id).?;
    try testing.expectEqualStrings("a\"b", switch (id_val) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    });

    // 另加一例： id 含反斜杠
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":\"x\\\\y\",\"method\":\"initialize\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    var p2 = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
    defer p2.deinit();
    const r2 = asObject(p2.value).?;
    const id2 = r2.get("id").?;
    try testing.expectEqualStrings("x\\y", switch (id2) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    });

    // 断言数： 4
}

// 第 170 轮·JSON-RPC 报文骨架构建器零直调面增量审计（证伪撤号不占号）。
// 承 108-129/165/166 通读模块证伪方法论：下列五函数（rangeJson/strField/resultResponse/
// errorResponse/itemsJoinAndFree）156/159/166 仅经 handle 端到端间接触达、全仓零直调。
// 逐函数推演 + 两处调用点 errdefer 对账坐实皆 stated-behavior 无在线缺陷（itemsJoinAndFree
// 错误路径下 items 原样留、由调用方 publishSave/diagnosticsJson 的 errdefer free 元素、无泄）
// →不占 D 号，落直钉测补零防线。load-bearing 亮点：errorResponse 对**客户端可控**的 method
// 串（L314 经 strField 取入）走 jsonrpc.jsonString 转义——缺之则 method 含引号即破帧结构（承 166
// idJson 同面·156 jsonString 自测钉的是转义器本体、钉不到 errorResponse 是否接线用它）。

// T1：strField 三分支（命中字符串/命中非字符串/缺键） + resultResponse 骨架 verbatim 嵌套 +
// errorResponse 客户端可控 message 经 jsonString 转义不破 JSON 结构（reparse 不变量）。
test "lsp.server：strField 三分支 + result/errorResponse 骨架与 message 转义（承 166 idJson 同面·第 170 轮）" {
    var asserts: usize = 0;
    const gpa = testing.allocator;

    // strField：命中 .string 取值、命中非字符串（integer/bool）与缺键皆 null。
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"method\":\"foo\",\"id\":7,\"flag\":true}", .{});
    defer parsed.deinit();
    const obj = asObject(parsed.value).?;
    try testing.expectEqualStrings("foo", strField(obj, "method").?);
    asserts += 1;
    try testing.expect(strField(obj, "id") == null); // integer 非字符串
    asserts += 1;
    try testing.expect(strField(obj, "absent") == null); // 缺键
    asserts += 1;

    // resultResponse：id/result 原样（{s}）嵌入，帧恰形且可 reparse 出 result 对象。
    const rs = try resultResponse(gpa, "1", "{\"ok\":true}");
    defer gpa.free(rs);
    try testing.expectEqualStrings("{\"jsonrpc\":\"" ++ jsonrpc.version_value ++ "\",\"id\":1,\"result\":{\"ok\":true}}", rs);
    asserts += 1;
    var pr = try std.json.parseFromSlice(std.json.Value, gpa, rs, .{});
    defer pr.deinit();
    try testing.expect(asObject(pr.value).?.get(k_result) != null);
    asserts += 1;

    // errorResponse：message 含引号+反斜杠（模拟客户端 method 串）须被转义——缺转义则 parseFromSlice 即失败。
    const emsg = "不支持的方法：x\"y\\z";
    const er = try errorResponse(gpa, "2", ec_method_not_found, emsg);
    defer gpa.free(er);
    var pe = try std.json.parseFromSlice(std.json.Value, gpa, er, .{});
    defer pe.deinit();
    const eerr = asObject(asObject(pe.value).?.get(k_error).?).?;
    try testing.expectEqualStrings(emsg, strField(eerr, k_message).?);
    asserts += 1;
    try testing.expectEqual(@as(i64, ec_method_not_found), intField(eerr, k_code).?);
    asserts += 1;

    std.debug.print("T1 asserts={d}\n", .{asserts});
}

// 第 240 轮 T0：JSON-RPC 协议版本值单源派生——写侧 `ek_v20`、自测 `resultResponse` want、守卫
// `params_face` needle 三面皆由 `jsonrpc.version_value` 派生，服务端实际应答的版本形与钉给客户端的
// needle 版本片段经同一 hub 同源（t2 P3 主靶「协同漂令服务端↔客户端版本分道却 fresh 全绿」自此转锚）。
test "第 240 轮 T0 JSON-RPC 协议版本值单源与写侧-自测-守卫needle 三面同源 round-trip 锈" {
    const gpa = testing.allocator;

    // A1 值钉：hub 真值逐字节 = "2.0"（协议标准版本，漂即与所有合规客户端失联）。
    try testing.expectEqualStrings("2.0", jsonrpc.version_value);

    // A2 写侧 ek_v20 由 hub 拼接（带 JSON 引号的 `"2.0"`），非独立字面。
    try testing.expectEqualStrings("\"" ++ jsonrpc.version_value ++ "\"", ek_v20);

    // A3 跨面 round-trip：服务端 resultResponse 真产物以 hub 版本形起头，守卫 params_face[0]
    //    needle 钉给客户端的版本片段亦由同一 hub 派生——两端同源，写侧/自测/js 不可分道。
    const rs = try resultResponse(gpa, "1", "{}");
    defer gpa.free(rs);
    try testing.expect(std.mem.startsWith(u8, rs, "{\"jsonrpc\":\"" ++ jsonrpc.version_value ++ "\""));
    try testing.expect(std.mem.indexOf(u8, params_face[0].needle, ": '" ++ jsonrpc.version_value ++ "',") != null);

    // A4 反锚：漂版本伪造形（hub 值换号）不得与写侧 ek_v20 等价，杜绝同值旁路蒙混。
    try testing.expect(!std.mem.eql(u8, ek_v20, "\"" ++ "2.1" ++ "\""));
}

// T2：rangeJson 字节区间→Range（ASCII 跨行 + CJK 每 3 字节 BMP 汉字 = 1 UTF-16 码元列） +
// itemsJoinAndFree 空→[]/多元素逗号拼接不加引号（元素本已是 JSON 串）/成功后接管清空元素。
test "lsp.server：rangeJson 字节区间→Range 与 itemsJoinAndFree 拼数组+元素接管（第 170 轮）" {
    var asserts: usize = 0;
    const gpa = testing.allocator;

    // rangeJson：text "ab\ncd"、off 3→{line1,char0}、off 5→{line1,char2}（跨行、行内 ASCII）。
    const ascii = "ab\ncd";
    const r1 = try rangeJson(gpa, ascii, 3, 5);
    defer gpa.free(r1);
    try testing.expectEqualStrings("{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":2}}", r1);
    asserts += 1;

    // rangeJson：CJK "甲乙"、off 0→{0,0}、off 3→{0,1}——3 字节 BMP 汉字经 cpWidth 计 1 UTF-16 码元。
    const cjk = "甲乙";
    const r2 = try rangeJson(gpa, cjk, 0, 3);
    defer gpa.free(r2);
    try testing.expectEqualStrings("{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}", r2);
    asserts += 1;

    // itemsJoinAndFree 空清单→"[]"。
    var l0: std.ArrayList([]const u8) = .empty;
    const j0 = try itemsJoinAndFree(gpa, &l0);
    defer gpa.free(j0);
    try testing.expectEqualStrings("[]", j0);
    asserts += 1;

    // itemsJoinAndFree 两元素：仅逗号拼接、原样嵌入（不加引号）；成功后 clearAndFree 使 items 空（元素所有权已接管）。
    var l2: std.ArrayList([]const u8) = .empty;
    try l2.append(gpa, try gpa.dupe(u8, "{\"a\":1}"));
    try l2.append(gpa, try gpa.dupe(u8, "{\"b\":2}"));
    const j2 = try itemsJoinAndFree(gpa, &l2);
    defer gpa.free(j2);
    try testing.expectEqualStrings("[{\"a\":1},{\"b\":2}]", j2);
    asserts += 1;
    try testing.expectEqual(@as(usize, 0), l2.items.len);
    asserts += 1;

    std.debug.print("T2 asserts={d}\n", .{asserts});
}

// 第 171 轮·JSON-RPC id 回显构造器 idJson 零直调面增量审计（证伪撤号不占号）：idJson 此前仅经
// handle/respond 间接驱动（156 initialize id:7 走 .integer、166 T3 经 handle 钉 .string 转义）、全仓零直调。
// 逐分支探针实测真形：.integer→裸数字、.number_string（超 i64 大整数）→原样保文（不丢精度）、
// .string→jsonString 加引号转义、.bool→true/false、.null/缺失→null、.float/.object/.array→null（非合形防御兜底）。
// 全部产出均为合法 JSON 字面量、绝不破坏响应帧结构（承 166/170 同面）；非合规范 id 形（float/对象/数组）
// 防御性回落 null——真实 LSP 客户端 id 恒为整数或字符串、此路不可达 → 证伪不占号，仅补零直调护栏测。
test "lsp.server：idJson 六分支回显真形与非法 id 形防御回落（第 171 轮）" {
    var asserts: usize = 0;
    const gpa = testing.allocator;

    // .integer：裸数字原样回显
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"id\":7}", .{});
        defer p.deinit();
        const s = try idJson(gpa, asObject(p.value).?.get("id"));
        defer gpa.free(s);
        try testing.expectEqualStrings("7", s);
        asserts += 1;
    }
    // .number_string：超 i64 大整数原样保文（不丢精度、不改写为 null）
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"id\":99999999999999999999999}", .{});
        defer p.deinit();
        const s = try idJson(gpa, asObject(p.value).?.get("id"));
        defer gpa.free(s);
        try testing.expectEqualStrings("99999999999999999999999", s);
        asserts += 1;
    }
    // .string：jsonString 加引号并转义嵌入引号（缺此则裸引号破坏响应帧结构）
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"id\":\"a\\\"b\"}", .{});
        defer p.deinit();
        const s = try idJson(gpa, asObject(p.value).?.get("id"));
        defer gpa.free(s);
        try testing.expectEqualStrings("\"a\\\"b\"", s);
        asserts += 1;
    }
    // .bool：原样 true（合法 JSON 字面量、不破帧）
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"id\":true}", .{});
        defer p.deinit();
        const s = try idJson(gpa, asObject(p.value).?.get("id"));
        defer gpa.free(s);
        try testing.expectEqualStrings("true", s);
        asserts += 1;
    }
    // .float（非合规范 id 形）：防御回落 null（真实客户端不发浮点 id、此路不可达）
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"id\":7.5}", .{});
        defer p.deinit();
        const s = try idJson(gpa, asObject(p.value).?.get("id"));
        defer gpa.free(s);
        try testing.expectEqualStrings("null", s);
        asserts += 1;
    }
    // 缺失 id：null
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"method\":\"x\"}", .{});
        defer p.deinit();
        const s = try idJson(gpa, asObject(p.value).?.get("id"));
        defer gpa.free(s);
        try testing.expectEqualStrings("null", s);
        asserts += 1;
    }
    std.debug.print("T3 asserts={d}\n", .{asserts});
}

// 第 172 轮·JSON-RPC 入向取值器零直调面增量审计（证伪撤号不占号）：asObject/objIn/intField（L122-148）
// 此前仅被 handle 生产链消费（既有测皆以 asObject(...)? 当解包工具、非锁定其分支行为）；三处防御面端到端
// 从未 fired：①帧根非对象形→-32600 应答（156 仅测坏 JSON→-32700）；②hover position.line 非整数形；③params 非对象形。
// 探针实测真形：asObject/objIn 仅 .object 返回对象、余形（integer/number_string/float/string/bool/null/array）皆 null；
// intField 仅 .integer 取值、float/number_string（大整数不回落 int）/string/bool/null/缺键皆 null。
// 防御面产物：非法帧根→合法 -32600 帧（id 恒 null）、非法 position/params→result:null 不崩——皆不破坏帧结构
// → 证伪撤号不占 D 号（真实 LSP 客户端从不发非对象帧根/非整数 position，此路防御性可达但规范上不可达），仅补零直调护栏测。
test "lsp.server：asObject/objIn/intField 取值器分支真形与帧根非对象形 -32600 防御面（第 172 轮）" {
    var asserts: usize = 0;
    const gpa = testing.allocator;

    // asObject：恰 .object 放行，七非对象形皆 null（含 number_string 大整数与 float）
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"k\":1}", .{});
        defer p.deinit();
        try testing.expect(asObject(p.value) != null);
        asserts += 1;
    }
    const non_obj = [_][]const u8{ "7", "7.5", "\"s\"", "true", "null", "[1,2]", "99999999999999999999999" };
    for (non_obj) |body| {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer p.deinit();
        try testing.expect(asObject(p.value) == null);
        asserts += 1;
        try testing.expect(objIn(p.value) == null); // objIn 值在形同走 asObject
        asserts += 1;
    }
    // objIn：缺省 null 入参先于取值即 null（ornull 短路边与值形边分立）
    {
        try testing.expect(objIn(null) == null);
        asserts += 1;
    }
    // intField：恰 .integer 取值；float/大整数 number_string（不回落 int）/string/bool/null/缺键皆 null
    {
        var p = try std.json.parseFromSlice(std.json.Value, gpa, "{\"i\":7,\"f\":7.5,\"s\":\"x\",\"b\":true,\"n\":null,\"big\":99999999999999999999999}", .{});
        defer p.deinit();
        const obj = asObject(p.value).?;
        try testing.expectEqual(@as(?i64, 7), intField(obj, "i"));
        asserts += 1;
        try testing.expect(intField(obj, "f") == null);
        asserts += 1;
        try testing.expect(intField(obj, "big") == null); // 超 i64 不回落 number_string→int，拒而不猜
        asserts += 1;
        try testing.expect(intField(obj, "s") == null);
        asserts += 1;
        try testing.expect(intField(obj, "b") == null);
        asserts += 1;
        try testing.expect(intField(obj, "n") == null);
        asserts += 1;
        try testing.expect(intField(obj, "absent") == null);
        asserts += 1;
    }

    // 端到端防御面：逐非对象帧根形→合法 -32600 帧、id 回 null、可 reparse 不破帧
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const ag = arena.allocator();
        var lang = try Pack.parse(ag, @embedFile(paths.builtin_pack_embed_child));
        defer lang.deinit();

        for (non_obj) |body| {
            var srv = Server.init(ag, &lang);
            defer srv.deinit();
            var out: OutList = .empty;
            defer freeOut(ag, &out);

            try srv.handle(body, &out);
            try testing.expectEqual(@as(usize, 1), out.items.len);
            asserts += 1;
            try testing.expect(std.mem.indexOf(u8, out.items[0], ek_code ++ ":" ++ std.fmt.comptimePrint("{d}", .{ec_invalid_request})) != null);
            asserts += 1;
            try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":null") != null);
            asserts += 1;
            var pr = try std.json.parseFromSlice(std.json.Value, ag, out.items[0], .{});
            defer pr.deinit();
            try testing.expect(asObject(pr.value) != null); // 防御帧本身合法 JSON
            asserts += 1;
            freeOut(ag, &out);
        }

        // hover position.line 非整数形（字符串）→ result:null 不崩（intField 防御面经 handle 端到端坐实）
        var srv2 = Server.init(ag, &lang);
        defer srv2.deinit();
        var out2: OutList = .empty;
        defer freeOut(ag, &out2);
        try srv2.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///d172.zz\",\"text\":\"a\\n\"}}}", &out2);
        freeOut(ag, &out2);
        try srv2.handle("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///d172.zz\"},\"position\":{\"line\":\"0\",\"character\":0}}}", &out2);
        try testing.expectEqual(@as(usize, 1), out2.items.len);
        asserts += 1;
        try testing.expect(std.mem.indexOf(u8, out2.items[0], "\"result\":null") != null);
        asserts += 1;
    }

    std.debug.print("T4 asserts={d}\n", .{asserts});
}

// 第 195 轮审计注：`Server.upsertDoc`（L327·文档表写入壳）系全库零直调——唯 `handle` 的
// didOpen L263 / didChange L280 两生产直调，既有 156/159/165/172 轮测皆经 `handle` 端到端
// 间接触达，且本文件测帧 gpa 恒为 `ArenaAllocator.init(testing.allocator)`（14 处）——所有权
// 面在 arena 掩盖下结构性不可见（D37/D49/D51/D58/D59 同族破局靶心）。
// **疑似 D60**：`docs` 的键系 `gpa.dupe(u8, uri)` 自持堆串（L330），而三处回收点一律只 free
// 值、从不 free 键——upsertDoc 替换臂（L329 `fetchRemove` 取回 `old` 只 `free(old.value)`）、
// didClose（L288 同形）、`deinit`（L213 迭代只 free `e.value_ptr.*`）。LSP 服务器是**长驻进程**、
// textDocumentSync=1 全量同步下 didChange 随键击成交——每次替换泄一只旧 uri 键串（比 D58/D59
// 的 CLI 短进程面高频得多）；`deinit` 末了亦把全部在表键串带走。另 `put(try dupe(uri),
// try dupe(text))` 把两只 dupe 挤在同一表达式里：第二只失败即第一只无人回收（errdefer 面）。
// 本测以 `FailingAllocator`（不设失败靶·纯计数）套裸 `testing.allocator` 直调本壳：原码必
// `deallocations < allocations`（差在键串数），补 free 后齐平——194 轮 A6「不借容量策略、
// 每轮必现的计数钉」形制直用；runner 的 leaked 报告为第二重保险。

test "第 195 轮 T1 upsertDoc 文档表所有权：首插/替换/双 uri/入参借用独立/didClose 端到端 + D60 键串计数钉" {
    // lang 走独立 arena（不入被计数的 fa）：本测计数面只管 Server 的分配成交。
    var lang_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer lang_arena.deinit();
    var lang = try Pack.parse(lang_arena.allocator(), @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();

    // A1..A5 直调形：首插读回 / 同 uri 替换（count 不增、文本换新）/ 双 uri 互不串 /
    // 入参借用独立性（dupe 契约·改写源缓冲表内不变）/ 未知 uri null。
    {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var srv = Server.init(fa.allocator(), &lang);
        try srv.upsertDoc("file:///a.zz", "常数 a = 1;\n");
        try testing.expectEqual(@as(usize, 1), srv.docs.count());
        try testing.expectEqualStrings("常数 a = 1;\n", srv.docs.get("file:///a.zz").?);
        try srv.upsertDoc("file:///a.zz", "常数 b = 2;\n"); // 替换臂：旧键串须在此回收
        try testing.expectEqual(@as(usize, 1), srv.docs.count());
        try testing.expectEqualStrings("常数 b = 2;\n", srv.docs.get("file:///a.zz").?);
        try srv.upsertDoc("file:///b.zz", "常数 c = 3;\n");
        try testing.expectEqual(@as(usize, 2), srv.docs.count());
        try testing.expectEqualStrings("常数 b = 2;\n", srv.docs.get("file:///a.zz").?);
        try testing.expectEqualStrings("常数 c = 3;\n", srv.docs.get("file:///b.zz").?);
        try testing.expect(srv.docs.get("file:///nope.zz") == null);
        // 入参借用独立性：喂可变缓冲，写入后改写源缓冲，表内字节须纹丝不动。
        var mut: [8]u8 = undefined;
        @memcpy(mut[0..7], "XYZ 06\n");
        mut[7] = '!';
        try srv.upsertDoc("file:///mut.zz", mut[0..7]);
        mut[0] = 'Q';
        mut[4] = 'Z';
        try testing.expectEqualStrings("XYZ 06\n", srv.docs.get("file:///mut.zz").?);
        srv.deinit(); // 在表键串+值须全收
        // D60 计数钉：原码从不 free 键串（三处回收点皆只 free 值）→ 此处必差 n 只。
        try testing.expectEqual(fa.deallocations, fa.allocations);
    }

    // A6 didOpen→didClose 端到端计数钉（覆盖 handle 的 didClose L288 回收臂与 upsertDoc
    //   首插臂的真实报文路径）：全报文字节经 fa 分配、逐段回收，末了表空——原码差一只
    //   didClose 未 free 的 uri 键串。
    {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var srv = Server.init(fa.allocator(), &lang);
        var out: OutList = .empty;
        try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///e1.zz\",\"text\":\"常数 a = 1;\\n\"}}}", &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///e1.zz\"}}}", &out);
        try testing.expectEqual(@as(usize, 2), out.items.len);
        try testing.expect(std.mem.indexOf(u8, out.items[1], "\"diagnostics\":[]") != null); // 关闭清波浪线
        try testing.expectEqual(@as(usize, 0), srv.docs.count());
        freeOut(srv.gpa, &out);
        srv.deinit();
        try testing.expectEqual(fa.deallocations, fa.allocations);
    }

    // A7 didOpen→didChange（同 uri 全文替换）→didChange→deinit 端到端计数钉：长驻会话里
    //   随键击成交的高频路径——原码每换一次文本泄一只旧键串（本轮三枚键串计数钉之二）。
    {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var srv = Server.init(fa.allocator(), &lang);
        var out: OutList = .empty;
        try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///e2.zz\",\"text\":\"常数 a = 1;\\n\"}}}", &out);
        try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///e2.zz\"},\"contentChanges\":[{\"text\":\"常数 b = 2;\\n\"}]}}", &out);
        try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///e2.zz\"},\"contentChanges\":[{\"text\":\"常数 c = 3;\\n\"}]}}", &out);
        try testing.expectEqual(@as(usize, 3), out.items.len);
        try testing.expectEqualStrings("常数 c = 3;\n", srv.docs.get("file:///e2.zz").?);
        freeOut(srv.gpa, &out);
        srv.deinit();
        try testing.expectEqual(fa.deallocations, fa.allocations);
    }

    // A8 三道分配失败臂逐点钉（探针实定落点：fail_index 0=dupe(uri)、1=dupe(text)、
    //   2=docs.put 首块表内存；≥3 恒成——本壳分配序固定故可逐臂钉）：任臂失败皆须
    //   ①向上传播 error.OutOfMemory（不静默）②表不留半个映射③已 dupe 的串全数回收。
    //   落点另以 `allocations == arm` 钉住（防“失败未落在所拟那一步”的伪钉）。
    //   原码两只 dupe 挤同一表达式且无 errdefer：fail_index=1 泄键、=2 泄键+值——本钉必红。
    {
        var arm: usize = 0;
        while (arm <= 2) : (arm += 1) {
            var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = arm });
            var srv = Server.init(fa.allocator(), &lang);
            try testing.expectError(error.OutOfMemory, srv.upsertDoc("file:///f.zz", "常数 a = 1;\n"));
            try testing.expectEqual(@as(usize, 0), srv.docs.count());
            try testing.expectEqual(arm, fa.allocations);
            try testing.expectEqual(fa.deallocations, fa.allocations);
            srv.deinit();
        }
    }

    // A9 成功臂分配套钉：首次插入恰三块（键串/值串/表首块）——防“只修不还形状”的
    //   过度修（比如把 dupe 改成存入借用则次数与独立性同变），与 A4 入参独立性互为经标。
    {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var srv = Server.init(fa.allocator(), &lang);
        try srv.upsertDoc("file:///g.zz", "常数 a = 1;\n");
        try testing.expectEqual(@as(usize, 3), fa.allocations);
        try testing.expectEqual(@as(usize, 0), fa.deallocations); // 在表期间一只都不该提前回
        srv.deinit();
        try testing.expectEqual(fa.deallocations, fa.allocations); // 含表首块在内全部齐平
    }
}

// ---------------------------------------------------------------------------
// 第 214 轮 D82：语义 token 图例单一真值钉
// ---------------------------------------------------------------------------

test "第 214 轮 T0 语义图例 round-trip：initialize 应答图例反查 tokenTypeOf/classToTokenType 索引（防写侧图例与索引族分道静默错色）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    // A1 initialize 应答的图例逐字节即 hub 派生形（应答写侧委派 legend_json 的出口钉）。
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], legend_json) != null);

    // A2 真数据 round-trip：同一应答解析出图例数组，发 token 的 type 索引反查图例须得承诺词元名。
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
    defer parsed.deinit();
    const init_result = objIn(asObject(parsed.value).?.get(k_result)).?;
    const caps = objIn(init_result.get("capabilities")).?; // 图例嵌在 capabilities 下（应答形实跑坐实）
    const legend = switch (objIn(objIn(caps.get("semanticTokensProvider")).?.get("legend")).?.get("tokenTypes").?) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(legend_types.len, legend.len);
    for (legend_types, 0..) |want, i| {
        try testing.expectEqualStrings(want, legend[i].string); // 应答图例逐员等于真值（改序即红）
    }

    freeOut(gpa, &out);
    // 「常数」→keyword、「整数」→type（M2 残口补腿：类索引漂移 round-trip 可抓）、「甲」未入 keywords 不发、
    // 1→number、// 注→comment；字符串与点链走既有跳过/映射支。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///rt214.zz\",\"text\":\"常数 整数 甲 = 1 // 注\"}}}", &out);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file:///rt214.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
    defer parsed2.deinit();
    const data = switch (objIn(asObject(parsed2.value).?.get(k_result)).?.get("data").?) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 20), data.len); // 4 token × 5 元组
    const expect_names = [_][]const u8{ "keyword", "type", "number", "comment" };
    for (expect_names, 0..) |name, k| {
        const idx: usize = @intCast(data[k * 5 + 3].integer);
        try testing.expect(idx < legend.len); // 索引越界即客户端静默错色的最劣形
        try testing.expectEqualStrings(name, legend[idx].string); // 由应答图例反查、非由我方常量反查
    }
}

test "第 214 轮 T1 图例派生面与客户端声明判据：needle/legend_json 形钉 + 抽取器正反小样 + extensionDeclaresLegend 小样（防守卫判据自身失真）" {
    // A1 客户端 needle 形钉：逐字节等于真值展开形（守卫 FAIL 消息与判据共此构造，改形即红）。
    try testing.expectEqualStrings(
        "const SEMANTIC_TOKEN_TYPES = ['keyword', 'type', 'function', 'variable', 'string', 'comment', 'number']",
        client_legend_needle,
    );
    // A2 应答图例段形钉：与 initialize 写侧拼接同一派生（拼形改样此处即红，免得守卫/断言两头猜）。
    try testing.expectEqualStrings(
        "\"tokenTypes\":[\"keyword\",\"type\",\"function\",\"variable\",\"string\",\"comment\",\"number\"]",
        legend_json,
    );
    // A3 extensionDeclaresLegend 正反小样：命中 needle 为真；错序/改名/空文本皆假（守卫据此判分道）。
    try testing.expect(extensionDeclaresLegend("const X = 1;\n" ++ client_legend_needle ++ "\nconst Y = 2;"));
    try testing.expect(!extensionDeclaresLegend("const SEMANTIC_TOKEN_TYPES = ['keyword', 'type', 'function', 'variable', 'string', 'number', 'comment']")); // P3 探针对序形
    try testing.expect(!extensionDeclaresLegend("const SEMANTIC_TOKEN_TYPES = ['kw', 'type', 'function', 'variable', 'string', 'comment', 'number']")); // P2 探针改名形
    try testing.expect(!extensionDeclaresLegend(""));
    // A4 抽取器正样：给定真值序的单引号词元串须逐员抽回。
    const got = parseClientLegendArray("'keyword', 'type', 'function', 'variable', 'string', 'comment', 'number'") orelse return error.TestUnexpectedResult;
    for (got, 0..) |t, i| try testing.expectEqualStrings(legend_types[i], t);
    // A5 抽取器反样：词元数不符 / 引号不闭合 皆 null。
    try testing.expect(parseClientLegendArray("'a', 'b'") == null);
    try testing.expect(parseClientLegendArray("'keyword', 'type', 'function', 'variable', 'string', 'comment', 'number', 'extra'") == null);
    try testing.expect(parseClientLegendArray("'unclosed, 'x'") == null);
}

// ---------------------------------------------------------------------------
// 第 218 轮 D86：LSP 方法名族单一真值钉
// ---------------------------------------------------------------------------

test "第 218 轮 T0 方法名族单源钉：二十二枚值钉 + needle 形钉 + 判据正反小样 + dispatch 同骨 round-trip + 覆盖钉（防 js 侧改名静默失联而构建链恒绿）" {
    // A1 值钉：二十二枚真值逐字节锚定 LSP 标准词形——改真值必先在此声明意图（t2 P5/P6 坐实
    // 旧形下 src 侧漂移仅同文件手抄 fixture 自照红，本钉把「改词」变成显式动作）。
    try testing.expectEqualStrings("initialize", m_initialize);
    try testing.expectEqualStrings("initialized", m_initialized);
    try testing.expectEqualStrings("shutdown", m_shutdown);
    try testing.expectEqualStrings("exit", m_exit);
    try testing.expectEqualStrings("textDocument/didOpen", m_didOpen);
    try testing.expectEqualStrings("textDocument/didChange", m_didChange);
    try testing.expectEqualStrings("textDocument/didClose", m_didClose);
    try testing.expectEqualStrings("textDocument/didSave", m_didSave);
    try testing.expectEqualStrings("textDocument/hover", m_hover);
    try testing.expectEqualStrings("textDocument/semanticTokens/full", m_semanticTokensFull);
    try testing.expectEqualStrings("textDocument/documentSymbol", m_documentSymbol);
    try testing.expectEqualStrings("textDocument/definition", m_definition);
    try testing.expectEqualStrings("textDocument/references", m_references);
    try testing.expectEqualStrings("textDocument/documentHighlight", m_documentHighlight);
    try testing.expectEqualStrings("textDocument/codeAction", m_codeAction);
    try testing.expectEqualStrings("textDocument/foldingRange", m_foldingRange);
    try testing.expectEqualStrings("textDocument/rename", m_rename);
    try testing.expectEqualStrings("textDocument/prepareRename", m_prepareRename);
    try testing.expectEqualStrings("workspace/symbol", m_workspaceSymbol);
    try testing.expectEqualStrings("textDocument/signatureHelp", m_signatureHelp);
    try testing.expectEqualStrings("textDocument/selectionRange", m_selectionRange);
    try testing.expectEqualStrings("textDocument/completion", m_completion);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", m_publishDiagnostics);
    // A2 needle 形钉：二十二枚对面声明形逐字节锚当前 extension.js 活路形——needle 拼装改样
    // 即红，免得守卫与对面两头猜书写形。
    try testing.expectEqualStrings("request('initialize', initialize)", methods_face[0].needle);
    try testing.expectEqualStrings("method: 'initialized', params: {} }", methods_face[1].needle);
    try testing.expectEqualStrings("id: ++seq, method: 'shutdown' }", methods_face[2].needle);
    try testing.expectEqualStrings("method: 'exit' })", methods_face[3].needle);
    try testing.expectEqualStrings("method: 'textDocument/didOpen',", methods_face[4].needle);
    try testing.expectEqualStrings("method: 'textDocument/didChange',", methods_face[5].needle);
    try testing.expectEqualStrings("method: 'textDocument/didClose',", methods_face[6].needle);
    try testing.expectEqualStrings("method: 'textDocument/didSave',", methods_face[7].needle);
    try testing.expectEqualStrings("request('textDocument/hover', {", methods_face[8].needle);
    try testing.expectEqualStrings("request('textDocument/semanticTokens/full', {", methods_face[9].needle);
    try testing.expectEqualStrings("request('textDocument/documentSymbol', {", methods_face[10].needle);
    try testing.expectEqualStrings("request('textDocument/definition', {", methods_face[11].needle);
    try testing.expectEqualStrings("request('textDocument/references', {", methods_face[12].needle);
    try testing.expectEqualStrings("request('textDocument/documentHighlight', {", methods_face[13].needle);
    try testing.expectEqualStrings("request('textDocument/codeAction', {", methods_face[14].needle);
    try testing.expectEqualStrings("request('textDocument/foldingRange', {", methods_face[15].needle);
    try testing.expectEqualStrings("request('textDocument/rename', {", methods_face[16].needle);
    try testing.expectEqualStrings("request('textDocument/prepareRename', {", methods_face[17].needle);
    try testing.expectEqualStrings("request('workspace/symbol', {", methods_face[18].needle);
    try testing.expectEqualStrings("request('textDocument/signatureHelp', {", methods_face[19].needle);
    try testing.expectEqualStrings("request('textDocument/selectionRange', {", methods_face[20].needle);
    try testing.expectEqualStrings("request('textDocument/completion', {", methods_face[21].needle);
    try testing.expectEqualStrings("msg.method === 'textDocument/publishDiagnostics'", methods_face[22].needle);
    // A3 判据正反小样：真 extension.js 实形为「不缺」；P1–P4 探针漂形为「缺」（本轮把
    // 四路静默面预先钉为有锚）；exit 针附尾防误配：进程级 child.on('exit') 形不算命中。
    try testing.expect(!jsonrpc.missing("request('initialize', initialize).then((res) => {", methods_face[0].needle));
    try testing.expect(!jsonrpc.missing("send({ jsonrpc: '2.0', method: 'initialized', params: {} });", methods_face[1].needle));
    try testing.expect(!jsonrpc.missing("send({ jsonrpc: '2.0', id: ++seq, method: 'shutdown' });", methods_face[2].needle));
    try testing.expect(!jsonrpc.missing("send({ jsonrpc: '2.0', method: 'exit' });", methods_face[3].needle));
    try testing.expect(!jsonrpc.missing("send({ jsonrpc: '2.0', method: 'textDocument/didSave', params: 0 });", methods_face[7].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/hover', {", methods_face[8].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/references', {", methods_face[12].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/documentHighlight', {", methods_face[13].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/codeAction', {", methods_face[14].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/foldingRange', {", methods_face[15].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/rename', {", methods_face[16].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/prepareRename', {", methods_face[17].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('workspace/symbol', { query });", methods_face[18].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/signatureHelp', {", methods_face[19].needle));
    try testing.expect(!jsonrpc.missing("const res = await request('textDocument/selectionRange', {", methods_face[20].needle));
    try testing.expect(!jsonrpc.missing("if (msg.method === 'textDocument/publishDiagnostics') {", methods_face[22].needle));
    try testing.expect(jsonrpc.missing("send({ jsonrpc: '2.0', method: 'textDocument/didSve', params: 0 });", methods_face[7].needle)); // P1 形
    try testing.expect(jsonrpc.missing("if (msg.method === 'textDocument/publishDiagnosticX') {", methods_face[22].needle)); // P2 形
    try testing.expect(jsonrpc.missing("request('textDocument/signatureHelX', {", methods_face[19].needle)); // 参数提示面漂形
    try testing.expect(jsonrpc.missing("request('textDocument/selectionRangX', {", methods_face[20].needle)); // 智能扩选面漂形
    try testing.expect(jsonrpc.missing("request('textDocument/completionX', {", methods_face[21].needle)); // 上下文补全面漂形
    try testing.expect(jsonrpc.missing("request('textDocument/referenceX', {", methods_face[12].needle)); // 引用面漂形
    try testing.expect(jsonrpc.missing("request('textDocument/documentHighlighX', {", methods_face[13].needle)); // 高亮面漂形
    try testing.expect(jsonrpc.missing("request('textDocument/codeActioX', {", methods_face[14].needle)); // 快速修复面漂形
    try testing.expect(jsonrpc.missing("request('textDocument/foldingRangX', {", methods_face[15].needle)); // 折叠面漂形
    try testing.expect(jsonrpc.missing("request('textDocument/renamX', {", methods_face[16].needle)); // 重命名面漂形
    try testing.expect(jsonrpc.missing("request('textDocument/prepareRenamX', {", methods_face[17].needle)); // 预检面漂形
    try testing.expect(jsonrpc.missing("request('workspace/symboX', {", methods_face[18].needle)); // 工作区符号面漂形
    try testing.expect(jsonrpc.missing("const res = await request('textDocument/hove', {", methods_face[8].needle)); // P3 形
    try testing.expect(jsonrpc.missing("request('initializeX', initialize).then(() => {});", methods_face[0].needle)); // P4 形
    try testing.expect(jsonrpc.missing("child.on('exit', () => { ready = false; });", methods_face[3].needle)); // 防误配反样
    // A4 dispatch 同骨 round-trip：以 hub 真值构造的报文必命中活臂（initialize 有应答、
    // didOpen 发诊断且 method 词等于写侧真值）；真值加尾即落不支持面 -32601（漂移的
    // 运行期后果钉，不再只靠同文件手抄 fixture 自照）。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"" ++ m_initialize ++ "\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":7") != null);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"" ++ m_didOpen ++ "\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.zz\",\"text\":\"常数 a = 1，\\n\"}}}", &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[1], "\"method\":\"" ++ m_publishDiagnostics ++ "\"") != null); // 写侧词即 hub 真值（publishRaw 委派）
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"" ++ m_documentSymbol ++ "\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[2], "\"name\":\"a\"") != null); // 大纲臂经 dispatch 真应答
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"" ++ m_initialize ++ "X\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[3], ek_code ++ ":" ++ std.fmt.comptimePrint("{d}", .{ec_method_not_found})) != null); // 漂形落不支持面（通知形则静默丢弃，请求形必报错）
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"" ++ m_selectionRange ++ "\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.zz\"},\"positions\":[{\"line\":0,\"character\":3}]}}", &out);
    try testing.expectEqual(@as(usize, 5), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[4], ek_parent) != null); // 扩选链带 parent（词元→行→文档）
    // A5 覆盖钉：二十三枚——新增方法接线须在此随动（防只加常量不加对账面，同 215–217）。
    try testing.expectEqual(@as(usize, 23), methods_face.len);
}

// 219 T0（第 219 轮 D87）：词类标签族六员单一真值——值钉 + classify→classToTokenType 全域
// round-trip 钉 + 双出口同词钉。t2 探针实锤的静默面：P1 hover 别名标签/P2 补全产物 .group
// 前缀扩展改名（标准库→标准库X）穿透宽松 indexOf 伪钉而 573/573 恒绿静默；P3 classify
// 「方言词」支漂移唯 snippets 自照红、server 旧测不采样该支（round-trip 缺口）；P5 新增类词
// 被 classToTokenType fallback 静默吞。双出口真跑坐实补全 description 组词与 hover md 组字
// 同词分道互不随动。
test "219 T0 词类标签族：六员值钉 + 全域 round-trip + 双出口同词（防跨模块手抄与 fallback 吞词静默）" {
    // A1 值钉：六员标签——改真值名须生成/消费两侧与这些钉同批随动。
    try testing.expectEqualStrings("内建函数", snippets.g_builtin);
    try testing.expectEqualStrings("字面常量", snippets.g_constant);
    try testing.expectEqualStrings("类型", snippets.g_type);
    try testing.expectEqualStrings("关键字", snippets.g_keyword);
    try testing.expectEqualStrings("方言词", snippets.g_dialect);
    try testing.expectEqualStrings("标准库", snippets.g_alias);
    // A2 覆盖钉：六员枚举——新增类标签先入 groups_all 并在消费侧立映射（P5 吞词的对照防线）。
    try testing.expectEqual(@as(usize, 6), snippets.groups_all.len);
    // A3 全域 round-trip 钉：classify 各族样本 → 返回值必等于 hub 真值成员 → classToTokenType
    //    必映射期望索引（旧形制缺「方言词」支采样——P3 实锤消费侧对该支漂移不可见）。
    const rt = [_]struct { word: []const u8, g: []const u8, ty: u8 }{
        .{ .word = "@sqrt", .g = snippets.g_builtin, .ty = ty_function },
        .{ .word = "true", .g = snippets.g_constant, .ty = ty_keyword },
        .{ .word = "u8", .g = snippets.g_type, .ty = ty_type },
        .{ .word = "const", .g = snippets.g_keyword, .ty = ty_keyword },
        .{ .word = "常数", .g = snippets.g_dialect, .ty = ty_variable },
    };
    var asserts: usize = 0;
    for (rt) |c| {
        try testing.expectEqualStrings(c.g, snippets.classify(c.word)); // 生成侧返回值即 hub 真值
        try testing.expectEqual(c.ty, classToTokenType(snippets.classify(c.word))); // 消费侧按 hub 真值词映射
        asserts += 2;
    }
    // A4 双出口同词钉：hover 别名 md 组词（server `hoverAt` 臂）与补全产物 description 组词
    //    （snippets `generate` 臂）皆锚 g_alias——t2 真跑的 P1/P2 各漂一侧即成对失联，今同出一源。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"" ++ m_didOpen ++ "\",\"params\":{\"textDocument\":{\"uri\":\"file:///g219.zz\",\"text\":\"标准库.调试.打印(\\\"甲\\\");\\n\"}}}", &out);
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"" ++ m_hover ++ "\",\"params\":{\"textDocument\":{\"uri\":\"file:///g219.zz\"},\"position\":{\"line\":0,\"character\":1}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "**" ++ snippets.g_alias ++ "**") != null); // hover 出口组词
    const json_bytes = try snippets.generate(gpa, lang);
    defer gpa.free(json_bytes);
    try testing.expect(std.mem.indexOf(u8, json_bytes, snippets.g_alias ++ " → ") != null); // 补全出口同词
    asserts += 2;
    std.debug.print("219 T0 asserts={d}\n", .{asserts});
}

// 220 T0（第 220 轮 D88）：消息本体键族 hub——十三枚值钉 / 骨架渲染不变量钉 / didOpen→publish
// 键 round-trip 真跑 / hover round-trip（半角合法源·语义命中臂）/ 漂 textDocument 键静默坠空行为
// 钉 / 对面清单成员数形钉。
test "220 T0：消息本体键族 hub 单源＋骨架渲染＋round-trip＋漂键静默坠空（第 220 轮）——D88" {
    const tg = testing.allocator;
    // A1 十三枚值钉：hub 键词字面逐一等于协议词汇。
    try testing.expectEqualStrings("jsonrpc", k_jsonrpc);
    try testing.expectEqualStrings("method", k_method);
    try testing.expectEqualStrings("id", k_id);
    try testing.expectEqualStrings("params", k_params);
    try testing.expectEqualStrings("result", k_result);
    try testing.expectEqualStrings("textDocument", k_textDocument);
    try testing.expectEqualStrings("uri", k_uri);
    try testing.expectEqualStrings("text", k_text);
    try testing.expectEqualStrings("contentChanges", k_contentChanges);
    try testing.expectEqualStrings("position", k_position);
    try testing.expectEqualStrings("line", k_line);
    try testing.expectEqualStrings("character", k_character);
    try testing.expectEqualStrings("diagnostics", k_diagnostics);
    // A2 骨架渲染不变量：f_* 模板渲染逐字节等于解析臂实际接受的报文形。
    {
        const u_js = try jsonrpc.jsonString(tg, "file:///x.zz");
        defer tg.free(u_js);
        const b_js = try jsonrpc.jsonString(tg, "甲");
        defer tg.free(b_js);
        const r1 = try std.fmt.allocPrint(tg, f_didOpen_params, .{ u_js, b_js });
        defer tg.free(r1);
        try testing.expectEqualStrings("{\"textDocument\":{\"uri\":\"file:///x.zz\",\"text\":\"甲\"}}", r1);
        const r2 = try std.fmt.allocPrint(tg, f_hover_params, .{ u_js, @as(usize, 0), @as(usize, 3) });
        defer tg.free(r2);
        try testing.expectEqualStrings("{\"textDocument\":{\"uri\":\"file:///x.zz\"},\"position\":{\"line\":0,\"character\":3}}", r2);
        const r3 = try std.fmt.allocPrint(tg, f_range_json, .{ @as(usize, 1), @as(usize, 2), @as(usize, 3), @as(usize, 4) });
        defer tg.free(r3);
        try testing.expectEqualStrings("{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":3,\"character\":4}}", r3);
        const r4 = try std.fmt.allocPrint(tg, f_fold_item, .{ @as(usize, 1), @as(usize, 3) });
        defer tg.free(r4);
        try testing.expectEqualStrings("{\"startLine\":1,\"endLine\":3}", r4);
    }
    var lang = try Pack.parse(tg, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(tg, &lang);
    defer srv.deinit();
    var out: OutList = .empty;
    defer freeOut(tg, &out);
    // A3 round-trip 真跑（全角坏源）：f 骨架拼 didOpen 帧 → publish 帧以 k_* 键回读非空诊断数组。
    const uri_js = try jsonrpc.jsonString(tg, "file:///r220.zz");
    defer tg.free(uri_js);
    const body_js = try jsonrpc.jsonString(tg, "标准库.调试.打印（\"甲\"）;\n");
    defer tg.free(body_js);
    const open = try std.fmt.allocPrint(tg, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_method ++ "\":\"" ++ m_didOpen ++ "\",\"" ++ k_params ++ "\":" ++ f_didOpen_params ++ "}}", .{ uri_js, body_js });
    defer tg.free(open);
    try srv.handle(open, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, tg, out.items[0], .{});
    defer parsed.deinit();
    const root = asObject(parsed.value).?;
    try testing.expectEqualStrings(m_publishDiagnostics, strField(root, k_method).?);
    const pmap = objIn(root.get(k_params)).?;
    try testing.expectEqualStrings("file:///r220.zz", strField(pmap, k_uri).?);
    switch (pmap.get(k_diagnostics).?) {
        .array => |arr| try testing.expect(arr.items.len >= 1), // 全角括号恰一枚词法诊断
        else => return error.UnexpectedDiagsShape,
    }
    // A3b hover round-trip（半角合法源·156 轮同文）：f_hover_params 拼帧 → k_result 回读非空对象。
    const h_uri = try jsonrpc.jsonString(tg, "file:///r220h.zz");
    defer tg.free(h_uri);
    const h_body = try jsonrpc.jsonString(tg, "标准库.调试.打印(\"甲\");\n");
    defer tg.free(h_body);
    const hopen = try std.fmt.allocPrint(tg, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_method ++ "\":\"" ++ m_didOpen ++ "\",\"" ++ k_params ++ "\":" ++ f_didOpen_params ++ "}}", .{ h_uri, h_body });
    defer tg.free(hopen);
    try srv.handle(hopen, &out);
    freeOut(tg, &out);
    const hover = try std.fmt.allocPrint(tg, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_id ++ "\":7,\"" ++ k_method ++ "\":\"" ++ m_hover ++ "\",\"" ++ k_params ++ "\":" ++ f_hover_params ++ "}}", .{ h_uri, @as(usize, 0), @as(usize, 4) });
    defer tg.free(hover);
    try srv.handle(hover, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    var hp = try std.json.parseFromSlice(std.json.Value, tg, out.items[0], .{});
    defer hp.deinit();
    try testing.expect(objIn(asObject(hp.value).?.get(k_result)) != null);
    // A4 漂键静默坠空行为钉：textDocument 键漂作 td → 文档不入表、零出站（t2 P4 真跑同骨）。
    freeOut(tg, &out);
    const drift = try std.fmt.allocPrint(tg, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_method ++ "\":\"" ++ m_didOpen ++ "\",\"" ++ k_params ++ "\":{{\"td\":{{\"" ++ k_uri ++ "\":{s},\"" ++ k_text ++ "\":{s}}}}}}}", .{ uri_js, body_js });
    defer tg.free(drift);
    try srv.handle(drift, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    // A5 对面十二清单成员数钉：十三枚 needle 全由 hub k_* 派生（对账在守卫对面十二）。
    try testing.expectEqual(@as(usize, 13), params_face.len);
}
// 221 T0（第 221 轮 D89）：诊断项/悬停/错误对象字段族 hub——十枚值钉 / 四模板渲染 reparse 回读
// round-trip / didOpen→publish 诊断项字段活体回读 / hover 结果 contents 活体回读 / 对面十三数形钉。
test "221 T0：诊断项字段族 hub 单源＋模板渲染 round-trip＋结果体活体回读（第 221 轮）——D89" {
    const tg = testing.allocator;
    // A1 十二枚值钉：hub 字段词逐一等于 LSP 协议词汇字面——改真值须声明意图。
    try testing.expectEqualStrings("range", k_range);
    try testing.expectEqualStrings("severity", k_severity);
    try testing.expectEqualStrings("source", k_source);
    try testing.expectEqualStrings("message", k_message);
    try testing.expectEqualStrings("contents", k_contents);
    try testing.expectEqualStrings("kind", k_kind);
    try testing.expectEqualStrings("value", k_value);
    try testing.expectEqualStrings("error", k_error);
    try testing.expectEqualStrings("code", k_code);
    try testing.expectEqualStrings("startLine", k_startLine);
    try testing.expectEqualStrings("endLine", k_endLine);
    try testing.expectEqualStrings("markdown", v_markdown);
    try testing.expectEqualStrings("placeholder", k_placeholder);
    // A2 模板渲染 round-trip：f_sem_item/f_fast_item/f_hover_result/f_error_response 渲染后 reparse，
    // 以 k_* 回读——写形与解析形同骨；source 值由 eq_prog_name comptime 内联、与客户端 needle 同源。
    {
        const rg = try std.fmt.allocPrint(tg, f_range_json, .{ @as(usize, 0), @as(usize, 1), @as(usize, 0), @as(usize, 2) });
        defer tg.free(rg);
        const mj = try jsonrpc.jsonString(tg, "甲");
        defer tg.free(mj);
        const one = try std.fmt.allocPrint(tg, f_sem_item, .{ rg, sv_warning, mj });
        defer tg.free(one);
        var p1 = try std.json.parseFromSlice(std.json.Value, tg, one, .{});
        defer p1.deinit();
        const o1 = asObject(p1.value).?;
        try testing.expect(objIn(o1.get(k_range)) != null);
        try testing.expectEqual(@as(i64, sv_warning), intField(o1, k_severity).?);
        try testing.expectEqualStrings(paths.prog_name, strField(o1, k_source).?);
        try testing.expectEqualStrings("甲", strField(o1, k_message).?);
        const two = try std.fmt.allocPrint(tg, f_fast_item, .{ rg, sv_error, mj });
        defer tg.free(two);
        var p2 = try std.json.parseFromSlice(std.json.Value, tg, two, .{});
        defer p2.deinit();
        try testing.expectEqual(@as(i64, sv_error), intField(asObject(p2.value).?, k_severity).?); // 快路 severity 恒 sv_error 值形钉
        const three = try std.fmt.allocPrint(tg, f_hover_result, .{ mj, rg });
        defer tg.free(three);
        var p3 = try std.json.parseFromSlice(std.json.Value, tg, three, .{});
        defer p3.deinit();
        const c3 = objIn(asObject(p3.value).?.get(k_contents)).?;
        try testing.expectEqualStrings(v_markdown, strField(c3, k_kind).?);
        try testing.expectEqualStrings("甲", strField(c3, k_value).?);
        const four = try std.fmt.allocPrint(tg, f_error_response, .{ "5", @as(i64, ec_method_not_found), mj });
        defer tg.free(four);
        var p4 = try std.json.parseFromSlice(std.json.Value, tg, four, .{});
        defer p4.deinit();
        const e4 = objIn(asObject(p4.value).?.get(k_error)).?;
        try testing.expectEqual(@as(i64, ec_method_not_found), intField(e4, k_code).?);
        try testing.expectEqualStrings("甲", strField(e4, k_message).?);
    }
    var lang = try Pack.parse(tg, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(tg, &lang);
    defer srv.deinit();
    var out: OutList = .empty;
    defer freeOut(tg, &out);
    // A3 活体 round-trip（全角坏源）：publish 帧诊断项以 k_range/k_start/k_line/k_severity/k_source/k_message 回读。
    const uri221 = try jsonrpc.jsonString(tg, "file:///r221.zz");
    defer tg.free(uri221);
    const body221 = try jsonrpc.jsonString(tg, "标准库.调试.打印（\"甲\");\n");
    defer tg.free(body221);
    const open = try std.fmt.allocPrint(tg, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_method ++ "\":\"" ++ m_didOpen ++ "\",\"" ++ k_params ++ "\":" ++ f_didOpen_params ++ "}}", .{ uri221, body221 });
    defer tg.free(open);
    try srv.handle(open, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    var pp = try std.json.parseFromSlice(std.json.Value, tg, out.items[0], .{});
    defer pp.deinit();
    const pm = objIn(asObject(pp.value).?.get(k_params)).?;
    const arr = switch (pm.get(k_diagnostics).?) {
        .array => |a| a.items,
        else => return error.UnexpectedDiagsShape,
    };
    try testing.expect(arr.len >= 1);
    const d0 = asObject(arr[0]).?;
    const rng = objIn(d0.get(k_range)).?;
    const st = objIn(rng.get(k_start)).?;
    try testing.expect(intField(st, k_line) != null);
    try testing.expect(intField(st, k_character) != null);
    try testing.expectEqual(@as(i64, sv_error), intField(d0, k_severity).?); // 快路诊断项 severity=sv_error
    try testing.expectEqualStrings(paths.prog_name, strField(d0, k_source).?);
    try testing.expect(strField(d0, k_message).?.len > 0);
    // A4 hover 活体 round-trip（半角合法源·220 A3b 同骨）：result 对象回读 contents/kind/value ＋ range。
    freeOut(tg, &out);
    const huri = try jsonrpc.jsonString(tg, "file:///r221h.zz");
    defer tg.free(huri);
    const hbody = try jsonrpc.jsonString(tg, "标准库.调试.打印(\"甲\");\n");
    defer tg.free(hbody);
    const hopen = try std.fmt.allocPrint(tg, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_method ++ "\":\"" ++ m_didOpen ++ "\",\"" ++ k_params ++ "\":" ++ f_didOpen_params ++ "}}", .{ huri, hbody });
    defer tg.free(hopen);
    try srv.handle(hopen, &out);
    freeOut(tg, &out);
    const hover = try std.fmt.allocPrint(tg, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_id ++ "\":7,\"" ++ k_method ++ "\":\"" ++ m_hover ++ "\",\"" ++ k_params ++ "\":" ++ f_hover_params ++ "}}", .{ huri, @as(usize, 0), @as(usize, 4) });
    defer tg.free(hover);
    try srv.handle(hover, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    var hv = try std.json.parseFromSlice(std.json.Value, tg, out.items[0], .{});
    defer hv.deinit();
    const ro = objIn(asObject(hv.value).?.get(k_result)).?;
    const hc = objIn(ro.get(k_contents)).?;
    try testing.expectEqualStrings(v_markdown, strField(hc, k_kind).?);
    try testing.expect(strField(hc, k_value).?.len > 0);
    try testing.expect(objIn(ro.get(k_range)) != null);
    // A5 对面十三清单成员数钉：廿七枚 needle 全由 hub k_*/v_markdown/paths.prog_name/lsp_kind_base 派生（对账在守卫对面十三）。
    try testing.expectEqual(@as(usize, 27), results_face.len);
}

// 222 T0（第 222 轮 · D90）：severity 码值族 hub——A1 四枚协议值钉／A2 clamp 边界
// round-trip（四支在界透传＋5/0 越界兜底·t2 P3 上界漂即此钉红）／A3 快路恒码委派渲染
// 回读／A4 sv_face 成员数钉＋派生数值形钉。
test "222 T0：诊断严重度码值族 hub 单源＋clamp 边界 round-trip＋客户端映射面钉（第 222 轮）——D90" {
    const tg = testing.allocator;
    // A1：四枚码值逐一等于 LSP DiagnosticSeverity 协议数值（协议常量钉死、改动即失联）。
    try testing.expectEqual(@as(u8, 1), sv_error);
    try testing.expectEqual(@as(u8, 2), sv_warning);
    try testing.expectEqual(@as(u8, 3), sv_information);
    try testing.expectEqual(@as(u8, 4), sv_hint);
    // A2：semItem clamp 边界 round-trip——界内四支透传、界外（5／0）兜底 sv_error。
    var lang = try Pack.parse(tg, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(tg, &lang);
    defer srv.deinit();
    const cases = [_]struct { in: u8, want: i64 }{
        .{ .in = sv_error, .want = sv_error },
        .{ .in = sv_warning, .want = sv_warning },
        .{ .in = sv_information, .want = sv_information },
        .{ .in = sv_hint, .want = sv_hint },
        .{ .in = 5, .want = sv_error },
        .{ .in = 0, .want = sv_error },
    };
    var asserts: usize = 4;
    for (cases) |c| {
        const j = try srv.semItem(.{ .line = 0, .character = 1, .char_len = 2, .severity = c.in, .message = "甲" });
        defer tg.free(j);
        const wrapped = try std.fmt.allocPrint(tg, "[{s}]", .{j});
        defer tg.free(wrapped);
        var parsed = try std.json.parseFromSlice(std.json.Value, tg, wrapped, .{});
        defer parsed.deinit();
        const o = asObject(parsed.value.array.items[0]).?;
        try testing.expectEqual(c.want, intField(o, k_severity).?);
        try testing.expectEqualStrings("甲", strField(o, k_message).?);
        asserts += 2;
    }
    // A3：快路恒码委派——diagItem 渲染 severity 必等于 sv_error（f_fast_item 由 {d} 槽
    // 携 hub 真值、字面 `:1` 已剿，clamp 上界漂不再能静默钳升 Hint/界外码）。
    const fast = try srv.diagItem("x", 0, 1, "乙");
    defer tg.free(fast);
    const wrapped2 = try std.fmt.allocPrint(tg, "[{s}]", .{fast});
    defer tg.free(wrapped2);
    var p2 = try std.json.parseFromSlice(std.json.Value, tg, wrapped2, .{});
    defer p2.deinit();
    try testing.expectEqual(@as(i64, sv_error), intField(asObject(p2.value.array.items[0]).?, k_severity).?);
    asserts += 1;
    // A4：客户端映射面清单——四枚成员数钉＋首三支 needle 数值全由 sv_* comptime 派生。
    try testing.expectEqual(@as(usize, 4), sv_face.len);
    try testing.expectEqualStrings("s === 1 ? vscode.DiagnosticSeverity.Error", sv_face[0].needle);
    try testing.expectEqualStrings(": s === 2 ? vscode.DiagnosticSeverity.Warning", sv_face[1].needle);
    try testing.expectEqualStrings(": s === 3 ? vscode.DiagnosticSeverity.Information", sv_face[2].needle);
    try testing.expect(std.mem.indexOf(u8, sv_face[3].needle, "Hint") != null);
    asserts += 4;
    std.debug.print("222 T0 asserts={d}\n", .{asserts});
}

// A3 补钉助手：应答帧 reparse 后回读 error.code 精确值——串钉只钉前缀，加尾漂即漏网。
fn expectErrCode(tg: std.mem.Allocator, frame: []const u8, want: i64) !void {
    var p = try std.json.parseFromSlice(std.json.Value, tg, frame, .{});
    defer p.deinit();
    const e = objIn(asObject(p.value).?.get(k_error)).?;
    try testing.expectEqual(want, intField(e, k_code).?);
}

// 223 T0（第 223 轮 · D91）：错误码族 hub——A1 三枚协议值钉／A2 f_error_response 三码渲染
// reparse round-trip／A3 handle 活体三臂改严形钉（坏 JSON→-32700、不支持方法→-32601、
// 根非对象→-32600——P4 加尾漂移形再现即红）／A4 errors_face 成员数钉＋派生形钉。
test "223 T0：JSON-RPC 错误码族 hub 单源＋应答体 round-trip＋客户端应答面钉（第 223 轮）——D91" {
    const tg = testing.allocator;
    // A1 三枚协议值钉
    try testing.expectEqual(@as(i64, -32700), ec_parse_error);
    try testing.expectEqual(@as(i64, -32600), ec_invalid_request);
    try testing.expectEqual(@as(i64, -32601), ec_method_not_found);
    // A2 f_error_response 渲染 round-trip：三码渲染后以 k_code 回读——与 handle 应答同骨
    const mj = "\"x\"";
    const codes = [_]i64{ ec_parse_error, ec_invalid_request, ec_method_not_found };
    for (codes) |code| {
        const fr = try std.fmt.allocPrint(tg, f_error_response, .{ "1", code, mj });
        defer tg.free(fr);
        var p = try std.json.parseFromSlice(std.json.Value, tg, fr, .{});
        defer p.deinit();
        const e = objIn(asObject(p.value).?.get(k_error)).?;
        try testing.expectEqual(code, intField(e, k_code).?);
    }
    // A3 handle 活体三臂改严形钉（键前缀＋派生数值逐字节）
    var lang = try Pack.parse(tg, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(tg, &lang);
    defer srv.deinit();
    var out: OutList = .empty;
    defer freeOut(tg, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/implementation\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], ek_code ++ ":" ++ std.fmt.comptimePrint("{d}", .{ec_method_not_found})) != null);
    // 加尾形（-32601→-326011）子串形漏网——补 reparse 精确值钉封死（t2 P4 静默面转锚）。
    try expectErrCode(tg, out.items[0], ec_method_not_found);
    freeOut(tg, &out);
    try srv.handle("not-json{{{", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], ek_code ++ ":" ++ std.fmt.comptimePrint("{d}", .{ec_parse_error})) != null);
    try expectErrCode(tg, out.items[0], ec_parse_error);
    freeOut(tg, &out);
    try srv.handle("[]", &out); // 根非对象形
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], ek_code ++ ":" ++ std.fmt.comptimePrint("{d}", .{ec_invalid_request})) != null);
    try expectErrCode(tg, out.items[0], ec_invalid_request);
    freeOut(tg, &out);
    // A4 errors_face 成员数钉＋needle 派生形钉
    try testing.expectEqual(@as(usize, 1), errors_face.len);
    try testing.expectEqualStrings("error: { code: -32601", errors_face[0].needle);
}

test "第 263 轮 documentSymbol：顶层声明扫描/修饰词跳过/嵌套与注释不收/空文档空数组" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();

    const text =
        "// 顶层注释\n" ++
        "公开 函数 主函数() 空 {\n" ++
        "    常数 内层 = 1;\n" ++
        "}\n" ++
        "结构 配置 {\n" ++
        "    变量 字段 = 0;\n" ++
        "}\n" ++
        "枚举 颜色 {\n" ++
        "    红,\n" ++
        "}\n" ++
        "常数 上限: 整数 = 100;\n" ++
        "变量 计数 = 0;\n";
    const js = try collectSymbolsJson(gpa, &lang, text);
    defer gpa.free(js);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, js, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 5), arr.len);
    const want_names = [_][]const u8{ "主函数", "配置", "颜色", "上限", "计数" };
    const want_kinds = [_]i64{ 12, 23, 10, 14, 13 };
    for (arr, 0..) |item, i| {
        const o = asObject(item).?;
        try testing.expectEqualStrings(want_names[i], strField(o, "name").?);
        try testing.expectEqual(want_kinds[i], intField(o, "kind").?);
        try testing.expect(o.get("range") != null);
        try testing.expect(o.get(k_selectionRange) != null);
    }
    // 嵌套声明（内层常数/结构体字段）只出现在缩进行，不收入顶层大纲；注释行更不收入。
    try testing.expect(std.mem.indexOf(u8, js, "内层") == null);
    try testing.expect(std.mem.indexOf(u8, js, "字段") == null);

    const empty = try collectSymbolsJson(gpa, &lang, "");
    defer gpa.free(empty);
    try testing.expectEqualStrings("[]", empty);
}

test "第 264 轮 definition：声明名与引用跳同一定位/字符串与注释及未知词不跳" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    const text =
        "常数 上限 = 1;\n" ++
        "函数 主函数() 空 {\n" ++
        "    返回 上限;\n" ++
        "}\n" ++
        "常数 提示 = \"上限\";\n" ++
        "// 上限\n";
    const uri = "file:///t.zz";
    const decl_off = std.mem.indexOf(u8, text, "上限").?;
    const ret_off = std.mem.indexOf(u8, text, "返回").?;
    const ref_off = std.mem.indexOfPos(u8, text, ret_off, "上限").?;

    const decl_js = srv.definitionAt(text, uri, decl_off) orelse return error.TestUnexpectedResult;
    defer gpa.free(decl_js);
    const ref_js = srv.definitionAt(text, uri, ref_off) orelse return error.TestUnexpectedResult;
    defer gpa.free(ref_js);
    // 声明名与函数体内的引用都落到同一顶层声明（0 基行 0、字符 3 起）。
    for ([_][]const u8{ decl_js, ref_js }) |js| {
        try testing.expect(std.mem.indexOf(u8, js, "\"uri\":\"file:///t.zz\"") != null);
        try testing.expect(std.mem.indexOf(u8, js, "\"line\":0,\"character\":3") != null);
    }
    // 光标落在引用词尾（末字符之后）仍取前一词元，兼容编辑器把 position 报在词尾。
    const tail_js = srv.definitionAt(text, uri, ref_off + "上限".len) orelse return error.TestUnexpectedResult;
    defer gpa.free(tail_js);
    try testing.expect(std.mem.indexOf(u8, tail_js, "\"line\":0,\"character\":3") != null);

    // 字符串、注释、关键字词元不参与跳转（lexer 词类过滤，不做上下文猜测）。
    const str_off = (std.mem.indexOf(u8, text, "\"上限\"") orelse return error.TestUnexpectedResult) + 1;
    try testing.expect(srv.definitionAt(text, uri, str_off) == null);
    const cmt_off = (std.mem.indexOf(u8, text, "// 上限") orelse return error.TestUnexpectedResult) + 3;
    try testing.expect(srv.definitionAt(text, uri, cmt_off) == null);
    try testing.expect(srv.definitionAt(text, uri, ret_off) == null);
}

test "第 266 轮 references：声明与引用全收/可排除声明/字符串注释不混入/无声明空数组" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    const text =
        "常数 上限 = 1;\n" ++
        "函数 主函数() 空 {\n" ++
        "    返回 上限;\n" ++
        "}\n" ++
        "常数 提示 = \"上限\";\n" ++
        "// 上限\n";
    const uri = "file:///t.zz";
    const decl_off = std.mem.indexOf(u8, text, "上限").?;
    const ret_off = std.mem.indexOf(u8, text, "返回").?;
    const ref_off = std.mem.indexOfPos(u8, text, ret_off, "上限").?;

    const all = try srv.referencesAt(text, uri, decl_off, true);
    defer gpa.free(all);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, all, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    // 声明 + 函数体内引用各一枚；字符串与注释中的「上限」不混入。
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expect(std.mem.indexOf(u8, all, "\"line\":0,\"character\":3") != null);
    try testing.expect(std.mem.indexOf(u8, all, "\"line\":2,\"character\":7") != null);

    // includeDeclaration=false 只留引用；从引用发起与从声明发起结果同集。
    const refs_only = try srv.referencesAt(text, uri, ref_off, false);
    defer gpa.free(refs_only);
    var parsed_refs = try std.json.parseFromSlice(std.json.Value, gpa, refs_only, .{});
    defer parsed_refs.deinit();
    const refs_arr = switch (parsed_refs.value) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 1), refs_arr.len);
    try testing.expect(std.mem.indexOf(u8, refs_only, "\"line\":2,\"character\":7") != null);
    try testing.expect(std.mem.indexOf(u8, refs_only, "\"line\":0,\"character\":3") == null);

    const from_ref = try srv.referencesAt(text, uri, ref_off, true);
    defer gpa.free(from_ref);
    try testing.expect(std.mem.eql(u8, all, from_ref));

    // 光标词没有同名顶层声明 → 空数组（不把局部/未知词硬凑成引用）。
    const unknown_text = "函数 主函数() 空 { 返回 未知; }\n";
    const unknown_off = std.mem.indexOf(u8, unknown_text, "未知").?;
    const unknown = try srv.referencesAt(unknown_text, uri, unknown_off, true);
    defer gpa.free(unknown);
    try testing.expectEqualStrings("[]", unknown);

    // dispatch 路径：context.includeDeclaration=false 必须被解析并只回引用项。
    try srv.upsertDoc(uri, text);
    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.zz\"},\"position\":{\"line\":0,\"character\":3},\"context\":{\"includeDeclaration\":false}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":9") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"line\":2,\"character\":7") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"line\":0,\"character\":3") == null);
}

// ─── 287 T0（第 287 轮 · D146）：codeAction item.title 跨侧手抄入面 ────────────
test "287 T0：results_face[20] 派生自 k_title、正/负/漂三形对拍实锤（第 287 轮 D146）" {
    // A1：needle 派生正确——"new vscode.CodeAction(item.title," 含 k_title。
    const n20 = results_face[20].needle;
    try testing.expect(std.mem.indexOf(u8, n20, k_title) != null);
    try testing.expectEqualStrings("new vscode.CodeAction(item.title,", n20);

    // A2：正面——实际 js 文本包含该 needle。
    const js_ok = "          const action = new vscode.CodeAction(item.title, kind);";
    try testing.expect(std.mem.indexOf(u8, js_ok, n20) != null);

    // A3：漂形（探针 P1 实锤的 form）——js 文本不包含该 needle。
    const js_drift = "          const action = new vscode.CodeAction(item.titl, kind);";
    try testing.expect(std.mem.indexOf(u8, js_drift, n20) == null);

    // A4：hub 漂形——若 k_title 改为 "titl" 则 needle 不再匹配当前 js 文本。
    const hub_drift_needle = "new vscode.CodeAction(item.titl,";
    try testing.expect(std.mem.indexOf(u8, js_ok, hub_drift_needle) == null);

    // A5：面长度钉。
    try testing.expectEqual(@as(usize, 27), results_face.len);
}

// ─── 288 T0（第 288 轮 · D147）：Location.uri 跨侧手抄入面 ────────────────────
test "288 T0：results_face[21] 派生自 k_uri、正/负/漂三形对拍实锤（第 288 轮 D147）" {
    // A1：needle 派生正确——"vscode.Uri.parse(loc.uri)" 含 k_uri。
    const n21 = results_face[21].needle;
    try testing.expect(std.mem.indexOf(u8, n21, k_uri) != null);
    try testing.expectEqualStrings("vscode.Uri.parse(loc.uri)", n21);

    // A2：正面——实际 js 文本包含该 needle（definition 路径）。
    const js_def_ok = "          vscode.Uri.parse(loc.uri),";
    try testing.expect(std.mem.indexOf(u8, js_def_ok, n21) != null);

    // A3：漂形（探针 P1）——loc.uri→loc.ur 不匹配 needle。
    const js_drift = "          vscode.Uri.parse(loc.ur),";
    try testing.expect(std.mem.indexOf(u8, js_drift, n21) == null);

    // A4：hub 漂形——若 k_uri 改为 "url" 则 needle 不再匹配当前 js。
    const hub_drift_needle = "vscode.Uri.parse(loc.url)";
    try testing.expect(std.mem.indexOf(u8, js_def_ok, hub_drift_needle) == null);

    // A5：面长度钉。
    try testing.expectEqual(@as(usize, 27), results_face.len);
}

// ─── 289 T0（第 289 轮 · D148）：documentSymbol selectionRange 跨侧手抄入面 ─────
test "289 T0：results_face[22] 派生自 k_selectionRange、正/负/漂三形对拍实锤（第 289 轮 D148）" {
    // A1：needle 派生正确。
    const n22 = results_face[22].needle;
    try testing.expect(std.mem.indexOf(u8, n22, k_selectionRange) != null);
    try testing.expectEqualStrings("s.selectionRange ||", n22);

    // A2：正面——实际 js 文本包含 needle。
    const js_ok = "  const sr = s.selectionRange || r;";
    try testing.expect(std.mem.indexOf(u8, js_ok, n22) != null);

    // A3：漂形（探针 P1）——js 文本不匹配。
    const js_drift = "  const sr = s.selectionRang || r;";
    try testing.expect(std.mem.indexOf(u8, js_drift, n22) == null);

    // A4：hub 漂形——若 k_selectionRange 改为 "selRange" 则 needle 不再匹配 js。
    const hub_drift_needle = "s.selRange ||";
    try testing.expect(std.mem.indexOf(u8, js_ok, hub_drift_needle) == null);

    // A5：f_document_symbol 由 ek_selectionRange 派生。
    try testing.expect(std.mem.indexOf(u8, f_document_symbol, k_selectionRange) != null);

    // A6：面长度钉。
    try testing.expectEqual(@as(usize, 27), results_face.len);
}
// ─── 290 T0（第 290 轮 · D149）：LSP↔vscode kind 枚举空间换算入面 ─────────────
test "290 T0：lsp_kind_base/sk_* 值钉、换算链同骨、results_face[23..25] 与 kinds_smoke_face 正反漂三形对拍（第 290 轮 D149）" {
    // A1：基址与宿主枚数值钉——vscode.d.ts 的 SymbolKind.Function=11、CompletionItemKind.Function=2、
    // CompletionItemKind.Keyword=13、SymbolKind.Constant=13，皆由本 hub 的 LSP 码减基址派生。
    try testing.expectEqual(@as(u32, 1), lsp_kind_base);
    try testing.expectEqual(@as(u32, 11), sk_function - lsp_kind_base);
    try testing.expectEqual(@as(u32, 12), sk_variable - lsp_kind_base);
    try testing.expectEqual(@as(u32, 13), sk_constant - lsp_kind_base);
    try testing.expectEqual(@as(u32, 9), sk_enum - lsp_kind_base);
    try testing.expectEqual(@as(u32, 22), sk_struct - lsp_kind_base);
    try testing.expectEqual(@as(u32, 2), ck_function - lsp_kind_base);
    try testing.expectEqual(@as(u32, 13), ck_keyword - lsp_kind_base);
    try testing.expectEqual(@as(u32, 20), ck_constant - lsp_kind_base);

    // A2：换算链同骨——declKind 的产出域与 completionKindForSymbol 的入参域共此一组 sk_*，
    // 二次映射不许落 else（落 else 即声明候选图标一律变变量）。
    try testing.expectEqual(ck_function, completionKindForSymbol(sk_function));
    try testing.expectEqual(ck_struct, completionKindForSymbol(sk_struct));
    try testing.expectEqual(ck_enum, completionKindForSymbol(sk_enum));
    try testing.expectEqual(ck_constant, completionKindForSymbol(sk_constant));
    try testing.expectEqual(ck_variable, completionKindForSymbol(sk_variable));
    try testing.expectEqual(ck_variable, completionKindForSymbol(0)); // 非 LSP 码 → 兜底（0 不在 LSP 值域）

    // A3：客户端换算调用形三枚 needle 的正面（js 实文形状·守卫对面十三）。
    const n23 = results_face[23].needle;
    const n24 = results_face[24].needle;
    const n25 = results_face[25].needle;
    try testing.expectEqualStrings("function toVscodeKind(k) { return Math.max(k - 1, 0); }", n23);
    try testing.expectEqualStrings("toVscodeKind(c.kind || 1)", n24);
    try testing.expectEqualStrings("toVscodeSymbolKind(s.kind)", n25);
    const js_ok = "function toVscodeKind(k) { return Math.max(k - 1, 0); }\n" ++
        "const item = new vscode.CompletionItem(label, toVscodeKind(c.kind || 1));\n" ++
        "    toVscodeSymbolKind(s.kind),\n" ++
        "          toVscodeSymbolKind(s.kind),\n";
    try testing.expect(std.mem.indexOf(u8, js_ok, n23) != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, js_ok, n23));
    try testing.expect(std.mem.indexOf(u8, js_ok, n24) != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, js_ok, n25));

    // A4：漂形（探针 P1 的直传/乱加形与 hub 基址漂形）——三枚 needle 皆落空。
    const js_drift = "    s.kind + 5 || vscode.SymbolKind.Variable,\n" ++
        "    c.kind || 0);\n" ++
        "    toVscodeSymbolKind(s.kind),\n";
    try testing.expect(std.mem.indexOf(u8, js_drift, n23) == null);
    try testing.expect(std.mem.indexOf(u8, js_drift, n24) == null);
    try testing.expect(std.mem.count(u8, js_drift, n25) < results_face[25].occ); // 只漏一处：计数下界拦下
    try testing.expect(std.mem.indexOf(u8, js_drift, n25) != null); // presence 判据对此形无能（occ 收紧的立论根据）

    // A5：计数下界钉——两处同形手抄只此一枚 needle，occ 须为 2；其余两枚 presence 足矣。
    try testing.expectEqual(@as(usize, 2), results_face[25].occ);
    try testing.expectEqual(@as(usize, 1), results_face[23].occ);
    try testing.expectEqual(@as(usize, 1), results_face[24].occ);

    // A6：对面二十七——宿主枚举数值针的正/反/漂形。
    try testing.expectEqual(@as(usize, 5), kinds_smoke_face.len);
    try testing.expectEqualStrings("eq(vscode.SymbolKind.Function, 11", kinds_smoke_face[0].needle);
    try testing.expectEqualStrings("eq(vscode.CompletionItemKind.Function, 2", kinds_smoke_face[1].needle);
    const esm_ok = "  eq(vscode.SymbolKind.Function, 11, '宿主 SymbolKind 为 0 基');\n" ++
        "  eq(vscode.CompletionItemKind.Function, 2, '宿主 CompletionItemKind 为 0 基');\n" ++
        "  eq(sym.kind, vscode.SymbolKind.Function, '大纲图标');\n" ++
        "  eq(decl.kind, vscode.CompletionItemKind.Function, '补全图标');\n" ++
        "  eq(ws.kind, vscode.SymbolKind.Function, '工作区图标');\n";
    inline for (kinds_smoke_face) |c| try testing.expect(std.mem.indexOf(u8, esm_ok, c.needle) != null);
    // 桩漂回 1 基（自照形）与断言抄写侧原数形：两枚数值针/三枚落点针分别落空。
    const esm_drift = "  eq(vscode.SymbolKind.Function, 12, '…');\n" ++
        "  eq(vscode.CompletionItemKind.Function, 3, '…');\n" ++
        "  eq(sym.kind, 12, '…');\n" ++
        "  eq(decl.kind, 3, '…');\n" ++
        "  eq(ws.kind, 12, '…');\n";
    inline for (kinds_smoke_face) |c| try testing.expect(std.mem.indexOf(u8, esm_drift, c.needle) == null);

    // A7：面长度钉。
    try testing.expectEqual(@as(usize, 27), results_face.len);
}

// ─── 291 写侧（第 291 轮 · D150）：补全截断旗标的真值路径 ────────────────────
// 旧测试图里 `isIncomplete` 只出现过 false 形（截断分支 `hits > limit` 从未被任何用例推过
// 边界），故上限魔数与极性皆空转；本测以成对边界用例把 true 形钉住（用例数由 hub
// `completion_item_limit` 驱动，测面不另抄 200）。
test "第 291 轮 lsp.server：候选达上限不截断、超上限截断并置 isIncomplete=true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile(paths.builtin_pack_embed_child));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    const cases = [_]struct { n: usize, want: bool }{
        .{ .n = completion_item_limit, .want = false }, // 恰达上限：不截断（钉 `>` 而非 `>=`）
        .{ .n = completion_item_limit + 1, .want = true }, // 超一枚：截断并置旗标
    };
    for (cases) |c| {
        // n 条同前缀顶层声明（名零填充，字典序即数值序），末行放光标前缀 `zzcA`。
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < c.n) : (i += 1) {
            try buf.appendSlice(gpa, try std.fmt.allocPrint(gpa, "常数 zzcA{d:0>4} = 0;\n", .{i}));
        }
        const tail_name = try std.fmt.allocPrint(gpa, "zzcA{d:0>4}", .{c.n - 1});
        try buf.appendSlice(gpa, "zzcA");
        const doc = try buf.toOwnedSlice(gpa);

        const uri_js = try jsonrpc.jsonString(gpa, "file:///trunc.zz");
        const body_js = try jsonrpc.jsonString(gpa, doc);
        var out: OutList = .empty;
        const open = try std.fmt.allocPrint(gpa, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_method ++ "\":\"" ++ m_didOpen ++ "\",\"" ++ k_params ++ "\":" ++ f_didOpen_params ++ "}}", .{ uri_js, body_js });
        try srv.handle(open, &out); // 附诊断通知，不入下列断言

        const req = try std.fmt.allocPrint(gpa, "{{\"" ++ k_jsonrpc ++ "\":\"2.0\",\"" ++ k_id ++ "\":9,\"" ++ k_method ++ "\":\"" ++ m_completion ++ "\",\"" ++ k_params ++ "\":" ++ f_hover_params ++ "}}", .{ uri_js, c.n, @as(usize, 4) });
        out = .empty;
        try srv.handle(req, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);

        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0], .{});
        defer parsed.deinit();
        const res = objIn(asObject(parsed.value).?.get(k_result)).?;
        switch (res.get(k_isIncomplete).?) {
            .bool => |b| try testing.expectEqual(c.want, b),
            else => return error.TestUnexpectedResult,
        }
        const items = switch (res.get(k_items).?) {
            .array => |a| a.items,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(completion_item_limit, items.len); // 截断后恰发上限枚
        var tail_seen: usize = 0;
        for (items) |it| {
            const lab = switch (it.object.get(k_label).?) {
                .string => |s| s,
                else => return error.TestUnexpectedResult,
            };
            if (std.mem.eql(u8, lab, tail_name)) tail_seen += 1;
        }
        try testing.expectEqual(@as(usize, if (c.want) 0 else 1), tail_seen); // 超限时字典序末名被截掉
    }
}

// ─── 291 T0（第 291 轮 · D150）：补全完整性旗标跨侧手抄入面 ──────────────────
test "291 T0：results_face[26] 派生自 k_isIncomplete、正/漂两形对拍与上限常量同骨（第 291 轮 D150）" {
    // A1：needle 派生正确——读面键段随 hub `k_isIncomplete` 漂。
    const n26 = results_face[26].needle;
    try testing.expectEqualStrings("!!res.isIncomplete", n26);
    try testing.expect(std.mem.indexOf(u8, n26, k_isIncomplete) != null);
    try testing.expectEqual(@as(usize, 1), results_face[26].occ); // 单点读面：presence 足矣

    // A2：正面——js 实文形状包含 needle。
    const js_ok = "        list.isIncomplete = !!res.isIncomplete;";
    try testing.expect(std.mem.indexOf(u8, js_ok, n26) != null);

    // A3：漂形（探针 P1）——键名少一字符，读侧落 undefined 而观测仍为 false，needle 须落空。
    const js_drift = "        list.isIncomplete = !!res.isIncomplet;";
    try testing.expect(std.mem.indexOf(u8, js_drift, n26) == null);
    // hub 漂形：键名改义后 js 旧形亦不匹配（两侧不可能各自漂而互不知情）。
    try testing.expect(std.mem.indexOf(u8, js_ok, "!!res.isCompIncomplete") == null);

    // A4：写侧同骨——旗标键与空表形皆由 `k_isIncomplete` 派生（测面针脚不再硬编字面量）。
    try testing.expect(std.mem.indexOf(u8, f_completion_list, k_isIncomplete) != null);
    try testing.expect(std.mem.indexOf(u8, f_empty_completion, k_isIncomplete) != null);
    try testing.expectEqualStrings("\"isIncomplete\":false", needle_incomplete_false);
    try testing.expect(std.mem.indexOf(u8, needle_empty_completion, k_isIncomplete) != null);

    // A5：上限常量值钉与写侧委派——臂内不得再留裸 200。
    try testing.expectEqual(@as(usize, 200), completion_item_limit);

    // A6：面长度钉。
    try testing.expectEqual(@as(usize, 27), results_face.len);
}
