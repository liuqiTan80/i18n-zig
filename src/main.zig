//! zzc —— 用母语编写真正的 Zig。
//!
//! 子命令：
//!   zzc init <项目名>       生成母语工程骨架
//!   zzc check [文件.zz]     翻译 + 词法/编译检查（母语报错）
//!   zzc build [文件.zz]     翻译 -> zig build-exe（其余参数透传 zig）
//!   zzc run   [文件.zz]     编译并运行，`--` 之后为程序参数
//!   zzc test  [文件.zz]     翻译 -> zig test
//!   zzc eject [目录]        导出标准 Zig 工程（毕业路径）
//!   zzc lang                列出内置语言包
//!   zzc version             版本信息
//!
//! 语法骨架保持 ASCII（() {} !T ?T @builtin），仅词法单元母语化；
//! 错误标签（FileNotFound 等）与 std 路径在方言里原样可用。

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const translate = @import("transpiler/translate.zig");
const Mangle = @import("transpiler/mangle.zig");
const ColumnMap = @import("transpiler/column_map.zig");
const Pack = @import("lang/pack.zig").Pack;
const PackParseError = @import("lang/pack.zig").ValidationError;
const diag = @import("diag/translate.zig");
const PureFilter = @import("diag/pure_filter.zig").PureFilter;
const UntranslatedList = @import("diag/pure_filter.zig").UntranslatedList;
const renderUntranslatedJson = @import("diag/pure_filter.zig").renderUntranslatedJson;
const cli = @import("cli/args.zig");
const file_io = @import("file_io.zig");
const registry = @import("lang/registry.zig");

const version_str = "0.1.0";
const zh_pack = @embedFile("lang/packs/中文.txt");

const Exit = error{ Usage, Failed };

var gpa_: std.mem.Allocator = undefined; // arena，进程级
var io_: Io = undefined;
var out_w: *Io.Writer = undefined;
var werr_file: Io.File.Writer = undefined;
var werr: *Io.Writer = undefined;

/// D46（第 101 轮）：bail 失败退出路径的符号表补位指针。仅在主函数里
/// `loadSymbols` 全量解析成功后指向 table——此前（init/--lang/半解析的
/// DuplicateSymbol）保持 null，bail 便不会落盘半成品表；此后任何失败退出
/// （check/build 语义编译错、eject `.fail` 毕业验证未过等）都与 D38 同形：
/// 本轮已 intern 的新母语名映射不得因 noreturn exit 被吞。
var bail_table: ?*Mangle = null;

// ---------------------------------------------------------------- 基础 IO

// 输入文件上限现由 file_io.max_source_bytes 定义（第 62 轮下沉测试图）。
/// 超限提示只打一次：预扫描/豁免解析/主循环会对同一文件多次 readWhole，
/// 重复同句是噪音；首次打印后由主循环 try 路径负责失败传播。
var size_limit_warned = false;

/// 编码错误去重集（D31）：同因多次 readWhole 扫描，坏文件须点名但不能每个扫描遍重复一次；
/// 按路径内容去重（每坏文件恰报一次、多坏文件各自点名）。懒初始化（gpa_ 全局有序依赖），
/// 键为调用方 path 借用视图、随 arena 长存（StringHashMap 按内容比较，后续扫描同路径字符串仍命中）。
var enc_warned_set: ?*std.StringHashMap(void) = null;

/// F3 未翻译短语收集清单（进程级）：跨多次 zigCompile 累积，在 main 命令分发前落盘——
/// 成功/bail 两条退出路径都覆盖（bail 直接 exit、后置代码不执行）。
var untranslated_list: UntranslatedList = .{};

/// 落盘未翻译清单（F3）：空清单不建文件（防 CI 消费面把恒在的空文件误读为“零未译”信号——
/// 缺失即“本次未发生过兜底”）。写失败是辅助信息面：母语提示但不改主流程退出码。
fn flushUntranslated() void {
    if (untranslated_list.items.items.len == 0) return;
    const ts = @as(i64, @intCast(@divFloor(Io.Timestamp.now(io_, .real).nanoseconds, std.time.ns_per_s)));
    const json = renderUntranslatedJson(gpa_, untranslated_list.items.items, ts) catch |e| {
        printErr("zzc: 未翻译清单序列化失败（{s}），已跳过落盘。", .{@errorName(e)});
        return;
    };
    defer gpa_.free(json);
    writeWhole("logs/untranslated_phrases.json", json) catch |e| {
        printErr("zzc: 未翻译清单落盘失败（{s}），已跳过。", .{@errorName(e)});
    };
}

/// 进程级薄封装：委托 file_io（已下沉测试图、第 62 轮），绑定 io_/gpa_ 全局并把超限反馈为母语提示。
fn readWhole(path: []const u8) ![]const u8 {
    return file_io.readWhole(io_, gpa_, path) catch |e| switch (e) {
        error.SourceTooLarge => {
            // 超限是用户可直接行动的情形（同第 42 轮“错误源头母语化”原则），不走 bail 兜底泄错名。
            if (!size_limit_warned) {
                size_limit_warned = true;
                printErr("zzc: 文件 {s} 超过大小上限（{d} MB）；母语工程不应有此体量源文件，请确认未误指向二进制/日志类文件", .{ path, file_io.max_source_bytes / (1024 * 1024) });
            }
            return error.Failed;
        },
        error.InvalidEncoding => {
            // 错编码保存是可直接行动的真因（D31）：逐文件点名、给可操作指引，不让用户拿与真因无关的
            // 下游语法错；同一文件被预扫描/豁免/主循环多遍读取，按路径去重防重复噪音（同超限只提一次
            // 的动机，但比全局旗标精确：多个坏文件须各自点名）。
            const set = enc_warned_set orelse blk: {
                const s = gpa_.create(std.StringHashMap(void)) catch break :blk null;
                s.* = std.StringHashMap(void).init(gpa_);
                enc_warned_set = s;
                break :blk s;
            };
            const first_time = if (set) |s| !s.contains(path) else true;
            if (first_time) {
                if (set) |s| s.put(path, {}) catch {};
                printErr("zzc: 文件 {s} 不是 UTF-8 编码（疑似 UTF-16/GBK 等错编码保存）；请在编辑器中另存为 UTF-8（有无 BOM 均可）后重试", .{path});
            }
            return error.Failed;
        },
        else => |other| return other,
    };
}

fn writeWhole(path: []const u8, data: []const u8) !void {
    return file_io.writeWhole(io_, path, data);
}

/// 判断相对当前工作目录的路径是否存在（仅用于避免覆盖，不区分文件/目录）。
fn pathExists(path: []const u8) bool {
    return file_io.pathExists(io_, path);
}

/// 原始字节读（**不**做 stripBom），用于拷贝资源文件（二进制安全）。
fn readFileRaw(path: []const u8) ![]const u8 {
    return file_io.readFileRaw(io_, gpa_, path);
}

/// 路径是否为符号链接（台账 R8）：第 63 轮下沉 file_io（基础 IO 一致性、入测试图），本处仅绑 io_ 全局。
/// 任何错误（不存在/无权限/平台不支持）一律回 false——保守不回退现状。
fn pathIsSymlink(path: []const u8) bool {
    return file_io.pathIsSymlink(io_, path);
}

/// 把某单位里 `@embedFile` 引用的资源从方言源目录原样拷到目标 .zig 所在目录（生成树或 eject dest）。
/// zig 里 `@embedFile` 相对当前 .zig 所在目录解析：源 = dirname(native .zz)/p，目标 = dirname(dest .zig)/p。
/// `root` 为镜像根（collect 传 `.zzc/gen`、eject 传 dest）：先做包含性守卫、目标解析 `..` 后越出 root 或 p 为绝对则直接跳过
/// （先判后读、既不越界写也不读项目外文件），留给 zig 原生报错；仅当源文件存在才拷（二进制安全）。拷贝失败静默忽略。
fn stageEmbedAssets(native_rel: []const u8, zig_str: []const u8, dest_zig: []const u8, root: []const u8) void {
    var list = cli.extractEmbedPaths(gpa_, zig_str) catch return;
    defer list.deinit(gpa_);
    const nat_dir = std.fs.path.dirname(native_rel) orelse ".";
    const dst_dir = std.fs.path.dirname(dest_zig) orelse ".";
    for (list.items) |p| {
        // 越界写守卫：解析后的目标必须仍严格处于镜像根内（否则 zig 也会拒、且不应把产物写到树外）。
        const within = cli.embedPathStaysWithin(gpa_, root, dst_dir, p) catch false;
        if (!within) continue;
        const srcp = cli.joinRelNorm(gpa_, nat_dir, p) catch continue; // 拼接+归一单一真值（D9）
        // 符号链接守卫（R8）：词法包含性判断（embedPathStaysWithin）防不住“树内链接指向树外”——
        // staging 会把外部内容读进生成树/eject 产物。链接资产拒拷并母语提示；
        // zig 自身 @embedFile 有 canonical 越界检查（嵌入越界条目已本地化其拒绝）。
        if (pathIsSymlink(srcp)) {
            printErr("zzc: 嵌入资源 `{s}` 是符号链接，不拷贝（防止把工程外内容读入生成树）；请改用工程内的真实文件。", .{srcp});
            gpa_.free(srcp);
            continue;
        }
        const dstp = cli.joinRelNorm(gpa_, dst_dir, p) catch {
            gpa_.free(srcp);
            continue;
        };
        const bytes = readFileRaw(srcp) catch continue; // 源缺失→跳过，交给 zig 自己报 `failed opening`
        defer gpa_.free(bytes);
        writeWhole(dstp, bytes) catch |e| {
            printErr("zzc: 拷贝嵌入资源文件失败：{s} -> {s}（{s}）", .{ srcp, dstp, @errorName(e) });
        };
    }
}

fn printOut(comptime fmt: []const u8, args: anytype) void {
    out_w.print(fmt ++ "\n", args) catch |e| {
        printErr("zzc: 标准输出失败（{s}）", .{@errorName(e)});
    };
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    werr.print(fmt ++ "\n", args) catch {
        // 错误输出本身失败时无任何通道可再记录，显式吞掉（error 值不可赋给 `_`）。
    };
}

// ---------------------------------------------------------------- 符号表持久化

/// 恢复历史符号表：读 `.zzc/symbols.txt` 后交给 `Mangle.parseSymbolText`（格式解析属 zzc_core 测试图、有单测）。
/// 恢复失败向上传播（台账 D16）：丢映射即破坏跨会话稳定、可能后续撞号；
/// 仅“文件不存在”（首次运行尚无符号表）仍为正常路径。
/// 超限（error.Failed，已在 readWhole 源头母语报出）不可静默跳过：照旧传播。
fn loadSymbols(table: *Mangle) !void {
    const bytes = readWhole(".zzc/symbols.txt") catch |e| switch (e) {
        error.FileNotFound => return, // 首次运行：尚无符号表，正常
        else => return e,
    };
    try table.parseSymbolText(bytes);
}

fn saveSymbols(table: Mangle) void {
    var out: std.ArrayList(u8) = .empty;
    for (table.symbols.items) |s| {
        out.appendSlice(gpa_, s.native) catch |e| {
            printErr("zzc: 保存符号表失败（写入符号名）：{s}", .{@errorName(e)});
            return;
        };
        out.appendSlice(gpa_, " = ") catch |e| {
            printErr("zzc: 保存符号表失败（写入等号）：{s}", .{@errorName(e)});
            return;
        };
        out.appendSlice(gpa_, s.ascii) catch |e| {
            printErr("zzc: 保存符号表失败（写入 ASCII 名）：{s}", .{@errorName(e)});
            return;
        };
        out.append(gpa_, '\n') catch |e| {
            printErr("zzc: 保存符号表失败（写入换行）：{s}", .{@errorName(e)});
            return;
        };
    }
    writeWhole(".zzc/symbols.txt", out.items) catch |e| {
        printErr("zzc: 保存符号表失败（写入文件）：{s}", .{@errorName(e)});
    };
}

// ---------------------------------------------------------------- 工程收集与翻译

const Unit = struct {
    native_rel: []const u8, // src/main.zz（相对当前工作目录）
    gen_rel: []const u8, // 生成文件相对路径，如 .zzc/gen/src/main.zig
    nat_src: []const u8,
    zig_str: []const u8,
    map: ColumnMap,
};

const Project = struct {
    units: std.ArrayList(Unit),
};

/// 生成文件相对路径：src/main.zz -> .zzc/gen/src/main.zig（保留子目录）。第 60 轮纯逻辑下沉 cli 并进测试图。
const genPathFor = cli.genPathFor;

/// 语言包 `@embedFile` 的全部词形：ASCII 直通形 + 映射值恰为 @embedFile 的方言词（如 `嵌入文件`）。
/// 供原文预扫描用（台账 D2）。第 61 轮下沉 pack.zig 并进测试图（D7/D21）。
const embedWordForms = @import("lang/pack.zig").embedWordForms;

/// 语言包中映射值恰为 `want` 的全部词形 + ASCII 直通形 `want` 本身（如 const → `const` + `常数`）。
/// 供原文单跳变量实参解析（台账 D3）。第 61 轮下沉 pack.zig 并进测试图。
const keywordFormsFor = @import("lang/pack.zig").keywordFormsFor;

/// 收集 entry 同目录（递归）全部 .zz 一并翻译（保证 @import 可达）。
fn collectAndTranslate(entry: []const u8, lang: Pack, table: *Mangle) !Project {
    const entry_dir = std.fs.path.dirname(entry) orelse ".";

    var files: std.ArrayList([]const u8) = .empty;
    // 目录不存在/不可读是常见用户情形（在错误目录运行），须给母语可操作提示，
    // 不能让原始 FileNotFound 经 bail 的兜底分支泄漏成英文“内部错误”。
    var dir = std.Io.Dir.cwd().openDir(io_, entry_dir, .{ .iterate = true }) catch {
        printErr("zzc: 找不到可读取的工程目录 `{s}`；请在方言工程根目录（含 `src/*.zz`）运行，或先用 `zzc init <名字>` 新建工程。", .{entry_dir});
        return error.Failed;
    };
    defer dir.close(io_);
    var walker = try dir.walk(gpa_);
    defer walker.deinit();
    while (try walker.next(io_)) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.path, ".zz")) continue;
        // 拼接+归一单一真值（D9）：正斜杠形与文档/findUnit 精确匹配对齐。
        const joined = try cli.joinRelNorm(gpa_, entry_dir, e.path);
        try files.append(gpa_, joined);
    }

    // 目录存在但无任何 .zz 源文件（空 src/ 或跑错目录）也要尽早母语报错，
    // 避免下游以“入口不在工程”之类的间接信息困惑用户。
    if (files.items.len == 0) {
        printErr("zzc: 目录 `{s}` 下未找到任何方言源文件（.zz）；若要新建工程请用 `zzc init <名字>`。", .{entry_dir});
        return error.Failed;
    }

    // 命名空间预留（防撞名）：intern 顺序派生 `z_<n>`，若用户源码里直接写了 ASCII
    // 标识符 `z_1`，某母语名可能被 intern 成同一个 `z_1` → 生成两个同名声明（zig 报“重复
    // 声明”却指向看起来毫不相干的 `z_1` 与母语名、诊断误导；运气不好还会静默改变语义）。
    // 故翻译前对所有源文件做一次全局预扫描，预留出现的每个 `z_<十进制>` 独立词元编号，intern 跳过。
    // 必须跨全量文件先预留、再翻译（否则后读文件里的 `z_1` 来不及影响先读文件的 intern）。
    for (files.items) |rel| {
        const src = readWhole(rel) catch continue;
        defer gpa_.free(src);
        try table.reserveZInText(src);
    }
    // 消除跨会话撞名：把从 symbols.txt 恢复的、ASCII 落在用户新写 `z_N` 预留号上的历史映射重新安置。
    try table.relocateReservedCollisions();

    // 资产豁免采集（台账 D2）：被 `嵌入文件`/`@embedFile` 字面参引用的 `.zz` 是**数据文件**而非编译单元：
    // 它们会由引用单元的 stageEmbedAssets 原样拷进生成树/eject 目标，若再被当方言源翻译，
    // 模板正文会被全角/字符安全拦截、整工程 EXIT=1。故先从原文预扫描出引用集（词形动态取自语言包），
    // 主循环命中即跳过；解析越出源根/绝对/非 .zz 的回 null 不豁免（留给 zig 原生报错）。
    const leads = try embedWordForms(gpa_, lang);
    // 单跳变量实参解析的 const 词形（`常数`/`const`；映射值恰为 const 的方言词都算）：
    // `嵌入文件(名字)` 的变量引用同样要命中豁免，否则资产 .zz 仍被误当编译单元（D2×D3 组合面）。
    // 注：`变量`(var) 不列入——zig 的 @embedFile 要求 comptime 实参，var 绑定本就非法。
    const cs_leads = try keywordFormsFor(gpa_, lang, "const");
    var exempt = std.StringHashMap(void).init(gpa_);
    // 扫描+解析同形循环下沉 cli.findReferencedRels（D9/D10；纯函数入测试图，D7）；
    // gpa_ 为 arena：解析结果入表后释放列表本体即可，字符串随 arena 存活供 contains 回看。
    for (files.items) |rel| {
        const raw = readWhole(rel) catch continue;
        defer gpa_.free(raw);
        const rdir = std.fs.path.dirname(rel) orelse ".";
        var refs = cli.findReferencedRels(gpa_, raw, rdir, leads, cs_leads) catch continue;
        defer refs.deinit(gpa_);
        for (refs.items) |asset| try exempt.put(asset, {});
    }

    // D4 编译单元优先：若 embed 豁免的 .zz 同时也是 import 目标（被真实编译单元 @import/导入），
    // 则取消豁免——它是编译单元（需生成 .zig），其 embed 引用由 stageEmbedAssets 原样镜像 .zz，
    // 同名 .zz 与 .zig 不同后缀可共存。单趟扫描：仅从当前非豁免文件中识别导入（级联场景下
    // 被取消豁免的文件若有自己的 import 指向其他 exempt 文件，需再次构建收敛——P3 可接受）。
    const imp_leads = try keywordFormsFor(gpa_, lang, "@import");
    const no_const: []const []const u8 = &.{};
    for (files.items) |rel| {
        if (exempt.contains(rel)) continue; // 数据资产正文中的"导入"字串不视为真实 import
        const raw = readWhole(rel) catch continue;
        defer gpa_.free(raw);
        const rdir = std.fs.path.dirname(rel) orelse ".";
        var refs = cli.findReferencedRels(gpa_, raw, rdir, imp_leads, no_const) catch continue;
        defer refs.deinit(gpa_);
        for (refs.items) |target| {
            if (exempt.contains(target)) _ = exempt.remove(target);
        }
    }

    var proj = Project{ .units = .empty };
    for (files.items) |rel| {
        if (exempt.contains(rel)) continue; // 被当数据嵌入的 .zz 资产：不翻译、不入编译单元
        const nat_src = try readWhole(rel);
        // 先过全角/字符安全关
        const vs = translate.preCheck(gpa_, nat_src) catch return error.Failed;
        if (vs.len > 0) {
            for (vs) |v| {
                const lc = ColumnMap.lineColOf(nat_src, v.off);
                if (v.ascii.len > 0) {
                    if (v.ascii[0] == ' ') {
                        // 全角空格：半角替换字面不可见，改用文字描述而非反引号包裹。
                        printErr("{s}:{d}:{d}: 词法: {s}，请改用半角空格作缩进/分隔", .{ rel, lc.line, lc.col, v.hint });
                    } else {
                        printErr("{s}:{d}:{d}: 词法: {s}，请改用半角 `{s}`（Zig 语法符号不翻译）", .{ rel, lc.line, lc.col, v.hint, v.ascii });
                    }
                } else {
                    printErr("{s}:{d}:{d}: 词法: {s}（`{s}`）", .{ rel, lc.line, lc.col, v.hint, v.word });
                }
            }
            return error.Failed;
        }
        // 纯母语强制（第 99 轮）：.zz 源不得混入英文关键字/类型词形——AI 生成方言代码的
        // 半中半英混搭旧行为是无声透传、方言纯度静默降级；与词法检查同形制母语报错。
        var eng = translate.findEnglishWordForms(gpa_, lang, nat_src) catch return error.Failed;
        defer eng.deinit();
        if (eng.items.len > 0) {
            for (eng.items) |v| {
                const lc = ColumnMap.lineColOf(nat_src, v.off);
                printErr("{s}:{d}:{d}: 纯母语: 方言源须全用母语词形，英文 `{s}` 请改用 `{s}`", .{ rel, lc.line, lc.col, v.word, v.native });
            }
            return error.Failed;
        }
        const res = try translate.translate(gpa_, nat_src, lang, table);
        const gen = try genPathFor(gpa_, rel);
        // .zzc 内容缓存：生成结果与磁盘上已有产物逐字节一致时跳过写盘，
        // 避免无谓的磁盘刷新与下游 zig 重新编译触发。
        if (readWhole(gen)) |old| {
            if (!std.mem.eql(u8, old, res.zig_str)) try writeWhole(gen, res.zig_str);
        } else |_| {
            try writeWhole(gen, res.zig_str);
        }
        // 把本单位 @embedFile 引用的资源镜像进生成树（zig 相对 .zig 所在目录解析、需与生成文件同层）；镜像根 `.zzc/gen` 做越界写守卫。
        stageEmbedAssets(rel, res.zig_str, gen, ".zzc/gen");
        try proj.units.append(gpa_, .{
            .native_rel = rel,
            .gen_rel = gen,
            .nat_src = nat_src,
            .zig_str = res.zig_str,
            .map = res.map,
        });
    }
    return proj;
}

/// 分隔符无关的路径比较（`/` 与 `\` 视为等价）：采集侧已将 native_rel 归一为 `/`，
/// 但用户传入的 entry 在 Windows 下可能带 `\`，故精确匹配需容忍分隔符差异。第 60 轮下沉 cli 并进测试图。
const samePathRel = cli.samePathRel;

fn findUnit(proj: Project, entry: []const u8) ?Unit {
    for (proj.units.items) |u| {
        if (samePathRel(u.native_rel, entry)) return u;
    }
    // 宽松：按 stem 匹配（用户可能输入 src/main 或 main.zz）
    const want = std.fs.path.stem(entry);
    for (proj.units.items) |u| {
        if (std.mem.eql(u8, std.fs.path.stem(u.native_rel), want)) return u;
    }
    return null;
}

// ---------------------------------------------------------------- zig 子进程与报错回译

/// 执行一次编译；失败时把 stderr 回译成母语打印，返回 error.Failed。
/// `seen` 不为 null 时跨多次调用去重诊断（`zzc check` 传入）。
fn zigCompile(lang: Pack, table: Mangle, proj: Project, argv: []const []const u8, seen: ?*std.StringHashMap(void)) !void {
    const res = std.process.run(gpa_, io_, .{
        .argv = argv,
        .create_no_window = true,
    }) catch {
        printErr("zzc: 无法启动 zig，请确认已安装 Zig 0.17+（PATH 中可找到 zig）", .{});
        return error.Failed;
    };
    defer gpa_.free(res.stdout);
    defer gpa_.free(res.stderr);

    if (res.term.success()) return;

    var units: std.ArrayList(diag.Unit) = .empty;
    for (proj.units.items) |u| {
        try units.append(gpa_, .{
            .native_path = u.native_rel,
            .gen_path = u.gen_rel,
            .gen_src = u.zig_str,
            .nat_src = u.nat_src,
            .map = u.map,
        });
    }
    // 纯母语过滤器接线（台账 D15）：回译/短语兜底后的残留英文句子在此终拦为兜底中文+原文。
    // gpa_ 为进程级 arena，过滤器内部分配随退出统一回收，不做逐次 deinit；
    // 检测规则为词链启发式、与 B2 操作数保留边界对称（孤立类型签名/参数名不误拦，见 pure_filter 单测）；
    // 白名单规则随语言包 `[whitelist]` 段加载（台账 F2，51 轮：工具层零硬编码）；
    // 未翻译清单注入进程级 `untranslated_list`（台账 F3，52 轮：跨多次 zigCompile 累积、出口落盘）。
    var filter: ?PureFilter = PureFilter.init(gpa_, .{}, &untranslated_list) catch null;
    if (filter) |*f| f.applyPackRules(lang.whitelist.items) catch {};
    const native_errs = diag.translateStderr(gpa_, lang, table, units.items, res.stderr, seen, if (filter) |*f| f else null) catch res.stderr;
    werr.writeAll(native_errs) catch |e| {
        printErr("zzc: 写入错误信息失败：{s}", .{@errorName(e)});
    };
    try werr.flush();
    return error.Failed;
}

/// 语言包契约校验失败（台账 B6）的母语描述：错误值逐个命名即为此用——
/// 告诉包作者缺哪条映射、为何工具链需要它（不透传英文错误名）。
fn describePackError(e: PackParseError) []const u8 {
    return switch (e) {
        error.PackMissingCode => "缺少 `$code = xx` 元数据行（语言代码用于版本/列表展示，不得默认为 `??`）",
        error.PackMissingConst => "缺少映射到 `const` 的关键字（声明位识别与 `常数` 单跳数据流预扫描依赖它）",
        error.PackMissingVar => "缺少映射到 `var` 的关键字",
        error.PackMissingFn => "缺少映射到 `fn` 的关键字（入口链与声明位识别依赖它）",
        error.PackMissingIf => "缺少映射到 `if` 的关键字",
        error.PackMissingElse => "缺少映射到 `else` 的关键字",
        error.PackMissingReturn => "缺少映射到 `return` 的关键字",
        error.PackMissingStruct => "缺少映射到 `struct` 的关键字",
        error.PackMissingEnum => "缺少映射到 `enum` 的关键字（枚举成员声明位识别依赖它）",
        error.PackMissingUnion => "缺少映射到 `union` 的关键字（变体名声明位识别依赖它）",
        error.PackMissingSwitch => "缺少映射到 `switch` 的关键字",
        error.PackMissingImport => "缺少映射到 `@import` 的关键字（`.zz` 资产豁免与 import 目标反查依赖它）",
        error.PackMissingEmbedFile => "缺少映射到 `@embedFile` 的关键字（嵌入资产预扫描与 staging 依赖它）",
        error.PackMissingMain => "缺少映射到 `main` 的关键字（语义编译根——含主入口的文件——判据依赖它）",
    };
}

// ---------------------------------------------------------------- 子命令

fn cmdCheck(lang: Pack, table: *Mangle, args: []const []const u8) !void {
    const entry = cli.pickEntry(args).entry;
    const proj = try collectAndTranslate(entry, lang, table);
    // 目标须确属工程（据此定位采集目录并给出母语提示）；但语义编译根取自“含 main 的文件”、
    // 不一定等于用户点名的文件——若点名的是库模块（无 main），直接 `build-exe` 会被 zig 误报
    // `root source file struct 'X' has no member named 'main'`，回译成费解的“成员不存在/查拼写”。
    _ = findUnit(proj, entry) orelse {
        printErr("zzc: {s} 不在工程目录中（收集自 {s}）", .{ entry, std.fs.path.dirname(entry) orelse "." });
        return error.Failed;
    };
    // 在收集到的模块里找语义编译根：按“生成 Zig 里**真正含顶层 `pub fn main(`**”判定
    // （而非仅按文件名 stem=="main"）。修复：入口被改名/写作 app.zz 等（含主函数）时，
    // 旧按 stem 判定会找不到 main、退化成只做浅层 ast-check，令 `u8=300` 这类类型错被静默
    // 放过（check 通过、build/run 却失败）。现按“是否真有 main”选根：① 常规 main.zz 仍深检；
    // ② app.zz（含 main）也被 build-exe；③ 无 main 的纯库工程（含用户点名库文件）不 build-exe、
    // 只 ast-check，不误报“无 main”（库直接 build-exe 会被 zig 报 root has no member named 'main'）。
    var any_fail = false;
    // 跨多次 zig 调用去重：入口 build-exe 会传递性检查导入链上的子模块，
    // 随后的逐模块 ast-check 会对同一错重复报（zig ast-check 会做名字解析）。
    var seen = std.StringHashMap(void).init(gpa_);
    defer seen.deinit();
    // ① 对每个含 main 的根做 build-exe 传递性语义深检（沿 @import 覆盖被导入的库模块，
    // 含用户点名的那个）。临时产物固定同名、串行覆盖即可（用后即弃）。
    for (proj.units.items) |u| {
        if (!cli.zigHasMainFn(u.zig_str)) continue;
        const bin = "-femit-bin=.zzc/tmp_check_root";
        const argv: []const []const u8 = &.{ "zig", "build-exe", u.gen_rel, bin };
        zigCompile(lang, table.*, proj, argv, &seen) catch |e| {
            if (e == error.Failed) {
                any_fail = true;
            } else return e;
        };
    }
    // ② 其余模块（不含 main 者）：仅做 ast-check（源码级语法 + 名字解析，不需要 main）。
    for (proj.units.items) |u| {
        if (cli.zigHasMainFn(u.zig_str)) continue; // 已作为语义根 build-exe
        const chk: []const []const u8 = &.{ "zig", "ast-check", u.gen_rel };
        zigCompile(lang, table.*, proj, chk, &seen) catch |e| {
            if (e == error.Failed) {
                any_fail = true;
                continue; // 继续检查其余文件，汇总所有报错
            }
            return e;
        };
    }
    if (any_fail) return error.Failed;
    printOut("✔ 检查通过：{d} 个方言文件已翻译为合法 Zig", .{proj.units.items.len});
}

const BuildMode = enum { build, run, test_ };

fn cmdBuild(lang: Pack, table: *Mangle, mode: BuildMode, args: []const []const u8) !void {
    // 拆 `--`：后半为程序参数
    var zig_args = args;
    var prog_args: []const []const u8 = &.{};
    for (args, 0..) |a, idx| {
        if (std.mem.eql(u8, a, "--")) {
            zig_args = args[0..idx];
            prog_args = args[idx + 1 ..];
            break;
        }
    }

    const pick = cli.pickEntry(zig_args);
    const entry = pick.entry;
    const proj = try collectAndTranslate(entry, lang, table);
    const unit = findUnit(proj, entry) orelse {
        printErr("zzc: {s} 不在工程目录中（收集自 {s}）", .{ entry, std.fs.path.dirname(entry) orelse "." });
        return error.Failed;
    };

    const stem = std.fs.path.stem(unit.native_rel);
    const ext_bin = if (builtin.os.tag == .windows) ".exe" else "";
    const bin_full = try std.fmt.allocPrint(gpa_, ".zzc/bin/{s}{s}", .{ stem, ext_bin });
    // zig -femit-bin 不会自建目录，需先创建产物目录
    try std.Io.Dir.cwd().createDirPath(io_, ".zzc/bin");

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa_, "zig");
    try argv.append(gpa_, if (mode == .test_) "test" else "build-exe");
    try argv.append(gpa_, unit.gen_rel);
    if (mode != .test_) {
        try argv.append(gpa_, try std.fmt.allocPrint(gpa_, "-femit-bin={s}", .{bin_full}));
    }
    // 透传除入口文件外的其余参数（含各种 zig 旗标及其值）：入口可能在任意位置，
    // 故按 pickEntry 命中的下标剔除，而非假设入口总在首位。
    for (zig_args, 0..) |a, i| {
        if (pick.idx != null and i == pick.idx.?) continue;
        try argv.append(gpa_, a);
    }

    try zigCompile(lang, table.*, proj, argv.items, null);

    switch (mode) {
        .test_ => printOut("✔ zig test 通过", .{}),
        .build => printOut("✔ 产物：{s}", .{bin_full}),
        .run => {
            var run_argv: std.ArrayList([]const u8) = .empty;
            try run_argv.append(gpa_, bin_full);
            try run_argv.appendSlice(gpa_, prog_args);
            var child = try std.process.spawn(io_, .{
                .argv = run_argv.items,
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            defer std.process.Child.kill(&child, io_);
            const term = try child.wait(io_);
            // 编译已成功：用户程序的退出码应忠实回传（脚本契约），而非被压成 1。
            // 正常退出码非 0 → 以其原码结束；异常终止（信号/停止/未知）→ 无可靠码，回落失败。
            const code: ?u8 = switch (term) {
                .exited => |c| c,
                else => null,
            };
            if (cli.runPropagateExitCode(code)) |c| {
                // D38（第 86 轮）：本 exit 是继「正常返回」「bail」之后的第三条退出路径，同样不跑
                // main 帧 defer、永不回分派末尾的 saveSymbols——新 intern 的母语名映射被吞（实测：
                // 用户程序非零退出的 run 后 symbols.txt 缺失，同工程 check 则落盘）。补位持久化；
                // F3 未翻译清单在本路径必空（只由 zigCompile 失败分支注入），无需也补 flush。
                saveSymbols(table.*);
                out_w.flush() catch |e| {
                    printErr("zzc: 刷新标准输出失败：{s}", .{@errorName(e)});
                };
                werr.flush() catch |e| {
                    printErr("zzc: 刷新错误输出失败：{s}", .{@errorName(e)});
                };
                std.process.exit(c);
            } else if (code == null) {
                return error.Failed;
            }
        },
    }
}

fn cmdInit(name: []const u8) !void {
    // 先验工程名：空/`.`/`..`/上溯/绝对名会在预期外的位置建目录写文件（实测 `zzc init ..`
    // 静默把工程建到父目录）。拒绝在任何 createDirPath/writeWhole 副作用之前。给出精确消息+exit 2
    // （与无名字 init 的 error.Usage 退出码一致）；std.process.exit 跳过 defer 刷写，故先显式 flush。
    if (cli.initNameIsUnsafe(name)) {
        printErr("zzc: 工程名 `{s}` 不安全（不能为空、`.`/`..`、上溯路径或绝对路径）；请用相对当前目录的子目录名（如 `zzc init myapp`）。", .{name});
        out_w.flush() catch |e| {
            printErr("zzc: 刷新标准输出失败：{s}", .{@errorName(e)});
        };
        werr.flush() catch |e| {
            printErr("zzc: 刷新错误输出失败：{s}", .{@errorName(e)});
        };
        std.process.exit(2);
    }
    const main_zz = try std.fmt.allocPrint(gpa_, "{s}/src/main.zz", .{name});
    // 防覆盖：入口文件已存在则不写盘，避免清空用户已有工程的劳动成果（幂等、非破坏）。
    if (pathExists(main_zz)) {
        printOut("zzc: 工程 {s} 的入口 {s} 已存在，未覆盖；如需重新初始化请先删除该文件。进入目录后运行：zzc run", .{ name, main_zz });
        return;
    }
    try std.Io.Dir.cwd().createDirPath(io_, name);
    const proj_zz =
        \\// zzc 母语工程模板 —— 在本目录运行 `zzc run` 即可
        \\常数 标准库 = 导入("std");
        \\
        \\公开 函数 主函数() !void {
        \\    变量 数量: 整数 = 10;
        \\    数量 = 数量 + 1;
        \\    标准库.打印("数量是：{d}\n", .{数量});
        \\}
        \\
    ;
    try writeWhole(main_zz, proj_zz);
    printOut("已创建工程 {s}（src/main.zz）。进入目录后运行：zzc run", .{name});
}

/// 判断 eject 目标是否会与源码树重叠的纯谓词已移到 cli.ejectDestHitsSourceTree（属
/// zzc_core 测试图，才能真跑单测）；下方 cmdEject 直接调用它。
fn cmdEject(lang: Pack, table: *Mangle, args: []const []const u8) !void {
    const dest = if (args.len > 0) args[0] else "standard";
    // 防毁源：在做任何工作（采集/翻译/写盘/清空）前先拒绝与源码树重叠的目标。
    if (cli.ejectDestHitsSourceTree(dest)) {
        printErr("zzc: eject 目标 `{s}` 会与方言源码目录 `src` 重叠或越出工程根，可能误删源码；请导出到一个独立的子目录（如 `zzc eject standard`）。", .{dest});
        return error.Failed;
    }
    const proj = try collectAndTranslate("src/main.zz", lang, table);

    // eject 产出的是可独立 `zig build` 的可执行程序，须有 `main` 入口；纯库工程无从毕业，
    // 提前母语拒绝，避免写出指向缺失 src/main.zig 的坏 build.zig 再报“验证未通过”的误导。
    // 选入口的判据与 cmdCheck 同构：按“生成 Zig 真含顶层 main”而非文件名 stem=="main"（后者与
    // 第二十三轮修 check 前同病——入口改名 app.zz 含合法 main 时误射“未找到 main”假拒、无法 eject）。
    var main_unit_idx: ?usize = null;
    for (proj.units.items, 0..) |u, i| {
        if (cli.zigHasMainFn(u.zig_str)) {
            main_unit_idx = i;
            break;
        }
    }
    const mu = if (main_unit_idx) |i| proj.units.items[i] else {
        printErr("zzc: 未找到 `main` 入口模块，无法 eject 为可执行程序；eject 需要一个含 `主函数`（main）的工程（纯库模块请用 `zzc check <文件>` 校验）。", .{});
        return error.Failed;
    };

    // 陈旧文件清理：`dest/src` 是完全由方言工程派生的输出目录。若上次 eject 后有模块
    // 被改名/删除（如 `sub/mod.zz`→`sub/core.zz`），仅靠逐文件覆写会残留已无方言对应的
    // 孤儿 `.zig`——它仍随 `.paths = "src"` 打进毕业包、误导使用者。故先整体清空 `dest/src`
    // 再重写，保证导出树与当前工程一一对应（`writeWhole` 会自动重建所需子目录）。
    const dest_src = try std.fmt.allocPrint(gpa_, "{s}/src", .{dest});
    if (pathExists(dest_src)) {
        std.Io.Dir.cwd().deleteTree(io_, dest_src) catch |e| {
            printErr("zzc: 清理旧导出目录 `{s}/src` 失败（{s}）；请手动删除后重试 eject。", .{ dest, @errorName(e) });
            return error.Failed;
        };
    }

    for (proj.units.items) |u| {
        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(gpa_, "// 由 zzc eject 导出的标准 Zig。母语符号对照表：\n");
        for (table.symbols.items) |s| {
            try content.appendSlice(gpa_, "//   ");
            try content.appendSlice(gpa_, s.native);
            try content.appendSlice(gpa_, " -> ");
            try content.appendSlice(gpa_, s.ascii);
            try content.append(gpa_, '\n');
        }
        try content.appendSlice(gpa_, "\n");
        try content.appendSlice(gpa_, u.zig_str);
        // 保留子目录结构：gen_rel 形如 `.zzc/gen/src/sub/mod.zig`，去掉 `.zzc/gen/` 前缀
        // 得到 `src/sub/mod.zig`，据此写入导出根；若只取 basename 会拉平子目录，
        // 导致导出后的 main.zig 中 `@import("sub/mod.zig")` 找不到文件、`zig build` 失败。
        const gen_rel = u.gen_rel;
        const rel = if (std.mem.startsWith(u8, gen_rel, ".zzc/gen/"))
            gen_rel[".zzc/gen/".len..]
        else
            std.fs.path.basename(gen_rel);
        const out_zig = try std.fmt.allocPrint(gpa_, "{s}/{s}", .{ dest, rel });
        try writeWhole(out_zig, content.items);
        // 随毕业一并把 @embedFile 引用的资源从 src/ 拷进 dest（dest 下的 .zig 位置与生成树同构）；
        // 不搬则毕业后独立 `zig build` 会因 `@embedFile` 打不开目标而失败。镜像根 dest 做越界写守卫。
        stageEmbedAssets(u.native_rel, u.zig_str, out_zig, dest);
    }

    // 自动迁移：写一份可直接 `zig build` 的 build.zig + build.zig.zon，作为毕业路径。
    // 入口选取与 build.zig 的 root_source_file 都按 mu（含 main 的单元）而非硬编码 src/main.zig：
    // - app_name：main.zz→"app"（历史约定、demos 依赖）；其他入口取自身 stem 自然反映名字（app.zz→app）；
    // - entry_rel：导出后入口在 dest 下的相对路径（与 writeWhole 使用的同一变换），build.zig 据此定位。
    const entry_stem = std.fs.path.stem(mu.native_rel);
    const app_name: []const u8 = if (std.mem.eql(u8, entry_stem, "main")) "app" else entry_stem;
    const entry_rel = if (std.mem.startsWith(u8, mu.gen_rel, ".zzc/gen/"))
        mu.gen_rel[".zzc/gen/".len..]
    else
        std.fs.path.basename(mu.gen_rel);
    const build_zig = try std.fmt.allocPrint(gpa_,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\    const exe = b.addExecutable(.{{
        \\        .name = "{s}",
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("{s}"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }}),
        \\    }});
        \\    b.installArtifact(exe);
        \\}}
        \\
    , .{ app_name, entry_rel });
    try writeWhole(try std.fmt.allocPrint(gpa_, "{s}/build.zig", .{dest}), build_zig);

    // Zig 0.17 的 `zig build` 要求 build.zig.zon 含顶层 fingerprint（u64）。
    // 其高 32 位由包名派生、不可自行伪造（伪造会被判为 invalid），低 32 位是随机盐（由 zig 每次
    // `zig build` 的随机 --seed 派生）。因此首次导出先写一份不带 fingerprint 的 zon，让本机 zig
    // 告诉我们一个合法值，再回写。
    // 幂等：但重复 eject 到同一目标时，若沿用“每次重新探测”会因低半随机而让 build.zig.zon
    // 逐次产生无谓差异、破坏“字节级可复现”。故先读目标既有 zon 里的 fingerprint，命中则复用（跳过探测）。
    const zon_path = try std.fmt.allocPrint(gpa_, "{s}/build.zig.zon", .{dest});
    const existing_fp = readExistingFingerprint(dest, app_name);
    try writeWhole(zon_path, try ejectZoneText(app_name, null));
    const fp = existing_fp orelse probeFingerprint(dest);
    if (fp) |t| {
        try writeWhole(zon_path, try ejectZoneText(app_name, t));
    } else {
        printErr("zzc: 未能向 zig 查询包 fingerprint（zig 不可用？）；zon 暂缺该字段，首次 `zig build` 会提示合法值。", .{});
    }

    // 验证“毕业路径”：进入导出目录直接 `zig build`，确认可独立构建。
    switch (verifyBuild(dest)) {
        .ok => printOut("已导出标准 Zig 到 {s}/（含 build.zig + build.zig.zon）；`zig build` 验证通过，产物：{s}/zig-out/bin/{s}。", .{ dest, dest, app_name }),
        .fail => {
            printErr("zzc: 导出完成，但 `zig build` 验证未通过，请进入 {s}/ 手动排查。", .{dest});
            return error.Failed;
        },
        .no_zig => printOut("已导出标准 Zig 到 {s}/（含 build.zig）；未检测到 zig，无法自动验证构建。", .{dest}),
    }
}

/// 生成 eject 的 build.zig.zon 文本；fp 为工具链建议的 `0x....` 十六进制串（可为 null）。
fn ejectZoneText(app_name: []const u8, fp: ?[]const u8) ![]const u8 {
    var z: std.ArrayList(u8) = .empty;
    try z.appendSlice(gpa_, "// 由 zzc eject 生成；可独立 `zig build` 构建。\n.{\n");
    try z.appendSlice(gpa_, try std.fmt.allocPrint(gpa_, "    .name = .{s},\n", .{app_name}));
    try z.appendSlice(gpa_, "    .version = \"0.1.0\",\n");
    if (fp) |t| try z.appendSlice(gpa_, try std.fmt.allocPrint(gpa_, "    .fingerprint = {s},\n", .{t}));
    try z.appendSlice(gpa_, "    .minimum_zig_version = \"0.17.0\",\n");
    try z.appendSlice(gpa_, "    .dependencies = .{},\n");
    try z.appendSlice(gpa_, "    .paths = .{\n        \"build.zig\",\n        \"build.zig.zon\",\n        \"src\",\n    },\n}\n");
    return z.toOwnedSlice(gpa_);
}

/// 在 dest 目录跑一次 `zig build`，从报错中抽取工具链建议的 fingerprint（形如 `0x....`）。
/// 取 `value: 0x` 之后的十六进制串；missing 与 invalid 两种措辞都含此子串。
fn probeFingerprint(dest: []const u8) ?[]const u8 {
    const res = std.process.run(gpa_, io_, .{
        .argv = &.{ "zig", "build" },
        .cwd = .{ .path = dest },
        .create_no_window = true,
    }) catch return null;
    defer gpa_.free(res.stdout);
    defer gpa_.free(res.stderr);

    const marker = "value: 0x";
    const idx = std.mem.indexOf(u8, res.stderr, marker) orelse return null;
    const digits_start = idx + marker.len; // 指向第一个十六进制位（0x 之后）
    var end = digits_start;
    while (end < res.stderr.len and std.ascii.isHex(res.stderr[end])) end += 1;
    if (end == digits_start) return null;
    // 连同前缀 `0x` 一并返回。
    const zero_x = idx + (marker.len - 2); // "0x" 起始位置
    return gpa_.dupe(u8, res.stderr[zero_x..end]) catch null;
}

/// 读目标目录既有 `build.zig.zon` 中的 fingerprint（`0x` 十六进制串，含前缀，gpa_ 拥有）；
/// 不存在文件/无该字段时返回 null。解析逻辑在测试图内的 cli.parseFingerprintFromZone（可真跑单测）。
fn readExistingFingerprint(dest: []const u8, app_name: []const u8) ?[]const u8 {
    const zon_path = std.fmt.allocPrint(gpa_, "{s}/build.zig.zon", .{dest}) catch return null;
    defer gpa_.free(zon_path);
    const text = readWhole(zon_path) catch return null;
    defer gpa_.free(text);
    const found = cli.parseFingerprintFromZone(text, app_name) orelse return null;
    return gpa_.dupe(u8, found) catch null;
}

const BuildVerify = enum { ok, fail, no_zig };

/// 跑 `zig build` 验证毕业构建可独立成功。
fn verifyBuild(dest: []const u8) BuildVerify {
    const res = std.process.run(gpa_, io_, .{
        .argv = &.{ "zig", "build" },
        .cwd = .{ .path = dest },
        .create_no_window = true,
    }) catch return .no_zig;
    defer gpa_.free(res.stdout);
    defer gpa_.free(res.stderr);
    return if (res.term.success()) .ok else .fail;
}

fn constTable(t: *const Mangle) *Mangle {
    return @constCast(t);
}

/// 统一失败退出：把已缓冲的输出刷出后静默退出，
/// 避免把 zzc 自身的 Zig 错误返回跟踪（stderr 栈帧）暴露给方言用户。
fn bail(e: anyerror) noreturn {
    switch (e) {
        error.Usage => printErr("zzc: 未知或不完整的子命令；运行不带参数的 zzc 查看用法。", .{}),
        error.Failed => {}, // 母语报错已在编译阶段打印，无需重复
        // D36（第 84 轮）：符号表被手工编辑出同一 z_N 归两个不同母语名——若不容忍静默合并，
        // 必须源头拒并点名文件与修法（两标识符转码后共享同名会静默改变程序语义）。
        error.DuplicateSymbol => printErr("zzc: 符号表 .zzc/symbols.txt 撞号：同一编号被分给两个不同母语名。请删除该文件让 zzc 重建（生成码标识符编号会变、程序语义不变），或手工改正冲突行。", .{}),
        // 常见文件系统/内存错误给纯母语可操作提示（避免把 `NotDir`/`AccessDenied` 等
        // Zig 内部英文标识符直接泄给方言用户）；未收录错误保留中文句式、仅附一个诊断码。
        else => {
            if (cli.localizeFsErr(e)) |zh| {
                printErr("zzc: {s}", .{zh});
            } else {
                printErr("zzc: 操作未能完成（诊断码 {s}）；请重试，若持续失败请携此码反馈。", .{@errorName(e)});
            }
        },
    }
    // bail 是 noreturn（exit 不跑 main 帧 defer）：落盘须在此补位（F3），与 main 的 defer 二选一命中。
    // D46（第 101 轮）：同理 saveSymbols 也须在失败退出前补位——D38 只接了 run 分支 exit(c)
    // 那条退出路径，bail 这条形同根因的遗漏面由 e2e 探针实锤（eject `.fail`/check 语义错后
    // symbols.txt 缺失，同工程修好走正常返回则落盘）。loadSymbols 成功后 bail_table 才非 null，
    // 半解析表（DuplicateSymbol）与无表场景（init/--lang）天然不写回。正常返回走 main 末尾
    // saveSymbols、bail 路径 noreturn，二者互斥无双写。
    if (bail_table) |t| saveSymbols(t.*);
    flushUntranslated();
    out_w.flush() catch |flush_err| {
        printErr("zzc: 刷新标准输出失败：{s}", .{@errorName(flush_err)});
    };
    werr.flush() catch |flush_err| {
        printErr("zzc: 刷新错误输出失败：{s}", .{@errorName(flush_err)});
    };
    std.process.exit(if (e == error.Usage) 2 else 1);
}

// ---------------------------------------------------------------- 入口

pub fn main(init: std.process.Init) !void {
    gpa_ = init.arena.allocator();
    io_ = init.io;
    diag.setIo(io_); // F3：产品时间源注入诊断层（单测图不注入、取时回 0）
    // 未翻译清单落盘（F3）：正常返回走下方 defer；失败退出在 bail 内 exit 前补刷——
    // `std.process.exit` 不跑调用帧 defer，而编译失败恰是兜底高发场景。
    defer flushUntranslated();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = Io.File.Writer.init(.stdout(), io_, &stdout_buf);
    out_w = &stdout_file.interface;
    defer out_w.flush() catch |e| {
        printErr("zzc: 刷新标准输出失败：{s}", .{@errorName(e)});
    };

    var wbuf: [4096]u8 = undefined;
    var werr_file_local = Io.File.Writer.init(.stderr(), io_, &wbuf);
    werr = &werr_file_local.interface;
    defer werr.flush() catch |e| {
        printErr("zzc: 刷新错误输出失败：{s}", .{@errorName(e)});
    };

    // all_args[0] 是可执行文件自身路径，子命令从 [1] 开始
    const all_args = try init.minimal.args.toSlice(gpa_);
    if (all_args.len < 2) {
        printOut("{s}", .{cli.usage_text});
        return;
    }
    const cmd = all_args[1];
    const args = all_args[2..];

    // 惯例帮助旗标：`--help`/`-h`/`-?`/`help` 都应打印用法并成功退出（而非当未知子命令报 EXIT=2）。
    // 放在解析语言包之前：用法文本静态、不依赖 lang。
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or
        std.mem.eql(u8, cmd, "-?") or std.mem.eql(u8, cmd, "help"))
    {
        printOut("{s}", .{cli.usage_text});
        return;
    }

    // R9（第 52 轮）：`--lang` 选包——cli 解旗标 + registry 按名取包；缺省用注册表默认（中文）。
    // 旗标从透传参数中剔离，不会进入 zig（check/build/run/test/eject 只看 argv）。
    const chosen: registry.Entry = if (cli.findLangFlag(args)) |n|
        registry.lookup(n) orelse {
            printErr("zzc: 未知语言包「{s}」。当前可用：", .{n});
            for (registry.entries) |p| printErr("{s}({s}) ", .{ p.key, p.display });
            printErr("\n", .{});
            werr.flush() catch {};
            std.process.exit(2); // 尚未编译、无兼底项待落盘；直接退 2（与 error.Usage 同码）
        }
    else
        registry.defaultEntry();
    var filtered = cli.stripLangFlag(gpa_, args) catch |e| {
        printErr("zzc: 参数处理失败（{s}）。", .{@errorName(e)});
        return e;
    };
    defer filtered.deinit(gpa_);
    const argv = filtered.items;

    // R11（第 53 轮）：基包 + 补充层叠加加载（当前 zh 无补充层，overlays 为空→等价单包）。
    var lang = Pack.loadWithOverlays(gpa_, chosen.bytes, chosen.overlays) catch |e| {
        printErr("zzc: 语言包解析失败（{s}），这属于工具自身缺陷，请反馈。", .{@errorName(e)});
        return error.Failed;
    };
    defer lang.deinit();
    // 契约面校验（B6）：登记的包理应恒通过（有单测锁定）；失败即工具缺陷，母语报错不外泄 error 名。
    lang.validate() catch |e| {
        printErr("zzc: 语言包不完整：{s}", .{describePackError(e)});
        return error.Failed;
    };

    if (std.mem.eql(u8, cmd, "version")) {
        printOut("zzc {s}（语言包：{s}）", .{ version_str, lang.name });
        return;
    }
    if (std.mem.eql(u8, cmd, "lang")) {
        // R9：反映注册表——除当前选定包详情外，列出可注册的包名（多包加载面可见）。
        printOut("当前语言包：{s}({s}) —— 关键字 {d} 条 / 路径别名 {d} 条 / 报错模式 {d} 条\n可注册包：", .{
            lang.name, chosen.code, lang.keywords.count(), lang.aliases.count(), lang.diagnostics.items.len,
        });
        for (registry.entries) |p| printOut("{s}({s}) ", .{ p.key, p.display });
        printOut("\n", .{});
        return;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        if (argv.len < 1) bail(error.Usage);
        cmdInit(argv[0]) catch |e| bail(e);
        return;
    }

    var table = Mangle.init(gpa_);
    defer table.deinit();
    loadSymbols(&table) catch |e| bail(e); // 此线之前 bail_table 为 null：半解析表不落盘（D46）
    bail_table = &table; // D46：自此表已全量就位，任何失败 bail 前补位持久化

    if (std.mem.eql(u8, cmd, "check")) {
        cmdCheck(lang, &table, argv) catch |e| bail(e);
    } else if (std.mem.eql(u8, cmd, "build")) {
        cmdBuild(lang, &table, .build, argv) catch |e| bail(e);
    } else if (std.mem.eql(u8, cmd, "run")) {
        cmdBuild(lang, &table, .run, argv) catch |e| bail(e);
    } else if (std.mem.eql(u8, cmd, "test")) {
        cmdBuild(lang, &table, .test_, argv) catch |e| bail(e);
    } else if (std.mem.eql(u8, cmd, "eject")) {
        cmdEject(lang, &table, argv) catch |e| bail(e);
    } else {
        // 显式给出未知/拼错的子命令（如 `zzc runn`）必须以非零码失败：旧行为只把用法打到
        // stdout 并 return→exit 0，会让 CI/脚本把拼错的命令误判为成功。走 error.Usage 统一提示并 exit 2。
        bail(error.Usage);
    }
    saveSymbols(table);
}
// 基础 IO 的读写/BOM/pathExists 单测已随函数下沉至 file_io.zig（第 62 轮，zzc_core 测试图内真跑）。
// main.zig 不在测试图、其 test 块从不执行，原此四段死测（且引用 0.17 已移除的 std.fs.createFileAbsolute/
// std.testing.tmpDir 等旧 API、根本编译不过）予以删除。
