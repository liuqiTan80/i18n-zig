//! 仅测用构件（第 196 轮）：测内盘上产物的**私有路径**构造器——不被生产码引用。
//!
//! 为什么要有这个东西（台账 D62）：全仓测块历来把盘上工作路径写成编译期固定的字面量
//! （`.zig-cache/zzc_fileio_probe.txt`、`/tmp/zzc193-t`、`.zig-cache/userpack_test_140`……），
//! 而 `zig build test` 一次并发跑**两个测试图**（core 图 root.zig + main 图 main.zig），凡在
//! 两图里都存在的测块就有两份**同名同径**的产物在并发读写；同一测试二进制被并跑（手工重跑、
//! CI 与本机构建交叠、压力自验）时更甚。测块里的「帧首回清」与「defer 回清」在这种局面下删的
//! 是**别人正在用的文件**，于是出现「串行恒绿、偶发就红」的间歇假红——排查时人人先怀疑被测逻辑，
//! 实际缺陷在测试自己的盘上形制。
//!
//! 本机实锤（第 196 轮探针：同一测试二进制串行 vs 24 路并跑各 3 轮）：core 图 71/72 红、main 图
//! 68/72 红，失败点名恰是这些共享固定路径的测块（`file_io` 七块报 `error.FileNotFound`、
//! `lang.userpack.install`、main 图 `stageEmbedAssets`/`loadSymbols`/`saveSymbols` 等），而同
//! 二进制串行复跑恒绿。
//!
//! 本构件落位后的同法复跑（修复后实据）：core 图 **0/24 红**、main 图 20/24 红而残红点名全属把路径
//! 硬编在**生产码**里的 `.zzc/symbols.txt` / `logs/untranslated_phrases.json` 族（只存于 main 图，仅在同
//! 一二进制被并跑时才互踩）；常规形制（core 图 + main 图各一份、60 对）复跑 **0/120 红**。**第 198 轮
//! D66 已把那最后一族收口**：生产侧把落盘路径做成进程级可覆写变量 seam（`main.symbols_path`/
//! `main.untranslated_log_path`，默认值一字未改），191 T2/192 T1/194 T1 遂能各写自己的私有径——同法复跑
//! main 图 24 路 **0/72 红**（修复前基线实测 68/72 红）、12 路 **0/36 红**（基线 11/12）。
//!
//! 本构件把「路径必须私有」做成一句可复用形制：一次 `init` 取随机字节作 8 位十六进制后缀，同一
//! 次 `init` 的结果供该测块所有路径拼装（同块内稳定、跨块跨进程几乎不可能相同），于是每个测块、
//! 每个进程各占一处目录，帧首/帧尾回清只可能删到自己。落点**沿用各测块既有前缀**而不另立标准：
//! core 图（本文件、`file_io`、`lang/userpack`）落在 `.zig-cache/tmp/` 下（相对 cwd，与
//! `std.testing.tmpDir` 同址同法——标准库自己就把测内临时目录建在那里，且本机实测 `zig build` +
//! 2×`zig build test` 序列不回收其下文件），main 图（188/190/191/192/193/194）沿用其既有的绝对
//! `/tmp/` 前缀——那些块的形制依赖绝对路径（`createFileAbsolute`/`deleteFileAbsolute` 内部
//! `assert(isAbsolute)`、LSP 的 `file:///tmp/...` URI 入参），迁移只动「固定名 → 私有名」这一维、
//! 把改动面收到最小。附带契约：私有名把「固定名覆盖」换成了「每跑一枚新名」，故块尾回清**必须齐备**，
//! 否则由并发互踩转为盘上累积（第 196 轮尾注自捕：191/192 两块曾漏 `deleteFileAbsolute` 回清）。

const std = @import("std");
const Io = std.Io;
const file_io = @import("file_io.zig"); // 仅供本文件测块落盘自验用

/// 随机后缀的字符数（4 字节 → 8 位十六进制）。
pub const tok_len: usize = 8;

const hex_digits = "0123456789abcdef";

pub const Priv = struct {
    tok: [tok_len]u8,

    /// 取一次随机作私有后缀。刻意**不**用进程号/时间戳：进程号在并跑时相邻可撞、时间戳在同一
    /// 时钟刻度内可撞，随机字节对「同一次构建里并跑的若干份同一测块」最稳。
    pub fn init(io: Io) Priv {
        var rb: [4]u8 = undefined;
        std.Io.random(io, &rb);
        var tok: [tok_len]u8 = undefined;
        for (rb, 0..) |b, i| {
            tok[i * 2] = hex_digits[b >> 4];
            tok[i * 2 + 1] = hex_digits[b & 0x0f];
        }
        return .{ .tok = tok };
    }

    /// 后缀切片的显式返回形（`{s}` 格式化的入参须是 `[]const u8`，不让调用点各次猜测）。
    pub fn token(self: *const Priv) []const u8 {
        return &self.tok;
    }

    /// 拼 `<prefix><tok><tail>` 到调用方缓冲并返回其切片；`tail` 多以 `/` 起（或为空）。
    /// 随机后缀落在中段，故同一 `Priv` 可派生同目录下任意多个子路径而彼此不逃逸。
    /// 缓冲不足即 `@panic`——各测块缓冲由本轮一次给到富余值，不设可测溢出臂。
    pub fn path(self: *const Priv, buf: []u8, comptime prefix: []const u8, comptime tail: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, prefix ++ "{s}" ++ tail, .{self.token()}) catch
            @panic("Priv.path 缓冲不足（D62 测内私有路径）");
    }
};

// ---------------------------------------------------------------- 测试

test "第 196 轮 T1 Priv 私有路径构件：后缀随机非固定 + 十六进制形制 + 三段拼接位序 + 异径互不踩/回清只删自己" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A1 唯一性：连续两次 init 的后缀必不相等（把随机换成常量即此处红——D62 的根判据）。
    const p1 = Priv.init(io);
    const p2 = Priv.init(io);
    try std.testing.expectEqual(tok_len, p1.tok.len);
    try std.testing.expect(!std.mem.eql(u8, p1.token(), p2.token()));

    // A2 字符集形制：每一位都属十六进制小写字母/数字。判据刻意用**字面量集**而不复用 `hex_digits`——
    //   复用则生成表怎么改都自洽（变异表为全大写时本钉仍绿，第 196 轮 t3 变异 S3 现形的自证循环），
    //   写死字面量才能钉住「后缀形制对下游glob/大小写敏感面是契约」这一意图。
    for (p1.token()) |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, "0123456789abcdef", c) != null);
    }

    // A3 三段拼接位序：前缀—后缀—尾段各就各位（拼序错位或漏拼一段即红）。
    var b1: [96]u8 = undefined;
    const pre = ".zig-cache/tmp/zzc196-";
    const got = p1.path(&b1, pre, "/probe.txt");
    try std.testing.expectEqualStrings(pre, got[0..pre.len]);
    try std.testing.expectEqualStrings(p1.token(), got[pre.len .. pre.len + tok_len]);
    try std.testing.expectEqualStrings("/probe.txt", got[got.len - "/probe.txt".len ..]);

    // A4 异径互不踩（本构件的正题钉）：两处私有目录写**同名**文件、内容各自独立——后缀若被
    //   固定化则两径合一，第二次写覆盖第一次，此处立刻红（正是 24 路并跑互踩的最小复现形）。
    var bd1: [96]u8 = undefined;
    var bd2: [96]u8 = undefined;
    var bf1: [96]u8 = undefined;
    var bf2: [96]u8 = undefined;
    const dirpre = ".zig-cache/tmp/zzc196-d62-";
    const d1 = p1.path(&bd1, dirpre, "");
    const d2 = p2.path(&bd2, dirpre, "");
    const f1 = p1.path(&bf1, dirpre, "/same.txt");
    const f2 = p2.path(&bf2, dirpre, "/same.txt");
    std.Io.Dir.cwd().deleteTree(io, d1) catch {};
    std.Io.Dir.cwd().deleteTree(io, d2) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, d1) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, d2) catch {};
    try file_io.writeWhole(io, f1, "甲");
    try file_io.writeWhole(io, f2, "乙");
    const gpa = std.testing.allocator;
    const r1 = try file_io.readWhole(io, gpa, f1);
    defer gpa.free(r1);
    const r2 = try file_io.readWhole(io, gpa, f2);
    defer gpa.free(r2);
    try std.testing.expectEqualStrings("甲", r1);
    try std.testing.expectEqualStrings("乙", r2);

    // A5 回清只删自己：整树清掉 p1 的目录后，p1 路径不可读而 p2 路径仍可读。
    std.Io.Dir.cwd().deleteTree(io, d1) catch {};
    try std.testing.expect(!file_io.pathExists(io, f1));
    try std.testing.expect(file_io.pathExists(io, f2));
}
