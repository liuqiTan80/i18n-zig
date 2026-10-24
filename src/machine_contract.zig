//! 机读出口契约 hub（零依赖、纯 comptime 逻辑）：`--machine` 旗标名、`check` 子命令名、
//! 机读单行的格式骨架，以及三个消费对面（我方 LSP 解析器 / 编辑器 problemMatcher 正则 /
//! 编辑器示例命令行）的共同单一真值。
//!
//! 第 203 轮 D71。靶面（t2 探针 `.scratch203/probe203.sh` 实锤）：
//!   * P1 `editors/vscode/package.json` 的 `problemMatchers[].pattern.regexp` 分隔符漂移 →
//!     `zig build test` **全绿且测数行为空**（该文件不是 source dependency、全仓无读者），
//!     而 `main.zig` 注释自 154 轮起即声称「与 problemMatcher 正则同一契约、同一真相源」——
//!     口头声明的跨文件依赖（197/202 轮 D65/D70 同形制）。后果：编辑器 Problems 面板静默全空。
//!   * P2 `examples/tasks.json` 的 `"zzc check --machine"` 命令名漂移 → 同上全绿零读者。
//!     后果：用户照抄示例即失败。
//!   * P6 `main` dispatch 的 `"check"` 字面量改名（LSP 自调用 argv 不动）→ **223/223 全绿**。
//!     后果：真跑时 LSP 语义供给器 spawn 得「未知子命令」，编辑器语义诊断面整块失效而测恒绿。
//!   * P7 `usage_text` 的机读形制说明 `路径:行:列: 种类: 消息` 漂移 → 全绿（既有测只判旗标名在场）。
//!     后果：帮助文案说谎（用户按文案写正则即不匹配）。
//!   * P8 旗标名在解析侧与开关侧同改（argv 不动）→ 全绿（各处手抄字面各自自洽）。
//!   反证 P3（消费侧解析器放宽）／P4（生成侧格式串漂移）／P5（自调用 argv 旗标名漂移）皆红——
//!   值侧本有钉，本轮补的是**跨面耦合**防线。
//!
//! 跨文件对面（package.json / tasks.json）不入测试图：`@embedFile` 受 module 包路径（`src/`）
//! 限制不可越（202 轮硬约束判例），测试内 `cwd()` 偷读又复制 P1 的假绿形制，故其覆盖交
//! `zig build check-machine-matcher` 守卫步（`addFileArg` 声明文件依赖），本模块只提供其判据真值。

const std = @import("std");
const zzc = @import("zzc_paths.zig"); // 第 210 轮 D78：示例命令行的程序名首词取单一真值（与 build.zig 产出的 exe 名同源）

/// comptime 片段串接（小工具）：拼定长缓冲、零堆分配，供由真值派生对面值时用。
fn comptimeCat(comptime parts: anytype) []const u8 {
    comptime {
        var buf: [512]u8 = undefined;
        var n: usize = 0;
        for (parts) |p| {
            if (n + p.len > buf.len) @compileError("comptimeCat 缓冲不足");
            for (p) |c| {
                buf[n] = c;
                n += 1;
            }
        }
        const out: [n]u8 = buf[0..n].*;
        return &out;
    }
    @compileError("comptimeCat 只可在 comptime 调用");
}

/// 子命令 `check` 的名真值：`main` dispatch 的 check 臂与 LSP 语义供给器自调用 argv 的配对点。
pub const sub_check: []const u8 = "check";

/// 机读旗标名真值：cli 解析、main 开关、LSP 自调用 argv、编辑器示例命令行的共同出处。
pub const flag_machine: []const u8 = "--machine";

/// 机读单行的字段名（帮助文案显示面），与 `sep_after` 同序、长度即 `field_count`。
pub const field_names = [_][]const u8{ "路径", "行", "列", "种类", "消息" };

/// 字段之间的字面分隔符序列（四枚，夹在五段之间）——生成侧格式串、消费侧解析器、
/// 编辑器正则三者共同的形制真值。
pub const sep_after = [_][]const u8{ ":", ":", ": ", ": " };

/// 机读单行的段数（五个捕获段 / 五个占位符）。
pub const field_count: usize = 5;

/// 机读行的坐标头部（文件:行:列: 三段的占位形与分隔符）：生成侧两式与词法/纯母语
/// 报错行共用的出处（这些行天然是单行机读形，走 machineLines 的透传臂）。
pub const line_head: []const u8 = "{s}:{d}:{d}: ";

/// 生成侧格式串（无提示形）：`diag.flushMachine` 的唯一取用点。
pub const line_fmt: []const u8 = comptimeCat(.{ line_head, "{s}: {s}", "\n" });

/// 生成侧格式串（带提示形）：提示以全角括号并入末段，不新增 ASCII 分隔符（否则消费侧
/// 正则的 `(\S+): (.*)` 两段会被切断）。行体与 `line_fmt` 同源。
pub const line_fmt_tip: []const u8 = comptimeCat(.{ line_head, "{s}: {s}", "（提示：{s}）", "\n" });

/// 编辑器 problemMatcher 的正则真值（**JSON 反转义后**的形，即 `package.json` 对面读到的值）。
/// Zig 字面量里 `\\d` 即文件里的 `\d`，故本常量持单反斜杠形；守卫步负责先反转义再逐字节比。
pub const matcher_regexp: []const u8 = "^([^\\s:].*?):(\\d+):(\\d+): (\\S+): (.*)$";

/// 编辑器示例命令行的命令前缀（`tasks.json` 对面的 `command` 值），由程序名真值与两枚契约真值派生、非手抄（第 210 轮 D78）。
pub const tasks_command: []const u8 = comptimeCat(.{ zzc.prog_name, " ", sub_check, " ", flag_machine });

// ---------------------------------------------------------- pattern 字段映射（第 225 轮 D93）
//
// `package.json` 的 problemMatcher `pattern` 除 `regexp` 外还有五枚**字段→捕获组号**映射
// （`"file": 1` … `"message": 5`）——对面一只核 regexp 词与同骨（段数/分隔符），从不读这五枚数字；
// t2 探针 P1/P2/P3 三路改数字 fresh 585/585 全绿静默，而 VSCode 按清单消费即面板字段串位
// （file 收到行号、code 收到消息本体）。本段把「五字段各取第几组、该组须为何种型」立为真值，
// 型序与 `line_fmt` 占位符序互钉（s,d,d,s,s），对面十七以派生 needle 逐字节对账 package.json。

/// VSCode pattern 五字段名与其应对的占位符型（组号 = 列序 + 1，与 `line_fmt` 占位符同序）。
/// `ty` 即 `line_fmt` 对应段占位符字符：'s' 字符串段、'd' 数字段——语义对应 file→路径、
/// location→行、column→列、code→种类、message→消息（与 `field_names` 同序，人约字面并列钉于 225 T0）。
pub const pattern_pairs = .{
    .{ .key = "file", .ty = 's' },
    .{ .key = "location", .ty = 'd' },
    .{ .key = "column", .ty = 'd' },
    .{ .key = "code", .ty = 's' },
    .{ .key = "message", .ty = 's' },
};

/// 单个数字字（本族段数恒 ≤ 5，组号皆单字符）。
fn digit(comptime n: usize) []const u8 {
    return switch (n) {
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        else => @compileError("digit 只容单个数字字（1..=5）"),
    };
}

/// 对面十七核对项（与守卫 checkFace 同形的 needle/why 对；判据入 hub，守卫只做 I/O）。
/// `occ`：对面文件中应现枚数（缺省 1＝presence 语义）。第 323 轮 D182 补齐——旧形缺此字段，
/// 守卫靠 `@hasField` 静默回落；本族与 `BuildFace`／`FaceCheck` 五族自此统一，名实闸可全覆盖。
pub const PatternFace = struct { needle: []const u8, why: []const u8, occ: usize = 1 };

/// 由 `pattern_pairs` 派生的五枚逐字节 needle（`"file": 1` … `"message": 5`）——
/// 改任一枚字段名/组号皆回到本真值重派生，杜绝第二份手抄。
pub const pattern_face: [pattern_pairs.len]PatternFace = blk: {
    var out: [pattern_pairs.len]PatternFace = undefined;
    for (pattern_pairs, 0..) |pf, i| {
        out[i] = .{
            .needle = comptimeCat(.{ "\"", pf.key, "\": ", digit(i + 1) }),
            .why = "problemMatcher pattern 字段「" ++ pf.key ++ "」须取第 " ++ digit(i + 1) ++
                " 捕获组（机读行段序真值）——漂移即编辑器 Problems 面板字段串位而构建链恒绿（第 225 轮 D93 t2 实锤）",
        };
    }
    break :blk out;
};

/// 从 Zig 格式串按序抽占位符型数组（只认 {s}/{d}单字符型、恰 `field_count` 枚，否则 null）。
pub fn fmtPlaceholderTypes(fmt: []const u8) ?[field_count]u8 {
    var out: [field_count]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '{') {
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalar(u8, fmt[i..], '}') orelse return null;
        const spec = fmt[i + 1 .. i + close];
        if (spec.len != 1) return null;
        if (n >= field_count) return null;
        out[n] = spec[0];
        n += 1;
        i += close + 1;
    }
    if (n != field_count) return null;
    return out;
}

/// `pattern_pairs` 声明的字段型序是否与格式串占位符型序逐位相配（对面十七的值侧判据，
/// 供测钉直接比对：若 line_fmt 段型与面板字段语义脱钩——如把行号段改成 {s}——即判否）。
pub fn patternTypesAgree(fmt: []const u8) bool {
    const t = fmtPlaceholderTypes(fmt) orelse return false;
    inline for (pattern_pairs, 0..) |pf, i| {
        if (t[i] != pf.ty) return false;
    }
    return true;
}

/// 帮助文案里的机读形制提示（由 `field_names` 与 `sep_after` 拼出，杜绝第二份手抄）。
pub const shape_hint: []const u8 = buildShapeHint();

/// `shape_hint` 的构造器：仅 comptime 调用（把字段名与分隔符逐段拼进定长缓冲）。
fn buildShapeHint() []const u8 {
    comptime {
        if (field_names.len != sep_after.len + 1) @compileError("field_names 与 sep_after 不同序");
        var buf: [256]u8 = undefined;
        var n: usize = 0;
        for (field_names, 0..) |nm, i| {
            if (n + nm.len > buf.len) @compileError("buildShapeHint 缓冲不足");
            for (nm) |c| {
                buf[n] = c;
                n += 1;
            }
            if (i < sep_after.len) {
                if (n + sep_after[i].len > buf.len) @compileError("buildShapeHint 缓冲不足");
                for (sep_after[i]) |c| {
                    buf[n] = c;
                    n += 1;
                }
            }
        }
        const out: [n]u8 = buf[0..n].*;
        return &out;
    }
    @compileError("buildShapeHint 只可在 comptime 调用");
}

/// LSP 语义供给器的自调用 argv 形（纯函数、可锚）：`{ exe, "check", "--machine", <入口基名> }`。
pub fn machineArgv(exe: []const u8, entry: []const u8) [4][]const u8 {
    return .{ exe, sub_check, flag_machine, entry };
}

// ---------------------------------------------------------------- 形制骨架判据

/// 分隔符序列骨架：定长缓冲 + 计数（comptime 可用、无堆分配）。
pub const SepList = struct {
    items: [8][]const u8 = .{ "", "", "", "", "", "", "", "" },
    len: usize = 0,

    fn add(self: *SepList, s: []const u8) bool {
        if (self.len >= self.items.len) return false;
        self.items[self.len] = s;
        self.len += 1;
        return true;
    }

    pub fn eql(self: SepList, other: SepList) bool {
        if (self.len != other.len) return false;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (!std.mem.eql(u8, self.items[i], other.items[i])) return false;
        }
        return true;
    }
};

/// 从 Zig 格式串抽骨架：数 `{...}` 占位符（须恰 `field_count` 枚），取相邻占位符之间的
/// 字面文本为分隔符。形不合（占位符数不对、含宽度说明、首尾多余字面）返 null。
pub fn fmtSkel(fmt: []const u8) ?SepList {
    var out: SepList = .{};
    var placeholders: usize = 0;
    var prev_end: ?usize = null;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '{') {
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalar(u8, fmt[i..], '}') orelse return null;
        const spec = fmt[i + 1 .. i + close];
        if (spec.len != 1) return null; // 只认 {s}/{d}，不认宽度与命名形
        if (prev_end) |p| {
            if (!out.add(fmt[p..i])) return null;
        } else if (i != 0) {
            return null; // 首占位符前有字面文本
        }
        prev_end = i + close + 1;
        placeholders += 1;
        i = prev_end.?;
    }
    if (placeholders != field_count) return null;
    const tail = fmt[prev_end.?..];
    if (tail.len != 0 and !(tail.len == 1 and tail[0] == '\n')) return null; // 只容行尾换行
    return out;
}

/// 从 problemMatcher 正则抽骨架：须以 `^` 开头、`$` 结尾，捕获组恰 `field_count` 枚
/// （本族正则无嵌套括号，故按顶层 `(`/`)` 配对扫描），组间字面文本为分隔符。形不合返 null。
pub fn regexpSkel(re: []const u8) ?SepList {
    if (!std.mem.startsWith(u8, re, "^") or !std.mem.endsWith(u8, re, "$")) return null;
    var out: SepList = .{};
    var groups: usize = 0;
    var prev_close: ?usize = null;
    var i: usize = 1;
    const body_end = re.len - 1;
    while (i < body_end) {
        switch (re[i]) {
            '(' => {
                if (i + 1 < body_end and re[i + 1] == '?') return null; // 非捕获组/环视不在本族形内
                if (prev_close) |p| {
                    if (!out.add(re[p..i])) return null;
                }
                groups += 1;
                i += 1;
            },
            ')' => {
                prev_close = i + 1;
                i += 1;
            },
            '\\' => i += 2, // 转义对（\d \S \s）整对跳过，免得把反斜杠当字面分隔符
            else => i += 1,
        }
    }
    if (groups != field_count) return null;
    const tail = re[prev_close.?..body_end];
    if (tail.len != 0) return null; // 末捕获组后不得有字面文本
    return out;
}

/// 生成侧格式串与消费侧正则的形制是否同骨（段数与分隔符序列逐枚相等）。
pub fn fmtAndRegexpAgree(fmt: []const u8, re: []const u8) bool {
    const f = fmtSkel(fmt) orelse return false;
    const r = regexpSkel(re) orelse return false;
    return f.eql(r);
}

/// 骨架是否等于 `sep_after` 真值序列（供测钉直接比对，免把期望表手抄进断言）。
pub fn sepListMatchesTruth(skel: SepList) bool {
    var truth: SepList = .{ .len = sep_after.len };
    for (sep_after, 0..) |s, i| truth.items[i] = s;
    return skel.eql(truth);
}

// ---------------------------------------------------------------- 测

test "第 203 轮 T0 机读出口契约族：值钉／派生对面值／骨架形制钉／负例小样" {
    // —— A1 值钉（期望表为独立手抄字面量，与 hub 真值对拍；任一枚漂移即红）。
    try std.testing.expectEqualStrings("check", sub_check);
    try std.testing.expectEqualStrings("--machine", flag_machine);
    try std.testing.expectEqualStrings("{s}:{d}:{d}: {s}: {s}\n", line_fmt);
    try std.testing.expectEqualStrings("{s}:{d}:{d}: {s}: {s}（提示：{s}）\n", line_fmt_tip);
    try std.testing.expectEqualStrings("^([^\\s:].*?):(\\d+):(\\d+): (\\S+): (.*)$", matcher_regexp);
    try std.testing.expectEqual(@as(usize, 5), field_count);
    try std.testing.expectEqual(@as(usize, 4), sep_after.len);
    try std.testing.expectEqual(@as(usize, 5), field_names.len);

    // —— A2 派生真值：三枚由常量拼出的对面值，逐字节钉形（示例命令行 + 帮助文案提示 + 坐标头部）。
    try std.testing.expectEqualStrings("zzc check --machine", tasks_command);
    try std.testing.expectEqualStrings("路径:行:列: 种类: 消息", shape_hint);
    try std.testing.expectEqualStrings("{s}:{d}:{d}: ", line_head);

    // —— A3 骨架形制契约：生成侧与消费侧同骨，且骨即 `sep_after` 真值序列。
    try std.testing.expect(fmtAndRegexpAgree(line_fmt, matcher_regexp));
    const f_plain = fmtSkel(line_fmt) orelse return error.TestUnexpectedResult;
    try std.testing.expect(sepListMatchesTruth(f_plain));
    const r_skel = regexpSkel(matcher_regexp) orelse return error.TestUnexpectedResult;
    try std.testing.expect(sepListMatchesTruth(r_skel));
    // 提示式与无提示式同源：去掉行尾换行后互为前缀，且追加段不含 ASCII 冒号（不切断五段形）。
    const head = line_fmt[0 .. line_fmt.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, line_fmt_tip, head));
    const wrap = line_fmt_tip[head.len..];
    try std.testing.expectEqual(@as(usize, 0), std.mem.indexOfScalar(u8, wrap, ':') orelse 0);
    try std.testing.expectEqualStrings("（提示：{s}）\n", wrap);

    // —— A4 负例小样：分隔符漂移／段数漂移／锚点缺失／宽度说明／多余字面皆判否或 null。
    try std.testing.expect(!fmtAndRegexpAgree("{s}:{d}:{d}; {s}; {s}\n", matcher_regexp)); // 生成分隔符漂移
    try std.testing.expect(!fmtAndRegexpAgree("{s}:{d}:{d}: {s}:{s}\n", matcher_regexp)); // 分隔符少空格
    try std.testing.expect(fmtAndRegexpAgree(head, matcher_regexp)); // 骨架不含行尾，去换行仍同骨
    try std.testing.expect(!fmtAndRegexpAgree(line_fmt, "^([^\\s:].*?):(\\d+):(\\d+):(\\S+): (.*)$")); // 正则少空格
    try std.testing.expect(!fmtAndRegexpAgree(line_fmt, "^(\\d+):(\\d+):(\\d+):(\\d+):(\\d+)$")); // 分隔符全 ":"
    try std.testing.expect(fmtSkel("{s}:{d}:{d}: {s}\n") == null); // 少一段
    try std.testing.expect(fmtSkel("{s}:{d:2}:{d}: {s}: {s}\n") == null); // 宽度说明形不认
    try std.testing.expect(fmtSkel("x{s}:{d}:{d}: {s}: {s}\n") == null); // 首占位符前有字面
    try std.testing.expect(fmtSkel("{s}:{d}:{d}: {s}: {s}x\n") == null); // 行尾多余字面
    try std.testing.expect(regexpSkel("([^\\s:].*?):(\\d+):(\\d+): (\\S+): (.*)") == null); // 无 ^ $ 锚
    try std.testing.expect(regexpSkel("^([^\\s:].*?):(\\d+):(\\d+): (\\S+): (.*)x$") == null); // 末组后有字面
    try std.testing.expect(regexpSkel("^(?:x)(\\d+):(\\d+): (\\S+): (.*)$") == null); // 非捕获组不在族形内
    try std.testing.expect(regexpSkel("^([^\\s:].*?):(\\d+):(\\d+): (\\S+): (.*)") == null); // 缺尾锚
}

test "第 225 轮 T0 pattern 字段映射族：needle 派生形钉／型序相配判据／基数与同序钉（D93）" {
    // —— A1 派生 needle 形钉：五枚逐字节形独立手抄与 pattern_face 对拍（派生失真即红，
    //    守卫据其对账 package.json；此钉不依赖对面文件，入测试图）。
    const want_needles = [_][]const u8{ "\"file\": 1", "\"location\": 2", "\"column\": 3", "\"code\": 4", "\"message\": 5" };
    try std.testing.expectEqual(pattern_face.len, want_needles.len);
    for (pattern_face, want_needles) |pf, w| {
        try std.testing.expectEqualStrings(w, pf.needle);
    }
    // —— A2 型序相配：line_fmt 占位符型序 s,d,d,s,s 与 pattern_pairs 逐位相配（正例）；
    //    把行号段改成 {s} 的漂移形即判否（负例：面板 location 收到字符串即串位）。
    try std.testing.expect(patternTypesAgree(line_fmt));
    try std.testing.expect(!patternTypesAgree("{s}:{s}:{d}: {s}: {s}\n"));
    try std.testing.expect(!patternTypesAgree("{s}:{d}:{d}: {s}\n")); // 段数不足亦 null→否
    // 抽型函数自身形钉：真形逐字 d/s 序。
    const types = fmtPlaceholderTypes(line_fmt) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("sdds"[0..1], types[0..1]);
    try std.testing.expectEqual(@as(u8, 'd'), types[1]);
    try std.testing.expectEqual(@as(u8, 'd'), types[2]);
    try std.testing.expectEqual(@as(u8, 's'), types[3]);
    try std.testing.expectEqual(@as(u8, 's'), types[4]);
    // —— A3 同序与基数钉：五枚字段名/型/分隔符/标签四表同长（field_names 与 pattern_pairs
    //    的中文↔VSCode 字段语义对应为人约字面，此处钉长度与序位防单边增删）。
    try std.testing.expectEqual(field_count, pattern_pairs.len);
    try std.testing.expectEqual(field_names.len, pattern_face.len);
    // 提示式超出 pattern 判据域：tip 体以第六占位符并入末段显示（不新增 ASCII 分隔符，
    // 五捕获组形不变），故 fmtPlaceholderTypes 对 tip 式判 null——此形为设计意图，钉住防变。
    try std.testing.expect(fmtPlaceholderTypes(line_fmt_tip) == null);
}
