//! 基础文件 IO 薄封装：把 main.zig 进程级 readWhole/writeWhole/pathExists/readFileRaw 的
//! 核心逻辑**参数化**（`io` + `gpa` 形参注入），使其能落入 zzc_core 测试图真跑（台账 D21）。
//! 主程序侧保留同名封装绑定 `io_`/`gpa_` 全局、并把超限反馈为母语提示，调用点零改动。

const std = @import("std");
const Io = std.Io;
const translate = @import("transpiler/translate.zig");

/// 输入文件上限（台账 B5，design.md 定值 10MB；旧 spec/tasks 的 100MB 矛盾表述已统一）：
/// 超限在读取边界以 `error.SourceTooLarge` 反馈，由调用方决定如何母语提示（main 侧只打一次）。
pub const max_source_bytes: usize = 10 * 1024 * 1024;

/// 读整个文本文件并剔除起始 UTF-8 BOM；超过 `max_source_bytes` 回 `error.SourceTooLarge`、
/// 非 UTF-8 字节流（UTF-16/GBK 等错编码保存）回 `error.InvalidEncoding`（均由调用方母语提示）。
/// 0.17 `Io.Limit` 是 enum(usize) 带载荷：有限值须经 `Limit.limited(n)` 构造，`.limited = n` 结构体初始化形不合法。
pub fn readWhole(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, Io.Limit.limited(max_source_bytes)) catch |e| switch (e) {
        error.StreamTooLong => return error.SourceTooLarge,
        else => |other| return other,
    };
    // 编码封口（D31）：错编码保存（记事本 UTF-16 LE/老编辑器 GBK）是母语工程事故率最高的现场之一：
    // 旧边界只剔 UTF-8 BOM、其余坏字节照单放行——方言词形按字节必不匹配 UTF-8 语言包，声明半消失，
    // 用户拿到与真因无关的误导性语法错。UTF-16 BOM（FF FE/FE FF）与 GBK 实字节皆非法 UTF-8 序列，
    // 单个 utf8ValidateSlice 一并封口；合法含 BOM 的 UTF-8 照过、交 stripBom。二进制安全面在
    // readFileRaw（资源拷贝）不受本封口影响。
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidEncoding;
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

test "readWhole 编码封口（D31）：UTF-16 BOM 与非法 UTF-8 字节拒为 InvalidEncoding、readFileRaw 不受影响" {
    // 缺陷面：错编码保存（记事本“Unicode UTF-16 LE”/国内老编辑器 GBK）是母语工程事故率最高的
    // 现场之一：旧边界只对 UTF-8 BOM 剔除、其余坏字节照单放行→方言词形按字节必不匹配 UTF-8
    // 语言包→声明半消失→用户拿到与真因无关的误导性语法错，拿不到“存为 UTF-8”指引。
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const probe = ".zig-cache/zzc_fileio_enc_probe.txt";
    try writeWhole(io, probe, "占位");
    defer std.Io.Dir.cwd().deleteFile(io, probe) catch {};

    // ① UTF-16 LE BOM（FF FE）：整文件多为非法 UTF-8，起始 BOM 即精确判据，拒。
    try writeWhole(io, probe, "\xFF\xFE\x00\x5E");
    try std.testing.expectError(error.InvalidEncoding, readWhole(io, gpa, probe));
    // ② UTF-16 BE BOM（FE FF）：同理拒（FE 后跟非 BB 的字节也不是合法 UTF-8 序列）。
    try writeWhole(io, probe, "\xFE\xFF\x5E\x00");
    try std.testing.expectError(error.InvalidEncoding, readWhole(io, gpa, probe));
    // ③ 无 BOM 的 GBK 实字节（“常数”= B3 A3 CA FD）：非法 UTF-8，拒。
    try writeWhole(io, probe, "\xB3\xA3\xCA\xFD x = 1;");
    try std.testing.expectError(error.InvalidEncoding, readWhole(io, gpa, probe));
    // ④ 对照：合法 UTF-8（含/不含 EF BB BF BOM）照过——封口不得误伤现有链路（demos 护栏）。
    try writeWhole(io, probe, "\xEF\xBB\xBF常数 = 1;\n");
    const ok_bom = try readWhole(io, gpa, probe);
    try std.testing.expectEqualStrings("常数 = 1;\n", ok_bom);
    // 二进制安全面：资源拷贝路径 readFileRaw 不校编码，非法字节原样回（勿误伤大资源/二进制资产）。
    try writeWhole(io, probe, "\xB3\xA3");
    const raw_ok = try readFileRaw(io, gpa, probe);
    try std.testing.expectEqual(@as(usize, 2), raw_ok.len);
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
