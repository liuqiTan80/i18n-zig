//! 落盘族 ↔ 仓根 `.gitignore` 覆盖守卫（第 202 轮 D70）：读真忽略面，核对 `zzc_paths.disk_family`
//! 全员被覆盖、且 `source_family` 全员不被误吞。用法：
//!   check-ignore-coverage [忽略面文件路径]   （缺省 `.gitignore`，构建步以文件依赖传入实际路径）
//! 判断本身（`dirIgnored`/`firstUncovered`/`firstFalselyIgnored`）全在 `zzc_paths.zig` 并由其 202 T0
//! 用小样钉住——本程序只做 I/O 与退出码，不另立第二套判据。
//! 为何不在测试图内读盘：`@embedFile("../.gitignore")` 被 zig 0.17 的 module 包路径（`src/`）拒绝
//! （`embed of file outside package path`，本轮实跑坐实），而测试内 `cwd()` 偷读的文件不入构建步骤
//! 清单——改忽略面不会触发重跑（202 t2 探针 P3 的失效形制），故跨文件覆盖只能由**声明了文件依赖**的
//! 构建步守卫（同 154/155 轮 `check-editor-syntax` 形制，已挂 `zig build test`）。

const std = @import("std");
const Io = std.Io;
const zzc = @import("zzc_core");
const paths = zzc.paths;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    const rules_path = if (args.len >= 2) args[1] else ".gitignore";

    const rules = std.Io.Dir.cwd().readFileAlloc(io, rules_path, gpa, .unlimited) catch |e| {
        std.debug.print("FAIL: 无法读取忽略面 {s}（{s}）\n", .{ rules_path, @errorName(e) });
        std.process.exit(1);
    };
    defer gpa.free(rules);

    if (paths.firstUncovered(rules)) |missing| {
        std.debug.print(
            "FAIL: 落盘族成员 {s} 未被 {s} 的任何目录规则覆盖——我方产物会出现在 `git status` 里、易被误提交。" ++
                " 请在忽略面补目录条目，或同步修订 zzc_paths.disk_family。\n",
            .{ missing, rules_path },
        );
        std.process.exit(1);
    }
    if (paths.firstFalselyIgnored(rules)) |swallowed| {
        std.debug.print(
            "FAIL: 源码成员 {s} 被 {s} 的目录规则误吞——该目录下的源码将不再入库。\n",
            .{ swallowed, rules_path },
        );
        std.process.exit(1);
    }

    std.debug.print("OK: {s} 覆盖落盘族 {d} 枚成员且未误吞源码面\n", .{ rules_path, paths.disk_family.len });
}
