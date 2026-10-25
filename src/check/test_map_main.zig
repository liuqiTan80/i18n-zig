//! 测试映射覆盖闸（第 340 轮 D199）：把「哪个文件有测、测了多少行」变成逐轮可对账的数字。
//!
//! 为何不是行覆盖率：Zig 0.17 发行包既没有 `zig build test --coverage`，也不带 `llvm-cov`
//! （`std.Build` 只剩 `sanitize_coverage_trace_pc_guard`，那是 AFL 插桩用途）——行覆盖率这台机器
//! 在本工具链上根本不存在，硬凑只会造出一列不可复跑的假数。故取**可实装口径**：文件级测块/测行账。
//!
//! 三条闸（缺一即退化成一张没人看的表）：
//!   1. 零测文件双向对账：盘上零命名 test 块的文件必须恰等于 hub `test_zero_exempt`——新文件零测
//!      不入清单即红（292/293 轮「单文件绿≠入图绿」同族的静态侧），清单里的文件长出测也红（防空壳豁免）；
//!   2. 测块总数 ≥ hub `test_block_floor`——成片删测即红；
//!   3. test 行占比 ≥ hub `test_share_floor_permille`——「测试占了一半体量」这句话本身可退化，占比闸住它。
//!
//! 判据（`measureTestMap`）在 hub、由 hub 的 340 T0 用小样直钉；本程序只做扫目录、读盘与退出码。
//! 用法：check-test-map（构建步以 `addDirectoryArg(src)` 声明整面源码为输入依赖，故读数不吃旧树）。

const std = @import("std");
const zzc = @import("zzc_core");
const paths = zzc.paths;

fn isExempt(rel: []const u8) bool {
    for (paths.test_zero_exempt) |ex| {
        if (std.mem.eql(u8, ex, rel)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var dir = std.Io.Dir.cwd().openDir(io, paths.test_map_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("FAIL: 打不开 {s}/ 目录（{s}）——测映闸无盘可对，本步元处落地（第 340 轮 D199）\n", .{ paths.test_map_dir, @errorName(e) });
        std.process.exit(1);
    };
    defer dir.close(io);
    var walker = dir.walk(gpa) catch |e| {
        std.debug.print("FAIL: 遍历 {s}/ 失败（{s}）\n", .{ paths.test_map_dir, @errorName(e) });
        std.process.exit(1);
    };
    defer walker.deinit();

    var files: usize = 0;
    var all_lines: usize = 0;
    var all_test_lines: usize = 0;
    var all_blocks: usize = 0;
    var fails: usize = 0;

    std.debug.print("[测映闸] 文件                      行   测行   测块  占比\n", .{});
    while (walker.next(io) catch |e| {
        std.debug.print("FAIL: 读 {s}/ 目录项失败（{s}）\n", .{ paths.test_map_dir, @errorName(e) });
        std.process.exit(1);
    }) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.path, ".zig")) continue; // walk 路径相对 src/
        const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ paths.test_map_dir, ent.path });
        const src = std.Io.Dir.cwd().readFileAlloc(io, rel, gpa, .unlimited) catch |e| {
            std.debug.print("FAIL: 无法读取 {s}（{s}）\n", .{ rel, @errorName(e) });
            std.process.exit(1);
        };
        const m = paths.measureTestMap(src);
        files += 1;
        all_lines += m.lines;
        all_test_lines += m.test_lines;
        all_blocks += m.blocks;
        const permille = if (m.lines > 0) (m.test_lines * 1000) / m.lines else 0;
        std.debug.print("         {s: <28}{d: >6}{d: >7}{d: >7}{d: >6}‰\n", .{ rel, m.lines, m.test_lines, m.blocks, permille });

        if (m.blocks == 0 and !isExempt(rel)) {
            std.debug.print("FAIL: {s} 零命名 test 块而不在 hub 豁免清单——新文件静默零测入图（第 340 轮 D199）\n", .{rel});
            fails += 1;
        }
        if (m.blocks > 0 and isExempt(rel)) {
            std.debug.print("FAIL: {s} 在豁免清单却已有 {d} 枚 test 块——豁免登记成空壳，清单不再反映事实（第 340 轮 D199）\n", .{ rel, m.blocks });
            fails += 1;
        }
    }

    if (files == 0) {
        std.debug.print("FAIL: 扫到 0 枚 .zig 文件——遍历形制漂了，闸门读数不可信（第 340 轮 D199）\n", .{});
        fails += 1;
    }
    if (all_blocks < paths.test_block_floor) {
        std.debug.print("FAIL: 命名 test 块实计 {d} 枚 < hub 下限 {d}——成片删测而闸不知（增测须同抬下限）（第 340 轮 D199）\n", .{ all_blocks, paths.test_block_floor });
        fails += 1;
    }
    const share = if (all_lines > 0) (all_test_lines * 1000) / all_lines else 0;
    if (share < paths.test_share_floor_permille) {
        std.debug.print("FAIL: test 行占比 {d}‰ < hub 下限 {d}‰——测试体量被稀释到阈值下（第 340 轮 D199）\n", .{ share, paths.test_share_floor_permille });
        fails += 1;
    }

    if (fails != 0) {
        std.debug.print("FAIL：测映闸 {d} 处未过（文件 {d} 枚／测块 {d} 枚／测行 {d}／占比 {d}‰）\n", .{ fails, files, all_blocks, all_test_lines, share });
        std.process.exit(1);
    }
    std.debug.print(
        "PASS：测映闸 {d} 枚文件／{d} 行源码／test 行 {d}（占比 {d}‰，下限 {d}‰）／命名 test 块 {d} 枚（下限 {d} 枚）／零测豁免 {d} 枚双向对账相符\n",
        .{ files, all_lines, all_test_lines, share, paths.test_share_floor_permille, all_blocks, paths.test_block_floor, paths.test_zero_exempt.len },
    );
}
