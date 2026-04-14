//! 工具链版本族 ↔ 本仓 `build.zig.zon` 与 CI 安装版本守卫（第 205 轮 D73）：读两枚对面文件，
//! 核对它们声明/安装的版本仍等于 `zzc_paths` 的族真值。用法：
//!   check-toolchain-baseline [zon 路径] [CI 工作流路径]
//!   （缺省 `build.zig.zon` 与 `.gitcode/workflows/ci.yml`，构建步以文件依赖传入实际路径）
//! 判断本身（`minimumZigVersionIn`/`zonDeclaresBaseline`/`ciInstallsBaseline`）全在 `zzc_paths.zig`
//! 并由其 205 T0 用小样钉住——本程序只做 I/O 与退出码，不另立第二套判据。
//! 为何不在测试图内读盘：`@embedFile` 受 zig 0.17 的 module 包路径（`src/`）限制不可越（202 轮硬约束），
//! 而测试内 `cwd()` 偷读的文件不入构建步骤清单——205 t2 探针 P3 实锤「改本仓 zon 而 522/522 全绿」的
//! 假绿形制，故跨文件覆盖由**声明了文件依赖**的本守卫步承担（同 154/155/202/203 轮形制，已挂 `test`）。

const std = @import("std");
const zzc_core = @import("zzc_core");
const paths = zzc_core.paths;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    const zon_path = if (args.len >= 2) args[1] else "build.zig.zon";
    const ci_path = if (args.len >= 3) args[2] else ".gitcode/workflows/ci.yml";

    const zon = std.Io.Dir.cwd().readFileAlloc(io, zon_path, gpa, .unlimited) catch |e| {
        std.debug.print("FAIL: 无法读取 {s}（{s}）\n", .{ zon_path, @errorName(e) });
        std.process.exit(1);
    };
    defer gpa.free(zon);
    if (!paths.zonDeclaresBaseline(zon)) {
        const got = paths.minimumZigVersionIn(zon) orelse "（字段缺失或非字符串形）";
        std.debug.print(
            "FAIL: {s} 声明的 .minimum_zig_version 是 {s}，与工具链族真值 {s}（zzc_paths.zig）不符——" ++
                "本仓标定与仓根声明分道，`zig build` 不会警告。请两处同改。\n",
            .{ zon_path, got, paths.zig_version },
        );
        std.process.exit(1);
    }

    const ci = std.Io.Dir.cwd().readFileAlloc(io, ci_path, gpa, .unlimited) catch |e| {
        std.debug.print("FAIL: 无法读取 {s}（{s}）\n", .{ ci_path, @errorName(e) });
        std.process.exit(1);
    };
    defer gpa.free(ci);
    if (!paths.ciInstallsBaseline(ci)) {
        std.debug.print(
            "FAIL: {s} 未按 download/{s}/ 安装 zig——CI 跑的工具链与族真值 {s} 不同代，回译标定早警在 CI 上失真。" ++
                " 请同步 CI 的版本号。\n",
            .{ ci_path, paths.zig_version, paths.zig_version },
        );
        std.process.exit(1);
    }

    std.debug.print("OK: {s} 与 {s} 均与工具链族真值 {s} 同源\n", .{ zon_path, ci_path, paths.zig_version });
}
