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
const PureFilter = @import("pure_filter.zig");

/// 一个已翻译的编译单元：方言文件 <-> 生成文件 的对照。
pub const Unit = struct {
    native_path: []const u8, // 如 src/main.zz
    gen_path: []const u8, // 如 .zzc/gen/src/main.zig（报错里出现的形态）
    gen_src: []const u8, // 生成的标准 Zig 源码（用于把 zig 行列表述回字节偏移）
    nat_src: []const u8, // 方言源码
    map: ColumnMap,
};

const kind_zh = std.StaticStringMap([]const u8).initComptime(.{
    .{ "error", "错误" },
    .{ "warning", "警告" },
    .{ "note", "说明" },
    .{ "referenced by", "被引用于" },
    .{ "unknown", "内部错误" },
});

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
    const kind_cn = kind_zh.get(kind) orelse kind;
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
        if (f.detectEnglish(msg_disp)) {
            if (!f.whitelist.check(msg_disp)) {
                owned_filtered = try f.filterMessage(gpa, msg_disp, file_path);
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
        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "{s}: {s}\n  --> {s}:{d}:{d}\n", .{
            kind_cn, filtered_msg, loc_native, native_line, native_col,
        }));
        if (snippet.len != 0) {
            try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "  | {s}\n", .{snippet}));
        }
    } else {
        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "{s}: {s}\n", .{ kind_cn, filtered_msg }));
    }
    if (m.tip.len != 0) {
        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "  💡 {s}\n", .{m.tip}));
    }
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
        const std_off = goff + (col - 1); // zig 报的是**字节列**（1 基），故 col-1 恒等于行内字节增量
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

/// 测试运行器专有英文短语、以及无位置的 CLI 级裸诊断前缀的母语替换（仅涉及已知串，
/// 不影响其他输出）。裸诊断（如 `error: unrecognized parameter: --release=fast`）不带
/// `file:line:col` 前缀，不进 `parseDiagLine`、只经此透传；按短语替换可保留引发问题的
/// 具体参数名（静态模板反而会丢它），对用户更有用。
fn localizeRunner(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    const pairs = [_][2][]const u8{
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
        .{ "error: ", "错误: " },
        .{ "warning: ", "警告: " },
        .{ "note: ", "说明: " },
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
    var out: std.ArrayList(u8) = .empty;
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
fn isInternalPath(p: []const u8) bool {
    if (p.len >= 2 and p[1] == ':' and std.ascii.isAlphabetic(p[0])) return true; // 盘符
    if (p.len > 0 and (p[0] == '/' or p[0] == '\\')) return true; // Unix/UNC 绝对
    if (std.mem.indexOf(u8, p, ".zig-cache") != null) return true; // 缓存目录
    if (std.mem.indexOf(u8, p, ".zzc") != null) return true; // 我方生成目录（未映射回方言的产物）
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
                    try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "  --> {s}:{d}:{d}\n", .{ L.path, L.line, L.col }));
                    if (L.snippet.len != 0) {
                        try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "  | {s}\n", .{L.snippet}));
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
            // 纯母语过滤器：对依赖循环错误消息进行最终检查
            if (filter) |f| {
                if (f.detectEnglish(shown)) {
                    if (!f.whitelist.check(shown)) {
                        const filtered = try f.filterMessage(gpa, shown, "dependency loop");
                        defer gpa.free(filtered);
                        shown = filtered;
                    }
                }
            }
            const kind_cn = kind_zh.get("error") orelse "error";
            try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "{s}: {s}\n", .{ kind_cn, shown }));
            if (m.tip.len != 0) {
                try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "  \u{1f4a1} {s}\n", .{m.tip}));
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
                try sm.put(try gpa.dupe(u8, key), {});
            }
            try out.appendSlice(gpa, rendered);
            drop_display = true;
        } else {
            const native = try unmangleText(gpa, raw, table);
            defer gpa.free(native);
            const localized = try localizeRunner(gpa, native);
            defer gpa.free(localized);
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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

test "诊断回译：未使用循环标签/语句结束符缺失/'an identifier' 描述符不泄漏英文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    // F 枚举声明位置：靠末尾 `declared here` 通用兜底命中（struct/function 更具体者优先）。
    const enumnote = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 9, "note", "enum declared here", &filter);
    defer gpa.free(enumnote);
    try hasSub(enumnote, "相关定义在此处声明");
    try noSub(enumnote, "declared here");
    try noSub(enumnote, "enum");

    // J 对可选值做字段访问（短语保留类型具体信息）：
    const opt = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 13, "error", "type '?i64' does not support field access");
    defer gpa.free(opt);
    try hasSub(opt, "不支持");
    try hasSub(opt, "字段访问");
    try hasSub(opt, "'?i64'");
    try noSub(opt, "does not support");
    try noSub(opt, "field access");

    // K 误用尝试：主体消息保留实得类型名、说明行走 packs 模板。
    const trymax = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 19, "error", "expected error union type, found 'comptime_int'");
    defer gpa.free(trymax);
    try hasSub(trymax, "错误联合类型");
    try noSub(trymax, "error union type");
    try noSub(trymax, "expected");
    const trynote = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 19, "note", "consider omitting 'try'");
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    // U 对 const 数组取地址赋给可变切片时的伴随说明行：
    const cq = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 19, "note", "cast discards const qualifier", &filter);
    defer gpa.free(cq);
    try hasSub(cq, "丢弃");
    try hasSub(cq, "常数");
    try noSub(cq, "cast discards");
    try noSub(cq, "const qualifier");
}

test "诊断回译：入口文件缺 main 给专门提示而非误导的拼写检查" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var lang = try Pack.parse(gpa, zh_pack);
    defer lang.deinit();
    var table = Mangle.init(gpa);
    defer table.deinit();

    // 初始化纯母语过滤器
    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    // build/run/test 指向无 main 的库模块时 zig 报此错；更具体的 `缺主入口`（no member named 'main'）
    // 必须排在通用 `成员不存在`（has no member）之前，否则回落成误导的“查拼写”。
    const m = try renderDiag(gpa, lang, table, &.{}, "src/lib.zz", 1, 1, "error", "root source file struct 'lib' has no member named 'main'", &filter);
    defer gpa.free(m);
    try hasSub(m, "缺少");
    try hasSub(m, "入口");
    try noSub(m, "所访问的成员不存在");
    try noSub(m, "拼写检查");
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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
    var filter = try PureFilter.init(gpa, .{});
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

test "纯母语过滤器：英文残留被拦截" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var filter = try PureFilter.init(gpa, .{});
    defer filter.deinit();

    // 测试英文检测
    try std.testing.expect(filter.detectEnglish("expected type, found 'i64'"));
    try std.testing.expect(!filter.detectEnglish("错误: 类型不匹配"));

    // 测试白名单
    try std.testing.expect(filter.whitelist.check("MyType"));
    try std.testing.expect(filter.whitelist.check("my_variable"));
    try std.testing.expect(filter.whitelist.check("@import"));

    // 测试过滤
    const result = try filter.filterMessage(gpa, "expected type, found 'i64'", "src/main.zz:5:10");
    defer gpa.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[未翻译]"));
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

    const out = try translateStderr(gpa, lang, table, &units, stderr, null);
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

    const out = try translateStderr(gpa, lang, table, &units, stderr, null);
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

    const out = try translateStderr(gpa, lang, table, &units, stderr, null);
    defer gpa.free(out);

    // 机器相关的绝对路径必须消失；英文内部说明也不得残留。
    try noSub(out, "C:\\");
    try noSub(out, "start.zig");
    try noSub(out, "zig-x86_64");
    try noSub(out, "AppData");
    try noSub(out, "called inline here");
    try noSub(out, "has no member");
    try noSub(out, "root source file");
    // 但错误的母语译文（命中 packs）必须保留；本例是“无 main 入口”，应命中更具体的 `缺主入口`
    //而非回落成误导的“成员不存在/查拼写”。
    try hasSub(out, "作为可执行/测试入口的文件缺少");
    try noSub(out, "拼写检查");
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
        "    标准库.打印(\"你好世界\", .{ 甲 });\n" ++
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
    // 方言行中 甲 前有 22 个字符 -> 应回映为字符列 23（而非 zig 字节列 40、也非方言字节列 41）。
    const out = try renderDiag(gpa, lang, table, &units, "gen/main.zig", 4, 40, "error", "use of undeclared identifier 'z_2'");
    defer gpa.free(out);
    try hasSub(out, "src/main.zz:4:23");
    try noSub(out, "4:40"); // 不得把 zig 的字节列原样透出
    try noSub(out, "4:41"); // 也不得退化为方言字节列
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
        "    标准库.打印(\"你好世界\", .{ 甲 });\n" ++
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

    const out_a = try translateStderr(gpa, lang, table, &units, a, &seen);
    defer gpa.free(out_a);
    try hasSub(out_a, "src/main.zz:4:23"); // 首次正常渲染

    const out_b = try translateStderr(gpa, lang, table, &units, b, &seen);
    defer gpa.free(out_b);
    try std.testing.expect(out_b.len == 0); // 重复块被去重（空输出）

    // 不同位置的诊断不得被去重：仍应渲染。
    const c = "gen/main.zig:3:5: error: use of undeclared identifier 'z_9'\n";
    const out_c = try translateStderr(gpa, lang, table, &units, c, &seen);
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
    const out = try translateStderr(gpa, lang, table, &.{}, "error: unrecognized parameter: --release=fast\n", null);
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
    const out = try translateStderr(gpa, lang, table, &.{}, stderr, null);
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
    const out = try translateStderr(gpa, lang, table, &.{}, stderr, null);
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
    const m = try renderDiag(gpa, lang, table, &.{}, "src/lib.zz", 1, 9, "error", "unused function parameter");
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

    const m = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 5, "error", "unreachable code");
    defer gpa.free(m);
    try hasSub(m, "不可达");
    try noSub(m, "unreachable");

    const n = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 5, "note", "control flow is diverted here");
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

    const m = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 15, "error", "incompatible types: '*const [6:0]u8' and 'comptime_int'");
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

    const b = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 5, "error", "break expression outside loop");
    defer gpa.free(b);
    try hasSub(b, "只能用在循环内部");
    try noSub(b, "outside loop");

    const c = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 5, "error", "continue expression outside loop");
    defer gpa.free(c);
    try noSub(c, "outside loop");
    try noSub(c, "implicitly");

    const r = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 14, "error", "function with non-void return type 'i64' implicitly returns");
    defer gpa.free(r);
    try hasSub(r, "没有返回值");
    try noSub(r, "implicitly returns");
    try noSub(r, "non-void return");

    const n = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 1, "note", "control flow reaches end of body here");
    defer gpa.free(n);
    try noSub(n, "reaches end of body");

    const pd = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 9, "note", "previous declaration here");
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

    const uc = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 11, "error", "unused local constant");
    defer gpa.free(uc);
    try hasSub(uc, "从未使用");
    try noSub(uc, "unused local constant");

    const cl = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 31, "error", "cannot load comptime-only type 'comptime_int'");
    defer gpa.free(cl);
    try hasSub(cl, "无法加载仅限编译期的类型");
    try noSub(cl, "cannot load comptime-only");

    const rk = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 4, 30, "note", "pointer of type '*const comptime_int' is runtime-known");
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
    const fs = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 5, 25, "error", "invalid format string 'd' for type 'i64'");
    defer gpa.free(fs);
    try hasSub(fs, "无效格式串 'd'");
    try hasSub(fs, "对类型 'i64'");
    try noSub(fs, "invalid format string");
    try noSub(fs, "for type");

    // 入口函数返回类型非法（packs 整句条目）：整句中文、允许的返回类型列于教学提示。
    const mr = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 1, "error", "expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'");
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
    const ue = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 25, "note", "unhandled enumeration value: '关'");
    defer gpa.free(ue);
    try hasSub(ue, "未处理的枚举取值");
    try hasSub(ue, "'关'");
    try noSub(ue, "unhandled enumeration value");

    // 格式串未闭合（localizeRunner 短语对）：译出谓语、保住实际闭合字符 `}`。
    const mc = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 20, "error", "missing closing }");
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
    const out = try renderDiag(gpa, lang, table, &.{}, "gen/x.zig", 1, 1, "error", "expected rparen, found 'x'");
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
    const a = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 5, 9, "error", "error union is discarded");
    defer gpa.free(a);
    try hasSub(a, "错误值");
    try noSub(a, "error union is discarded");

    // ② 容器声明错误的说明行 `to declare a container do 'const 点 = struct'`（旧为整句英文）。
    const b = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 1, 8, "note", "to declare a container do 'const 点 = struct'");
    defer gpa.free(b);
    try hasSub(b, "容器");
    try noSub(b, "to declare a container");

    // ③ 主错 `'struct 点' is invalid`：不命中 packs → 走 localizeRunner 兜底，保留操作数、仅译谓语。
    const c = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 1, 8, "error", "'struct 点' is invalid");
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
    const a = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 3, 9, "error", "expected optional type, found 'i64'");
    defer gpa.free(a);
    try hasSub(a, "可选类型");
    try noSub(a, "optional type");
    try hasSub(a, "'i64'");

    // ② `cannot convert error union to payload type`（说明行）。
    const b = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 40, "note", "cannot convert error union to payload type");
    defer gpa.free(b);
    try hasSub(b, "错误联合");
    try noSub(b, "cannot convert error union");

    // ③ `function cannot return an error`（说明行）。
    const c = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 2, 10, "note", "function cannot return an error");
    defer gpa.free(c);
    try hasSub(c, "不能返回错误");
    try noSub(c, "function cannot return an error");

    // ④ 枚举容器声明注：提示应同时提及枚举（而非只给结构例子）。
    const d = try renderDiag(gpa, lang, table, &.{}, "src/main.zz", 1, 6, "note", "to declare a container do 'const 颜色 = enum'");
    defer gpa.free(d);
    try hasSub(d, "枚举");
    try hasSub(d, "的形式"); // 防止译文里误用分隔符 `|` 导致消息被截断
    try noSub(d, "to declare a container");
}

fn hasSub(hay: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, hay, needle) != null);
}
fn noSub(hay: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, hay, needle) == null);
}
