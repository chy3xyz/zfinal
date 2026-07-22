//! `zf migrate` / `zf seed` command handlers.
const std = @import("std");
const zf_shared = @import("zf_shared.zig");
const zf_db = @import("zf_db.zig");

const openZfinalDb = zf_db.openZfinalDb;
const ZfDb = zf_db.ZfDb;
const escapeSqlString = zf_db.escapeSqlString;
const formatSqlZ = zf_db.formatSqlZ;
const readFileAlloc = zf_shared.readFileAlloc;

pub fn handleMigrate(allocator: std.mem.Allocator, action: []const u8, name: []const u8) !void {
    if (std.mem.eql(u8, action, "new")) {
        if (name.len == 0) {
            std.debug.print("Error: Migration name is required\n", .{});
            return;
        }

        const migrations_dir = "migrations";
        std.Io.Dir.cwd().createDirPath(zf_shared.io, migrations_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const timestamp = std.Io.Timestamp.now(zf_shared.io, .real).toSeconds();
        const filename = try std.fmt.allocPrint(allocator, "{s}/{d}_{s}.sql", .{ migrations_dir, timestamp, name });
        defer allocator.free(filename);

        const content =
            \\-- Migration: {s}
            \\-- Created at: {d}
            \\
            \\-- Up
            \\CREATE TABLE {s} (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
            \\
            \\-- Down
            \\DROP TABLE {s};
            \\
        ;
        // Note: Simple format string, not using the name in SQL to avoid issues, just a template
        const file_content = try std.fmt.allocPrint(allocator, content, .{ name, timestamp, name, name });
        defer allocator.free(file_content);

        try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = file_content });
        std.debug.print("✅ Created migration: {s}\n", .{filename});
    } else if (std.mem.eql(u8, action, "run") or std.mem.eql(u8, action, "up")) {
        try migrateRun(allocator);
    } else if (std.mem.eql(u8, action, "down")) {
        try migrateDown(allocator);
    } else if (std.mem.eql(u8, action, "status")) {
        try migrateStatus(allocator);
    } else {
        std.debug.print("Unknown migration action: {s}\n", .{action});
        std.debug.print("Available actions: new, run/up, down, status\n", .{});
    }
}

/// Apply all pending migrations. Driver and connection details are read from
/// environment variables (see `openZfinalDb`).
pub fn migrateRun(allocator: std.mem.Allocator) !void {
    var db = try openZfinalDb(allocator);
    defer db.deinit();

    try db.ensureMigrationsTable();
    try applyMigrations(allocator, db, "migrations", false);
}

/// Revert the most recent migration.
pub fn migrateDown(allocator: std.mem.Allocator) !void {
    var db = try openZfinalDb(allocator);
    defer db.deinit();

    try db.ensureMigrationsTable();
    try applyMigrations(allocator, db, "migrations", true);
}

/// Print applied + pending migrations.
pub fn migrateStatus(allocator: std.mem.Allocator) !void {
    var db = try openZfinalDb(allocator);
    defer db.deinit();

    try db.ensureMigrationsTable();
    try printMigrationStatus(allocator, db, "migrations");
}

// ─────────────────────────────────────────────────────────────────────────────
// SEED — populate database with initial/fixture data
// Complements `zf migrate`. Migrations create schema; seeds fill it.
// ─────────────────────────────────────────────────────────────────────────────

/// Dispatch seed subcommands: new, run, list.
pub fn handleSeed(allocator: std.mem.Allocator, action: []const u8, name: []const u8) !void {
    if (std.mem.eql(u8, action, "new")) {
        if (name.len == 0) {
            std.debug.print("Error: seed name is required\n", .{});
            return;
        }
        try seedNew(allocator, name);
    } else if (std.mem.eql(u8, action, "run") or std.mem.eql(u8, action, "up")) {
        try seedRun(allocator);
    } else if (std.mem.eql(u8, action, "list")) {
        try seedList(allocator);
    } else if (std.mem.eql(u8, action, "reset")) {
        try seedReset(allocator);
    } else {
        std.debug.print("Unknown seed action: {s}\n", .{action});
        std.debug.print("Available: new <name>, run/up, list, reset\n", .{});
    }
}

/// Create a new seed file with timestamp prefix.
pub fn seedNew(allocator: std.mem.Allocator, name: []const u8) !void {
    const seeds_dir = "seeds";
    std.Io.Dir.cwd().createDirPath(zf_shared.io, seeds_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const timestamp = std.Io.Timestamp.now(zf_shared.io, .real).toSeconds();
    const filename = try std.fmt.allocPrint(allocator, "{s}/{d}_{s}.sql", .{ seeds_dir, timestamp, name });
    defer allocator.free(filename);

    const content =
        \\-- Seed: {s}
        \\-- Created at: {d}
        \\
        \\-- Idempotent: use INSERT OR IGNORE so re-running is safe.
        \\-- Edit the INSERT statements below to match your schema.
        \\
        \\-- Example: insert 3 rows into your table.
        \\-- Replace 'my_table' and columns with your actual schema.
        \\
        \\INSERT OR IGNORE INTO users (id, name, email) VALUES
        \\  (1, 'admin', 'admin@example.com'),
        \\  (2, 'alice', 'alice@example.com'),
        \\  (3, 'bob', 'bob@example.com');
    ;
    const file_content = try std.fmt.allocPrint(allocator, content, .{ name, timestamp });
    defer allocator.free(file_content);

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = file_content });
    std.debug.print("✅ Created seed: {s}\n", .{filename});
    std.debug.print("   Run: zf seed run\n", .{});
}

/// Apply all pending seeds.
pub fn seedRun(allocator: std.mem.Allocator) !void {
    var db = try openZfinalDb(allocator);
    defer db.deinit();

    try db.ensureSeedsTable();
    try applySeeds(allocator, db, "seeds");
}

/// Show applied + pending seeds.
pub fn seedList(allocator: std.mem.Allocator) !void {
    var db = try openZfinalDb(allocator);
    defer db.deinit();

    try db.ensureSeedsTable();
    try printSeedStatus(allocator, db, "seeds");
}

/// Reset the seeds tracking table — allows re-running all seeds.
pub fn seedReset(allocator: std.mem.Allocator) !void {
    var db = try openZfinalDb(allocator);
    defer db.deinit();
    const drop_sql = "DELETE FROM _zfinal_seeds;";
    db.exec(drop_sql) catch {
        std.debug.print("✗ Reset failed.\n", .{});
        return error.SeedResetFailed;
    };
    std.debug.print("✓ Seeds tracking reset. Run `zf seed run` to re-apply.\n", .{});
}

/// Apply pending seeds in `dir` (sorted by filename = timestamp prefix).
fn applySeeds(allocator: std.mem.Allocator, db: ZfDb, dir: []const u8) !void {
    var d = std.Io.Dir.cwd().openDir(zf_shared.io, dir, .{}) catch {
        std.debug.print("⚠️  seeds dir not found: {s}\n", .{dir});
        return;
    };
    defer std.Io.Dir.close(d, zf_shared.io);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(zf_shared.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const p = try allocator.alloc(u8, dir.len + 1 + entry.name.len);
        @memcpy(p[0..dir.len], dir);
        p[dir.len] = '/';
        @memcpy(p[dir.len + 1 ..], entry.name);
        try paths.append(allocator, p);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var applied_count: u32 = 0;
    for (paths.items) |path| {
        const name = std.fs.path.basename(path);
        const name_no_ext = if (std.mem.endsWith(u8, name, ".sql")) name[0 .. name.len - 4] else name;
        if (try seedApplied(allocator, db, name_no_ext)) {
            std.debug.print("  ⏭  skip {s} (already applied)\n", .{name_no_ext});
            continue;
        }
        const content = try readMigrationFile(allocator, path);
        defer allocator.free(content);
        const sql_z = try allocator.allocSentinel(u8, content.len, 0);
        defer allocator.free(sql_z);
        @memcpy(sql_z, content);
        std.debug.print("  → seeding {s}\n", .{name_no_ext});
        db.exec(sql_z) catch {
            std.debug.print("  ✗ failed: {s}\n", .{name_no_ext});
            return error.SeedApplyFailed;
        };
        const checksum = std.hash.Crc32.hash(content);
        const escaped_name = try escapeSqlString(allocator, name_no_ext);
        defer allocator.free(escaped_name);
        const escaped_filename = try escapeSqlString(allocator, name);
        defer allocator.free(escaped_filename);
        const record_sql = try formatSqlZ(allocator, "INSERT INTO _zfinal_seeds (name, filename, checksum) VALUES ('{s}', '{s}', {d});", .{ escaped_name, escaped_filename, checksum });
        defer allocator.free(record_sql);
        try db.exec(record_sql);
        std.debug.print("  ✓ seeded {s}\n", .{name_no_ext});
        applied_count += 1;
    }
    std.debug.print("\nApplied: {d} | Skipped: {d} | Total: {d}\n", .{ applied_count, paths.items.len - applied_count, paths.items.len });
}

/// Check if a seed name has already been applied.
fn seedApplied(allocator: std.mem.Allocator, db: ZfDb, name: []const u8) !bool {
    const escaped = try escapeSqlString(allocator, name);
    defer allocator.free(escaped);
    const sql = try formatSqlZ(allocator, "SELECT 1 FROM _zfinal_seeds WHERE name = '{s}';", .{escaped});
    defer allocator.free(sql);
    return try db.queryExists(sql);
}

/// Show applied (✓) and pending (○) seeds.
fn printSeedStatus(allocator: std.mem.Allocator, db: ZfDb, dir: []const u8) !void {
    std.debug.print("\n── Seeds Status ──\n", .{});
    var d = std.Io.Dir.cwd().openDir(zf_shared.io, dir, .{}) catch {
        std.debug.print("⚠️  seeds dir not found: {s}\n", .{dir});
        return;
    };
    defer std.Io.Dir.close(d, zf_shared.io);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(zf_shared.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const p = try allocator.alloc(u8, dir.len + 1 + entry.name.len);
        @memcpy(p[0..dir.len], dir);
        p[dir.len] = '/';
        @memcpy(p[dir.len + 1 ..], entry.name);
        try paths.append(allocator, p);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var pending: u32 = 0;
    for (paths.items) |path| {
        const name = std.fs.path.basename(path);
        const name_no_ext = if (std.mem.endsWith(u8, name, ".sql")) name[0 .. name.len - 4] else name;
        if (try seedApplied(allocator, db, name_no_ext)) {
            std.debug.print("  ✓ {s}\n", .{name_no_ext});
        } else {
            std.debug.print("  ○ {s}\n", .{name_no_ext});
            pending += 1;
        }
    }
    std.debug.print("\nTotal: {d} | Pending: {d}\n", .{ paths.items.len, pending });
    if (pending > 0) std.debug.print("Run `zf seed run` to apply.\n", .{});
}

/// Apply or revert all migrations in `dir` (sorted by timestamp prefix).
fn applyMigrations(allocator: std.mem.Allocator, db: ZfDb, dir: []const u8, revert: bool) !void {
    var d = std.Io.Dir.cwd().openDir(zf_shared.io, dir, .{}) catch {
        std.debug.print("⚠️  migrations dir not found: {s}\n", .{dir});
        return;
    };
    defer std.Io.Dir.close(d, zf_shared.io);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(zf_shared.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const p = try allocator.alloc(u8, dir.len + 1 + entry.name.len);
        @memcpy(p[0..dir.len], dir);
        p[dir.len] = '/';
        @memcpy(p[dir.len + 1 ..], entry.name);
        try paths.append(allocator, p);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    if (!revert) {
        for (paths.items) |path| {
            const version = std.fs.path.basename(path);
            const version_trimmed = if (std.mem.endsWith(u8, version, ".sql"))
                version[0 .. version.len - 4]
            else
                version;
            const applied = try migrationApplied(allocator, db, version_trimmed);
            if (applied) continue;
            // Extract only the UP section (avoid executing DROP on first run)
            const up_sql = try extractSection(allocator, version, .up);
            defer allocator.free(up_sql);
            if (up_sql.len == 0) {
                std.debug.print("  ! no UP section in {s}\n", .{version_trimmed});
                continue;
            }
            const sql_z = try allocator.allocSentinel(u8, up_sql.len, 0);
            defer allocator.free(sql_z);
            @memcpy(sql_z, up_sql);
            std.debug.print("  → applying {s}\n", .{version_trimmed});
            db.exec(sql_z) catch {
                std.debug.print("  ✗ failed: {s}\n", .{version_trimmed});
                return error.MigrationApplyFailed;
            };
            const checksum = std.hash.Crc32.hash(up_sql);
            const escaped_version = try escapeSqlString(allocator, version_trimmed);
            defer allocator.free(escaped_version);
            const escaped_filename = try escapeSqlString(allocator, version);
            defer allocator.free(escaped_filename);
            const record_sql = try formatSqlZ(allocator, "INSERT INTO _zfinal_migrations (version, filename, checksum) VALUES ('{s}', '{s}', {d});", .{ escaped_version, escaped_filename, checksum });
            defer allocator.free(record_sql);
            try db.exec(record_sql);
            std.debug.print("  ✓ applied  {s}\n", .{version_trimmed});
        }
    } else {
        // Revert: find latest applied, execute its Down section.
        const latest = (try findLatestApplied(allocator, db)) orelse {
            std.debug.print("No migrations applied yet.\n", .{});
            return;
        };
        defer allocator.free(latest._owned);
        const down_sql = try extractSection(allocator, latest.filename, .down);
        defer allocator.free(down_sql);
        if (down_sql.len == 0) {
            std.debug.print("  ! no DOWN section in {s} — manual revert required\n", .{latest.filename});
            return;
        }
        const down_z = try allocator.allocSentinel(u8, down_sql.len, 0);
        defer allocator.free(down_z);
        @memcpy(down_z, down_sql);
        std.debug.print("  ← reverting {s}\n", .{latest.version});
        db.exec(down_z) catch {
            std.debug.print("  ✗ revert failed: {s}\n", .{latest.version});
            return error.MigrationRevertFailed;
        };
        const escaped_version = try escapeSqlString(allocator, latest.version);
        defer allocator.free(escaped_version);
        const del_sql = try formatSqlZ(allocator, "DELETE FROM _zfinal_migrations WHERE version = '{s}';", .{escaped_version});
        defer allocator.free(del_sql);
        try db.exec(del_sql);
        std.debug.print("  ✓ reverted {s}\n", .{latest.version});
    }
}

/// Show applied (✓) and pending (○) migrations.
fn printMigrationStatus(allocator: std.mem.Allocator, db: ZfDb, dir: []const u8) !void {
    var d = std.Io.Dir.cwd().openDir(zf_shared.io, dir, .{}) catch {
        std.debug.print("⚠️  migrations dir not found: {s}\n", .{dir});
        return;
    };
    defer std.Io.Dir.close(d, zf_shared.io);

    std.debug.print("\n── Migrations Status ──\n", .{});

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(zf_shared.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const p = try allocator.alloc(u8, dir.len + 1 + entry.name.len);
        @memcpy(p[0..dir.len], dir);
        p[dir.len] = '/';
        @memcpy(p[dir.len + 1 ..], entry.name);
        try paths.append(allocator, p);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var pending: u32 = 0;
    for (paths.items) |path| {
        const version = std.fs.path.basename(path);
        const version_trimmed = if (std.mem.endsWith(u8, version, ".sql"))
            version[0 .. version.len - 4]
        else
            version;
        const applied = try migrationApplied(allocator, db, version_trimmed);
        if (applied) {
            std.debug.print("  ✓ {s}\n", .{version_trimmed});
        } else {
            std.debug.print("  ○ {s}\n", .{version_trimmed});
            pending += 1;
        }
    }
    std.debug.print("\nTotal: {d} | Pending: {d}\n", .{ paths.items.len, pending });
    if (pending > 0) std.debug.print("Run `zf migrate up` to apply.\n", .{});
}

/// Check if a migration version is already applied.
fn migrationApplied(allocator: std.mem.Allocator, db: ZfDb, version: []const u8) !bool {
    const escaped = try escapeSqlString(allocator, version);
    defer allocator.free(escaped);
    const sql = try formatSqlZ(allocator, "SELECT 1 FROM _zfinal_migrations WHERE version = '{s}';", .{escaped});
    defer allocator.free(sql);
    return try db.queryExists(sql);
}

const AppliedMigration = struct { version: []const u8, filename: []const u8, _owned: []u8 };

/// Find the most recently applied migration (latest version).
/// Caller must free `result._owned` after use.
fn findLatestApplied(allocator: std.mem.Allocator, db: ZfDb) !?AppliedMigration {
    const version_sql = "SELECT version FROM _zfinal_migrations ORDER BY applied_at DESC LIMIT 1;";
    const filename_sql = "SELECT filename FROM _zfinal_migrations ORDER BY applied_at DESC LIMIT 1;";
    const version = (try db.queryText(allocator, version_sql)) orelse return null;
    errdefer allocator.free(version);
    const filename = (try db.queryText(allocator, filename_sql)) orelse {
        allocator.free(version);
        return null;
    };
    const owned = try allocator.alloc(u8, version.len + filename.len + 1);
    @memcpy(owned[0..version.len], version);
    @memcpy(owned[version.len .. version.len + filename.len], filename);
    owned[version.len + filename.len] = 0;
    allocator.free(version);
    allocator.free(filename);
    return .{
        .version = owned[0..version.len],
        .filename = owned[version.len..][0..filename.len],
        ._owned = owned,
    };
}

const Section = enum { up, down };

/// Extract the "-- Up" or "-- Down" section from a migration file.
fn extractSection(allocator: std.mem.Allocator, filename: []const u8, section: Section) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{filename});
    defer allocator.free(path);
    const content = readMigrationFile(allocator, path) catch {
        return &[_]u8{};
    };
    defer allocator.free(content);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var in_section = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "-- Up")) {
            in_section = section == .up;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "-- Down")) {
            in_section = section == .down;
            continue;
        }
        if (in_section and !std.mem.startsWith(u8, trimmed, "-- ")) {
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn readMigrationFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // (delegates to existing readFileAlloc)
    return readFileAlloc(allocator, path);
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
