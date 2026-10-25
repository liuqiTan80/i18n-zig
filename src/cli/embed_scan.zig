//! @embedFile 静态扫描与相对路径归一族（第 341 轮 D200·自 `cli/args.zig` 整簇下沉）。
//!
//! 为什么单独成模块：本族只做一件事——**不执行代码**地从 Zig 源文里按字节扫出 `@embedFile("…")`
//! 的字面/单跳 const 实参，再把相对路径归一、判它是否留在镜像根内。它对外只吃两样东西（`std` 与
//! hub 的 `isDialectSource`/`isWordByte`），与 args 里的旗标扫描、话术模板、面表针清单**零耦合**——
//! 这种「零内部依赖 + 独立判据」的簇留在 4000 行的 CLI hub 里，读的人必须滚动半屏才知道它和命令行
//! 没关系；抽出来后 args.zig 回到「CLI 词汇与话术的 hub」这一件事上。
//!
//! 表面不断：`cli.*` 的七个出口（`extractEmbedPaths`／`extractEmbedPathsForms`／`resolveEmbedZzRel`／
//! `normalizeRelPath`／`joinRelNorm`／`findReferencedRels`／`embedPathStaysWithin`）在 `cli/args.zig`
//! 逐名转出，main.zig 四处直调与既有「委派形」注记一字未动。
//!
//! 私有谓词 `skipWs`／`isWordCharByte`／`collectConstStringBindings` 与其第 178 轮穷举护栏测同迁——
//! 那两块测是全仓唯一直调它们的地方，测与判据不同文件即成「改判据无人拦」。

const std = @import("std");
const zzc = @import("../zzc_paths.zig"); // 第 200 轮 D68：`.zz` 方言词判定取 hub 唯一真值

/// 跳过空白（空格/制表/换行），返回首个非空白下标（越界则返回 src.len）。
fn skipWs(src: []const u8, from: usize) usize {
    var k = from;
    while (k < src.len) {
        const c = src[k];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') k += 1 else break;
    }
    return k;
}

/// 收集 `X = "字面串";` 形的单跳数据流：`const_leads` 里的关键词（如 `const`/`常数`）后接标识符、
/// 再直接绑定字符串字面量时，登记 标识符→字面值（值为 src 子串）。供 embed 实参为变量名时解析（台账 D3）。
/// 近似词法：仅认“紧跟字面量”的单跳形（`const b = a;` 间接链/拼接/函数返回不登记）；
/// 字符串正文里恰含 `const x = "…"` 形可能轻微污染映射表——仅当该名字真被 @embedFile 引用才生效，风险可忽。
fn collectConstStringBindings(
    map: *std.StringHashMap([]const u8),
    src: []const u8,
    const_leads: []const []const u8,
) !void {
    for (const_leads) |lead| {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, src, idx, lead)) |pos| : (idx = pos + lead.len) {
            // 词边界：`myconst`/超串不认（lead 前一字节是词内字符即跳过）
            if (pos > 0 and isWordCharByte(src[pos - 1])) continue;
            var k = pos + lead.len;
            // lead 与名字之间允许空白（方言形 `常数 名字` 必隔空格；ASCII `const名字` 非法）
            k = skipWs(src, k);
            const name_start = k;
            // 名字可含非 ASCII：原文侧变量名是母语词（如 `名字`），生成侧是 ASCII；统一按词内字符扫描
            while (k < src.len and isWordCharByte(src[k])) k += 1;
            if (k == name_start) continue;
            const name = src[name_start..k];
            k = skipWs(src, k);
            if (k >= src.len or src[k] != '=') continue;
            // Zig 的 `=` 不能接在 `==`/`=>` 里；单 `=` 后若又是 `=` 则是比较式，不登记
            if (k + 1 < src.len and src[k + 1] == '=') continue;
            k = skipWs(src, k + 1);
            if (k >= src.len or src[k] != '\"') continue;
            k += 1;
            const vstart = k;
            while (k < src.len and src[k] != '\"') {
                if (src[k] == '\\') k += 1;
                k += 1;
            }
            if (k >= src.len) continue;
            try map.put(name, src[vstart..k]); // key 同为 src 子串：随 src 生命期，不额外拷贝
        }
    }
}

/// 从生成后的 Zig 源码里扫出全部 `@embedFile(…)` 的路径实参（元素为指向 src 的子串）。
/// 用途：把被嵌入的资源文件一并落到生成树 / eject 目标——zig 的 `@embedFile` 相对**当前 .zig 所在目录**解析，
/// 而 zzc 把源码生成到 `.zzc/gen/…`，若不搬运资源就会报 `failed opening …: FileNotFound`。
/// 认两种实参：字面字符串；以及单跳 const 变量（`const 名 = "字面";` 后 `@embedFile(名)`，台账 D3）。
/// 其余计算式实参（拼接/函数/间接链）zig 虽可能在 comptime 求出，zzc 仍无法静态预知 → 跳过，
/// 由诊断提示的**条件表述**说明“可能未被自动拷贝”而非断言不存在；跳过 `\"` 转义。
pub fn extractEmbedPaths(gpa: std.mem.Allocator, src: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    // out 元素皆 src 借用子串（含 consts.get 值）→ 错误回滚只 deinit 本体、不逐项 free（R7f ⑤）；
    // 孪生 findReferencedRels 已有本 errdefer，此处补齐对称（D22 族底衬回滚缺口，R10f 不可注入红·源头治理）。
    errdefer out.deinit(gpa);
    var consts = std.StringHashMap([]const u8).init(gpa);
    defer consts.deinit();
    const one_const = [_][]const u8{"const"};
    try collectConstStringBindings(&consts, src, &one_const);
    const lead = "@embedFile";
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] != '@') continue;
        if (!std.mem.startsWith(u8, src[i..], lead)) continue;
        var j = skipWs(src, i + lead.len);
        if (j >= src.len or src[j] != '(') continue;
        j = skipWs(src, j + 1);
        if (j < src.len and (std.ascii.isAlphabetic(src[j]) or src[j] == '_')) {
            // 变量实参：单跳解析到 const 绑定的字面值；未登记则跳过（留给 zig 报错/提示）
            const s = j;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
            if (consts.get(src[s..j])) |v| try out.append(gpa, v);
            continue;
        }
        if (j >= src.len or src[j] != '\"') continue; // 非字面串（其它计算式）→ 不处理
        j += 1;
        const start = j;
        while (j < src.len and src[j] != '\"') {
            if (src[j] == '\\') j += 1; // 跳过被转义的下一字符
            j += 1;
        }
        if (j >= src.len) break; // 字符串未闭合
        try out.append(gpa, src[start..j]);
        i = j; // 从右引号处继续（循环尾会再 +1）
    }
    return out;
}

test "extractEmbedPaths：扫出 @embedFile 字面路径、忽略非字面实参" {
    const src =
        \\const a = @embedFile("note.txt");
        \\const b = @embedFile("sub/数据.bin");
        \\const c = @embedFile(n);
        \\const d = @embedFile (  "带空格.txt" );
    ;
    var list = try extractEmbedPaths(std.testing.allocator, src);
    defer list.deinit(std.testing.allocator);
    // 三个合法字面（含 `@embedFile (` 带空白形）；未登记变量 `n` 不计。
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("note.txt", list.items[0]);
    try std.testing.expectEqualStrings("sub/数据.bin", list.items[1]);
    try std.testing.expectEqualStrings("带空格.txt", list.items[2]);
}

test "extractEmbedPaths：单跳 const 变量实参解析（D3），间接链/未登记名跳过" {
    const src =
        \\const name = "note.txt";
        \\const blob = @embedFile(name);
        \\pub const p2 = "sub/数据.bin";
        \\const b2 = @embedFile(p2);
        \\const chain = name; // 间接链：RHS 非字面量，不登记
        \\const b3 = @embedFile(chain);
        \\const b4 = @embedFile(未知名);
    ;
    var list = try extractEmbedPaths(std.testing.allocator, src);
    defer list.deinit(std.testing.allocator);
    // 只解析两跳：name→note.txt、p2→sub/数据.bin；chain/未知名不纳入。
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("note.txt", list.items[0]);
    try std.testing.expectEqualStrings("sub/数据.bin", list.items[1]);
}

test "extractEmbedPaths：无 embedFile 时为空、不报错" {
    var list = try extractEmbedPaths(std.testing.allocator, "const x: i64 = 1;\n");
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

/// 字节是否为“词内字符”（ASCII 字母数字/下划线或非 ASCII 字节）：用于词边界判定，
/// 防止方言词 lead 被超串拆分命中（如 `我的嵌入文件`、`嵌入文件1` 都不算独立词）。
fn isWordCharByte(c: u8) bool {
    // 第 241 轮 D109：词边界字节集取单一真值（与 lsp/server 链式词字节、transpiler/lexer 非 ASCII 续读同源）。
    return zzc.isWordByte(c);
}

/// 从**方言原文**里扫出全部 `lead(路径实参)` 形（lead 取词列表：ASCII 直通形 + 语言包词表形）。
/// 与 extractEmbedPaths 的区别：那边只认生成后的 ASCII `@embedFile`；这边要认尚未翻译的原文，
/// 且 lead 两侧须为词边界。用途：采集前预扫描出被当数据嵌入的 `.zz` 资产、从编译单元豁免（台账 D2）。
/// `const_leads`（如 `{"const", "常数"}`）启用与 D3 同构的单跳变量实参解析：原文里
/// `常数 名字 = "模板.zz"; 常数 内容 = 嵌入文件(名字);` 的变量引用同样能命中豁免（台账 D3 组合面）。
pub fn extractEmbedPathsForms(
    gpa: std.mem.Allocator,
    src: []const u8,
    leads: []const []const u8,
    const_leads: []const []const u8,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    // out 元素皆 src 借用子串 → 错误回滚只 deinit 本体、不逐项 free（R7f ⑤，同 extractEmbedPaths）。
    errdefer out.deinit(gpa);
    var consts = std.StringHashMap([]const u8).init(gpa);
    defer consts.deinit();
    if (const_leads.len > 0) try collectConstStringBindings(&consts, src, const_leads);
    for (leads) |lead| {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, src, idx, lead)) |pos| : (idx = pos + lead.len) {
            if (pos > 0 and isWordCharByte(src[pos - 1])) continue;
            const after = pos + lead.len;
            if (after < src.len and isWordCharByte(src[after])) continue;
            var j = skipWs(src, after);
            if (j >= src.len or src[j] != '(') continue;
            j = skipWs(src, j + 1);
            if (j < src.len and isWordCharByte(src[j])) {
                // 变量实参：仅在启用 const_leads 且能单跳解析时纳入（名字可为母语词）
                const s = j;
                while (j < src.len and isWordCharByte(src[j])) j += 1;
                if (consts.get(src[s..j])) |v| try out.append(gpa, v);
                continue;
            }
            if (j >= src.len or src[j] != '\"') continue; // 非字面串（变量未登记/计算式）→ 不处理
            j += 1;
            const start = j;
            while (j < src.len and src[j] != '\"') {
                if (src[j] == '\\') j += 1; // 跳过被转义的下一字符
                j += 1;
            }
            if (j >= src.len) break; // 字符串未闭合
            try out.append(gpa, src[start..j]);
        }
    }
    return out;
}

/// 把 embed 字面参 p（相对引用文件所在目录 referrer_dir）解析成归一化的源树相对路径；
/// 返回 null：p 为空/绝对（前导 `/` `\` 或盘符）/解析后越出源根/不以 `.zz` 结尾
///（非方言后缀资产不与 .zz 源采集相碰，无需豁免）。
pub fn resolveEmbedZzRel(gpa: std.mem.Allocator, referrer_dir: []const u8, p: []const u8) !?[]const u8 {
    if (p.len == 0) return null;
    if (p[0] == '/' or p[0] == '\\') return null;
    if (p.len >= 2 and p[1] == ':') return null;
    if (!zzc.isDialectSource(p)) return null; // 先筛后缀再拼接，省无谓 join（第 201 轮 D69：后缀真值同源）
    const joined = try std.fs.path.join(gpa, &.{ referrer_dir, p });
    defer gpa.free(joined);
    const norm = try normalizeRelPath(gpa, joined);
    if (std.mem.startsWith(u8, norm, "..") and (norm.len == 2 or norm[2] == '/')) {
        gpa.free(norm);
        return null; // 越出源根：不属于工程内资产
    }
    return norm;
}

test "extractEmbedPathsForms：原文方言词/直通词都认，超串不拆，变量实参跳过" {
    const src =
        \\常数 a = 嵌入文件("模板.zz");
        \\const b = @embedFile("note.txt");
        \\常数 我的嵌入文件 = 1; // 超串名：不当函数词
        \\常数 c = 嵌入文件1("坏.zz"); // lead 后接词字符：非独立词
        \\常数 d = 嵌入文件(n);
    ;
    const leads = [_][]const u8{ "@embedFile", "嵌入文件" };
    var list = try extractEmbedPathsForms(std.testing.allocator, src, &leads, &.{});
    defer list.deinit(std.testing.allocator);
    // 只收到两条字面参：超串 `我的嵌入文件`/`嵌入文件1` 被词边界拦截，变量实参跳过。
    // 注意：按 lead 分组扫描，先扫完全部 @embedFile 再扫方言词，顺序为 note → 模板。
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("note.txt", list.items[0]);
    try std.testing.expectEqualStrings("模板.zz", list.items[1]);
}

test "extractEmbedPathsForms：原文单跳变量实参也能命中（D2×D3 组合面）" {
    const src =
        \\常数 名字 = "模板.zz";
        \\常数 内容 = 嵌入文件(名字);
        \\常数 其它 = 嵌入文件("直接.zz");
        \\常数 无关 = "没被引用.zz";
    ;
    const leads = [_][]const u8{ "@embedFile", "嵌入文件" };
    const cs_leads = [_][]const u8{ "const", "常数" };
    var list = try extractEmbedPathsForms(std.testing.allocator, src, &leads, &cs_leads);
    defer list.deinit(std.testing.allocator);
    // 变量形与字面形都纳入；未被引用的常量不算资产。
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("模板.zz", list.items[0]);
    try std.testing.expectEqualStrings("直接.zz", list.items[1]);
}

test "三处字面串扫描器：末字节反斜杠未闭合串不越界 panic（D33 同族双自增，靠循环后置守卫兜住）" {
    // collectConstStringBindings：`const 名 = "...\` 串体以反斜杠收尾且无右引号，
    // while 内 `if (src[k]=='\\') k+=1; k+=1;` 双自增令 k 越至 src.len+1，
    // 靠 473 行 `if (k >= src.len) continue;` 拦下——越界值绝不用于切片。
    {
        const src = "const name = \"abc\\"; // 末字节为反斜杠，字符串未闭合
        var consts = std.StringHashMap([]const u8).init(std.testing.allocator);
        defer consts.deinit();
        const leads = [_][]const u8{"const"};
        try collectConstStringBindings(&consts, src, &leads);
        try std.testing.expectEqual(@as(usize, 0), consts.count());
    }
    // extractEmbedPaths：前一条合法、后一条末字节反斜杠未闭合——合法的照常收，畸形的靠 516 行 break 跳过。
    {
        const src = "const ok = @embedFile(\"good.txt\"); const y = @embedFile(\"abc\\";
        var list = try extractEmbedPaths(std.testing.allocator, src);
        defer list.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), list.items.len);
        try std.testing.expectEqualStrings("good.txt", list.items[0]);
    }
    // extractEmbedPathsForms：方言词 lead，同样末字节反斜杠未闭合 → 靠 609 行 break 跳过、不 panic。
    {
        const src = "嵌入文件(\"abc\\";
        const leads = [_][]const u8{"嵌入文件"};
        var list = try extractEmbedPathsForms(std.testing.allocator, src, &leads, &.{});
        defer list.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), list.items.len);
    }
}

test "resolveEmbedZzRel：同目录/子目录/包内 .. 解析，非 .zz/绝对/越根返回 null" {
    const gpa = std.testing.allocator;
    const a = try resolveEmbedZzRel(gpa, "src", "模板.zz");
    try std.testing.expectEqualStrings("src/模板.zz", a.?);
    gpa.free(a.?);
    const b = try resolveEmbedZzRel(gpa, "src/sub", "../共享.zz");
    try std.testing.expectEqualStrings("src/共享.zz", b.?);
    gpa.free(b.?);
    const c = try resolveEmbedZzRel(gpa, "src/sub", "深层\\嵌套.zz"); // 反斜杠归一
    try std.testing.expectEqualStrings("src/sub/深层/嵌套.zz", c.?);
    gpa.free(c.?);
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "../../坏.zz")); // 越根
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "/etc/x.zz")); // 绝对
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "C:/x.zz")); // 盘符
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "数据.bin")); // 非 .zz 不碰采集
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveEmbedZzRel(gpa, "src", "")); // 空
}

/// 词法规范化路径（无系统调用）：反斜杠归一为正斜杠、折叠重复分隔符、去除 `.`、解析 `..`（越出起点则保留前导 `..`）。
/// 仅用于判包含性（不要求访问磁盘），统一分隔符后拿到的段逐个入栈。
pub fn normalizeRelPath(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, raw, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0 and !std.mem.eql(u8, segs.items[segs.items.len - 1], "..")) {
                _ = segs.pop();
            } else {
                try segs.append(gpa, seg); // 越出起点：保留前导 ..
            }
            continue;
        }
        try segs.append(gpa, seg);
    }
    return std.mem.join(gpa, "/", segs.items);
}

/// 拼接相对路径并归一分隔符（台账 D9：采集侧/walker 与 stage 侧四处同形 `join`+`replaceScalar` 的单一真值）：
/// `base` 为空或 `.` 时直取 `sub`；结果恒为正斜杠形（与文档/用法示例一致，也保证 findUnit
/// 的精确匹配不因 Windows 反斜杠而退化到 stem 兜底）。返回 `gpa` 所有权。
pub fn joinRelNorm(gpa: std.mem.Allocator, base: []const u8, sub: []const u8) ![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return gpa.dupe(u8, sub);
    const joined = try std.fs.path.join(gpa, &.{ base, sub });
    std.mem.replaceScalar(u8, joined, '\\', '/');
    return joined;
}

/// 扫描一段源码里的引用词形（`leads` 函数词 + `const_leads` 单跳变量绑定词形，D2/D3 同一识别面），
/// 逐个按 `resolveEmbedZzRel` 解析为归一化的工程内 `.zz` 相对路径。台账 D9/D10：
/// 采集阶段“资产豁免预扫描”与“D4 编译单元优先”两趟同形循环的单一真值；纯函数（不碰磁盘），
/// 进 zzc_core 测试图可单测（D7：原逻辑困在 exe 图内从未被单元级覆盖）。
/// 列表元素与本体均为 `gpa` 所有权，由调用方逐个释放。
pub fn findReferencedRels(
    gpa: std.mem.Allocator,
    src: []const u8,
    src_dir: []const u8,
    leads: []const []const u8,
    const_leads: []const []const u8,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |it| gpa.free(it);
        out.deinit(gpa);
    }
    var list = try extractEmbedPathsForms(gpa, src, leads, const_leads);
    // list 元素是 src 子串（借用、非 gpa 分配），只 deinit 本体、不逐项 free。
    defer list.deinit(gpa);
    for (list.items) |p| {
        if (try resolveEmbedZzRel(gpa, src_dir, p)) |rel| {
            // rel 为新分配、尚未入列（入列后由顶部 errdefer/调用方回收）：append 失败则泄 rel（D22 族）。
            // 批量预留容量不可注入红（R10f），code-review 源头治理。
            errdefer gpa.free(rel);
            try out.append(gpa, rel);
        }
    }
    return out;
}

/// 判断“将嵌入资浅相对路径 p 拼到 base_dir 后、词法解析 `..` 结果仍严格处于镜像根 root 之内”。
/// 用于 stageEmbedAssets 的越界写守卫：若 p 为绝对（前导 `/` `\` 或盘符 `X:`）或解析后越出 root → 返回 false（不 stage）。
pub fn embedPathStaysWithin(gpa: std.mem.Allocator, root: []const u8, base_dir: []const u8, p: []const u8) !bool {
    if (p.len == 0) return false;
    if (p[0] == '/' or p[0] == '\\') return false; // 绝对（unix/unc 起头）
    if (p.len >= 2 and p[1] == ':') return false; // 盘符绝对 C:/…
    const joined = try std.fs.path.join(gpa, &.{ base_dir, p });
    defer gpa.free(joined);
    const nfull = try normalizeRelPath(gpa, joined);
    defer gpa.free(nfull);
    const nroot = try normalizeRelPath(gpa, root);
    defer gpa.free(nroot);
    // 严格处于 root 之下：前缀等于 root 且下一字符为分隔符（而非同名目录/相等）。
    return nfull.len > nroot.len and std.mem.startsWith(u8, nfull, nroot) and nfull[nroot.len] == '/';
}

test "normalizeRelPath：解 ./../、统一分隔、越界保留前导 .." {
    const a = try normalizeRelPath(std.testing.allocator, ".zzc/gen/src/../共享.bin");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings(".zzc/gen/共享.bin", a);
    const b = try normalizeRelPath(std.testing.allocator, "src\\sub\\..\\..\\..\\x");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("../x", b); // 从 src/sub 上溯三段→越过项目根、保留前导 ..
    const c = try normalizeRelPath(std.testing.allocator, "a//./b/");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("a/b", c);
}

// 护栏（第 119 轮证伪落位）：normalizeRelPath 的「连续多级前导 `..` 逐级保留」分支
// （L840 else 之「segs 非空且末段已是 .. → 追加」子路）此前零直调——既有测 L913
// `src\sub\..\..\..\x` 只在 segs 被清空后经 `len==0` 支追加单个 ..，从未走到「末段
// 已 .. 再追加 ..」的多级累加。此支是 resolveEmbedZzRel 越根判定、embedPathStaysWithin
// 越界写守卫赖以识别「逃出 N 层」的不变量：若误改判据去掉 `!eql(末段,"..")` → `../../x`
// 塌成 `x`，多级上溯被下报、越界路径伪装成工程内相对路径。本测钉死任意多个前导 .. 全数保留。
test "normalizeRelPath：连续多级前导 .. 逐级保留不折叠（越界深度即安全边界，第 119 轮证伪落位）" {
    const gpa = std.testing.allocator;
    // 双 .. 起头、无先行真实段：两段 .. 皆保留（命中「末段已是 .. → 追加」子路）。
    const a = try normalizeRelPath(gpa, "../../x");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("../../x", a);
    // 三连 .. 亦全数保留。
    const b = try normalizeRelPath(gpa, "../../../y");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("../../../y", b);
    // 真实段先被抵消、余下两级 .. 保留（混合形）。
    const c = try normalizeRelPath(gpa, "src/../../../z");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("../../z", c);
    // 纯 `../..`（无尾段）两级都留，不退化。
    const d = try normalizeRelPath(gpa, "../..");
    defer gpa.free(d);
    try std.testing.expectEqualStrings("../..", d);
}

test "embedPathStaysWithin：同目录/子目录/包内 ../ 允许，越出镜像根与绝对路径拒绝" {
    const gpa = std.testing.allocator;
    // base=.zzc/gen/src、root=.zzc/gen：
    try std.testing.expect(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "note.txt")); // 同目录
    try std.testing.expect(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "sub/数据.bin")); // 子目录
    try std.testing.expect(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "../共享.bin")); // 单 ../仍在镜像根内
    try std.testing.expect(!(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "../../evil.txt"))); // 越出 .zzc/gen
    try std.testing.expect(!(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "/etc/passwd"))); // 绝对
    try std.testing.expect(!(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", "C:/Windows/x"))); // 盘符
    try std.testing.expect(!(try embedPathStaysWithin(gpa, ".zzc/gen", ".zzc/gen/src", ""))); // 空
}

test "joinRelNorm：拼接归一正斜杠、`.` 基座直取子路" {
    const gpa = std.testing.allocator;
    const a = try joinRelNorm(gpa, "src", "sub\\mod.zz"); // Windows 混入反斜杠→归一
    defer gpa.free(a);
    try std.testing.expectEqualStrings("src/sub/mod.zz", a);
    const b = try joinRelNorm(gpa, ".", "main.zz"); // 当前目录基座：不prepend `./`
    defer gpa.free(b);
    try std.testing.expectEqualStrings("main.zz", b);
    const c = try joinRelNorm(gpa, "", "x/y.zz");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("x/y.zz", c);
}

test "findReferencedRels：方言/ASCII 两形都解、非 .zz 与越根跳过、单跳变量实参命中" {
    const gpa = std.testing.allocator;
    const leads = [_][]const u8{ "嵌入文件", "@embedFile" };
    const cs = [_][]const u8{ "常数", "const" };
    const src =
        \\常数 模板名 = "共享/模板.zz";
        \\常数 a = 嵌入文件(模板名); // 单跳变量实参
        \\const b = @embedFile("note.txt"); // 非 .zz：不碰采集
        \\常数 c = 嵌入文件("../../外.zz"); // 从 src 上溯两段→越出源根（归一后带前导 ..）
        \\常数 d = 嵌入文件("正文.zz");
    ;
    var list = try findReferencedRels(gpa, src, "src", &leads, &cs);
    defer {
        for (list.items) |it| gpa.free(it);
        list.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("src/共享/模板.zz", list.items[0]);
    try std.testing.expectEqualStrings("src/正文.zz", list.items[1]);
}

// ---------------------------------------------------------------- 第 178 轮证伪撤号增量审计
//
// 承 111/175 词边界对称不变量方法论，转审本文件两个**私有零直调谓词**——全仓仅经
// `collectConstStringBindings`/`extractEmbedPaths`/`extractEmbedPathsForms` 间接触达，其精确字节集
// 从未被任一端到端测钉住（既有测只喂：超串尾随 ASCII 数字 `嵌入文件1`、超串前导 CJK `我的嵌入文件`、
// 空格空白形 `@embedFile (  ".." )`）：
//   · `isWordCharByte`（L863）——D2「超串不拆分命中」词边界判据，`_` 下划线臂与高字节 `>=0x80`
//     边界端（0x7F 界外 vs 0x80 界内）现行数据/测试零触达；误删 `_` 臂即令 `foo_嵌入文件`/
//     `嵌入文件_x` 形超串被误拆为独立 lead 命中、错误采集路径；`>=0x80` 收窄一格即令 UTF-8 续字节
//     0x80 被当词边界、母语超串静默漏检。
//   · `skipWs`（L728）——刻意只认 `{' ','\t','\r','\n'}` **四字节**空白集（异于 `std.ascii.isWhitespace`
//     另含 0x0B 垂直制表/0x0C 进纸），lead 与 `(`、`=` 与字面量间跨 CRLF 源换行的空白全靠此跳过；
//     误摘 `\r` 臂即令 CRLF 源里 `嵌入文件\r\n(..)` 跳过停在 `\r`、非 `(` 而漏采资产。
// 探针先行以独立 oracle（不借 `std.ascii.isAlphanumeric`、显式字节区间）对全 256 字节 iff 穷举坐实
// `isWordCharByte` 真形恰为 `[0-9A-Za-z_] ∪ [0x80..0xFF]`、`skipWs` 四字节集与越界/停位边界皆自洽，
// 无在线缺陷 → 证伪撤号不占 D 号（同 111/116/170-176 判例）。落 T1+T2 两组直钉护栏测。

test "isWordCharByte：全字节 iff 穷举钉词边界集 [0-9A-Za-z_] ∪ [0x80..0xFF]（独立 oracle·第 178 轮）" {
    // 独立 oracle：显式字节区间，不复用被测函数依赖的 std.ascii.isAlphanumeric——两侧同写即失却对账意义。
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        const word = (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or
            (b >= 'a' and b <= 'z') or (b == '_') or (b >= 0x80);
        try std.testing.expect(word == isWordCharByte(b));
    }
    // 关键边界逐例点名（把 iff 穷举里最易被误改的四形固化为可读锚）。
    try std.testing.expect(isWordCharByte('_')); // 下划线臂——现行任何端到端测零喂，本测独防
    try std.testing.expect(isWordCharByte(0x80)); // 高字节含端下界（UTF-8 续字节可为 0x80）
    try std.testing.expect(!isWordCharByte(0x7F)); // DEL：紧邻 0x80 之下、系词边界非词内字符
    try std.testing.expect(!isWordCharByte('-')); // 连字符：蛇形/中划线名两侧须为词边界
}

test "skipWs：钉四字节空白集 {' ','\\t','\\r','\\n'} 跳过 + 非空白停位 + 越界/末段边界（第 178 轮）" {
    // 四类空白一并跳过——单测即钉 `\r`/`\n` 两臂（CRLF 源跨行 lead 与 `(` 间空白的跳过依赖）。
    try std.testing.expectEqual(@as(usize, 4), skipWs(" \t\r\nx", 0));
    // 非空白字节绝不跳：0x0B 垂直制表/0x0C 进纸刻意不在集内（异于 std.ascii.isWhitespace），
    // 若有人「顺手扩大」空白集即本断言红——钉住四字节显式集的定义性边界。
    try std.testing.expectEqual(@as(usize, 0), skipWs("\x0B\x0C", 0));
    // 首字节即非空白 → 原位返回（lead 紧接 `(` 的常见形）。
    try std.testing.expectEqual(@as(usize, 0), skipWs("(abc", 0));
    // from 落在非空白字节 → 不越位（即便其后有空白）。
    try std.testing.expectEqual(@as(usize, 2), skipWs("a b", 2));
    // 连续空白后停在首个非空白（lead 与字面量间多空白跳过至 `"`）。
    try std.testing.expectEqual(@as(usize, 3), skipWs("a  (", 1));
    // 末段全空白 → 返回 src.len（不越界，跳过整尾）。
    try std.testing.expectEqual(@as(usize, 4), skipWs("ab  ", 2));
    try std.testing.expectEqual(@as(usize, 4), skipWs(" \t\n\r", 0));
    // from == src.len 边界 → 恒返回 len（空尾不越界）。
    try std.testing.expectEqual(@as(usize, 2), skipWs("ab", 2));
    try std.testing.expectEqual(@as(usize, 0), skipWs("", 0));
}
