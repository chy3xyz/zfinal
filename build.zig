//! ZFinal - A high-performance Zig web framework inspired by JFinal.
//! This build script handles the framework library, CLI tool, demos, and benchmarks.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Database build options
    const enable_postgres = b.option(bool, "postgres", "Enable PostgreSQL support") orelse false;
    const enable_mysql = b.option(bool, "mysql", "Enable MySQL support") orelse false;
    const enable_sqlite = b.option(bool, "sqlite", "Enable SQLite support") orelse true;

    // Define the zfinal module
    const zfinal_mod = b.addModule("zfinal", .{
        .root_source_file = b.path("src/main.zig"),
    });

    // Library step
    const lib = b.addStaticLibrary(.{
        .name = "zfinal",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkDatabaseLibraries(lib, enable_postgres, enable_mysql, enable_sqlite);
    b.installArtifact(lib);

    // Demo executable
    const demo_exe = b.addExecutable(.{
        .name = "hello-world",
        .root_source_file = b.path("examples/hello-world/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_exe.root_module.addImport("zfinal", zfinal_mod);
    linkDatabaseLibraries(demo_exe, enable_postgres, enable_mysql, enable_sqlite);
    b.installArtifact(demo_exe);

    // Run demo step
    const run_demo_cmd = b.addRunArtifact(demo_exe);
    run_demo_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_demo_cmd.addArgs(args);
    }
    const run_demo_step = b.step("run-demo", "Run the demo app");
    run_demo_step.dependOn(&run_demo_cmd.step);

    // Blog Demo executable
    const blog_exe = b.addExecutable(.{
        .name = "blog",
        .root_source_file = b.path("examples/blog/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    blog_exe.root_module.addImport("zfinal", zfinal_mod);
    linkDatabaseLibraries(blog_exe, enable_postgres, enable_mysql, enable_sqlite);
    b.installArtifact(blog_exe);

    // Run blog demo step
    const run_blog_cmd = b.addRunArtifact(blog_exe);
    run_blog_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_blog_cmd.addArgs(args);
    }
    const run_blog_step = b.step("run-blog", "Run the blog demo app");
    run_blog_step.dependOn(&run_blog_cmd.step);

    // Blog App (Single File) executable
    const blog_app_exe = b.addExecutable(.{
        .name = "blog_app",
        .root_source_file = b.path("examples/blog-single/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    blog_app_exe.root_module.addImport("zfinal", zfinal_mod);
    linkDatabaseLibraries(blog_app_exe, enable_postgres, enable_mysql, enable_sqlite);
    b.installArtifact(blog_app_exe);

    // Run blog app step
    const run_blog_app_cmd = b.addRunArtifact(blog_app_exe);
    run_blog_app_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_blog_app_cmd.addArgs(args);
    }
    const run_blog_app_step = b.step("run-blog-app", "Run the single-file blog app");
    run_blog_app_step.dependOn(&run_blog_app_cmd.step);

    // WebSocket Demo executable
    const ws_demo_exe = b.addExecutable(.{
        .name = "websocket_demo",
        .root_source_file = b.path("examples/websocket/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ws_demo_exe.root_module.addImport("zfinal", zfinal_mod);
    ws_demo_exe.linkLibC();
    b.installArtifact(ws_demo_exe);

    // Run websocket demo step
    const run_ws_demo_cmd = b.addRunArtifact(ws_demo_exe);
    run_ws_demo_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_ws_demo_cmd.addArgs(args);
    }
    const run_ws_demo_step = b.step("run-ws-demo", "Run the websocket demo app");
    run_ws_demo_step.dependOn(&run_ws_demo_cmd.step);

    // Benchmark tool
    const bench_exe = b.addExecutable(.{
        .name = "zbench",
        .root_source_file = b.path("benchmark/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_exe.root_module.addImport("zfinal", zfinal_mod);
    b.installArtifact(bench_exe);

    const run_bench_cmd = b.addRunArtifact(bench_exe);
    run_bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_bench_cmd.addArgs(args);
    }
    const run_bench_step = b.step("run-bench", "Run the Zig benchmark tool");
    run_bench_step.dependOn(&run_bench_cmd.step);

    // zf tool (CLI)
    const zf_exe = b.addExecutable(.{
        .name = "zf",
        .root_source_file = b.path("tools/zf/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zf_exe);

    // HTMX Demo executable
    const htmx_demo_exe = b.addExecutable(.{
        .name = "htmx_demo",
        .root_source_file = b.path("examples/htmx/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    htmx_demo_exe.root_module.addImport("zfinal", zfinal_mod);
    linkDatabaseLibraries(htmx_demo_exe, enable_postgres, enable_mysql, enable_sqlite);
    b.installArtifact(htmx_demo_exe);

    const run_htmx_demo_cmd = b.addRunArtifact(htmx_demo_exe);
    run_htmx_demo_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_htmx_demo_cmd.addArgs(args);
    }
    const run_htmx_demo_step = b.step("run-htmx", "Run the HTMX demo app");
    run_htmx_demo_step.dependOn(&run_htmx_demo_cmd.step);

    // Edge Computing Demo
    const edge_demo = b.addExecutable(.{
        .name = "edge_demo",
        .root_source_file = b.path("examples/edge/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    edge_demo.root_module.addImport("zfinal", zfinal_mod);
    const run_edge_cmd = b.addRunArtifact(edge_demo);
    run_edge_cmd.step.dependOn(b.getInstallStep());
    const run_edge_step = b.step("run-edge", "Run the Edge Computing demo");
    run_edge_step.dependOn(&run_edge_cmd.step);

    // PocketBase Lite Demo
    const pb_lite_demo = b.addExecutable(.{
        .name = "pocketbase_lite",
        .root_source_file = b.path("examples/pocketbase/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    pb_lite_demo.root_module.addImport("zfinal", zfinal_mod);
    linkDatabaseLibraries(pb_lite_demo, enable_postgres, enable_mysql, enable_sqlite);
    const run_pb_lite_cmd = b.addRunArtifact(pb_lite_demo);
    run_pb_lite_cmd.step.dependOn(b.getInstallStep());
    const run_pb_lite_step = b.step("run-pb", "Run the PocketBase Lite demo");
    run_pb_lite_step.dependOn(&run_pb_lite_cmd.step);

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkDatabaseLibraries(lib_unit_tests, enable_postgres, enable_mysql, enable_sqlite);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

fn linkDatabaseLibraries(compile: *std.Build.Step.Compile, enable_postgres: bool, enable_mysql: bool, enable_sqlite: bool) void {
    if (enable_postgres) compile.linkSystemLibrary("pq");
    if (enable_mysql) compile.linkSystemLibrary("mysqlclient");
    if (enable_sqlite) compile.linkSystemLibrary("sqlite3");
    compile.linkLibC();
}
