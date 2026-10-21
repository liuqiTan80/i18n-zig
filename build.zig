const std = @import("std");

/// zzc —— 母语 Zig 方言编译器（transpiler + 工具链驱动）。
/// 模块 zzc_core 暴露翻译/报错回译引擎（供测试与第三方嵌入），
/// exe zzc 是 CLI 入口。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // R9续②（第 54 轮）：构建期自动发现语言包——扫 src/lang/packs/*.txt 的 `# @` 头指令，
    // 生成 pack 注册表模块（含内联包字节），作者丢文件即注册、无需手改 registry.zig。
    // 第 260 轮 D126 根治（承 D45/R9f）：生成从「build.zig 求值期内联」迁到「独立 run 步」，
    // run 步以 addFileArg 声明每个包 .txt 为输入依赖——**改包内容即 cache miss、重跑生成器刷新
    // 内联字节**，消除旧形制「仅改 .txt 不触发重跑、内联字节陈旧而与测图 @embedFile 分歧假绿」。
    // 生成规则单源在 src/lang/pack_discover.zig、驱动程序在 src/gen/pack_registry_main.zig。
    const pack_mod = generatePackRegistry(b, optimize);

    const mod = b.addModule("zzc_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "pack_registry", .module = pack_mod }},
    });

    const exe = b.addExecutable(.{
        .name = "zzc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zzc_core", .module = mod },
                .{ .name = "pack_registry", .module = pack_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "运行 zzc（示例：zig build run -- check demo/hello.zz）");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // 注：子模块测试已经由 zzc_core（src/root.zig）汇总；不再单独跑 exe
    // 测试可执行文件，避免同一 test block 被编入两个模块时符号重名。
    // 第 181 轮例外接线：main.zig 的 test 块此前恒不执行（L1335 注在册），但其 LSP 接线侧
    // 四纯函数（parseMachineDiag/kindSeverity/fileMatchesDoc/uriToFilesystemPath）系全库
    // 零直调面——接线本体不入图则无任何钉住通道。单独 addTest 以 main.zig 为 root：其
    // test 块仅此一图（root.zig 不 import main.zig），无重名风险；test 构建下 root 的
    // `pub fn main` 被编译排除，不与测试 runner 冲突。
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zzc_core", .module = mod },
            .{ .name = "pack_registry", .module = pack_mod },
        },
    });
    const main_tests = b.addTest(.{ .root_module = main_mod });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "运行单元与快照测试");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_main_tests.step);

    // 第 154 轮：tmLanguage 语法高亮生成器（编辑器集成 MVP）。
    const gen_tmlang_exe = b.addExecutable(.{
        .name = "gen-tmlang",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/editor/gen_tmlang_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });

    const gen_syntax_step = b.step("gen-editor-syntax", "生成 editors/vscode/syntaxes/zz.tmLanguage.json");
    const gen_run = b.addRunArtifact(gen_tmlang_exe);
    gen_run.addArg("emit");
    gen_syntax_step.dependOn(&gen_run.step);

    const check_syntax_step = b.step("check-editor-syntax", "校验 tmLanguage 与语言包同步（CI 守卫）");
    const check_run = b.addRunArtifact(gen_tmlang_exe);
    check_run.addArg("check");
    // 第 228 轮 D96：committed 生成物与语言包均声明为文件依赖（`addFileArg` 把二
    // 者内容哈希计入本步依赖）——改任一即重跑本步；本步挂在 `test` 上，使
    // `zig build test`/CI 必检。此前本步既不入 `test`、亦不在 CI（ci.yml 仅 `zig build`/
    // `zig build test`/`check-demos.ps1`），committed tmLanguage 相对语言包/生成器漂移
    // 全程静默（228 t2 探针 P1 实锤「追加 1 字节 → 591/591 全绿」的假锚形制）。
    check_run.addFileArg(b.path("editors/vscode/syntaxes/zz.tmLanguage.json"));
    check_run.addFileArg(b.path("src/lang/packs/中文.txt"));
    check_syntax_step.dependOn(&check_run.step);
    test_step.dependOn(&check_run.step);

    // 第 155 轮：补全片段生成器（编辑器集成 MVP 补全面）。
    const gen_snippets_exe = b.addExecutable(.{
        .name = "gen-snippets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/editor/gen_snippets_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });

    const gen_snippets_step = b.step("gen-editor-snippets", "生成 editors/vscode/snippets/zz.json");
    const gen_snip_run = b.addRunArtifact(gen_snippets_exe);
    gen_snip_run.addArg("emit");
    gen_snippets_step.dependOn(&gen_snip_run.step);

    const check_snippets_step = b.step("check-editor-snippets", "校验 snippets 与语言包同步（CI 守卫）");
    const check_snip_run = b.addRunArtifact(gen_snippets_exe);
    check_snip_run.addArg("check");
    // 第 228 轮 D96：同 syntax 侧——committed snippets 与语言包声明为文件依赖、本步挂 `test`。
    // 此前该步从不被 `zig build test`/CI 触发，committed zz.json 漂移全程静默。
    check_snip_run.addFileArg(b.path("editors/vscode/snippets/zz.json"));
    check_snip_run.addFileArg(b.path("src/lang/packs/中文.txt"));
    check_snippets_step.dependOn(&check_snip_run.step);
    test_step.dependOn(&check_snip_run.step);

    // 第 202 轮 D70：落盘族 ↔ 仓根 `.gitignore` 覆盖守卫（跨文件同步守卫形制，同上面的 syntax/snippets）。
    // 为什么必须是独立构建步而不是测试图内读盘：`@embedFile("../.gitignore")` 被 zig 0.17 的 module 包路径
    // 拦死（包路径＝模块根源文件目录 `src/`，报 `embed of file outside package path`），而测试里 `cwd()` 偷读
    // 的文件不入构建步骤清单——改忽略面不会触发重跑，即 202 t2 探针 P3 实锤的假绿形制。`addFileArg` 会把该
    // 文件的内容哈希计入本步依赖，忽略面一变即重跑并转红；本步挂在 `test` 上，故 CI 的 `zig build test` 即覆盖。
    const check_ignore_exe = b.addExecutable(.{
        .name = "check-ignore-coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check/ignore_coverage_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });

    const check_ignore_step = b.step("check-ignore-coverage", "校验 .gitignore 覆盖我方落盘族（CI 守卫）");
    const check_ignore_run = b.addRunArtifact(check_ignore_exe);
    check_ignore_run.addFileArg(b.path(".gitignore"));
    check_ignore_step.dependOn(&check_ignore_run.step);
    test_step.dependOn(&check_ignore_run.step);

    // 第 203 轮 D71：机读出口契约 ↔ 编辑器对面守卫（同上的跨文件同步守卫形制）。对面是
    // `editors/vscode/package.json` 的 problemMatcher 正则与 `examples/tasks.json` 的示例命令行——
    // 二者在 `src/` 包路径之外（同 202 轮硬约束）、且 203 t2 探针 P1/P2 实锤「改对面文件而测数行为空」
    // （非 source dependency），故只能由本步以 `addFileArg` 声明文件依赖后核对；挂在 `test` 上使 CI 必检。
    const check_matcher_exe = b.addExecutable(.{
        .name = "check-machine-matcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check/machine_matcher_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });

    const check_matcher_step = b.step("check-machine-matcher", "校验编辑器对面与机读契约同源（CI 守卫）");
    const check_matcher_run = b.addRunArtifact(check_matcher_exe);
    check_matcher_run.addFileArg(b.path("editors/vscode/package.json"));
    check_matcher_run.addFileArg(b.path("editors/vscode/examples/tasks.json"));
    // 第 210 轮 D78：再声明 `build.zig` 自身为文件依赖——守卫核对「编辑器示例命令行的程序名」与
    // 本 build 脚本 `addExecutable(.name)` 实际产出的 exe 名同源（t2 探针 P1 实锤改 exe 名而恒绿的静默面）。
    check_matcher_run.addFileArg(b.path("build.zig"));
    // 第 214 轮 D82：再声明 `extension.js` 为文件依赖——客户端语义图例须与 `lsp/server.zig` 的
    // legend hub 真值逐字节同源（t2 探针 P3 实锤改客户端图例序而 563/563 恒绿的静默错色面）。
    check_matcher_run.addFileArg(b.path("editors/vscode/extension.js"));
    // 对面十（第 217 轮 D85）：LSP 基座协议帧客户端实现——帧头名/分隔符/上限与服务端同骨面。
    check_matcher_run.addFileArg(b.path("editors/vscode/client_frames.js"));
    // 对面十六（第 224 轮 D92）：工具链 spawn argv 词族的消费侧——main.zig 须以委派形引用
    // `cli.tl_*` 真值（t2 探针 P1–P7 七路字面量漂移 583/583 全绿静默，真跑即功能级断裂）。
    check_matcher_run.addFileArg(b.path("src/main.zig"));
    // 对面十八（第 226 轮 D94）：CI e2e 基线脚本 `tools/check-demos.ps1`——其命令词族（子命令/旗标/
    // 落盘路径）是 `cli.sub_*`/`flag_*`/`zzc_paths` 真值的第二份跨文件手抄；ps1 不在测试图（本机与 CI
    // 双盲：NO_PWSH + GitCode 不跑 Actions·D17 在册）、203 t2 判例同形「改对面文件而测数行为空」，
    // 故须以 addFileArg 声明依赖后由守卫核对十七枚派生 needle 在脚本面逐一命中。
    check_matcher_run.addFileArg(b.path("tools/check-demos.ps1"));
    // 对面十九（第 229 轮 D97）：编辑器注释标记族——`language-configuration.json` 的注释声明与
    // `zz.tmLanguage.json` 的注释高亮皆是 `lang_identity` 注释族真值的手抄面；前者既非 source dep
    // （229 t2 探针 P1 改 `//`→`##` fresh 592/592 全绿静默）也无任何守卫读过，后者虽被 check-editor-syntax
    // 比对生成物却从不与声明面对账——故两文件皆须 addFileArg 声明后由守卫逐字节对账。
    check_matcher_run.addFileArg(b.path("editors/vscode/language-configuration.json"));
    check_matcher_run.addFileArg(b.path("editors/vscode/syntaxes/zz.tmLanguage.json"));
    check_matcher_step.dependOn(&check_matcher_run.step);
    test_step.dependOn(&check_matcher_run.step);

    // 第 205 轮 D73：工具链版本族 ↔ 本仓 `build.zig.zon` 与 CI 安装版本守卫（同上的跨文件同步守卫形制）。
    // 对面是两枚 `src/` 包路径之外的文件——205 t2 探针 P3 实锤「改 build.zig.zon 的 minimum_zig_version
    // 而 522/522 全绿」（zon 与 CI 皆非 source dependency，测试根本不重跑），故只能由本步以 `addFileArg`
    // 声明文件依赖后核对；挂在 `test` 上使 CI 的 `zig build test` 必检（同 202/203 轮判例）。
    const check_ver_exe = b.addExecutable(.{
        .name = "check-toolchain-baseline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check/zon_baseline_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });

    const check_ver_step = b.step("check-toolchain-baseline", "校验 build.zig.zon 与 CI 安装版本同源于工具链族真值（CI 守卫）");
    const check_ver_run = b.addRunArtifact(check_ver_exe);
    check_ver_run.addFileArg(b.path("build.zig.zon"));
    check_ver_run.addFileArg(b.path(".gitcode/workflows/ci.yml"));
    check_ver_step.dependOn(&check_ver_run.step);
    test_step.dependOn(&check_ver_run.step);
}

// ---------------------------------------------------------------- 语言包自动发现（R9续②；第 260 轮 D126 迁 run 步）

const packs_dir = "src/lang/packs";

/// 构建期生成 pack_registry 模块——把生成从「build.zig 求值期内联」迁到「独立 run 步」。
/// run 步以 `addFileArg` 声明每个包 .txt 为输入依赖：包内容一改即 cache miss、重跑生成器
/// （驱动程序 `src/gen/pack_registry_main.zig`、内核 `src/lang/pack_discover.zig`），产出新鲜内联字节，
/// 根治旧 D45/R9f 形制「仅改 .txt 不触发重跑、内联字节陈旧而与测图 @embedFile 分歧假绿」。
/// 残留边界：新增/删除包**文件**（改目录清单）仍需 build.zig 自身变更或清缓存以刷新依赖列表——
/// 此与内嵌档一贯限制一致（用户级新包请走 `zzc lang add` 运行期目录，见 src/lang/userpack.zig）。
fn generatePackRegistry(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const gpa = b.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = threaded.io();

    // 求值期仅枚举"有哪些 .txt"以声明为 run 步依赖；内容读取与注册表生成全下沉到生成器程序。
    var dir = std.Io.Dir.cwd().openDir(io, packs_dir, .{ .iterate = true }) catch |e|
        std.process.fatal("无法打开语言包目录 {s}（{s}）", .{ packs_dir, @errorName(e) });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |e| std.process.fatal("遍历语言包目录失败（{s}）", .{@errorName(e)})) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".txt")) continue;
        names.append(gpa, gpa.dupe(u8, ent.name) catch @panic("OOM")) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, bb: []const u8) bool {
            return std.mem.lessThan(u8, a, bb);
        }
    }.lt);
    if (names.items.len == 0) std.process.fatal("语言包目录 {s} 下没有 .txt 包", .{packs_dir});

    // 构建期生成器 exe（native 跑，与 --target 解耦，故取 host target）。
    // 生成内核 pack_discover 以**具名模块**导入（@import 不能跨模块路径，见 Zig module-path 限制）。
    const discover_mod = b.createModule(.{
        .root_source_file = b.path("src/lang/pack_discover.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const gen_exe = b.addExecutable(.{
        .name = "gen-pack-registry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen/pack_registry_main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "pack_discover", .module = discover_mod }},
        }),
    });

    // run 步：输出路径先、逐包 .txt 声明为文件依赖。改任一包内容 → 本步 cache miss → 重跑生成器。
    const gen_run = b.addRunArtifact(gen_exe);
    const registry_src = gen_run.addOutputFileArg("pack_registry.zig");
    for (names.items) |n| {
        const rel = std.fs.path.join(gpa, &.{ packs_dir, n }) catch @panic("OOM");
        gen_run.addFileArg(b.path(rel));
    }

    // 具名步（可选独立触发；产品/测试依赖链已隐式拉起本 run 步）。
    const gen_step = b.step("gen-pack-registry", "生成 pack_registry 模块（内联语言包字节·随包内容自动刷新）");
    gen_step.dependOn(&gen_run.step);

    return b.createModule(.{ .root_source_file = registry_src });
}
