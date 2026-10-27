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
const vsix_hub = @import("zzc_core").vsix; // 第 292 轮 D151：本机 VSIX 产物 ↔ 源树逐员 CRC 对账的读侧判据
const pack_hub = @import("zzc_core").Pack; // 第 294 轮 D153：对照表 ↔ 内置默认包两段映射的双向判据（eachKwRow/auditKwTable）与两面对 needle

/// 一面（needle 清单）逐字节对账：命中不足即分道退出。判据（needle／后果／应现枚数 `occ`）全在 hub，
/// 本函数只做「在已读入的对面文本里按枚计数」与退出码——守 203/210/214 轮「判据入 hub、守卫只做 I/O」形制。
/// `face` 取 anytype：215/216 两 hub 各自声明同形制 FaceCheck（Zig struct 名义类型互不兼容），
/// 而搜索判据 `lid.countOccurrences` 与旧 `lcfg.missing` 语义在 `occ == 1` 时逐字节等价（计数 0 ⟺ indexOf 落空），
/// 不另立第三套；对无 `occ` 字段的 hub FaceCheck 以 `@hasField` 回落 `occ = 1`（presence 语义不变）。
/// —— 面针名实闸（第 323 轮 D182）：322 轮的元判据只审 `cli.args` 两表（21 枚），其余 7 个 hub 的 62 张
/// 表零名实闸，且 `lsp_config.FaceCheck`／`machine_contract.PatternFace` 两族缺 `occ` 字段（守卫靠
/// `@hasField` 静默回落只看「在不在」）。本段把闸铺到全部 9 hub／64 表，判据本体全在 hub
/// （`paths.declaredAddrCount`），本处只遍历与报错。
const FaceAudit = struct {
    tables: usize = 0,
    pins: usize = 0,
    occ_multi: usize = 0, // 已收紧（occ>1）的枚数——收紧进展锚
    declared_multi: usize = 0, // 自称多址的枚数——须与 occ_multi 相等
};

/// 一枚一枚核：①面型必有 `occ` 字段（六族统一，禁回落）；②声明 N 址则 `occ == N`；③`occ > 1` 必声明。
fn auditTable(comptime table_name: []const u8, comptime face: anytype, a: *FaceAudit) void {
    a.tables += 1;
    inline for (face) |c| {
        a.pins += 1;
        const has_occ = @hasField(@TypeOf(c), "occ");
        if (!has_occ) fail(
            "FAIL: 面型缺 occ 字段——{s}／「{s}」：六族面型须统一，否则守卫静默回落只看存在性\n",
            .{ table_name, c.needle },
        );
        const occ: usize = if (has_occ) c.occ else 1;
        if (occ > 1) a.occ_multi += 1;
        if (paths.declaredAddrCount(c.why)) |n| {
            a.declared_multi += 1;
            if (occ != n) fail(
                "FAIL: 名实不符 {s}／「{s}」——.why 声明 {d} 址而 occ={d}\n",
                .{ table_name, c.needle, n, occ },
            );
        } else if (occ > 1) {
            fail(
                "FAIL: 声称多址而未声明 {s}／「{s}」occ={d}——.why 须写明「N 址」\n",
                .{ table_name, c.needle, occ },
            );
        }
    }
}

/// 清单覆盖闸（第 323 轮 D182）：本清单审到的每 hub 表数必须等于手抄基数——而「hub 新增/删除
/// `*_face` 表」由 `src/zzc_paths.zig` 的 323 T0 用 `@embedFile` 自嵌源码统计并对拍同一批数字
/// （彼处属 `src/` 包路径内，合法；本 exe 的包路径是 `src/check/`，`@embedFile` 越界会编译拒）。
/// 两侧同一批数字＝双源手抄：hub 添表只顾一侧即红，清单漏抄不再静默。
fn expectTableCount(comptime src_path: []const u8, expected: usize, seen: usize) void {
    if (expected != seen) fail(
        "FAIL: 面表清单漏表——{s} 应有 {d} 张 `*_face` 表，本清单只审 {d} 张：漏抄即该表零名实闸\n",
        .{ src_path, expected, seen },
    );
}

fn auditAllFaces() void {
    var a: FaceAudit = .{};
    var seen_cli: usize = 0;
    var seen_paths: usize = 0;
    var seen_lsp_srv: usize = 0;
    var seen_lcfg: usize = 0;
    var seen_lid: usize = 0;
    var seen_vsix: usize = 0;
    var seen_pack: usize = 0;
    var seen_jrpc: usize = 0;
    var seen_mcon: usize = 0;
    auditTable("cli.help_main_face", cli_hub.help_main_face, &a);
    seen_cli += 1;
    auditTable("cli.readme_flag_face", cli_hub.readme_flag_face, &a);
    seen_cli += 1;
    auditTable("cli.plan_flag_face", cli_hub.plan_flag_face, &a);
    seen_cli += 1;
    auditTable("cli.contrib_flag_face", cli_hub.contrib_flag_face, &a);
    seen_cli += 1;
    auditTable("cli.agents_cmd_face", cli_hub.agents_cmd_face, &a);
    seen_cli += 1;
    auditTable("cli.agents_flag_face", cli_hub.agents_flag_face, &a);
    seen_cli += 1;
    auditTable("cli.pure_native_smoke_face", cli_hub.pure_native_smoke_face, &a);
    seen_cli += 1;
    auditTable("cli.lang_axis_face", cli_hub.lang_axis_face, &a);
    seen_cli += 1;
    auditTable("cli.flag_arity_face", cli_hub.flag_arity_face, &a);
    seen_cli += 1;
    auditTable("cli.subcmd_face", cli_hub.subcmd_face, &a);
    seen_cli += 1;
    auditTable("cli.overlay_name_face", cli_hub.overlay_name_face, &a);
    seen_cli += 1;
    auditTable("cli.lang_verb_face", cli_hub.lang_verb_face, &a);
    seen_cli += 1;
    auditTable("cli.lang_remove_face", cli_hub.lang_remove_face, &a);
    seen_cli += 1;
    auditTable("cli.overlay_smoke_face", cli_hub.overlay_smoke_face, &a);
    seen_cli += 1;
    auditTable("cli.lang_list_face", cli_hub.lang_list_face, &a);
    seen_cli += 1;
    auditTable("cli.lang_add_face", cli_hub.lang_add_face, &a);
    seen_cli += 1;
    auditTable("cli.overlay_pack_face", cli_hub.overlay_pack_face, &a);
    seen_cli += 1;
    auditTable("cli.tl_face", cli_hub.tl_face, &a);
    seen_cli += 1;
    auditTable("cli.exit_code_face", cli_hub.exit_code_face, &a);
    seen_cli += 1;
    auditTable("cli.exit_code_ps1_face", cli_hub.exit_code_ps1_face, &a);
    seen_cli += 1;
    auditTable("cli.ps1_face", cli_hub.ps1_face, &a);
    seen_cli += 1;
    auditTable("cli.version_main_face", cli_hub.version_main_face, &a);
    seen_cli += 1;
    auditTable("cli.readme_cmd_face", cli_hub.readme_cmd_face, &a);
    seen_cli += 1;
    auditTable("cli.book_cmd_face", cli_hub.book_cmd_face, &a);
    seen_cli += 1;
    auditTable("cli.ps1_native_face", cli_hub.ps1_native_face, &a);
    seen_cli += 1;
    auditTable("paths.build_pack_face", paths.build_pack_face, &a);
    seen_paths += 1;
    auditTable("paths.readme_face", paths.readme_face, &a);
    seen_paths += 1;
    auditTable("paths.readme_build_face", paths.readme_build_face, &a);
    seen_paths += 1;
    auditTable("paths.doc38_build_face", paths.doc38_build_face, &a);
    seen_paths += 1;
    auditTable("paths.doc41_build_face", paths.doc41_build_face, &a);
    seen_paths += 1;
    auditTable("paths.doc42_build_face", paths.doc42_build_face, &a);
    seen_paths += 1;
    auditTable("paths.demos_smoke_face", paths.demos_smoke_face, &a);
    seen_paths += 1;
    auditTable("paths.demos_smoke_count_face", paths.demos_smoke_count_face, &a);
    seen_paths += 1;
    auditTable("paths.doc45_build_face", paths.doc45_build_face, &a);
    seen_paths += 1;
    auditTable("paths.lang_smoke_face", paths.lang_smoke_face, &a);
    seen_paths += 1;
    auditTable("paths.demos_build_face", paths.demos_build_face, &a);
    seen_paths += 1;
    auditTable("paths.ci_tools_face", paths.ci_tools_face, &a);
    seen_paths += 1;
    auditTable("paths.ci_build_face", paths.ci_build_face, &a);
    seen_paths += 1;
    auditTable("paths.github_ci_build_face", paths.github_ci_build_face, &a); // 第 334 轮 D193：镜像面两枚步名限定针
    seen_paths += 1;
    auditTable("paths.github_release_face", paths.github_release_face, &a); // 第 335 轮 D194：发布面四针（触发/权限/出口/打包器）
    seen_paths += 1;
    auditTable("paths.diag_corpus_face", paths.diag_corpus_face, &a); // 第 336 轮 D195：语料面两针（条数锚／语料根）
    seen_paths += 1;
    auditTable("paths.diag_corpus_build_face", paths.diag_corpus_build_face, &a); // 第 336 轮 D195：回放器 build 侧依赖针
    seen_paths += 1;
    auditTable("paths.entry_root_face", paths.entry_root_face, &a); // 第 337 轮 D196：工程根解析委派四针
    seen_paths += 1;
    auditTable("paths.probe_face", paths.probe_face, &a); // 第 347 轮 D206：深检探针臂路径名委派一针
    seen_paths += 1;
    auditTable("paths.license_face", paths.license_face, &a); // 第 338 轮 D197：许可证正文四针（署名派生 + MIT 三句）
    seen_paths += 1;
    auditTable("paths.license_readme_face", paths.license_readme_face, &a); // 第 338 轮 D197：README 链接形一针
    seen_paths += 1;
    auditTable("paths.license_pkg_face", paths.license_pkg_face, &a); // 第 338 轮 D197：扩展清单 license 字段一针
    seen_paths += 1;
    auditTable("paths.license_zon_face", paths.license_zon_face, &a); // 第 338 轮 D197：包清单收录一针
    seen_paths += 1;
    auditTable("paths.upstream_watch_face", paths.upstream_watch_face, &a); // 第 339 轮 D198：周检脚本四针（版本源/标记/回放器/钉版来源）
    seen_paths += 1;
    auditTable("paths.upstream_watch_yml_face", paths.upstream_watch_yml_face, &a); // 第 339 轮 D198：workflow 三针（周频/取版/本体）
    seen_paths += 1;
    auditTable("paths.upstream_watch_build_face", paths.upstream_watch_build_face, &a); // 第 339 轮 D198：两面 build 侧依赖针
    seen_paths += 1;
    auditTable("paths.metric_build_face", paths.metric_build_face, &a); // 第 340 轮 D199：测映闸／基准两步步名钩子针
    seen_paths += 1;
    auditTable("paths.book_demo_face", paths.book_demo_face, &a);
    seen_paths += 1;
    auditTable("paths.bookdemo_build_face", paths.bookdemo_build_face, &a);
    seen_paths += 1;
    auditTable("paths.book_prog_face", paths.book_prog_face, &a); // 第 346 轮 D205：逐块闸读两枚文档路径（occ 取表内该文件块数）
    seen_paths += 1;
    auditTable("paths.book_prog_count_face", paths.book_prog_count_face, &a); // 第 346 轮 D205：块数锚＋认块标记两针
    seen_paths += 1;
    auditTable("paths.book_prog_build_face", paths.book_prog_build_face, &a); // 第 346 轮 D205：闸脚本对 matcher 步的 addFileArg 针
    seen_paths += 1;
    auditTable("lsp_srv.methods_face", lsp_srv.methods_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.cap_face", lsp_srv.cap_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.ps1_frame_face", lsp_srv.ps1_frame_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.smoke_frame_face", lsp_srv.smoke_frame_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.smoke_cap_face", lsp_srv.smoke_cap_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.smoke_js_cap_face", lsp_srv.smoke_js_cap_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.smoke_js_provider_face", lsp_srv.smoke_js_provider_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.params_face", lsp_srv.params_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.results_face", lsp_srv.results_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.kinds_smoke_face", lsp_srv.kinds_smoke_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.sv_face", lsp_srv.sv_face, &a);
    seen_lsp_srv += 1;
    auditTable("lsp_srv.errors_face", lsp_srv.errors_face, &a);
    seen_lsp_srv += 1;
    auditTable("lcfg.pkg_face", lcfg.pkg_face, &a);
    seen_lcfg += 1;
    auditTable("lcfg.ext_readme_cfg_face", lcfg.ext_readme_cfg_face, &a);
    seen_lcfg += 1;
    auditTable("lcfg.client_face", lcfg.client_face, &a);
    seen_lcfg += 1;
    auditTable("lcfg.log_writer_face", lcfg.log_writer_face, &a);
    seen_lcfg += 1;
    auditTable("lcfg.log_assert_face", lcfg.log_assert_face, &a);
    seen_lcfg += 1;
    auditTable("lid.langconf_face", lid.langconf_face, &a);
    seen_lid += 1;
    auditTable("lid.tm_face", lid.tm_face, &a);
    seen_lid += 1;
    auditTable("lid.pkg_face", lid.pkg_face, &a);
    seen_lid += 1;
    auditTable("lid.client_face", lid.client_face, &a);
    seen_lid += 1;
    auditTable("lid.tasks_face", lid.tasks_face, &a);
    seen_lid += 1;
    auditTable("vsix.pack_face", vsix_hub.pack_face, &a);
    seen_vsix += 1;
    auditTable("pack.kwtable_build_face", pack_hub.kwtable_build_face, &a);
    seen_pack += 1;
    auditTable("pack.kwtable_pack_face", pack_hub.kwtable_pack_face, &a);
    seen_pack += 1;
    auditTable("pack.bookdict_build_face", pack_hub.bookdict_build_face, &a);
    seen_pack += 1;
    auditTable("pack.bookdict_book_face", pack_hub.bookdict_book_face, &a);
    seen_pack += 1;
    auditTable("jrpc.frames_face", jrpc.frames_face, &a);
    seen_jrpc += 1;
    auditTable("mcon.pattern_face", mcon.pattern_face, &a);
    seen_mcon += 1;
    // 第 324 轮 D183：`.count` 形三张已收编为 `occ`（`tl_face`／`exit_code_face`／`version_main_face`），
    // 豁免登记撤销、全 20 表一律入闸——此前 matcher 侧 `checkFace` 只读 `occ` 并回落 1，声明「九处/两处」
    // 的针在真跑对账里只被要求 1 枚（测试图按 count 精确、守卫步却宽松，两套语义）。
    expectTableCount("src/cli/args.zig", 25, seen_cli);
    expectTableCount("src/zzc_paths.zig", 32, seen_paths); // 第 347 轮 D206：31→32（深检探针臂 probe_face）
    expectTableCount("src/lsp/server.zig", 12, seen_lsp_srv);
    expectTableCount("src/editor/lsp_config.zig", 5, seen_lcfg);
    expectTableCount("src/editor/lang_identity.zig", 5, seen_lid);
    expectTableCount("src/vsix.zig", 1, seen_vsix);
    expectTableCount("src/lang/pack.zig", 4, seen_pack);
    expectTableCount("src/lsp/jsonrpc.zig", 1, seen_jrpc);
    expectTableCount("src/machine_contract.zig", 1, seen_mcon);
    if (a.declared_multi != a.occ_multi) fail(
        "FAIL: 名实总分道——自称多址 {d} 枚而已收紧 {d} 枚\n",
        .{ a.declared_multi, a.occ_multi },
    );
    std.debug.print(
        "面针名实普查：9 hub / {d} 表 / {d} 针，已收紧（occ>1）{d} 枚，自称址数 {d} 枚，全部名实相符\n",
        .{ a.tables, a.pins, a.occ_multi, a.declared_multi },
    );
}

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

/// 扫 `dir` 里是否存在**任何** `.vsix`（含异名旧包）；无目录或不可读一律视作「没有」。
fn findAnyVsix(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]const u8 {
    var rd = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer rd.close(io);
    var walker = rd.walk(gpa) catch return null;
    defer walker.deinit();
    var found: ?[]const u8 = null;
    while (walker.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.basename, vsix_hub.skip_suffix)) {
            found = gpa.dupe(u8, e.basename) catch found;
        }
    }
    return found;
}

/// 对面二十八·本机 VSIX 产物对账（第 292 轮 D151）。判据（ZIP 中央目录布局、`extension/` 前缀族、
/// 成员下限、CRC-32 真值）全在 `src/vsix.zig` 并由 292 T0 以小样钉住；本函数只做 I/O：由已读入的
/// `package.json` 文本组包名、读包字节、逐员读盘上同名文件比哈希。期望包缺席时：目录里一个包都没有
/// 即**显式**打一行跳过文案（CI 与新克隆无 python、无包），若另有异名旧包即红（版本已漂而包未重打，
/// 装进宿主的仍是旧码）。包存在而任一成员与源树 CRC 不等即红——本轮实锤的空转防线：三门禁全绿而
/// `extension.js` 在包里仍是缺 D149 换算的旧码。
fn auditVsix(gpa: std.mem.Allocator, io: std.Io, pkg_path: []const u8, pkg: []const u8) void {
    const name = (jsonStringValue(pkg, "name", 0) orelse
        fail("FAIL: {s} 里找不到 \"name\"——VSIX 产物面无从组包名。\n", .{pkg_path})).val;
    const version = (jsonStringValue(pkg, "version", 0) orelse
        fail("FAIL: {s} 里找不到 \"version\"——VSIX 产物面无从组包名。\n", .{pkg_path})).val;
    const dir = std.fs.path.dirname(pkg_path) orelse ".";
    const vname = vsix_hub.vsixNameFor(gpa, name, version) catch
        fail("FAIL: 组 VSIX 包名失败。\n", .{});
    const vpath = std.fs.path.join(gpa, &.{ dir, vname }) catch
        fail("FAIL: 拼 VSIX 包路径失败。\n", .{});

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, vpath, gpa, .unlimited) catch {
        if (findAnyVsix(gpa, io, dir)) |other| {
            fail(
                "FAIL: 期望的包 {s} 不存在，而 {s} 里另有旧包「{s}」——版本已漂而包未重打，装进宿主的仍是旧码。\n",
                .{ vpath, dir, other },
            );
        }
        std.debug.print("NOTE: {s} 未打包——跳过产物对账（需要本机包时跑：python3 tools/build-vsix.py）\n", .{vpath});
        return;
    };

    const opened = vsix_hub.Dir.open(bytes) catch |e| fail(
        "FAIL: {s} 中央目录不可读（{s}）——包体非 zip 或已截断，请重新打包。\n",
        .{ vpath, @errorName(e) },
    );
    var it = opened orelse fail("FAIL: {s} 中央目录零条目——包体空转，请重新打包。\n", .{vpath});

    var checked: usize = 0;
    var total: usize = 0;
    while (it.next() catch |e| fail(
        "FAIL: {s} 逐员解析中断（{s}）——包体结构与 ZIP 布局分道，请重新打包。\n",
        .{ vpath, @errorName(e) },
    )) |ent| {
        total += 1;
        const rel = ent.diskRel() orelse continue; // 打包器现生成的包根件（盘上无同名源）不核
        const dpath = std.fs.path.join(gpa, &.{ dir, rel }) catch
            fail("FAIL: 拼盘上源路径失败。\n", .{});
        const srcb = std.Io.Dir.cwd().readFileAlloc(io, dpath, gpa, .unlimited) catch |e| fail(
            "FAIL: 包内成员「{s}」在盘上无同名源（{s}）——文件树与包已分道，请重新打包。\n",
            .{ rel, @errorName(e) },
        );
        const crc = vsix_hub.crcOf(srcb);
        if (crc != ent.crc or srcb.len != ent.size) fail(
            "FAIL: 包内「{s}」与盘上源不同步（包内 0x{x}/{d} 字节，盘上 0x{x}/{d} 字节）" ++
                "——源已漂而包未重打，装进宿主的仍是旧码，请跑 python3 tools/build-vsix.py。\n",
            .{ rel, ent.crc, ent.size, crc, srcb.len },
        );
        checked += 1;
    }
    if (checked < vsix_hub.member_floor) fail(
        "FAIL: {s} 可核成员仅 {d} 枚，低于 hub 下限 {d} 枚（共 {d} 条目）——打包器漏员或前缀族改形。\n",
        .{ vpath, checked, vsix_hub.member_floor, total },
    );
    std.debug.print("OK: {s} 与源树逐字节同源（{d} 枚成员 CRC 对账，hub 下限 {d}）\n", .{ vpath, checked, vsix_hub.member_floor });
}

fn fail(comptime msg: []const u8, args: anytype) noreturn {
    std.debug.print(msg, args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);

    // 面针名实闸先行：与对面文本无关，全表一次跑完（红即退，早于任何文件读取）。
    auditAllFaces();

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

    // —— 对面十一：`extension.js` 的 LSP 方法名族二十三员（第 218 轮 D86，第 279 轮随 completion 增员）。服务端 dispatch
    //   二十二臂与写侧 publishDiagnostics 同客户端二十三处发起/消费面此前互不引用，守卫 214–217
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

    // —— 对面十六第三清单：`src/main.zig` 的工程根解析委派形（第 337 轮 D196）。
    //   `pickEntry` 只认 `.zz`，其余实参被静默无视并回落缺省入口：`zzc check demo/hello` 报的是
    //   「目录 `src` 下未找到」——报错路径与用户给的路径毫不相干（复用本面已读的 main_txt，零新增 I/O）。
    checkFace(main_path, &paths.entry_root_face, main_txt);

    // —— 对面十六第四清单：`src/main.zig` 的深检探针臂路径名委派形（第 347 轮 D206）。
    //   探针副本名须由 hub 的 `probe_file_prefix` 拼出、落 `.zzc/` 树内方能被 isInternalPath 隐藏其
    //   自身形制错；消费侧改回手抄 `.zzc_probe` 即本面红（复用本面已读的 main_txt，零新增 I/O）。
    checkFace(main_path, &paths.probe_face, main_txt);

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

    // —— 对面十八第四清单：`tools/check-demos.ps1` 客户端节对 `extension.js` 的 Contains 针族
    //   （第 280 轮 D138）。ps1 以 `$extSrc.Contains("<js 书写形>")` 手抄客户端实文第三面（对面
    //   十一／十二／十三只核 hub 派生 needle，从不反向核脚本自写的 js 形），而该节只在 Windows
    //   PowerShell 跑——本机 NO_PWSH＋GitCode 不执行 Actions（D17 在册）双盲：第 279 轮人工普查
    //   坐实两枚针早与 js 分道（D136 拆 spawn 形、signatureHelp 用赋值形），pwsh 下必假红、Linux
    //   上零信号。判据（抽取/极性/引号折叠）全在 hub，本步复用对面四与十八已读的 ext 与 ps1_txt
    //   （零新增 I/O），只按非空漂移清单出报告并退码。
    const pin_audit = cli_hub.jsPinAudit(gpa, ps1_txt, ext) catch |e|
        fail("FAIL: {s} 客户端针族抽取失败（{s}）——脚本形制超出抽取面，须人工复核。\n", .{ ps1_path, @errorName(e) });
    var pin_stats: [48]u8 = undefined;
    const pin_word = std.fmt.bufPrint(&pin_stats, "{d} 枚（{d} 正向／{d} 反向）", .{ pin_audit.total, pin_audit.positive, pin_audit.total - pin_audit.positive }) catch "针族";
    if (pin_audit.drifts.len != 0) {
        for (pin_audit.drifts) |p| {
            std.debug.print(
                "  [DRIFT] {s}: $extSrc.Contains(\"{s}\")\n",
                .{ if (p.positive) "正向针落空（js 已不写此形 → ps1 必假红）" else "反向针泄漏（js 已写回此串 → ps1 必假红）", p.raw },
            );
        }
        fail(
            "FAIL: {s} 客户端节对 {s} 的 Contains 针有 {d} 枚分道——要么把脚本针改回当前 js 书写形，" ++
                "要么恢复 js 侧写法；两侧同改亦须在此会齐（第 280 轮 D138）。\n",
            .{ ps1_path, ext_path, pin_audit.drifts.len },
        );
    }

    // —— 对面二十三：`tools/lsp-live-smoke.sh` 的帧协议词族与 capability 断言族（第 281 轮 D139）。
    //   脚本以 JSON 帧字面量向 `zzc lsp` 发起十八方法、并逐枚 `grep -Fq` 断言 initialize 应答的十三枚
    //   capability 形串——协议词汇的第四处手抄（server.zig 单源／extension.js 客户端面／ps1 内嵌帧皆已收面）。
    //   脚本本身是运行时防线却不在 `zig build test` 门内，亦非测图 source dep：t2 探针 P1 实锤删掉
    //   completion 的 capability 断言一行，构建链 17/17 全绿且脚本自身仍 PASS（少一条断言不会失败）——
    //   覆盖静默消失的双零信号形（D94/D113 空转防线同族）。本步新增第二片脚本实文，按 hub 派生 needle
    //   逐枚对账：断言被删／被改松／服务端改词，皆当场红。
    const smoke_path = if (args.len >= 11) args[10] else paths.smoke_sh_path;
    const smoke_txt = std.Io.Dir.cwd().readFileAlloc(io, smoke_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ smoke_path, @errorName(e) });
    defer gpa.free(smoke_txt);
    checkFace(smoke_path, &lsp_srv.smoke_frame_face, smoke_txt);
    checkFace(smoke_path, &lsp_srv.smoke_cap_face, smoke_txt);

    // —— 对面二十四：客户端 e2e 冒烟 `tools/extension-smoke.js` 的断言条数锚与 capability 键名族
    //   （第 282 轮 D140／D141）。该套件是 extension.js 在 Linux 上唯一的端到端防线（CI 第 5) 步），
    //   而它的覆盖面就是「断言条数」本身：第 282 轮探针实锤——从 capability 键名数组删一枚
    //   'hoverProvider' 再删一条独立断言，`node tools/extension-smoke.js` 照旧报 `PASS：87 项断言全过`
    //   退 0，且 `zig build test` 17/17 全绿（运行时与构建链双静默，D139 同族）。修形为三道门：
    //   js 内条数锚声明（数字由 hub 的 smoke_js_floor comptime 派生）＋ 精确等号退坡闸 ＋ 本步跨侧对账；
    //   另按 cap_* 单源抽取键名段，逐枚钉住 js 的 provider 核验集（服务端改 provider 而 js 少验即红）。
    const esm_path = if (args.len >= 12) args[11] else paths.esm_js_path;
    // 第 292 轮 D151：打包器 `tools/build-vsix.py` 的命名面（对面二十九）——包名/包内前缀/排除
    // 后缀三枚 needle 由 `vsix.zig` hub 派生，跨语言手抄一侧漂形即分道转锚。
    const pack_py_path = if (args.len >= 13) args[12] else "tools/build-vsix.py";
    const esm_txt = std.Io.Dir.cwd().readFileAlloc(io, esm_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ esm_path, @errorName(e) });
    defer gpa.free(esm_txt);
    checkFace(esm_path, &lsp_srv.smoke_js_cap_face, esm_txt);
    const js_anchor = cli_hub.jsAnchorOk(esm_txt);
    //   条数锚只拦「少一条」，此处再拦「断言还在而判据被掏空」（第 283 轮 D142）：`ok(true, …)` 形
    //   保住条数、不改 label、PASS 行一字不变，覆盖面却已归零——普查上限钉 0，一处即红。
    const taut_n = cli_hub.jsTautCount(esm_txt);
    if (taut_n > cli_hub.js_tautology_ceiling) {
        fail("FAIL: {s} 有 {d} 处恒真谓词「ok(true, …)」——条数锚保住而判据已被掏空，该条覆盖面归零（第 283 轮 D142）。须换成与被测状态同骨的实质表达式。\n", .{ esm_path, taut_n });
    }

    if (!js_anchor.decl or !js_anchor.guard) {
        fail("FAIL: {s} 的断言条数锚不完整（声明{s}／退坡闸{s}）——该套件的覆盖面就是断言条数本身，缺锚即可被静默拆条而仍报 PASS 退 0（第 282 轮 D140）。须同时具备「const EXPECT_CHECKS = {d};」与「if (checks !== EXPECT_CHECKS)」两形，且数值与 hub 真值同锚。\n", .{ esm_path, if (js_anchor.decl) "在" else "缺", if (js_anchor.guard) "在" else "缺", cli_hub.smoke_js_floor });
    }

    // —— 对面二十五：客户端日志文案族的两处手抄（第 284 轮 D143）。`extension.js` 的四条 appendLine
    //   提示与 `tools/extension-smoke.js` 断言它们的四枚针是同一句话的两份手抄（此前 hub 只锚了写侧
    //   就绪语一枚，断言侧四枚全无锚），而其中一枚是**反向针**：写侧改名即永真。t2 探针 P1 实锤——
    //   写侧漂 `帧解析错误`→`帧解码错误`：`node` 照旧 `PASS：89 项断言全过` 退 0 且 `zig build test`
    //   17/17 全绿（双静默）；第 283 轮的恒真闸只盯 `ok(true,` 形，抓不到这种「针漂致永真」的退化。
    //   两面文件皆已读过（零新增 I/O），按 hub 的 log_writer_face／log_assert_face 逐枚对账：
    //   任一侧漂文案、翻极性（删 `!`）、漂正则形（丢 `/g` 或全角改半角）皆当场红。
    checkFace(ext_path, &lcfg.log_writer_face, ext);
    checkFace(esm_path, &lcfg.log_assert_face, esm_txt);

    // —— 对面二十六：客户端 e2e 的 provider 注册核验族（第 285 轮 D144）。js 以
    //   `for (const name of ['hover', …]) ok(!!P[name], …)` 逐枚验客户端十三家 provider——这套短名是
    //   capability 键名的第二套词汇（对面二十四钉的是 'hoverProvider' 形串，本面钉 'hover' 形），旧无锚。
    //   两路探针实锤的静默形：P1 把 'completion' 顶替为重复的 'hover' → 条数 89 不变、`node` 退 0 且
    //   构建链全绿；P2 把判据去下标 `!!P[name]`→`!!P` → 十三枚注册断言全空转而仍逐枚打 `[ok] 已注册 provider：…`
    //   并 PASS 退 0（D142 的恒真闸只识别 `ok(true,` 形，此形字面上不是恒真）。名针由 cap_* 剥尾段派生，
    //   加循环头与判据体两枚形针；复用已读的 esm 实文，零新增 I/O。
    checkFace(esm_path, &lsp_srv.smoke_js_provider_face, esm_txt);

    // —— 对面二十七：客户端 e2e 的 kind 值域断言族（第 290 轮 D149）。LSP 的 SymbolKind／
    //   CompletionItemKind 以 1 起编而 vscode 同名枚举以 0 起编，两空间之间的换算此前在任何一面
    //   皆无锚：t2 探针 P1 实锤把大纲 kind 改成 `s.kind + 5` 时守卫与 e2e 一字不变（双静默），
    //   P2 实锤旧断言 `eq(decl.kind, 3)` 反把正确换算判为失败（断言把 bug 当预期钉住）。
    //   本面把宿主枚数锁到 hub（sk_*/ck_* 减 lsp_kind_base）并钉三处 provider 断言的落点形；
    //   客户端侧的换算调用形另由 results_face 三枚 needle 守（复用已读的 ext，零新增 I/O）。
    checkFace(esm_path, &lsp_srv.kinds_smoke_face, esm_txt);

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
    //   本步以 hub 派生十三枚 needle 复用对面十八已读的 ps1 实文逐字节对账（零新增 I/O）：写侧应答形串与
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

    // —— 对面二十九：打包器命名面（第 292 轮 D151）——
    const pack_py = std.Io.Dir.cwd().readFileAlloc(io, pack_py_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ pack_py_path, @errorName(e) });
    checkFace(pack_py_path, &vsix_hub.pack_face, pack_py);

    // —— 对面三十：`docs/关键字对照表.md` ↔ 内置默认包 `[keywords]`／`[aliases]` 的两侧手抄（第 294 轮 D153）。
    //   表是包内映射的第二份手抄，而**包自己的报错文案**（`未知标识符` 提示语）正把用户指向该表——
    //   表若过期，照表核对的人即核对到根本不存在的词。探针 P1 实锤：在真表上同时注入三形
    //   （值漂 `const`→`konst`、删整行 `如果 / 否则`、凭空加鬼词 `假键`），`zig fmt`／`zig build test`
    //   （17/17 succeeded）／本守卫三门禁一律零信号、退码皆 0。判据全在 `lang/pack.zig`
    //   （`eachKwRow` 抽取器＋`auditKwTable` 双向对拍，纯函数、零 I/O，294 T0 以合成小样钉住），
    //   本步只读两文件、调判据、按返回值退出——表在 `docs/` 越出模块包路径不可 embed（202 轮硬约束），
    //   故两文件皆须 addFileArg 声明为文件依赖（不声明则改一面不触发本步重跑＝203/210 轮假绿形制）。
    const kw_doc_path = if (args.len >= 14) args[13] else pack_hub.kwtable_path;
    const zh_pack_path = if (args.len >= 15) args[14] else paths.builtin_pack_cwd_rel;
    const kw_doc = std.Io.Dir.cwd().readFileAlloc(io, kw_doc_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ kw_doc_path, @errorName(e) });
    defer gpa.free(kw_doc);
    const zh_pack_txt = std.Io.Dir.cwd().readFileAlloc(io, zh_pack_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ zh_pack_path, @errorName(e) });
    defer gpa.free(zh_pack_txt);
    // 两面对：①`build.zig` 须按 hub 派生的路径串声明对照表的 addFileArg（改一侧即分道）；
    // ②包内指路文案须写 hub 词干（文案漂 → 用户被指向不存在的文件；文件改名 → 本步读不到文件）。
    checkFace(build_path, &pack_hub.kwtable_build_face, build);
    checkFace(zh_pack_path, &pack_hub.kwtable_pack_face, zh_pack_txt);
    var zh_pack = pack_hub.parse(gpa, zh_pack_txt) catch |e|
        fail("FAIL: 解析内置默认包 {s} 失败（{s}）\n", .{ zh_pack_path, @errorName(e) });
    defer zh_pack.deinit();
    const aud = pack_hub.auditKwTable(&zh_pack, kw_doc);
    if (aud.ghost != 0 or aud.wrong != 0 or aud.hidden != 0 or !aud.heading_hit or
        aud.alias_rows < pack_hub.kwtable_alias_floor or aud.kw_rows < zh_pack.keywords.count())
    {
        fail(
            "FAIL: {s} 与 {s} 的映射面分道——ghost={d}（表有包无，首个「{s}」）／wrong={d}（同名异值，首个「{s}」表={s} 包={s}）／hidden={d}（包有表无，首个「{s}」）；aliases 域抽出 {d} 行（独立手设下限 {d}）／keywords 域抽出 {d} 行（包内 {d} 枚）；域路由标题{s}。后果：母语关键字拼错的报错把用户指向本表核对，表若过期即核对到不存在的词（第 294 轮 D153）。判据见 `lang/pack.zig` 的 `auditKwTable`。\n",
            .{ kw_doc_path, zh_pack_path, aud.ghost, aud.first_ghost, aud.wrong, aud.first_wrong, aud.first_wrong_doc, aud.first_wrong_pack, aud.hidden, aud.first_hidden, aud.alias_rows, pack_hub.kwtable_alias_floor, aud.kw_rows, zh_pack.keywords.count(), if (aud.heading_hit) "命中" else "缺席" },
        );
    }

    // —— 对面三十一：书稿《字典篇》（`docs/母语编写zig-中文版.md`）↔ 内置默认包映射的**第三份手抄**（第 295 轮 D154）。
    //   该篇头注自称「想知道某个中文词……在这里按主题查」，故它对 `[keywords]` 是全量承诺；探针实测书稿
    //   只列 86/113 枚、缺 27 枚，而两条尾注点名「不透明类型／对齐／易变…均在词表中」「完整的 @ 族…均在包内
    //   词表」——被点名的十枚恰一枚都不在表内。实锤 P1：删「如果」整行、`const`→`konst`、凭空加鬼词「假键」
    //   三形同注，`zig fmt`／`zig build test`（17/17 succeeded）／本守卫三门禁一律零信号、退码皆 0。判据全在
    //   `lang/pack.zig`（`eachBookRow` 抽取器＋`auditBookDict` 对拍，纯函数、零 I/O，295 T0/T1 以合成小样钉住），
    //   本步只读书、调判据、按返回值退出；书在 `docs/` 不可 embed（202 轮硬约束），故亦须 addFileArg 声明。
    const book_arg = if (args.len >= 16) args[15] else pack_hub.book_path;
    const book_txt = std.Io.Dir.cwd().readFileAlloc(io, book_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ book_arg, @errorName(e) });
    defer gpa.free(book_txt);
    checkFace(build_path, &pack_hub.bookdict_build_face, build); // 书稿须经 addFileArg 声明为文件依赖
    checkFace(book_arg, &pack_hub.bookdict_book_face, book_txt); // 书稿五处指路皆须写 hub 词干
    const ba = pack_hub.auditBookDict(&zh_pack, book_txt);
    if (ba.ghost != 0 or ba.wrong != 0 or ba.hidden != 0 or ba.unpaired != 0 or !ba.heading_hit or
        ba.kw_rows < pack_hub.bookdict_kw_floor or ba.alias_rows < pack_hub.bookdict_alias_floor)
    {
        fail(
            "FAIL: {s} 的《字典篇》与 {s} 的映射面分道——ghost={d}（书有包无，首个「{s}」）／wrong={d}（同名异值，首个「{s}」书={s} 包={s}）／hidden={d}（包有而书查无，首个「{s}」）／unpaired={d}（名值枚数配不出的行）；keywords 域抽出 {d} 行（独立手设下限 {d}）／aliases 域抽出 {d} 行（下限 {d}）；区段起点标记{s}。后果：读者按自己的书查词即查无此词、照抄即编译失败（第 295 轮 D154）。判据见 `lang/pack.zig` 的 `auditBookDict`。\n",
            .{ book_arg, zh_pack_path, ba.ghost, ba.first_ghost, ba.wrong, ba.first_wrong, ba.first_wrong_doc, ba.first_wrong_pack, ba.hidden, ba.first_hidden, ba.unpaired, ba.kw_rows, pack_hub.bookdict_kw_floor, ba.alias_rows, pack_hub.bookdict_alias_floor, if (ba.heading_hit) "命中" else "缺席" },
        );
    }

    // —— 对面二十八：本机 VSIX 产物 ↔ 源树逐员 CRC 对账（第 292 轮 D151）——
    auditVsix(gpa, io, pkg_path, pkg);

    // —— 对面三十二：`README.md` 版本族（第 296 轮 D155）。用户第一眼读的入口文档以多点位手抄
    //   产品版本（`zzc_paths.zzc_version`）、工具链版本（`zig_version`/`zig_series`）、`zzc version`
    //   出口样例行、扩展版号（`package.json` 的 version）与产物全名，而全仓门禁从不读 README——
    //   落码前探针实锤：五形同注（0.1.0→0.2.0 两处／0.17.0→0.16.0 三处／v0.5.0→v0.4.0 四处）后
    //   fmt 0／build 0／test 17/17／本守卫 OK 一律零信号，活体 `zzc version` 与文档样例实地分道。
    //   判据全在 hub：静态七枚由族真值 comptime 派生（`paths.readme_face`）；样例行形串单源
    //   `cli.version_line_fmt`（main 出口同步委派，守卫渲染含真机同骨全行再要求 README 命中）；
    //   扩展臂两枚判据入 `src/vsix.zig`（全名构造与 `package.json` 的 name/version 同源）。本步只读文件、
    //   调判据、按返回值退出；README 非测图 source dep，故 build.zig 须 addFileArg 声明（本面 build 针先验）。
    const readme_arg = if (args.len >= 17) args[16] else paths.readme_path;
    const readme = std.Io.Dir.cwd().readFileAlloc(io, readme_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ readme_arg, @errorName(e) });
    defer gpa.free(readme);
    checkFace(build_path, &paths.readme_build_face, build); // README 须经 addFileArg 声明为文件依赖
    checkFace(readme_arg, &paths.readme_face, readme); // 静态版本族七枚 needle
    checkFace(main_path, &cli_hub.version_main_face, main_txt);
    checkFace(main_path, &cli_hub.flag_arity_face, main_txt);
    checkFace(main_path, &cli_hub.subcmd_face, main_txt); // D186 未知子命令点名与建议使用点
    checkFace(main_path, &cli_hub.overlay_name_face, main_txt); // D187 叠加层点名与判据接线
    checkFace(main_path, &cli_hub.lang_verb_face, main_txt); // D188 lang 二级动词点名与近似建议
    checkFace(main_path, &cli_hub.lang_remove_face, main_txt); // D189 lang remove 卸载面 // D184 三闸接线与话术使用点
    // 出口行委派形在位（复用已读 main_txt·零新增 I/O）
    const rd_name = (jsonStringValue(pkg, "name", 0) orelse
        fail("FAIL: {s} 里找不到 \"name\"——README 扩展臂无从取包名真值。\n", .{pkg_path})).val;
    const rd_ver = (jsonStringValue(pkg, "version", 0) orelse
        fail("FAIL: {s} 里找不到 \"version\"——README 扩展臂无从取版号真值。\n", .{pkg_path})).val;
    if (!vsix_hub.readmeDeclaresExtVersion(readme, rd_ver)) {
        fail("FAIL: {s} 未以（`v{s}`）形注记扩展版本——`{s}` 的 version 真值为 {s}，文档手抄已分道：照文档认代即认错（第 296 轮 D155）。\n", .{ readme_arg, rd_ver, pkg_path, rd_ver });
    }
    if (!vsix_hub.readmeDeclaresVsixName(readme, rd_name, rd_ver)) {
        fail("FAIL: {s} 未提到产物全名「{s}-{s}{s}」——安装指引/打包注释的版本面与 {s} 分道，照文档找包即找不存在的名（第 296 轮 D155）。\n", .{ readme_arg, rd_name, rd_ver, vsix_hub.skip_suffix, pkg_path });
    }
    const vsample = std.fmt.allocPrint(gpa, cli_hub.version_line_fmt, .{ paths.zzc_version, zh_pack.name }) catch
        fail("FAIL: 组 `zzc version` 样例行失败。\n", .{});
    if (std.mem.indexOf(u8, readme, vsample) == null) {
        fail("FAIL: {s} 未含 `zzc version` 样例行「{s}」——文档样例与真机出口（main 委派 cli.version_line_fmt）分道，照文档认代即对不上真跑输出（第 296 轮 D155）。\n", .{ readme_arg, vsample });
    }

    // —— 对面三十三：`demo/` 示例编译/运行防线（第 297 轮 D156）。六枚 demo 是用户第一眼照抄面
    //（书稿 quickstart 同源），而 `tools/check-demos.ps1` 基线因 NO_PWSH＋CI 无 pwsh 步从未被任何
    // 通道执行——t2 探针实锤 demo 编译坏形（活体 RC=1）后四门禁一律零信号。`tools/demos-smoke.sh`
    // 落成 bash/CI 常驻防线；本面钉其覆盖面：入口逐枚点名、条数锚与 hub 互锁、盘上双向对账。
    const smoke_arg = if (args.len >= 18) args[17] else paths.demos_smoke_path;
    const demos_smoke_txt = std.Io.Dir.cwd().readFileAlloc(io, smoke_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ smoke_arg, @errorName(e) });
    defer gpa.free(demos_smoke_txt);
    checkFace(build_path, &paths.demos_build_face, build); // 脚本须经 addFileArg 声明为文件依赖
    checkFace(smoke_arg, &paths.demos_smoke_face, demos_smoke_txt); // 六枚入口逐枚点名
    checkFace(smoke_arg, &paths.demos_smoke_count_face, demos_smoke_txt); // EXPECT_CHECKS 锚与 hub 断言下限同源
    // 对面四十三·纯母语行为面脚本话术对账（第 307 轮 D166）：第七臂手抄的「纯母语」「请改用」
    // 两词须与 msg_pure_native 模板真值胶合——文案改版漏随脚本即红；复用已读脚本文本零新增 I/O。
    checkFace(smoke_arg, &cli_hub.pure_native_smoke_face, demos_smoke_txt);
    // 对面四十四·指定语言行为面 fixture 路径单源（第 308 轮 D167）：第八臂手抄两枚路径须与
    // hub 同形——fixture 改名而脚本漏随即红；复用已读脚本文本零新增 I/O。
    checkFace(smoke_arg, &paths.lang_smoke_face, demos_smoke_txt);
    // 对面四十五·CLI 叠加轴行为面（第 309 轮 D168；311 轮 D170 扩话术；312 轮 D171 选包轴
    // 标识入面）：手抄七枚（话术五＋映射两）须与 hub 模板/叠加包活线胶合（关系钉在 309/311/
    // 312 T0）；十一/十二臂共用话术四枚，「选包轴」独指十二臂——皆复用已读脚本面零新增 I/O。
    checkFace(smoke_arg, &cli_hub.overlay_smoke_face, demos_smoke_txt);
    // 对面四十六·--lang 内置选包轴行为面（第 310 轮 D169）：第十臂三枚（未知包话术派生自
    // hub、互斥短形⊂模板、退码数锚派生自 usage_exit_code）与脚本手抄胶合（全等/子串关系钉
    // 在 310 T0）；复用已读脚本文本零新增 I/O。
    checkFace(smoke_arg, &cli_hub.lang_axis_face, demos_smoke_txt);
    // 对面四十七·`zzc lang` 列播轴行为面（第 313 轮 D172；315 轮 D174 收录列播标识入面
    // 成五枚）：两 header 派生全等、拒绝短形⊂msg_lang_bad_verb、内容针「zh(」对 registry
    // 交叉在 313 T0、十五臂标识针独指收录形；皆复用已读脚本文本零新增 I/O。
    checkFace(smoke_arg, &cli_hub.lang_list_face, demos_smoke_txt);
    // 对面四十八·`zzc lang add` 注册链内容交叉（第 314 轮 D173）：fixture 基包 $code
    // 活线须命中 lang_add_face 尾针（包改而针不改即红；路径取 hub ja_fixture_pack_path
    // 单源，D167 在册）；十四臂四形（成功回执/防覆盖退码/新键可用/缺省 $code 同源）
    // 的脚本侧胶合全五枚另走同一已读脚本文本，零另新增面。
    const fx_min = std.Io.Dir.cwd().readFileAlloc(io, paths.ja_fixture_pack_path, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）——注册链内容针交叉面消失\n", .{ paths.ja_fixture_pack_path, @errorName(e) });
    defer gpa.free(fx_min);
    checkFace("对面四十八", .{.{ .needle = cli_hub.lang_add_face[4].needle, .why = "缺省注册名针必为 fixture 包 $code 活线（`$code = tst-ja` 形）" }}, fx_min);
    // 对面四十九·注册链面十四枚与脚本十四/十六/十七/十八/十九臂手抄胶合（316 坏名话术成七枚、317 坏
    // 包词核＋失败退码数锚成十枚、318 疑形提示词＋十八臂标识成十二枚、319 遮蔽词核＋十九臂标识成十四枚；
    // 同一已读脚本文本，零新增 I/O）。
    checkFace(smoke_arg, &cli_hub.lang_add_face, demos_smoke_txt);
    // 盘上↔hub 表双向对账：表有盘无＝hidden（demo 被删而闸不随动），盘有表无＝ghost（新增忘接线）。
    inline for (paths.demo_entries) |entry| {
        const r = std.Io.Dir.cwd().readFileAlloc(io, entry, gpa, std.Io.Limit.limited(1));
        if (r) |b| {
            gpa.free(b);
        } else |e| {
            // 超 1 字节即证文件在（入口非空是既定形）；其余错形皆 demo 被删/改名而闸未随动。
            if (e != error.StreamTooLong) {
                fail("FAIL: hub 入口表指向的 {s} 读不到（{s}）——demo 被删/改名而 hub 与冒烟闸未随动（第 297 轮 D156）。\n", .{ entry, @errorName(e) });
            }
        }
    }
    { // ghost 普查：盘上每枚 */src/main.zz 须被 hub 表点名；同时实计盘上枚数验下限。
        var dir = std.Io.Dir.cwd().openDir(io, "demo", .{ .iterate = true }) catch |e|
            fail("FAIL: 打不开 demo/ 目录（{s}）——盘上对账元缺失，ghost/hidden 普查元处落地（第 297 轮 D156）。\n", .{@errorName(e)});
        defer dir.close(io);
        var walker = dir.walk(gpa) catch |e| fail("FAIL: 遍历 demo/ 失败（{s}）\n", .{@errorName(e)});
        defer walker.deinit();
        var disk_hits: usize = 0;
        while (walker.next(io) catch |e| fail("FAIL: 读 demo/ 目录项失败（{s}）\n", .{@errorName(e)})) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.path, "/src/main.zz")) continue; // walk 路径相对 demo/，首段即 demo 名
            disk_hits += 1;
            const sep = std.mem.indexOfScalar(u8, ent.path, '/') orelse continue;
            const name = ent.path[0..sep]; // walk 路径首段即 demo 名（形如 "hello/src/main.zz"）
            var wbuf: [64]u8 = undefined;
            const want_path = std.fmt.bufPrint(&wbuf, "demo/{s}/src/main.zz", .{name}) catch "demo//src/main.zz";
            var listed = false;
            for (paths.demo_entries) |entry| {
                if (std.mem.eql(u8, entry, want_path)) {
                    listed = true;
                    break;
                }
            }
            if (!listed) {
                // 显式豁免清单（demo/httpz 真依赖工程，hub 单源）按名放行；其余盘上有/表无皆 ghost。
                for (paths.demo_exempt_dirs) |ex| {
                    if (std.mem.eql(u8, name, ex)) listed = true;
                }
            }
            if (!listed) {
                fail("FAIL: 盘上 demo/{s}/src/main.zz 未列入 hub demo_entries/冒烟脚本——新增 demo 静默脱编译防线（第 297 轮 D156）。\n", .{name});
            }
        }
        if (disk_hits < paths.demo_count_floor) {
            fail("FAIL: 盘上 demo 入口实计 {d} 枚低于独立下限 {d}——demo 被成批删除而防线未知情（第 297 轮 D156）。\n", .{ disk_hits, paths.demo_count_floor });
        }
    }

    // —— 对面三十四：CI 调用面与 README 命令词面（第 298 轮 D157）。ci.yml 此前只被 D73 步读（版本族），
    // matcher 步不读：改脚本名忘改 ci.yml 即本地全绿而 CI 到推即断（lsp-live-smoke.sh 顶注自警在册）；
    // README 29 处命令样例手抄八枚 sub_* 真值亦零针——t2 探针两形（README `zzc eject→emit`、ci.yml
    // 脚本路径漂）三门禁零信号实锤。本面三面对账：build 命名针／ci 执行针×3／README 命令针×8。
    const ci_arg = if (args.len >= 19) args[18] else paths.ci_path;
    const ci_txt = std.Io.Dir.cwd().readFileAlloc(io, ci_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ ci_arg, @errorName(e) });
    defer gpa.free(ci_txt);
    checkFace(build_path, &paths.ci_build_face, build); // ci.yml 须对 matcher 步声明文件依赖（步名限定针）
    checkFace(ci_arg, &paths.ci_tools_face, ci_txt); // 四枚脚本执行针由 hub 路径派生（第 346 轮 D205 添逐块闸）
    checkFace(readme_arg, &cli_hub.readme_cmd_face, readme); // 八枚命令词针由 sub_* 派生（复用已读 README·零新增 I/O）

    // —— 对面四十七：CI 镜像面（第 334 轮 D193）。GitHub 仓加建后本仓有了两个 CI 面：`.gitcode/` 在
    // GitHub 侧从不执行、`.github/` 又不被任何本地守卫读——两面各持一份「该跑哪些门禁」的手抄清单，
    // 改一面忘另一面即「本地全绿、推到某侧才发现少跑」（D157 同根，那时只一个面）。本面把命令核收编
    // 为 hub 单源表 `ci_gate_cmds`，两面逐条必须各含一份；归一器（timeout 秒数/注释/空行）亦在 hub，
    // 本处只读文、比对与报错。镜像面顺带过 `ci_tools_face` 四枚执行针（两面脚本调用亦须同源）。
    const gh_ci_arg = if (args.len >= 26) args[25] else paths.github_ci_path;
    const gh_ci_txt = std.Io.Dir.cwd().readFileAlloc(io, gh_ci_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ gh_ci_arg, @errorName(e) });
    defer gpa.free(gh_ci_txt);
    checkFace(build_path, &paths.github_ci_build_face, build); // 两枚步名限定针（matcher 步＋D73 版本步）
    checkFace(gh_ci_arg, &paths.ci_tools_face, gh_ci_txt); // 四枚脚本执行针在镜像面亦须同源
    // 发布面（第 335 轮 D194）：同一份 GitHub CI 文本里的发版 job——tag 触发、写权限、gh 出口、
    // 打包器路径四针；四者缺一即「门禁绿但无人能产出发行件」，与 D193 同根（清单只活在 CI 里）。
    checkFace(gh_ci_arg, &paths.github_release_face, gh_ci_txt);

    // —— 对面四十八：诊断语料回放器（第 336 轮 D195）。语料把「哪段源码逼出哪条报文」固化，回放器
    // 逐 case 跑 `zzc check`；本面只钉两件会静默的事——条数锚（删 case 只动脚本即退化成抽样）与
    // 语料根目录（改名而脚本不改则该目录恒空、逐条全绿），两枚皆由 hub 真值 comptime 派生。
    // build 侧另钉一片：回放器须对 matcher 步声明文件依赖，否则改脚本不重跑、面针吃旧文本。
    const corpus_sh_arg = if (args.len >= 27) args[26] else paths.diag_corpus_sh;
    const corpus_sh_txt = std.Io.Dir.cwd().readFileAlloc(io, corpus_sh_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ corpus_sh_arg, @errorName(e) });
    defer gpa.free(corpus_sh_txt);
    checkFace(corpus_sh_arg, &paths.diag_corpus_face, corpus_sh_txt);
    checkFace(build_path, &paths.diag_corpus_build_face, build);

    // —— 对面四十九：许可证面（第 338 轮 D197）。全仓此前零 LICENSE，而发布链（D194）与 VSIX 清单
    // 都在对外分发产物：产物无许可声明即「默认保留所有权利」。本面把「一份正文 + 三处声明」胶合到
    // hub 五枚真值（路径/SPDX/署名/年份/署名行）——README 与扩展清单两处复用本函数已读的文本，
    // 只新增两读（LICENSE 第 27 片、build.zig.zon 第 28 片）。
    const lic_arg = if (args.len >= 28) args[27] else paths.license_path;
    const lic_txt = std.Io.Dir.cwd().readFileAlloc(io, lic_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ lic_arg, @errorName(e) });
    defer gpa.free(lic_txt);
    const zon_arg = if (args.len >= 29) args[28] else paths.root_zon_path;
    const zon_txt = std.Io.Dir.cwd().readFileAlloc(io, zon_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ zon_arg, @errorName(e) });
    defer gpa.free(zon_txt);
    checkFace(lic_arg, &paths.license_face, lic_txt);
    checkFace(readme_arg, &paths.license_readme_face, readme);
    checkFace(pkg_path, &paths.license_pkg_face, pkg);
    checkFace(zon_arg, &paths.license_zon_face, zon_txt);

    // —— 对面五十：上游漂移周检面（第 339 轮 D198）。「下一版上游会不会把回译打回裸英文」此前零
    // 通道：两面 CI 都装钉死的 Zig，永远只测已知会绿的那侧。周检脚本＋独立 workflow 把这件事变成
    // 每周一次的有信号通道，但它在本地既不会被执行也无法触网——能落地的只有「三面声明不许静默漂」：
    // 脚本面十八枚（339 轮的版本源/漂移标记/回放器/钉版来源＋342 轮补的三态判词两枚/离线快照入口/方向
    // 判据机器＋343 轮补的装版臂两枚离线入口/基线自红标记/同构与分道两句话术＋344 轮补的自检闸面：平台位
    // 离线入口/索引两枚字段名（tarball、shasum）/自检不过与无本平台两枚前置错标记，皆钉**赋值或取值行**
    // ——D195 的 M2 判例沿用）、workflow 三枚（周频/取版单源/本体执行）、build 依赖两枚（不声明即改面不重跑，
    // D157 同族）。342/343/344 三轮补面后本面仍只读同一份脚本文本：表扩容不动 argv 位序（新针吃已读入的
    // watch_sh_txt，零新增文件读）。
    const watch_sh_arg = if (args.len >= 30) args[29] else paths.upstream_watch_sh;
    const watch_sh_txt = std.Io.Dir.cwd().readFileAlloc(io, watch_sh_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ watch_sh_arg, @errorName(e) });
    defer gpa.free(watch_sh_txt);
    const watch_yml_arg = if (args.len >= 31) args[30] else paths.upstream_watch_yml;
    const watch_yml_txt = std.Io.Dir.cwd().readFileAlloc(io, watch_yml_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ watch_yml_arg, @errorName(e) });
    defer gpa.free(watch_yml_txt);
    checkFace(watch_sh_arg, &paths.upstream_watch_face, watch_sh_txt);
    checkFace(watch_yml_arg, &paths.upstream_watch_yml_face, watch_yml_txt);
    checkFace(build_path, &paths.upstream_watch_build_face, build);

    // —— 对面五十一：量化收益两步步名钩子（第 340 轮 D199）。测映闸与吞吐基准都是「挂在 test 上」
    // 的量化防线：一旦有人把依赖摘掉，两面 CI 永不跑它们而本地全绿——本面三枚针只钉住「步存在且入 test」，
    // 读数本身（测块数/占比/每千行毫秒）由两步自校，上限与下限住 hub。
    checkFace(build_path, &paths.metric_build_face, build);

    // —— 对面五十二：教程逐块编译/运行闸（第 346 轮 D205）。书稿与 README 的 ```zz 块是读者照抄面，
    // 而取证实锤全仓从无通道读过 fence（`grep '```zz'` 在 tools/ src/ build.zig 零命中）：四枚自带 main
    // 的程序从未被机器验过「可编＋输出等值」（书稿 11.3 还顶着「已实测」），九枚声明碎片只走
    // `zig ast-check` 浅路（无 main 不 build-exe——类型从未检查），十枚语句碎片连 `zzc check` 都过不了。
    // 本面只做**声明面与账**：闸脚本自身的 addFileArg／脚本里的块数锚与认块标记／表内四枚期望输出在
    // 脚本手抄侧逐字在场／zz 族块实计与 hub 锚全等（棘轮）——真编译与输出等值由 `tools/book-blocks-smoke.sh`
    // 自己跑（行为道）。两面文档不另读：书稿（第 16 片）与 README（第 17 片）已在册，零新增文件读。
    const book_blocks_arg = if (args.len >= 32) args[31] else paths.book_blocks_smoke_path;
    const book_blocks_txt = std.Io.Dir.cwd().readFileAlloc(io, book_blocks_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ book_blocks_arg, @errorName(e) });
    defer gpa.free(book_blocks_txt);
    checkFace(build_path, &paths.book_prog_build_face, build);
    checkFace(book_blocks_arg, &paths.book_prog_face, book_blocks_txt); // 两枚路径钉赋值行＋一枚接线针钉 assert_block 实参位
    checkFace(book_blocks_arg, &paths.book_prog_count_face, book_blocks_txt); // 块数锚＋认块标记逐字
    // 表内每枚期望输出须在脚本文里逐字在场（胶合形制承对面四十五/五十一）：脚本被改成另一串
    // 而 hub 表不动，即「跑自己的输出、比自己的期望」，闸对文档再无约束力。
    // `inline for`：`countOccurrences` 的 needle 形参是 comptime（lang_identity:190），逐枚展开方能使
    // `e.want` 成为编译期已知串——非 inline 的 `for` 会把它降成运行期值而闸红在编译前。
    inline for (paths.book_prog_entries) |e| {
        if (lid.countOccurrences(book_blocks_txt, e.want) < 1) {
            fail("FAIL: 教程逐块闸 {s} 里找不到表内期望输出「{s}」（来自 {s} 第 {d} 枚块）——脚本手抄侧与 hub `book_prog_entries` 分道，闸比的不再是账上的值（第 346 轮 D205）。\n", .{ book_blocks_arg, e.want, e.file, e.idx });
        }
    }
    // 文档侧实计与两枚锚全等：棘轮只许同动。实计走 hub 的纯函数（与闸内 grep 同一判据不另立第二套）。
    const zz_real = paths.countZzFences(book_txt) + paths.countZzFences(readme);
    const prog_real = paths.countZzProgFences(book_txt) + paths.countZzProgFences(readme);
    if (zz_real != paths.book_zz_floor or prog_real != paths.book_prog_floor) {
        fail("FAIL: 文档侧 zz 族块实计 {d}（锚 {d}）／真跑块 zz+ 实计 {d}（锚 {d}）不同——新增未标注块即当场定形制（标 {s} 或入册 hub `book_zz_floor`），旧块被删/拆标记亦须同动锚；两边分道即「账上有块而文档无块」或「文档有块而账上无名」（第 346 轮 D205）。\n", .{ zz_real, paths.book_zz_floor, prog_real, paths.book_prog_floor, paths.book_prog_marker });
    }
    const ci_faces = .{ .{ ci_arg, ci_txt }, .{ gh_ci_arg, gh_ci_txt } };
    inline for (ci_faces) |face| {
        var miss_buf: [paths.ci_gate_cmds.len][]const u8 = undefined;
        const miss_n = paths.ciGateMiss(face[1], &miss_buf);
        if (miss_n != 0) {
            fail(
                "FAIL: CI 面 {s} 缺 {d} 条门禁命令，首缺「{s}」——两面须对 hub 单源命令核（{d} 条）逐条等价：缺步即该侧静默少跑一道门禁，另一侧与本地皆无法察觉（第 334 轮 D193）。\n",
                .{ face[0], miss_n, miss_buf[0], @as(usize, paths.ci_gate_cmds.len) },
            );
        }
    }

    // —— 对面三十五：书稿图片引用 ↔ `docs/images` 盘上双向普查（第 299 轮 D158）。九枚插图被书稿以
    // `![题](images/名.svg)` 手抄引用而全仓门禁从不校双向存在——t2 探针双形（引用改漂名／新增孤立
    // svg）fmt/build/test/matcher 四道零信号实锤。判据全在 hub（抽取器＋声明判定纯函数），本步只做 I/O，
    // 复用对面三十一已读书稿文本·零新增读文件；svg 文件非测图 source dep 也未逐枚 addFileArg（改名不
    // 触重跑，盘上增量靠下次他变/CI 全新 cache 全量兼保——册为边界）。
    const img_stats = blk: {
        const refs = paths.collectBookImageRefs(book_txt);
        if (refs.overflow) {
            fail("FAIL: {s} 图片引用实计越过上限 {d}——异常灌入（抽取形制被改坏即卷入非图链接），禁静默吞尾（第 299 轮 D158）。\n", .{ book_arg, @as(usize, paths.book_images_cap) });
        }
        if (refs.count < paths.book_images_floor) {
            fail("FAIL: {s} 抽出图片引用实计 {d} 枚低于独立手设下限 {d}——引用被整体删除/抽取形改词而防线未知情（第 299 轮 D158）。\n", .{ book_arg, refs.count, @as(usize, paths.book_images_floor) });
        }
        // hidden：书稿有引用而盘上无文件——印刷即破图；逐枚 access 验在。
        var ibuf: [512]u8 = undefined;
        for (refs.names[0..refs.count]) |name| {
            const p = std.fmt.bufPrint(&ibuf, "{s}/{s}", .{ paths.book_images_dir, name }) catch
                fail("FAIL: 图片引用路径超长（>{d} 字节），盘上普查无法进行（第 299 轮 D158）。\n", .{@as(usize, 512)});
            std.Io.Dir.cwd().access(io, p, .{}) catch |e| {
                if (e == error.FileNotFound) {
                    fail("FAIL: 书稿 {s} 引用了 images/{s} 而盘上 {s}/{s} 不存在（hidden 形）——引用漂名/文件删改而门禁不知情，印刷即破图（第 299 轮 D158）。\n", .{ book_arg, name, paths.book_images_dir, name });
                }
                fail("FAIL: 盘上访问 {s} 失败（{s}）（第 299 轮 D158）。\n", .{ p, @errorName(e) });
            };
        }
        // ghost：盘上有文件而书稿未声明——孤立图；逐枚声明判据对拍（尾截扩展名取名干）。
        var img_dir = std.Io.Dir.cwd().openDir(io, paths.book_images_dir, .{ .iterate = true }) catch |e|
            fail("FAIL: 无法打开盘上图片目录 {s}（{s}）——目录被删/改名而 hub 未随动（第 299 轮 D158）。\n", .{ paths.book_images_dir, @errorName(e) });
        defer img_dir.close(io);
        var iwalker = img_dir.walk(gpa) catch |e|
            fail("FAIL: 无法遍历 {s}（{s}）（第 299 轮 D158）。\n", .{ paths.book_images_dir, @errorName(e) });
        defer iwalker.deinit();
        var disk_hits: usize = 0;
        while (iwalker.next(io) catch |e| fail("FAIL: 遍历 {s} 中断（{s}）（第 299 轮 D158）。\n", .{ paths.book_images_dir, @errorName(e) })) |ent| {
            if (ent.kind != .file) continue;
            if (std.mem.indexOfScalar(u8, ent.path, '/') != null) continue; // 只普查目录顶层（嵌套子目录非插图面）
            if (!std.mem.endsWith(u8, ent.path, paths.book_images_suffix)) continue;
            disk_hits += 1;
            const stem = ent.path[0 .. ent.path.len - paths.book_images_suffix.len];
            if (!paths.bookDeclaresImage(book_txt, stem)) {
                fail("FAIL: 盘上 {s}/{s} 未被书稿 {s} 任何引用声明（ghost 形）——新增插图忘入书稿/废弃图未清，盘上网页与印书面静默分道（第 299 轮 D158）。\n", .{ paths.book_images_dir, ent.path, book_arg });
            }
        }
        if (disk_hits < paths.book_images_floor) {
            fail("FAIL: 盘上 {s} 实计 svg {d} 枚低于独立下限 {d}——图被成批删除而防线未知情（第 299 轮 D158）。\n", .{ paths.book_images_dir, disk_hits, @as(usize, paths.book_images_floor) });
        }
        break :blk .{ refs.count, disk_hits };
    };

    // —— 对面三十六：书稿 demo 引用面（第 300 轮 D159）。书稿附录以反引号点名六枚 demo 目录（hub 表与
    // 冒烟脚本外的第三份手抄），快跑道又逐字节引 hello 源码体与输出串——t2 探针两形（输出改「十一」＋
    // synta 鬼名）五通道零信号实锤。判据全在 hub（抽取器/去首行/期望抽取皆纯函数），本步只做 I/O：
    // 正向六枚点名针 checkFace＋逆向抽取器防鬼名＋hello 源体全文对拍（新读·须 addFileArg 第 19 片）＋
    // 冒烟期望串在场（复用对面三十三已读脚本）。
    checkFace(book_arg, &paths.book_demo_face, book_txt); // 六枚反引号点名针由 hub 表派生
    checkFace(build_path, &paths.bookdemo_build_face, build); // hello 源须对 matcher 步声明文件依赖
    {
        const brefs = paths.collectBookDemoRefs(book_txt);
        if (brefs.overflow) {
            fail("FAIL: {s} 的 `demo/<名>` 抽取实计越过上限 {d}——异常灌入，禁静默吞尾（第 300 轮 D159）。\n", .{ book_arg, @as(usize, paths.book_demo_cap) });
        }
        outer: for (brefs.names[0..brefs.count]) |name| {
            for (paths.demo_entries) |e| {
                const first = std.mem.indexOfScalar(u8, e, '/') orelse continue;
                const second = std.mem.indexOfScalar(u8, e[first + 1 ..], '/') orelse continue;
                // 抽取器集的是去掉「demo/」前缀的名段（切点在 prefix 之后），故比 entry 的第二段。
                if (std.mem.eql(u8, e[first + 1 .. first + 1 + second], name)) continue :outer;
            }
            fail("FAIL: 书稿 {s} 点名了 `demo/{s}` 而 hub 入口表无此目录（ghost 形）——书稿自增/独改目录名而盘上与表皆不知情，读者照抄报即扑空（第 300 轮 D159）。\n", .{ book_arg, name });
        }
        // hello 引用体逐字节对拍：源去首行（首行注释书稿缩短形为有意差异）后须整段现于书稿。
        const hello_src = std.Io.Dir.cwd().readFileAlloc(io, paths.demo_entries[0], gpa, .unlimited) catch |e|
            fail("FAIL: 无法读取 {s}（{s}）（第 300 轮 D159）。\n", .{ paths.demo_entries[0], @errorName(e) });
        defer gpa.free(hello_src);
        const hello_body = paths.stripFirstLine(hello_src) orelse
            fail("FAIL: {s} 无换行符（整文件一行）——引用体对拍无法进行（第 300 轮 D159）。\n", .{paths.demo_entries[0]});
        if (std.mem.indexOf(u8, book_txt, hello_body) == null) {
            fail("FAIL: 书稿 {s} 未逐字含 {s} 的源体（去首行注释）——demo 源或书稿引文一侧漂，印刷即变谎（第 300 轮 D159）。\n", .{ book_arg, paths.demo_entries[0] });
        }
        // 输出串对拍：冒烟期望表（297 轮独立手抄单源）的 hello 期望须整串现于书稿——盘上实跑与读者书面结构上同源。
        const exp = paths.smokeExpectFor(demos_smoke_txt, paths.demo_entries[0]) orelse
            fail("FAIL: 冒烟脚本 {s} 抽不到 demo/hello 的期望行——脚本形制被改坏（第 300 轮 D159）。\n", .{smoke_arg});
        if (std.mem.indexOf(u8, book_txt, exp) == null) {
            fail("FAIL: 书稿 {s} 不含冒烟期望串「{s}」——demo 输出漂而书稿旧文未随动，读者看到的样例输出即谎（第 300 轮 D159）。\n", .{ book_arg, exp });
        }
    }

    // —— 对面三十七：书稿命令词面（第 301 轮 D160）。书稿 24 处命令样例手抄五枚 sub_* 真值而 298 轮
    // 只钉 README 面——t2 探针两形（eject→emit、build→bild 全量 12 行）五通道零信号实锤。本面复用
    // 对面三十一已读书稿·零新增 I/O：正向五枚派生针 checkFace＋逆向抽取器以 subcommands 全集防鬼词。
    checkFace(book_arg, &cli_hub.book_cmd_face, book_txt); // 五枚教学主线词针由 sub_* 派生（子集独立手设）
    {
        const wsz = cli_hub.collectWordsAfter(book_txt, paths.prog_name ++ " ");
        if (wsz.overflow) {
            fail("FAIL: 书稿 {s} 的「{s}<词>」抽取实计越过上限 {d}——异常灌入，禁静默吞尾（第 301 轮 D160）。\n", .{ book_arg, paths.prog_name, @as(usize, cli_hub.book_zzc_word_cap) });
        }
        outer2: for (wsz.words[0..wsz.count]) |w| {
            if (cli_hub.isDocWordLegal(w)) continue :outer2; // 合法集判据单源（九子命令∪help 旗标族，第 302 轮 D161 收编）
            fail("FAIL: 书稿 {s} 出现「{s} {s}」而合法词集无此词（ghost 形）——书稿自增/独改命令词，读者照敲即 UnknownSubcommand（第 301 轮 D160）。\n", .{ book_arg, paths.prog_name, w });
        }
    }

    // —— 对面三十八：文档命令词面逆向全覆盖＋help 旗标族收编（第 302 轮 D161）。方案书 11 处与
    // contributing 12 处命令样例从无针入任何通道，README 又处逆向盲区——t2 探针（方案书 `zzc eject→
    // emit` 全量＋README 添 `zzc wizard`）五通道零信号实锤。main 帮助兜底的四枚裸字面量同步收编
    // `cli.help_words` 单源：文档面合法集与运行期兜底从此共源，手抄回潮即委派针转红。
    // CHANGELOG/台账自身不挂此面：历史演漂记录含 `zzc runn`/`zzc foobar` 引文形，挂面即误报（册边界）。
    // 注意位序：第 19 片 demo/hello/src/main.zz 已占 args[19]（对面三十六走 cwd 直读未取 argv，
    // 但 argv 仍含之）——两面新读依次落 args[20]/[21]，索引错位即把 demo 源当方案书对账。
    const plan_arg = if (args.len >= 21) args[20] else paths.plan_doc_path;
    const contrib_arg = if (args.len >= 22) args[21] else paths.contrib_doc_path;
    // 对面四十一·扩展 README（第 305 轮 D164）：全仓守卫从不读本文件——包线只锁「包↔盘」同形，
    // t2 探针两面漂（`zzc Ips`/`zzc.lng`）重打 vsix 后六道零信号实锤。配置键三针正向＋并入命令/旗标
    // 两面逆向第五面；其自身亦须 addFileArg 声明（doc41 针）。argv 位序：第 22 片落 args[22]。
    const ext_readme_arg = if (args.len >= 23) args[22] else paths.ext_readme_path;
    const ext_readme_txt = std.Io.Dir.cwd().readFileAlloc(io, ext_readme_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ ext_readme_arg, @errorName(e) });
    defer gpa.free(ext_readme_txt);
    checkFace(build_path, &paths.doc41_build_face, build); // 扩展 README 须声明为守卫步文件依赖
    checkFace(ext_readme_arg, &lcfg.ext_readme_cfg_face, ext_readme_txt); // 配置键反引号三面形
    // 对面四十二·AGENTS.md（AI 编码操作手册，第 306 轮 D165）：读者是自动化工具——命令词/旗标
    // 静默漂的代价是 AI 照手册敲错命令产出不可编译代码；t2 探针（`zzc bild`＋`--machinX`）五通道
    // 零信号实锤。两面正向九+五枚针（子集独立手设）＋并入命令/旗标两面逆向第六面；argv 位序第 23 片落 args[23]。
    const agents_arg = if (args.len >= 24) args[23] else paths.agents_doc_path;
    const agents_txt = std.Io.Dir.cwd().readFileAlloc(io, agents_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ agents_arg, @errorName(e) });
    defer gpa.free(agents_txt);
    checkFace(build_path, &paths.doc42_build_face, build); // AGENTS.md 须声明为守卫步文件依赖
    checkFace(agents_arg, &cli_hub.agents_cmd_face, agents_txt); // 九子命令全集真值针
    checkFace(agents_arg, &cli_hub.agents_flag_face, agents_txt); // 五旗标全集真值针
    // 对面四十五·CLI 叠加轴行为面（第 309 轮 D168）：第九臂手抄话术两枚对脚本文（上方胶合）＋
    // 映射两枚对叠加包活线（第 24 片新读 args[24]，@embedFile 不可越包路径改 run 时读）；
    // 探针实锤：拆缺包报错臂静默回退基包后五通道全绿而 RC 1→0——失败形入行为防线的同时，
    // 包改版（映射漂字）而第九臂/话术面不随亦双红。包文本不入文档逆向面（运行期资产非手册）。
    const ov_pack_arg = if (args.len >= 25) args[24] else paths.overlay_pack_path;
    const ov_pack_txt = std.Io.Dir.cwd().readFileAlloc(io, ov_pack_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ ov_pack_arg, @errorName(e) });
    defer gpa.free(ov_pack_txt);
    checkFace(build_path, &paths.doc45_build_face, build); // 叠加包须声明为守卫步文件依赖
    checkFace(ov_pack_arg, &cli_hub.overlay_pack_face, ov_pack_txt); // 映射键/值形对包活线
    const plan_txt = std.Io.Dir.cwd().readFileAlloc(io, plan_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ plan_arg, @errorName(e) });
    defer gpa.free(plan_txt);
    const contrib_txt = std.Io.Dir.cwd().readFileAlloc(io, contrib_arg, gpa, .unlimited) catch |e|
        fail("FAIL: 无法读取 {s}（{s}）\n", .{ contrib_arg, @errorName(e) });
    defer gpa.free(contrib_txt);
    checkFace(build_path, &paths.doc38_build_face, build); // 两面须 addFileArg 声明为守卫步文件依赖
    checkFace(main_path, &cli_hub.help_main_face, main_txt); // main 帮助兜底须表驱动读 hub
    const doc_faces = .{ // 六面逆向鬼词普查：三面复用已读，三面新读皆 argv 传入
        .{ readme_arg, readme },
        .{ book_arg, book_txt },
        .{ plan_arg, plan_txt },
        .{ contrib_arg, contrib_txt },
        .{ ext_readme_arg, ext_readme_txt },
        .{ agents_arg, agents_txt },
    };
    inline for (doc_faces) |face| {
        const wsz2 = cli_hub.collectWordsAfter(face[1], paths.prog_name ++ " ");
        if (wsz2.overflow) {
            fail("FAIL: {s} 的「{s}<词>」抽取实计越过上限 {d}——异常灌入，禁静默吞尾（第 302 轮 D161）。\n", .{ face[0], paths.prog_name, @as(usize, cli_hub.book_zzc_word_cap) });
        }
        for (wsz2.words[0..wsz2.count]) |w| {
            if (cli_hub.isDocWordLegal(w)) continue;
            fail("FAIL: {s} 出现「{s} {s}」而合法词集（九子命令∪help 旗标族）无此词（ghost 形）——文档自增/独改命令词，读者照敲即 EXIT=2（第 302 轮 D161）。\n", .{ face[0], paths.prog_name, w });
        }
    }

    // —— 对面三十九：文档旗标词面（第 303 轮 D162）。三面 36 处旗标手抄 `zzc_flags` 真值从无针入
    // 任何通道——t2 探针形B（README `--machine→--mchine`＋`--lang-overlay→--lng-overlay` 共 9 行）
    // 五通道零信号实锤。三面文本对面三十二/三十八均已读——零新增 I/O·零新增片；子集划分判据在 hub。
    checkFace(readme_arg, &cli_hub.readme_flag_face, readme); // 五枚全在
    checkFace(plan_arg, &cli_hub.plan_flag_face, plan_txt); // 方案书一枚
    checkFace(contrib_arg, &cli_hub.contrib_flag_face, contrib_txt); // contributing 三枚

    // —— 对面四十：文档旗标逆向鬼词面（第 304 轮 D163）。303 正向只拦「该在的不在」，文档自增新
    // 旗标无从捕——t2 探针（README 添 `--verbose`、书稿添 `--zzcghost`）五通道零信号实锤。四面文本
    // 均已读——零新增 I/O·零新增片；合法集与外部豁免表判据全在 hub（isDocFlagLegal）。
    const flag_faces = .{ // 六面逆向普查：抽取器只认 `--` 双破折头，单短旗形入册边界（顶注）
        .{ readme_arg, readme },
        .{ book_arg, book_txt },
        .{ plan_arg, plan_txt },
        .{ contrib_arg, contrib_txt },
        .{ ext_readme_arg, ext_readme_txt },
        .{ agents_arg, agents_txt },
    };
    inline for (flag_faces) |face| {
        const cfg = cli_hub.collectDocFlagWords(face[1]);
        if (cfg.overflow) {
            fail("FAIL: {s} 的旗标抽取实计越过上限 {d}——异常灌入，禁静默吞尾（第 304 轮 D163）。\n", .{ face[0], @as(usize, cli_hub.book_zzc_word_cap) });
        }
        for (cfg.words[0..cfg.count]) |f| {
            if (cli_hub.isDocFlagLegal(f)) continue;
            fail("FAIL: {s} 出现旗标「{s}」而合法集（zzc 五旗标∪--help∪外部豁免四枚）无此词（ghost 形）——文档自增/误改旗标，读者照敲即未知旗标（第 304 轮 D163）。\n", .{ face[0], f });
        }
    }

    std.debug.print(
        "OK: {s}／{s} 与机读契约同源，{s} 产出的 CLI exe 名 =「{s}」（正则同骨、示例命令 =「{s}」），且 {s} 客户端图例与 LSP 语义图例同源、语言标识族十一/一/一 枚 needle 在清单／客户端／示例三面皆命中、LSP 客户端接线族三/十四 枚 needle 在清单／客户端两面皆命中、协议帧族五 枚 needle 在帧客户端面命中、方法名族二十三 枚 needle 在客户端面命中、消息本体键族十三 枚 needle 在客户端面命中、结果字段族廿七 枚 needle 在客户端面命中、严重度码值族四 枚 needle 在客户端映射面命中、错误码族一 枚 needle 在客户端应答面命中、工具链词族八 枚委派形 needle 在 {s} 消费面命中、pattern 字段映射族五 枚 needle 在清单面对账命中、ps1 命令词族十七 枚 needle 在 e2e 基线脚本 {s} 面命中、ps1 码点文案断言族廿一 枚 needle 在同面对账命中、注释标记族四/二 枚 needle 在 {s} 声明面与 {s} 生成物面各自对账命中、LSP capability 协商形串族十四 枚 needle 在 e2e 基线脚本 {s} 面命中、ps1 内嵌 LSP 帧协议词族十 枚 needle 在同面逐字节对账命中、ps1 客户端节 Contains 针族{s} 在 ps1 与客户端两面逐枚对账命中、冒烟脚本 {s} 的帧协议词族{d} 枚与 capability 断言族{d} 枚逐枚对账命中、客户端 e2e {s} 的断言条数锚（{d} 条）与 capability 键名族{d} 枚命中、恒真谓词 {d} 处（上限 {d}）、客户端日志文案族写侧{d} 枚与断言侧{d} 枚双侧逐枚对账命中、provider 注册核验族{d} 枚 needle 在客户端 e2e 面命中、kind 值域断言族{d} 枚 needle 在客户端 e2e 面命中、build.zig 内置默认包 addFileArg 路径一枚 needle 与 hub 同源、对照表 {s} 与内置默认包 {s} 双向零漂（aliases 域抽出 {d} 枚 ≥ 独立下限 {d}／keywords 域抽出 {d} 枚 ≥ 包内 {d} 枚，ghost/wrong/hidden 皆 0）",
        .{ pkg_path, tasks_path, build_path, paths.prog_name, mcon.tasks_command, ext_path, main_path, ps1_path, langconf_path, tm_path, ps1_path, pin_word, smoke_path, @as(usize, lsp_srv.smoke_frame_face.len), @as(usize, lsp_srv.smoke_cap_face.len), esm_path, cli_hub.smoke_js_floor, @as(usize, lsp_srv.smoke_js_cap_face.len), taut_n, cli_hub.js_tautology_ceiling, @as(usize, lcfg.log_writer_face.len), @as(usize, lcfg.log_assert_face.len), @as(usize, lsp_srv.smoke_js_provider_face.len), @as(usize, lsp_srv.kinds_smoke_face.len), kw_doc_path, zh_pack_path, aud.alias_rows, pack_hub.kwtable_alias_floor, aud.kw_rows, zh_pack.keywords.count() },
    );
    // 书稿与 README 回执另式：单次 format call 逾 32 枚实参即 compileError，故拆续式接力同一行。
    std.debug.print(
        "、书稿 {s} 的《字典篇》与内置默认包全量零漂（keywords 域抽出 {d} 枚 ≥ 独立下限 {d}／aliases 域抽出 {d} 枚 ≥ 下限 {d}，ghost/wrong/hidden/unpaired 皆 0，区段与四形皆对账）",
        .{ book_arg, ba.kw_rows, pack_hub.bookdict_kw_floor, ba.alias_rows, pack_hub.bookdict_alias_floor },
    );
    std.debug.print(
        "、README {s} 版本族七枚 needle 与产品/工具链版本真值同源，扩展版号与产物全名（{s}-{s}{s}）同于 {s}，`zzc version` 样例行「{s}」在位且 main 出口委派形同源",
        .{ readme_arg, rd_name, rd_ver, vsix_hub.skip_suffix, pkg_path, vsample },
    );
    std.debug.print(
        "、demo 冒烟防线 {s} 六枚入口 needle 逐枚点名且与 hub 表同源、条数锚 EXPECT_CHECKS={d} 同骨、盘上 demo/ 双向零漂（ghost=0／hub 表 {d} 枚皆验在）、{s} 已经 addFileArg 声明为守卫步文件依赖",
        .{ smoke_arg, @as(usize, paths.demo_entries.len), @as(usize, paths.demo_entries.len), paths.demos_smoke_path },
    );
    std.debug.print(
        "、CI 调用面 {s} 四枚脚本执行针（sh／node／两枚 bash）与 hub 路径同源且其对 matcher 步 addFileArg 在位，README {s} 八枚命令词针与 cli.sub_* 真值同源",
        .{ ci_arg, readme_arg },
    );
    std.debug.print(
        "、CI 镜像面 {s} 与 {s} 对 hub 单源命令核（{d} 条）逐条等价（timeout 秒数/注释/空行归一，缺步即点名）且镜像面对 matcher／版本两步入 addFileArg、三枚脚本执行针亦同源",
        .{ ci_arg, gh_ci_arg, @as(usize, paths.ci_gate_cmds.len) },
    );
    std.debug.print(
        "、GitHub 发布面 {s} 四针在位（tag 触发／contents: write／gh 出口／打包器路径由 vsix_py_path 派生、与 build 步同源）",
        .{gh_ci_arg},
    );
    std.debug.print(
        "、诊断语料回放器 {s} 的条数锚（{d} 条）与语料根 {s} 与 hub 同源、且对 matcher 步声明文件依赖",
        .{ corpus_sh_arg, paths.diag_corpus_floor, paths.diag_corpus_dir },
    );
    std.debug.print(
        "、工程根解析面 {s} 四针在位（cmdCheck／cmdBuild 皆委派 pickEntryOrRoot、工程根形与源目录形各一枚判盘针）",
        .{main_path},
    );
    std.debug.print(
        "、许可证面 {s} 四针（署名行由 hub 派生 + MIT 三句）与三处声明面（README／扩展清单／包清单）同吃 hub 五枚真值",
        .{lic_arg},
    );
    std.debug.print(
        "、上游漂移周检三面同源：脚本 {s} 四枚赋值行针（版本源 {s}／漂移标记／语料回放器／钉版取自 {s}）＋ workflow {s} 三枚（周频 {s}／向脚本取版而不在此抄字面量／本体执行）＋两枚 addFileArg 依赖针在位",
        .{ watch_sh_arg, paths.zig_index_url, paths.github_ci_path, watch_yml_arg, paths.upstream_watch_cron },
    );
    std.debug.print(
        "、量化收益两面步名钩子在位 {s}：测映闸的 src/ 输入依赖与两步均挂 test——摘依赖即量化防线退化成手动跑的附件",
        .{build_path},
    );
    std.debug.print(
        "、教程逐块闸 {s} 三面同源（块数锚 {d}／zz 族锚 {d}／认块标记 {s}）：表内 {d} 枚期望输出在脚本手抄侧逐字在场，文档实计 zz {d} 枚·zz+ {d} 枚与两锚全等（真编真跑由脚本自己跑）",
        .{ book_blocks_arg, paths.book_prog_floor, paths.book_zz_floor, paths.book_prog_marker, @as(usize, paths.book_prog_entries.len), zz_real, prog_real },
    );
    std.debug.print(
        "、书稿图片面 {s} 引用实计 {d} 枚与盘上 {s} svg {d} 枚双向零漂（hidden=ghost=0，独立手设下限 {d}，未逐枚 addFileArg 则盘上增量靠下次他变/CI 全新 cache 兼保）",
        .{ book_arg, img_stats[0], paths.book_images_dir, img_stats[1], @as(usize, paths.book_images_floor) },
    );
    std.debug.print(
        "、书稿 demo 引用面六枚反引号点名针与 hub 表同源、抽取器鬼名零、hello 源体（去首行）与冒烟期望串皆逐字在场且 {s} 已经 addFileArg 声明为守卫步文件依赖",
        .{paths.demo_entries[0]},
    );
    std.debug.print(
        "、书稿命令词面五枚教学主线针与 cli.sub_* 真值同源（子集独立手设非抽取），逆向抽取器以子命令全集普查鬼词零（{s} 面零新增 I/O）",
        .{book_arg},
    );
    std.debug.print("、文档命令词面逆向四面普查（README/书稿/方案书/contributing）鬼词零，help 旗标族四枚收编 cli.help_words 单源且 main 表驱动委派针在位", .{});
    std.debug.print(
        "、文档旗标词面三面对账（README 五枚／方案书一枚／contributing 三枚）全由 cli.zzc_flags 真值 comptime 派生，子集独立手设非抽取，三面复用已读文本零新增 I/O",
        .{},
    );
    std.debug.print(
        "、文档旗标逆向四面普查（README/书稿/方案书/contributing）鬼旗标零，外部豁免四枚（zig 三／code 一）独立手设非抽取",
        .{},
    );
    std.debug.print(
        "、扩展 README 三面挂针（第 22 片新读）：配置键反引号三面对 lcfg 真值、命令/旗标两面皆入第五面逆向普查——包线只锁「包↔盘」不锁语义之缺（D164）",
        .{},
    );
    std.debug.print(
        "、AGENTS.md（AI 编码手册·第 23 片新读）两面九+五枚正向针由 hub 真值派生且入命令/旗标两面逆向第六面——读者是自动化工具，静默漂即 AI 产出不可编译代码（D165）",
        .{},
    );
    std.debug.print(
        "、纯母语行为面脚本话术两枚（纯母语/请改用）与 msg_pure_native 模板真值胶合，第七臂条数锚落 hub smoke_assert_floor（D166）",
        .{},
    );
    std.debug.print(
        "、指定语言行为面 fixture 两枚路径（proj-ja 源/external-min 包）落 hub 单源与第八臂手抄胶合，条数锚随动（D167）",
        .{},
    );
    std.debug.print(
        "、CLI 叠加轴行为面：话术两枚与 hub 模板胶合、映射两枚对第 24 片新读叠加包活线（@embedFile 不可越包路径改 run 时读），路径第三枚入面，条数锚随动（D168）",
        .{},
    );
    std.debug.print(
        "、--lang 选包轴行为面：三枚胶合（未知名话术全等派生、互斥短形⊂模板、退码数锚随 usage_exit_code）入对面四十六，复用已读脚本零新增 I/O（D169）",
        .{},
    );
    std.debug.print(
        "、叠加轴版本闸行为面：全形模板迁 hub msg_fmt_too_new（输出字节全等迁移无损），话术面扩两枚（过新⊂模板、请升级全等派生），第十一臂极性三断入烟，条数锚随臂（D170）",
        .{},
    );
    std.debug.print(
        "、选包文件轴版本闸行为面：第十二臂极性三断入烟（RC 不变形、话术分流唯一捕手），「选包轴」标识针入对面四十五，条数锚随臂（D171）",
        .{},
    );
    std.debug.print(
        "、lang 列播轴行为面：拒绝模板迁 hub msg_lang_bad_verb（输出字节全等无损），四枚入对面四十七（两 header 派生＋⊂模板＋zh( 内容针对 registry 交叉），第十三臂三形入烟，条数锚随臂（D172）",
        .{},
    );
    std.debug.print(
        "、lang add 注册链行为面：对面四十八 fixture 内容交叉（新读一路径取 hub）＋对面四十九五枚脚本胶合，第十四臂四形闭环入烟（userpack 先查分支真跑首次入线），条数锚随臂（D173）",
        .{},
    );
    std.debug.print(
        "、已装用户包收录列播（消缺）：列播并轴 userpack.listInstalled 内核入测试图（五形 unit＋裸泄检），十五臂前后对照/同名去重入烟，标识针入对面四十七，条数锚随臂（D174）",
        .{},
    );
    std.debug.print(
        "、坏注册名拦截行为面：话术迁 hub msg_reg_key_bad（stderr 字节全等迁移无损，`--as`/`$name`/上限数三处改派生），两枚入对面四十九成七枚，十六臂三形＋越界零写盘入烟（探针实锤摘臂即 panic 134 而本地唯静态退码计数红），条数锚随臂（D175）",
        .{},
    );
    std.debug.print(
        "、坏包族零落盘行为面：「不完整」词核立 np_incomplete 单源、四模板派生收编 main 五址内联手抄（三形 stderr 字节全等无损），三枚（词核＋EXPECT_FAIL_RC 数锚＋臂标识）入对面四十九成十枚，十七臂四形退码/话术/零落盘入烟（探针实锤摘契约硬门即坏包装成功而三通道全绿），条数锚随臂（D176）",
        .{},
    );
    std.debug.print(
        "、已装坏包点名路径行为面：疑形提示词立 np_corrupt_hint 单源（三形分工不重叠入 T0），两枚（提示词派生＋臂标识）入对面四十九成十二枚，十八臂三步链（装好→手工改坏→再选用）断退码/疑形/路径点名入烟（探针实锤 |/ip|→|_| 退化裸形而三通道全绿），条数锚随臂（D177）",
        .{},
    );
    std.debug.print(
        "、同名遮蔽真相行为面：装前即拒撞内置注册名（承坏名/坏包失能态同策略）＋话术立 np_shadow/msg_reg_key_shadow 单源，两枚（遮蔽词核派生＋臂标识）入对面四十九成十六枚，十九臂两形（装前拒＋零落盘／手工同名态下内置优先序正断＋反客为主反断）入烟（探针实锤选包序整个反转而三通道全绿），十五臂去重被测物随动改手工造态防空转伪锚，条数锚随臂（D178）",
        .{},
    );
    std.debug.print(
        "、选包调用序静态面：十九臂形二系输出文本代理判据，探针「序改而输出不变」（预查已装仍回内置）三通道全绿现其盲区；320 T0 以 @embedFile main 取选包段窗口钉首现序＋出现次数＋兜底归位同源＋装前拦臂同 lookup 真相源＋反预查反形，把代理判据升级为序判据（本轮零新增 I/O、零添臂，floor 仍 19，D179）\n",
        .{},
    );
    std.debug.print(
        "、旗标笔误行为面：真值实测 `--langx`/`--language`/`-lang`/`--machin` 一律静默吞（RC=0 走默认包、而错包名有 314 轮闸），判据立 hub nearZzcFlag（三形近似＋最近匹配打分＋等号形取左核＋合法集全等早退）纯函数零 I/O，话术 msg_flag_near 携派生清单 flag_list_text，两枚（笔误词核派生＋臂标识）入对面四十九成十六枚，二十臂真跑（正形两桩退码＋点名最近名／反形六桩透传不误拦）入烟，floor 随臂 19→20、236 静态计数 8→9（D180）",
        .{},
    );
    std.debug.print(
        "、面针名实相符面：五枚自称双址的臂标识针按实测址数收紧（3/4/4/3/2），322 T0 立元判据——由 `.why` 文字声明解析址数与 occ 等值对拍（双向：声明几址就几址、已收紧必声明），并钉元判据清单枚数与各表基数（清单漏表即整表失守）；`BuildFace` 第 321 轮补 occ 与四面族对齐，本轮补「名实」闸（D181）\n",
        .{},
    );
    std.debug.print(
        "、面针名实闸横铺：`lsp_config.FaceCheck`（28 针）与 `machine_contract.PatternFace`（5 针）补 `occ` 字段、六族面型自此统一；`declaredAddrCount` 从 cli 提到 `zzc_paths` 公有（判据入 hub）；名实闸覆盖 9 hub／64 表全部面针，另以 `@embedFile` 自嵌源码统计 `pub const *_face` 声明数与清单枚数对拍——清单漏一张表即红，堵 322 轮「清单漏表＝整表失守」的元层缺口（D182）\n",
        .{},
    );
}
