//! LSP 基座协议帧（第 156 轮 · 编辑器 LSP 面）：JSON-RPC 2.0 + `Content-Length` 报文帧。
//! 纯字节函数、不触 IO——stdin/stdout 环流接线留在 main.zig（不入测试图），
//! 帧的编解码在此全量进测试图钉死（对齐 154/155 轮「纯逻辑下沉、编排薄接线」先例）。
//!
//! 形制契约（LSP 3.17 基座协议）：
//!   - 帧头 `Header: value` 行以 `\r\n` 分隔、空行 `\r\n\r\n` 结束；必需头 `Content-Length`
//!     （大小写不敏感），其余头（`Content-Type` 等）接受但忽略；
//!   - Content-Length 计**字节数**（UTF-8 体不透明透传，本层不解析 JSON 语义）；
//!   - 解析采增量形：缓冲不足一帧返回 null 令调用方续读，坏帧返回错误（不发半帧）。

const std = @import("std");

pub const ParseError = error{ InvalidFrame, FrameTooLarge };

/// 单帧上限（对抗恶意/失同步流）：与 file_io 的 10MB 输入上限同源量级。
/// 第 217 轮 D85：值面自此有字面钉（217 T0 A1）——旧超长测试只以 `max_frame_len + 1`
/// 派生对账，改本值即测试随动全绿（t2 探针 P6 实锤的静默面）。
pub const max_frame_len: usize = 10 * 1024 * 1024;

/// 必需头名单一真值（第 217 轮 D85）：解析（大小写不敏感比较）、编码形串与客户端
/// `client_frames.js` 对面 needle 皆自此派生——旧形为两端各自手抄同名字面量，js 侧任何
/// 漂移对本构建链零信号（唯一旧防线 `check-demos.ps1`「shared handshake guard」节 NO_PWSH＋NO_NODE 双盲）。
pub const header_name: []const u8 = "Content-Length";

/// 头部块结束分隔符单一真值：解析搜索、编码尾串、`start` 偏移与 js 面 needle 皆自它派生。
pub const header_sep: []const u8 = "\r\n\r\n";

pub const Frame = struct {
    /// 帧体字节（JSON-RPC 报文原文，不 NUL 结尾）
    body: []const u8,
    /// 整帧（含头）在缓冲中占用的字节数，调用方据此消费
    consumed: usize,
};

/// 从缓冲头部解析一帧。返回 null = 数据还不完整（调用方续读后重试）；
/// 错误 = 帧头坏了（非数字长度/超长/缺失），流已不可信。
pub fn parseFrame(buf: []const u8) ParseError!?Frame {
    const sep = std.mem.indexOf(u8, buf, header_sep) orelse return null;
    const headers = buf[0..sep];
    var content_len: ?usize = null;
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |line0| {
        // 行尾拖字 \r 剔除（已按 '\n' 切行）
        const line = if (line0.len > 0 and line0[line0.len - 1] == '\r') line0[0 .. line0.len - 1] else line0;
        if (line.len == 0) continue; // 前导空行容忍（`\r\n\r\n` 前已是全头）
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidFrame;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, header_name)) {
            content_len = std.fmt.parseInt(usize, value, 10) catch return error.InvalidFrame;
        }
    }
    const n = content_len orelse return error.InvalidFrame;
    if (n > max_frame_len) return error.FrameTooLarge;
    const start = sep + header_sep.len;
    const end = start + n;
    if (end > buf.len) return null; // 体未收全
    return .{ .body = buf[start..end], .consumed = end };
}

/// 编码一帧：`Content-Length: N\r\n\r\n` + 体（调用方 free）。
pub fn encodeFrame(gpa: std.mem.Allocator, body: []const u8) ![]const u8 {
    const hdr = try std.fmt.allocPrint(gpa, header_name ++ ": {d}" ++ header_sep, .{body.len});
    defer gpa.free(hdr);
    return std.mem.concat(gpa, u8, &.{ hdr, body });
}

/// 把任意字节写成 JSON 字符串字面量（含两端引号，调用方 free）。
/// 转义 `"` `\` 与控制字符；`\x80` 以上字节 UTF-8 原样透传（母语词形零转义膨胀）。
pub fn jsonString(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    const esc = try std.fmt.allocPrint(gpa, "\\u{x:0>4}", .{c});
                    defer gpa.free(esc);
                    try out.appendSlice(gpa, esc);
                } else {
                    try out.append(gpa, c);
                }
            },
        }
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// 对面·客户端 `editors/vscode/client_frames.js`（第 217 轮 D85）
// ---------------------------------------------------------------------------
//
// 该文件是 LSP 基座协议帧的客户端实现（零 npm 依赖、vscode-free），注释自称
// 「mirrors src/lsp/jsonrpc.zig … kept in sync by the shared handshake guard」，而那个
// guard 在 `tools/check-demos.ps1`（需 pwsh+node）——本机与 CI 的 `zig build test` 链
// NO_PWSH＋NO_NODE 双盲，t2 探针 P1–P5 五路 js 漂移 569/569 全绿静默实证假锚防线。
// 本节把帧头名/分隔符/上限的逐字节对面 needle 清单入 hub（皆自上面族真值派生），
// 由守卫步 `check-machine-matcher` 对面十对账——判据入 hub、守卫只做 I/O（承 203/215/216）。

/// 帧上限的 MB 计（js 面 needle 以 `N * 1024 * 1024` 字面形声明）：非整 MB 即编译拒自守。
pub const max_frame_mb: usize = if (max_frame_len % (1024 * 1024) != 0) @compileError("max_frame_len 须为整 MB——js 面 needle 以 MB 字面形拼装") else max_frame_len / (1024 * 1024);

/// 把字节串转为 JS 源码转义形（本族只需 CR/LF；其余字符即 `@compileError` 自守）。
/// 输出长度恒为 `2 * s.len`（每字符皆落两字节转义对），故按值返回定长数组、无局部指针逃逸。
/// `comptime` 块强制全体在编译期求值（按值 `break :blk out`）：若裸露于运行期路径，
/// 运行期函数体内调用时 `c` 非 comptime 已知，`@compileError` 分支会被当作可达而拦截（217 判例）。
pub fn jsEsc(comptime s: []const u8) [s.len * 2]u8 {
    return comptime blk: {
        var out: [s.len * 2]u8 = undefined;
        var n: usize = 0;
        for (s) |c| {
            switch (c) {
                '\r' => {
                    out[n] = '\\';
                    out[n + 1] = 'r';
                    n += 2;
                },
                '\n' => {
                    out[n] = '\\';
                    out[n + 1] = 'n';
                    n += 2;
                },
                else => @compileError("jsEsc：仅支持 CR/LF 转义形"),
            }
        }
        break :blk out;
    };
}

/// 全小写形（js 解码端先 `toLowerCase()` 再比字面）：自 `header_name` 派生，非手抄。
pub fn asciiLower(comptime s: []const u8) [s.len]u8 {
    var out: [s.len]u8 = undefined;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// 一次对面核对项：逐字节 needle 与「分道即何为」说明（与 215/216 轮同形制）。
pub const FaceCheck = struct {
    needle: []const u8,
    why: []const u8,
};

/// 对面·`client_frames.js`：上限／写侧头名／写侧分隔符／读侧头名／读侧分隔符。
/// 后端（服务端）帧形与前端这五枚同骨即双向可解；分道即 initialize 握手都解不了——LSP 全废。
pub const frames_face = [_]FaceCheck{
    .{ .needle = "const MAX_FRAME_BYTES = " ++ std.fmt.comptimePrint("{d}", .{max_frame_mb}) ++ " * 1024 * 1024;", .why = "客户端帧上限须等于服务端 max_frame_len 的 MB 字面形，分道即两端对超限帧取舍口径不一（流失同步或超大合法帧被客户端拒收）" },
    .{ .needle = "'" ++ header_name ++ ": ' + payload.length", .why = "写侧帧头名与冒号空格形须逐字节等于服务端编码形，分道即服务端认不出必需头——initialize 即死" },
    .{ .needle = "payload.length + '" ++ jsEsc(header_sep) ++ "', 'ascii'", .why = "写侧头部块结束分隔符须等于服务端搜索形，分道即服务端永凑不齐一帧（全量静默无应答）" },
    .{ .needle = "name === '" ++ asciiLower(header_name) ++ "'", .why = "读侧 lowercase 后比较的头名须由服务端真值派生，分道即客户端解不了服务端应答帧（取 throw 形失联）" },
    .{ .needle = "this.buf.indexOf('" ++ jsEsc(header_sep) ++ "')", .why = "读侧分隔符搜索形须等于真值转义，分道即客户端永认为帧未收全——应答满屏而不显" },
};

/// `text`（运行时对面全文）是否缺 `needle`（命中即已同步；缺失即分道）。守卫据此循环报错、不自立判据。
pub fn missing(text: []const u8, comptime needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) == null;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "jsonrpc.encodeFrame：字节级钉死头+体（第 156 轮）" {
    const got = try encodeFrame(testing.allocator, "{\"a\":1}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Content-Length: 7\r\n\r\n{\"a\":1}", got);
}

test "jsonrpc.encodeFrame：UTF-8 体按字节计长（母语零膨胀）（第 156 轮）" {
    const body = "{\"w\":\"词\"}"; // 词 = 3 字节
    const got = try encodeFrame(testing.allocator, body);
    defer testing.allocator.free(got);
    const want = std.fmt.allocPrint(testing.allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, got);
}

test "jsonrpc.parseFrame：完整帧→体+consumed；往返一致（第 156 轮）" {
    const body = "{\"id\":1,\"method\":\"exit\"}";
    const framed = try encodeFrame(testing.allocator, body);
    defer testing.allocator.free(framed);
    const f = (try parseFrame(framed)).?;
    try testing.expectEqualStrings(body, f.body);
    try testing.expectEqual(framed.len, f.consumed);
}

test "jsonrpc.parseFrame：增量读——头缺/体缺皆 null 不误报（第 156 轮）" {
    const framed = try encodeFrame(testing.allocator, "hello");
    defer testing.allocator.free(framed);
    // 截到头部中间
    try testing.expectEqual(@as(?Frame, null), try parseFrame(framed[0 .. framed.len - 2]));
    // 截到空分隔前
    try testing.expectEqual(@as(?Frame, null), try parseFrame("Content-Length: 5\r\n"));
    // 头全但体只到 1 字节
    try testing.expectEqual(@as(?Frame, null), try parseFrame("Content-Length: 5\r\n\r\nh"));
}

test "jsonrpc.parseFrame：Content-Length 大小写不敏感 + 附加头容忍（第 156 轮）" {
    const f = (try parseFrame("content-length:2\r\nContent-Type: application/json\r\n\r\nab")).?;
    try testing.expectEqualStrings("ab", f.body);
}

test "jsonrpc.parseFrame：坏帧拒——缺长度头/非数字/超长（第 156 轮·对抗形）" {
    try testing.expectError(error.InvalidFrame, parseFrame("X-Oops: 1\r\n\r\nbody"));
    try testing.expectError(error.InvalidFrame, parseFrame("Content-Length: abc\r\n\r\nx"));
    try testing.expectError(error.InvalidFrame, parseFrame("novalueheader\r\n\r\nx"));
    const huge = std.fmt.allocPrint(testing.allocator, "Content-Length: {d}\r\n\r\n", .{max_frame_len + 1}) catch unreachable;
    defer testing.allocator.free(huge);
    try testing.expectError(error.FrameTooLarge, parseFrame(huge));
}

test "jsonrpc.jsonString：转义矩阵 + 母语透传（第 156 轮）" {
    const q = try jsonString(testing.allocator, "a\"b\\c\nd\te\u{1}");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001\"", q);
    const zh = try jsonString(testing.allocator, "词法 → const");
    defer testing.allocator.free(zh);
    try testing.expectEqualStrings("\"词法 → const\"", zh);
}

test "lsp.jsonrpc：jsonString 控制字符转义臂 + parseFrame 头值 trim/分隔符/空值 零直调分支真形（第 173 轮）" {
    // 承 156 帧层七测，补其零直调分支：jsonString 转义矩阵独缺 CR 短转义臂、
    // 控制字符阈值恰等边界 0x1f/0x20、NUL 四位补零；parseFrame 空头部块/头值 trim 集含 tab/
    // 裸 \n 分隔（null 待续 vs 坏帧）/空 Content-Length 值。皆经探针坐实为正确防御行为、无在线缺陷。
    var asserts: usize = 0;

    // A. jsonString 控制字符转义分支
    {
        const cr = try jsonString(testing.allocator, "a\rb");
        defer testing.allocator.free(cr);
        try testing.expectEqualStrings("\"a\\rb\"", cr); // CR → 短转义 \r（非 \u000d）
        asserts += 1;
    }
    {
        const crlf = try jsonString(testing.allocator, "x\r\ny");
        defer testing.allocator.free(crlf);
        try testing.expectEqualStrings("\"x\\r\\ny\"", crlf); // CR+LF 各短转义
        asserts += 1;
    }
    {
        const u1f = try jsonString(testing.allocator, "\u{1f}");
        defer testing.allocator.free(u1f);
        try testing.expectEqualStrings("\"\\u001f\"", u1f); // 0x1f 末位转义（c<0x20 恰等边界）
        asserts += 1;
    }
    {
        const nul = try jsonString(testing.allocator, "\u{0}");
        defer testing.allocator.free(nul);
        try testing.expectEqualStrings("\"\\u0000\"", nul); // NUL → \u0000 四位补零
        asserts += 1;
    }
    {
        const sp = try jsonString(testing.allocator, "\u{20}");
        defer testing.allocator.free(sp);
        try testing.expectEqualStrings("\" \"", sp); // 0x20 空格透传不转义（边界另一侧）
        asserts += 1;
    }
    // reparse 不变量：CR 转义串可被 std.json 解回原串（缺转义则帧结构破损）
    {
        const cr = try jsonString(testing.allocator, "a\rb");
        defer testing.allocator.free(cr);
        const doc = try std.fmt.allocPrint(testing.allocator, "{{\"s\":{s}}}", .{cr});
        defer testing.allocator.free(doc);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, doc, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("a\rb", parsed.value.object.get("s").?.string);
        asserts += 1;
    }

    // B. parseFrame 帧头状态机边界
    {
        try testing.expectError(error.InvalidFrame, parseFrame("\r\n\r\nbody")); // 空头部块：无 Content-Length
        asserts += 1;
    }
    {
        const f = (try parseFrame("Content-Length:   7\t\r\n\r\n{\"a\":1}")).?; // 值 trim 剥前导多空格+尾随 tab
        try testing.expectEqualStrings("{\"a\":1}", f.body);
        asserts += 1;
        try testing.expectEqual(@as(usize, 31), f.consumed);
        asserts += 1;
    }
    {
        try testing.expectEqual(@as(?Frame, null), try parseFrame("Content-Length: 2\n\nab")); // 裸 \n 分隔（非 \r\n\r\n）→ null 待续非坏帧
        asserts += 1;
    }
    {
        try testing.expectError(error.InvalidFrame, parseFrame("Content-Length:\r\n\r\nab")); // 空值：parseInt("") 失败
        asserts += 1;
    }

    std.debug.print("T asserts={d}\n", .{asserts});
}

test "第 217 轮 T0 LSP 基座协议帧族：值字面钉／派生形钉／js 面五枚 needle 形钉／判据正反小样含 P1–P5 探针形" {
    // A1 值字面钉：族三根真值的字面形（P6 静默面关闸——旧形只存 max_frame_len+1 派生对账，改值即全绿随动）。
    try testing.expectEqualStrings("Content-Length", header_name);
    try testing.expectEqualStrings("\r\n\r\n", header_sep);
    try testing.expectEqual(@as(usize, 10 * 1024 * 1024), max_frame_len);
    // A2 派生形钉：MB 计、JS 转义形与 lowercase 形皆由真值派生（改真值即 needle 全族同动）。
    try testing.expectEqual(@as(usize, 10), max_frame_mb);
    const esc_sep = jsEsc(header_sep); // JS 源码字面形：反斜杠+字母，非控制字节
    try testing.expectEqualStrings("\\r\\n\\r\\n", &esc_sep);
    const lower_name = asciiLower(header_name);
    try testing.expectEqualStrings("content-length", &lower_name);
    // A3 五枚 needle 形钉：逐字节当前活路形（形改即守卫与对面两头猜）。
    try testing.expectEqualStrings("const MAX_FRAME_BYTES = 10 * 1024 * 1024;", frames_face[0].needle);
    try testing.expectEqualStrings("'Content-Length: ' + payload.length", frames_face[1].needle);
    try testing.expectEqualStrings("payload.length + '\\r\\n\\r\\n', 'ascii'", frames_face[2].needle);
    try testing.expectEqualStrings("name === 'content-length'", frames_face[3].needle);
    try testing.expectEqualStrings("this.buf.indexOf('\\r\\n\\r\\n')", frames_face[4].needle);
    // A4 判据正反小样：命中为不缺；P1–P5 探针形（本轮把五路静默面逐一预先钉为有锚）皆为缺。
    try testing.expect(!missing("const MAX_FRAME_BYTES = 10 * 1024 * 1024;", frames_face[0].needle));
    try testing.expect(missing("const MAX_FRAME_BYTES = 5 * 1024 * 1024;", frames_face[0].needle)); // P1 形
    try testing.expect(missing("Buffer.from('X-Content-Length: ' + payload.length", frames_face[1].needle)); // P2 形
    try testing.expect(missing("payload.length + '\\n\\n', 'ascii'", frames_face[2].needle)); // P3 形
    try testing.expect(missing("if (name === 'contentlength') {", frames_face[3].needle)); // P4 形
    try testing.expect(missing("const sep = this.buf.indexOf('\\r\\r');", frames_face[4].needle)); // P5 形
    // A5 编解码同骨 round-trip：我方编码出口逐字节含写侧 needle 所钉的同源段（服务端真值与对面声明同骨）。
    const enc = try encodeFrame(testing.allocator, "{}");
    defer testing.allocator.free(enc);
    try testing.expectEqualStrings("Content-Length: 2\r\n\r\n{}", enc);
    // A6 面清单覆盖钉：五枚——新增接线点须在此随动（防只加常量不加对账面）。
    try testing.expectEqual(@as(usize, 5), frames_face.len);
}
