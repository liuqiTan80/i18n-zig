//! LSP 服务器分发核（第 156 轮 · 编辑器 LSP 面）：JSON-RPC 报文 → 应答/通知报文。
//! 纯函数核、不触 IO——stdin/stdout 环流与帧收发留在 main.zig 薄接线（不入测试图），
//! 本模块全量进测试图（承 154/155 轮「纯逻辑下沉、编排薄接线」范式）。
//!
//! 能力面（MVP）：
//!   - 生命周期：`initialize`（capabilities：全量文本同步 + hover）、`initialized`、
//!     `shutdown`、`exit`（置停旗标由环流侧结束）；
//!   - 文档同步：`didOpen`/`didChange`（全量形）/`didClose`，服务端自持文档表；
//!   - 快路诊断：didOpen/didChange/didClose 后 `publishDiagnostics`——判据取纯函数面
//!     （`translate.preCheck` 全角/词法 + `findEnglishWordForms` 纯母语强制），
//!     消息措辞与 `zzc check` 逐字同形（去路径前缀、坐标改 LSP 0 基）；语义级编译诊断
//!     仍走 154 轮 task/problemMatcher 通道（每次键击起 zig 编译既慢又与 symbols.txt 竞争）；
//!   - 悬停：`textDocument/hover`——光标词（含 `标准库.调试.打印` 点链整体取词）反查
//!     语言包 keywords/aliases，详情分组与 155 轮补全描述同口径（`snippets.classify` 复用）。
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
const paths = @import("../zzc_paths.zig"); // 第 210 轮 D78：诊断 source 标注的程序名取单一真值（与 CLI/编辑器同源）

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

/// 字节区间 [start,end) → LSP Range JSON 文本（调用方 free）。
fn rangeJson(gpa: std.mem.Allocator, text: []const u8, start: usize, end: usize) ![]const u8 {
    const a = positionOfOffset(text, start);
    const b = positionOfOffset(text, end);
    return std.fmt.allocPrint(
        gpa,
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ a.line, a.character, b.line, b.character },
    );
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
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json });
}

fn errorResponse(gpa: std.mem.Allocator, id_json: []const u8, code: i64, message: []const u8) ![]const u8 {
    const msg_js = try jsonrpc.jsonString(gpa, message);
    defer gpa.free(msg_js);
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ id_json, code, msg_js });
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
            try out.append(gpa, try errorResponse(gpa, id_null, -32700, "解析失败：不是合法 JSON 报文"));
            return;
        };
        defer parsed.deinit();

        const root = asObject(parsed.value) orelse {
            const id_null = try gpa.dupe(u8, "null");
            defer gpa.free(id_null);
            try out.append(gpa, try errorResponse(gpa, id_null, -32600, "解析失败：报文根不是对象"));
            return;
        };
        const method = strField(root, "method") orelse return; // 应答形（无 method）：本服务器不发请求，忽略
        const idv = root.get("id");
        const params_obj = objIn(root.get("params"));

        if (std.mem.eql(u8, method, "initialize")) {
            // textDocumentSync 升级为对象形（第 159 轮）：声明 openClose + 全量 change + save（includeText:false，
            // didSave 时服务端用自持文档表文本），据以让客户端知晓可发 textDocument/didSave。
            // semanticTokensProvider（第 161 轮）：声明语义 token 图例（token 类型索引即下表顺序）+ full 供给，
            // 把方言母语词汇的语义高亮据 LSP 标准面供任意客户端（编辑端渲染留 162）。
            const res = "{\"capabilities\":{\"textDocumentSync\":{\"openClose\":true,\"change\":1,\"save\":{\"includeText\":false}},\"hoverProvider\":true,\"semanticTokensProvider\":{\"legend\":{" ++ legend_json ++ ",\"tokenModifiers\":[]},\"full\":true}},\"serverInfo\":{\"name\":\"zzc-lsp\"}}";
            try self.respond(out, idv, res);
            return;
        }
        if (std.mem.eql(u8, method, "initialized")) return; // 通知、无应答
        if (std.mem.eql(u8, method, "shutdown")) {
            try self.respond(out, idv, "null");
            return;
        }
        if (std.mem.eql(u8, method, "exit")) {
            self.stop = true;
            return;
        }
        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            const p = params_obj orelse return;
            const td = objIn(p.get("textDocument")) orelse return;
            const uri = strField(td, "uri") orelse return;
            const text = strField(td, "text") orelse return;
            try self.upsertDoc(uri, text);
            try self.publish(out, uri, text);
            return;
        }
        if (std.mem.eql(u8, method, "textDocument/didChange")) {
            const p = params_obj orelse return;
            const td = objIn(p.get("textDocument")) orelse return;
            const uri = strField(td, "uri") orelse return;
            if (!self.docs.contains(uri)) return; // 未 open 的文档不接变更
            // 全量同步（textDocumentSync=1）：contentChanges 末项必带全文 text
            const changes = switch (p.get("contentChanges") orelse .null) {
                .array => |a| a.items,
                else => return,
            };
            if (changes.len == 0) return;
            const last = objIn(changes[changes.len - 1]) orelse return;
            const text = strField(last, "text") orelse return;
            try self.upsertDoc(uri, text);
            try self.publish(out, uri, text);
            return;
        }
        if (std.mem.eql(u8, method, "textDocument/didClose")) {
            const p = params_obj orelse return;
            const td = objIn(p.get("textDocument")) orelse return;
            const uri = strField(td, "uri") orelse return;
            // D60（第 195 轮）：`fetchRemove` 取回的键同为自持堆串，须与值一并回收（原码只 free 值）。
            if (self.docs.fetchRemove(uri)) |kv| {
                gpa.free(kv.key);
                gpa.free(kv.value);
            }
            // 规范：文档关闭后清波浪线——发布空诊断数组
            try self.publishRaw(out, uri, "[]");
            return;
        }
        if (std.mem.eql(u8, method, "textDocument/didSave")) {
            const p = params_obj orelse return;
            const td = objIn(p.get("textDocument")) orelse return;
            const uri = strField(td, "uri") orelse return;
            // includeText:false → 取服务端自持文档表文本（已由 didChange 同步至最新）；未 open 则不处理。
            const text = self.docs.get(uri) orelse return;
            try self.publishSave(out, uri, text);
            return;
        }
        if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.hover(out, idv, params_obj);
            return;
        }
        if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            try self.semanticTokensFull(out, idv, params_obj);
            return;
        }

        if (idv != null) {
            const id_json = try idJson(gpa, idv);
            defer gpa.free(id_json);
            const msg = try std.fmt.allocPrint(gpa, "不支持的方法：{s}", .{method});
            defer gpa.free(msg);
            try out.append(gpa, try errorResponse(gpa, id_json, -32601, msg));
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
        const sev = if (s.severity >= 1 and s.severity <= 4) s.severity else 1;
        const range = try std.fmt.allocPrint(
            gpa,
            "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ s.line, s.character, s.line, s.character + w },
        );
        defer gpa.free(range);
        const msg_js = try jsonrpc.jsonString(gpa, s.message);
        defer gpa.free(msg_js);
        return std.fmt.allocPrint(gpa, "{{\"range\":{s},\"severity\":{d},\"source\":\"{s}\",\"message\":{s}}}", .{ range, sev, paths.prog_name, msg_js });
    }

    fn publishRaw(self: *Server, out: *OutList, uri: []const u8, diags_json: []const u8) !void {
        const gpa = self.gpa;
        const uri_js = try jsonrpc.jsonString(gpa, uri);
        defer gpa.free(uri_js);
        try out.append(gpa, try std.fmt.allocPrint(
            gpa,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":{s},\"diagnostics\":{s}}}}}",
            .{ uri_js, diags_json },
        ));
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
                try std.fmt.allocPrint(gpa, "词法: {s}，请改用半角空格作缩进/分隔", .{v.hint})
            else if (v.ascii.len > 0)
                try std.fmt.allocPrint(gpa, "词法: {s}，请改用半角 `{s}`（Zig 语法符号不翻译）", .{ v.hint, v.ascii })
            else
                try std.fmt.allocPrint(gpa, "词法: {s}（`{s}`）", .{ v.hint, v.word });
            defer gpa.free(msg);
            try items.append(gpa, try self.diagItem(text, v.off, v.off + v.len, msg));
        }

        var eng = translate.findEnglishWordForms(gpa, self.lang.*, text) catch return;
        defer eng.deinit();
        for (eng.items) |v| {
            const msg = try std.fmt.allocPrint(gpa, "纯母语: 方言源须全用母语词形，英文 `{s}` 请改用 `{s}`", .{ v.word, v.native });
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
        return std.fmt.allocPrint(gpa, "{{\"range\":{s},\"severity\":1,\"source\":\"{s}\",\"message\":{s}}}", .{ range, paths.prog_name, msg_js });
    }

    /// 悬停：光标词（含点链）反查语言包；未命中/越界/文档不在表 → result null。
    fn hover(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var result_json: ?[]const u8 = null;
        defer if (result_json) |r| gpa.free(r);

        if (params_obj) |p| {
            if (objIn(p.get("textDocument"))) |td| {
                if (strField(td, "uri")) |uri| {
                    if (self.docs.get(uri)) |text| {
                        if (objIn(p.get("position"))) |pos| {
                            const line = intField(pos, "line") orelse -1;
                            const character = intField(pos, "character") orelse -1;
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
        const group = if (alias_val != null) "标准库" else snippets.classify(word_val);

        const md = std.fmt.allocPrint(gpa, "**{s}** `{s}`\n\n- 标准 Zig 形：`{s}`", .{ group, chain, word_val }) catch return null;
        defer gpa.free(md);
        const md_js = jsonrpc.jsonString(gpa, md) catch return null;
        defer gpa.free(md_js);
        const range = rangeJson(gpa, text, start, end) catch return null;
        defer gpa.free(range);
        return std.fmt.allocPrint(gpa, "{{\"contents\":{{\"kind\":\"markdown\",\"value\":{s}}},\"range\":{s}}}", .{ md_js, range }) catch return null;
    }

    /// `textDocument/semanticTokens/full`（第 161 轮）：对文档全文产语义 token 稀疏流。
    /// 语义高亮仅「被请求才返回」——编辑端未注册 provider 前不应用、无 tmLanguage 降级风险。
    fn semanticTokensFull(self: *Server, out: *OutList, idv: ?std.json.Value, params_obj: ?std.json.ObjectMap) !void {
        const gpa = self.gpa;
        var data_json: ?[]const u8 = null;
        if (params_obj) |p| {
            if (objIn(p.get("textDocument"))) |td| {
                if (strField(td, "uri")) |uri| {
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
    return c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '_';
}

/// `snippets.classify` 词类标签 → LSP tokenTypes 图例索引（第 214 轮 D82：词元名与索引皆取
/// 图例 hub 派生常量，与 initialize 图例强制同序；新增词类须先在 legend_types 立名）。
fn classToTokenType(group: []const u8) u8 {
    if (std.mem.eql(u8, group, "关键字")) return ty_keyword;
    if (std.mem.eql(u8, group, "字面常量")) return ty_keyword;
    if (std.mem.eql(u8, group, "类型")) return ty_type;
    if (std.mem.eql(u8, group, "内建函数")) return ty_function;
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

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"hoverProvider\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"textDocumentSync\":{\"openClose\":true,\"change\":1,\"save\":{\"includeText\":false}}") != null);
    // 第 161 轮：新增语义 token 供给能力（图例七类 + full），供任意 LSP 客户端语义高亮。
    // 第 214 轮 D82 手抄清剿：图例段断言改以 hub 派生的 legend_json 构造（改图例则断言随动，
    // 杜绝「应答与测各抄一份、一改两红」的自照形制）。
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"semanticTokensProvider\":{\"legend\":{" ++ legend_json ++ ",\"tokenModifiers\":[]},\"full\":true}") != null);
}

test "lsp.server：didOpen 坏源→publishDiagnostics 词法形、坐标 0 基 UTF-16（第 156 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
    const mth = strField(root, "method").?;
    try testing.expectEqualStrings("textDocument/publishDiagnostics", mth);
    const po = objIn(root.get("params")).?;
    const arr = switch (po.get("diagnostics").?) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(arr.len >= 1);
    const d0 = asObject(arr[0]).?;
    const rng = asObject(d0.get("range").?).?;
    const st = asObject(rng.get("start").?).?;
    try testing.expectEqual(@as(i64, 0), intField(st, "line").?);
    try testing.expectEqual(@as(i64, 8), intField(st, "character").?);
    const msg = strField(d0, "message").?;
    try testing.expect(std.mem.indexOf(u8, msg, "词法") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "半角") != null);
}

test "lsp.server：hover 方言词命中 keywords、与补全描述同口径；未命中 null（第 156 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
    try testing.expect(std.mem.indexOf(u8, out.items[0], "关键字") != null);

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

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
    defer lang.deinit();
    var srv = Server.init(gpa, &lang);
    defer srv.deinit();

    var out: OutList = .empty;
    defer freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}", &out);
    try testing.expect(srv.stop);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"textDocument/completion\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "-32601") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"id\":\"abc\"") != null); // 字符串 id 原样回显
    freeOut(gpa, &out);

    try srv.handle("not-json{{{", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "-32700") != null);
    freeOut(gpa, &out);

    // 未知通知（无 id）：静默
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{}}", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "lsp.server：hover 点链别名整体取词（标准库.调试.打印 形）（第 156 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
    try testing.expect(std.mem.indexOf(u8, out.items[0], "标准库") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "std.debug.print") != null);

    // 点链中段悬停（`调试` 上）亦整体取词到叶链
    freeOut(gpa, &out);
    try srv.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zz\"},\"position\":{\"line\":0,\"character\":4}}}", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "std.debug.print") != null);
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
    .{ .line = 0, .character = 3, .char_len = 4, .severity = 1, .message = "错误: 假语义诊断XYZ" },
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

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"severity\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"character\":3") != null);
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"source\":\"" ++ paths.prog_name ++ "\"") != null); // 210：source 标注程序名同源
    freeOut(gpa, &out);

    // 未 open 的 uri：didSave 无文本可算，静默不发布。
    try srv.handle("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file:///never.zz\"}}}", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "lsp.server：semanticTokens/full 基本映射 + delta 编码（第 161 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
    try testing.expectEqual(@as(i64, 5), intField(root, "id").?);
    const result = objIn(root.get("result")).?;
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

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
test "lsp.server：classToTokenType 图例索引全分支钉（承 162 共享真相源·第 165 轮）" {
    try testing.expectEqual(@as(u8, 0), classToTokenType("关键字")); // 关键字 → keyword
    try testing.expectEqual(@as(u8, 0), classToTokenType("字面常量")); // 字面常量 → keyword
    try testing.expectEqual(@as(u8, 1), classToTokenType("类型")); // 类型 → type
    try testing.expectEqual(@as(u8, 2), classToTokenType("内建函数")); // 内建函数 → function
    try testing.expectEqual(@as(u8, 3), classToTokenType("方言词")); // 方言词 → variable
    try testing.expectEqual(@as(u8, 3), classToTokenType("未知标签")); // 兜底 → variable
}

// D56 真数据路由钉（第 169 轮）：中文包 真/假/空值/未定义 映射 true/false/null/undefined——
// D56 前 classify 先判 isPrimitive 把四值遮蔽成「类型」→classToTokenType→1（类型色，且字面常量支为死）；
// 修后 classify 先判 isLanguageConstant→「字面常量」→classToTokenType→0（keyword）。坐实设计意图支由死变活。
test "lsp.server：classify→classToTokenType 字面量四值经图例归 keyword(0)（承 162/165 共享真相源·第 169 轮 D56）" {
    var asserts: usize = 0;
    for ([_][]const u8{ "true", "false", "null", "undefined" }) |v| {
        try testing.expectEqualStrings("字面常量", snippets.classify(v));
        asserts += 1;
        try testing.expectEqual(@as(u8, 0), classToTokenType(snippets.classify(v))); // 字面常量 → keyword
        asserts += 1;
    }
    // 对照：真类型名仍走 isPrimitive→「类型」→token 1（坐实判序调整未过度捕获）。
    try testing.expectEqualStrings("类型", snippets.classify("bool"));
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
    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
    const prm = objIn(root.get("params")).?;
    const diags = switch (prm.get("diagnostics").?) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), diags.len);

    // item 0: char_len=0 → w=1, severity=99 → clamp 1
    const d0 = asObject(diags[0]).?;
    const r0 = asObject(d0.get("range").?).?;
    const s0 = asObject(r0.get("start").?).?;
    const e0 = asObject(r0.get("end").?).?;
    try testing.expectEqual(@as(i64, 2), intField(s0, "line").?);
    try testing.expectEqual(@as(i64, 5), intField(s0, "character").?);
    try testing.expectEqual(@as(i64, 1), intField(e0, "character").? - intField(s0, "character").?); // w=1
    try testing.expectEqual(@as(i64, 1), intField(d0, "severity").?); // 99→1

    // item 1: char_len=3, severity=0 → clamp 1
    const d1 = asObject(diags[1]).?;
    const r1 = asObject(d1.get("range").?).?;
    const s1 = asObject(r1.get("start").?).?;
    const e1 = asObject(r1.get("end").?).?;
    try testing.expectEqual(@as(i64, 3), intField(e1, "character").? - intField(s1, "character").?); // w=3
    try testing.expectEqual(@as(i64, 1), intField(d1, "severity").?); // 0→1

    // 断言数： 10
}

test "lsp.server：handle 未 open 退/空数组退/重复 open 覆盖（第 166 轮）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
    const id_val = root.get("id").?;
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
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}", rs);
    asserts += 1;
    var pr = try std.json.parseFromSlice(std.json.Value, gpa, rs, .{});
    defer pr.deinit();
    try testing.expect(asObject(pr.value).?.get("result") != null);
    asserts += 1;

    // errorResponse：message 含引号+反斜杠（模拟客户端 method 串）须被转义——缺转义则 parseFromSlice 即失败。
    const emsg = "不支持的方法：x\"y\\z";
    const er = try errorResponse(gpa, "2", -32601, emsg);
    defer gpa.free(er);
    var pe = try std.json.parseFromSlice(std.json.Value, gpa, er, .{});
    defer pe.deinit();
    const eerr = asObject(asObject(pe.value).?.get("error").?).?;
    try testing.expectEqualStrings(emsg, strField(eerr, "message").?);
    asserts += 1;
    try testing.expectEqual(@as(i64, -32601), intField(eerr, "code").?);
    asserts += 1;

    std.debug.print("T1 asserts={d}\n", .{asserts});
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
        var lang = try Pack.parse(ag, @embedFile("../lang/packs/中文.txt"));
        defer lang.deinit();

        for (non_obj) |body| {
            var srv = Server.init(ag, &lang);
            defer srv.deinit();
            var out: OutList = .empty;
            defer freeOut(ag, &out);

            try srv.handle(body, &out);
            try testing.expectEqual(@as(usize, 1), out.items.len);
            asserts += 1;
            try testing.expect(std.mem.indexOf(u8, out.items[0], "\"code\":-32600") != null);
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
    var lang = try Pack.parse(lang_arena.allocator(), @embedFile("../lang/packs/中文.txt"));
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

    var lang = try Pack.parse(gpa, @embedFile("../lang/packs/中文.txt"));
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
    const init_result = objIn(asObject(parsed.value).?.get("result")).?;
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
    const data = switch (objIn(asObject(parsed2.value).?.get("result")).?.get("data").?) {
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
