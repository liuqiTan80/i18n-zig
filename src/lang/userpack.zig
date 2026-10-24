//! R9g 第二档（第 140 轮）：**工程级运行期语言包**的安装与发现（`zzc lang add`）。
//!
//! 第一档（第 103 轮）给了 `--lang-file <路径>`：外部包免重编译，但每次调用都要带长路径、
//! 且路径写错就在流程深处才报错。第二档把「校验通过的外部包」**装进当前工程**
//! （`.zzc/lang/<key>.txt`，与 `.zzc/gen`/`.zzc/bin`/`.zzc/symbols.txt` 同宿主目录），此后
//! `--lang <key>` 直接命中——同样**免重编译**（装载仍走 `main.loadExternalPack` 同一真相源）。
//!
//! 为什么不选「写进 `src/lang/packs/` 随二进制内嵌」那条路：第 140 轮实测坐实——新增包文件后
//! `zig build` **不会**重跑 build.zig 的扫描步（脚本命令式 `iterate` 未向构建系统声明文件依赖，
//! 即 R9f/D45 在册陷阱），新包既不报错也不出现，须清 `.zig-cache` 才生效。那条路的成交提示
//! （「请重编译即可用」）因此是**谎报**。故本档选运行期目录：装上立刻可用、可被 e2e 真验。
//!
//! 本模块刻意做成 `io`+`gpa` 形参注入的薄封装（同 `file_io.zig` 的 D21 手法），使真 IO 行为
//! 能落进 zzc_core 测试图执行——`main.zig` 的 test 块从不运行，选包/写盘策略若留在 main 即零防线。

const std = @import("std");
const Io = std.Io;
const file_io = @import("../file_io.zig");
const Pack = @import("pack.zig"); // 第 315 轮 D174：取 meta_name 真值消 "$name" 跨模块手抄
const zzc = @import("../zzc_paths.zig"); // 第 200 轮 D68：`.zzc` 族单一真值

/// 默认安装目录（相对当前工作目录）。正斜杠形与既有 `.zzc/symbols.txt` 等一致，Windows 亦接受。
/// 第 200 轮 D68：值改取 `zzc.lang_dir`（与符号表/生成树/产物目录同一根派生、全员钉在 `zzc_paths` 的 200 T0）。
pub const default_dir: []const u8 = zzc.lang_dir;

/// 注册名长度上限：key 直接成为文件名与 argv 选择名，过长只会制造截断/展示问题。
pub const max_key_len: usize = 64;

/// 注册名字符白名单：ASCII 字母/数字/`-`/`_`。
///
/// 刻意**不放行** `.`（隐藏文件、`..` 穿越）、`/`\`（路径分隔）、`:`（Windows 盘符/ADS）、
/// 空白与控制字符（argv 传递与展示歧义），也**不放行**非 ASCII：注册名要跨机出现在命令行与
/// 文件名两处，码页/控制台编码差异正是 D17/D45 一族「本机绿 ≠ 他机绿」的源头。方言展示名
/// 不受此限——它由包内 `$name`/`# @display` 承担，与选择名解耦（`zzc lang` 详情行展示的就是它）。
pub fn keyIsSafe(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_len) return false;
    if (key[0] == '-' or key[0] == '.') return false; // 前导 dash 会被当旗标、前导点成隐藏文件
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
            c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// 某注册名在给定目录下的包文件相对路径 `<dir>/<key>` ++ `pack_ext`。不校验 key（调用方先过 `keyIsSafe`）。
/// 第 237 轮 D105：扩展名段委派 `zzc.pack_ext` 单源（与 `main.cmdLangAdd` 两处提示文案同一真值派生、
/// 单边漂移即文案指错文件名——见 `zzc_paths.pack_ext` 顶注）。
pub fn fileRel(gpa: std.mem.Allocator, dir: []const u8, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}" ++ zzc.pack_ext, .{ dir, key });
}

/// 安装失败的种类（供调用方翻译成母语可操作提示；fs 错误另由 `localizeFsErr` 兜底）。
pub const InstallError = error{
    BadKey, // 注册名不合白名单（含 `--as` 传入与包内 `$code` 派生两种来源）
    AlreadyInstalled, // 目标位已有同名包：绝不静默覆盖（与 `init` 防覆盖同一契约形制）
};

/// 把已校验的外部包字节装为 `<dir>/<key>.txt`。先建目录、目标已存在即拒（防覆盖）、字节原样写。
/// 副作用顺序刻意是「判 key → 查存在 → 建目录 → 写盘」：前两步零副作用，坏名/撞名都不会留下半个目录。
pub fn install(io: Io, gpa: std.mem.Allocator, dir: []const u8, key: []const u8, bytes: []const u8) !void {
    if (!keyIsSafe(key)) return error.BadKey;
    const rel = try fileRel(gpa, dir, key);
    defer gpa.free(rel); // 第 255 轮 D122：fileRel/allocPrint 临时串逐枚释放（承 D23/D121 守则·函数返 void 不移交所有权；旧形从不 free、生产 arena+历轮测 arena 包裹双侧掩盖）
    if (file_io.pathExists(io, rel)) return error.AlreadyInstalled;
    try file_io.writeWhole(io, rel, bytes);
}

/// 已装用户包列播条目（第 315 轮 D174 列播补位）：`key` 为文件名基形（即 `--lang`
/// 选择名），`name` 为包内 `展示名`（`Pack.meta_name` 键）值；缺失/畸形回落 key——
/// 列播是只读指引，不做全包 parse，坏包也要让用户看见装了什么名。
pub const Listed = struct { key: []const u8, name: []const u8 };

/// 枚举工程已装用户包（目录不存在＝从未 add＝空列表非错误）。两切片皆 `gpa` 分配、
/// 归调用方逐枚释放（`freeListed`）；按 key 升序保证输出确定（列播可被逐字节对拍）。
pub fn listInstalled(io: Io, gpa: std.mem.Allocator, dir: []const u8) ![]Listed {
    var out: std.ArrayList(Listed) = .empty; // Zig 0.17 形制：.empty＋逐调用喂 gpa（同 pack.zig L351）
    errdefer freeListed(gpa, out.items);
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out.items, // 无 .zzc/lang 的工程：空列播
        else => return e,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .file) continue; // 子目录/符号链一律跳（只认真身）
        const base = std.fs.path.stem(ent.name);
        if (!keyIsSafe(base)) continue; // 隐藏文件/非法名/非包文件封口于白名单
        const bytes = d.readFileAlloc(io, ent.name, gpa, Io.Limit.limited(1 << 20)) catch continue; // 超限坏包：跳过不拦列播
        defer gpa.free(bytes);
        const name: []const u8 = blk: {
            const at = std.mem.indexOf(u8, bytes, Pack.meta_name) orelse break :blk try gpa.dupe(u8, base);
            const rest = bytes[at + Pack.meta_name.len ..];
            const eq = std.mem.indexOfScalar(u8, rest, '=') orelse break :blk try gpa.dupe(u8, base);
            const v = std.mem.trim(u8, rest[eq + 1 ..], " \t\r\n");
            const nl = std.mem.indexOfScalar(u8, v, '\n') orelse v.len;
            const val = std.mem.trim(u8, v[0..nl], " \t\r");
            if (val.len == 0) break :blk try gpa.dupe(u8, base);
            break :blk try gpa.dupe(u8, val);
        };
        errdefer gpa.free(name);
        const key = try gpa.dupe(u8, base);
        errdefer gpa.free(key);
        try out.append(gpa, .{ .key = key, .name = name });
    }
    std.mem.sort(Listed, out.items, {}, struct {
        fn lt(_: void, a: Listed, b: Listed) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// 释放 `listInstalled` 返回切片的三 ownership：两内字符串一枚外层数组（与 D122/D125
/// 逐枚释放守则同形；列播调用方 defer 一行收口）。
pub fn freeListed(gpa: std.mem.Allocator, items: []Listed) void {
    for (items) |*it| {
        gpa.free(it.key);
        gpa.free(it.name);
    }
    gpa.free(items);
}

/// 查已装包文件路径：key 不安全（如 `--lang ../evil`）恒 null——**先于磁盘查询**封口，
/// 令「穿越尝试」与「未安装」走同一条母语提示，不泄露目录结构、也不读到工程外的任意 .txt。
/// 命中返回的切片由 `gpa` 分配、归调用方。
pub fn installedFile(io: Io, gpa: std.mem.Allocator, dir: []const u8, key: []const u8) ?[]const u8 {
    if (!keyIsSafe(key)) return null;
    const rel = fileRel(gpa, dir, key) catch return null;
    if (!file_io.pathExists(io, rel)) {
        gpa.free(rel); // 第 259 轮 D125：fileRel/allocPrint 临时串在未命中路径逐枚释放（承 D23/D122 守则·旧形仅命中时把 rel 移交调用方、未命中即 return null 而从不 free；生产 gpa_ 进程 arena+旧测 arena-over-testing 双侧同蔽）
        return null;
    }
    return rel;
}

// ---------------------------------------------------------------- 单测（真 IO·落 zzc_core 测试图）

// 测块共用构件（第 196 轮 D62）：`tpriv.Priv` 取进程私有后缀作安装目录名。
// 测内另备同步 Io（第 109 轮在册手法）：`Threaded` 内部 gpa 须线程安全，故用 page_allocator；
// 被测分配另走 Arena over testing.allocator 以获零泄漏判定。产物落 `.zig-cache/` 下自清。
// 原先此处是一个编译期固定的共享目录名（`userpack_test_140`），而本模块的测块在两个测试图
// 并发跑（或多进程并跑同一二进制）时互删对方在装的文件——旧固定 const 因此撤销。
const tpriv = @import("../test_priv.zig");

test "keyIsSafe：ASCII 白名单放行，穿越/盘符/分隔/空白/非 ASCII/前导点划/超长一律拒" {
    // 放行形（内置与既有 fixture 的真实注册名都在此列）。
    try std.testing.expect(keyIsSafe("zh"));
    try std.testing.expect(keyIsSafe("tst-ja")); // fixture external-min 的 $code 形
    try std.testing.expect(keyIsSafe("en_US"));
    try std.testing.expect(keyIsSafe("a1"));
    try std.testing.expect(keyIsSafe("klingon"));
    // 长度边界：64 放行、65 拒。
    var buf64: [64]u8 = undefined;
    @memset(&buf64, 'a');
    try std.testing.expect(keyIsSafe(&buf64));
    var buf65: [65]u8 = undefined;
    @memset(&buf65, 'a');
    try std.testing.expect(!keyIsSafe(&buf65));
    // 拒绝形——每条都是「写盘目标名」或「argv 选择名」上的真实攻击/事故面。
    try std.testing.expect(!keyIsSafe("")); // 空名 → 目录下一个裸 `.txt`
    try std.testing.expect(!keyIsSafe("..")); // 上溯
    try std.testing.expect(!keyIsSafe("../evil")); // 上溯到目录外
    try std.testing.expect(!keyIsSafe("a/b")); // 分隔符（子目录逃逸出安装目录）
    try std.testing.expect(!keyIsSafe("a\\b")); // Windows 分隔符
    try std.testing.expect(!keyIsSafe("C:/out")); // 盘符绝对
    try std.testing.expect(!keyIsSafe("a:b")); // 冒号（盘符/NTFS ADS）
    try std.testing.expect(!keyIsSafe("a b")); // 空白
    try std.testing.expect(!keyIsSafe("a\tb")); // 制表
    try std.testing.expect(!keyIsSafe("\x00")); // 控制字符
    try std.testing.expect(!keyIsSafe(".hidden")); // 前导点 → 隐藏文件
    try std.testing.expect(!keyIsSafe("-as")); // 前导划 → 会被当旗标
    try std.testing.expect(!keyIsSafe("中文")); // 非 ASCII：跨机码页分叉面（展示名归 $name）
    try std.testing.expect(!keyIsSafe("ｆｕｌｌ")); // 全角形同样拒（本仓 fullwidth 族拦的就是这类）
}

test "fileRel：安装路径形制钉住 `<dir>/<key>.txt`" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const gpa = arena_impl.allocator();
    try std.testing.expectEqualStrings(".zzc/lang/zh.txt", try fileRel(gpa, default_dir, "zh"));
    try std.testing.expectEqualStrings("d1/k2.txt", try fileRel(gpa, "d1", "k2"));
}

test "install：真 IO 往返——建目录、字节原样落位、重名拒覆盖（不留半个改写态）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const gpa = arena_impl.allocator();

    const priv = tpriv.Priv.init(io); // D62：安装目录改进程私有
    var db: [96]u8 = undefined;
    var eb: [128]u8 = undefined;
    const dir = priv.path(&db, ".zig-cache/tmp/zzc_userpack_", "");
    const evil = priv.path(&eb, ".zig-cache/tmp/zzc_userpack_", "/../../evil.txt");
    const rel = try fileRel(gpa, dir, "kA");
    std.Io.Dir.cwd().deleteFile(io, rel) catch {}; // 前次中断残留

    const body = "$name = 测试甲\n$code = kA\n[keywords]\n常数 = const\n";
    try install(io, gpa, dir, "kA", body);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {}; // 私有目录整树回清（不留空壳累在 .zig-cache/tmp 下）

    // 落位字节与入参全等（包体不得被加工/追加头指令——那是内嵌档的事，本档只管原样存）。
    const back = try file_io.readWhole(io, gpa, rel);
    try std.testing.expectEqualStrings(body, back);

    // 重名拒覆盖：先落 sentinel，再尝试装同名的不同内容，须原样保留 sentinel。
    const body2 = "$name = 测试乙\n$code = kA\n[keywords]\n常数 = var\n";
    try std.testing.expectError(error.AlreadyInstalled, install(io, gpa, dir, "kA", body2));
    const still = try file_io.readWhole(io, gpa, rel);
    try std.testing.expectEqualStrings(body, still);

    // 坏名零副作用：BadKey 必须先于任何写盘返回，且目录内不出现该名文件。
    try std.testing.expectError(error.BadKey, install(io, gpa, dir, "../evil", body));
    try std.testing.expect(!file_io.pathExists(io, evil));
    try std.testing.expectError(error.BadKey, install(io, gpa, dir, "中文", body));
}

test "installedFile：装后可查、未装为 null、不安全名先于磁盘查询即 null（防穿越读）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const gpa = arena_impl.allocator();

    const priv = tpriv.Priv.init(io); // D62：安装目录改进程私有
    var db: [96]u8 = undefined;
    const dir = priv.path(&db, ".zig-cache/tmp/zzc_userpack_", "");
    const rel = try fileRel(gpa, dir, "kB");
    std.Io.Dir.cwd().deleteFile(io, rel) catch {};

    // 未装 → null（与「未知语言包」同一路径，不误报已装）。
    try std.testing.expect(installedFile(io, gpa, dir, "kB") == null);

    try install(io, gpa, dir, "kB", "$code = kB\n[keywords]\n常数 = const\n");
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {}; // 私有目录整树回清

    const hit = installedFile(io, gpa, dir, "kB") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(rel, hit);

    // 穿越形选择名：即便 `<dir>/../..` 下真有同名文件，也须因白名单先拒而不返回路径。
    try std.testing.expect(installedFile(io, gpa, dir, "../../build") == null);
    try std.testing.expect(installedFile(io, gpa, dir, "C:/windows/x") == null);
}

test "第 237 轮 T1 fileRel 扩展名段委派 hub pack_ext：落名 = dir '/' key ++ pack_ext 且尾缀随 hub（防 fileRel 退回内联手抄）" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const gpa = arena_impl.allocator();
    const rel = try fileRel(gpa, default_dir, "zh");
    // A1 组合钉：输出必恰为 dir + "/" + key + pack_ext——扩展名段由 hub 派生，若 fileRel 退回内联
    //    `.txt` 而 pack_ext 漂为异值，本钉红（与 237 T0 的 pack_ext 值钉合力封住值侧漂移）。
    try std.testing.expectEqualStrings(default_dir ++ "/" ++ "zh" ++ zzc.pack_ext, rel);
    // A2 尾缀随 hub：endsWith pack_ext（串面直连，不引入另一侧字面量）。
    try std.testing.expect(std.mem.endsWith(u8, rel, zzc.pack_ext));
}

test "第 237 轮 T2 cmdLangAdd 两文案委派 hub pack_ext（@embedFile 反锚 main.zig·防落名↔文案手抄静默脱钩）" {
    // 本锚系 D105 主靶：旧形制下 main 两处 lang-add 文案各自内联 `{s}/{s}.txt`、与 fileRel 互不引用
    // （t2 探针 P1：独漂两文案 fresh 611/611 全绿静默、真跑文案说 PACKEXT 实落 txt）。落盘名与文案
    // 宣示名同源于 hub pack_ext 后，main 不得再内联裸扩展名。
    const src = @embedFile("../main.zig");
    // A1 委派形必现两处（已存在报错文案 + 成功文案）：皆以 `++ zzc.pack_ext ++` 拼接。
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "++ zzc.pack_ext ++"));
    // A2 反锚：旧内联手抄形 `{s}/{s}.txt`（裸 `.txt` 接在 `{s}/{s}` 后）必 0 处——任一文案退回硬编即本锚红。
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, src, "{s}/{s}.txt"));
}

// 探针（第 255 轮 t2·承 D23/D37/D121 泄漏族守则）：install L62 `const rel = try fileRel(gpa, ...)`
// 系 allocPrint 堆串、纯局部、函数返 void 不移交所有权、从不 free——每次调用泄一块。生产 main.zig:565
// 传 arena `gpa_`、本模块历轮测 gpa 皆 arena-over-testing 包裹，双侧同蔽（同 D27/D121 盲区形）。
// 破法：gpa 直喂裸 std.testing.allocator（leak-checking），作用域退出自动报 leaked。
test "第 255 轮 T0 userpack.install 落盘路径临时串逐枚释放：直喂裸 std.testing.allocator（非 arena）坐实 rel 无泄（D122）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const priv = tpriv.Priv.init(io); // D62：安装目录进程私有
    var db: [96]u8 = undefined;
    const dir = priv.path(&db, ".zig-cache/tmp/zzc_userpack_", "");
    std.Io.Dir.cwd().deleteTree(io, dir) catch {}; // 前置确定性：清历史残留
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const body = "$name = 泄漏探针\n$code = kL\n[keywords]\n常数 = const\n";
    try install(io, std.testing.allocator, dir, "kL", body);
}

// 第 259 轮 D125 同族永久 T0 测钉：installedFile 未命中路径——fileRel 分配 rel 后
// pathExists 为 false，旧形从不释放即返回 null（每次调用泄一块 path 串）。
// 生产 gpa_ 进程 arena 掩盖、旧测 L162 arena-over-testing 掩盖——双侧同蔽（D122 同形）。
// 修法：pathExists-false 分支加 gpa.free(rel)。
// 验法：gpa 直喂裸 std.testing.allocator，作用域退出自动报 leaked。
test "第 259 轮 T0 installedFile 未命中路径 rel 逐枚释放（D125·裸 testing.allocator 泄检）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const priv = tpriv.Priv.init(io);
    var db: [96]u8 = undefined;
    const dir = priv.path(&db, ".zig-cache/tmp/zzc_userpack_probe259_", "");
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // keyIsSafe 通过、但文件不存在 → pathExists false → 返回 null → rel 泄漏。
    const result = installedFile(io, std.testing.allocator, dir, "nonexistent_key");
    try std.testing.expect(result == null);
}

// 第 315 轮 T0（D174）：listInstalled 列播内核——从未 add（目录缺失）＝空列播非错误；
// 正形（$name 活线提取）；回落形（无 $name 键时 name==key）；封口形（非法名文件/子目录
// 不入列）；排序确定形（key 升序可逐字节对拍）。裸 testing.allocator 直喂验逐枚释放
// （承 D122/D125 守则：listInstalled/freeListed 三 ownership 无泄）。
test "第 315 轮 T0 listInstalled：空目录/正形/回落/封口/排序五形＋无泄（D174）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const priv = tpriv.Priv.init(io);
    var db: [96]u8 = undefined;
    const dir = priv.path(&db, ".zig-cache/tmp/zzc_list315_", "");
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // 形一：目录不存在 → 空列表、非错误。
    const empty = try listInstalled(io, std.testing.allocator, dir);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    std.testing.allocator.free(empty);

    // 铺盘：两正装包（b 带 $name、a 无）＋非法名文件＋子目录。
    try install(io, std.testing.allocator, dir, "b", "$name = 乙包\n$code = kb\n[keywords]\n常数 = const\n");
    try install(io, std.testing.allocator, dir, "a", "$code = ka\n[keywords]\n常数 = const\n");
    // 铺盘直写用 allocPrint（runtime slice 不可 `++` 拼）；子目录借 writeWhole 的建父目录能力带出。
    const hid = try std.fmt.allocPrint(std.testing.allocator, "{s}/.hidden.txt", .{dir});
    defer std.testing.allocator.free(hid);
    file_io.writeWhole(io, hid, "$name = 幽灵\n") catch {}; // 非法名直写（install 白名单会拒，正是要验封口）
    const subf = try std.fmt.allocPrint(std.testing.allocator, "{s}/sub/x.txt", .{dir});
    defer std.testing.allocator.free(subf);
    file_io.writeWhole(io, subf, "占位") catch {}; // 子目录条目：kind != .file 应跳

    // 形二～五：枚举 a,b（升序）；b.name=乙包、a.name 回落 "a"；非法名/目录不入。
    const got = try listInstalled(io, std.testing.allocator, dir);
    defer freeListed(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("a", got[0].key);
    try std.testing.expectEqualStrings("a", got[0].name); // 无 $name 回落 key
    try std.testing.expectEqualStrings("b", got[1].key);
    try std.testing.expectEqualStrings("乙包", got[1].name);
}
