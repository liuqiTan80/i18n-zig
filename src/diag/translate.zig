//! 报错回译：解析 zig 的英文诊断，经 ColumnMap 映射回方言位置，
//! 反转码符号名，按语言包模式表匹配母语译文与教学提示。
//!
//! zig 输出形如：
//!   path:line:col: error: cannot assign to constant
//! 渲染统一为母语风格：
//!   错误: 不可变常量不能被重新赋值
//!     --> src/main.zz:3:5
//!     | const 数量 = 10; 数量 += 1;
//!     💡 <教学提示>

const std = @import("std");
const ColumnMap = @import("../transpiler/column_map.zig");
const Mangle = @import("../transpiler/mangle.zig");
const Pack = @import("../lang/pack.zig");
const PureFilter = @import("pure_filter.zig").PureFilter; // 取嵌套 struct，非文件根命名空间
const UntranslatedList = @import("pure_filter.zig").UntranslatedList;
const zzc = @import("../zzc_paths.zig"); // 第 200 轮 D68：内部路径族的隐藏判据与族成员同源
const mcon = @import("../machine_contract.zig"); // 第 203 轮 D71：机读单行格式串取契约 hub 真值
const kdiag = @import("kind.zig"); // 第 208 轮 D76：机读 kind 词汇(en↔zh↔severity)取单一真值 hub

/// 产品时间源（F3）：主层启动时经 `setIo` 注入；单测图不注入保持默认 null → 取时回 0，
/// 诊断纯函数测试图不被 Io 污染（D7 可测性守则）。
var io_: ?std.Io = null;
pub fn setIo(io: std.Io) void {
    io_ = io;
}

/// 当前 epoch 秒（F3 记录面）：取时在产品边界（本层有 Io），不下沉进 pure_filter——
/// 过滤器本体保持纯函数可单测（D7）。单测等无产品时间语境传 io=null → 回 0（不致命）。
fn nowEpochS(io: ?std.Io) i64 {
    const i = io orelse return 0;
    const t = std.Io.Timestamp.now(i, .real); // 0.17 Clock 枚举真名是 `.real`（非 `.realtime`，D12 同族 API 断代）
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s));
}

/// 一个已翻译的编译单元：方言文件 <-> 生成文件 的对照。
pub const Unit = struct {
    native_path: []const u8, // 如 src/main.zz
    gen_path: []const u8, // 如 .zzc/gen/src/main.zig（报错里出现的形态）
    gen_src: []const u8, // 生成的标准 Zig 源码（用于把 zig 行列表述回字节偏移）
    nat_src: []const u8, // 方言源码
    map: ColumnMap,
};

// 机器 kind 段词表已下沉至 D76 单一真值 hub `diag/kind.zig`：本文件经 `kdiag.lookupZh`（en→zh）
// 与 `kdiag.zh_values`（值面·machineHead 判据）读之，消费侧 main.kindSeverity 同源读 `severityOf`。

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// 消息里的 ASCII 转码名 z_<n> 替换回母语名。
/// 仅当 `z_<数字>` 构成一个**极大词元**（左右两侧都不紧邻标识符字符）才反查：
/// 左边界避开 `az_1`/`xz_1`，右边界避开 `z_1x`/`z_1_2`（防把更长的 ASCII 标识符 `z_1x` 的前缀
/// `z_1` 误反查成母语名、拼出 `母语名x`）。与 `reserveZInText` 的极大词段判定保持对称。
/// 跨模块链 `z_1.z_2`（`.` 非标识符字符）两侧均能各自反查。
pub fn unmangleText(gpa: std.mem.Allocator, text: []const u8, table: Mangle) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 'z' and i + 1 < text.len and text[i + 1] == '_' and
            (i == 0 or !isIdentChar(text[i - 1])))
        {
            var j = i + 2;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            // 需至少一位数字，且右侧紧邻的不能是标识符字符（字母/数字/下划线），否则属更长标识符、不反查。
            if (j > i + 2 and (j == text.len or !isIdentChar(text[j]))) {
                if (table.unmangle(text[i..j])) |native| {
                    try out.appendSlice(gpa, native);
                    i = j;
                    continue;
                }
            }
        }
        try out.append(gpa, c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// 按语言包 diagnostics 表匹配消息译文模板与提示；未命中返回原消息。
/// 采用子串匹配（而非仅前缀）：zig 常把诊断短语嵌在主题之后，
/// 如 `root source file struct 'main' has no member named 'x'`，仅前缀会漏匹、造成英文泄漏。
fn matchDiag(lang: Pack, msg: []const u8) struct { message: []const u8, tip: []const u8, matched: bool } {
    for (lang.diagnostics.items) |e| {
        if (std.mem.indexOf(u8, msg, e.pattern) != null) {
            return .{ .message = e.message, .tip = e.tip, .matched = true };
        }
    }
    return .{ .message = msg, .tip = "", .matched = false };
}

/// 把一段 allocPrint 格式化的临时串追加进 `out`，追加后即刻释放临时串。
/// 旧写法 `out.appendSlice(gpa, try allocPrint(gpa, …))` 把临时串字节拷入 out 后从不 free，
/// 非 arena 分配器下每调用泄 1 块（第 69 轮 D27，与 D23 renderReport 同族反模式）；
/// arena 生产路径不体现、但既有测均以 arena 包裹而从未暴露（本文件新测直接喂 testing.allocator 坐实）。
fn appendPrintF(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}

/// 渲染单条诊断为母语文本（调用方 free）。
pub fn renderDiag(
    gpa: std.mem.Allocator,
    lang: Pack,
    table: Mangle,
    units: []const Unit,
    file_path: []const u8,
    line: usize,
    col: usize,
    kind: []const u8,
    msg: []const u8,
    filter: ?*PureFilter, // 纯母语过滤器（可选）
) ![]const u8 {
    const kind_cn = kdiag.lookupZh(kind) orelse kind;
    const msg_native = try unmangleText(gpa, msg, table);
    defer gpa.free(msg_native);
    const m = matchDiag(lang, msg_native);

    // 未命中语言包模式时，对消息做已知短语的母语替换（如 `expected …, found …` 解析错），
    // 作为兜底——至少把语法脚手架类词语本地化，避免整句英文直接泄漏。
    var msg_disp = m.message;
    var owned_msg: ?[]const u8 = null;
    if (!m.matched) {
        owned_msg = try localizeRunner(gpa, m.message);
        msg_disp = owned_msg.?;
    }
    defer if (owned_msg) |o| gpa.free(o);

    // 纯母语过滤器：在报错输出前做最终检查，对任何残留的英文进行拦截或兜底翻译
    var filtered_msg = msg_disp;
    var owned_filtered: ?[]const u8 = null;
    if (filter) |f| {
        if (f.*.detectEnglish(msg_disp)) {
            if (!f.*.whitelist.check(msg_disp)) {
                owned_filtered = try f.*.filterMessage(gpa, msg_disp, file_path, nowEpochS(io_));
                filtered_msg = owned_filtered.?;
            }
        }
    }
    defer if (owned_filtered) |o| gpa.free(o);

    // 定位方言单元与偏移，取母语源码片段（行号两端一致，行内字节宽度经 ColumnMap 反查）。
    var snippet: []const u8 = "";
    var loc_native: []const u8 = file_path;
    var native_line = line;
    var native_col = col;
    // 位置落在 zig 内部/绝对路径且无法映射回方言时，隐藏 `-->` 位置行（仅保留译文+提示），
    // 避免把机器相关的安装路径泄给学习者。
    var show_loc = true;
    if (nativeLoc(units, file_path, line, col)) |L| {
        loc_native = L.path;
        native_line = L.line;
        native_col = L.col;
        snippet = L.snippet;
    } else if (isInternalPath(file_path)) {
        show_loc = false;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (show_loc) {
        try appendPrintF(&out, gpa, "{s}: {s}\n  --> {s}:{d}:{d}\n", .{
            kind_cn, filtered_msg, loc_native, native_line, native_col,
        });
        if (snippet.len != 0) {
            try appendPrintF(&out, gpa, "  | {s}\n", .{snippet});
        }
    } else {
        try appendPrintF(&out, gpa, "{s}: {s}\n", .{ kind_cn, filtered_msg });
    }
    if (m.tip.len != 0) {
        try appendPrintF(&out, gpa, "  \u{1f4a1} {s}\n", .{m.tip});
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// 机读单行化（第 154 轮 · 编辑器/CI 集成出口 `--machine`）
// ---------------------------------------------------------------------------

/// 渲染器提示行前缀（renderDiag 与 dependency-loop 块同源）。
const tip_mark = "\u{1F4A1}";

/// 块形制顶行判据：`<种类>: <消息>`，且 `<种类>` 恰为 kind_zh 值面之一。
/// 词表取渲染器自身的 kind_zh（不新增硬编码词表，免 D34/D35 误注族）：顶格要求与渲染器一致；
/// 已是单行的 `src/main.zz:4:21: 词法: …` 首个冒号后不是空格 → 不误判、原样透传。
fn machineHead(line: []const u8) ?struct { kind: []const u8, msg: []const u8 } {
    if (line.len == 0) return null;
    if (line[0] == ' ' or line[0] == '\t') return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (colon == 0) return null;
    if (line.len < colon + 2 or line[colon + 1] != ' ') return null;
    const kind = line[0..colon];
    for (kdiag.zh_values) |v| {
        if (std.mem.eql(u8, v, kind)) return .{ .kind = kind, .msg = line[colon + 2 ..] };
    }
    return null;
}

const MachinePending = struct {
    kind: []const u8,
    msg: []const u8,
    loc: ?FrameLoc = null,
    tip: ?[]const u8 = null,
};

/// 结算一个挂起块：有位置→`路径:行:列: 种类: 消息（提示：…）`；无位置→原样 `{种类}: {消息}`。
fn flushMachine(gpa: std.mem.Allocator, out: *std.ArrayList(u8), maybe: ?MachinePending) !void {
    const p = maybe orelse return;
    if (p.loc) |L| {
        if (p.tip) |tip| {
            try appendPrintF(out, gpa, mcon.line_fmt_tip, .{ L.file, L.line, L.col, p.kind, p.msg, tip });
        } else {
            try appendPrintF(out, gpa, mcon.line_fmt, .{ L.file, L.line, L.col, p.kind, p.msg });
        }
    } else {
        try appendPrintF(out, gpa, "{s}: {s}\n", .{ p.kind, p.msg });
    }
}

/// 把已回译的母语输出压成「每条诊断一行」的机读形制 `路径:行:列: 种类: 消息（提示：…）`，
/// 与 main 直出的 `词法`/`纯母语` 行同构。
///
/// 为何需要（154 轮以真实输出 + node 实测为证）：块形制把消息与位置分在相邻两行，而 VS Code
/// problemMatcher 的 pattern 数组状态**只向后传递**（首模式捕 file、后续模式补 line/message），
/// 「消息在前、位置在后」捕不到（逐行正则对块形制 0/8 命中）；本出口把二者合一行后，
/// 编辑器侧只需一条逐行正则即可覆盖全部诊断种类（也是后续 LSP/CI 消费的同一出口）。
///
/// 形制契约（判据全取自本模块自有渲染形制）：
///   - `{种类}: …` 顶行 + `  --> 路径:行:列` + `  | 回显`（丢） + `  💡 提示`（并入）→ 合一并行；
///   - 无位置的顶行（位置落 zig 内部/不可回映时渲染器本就省 `-->` 行）→ 原样一行（无路径、匹配器不采）；
///   - 单独的 `  --> 路径:行:列`（zig test 失败栈帧位置）无消息可配 → 原样透传；
///   - 已是单行的诊断（词法/纯母语）与透传行（用户程序 stderr 等）→ 逐字节原样输出。
pub fn machineLines(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var pending: ?MachinePending = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |seg| {
        const raw = std.mem.trimEnd(u8, seg, "\r\n");
        const t = std.mem.trimStart(u8, raw, " \t");

        if (std.mem.startsWith(u8, t, "--> ")) {
            if (pending) |*p| {
                if (p.loc == null) p.loc = splitLoc(std.mem.trimEnd(u8, t[4..], " \t"));
            } else {
                try out.appendSlice(gpa, raw);
                try out.append(gpa, '\n');
            }
            continue;
        }
        if (std.mem.startsWith(u8, t, "| ")) continue; // 源码回显行：单行制不需它、丢
        if (std.mem.startsWith(u8, t, tip_mark)) {
            if (pending) |*p| {
                p.tip = std.mem.trim(u8, t[tip_mark.len..], " \t");
            } else {
                try out.appendSlice(gpa, raw);
                try out.append(gpa, '\n');
            }
            continue;
        }
        if (machineHead(raw)) |h| {
            try flushMachine(gpa, &out, pending); // 前一块先结算
            pending = MachinePending{ .kind = h.kind, .msg = h.msg };
            continue;
        }
        // 其余行（空行、透传行）：先结算挂起块，再原样输出本行。
        try flushMachine(gpa, &out, pending);
        pending = null;
        try out.appendSlice(gpa, raw);
        try out.append(gpa, '\n');
    }
    try flushMachine(gpa, &out, pending);
    // 末尾幻影空段（splitScalar 对以 `\n` 结尾的输入多出的一段）与多余空行一并剪掉、只补回一个换行
    //（同 translateStderr 出栈前的归一形制，保证输出恒以单 `\n` 结尾、不凭空造空行）。
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        out.shrinkRetainingCapacity(out.items.len - 1);
    }
    if (out.items.len > 0) try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

const NativeLoc = struct { path: []const u8, line: usize, col: usize, snippet: []const u8 };

/// 若 file 命中某方言单元，返回其方言路径/行列/源码片段；否则 null（如 stdlib 帧）。
fn nativeLoc(units: []const Unit, file_path: []const u8, line: usize, col: usize) ?NativeLoc {
    for (units) |u| {
        if (!pathsMatch(file_path, u.gen_path)) continue;
        // 行号在两端一致（逐字节保留换行），但行内字节宽度不同，
        // 必须先在生成源码中定位字节偏移，再经 ColumnMap 反查方言偏移。
        var goff: usize = 0;
        var gl: usize = 1;
        while (gl < line and goff < u.gen_src.len) : (gl += 1) {
            const nl = std.mem.indexOfScalarPos(u8, u.gen_src, goff, '\n') orelse break;
            goff = nl + 1;
        }
        // zig 报的是**字节列**（1 基），故 col-1 恒等于行内字节增量。
        // 74 轮已裁定 col=0 生产不可达（zig 输出恒 1 基、run 路用户 stderr 不经本链、B1）；
        // 但本函数属 pub 回译链入口、不对未来调用方留缺口：@max 钳制消 usize 下溢（88 轮探针
        // 坐实旧形 `col - 1` 喂 0 即 panic: integer overflow），0 列退化为行首（同 splitLoc 缺列形）。
        const std_off = goff + (@max(col, 1) - 1);
        // ——与该行是否含 CJK 无关：字符串/注释逐字节原样保留，在方言端与生成端字节数相同，不扰动映射。
        const nat_off = u.map.toNative(std_off);
        const lc = ColumnMap.lineColOf(u.nat_src, nat_off);
        return .{
            .path = u.native_path,
            .line = lc.line,
            .col = lc.col,
            .snippet = ColumnMap.lineText(u.nat_src, nat_off),
        };
    }
    return null;
}

/// zig test 失败栈帧形如 `path:line[:col]: 0xADDR in name (obj)`。
/// 命中则返回 location 前缀 `path:line[:col]`（不含 `: 0x...`），非栈帧返回 null。
fn parseFrame(raw: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, raw, ": 0x") orelse return null;
    const after = raw[at + 3 ..]; // ": 0x" 中 at 指向 ':'，+3 落在 'x'，故 after = "x<hex> in "
    if (after.len < 1 or after[0] != 'x') return null;
    var k: usize = 1;
    while (k < after.len and std.ascii.isHex(after[k])) k += 1;
    if (k == 1) return null; // 0x 后无十六进制数字
    if (!std.mem.startsWith(u8, after[k..], " in ")) return null;
    return raw[0..at];
}

const FrameLoc = struct { file: []const u8, line: usize, col: usize };

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// 拆 `file:L:C` 或 `file:L`（Windows 路径含 `C:` 盘符，从右往左取数字段）。
fn splitLoc(loc: []const u8) ?FrameLoc {
    const c1 = std.mem.lastIndexOfScalar(u8, loc, ':') orelse return null;
    const tail = loc[c1 + 1 ..];
    if (!allDigits(tail)) return null;
    const head = loc[0..c1];
    if (std.mem.lastIndexOfScalar(u8, head, ':')) |c2| {
        const mid = head[c2 + 1 ..];
        if (allDigits(mid)) {
            return .{
                .file = head[0..c2],
                .line = std.fmt.parseInt(usize, mid, 10) catch return null,
                .col = std.fmt.parseInt(usize, tail, 10) catch return null,
            };
        }
    }
    return .{ .file = head, .line = std.fmt.parseInt(usize, tail, 10) catch return null, .col = 1 };
}

/// 短语替换表（文件级：供 localizeRunner 与「前缀劫持不变量」护栏测共同引用）。
/// **表序即优先级**：匹配是逐偏移 `startsWith` 首中即停，所以若表序靠前的短语是另一靠后
/// 短语的**严格前缀**（如 `argument` 排在 `arguments` 前），短串会在同偏移永久截胡长串、
/// 长串条目失效、译文静默劣化——且这类错位不报错、只悄悄变坏。下面成对注释的排序约束
/// 由此不变量测自动钉死（第 92 轮），新增条目排错序即红，不再只靠人肉注释提醒。
const runner_pairs = [_][2][]const u8{
    .{ "expected ", "期望 " },
    .{ ", found ", "，实得 " },
    .{ "; found ", "；实得 " },
    .{ " passed", " 通过" },
    .{ " skipped", " 跳过" },
    .{ " failed", " 失败" },
    // 逐用例失败行 zig 打 `FAIL (错误集名)`（与汇总行的小写 `failed` 不同形）：状态词 `FAIL` 本地化，
    // 括号内的错误集名（如 TestExpectedEqual）按项目惯例作类型/错误操作数原样保留。
    .{ "FAIL ", "失败 " },
    // 无位置的 CLI 级裸诊断：只翻前缀/关键短语，保留尾部（如非法参数名）。
    // 第 209 轮 D77：三枚母语前缀词的「值面」委派 kind 词汇 hub `kdiag.zhOf`（编译期派生）——
    // 旧形制下 错误/警告/说明 在 kind.zig(entries) 与本表两处各抄一份，改 hub 则 machineHead/renderDiag
    // kind 段随 hub 动、本消息体前缀却留旧词，两条渲染路径对同一 warning 概念渲出「警告 vs 告警」不一致
    // 而全库无锚（P3 探针：本行「警告: 」改「告警: 」→ zig build test 12/12 全绿）。委派后值恒同源、
    // 结构上不可能再各自漂移；209 T1 round-trip 测把本表输出逐字节钉回 hub，防有人重新回硬编/改英文匹配键。
    .{ "error: ", kdiag.zhOf("error") ++ ": " },
    .{ "warning: ", kdiag.zhOf("warning") ++ ": " },
    .{ "note: ", kdiag.zhOf("note") ++ ": " },
    .{ "unrecognized parameter", "无法识别的参数" },
    // 需保留具体数值/字段名/类型名的诊断：按短语本地化、不丢弃 zig 给出的具体信息（走命中失败后的兜底路）。
    .{ "argument(s)", "参数" },
    .{ "arguments", "参数" },
    .{ "argument", "参数" }, // 单数形式（如 `@enumFromInt` 少参报 "expected 1 argument"）；须排在 `arguments`/`argument(s)` 之后，不抢复数前缀。
    .{ "duplicate switch value", "重复的匹配分支值" }, // 保留被重复的具体值 '1'。
    .{ "previous value", "先前的分支值" }, // 配以上说明行。
    .{ "array elements", "数组元素" },
    .{ "an identifier", "标识符" }, // 解析错描述符（如 `expected 'an identifier', found '='`）；词序与中文对齐、且保留 `found` 侧的具体符号操作数。
    .{ "missing struct field", "结构体缺少字段" },
    .{ "cannot represent integer value", "无法表示整数值" },
    // 保留数字操作数的下标越界消息：英文词序与中文天然对齐（index→下标、outside array of length→超出数组长度），
    // 两端数字 5/3 原样保留（同 `期望 N 参数，实得 M` 机制）。须在通用 `length ` 之前、且靠各自偏移的前缀匹配。
    .{ "outside array of length ", "超出数组长度 " },
    .{ "index ", "下标 " },
    // 格式串与实参类型不符（`std.fmt`/打印 常见）：`invalid format string 'd' for type 'X'`——
    // 用一对短语保住格式符 'd' 与类型操作数 'X'（整句模板反而会丢这两个关键信息）。
    .{ "invalid format string ", "无效格式串 " },
    .{ " for type '", " 对类型 '" },
    .{ "type '", "类型 '" },
    // 枚举 `匹配` 非穷尽时逐条列出的说明行 `unhandled enumeration value: 'X'`——保住未处理的枚举成员名 'X'（主错 `switch must handle` 已由 packs `匹配不穷尽` 接住）。
    .{ "unhandled enumeration value", "未处理的枚举取值" },
    // 格式串/括号未闭合 `missing closing }`（std @compileError）——保住实际的闭合字符 `}`（同族还有 `)` 等）。
    .{ "missing closing ", "缺少闭合的 " },
    // comptime_int 变量须 const：`variable of type 'X' must be const or comptime`——用一对短语把 “variable of type X” 重排为中文的“变量（类型 X）”，
    // 闭括号搭在第二段开头，既保住类型操作数 'X'、又拼出自然语序（const→常数、comptime→计期 用真实别名）。
    .{ "variable of type ", "变量（类型 " },
    .{ " must be const or comptime", "）必须是 `常数`（const）或 `计期`（comptime）" },
    .{ "error union type", "错误联合类型" },
    .{ "optional type", "可选类型" }, // `expected optional type, found 'i64'`（对非可选值用 `.?`）：`expected `/`, found ` 已由上面短语翻译，这里补中间描述词；'i64' 类型签名保留。
    .{ "does not support", "不支持" },
    .{ "field access", "字段访问" },
    .{ "not a function", "不是函数" },
    .{ "cannot dereference non-pointer", "不能解引用非指针" },
    .{ "invalid escape character", "非法转义字符" },
    .{ " is invalid", " 无效" }, // `'struct X' is invalid` 之类：保住被引号包裹的操作数（类型/名字），仅译尾部谓语；配套的 `说明: 声明容器…` 走 packs 给正确写法。
    .{ "length ", "长度 " },
    .{ " here", " 在此处" },
};

/// 测试运行器专有英文短语、以及无位置的 CLI 级裸诊断前缀的母语替换（仅涉及已知串，
/// 不影响其他输出）。裸诊断（如 `error: unrecognized parameter: --release=fast`）不带
/// `file:line:col` 前缀，不进 `parseDiagLine`、只经此透传；按短语替换可保留引发问题的
/// 具体参数名（静态模板反而会丢它），对用户更有用。短语表见 `runner_pairs`（表序即优先级）。
fn localizeRunner(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    const pairs: []const [2][]const u8 = &runner_pairs;
    var out: std.ArrayList(u8) = .empty;
    // D51（第 107 轮）：D26/D29/D37/D49 泄漏族——循环内 try append/appendSlice 增长 OOM 返错时，
    // 已累积的部分译文无人回收；同文件 unmangleText/renderDiag/translateStderr 皆 errdefer out.deinit，
    // 唯独本函数缺席（不对称即铁证）。成功路径 toOwnedSlice 已移交所有权、errdefer 自动撤销。
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        var matched = false;
        for (pairs) |p| {
            if (std.mem.startsWith(u8, s[i..], p[0])) {
                try out.appendSlice(gpa, p[1]);
                i += p[0].len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// 报错路径可能带 ./ 或绝对前缀，宽松匹配生成路径尾部（忽略分隔符差异）。
fn pathsMatch(err_path: []const u8, gen_path: []const u8) bool {
    const norm_err = if (std.mem.startsWith(u8, err_path, "./")) err_path[2..] else err_path;
    return endsWithSepNorm(norm_err, gen_path) or endsWithSepNorm(gen_path, norm_err);
}

/// 判断路径是否为无法映射回方言的 zig 内部/绝对路径：盘符绝对路径（`X:` 开头）、
/// Unix/UNC 前导分隔符，zig 缓存目录（`.zig-cache`），或我方生成目录（`.zzc`）。
/// 这类路径直接展示会泄漏与机器相关的安装位置（如 `C:\Users\…\lib\std\start.zig`）
/// 或对用户不存在的生成产物（如导入缺文件时 zig 报的 `.zzc/gen/…/gone.zig`），应当隐藏。
/// 注意：我方**已生成**文件即便被 zig 以该路径报出，也会先经 nativeLoc/pathsMatch 命中映射、
/// 改展示方言路径；故本判定仅在 nativeLoc 已返回 null（确非我方已映射文件）时才起作用。
/// 第 200 轮 D68：子串由硬编 `".zzc"` 改取族真值 `zzc.root`——旧形制下族成员（生成树/符号表/产物
/// 目录/包目录/临时发射物）散在 4 个模块、本判据与它们无任何引用关系：探针 P1（写侧族名整体改掉、
/// 本判据不动）与 P3（收窄为只认生成树）均 502/502 全绿——耦合面零钉，族改名即把内部路径直泄给用户。
fn isInternalPath(p: []const u8) bool {
    if (p.len >= 2 and p[1] == ':' and std.ascii.isAlphabetic(p[0])) return true; // 盘符
    if (p.len > 0 and (p[0] == '/' or p[0] == '\\')) return true; // Unix/UNC 绝对
    if (std.mem.indexOf(u8, p, ".zig-cache") != null) return true; // 缓存目录
    if (std.mem.indexOf(u8, p, zzc.root) != null) return true; // 我方内部目录族（未映射回方言的产物）
    return false;
}

/// 将 `\` 与 `/` 视为等价的后缀比较（Windows 下 zig 会把路径归一为反斜杠）。
fn endsWithSepNorm(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    const start = hay.len - needle.len;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        const hs = sep(hay[start + i]);
        const ns = sep(needle[i]);
        if (hs != ns) return false;
    }
    return true;
}

fn sep(c: u8) u8 {
    return if (c == '\\') '/' else c;
}

pub const DiagLine = struct {
    file: []const u8,
    line: usize,
    col: usize,
    kind: []const u8,
    msg: []const u8,
};

/// 解析 `file:line:col: kind: message`。非诊断行返回 null。
pub fn parseDiagLine(raw: []const u8) ?DiagLine {
    // file 不能以空白开头（排除 zig 的代码引用展示行）
    if (raw.len == 0 or raw[0] == ' ' or raw[0] == '\t') return null;

    // 找 `:数字+:数字+: ` 结构
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, i, ':')) |c1| : (i = c1 + 1) {
        var j = c1 + 1;
        if (j >= raw.len or !std.ascii.isDigit(raw[j])) continue;
        const line_start = j;
        while (j < raw.len and std.ascii.isDigit(raw[j])) j += 1;
        if (j >= raw.len or raw[j] != ':') continue;
        j += 1;
        const col_start = j;
        if (col_start >= raw.len or !std.ascii.isDigit(raw[col_start])) continue;
        while (j < raw.len and std.ascii.isDigit(raw[j])) j += 1;
        if (j + 1 >= raw.len or raw[j] != ':' or raw[j + 1] != ' ') continue;

        const file = raw[0..c1];
        const line_end = std.mem.indexOfScalarPos(u8, raw, line_start, ':').?;
        const col_end = std.mem.indexOfScalarPos(u8, raw, col_start, ':').?;
        const line_num = std.fmt.parseInt(usize, raw[line_start..line_end], 10) catch continue;
        const col_num = std.fmt.parseInt(usize, raw[col_start..col_end], 10) catch continue;

        // 冒号后：kind 到下一个 `: `，或整句
        const rest = raw[j + 2 ..];
        var kind = rest;
        var msg = rest;
        if (std.mem.indexOfScalar(u8, rest, ':')) |k| {
            const cand = rest[0..k];
            // kind 是单词（无空格）才当作种类；否则整段视为消息
            if (cand.len > 0 and cand.len <= 20 and std.mem.indexOfScalar(u8, cand, ' ') == null) {
                kind = cand;
                msg = rest[k + 1 ..];
                if (msg.len > 0 and msg[0] == ' ') msg = msg[1..];
            }
        }
        return .{
            .file = file,
            .line = line_num,
            .col = col_num,
            .kind = kind,
            .msg = msg,
        };
    }
    return null;
}

/// 仅由 `^` 与 `~` 组成的行（zig 报错定位的波浪线标志）；空串返回 false。
fn onlyCarets(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c != '^' and c != '~') return false;
    }
    return true;
}

/// 把整段 zig stderr 逐行处理：诊断行回译，其余行透传（仅符号反转码）。
/// `seen`：跨多次 zig 调用去重（供 `zzc check` 使用）——入口 `build-exe` 会沿 @import
/// 传递性检查子模块，随后对子模块的 `ast-check` 会重复报同一错；按「回映后的方言语
/// 位置 + kind + 消息」去重，已渲染过的重复块不再输出。单路调用（build/run/test）传 null。
pub fn translateStderr(
    gpa: std.mem.Allocator,
    lang: Pack,
    table: Mangle,
    units: []const Unit,
    stderr: []const u8,
    seen: ?*std.StringHashMap(void),
    filter: ?*PureFilter, // 纯母语过滤器（可选）
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    {
        var it = std.mem.splitScalar(u8, stderr, '\n');
        while (it.next()) |ln| try lines.append(gpa, ln);
    }

    // zig 报错后的“源码回显 + 波浪线”基于生成文件，与母语片段重复，渲染后丢弃。
    // “referenced by:” 回溯块指向 gen/std 内部，对学习者无意义，整块丢弃。
    var drop_display = false;
    var drop_block = false;
    // zig test 失败会附上“error: the following test command failed ...”及其后的
    // 可执行文件调用行（泄漏 .zig-cache 绝对路径与 --seed），两行一并丢弃。
    var drop_cmd_next = false;
    // “dependency loop”错误的顶行无 file:line:col 前缀，其下是一串缩进的 `note:` 帧
    // （指向 .zzc/gen 生成文件、生成源码回显与转码名），逐行透传会多重泄漏；顶行渲染为
    // 单一母语诊断后置此标志，把后续缩进帧与其间空行整块丢弃，直到下一个顶格非空行。
    var skip_dep_frames = false;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const raw = lines.items[i];
        // 纯 `^`/`~` 的定位波浪线恒为 zig 报错装饰、对学习者无意义：无条件丢弃。
        // （EOF 类错误会在诊断行后先输出空行再输出 `^`，若仅在 drop_display 态丢弃，
        // 那个空行会复位丢弃态致使 `^` 泄漏到母语输出。）
        if (onlyCarets(std.mem.trim(u8, raw, " \t\r"))) continue;
        if (skip_dep_frames) {
            // 依赖循环块内：缩进帧（note 帧与生成源码回显）与其间空行均丢弃，
            // 直到遇到下一个顶格非空行才恢复正常处理（该行落到下方继续解析）。
            if (raw.len == 0 or raw[0] == ' ' or raw[0] == '\t') continue;
            skip_dep_frames = false;
        }
        if (raw.len == 0) {
            drop_display = false;
            if (!drop_block and !drop_cmd_next) try out.append(gpa, '\n');
            continue;
        }
        if (drop_cmd_next) {
            drop_cmd_next = false;
            continue; // 丢弃“命令失败”提示后的可执行文件路径行
        }
        if (drop_display) {
            // 丢弃 zig 报错后的源码回显与 `^~` 波浪线：
            //   - 纯 `^~` 波浪线（不论列）直接丢；
            //   - 缩进回显行直接丢；
            //   - 顶格源码回显（第 1 列起的语句，如顶层 const/fn）仅当“下一行是波浪线”时
            //     判定为回显并丢弃（否则旧逻辑会因非缩进而漏放，导致 gen 源码泄漏）；
            //   - 其余顶格行（新诊断 / error:/warning:/note:/referenced by 等）停止丢弃、正常处理。
            const t = std.mem.trim(u8, raw, " \t\r");
            if (onlyCarets(t)) continue;
            if (raw[0] == ' ' or raw[0] == '\t') continue;
            const next_is_caret = (i + 1 < lines.items.len) and
                onlyCarets(std.mem.trim(u8, lines.items[i + 1], " \t\r"));
            if (next_is_caret and parseDiagLine(raw) == null) continue; // 顶格源码回显
            drop_display = false; // 遇到真正的新行，回到正常处理
        }
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (drop_block) {
            if (raw[0] == ' ' or raw[0] == '\t') continue; // 回溯行（缩进）
            drop_block = false;
        }
        if (std.mem.startsWith(u8, trimmed, "referenced by")) {
            drop_block = true;
            continue;
        }
        // zig test 失败栈帧：`path:line[:col]: 0xADDR in name (obj)`。
        // 命中我方生成文件 → 只渲染干净的母语位置（不含栈地址/对象名）；
        // stdlib 帧（泄漏 zig 安装绝对路径）整体丢弃。两种情况都随后吞掉缩进回显。
        if (parseFrame(raw)) |loc| {
            drop_display = true;
            if (splitLoc(loc)) |fl| {
                if (nativeLoc(units, fl.file, fl.line, fl.col)) |L| {
                    try appendPrintF(&out, gpa, "  --> {s}:{d}:{d}\n", .{ L.path, L.line, L.col });
                    if (L.snippet.len != 0) {
                        try appendPrintF(&out, gpa, "  | {s}\n", .{L.snippet});
                    }
                }
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "error: the following test command failed")) {
            drop_cmd_next = true;
            continue;
        }
        // 依赖循环：顶行出单一母语诊断+提示，其下缩进帧整块丢弃（见 skip_dep_frames）。
        if (std.mem.startsWith(u8, trimmed, "error: dependency loop")) {
            const body = std.mem.trim(u8, trimmed["error:".len..], " ");
            const m = matchDiag(lang, body);
            var shown: []const u8 = m.message;
            var owned: ?[]const u8 = null;
            defer if (owned) |o| gpa.free(o);
            if (!m.matched) {
                owned = try localizeRunner(gpa, m.message);
                shown = owned.?;
            }
            // 纯母语过滤器：对依赖循环错误消息进行最终检查。
            // 释放须置于本 dep-loop 块作用域、shown 全部使用之后（同 renderDiag 的 owned_filtered 形制）；
            // 若误写进内层 `if (!whitelist.check)` 块尾，则 filtered 在块一结束即释放、而 shown 在块外
            // 才被下方 appendPrintF 读取 → 悬垂读（use-after-free，第 70 轮 D28）。
            var owned_filtered: ?[]const u8 = null;
            if (filter) |f| {
                if (f.*.detectEnglish(shown)) {
                    if (!f.*.whitelist.check(shown)) {
                        owned_filtered = try f.*.filterMessage(gpa, shown, "dependency loop", nowEpochS(io_));
                        shown = owned_filtered.?;
                    }
                }
            }
            defer if (owned_filtered) |o| gpa.free(o);
            const kind_cn = kdiag.lookupZh("error") orelse "error";
            try appendPrintF(&out, gpa, "{s}: {s}\n", .{ kind_cn, shown });
            if (m.tip.len != 0) {
                try appendPrintF(&out, gpa, "  \u{1f4a1} {s}\n", .{m.tip});
            }
            skip_dep_frames = true;
            continue;
        }
        if (parseDiagLine(raw)) |d| {
            // 纯 zig 内部的说明行（note，且位置是无法映射的绝对/缓存路径，如 `called inline here`、
            // 落在 stdlib 的 `struct declared here`）对学习者无意义且会泄漏安装路径，整条丢弃并吞掉其回显。
            if (std.mem.eql(u8, d.kind, "note") and
                nativeLoc(units, d.file, d.line, d.col) == null and
                isInternalPath(d.file))
            {
                drop_display = true;
                continue;
            }
            const rendered = try renderDiag(
                gpa,
                lang,
                table,
                units,
                d.file,
                d.line,
                d.col,
                d.kind,
                d.msg,
                filter,
            );
            defer gpa.free(rendered);
            // 去重：以回映后的方言位置（无法映射则用原始 gen 位置）+ kind + 消息为键，
            // 同一诊断被多次 zig 调用重复报时仅输出首次，并吞掉本条的源码回显行。
            if (seen) |sm| {
                const loc_key: struct { p: []const u8, l: usize, c: usize } =
                    if (nativeLoc(units, d.file, d.line, d.col)) |L| .{ .p = L.path, .l = L.line, .c = L.col } else .{ .p = d.file, .l = d.line, .c = d.col };
                const key = try std.fmt.allocPrint(gpa, "{s}:{d}:{d}|{s}|{s}", .{ loc_key.p, loc_key.l, loc_key.c, d.kind, d.msg });
                defer gpa.free(key);
                if (sm.get(key) != null) {
                    drop_display = true;
                    continue;
                }
                // dupe 接住、在 put **之前**登记 errdefer（D29，D26 同族源头治理）：0.17 hash_map 空表首
                // put 走一次 alignedAlloc 分配“桶+键值对”合体块；该块失败时 dupe 尚未被表接管，
                // 旧 inline 形 `put(try dupe(...))` 无人回滚 → 泄 dupe 键（新测杀该合体分配坐实红）；
                // 成功路径 errdefer 不触发、表接管键，行为不变（main 端由 arena 整体回收）。
                const owned_key = try gpa.dupe(u8, key);
                errdefer gpa.free(owned_key);
                try sm.put(owned_key, {});
            }
            try out.appendSlice(gpa, rendered);
            drop_display = true;
        } else {
            const native = try unmangleText(gpa, raw, table);
            defer gpa.free(native);
            const localized = try localizeRunner(gpa, native);
            defer gpa.free(localized);
            // 纯母语过滤器（台账 D15）：透传行里的未译英文句子同样终拦；
            // 词链启发式不拦孤立 ASCII 词（参数名/路径段等 B2 操作数），故保留行不会被兜底误伤。
            if (filter) |f| {
                if (f.*.detectEnglish(localized) and !f.*.whitelist.check(localized)) {
                    const filtered = try f.*.filterMessage(gpa, localized, "stderr", nowEpochS(io_));
                    defer gpa.free(filtered);
                    try out.appendSlice(gpa, filtered);
                    try out.append(gpa, '\n');
                    continue;
                }
            }
            try out.appendSlice(gpa, localized);
            try out.append(gpa, '\n');
        }
    }
    // 去除末尾多余空行
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        out.shrinkRetainingCapacity(out.items.len - 1);
    }
    if (out.items.len > 0) try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

const zh_pack = @embedFile("../lang/packs/中文.txt");

test "报错回译快照：常量重赋值 -> 母语译文 + 教学提示" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    const rendered = try renderDiag(
        gpa,
        lang,
        table,
        &.{},
        "src/main.zz",
        3,
        5,
        "error",
        "cannot assign to constant",
        &filter,
    );
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "不可变常量被重新赋值") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "src/main.zz:3:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{1f4a1}") != null); // 含教学提示图标
}

test "诊断回译：短语位于句中（非前缀）也能命中并消除英文泄漏" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // zig 把“has no member”嵌在主题之后；旧的前缀匹配会漏匹、直返英文原文。
    const rendered = try renderDiag(
        gpa,
        lang,
        table,
        &.{},
        "src/lib.zz",
        3,
        20,
        "error",
        "root source file struct 'main' has no member named 'x'",
        &filter,
    );
    defer gpa.free(rendered);
    // 必须命中 packs 中的“成员不存在”模式。
    try hasSub(rendered, "所访问的成员不存在");
    try hasSub(rendered, "src/lib.zz:3:20");
    // 英文短语不得残留。
    try noSub(rendered, "has no member");
    try noSub(rendered, "root source file");
}

test "诊断回译：结构体字段不存在（no field named）不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // zig 对 `p.高` 这类不存在字段的访问报 `no field named ... in struct ...`，
    // 旧语言包仅有 has no member、此处会整句英文直透。
    const rendered = try renderDiag(
        gpa,
        lang,
        table,
        &.{},
        "src/main.zz",
        5,
        34,
        "error",
        "no field named 'z_4' in struct 'main.z_1'",
        &filter,
    );
    defer gpa.free(rendered);
    // 必须命中 packs 中的“字段不存在”模式。
    try hasSub(rendered, "所访问的字段不存在");
    try hasSub(rendered, "src/main.zz:5:34");
    // 英文结构不得残留。
    try noSub(rendered, "no field named");
    try noSub(rendered, "in struct");
}

test "诊断回译：成员/成员函数不存在（no field or member function named）不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // zig 对不存在的方法/字段调用报 `no field or member function named ... in ...`，
    // 与 no field named / has no member 分属三条不同消息，旧包不覆盖这一条。
    const rendered = try renderDiag(
        gpa,
        lang,
        table,
        &.{},
        "src/main.zz",
        5,
        18,
        "error",
        "no field or member function named 'z_7' in 'process.Args.Iterator'",
        &filter,
    );
    defer gpa.free(rendered);
    try hasSub(rendered, "所访问的成员或成员函数不存在");
    try hasSub(rendered, "src/main.zz:5:18");
    // 英文不得残留。
    try noSub(rendered, "no field or member function named");
    try noSub(rendered, "member function");

    // 伴随说明行 `consider using 'try', 'catch', or 'if'` 也必须回译（旧包仅有 consider using 'const'）。
    const note = try renderDiag(
        gpa,
        lang,
        table,
        &.{},
        "src/main.zz",
        5,
        18,
        "note",
        "consider using 'try', 'catch', or 'if'",
        &filter,
    );
    defer gpa.free(note);
    try hasSub(note, "建议处理错误或可选值");
    try noSub(note, "consider using");
    try noSub(note, "catch'");
}

test "诊断回译：变量从未修改 / 建议改用 const 不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // `变量` 声明却从不重新赋值：zig 报 error + 伴随 note，旧包均未覆盖。
    const err = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 6, 8, "error", "local variable is never mutated", &filter);
    defer gpa.free(err);
    try hasSub(err, "局部变量从未被修改");
    try noSub(err, "never mutated");
    try noSub(err, "local variable");

    const note = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 6, 8, "note", "consider using 'const'", &filter);
    defer gpa.free(note);
    try hasSub(note, "建议改用不可变常量");
    try noSub(note, "consider using");
    try noSub(note, "'const'");
}

test "诊断回译：顶层重复声明（duplicate struct member name / duplicate name here）不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 顶层两个同名 `常数`：zig 报 error + note；旧包仅有 redeclaration of（局部作用域），不覆盖。
    const err = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 4, "error", "duplicate struct member name 'z_1'", &filter);
    defer gpa.free(err);
    try hasSub(err, "名字在同一文件结构内被重复声明");
    try noSub(err, "duplicate struct member name");

    const note = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 4, "note", "duplicate name here", &filter);
    defer gpa.free(note);
    try hasSub(note, "与此处名称重复");
    try noSub(note, "duplicate name here");
}

test "诊断回译：参数个数/缺字段/匹配不穷尽/整数越界/除零不泄漏英文且保留具体信息" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // A 参数个数（兜底短语替换，保留具体计数）：
    const argc = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 12, "error", "expected 1 argument(s), found 2", &filter);
    defer gpa.free(argc);
    try hasSub(argc, "参数");
    try hasSub(argc, "1");
    try hasSub(argc, "2");
    try noSub(argc, "argument");
    try noSub(argc, "found");
    // A 下标越界（保留两个数字 5/3）：
    const idx = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 15, "error", "index 5 outside array of length 3", &filter);
    defer gpa.free(idx);
    try hasSub(idx, "下标");
    try hasSub(idx, "超出数组长度");
    try hasSub(idx, "5");
    try hasSub(idx, "3");
    try noSub(idx, "index");
    try noSub(idx, "outside");
    // A 数组初始化个数不符（保留两个数字 2/3）：
    const ar = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 29, "error", "expected 2 array elements; found 3", &filter);
    defer gpa.free(ar);
    try hasSub(ar, "期望");
    try hasSub(ar, "数组元素");
    try hasSub(ar, "实得");
    try hasSub(ar, "2");
    try hasSub(ar, "3");
    try noSub(ar, "array elements");
    try noSub(ar, "found");
    // A 单数 argument（@enumFromInt 少参）：
    const arg1 = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 13, "error", "expected 1 argument, found 2", &filter);
    defer gpa.free(arg1);
    try hasSub(arg1, "参数");
    try noSub(arg1, "argument");
    try noSub(arg1, "found");
    // A 重复匹配分支值（保留 '1'）+ 说明行：
    const dsv = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 35, "error", "duplicate switch value '1'", &filter);
    defer gpa.free(dsv);
    try hasSub(dsv, "重复的匹配分支值");
    try hasSub(dsv, "1");
    try noSub(dsv, "duplicate switch value");
    const pv = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 18, "note", "previous value here", &filter);
    defer gpa.free(pv);
    try hasSub(pv, "先前的分支值");
    try noSub(pv, "previous value");
    // A 参数缺逗号（packs 整句）：
    const mc = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 27, "error", "expected ',' after argument", &filter);
    defer gpa.free(mc);
    try hasSub(mc, "参数列表缺少逗号");
    try noSub(mc, "expected");
    try noSub(mc, "after argument");
    // A 伴随定位行：
    const fnnote = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 1, "note", "function declared here", &filter);
    defer gpa.free(fnnote);
    try hasSub(fnnote, "相关函数在此处声明");
    try noSub(fnnote, "function declared here");

    // B 结构体缺字段（保留字段名 y）：
    const field = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 13, "error", "missing struct field: y", &filter);
    defer gpa.free(field);
    try hasSub(field, "结构体缺少字段");
    try hasSub(field, "y");
    try noSub(field, "missing struct field");

    // C 匹配不穷尽：
    const sw = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 5, "error", "switch must handle all possibilities", &filter);
    defer gpa.free(sw);
    try hasSub(sw, "匹配语句未覆盖所有可能的取值");
    try noSub(sw, "switch must handle");

    // D 整数字面量越界（保留类型与值）：
    const range = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 16, "error", "type 'u8' cannot represent integer value '300'", &filter);
    defer gpa.free(range);
    try hasSub(range, "无法表示整数值");
    try hasSub(range, "'300'");
    try noSub(range, "cannot represent integer value");

    // E 除零 + 冗余修饰：
    const div = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 23, "error", "division by zero here causes illegal behavior", &filter);
    defer gpa.free(div);
    try hasSub(div, "除数为零");
    try noSub(div, "division by zero");
    const red = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 5, "error", "'comptime const' is redundant; instead wrap the initialization expression with 'comptime'", &filter);
    defer gpa.free(red);
    try hasSub(red, "冗余的修饰关键字");
    try noSub(red, "redundant");
}

test "localizeRunner 最长超串优先：裸复数 arguments 整体替换不残留 s（第 75 轮·活路径护栏）" {
    // pairs 采用「逐字符贪心 + 数组序首个前缀命中」，要求最长超串在前：`argument(s)`/`arguments`
    // 必须排在 `argument` 之前。若有人把 `argument` 上移（如按字母序重排），裸复数 "arguments"
    // 会被 `argument` 抢先命中、残留 "s" 于「参数」与「，实得」之间→静默错译。本测钉死该不变量
    // （既有测仅覆盖 `argument(s)`/单数 `argument`，独缺裸复数这一能证伪顺序的唯一形）。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    const out = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 14, "error", "expected 2 arguments, found 3", &filter);
    defer gpa.free(out);
    try hasSub(out, "期望");
    try hasSub(out, "参数，实得"); // 复数被整体替换、无残 "s"（若顺序被破坏则成「参数s，实得」）
    try hasSub(out, "2");
    try hasSub(out, "3");
    try noSub(out, "argument");
}

test "localizeRunner 短语表不变量：表序靠前条目不得是靠后条目的严格前缀（防前缀劫持，第 92 轮护栏）" {
    // localizeRunner 匹配是逐偏移 startsWith 首中即停——若表序靠前的 pair p 是另一靠后 pair q
    // 的**严格前缀**，则同偏移 p 永久截胡 q：q 条目失效、译文静默劣化且编译/跑测均不报错。
    // 现表的三处排序人肉注释（`argument(s)`/`arguments` 先于 `argument`、` for type '` 先于
    // `type '`）即此约束的实例；但注释提醒不了后来者——只有全表扫描才能自动拦截插错序。
    // 同长度重复键一并拒绝（靠后条目成永不命中的死码）。注：`length `/`index ` 那类靠
    // **不同偏移**各自命中、不属同偏移前缀竞争，不受本不变量约束、也不应被它误拦。
    for (runner_pairs, 0..) |p, i| {
        for (runner_pairs[i + 1 ..], 0..) |q, j| {
            const k = i + 1 + j;
            if (std.mem.eql(u8, p[0], q[0])) {
                std.debug.print("重复短语条目: #{d} 与 #{d} `{s}`\n", .{ i, k, p[0] });
                return error.DuplicatePairInTable;
            }
            if (q[0].len > p[0].len and std.mem.startsWith(u8, q[0], p[0])) {
                std.debug.print("前缀劫持: #{d} `{s}` 是 #{d} `{s}` 的严格前缀\n", .{ i, p[0], k, q[0] });
                return error.PrefixHijackInTable;
            }
        }
    }
}

test "第 209 轮 T1 裸诊断 kind 前缀经 localizeRunner 输出逐字节 == kind 词汇 hub（防 runner_pairs 重立手抄/改匹配键）" {
    // 承 D76：kind 段的母语词以 `diag/kind.zig` 为唯一真值。本测把「消息体裸前缀」这条
    // 与 renderDiag kind 段并列的渲染路径也钉回同一 hub：对每个 bare_prefix 种类，喂
    // `<en>: <尾部>`、要求 localizeRunner 产出 `<hub zh>: <尾部>`。若有人把 runner_pairs 的
    // 母语值回硬编成与 hub 相异的词（P3 静默面）、或改动左侧英文匹配键偏离 hub.en，本测即红。
    for (kdiag.entries) |e| {
        if (!e.bare_prefix) continue;
        const input = try std.fmt.allocPrint(std.testing.allocator, "{s}: probe尾部", .{e.en});
        defer std.testing.allocator.free(input);
        const got = try localizeRunner(std.testing.allocator, input);
        defer std.testing.allocator.free(got);
        const want = try std.fmt.allocPrint(std.testing.allocator, "{s}: probe尾部", .{e.zh});
        defer std.testing.allocator.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
}

test "诊断回译：未使用循环标签/语句结束符缺失/'an identifier' 描述符不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // A 未使用循环标签（packs 整句，固定句无载荷）：
    const ul = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 5, "error", "unused while loop label", &filter);
    defer gpa.free(ul);
    try hasSub(ul, "循环标签声明后从未使用");
    try noSub(ul, "unused");
    try noSub(ul, "loop label");
    // 变体 for 循环标签（同一 `loop label` 子串）：
    const uf = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 5, "error", "unused for loop label", &filter);
    defer gpa.free(uf);
    try hasSub(uf, "循环标签声明后从未使用");
    try noSub(uf, "loop label");
    // 块标签变体：
    const ub = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 5, "error", "unused block label", &filter);
    defer gpa.free(ub);
    try hasSub(ub, "块标签声明后从未使用");
    try noSub(ub, "block label");

    // B 语句结束符缺失（packs 整句，词序需重排）：
    const st = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 18, "error", "expected ';' after statement", &filter);
    defer gpa.free(st);
    try hasSub(st, "语句结束后缺少结束符");
    try noSub(st, "after statement");
    try noSub(st, "expected");

    // C 'an identifier' 描述符（localizeRunner 短语，保留 found 侧具体符号）：
    const idf = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 8, "error", "expected 'an identifier', found '='", &filter);
    defer gpa.free(idf);
    try hasSub(idf, "标识符");
    try hasSub(idf, "实得");
    try hasSub(idf, "'='");
    try noSub(idf, "an identifier");
    try noSub(idf, "found");
    try noSub(idf, "expected");
}

test "诊断回译：@import 非字面量/comptime_int 变量须 const/运行时改值提示不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // A @import 参数非字面量（packs 整句，保留 @import 实体）：
    const ai = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 1, 21, "error", "@import operand must be a string literal", &filter);
    defer gpa.free(ai);
    try hasSub(ai, "字符串字面量");
    try noSub(ai, "operand");
    try noSub(ai, "string literal");

    // B comptime_int 变量须 const（localizeRunner 短语对，保留类型操作数 'comptime_int'）：
    const ct = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 9, "error", "variable of type 'comptime_int' must be const or comptime", &filter);
    defer gpa.free(ct);
    try hasSub(ct, "变量（类型 'comptime_int'）");
    try hasSub(ct, "常数");
    try hasSub(ct, "计期");
    try noSub(ct, "variable of type");
    try noSub(ct, "must be const");

    // C 运行时修改需定宽类型（packs 整句说明行）：
    const nt = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 9, "note", "to modify this variable at runtime, it must be given an explicit fixed-size number type", &filter);
    defer gpa.free(nt);
    try hasSub(nt, "固定宽度");
    try noSub(nt, "modify this variable");
    try noSub(nt, "number type");
}

test "诊断回译：枚举声明位置/可选值字段访问/误用尝试不泄漏英文（声明位置通用兜底）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // F 枚举声明位置：靠末尾 `declared here` 通用兜底命中（struct/function 更具体者优先）。
    const enumnote = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 9, "note", "enum declared here", &filter);
    defer gpa.free(enumnote);
    try hasSub(enumnote, "相关定义在此处声明");
    try noSub(enumnote, "declared here");
    try noSub(enumnote, "enum");

    // J 对可选值做字段访问（短语保留类型具体信息）：
    const opt = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 13, "error", "type '?i64' does not support field access", null);
    defer gpa.free(opt);
    try hasSub(opt, "不支持");
    try hasSub(opt, "字段访问");
    try hasSub(opt, "'?i64'");
    try noSub(opt, "does not support");
    try noSub(opt, "field access");

    // K 误用尝试：主体消息保留实得类型名、说明行走 packs 模板。
    const trymax = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 19, "error", "expected error union type, found 'comptime_int'", null);
    defer gpa.free(trymax);
    try hasSub(trymax, "错误联合类型");
    try noSub(trymax, "error union type");
    try noSub(trymax, "expected");
    const trynote = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 19, "note", "consider omitting 'try'", null);
    defer gpa.free(trynote);
    try hasSub(trynote, "建议省略");
    try noSub(trynote, "consider omitting");
}

test "诊断回译：for 长度不符/非函数调用/非法转义不泄漏英文且保留具体信息" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // L for 长度不符：错误走 packs 模板，定位说明行“length N here”经短语保留 N。
    const ferr = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 5, 5, "error", "non-matching for loop lengths", null);
    defer gpa.free(ferr);
    try hasSub(ferr, "并列的多个序列长度不一致");
    try noSub(ferr, "non-matching");
    const fnote = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 5, 9, "note", "length 3 here", null);
    defer gpa.free(fnote);
    try hasSub(fnote, "长度 3");
    try noSub(fnote, "length");
    try noSub(fnote, "here");

    // N 非函数调用（保留类型名）：
    const call = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 12, "error", "type 'i64' not a function", null);
    defer gpa.free(call);
    try hasSub(call, "不是函数");
    try hasSub(call, "'i64'");
    try noSub(call, "not a function");

    // R 非法转义（保留 offending 字符 'q'）：
    const esc = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 15, "error", "invalid escape character: 'q'", null);
    defer gpa.free(esc);
    try hasSub(esc, "非法转义字符");
    try hasSub(esc, "'q'");
    try noSub(esc, "invalid escape character");
}

test "诊断回译：导入漏扩展名（no module named）不泄漏英文且给出 .zz 提示" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // `导入("lib")` 漏写 .zz → zig `no module named 'lib' available within module 'main'`（旧为整句英文透传、无提示）。
    const e = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 1, 11, "error", "no module named 'lib' available within module 'main'", &filter);
    defer gpa.free(e);
    try hasSub(e, "找不到要导入的模块");
    try hasSub(e, ".zz"); // 教学提示需点破本地模块要带 .zz 扩展名
    try noSub(e, "no module named");
    try noSub(e, "available within module");
}

test "诊断回译：解引用非指针/无法解析计期值不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // P 解引用非指针（短语保留类型名）：
    const deref = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 13, "error", "cannot dereference non-pointer type 'i64'", &filter);
    defer gpa.free(deref);
    try hasSub(deref, "不能解引用非指针");
    try hasSub(deref, "'i64'");
    try noSub(deref, "cannot dereference");
    try noSub(deref, "non-pointer");

    // T 无法解析计期值 + 类型须计期已知：
    const cv = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 13, "error", "unable to resolve comptime value", &filter);
    defer gpa.free(cv);
    try hasSub(cv, "无法解析编译期");
    try noSub(cv, "unable to resolve comptime value");
    const tk = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 13, "note", "types must be comptime-known", &filter);
    defer gpa.free(tk);
    try hasSub(tk, "类型必须在编译期已知");
    try noSub(tk, "types must be comptime-known");
}

test "诊断回译：指针方法调用两重解引用限制的两条说明行不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 在指针上调需解引用的方法时，zig 除主错外还会打两条 note 续行；均需本地化、不留英文。
    const n1 = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 22, "note", "method invocation only supports up to one level of implicit pointer dereferencing", &filter);
    defer gpa.free(n1);
    try hasSub(n1, "方法调用只支持一重隐式指针解引用");
    try noSub(n1, "method invocation");
    try noSub(n1, "dereferencing");

    const n2 = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 22, "note", "use '.*' to dereference pointer", &filter);
    defer gpa.free(n2);
    try hasSub(n2, "可用 `.*` 解引用指针");
    try noSub(n2, "to dereference pointer");
}

test "诊断回译：丢弃 const 限定说明行不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // U 对 const 数组取地址赋给可变切片时的伴随说明行：
    const cq = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 19, "note", "cast discards const qualifier", &filter);
    defer gpa.free(cq);
    try hasSub(cq, "丢弃");
    try hasSub(cq, "常数");
    try noSub(cq, "cast discards");
    try noSub(cq, "const qualifier");
}

test "诊断回译：入口文件缺 main 收到入口场景指引（D50 合并形）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // build/run/test 指向无 main 的库模块时 zig 报此形。D50（第 106 轮）后该形与「误访 .main 成员」
    // 共用同一消息（文本不可分）、同命中合并后的 `成员不存在` 单条——旧「缺主入口」独立条目
    // 会反向劫持成员访问场景（误导 tip），合并 tip 须同时涵盖入口指引，两形皆不误导。
    const m = try renderDiag(gpa, lang, table, &.{}, "src/lib.zz", 1, 1, "error", "root source file struct 'lib' has no member named 'main'", &filter);
    defer gpa.free(m);
    // 入口场景指引不得丢（合并 tip 末句）：
    try hasSub(m, "主函数");
    try hasSub(m, "入口");
    // 合并后消息为通用成员形：
    try hasSub(m, "所访问的成员不存在");
    try noSub(m, "has no member");
    try noSub(m, "no member named");
}

test "诊断回译：入口非公开（'main' is not marked 'pub'）本地化不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 入口写成非公开 `函数 主函数`（无 pub）时 zig 报 `'main' is not marked 'pub'`；
    // 应命中 packs `入口未公开` 词条、给出母语提示且不残留英文。
    const m = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 1, "error", "'main' is not marked 'pub'", &filter);
    defer gpa.free(m);
    try hasSub(m, "入口");
    try hasSub(m, "公开");
    try noSub(m, "is not marked");
}

test "诊断回译：@import 越过模块根（import of file outside module path）不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 把 test/build/run 直接指向子目录里的 .zz，使该子目录成为模块根，`../` 导入会越过它，
    // zig 报 import of file outside module path；需回译为母语且不留英文。
    const m = try renderDiag(gpa, lang, table, &.{}, "src/core/engine.zz", 1, 12, "error", "import of file outside module path", &filter);
    defer gpa.free(m);
    try hasSub(m, "导入的文件位于模块根目录之外");
    try hasSub(m, "src/core/engine.zz:1:12");
    // 提示需同时涵盖 `../` 越界与绝对路径两种触发（后者共享同一 packs 条目）。
    try hasSub(m, "绝对路径");
    try noSub(m, "import of file");
    try noSub(m, "outside module path");
}

test "诊断回译：导入不存在的文件不泄漏生成路径与 FileNotFound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 导入一个不存在的 .zz 时，zig 报 `unable to load "gone.zig": FileNotFound`，
    // 位置行指向未生成的 `.zzc/gen/.../gone.zig`（无对应方言单元）。两者均需隐藏/回译。
    const m = try renderDiag(gpa, lang, table, &.{}, ".zzc/gen/src/gone.zig", 1, 1, "error", "unable to load \"gone.zig\": FileNotFound", &filter);
    defer gpa.free(m);
    try hasSub(m, "导入的文件无法加载");
    try noSub(m, ".zzc");
    try noSub(m, "gone.zig");
    try noSub(m, "FileNotFound");
    try noSub(m, "unable to load");
}

test "诊断回译：@embedFile 指向缺失资产（failed opening）不泄漏英文与错误名" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 嵌入一个真不存在的资产时，zig 报 `failed opening "nope.txt": FileNotFound`（与 @import 缺失的 `unable to load "` 不同动词）。
    // 走 packs 整句条目 `嵌入文件缺失`（模式 `failed opening "`），具体缺失路径由下方方言片段行（@embedFile("nope.txt")）展示。
    const m = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 19, "error", "failed opening \"nope.txt\": FileNotFound", &filter);
    defer gpa.free(m);
    try hasSub(m, "嵌入的资源文件无法加载");
    try noSub(m, "failed opening");
    try noSub(m, "FileNotFound");
}

test "诊断回译：@embedFile 路径越出模块根（embed of file outside package path）不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // embedFile 用 `../../` 越过模块根时，zig 报 `embed of file outside package path: '../../evil.txt'`（含越界路径操作数）。
    // 走 packs 整句 `嵌入越界`；具体越界路径由下方方言片段行展示。
    const m = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 19, "error", "embed of file outside package path: '../../evil.txt'", &filter);
    defer gpa.free(m);
    try hasSub(m, "越过了模块根");
    try noSub(m, "embed of file outside");
    try noSub(m, "package path");
}

test "诊断回译：file imported here 说明行完整本地化（不残留英文）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    const m = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 11, "note", "file imported here", &filter);
    defer gpa.free(m);
    try hasSub(m, "引用该文件的导入语句");
    try noSub(m, "file imported");
    try noSub(m, "here");
}

test "诊断行解析：file:line:col: kind: msg" {
    const d = diag_parse_one("src/main.zig:7:5: error: use of undeclared identifier 'z_1'");
    try std.testing.expectEqual(@as(usize, 7), d.line);
    try std.testing.expectEqual(@as(usize, 5), d.col);
    try std.testing.expectEqualStrings("error", d.kind);
    try std.testing.expectEqualStrings("use of undeclared identifier 'z_1'", d.msg);
}

test "parseDiagLine 对抗/畸形输入不 panic（两处 .? 由前置结构守卫兜住）、非诊断行一律 null" {
    // 防回归护栏（非在线缺陷登记）：parseDiagLine 解析的是 zig stderr 这一**外部可控**面，
    // 内含两处 `std.mem.indexOfScalarPos(...).?` 强制解包（line_end / col_end）。二者的安全性
    // 依赖**非本地**的前置结构守卫——数字段后必跟 ':'（388）、列数字后必跟 ": "（393）。此测钉死
    // 该跨行不变量：日后若有人重构削弱任一守卫，使解包落空，报错器反成崩溃源（在给用户翻译编译
    // 错误的路径上 panic），本测立即转红。同时以 Windows 盘符 'C:' 正例钉住守卫**不得过度拒绝**。
    const malformed = [_][]const u8{
        "", // 空行
        "  缩进行", // 前导空白（zig 顶格源码回显）
        "a:1:2", // 缺尾部 ": "——若无 393 守卫则 col_end 的 .? panic
        "a:1:2 error", // 列数字后是空格非冒号——同上，守卫兜底返 null
        "a:1", // 仅行号、列冒号缺失
        "a:b:c: msg", // 冒号后非数字
        "a:1x:2: error: m", // 行号段夹字母
        "a:1:2:", // 尾冒号无空格（须 ": "）
        "a:99999999999999999999:1: error: x", // 行号 usize 溢出：parseInt catch → continue（非 panic）
        "普通散文行，无位置前缀", // 纯消息行、无任何冒号
    };
    for (malformed) |raw| {
        if (parseDiagLine(raw)) |_| return error.TestUnexpectedResult; // 畸形行绝不当作诊断
    }
    // 合法行须正确解析（守卫不得过度拒绝）：含 Windows 盘符 'C:' 的路径，其冒号后非数字，
    // 不得被误当作位置分隔——首个数字段匹配须跳过盘符冒号命中真正的 ":行:列: "。
    const win = "C:\\proj\\主.zz:3:4: error: 未声明";
    const dw = parseDiagLine(win) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("C:\\proj\\主.zz", dw.file);
    try std.testing.expectEqual(@as(usize, 3), dw.line);
    try std.testing.expectEqual(@as(usize, 4), dw.col);
    try std.testing.expectEqualStrings("error", dw.kind);
    try std.testing.expectEqualStrings("未声明", dw.msg);
}

// 护栏（第 118 轮证伪落位）：parseDiagLine 定位段之后 `rest` 的 kind/msg 分割启发式
// （`cand.len>0 and <=20 and 无空格` 才认 kind）此前仅被 77 轮 clean「error」正例触及——
// rest 无冒号整段、冒号前含空格、前缀恰 20/21 字符阈值、空前缀四类拒分/恰等分支全零直调。
// 若阈值或空格校验被误改，会对含冒号的普通消息散文伪造出 kind、或把长 kind 整段坠入 msg、
// 令 kind_zh 本地化错位、错误种类词泄漏进正文——既有 e2e 测全用单字 kind 无从暴露。本测钉全分支。
test "parseDiagLine kind/msg 分割启发式全分支：无冒号整段·含空格拒分·20 恰等认/21 拒·空前缀拒（第 118 轮证伪落位）" {
    // ① 干净基线：短 kind「error」正常剖离、msg 去前导空格。
    const d1 = parseDiagLine("src/m.zz:1:2: error: boom") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error", d1.kind);
    try std.testing.expectEqualStrings("boom", d1.msg);
    // ② rest 无冒号：不伪造 kind，整段同时作 kind 与 msg（真实退化形）。
    const d2 = parseDiagLine("src/m.zz:1:2: just a message") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("just a message", d2.kind);
    try std.testing.expectEqualStrings("just a message", d2.msg);
    // ③ 冒号前含空格（"a b"）：拒认 kind、整段留 msg（防把散文首词误当种类词）。
    const d3 = parseDiagLine("src/m.zz:1:2: a b: c") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a b: c", d3.kind);
    try std.testing.expectEqualStrings("a b: c", d3.msg);
    // ④ 冒号前缀恰 20 字符（<=20 上界含端）：认作 kind。
    const d4 = parseDiagLine("src/m.zz:1:2: abcdefghijklmnopqrst: tail") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", d4.kind);
    try std.testing.expectEqualStrings("tail", d4.msg);
    // ⑤ 冒号前缀 21 字符（>20）：拒认 kind、整段留 msg（钉阈值上界恰在 20/21 之间）。
    const d5 = parseDiagLine("src/m.zz:1:2: abcdefghijklmnopqrstu: tail") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstu: tail", d5.kind);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstu: tail", d5.msg);
    // ⑥ rest 以冒号开头（空前缀 cand.len==0）：拒认 kind、整段留 msg。
    const d6 = parseDiagLine("src/m.zz:1:2: : x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(": x", d6.kind);
    try std.testing.expectEqualStrings(": x", d6.msg);
}

test "纯母语过滤器：英文残留被拦截" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();
    // 白名单规则随包加载（F2，51 轮：工具层零硬编码）
    var wlpack = try Pack.parse(gpa, zh_pack);
    defer wlpack.deinit();
    try filter.applyPackRules(wlpack.whitelist.items);

    // 测试英文检测
    try std.testing.expect(filter.detectEnglish("expected type, found 'i64'"));
    try std.testing.expect(!filter.detectEnglish("错误: 类型不匹配"));

    // 测试白名单
    try std.testing.expect(filter.whitelist.check("MyType"));
    try std.testing.expect(filter.whitelist.check("my_variable"));
    try std.testing.expect(filter.whitelist.check("@import"));

    // 测试过滤（本过滤器未注入落盘清单：只拦不记，时间传 nowEpochS(null)=0 即可）
    const result = try filter.filterMessage(gpa, "expected type, found 'i64'", "src/main.zz:5:10", nowEpochS(null));
    defer gpa.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[未翻译]") != null);
}

fn diag_parse_one(s: []const u8) DiagLine {
    return parseDiagLine(s).?;
}

test "测试运行器栈帧回译：栈地址/绝对路径/缓存命令均不泄漏，失败帧映射回母语位置" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 以真实转译产物构造一个方言单元（行号与生成文件一致：第 3 行为 expectEqual 调用）。
    const tr = @import("../transpiler/translate.zig");
    const src = "常数 甲 = 1;\n" ++
        "test \"乙\" {\n" ++
        "    尝试 标准库.测试相等(1, 甲);\n" ++
        "}\n";
    const res = try tr.translate(gpa, src, lang, &table);
    const units = [_]Unit{.{
        .native_path = "src/main.zz",
        .gen_path = "gen/main.zig",
        .gen_src = res.zig_str,
        .nat_src = src,
        .map = res.map,
    }};

    // 模拟 zig test 失败输出：含 stdlib 帧（绝对路径）、我方生成文件帧（含转码名）、
    // 缩进回显与波浪线、总结行、以及会泄漏 .zig-cache 路径/seed 的命令失败行。
    const stderr = "1/1 main.test.乙...expected 1, found 2\n" ++
        "FAIL (TestExpectedEqual)\n" ++
        "C:\\zig\\lib\\std\\testing.zig:93:17: 0xdeadbeef in expectEqualInner__func_827 (test_zcu.obj)\n" ++
        "                return error.TestExpectedEqual;\n" ++
        "                ^\n" ++
        "gen/main.zig:3:5: 0xfeedface in test.乙 (test_zcu.obj)\n" ++
        "    try std.testing.expectEqual(1, z_1);\n" ++
        "    ^\n" ++
        "0 passed; 0 skipped; 1 failed.\n" ++
        "error: the following test command failed with exit code 1:\n" ++
        "D:\\cache\\o\\abc123\\test.exe --seed=0x1234\n";

    const out = try translateStderr(gpa, lang, table, &units, stderr, null, null);
    defer gpa.free(out);

    // 泄漏必须全部消失。
    try noSub(out, "0x");
    try noSub(out, "test_zcu.obj");
    try noSub(out, "z_1");
    try noSub(out, "seed=");
    try noSub(out, "zig-cache");
    try noSub(out, "expectEqual(");
    try noSub(out, "C:\\");
    // 逐用例失败行的状态词 FAIL 已本地化（错误集名作操作数保留）。
    try noSub(out, "FAIL");
    try hasSub(out, "失败 (TestExpectedEqual)");
    // 母语位置与本地化文案必须保留。
    try hasSub(out, "src/main.zz");
    try hasSub(out, "甲"); // 母语源码片段（非转码名）
    try hasSub(out, "期望");
    try hasSub(out, "实得");
    try hasSub(out, "通过");
}

test "unmangleText：只反查极大词元 z_<数字>（右边界防 z_1x、跨模块链 z_1.z_2、左边界防 az_1）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var table = Mangle.init(gpa);
    defer table.deinit();
    _ = try table.intern("甲"); // z_1
    _ = try table.intern("乙"); // z_2

    const check = struct {
        fn run(gp: std.mem.Allocator, tbl: Mangle, input: []const u8, want: []const u8) !void {
            const got = try unmangleText(gp, input, tbl);
            defer gp.free(got);
            try std.testing.expectEqualStrings(want, got);
        }
    }.run;

    // 独立成词的转码名 → 反查回母语名。
    try check(gpa, table, "z_1 与 z_2", "甲 与 乙");
    // 跨模块链：`.` 非标识符字符，两侧各自反查。
    try check(gpa, table, "z_1.z_2", "甲.乙");
    // 右边界：z_1 后紧跟字母/下划线属更长标识符，前缀不反查（避免 z_1x → 甲x）。
    try check(gpa, table, "z_1x", "z_1x");
    try check(gpa, table, "z_1_2", "z_1_2");
    // 左边界：az_1 的 z_1 前缀不反查。
    try check(gpa, table, "az_1", "az_1");
}

// 护栏（第 175 轮证伪落位·diag/translate isIdentChar 零直调面增量审计）：
// isIdentChar 系 unmangleText 反查 z_<n> 极大词元左右两端的词边界判据（L68 左界、L73 右界），
// 与 transpiler/mangle.isIdentByte（reserveZInText 正向避让的同模式词边界谓词）函数体逐字节相同、
// 合起来构成「反向识别 ↔ 正向避让」的边界对称不变量（记忆：识别/避让同模式的函数须边界对称）。
// isIdentByte 已于第 111 轮直钉，独此 isIdentChar 全仓零直调——历轮仅经 unmangleText 整串喂入
// 间接触达、其精确字节集从未被钉。若被误改（丢 `_`、改用 std.unicode 收非 ASCII 字母、增 `$` 等），
// 反向反查边界与正向避让边界即失对称，D36 类「不同母语名撞同一 z_N」前缀误反查静默回归，
// 且恰藏在 unmangleText 端到端测不喂该字节形状的缝隙里隐身。本测以独立 oracle（不依赖
// std.ascii.isAlphanumeric）对全 256 字节做 iff 穷举，钉 isIdentChar 恰为 [0-9A-Za-z_]、
// 非 ASCII 字节恒判词边界；令两模块各自独立钉同一集，任一侧漂移即各自抓红。
test "护栏：isIdentChar 词边界谓词全字节穷举——与 mangle.isIdentByte 对称不变量（第 175 轮证伪落位）" {
    for (0..256) |c| {
        const b: u8 = @intCast(c);
        // 独立 oracle：显式列出合法标识符续字节集，与 std.ascii 实现无关（防 tautology 空转）。
        const want = (b >= '0' and b <= '9') or
            (b >= 'A' and b <= 'Z') or
            (b >= 'a' and b <= 'z') or
            (b == '_');
        try std.testing.expectEqual(want, isIdentChar(b));
    }
    // 关键边界逐例点名（承第 111 轮 isIdentByte 矩阵，形异实同、双侧独立可钉）：
    try std.testing.expect(isIdentChar('a')); // 字母
    try std.testing.expect(isIdentChar('Z')); // 大写字母
    try std.testing.expect(isIdentChar('0')); // 数字
    try std.testing.expect(isIdentChar('_')); // 下划线系 D36 撞号避让依赖的续字节，绝不可从集内丢失
    try std.testing.expect(!isIdentChar(' ')); // 空白断边界
    try std.testing.expect(!isIdentChar('.')); // 点非标识符字节 → 跨模块链 z_1.z_2 两侧各自反查
    try std.testing.expect(!isIdentChar('-')); // 连字符断边界
    try std.testing.expect(!isIdentChar(0x80)); // 非 ASCII 字节（CJK 续字节等）恒判词边界
    try std.testing.expect(!isIdentChar(0xFF)); // 同上：谓词纯 ASCII、高字节永不续标识符
}

test "顶格（第 1 列）语句报错：gen 源码回显与波浪线不泄漏" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 顶层（第 1 行、第 1 列）常数声明，其类型不匹配会触发 zig 回显顶格源码。
    const tr = @import("../transpiler/translate.zig");
    const src = "常数 环值: 整数 = \"哈\";\n";
    const res = try tr.translate(gpa, src, lang, &table);
    const units = [_]Unit{.{
        .native_path = "src/main.zz",
        .gen_path = "gen/main.zig",
        .gen_src = res.zig_str,
        .nat_src = src,
        .map = res.map,
    }};

    // 模拟 zig build-exe 对顶格语句的报错：诊断行 + 顶格源码回显 + 缩进波浪线。
    const stderr = "gen/main.zig:1:18: error: expected type 'i64', found '*const [3:0]u8'\n" ++
        "const z_1: i64 = \"\u{54c0}\";\n" ++
        "                 ^~~~~~~~~~~~~~\n";

    const out = try translateStderr(gpa, lang, table, &units, stderr, null, null);
    defer gpa.free(out);

    // gen 专有语法/回显必须被丢弃：不应出现 const / i64 / 波浪线 / 转码名。
    try noSub(out, "const ");
    try noSub(out, "i64");
    try noSub(out, "^");
    try noSub(out, "z_1");
    try noSub(out, "gen/main");
    // 干净母语块仍完整：方言位置 + 方言源码片段。
    try hasSub(out, "src/main.zz");
    try hasSub(out, "环值");
    try hasSub(out, "常数");
}

test "编译诊断落在 zig 标准库绝对路径：安装路径与英文说明均不泄漏" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const tr = @import("../transpiler/translate.zig");
    const src = "公开 函数 数() 整数 { 返回 1; }\n";
    const res = try tr.translate(gpa, src, lang, &table);
    const units = [_]Unit{.{
        .native_path = "src/lib.zz",
        .gen_path = "gen/lib.zig",
        .gen_src = res.zig_str,
        .nat_src = src,
        .map = res.map,
    }};

    // 模拟将 `zzc run` 指向一个无 main 的子模块：zig 将错误定位到标准库 start.zig
    // 的绝对安装路径，并附带 `called inline here` 说明（同处 stdlib）。
    const stderr = "C:\\Users\\me\\AppData\\zig-x86_64-windows-0.17.0\\lib\\std\\start.zig:787:43: error: root source file struct 'main' has no member named 'main'\n" ++
        "C:\\Users\\me\\AppData\\zig-x86_64-windows-0.17.0\\lib\\std\\start.zig:576:17: note: called inline here\n";

    const out = try translateStderr(gpa, lang, table, &units, stderr, null, null);
    defer gpa.free(out);

    // 机器相关的绝对路径必须消失；英文内部说明也不得残留。
    try noSub(out, "C:\\");
    try noSub(out, "start.zig");
    try noSub(out, "zig-x86_64");
    try noSub(out, "AppData");
    try noSub(out, "called inline here");
    try noSub(out, "has no member");
    try noSub(out, "root source file");
    // 但错误的母语译文（命中 packs）必须保留；本例是「无 main 入口」来源，D50（第 106 轮）合并后
    // 命中的是 `成员不存在` 单条（旧「缺主入口」独立条目与成员访问场景交叉劫持、已删），
    // 其 tip 末句涵盖入口场景指引——译文主体与入口指引两句都必须在场。
    try hasSub(out, "所访问的成员不存在");
    try hasSub(out, "主函数");
}

test "报错列映射：CJK 字符串字面量在前时，zig 字节列正确回映为方言字符列" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const tr = @import("../transpiler/translate.zig");
    // 第 4 行：错误标识符 甲 之前有含 CJK 的字符串字面量（生成 .zig 中逐字节保留）。
    const src = "常数 标准库 = 导入(\"std\");\n" ++
        "公开 函数 主函数() !void {\n" ++
        "    变量 乙: 整数 = 0;\n" ++
        "    标准库.调试.打印(\"你好世界\", .{ 甲 });\n" ++
        "}\n";
    const res = try tr.translate(gpa, src, lang, &table);
    const units = [_]Unit{.{
        .native_path = "src/main.zz",
        .gen_path = "gen/main.zig",
        .gen_src = res.zig_str,
        .nat_src = src,
        .map = res.map,
    }};

    // zig 对生成行报的是字节列：`    std.debug.print("你好世界", .{ ` = 39 字节 -> 第 40 列。
    // 方言行中 甲 前有 25 个字符 -> 应回映为字符列 26（而非 zig 字节列 40、也非方言字节列 48）。
    const out = try renderDiag(gpa, lang, table, &units, "gen/main.zig", 4, 40, "error", "use of undeclared identifier 'z_2'", null);
    defer gpa.free(out);
    try hasSub(out, "src/main.zz:4:26");
    try noSub(out, "4:40"); // 不得把 zig 的字节列原样透出
    try noSub(out, "4:48"); // 也不得退化为方言字节列
}

test "去重 seen：跨两次 zig 调用（同位置同消息）仅输出一次，异位置不受影响" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const tr = @import("../transpiler/translate.zig");
    const src = "常数 标准库 = 导入(\"std\");\n" ++
        "公开 函数 主函数() !void {\n" ++
        "    变量 乙: 整数 = 0;\n" ++
        "    标准库.调试.打印(\"你好世界\", .{ 甲 });\n" ++
        "}\n";
    const res = try tr.translate(gpa, src, lang, &table);
    const units = [_]Unit{.{
        .native_path = "src/main.zz",
        .gen_path = "gen/main.zig",
        .gen_src = res.zig_str,
        .nat_src = src,
        .map = res.map,
    }};

    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();

    // 同一诊断：build-exe 以相对路径报，ast-check 以绝对路径报；两者回映到同一方言位置。
    const a = "gen/main.zig:4:40: error: use of undeclared identifier 'z_2'\n";
    const b = "D:\\proj\\.zzc\\gen\\main.zig:4:40: error: use of undeclared identifier 'z_2'\n";

    const out_a = try translateStderr(gpa, lang, table, &units, a, &seen, null);
    defer gpa.free(out_a);
    try hasSub(out_a, "src/main.zz:4:26"); // 首次正常渲染

    const out_b = try translateStderr(gpa, lang, table, &units, b, &seen, null);
    defer gpa.free(out_b);
    try std.testing.expect(out_b.len == 0); // 重复块被去重（空输出）

    // 不同位置的诊断不得被去重：仍应渲染。
    const c = "gen/main.zig:3:5: error: use of undeclared identifier 'z_9'\n";
    const out_c = try translateStderr(gpa, lang, table, &units, c, &seen, null);
    defer gpa.free(out_c);
    try std.testing.expect(out_c.len > 0);
}

test "裸 CLI 诊断回译：unrecognized parameter 不泄漏英文、保留非法参数名" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 无 `file:line:col` 前缀的裸 error 行不进 parseDiagLine，只经透传；应翻前缀与关键短语。
    const out = try translateStderr(gpa, lang, table, &.{}, "error: unrecognized parameter: --release=fast\n", null, null);
    defer gpa.free(out);
    try hasSub(out, "无法识别的参数");
    try hasSub(out, "--release=fast"); // 引发问题的参数名必须保留（静态模板反而会丢）
    try noSub(out, "error:");
    try noSub(out, "unrecognized");
    try noSub(out, "parameter");
}

test "定位解析错误命中 packs 模板，且波浪线装饰行无条件丢弃" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // zig 对 EOF 类错误会先输出空行再输出 `^`；若不无条件丢弃，空行会复位态致 `^` 泄漏。
    const stderr = "gen/main.zig:3:1: error: expected statement, found 'EOF'\n\n^\n";
    const out = try translateStderr(gpa, lang, table, &.{}, stderr, null, null);
    defer gpa.free(out);
    try hasSub(out, "缺少语句或代码块未闭合"); // 命中 packs 模板
    try noSub(out, "expected");
    try noSub(out, "found 'EOF'"); // 原始英文消息已替为模板（提示行里用反引号解释 EOF 仍可）
    try noSub(out, "^"); // 孤零的波浪线行被丢
}

test "报错回译：依赖循环整块本地化，不泄漏生成路径/生成源码/转码名" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // zig 的 dependency loop：顶行无前缀，其下是缩进的 note 帧（指向 .zzc/gen 生成文件）、
    // 生成源码回显（pub const … : i64）与转码名。应只留一条母语诊断，帧全部丢弃。
    const stderr =
        "error: dependency loop with length 2\n" ++
        "    .zzc/gen/src/a.zig:2:23: note: value of declaration 'a.z_1' uses value of declaration 'b.z_12' here\n" ++
        "    pub const z_1: i64 = b.z_12;\n" ++
        "                         ~^~~~~\n" ++
        "    .zzc/gen/src/b.zig:2:24: note: value of declaration 'b.z_12' uses value of declaration 'a.z_1' here\n" ++
        "    pub const z_12: i64 = a.z_1;\n" ++
        "                          ~^~~~\n" ++
        "    note: eliminate any one of these dependencies to break the loop\n";
    const out = try translateStderr(gpa, lang, table, &.{}, stderr, null, null);
    defer gpa.free(out);
    try hasSub(out, "循环依赖");
    try noSub(out, ".zzc");
    try noSub(out, "dependency loop");
    try noSub(out, "pub const");
    try noSub(out, "i64");
    try noSub(out, "value of declaration");
    try noSub(out, "eliminate");
    try noSub(out, "z_1");
}

test "诊断回译：unused function parameter 本地化（区别于 unused local variable）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // zig 对未用参数报 `unused function parameter`（与 `unused local variable` 不同句）；旧 packs 只收录了局部变量。
    const m = try renderDiag(gpa, lang, table, &.{}, "src/lib.zz", 1, 9, "error", "unused function parameter", null);
    defer gpa.free(m);
    try hasSub(m, "函数参数声明后未使用");
    try noSub(m, "unused");
    try noSub(m, "function parameter");
}

test "诊断回译：unreachable code 与其 diverted 说明行本地化" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const m = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 5, "error", "unreachable code", null);
    defer gpa.free(m);
    try hasSub(m, "不可达");
    try noSub(m, "unreachable");

    const n = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 5, "note", "control flow is diverted here", null);
    defer gpa.free(n);
    try hasSub(n, "控制流");
    try noSub(n, "control flow");
    try noSub(n, "diverted");
}

test "诊断回译：incompatible types 本地化（运算符两侧类型不兼容）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const m = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 15, "error", "incompatible types: '*const [6:0]u8' and 'comptime_int'", null);
    defer gpa.free(m);
    try hasSub(m, "运算符两侧的类型不兼容");
    try noSub(m, "incompatible types");
}

test "诊断回译：break/continue 出环、隐式返回、控制流触底、先前声明均本地化" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const b = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 5, "error", "break expression outside loop", null);
    defer gpa.free(b);
    try hasSub(b, "只能用在循环内部");
    try noSub(b, "outside loop");

    const c = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 5, "error", "continue expression outside loop", null);
    defer gpa.free(c);
    try noSub(c, "outside loop");
    try noSub(c, "implicitly");

    const r = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 14, "error", "function with non-void return type 'i64' implicitly returns", null);
    defer gpa.free(r);
    try hasSub(r, "没有返回值");
    try noSub(r, "implicitly returns");
    try noSub(r, "non-void return");

    const n = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 1, "note", "control flow reaches end of body here", null);
    defer gpa.free(n);
    try noSub(n, "reaches end of body");

    const pd = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 9, "note", "previous declaration here", null);
    defer gpa.free(pd);
    try hasSub(pd, "更早的同名声明");
    try noSub(pd, "previous declaration");
}

test "诊断回译：unused local constant 与 cannot load comptime-only / is runtime-known 本地化" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    const uc = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 11, "error", "unused local constant", null);
    defer gpa.free(uc);
    try hasSub(uc, "从未使用");
    try noSub(uc, "unused local constant");

    const cl = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 31, "error", "cannot load comptime-only type 'comptime_int'", null);
    defer gpa.free(cl);
    try hasSub(cl, "无法加载仅限编译期的类型");
    try noSub(cl, "cannot load comptime-only");

    const rk = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 30, "note", "pointer of type '*const comptime_int' is runtime-known", null);
    defer gpa.free(rk);
    try hasSub(rk, "运行时才可知");
    try noSub(rk, "runtime-known");
    try noSub(rk, "pointer of");
}

test "诊断回译：格式串类型不符保留操作数、入口返回类型不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 格式串与实参类型不符（localizeRunner 短语对）：保住格式符 'd' 与类型操作数，不留英文。
    const fs = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 5, 25, "error", "invalid format string 'd' for type 'i64'", null);
    defer gpa.free(fs);
    try hasSub(fs, "无效格式串 'd'");
    try hasSub(fs, "对类型 'i64'");
    try noSub(fs, "invalid format string");
    try noSub(fs, "for type");

    // 入口函数返回类型非法（packs 整句条目）：整句中文、允许的返回类型列于教学提示。
    const mr = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 1, "error", "expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'", null);
    defer gpa.free(mr);
    try hasSub(mr, "入口函数 主函数 的返回类型不受支持");
    try noSub(mr, "return type of main");
    try noSub(mr, "to be");
}

test "诊断回译：枚举匹配非穷尽的未处理取值说明行与格式串未闭合不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 枚举 `匹配` 非穷尽逐条列出的说明行（localizeRunner 短语对）：保住未处理的枚举成员名、不留英文。
    const ue = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 25, "note", "unhandled enumeration value: '关'", null);
    defer gpa.free(ue);
    try hasSub(ue, "未处理的枚举取值");
    try hasSub(ue, "'关'");
    try noSub(ue, "unhandled enumeration value");

    // 格式串未闭合（localizeRunner 短语对）：译出谓语、保住实际闭合字符 `}`。
    const mc = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 20, "error", "missing closing }", null);
    defer gpa.free(mc);
    try hasSub(mc, "缺少闭合的 }");
    try noSub(mc, "missing closing");
}

test "兜底：未命中 packs 的解析错误消息仍做短语本地化（期望/实得）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // “expected …, found …” 解析错族无法枚举，不命中 packs 时至少本地化脚手架词。
    const out = try renderDiag(gpa, lang, table, &.{}, "gen/x.zig", 1, 1, "error", "expected rparen, found 'x'", null);
    defer gpa.free(out);
    try hasSub(out, "期望");
    try hasSub(out, "实得");
    try noSub(out, "expected");
    try noSub(out, "found");
}

test "诊断回译：错误值被丢弃 / 容器声明注 / is invalid 不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // ① `_ = 一个 !T` → `error union is discarded`（旧为整句英文透传）。
    const a = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 5, 9, "error", "error union is discarded", null);
    defer gpa.free(a);
    try hasSub(a, "错误值");
    try noSub(a, "error union is discarded");

    // ② 容器声明错误的说明行 `to declare a container do 'const 点 = struct'`（旧为整句英文）。
    const b = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 1, 8, "note", "to declare a container do 'const 点 = struct'", null);
    defer gpa.free(b);
    try hasSub(b, "容器");
    try noSub(b, "to declare a container");

    // ③ 主错 `'struct 点' is invalid`：不命中 packs → 走 localizeRunner 兜底，保留操作数、仅译谓语。
    const c = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 1, 8, "error", "'struct 点' is invalid", null);
    defer gpa.free(c);
    try hasSub(c, "无效");
    try noSub(c, "is invalid");
}

test "诊断回译：可选类型描述 / 错误联合转换 / 函数不能返回错 / 枚举容器注 不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // ① `expected optional type, found 'i64'`（对非可选值用 `.?`）：描述词可选类型需译、'i64' 保留。
    const a = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 9, "error", "expected optional type, found 'i64'", null);
    defer gpa.free(a);
    try hasSub(a, "可选类型");
    try noSub(a, "optional type");
    try hasSub(a, "'i64'");

    // ② `cannot convert error union to payload type`（说明行）。
    const b = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 40, "note", "cannot convert error union to payload type", null);
    defer gpa.free(b);
    try hasSub(b, "错误联合");
    try noSub(b, "cannot convert error union");

    // ③ `function cannot return an error`（说明行）。
    const c = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 10, "note", "function cannot return an error", null);
    defer gpa.free(c);
    try hasSub(c, "不能返回错误");
    try noSub(c, "function cannot return an error");

    // ④ 枚举容器声明注：提示应同时提及枚举（而非只给结构例子）。
    const d = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 1, 6, "note", "to declare a container do 'const 颜色 = enum'", null);
    defer gpa.free(d);
    try hasSub(d, "枚举");
    try hasSub(d, "的形式"); // 防止译文里误用分隔符 `|` 导致消息被截断
    try noSub(d, "to declare a container");
}

test "renderDiag 用精确计数分配器时不泄漏 allocPrint 临时串（D27 坐实）" {
    // 历轮既有测均以 arena 包裹 gpa，arena 退出批量回收掩盖了 renderDiag 内
    // `appendSlice(gpa, try allocPrint(gpa, …))` 的逐次临时串泄漏（D23 同族反模式）。
    // 本测直接喂 std.testing.allocator（精确计数、测毕自动核查泄漏）：若 renderDiag 未
    // free 那些 allocPrint 临时串，即报 leaked——allocPrint 是干净 alloc，可确定性坐实（R10f 可注入族）。
    const gpa = std.testing.allocator;
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    const rendered = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 5, "error", "cannot assign to constant", null);
    defer gpa.free(rendered);
    try hasSub(rendered, "不可变常量被重新赋值");
}

/// 测试专用：把每次 `free` 前的内存填成哨兵字节 `0xDD` 再交回底层分配器。
/// 用于确定性坐实「某串在真正使用前就被释放、随后仍被读取」的悬垂读（use-after-free）：
/// 若释放发生在读取之前，其字节会全变 0xDD、出现在输出里即铁证。底层接 `std.testing.allocator`、
/// 保留其泄漏检测（本测只测悬垂读、不测泄漏，二者互补）。
/// 0.17 vtable 形制：alloc/resize/remap/free 分别经 rawAlloc/rawResize/rawRemap/rawFree 委托底层。
const PoisonAlloc = struct {
    backing: std.mem.Allocator,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoisonAlloc = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PoisonAlloc = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PoisonAlloc = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PoisonAlloc = @ptrCast(@alignCast(ctx));
        @memset(old_mem, 0xDD); // 释放前投毒
        self.backing.rawFree(old_mem, alignment, ra);
    }
    fn allocator(self: *PoisonAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
};

test "translateStderr 依赖循环分支：filterMessage 临时串不得在渲染前被释放（D28 坐实·悬垂读）" {
    // 依赖循环分支把 `shown = filtered`（filterMessage 的 owned 结果）却在**内层 if 块尾**就
    // `defer gpa.free(filtered)`——块一结束即释放，而 shown 在块外第 555 行才被 appendPrintF 读取
    // → 读已释放内存（UB）。孪生的 renderDiag 用 `var owned_filtered + 函数作用域 defer`（用后才
    // free）是正确形制，本分支系复制时把 defer 误写进了内层块。产品 gpa_=arena（逐块 free 为 no-op）
    // 故不现形、既有测清一色 arena 包裹亦不暴（与 D27 同一 arena 系统性盲区、惟此为 P1 悬垂读）。
    var p = PoisonAlloc{ .backing = std.testing.allocator };
    const gpa = p.allocator();

    // 最小包（无 [diagnostics]）→ matchDiag 不命中依赖循环消息 → shown 留英 → detectEnglish 真
    // → 非白名单 → filterMessage 被调用（分配 owned 临时串）。若用 zh_pack，`循环依赖` 条目会命中、
    // 译文为中文、detectEnglish 假、走不到 filterMessage，故必须用不含该诊断项的最小包才能达本分支。
    const min_pack =
        \\# 最小包（无诊断表）\n
        \\[keywords]\n
        \\常数 = const\n
    ;
    var lang = try Pack.parse(gpa, min_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    var f = try PureFilter.init(gpa, .{}, null);
    defer f.deinit();

    const res = try translateStderr(gpa, lang, table, &.{}, "error: dependency loop with length 3", null, &f);
    defer gpa.free(res);

    // 红→绿判据：修复前 filtered 在内层块尾提前释放、渲染时读到 0xDD 哨兵；修复后用后才释放、无哨兵。
    try std.testing.expect(std.mem.indexOfScalar(u8, res, 0xDD) == null);
    // 确证该分支真被执行（走了 filterMessage 兑底、含"原文"字样），非误接其他路径。
    try std.testing.expect(std.mem.indexOf(u8, res, "原文") != null);
}

/// 测试专用：计数分配器包装——每次 rawAlloc 计数后透传底层。
/// 用于运行期精确校准 `FailingAllocator.fail_index` 的注入槽位（免魔法数）；仅 alloc 计数，
/// resize/remap/free 透传不计数。
const CountAlloc = struct {
    backing: std.mem.Allocator,
    count: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountAlloc = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(old_mem, alignment, ra);
    }
    fn allocator(self: *CountAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
};

test "translateStderr seen 的 dupe→put：空表桶分配失败不得泄漏 dupe 键（D29 坐实·D26 同族·可确定性注入红）" {
    // 旧形 `try sm.put(try gpa.dupe(u8, key), {})`：dupe 成功后、空表首次 put 需新分配桶——
    // 若该分配失败，try 即返回、dupe 键串无人回收（D26 同族错误路径泄漏；生产 arena 掩盖）。
    // 与 dupe→append 的“批量预留容量”不同，put 的桶分配是干净 alloc、R10f 属可注入族——
    // 本测把注入槽位运行期校准、不用魔法数：同输入同 CountAlloc 双跑 translateStderr（首轮走到 put、
    // 次轮 get 命中短路），次轮额外分配数 c2 即“全新轮”截至 get 前的分配数；全新轮里 dupe 排在第 c2
    // 次 alloc（0 基）、桶分配紧随其后第 c2+1 次 → 杀后者。
    const back = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(back);
    defer arena.deinit();
    const setup = arena.allocator();
    var lang = try Pack.parse(setup, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(setup);
    defer table.deinit();
    // 不带尾换行：命中轮（get 短路）在 get 之后零分配（含尾部 '\n' 会使 out.append('\n') 混入计数、校准偏 1）。
    const stderr = "gen/main.zig:4:40: error: use of undeclared identifier";

    // 校准跑：两轮同用一个 CountAlloc（同一分配行为、确定性同序）。
    var ca = CountAlloc{ .backing = back };
    const cgpa = ca.allocator();
    var seen_c = std.StringHashMap(void).init(cgpa);
    defer {
        // dupe 键为 map 外拥有（deinit 不释键字节），须逐个回交——本测的卫生契约，同 main 端 arena 回收对等。
        var kit = seen_c.keyIterator();
        while (kit.next()) |k| cgpa.free(k.*);
        seen_c.deinit();
    }
    ca.count = 0;
    const o1 = try translateStderr(cgpa, lang, table, &.{}, stderr, &seen_c, null);
    const n1 = ca.count;
    defer cgpa.free(o1);
    try hasSub(o1, "错误"); // 首轮正常渲染（已走 dupe→put）
    ca.count = 0;
    const o2 = try translateStderr(cgpa, lang, table, &.{}, stderr, &seen_c, null);
    const c2 = ca.count;
    defer cgpa.free(o2);
    try std.testing.expect(o2.len == 0); // 去重短路成立 ✓（本轮分配全部发生在 get 之前）
    try std.testing.expect(n1 > c2); // 全新轮多出 dupe/桶/out 尾项，严格更多

    // 失败注入跑：杀桶分配（槽 c2+1，0 基）。
    var failing = std.testing.FailingAllocator.init(back, .{ .fail_index = c2 + 1 });
    const fgpa = failing.allocator();
    var seen_f = std.StringHashMap(void).init(fgpa); // put 失败→桶从未分配、map 不持资源、无需 deinit
    // 旧实现：dupe（槽 c2）成功、桶失败 → dupe 键泄漏（testing.allocator 测毕报红）；
    // 新实现（errdefer 回滚）：无泄漏。
    try std.testing.expectError(error.OutOfMemory, translateStderr(fgpa, lang, table, &.{}, stderr, &seen_f, null));
}

test "CRLF 源位置回映防回归：混坐标自洽闭合（第 74 轮勘察坐实、非缺陷）" {
    // 背景：translate 输出把 CRLF 归一为 LF，而 ColumnMap 登记的 nat_off 处于 CRLF 源坐标系——曾疑似
    // 「混坐标回映逐行累偏」（本轮开头的手推账）。探针实证推翻：CRLF 多余字节只分布在已扫过的行尾、
    // 必被 line_start 推进同数对销，列差不变；行归属同构。本测把该实证钉成防回归护栏：
    // 若未来有人在边界野归一/改 copyVerbatim 破坏此自洽，回映立即报错。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    const tr = @import("../transpiler/translate.zig");
    // LF 基线形与 CRLF 同形（同一程序、仅行尾不同）
    const src_lf = "常数 标准库 = 导入(\"std\");\n" ++
        "公开 函数 主函数() !void {\n" ++
        "    变量 乙: 整数 = 0;\n" ++
        "    标准库.调试.打印(\"你好世界\", .{ 甲 });\n" ++
        "}\n";
    const src_crlf = "常数 标准库 = 导入(\"std\");\r\n" ++
        "公开 函数 主函数() !void {\r\n" ++
        "    变量 乙: 整数 = 0;\r\n" ++
        "    标准库.调试.打印(\"你好世界\", .{ 甲 });\r\n" ++
        "}\r\n";

    // 两份同坐标系的 table 独立建（同程序同序、转码编号一致）
    var t1 = Mangle.init(gpa);
    const r1 = try tr.translate(gpa, src_lf, lang, &t1);
    const units1 = [_]Unit{.{ .native_path = "src/main.zz", .gen_path = "gen/main.zig", .gen_src = r1.zig_str, .nat_src = src_lf, .map = r1.map }};
    var t2 = Mangle.init(gpa);
    const r2 = try tr.translate(gpa, src_crlf, lang, &t2);
    // 生成端字节同（CRLF 已归一）：两端 gen_src 全等、zig 报位同一坐标
    try std.testing.expectEqualStrings(r1.zig_str, r2.zig_str);
    const units2 = [_]Unit{.{ .native_path = "src/main.zz", .gen_path = "gen/main.zig", .gen_src = r2.zig_str, .nat_src = src_crlf, .map = r2.map }};

    const o1 = try renderDiag(gpa, lang, t1, &units1, "gen/main.zig", 4, 40, "error", "use of undeclared identifier 'z_2'", null);
    defer gpa.free(o1);
    const o2 = try renderDiag(gpa, lang, t2, &units2, "gen/main.zig", 4, 40, "error", "use of undeclared identifier 'z_2'", null);
    defer gpa.free(o2);

    // 铁证：CRLF 源与 LF 源回映到完全相同的方言位置（与既有 LF 基线测同坐标 4:26）
    try hasSub(o1, "src/main.zz:4:26");
    try hasSub(o2, "src/main.zz:4:26");
    // 片段行同文（行尾 \r 不在行本体、不上屏）
    try hasSub(o2, "|     标准库.调试.打印(\"你好世界\", .{ 甲 });");
}

// 护栏（第 88 轮、第 74 轮证伪面续）：zig 正常坐标域之外的对抗形坐标（col=0 / 行号越界）
// 在生产链上不可达（zig 输出恒 1 基、run 路用户 stderr 不经本链），但回译链 pub 入口不对
// 未来调用方留缺口：旧形 nativeLoc `col - 1` 喂 0 即 panic: integer overflow（本轮探针对
// 原始码实锤 crashed），钳制修复后钉两形不崩且退化为与 splitLoc 缺列形一致的合法坐标。
test "护栏：对抗坐标 col=0/行越界回译不崩、退化形合法" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    const tr = @import("../transpiler/translate.zig");
    const src = "常数 甲 = 1;\n常数 乙 = 2;\n";
    const res = try tr.translate(gpa, src, lang, &table);
    const units = [_]Unit{.{ .native_path = "src/main.zz", .gen_path = "gen/main.zig", .gen_src = res.zig_str, .nat_src = src, .map = res.map }};

    // ① col=0：不崩，退化到行首 1:1（实测形）。
    const out0 = try renderDiag(gpa, lang, table, &units, "gen/main.zig", 1, 0, "error", "unused variable 'z_1'", null);
    defer gpa.free(out0);
    try hasSub(out0, "src/main.zz:1:1");

    // ② 行号越界（999 远超真行数）：不崩，尾夹取后报 EOF 退化行（2 行源 → 3:1，实测形）。
    const out999 = try renderDiag(gpa, lang, table, &units, "gen/main.zig", 999, 1, "error", "unused variable 'z_1'", null);
    defer gpa.free(out999);
    try hasSub(out999, "src/main.zz:3:1");
}

// D41（第 95 轮）：`成员名不存在`（pattern "no member named"）永远被排在它前面的
// `成员不存在`（pattern "has no member"）劫持——zig 成员错误恒形如 "has no member named"
// 同时含两子串，短 pattern 先命中导致更具体的 tip（.len/标量/切片）不可达。
// 修复=合并 tip 入保留条目、删死条目。红判据：修复前 tip 不含"切片"；修复后含。
test "诊断回译：标量/切片类型成员错误给完整提示（D41 子串共现遮蔽消缺）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    // 模拟 zig 对标量类型成员访问的报错——旧形只命中 `成员不存在`、tip 无切片/标量说明。
    const rendered = try renderDiag(
        gpa,
        lang,
        table,
        &.{},
        "src/main.zz",
        2,
        15,
        "error",
        "type 'u32' has no member named 'len'",
        &filter,
    );
    defer gpa.free(rendered);
    // 译文主体保持（合并后仍用原 `成员不存在` 的 message 措辞）：
    try hasSub(rendered, "所访问的成员不存在");
    // D41 关键断言：修复后 tip 须涵盖切片/标量指引：
    try hasSub(rendered, "切片");
    try hasSub(rendered, "标量");
    // 英文短语不得残留：
    try noSub(rendered, "has no member");
    try noSub(rendered, "no member named");
}

// D50（第 106 轮）：D41 同族「交叉共现遮蔽」的反向场景——用户误访 `.main` 成员时 zig 报
// `root source file struct 'math' has no member named 'main'`（探针实捕），该消息同时含
// `has no member`（成员不存在）与 `no member named 'main'`（缺主入口、排前）两 pattern 而互不包含，
// 表序前者永久劫持——用户收到「入口文件缺少 main」误导性 tip（自己的文件明明有 `主函数`）。
// 且缺真 main 时 zig 报形完全同构（探针二实捕 struct 'r106_probe4' 同款消息）、文本层不可分，
// 故修复=D41 先例形合并入单条目、tip 同时覆盖「成员访问笔误」+「入口缺 main」两场景指引。
// 红判据：旧形 message 为「作为可执行/测试入口的文件缺少 main」、不含「所访问的成员不存在」→红。
test "诊断回译：误访 .main 成员不得被缺主入口劫持成误导提示（D50 交叉共现遮蔽消缺）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    const rendered = try renderDiag(
        gpa,
        lang,
        table,
        &.{},
        "src/main.zz",
        5,
        14,
        "error",
        "root source file struct 'math' has no member named 'main'",
        &filter,
    );
    defer gpa.free(rendered);
    // 合并后须落在通用成员 message 上（旧形被「缺主入口」劫持、此处红）：
    try hasSub(rendered, "所访问的成员不存在");
    // 入口场景指引不得丢（合并 tip 须涵盖「build/run/test 入口缺 main」另一来源）：
    try hasSub(rendered, "主函数");
    // 英文短语不得残留：
    try noSub(rendered, "has no member");
    try noSub(rendered, "no member named");
}

// 真消息命中矩阵（D50 方法论，第 106 轮）：「全表子串包含序守卫」只能扫 A⊆B 对；
// 交叉共现（互不包含但真实消息同时含两者，如 D41/D50 两案）无法从 pattern 表自动检出
//（需真实消息域知识）。故以探针实捕真形为样本库落守卫：每条消息→断言命中条目归属与
// 场景指引在场。后续新增 diagnostics 条目时，先将其真形登本矩阵再提交（防交叉劫持回归）。
test "matchDiag 真消息命中矩阵（D50 方法论·探针实捕真形样本）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    const Sample = struct { msg: []const u8, message: []const u8, tip_must: []const u8 };
    const samples = [_]Sample{
        // 探针三（第 106 轮）：误访 std.math 的 .main 成员——D50 劫持案主场景。
        .{ .msg = "root source file struct 'math' has no member named 'main'", .message = "所访问的成员不存在", .tip_must = "主函数" },
        // 探针四（第 106 轮）：真缺入口的同构报形——合并 tip 的入口指引也须服务此场景。
        .{ .msg = "root source file struct 'mylib' has no member named 'main'", .message = "所访问的成员不存在", .tip_must = "主函数" },
        // D41（第 95 轮）真形：标量取 .len——成员 tip 须涵盖切片/标量指引。
        .{ .msg = "type 'u32' has no member named 'len'", .message = "所访问的成员不存在", .tip_must = "标量" },
        // 探针一（第 106 轮）真形：结构体字段不存在——独立条目未被成员系劫持。
        .{ .msg = "no field named 'main' in struct 'probe.main.T'", .message = "所访问的字段不存在", .tip_must = "字段" },
    };
    for (samples) |s| {
        const m = matchDiag(lang, s.msg);
        try std.testing.expect(m.matched);
        try std.testing.expectEqualStrings(s.message, m.message);
        try hasSub(m.tip, s.tip_must);
    }
}

// ---------------------------------------------------------------------------
// R11（第 164 轮）：真形快照矩阵数据 + 豁免表（文件级、供快照测与覆盖率测共用）。
// 承 D50「先登矩阵再提交」规约的机械化——把「每条 [diagnostics] 都须有真形样本命中并归属、
// 否则显式豁免」从人工纪律升为常驻测：新增/改包条目若未同步登记样本或豁免即红（防回译词条
// 静默不可达的译链回归面）。真形来源（不臆造）：本机真 zig 实跑（_probe/diag/raw_*.txt）、既有
// 回译测与 D50/D41 历史探针实录；基线行以「包内登记的匹配短语」为真形——该短语本身即从真 zig
// 报错逐字摘取的子串（见 中文.txt [diagnostics] 段头注）。归属判据用「身份」：matchDiag(真形) 命中
// 条目的 message/tip 须逐字等于「按该 pattern 在表里查得的条目」，被更靠前条目劫持则 message 立即
// 不等而红（表序不变量由下方全表子串包含序守卫兜住）；再以 msg_key/tip_key 短子串钉住关键译文与
// 教学指引不失踪。方言/工具链面不可造纯英文真形者入豁免表并附因——其升版措辞漂移由
// cli.parseZigVersion 版本检测告警作轻量早警替代，全量错形 e2e 回放登记为在册边界（见台账）。
// ---------------------------------------------------------------------------
const R11Snap = struct { eng: []const u8, pattern: []const u8, msg_key: []const u8, tip_key: []const u8 };
const r11_snaps = [_]R11Snap{
    // 表序前段 1–8。
    .{ .eng = "cannot assign to constant", .pattern = "cannot assign to constant", .msg_key = "重新赋值", .tip_key = "变量" },
    .{ .eng = "use of undeclared identifier", .pattern = "use of undeclared identifier", .msg_key = "未声明", .tip_key = "拼写" },
    .{ .eng = "expected type", .pattern = "expected type", .msg_key = "期望不符", .tip_key = "@as" },
    .{ .eng = "incompatible types", .pattern = "incompatible types", .msg_key = "不兼容", .tip_key = "不一致" },
    .{ .eng = "return of non-void function missing", .pattern = "return of non-void function missing", .msg_key = "返回语句", .tip_key = "路径" },
    .{ .eng = "unknown identifier", .pattern = "unknown identifier", .msg_key = "标识符", .tip_key = "关键字" },
    .{ .eng = "is not marked 'pub'", .pattern = "is not marked 'pub'", .msg_key = "未标记", .tip_key = "公开" },
    .{ .eng = "expected return type of main", .pattern = "expected return type of main", .msg_key = "返回类型", .tip_key = "可执行入口" },
    // 14–54（9–13 系工具链内部/越界不可造形者，见豁免表）。
    .{ .eng = "file imported", .pattern = "file imported", .msg_key = "导入语句", .tip_key = "核对" },
    .{ .eng = "no module named", .pattern = "no module named", .msg_key = "模块", .tip_key = ".zz" },
    .{ .eng = "dependency loop", .pattern = "dependency loop", .msg_key = "循环依赖", .tip_key = "环" },
    // 富真形（本机实跑/历史探针）：以完整报形钉归属、防交叉共现劫持复发。
    .{ .eng = "type 'u32' has no member named 'len'", .pattern = "has no member", .msg_key = "成员不存在", .tip_key = "标量" },
    .{ .eng = "no field named 'main' in struct 'probe.main.T'", .pattern = "no field named", .msg_key = "字段不存在", .tip_key = "字段" },
    .{ .eng = "no field or member function named", .pattern = "no field or member function named", .msg_key = "成员函数", .tip_key = "分配器" },
    .{ .eng = "invalid builtin function: '@importt'", .pattern = "invalid builtin function", .msg_key = "内建函数", .tip_key = "原名" },
    .{ .eng = "integer cast failed", .pattern = "integer cast failed", .msg_key = "表示范围", .tip_key = "@intCast" },
    .{ .eng = "index out of bounds", .pattern = "index out of bounds", .msg_key = "数组长度", .tip_key = "边界检查" },
    .{ .eng = "expected statement", .pattern = "expected statement", .msg_key = "未闭合", .tip_key = "花括号" },
    .{ .eng = "after statement", .pattern = "after statement", .msg_key = "结束符", .tip_key = "漏了" },
    .{ .eng = "expected ',' after argument", .pattern = "expected ',' after argument", .msg_key = "逗号", .tip_key = "补上逗号" },
    .{ .eng = "expression must be handled", .pattern = "expression must be handled", .msg_key = "没有被处理", .tip_key = "兜底" },
    .{ .eng = "dereference of null pointer", .pattern = "dereference of null pointer", .msg_key = "空可选值", .tip_key = "判空" },
    .{ .eng = "redeclaration of", .pattern = "redeclaration of", .msg_key = "重复声明", .tip_key = "唯一" },
    .{ .eng = "duplicate struct member name", .pattern = "duplicate struct member name", .msg_key = "文件结构", .tip_key = "重命名" },
    .{ .eng = "duplicate name here", .pattern = "duplicate name here", .msg_key = "名称重复", .tip_key = "冲突" },
    .{ .eng = "import loop", .pattern = "import loop", .msg_key = "导入环", .tip_key = "单向" },
    .{ .eng = "unused local variable", .pattern = "unused local variable", .msg_key = "未使用", .tip_key = "删除" },
    .{ .eng = "unused function parameter", .pattern = "unused function parameter", .msg_key = "未使用", .tip_key = "下划线" },
    .{ .eng = "unused local constant", .pattern = "unused local constant", .msg_key = "从未使用", .tip_key = "绑定" },
    .{ .eng = "unreachable code", .pattern = "unreachable code", .msg_key = "不可达", .tip_key = "分支" },
    .{ .eng = "control flow is diverted", .pattern = "control flow is diverted", .msg_key = "控制流", .tip_key = "不可达代码" },
    .{ .eng = "break expression outside loop", .pattern = "break expression outside loop", .msg_key = "循环内部", .tip_key = "循环体" },
    .{ .eng = "loop label", .pattern = "loop label", .msg_key = "循环标签", .tip_key = "标签" },
    .{ .eng = "block label", .pattern = "block label", .msg_key = "块标签", .tip_key = "标签" },
    .{ .eng = "continue expression outside loop", .pattern = "continue expression outside loop", .msg_key = "循环内部", .tip_key = "循环体" },
    .{ .eng = "implicitly returns", .pattern = "implicitly returns", .msg_key = "返回值", .tip_key = "非空返回类型" },
    .{ .eng = "reaches end of body", .pattern = "reaches end of body", .msg_key = "函数体", .tip_key = "控制流" },
    .{ .eng = "previous declaration", .pattern = "previous declaration", .msg_key = "同名声明", .tip_key = "冲突" },
    .{ .eng = "local variable is never mutated", .pattern = "local variable is never mutated", .msg_key = "从未被修改", .tip_key = "只读绑定" },
    .{ .eng = "consider using 'const'", .pattern = "consider using 'const'", .msg_key = "不可变常量", .tip_key = "从未重新赋值" },
    .{ .eng = "consider using 'try'", .pattern = "consider using 'try'", .msg_key = "错误或可选值", .tip_key = "尝试" },
    .{ .eng = "error union is discarded", .pattern = "error union is discarded", .msg_key = "被丢弃", .tip_key = "错误联合" },
    .{ .eng = "to declare a container", .pattern = "to declare a container", .msg_key = "容器", .tip_key = "容器类型" },
    .{ .eng = "cannot convert error union", .pattern = "cannot convert error union", .msg_key = "错误联合", .tip_key = "捕获" },
    .{ .eng = "function cannot return an error", .pattern = "function cannot return an error", .msg_key = "不能返回错误", .tip_key = "返回类型" },
    .{ .eng = "struct declared here", .pattern = "struct declared here", .msg_key = "结构在此处", .tip_key = "定位" },
    .{ .eng = "function declared here", .pattern = "function declared here", .msg_key = "函数在此处", .tip_key = "定位" },
    .{ .eng = "switch must handle", .pattern = "switch must handle", .msg_key = "匹配语句", .tip_key = "兜底" },
    .{ .eng = "division by zero", .pattern = "division by zero", .msg_key = "除数为零", .tip_key = "除数" },
    // 63/65/66（55–62、64 系不可独立造形/伴随行，见豁免表）。
    .{ .eng = "is redundant", .pattern = "is redundant", .msg_key = "冗余", .tip_key = "隐含" },
    .{ .eng = "consider omitting 'try'", .pattern = "consider omitting 'try'", .msg_key = "省略", .tip_key = "去掉" },
    .{ .eng = "declared here", .pattern = "declared here", .msg_key = "定义在此处", .tip_key = "定位" },
};

const R11Waiver = struct { pattern: []const u8, why: []const u8 };
const r11_waivers = [_]R11Waiver{
    .{ .pattern = "outside module path", .why = "导入越界：需把入口指向子目录令模块根上溯才触发、默认从工程根运行不产此英文串——方言面不可造纯英文真形" },
    .{ .pattern = "unable to load \"", .why = "导入文件加载失败：措辞含动态文件名、真形不稳定（高频子集由 check-demos 广谱语料 e2e 覆盖）" },
    .{ .pattern = "failed opening \"", .why = "嵌入资源加载失败：含动态路径、真形不稳定" },
    .{ .pattern = "embed of file outside package path", .why = "嵌入越界：zzc 已镜像 src 内资产、越界少触发，方言面难造稳定纯英文真形" },
    .{ .pattern = "@import operand", .why = "导入参数非字面量：需特定 AST 形、本机方言面不可造纯英文真形" },
    .{ .pattern = "non-matching for loop lengths", .why = "for 并列序列长度不符：措辞含动态数字、真形不稳定" },
    .{ .pattern = "unable to resolve comptime value", .why = "comptime 求值失败：多依赖具体表达式上下文、真形不稳" },
    .{ .pattern = "types must be comptime-known", .why = "类型须计期已知：工具链类型系统内部措辞、方言面少触发" },
    .{ .pattern = "cannot load comptime-only", .why = "加载仅限编译期类型：依赖特定 std 措辞" },
    .{ .pattern = "modify this variable", .why = "运行时改值需定宽类型：伴随主报错出现、不独立成行" },
    .{ .pattern = "is runtime-known", .why = "指针类型运行时可知：上一条伴随说明行、不独立出现" },
    .{ .pattern = "method invocation only supports", .why = "方法调用仅一重解引用：需指针的指针等特定形、本机方言面少触发" },
    .{ .pattern = "to dereference pointer", .why = "解引用提示：上一条的续行提示、不独立出现" },
    .{ .pattern = "cast discards const qualifier", .why = "丢弃常量限定：需特定 const 指针转换形、本机方言面少触发" },
};

test "matchDiag 真形快照矩阵（R11·全条归属钉，第 164 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    const items = lang.diagnostics.items;
    for (r11_snaps) |s| {
        // 表里须存在该 pattern 条目（防删条目后快照空转）。
        var found: ?Pack.Entry = null;
        for (items) |e| {
            if (std.mem.eql(u8, e.pattern, s.pattern)) {
                found = e;
                break;
            }
        }
        if (found == null) {
            std.debug.print("[R11 快照] 表内缺 pattern '{s}'（条目被删/拼写漂移？）\n", .{s.pattern});
            return error.TestUnexpectedResult;
        }
        const want = found.?;
        const m = matchDiag(lang, s.eng);
        try std.testing.expect(m.matched);
        // 身份钉：命中条目逐字即目标条目——被更靠前条目劫持/改表序使子串包含复发即此不等而红。
        try std.testing.expectEqualStrings(want.message, m.message);
        try std.testing.expectEqualStrings(want.tip, m.tip);
        // 关键译文/教学指引子串钉（内容失踪/被删即红）。
        try hasSub(m.message, s.msg_key);
        try hasSub(m.tip, s.tip_key);
    }
}

test "快照矩阵覆盖率守卫（R11·全条 pattern 须有样本或豁免，第 164 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    const items = lang.diagnostics.items;
    var covered: usize = 0;
    for (items) |e| {
        var hit = false;
        for (r11_snaps) |s| {
            if (std.mem.eql(u8, s.pattern, e.pattern)) {
                hit = true;
                break;
            }
        }
        if (!hit) for (r11_waivers) |w| {
            if (std.mem.eql(u8, w.pattern, e.pattern)) {
                hit = true;
                break;
            }
        };
        if (hit) covered += 1 else {
            std.debug.print("[R11 覆盖率缺口] pattern '{s}' 既无快照样本亦无豁免（新增条目须先登矩阵或豁免）\n", .{e.pattern});
            return error.TestUnexpectedResult;
        }
    }
    // 基数锚防静默空转（103 轮教训）：样本/豁免下限；且覆盖计数须恰等于全表条目数。
    try std.testing.expect(r11_snaps.len >= 45);
    try std.testing.expect(r11_waivers.len >= 10);
    try std.testing.expectEqual(items.len, covered);
    std.debug.print("[R11 覆盖率] 条目={d} 覆盖={d} 样本={d} 豁免={d}\n", .{ items.len, covered, r11_snaps.len, r11_waivers.len });
}

// 全表序守卫（D41 同族预防，承 92 轮 localizeRunner 方法论）：
// 若 pattern A 是 pattern B 的子串（A⊆B），则任何匹配 B 的消息也匹配 A；
// A 排在 B 前会劫持 B 的专属匹配——须保证「长（更具体）在前、短（更泛）在后」。
test "matchDiag 全表子串包含序守卫（D41 同族·表序不变量）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();

    // O(n²) 扫描：对每对 (i, j) i<j，若 diagnostics[j].pattern 是 diagnostics[i].pattern 的子串，
    // 则 j 的消息集 ⊆ i 的消息集（j 是更具体的、i 是更泛的），且 i 先被 matchDiag 遍历到、
    // 会劫持 j——违反「长 pattern 在前」不变量。期望零违规。
    const items = lang.diagnostics.items;
    for (items, 0..) |earlier, i| {
        for (items[i + 1 ..]) |later| {
            // later.pattern 包含 earlier.pattern → earlier 更泛且在前 → 劫持 later
            if (earlier.pattern.len > 0 and later.pattern.len > 0 and
                std.mem.indexOf(u8, later.pattern, earlier.pattern) != null)
            {
                std.debug.print("D41 序违规：idx {d} pattern '{s}' 是后项 '{s}' 的子串，泛条目劫持具体条目\n", .{ i, earlier.pattern, later.pattern });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// D51（第 107 轮）：D26/D29/D37/D49 泄漏族·OOM 错误路径形。不对称铁证：同文件四处 ArrayList 出生点
// unmangleText/renderDiag/translateStderr 皆有 errdefer out.deinit，唯独本函数没有——
// localizeRunner 循环内 try append/appendSlice 增长 OOM 返错，已累积的部分译文无人回收。
// 生产主链走 arena 掩盖（同 D27/D37/D49 先例）、历轮直测全 arena 包裹盲区未暴。
// 注入校准（承 D49 教训、零魔法数）：GPA 对同 size-class 增大走 extend_sent 原地扩展，
// resize_fail_index=1 形下整链仅 1 次 alloc（实测坐实）——杀末次即杀首 alloc、缓冲尚未
// 建立无从泄。改 resize_fail_index=0：所有原地 resize 一律失败，每次增长皆走
// alloc+copy+free 回退，alloc 数随串长增长；**双跑同用 FailingAllocator**（cal.alloc_index
// 直接计数）彻底消除跨工具分配序分歧；杀末次 alloc（fail_index=n-1）时 out 仍持上一缓冲 →
// 旧形必泄、leaked 栈指认。
test "D51（第 107 轮）localizeRunner 增长失败须回滚已累积译文（泄漏族·可确定性注入）" {
    const back = std.testing.allocator;
    const sample = "expected type 'u32', found pointer, expected statement, dependency loop detected";

    // 校准跑：同配置只数不杀，alloc 总数 n 即注入跑可杀槽位数。
    var cal = std.testing.FailingAllocator.init(back, .{ .resize_fail_index = 0 });
    const ok = try localizeRunner(cal.allocator(), sample);
    back.free(ok);
    const n = cal.alloc_index;
    try std.testing.expect(n >= 2); // 自锚：多次 alloc 存在，杀末次才有已累积缓冲可泄

    // 注入跑：杀最后一次 alloc（旧缓冲仍在手）——旧形 errdefer 缺席、已累积 out 泄；修复后回滚干净。
    var fa = std.testing.FailingAllocator.init(back, .{ .fail_index = n - 1, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, localizeRunner(fa.allocator(), sample));
}

// 纯函数边界形对抗护栏（第 108 轮，承 77/80/81/82 轮方法论）：translateStderr 的七个静态
// 切分/判定纯函数（parseFrame/splitLoc/onlyCarets/allDigits/endsWithSepNorm/pathsMatch/
// isInternalPath）此前仅经 e2e 栈帧测间接触达、零直调覆盖——逐例推演证伪无在线缺陷
//（区间恒闭合、溢出走 catch、两处 .? 有前置结构守卫），本测把推演结论钉成回归防线：
// 畸形输入不 panic 不越界（未来改动破边界即红）+ 已推演判定形不漂移（误改即红）。
test "护栏：stderr 回译静态纯函数边界形——畸形输入不崩、判定不漂移（第 108 轮证伪落位）" {
    // parseFrame：`path:line: 0xHEX in name (obj)` 取前缀；畸形全 null、不越界。
    try std.testing.expectEqualStrings("a.zig:3", parseFrame("a.zig:3: 0x7ff in foo (bar)").?);
    try std.testing.expectEqual(null, parseFrame("no frame here")); // 无 `: 0x`
    try std.testing.expectEqual(null, parseFrame("a: 0x in b")); // 0x 后无十六进制数字
    try std.testing.expectEqual(null, parseFrame("a:3: 0x7ff")); // 地址后缺 ` in `（尾部短串）
    try std.testing.expectEqual(null, parseFrame("a:3: 0x7ffin b")); // `in` 前缺空格
    // splitLoc：`file:L:C`/`file:L` 从右往左取数字段；盘符 Windows 路径不致错位。
    const two = splitLoc("C:\\u\\x.zz:12:34").?;
    try std.testing.expectEqualStrings("C:\\u\\x.zz", two.file);
    try std.testing.expectEqual(@as(usize, 12), two.line);
    try std.testing.expectEqual(@as(usize, 34), two.col);
    const one = splitLoc("src/lib.zz:7").?;
    try std.testing.expectEqual(@as(usize, 7), one.line);
    try std.testing.expectEqual(@as(usize, 1), one.col); // 缺列形退化列 1
    try std.testing.expectEqual(null, splitLoc("nofile")); // 无冒号
    try std.testing.expectEqual(null, splitLoc("a:")); // 尾空非数字
    try std.testing.expectEqual(null, splitLoc("a:x")); // 尾非数字
    try std.testing.expectEqual(null, splitLoc("a:99999999999999999999")); // 溢出走 catch 回 null、不 panic
    // allDigits：空串 false、含非数字 false、全数字 true。
    try std.testing.expect(!allDigits(""));
    try std.testing.expect(allDigits("1234"));
    try std.testing.expect(!allDigits("12a"));
    // onlyCarets：空串 false（装饰判定不得把空行认成波浪线）；纯 `^~` true；其余 false。
    try std.testing.expect(!onlyCarets(""));
    try std.testing.expect(onlyCarets("^^~~^"));
    try std.testing.expect(!onlyCarets("^ ^"));
    try std.testing.expect(!onlyCarets("^—")); // 多字节形按字节判、非 ^~ 即 false
    // endsWithSepNorm / pathsMatch：`\`≡`/`，前缀不算命中，`./` 归一。
    try std.testing.expect(endsWithSepNorm("x\\y\\src\\main.zig", "src/main.zig"));
    try std.testing.expect(!endsWithSepNorm("src/main.zig", "x\\y\\src\\main.zig")); // 长 needle 直 false
    try std.testing.expect(endsWithSepNorm("azig", "zig")); // 本函数仅字节后缀比较、无路径段语义（伪命中由调用方场景限定，
    // pathsMatch 双序包含性即此防御）；此处钉真实行为、写反即红——护栏测自身推演也须实跑自证。
    try std.testing.expect(pathsMatch("./src/main.zig", "src/main.zig"));
    try std.testing.expect(!pathsMatch("backup/src/main.zig", "x/src/main.zig"));
    // isInternalPath：盘符绝对/前导分隔符/.zig-cache/.zzc 内部形 true，方言相对路径 false。
    try std.testing.expect(isInternalPath("C:\\Users\\guilt\\zig\\lib\\std\\start.zig"));
    try std.testing.expect(isInternalPath("/usr/lib/zig/std.zig"));
    try std.testing.expect(isInternalPath("\\srv\\share\\x.zig"));
    try std.testing.expect(isInternalPath(".zig-cache/o/abc/x.o"));
    try std.testing.expect(isInternalPath(".zzc/gen/src/main.zig"));
    try std.testing.expect(!isInternalPath("src/main.zz"));
    try std.testing.expect(!isInternalPath("")); // 空路径不得误判内部（否则位置行被隐藏）
    try std.testing.expect(!isInternalPath("1a:bad")); // 首字符非字母的 `X:` 形不当盘符
}

// 机读单行化（第 154 轮 · 编辑器/CI 集成出口）：与真实渲染器对拍 + 形制表驱动 + 幂等不变量。
// 为何与渲染器对拍：machineLines 吃的就是 renderDiag 的字面输出；若只喂手抄串，渲染器形制一改
// （如 `  -->` 改成 `->`）本测仍绿而真输出已压不平——同 D34/D35「注与码自相矛盾」族的测面变体。
test "machineLines：真实渲染器输出→单行恰一行、无 `-->` 漏留、提示并入（第 154 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    var filter = try PureFilter.init(gpa, .{}, null);
    defer filter.deinit();

    const rendered = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 5, 5, "error", "cannot assign to constant", &filter);
    defer gpa.free(rendered);
    // 前置：渲染器确实产块形制（否则本测的对比面为空、机读出口无从反证）。
    try hasSub(rendered, "  --> src/main.zz:5:5");

    const flat = try machineLines(gpa, rendered);
    defer gpa.free(flat);
    try hasSub(flat, "src/main.zz:5:5: 错误: ");
    try hasSub(flat, "（提示："); // 提示行并入同一行
    try noSub(flat, "-->"); // 位量行不再单列
    try noSub(flat, "\u{1f4a1}"); // 图标不泄进机读面
    // 恰一行：除行尾换行外无第二个 `\n`。
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, flat, "\n"));
    try std.testing.expect(flat[flat.len - 1] == '\n');
}

test "machineLines：块/说明/已是单行/无位量块/孤立位量行/透传行表驱动逐字节形制（第 154 轮）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // 提示行以 `\u{1F4A1}` 转义形构造（源文件不落 astral 字符：码页写坏它就会静默弄坏
    // “该行被识别为提示行”这个判据本身）。
    const tip_body = "删除该变量，或以 `_ =` 显式丢弃。";
    const in_head =
        \\错误: 局部变量声明后未使用
        \\  --> src/main.zz:6:8
        \\  |     变量 未用: 字节 = 5;
    ;
    const in_tip = "  \u{1F4A1} " ++ tip_body ++ "\n";
    const in_rest =
        \\错误: 不可变常量被重新赋值
        \\  --> src/main.zz:5:5
        \\
        \\说明: 建议改用不可变常量
        \\src/main.zz:4:21: 词法: 全角分号，请改用半角 `;`
        \\  --> src/lib.zz:2:3
        \\程序输出的一行
        \\
    ;
    const in = in_head ++ "\n" ++ in_tip ++ in_rest;
    const want_head = "src/main.zz:6:8: 错误: 局部变量声明后未使用（提示：" ++ tip_body ++ "）\n";
    const want_rest =
        \\src/main.zz:5:5: 错误: 不可变常量被重新赋值
        \\
        \\说明: 建议改用不可变常量
        \\src/main.zz:4:21: 词法: 全角分号，请改用半角 `;`
        \\  --> src/lib.zz:2:3
        \\程序输出的一行
    ;
    const want = want_head ++ want_rest ++ "\n";
    const out1 = try machineLines(gpa, in);
    defer gpa.free(out1);
    try std.testing.expectEqualStrings(want, out1);
    // 幂等：已是单行的输出再压一次逐字节不变（消费方可多次过线、不致越压越坏）。
    const out2 = try machineLines(gpa, out1);
    defer gpa.free(out2);
    try std.testing.expectEqualStrings(want, out2);
    // 空输入与无诊断输入：输出空串/逐字节原样（不凭空造行）。
    const e = try machineLines(gpa, "");
    defer gpa.free(e);
    try std.testing.expectEqual(@as(usize, 0), e.len);
    const p = try machineLines(gpa, "第一行\r\n第二行\r\n");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("第一行\n第二行\n", p); // CRLF 归一 LF、不多出空行
    // 无位量顶行（位置落 zig 内部时渲染器本就省 `-->`）：原样一行、不造伪路量。
    const n = try machineLines(gpa, "内部错误: 编译器内部异常\n");
    defer gpa.free(n);
    try std.testing.expectEqualStrings("内部错误: 编译器内部异常\n", n);
    // kind 词表取自 kind_zh 值面（不新增硬编码）：未收录的英文 `error:` 顶行不当块头、逐字节透传。
    const k = try machineLines(gpa, "error: leaked english\n");
    defer gpa.free(k);
    try std.testing.expectEqualStrings("error: leaked english\n", k);
}

// 第 208 轮 D76：生成侧词面与 kind 词汇 hub 同源对账——本文件经 kdiag.lookupZh 取 en→zh。
// 除静态对账外，更跑真 `renderDiag`：渲英文种类名 → 机器行 kind 段必等于 hub 声明的 zh 词。
// 原缺口：生成侧本地 `kind_zh` 与消费侧各持手抄，P1 漂移生成值时全仓无测把实际渲染输出
// 回对 hub。本测把「renderDiag 实际输出的 kind 段」钉在 hub 真值上——若生成侧重立本地手抄
// 并与 hub 分道，本测即红（与 main 侧 208 T1 于 hub 中会，合成 en→渲染→severity 全链）。
test "第 208 轮 T2 生成侧 kind 词面 == hub 真值（静态 en→zh + 真 renderDiag 输出 kind 段逐字节）" {
    for (kdiag.entries) |e| {
        try std.testing.expectEqualStrings(e.zh, kdiag.lookupZh(e.en).?);
    }
    // 反向：hub 值面集合与 machineHead 判据所取 zh_values 等长（不漏词）。
    try std.testing.expectEqual(kdiag.entries.len, kdiag.zh_values.len);

    // 真渲染：逐条以英文 zig 种类名走 renderDiag，输出行首 kind 段必为 hub 声明的 zh 词。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();
    for (kdiag.entries) |e| {
        const rendered = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 6, 8, e.en, "probe", null);
        defer gpa.free(rendered);
        try std.testing.expect(rendered.len > e.zh.len + 2);
        try std.testing.expectEqualStrings(e.zh, rendered[0..e.zh.len]); // 行首 kind 段 == hub 值
        try std.testing.expectEqualStrings(": ", rendered[e.zh.len .. e.zh.len + 2]); // 紧跟 kind 分隔
    }
}

fn hasSub(hay: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, hay, needle) != null);
}
fn noSub(hay: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, hay, needle) == null);
}

// 第 174 轮：机读格式化（`--machine` 出口）私有助手 machineHead / flushMachine 零直调分支面。
// 二者仅经 machineLines（第 154 轮两测）端到端触及：machineHead 的前导空白/冒号在 0/冒号后非空格/冒号在末
// 四拒绝臂在 machineLines 流中被 `--> `/`| `/tip 的 startsWith 前置分支截获或从未构造→零直钉；接受臂的
// msg 切片恰从 colon+2 起（吞冒号后空格）未字节钉；flushMachine 的「无位量却带 tip 丢 tip」臂 machineLines 表测从未构造。
// 经探针坐实全部为正确防御行为、无在线缺陷（真 --machine 消费方 problemMatcher/LSP/CI 只收合规行）→证伪撤号不占号。
test "lsp.diag 机读格式化：machineHead 头判据拒绝/接受臂 + flushMachine 四格式臂（含无位量丢 tip）零直调分支真形（第 174 轮）" {
    const testing = std.testing;
    var asserts: usize = 0;
    const err_kind = "\u{9519}\u{8bef}"; // 错误
    const note_kind = "\u{8bf4}\u{660e}"; // 说明

    // A. machineHead 六拒绝臂（皆 null）——决定一行不被当诊断块头、走透传。
    try testing.expect(machineHead("") == null); // 空行 L196
    asserts += 1;
    try testing.expect(machineHead(" " ++ err_kind ++ ": x") == null); // 前导空格 L197
    asserts += 1;
    try testing.expect(machineHead("\t" ++ err_kind ++ ": x") == null); // 前导 tab L197
    asserts += 1;
    try testing.expect(machineHead("foo bar") == null); // 无冒号 L198
    asserts += 1;
    try testing.expect(machineHead(": foo") == null); // 冒号在 0 L199
    asserts += 1;
    try testing.expect(machineHead(err_kind ++ ":x") == null); // 冒号后非空格 L200（锁「种类: 消息」须有空格分隔）
    asserts += 1;
    try testing.expect(machineHead(err_kind ++ ":") == null); // 冒号在末尾 len<colon+2 L200
    asserts += 1;
    // kind 在但不在 kind_zh 值面（防任意「文本: 内容」行误判为诊断头）：ASCII 与 CJK 两形。
    try testing.expect(machineHead("error: x") == null); // L205（"error" 是 key 非 value）
    asserts += 1;
    try testing.expect(machineHead("\u{968f}\u{673a}: x") == null); // 「随机: x」非五 kind 之一 L205
    asserts += 1;

    // B. machineHead 接受臂（kind ∈ kind_zh 值面）：返回 .{kind,msg} 且 msg 恰从 colon+2 起（吞冒号后空格）。
    if (machineHead(err_kind ++ ": msg")) |h| {
        try testing.expectEqualStrings(err_kind, h.kind);
        asserts += 1;
        try testing.expectEqualStrings("msg", h.msg); // 无领前空格
        asserts += 1;
    } else return error.TestUnexpectedResult;
    if (machineHead(note_kind ++ ": headsup")) |h| {
        try testing.expectEqualStrings(note_kind, h.kind);
        asserts += 1;
        try testing.expectEqualStrings("headsup", h.msg);
        asserts += 1;
    } else return error.TestUnexpectedResult;
    if (machineHead(err_kind ++ ": ")) |h| { // 空消息体仍认头
        try testing.expectEqualStrings(err_kind, h.kind);
        asserts += 1;
        try testing.expectEqualStrings("", h.msg);
        asserts += 1;
    } else return error.TestUnexpectedResult;

    // C. flushMachine 四格式臂（loc×tip）字节形钉 + null pending 零输出。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const L = FrameLoc{ .file = "a.zz", .line = 5, .col = 7 };
    // 有位量 + 有提示 → `路:行:列: 种类: 消息（提示：…）`
    {
        var out: std.ArrayList(u8) = .empty;
        try flushMachine(gpa, &out, .{ .kind = err_kind, .msg = "m", .loc = L, .tip = "t" });
        try testing.expectEqualStrings("a.zz:5:7: " ++ err_kind ++ ": m\u{FF08}\u{63D0}\u{793A}\u{FF1A}t\u{FF09}\n", out.items);
        asserts += 1;
    }
    // 有位量无提示 → `路:行:列: 种类: 消息`（无括号尾）
    {
        var out: std.ArrayList(u8) = .empty;
        try flushMachine(gpa, &out, .{ .kind = err_kind, .msg = "m", .loc = L, .tip = null });
        try testing.expectEqualStrings("a.zz:5:7: " ++ err_kind ++ ": m\n", out.items);
        asserts += 1;
    }
    // 无位量无提示 → 原样 `{种类}: {消息}`
    const no_loc_no_tip = blk: {
        var out: std.ArrayList(u8) = .empty;
        try flushMachine(gpa, &out, .{ .kind = err_kind, .msg = "m", .loc = null, .tip = null });
        break :blk try dupStr(gpa, out.items);
    };
    defer gpa.free(no_loc_no_tip);
    try testing.expectEqualStrings(err_kind ++ ": m\n", no_loc_no_tip);
    asserts += 1;
    // 无位量却带 tip → tip 被丢（else 臂不含提示），与上臂逐字节相同——坐实真形、经 machineLines 不可达的防御态。
    {
        var out: std.ArrayList(u8) = .empty;
        try flushMachine(gpa, &out, .{ .kind = err_kind, .msg = "m", .loc = null, .tip = "t" });
        try testing.expectEqualStrings(no_loc_no_tip, out.items);
        asserts += 1;
    }
    // null pending 零输出。
    {
        var out: std.ArrayList(u8) = .empty;
        try flushMachine(gpa, &out, null);
        try testing.expectEqual(@as(usize, 0), out.items.len);
        asserts += 1;
    }
    std.debug.print("T174 asserts={d}\n", .{asserts});
}

fn dupStr(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    return gpa.dupe(u8, s);
}

// 第 200 轮 T1（D68 · `.zzc` 族 ↔ 隐藏判据 的跨模块耦合锚）。
// 上一条测（L2856 区）直钉的是判据自身的四臂形为；本测钉的是**两条跨模块面无测**——t2 探针实锤
// （`.scratch200/probe200.sh`）：P1 把写侧族名整体改掉而判据不动 → 502/502 全绿（耦合零钉）；
// P3 把判据收窄为只认生成树 `.zzc/gen`（符号表/产物目录/包目录/临时发射物就此不再隐藏）→ 502/502 全绿
// （成员命中面零钉）。二者都是「族改名或收窄即把内部路径直泄给方言用户」的活路径（台账 B1 同族泄漏面）。
// A1 走 199 轮 D67 的推论二形制：写侧产物与隐藏判据是配对契约，经函数组合（真实 `genPathFor` 的输出喂
// `isInternalPath`）转为行为锚——任一侧脱离 `zzc_paths` 真值即断；纯「两点引用同一常量」不可锚，故不写。
test "第 200 轮 T1 隐藏判据与 .zzc 族同源：写侧产物→组合锚 + 全员命中 + 负例（D68）" {
    const cli = @import("../cli/args.zig"); // 只在测体内 import：生产侧判据不得依赖 cli，跨模块耦合仅在测面闭合
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // A1 组合锚：写侧真实产出的生成路径（顶层与子目录两形）必须被隐藏判据认内部。
    //    独立字面量侧同钉（判据不复用常量，遵 196/197 通则），故 hub 真值一改即此处红——逼两侧同步复跑。
    const top = try cli.genPathFor(gpa, "main.zz");
    try std.testing.expectEqualStrings(".zzc/gen/main.zig", top);
    try std.testing.expect(isInternalPath(top));
    const sub = try cli.genPathFor(gpa, "sub/mod.zz");
    try std.testing.expectEqualStrings(".zzc/gen/sub/mod.zig", sub);
    try std.testing.expect(isInternalPath(sub));
    try std.testing.expect(isInternalPath(".zzc/gen/main.zig")); // 字面量侧：写侧脱靶亦红

    // A2 全员命中锚：族其余成员（符号表/产物目录/包目录/临时发射物）及其下真实产物路径都须被隐藏。
    //    P3 的收窄形（只认生成树）在此红——把判据改回任何单成员字面量都过不了这一串。
    try std.testing.expect(isInternalPath(zzc.symbols_file));
    try std.testing.expect(isInternalPath(zzc.bin_dir));
    try std.testing.expect(isInternalPath(zzc.bin_dir ++ "/root"));
    try std.testing.expect(isInternalPath(zzc.lang_dir));
    try std.testing.expect(isInternalPath(zzc.lang_dir ++ "/中文.txt"));
    try std.testing.expect(isInternalPath(zzc.check_root));
    try std.testing.expect(isInternalPath(zzc.check_root ++ ".exe"));

    // A3 负例锚：方言相对路径与裸名 `zzc/`（无前导点，用户自建的目录）都不得被隐藏——
    //    判据若被放宽成「含 zzc 即隐藏」，会把用户自己的路径位置行一起吞掉（同 L2864 空路径那枚的反向防御）。
    try std.testing.expect(!isInternalPath("src/main.zz"));
    try std.testing.expect(!isInternalPath("zzc/gen/main.zig"));
    // A4 粗粒度真形（坐实真行为、非期望）：判据是子串匹配，故 `.zzcfoo` 这类同前缀名也被隐藏——
    //    隐藏多一个不存在的路径无害、漏隐藏才泄密，此处钉住「宁宽勿严」的设计取向；判据改段边界匹配即本钉红。
    try std.testing.expect(isInternalPath(".zzcfoo/x.zig"));
}
