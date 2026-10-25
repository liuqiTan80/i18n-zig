//! 翻译吞吐基准（第 340 轮 D199）：给「改写一遍要多少钱」一个逐轮同坐标的读数。
//!
//! 为何要独立成一步而不是塞进测试图：测试图的断言只问「对不对」，从不问「多快」；而性能退化
//! （多写一层 O(n²) 扫描、每行重扫全表）在正确性上完全隐形。本步固定语料、固定档位，把墙钟
//! 读数打成数字：`每千行毫秒`（主读数）+ `KiB/s`（副读数），并按 hub 的 `bench_ms_per_kilo_ceiling`
//! 做**量级闸**——它不追微优化，只拦十倍级退化（阈值取实测的量级余量，故不因负载抖动假红）。
//!
//! 两条不可比性来源已被排除（改任一条读数就失去纵向可比，须连同台账说明同动）：
//!   1. 档位：本 exe 恒以 `ReleaseSafe` 构建，不随 `-Doptimize` 漂（Debug 与 Release 差一个量级）；
//!   2. 语料：单位模板与单位数皆 hub 单源（`bench_unit_fmt`／`bench_units`），且模板带 `{d}`
//!      序号——每单位标识符互不相同，防同形重复被跳同优化拉低读数而虚报性能。
//!
//! 用法：check-bench（无实参；语料在内存合成，不落盘、不碰工作树）。

const std = @import("std");
const zzc = @import("zzc_core");
const paths = zzc.paths;
const Pack = zzc.Pack;
const Mangle = zzc.Mangle;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var lang = Pack.parse(gpa, zzc.zh_pack_bytes) catch |e| {
        std.debug.print("FAIL: 内置默认包解析失败（{s}）——基准无语言可译\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // —— 语料构造（**不计时**：计时区只含改写主路，否则 allocPrint 的成本混进读数）——
    const lines_total = paths.bench_units * paths.bench_unit_lines;
    var corpus: std.ArrayList(u8) = .empty;
    for (0..paths.bench_units) |i| {
        const unit = try std.fmt.allocPrint(gpa, paths.bench_unit_fmt, .{i});
        try corpus.appendSlice(gpa, unit);
    }
    const src = try corpus.toOwnedSlice(gpa);

    // —— 计时区 ——
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const res = try zzc.translate.translate(gpa, src, lang, &table);
    const dur = std.Io.Clock.Timestamp.durationTo(t0, std.Io.Clock.Timestamp.now(io, .awake));
    const ns: i128 = dur.raw.nanoseconds;

    // 极性闸（先于速度闸）：语料是**纯母语**（零 ASCII 字母），产物必须含 ASCII 字母且不得短于行数——
    // 否则「返回原文/空串」这类空转也能跑出漂亮的墙钟读数，基准就成了自欺（产物比语料短是正常的：
    // 多字节关键词被映射成更短的 ASCII，本轮实测 286890 → 244899 字节）。
    var native_letters: usize = 0;
    for (src) |c| {
        if (std.ascii.isAlphabetic(c)) native_letters += 1;
    }
    var out_letters: usize = 0;
    for (res.zig_str) |c| {
        if (std.ascii.isAlphabetic(c)) out_letters += 1;
    }
    if (native_letters != 0 or out_letters == 0 or res.zig_str.len < lines_total) {
        std.debug.print(
            "FAIL: 语料含 ASCII 字母 {d} 枚（应为 0）而产物含 {d} 枚／产物 {d} 字节——改写主路疑似空转，读数不可信（第 340 轮 D199）\n",
            .{ native_letters, out_letters, res.zig_str.len },
        );
        std.process.exit(1);
    }

    const ns_per_kilo: i128 = @divTrunc(ns * 1000, lines_total); // 每千行的纳秒数
    const ms_per_kilo: i128 = @divTrunc(ns_per_kilo, std.time.ns_per_ms);
    const tenth: i128 = @mod(@divTrunc(ns_per_kilo, 100_000), 10); // 一位小数
    const kib_per_s: i128 = @divTrunc(@as(i128, @intCast(src.len)) * std.time.ns_per_s, ns * 1024);

    std.debug.print(
        "[基准] 语料 {d} 行／{d} 字节，改写耗时 {d}.{d} ms／千行（总 {d} ms，{d} KiB/s）；产物 {d} 字节；每千行上限 {d} ms\n",
        .{ lines_total, src.len, ms_per_kilo, tenth, @divTrunc(ns, std.time.ns_per_ms), kib_per_s, res.zig_str.len, @as(usize, paths.bench_ms_per_kilo_ceiling) },
    );
    // 速度闸以**纳秒**比大小、不以 `ms_per_kilo` 比：本轮实读数为 0.9 ms／千行，截断成整数毫秒即 0——
    // 拿截断值去比，则「上限=0」这类收紧也咬不着空转（第 340 轮演漂 M5 实测暴露：上限归零仍 PASS）。
    // 展示值仍用一位小数（`tenth`），只有判据走 `ns_per_kilo` 的原始精度。
    const ceiling_ns: i128 = @as(i128, @intCast(paths.bench_ms_per_kilo_ceiling)) * std.time.ns_per_ms;
    if (ns_per_kilo > ceiling_ns) {
        std.debug.print(
            "FAIL: 每千行 {d}.{d} ms 越过上限 {d} ms——上限是量级闸（只拦十倍级退化），越线即改写主路多了数量级的重复工作（第 340 轮 D199）\n",
            .{ ms_per_kilo, tenth, @as(usize, paths.bench_ms_per_kilo_ceiling) },
        );
        std.process.exit(1);
    }
    std.debug.print("PASS：翻译吞吐基准在闸内（语料规模与档位由 hub 单源，读数可与历轮纵向对拍）\n", .{});
}
