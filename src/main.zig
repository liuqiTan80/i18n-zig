//! zzc —— 用母语编写真正的 Zig。
//!
//! 子命令：
//!   zzc init <项目名>       生成母语工程骨架
//!   zzc check [文件.zz]     翻译 + 词法/编译检查（母语报错）
//!   zzc build [文件.zz]     翻译 -> zig build-exe（其余参数透传 zig）
//!   zzc run   [文件.zz]     编译并运行，`--` 之后为程序参数
//!   zzc test  [文件.zz]     翻译 -> zig test
//!   zzc eject [目录]        导出标准 Zig 工程（毕业路径）
//!   zzc lsp                 启动 LSP 服务器（JSON-RPC over stdio，第 156 轮）
//!   zzc lang                列出当前语言包与可注册包；`lang add` 装入外部包（R9g 第二档）
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
const UntranslatedPhrase = @import("diag/pure_filter.zig").UntranslatedPhrase; // 192 T1 造清单 entry 用（生产侧经 UntranslatedList 间接引用、无此别名先例）
const cli = @import("cli/args.zig");
const file_io = @import("file_io.zig");
const registry = @import("lang/registry.zig");
const userpack = @import("lang/userpack.zig");
const lsp = @import("lsp/server.zig");
const lsp_jsonrpc = @import("lsp/jsonrpc.zig");

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

/// 机读单行化开关（第 154 轮 · `--machine`）：把已回译的母语报错压成每条一行供
/// 编辑器 problemMatcher / CI 逐行正则消费；默认关（人读块形制一字不变）。
/// 取进程级变量形制（同 `untranslated_list`/`bail_table` 先例）：消费点 zigCompile 被多处
/// 调用、为它多穿一层参只会把默认形制的调用点弄胖；main 不入测试图，压行本体逻辑
/// （diag.machineLines）已在测试图内单测，本旗标只做接线（行为面由 demos e2e 守卫钉）。
var machine_mode: bool = false;

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
    // 机读出口（第 154 轮 `--machine`）：只改写已回译的母语输出、不改退出码与去重逻辑；
    // 压行失败即退回原形制（辅面异常不得吞主报错，同 flushUntranslated 落盘面形制）。
    var out_txt: []const u8 = native_errs;
    if (machine_mode) {
        out_txt = diag.machineLines(gpa_, native_errs) catch native_errs;
    }
    werr.writeAll(out_txt) catch |e| {
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

/// R9g（第 103 轮）：外部语言包文件装载真相源（第三方发行包、运行时加载免重编译）。
/// 各失败形面向贡献者母语报出（区别于内置包的「工具自身缺陷」措辞）；契约缺失由调用处
/// 统一 validate（同一消息形制、携路径）。字节不 free：Pack 键值为借用视图（pack.zig
/// 存活期约定），gpa_ 为 arena 活到进程退出天然满足；FileNotFound 等可行动错误源头母语。
fn loadExternalPack(path: []const u8) !Pack {
    const bytes = readWhole(path) catch |e| switch (e) {
        error.FileNotFound => {
            printErr("zzc: 外部语言包文件不存在：{s}", .{path});
            return error.Failed;
        },
        else => return e, // 超限/权限等：readWhole 母语前缀或 bail 的 localizeFsErr 双层拦截既有形
    };
    return Pack.parse(gpa_, bytes) catch |e| switch (e) {
        error.PackFormatTooNew => {
            printErr("zzc: 外部语言包「{s}」声明的 $format 过新（当前 zzc 仅支持格式 {d}）。请升级 zzc。", .{ path, Pack.supported_format });
            return error.Failed;
        },
        error.InvalidLangPack => {
            printErr("zzc: 外部语言包「{s}」解析失败：行式语法错（未知段头/空键或值/同层键冲突/$format 非数等），请按 docs/contributing-lang-pack.md 检查。", .{path});
            return error.Failed;
        },
        else => return e, // OOM 等工具层错误传播致 bail
    };
}

// ---------------------------------------------------------------- 子命令

/// R9g 第二档（第 140 轮）：`zzc lang add <文件> [--as 注册名]`——把校验通过的外部包**装进当前工程**
/// （`.zzc/lang/<名>.txt`），此后 `--lang <名>` 免重编译直接命中。装载与契约校验复用第一档同一真相源
/// （`loadExternalPack` + `validate`，贡献者向母语消息）；策略面（注册名白名单/防覆盖/原样落位/
/// 穿越拒读）在测试图内的 `lang/userpack.zig`——main 不入测试图，放这里的代码一行也不会被单测跑到，
/// 故本函数只做参数拆解、消息与退出码。
/// 副作用顺序：拆参 → 装载校验（零写盘）→ 注册名封口（零写盘）→ install。坏包/坏名一律不留半个文件。
fn cmdLangAdd(args: []const []const u8) void {
    const file = if (args.len > 0) args[0] else {
        printErr("zzc: lang add 需要语言包文件：`zzc lang add <文件> [--as 注册名]`。", .{});
        werr.flush() catch {};
        std.process.exit(2); // 用法错与未知包/未知动词同码（与 error.Usage 一致）
    };
    var pk = loadExternalPack(file) catch |e| bail(e); // 不存在/$format 过新/语法错均已在源头母语报出
    defer pk.deinit();
    // B6 契约硬门：不合格包装进来后只在 `--lang` 选中它时才在流程深处报缺——将“坏包”变成工程内的
    // 定时炸弹，故装前即拒（与第一档加载时 validate 同一判据、同一消息形制）。
    pk.validate() catch |e| {
        printErr("zzc: 外部语言包「{s}」不完整：{s}", .{ file, describePackError(e) });
        werr.flush() catch {};
        bail(error.Failed); // noreturn：退 1、不外泄 error 名与栈帧
    };
    const key = cli.findFlag(args, "--as") orelse pk.code; // 缺省取包内 $code（与内置注册名同源）
    if (!userpack.keyIsSafe(key)) {
        printErr("zzc: 注册名「{s}」不可用——须为 ASCII 字母/数字/-/_，不以 . 或 - 开头，至多 {d} 字（注册名会直接成为文件名与命令行选择名）。可 --as 另起；展示名仍用包内 $name，不受此限。", .{ key, userpack.max_key_len });
        werr.flush() catch {};
        std.process.exit(2);
    }
    // 二次读同一文件：校验用的是 Pack 结构、落位用原字节（包体不得被加工——第一档装载器同样吃它）。
    const bytes = readWhole(file) catch |e| bail(e);
    userpack.install(io_, gpa_, userpack.default_dir, key, bytes) catch |e| switch (e) {
        error.BadKey => unreachable, // 上面已拦
        error.AlreadyInstalled => {
            printErr("zzc: 本工程内已装有语言包「{s}」（{s}/{s}.txt）。不覆盖既有包：请 --as 另起注册名，或先手工删除该文件。", .{ key, userpack.default_dir, key });
            werr.flush() catch {};
            std.process.exit(2); // 与 init 防覆盖形制一致：退 2 且原文件逐字节不动
        },
        else => bail(e), // 权限/IsDir/超限等：bail 的 localizeFsErr 母语兜底既有形
    };
    printOut("✔ 已装入语言包「{s}({s})」→ {s}/{s}.txt；用 `--lang {s}` 选用（免重编译，仅本工程可见）。", .{ pk.name, key, userpack.default_dir, key, key });
}

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

fn cmdInit(name: []const u8, lang: Pack) !void {
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
    // 模板生成器 cli.buildInitTemplate（D48 第 104 轮下沉 + 第 142 轮按包组词 i18n）：进测试图被
    // 零违例纯测钉住，防再被历轮契约升格漏 dogfood 而「工具拒自家脚手架」；旧常量形恒为中文词，
    // 选外语包时出生即碎码（探针 T2 实锤）——现在全部词形取自所选包、缺则安全降级。
    const tmpl_src = try cli.buildInitTemplate(gpa_, lang);
    try writeWhole(main_zz, tmpl_src);
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

// ---------------------------------------------------------------- LSP 接线

/// 语义诊断解析自 `zzc check --machine` 单行：`<file>:<line>:<col>: <kind>: <msg>`
/// （file/line/col 已是回映到 .zz 源的工程相对路径 + 1 基字符行列、kind/msg 已回译纯中文）。
/// 与 problemMatcher 正则 `^([^\s:].*?):(\d+):(\d+): (\S+): (.*)$` 同一契约、同一真相源。
const MachineDiag = struct { file: []const u8, line: usize, col: usize, kind: []const u8, message: []const u8 };

fn parseMachineDiag(line: []const u8) ?MachineDiag {
    if (line.len == 0) return null;
    if (line[0] == ' ' or line[0] == '\t' or line[0] == ':') return null; // 顶格无空白/无前导冒号
    const c1 = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const file = line[0..c1];
    if (file.len == 0) return null;
    var i = c1 + 1;
    const ln_start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == ln_start) return null;
    const ln = std.fmt.parseInt(usize, line[ln_start..i], 10) catch return null;
    if (i >= line.len or line[i] != ':') return null;
    i += 1;
    const col_start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == col_start) return null;
    const coln = std.fmt.parseInt(usize, line[col_start..i], 10) catch return null;
    if (i >= line.len or line[i] != ':') return null;
    i += 1;
    if (i >= line.len or line[i] != ' ') return null; // 坐标段后须 ": "
    i += 1;
    const k_start = i;
    while (i < line.len and line[i] != ' ' and line[i] != ':') i += 1;
    const kind = line[k_start..i];
    if (kind.len == 0) return null;
    if (i >= line.len or line[i] != ':') return null;
    i += 1;
    if (i >= line.len or line[i] != ' ') return null; // kind 段后须 ": "
    i += 1;
    if (i >= line.len) return null;
    return .{ .file = file, .line = ln, .col = coln, .kind = kind, .message = line[i..] };
}

/// 机读 kind（`kind_zh` 值面）→ LSP DiagnosticSeverity（1..4）；未知退 1（错误）。
fn kindSeverity(kind: []const u8) u8 {
    if (std.mem.eql(u8, kind, "\u{8B66}\u{544A}")) return 2; // 警告
    if (std.mem.eql(u8, kind, "\u{8BF4}\u{660E}")) return 3; // 说明
    if (std.mem.eql(u8, kind, "\u{88AB}\u{5F15}\u{7528}\u{4E8E}")) return 4; // 被引用于
    return 1; // 错误 / 内部错误 / 其他
}

/// 机读 `file`（工程相对、`/` 分隔）是否属于当前文档（basename 匹配、需词边界）。
fn fileMatchesDoc(mfile: []const u8, base: []const u8) bool {
    if (!std.mem.endsWith(u8, mfile, base)) return false;
    if (mfile.len == base.len) return true;
    const before = mfile[mfile.len - base.len - 1];
    return before == '/' or before == '\\';
}

/// LSP URI → 文件系统绝对路径（剥 file://、驱符前导斜杠、百分号解码、Windows 分隔符归一）。
fn uriToFilesystemPath(a: std.mem.Allocator, uri: []const u8) ?[]const u8 {
    var s = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else return null;
    if (s.len >= 3 and s[0] == '/' and std.ascii.isAlphabetic(s[1]) and s[2] == ':') s = s[1..]; // 去盘符前导 /
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var j: usize = 0;
    while (j < s.len) {
        if (s[j] == '%' and j + 2 < s.len) {
            const b = std.fmt.parseInt(u8, s[j + 1 .. j + 3], 16) catch {
                out.append(a, s[j]) catch return null;
                j += 1;
                continue;
            };
            out.append(a, b) catch return null;
            j += 3;
        } else {
            out.append(a, s[j]) catch return null;
            j += 1;
        }
    }
    const dec = out.toOwnedSlice(a) catch return null;
    if (builtin.os.tag == .windows) {
        for (dec) |*c| {
            if (c.* == '/') c.* = '\\';
        }
    }
    return dec;
}

/// 真语义供给器（IO 侧、不入测试图）：didSave 时 spawn 一个短命 `zzc check --machine <入口>`
/// 子进程（自带干净 arena、退出即回收，父 LSP 长活 arena 零增长），解其 stderr 机读行→语义项。
/// 暂存 arena 每调用开头 reset(.retain_capacity)，返回项为本次调用期内有效的借用切片。
const LspSemantic = struct {
    exe: ?[]const u8, // 本可执行文件绝对路径（拿不到则语义面优雅降级为空、不影响快路/悬停）
    scratch: std.heap.ArenaAllocator,

    fn run(self: *LspSemantic, uri: []const u8) []lsp.SemanticItem {
        const exe = self.exe orelse return &.{};
        _ = self.scratch.reset(.retain_capacity);
        const a = self.scratch.allocator();
        const fs_path = uriToFilesystemPath(a, uri) orelse return &.{};
        const dir = std.fs.path.dirname(fs_path) orelse return &.{};
        const base = std.fs.path.basename(fs_path);
        const argv = &.{ exe, "check", "--machine", base };
        const res = std.process.run(a, io_, .{
            .argv = argv,
            .cwd = .{ .path = dir },
            .create_no_window = true,
        }) catch return &.{};
        var items: std.ArrayList(lsp.SemanticItem) = .empty;
        var it = std.mem.splitScalar(u8, res.stderr, '\n');
        while (it.next()) |rawline| {
            const line = std.mem.trimEnd(u8, rawline, "\r");
            const d = parseMachineDiag(line) orelse continue;
            if (!fileMatchesDoc(d.file, base)) continue;
            const lnz = if (d.line > 0) d.line - 1 else 0;
            const cnz = if (d.col > 0) d.col - 1 else 0;
            items.append(a, .{
                .line = lnz,
                .character = cnz,
                .char_len = 0, // 单字符下划（核内视作 1）
                .severity = kindSeverity(d.kind),
                .message = d.message, // 借用自暂存 arena，下次 reset 前有效
            }) catch return &.{};
        }
        return items.items;
    }
};

fn lspSemanticCall(ctx: *anyopaque, uri: []const u8, text: []const u8) []lsp.SemanticItem {
    _ = text; // 编译取盘上已存文件（==刚保存文本），坐标回映不依赖内存文本
    const self: *LspSemantic = @ptrCast(@alignCast(ctx));
    return self.run(uri);
}

/// LSP 服务器（第 156 轮）：JSON-RPC over stdio 帧环流。stdout 专供协议帧、
/// 人读消息一律走 stderr（启动失败/流断坏）；分发核（能力/诊断/悬停）全在
/// lsp/server.zig 测试图内单测，此处只做 stdin→handle→stdout 的字节搬运。
fn cmdLsp(lang: Pack) void {
    var srv = lsp.Server.init(gpa_, &lang); // lang 形参与函数体同寿，&lang 安全
    defer srv.deinit();

    // 第 159 轮：接上真语义供给器——didSave 时按需起 `zzc check --machine` 子进程拿语义诊断。
    // 本可执行文件绝对路径取不到则 exe=null、语义面优雅降级为空（didSave 退化为仅重发快路）。
    var sem = LspSemantic{
        .exe = std.process.executablePathAlloc(io_, gpa_) catch null,
        .scratch = std.heap.ArenaAllocator.init(gpa_),
    };
    defer sem.scratch.deinit();
    srv.semantic = .{ .ctx = @ptrCast(&sem), .call = &lspSemanticCall };

    var in_buf: [8192]u8 = undefined;
    var in_r = Io.File.Reader.init(.stdin(), io_, &in_buf);
    var pend: std.ArrayList(u8) = .empty; // 跨帧未解析字节

    while (true) {
        // 缓冲内逐帧消费
        while (true) {
            const f = lsp_jsonrpc.parseFrame(pend.items) catch |e| {
                printErr("zzc: LSP 帧解析失败（{s}），流已不可信，结束。", .{@errorName(e)});
                werr.flush() catch {};
                return;
            };
            const frame = f orelse break;
            var out: lsp.OutList = .empty;
            srv.handle(frame.body, &out) catch {
                printErr("zzc: LSP 处理本条报文失败（内存不足），已跳过。\n", .{});
            };
            defer {
                for (out.items) |m| gpa_.free(m);
                out.deinit(gpa_);
            }
            var io_broke = false;
            for (out.items) |m| {
                const enc = lsp_jsonrpc.encodeFrame(gpa_, m) catch {
                    io_broke = true;
                    break;
                };
                defer gpa_.free(enc);
                out_w.writeAll(enc) catch {
                    io_broke = true;
                    break;
                };
            }
            out_w.flush() catch {
                io_broke = true;
            };
            if (io_broke) {
                printErr("zzc: LSP 标准输出写入失败，客户端已断开，结束。\n", .{});
                return;
            }
            // 消费已处理字节
            const rest = pend.items[frame.consumed..];
            std.mem.copyForwards(u8, pend.items, rest);
            pend.shrinkRetainingCapacity(rest.len);
            if (srv.stop) return; // exit 通知：环流结束（调用方 main 自然退 0）
        }
        // 不足一帧：续读 stdin
        var chunk: [4096]u8 = undefined;
        const n = in_r.interface.readSliceShort(&chunk) catch 0;
        if (n == 0) return; // stdin 关闭：客户端断开，正常收束
        pend.appendSlice(gpa_, chunk[0..n]) catch {
            printErr("zzc: LSP 读缓冲耗尽（内存不足），结束。\n", .{});
            return;
        };
    }
}

// ---------------------------------------------------------------- 入口

/// R11（第 164 轮）：版本漂移早警。一次性 spawn `zig version`，解析成功且非标定基线时把母语
/// 告警走 stdout（人读提示、非错误）。zig 缺失 / 退出非零 / 解析失败一律静默（不误报、不增失败
/// 面——真实编译失败自有「无法启动 zig」母语提示兜底）。本机恒为标定基线 0.17 → 恒静默、
/// 既有 stdout 契约（clean-check 无泄漏守卫）不受影响。只挂编译类四入口消费 [diagnostics] 措辞表的路径。
fn maybeWarnZigDrift() void {
    const res = std.process.run(gpa_, io_, .{
        .argv = &.{ "zig", "version" },
        .create_no_window = true,
    }) catch return; // zig 不在 PATH：静默，交由后续真实编译给出母语提示
    defer gpa_.free(res.stdout);
    defer gpa_.free(res.stderr);
    if (!res.term.success()) return;
    const v = cli.parseZigVersion(res.stdout) orelse return;
    var buf: [256]u8 = undefined;
    if (cli.zigDriftNote(v.major, v.minor, &buf)) |note| printOut("{s}", .{note});
}

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

    // 第 154 轮：`--machine` 机读单行化旗标（编辑器/CI 消费）——在场即开、后续统一剔离不透传 zig。
    machine_mode = cli.hasBoolFlag(args, "--machine");

    // 惯例帮助旗标：`--help`/`-h`/`-?`/`help` 都应打印用法并成功退出（而非当未知子命令报 EXIT=2）。
    // 放在解析语言包之前：用法文本静态、不依赖 lang。
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or
        std.mem.eql(u8, cmd, "-?") or std.mem.eql(u8, cmd, "help"))
    {
        printOut("{s}", .{cli.usage_text});
        return;
    }

    // R9（第 52 轮）：`--lang` 选包——cli 解旗标 + registry 按名取包；缺省用注册表默认（中文）。
    // R9g（第 103 轮）：新增 `--lang-file` 外部发行包文件源（免重编译），与 `--lang` 互斥。
    // 旗标从透传参数中剔离，不会进入 zig（check/build/run/test/eject 只看 argv）。
    const lang_name = cli.findLangFlag(args);
    const lang_file = cli.findLangFileFlag(args);
    if (lang_name != null and lang_file != null) {
        printErr("zzc: --lang 与 --lang-file 互斥：内置选包、外部包文件二选一。", .{});
        werr.flush() catch {};
        std.process.exit(2); // 用法错与未知包同码；此刻表未建、无派生状态待落盘（D46 形安全）
    }
    // R9g 第二档（第 140 轮）：命名来源标——内置注册表 / 工程级已装包（.zzc/lang）。仅用于
    // 把“契约不完整”消息归位：已装包被手工改坏不能报成“工具自身缺陷”（内置包的措辞）。
    var installed_src: ?[]const u8 = null;
    var lang: Pack = if (lang_file) |fp|
        // 失败走 bail 而非 `return error.Failed`：main 带错返回会由 Zig 运行时打 `error: Failed`
        // + 栈帧（泄 std 绝对路径、D 族历史形）；母语消息已在源头报出，bail(Failed) 静默退 1。
        loadExternalPack(fp) catch |e| bail(e)
    else blk: {
        const chosen: registry.Entry = if (lang_name) |n|
            registry.lookup(n) orelse {
                // R9g 第二档：内置未命中先查工程级已装包，命中即交回第一档同一装载真相源
                // （免重编译）；仍不命中才落原“未知语言包”提示（第 137 轮守卫钉的形制不动）。
                if (userpack.installedFile(io_, gpa_, userpack.default_dir, n)) |ip| {
                    installed_src = ip;
                    break :blk loadExternalPack(ip) catch |e| bail(e);
                }
                printErr("zzc: 未知语言包「{s}」。当前可用：", .{n});
                for (registry.entries) |p| printErr("{s}({s}) ", .{ p.key, p.display });
                printErr("\n", .{});
                werr.flush() catch {};
                std.process.exit(2); // 尚未编译、无兼底项待落盘；直接退 2（与 error.Usage 同码）
            }
        else
            registry.defaultEntry();
        // R11（第 53 轮）：基包 + 补充层叠加加载（当前 zh 无补充层，overlays 为空→等价单包）。
        const bp = Pack.loadWithOverlays(gpa_, chosen.bytes, chosen.overlays) catch |e| {
            printErr("zzc: 语言包解析失败（{s}），这属于工具自身缺陷，请反馈。", .{@errorName(e)});
            bail(error.Failed); // noreturn：不外泄 error 名与栈帧（同外部源形制）
        };
        break :blk bp;
    };
    defer lang.deinit();
    var stripped = cli.stripLangFlag(gpa_, args) catch |e| {
        printErr("zzc: 参数处理失败（{s}）。", .{@errorName(e)});
        return e;
    };
    defer stripped.deinit(gpa_);
    var filtered = cli.stripLangFileFlag(gpa_, stripped.items) catch |e| {
        printErr("zzc: 参数处理失败（{s}）。", .{@errorName(e)});
        return e;
    };
    defer filtered.deinit(gpa_);
    var mach_stripped = cli.stripBoolFlag(gpa_, filtered.items, "--machine") catch |e| {
        printErr("zzc: 参数处理失败（{s}）。", .{@errorName(e)});
        return e;
    };
    defer mach_stripped.deinit(gpa_);
    const argv = mach_stripped.items;

    // 契约面校验（B6）：登记的包理应恒通过（有单测锁定）；失败即工具缺陷，母语报错不外泄 error 名。
    // 外部包（R9g）失败则是贡献者缺陷，消息面向包作者携带路径可行动。
    lang.validate() catch |e| {
        if (lang_file) |fp|
            printErr("zzc: 外部语言包「{s}」不完整：{s}", .{ fp, describePackError(e) })
        else if (installed_src) |ip|
            printErr("zzc: 已装语言包「{s}」不完整（装后又被改坏了？）：{s}", .{ ip, describePackError(e) })
        else
            printErr("zzc: 语言包不完整：{s}", .{describePackError(e)});
        bail(error.Failed); // 静默退 1：不外泄 error 名与栈帧（探针实锤形，第 103 轮）
    };

    if (std.mem.eql(u8, cmd, "version")) {
        printOut("zzc {s}（语言包：{s}）", .{ version_str, lang.name });
        return;
    }
    if (std.mem.eql(u8, cmd, "lang")) {
        // R9g 第二档（第 140 轮）：`lang` 由“只读详情”升为带动词，但**无参形制逐字不动**（第 136 轮
        // 守卫钉的详情行 + 可注册段）。本轮探针实捕旧行为：多余 argv 被整体忽略——`zzc lang add x.txt`
        // 也只打印一次详情退 0，用户以为装好了（“该拒绝未拒绝”形），故未知动词必递退 2。
        const verb = if (argv.len > 0) argv[0] else "";
        if (verb.len == 0) {
            // R9：反映注册表——除当前选定包详情外，列出可注册的包名（多包加载面可见）。
            printOut("当前语言包：{s}({s}) —— 关键字 {d} 条 / 路径别名 {d} 条 / 报错模式 {d} 条\n可注册包：", .{
                lang.name, lang.code, lang.keywords.count(), lang.aliases.count(), lang.diagnostics.items.len,
            });
            for (registry.entries) |p| printOut("{s}({s}) ", .{ p.key, p.display });
            printOut("\n", .{});
            return;
        }
        if (std.mem.eql(u8, verb, "add")) {
            cmdLangAdd(argv[1..]);
            return;
        }
        printErr("zzc: lang 只有 add 子命令：`zzc lang add <文件> [--as 注册名]`（不带参数则列当前包与可注册包）；「{s}」不是有效子命令。", .{verb});
        werr.flush() catch {};
        std.process.exit(2); // 与 --lang 未知包/用法错同码；此刻表未建、无派生状态待落盘（D46 形安全）
    }
    if (std.mem.eql(u8, cmd, "init")) {
        if (argv.len < 1) bail(error.Usage);
        cmdInit(argv[0], lang) catch |e| bail(e);
        return;
    }
    if (std.mem.eql(u8, cmd, "lsp")) {
        // LSP（第 156 轮）：分发核在 lsp/server.zig（测试图内全量单测），此处只接 stdio 帧环流。
        // 不走 symbols/Mangle 链：快路诊断纯函数化、不 intern 不写盘，无 saveSymbols 义务（D46 形安全）。
        cmdLsp(lang);
        return;
    }

    var table = Mangle.init(gpa_);
    defer table.deinit();
    loadSymbols(&table) catch |e| bail(e); // 此线之前 bail_table 为 null：半解析表不落盘（D46）
    bail_table = &table; // D46：自此表已全量就位，任何失败 bail 前补位持久化

    // R11（第 164 轮）：版本漂移早警只挂编译类四入口（check/build/run/test）——这些路径消费
    // [diagnostics] 措辞表；init/lang/version/lsp/eject 不产 zig 编译回译、无需提醒。
    if (std.mem.eql(u8, cmd, "check") or std.mem.eql(u8, cmd, "build") or
        std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "test"))
    {
        maybeWarnZigDrift();
    }

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
//
// 第 181 轮改接线：本文件 LSP 接线侧四纯函数（parseMachineDiag/kindSeverity/
// fileMatchesDoc/uriToFilesystemPath）系全库零直调且仅本文件可达——build.zig 已新增
// main 专测图（root=main.zig、test 构建下 pub fn main 被编译排除、root.zig 不 import
// 本文件故无重名风险），下方 test 块真跑。既有守卫面：156/159 轮 demos e2e 只喂合法形
// 机读行间接触达、防御臂零钉——问题形状（盘符形 URI、顶格冒号、空 message、CRLF 残留、
// 伪后缀词边界）全库无钉。探针即测：本块首跑即坐实真形，发现与 problemMatcher 正则
// 契约两处已知分歧（空 message 函数拒、正则允；盘符绝对路径函数拒）——均为调用方
// 实际不传此形、不构成在线缺陷，按契约钉住并登记观察面。

test "第 181 轮 T1 parseMachineDiag：合法形提取 + 防御拒形全臂钉（直接命中的每个拒绝分支都喂一例）" {
    const d = parseMachineDiag("src/main.zz:5:10: 错误: 未声明标识符").?;
    try std.testing.expectEqualStrings("src/main.zz", d.file);
    try std.testing.expectEqual(@as(usize, 5), d.line);
    try std.testing.expectEqual(@as(usize, 10), d.col);
    try std.testing.expectEqualStrings("错误", d.kind);
    try std.testing.expectEqualStrings("未声明标识符", d.message);
    // 列号多位/kind 含多字节 UTF-8：扫描按字节、数字段按 ASCII Digit、kind 段终止子只识 ASCII 空格与冒号。
    const d2 = parseMachineDiag("a.zz:123:4567: 内部错误: xyz").?;
    try std.testing.expectEqual(@as(usize, 123), d2.line);
    try std.testing.expectEqual(@as(usize, 4567), d2.col);
    try std.testing.expectEqualStrings("内部错误", d2.kind);
    try std.testing.expectEqualStrings("xyz", d2.message);

    // 拒形全臂：每例标注命中的那条拒绝分支。
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("")); // 空串
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag(" :1:1: 错误: x")); // 前导空格（顶格无空白契约）
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("\t:1:1: 错误: x")); // 前导制表符
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag(":x:1:1: 错误: y")); // 前导冒号（防把坐标分隔当 file 冒号）
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("no-colon-here")); // 无冒号
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag(":1:1: 错误: x")); // 冒号在 0 → file 段空
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:x:1: 错误: y")); // 行号位非数字
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1x2:3: 错误: y")); // 行号含字母
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1;2: 错误: y")); // 行号后缺冒号
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1: 错误: y")); // 缺列号段
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1:2错误: y")); // 列后缺空格（要求 ": "）
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1:2:错误: y")); // 列后直接接冒号（要求 ": "）
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1:2: : y")); // kind 空
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1:2: 错 误: y")); // kind 含空格 → 命中后后续非冒号
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1:2: 错误:y")); // kind 后缺空格
    try std.testing.expectEqual(@as(?MachineDiag, null), parseMachineDiag("a:1:2: 错误: ")); // message 空（函数拒，与正则 (.*) 允许 0 长分歧）
    // 探针坐实真形（非拒臂）：盘符形 "C:1:2: 错误: x" 解析成功 file="C"——首冒号取法对盘符无防备，
    // 恰因 digit 段落在位置 2/4 而全解析通过；problemMatcher 正则 `[^\s:]` 拒此行、函数收之。
    // 分歧登记观察面：生产消费链（emit 侧 L220 工相对路径 + L1036 调用方 trimEnd）不喂此形，
    // 不构成在线缺陷；若改首冒号取法即破本钉，故按真形钉住防静默变_contract_。
    const ddrive = parseMachineDiag("C:1:2: 错误: x").?;
    try std.testing.expectEqualStrings("C", ddrive.file);
    try std.testing.expectEqual(@as(usize, 1), ddrive.line);
    try std.testing.expectEqual(@as(usize, 2), ddrive.col);
    try std.testing.expectEqualStrings("错误", ddrive.kind);
    try std.testing.expectEqualStrings("x", ddrive.message);
    // 探针登记：函数形态拒的合法行（e2e 不喂此形、不构成在线缺陷、观察面）：
    //   CRLF 残留行（调用方已 trimEnd "\r"、此例验证未 trim 则消息含尾 \r 仍解析成功——不拒）：
    const dcr = parseMachineDiag("a.zz:1:1: 错误: msg\r").?;
    try std.testing.expectEqualStrings("msg\r", dcr.message); // 函数不剔 \r、交给调用方 trimEnd
}

test "第 181 轮 T2 kindSeverity：四 Unicode 转义 kind 精确命中 + 全臂近邻拒" {
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("错误")); // 默认（未命中三特例退错误）
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("内部错误")); // 未命中
    try std.testing.expectEqual(@as(u8, 2), kindSeverity("警告")); // 精确
    try std.testing.expectEqual(@as(u8, 3), kindSeverity("说明")); // 精确
    try std.testing.expectEqual(@as(u8, 4), kindSeverity("被引用于")); // 精确
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("")); // 空串
    // 近邻：前缀/后缀/大小写异体/全角/同形异体——全不命中三特例、退 1。
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("警"));
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("警告x"));
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("错 误")); // 含空格
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("warning")); // 英文异体
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("Warning")); // 英文异体
    try std.testing.expectEqual(@as(u8, 1), kindSeverity("ＷＡＲＮ")); // 全角英文
}

test "第 181 轮 T3 fileMatchesDoc：后缀精确 / 等长 / 词边界门 / 伪后缀拒" {
    // 命中：完全等长
    try std.testing.expect(fileMatchesDoc("main.zz", "main.zz"));
    // 命中：后缀 + 分隔符（两种分隔符均认）
    try std.testing.expect(fileMatchesDoc("src/main.zz", "main.zz"));
    try std.testing.expect(fileMatchesDoc("a\\b\\main.zz", "main.zz"));
    try std.testing.expect(fileMatchesDoc("deep/sub/path/main.zz", "main.zz"));
    // 拒：长 needle 直 false
    try std.testing.expect(!fileMatchesDoc("main.zz", "src/main.zz"));
    // 拒：字节后缀命中但缺词边界（前缀同形异体、不是路径段）
    try std.testing.expect(!fileMatchesDoc("domain.zz", "main.zz"));
    try std.testing.expect(!fileMatchesDoc("xyzmain.zz", "main.zz"));
    // 拒：后缀前的分隔符既非 / 亦非 \（例如字母/数字/连字符紧接 needle）
    try std.testing.expect(!fileMatchesDoc("v2/main.zz", "n.zz")); // 前缀 "v2/ma" 中 needle "n.zz" 非后缀
    // 注：needle 与 mfile 同后缀但前字节是 ASCII 词字符 → 拒（词边界只接 /=\）
    try std.testing.expect(!fileMatchesDoc("mainzz/main.zz", "/main.zz"));
    // 边界：空 base——endsWith 恒真、mfile.len > base.len 时查前字节：'b' 非 /=\ 仍应 false
    try std.testing.expect(!fileMatchesDoc("a/b.zz", "")); // 真形坐实：空 base 仅当 mfile 亦空串才 true
    try std.testing.expect(fileMatchesDoc("", "")); // 等长 0 形直 true
}

test "第 181 轮 T4 uriToFilesystemPath：file:// 剥前缀 + 盘符门 + 百分号解码全臂（非法 hex 透传 / 越界拒 / 边界）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 非 file:// 前缀一律 null。
    try std.testing.expectEqual(@as(?[]const u8, null), uriToFilesystemPath(a, "http://x"));
    try std.testing.expectEqual(@as(?[]const u8, null), uriToFilesystemPath(a, ""));
    try std.testing.expectEqual(@as(?[]const u8, null), uriToFilesystemPath(a, "FILE:///x")); // 大小写敏感
    // Unix 直形：file:///abs/path → /abs/path
    try std.testing.expectEqualStrings("/abs/path", uriToFilesystemPath(a, "file:///abs/path").?);
    // 盘符门：s.len >= 3 且 s[0]=='/' && isAlphabetic(s[1]) && s[2]==':' → 去首斜杠
    //   注：Windows 归一（'/' → '\'）仅在 os.tag == .windows 生效、Linux 测图不执行此分支，
    //   本函数返回的仍是 '/' 分隔形——契约钉「去前导斜杠 + 百分号解码」两步、不归一。
    try std.testing.expectEqualStrings("C:/x", uriToFilesystemPath(a, "file:///C:/x").?);
    // 盘符门不命中的边界形（拒剥前导 /）：
    //   s.len < 3：短串不剥
    try std.testing.expectEqualStrings("/a", uriToFilesystemPath(a, "file:///a").?);
    //   s[1] 非字母：不剥
    try std.testing.expectEqualStrings("/1:/x", uriToFilesystemPath(a, "file:///1:/x").?);
    //   s[2] 非冒号：不剥
    try std.testing.expectEqualStrings("/ab/x", uriToFilesystemPath(a, "file:///ab/x").?);
    // 百分号解码：合法 hex 替换
    try std.testing.expectEqualStrings("/a b", uriToFilesystemPath(a, "file:///a%20b").?);
    try std.testing.expectEqualStrings("/a/b", uriToFilesystemPath(a, "file:///a%2Fb").?);
    try std.testing.expectEqualStrings("/A", uriToFilesystemPath(a, "file:///%41").?); // 'A'=0x41（前导 / + 解码）
    // 十六进制大小写不敏感坐实例（小写 hex 同字节 0x41='A'）：
    try std.testing.expectEqualStrings("/aA", uriToFilesystemPath(a, "file:///a%41").?);
    // 非法 hex 透传 '%'、j 前进 1：
    try std.testing.expectEqualStrings("/a%zzb", uriToFilesystemPath(a, "file:///a%zzb").?);
    // 截断形（末尾不足 2 字节）走 else 分支透传 '%'：
    //   `%` 满足 j+2 >= s.len（条件 `j+2 < s.len` 假）→ else 分支原样输出
    try std.testing.expectEqualStrings("/%", uriToFilesystemPath(a, "file:///%").?);
    try std.testing.expectEqualStrings("/%2", uriToFilesystemPath(a, "file:///%2").?);
}

// 第 188 轮审计注（一）·D57 新登并消：本文件曾有死码 `fn constTable(t: *const
// Mangle) *Mangle { return @constCast(t); }`（937fd6f [9.1.2] 引入后成孤儿，全仓
// grep 含文档唯定义一处、零引用）。结构性盲区登册：Zig 只报 unused local/param、
// 不报未引用文件级私有 fn——死码于编译期完全隐形，唯引用对账能抓，与 181 轮
// L1335 死测（test 块恒不执行）同属「文件级失守、局部级自守」族。
//
// 第 188 轮审计注（二）：lspSemanticCall（cmdLsp 接线位注入的语义供给钩子）系
// 全库零直调（any=1 call=0，唯 cmdLsp L1075 接线）——156/159 轮 demos e2e 只从
// didSave 间接触达、无任何形状钉。既有守卫面：本文件 181 轮 T1..T4 钉四纯函数
// 本体，钩子层（ctx 往返 / text 恒忽略 / 五道降级臂 / 过滤链 / scratch 借用契约）
// 零钉。探针即测：下方 T1 首跑自证，期望全部实跑坐实。

test "第 188 轮 T1 lspSemanticCall：接线钩子契约钉（ctx 往返/text 恒忽略/降级全臂/真 spawn 非空出口）" {
    // 测试图永不跑 main（181 轮注：test 构建下 pub fn main 被编译排除）——文件级
    // 全局 io_ 恒为 undefined，而 run 内 std.process.run 消费它；本测手动接线一次，
    // 形态与 cmdMain 入口 L1155 `io_ = init.io` 同构（Threaded 后端、page_allocator，
    // 承 file_io.zig 测图既有 Threaded.init 先例）。
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    io_ = threaded.io();

    // —— A1..A4：exe=null 优雅降级（159 轮声明形）——text 四形全不被读、uri 四形全喂。
    //   ctx 往返同步钉：钩子收到的 *anyopaque 即 &LspSemantic（cmdLsp L1075 接线形），
    //   解不回则第一行读 exe 即崩。
    var sem_null = LspSemantic{ .exe = null, .scratch = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer sem_null.scratch.deinit();
    try std.testing.expectEqual(@as(usize, 0), lspSemanticCall(&sem_null, "file:///x.zz", "任意文本").len);
    try std.testing.expectEqual(@as(usize, 0), lspSemanticCall(&sem_null, "http://x", "").len);
    try std.testing.expectEqual(@as(usize, 0), lspSemanticCall(&sem_null, "", "file:///bin/true").len); // text 呈合法 URI 形亦不被当 uri 用
    try std.testing.expectEqual(@as(usize, 0), lspSemanticCall(&sem_null, "FILE:///x", "a\nb\nc").len); // 大小写敏感拒形（与 T4 口径一致）

    // —— A5：exe 在、uri 指不存在文件 → spawn 失败（探针 P1 实跑坐实 throw FileNotFound）
    //   catch 降级。另喂空串 uri（剥前缀失败第一道 null）与非 file:// 形（http）。
    const badexe = if (builtin.os.tag == .windows) "C:/zzc188-no-such.zz" else "/bin/zzc188-nope";
    var sem_bad = LspSemantic{ .exe = badexe, .scratch = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer sem_bad.scratch.deinit();
    try std.testing.expectEqual(@as(usize, 0), lspSemanticCall(&sem_bad, "file:///tmp/zzc188-none.zz", "t").len);
    try std.testing.expectEqual(@as(usize, 0), lspSemanticCall(&sem_bad, "", "t").len);

    // —— A5b：uri 剥前缀后恰空串 → dirname("")=null 第三道降级臂（'/x' 形 dirname 是 "/"、非本臂）。
    try std.testing.expectEqual(@as(usize, 0), lspSemanticCall(&sem_bad, "file://", "t").len);

    // —— A5c：百分号哨兵截断形——uri 以 "%40" 结尾，j+2 < s.len 恰假走透传 else 臂；
    //   若变异改 j 步进则尾部字节形变，但仍指不存在文件——本臂钉透传形不崩不泄，
    //   真 decode 全臂已由 181 T4 钉住，此处只加钩子层透传过点。
    try std.testing.expectEqual(@as(usize, 0), lspSemanticCall(&sem_bad, "file:///zzc188-nope%40", "t").len);

    if (builtin.os.tag != .windows) {
        // —— A6：POSIX 真 spawn 非空出口（堵纯桩 `return &.{}` 与 uri/text 换位变异）。
        //   run 的子进程形定（探针实跑兼得）：argv 恒 = {exe, "check", "--machine",
        //   basename(uri 解码形)}、cwd = dirname(同一解码形)——uri 在木层的作面就
        //   是供这一对 (dir, base)（所传 exe 形参不参与拼接、%20 在 uri 里不会分词；
        //   前三轮探针沿“%20 拆 argv”的错误模型建模、均误，已自捕入注）。
        //   本臂置一个盘上探针脚本（首跑建、defer 删）：argv 前两参须恰为
        //   check / --machine 才往 stderr 写一行合法机读行（钉 run 的 argv 拼接形），
        //   且所写 file 段恒为 zzc188-probe.sh（使 A7 的 base 不等形可钉过滤链）。
        //   exe 与 uri 同指该脚本：dir=/tmp、base=脚本名→fileMatchesDoc 等长命中，
        //   过滤链恰 1 项、字段逐一钉（kind 段后须 `: `、故行形为 `err: x`）：
        //   line/col 1 基转 0 基、kind=err 退 1、
        //   char_len=0、message=x。base 取错（如误喂整路径）则后缀前字节非 /=\ 而拒→红。
        const probe_path = "/tmp/zzc188-probe.sh";
        {
            var f = std.Io.Dir.createFileAbsolute(io_, probe_path, .{
                .read = true,
                .permissions = .executable_file,
            }) catch |e| {
                std.debug.print("A6 探针脚本创建失败：{s}\n", .{@errorName(e)});
                return error.TestUnexpectedResult;
            };
            defer f.close(io_);
            var buf: [512]u8 = undefined;
            var w = Io.File.Writer.init(f, io_, &buf);
            w.interface.writeAll("#!/bin/sh\n[ \"$1\" = check ] && [ \"$2\" = --machine ] && printf 'zzc188-probe.sh:1:2: err: x\\n' 1>&2\n") catch |e| {
                std.debug.print("A6 探针脚本写入失败：{s}\n", .{@errorName(e)});
                return error.TestUnexpectedResult;
            };
            w.interface.flush() catch {};
        }
        defer std.Io.Dir.cwd().deleteFile(io_, probe_path) catch {};
        var sem_probe = LspSemantic{ .exe = probe_path, .scratch = std.heap.ArenaAllocator.init(std.testing.allocator) };
        defer sem_probe.scratch.deinit();
        const got = lspSemanticCall(&sem_probe, "file:///tmp/zzc188-probe.sh", "file:///bin/false");
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqual(@as(usize, 0), got[0].line); // 1 基→0 基回映
        try std.testing.expectEqual(@as(usize, 1), got[0].character); // 2-1
        try std.testing.expectEqual(@as(usize, 0), got[0].char_len); // 单字符下划形（核内视作 1）
        try std.testing.expectEqual(@as(u8, 1), got[0].severity); // kind "err" 非三特例退 1
        try std.testing.expectEqualStrings("x", got[0].message);

        // —— A7：同 exe、uri 换基名形——argv[3] 变了但脚本仍写固定 file 段（前两参门仍过），
        //   该行基名与本次 base 不等→fileMatchesDoc 拒→ 0 项（钉过滤链、而非只要 spawn 成功就产出）。
        const got2 = lspSemanticCall(&sem_probe, "file:///tmp/zzc188-other.sh", "t");
        try std.testing.expectEqual(@as(usize, 0), got2.len);
    }
}

// 第 189 轮审计注：D57 后全库私有 fn 引用对账刷新（死码归零首轮），`src/main.zig`
// 生产层两枚**测面零直调**核落位钉：
// ①describePackError（L456·B6 契约缺失母语报错文案表 14 臂）——唯 cmdLangAdd L519 与
//   主分发 L1255/1257/1259 三消息位生产直调，全库测面零钉；pack.zig 只钉错误值**产生侧**
//   （validate 判序/expectError/err_for 序），本文案表**消费侧**的臂-文案映射换位/增臂
//   断代（ValidationError 集合扩而 switch 未补则编译拒、文案错而集合未动则全库无防）零防。
// ②ejectZoneText（L830·毕业构建 build.zig.zon 模板构建器）——唯 cmdEject L810/813 两形
//   直调（fp=null 首写/回写）；102 轮 parseFingerprintFromZone 只钉**读侧**、写侧的
//   fingerprint 行插位与关键行措辞（.name/.version/.minimum_zig_version/.paths）系 zig
//   工具链字节契约，全库零钉。
// 两皆活路径探针即测：T1/T2 期望值全部自本文件源码逐字节抽取生成（防手抄漂移即自捕形）。
// 证伪撤号轮——通读未见缺陷不占 D 号。

test "第 189 轮 T1 describePackError：B6 报错文案表 14 臂一一映射钉（换位即红·与 ValidationError 同源）" {
    const Case = struct { e: PackParseError, want: []const u8 };
    // 期望表逐字节取自本文件 L457-470 定义（脚本抽取生成、非手抄）。
    const cases = [_]Case{
        .{ .e = error.PackMissingCode, .want = "缺少 `$code = xx` 元数据行（语言代码用于版本/列表展示，不得默认为 `??`）" },
        .{ .e = error.PackMissingConst, .want = "缺少映射到 `const` 的关键字（声明位识别与 `常数` 单跳数据流预扫描依赖它）" },
        .{ .e = error.PackMissingVar, .want = "缺少映射到 `var` 的关键字" },
        .{ .e = error.PackMissingFn, .want = "缺少映射到 `fn` 的关键字（入口链与声明位识别依赖它）" },
        .{ .e = error.PackMissingIf, .want = "缺少映射到 `if` 的关键字" },
        .{ .e = error.PackMissingElse, .want = "缺少映射到 `else` 的关键字" },
        .{ .e = error.PackMissingReturn, .want = "缺少映射到 `return` 的关键字" },
        .{ .e = error.PackMissingStruct, .want = "缺少映射到 `struct` 的关键字" },
        .{ .e = error.PackMissingEnum, .want = "缺少映射到 `enum` 的关键字（枚举成员声明位识别依赖它）" },
        .{ .e = error.PackMissingUnion, .want = "缺少映射到 `union` 的关键字（变体名声明位识别依赖它）" },
        .{ .e = error.PackMissingSwitch, .want = "缺少映射到 `switch` 的关键字" },
        .{ .e = error.PackMissingImport, .want = "缺少映射到 `@import` 的关键字（`.zz` 资产豁免与 import 目标反查依赖它）" },
        .{ .e = error.PackMissingEmbedFile, .want = "缺少映射到 `@embedFile` 的关键字（嵌入资产预扫描与 staging 依赖它）" },
        .{ .e = error.PackMissingMain, .want = "缺少映射到 `main` 的关键字（语义编译根——含主入口的文件——判据依赖它）" },
    };
    // 主钉：逐臂 expectEqualStrings 全文对照（任一臂文案换位/措辞漂移即红）。
    for (cases) |c| try std.testing.expectEqualStrings(c.want, describePackError(c.e));
    // 完备钉：cases 与 ValidationError 全 14 员对齐（switch 穷举在编译期自守、本钉防
    // 「cases 漏收新臂」的测面断代——与编译期穷举互补成双线）。
    try std.testing.expectEqual(@as(usize, 14), cases.len);
    // 第二防线：任意两臂文案互异（复制粘贴同文案形——即便 oracle 表随本体同步腐坏，互异性仍可点名）。
    for (cases, 0..) |a, i| {
        for (cases[0..i]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.want, b.want));
        }
    }
}

test "第 189 轮 T2 ejectZoneText：build.zig.zon 模板两形字节钉（fp 缺/有·行序·关键行措辞）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    gpa_ = arena.allocator(); // 文件级 arena 手动接线（生产 main L1150 同形制、188 轮 io_ 同族先例）

    const tail =
        "    .minimum_zig_version = \"0.17.0\",\n" ++
        "    .dependencies = .{},\n" ++
        "    .paths = .{\n        \"build.zig\",\n        \"build.zig.zon\",\n        \"src\",\n    },\n}\n";

    // 形 A：fp=null（首写占位 zon，fp 行必须缺席——存在即被回写覆盖前的非法中间态泄漏）。
    const want_a =
        "// 由 zzc eject 生成；可独立 `zig build` 构建。\n.{\n" ++
        "    .name = .pj,\n" ++
        "    .version = \"0.1.0\",\n" ++
        tail;
    try std.testing.expectEqualStrings(want_a, try ejectZoneText("pj", null));

    // 形 B：fp 非空——fingerprint 行恰插于 .version 之后、.minimum_zig_version 之前（字节位钉）。
    const want_b =
        "// 由 zzc eject 生成；可独立 `zig build` 构建。\n.{\n" ++
        "    .name = .pj,\n" ++
        "    .version = \"0.1.0\",\n" ++
        "    .fingerprint = 0xdeadbeef,\n" ++
        tail;
    try std.testing.expectEqualStrings(want_b, try ejectZoneText("pj", "0xdeadbeef"));

    // 边界透传形登记（观察面）：函数不校验 app_name——安全性由调用侧 init/eject 名字闸门
    // 拦（cmdInit 不安全名判定），空名直落模板生 `.name = .,` 非法 zon 形。按真形钉透传、
    // 防日后在本函数静默加判致两侧双闸或措辞改动无人知。
    const want_c =
        "// 由 zzc eject 生成；可独立 `zig build` 构建。\n.{\n" ++
        "    .name = .,\n" ++
        "    .version = \"0.1.0\",\n" ++
        tail;
    try std.testing.expectEqualStrings(want_c, try ejectZoneText("", null));
}

// 第 190 轮审计注：承 189 对账，main.zig 再锁定测面零直调两域——
// ①findUnit（L394·入口→unit 三层检索：samePathRel 精确臂（分隔符归一）→ stem
//   宽松臂 → null）唯 cmdCheck L549 / cmdBuild L609 两生产直调；samePathRel/stem
//   各已下层钉，但三层**序**（精确先于宽松）、同 stem first-wins、stem 臂扩展名
//   盲区形全库零钉——序颠倒即 entry 指名目录时被首 stem 单元劫持（语义反转）。
// ②eject 回读/验证三件套（readExistingFingerprint L866·probeFingerprint L844·
//   verifyBuild L878）唯 cmdEject L809/811/819 直调——102 轮 parseFingerprintFromZone
//   只钉解析本体，wrapper 四降级臂（allocPrint/readWhole catch、parse orelse、dupe
//   catch）与 spawn 失败 catch（probe→null、verify→.no_zig）全库零防；verifyBuild
//   把一切 spawn throw 判 .no_zig——cwd 不存在形与「未检测到 zig」同臂，观察面登册
//   （调用方先 writeWhole 建 dest、生产不可达此形，不构成在线缺陷）。
// 探针即测：T1/T2 期望皆首跑自证。证伪撤号轮不占 D 号。

test "第 190 轮 T1 findUnit：三层检索契约钉（精确先于宽松·反斜杠精确形·stem first-wins·扩展名盲区·null 臂）" {
    const ta = std.testing.allocator;
    var list: std.ArrayList(Unit) = .empty;
    defer list.deinit(ta);
    try list.append(ta, .{ .native_rel = "src/main.zz", .gen_rel = "g_src", .nat_src = "n1", .zig_str = "z1", .map = .{ .entries = .empty } });
    try list.append(ta, .{ .native_rel = "lib/a.zz", .gen_rel = "g_lib", .nat_src = "n2", .zig_str = "z2", .map = .{ .entries = .empty } });
    try list.append(ta, .{ .native_rel = "sub/main.zz", .gen_rel = "g_sub", .nat_src = "n3", .zig_str = "z3", .map = .{ .entries = .empty } });
    const proj = Project{ .units = list };

    // A1 精确臂命中。
    try std.testing.expectEqualStrings("g_src", findUnit(proj, "src/main.zz").?.gen_rel);
    // A2 分隔符归一：Windows 反斜杠形在精确臂命中（非宽松臂兜住——samePathRel 契约透传钉）。
    try std.testing.expectEqualStrings("g_src", findUnit(proj, "src\\main.zz").?.gen_rel);
    // A3/A4 stem 宽松臂：无扩展形、无目录形。
    try std.testing.expectEqualStrings("g_src", findUnit(proj, "src/main").?.gen_rel);
    try std.testing.expectEqualStrings("g_src", findUnit(proj, "main.zz").?.gen_rel);
    // A5 精确先于宽松 + first-wins 序反证锚：entry="sub/main.zz" 虽 stem "main" 与首单元
    //   撞名、仍须取第三单元——若两层顺序颠倒（宽松臂先跑）此处得 g_src 即红。
    try std.testing.expectEqualStrings("g_sub", findUnit(proj, "sub/main.zz").?.gen_rel);
    // A6 stem 形择首：entry="main"（无扩展）→ 表序首个 stem 命中 g_src（非 g_sub）。
    try std.testing.expectEqualStrings("g_src", findUnit(proj, "main").?.gen_rel);
    // A7 扩展名盲区真形（观察面钉）：.zig 标准扩展同被 stem 臂命中——宽松臂不看扩展名，
    //   用户误传生成物形也照取 .zz 单元（无害·钉住防判据静默改）。
    try std.testing.expectEqualStrings("g_src", findUnit(proj, "src/main.zig").?.gen_rel);
    // A8 全不命中 → null。
    try std.testing.expect(findUnit(proj, "other.zz") == null);
    // A9 空 entry：精确臂无 0 长单元、stem("")="" 亦不中 → null。
    try std.testing.expect(findUnit(proj, "") == null);
    // A10 宽松臂分隔符盲区真形（观察面钉·探针首跑自捕）：std.fs.path.stem 按 machine
    //   分隔符切段——Linux 图不切反斜杠，"lib\\a" 整体成 stem、精确臂同不中 → null；
    //   Windows 机 stem 切 '\\' 得 "a" 可命中——本函数宽松臂行为随 os.tag 异（生产形：
    //   Windows 用户传反斜杠无扩展形在其本机命中、Linux 传此形属罕见且落 null 安全侧）。
    try std.testing.expect(findUnit(proj, "lib\\a") == null);
    // A10b 裸名宽松命中：entry="a" → stem "a" 命中表内 "lib/a.zz"。
    try std.testing.expectEqualStrings("g_lib", findUnit(proj, "a").?.gen_rel);
}

test "第 190 轮 T2 eject 三件套：回读命中/名闸/无字段/NotDir + spawn 失败降级臂（probe→null·verify→no_zig 同臂观察面）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    io_ = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    gpa_ = arena.allocator(); // 文件级 arena 接线（189 T2 同族形制）

    const dir = "/tmp/zzc190proj";
    const zon = "/tmp/zzc190proj/build.zig.zon";
    // 前置清理历史残留（保 A1 幂等：目录/文件不存在须为真前提而非巧合）。
    std.Io.Dir.cwd().deleteFile(io_, zon) catch {};
    std.Io.Dir.cwd().deleteDir(io_, dir) catch {};
    // A1 目录不存在（zon 必缺）→ readWhole FileNotFound → null。
    try std.testing.expectEqual(@as(?[]const u8, null), readExistingFingerprint(dir, "pj"));

    std.Io.Dir.cwd().createDirPath(io_, dir) catch |e| {
        std.debug.print("T2 setup createDirPath 失败：{s}", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    defer std.Io.Dir.cwd().deleteFile(io_, zon) catch {};
    defer std.Io.Dir.cwd().deleteDir(io_, dir) catch {};

    const good = "// zzc\n.{\n    .name = .pj,\n    .fingerprint = 0xdeadbeef,\n}\n";
    {
        var f = std.Io.Dir.createFileAbsolute(io_, zon, .{ .read = true }) catch |e| {
            std.debug.print("T2 setup createFile 失败：{s}", .{@errorName(e)});
            return error.TestUnexpectedResult;
        };
        defer f.close(io_);
        var buf: [256]u8 = undefined;
        var w = Io.File.Writer.init(f, io_, &buf);
        w.interface.writeAll(good) catch |e| {
            std.debug.print("T2 setup 写入失败：{s}", .{@errorName(e)});
            return error.TestUnexpectedResult;
        };
        w.interface.flush() catch {};
    }
    // A2 命中臂：连同 "0x" 前缀一并返回（读侧契约透传）。
    try std.testing.expectEqualStrings("0xdeadbeef", readExistingFingerprint(dir, "pj").?);
    // A3 名闸透传：app_name 不匹配 → parse null → wrapper null（防把别家工程指纹复用）。
    try std.testing.expectEqual(@as(?[]const u8, null), readExistingFingerprint(dir, "other"));
    // A4 无 fingerprint 字段：truncate 重写后 → parse orelse 臂 → null。
    {
        const nofp = "// zzc\n.{\n    .name = .pj,\n}\n";
        var f = std.Io.Dir.createFileAbsolute(io_, zon, .{ .read = true }) catch |e| {
            std.debug.print("T2 setup 重写失败：{s}", .{@errorName(e)});
            return error.TestUnexpectedResult;
        };
        defer f.close(io_);
        var buf: [256]u8 = undefined;
        var w = Io.File.Writer.init(f, io_, &buf);
        w.interface.writeAll(nofp) catch |e| {
            std.debug.print("T2 setup 重写写入失败：{s}", .{@errorName(e)});
            return error.TestUnexpectedResult;
        };
        w.interface.flush() catch {};
    }
    try std.testing.expectEqual(@as(?[]const u8, null), readExistingFingerprint(dir, "pj"));

    // A5 dest 系普通文件：zon_path 落文件之下 → NotDir → readWhole catch → null（第三降级形）。
    const file_path = "/tmp/zzc190plain";
    {
        var f = std.Io.Dir.createFileAbsolute(io_, file_path, .{ .read = true }) catch |e| {
            std.debug.print("T2 setup 建普通文件失败：{s}", .{@errorName(e)});
            return error.TestUnexpectedResult;
        };
        f.close(io_);
    }
    defer std.Io.Dir.cwd().deleteFile(io_, file_path) catch {};
    try std.testing.expectEqual(@as(?[]const u8, null), readExistingFingerprint(file_path, "pj"));

    // B probeFingerprint spawn 失败降级：dest 不存在 → run throw（FileNotFound 族）→ catch null。
    try std.testing.expectEqual(@as(?[]const u8, null), probeFingerprint("/tmp/zzc190-no-such-dir"));

    // C verifyBuild 同形 → 统一 catch 臂 → .no_zig。观察面钉：本把一切 spawn throw（含 cwd
    //   不存在）判「未检测到 zig」——措辞与真因可能错位，唯调用方 cmdEject 必先成功写盘建
    //   dest、生产不可达此形，不构成在线缺陷；钉死现语义防两臂静默拆分或措辞改动无测知。
    try std.testing.expectEqual(BuildVerify.no_zig, verifyBuild("/tmp/zzc190-no-such-dir"));
}

// 第 191 轮审计注（二）：loadSymbols（L196·符号表恢复入口）系测面零直调——唯
// main 分发 L1283 生产直调；101 轮 D46 只证了其失败退出补位面、parseSymbolText
// 格式解析属 zzc_core 图有单测，而 wrapper 本身的三向决策臂（FileNotFound 静默
// 正常 / D31 编码封口传播 / D36 撞号传播）全库零钉——把 else 臂改成静默吞（首次
// 运行豁免扩成一切失败豁免）即跨会话映射静默丢失、无任何测可抓。盘上形制：路径
// 硬编 `.zzc/symbols.txt` 相对 cwd，测试图 cwd=仓库根、`.zzc/` 已 gitignore；
// 前置清理+defer 回清保幂等。观察面登册：SourceTooLarge 臂（10MB 门槛）不以重 IO
// 诱发——同体传播臂已由 InvalidEncoding 形钉住。证伪撤号轮不占 D 号。

test "第 191 轮 T2 loadSymbols：三向决策臂钉（FileNotFound 静默/恢复端到端/InvalidEncoding 传播/DuplicateSymbol 传播）" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    io_ = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    gpa_ = arena.allocator(); // 189/190 同族形制：文件级 arena 接线
    // werr 接线（探针即测自捕：readWhole wrapper 的 D31 编码封口臂经 printErr 打
    //   母语提示，测试图 werr=undefined 直崩）：挂到盘上日志文件、用毕回 undefined。
    const werr_path = "/tmp/zzc191-werr.log";
    var wf: Io.File.Writer = undefined;
    var wbuf: [512]u8 = undefined;
    var wfile = std.Io.Dir.createFileAbsolute(io_, werr_path, .{}) catch return error.TestUnexpectedResult;
    defer wfile.close(io_);
    wf = Io.File.Writer.init(wfile, io_, &wbuf);
    werr = &wf.interface;
    defer wf.interface.flush() catch {};
    defer werr = undefined;

    // 前置清理（A1「尚无符号表」须为真前提而非巧合）+ 尾部回清。
    std.Io.Dir.cwd().deleteFile(io_, ".zzc/symbols.txt") catch {};
    std.Io.Dir.cwd().deleteDir(io_, ".zzc") catch {};
    // defer LIFO：先注删目录（后跑）再注删文件（先跑）——反序则目录非空删失败、留空壳。
    defer std.Io.Dir.cwd().deleteDir(io_, ".zzc") catch {};
    defer std.Io.Dir.cwd().deleteFile(io_, ".zzc/symbols.txt") catch {};

    // A1 首次运行形：FileNotFound → 静默正常返回、表零变化（唯一豁免臂）。
    {
        var t = Mangle.init(std.testing.allocator);
        defer t.deinit();
        try loadSymbols(&t);
        try std.testing.expectEqual(@as(usize, 0), t.count());
    }
    // A2 恢复端到端：writeWhole 落盘 → loadSymbols 完整透传 parseSymbolText——
    //   既有映射命中不复派生、新名续接已恢复最大编号之后（D16 跨会话稳定契约）。
    try writeWhole(".zzc/symbols.txt", "甲 = z_1\n乙 = z_2\n");
    {
        var t = Mangle.init(std.testing.allocator);
        defer t.deinit();
        try loadSymbols(&t);
        try std.testing.expectEqual(@as(usize, 2), t.count());
        const a = try t.intern("甲"); // 缓存命中：不消耗新编号
        try std.testing.expectEqualStrings("z_1", a);
        const b = try t.intern("乙");
        try std.testing.expectEqualStrings("z_2", b);
        const c = try t.intern("丙"); // next_index 已推至 3：续接编号
        try std.testing.expectEqualStrings("z_3", c);
    }
    // A3 编码封口传播臂（D31 形透传）：UTF-16LE BOM 字节非法 UTF-8 → readWhole
    //   本地化为母语提示（本次接线 werr 即打向日志文件）+ error.Failed 上传——
    //   wrapper 把 file_io 的 InvalidEncoding 折成 Failed 是产品契约（方言用户不见
    //   英文错误名），loadSymbols else 臂照传（丢映射不可静默吞）。
    try writeWhole(".zzc/symbols.txt", "\xFF\xFE\x00\x01");
    {
        var t = Mangle.init(std.testing.allocator);
        defer t.deinit();
        try std.testing.expectError(error.Failed, loadSymbols(&t));
    }
    // A4 撞号传播臂（D36 形透传）：同一 z_1 归两名 → parseSymbolText 抛
    //   DuplicateSymbol → try 传播（源头拒并点名语义贯穿 wrapper）。
    try writeWhole(".zzc/symbols.txt", "甲 = z_1\n乙 = z_1\n");
    {
        var t = Mangle.init(std.testing.allocator);
        defer t.deinit();
        try std.testing.expectError(error.DuplicateSymbol, loadSymbols(&t));
    }
}

// 第 192 轮审计注：flushUntranslated（L79·未翻译清单进程出口落盘壳）系测面零直调——
// 生产直调唯 bail L915 与 main defer L1155（皆产品入口流、测试二进制不触发）；纯函数面
// renderUntranslatedJson（键名/转义/D22 mid-loop OOM errdefer）已有三枚 pure_filter 单测、
// UntranslatedList.log 去重亦有测钉，但壳本体全库零钉：F3「空清单不建文件」早退臂（防 CI
// 把恒在空文件误读为零未译）、real 时钟 generated_at（改 monotonic 族即落 1970）、双 catch
// 静面（序列化失败/落盘失败均只 printErr、不改退出码——改成 try 传播即把辅面异常升格成主
// 报错）、defer free(json) 泄漏防线（191 S1 同族）与 entry 字段透传/顺序契约。盘上形制：
// writeWhole 自动 createDirPath("logs")（file_io L40）、logs/ 未 gitignore——测试图以
// deleteTree 回清（崩溃幂等：文件/目录/子树全形态归零）；werr 接线 /tmp 盘上日志
// （191 T2 同族：静面 printErr 臂 werr=undefined 直崩）。首跑自证注：0.17 断代候选
// `f.deleteFile` 不存在；`deleteFileAbsolute` 内部 assert(isAbsolute) 传相对路径即
// ABRT——回清统一 cwd().deleteFile 相对形；后因崩溃残留脏态改 deleteTree 整树归零
// （五跑）。JsonDoc 系 pure_filter 私有不可 import，改动态 std.json.Value 按字节面
// 键名钉。连环自捕八案：①statsAllocator 已断代——B3 改 FailingAllocator 公开计数
// 字段；②errdefer+defer 同指针双手清理在失败展开路径双 deinit，0.17 SafetyLock
// assertUnlocked panic 掩原始测红——统一单手 defer；③跨段悬垂全局拷贝：B2 块尾
// deinit 后 untranslated_list 仍持死指针，C 段壳读垃圾 phrase.len 直诱发巨量分配
// overflow——跨段交接须显式重置全局；④log 自持 dupe 串须逐条 free（deinit 只释放
// 数组本体）。证伪撤号轮不占 D 号。

test "第 192 轮 T1 flushUntranslated：空清单不建文件/落盘字段透传/静面双 catch/json 免泄漏" {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    io_ = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    gpa_ = arena.allocator(); // 189/190/191 同族形制：文件级 arena 接线
    // werr 接线（静面 printErr 臂需实流；191 T2 同族形制）：函数帧作用域一次接线、
    //   defer 回置——B/C 段内块会重开 append 句柄复用法帧的 wf/wbuf。
    const werr_path = "/tmp/zzc192-werr.log";
    var wf: Io.File.Writer = undefined;
    var wbuf: [512]u8 = undefined;
    var wfile = std.Io.Dir.createFileAbsolute(io_, werr_path, .{}) catch return error.TestUnexpectedResult;
    defer wfile.close(io_);
    wf = Io.File.Writer.init(wfile, io_, &wbuf);
    werr = &wf.interface;
    defer werr = undefined; // 先注册=后跑：wf.flush 于其前执行完毕
    defer wf.interface.flush() catch {};
    // 前置清理（A1「尚无文件」须为真前提）+ 尾部回清。自捕（五跑）：上一跑 ABRT 崩溃
    //   把 logs/untranslated_phrases.json 残留成**目录**形态（C 段构造的失败注入态），
    //   deleteFile 对目录失败、pathExists 仍真——改 deleteTree 递归删（文件/目录/子树
    //   全形态归零，崩溃幂等）。
    std.Io.Dir.cwd().deleteTree(io_, "logs") catch {};
    defer std.Io.Dir.cwd().deleteTree(io_, "logs") catch {};

    // A1 F3 契约主钉：空清单 → 早退、不建文件（防 CI 把恒在空文件误读为「零未译」）。
    untranslated_list = .{};
    flushUntranslated();
    try std.testing.expect(!pathExists("logs/untranslated_phrases.json"));

    // A2 非空落盘端到端：entry 字段透传 + generated_at 走 real 时钟（下界=epoch 秒
    //   量级、上界拒 monotonic 族小值——ts 源被改成开机钟即红）+ 键名形制自证。
    const PHRASE = "未译甲";
    const LOC = "src/a.zz:1:2";
    const TS: i64 = 1700000001;
    var items_a = std.ArrayList(UntranslatedPhrase).empty;
    defer items_a.deinit(std.testing.allocator); // 六跑自捕：原 errdefer+defer 同指针双 deinit（见尾部总注）
    try items_a.append(std.testing.allocator, .{ .phrase = PHRASE, .location = LOC, .timestamp = TS });
    untranslated_list = .{ .items = items_a };
    flushUntranslated();
    try std.testing.expect(pathExists("logs/untranslated_phrases.json"));
    // 自捕（二跑）：JsonDoc 系 pure_filter 模块私有 const 不可 import——改动态
    //   std.json.Value 解析，键名形制（generated_at/phrase/…）在测试侧显式写死，
    //   反证面更宽（改键名即红）。
    const raw_a = try readFileRaw("logs/untranslated_phrases.json");
    const dv = try std.json.parseFromSlice(std.json.Value, gpa_, raw_a, .{});
    defer dv.deinit();
    const doc = dv.value;
    const ga = doc.object.get("generated_at").?;
    // 自捕（三跑）：0.17 动态 union 无 `Integer` 大写成员；tag 断言系冗余——
    //   下行 ga.integer 字段访问本身即 tag 校验（错 tag 直崩即红），删专门断言。
    const now_hi = @as(i64, @intCast(@divFloor(Io.Timestamp.now(io_, .real).nanoseconds, std.time.ns_per_s)));
    try std.testing.expect(ga.integer >= 1_760_000_000); // 下界：实置真时钟
    try std.testing.expect(ga.integer <= now_hi + 60); // 上界：monotonic 族小值直穿
    const arr = doc.object.get("phrases").?;
    try std.testing.expectEqual(@as(usize, 1), arr.array.items.len);
    const e0 = arr.array.items[0].object;
    try std.testing.expectEqualStrings(PHRASE, e0.get("phrase").?.string);
    try std.testing.expectEqualStrings(LOC, e0.get("location").?.string);
    try std.testing.expectEqual(TS, e0.get("timestamp").?.integer);
    try std.testing.expectEqualStrings("[待翻译] " ++ PHRASE, e0.get("suggested_translation").?.string);

    // A3 去重清单多 entry 顺序透传：log 去重属纯函数面（已有钉），壳侧契约=条目序照传。
    var items_c = std.ArrayList(UntranslatedPhrase).empty;
    defer items_c.deinit(std.testing.allocator); // 六跑自捕：双手清理改单手（同上）
    var lc_c = UntranslatedList{};
    // 八跑自捕：log 的 phrase/location 系 gpa.dupe 自持堆串——items.deinit 只释放
    //   数组本体，4 枚 dupe 须逐条 free（LeakCheckedAllocator 直报 leaked 4）。
    defer {
        for (lc_c.items.items) |it| {
            std.testing.allocator.free(it.phrase);
            std.testing.allocator.free(it.location);
        }
        lc_c.items.deinit(std.testing.allocator);
    }
    try lc_c.log(std.testing.allocator, "重复乙", "src/b.zz", 1);
    try lc_c.log(std.testing.allocator, "重复乙", "src/b.zz", 1); // 复合键去重：仍 1 条
    try lc_c.log(std.testing.allocator, "另一丙", "src/c.zz", 2);
    try items_c.appendSlice(std.testing.allocator, lc_c.items.items);
    untranslated_list = .{ .items = items_c };
    flushUntranslated();
    const raw_c = try readFileRaw("logs/untranslated_phrases.json");
    var vd_c = try std.json.parseFromSlice(std.json.Value, gpa_, raw_c, .{});
    defer vd_c.deinit();
    const arr_c = vd_c.value.object.get("phrases").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr_c.items.len);
    try std.testing.expectEqualStrings("重复乙", arr_c.items[0].object.get("phrase").?.string);
    try std.testing.expectEqualStrings("另一丙", arr_c.items[1].object.get("phrase").?.string);

    // B1 同清单重写=覆盖非追加（createFile 默认 truncate 经壳成立）：条数仍 2
    //   （generated_at 秒级可变，不拿全文相等当判据、防跨秒假红）。
    flushUntranslated();
    const raw_b1 = try readFileRaw("logs/untranslated_phrases.json");
    var vd_b1 = try std.json.parseFromSlice(std.json.Value, gpa_, raw_b1, .{});
    defer vd_b1.deinit();
    try std.testing.expectEqual(@as(usize, 2), vd_b1.value.object.get("phrases").?.array.items.len);

    // B2 序列化失败静面（catch printErr 臂）：fail-at-0 分配器注入 gpa_ → render 首
    //    alloc 即 OOM → printErr「序列化失败…已跳过落盘」+ return——void 签名即「不改
    //   退出码」契约本体（改成 try 传播则 defer 调用点编译期自守）。借清单字段零分配
    //   路径（纯 ASCII 免转义），不触 io 分配面。
    {
        wf = Io.File.Writer.init(wfile, io_, &wbuf); // 复用句柄重开 writer（append 语义、读前 flush）
        werr = &wf.interface;
        var b_items = std.ArrayList(UntranslatedPhrase).empty;
        defer b_items.deinit(std.testing.allocator); // 六跑自捕：双手改单手（同上）
        try b_items.append(std.testing.allocator, .{ .phrase = "plain-ascii", .location = "src/d.zz", .timestamp = 3 });
        untranslated_list = .{ .items = b_items };
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        gpa_ = fa.allocator();
        flushUntranslated();
        gpa_ = arena.allocator(); // 回置必须早于块尾 flush defer（werr 后续仍用 io_）
        wf.interface.flush() catch {};
        const wraw = try readFileRaw(werr_path);
        try std.testing.expect(std.mem.indexOf(u8, wraw, "序列化失败") != null);
        try std.testing.expect(std.mem.indexOf(u8, wraw, "已跳过落盘") != null);
    }

    // C 落盘失败静面（writeWhole catch 臂）：目标路径已是目录 → createDirPath/createFile
    //   失败 → printErr「落盘失败…已跳过」、void 静默返回（改成 try 传播即主报错升格缺陷）。
    {
        // 七跑自捕：B2 块尾 defer 已把 b_items 归还 testing.allocator，而全局
        //   untranslated_list 拷贝未回清——C 段壳读到悬垂内存（phrase.len 垃圾直
        //   接诱发 render 巨量分配 integer overflow）。回清归段内职责、跨段交接
        //   须显式重置全局（188/189 全局接线回置守则同族延伸）。
        untranslated_list = .{};
        std.Io.Dir.cwd().deleteTree(io_, "logs") catch {}; // 承上：整树归零再造目录态
        try std.Io.Dir.cwd().createDirPath(io_, "logs/untranslated_phrases.json");
        wf = Io.File.Writer.init(wfile, io_, &wbuf);
        werr = &wf.interface;
        var c_items = std.ArrayList(UntranslatedPhrase).empty;
        defer c_items.deinit(std.testing.allocator); // 单手清理（六跑自捕同族）
        try c_items.append(std.testing.allocator, .{ .phrase = "落盘失败钉", .location = "src/f.zz", .timestamp = 5 });
        untranslated_list = .{ .items = c_items };
        flushUntranslated(); // 非空清单 → writeWhole 失败臂
        wf.interface.flush() catch {};
        const wraw = try readFileRaw(werr_path);
        try std.testing.expect(std.mem.indexOf(u8, wraw, "落盘失败") != null);
        try std.testing.expect(std.mem.indexOf(u8, wraw, "已跳过") != null);
        std.Io.Dir.cwd().deleteDir(io_, "logs/untranslated_phrases.json") catch {};
    }

    // B3 defer free(json) 泄漏钉（191 S1 同族反证靶）：gpa_ 换 FailingAllocator 直连
    //   （0.17 断代自捕：statsAllocator 已不存在——改读 fa.allocations/deallocations
    //   公开计数字段；init 第二参为 Config 结构非裸整数）。壳的 defer gpa_.free(json)
    //   如实兑现；去 defer 即 allocations > deallocations 测红。
    {
        untranslated_list = .{};
        var b3_items = std.ArrayList(UntranslatedPhrase).empty;
        defer b3_items.deinit(std.testing.allocator); // 六跑自捕：双手改单手（同上）
        try b3_items.append(std.testing.allocator, .{ .phrase = "plain-ascii2", .location = "src/e.zz", .timestamp = 4 });
        untranslated_list = .{ .items = b3_items };
        var fa3 = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        gpa_ = fa3.allocator();
        flushUntranslated();
        gpa_ = arena.allocator(); // 回置早于块尾（B3 无 werr 依赖、计数已定格）
        try std.testing.expectEqual(fa3.deallocations, fa3.allocations);
        try std.testing.expect(fa3.allocations > 0); // 防双零假绿（render 确走过分配）
    }
}
