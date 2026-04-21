//! ZFinal - A high-performance Zig web framework inspired by JFinal.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Define the zfinal module
    const zfinal_mod = b.addModule("zfinal", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
zfinal_mod.link_libc = true;
zfinal_mod.linkSystemLibrary("sqlite3", .{});

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = zfinal_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Benchmark tool (disabled - needs Zig 0.16 porting)
    // TODO: Port benchmark to Zig 0.16
    // const bench_mod = b.createModule(.{
    //     .root_source_file = b.path("benchmark/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    //     .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    // });
    // const bench_exe = b.addExecutable(.{
    //     .name = "zbench",
    //     .root_module = bench_mod,
    // });
    // b.installArtifact(bench_exe);
    //
    // const run_bench_cmd = b.addRunArtifact(bench_exe);
    // run_bench_cmd.step.dependOn(b.getInstallStep());
    // if (b.args) |args| {
    //     run_bench_cmd.addArgs(args);
    // }
    // const run_bench_step = b.step("run-bench", "Run the Zig benchmark tool");
    // run_bench_step.dependOn(&run_bench_cmd.step);
}
