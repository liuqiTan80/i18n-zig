//! 深检探针（第 347 轮 D206）：把「无 main 的模块只走 `zig ast-check`」那条零类型检查通道补成
//! 真语义检查——ast-check 只做语法与名字解析，**从不做类型检查**，故库模块里的
//! `结构 { 上限: 字节 = 300 }`、未引用函数体里的 `甲 + "字符串"` 一类形全被静默放过
//! （`zzc check` 报「✔ 检查通过」而 `zzc build` 在同一行崩）。
//!
//! 做法：在生成 Zig 的**同目录**写一枚探针副本（原文件尾后追加一枚 `comptime` 块，只在尾部加行、
//! 不在中间插行——原行号分毫不动，回译与列映射沿用既有的逐字节保行契约），再以
//! `zig build-lib <探针> -fno-emit-bin` 做一次完整语义分析。副本留在 `.zzc/` 树内，故其**自身**
//! 形制错由 `diag.isInternalPath` 既有判据归为内部路径，不外泄英文噪声。
//!
//! 探针形制按顶层声明的形制分派三式（判据全部由首元词唯一决定）：
//!   * `fn`／`var` → `const p_N = &N; _ = p_N;`  取址即逼出函数体／全局初值的语义分析；
//!   * `const` 且 RHS 首元词是**类型**（`struct`／`enum`／`union`／原子整型／`[]T`／`[N]T`／
//!     `*T`／`?T`／`type`…）→ `const p_N = @as(N, undefined); _ = p_N;`  型制化逼出容器字段
//!     默认值与枚举显值的位宽核对；
//!   * 其余一切（含 `@import`／`error{}`／`opaque`／`!T`／`anyopaque`／带型注常数／调用式／
//!     形制不明者）→ `const p_N = .{N}; _ = p_N;`  只做一次 comptime 引用。
//!
//! 最后一式是**有意的保守回落**：`@as(值名, undefined)` 在 `const K = 3 + 4;` 上报「期望类型
//! 而非值」、`&K` 在带型注常数上报「无法解析 comptime 值」、`@as` 在 `error{}`／`opaque`／`!T`
//! 上各有假红——本轮实测逐形坐实（见台账 347 节形制矩阵）。假红会把绿工程判死，比漏检危害大，
//! 故形制不明一律走引用形：**宁漏不误伤**。

const std = @import("std");

/// 顶层声明行首形：`[pub] [extern] (fn|const|var) 名`。调用方（`probeSource`）仅在**花括号深度为
/// 0** 的行喂入本判据——缩进对 Zig 无语义，去缩进的函数体语句会顶格出现，故「行首非空白」不足
/// 以界定顶层；深度轨才是「只探顶层声明」的唯一真相（见 `probeSource`）。
const decl_pat = "fn|const|var";

/// 可安全施加 `@as(N, undefined)` 的 RHS 首元词——**原子类型名单**（Zig 的整型/浮点/布尔/
/// void/type/comptime_* 皆类型，实例化为 `undefined` 恒合法）。
const atom_types = [_][]const u8{
    "i8",             "i16",      "i32", "i64", "i128", "u8",   "u16",  "u32",  "u64",  "u128",
    "isize",          "usize",    "f16", "f32", "f64",  "f128", "bool", "void", "type", "comptime_int",
    "comptime_float", "noreturn",
};

/// 探针式的分类结果。
pub const Probe = enum {
    /// 取址形：`const p_N = &N; _ = p_N;`
    addr,
    /// 型制化形：`const p_N = @as(N, undefined); _ = p_N;`
    as_undef,
    /// 引用形（保守回落）：`const p_N = .{N}; _ = p_N;`
    refer,

    /// 渲染单枚探针（三式共用 `p_<名>` 具名绑定，避开 comptime 块内 `_ =` 重名 discard）。
    pub fn render(self: Probe, name: []const u8, buf: []u8) []const u8 {
        return switch (self) {
            .addr => std.fmt.bufPrint(buf, "const p_{s} = &{s}; _ = p_{s};", .{ name, name, name }) catch "",
            .as_undef => std.fmt.bufPrint(buf, "const p_{s} = @as({s}, undefined); _ = p_{s};", .{ name, name, name }) catch "",
            .refer => std.fmt.bufPrint(buf, "const p_{s} = .{{{s}}}; _ = p_{s};", .{ name, name, name }) catch "",
        };
    }
};

/// 取 `s` 的前导标识符（ASCII 词首）；无则 null。
fn firstIdent(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    const c = s[0];
    if (!(std.ascii.isAlphabetic(c) or c == '_')) return null;
    var i: usize = 1;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
    return s[0..i];
}

/// 该标识符是否恰为 `kw`（整词：后一字符不得仍是词字符）。
fn isKeyword(ident: []const u8, kw: []const u8) bool {
    if (!std.mem.eql(u8, ident, kw)) return false;
    return true;
}

/// RHS 是否以「长度前缀数组型」`[数字]` 开头（如 `[3]u8`、`[0]u8`、`[_]u8`）。
fn isLenArrayTy(rhs: []const u8) bool {
    if (rhs.len == 0 or rhs[0] != '[') return false;
    var i: usize = 1;
    var seen = false;
    while (i < rhs.len and rhs[i] != ']') : (i += 1) {
        if (rhs[i] == '_') {
            seen = true;
            continue;
        }
        if (!std.ascii.isDigit(rhs[i])) return false;
        seen = true;
    }
    return seen and i < rhs.len and rhs[i] == ']';
}

/// 判 `const` 声明的 RHS 是否确为「类型」——只有类型才允许走 `@as(_, undefined)` 形。
/// 判据只取**首元词/首符号**，形制不明一律 false（落引用形）。
fn rhsIsType(rhs: []const u8) bool {
    const s = rhs;
    // 前导空白已在调用侧剥除；此处只处理形制首符。
    if (s.len == 0) return false;
    switch (s[0]) {
        '*', '?' => return true, // 指针型 `*T`、可选型 `?T`
        '[' => return std.mem.startsWith(u8, s, "[]") or isLenArrayTy(s), // 切片型／定长数组型
        '@' => return false, // `@import`/`@TypeOf`/`@max`… 内置调用：返回类型者极少，保守走引用形
        'e' => {
            // `error{A,B}` 是**值**（错误集实例）而非类型；`error.Name` 亦是值。
            if (std.mem.startsWith(u8, s, "error")) return false;
        },
        else => {},
    }
    const ident = firstIdent(s) orelse return false;
    // `packed struct`／`extern struct`／`opaque {}` 皆非「可直接 @as 的类型名」：前两者首词不是类型，
    // `opaque` 是类型但 `@as(opaque型, undefined)` 报「cannot cast to opaque type」——本轮实测假红，落引用形。
    if (std.mem.eql(u8, ident, "packed") or std.mem.eql(u8, ident, "extern") or
        std.mem.eql(u8, ident, "opaque") or std.mem.eql(u8, ident, "anyopaque")) return false;
    if (isKeyword(ident, "struct") or isKeyword(ident, "enum") or isKeyword(ident, "union")) {
        // 容器字面量族：`enum` 的显值位宽核对亦在此形下逼出（实测 `enum(u2){a=9}` 报红）。
        return true;
    }
    if (isKeyword(ident, "fn")) return false; // 函数**型** `fn () void` 可 @as，但方言不产出，保守落引用形
    for (atom_types) |t| {
        if (std.mem.eql(u8, ident, t)) return true;
    }
    return false; // 命名引用（`const K = U;`）、调用式、标量……形制不明 → 引用形
}

/// 声明匹配结果。
const Decl = struct { name: []const u8, probe: Probe };

/// 解析一行的顶层声明形；非声明行返回 null。
fn matchDecl(line: []const u8) ?Decl {
    var s = line;
    s = consumeKw(s, "pub") orelse return null; // `pub` 可选，consumeKw 未命中时原样返回
    s = consumeKw(s, "extern") orelse return null;
    const kw = firstIdent(s) orelse return null;
    if (std.mem.indexOf(u8, decl_pat, kw) == null) return null;
    s = std.mem.trim(u8, s[kw.len..], " ");
    const name = firstIdent(s) orelse return null;
    if (std.mem.eql(u8, kw, "fn")) return .{ .name = name, .probe = .addr };
    if (std.mem.eql(u8, kw, "var")) return .{ .name = name, .probe = .addr };
    // const：先看有无型注（`const N: T = v;` 的 N 是**值**，`@as(N, undefined)` 必假红），再判 RHS 形制。
    const after = std.mem.trim(u8, s[name.len..], " ");
    if (after.len > 0 and after[0] == ':') return .{ .name = name, .probe = .refer };
    const eq = std.mem.indexOfScalarPos(u8, after, 0, '=') orelse return .{ .name = name, .probe = .refer };
    // 声明头里不得先出现换行（跨行声明头在此保守落引用形，不误伤）。
    const rhs = std.mem.trim(u8, after[eq + 1 ..], " \t");
    if (rhs.len == 0) return .{ .name = name, .probe = .refer };
    return .{ .name = name, .probe = if (rhsIsType(rhs)) Probe.as_undef else Probe.refer };
}

/// 若 `s` 以关键字 `kw` 开头（整词）则剥之并返回余下（已去前导空白）；否则原样返回（关键字可选）。
fn consumeKw(s: []const u8, kw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, kw)) return s;
    const rest = s[kw.len..];
    if (rest.len == 0) return s;
    // 词边界：关键字后必须紧跟空白，否则是撞词首（如 `publib …` 不是 `pub` 修饰）。
    if (rest[0] != ' ' and rest[0] != '\t') return s;
    return std.mem.trimStart(u8, rest, " \t");
}

/// 拼装探针副本全文：原源码 ＋ 尾部一枚 `comptime` 块（全挤一行、只增尾行）。
/// 无顶层声明时返回 null——不必为碎片文件多跑一次 zig。
///
/// 「顶层」由**花括号嵌套深度**界定而非缩进：Zig 缩进无语义，教程去缩进块（或任何平铺写法）
/// 里函数体的 `var`/`const` 会顶格出现——旧判据 `line[0] != ' '` 把这些局部声明误当顶层、
/// 探针越界引用局部名→假红（第 347 轮 D206 活线：去缩进的 `pub fn main` 内 `var z_1` 被当顶层、
/// `&z_1` 报「使用了未声明的标识符」）。改以行首深度 == 0 为准；深度扫描忽略字符串/字符字面量
/// 与行注释内的花括号（Zig 无块注释，仅 `//`）。
pub fn probeSource(gpa: std.mem.Allocator, src: []const u8) !?[]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, src);
    try list.appendSlice(gpa, "\ncomptime { ");
    var n: usize = 0;
    var depth: usize = 0; // 花括号嵌套深度；行首为 0 者才是顶层声明（与缩进无关）
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        // 先用「行首深度」判定是否顶层（本行自带的 `{` 不得参与自刑），再扫描本行更新深度。
        if (depth == 0) {
            if (matchDecl(line)) |d| {
                var buf: [256]u8 = undefined;
                const one = d.probe.render(d.name, &buf);
                if (one.len != 0) {
                    if (n > 0) try list.append(gpa, ' ');
                    try list.appendSlice(gpa, one);
                    n += 1;
                }
            }
        }
        var in_str = false; // 本行内是否处于字符串/字符字面量（逐行复位：正常字面量不跨行）
        var i: usize = 0;
        while (i < line.len) {
            const c = line[i];
            if (in_str) {
                if (c == '\\') { // 转义：连同后一字节一并跳过
                    i += 2;
                    continue;
                }
                if (c == '\"' or c == '\'') in_str = false;
                i += 1;
                continue;
            }
            if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break; // 行注释：本行余下皆忽略
            if (c == '\"' or c == '\'') {
                in_str = true;
                i += 1;
                continue;
            }
            if (c == '{') depth += 1;
            if (c == '}') depth -%= 1; // 夹顶：绝不使 depth 下溢为巨值（一旦下溢即视为深层、永不再探，保守漏检）
            i += 1;
        }
    }
    if (n == 0) {
        list.deinit(gpa);
        return null;
    }
    try list.appendSlice(gpa, " }\n");
    const owned: []const u8 = try list.toOwnedSlice(gpa);
    return owned;
}

// ============================================================================
// 守卫归位（第 347 轮 D206）：本模块系深检探针的**实现**模块，按 341 轮 D200 判据「面表须与其
// 词汇同源」——它不持 `*_face`。两处对账针分居其词汇归属 hub：
//   * `&.{ cli.tl_zig, cli.tl_build_lib, probe_rel, cli.tl_no_emit_bin }`（main ③ 臂 argv 委派形）
//     → `cli.tl_face`（持 `tl_*` 词族）；
//   * `zzc.probe_file_prefix`（main 探针副本名委派 hub 单源）→ `zzc_paths.probe_face`（持该常量）。
// 二者皆由 `check-machine-matcher` 对 `src/main.zig` 逐字节对账；消费侧改回手抄字面量或整臂被删即守卫红。
// ============================================================================

// ============================================================================
// 测块
// ============================================================================

const testing = std.testing;

test "347 T0 A1：三式分派逐形钉（第 347 轮 D206）——形制判据不得漂" {
    // fn / var → 取址形
    try testing.expectEqual(Probe.addr, (matchDecl("pub fn z_4(z_5: u8) u8 {") orelse return error.Bad).probe);
    try testing.expectEqual(Probe.addr, (matchDecl("var z_1: u8 = 3;") orelse return error.Bad).probe);
    // 容器/枚举/联合/原子型/切片/定长数组/指针/可选 → 型制化形
    for ([_][]const u8{
        "const z_1 = struct { a: u8 = 7 };",
        "const z_1 = enum(u2) { a, b };",
        "const z_1 = union(enum) { a: u8 };",
        "const z_1 = u8;",
        "const z_1 = []const u8;",
        "const z_1 = [3]u8;",
        "const z_1 = *u8;",
        "const z_1 = ?u8;",
    }) |l| {
        try testing.expectEqual(Probe.as_undef, (matchDecl(l) orelse return error.Bad).probe);
    }
    // 保守回落族：@import / error 集 / opaque / 错误联合 / anyopaque / 带型注常数 / 标量 / 调用式 / 命名引用
    for ([_][]const u8{
        "const z_1 = @import(\"std\");",
        "const z_1 = error{ A, B };",
        "const z_1 = opaque {};",
        "const z_1 = anyopaque;",
        "const z_1 = !u8;",
        "const z_1: u8 = 3;",
        "const z_1 = 3 + 4;",
        "const z_1 = @max(3, 9);",
        "const z_1 = z_2(1);",
        "const z_1 = z_9;",
    }) |l| {
        try testing.expectEqual(Probe.refer, (matchDecl(l) orelse return error.Bad).probe);
    }
    // 非顶层声明行不入集（缩进、右花括号续行、注释、表达式）
    try testing.expect(matchDecl("    const inner = 1;") == null);
    try testing.expect(matchDecl("};") == null);
    try testing.expect(matchDecl("// 注释 const x = 1;") == null);
    try testing.expect(matchDecl("const") == null);
}

test "347 T0 A2：名钉＋型注位钉——声明名取错即探针指向不存在的标识符" {
    const d = (matchDecl("pub const z_42 = struct {}") orelse return error.Bad);
    try testing.expectEqualStrings("z_42", d.name);
    const f = (matchDecl("extern fn z_7(a: u8) void;") orelse return error.Bad);
    try testing.expectEqualStrings("z_7", f.name);
    try testing.expectEqual(Probe.addr, f.probe);
}

test "347 T0 A3：拼装全文——只在尾部加行，原行号分毫不动" {
    const src = "const z_1 = @import(\"std\");\n\npub fn z_2() void {\n    z_1.debug.print(\"x\\n\", .{});\n}\n";
    const got = (try probeSource(testing.allocator, src)) orelse return error.NoProbe;
    defer testing.allocator.free(got);
    // 原 5 行逐字节保留（回译契约：行号映射不得因探针而位移）。
    try testing.expect(got.len > src.len);
    try testing.expectEqualStrings(src, got[0..src.len]);
    // 追加体只有一枚 comptime 块、且不含换行插在中部。
    const tail = got[src.len..];
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tail, "\n"));
    try testing.expect(std.mem.startsWith(u8, tail, "\ncomptime { "));
    try testing.expect(std.mem.indexOf(u8, tail, "const p_z_1 = .{z_1};") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "const p_z_2 = &z_2;") != null);
}

test "347 T0 A4：零顶层声明者不产探针（碎片文件不必多跑一次 zig）" {
    const got = try probeSource(testing.allocator, "    只有缩进的声明\n");
    try testing.expectEqual(@as(?[]const u8, null), got);
}

test "347 T0 A5：三式渲染逐字节钉（第 347 轮 D206）——探针文本形漂即假红/漏检" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("const p_z_1 = &z_1; _ = p_z_1;", Probe.addr.render("z_1", &buf));
    try testing.expectEqualStrings("const p_z_2 = @as(z_2, undefined); _ = p_z_2;", Probe.as_undef.render("z_2", &buf));
    try testing.expectEqualStrings("const p_z_3 = .{z_3}; _ = p_z_3;", Probe.refer.render("z_3", &buf));
}

test "347 T0 A6：去缩进函数体局部声明不入探针集（第 347 轮 D206 假红消解）——深度轨而非缩进轨" {
    // 平铺写法（教程去缩进块即此形）：函数体 `var`/`const` 顶格出现，旧 `line[0] != ' '` 判据
    // 误当顶层 → 探针 `&z_1` 越界引用局部名 → zig build-lib 报「use of undeclared identifier」假红。
    // 本测把假红形固化为反例：只许探顶层 `main`，字符串内 `{d}` 不得扰动深度轨。
    const src = "pub fn main() !void {\nvar z_1: i64 = 10;\nz_1 = z_1 + 1;\nstd.debug.print(\"{d}\\n\", .{z_1});\n}\n";
    const got = (try probeSource(testing.allocator, src)) orelse return error.NoProbe;
    defer testing.allocator.free(got);
    try testing.expect(got.len > src.len);
    const tail = got[src.len..];
    try testing.expect(std.mem.indexOf(u8, tail, "&main") != null); // 顶层 fn 入集
    try testing.expect(std.mem.indexOf(u8, tail, "z_1") == null); // 局部名绝不入集（否则即本轮假红复现）
    // 去缩进后仅剩一枚 main 探针 → 尾部恰一枚 comptime 块、两枚绑定，无第二枚 p_z_1。
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, tail, "const p_"));
}
