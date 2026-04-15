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
const legend = @import("zzc_core").lsp_legend; // 第 214 轮 D82：语义 token 图例真值与 `extensionDeclaresLegend` 判据
const paths = @import("zzc_core").paths; // 第 210 轮 D78：程序名单一真值与 `buildDeclaresExe` 判据
const lid = @import("zzc_core").lang_id; // 第 215 轮 D83：编辑器语言标识族真值与三面对账 needle 清单

/// 一面（needle 清单）逐字节对账：缺任一枚即分道退出。判据（needle 与后果描述）全在 hub，
/// 本函数只做「在已读入的对面文本里找」与退出码——守 203/210/214 轮「判据入 hub、守卫只做 I/O」形制。
fn checkFace(face_name: []const u8, comptime face: []const lid.FaceCheck, text: []const u8) void {
    inline for (face) |c| {
        if (lid.missing(text, c.needle)) {
            fail(
                "FAIL: {s} 缺逐字节声明「{s}」——{s}\n",
                .{ face_name, c.needle, c.why },
            );
        }
    }
}

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

    // —— 对面三：`build.zig` 实际产出的 CLI exe 名（第 210 轮 D78）。示例命令首词由 `mcon.tasks_command`
    //   派生自 `paths.prog_name`；若 build 脚本里的 `addExecutable(.name)` 与之分道（改名而忘同步），
    //   编辑器照示例运行的 `zzc …` 就指向一个不存在的二进制——t2 探针 P1 实锤这条静默的功能级断裂。
    const build_path = if (args.len >= 4) args[3] else "build.zig";
    const build = std.Io.Dir.cwd().readFileAlloc(io, build_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ build_path, @errorName(e) });
    defer gpa.free(build);
    if (!paths.buildDeclaresExe(build)) {
        fail(
            "FAIL: {s} 未声明名为「{s}」的可执行文件（`.name = \"{s}\"`），与程序名真值分道——产出二进制会更名，" ++
                "而编辑器示例命令/报错前缀/LSP source 仍写旧名。请同改 `{s}` 的 `.name` 与 `zzc_paths.prog_name`。\n",
            .{ build_path, paths.prog_name, paths.prog_name, build_path },
        );
    }

    // —— 对面四：`editors/vscode/extension.js` 的客户端语义 token 图例（第 214 轮 D82）。该文件内注释
    //   自称 guard-pinned 而既有三对面皆不含它——t2 探针 P3 实锤改客户端图例序全绿静默：索引由服务端
    //   数据 5 元组携带、客户端拿自家图例反查，错序/改名即静默错色。判据在 hub（extensionDeclaresLegend），
    //   本步只读文件与退出码；同时本步 addFileArg 已声明其入 source dependency 清单。
    const ext_path = if (args.len >= 5) args[4] else "editors/vscode/extension.js";
    const ext = std.Io.Dir.cwd().readFileAlloc(io, ext_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ ext_path, @errorName(e) });
    defer gpa.free(ext);
    if (!legend.extensionDeclaresLegend(ext)) {
        fail(
            "FAIL: {s} 的客户端图例与 LSP 语义图例真值分道——须逐字节声明 `{s}`。" ++
                "客户端拿自家图例反查服务端索引，错序/改名即静默错色（或越界）。\n",
            .{ ext_path, legend.client_legend_needle },
        );
    }

    // —— 对面五／六／七：编辑器语言标识族（第 215 轮 D83）。`language_id`／`scope_name`／`matcher_name`／
    //   资产路径在 `src/editor/`（生成侧）与 `editors/vscode/`（清单/客户端/示例）两侧互不引用——
    //   t2 探针 P2（改清单 scopeName）／P3（改客户端 LANGUAGE_ID）／P4（改清单 id）／P6（改生成器落点）／
    //   P7／P8（改 matcher 引用与定义名）六路全绿静默，而后果是功能级断裂（高亮全废／LSP 全废／
    //   Problems 面板不填）。三片皆已在上面读过（零新增 I/O），此处只按 hub 的 needle 清单对账；
    //   生成侧与资产文件本体由 `check-editor-syntax`／`check-editor-snippets` 步守（产物 == 重生成品），
    //   产物内 scopeName 今已由 hub 派生，故该两步步步相衔接地钉住了本族。
    checkFace(pkg_path, &lid.pkg_face, pkg);
    checkFace(ext_path, &lid.client_face, ext);
    checkFace(tasks_path, &lid.tasks_face, tasks);

    std.debug.print(
        "OK: {s}／{s} 与机读契约同源，{s} 产出的 CLI exe 名 =「{s}」（正则同骨、示例命令 =「{s}」），且 {s} 客户端图例与 LSP 语义图例同源、语言标识族九/一/一 枚 needle 在清单／客户端／示例三面皆命中\n",
        .{ pkg_path, tasks_path, build_path, paths.prog_name, mcon.tasks_command, ext_path },
    );
}
