//! 基础文件 IO 薄封装：把 main.zig 进程级 readWhole/writeWhole/pathExists/readFileRaw 的
//! 核心逻辑**参数化**（`io` + `gpa` 形参注入），使其能落入 zzc_core 测试图真跑（台账 D21）。
//! 主程序侧保留同名封装绑定 `io_`/`gpa_` 全局、并把超限反馈为母语提示，调用点零改动。

const std = @import("std");
const builtin = @import("builtin");
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
    // D37（第 85 轮）：拒绝前必须回收 gpa 所有权缓冲——错误以值返回、调用方拿不到指针，
    // 不 free 即每拒一块坏编码文件泄一块（产品主链走 arena 被末段回收掩盖、直调方必泄）。
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        gpa.free(bytes);
        return error.InvalidEncoding;
    }
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

/// 原子写整个文件（D130）：先写同目录的临时文件，再 rename 覆盖目标。
/// 符号表是跨会话稳定的母语名→ASCII 名映射；旧形制直接 createFile 覆盖，写入中途崩溃
/// 或两进程并发会把文件留成半截，下次 parseSymbolText 丢映射甚至撞号。`createFileAtomic`
/// 的临时文件与 `replace` 的改名由 std 在 Windows/POSIX 上各自落到原子原语；失败时
/// `deinit` 清理临时文件、旧目标原样保留。
pub fn writeWholeAtomic(io: Io, path: []const u8, data: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    var af = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var buf: [4096]u8 = undefined;
    var w = af.file.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
    try af.file.sync(io); // 先落盘再改名：崩溃时目标要么旧完整、要么新完整
    try af.replace(io);
}

/// 判断相对当前工作目录的路径是否存在（仅用于避免覆盖，不区分文件/目录）。
/// 删单个文件（第 330 轮 D189）：`lang remove` 要撤掉已装用户包。不做存在性判断——「本来
/// 就没有」由调用方按语义翻成母语（`error.FileNotFound` 在 userpack 层已提前挡成 NotInstalled）。
pub fn delFile(io: Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(io, path);
}

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

// 测内私有路径构件（第 196 轮 D62）：本文件测块的盘上产物一律落到带随机后缀的私有目录下——
// 编译期固定的同径名在 `zig build test` 并发跑两测试图（同一测块被两图各跑一份）时会互删
// 对方正在读写的文件，表现为「串行恒绿、偶发红」的间歇假红（机理与实锤数见 src/test_priv.zig 头注）。
const tpriv = @import("test_priv.zig");

test "file_io 读写往返 + BOM 剥离 + pathExists + readFileRaw 保留 BOM（第 62 轮 D21 下沉真测）" {
    // 测试上下文无 std.process.Init，自建同步 Io（文件操作走调用线程、不触异步分发，故 gpa 用 page_allocator 即可）。
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const priv = tpriv.Priv.init(io); // D62：同径名改私有
    var pb: [96]u8 = undefined;
    const pre = ".zig-cache/tmp/zzc_fileio_";
    const probe = priv.path(&pb, pre, "_probe.txt");

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

    const priv = tpriv.Priv.init(io); // D62：同径名改私有
    var pb: [96]u8 = undefined;
    const probe = priv.path(&pb, ".zig-cache/tmp/zzc_fileio_", "_enc_probe.txt");
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

    const priv = tpriv.Priv.init(io); // D62：同径名改私有
    var pb: [96]u8 = undefined;
    var nb: [96]u8 = undefined;
    const probe = priv.path(&pb, ".zig-cache/tmp/zzc_", "symlink_probe.txt");
    const absent = priv.path(&nb, ".zig-cache/tmp/zzc_", "no_such_link_xyz");
    try writeWhole(io, probe, "x");
    defer std.Io.Dir.cwd().deleteFile(io, probe) catch {};

    // 普通文件不是符号链接（守 R8：非链接的合法嵌入资产不得被误拒拷贝）。
    try std.testing.expect(!pathIsSymlink(io, probe));
    // 不存在路径保守回 false（交后续 readFileRaw catch-continue 处理）。
    try std.testing.expect(!pathIsSymlink(io, absent));
    // 真符号链接→true 分支系 POSIX 面：另见下方「pathIsSymlink 真链接」平台门控测（第 177 轮消台账 R8 真链接面待验）。
}

// 护栏（第 177 轮·消台账 R8「真链接→true 分支待验」）：上方测仅钉 pathIsSymlink 的两条**假分支**
// （普通文件 / 不存在路径）；`.sym_link == true` 这条**正分支**历轮因「Windows 非管理员建链接不可靠」
// 而挂起为待验——恰是 stageEmbedAssets 拒拷「树内链接指向树外」赖以生效的判据，全仓零 fired。
// 本环境为 POSIX：以平台门控（Windows 早退、ubuntu CI 矩阵真跑）建**真实符号链接**永久锁死该支。
// load-bearing 反证：把 statFile 的 `follow_symlinks = false` 误改为 `true` → 跟随链接见其目标（普通文件）
// → kind 不为 .sym_link → 本测 `expect(true)` 即红（证本测确实钉的是「不跟随地认出链接本体」这一语义、非空跑）。
test "pathIsSymlink：POSIX 真符号链接→true（链接指向文件/目录/悬空皆 .sym_link；目标本体为假；R8 真链接面）" {
    if (builtin.os.tag == .windows) return; // 非管理员建链接不可靠——跳过以保 windows CI 矩阵绿
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const priv = tpriv.Priv.init(io); // D62：同径名改私有（七条子路径各占一段缓冲）
    const pre = ".zig-cache/tmp/zzc_r177_";
    var bb: [96]u8 = undefined;
    var bt: [96]u8 = undefined;
    var blf: [96]u8 = undefined;
    var bld: [96]u8 = undefined;
    var bldang: [96]u8 = undefined;
    var bdang: [96]u8 = undefined;
    var bdir: [96]u8 = undefined;
    const base = priv.path(&bb, pre, "");
    const target = priv.path(&bt, pre, "/real.txt"); // 工程内真实文件（链接目标）
    const link_file = priv.path(&blf, pre, "/link_to_file"); // 指向上面真实文件的链接
    const link_dir = priv.path(&bld, pre, "/link_to_dir"); // 指向目录的链接（main.zig「树内链接指向树外」最危险形）
    const link_dangling = priv.path(&bldang, pre, "/link_dangling"); // 悬空链接（目标不存在仍应是 .sym_link）
    const dir_target = priv.path(&bdir, pre, "/adir");

    // 清历史残留，使前置确定性成立。
    cwd.deleteFile(io, link_file) catch {};
    cwd.deleteFile(io, link_dir) catch {};
    cwd.deleteFile(io, link_dangling) catch {};
    cwd.deleteTree(io, dir_target) catch {};
    cwd.deleteFile(io, target) catch {};
    cwd.deleteTree(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    try writeWhole(io, target, "real"); // 建目录 + 真实文件
    try cwd.createDirPath(io, dir_target);

    // ① 指向文件的链接 → pathIsSymlink true（正分支首次 fired）。
    try cwd.symLink(io, target, link_file, .{});
    try std.testing.expect(pathIsSymlink(io, link_file));
    // ② 链接的**目标本体**（普通文件）仍为 false——证判据认的是「这个路径本身是不是链接」，
    //    非「路径是否可达文件」；误把 follow_symlinks=true 时 link_file 会被读成 real.txt→false。
    try std.testing.expect(!pathIsSymlink(io, target));
    // ③ 指向目录的链接 → true（main 的拒拷守卫正是要拦这一「树内链接指向树外」形）。
    try cwd.symLink(io, dir_target, link_dir, .{ .is_directory = true });
    try std.testing.expect(pathIsSymlink(io, link_dir));
    // ④ 悬空链接（目标不存在）→ 仍 true：`follow_symlinks=false` 的 lstat 只认链接元数据、
    //    不要求目标存在；这条钉死「不存在路径保守回 false」与「链接指向不存在回 true」的边界分野。
    try cwd.symLink(io, priv.path(&bdang, pre, "/no_such_target"), link_dangling, .{});
    try std.testing.expect(pathIsSymlink(io, link_dangling));
}

test "D37：readWhole 编码封口错误路径不泄已分配缓冲（裸 testing.allocator 直调·不 arena 包裹）" {
    // 缺陷面：readFileAlloc 成功后、封口失败前无任何登记释放——gpa 所有权缓冲对调用方不可达，
    // 每次被拒的坏编码文件泄一块（D22/D27/D29 泄漏族·错误路径形）。历轮测 gpa 皆 arena-over-
    // testing 包裹、leak 被 arena 吞掉——同 D27 先例「产品走 arena、测清一色 arena 包裹致漏未暴」。
    // 本测 gpa 直喂裸 testing.allocator：错误路径未 free 即报 leaked（先红）、free 后转绿。
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const priv = tpriv.Priv.init(io); // D62：同径名改私有
    var pb: [96]u8 = undefined;
    const probe = priv.path(&pb, ".zig-cache/tmp/zzc_fileio_", "_leak_probe.txt");
    try writeWhole(io, probe, "\xB3\xA3"); // GBK 实字节、非法 UTF-8
    defer std.Io.Dir.cwd().deleteFile(io, probe) catch {};

    // ① 错误路径：拒绝必须自行回收缓冲（leak 检查在测试结束自动触发）。
    try std.testing.expectError(error.InvalidEncoding, readWhole(io, std.testing.allocator, probe));

    // ② 成功路径对照：所有权交调用方、显式 free 不泄——封口修复不得误改成双重释放。
    try writeWhole(io, probe, "合法 utf8 内容");
    const ok = try readWhole(io, std.testing.allocator, probe);
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("合法 utf8 内容", ok);
}

// 护栏（第 122 轮证伪落位）：readWhole 的超限封口 error.SourceTooLarge（L18 `error.StreamTooLong` 转换臂）
// 此前零测——头注 L9-11 明文承诺「超过 max_source_bytes（10MB）在读取边界以 error.SourceTooLarge 反馈」，
// 但无任何测构造超限文件 fired 该分支。此支 load-bearing：readFileRaw 用 .unlimited，若 readWhole 的
// `Io.Limit.limited(max_source_bytes)` 被误抄成 `.unlimited` → 超限源静默全量读入（内存失控）而非以母语提示拒；
// 若删 switch 的 StreamTooLong 转换臂 → 裸 Zig StreamTooLong 上抛、main 侧按 SourceTooLarge 的母语映射失配。
test "readWhole 超限封口（B5/max_source_bytes）：限内放行、超限 1 字节即拒为 SourceTooLarge（非静默全读、非裸 StreamTooLong，第 122 轮证伪落位）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const priv = tpriv.Priv.init(io); // D62：同径名改私有
    var pb: [96]u8 = undefined;
    const probe = priv.path(&pb, ".zig-cache/tmp/zzc_fileio_", "_size_probe.txt");
    defer std.Io.Dir.cwd().deleteFile(io, probe) catch {};

    // ① 恰在限内（max_source_bytes - 1）：正常读取、内容等长（证 .limited 不误拦边界内）。
    const ok = try gpa.alloc(u8, max_source_bytes - 1);
    defer gpa.free(ok);
    @memset(ok, 'x');
    try writeWhole(io, probe, ok);
    const read_ok = try readWhole(io, gpa, probe);
    try std.testing.expectEqual(max_source_bytes - 1, read_ok.len);

    // ② 超 1 字节（max_source_bytes + 1）：读取边界拒为 error.SourceTooLarge。误改 .unlimited → 此处会成功读回而红。
    const big = try gpa.alloc(u8, max_source_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'x');
    try writeWhole(io, probe, big);
    try std.testing.expectError(error.SourceTooLarge, readWhole(io, gpa, probe));
}

// 护栏（第 129 轮证伪落位）：两条头注声明面此前零真 fired 直钉——
// ① writeWhole L36「必要时先建父目录」：既有全部测 probe 父目录恒为 `.zig-cache/`（zig build
//   先于 test 必然已建），createDirPath 只走幂等已存在臂；「父目录缺失→真建」与多级嵌套
//   语义零钉——删建目录调用/误写单级形，既有测无一能红（生产链 main 的 .zzc/bin 与 init 名
//   恰是多级真需求）。② pathExists L50「不区分文件/目录」：既有断言只碰文件与不存在路径，
//   目录形回 true 零钉——后人「改进」为只检文件即 init 防覆盖/eject 已存在目录判定静默回退。
// test 内不可写 doc 注释，声明以 // 注释承载。
test "writeWhole 必要时建父目录声明面：二级缺失嵌套真建可写读回 + 嵌套覆盖；pathExists 目录形回 true（不区分文件/目录）（第 129 轮）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const priv = tpriv.Priv.init(io); // D62：同径名改私有（root/sub/deep 三径同源后缀）
    const pre = ".zig-cache/tmp/zzc_r129_deep_";
    var br: [96]u8 = undefined;
    var bs: [96]u8 = undefined;
    var bd: [96]u8 = undefined;
    const root = priv.path(&br, pre, "");
    const sub = priv.path(&bs, pre, "/sub");
    const deep = priv.path(&bd, pre, "/sub/probe.txt");
    // 先清历史异常残留，使前置「缺失」断言确定性成立（正常 defer 已清，本行为双保险）。
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // ① 前置：目录与目标文件均不存在（pathExists 对不存在回 false 既有测已钉，此处为后文证伪锤）。
    try std.testing.expect(!pathExists(io, root));
    try std.testing.expect(!pathExists(io, deep));

    // ② 声明面核心：父目录缺失二级（root/sub）嵌套写——createDirPath 真建分支 fired、
    //   误删即 FileNotFound、误写单级/上溯一级形即末级仍缺（S1/S2 点位）。
    try writeWhole(io, deep, "nested write");
    const back = try readWhole(io, gpa, deep);
    try std.testing.expectEqualStrings("nested write", back);

    // ③ 目录存在亦回 true（「不区分文件/目录」声明面直钉，S3 点位）。
    try std.testing.expect(pathExists(io, root));
    try std.testing.expect(pathExists(io, sub));
    try std.testing.expect(pathExists(io, deep));

    // ④ 嵌套路径下覆盖形：同 deep 再写换内容（覆盖面既有单级已兜、此形顺手钉住不另设点位）。
    try writeWhole(io, deep, "overwritten");
    const back2 = try readWhole(io, gpa, deep);
    try std.testing.expectEqualStrings("overwritten", back2);
}

test "writeWholeAtomic（D130）：覆盖旧文件为完整新内容、无临时残留" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const priv = tpriv.Priv.init(io);
    var db: [96]u8 = undefined;
    var pb: [96]u8 = undefined;
    // 独立子目录：原子写的临时文件也落在这里，walk 断言不会被同前缀的其他测块污染。
    const parent = priv.path(&db, ".zig-cache/tmp/zzc_atomic_", "");
    const probe = std.fmt.bufPrint(&pb, "{s}/probe.txt", .{parent}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};

    // 先有旧完整内容，再原子覆盖；读回必须是新内容（不得是半截/旧新混合）。
    try writeWhole(io, probe, "旧内容完整");
    try writeWholeAtomic(io, probe, "新内容完整且更长一些");
    const back = try readWhole(io, gpa, probe);
    try std.testing.expectEqualStrings("新内容完整且更长一些", back);

    // 原子写不得在目标目录留下命名临时文件：walk 到的文件必须只有 probe 本体。
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        n += 1;
        try std.testing.expectEqualStrings(std.fs.path.basename(probe), e.basename);
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}
