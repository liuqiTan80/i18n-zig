//! 阶段1：httpz API 存在性验证（纯 Zig，不经方言/接缝）。
//! 每条被引用/被别名指向的 httpz 路径都在此实引用；`zig build` 编译通过＝该路径真实存在。
//! 拟译条目以本文件编译绿为准回填 contrib 叠加包（任一红＝路径不存在＝不入库）。
const std = @import("std");
const httpz = @import("httpz");

// 顶层类型/名——编译期钉住其存在（拟作 [aliases] 目标）。
const _TServer = httpz.Server(void);
const _TRequest = httpz.Request;
const _TResponse = httpz.Response;
const _TRouter = httpz.Router;
const _TUrl = httpz.Url;
const _TConfig = httpz.Config;
const _TContentType = httpz.ContentType;
const _TMethod = httpz.Method;
const _TProtocol = httpz.Protocol;

fn handler(req: *httpz.Request, res: *httpz.Response) !void {
    // Request：query()/param()/formData()
    const q = try req.query();
    _ = q.get("name");
    _ = req.param("name");
    var it = (try req.formData()).iterator();
    while (it.next()) |kv| {
        _ = kv.key;
        _ = kv.value;
    }
    // Response：body/arena/content_type/json/writer/write
    res.body = "hi";
    res.content_type = httpz.ContentType.JSON;
    res.content_type = .TEXT;
    try res.json(.{ .ok = 1 }, .{});
    const w = res.writer();
    try w.print("{s}\n", .{"x"});
    _ = res.arena;
    _ = req.method;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    // Server(void).init(io, gpa, Config{address=.localhost, request={max_form_count}}, handler)
    var server = try httpz.Server(void).init(init.io, allocator, .{
        .address = .localhost(8801),
        .request = .{ .max_form_count = 20 },
    }, {});
    defer server.deinit();
    defer server.stop();
    var router = try server.router(.{});
    // Router：get/post/put/delete/head/options/all
    router.get("/", handler, .{});
    router.post("/", handler, .{});
    router.put("/", handler, .{});
    router.delete("/", handler, .{});
    router.head("/", handler, .{});
    router.options("/", handler, .{});
    // writeMetrics(writer)
    std.debug.print("metrics: {}\n", .{@TypeOf(httpz.writeMetrics) != void});
    try server.listen();
}
