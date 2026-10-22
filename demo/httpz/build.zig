const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 真依赖：httpz（其 build.zig 以 addModule("httpz") 暴露、自带 metrics/websocket 传递依赖）。
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // 阶段1存在性验证：把拟定要翻译的每条 httpz API 路径写进 check_api.zig，编译过即坐实其存在。
    // Zig 0.17 形制：addExecutable 收 root_module，模块经 createModule 建并把 httpz 挂进 imports。
    const check_module = b.createModule(.{
        .root_source_file = b.path("check_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz_dep.module("httpz") },
        },
    });
    const check_exe = b.addExecutable(.{
        .name = "check_api",
        .root_module = check_module,
    });
    b.getInstallStep().dependOn(&check_exe.step);
}
