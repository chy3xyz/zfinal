const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Prefer the same zent resolved by the parent package; fall back to this package's dep.
    const zent_dep = b.dependency("zent", .{
        .target = target,
        .optimize = optimize,
    });
    const zent_mod = zent_dep.module("zent");

    // Parent zfinal as path module (this package lives under examples/zent-shop).
    const zfinal_mod = b.addModule("zfinal", .{
        .root_source_file = b.path("../../src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zfinal_mod.linkSystemLibrary("sqlite3", .{});
    zfinal_mod.addImport("zent", zent_mod);

    // zfinal needs translated sqlite headers like the root build.
    const sqlite3_tc = b.addTranslateC(.{
        .root_source_file = b.path("../../src/db/drivers/c_sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    zfinal_mod.addImport("c_sqlite3", sqlite3_tc.createModule());

    const log_opts = b.addOptions();
    log_opts.addOption([]const u8, "log_level", "info");
    log_opts.addOption(bool, "enable_mysql", false);
    log_opts.addOption(bool, "enable_pg", false);
    log_opts.addOption(bool, "enable_zent", true);
    zfinal_mod.addImport("build_options", log_opts.createModule());

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zfinal", zfinal_mod);
    // Peer surface: prefer `zfinal.zent`; keep `zent` import for direct schema code.
    exe_mod.addImport("zent", zent_mod);
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "zent-shop",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run ZFinal + zent shop/social demo");
    run_step.dependOn(&run_cmd.step);
}
