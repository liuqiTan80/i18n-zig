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
    // 对面二十三（第 281 轮 D139）：LSP 长连接冒烟脚本 `tools/lsp-live-smoke.sh`——其内嵌帧方法词与
    // capability 断言形串是协议词汇的第四处手抄，脚本非测图 source dep 且不在 test 门内（t2 探针 P1：
    // 删一条断言而 17/17 全绿且脚本自身仍 PASS），故须 addFileArg 声明依赖后由守卫逐枚对账。
    check_matcher_run.addFileArg(b.path("tools/lsp-live-smoke.sh"));
    // 对面二十四（第 282 轮 D140／D141）：客户端 e2e 冒烟 `tools/extension-smoke.js`——断言条数即覆盖面，
    // 探针实锤删一条断言仍报 `PASS：87` 退 0 且构建链全绿；条数锚与 capability 键名族皆须跨侧对账，
    // 故同 D139 补 addFileArg 声明（改 js 即触发守卫重跑）。
    check_matcher_run.addFileArg(b.path("tools/extension-smoke.js"));
    // 对面二十九（第 292 轮 D151）：打包器命名面——`tools/build-vsix.py` 的包名/包内前缀/排除
    // 后缀三枚针脚与 `src/vsix.zig` hub 同源，改 py 即触发守卫重跑（非 source dep 则恒绿静默）。
    check_matcher_run.addFileArg(b.path("tools/build-vsix.py"));
    // 对面三十（第 294 轮 D153）：`docs/关键字对照表.md` 是内置默认包 `[keywords]`／`[aliases]` 两段的
    // 第二份手抄，而包内 `未知标识符` 报错文案正把用户指向该表；两文件皆非测图 source dep（表在 `docs/`
    // 越出模块包路径、不可 `@embedFile`，202 轮硬约束判例），P1 探针实锤三形漂动三门禁零信号——故一并
    // addFileArg 声明，改任一面即触发守卫重跑。路径串由 `lang/pack.zig` 的 kwtable_path 派生并被守卫核对。
    check_matcher_run.addFileArg(b.path("docs/关键字对照表.md"));
    check_matcher_run.addFileArg(b.path("src/lang/packs/中文.txt"));
    // 第 295 轮 D154：书稿《字典篇》系包映射面的**第三份手抄**（该篇头注自称「可按主题查词」，探针实测
    // 却缺 27/113 枚，且两条尾注点名「均在词表中」的十枚一枚皆不在表内）；书非 source dependency，
    // 故同 D153 补 addFileArg 声明，路径串由 `lang/pack.zig` 的 book_path 派生并被守卫核对。
    check_matcher_run.addFileArg(b.path("docs/母语编写zig-中文版.md"));
    // 第 296 轮 D155：对面三十二——仓根 `README.md` 的版本族（产品版本/工具链版本/`zzc version` 样例/
    // 扩展版号与产物全名共十余处手抄）系 `zzc_paths`/`package.json` 真值的文档侧副本；探针实锤五形
    // 同注后 fmt/build/test/matcher 皆零信号（README 从不被门禁读取、亦非测图 source dep），升代或
    // 独漂皆静默——故 addFileArg 声明为文件依赖，路径串由 hub 的 readme_path 派生并被守卫核对。
    check_matcher_run.addFileArg(b.path("README.md"));
    // 第 297 轮 D156：demo 冒烟脚本 `tools/demos-smoke.sh` 纳入同一形制——第 17 片。六枚 demo
    // 是用户照抄面而 `check-demos.ps1` 基线因 NO_PWSH＋CI 无 pwsh 步从未被调用（t2 探针实锤
    // demo 编译坏形后四门禁零信号）；守卫对面三十三读脚本实文对账入口点名/条数锚/盘上双向。
    check_matcher_run.addFileArg(b.path("tools/demos-smoke.sh"));
    // 第 298 轮 D157：CI 工作流 `.gitcode/workflows/ci.yml` 纳入 matcher 步输入——第 18 片。此前它
    // 只被 D73 步（版本族）读：改脚本名忘改 ci.yml 即本地全绿而 CI 到推即断（lsp-live-smoke.sh 顶注
    // 自警在册）；matcher 步需自己的 addFileArg（逐 step 生效，D73 片不顶本针）。
    check_matcher_run.addFileArg(b.path(".gitcode/workflows/ci.yml"));
    // 第 300 轮 D159：hello demo 源纳入 matcher 步输入——第 19 片。对面三十六需**全文**读它对书稿
    // 引文块做逐字节对拍（非 297 轮限读 1 字节的验在形），改源不触发重跑即假绿（202 轮判例）。
    check_matcher_run.addFileArg(b.path("demo/hello/src/main.zz"));
    // 第 302 轮 D161：方案书与 contributing 指南纳入 matcher 步输入——第 20/21 片。对面三十八对
    // 两面命令样例做逆向鬼词普查（此前两面从无针入任何通道：方案书全量漂 eject→emit 五通道
    // 零信号实锤）；不声明即改文档不触发重跑，202/210 轮假绿判例重播。
    check_matcher_run.addFileArg(b.path("docs/方案书.md"));
    check_matcher_run.addFileArg(b.path("docs/contributing-lang-pack.md"));
    // 第 22 片（对面四十一·第 305 轮 D164）：扩展 README——全仓守卫从不读本文件，包线（vsix 字节同源）
    // 只锁「包↔盘」不锁语义；t2 探针两面漂重打包后六道零信号实锤。配置键三针＋命令/旗标两面逆向第五面。
    // 路径单源 `paths.ext_readme_path`，needle 由真值派生（`src/zzc_paths.zig` doc41_build_face）。
    check_matcher_run.addFileArg(b.path("editors/vscode/README.md"));
    // 第 23 片（对面四十二·第 306 轮 D165）：AGENTS.md（AI 编码操作手册）——读者是自动化工具，
    // 命令词/旗标静默漂即 AI 照手册产出不可编译代码；两面九+五枚正向针＋命令/旗标两面逆向第六面。
    check_matcher_run.addFileArg(b.path("AGENTS.md"));
    // 第 24 片（对面四十五·第 309 轮 D168）：第三方库叠加包 contrib/packs/httpz-中文.txt——
    // 第九臂正形/映射源的盘上真值件（@embedFile 不可越包路径，296 自守形制在此不适用，改 run 时读）；
    // 路径单源 `paths.overlay_pack_path`，映射两枚 needle 对包文 presence 由守卫胶合。
    check_matcher_run.addFileArg(b.path("contrib/packs/httpz-中文.txt"));
    // 第 334 轮 D193：GitHub Actions 侧 CI 工作流纳入 matcher 步输入——第 25 片（**位序垫底**：前 24
    // 片的 argv 位已被守卫各面对固定，新片只能排在末位，否则后续各面对全体错位、把包文当文档）。
    // GitHub 仓加建后本仓有了第二个 CI 面，而 `.github/` 从不被任何本地守卫读：两面各持一份「该跑
    // 哪些门禁」的手抄清单，改一面忘另一面即本地全绿、推到某侧才发现少跑（D157 同根，那时只一个面）。
    // 本片令对面四十七把两面逐行对 `paths.ci_gate_cmds` 单源命令核；不声明即改 CI 不触发重跑。
    check_matcher_run.addFileArg(b.path(".github/workflows/ci.yml"));
    // 第 336 轮 D195：诊断语料回放器纳入 matcher 步输入——第 26 片（**仍垫底**：前 25 片的 argv 位已被
    // 各面对固定）。回放器自身承载「条数锚 + 语料根」两枚面针，改脚本不重跑即吃陈旧文本（D157 同族）。
    check_matcher_run.addFileArg(b.path("tools/diag-corpus.sh"));
    // 第 338 轮 D197：许可证正文与仓根包清单纳入 matcher 步输入——第 27/28 片（**仍垫底**，前 26 片
    // 的 argv 位已被各面对固定）。二者皆是「声明面」：LICENSE 承载义务正文，zon 的 .paths 决定包内
    // 是否随许可走；不声明即改文件不重跑、面针吃陈旧文本（D157 同族）。
    check_matcher_run.addFileArg(b.path("LICENSE"));
    check_matcher_run.addFileArg(b.path("build.zig.zon"));
    // 第 339 轮 D198：上游漂移周检的两面纳入 matcher 步输入——第 29/30 片（**仍垫底**，前 28 片
    // 的 argv 位已被各面对固定）。周检是「只在定时面上跑」的防线，本地既不会执行 workflow 也无法
    // 触网装工具链，故能落地的只有「三面声明本身不许静默漂」：脚本判据（版本源/回放器/钉版来源）、
    // workflow 的调用与频率、build 侧的依赖声明——三处任一改名不随动即周检静默退化成空转。
    check_matcher_run.addFileArg(b.path("tools/upstream-watch.sh"));
    check_matcher_run.addFileArg(b.path(".github/workflows/upstream-watch.yml"));
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
    // 第 334 轮 D193：版本族对账逐面进行——GitHub 面也装 zig，故也须核 `download/<ver>/` 字面；
    // 只挂 GitCode 面即那面可静默换代（与 matcher 步同路径两片各管一事，不可互顶）。
    check_ver_run.addFileArg(b.path(".github/workflows/ci.yml"));
    check_ver_step.dependOn(&check_ver_run.step);
    test_step.dependOn(&check_ver_run.step);

    // ---------------------------------------------------------------- 诊断语料回放（第 336 轮 D195）
    // 语料（`tools/diag-corpus/<族-名>/`）是「哪段源码逼出哪条报文」的沉淀：此前每轮补诊断族都
    // 靠一次性探针，用完即删，下一族又从零摸。本步把回放挂进 test 图——逐 case 跑 `zzc check`，
    // 断言「报错退非零 + 输出含期望子串 + case 数 = hub 锚」。
    // 三个 add* 各管一事：artifact 给刚构建的 zzc（防 zig-out 陈旧）、directory 令语料增删/改内容
    // 都成为输入依赖（不声明即改 case 不重跑＝回放恒绿）、fileInput 钉脚本本体。
    const check_corpus_run = b.addSystemCommand(&.{ "bash", "tools/diag-corpus.sh" });
    check_corpus_run.addArtifactArg(exe);
    check_corpus_run.addDirectoryArg(b.path("tools/diag-corpus"));
    check_corpus_run.addFileInput(b.path("tools/diag-corpus.sh"));
    const check_corpus_step = b.step("check-diag-corpus", "诊断语料回放（触发源码 + 期望译文 + 极性 + 条数锚）");
    check_corpus_step.dependOn(&check_corpus_run.step);
    test_step.dependOn(&check_corpus_run.step);

    // ---------------------------------------------------------------- 量化收益：测映闸与吞吐基准（第 340 轮 D199）
    // 仓里测试占了一半体量却零可对账量：不知道「哪个文件有测、测了多少行」（新文件零测入图只能靠
    // 人目测，292/293 轮反复吃过这形亏），也不知道「译一遍多少钱」（退到十倍慢也无人知道）。另：
    // Zig 0.17 无 `zig build test --coverage`、发行包不带 llvm-cov，行覆盖率这台机器不存在，故取
    // 可实装口径：文件级测块/测行账 + 固定语料墙钟基准。两件都挂在 test 上（两面 CI 随之逐轮跑，
    // 读数才有纵向曲线）；判据全在 hub，两个 main 只做扫目录/读盘/计时与退出码。
    const check_test_map_exe = b.addExecutable(.{
        .name = "check-test-map",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check/test_map_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });
    const check_test_map_run = b.addRunArtifact(check_test_map_exe);
    // 整面 src/ 作为输入依赖：新增/改动任一源文件都重跑本步，否则测块计数吃旧树（D195 同族）。
    check_test_map_run.addDirectoryArg(b.path("src"));
    const check_test_map_step = b.step("check-test-map", "测试映射覆盖闸（测块数／测行占比／零测豁免双向对账）");
    check_test_map_step.dependOn(&check_test_map_run.step);
    test_step.dependOn(&check_test_map_run.step);

    // 基准档位固定为 ReleaseSafe（不随 `-Doptimize` 漂）：Debug 与 Release 差一个量级，
    // 跟随命令行档位即「同一仓两次不同命令的读数不可比」，曲线当场作废。
    const check_bench_exe = b.addExecutable(.{
        .name = "check-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check/bench_main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });
    const check_bench_run = b.addRunArtifact(check_bench_exe);
    const check_bench_step = b.step("check-bench", "翻译吞吐基准（每千行毫秒＋量级闸）");
    check_bench_step.dependOn(&check_bench_run.step);
    test_step.dependOn(&check_bench_run.step);
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
