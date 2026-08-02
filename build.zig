//! ZFinal - A high-performance Zig web framework inspired by JFinal.

const std = @import("std");
const fw_version = @import("src/version.zig");
const package_zon = @import("build.zig.zon");

comptime {
    if (!std.mem.eql(u8, fw_version.semver, package_zon.version)) {
        @compileError("src/version.zig semver must match build.zig.zon .version");
    }
}

fn addExample(
    b: *std.Build,
    zfinal_mod: *std.Build.Module,
    name: []const u8,
    root_file: []const u8,
    desc: []const u8,
    driver_mysql: bool,
    driver_pg: bool,
) void {
    const example_mod = b.createModule(.{
        .root_source_file = b.path(root_file),
        .target = zfinal_mod.resolved_target orelse b.standardTargetOptions(.{}),
        .optimize = zfinal_mod.optimize orelse .Debug,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    example_mod.link_libc = true;
    example_mod.linkSystemLibrary("sqlite3", .{});
    linkOptionalDbDrivers(example_mod, driver_mysql, driver_pg);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = example_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step(b.fmt("run-{s}", .{name}), desc);
    run_step.dependOn(&run_cmd.step);
}

fn linkOptionalDbDrivers(mod: *std.Build.Module, driver_mysql: bool, driver_pg: bool) void {
    if (driver_mysql) mod.linkSystemLibrary("mysqlclient", .{});
    if (driver_pg) mod.linkSystemLibrary("pq", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Driver flags (declared early for translate-c conditional blocks) ---
    const driver_mysql = b.option(bool, "driver_mysql", "Enable MySQL driver") orelse false;
    const driver_pg = b.option(bool, "driver_pg", "Enable PostgreSQL driver") orelse false;
    const enable_pg = b.option(bool, "enable-pg", "Enable PostgreSQL introspection (requires libpq)") orelse false;
    const enable_mysql = b.option(bool, "enable-mysql", "Enable MySQL introspection (requires libmysqlclient)") orelse false;

    // Platform-aware include paths (user overridable)
    const mysql_include = b.option([]const u8, "mysql-include", "Path to MySQL include directory (e.g. /usr/include/mysql)");
    const pg_include = b.option([]const u8, "pg-include", "Path to PostgreSQL include directory (e.g. /usr/include/postgresql)");

    // Detect platform-appropriate defaults
    const native_os = target.result.os.tag;
    const default_mysql_include: []const u8 = if (native_os == .macos) "/opt/homebrew/include" else "/usr/include/mysql";
    const default_pg_include: []const u8 = if (native_os == .macos) "/opt/homebrew/opt/libpq/include" else "/usr/include/postgresql";

    // --- C header translation (Zig 0.17: @cImport removed, use build-system translate-c) ---

    // SQLite — always available (system SDK or Homebrew)
    const sqlite3_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/db/drivers/c_sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    const sqlite3_c_mod = sqlite3_tc.createModule();

    // MySQL for framework (mysql/mysql.h) — conditional on driver flag
    const mysql_c_mod = if (driver_mysql) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("src/db/drivers/c_mysql.h"),
            .target = target,
            .optimize = optimize,
        });
        tc.addSystemIncludePath(.{ .cwd_relative = mysql_include orelse default_mysql_include });
        break :blk tc.createModule();
    } else null;

    // PostgreSQL for framework (libpq-fe.h) — conditional on driver flag
    const pg_c_mod = if (driver_pg) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("src/db/drivers/c_postgres.h"),
            .target = target,
            .optimize = optimize,
        });
        tc.addSystemIncludePath(.{ .cwd_relative = pg_include orelse default_pg_include });
        break :blk tc.createModule();
    } else null;

    // MySQL for zf CLI (mysql.h) — conditional
    const mysql_zf_c_mod = if (enable_mysql) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("tools/zf/c_mysql.h"),
            .target = target,
            .optimize = optimize,
        });
        tc.addSystemIncludePath(.{ .cwd_relative = mysql_include orelse default_mysql_include });
        break :blk tc.createModule();
    } else null;

    // PostgreSQL for zf CLI (libpq-fe.h) — conditional
    const pg_zf_c_mod = if (enable_pg) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("tools/zf/c_pg.h"),
            .target = target,
            .optimize = optimize,
        });
        tc.addSystemIncludePath(.{ .cwd_relative = pg_include orelse default_pg_include });
        break :blk tc.createModule();
    } else null;

    // --- Log level build option ---
    const log_level = b.option(
        []const u8,
        "log-level",
        "Minimum log level: debug, info, warn, err (default: info)",
    ) orelse "info";

    const enable_zent = b.option(bool, "enable-zent", "Enable zent data layer (alternative/primary to DB/Model; default on)") orelse true;

    // Define the zfinal module
    const zfinal_mod = b.addModule("zfinal", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zfinal_mod.link_libc = true;
    zfinal_mod.linkSystemLibrary("sqlite3", .{});
    linkOptionalDbDrivers(zfinal_mod, driver_mysql, driver_pg);
    zfinal_mod.addImport("c_sqlite3", sqlite3_c_mod);
    if (mysql_c_mod) |m| zfinal_mod.addImport("c_mysql", m);
    if (pg_c_mod) |p| zfinal_mod.addImport("c_pg", p);

    // Peer data layer: zent (ent-style). Same product surface as DB/Model when enabled.
    if (enable_zent) {
        const zent_dep = b.dependency("zent", .{
            .target = target,
            .optimize = optimize,
        });
        zfinal_mod.addImport("zent", zent_dep.module("zent"));
    }

    // Inject compile-time log level via a generated options module
    const log_opts = b.addOptions();
    log_opts.addOption([]const u8, "log_level", log_level);
    log_opts.addOption(bool, "enable_mysql", driver_mysql);
    log_opts.addOption(bool, "enable_pg", driver_pg);
    log_opts.addOption(bool, "enable_zent", enable_zent);
    zfinal_mod.addImport("build_options", log_opts.createModule());

    // Tests (unit)
    // NOTE: Zig 0.17-dev server-mode test runner crashes with EndOfStream on this
    // machine, so run the compiled test binary directly in standalone mode.
    const lib_unit_tests = b.addTest(.{
        .root_module = zfinal_mod,
    });
    const run_lib_unit_tests = b.addRunFile(lib_unit_tests.getEmittedBin());
    run_lib_unit_tests.expectExitCode(0);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Integration tests (generated CRUD against real DB)
    const int_mod = b.createModule(.{
        .root_source_file = b.path("test_gen_crud.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    int_mod.link_libc = true;
    int_mod.linkSystemLibrary("sqlite3", .{});
    linkOptionalDbDrivers(int_mod, driver_mysql, driver_pg);
    const int_tests = b.addTest(.{ .root_module = int_mod });
    const run_int_tests = b.addRunArtifact(int_tests);
    const int_test_step = b.step("test-int", "Run integration tests (requires generated modules)");
    int_test_step.dependOn(&run_int_tests.step);

    // DB integration tests — run as part of unit tests (imported via main.zig)
    const db_int_test_step = b.step("test-db", "Run DB integration tests (alias for test)");
    db_int_test_step.dependOn(&run_lib_unit_tests.step);

    // Example runners
    addExample(b, zfinal_mod, "hello", "examples/hello-world/main.zig", "Run hello-world demo", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "blog", "examples/blog-single/main.zig", "Run blog-single demo", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "ai-blog-5min", "examples/ai-blog-5min/main.zig", "Run 5-minute AI speedrun demo (blog CRUD scaffold)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "ai-runtime", "examples/ai-runtime/main.zig", "Run offline zfinal.ai runtime demo (Agent/Workflow/skills)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "ai-live", "examples/ai-live/main.zig", "Run live LLM demo (needs OPENAI_API_KEY)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "htmx", "examples/htmx/main.zig", "Run HTMX demo", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "htmx-admin", "examples/htmx-admin/main.zig", "Run vben-style admin UI demo (run `zf admin` first)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "htmx-admin-demo", "examples/htmx-admin-demo/main.zig", "Run full-stack multi-table admin demo (3 tables, search, multi-table sidebar)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "standalone-admin", "examples/standalone-admin/main.zig", "Run standalone single-binary admin (all HTML @embedFile, zero deps)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "ws", "examples/websocket/main.zig", "Run WebSocket demo (ZFinal.addWebSocket)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "oauth2", "examples/oauth2/main.zig", "Run OAuth2 PKCE helpers demo (offline)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "edge", "examples/edge/main.zig", "Run edge computing demo", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "auth", "examples/auth/main.zig", "Run auth demo", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "captcha", "examples/captcha/main.zig", "Run captcha demo", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "production", "examples/production/main.zig", "Run production example", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "ports-l2", "examples/ports-l2/main.zig", "Run L2 ports DI demo (store/cache/bus)", driver_mysql, driver_pg);
    addExample(b, zfinal_mod, "ports-l3", "examples/ports-l3/main.zig", "Run L3 ports DI demo (store/cache/bus/outbox + tenant)", driver_mysql, driver_pg);
    // RuoYi example — only when MySQL driver is enabled (needs libmysqlclient)
    if (driver_mysql) {
        const ruoyi_mod = b.createModule(.{
            .root_source_file = b.path("examples/ruoyi-gen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
        });
        ruoyi_mod.link_libc = true;
        ruoyi_mod.linkSystemLibrary("sqlite3", .{});
        linkOptionalDbDrivers(ruoyi_mod, driver_mysql, driver_pg);
        const ruoyi_exe = b.addExecutable(.{ .name = "ruoyi-gen", .root_module = ruoyi_mod });
        b.installArtifact(ruoyi_exe);
        const ruoyi_run = b.addRunArtifact(ruoyi_exe);
        ruoyi_run.step.dependOn(b.getInstallStep());
        const ruoyi_step = b.step("run-ruoyi-gen", "Run RuoYi generated API (MySQL)");
        ruoyi_step.dependOn(&ruoyi_run.step);
    }

    // zent-shop demo (uses package zent; path sibling optional for local edit)
    {
        const zs_step = b.step("run-zent-shop", "Run zent-shop demo (zfinal.zent peer data layer; see doc/zent.md)");
        const note = b.addSystemCommand(&.{
            "sh", "-c",
            \\cd examples/zent-shop && exec zig build run
        });
        zs_step.dependOn(&note.step);
    }

    // PocketBase demo (more complex, has its own src/ tree)
    const pb_mod = b.createModule(.{
        .root_source_file = b.path("examples/pocketbase/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    pb_mod.link_libc = true;
    pb_mod.linkSystemLibrary("sqlite3", .{});
    linkOptionalDbDrivers(pb_mod, driver_mysql, driver_pg);
    const pb_exe = b.addExecutable(.{
        .name = "pb",
        .root_module = pb_mod,
    });
    b.installArtifact(pb_exe);
    const run_pb = b.addRunArtifact(pb_exe);
    run_pb.step.dependOn(b.getInstallStep());
    const run_pb_step = b.step("run-pb", "Run PocketBase demo");
    run_pb_step.dependOn(&run_pb.step);

    // CLI tool (zf) — version derived from src/version.zig (must match build.zig.zon)
    const zf_opts = b.addOptions();
    zf_opts.addOption(bool, "enable_pg", enable_pg);
    zf_opts.addOption(bool, "enable_my", enable_mysql);
    zf_opts.addOption([]const u8, "version", fw_version.tag);
    zf_opts.addOption([]const u8, "semver", fw_version.semver);

    const version_mod = b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zf_mod = b.createModule(.{
        .root_source_file = b.path("tools/zf/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zf_cfg", .module = zf_opts.createModule() },
            .{ .name = "zfinal_version", .module = version_mod },
        },
    });
    // Expose codegen as a named module so admin_templates.zig can
    // import it as @import("codegen") instead of @import("codegen.zig").
    {
        const codegen_for_zf = b.createModule(.{
            .root_source_file = b.path("tools/zf/codegen.zig"),
            .target = target,
            .optimize = optimize,
        });
        codegen_for_zf.link_libc = true;
        codegen_for_zf.linkSystemLibrary("sqlite3", .{});
        codegen_for_zf.addImport("c_sqlite3", sqlite3_c_mod);
        zf_mod.addImport("codegen", codegen_for_zf);
    }
    {
        const zent_cg = b.createModule(.{
            .root_source_file = b.path("tools/zf/zent_codegen.zig"),
            .target = target,
            .optimize = optimize,
        });
        zent_cg.addImport("zfinal_version", version_mod);
        zf_mod.addImport("zent_codegen", zent_cg);
    }
    {
        const openapi_for_zf = b.createModule(.{
            .root_source_file = b.path("tools/zf/openapi.zig"),
            .target = target,
            .optimize = optimize,
        });
        zf_mod.addImport("openapi", openapi_for_zf);
    }
    {
        // Vendored [zdeadcode](https://github.com/chy3xyz/zdeadcode) — `zf check --deadcode`
        const deadcode_mod = b.createModule(.{
            .root_source_file = b.path("tools/zf/deadcode.zig"),
            .target = target,
            .optimize = optimize,
        });
        zf_mod.addImport("deadcode", deadcode_mod);
    }
    zf_mod.link_libc = true;
    zf_mod.linkSystemLibrary("sqlite3", .{});
    if (enable_pg) zf_mod.linkSystemLibrary("pq", .{});
    if (enable_mysql) zf_mod.linkSystemLibrary("mysqlclient", .{});
    zf_mod.addImport("c_sqlite3", sqlite3_c_mod);
    if (mysql_zf_c_mod) |m| zf_mod.addImport("c_mysql", m);
    if (pg_zf_c_mod) |p| zf_mod.addImport("c_pg", p);

    const zf_exe = b.addExecutable(.{
        .name = "zf",
        .root_module = zf_mod,
    });
    b.installArtifact(zf_exe);
    const install_zf_step = b.step("install-zf", "Install zf CLI tool");
    install_zf_step.dependOn(b.getInstallStep());

    // Productized quality / release gates (scripts/quality_gate.sh)
    {
        const gate_full = b.addSystemCommand(&.{ "bash", "scripts/quality_gate.sh", "full" });
        const gate_step = b.step("gate", "Run full quality gate (fmt/version/test/test-zf/ReleaseSafe/zf check)");
        gate_step.dependOn(&gate_full.step);

        const gate_quick = b.addSystemCommand(&.{ "bash", "scripts/quality_gate.sh", "quick" });
        const gate_quick_step = b.step("gate-quick", "Run quick quality gate (fmt/version/build/test/test-zf)");
        gate_quick_step.dependOn(&gate_quick.step);

        const gate_release = b.addSystemCommand(&.{ "bash", "scripts/quality_gate.sh", "release", "--strict" });
        const release_gate_step = b.step("release-gate", "Run release gate (full + CHANGELOG + tag check; --strict)");
        release_gate_step.dependOn(&gate_release.step);
    }

    // Benchmark tool
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmark/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    bench_mod.link_libc = true;
    bench_mod.linkSystemLibrary("sqlite3", .{});
    linkOptionalDbDrivers(bench_mod, driver_mysql, driver_pg);
    const bench_exe = b.addExecutable(.{
        .name = "zbench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);
    const run_bench_cmd = b.addRunArtifact(bench_exe);
    run_bench_cmd.step.dependOn(b.getInstallStep());
    const run_bench_step = b.step("run-bench", "Run benchmark tool");
    run_bench_step.dependOn(&run_bench_cmd.step);

    // DB result decoding micro-benchmark (v0.15.0 vs legacy text parseInt)
    {
        const db_bench_mod = b.createModule(.{
            .root_source_file = b.path("benchmark/db_decode.zig"),
            .target = target,
            .optimize = .ReleaseFast, // bench must be optimized to be meaningful
            .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
        });
        db_bench_mod.link_libc = true;
        db_bench_mod.linkSystemLibrary("sqlite3", .{});
        linkOptionalDbDrivers(db_bench_mod, driver_mysql, driver_pg);
        const db_bench_exe = b.addExecutable(.{
            .name = "zbench-db",
            .root_module = db_bench_mod,
        });
        b.installArtifact(db_bench_exe);
        const run_db_bench_cmd = b.addRunArtifact(db_bench_exe);
        run_db_bench_cmd.step.dependOn(b.getInstallStep());
        const run_db_bench_step = b.step("run-db-bench", "Run DB result decoding benchmark (v0.15.0 typed vs legacy)");
        run_db_bench_step.dependOn(&run_db_bench_cmd.step);
    }

    // sockread / HttpClient isolation micro-benchmark
    {
        const sr_bench_mod = b.createModule(.{
            .root_source_file = b.path("benchmark/sockread_io.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
        });
        sr_bench_mod.link_libc = true;
        sr_bench_mod.linkSystemLibrary("sqlite3", .{});
        linkOptionalDbDrivers(sr_bench_mod, driver_mysql, driver_pg);
        const sr_bench_exe = b.addExecutable(.{
            .name = "zbench-sockread",
            .root_module = sr_bench_mod,
        });
        b.installArtifact(sr_bench_exe);
        const run_sr_bench_cmd = b.addRunArtifact(sr_bench_exe);
        run_sr_bench_cmd.step.dependOn(b.getInstallStep());
        const run_sr_bench_step = b.step("run-sockread-bench", "Run sockread vs Io + HttpClient isolation micro-bench");
        run_sr_bench_step.dependOn(&run_sr_bench_cmd.step);
    }

    // NATS integration test — disabled (NATS v0.1.0 incompatible with Zig 0.17-dev.704)
    // TODO: re-enable when NATS releases a 0.17-compatible version
    //const nats_test_step = b.step("test-nats", "Run NATS integration test (requires nats-server)");

    // zf code generator regression tests
    {
        const codegen_mod = b.createModule(.{
            .root_source_file = b.path("tools/zf/codegen.zig"),
            .target = target,
            .optimize = optimize,
        });
        codegen_mod.link_libc = true;
        codegen_mod.linkSystemLibrary("sqlite3", .{});
        codegen_mod.addImport("c_sqlite3", sqlite3_c_mod);

        const admin_templates_mod = b.createModule(.{
            .root_source_file = b.path("tools/zf/admin_templates.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "codegen", .module = codegen_mod },
            },
        });
        admin_templates_mod.link_libc = true;
        admin_templates_mod.linkSystemLibrary("sqlite3", .{});
        admin_templates_mod.addImport("c_sqlite3", sqlite3_c_mod);

        const zent_cg_mod = b.createModule(.{
            .root_source_file = b.path("tools/zf/zent_codegen.zig"),
            .target = target,
            .optimize = optimize,
        });
        zent_cg_mod.addImport("zfinal_version", version_mod);

        const openapi_mod = b.createModule(.{
            .root_source_file = b.path("tools/zf/openapi.zig"),
            .target = target,
            .optimize = optimize,
        });

        const zf_test_mod = b.createModule(.{
            .root_source_file = b.path("tools/zf/codegen_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "codegen", .module = codegen_mod },
                .{ .name = "admin_templates", .module = admin_templates_mod },
                .{ .name = "zent_codegen", .module = zent_cg_mod },
                .{ .name = "openapi", .module = openapi_mod },
                .{ .name = "zfinal_version", .module = version_mod },
                .{ .name = "zone_merge", .module = b.createModule(.{
                    .root_source_file = b.path("tools/zf/zone_merge.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        });
        zf_test_mod.link_libc = true;
        zf_test_mod.linkSystemLibrary("sqlite3", .{});
        zf_test_mod.addImport("c_sqlite3", sqlite3_c_mod);
        const zf_tests = b.addTest(.{ .root_module = zf_test_mod });
        const run_zf_tests = b.addRunFile(zf_tests.getEmittedBin());
        run_zf_tests.expectExitCode(0);

        const routes_test_mod = b.createModule(.{
            .root_source_file = b.path("tools/zf/cmd_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        const routes_tests = b.addTest(.{ .root_module = routes_test_mod });
        const run_routes_tests = b.addRunFile(routes_tests.getEmittedBin());
        run_routes_tests.expectExitCode(0);

        const zf_test_step = b.step("test-zf", "Run zf code generator regression tests");
        zf_test_step.dependOn(&run_zf_tests.step);
        zf_test_step.dependOn(&run_routes_tests.step);
    }
}
