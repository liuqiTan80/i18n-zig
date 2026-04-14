//! 机读出口契约 ↔ 编辑器对面守卫（第 203 轮 D71）：读 `package.json` 的 problemMatcher 正则
//! 与 `tasks.json` 的示例命令行，核对二者仍等于 `machine_contract` 的契约真值、且正则与我方
//! 生成侧格式串同骨。用法：
//!   check-machine-matcher [package.json 路径] [tasks.json 路径]
//!   （缺省 `editors/vscode/package.json` 与 `editors/vscode/examples/tasks.json`）
//! 判断本身（`fmtSkel`/`regexpSkel`/`fmtAndRegexpAgree`）全在 `machine_contract.zig` 并由其 203 T0
//! 用小样钉住——本程序只做 I/O、JSON 取值与退出码，不另立第二套判据。
//! 为何不在测试图内读盘：`@embedFile` 受 zig 0.17 的 module 包路径（`src/`）限制不可越（202 轮
//! 硬约束判例），而测试内 `cwd()` 偷读的文件不入构建步骤清单——改对面文件不会触发重跑
//! （203 t2 探针 P1/P2 实锤「全绿且测数行为空」的假绿形制），故跨文件覆盖由**声明了文件依赖**的
//! 本守卫步承担（同 154/155/202 轮形制，已挂 `zig build test`）。

const std = @import("std");
const mcon = @import("zzc_core").machine;

/// 取 `text` 中 `from` 之后首个 `"key"` 对应的 JSON 字符串值；返回引号之间的**原始**片段
/// （未反转义）与其后下标。非字符串值、无该键、引号不闭合皆返 null。
fn jsonStringValue(text: []const u8, comptime key: []const u8, from: usize) ?struct { val: []const u8, next: usize } {
    const quoted = "\"" ++ key ++ "\"";
    const k = std.mem.indexOf(u8, text[from..], quoted) orelse return null;
    var i = from + k + quoted.len;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    if (i >= text.len or text[i] != ':') return null;
    i += 1;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    if (i >= text.len or text[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < text.len) {
        switch (text[i]) {
            '"' => return .{ .val = text[start..i], .next = i + 1 },
            '\\' => i += 2, // 转义对整体跳过，免得把 \" 当收尾引号
            else => i += 1,
        }
    }
    return null;
}

/// JSON 字符串片段反转义（本族对面只用到 `\\` 与 `\"`；其余转义如实报错、不静默放过）。
fn unescape(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try out.append(gpa, raw[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= raw.len) return error.BadEscape;
        const c: u8 = switch (raw[i + 1]) {
            '\\' => '\\',
            '"' => '"',
            '/' => '/',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => return error.BadEscape,
        };
        try out.append(gpa, c);
        i += 2;
    }
    return out.toOwnedSlice(gpa);
}

fn fail(comptime msg: []const u8, args: anytype) noreturn {
    std.debug.print(msg, args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    const pkg_path = if (args.len >= 2) args[1] else "editors/vscode/package.json";
    const tasks_path = if (args.len >= 3) args[2] else "editors/vscode/examples/tasks.json";

    // —— 对面一：package.json 的 problemMatcher 正则（分隔符/段数一改，编辑器 Problems 面板即静默全空）。
    const pkg = std.Io.Dir.cwd().readFileAlloc(io, pkg_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ pkg_path, @errorName(e) });
    defer gpa.free(pkg);
    const got = jsonStringValue(pkg, "regexp", 0) orelse
        fail("FAIL: {s} 里找不到 problemMatchers 的 \"regexp\" 字段——对面消失即无契约可言。\n", .{pkg_path});
    const re = unescape(gpa, got.val) catch |e|
        fail("FAIL: {s} 的 regexp 值反转义失败（{s}）\n", .{ pkg_path, @errorName(e) });
    defer gpa.free(re);
    if (!std.mem.eql(u8, re, mcon.matcher_regexp)) {
        fail(
            "FAIL: {s} 的 problemMatcher 正则与契约真值分道：\n  对面 = {s}\n  真值 = {s}\n" ++
                "  要么编辑器侧不再按机读行解析（用户 Problems 面板会空），要么我方改了形制而忘了对面。\n",
            .{ pkg_path, re, mcon.matcher_regexp },
        );
    }
    // 同骨判据复核（真行为面：即使字面相等，也确认正则确实吃得下我方生成侧的行形）。
    if (!mcon.fmtAndRegexpAgree(mcon.line_fmt, re)) {
        fail("FAIL: {s} 的正则与我方机读行格式串不同骨（段数或分隔符序列不等）。\n", .{pkg_path});
    }

    // —— 对面二：tasks.json 的示例命令行（用户照抄即失败的那一面）。
    const tasks = std.Io.Dir.cwd().readFileAlloc(io, tasks_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ tasks_path, @errorName(e) });
    defer gpa.free(tasks);
    var found_cmd = false;
    var matched = false;
    var from: usize = 0;
    while (jsonStringValue(tasks, "command", from)) |c| {
        from = c.next;
        found_cmd = true;
        const val = unescape(gpa, c.val) catch |e|
            fail("FAIL: {s} 的 command 值反转义失败（{s}）\n", .{ tasks_path, @errorName(e) });
        defer gpa.free(val);
        if (std.mem.eql(u8, val, mcon.tasks_command)) matched = true;
    }
    if (!found_cmd) fail("FAIL: {s} 里找不到 \"command\" 字段。\n", .{tasks_path});
    if (!matched) {
        fail(
            "FAIL: {s} 没有等于契约真值「{s}」的示例命令——用户照抄示例即得未知子命令/未知旗标。\n",
            .{ tasks_path, mcon.tasks_command },
        );
    }

    std.debug.print(
        "OK: {s} 与 {s} 仍与机读契约同源（正则同骨、示例命令 =「{s}」）\n",
        .{ pkg_path, tasks_path, mcon.tasks_command },
    );
}
