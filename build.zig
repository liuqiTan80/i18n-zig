const std = @import("std");

/// zzc —— 母语 Zig 方言编译器（transpiler + 工具链驱动）。
/// 模块 zzc_core 暴露翻译/报错回译引擎（供测试与第三方嵌入），
/// exe zzc 是 CLI 入口。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zzc_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zzc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zzc_core", .module = mod },
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
    const test_step = b.step("test", "运行单元与快照测试");
    test_step.dependOn(&run_mod_tests.step);
}
