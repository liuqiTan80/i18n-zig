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
//! 换算集中在 positionOfOffset/byteOfPosition 两处、单测直钉（BMP 母语一字一码元）。

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const Pack = @import("../lang/pack.zig").Pack;
const lexer = @import("../transpiler/lexer.zig");
const translate = @import("../transpiler/translate.zig");
const fullwidth = @import("../diag/fullwidth.zig");
const snippets = @import("../editor/snippets.zig");

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
        while (it.next()) |e| self.gpa.free(e.value_ptr.*);
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
            const res =
                \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":1,"save":{"includeText":false}},"hoverProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","type","function","variable","string","comment","number"],"tokenModifiers":[]},"full":true}},"serverInfo":{"name":"zzc-lsp"}}
            ;
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
            if (self.docs.fetchRemove(uri)) |kv| gpa.free(kv.value);
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
        if (self.docs.fetchRemove(uri)) |old| gpa.free(old.value);
        try self.docs.put(try gpa.dupe(u8, uri), try gpa.dupe(u8, text));
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
        return std.fmt.allocPrint(gpa, "{{\"range\":{s},\"severity\":{d},\"source\":\"zzc\",\"message\":{s}}}", .{ range, sev, msg_js });
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
        return std.fmt.allocPrint(gpa, "{{\"range\":{s},\"severity\":1,\"source\":\"zzc\",\"message\":{s}}}", .{ range, msg_js });
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
            .comment => 5, // comment
            .string, .char, .multiline, .symbol => 4, // string
            .nonascii_word => blk: {
                const word = text[t.off..][0..t.len];
                const v = self.lang.keywords.get(word) orelse break :blk null;
                break :blk classToTokenType(snippets.classify(v));
            },
            .ascii_word => blk: {
                const word = text[t.off..][0..t.len];
                break :blk if (word.len > 0 and std.ascii.isDigit(word[0])) @as(u8, 6) else null; // number
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

/// `snippets.classify` 词类标签 → LSP tokenTypes 图例索引（与 initialize 图例顺序同绑）。
fn classToTokenType(group: []const u8) u8 {
    if (std.mem.eql(u8, group, "关键字")) return 0;
    if (std.mem.eql(u8, group, "字面常量")) return 0;
    if (std.mem.eql(u8, group, "类型")) return 1;
    if (std.mem.eql(u8, group, "内建函数")) return 2;
    return 3; // 方言词 → variable
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
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"keyword\",\"type\",\"function\",\"variable\",\"string\",\"comment\",\"number\"],\"tokenModifiers\":[]},\"full\":true}") != null);
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
    try testing.expect(std.mem.indexOf(u8, out.items[0], "\"source\":\"zzc\"") != null);
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
    try testing.expectEqual(@as(i64, 2), data[2].integer); // length：两个 BMP 码元
    try testing.expectEqual(@as(i64, 0), data[3].integer); // type=keyword
    // token2 数字 1：同行、delta_start=7（常(0)数(1)空(2)甲(3)空(4)=(5)空(6)1(7)）、type=number(6)
    try testing.expectEqual(@as(i64, 0), data[5].integer); // delta_line
    try testing.expectEqual(@as(i64, 7), data[6].integer); // delta_start
    try testing.expectEqual(@as(i64, 1), data[7].integer); // length
    try testing.expectEqual(@as(i64, 6), data[8].integer); // type=number
    // token3 注释 // 注：同行、delta_start=2（自 1 后）、length=4、type=comment(5)
    try testing.expectEqual(@as(i64, 2), data[11].integer); // delta_start
    try testing.expectEqual(@as(i64, 4), data[12].integer); // length
    try testing.expectEqual(@as(i64, 5), data[13].integer); // type=comment
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
