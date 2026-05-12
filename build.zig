//! ZFinal - A high-performance Zig web framework inspired by JFinal.

const std = @import("std");

fn addExample(b: *std.Build, zfinal_mod: *std.Build.Module, name: []const u8, root_file: []const u8, desc: []const u8) void {
    const example_mod = b.createModule(.{
        .root_source_file = b.path(root_file),
        .target = zfinal_mod.resolved_target orelse b.standardTargetOptions(.{}),
        .optimize = zfinal_mod.optimize orelse .Debug,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    example_mod.link_libc = true;
    example_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = example_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(b.fmt("run-{s}", .{name}), desc);
    run_step.dependOn(&run_cmd.step);
}

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

    // Example runners
    addExample(b, zfinal_mod, "hello", "examples/hello-world/main.zig", "Run hello-world demo");
    addExample(b, zfinal_mod, "blog", "examples/blog-single/main.zig", "Run blog-single demo");
    addExample(b, zfinal_mod, "htmx", "examples/htmx/main.zig", "Run HTMX demo");
    addExample(b, zfinal_mod, "ws", "examples/websocket/main.zig", "Run WebSocket demo");
    addExample(b, zfinal_mod, "edge", "examples/edge/main.zig", "Run edge computing demo");
    addExample(b, zfinal_mod, "auth", "examples/auth/main.zig", "Run auth demo");
    addExample(b, zfinal_mod, "captcha", "examples/captcha/main.zig", "Run captcha demo");

    // PocketBase demo (more complex, has its own src/ tree)
    const pb_mod = b.createModule(.{
        .root_source_file = b.path("examples/pocketbase/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    pb_mod.link_libc = true;
    pb_mod.linkSystemLibrary("sqlite3", .{});
    const pb_exe = b.addExecutable(.{
        .name = "pb",
        .root_module = pb_mod,
    });
    b.installArtifact(pb_exe);
    const run_pb = b.addRunArtifact(pb_exe);
    run_pb.step.dependOn(b.getInstallStep());
    const run_pb_step = b.step("run-pb", "Run PocketBase demo");
    run_pb_step.dependOn(&run_pb.step);

    // CLI tool (zf)
    const zf_mod = b.createModule(.{
        .root_source_file = b.path("tools/zf/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zf_exe = b.addExecutable(.{
        .name = "zf",
        .root_module = zf_mod,
    });
    b.installArtifact(zf_exe);
    const install_zf_step = b.step("install-zf", "Install zf CLI tool");
    install_zf_step.dependOn(b.getInstallStep());

    // Benchmark tool
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmark/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    bench_mod.link_libc = true;
    bench_mod.linkSystemLibrary("sqlite3", .{});
    const bench_exe = b.addExecutable(.{
        .name = "zbench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);
    const run_bench_cmd = b.addRunArtifact(bench_exe);
    run_bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_bench_cmd.addArgs(args);
    }
    const run_bench_step = b.step("run-bench", "Run benchmark tool");
    run_bench_step.dependOn(&run_bench_cmd.step);
}
