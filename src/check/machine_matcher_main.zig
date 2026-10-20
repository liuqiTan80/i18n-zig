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
const lcfg = @import("zzc_core").lsp_cfg; // 第 216 轮 D84：LSP 客户端接线族真值与清单/客户端两面 needle 清单
const jrpc = @import("zzc_core").lsp_jsonrpc; // 第 217 轮 D85：LSP 基座协议帧族真值与 client_frames.js 对面 needle 清单
const lsp_srv = @import("zzc_core").lsp_server; // 第 218 轮 D86：LSP 方法名族真值与 extension.js 对面 needle 清单
const cli_hub = @import("zzc_core").cli; // 第 224 轮 D92：工具链 spawn argv 词族真值与 main.zig 委派形对面清单

/// 一面（needle 清单）逐字节对账：命中不足即分道退出。判据（needle／后果／应现枚数 `occ`）全在 hub，
/// 本函数只做「在已读入的对面文本里按枚计数」与退出码——守 203/210/214 轮「判据入 hub、守卫只做 I/O」形制。
/// `face` 取 anytype：215/216 两 hub 各自声明同形制 FaceCheck（Zig struct 名义类型互不兼容），
/// 而搜索判据 `lid.countOccurrences` 与旧 `lcfg.missing` 语义在 `occ == 1` 时逐字节等价（计数 0 ⟺ indexOf 落空），
/// 不另立第三套；对无 `occ` 字段的 hub FaceCheck 以 `@hasField` 回落 `occ = 1`（presence 语义不变）。
fn checkFace(face_name: []const u8, comptime face: anytype, text: []const u8) void {
    inline for (face) |c| {
        const occ: usize = if (@hasField(@TypeOf(c), "occ")) c.occ else 1;
        if (lid.countOccurrences(text, c.needle) < occ) {
            fail(
                "FAIL: {s} 逐字节声明「{s}」命中不足 {d} 枚——{s}\n",
                .{ face_name, c.needle, occ, c.why },
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

    // —— 对面八／九：LSP 客户端接线族（第 216 轮 D84）。配置命名空间／取值键名／回落程序名／
    //   spawn 子命令词／方言旗标在 `src/` 真值（prog_name／cli.sub_lsp／cli.flag_lang）与清单声明侧、
    //   客户端消费侧三处互不引用——既有防线只在 `tools/check-demos.ps1` 的「lsp client guard」节，
    //   而本机与 CI 的 `zig build test` 链皆 NO_PWSH：t2 探针 P1–P6／P8 七路 568/568 全绿静默实证
    //   这条防线对本构建链等于零（假锚防线又一实例）。两面文件皆已读过（零新增 I/O），
    //   按 hub needle 清单对账；src 侧改名而 js 不随动即此处红——把「改名须同步客户端」变硬闸。
    checkFace(pkg_path, &lcfg.pkg_face, pkg);
    checkFace(ext_path, &lcfg.client_face, ext);

    // —— 对面十：`editors/vscode/client_frames.js` 的 LSP 基座协议帧族（第 217 轮 D85）。该文件
    //   注释自称与 `jsonrpc.zig` 「kept in sync by the shared handshake guard」，而该 guard 在
    //   ps1（需 pwsh+node）——本机与 CI 双盲：t2 探针 P1–P5 五路帧形漂移 569/569 全绿静默，
    //   后果是 initialize 握手都解不了（LSP 全废）。针面对账由本步新声明的第十片承担。
    const frames_path = if (args.len >= 6) args[5] else "editors/vscode/client_frames.js";
    const frames = std.Io.Dir.cwd().readFileAlloc(io, frames_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ frames_path, @errorName(e) });
    defer gpa.free(frames);
    checkFace(frames_path, &jrpc.frames_face, frames);

    // —— 对面十一：`extension.js` 的 LSP 方法名族十一员（第 218 轮 D86）。服务端 dispatch
    //   十臂与写侧 publishDiagnostics 同客户端十一处发起/消费面此前互不引用，守卫 214–217
    //   核过图例/标识/接线/帧形而从未核方法词——t2 探针 P1–P4 四路 js 侧改名 571/571 全绿
    //   静默，真跑 P7 坐实漂形 didSave 不发诊断且零应答：功能级断裂而构建链恒绿。
    //   本片复用对面四已读的 ext（零新增 I/O），按 hub needle 清单逐字节对账。
    checkFace(ext_path, &lsp_srv.methods_face, ext);

    // —— 对面十二：`extension.js` 的 LSP 消息本体键族（第 220 轮 D88）。服务端解析臂
    //   （method/params/textDocument/uri/text/contentChanges/position/line/character）与写侧
    //   （jsonrpc/id/result/diagnostics）键词同客户端九处书写形此前互不引用，守卫 214–218
    //   核过图例/标识/接线/帧形/方法词而从未核参数键——t2 探针 P1–P3 三路 js 侧改键
    //   575/575 全绿静默，真跑 P4 坐实漂形文档不入表：诊断/悬停全空而构建链恒绿。
    //   本片同样复用对面四已读的 ext（零新增 I/O）。
    checkFace(ext_path, &lsp_srv.params_face, ext);

    // —— 对面十三：`extension.js` 的 LSP 结果体字段族（第 221 轮 D89）。写侧诊断项/
    //   悬停/错误对象字段词（range/severity/source/message/contents/kind/value/code ＋
    //   markdown 值）同客户端八处属性读此前互不引用，守卫 214–220 核过帧形/方法词/
    //   参数键而从未核结果体字段——t2 探针 P1–P4 四路 js 侧改字段全绿静默、P6 写侧
    //   kind 漂连测面亦零锚：诊断波浪线/悬停渲染静默熄灭而构建链恒绿。本片同样复用
    //   对面四已读的 ext（零新增 I/O）。
    checkFace(ext_path, &lsp_srv.results_face, ext);
    // —— 对面十四：`extension.js` 的 severity 码值映射面（第 222 轮 D90）。js `sev()`
    // 四支硬编数值同 src clamp 界／快路恒码互为跨侧手抄、守卫从未核码值语义——
    // 漂即诊断分级静默错色，四枚 needle 数值全由 `sv_*` 派生。
    checkFace(ext_path, &lsp_srv.sv_face, ext);
    // —— 对面十五：`extension.js` 的 JSON-RPC 错误码应答面（第 223 轮 D91）。js 对
    //   服务端发起请求应答臂手抄 -32601 同 src 写侧三臂码值、守卫从未核错误码——
    //   漂即协议错误语义跨侧塌陷，needle 数值由 `ec_*` 派生（t2 P1 静默面）。
    checkFace(ext_path, &lsp_srv.errors_face, ext);

    // —— 对面十六：`src/main.zig` 的工具链 spawn argv 委派形（第 224 轮 D92）。五处活路径 13 处
    //   旧各自持字面量，守卫 1–15 面对象皆 editors/build.zig 文件词从未核 zig argv——
    //   t2 探针 P1–P7 七路词漂 583/583 全绿静默、真跑坐实 `unknown command: build-exx` 断裂。
    //   本步读 main.zig 文本验委派形在位（消费侧改回手抄字面量即红）；频次全等钉另由
    //   224 T0 在测试图内以 @embedFile 守（本面对账与测试图双向互备）。
    const main_path = if (args.len >= 7) args[6] else "src/main.zig";
    const main_txt = std.Io.Dir.cwd().readFileAlloc(io, main_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ main_path, @errorName(e) });
    defer gpa.free(main_txt);
    checkFace(main_path, &cli_hub.tl_face, main_txt);

    // —— 对面十六第二清单：`src/main.zig` 的 CLI 退码契约委派形（第 236 轮 D104）。
    //   usage=2／fail=1 此前全仓无共同真值：main 七处直接 `exit(2)` 臂与 bail 的
    //   `if (e == error.Usage) 2 else 1` 各抄字面量——`process.exit` 系 noreturn、`zig build test`
    //   门内不可观测，t2 探针漂 bail/裸 exit 皆 fresh 609/609 全绿静默。本步读同一 main_txt
    //   （零新增 I/O）验委派形在位（消费侧改回手抄字面量即红）；频次全等钉另由 236 T0 反锚守。
    checkFace(main_path, &cli_hub.exit_code_face, main_txt);

    // —— 对面十七：`package.json` 的 problemMatcher pattern 字段映射五枚（第 225 轮 D93）。
    //   「file/location/column/code/message 各取第几捕获组」与机读行段序（line_fmt 占位符序）同骨，
    //   而对面一只核 regexp 词、从不读这五枚数字——t2 探针 P1/P2/P3 改数字 fresh 585/585 全绿
    //   静默，活体消费模拟坐实面板字段串位（file 收到行号、code 收到消息本体）而构建链恒绿。
    //   本片复用对面一已读的 pkg（零新增 I/O），按 hub 派生 needle 清单逐字节对账。
    checkFace(pkg_path, &mcon.pattern_face, pkg);

    // —— 对面十八：`tools/check-demos.ps1` 的 CI e2e 基线脚本命令词族（第 226 轮 D94）。
    //   该脚本以 PowerShell 字面量直敲 zzc 子命令/旗标/落盘路径——hub 真值在其上持第二份
    //   手抄，而 ps1 非测图 source dep、不在旧 addFileArg 清单，且 GitCode 不跑 Actions
    //   （D17）＋本机 NO_PWSH 双盲——t2 探针 P1–P4 四路字面漂 fresh 587/587 全绿静默，
    //   漂移即基线防线错红/清理静默漏删（D81 漏员判例）。本步按 hub 派生 needle 逐字节对账。
    const ps1_path = if (args.len >= 8) args[7] else "tools/check-demos.ps1";
    const ps1_txt = std.Io.Dir.cwd().readFileAlloc(io, ps1_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ ps1_path, @errorName(e) });
    defer gpa.free(ps1_txt);
    checkFace(ps1_path, &cli_hub.ps1_face, ps1_txt);

    // —— 对面十八第二清单：`tools/check-demos.ps1` 的码点构造文案断言族（第 227 轮 D95）。
    //   脚本为保持纯 ASCII 以 `Native 0x…` 码点形内嵌 21 处中文文案断言——src 出口文案的
    //   第二份手抄，码点形绕过第 226 轮字面量普查；t2 探针 P1 src 文案漂／P2 ps1 码点漂
    //   双路 fresh 589/589 全绿静默。本步读同一 ps1 文本（零新增 I/O）按 hub 派生码点 needle 对账。
    checkFace(ps1_path, &cli_hub.ps1_native_face, ps1_txt);

    // —— 对面十八第三清单：`tools/check-demos.ps1` 的 usage 错退码断言（第 236 轮 D104）。
    //   脚本以 PowerShell 字面量 `ExitCode -ne 2` 断言同一退码契约（≥7 处），ps1 非测图
    //   source dep＋本机 NO_PWSH 双盲——漂 usage_exit_code 或 ps1 断言即外部基线对契约失保。
    //   needle 由 hub `usage_exit_code` comptime 派生（承 D94 presence 形制），读同一 ps1_txt 对账。
    checkFace(ps1_path, &cli_hub.exit_code_ps1_face, ps1_txt);

    // —— 对面十九：编辑器注释标记族（第 229 轮 D97）。`language-configuration.json` 的注释声明
    //   （lineComment/blockComment/折叠起止）与 `zz.tmLanguage.json` 的注释高亮正则互为同一词形
    //   的两份手抄，前者既非 source dep 也不在任何对面——t2 探针 P1 实锤改 `//`→`##`、`/*`→`<<`
    //   fresh 592/592 全绿静默。本步以 hub 派生四/二 枚 needle 同时对两文件逐字节对账：
    //   任一侧漂即红，两面同时命中即互洽（同源传递）。
    const langconf_path = if (args.len >= 9) args[8] else "editors/vscode/language-configuration.json";
    const tm_path = if (args.len >= 10) args[9] else "editors/vscode/syntaxes/zz.tmLanguage.json";
    const langconf = std.Io.Dir.cwd().readFileAlloc(io, langconf_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ langconf_path, @errorName(e) });
    defer gpa.free(langconf);
    const tm_txt = std.Io.Dir.cwd().readFileAlloc(io, tm_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ tm_path, @errorName(e) });
    defer gpa.free(tm_txt);
    checkFace(langconf_path, &lid.langconf_face, langconf);
    checkFace(tm_path, &lid.tm_face, tm_txt);

    // —— 对面二十：`tools/check-demos.ps1` 的 LSP initialize capability 协商形串族（第 230 轮 D98）。
    //   服务端 `initialize` 应答声明的 capability 对象形串（textDocumentSync 对象形／hoverProvider／
    //   semanticTokensProvider）在写侧 server.zig 应答字面、服务端自测 indexOf 钉、e2e 基线 ps1 的
    //   Contains 断言三处各持一份手抄——守卫对面十八／十九只核 ps1 命令词族与码点文案族，从未核这些
    //   JSON capability 形串；ps1 属双盲防线（NO_PWSH＋GitCode 不跑·D17）。t2 探针 P1 独漂 ps1 断言
    //   fresh 593/593 全绿静默、P3 写侧＋自测同步演进而 ps1 落单亦全绿静默（writer↔consumer 脱钩无信号）。
    //   本步以 hub 派生三枚 needle 复用对面十八已读的 ps1 实文逐字节对账（零新增 I/O）：写侧应答形串与
    //   ps1 Contains 断言同源，一侧漂形即分道转锚。serverInfo ps1 零消费不入针（如实登册）。
    checkFace(ps1_path, &lsp_srv.cap_face, ps1_txt);

    // —— 对面二十二：`tools/check-demos.ps1` 内嵌 LSP 帧协议词族（第 245 轮 D113）。脚本以
    //   JSON 帧字面量向 zzc lsp 发起八方法、并携 `"jsonrpc":"2.0"` 与 `"languageId":"zig-dialect"`——
    //   此系协议词汇的第三处手抄（server.zig m_*/jsonrpc.version_value/lang_identity.language_id 写侧单源
    //   + extension.js 已收对面十一/十二/二十）。D94 ps1_face 只核命令词/路径/旗标、D98 cap_face 只核
    //   capability 断言形串——皆从不核帧内 method 词/版本值/语言 id；ps1 非测图 source dep＋本机 NO_PWSH
    //   ＋GitCode 不跑 Actions 双盲。t2 探针独漂 ps1 帧方法词 fresh 633/633 全绿静默、活体喂漂形帧 init2
    //   予真 lsp → -32601 零应答坐实握手失联。本步以 hub 派生十枚 needle 复用对面十八已读 ps1 实文逐字节对账。
    checkFace(ps1_path, &lsp_srv.ps1_frame_face, ps1_txt);

    // —— 对面二十一：`build.zig` 的内置默认包 `addFileArg` 路径（第 238 轮 D106）。`build.zig` 系构建脚本
    //   独立编译单元、无法 `@import` hub，两枚 `addFileArg(b.path("src/lang/packs/中文.txt"))` 是内置默认包
    //   文件名的一份跨文件手抄；t2 探针 P3 实锤 `gen-*-main` emit 缺省包路径漂移而 CI 不可见绿。本面 needle
    //   由 `paths.builtin_pack_cwd_rel` 派生，复用本步早先已读的 build（D78 已 addFileArg build.zig·零新增 I/O）。
    checkFace(build_path, &paths.build_pack_face, build);

    std.debug.print(
        "OK: {s}／{s} 与机读契约同源，{s} 产出的 CLI exe 名 =「{s}」（正则同骨、示例命令 =「{s}」），且 {s} 客户端图例与 LSP 语义图例同源、语言标识族十一/一/一 枚 needle 在清单／客户端／示例三面皆命中、LSP 客户端接线族三/七 枚 needle 在清单／客户端两面皆命中、协议帧族五 枚 needle 在帧客户端面命中、方法名族十一 枚 needle 在客户端面命中、消息本体键族九 枚 needle 在客户端面命中、结果字段族八 枚 needle 在客户端面命中、严重度码值族四 枚 needle 在客户端映射面命中、错误码族一 枚 needle 在客户端应答面命中、工具链词族七 枚委派形 needle 在 {s} 消费面命中、pattern 字段映射族五 枚 needle 在清单面对账命中、ps1 命令词族十七 枚 needle 在 e2e 基线脚本 {s} 面命中、ps1 码点文案断言族廿一 枚 needle 在同面对账命中、注释标记族四/二 枚 needle 在 {s} 声明面与 {s} 生成物面各自对账命中、LSP capability 协商形串族三 枚 needle 在 e2e 基线脚本 {s} 面命中、ps1 内嵌 LSP 帧协议词族十 枚 needle 在同面逐字节对账命中、build.zig 内置默认包 addFileArg 路径一枚 needle 与 hub 同源\n",
        .{ pkg_path, tasks_path, build_path, paths.prog_name, mcon.tasks_command, ext_path, main_path, ps1_path, langconf_path, tm_path, ps1_path },
    );
}
