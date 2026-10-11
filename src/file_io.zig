//! 基础文件 IO 薄封装：把 main.zig 进程级 readWhole/writeWhole/pathExists/readFileRaw 的
//! 核心逻辑**参数化**（`io` + `gpa` 形参注入），使其能落入 zzc_core 测试图真跑（台账 D21）。
//! 主程序侧保留同名封装绑定 `io_`/`gpa_` 全局、并把超限反馈为母语提示，调用点零改动。

const std = @import("std");
const Io = std.Io;
const translate = @import("transpiler/translate.zig");

/// 输入文件上限（台账 B5，design.md 定值 10MB；旧 spec/tasks 的 100MB 矛盾表述已统一）：
/// 超限在读取边界以 `error.SourceTooLarge` 反馈，由调用方决定如何母语提示（main 侧只打一次）。
pub const max_source_bytes: usize = 10 * 1024 * 1024;

/// 读整个文本文件并剔除起始 UTF-8 BOM；超过 `max_source_bytes` 回 `error.SourceTooLarge`。
/// 0.17 `Io.Limit` 是 enum(usize) 带载荷：有限值须经 `Limit.limited(n)` 构造，`.limited = n` 结构体初始化形不合法。
pub fn readWhole(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, Io.Limit.limited(max_source_bytes)) catch |e| switch (e) {
        error.StreamTooLong => return error.SourceTooLarge,
        else => |other| return other,
    };
    // 剔除可能的 UTF-8 BOM，避免 Windows 编辑器写入的 BOM 污染首个词元。
    return translate.stripBom(bytes);
}

/// 写整个文件（必要时先建父目录）。
pub fn writeWhole(io: Io, path: []const u8, data: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    var f = try dir.createFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = Io.File.Writer.init(f, io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

/// 判断相对当前工作目录的路径是否存在（仅用于避免覆盖，不区分文件/目录）。
pub fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// 原始字节读（**不**做 stripBom），用于拷贝资源文件（二进制安全）。
pub fn readFileRaw(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

/// 路径是否为符号链接（台账 R8）：不跟随地 stat，只认 `.sym_link` 真值。
/// 任何错误（不存在/无权限/平台不支持）一律回 false——保守不回退现状：
/// 源缺失仍由后续 readFileRaw catch-continue 交给 zig 原生报错。第 63 轮自 main.zig 下沉本模块（D7/D21 基础 IO 一致性）。
pub fn pathIsSymlink(io: Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

test "file_io 读写往返 + BOM 剥离 + pathExists + readFileRaw 保留 BOM（第 62 轮 D21 下沉真测）" {
    // 测试上下文无 std.process.Init，自建同步 Io（文件操作走调用线程、不触异步分发，故 gpa 用 page_allocator 即可）。
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const probe = ".zig-cache/zzc_fileio_probe.txt";

    // 写→读往返（无 BOM 内容原样回读）。
    try writeWhole(io, probe, "hello zzc");
    defer std.Io.Dir.cwd().deleteFile(io, probe) catch {};
    const back = try readWhole(io, gpa, probe);
    try std.testing.expectEqualStrings("hello zzc", back);

    // pathExists：已存在 true / 不存在 false。
    try std.testing.expect(pathExists(io, probe));
    try std.testing.expect(!pathExists(io, ".zig-cache/zzc_no_such_file_xyz.txt"));

    // BOM 处理不对称：readWhole 去起始 EF BB BF，readFileRaw 原样保留（二进制安全）。
    const bomded = "\xEF\xBB\xBF带BOM内容";
    try writeWhole(io, probe, bomded);
    const stripped = try readWhole(io, gpa, probe);
    try std.testing.expectEqualStrings("带BOM内容", stripped);
    const raw = try readFileRaw(io, gpa, probe);
    try std.testing.expectEqual(stripped.len + 3, raw.len);
    try std.testing.expectEqual(@as(u8, 0xEF), raw[0]);
}

test "pathIsSymlink：普通文件与不存在路径均回 false（R8 守卫假分支；第 63 轮下沉真测）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const probe = ".zig-cache/zzc_symlink_probe.txt";
    try writeWhole(io, probe, "x");
    defer std.Io.Dir.cwd().deleteFile(io, probe) catch {};

    // 普通文件不是符号链接（守 R8：非链接的合法嵌入资产不得被误拒拷贝）。
    try std.testing.expect(!pathIsSymlink(io, probe));
    // 不存在路径保守回 false（交后续 readFileRaw catch-continue 处理）。
    try std.testing.expect(!pathIsSymlink(io, ".zig-cache/zzc_no_such_link_xyz"));
    // 边界：真符号链接→true 分支需 POSIX/管理员权限造链接，Windows 环内不可靠、不在此测（同台账 R8 真链接面待验）。
}
