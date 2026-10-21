//! 构建期语言包注册表生成器（第 260 轮 D126）：把「生成 pack_registry.zig」从 build.zig 求值期
//! 内联迁到独立 run 步——本程序由 `zig build` 作为构建工具执行，读取各包文件、调用单源生成内核
//! （`src/lang/pack_discover.zig`），把注册表源码写到指定输出路径。
//!
//! 为何走 run 步：run 步经 `addFileArg` 声明每个包文件为输入依赖，其内容哈希计入步骤缓存键——
//! **仅改包 .txt 内容即 cache miss、重跑本生成器、产出新鲜内联字节**，根治旧形制「改包不触发
//! build.zig 重跑、内联字节长期陈旧」（台账 D45/R9f 假绿形）。
//!
//! 用法（由 build.zig 自动调用）：`gen-pack-registry <输出路径> <包文件1> [<包文件2> ...]`
//!   - 参数顺序即 build.zig 里 `addOutputFileArg` 先、`addFileArg` 逐包后的调用顺序；
//!   - 路径相对本进程 cwd 打开/写入（与 gen-tmlang 同一 build 工具口径）。
//! 生成确定性由内核按文件名字典序排序保证，与 argv 顺序无关。

const std = @import("std");
const Io = std.Io;
const discover = @import("pack_discover"); // 由 build.zig 作具名模块注入（@import 不能跨模块路径）

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) {
        std.debug.print("用法: gen-pack-registry <输出路径> <包文件...>\n", .{});
        std.process.exit(1);
    }
    const out_path = args[1];
    const pack_paths = args[2..];

    var files: std.ArrayList(discover.PackFile) = .empty;
    for (pack_paths) |p| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .unlimited) catch |e| {
            std.debug.print("无法读取语言包 {s}（{s}）\n", .{ p, @errorName(e) });
            std.process.exit(1);
        };
        files.append(gpa, .{ .name = std.fs.path.basename(p), .bytes = bytes }) catch {
            std.debug.print("OOM\n", .{});
            std.process.exit(1);
        };
    }

    const source = discover.generateRegistrySource(gpa, files.items) catch |e| {
        std.debug.print("生成语言包注册表失败（{s}）\n", .{@errorName(e)});
        std.process.exit(1);
    };

    // 写到输出路径（相对 cwd；其父目录由本程序确保存在——run 步输出常落在 zig-cache 子目录）。
    const dir = std.Io.Dir.cwd();
    if (std.fs.path.dirname(out_path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    var f = try dir.createFile(io, out_path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = Io.File.Writer.init(f, io, &buf);
    try w.interface.writeAll(source);
    try w.interface.flush();
}
