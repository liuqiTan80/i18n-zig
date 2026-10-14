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
pub const max_frame_len: usize = 10 * 1024 * 1024;

pub const Frame = struct {
    /// 帧体字节（JSON-RPC 报文原文，不 NUL 结尾）
    body: []const u8,
    /// 整帧（含头）在缓冲中占用的字节数，调用方据此消费
    consumed: usize,
};

/// 从缓冲头部解析一帧。返回 null = 数据还不完整（调用方续读后重试）；
/// 错误 = 帧头坏了（非数字长度/超长/缺失），流已不可信。
pub fn parseFrame(buf: []const u8) ParseError!?Frame {
    const sep = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
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
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_len = std.fmt.parseInt(usize, value, 10) catch return error.InvalidFrame;
        }
    }
    const n = content_len orelse return error.InvalidFrame;
    if (n > max_frame_len) return error.FrameTooLarge;
    const start = sep + 4;
    const end = start + n;
    if (end > buf.len) return null; // 体未收全
    return .{ .body = buf[start..end], .consumed = end };
}

/// 编码一帧：`Content-Length: N\r\n\r\n` + 体（调用方 free）。
pub fn encodeFrame(gpa: std.mem.Allocator, body: []const u8) ![]const u8 {
    const hdr = try std.fmt.allocPrint(gpa, "Content-Length: {d}\r\n\r\n", .{body.len});
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
