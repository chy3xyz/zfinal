//! `zf migrate` / `zf seed` command handlers.
const std = @import("std");
const zf_shared = @import("zf_shared.zig");
const zf_db = @import("zf_db.zig");

const codegen = @import("codegen");
const sqlite_c = zf_db.sqlite_c;
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
        const name = std.Io.Dir.path.basename(path);
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
        const name = std.Io.Dir.path.basename(path);
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
            const version = std.Io.Dir.path.basename(path);
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
        const version = std.Io.Dir.path.basename(path);
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

// ─────────────────────────────────────────────────────────────────────────────
// DIFF — draft incremental DDL from schema.gen.sql vs the live database (C2)
// Compares the desired schema (src/modules/*/schema.gen.sql + ./schema.gen.sql)
// against the actual project database and emits ALTER/CREATE drafts. Dropping
// data is never automatic: removals come back as commented statements for
// review. v1 introspects SQLite project DBs (the default driver); PG/MySQL
// print an explicit unsupported note.
// ─────────────────────────────────────────────────────────────────────────────

/// One CREATE statement scanned verbatim from a schema file.
const SchemaStmt = struct {
    kind: Kind,
    name: []const u8, // table or index name
    sql: []const u8, // verbatim statement (without trailing ';')

    const Kind = enum { create_table, create_index };

    fn eqlName(self: SchemaStmt, other: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, other);
    }
};

fn isCreateKeyword(sql: []const u8, at: usize) bool {
    if (at + 6 > sql.len) return false;
    if (at > 0) {
        const prev = sql[at - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '_') return false;
    }
    const word = "create";
    for (word, 0..) |ch, k| {
        if (std.ascii.toLower(sql[at + k]) != ch) return false;
    }
    return true;
}

fn skipWs(content: []const u8, i: *usize) void {
    while (i.* < content.len and (content[i.*] == ' ' or content[i.*] == '\t' or content[i.*] == '\n' or content[i.*] == '\r')) i.* += 1;
}

fn skipToken(content: []const u8, i: *usize) void {
    while (i.* < content.len and (std.ascii.isAlphanumeric(content[i.*]) or content[i.*] == '_')) i.* += 1;
}

/// Scan `CREATE TABLE` / `CREATE [UNIQUE] INDEX` statements from a schema file.
/// Statements end at `;` outside single quotes; parens are balanced so
/// semicolons inside `DEFAULT 'a;b'` literals do not split statements.
fn scanStatements(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList(SchemaStmt) {
    var out: std.ArrayList(SchemaStmt) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;

    while (i < content.len) {
        skipWs(content, &i);
        if (i < content.len and content[i] == '-' and i + 1 < content.len and content[i + 1] == '-') {
            while (i < content.len and content[i] != '\n') i += 1;
            continue;
        }
        if (i >= content.len) break;
        if (!isCreateKeyword(content, i)) {
            while (i < content.len and content[i] != '\n' and content[i] != ';') i += 1;
            if (i < content.len and content[i] == ';') i += 1;
            continue;
        }

        const stmt_start = i;
        var j = i + "create".len;
        skipWs(content, &j);
        var kind: SchemaStmt.Kind = .create_table;
        var after_keyword = j;
        if (j + 6 <= content.len and std.ascii.eqlIgnoreCase(content[j .. j + 6], "unique")) {
            j += 6;
            skipWs(content, &j);
            after_keyword = j;
        }
        if (j + 5 <= content.len and std.ascii.eqlIgnoreCase(content[j .. j + 5], "index")) {
            kind = .create_index;
            after_keyword = j + 5;
        } else if (j + 5 <= content.len and std.ascii.eqlIgnoreCase(content[j .. j + 5], "table")) {
            after_keyword = j + 5;
        } else {
            // CREATE TRIGGER/VIEW/… — not our target; skip this line
            while (i < content.len and content[i] != '\n' and content[i] != ';') i += 1;
            if (i < content.len and content[i] == ';') i += 1;
            continue;
        }

        // name = first identifier after the keyword, skipping "IF NOT EXISTS"
        var k = after_keyword;
        skipWs(content, &k);
        if (k + 2 <= content.len and std.ascii.eqlIgnoreCase(content[k .. k + 2], "if")) {
            skipToken(content, &k); // IF
            skipWs(content, &k);
            skipToken(content, &k); // NOT
            skipWs(content, &k);
            skipToken(content, &k); // EXISTS
            skipWs(content, &k);
        }
        const name_start = k;
        while (k < content.len and content[k] != ' ' and content[k] != '\t' and content[k] != '\n' and content[k] != '\r' and content[k] != '(') k += 1;
        const clean_name = std.mem.trim(u8, content[name_start..k], "`\"[]");

        // statement ends at ';' at paren depth 0 outside strings
        var depth: usize = 0;
        var in_str = false;
        var e = k;
        while (e < content.len) : (e += 1) {
            const ch = content[e];
            if (in_str) {
                if (ch == '\'') in_str = false;
                continue;
            }
            switch (ch) {
                '\'' => in_str = true,
                '(' => depth += 1,
                ')' => {
                    if (depth > 0) depth -= 1;
                },
                ';' => break,
                else => {},
            }
        }
        const end = @min(e, content.len);
        const sql_trimmed = std.mem.trim(u8, content[stmt_start..end], " \t\r\n");
        if (clean_name.len > 0 and sql_trimmed.len > 0) {
            try out.append(allocator, .{
                .kind = kind,
                .name = try allocator.dupe(u8, clean_name),
                .sql = try allocator.dupe(u8, sql_trimmed),
            });
        }
        i = if (end < content.len) end + 1 else content.len;
    }
    return out;
}

/// All cells of a PRAGMA/query as dup'd strings (NULL → "").
fn sqliteQueryRows(
    allocator: std.mem.Allocator,
    handle: *sqlite_c.sqlite3,
    sql: [:0]const u8,
    cols: usize,
) !std.ArrayList([][]const u8) {
    var rows: std.ArrayList([][]const u8) = .empty;
    errdefer {
        for (rows.items) |r| allocator.free(r);
        rows.deinit(allocator);
    }
    var stmt: ?*sqlite_c.sqlite3_stmt = null;
    if (sqlite_c.sqlite3_prepare_v2(handle, sql.ptr, -1, &stmt, null) != sqlite_c.SQLITE_OK) {
        return error.DiffQueryFailed;
    }
    defer _ = sqlite_c.sqlite3_finalize(stmt);
    while (sqlite_c.sqlite3_step(stmt) == sqlite_c.SQLITE_ROW) {
        const row = try allocator.alloc([]const u8, cols);
        for (0..cols) |c| {
            const raw = sqlite_c.sqlite3_column_text(stmt, @intCast(c));
            row[c] = if (raw != null) try allocator.dupe(u8, std.mem.sliceTo(raw, 0)) else try allocator.dupe(u8, "");
        }
        try rows.append(allocator, row);
    }
    return rows;
}

const ActualTable = struct {
    name: []const u8,
    columns: std.ArrayList([]const u8) = .empty, // names
    indexes: std.ArrayList([]const u8) = .empty, // user index names (auto excluded)

    fn hasColumn(self: *const ActualTable, name: []const u8) bool {
        for (self.columns.items) |c| {
            if (std.ascii.eqlIgnoreCase(c, name)) return true;
        }
        return false;
    }
    fn hasIndex(self: *const ActualTable, name: []const u8) bool {
        for (self.indexes.items) |ix| {
            if (std.ascii.eqlIgnoreCase(ix, name)) return true;
        }
        return false;
    }
};

const ActualSchema = struct {
    tables: std.ArrayList(ActualTable) = .empty,
    alloc: std.mem.Allocator,

    fn findTable(self: *ActualSchema, name: []const u8) ?*ActualTable {
        for (self.tables.items) |*t| {
            if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
        }
        return null;
    }
};

/// Introspect the live SQLite database (tables, columns, user indexes).
fn introspectSqlite(allocator: std.mem.Allocator, handle: *sqlite_c.sqlite3) !ActualSchema {
    // `allocator` is an arena — per-query buffers and dup'd names are freed
    // wholesale by the caller.
    var actual = ActualSchema{ .alloc = allocator };

    const tables = try sqliteQueryRows(
        allocator,
        handle,
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE '\\_zfinal%' ESCAPE '\\'",
        1,
    );
    for (tables.items) |row| {
        var t = ActualTable{ .name = try allocator.dupe(u8, row[0]) };

        const cols_sql = try zf_db.formatSqlZ(allocator, "PRAGMA table_info({s})", .{t.name});
        const cols = try sqliteQueryRows(allocator, handle, cols_sql, 2);
        for (cols.items) |r| try t.columns.append(allocator, try allocator.dupe(u8, r[1]));

        const idx_sql = try zf_db.formatSqlZ(allocator, "PRAGMA index_list({s})", .{t.name});
        // index_list columns: seq, name, unique, origin, partial — name is col 1.
        const idxs = try sqliteQueryRows(allocator, handle, idx_sql, 2);
        for (idxs.items) |r| {
            if (std.mem.startsWith(u8, r[1], "sqlite_autoindex")) continue;
            try t.indexes.append(allocator, try allocator.dupe(u8, r[1]));
        }

        try actual.tables.append(allocator, t);
    }
    return actual;
}

/// Table name from a CREATE INDEX statement: the identifier after ` ON `.
fn indexTableOf(allocator: std.mem.Allocator, index_sql: []const u8) ![]const u8 {
    const lower = try std.ascii.allocLowerString(allocator, index_sql);
    defer allocator.free(lower);
    const pos = std.mem.indexOf(u8, lower, " on ") orelse return "";
    var s = index_sql[pos + 4 ..];
    var e: usize = 0;
    while (e < s.len and s[e] != ' ' and s[e] != '\t' and s[e] != '(' and s[e] != '\n') e += 1;
    return std.mem.trim(u8, s[0..e], "`\"[]");
}

/// Build the incremental DDL draft. Pure over (desired, actual) — unit-tested
/// without a database.
fn buildDiffDraft(
    allocator: std.mem.Allocator,
    desired_tables: []const SchemaStmt,
    desired_indexes: []const SchemaStmt,
    table_columns: *std.StringHashMap([]const codegen.Column),
    actual: *ActualSchema,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // 1. new tables → verbatim CREATE
    for (desired_tables) |t| {
        if (actual.findTable(t.name) == null) {
            try out.appendSlice(allocator, t.sql);
            try out.appendSlice(allocator, ";\n\n");
        }
    }

    // 2. existing tables → column diff (ADD COLUMN only; removals are comments)
    var tit = table_columns.iterator();
    while (tit.next()) |entry| {
        const actual_table = actual.findTable(entry.key_ptr.*) orelse continue;
        for (entry.value_ptr.*) |col| {
            if (actual_table.hasColumn(col.name)) continue;
            if (!col.is_nullable and col.default_value == null) {
                try out.appendSlice(allocator, "-- review: NOT NULL without DEFAULT requires a backfill plan\n");
            }
            try out.appendSlice(allocator, "ALTER TABLE ");
            try out.appendSlice(allocator, entry.key_ptr.*);
            try out.appendSlice(allocator, " ADD COLUMN ");
            try out.appendSlice(allocator, col.name);
            if (col.sql_type.len > 0) {
                try out.appendSlice(allocator, " ");
                try out.appendSlice(allocator, col.sql_type);
            }
            if (!col.is_nullable) try out.appendSlice(allocator, " NOT NULL");
            if (col.default_value) |d| {
                try out.appendSlice(allocator, " DEFAULT ");
                try out.appendSlice(allocator, d);
            }
            try out.appendSlice(allocator, ";\n");
        }
    }

    // 3. new indexes → verbatim CREATE (matched by index name on its table)
    for (desired_indexes) |ix| {
        var missing = true;
        const tbl = indexTableOf(allocator, ix.sql) catch "";
        if (tbl.len > 0) {
            if (actual.findTable(tbl)) |t| missing = !t.hasIndex(ix.name);
        }
        if (missing) {
            try out.appendSlice(allocator, ix.sql);
            try out.appendSlice(allocator, ";\n");
        }
    }

    // 4. removals → commented, human review required
    for (actual.tables.items) |*t| {
        var desired_has = false;
        for (desired_tables) |dt| {
            if (dt.eqlName(t.name)) desired_has = true;
        }
        if (!desired_has) {
            try out.appendSlice(allocator, "-- table exists in DB but not in schema.gen.sql (intentional?):\n");
            try out.appendSlice(allocator, "-- DROP TABLE ");
            try out.appendSlice(allocator, t.name);
            try out.appendSlice(allocator, ";\n");
            continue;
        }
        for (t.indexes.items) |ix| {
            var in_desired = false;
            for (desired_indexes) |di| {
                if (di.eqlName(ix)) in_desired = true;
            }
            if (!in_desired) {
                try out.appendSlice(allocator, "-- index no longer in schema.gen.sql (verify, then run manually):\n-- DROP INDEX ");
                try out.appendSlice(allocator, ix);
                try out.appendSlice(allocator, ";\n");
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Load every `schema.gen.sql` under the project (root + src/modules/*/).
const DesiredSchema = struct {
    tables: std.ArrayList(SchemaStmt),
    indexes: std.ArrayList(SchemaStmt),
    table_columns: std.StringHashMap([]const codegen.Column),
};

fn loadDesiredSchema(allocator: std.mem.Allocator) !DesiredSchema {
    var tables: std.ArrayList(SchemaStmt) = .empty;
    var indexes: std.ArrayList(SchemaStmt) = .empty;
    var table_columns = std.StringHashMap([]const codegen.Column).init(allocator);
    errdefer {
        tables.deinit(allocator);
        indexes.deinit(allocator);
        table_columns.deinit();
    }

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    {
        const p = try allocator.dupe(u8, "schema.gen.sql");
        try paths.append(allocator, p);
    }
    {
        const d = std.Io.Dir.cwd().openDir(zf_shared.io, "src/modules", .{ .iterate = true }) catch null;
        if (d) |mods| {
            var m = mods;
            defer m.close(zf_shared.io);
            var it = m.iterate();
            while (try it.next(zf_shared.io)) |entry| {
                if (entry.kind != .directory) continue;
                const p = try std.fmt.allocPrint(allocator, "src/modules/{s}/schema.gen.sql", .{entry.name});
                try paths.append(allocator, p);
            }
        }
    }

    // NOTE: the caller passes an arena — everything allocated here (statements,
    // parsed columns, map keys) is freed wholesale by the arena, so keeping
    // `parsed` alive is fine and Columns stay valid without deep copies.
    for (paths.items) |p| {
        const content = zf_shared.readFileAlloc(allocator, p) catch continue;

        const stmts = try scanStatements(allocator, content);
        for (stmts.items) |st| {
            switch (st.kind) {
                .create_table => try tables.append(allocator, st),
                .create_index => try indexes.append(allocator, st),
            }
        }

        const parsed = codegen.parseSqlFile(allocator, content) catch continue;
        for (parsed.items) |*t| {
            try table_columns.put(t.name, t.columns.items);
        }
    }

    return .{ .tables = tables, .indexes = indexes, .table_columns = table_columns };
}

/// `zf migrate diff [--write]` — draft incremental DDL (schema.gen.sql vs live DB).
pub fn migrateDiff(allocator: std.mem.Allocator, write: bool) !void {
    // One-shot CLI command: allocate the whole diff in an arena and free it
    // wholesale — no per-statement ownership bookkeeping to get wrong.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var db = try openZfinalDb(al);
    defer db.deinit();

    if (db != .sqlite) {
        std.debug.print("zf migrate diff currently supports SQLite project DBs (the default driver).\n", .{});
        std.debug.print("PG/MySQL introspection is not wired yet — review schema changes manually.\n", .{});
        return;
    }

    var desired = try loadDesiredSchema(al);
    if (desired.tables.items.len == 0) {
        std.debug.print("⚠️  no schema.gen.sql found — run `zf crud:sql` first, or place schema.gen.sql in the project root.\n", .{});
        return;
    }

    var actual = try introspectSqlite(al, db.sqlite.db);

    const draft = try buildDiffDraft(al, desired.tables.items, desired.indexes.items, &desired.table_columns, &actual);

    if (draft.len == 0) {
        std.debug.print("✅ schema.gen.sql matches the database — nothing to migrate.\n", .{});
        return;
    }

    if (write) {
        const ts = std.Io.Timestamp.now(zf_shared.io, .real).toSeconds();
        std.Io.Dir.cwd().createDirPath(zf_shared.io, "migrations") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        const filename = try std.fmt.allocPrint(al, "migrations/{d}_auto_diff.sql", .{ts});
        // Wrap in Up/Down sections so `zf migrate run` applies it directly.
        const wrapped = try std.fmt.allocPrint(
            al,
            "-- Migration: auto_diff (generated by zf migrate diff; review before running)\n\n-- Up\n{s}\n-- Down\n-- (no automatic reverse; write it manually if needed)\n",
            .{draft},
        );
        try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = wrapped });
        std.debug.print("✅ Draft written: {s}\n", .{filename});
        std.debug.print("   Review it (removals are comments), rename if desired, then `zf migrate run`.\n", .{});
    } else {
        std.debug.print("-- draft DDL (use `zf migrate diff --write` to save into migrations/):\n\n{s}", .{draft});
    }
}

test "migrate diff: scanStatements extracts tables and indexes with names" {
    const a = std.testing.allocator;
    const sql =
        \\-- comment; with semicolon
        \\INSERT INTO x VALUES (1);
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  email TEXT NOT NULL, -- @unique @email
        \\  bio TEXT DEFAULT 'a;b'
        \\);
        \\CREATE UNIQUE INDEX idx_users_email ON users(email);
    ;
    var stmts = try scanStatements(a, sql);
    defer stmts.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), stmts.items.len);
    try std.testing.expect(stmts.items[0].kind == .create_table);
    try std.testing.expectEqualStrings("users", stmts.items[0].name);
    try std.testing.expect(std.mem.indexOf(u8, stmts.items[0].sql, "'a;b'") != null);
    try std.testing.expect(stmts.items[1].kind == .create_index);
    try std.testing.expectEqualStrings("idx_users_email", stmts.items[1].name);
    const tbl = try indexTableOf(a, stmts.items[1].sql);
    try std.testing.expectEqualStrings("users", tbl);
}

test "migrate diff: buildDiffDraft emits ADD COLUMN, skips existing, comments drops" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    var actual = ActualSchema{ .alloc = al };
    var cols: std.ArrayList([]const u8) = .empty;
    try cols.append(al, try al.dupe(u8, "id"));
    try actual.tables.append(al, .{ .name = try al.dupe(u8, "users"), .columns = cols });
    try actual.tables.append(al, .{ .name = try al.dupe(u8, "legacy") });

    const desired_tables = [_]SchemaStmt{
        .{ .kind = .create_table, .name = "users", .sql = "CREATE TABLE users (id INTEGER PRIMARY KEY)" },
        .{ .kind = .create_table, .name = "posts", .sql = "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)" },
    };
    const desired_indexes = [_]SchemaStmt{
        .{ .kind = .create_index, .name = "idx_users_email", .sql = "CREATE INDEX idx_users_email ON users(email)" },
    };

    var columns = [_]codegen.Column{
        .{ .name = "id", .sql_type = "INTEGER", .is_nullable = false, .is_primary_key = true, .is_auto_increment = true, .default_value = null, .max_length = null },
        .{ .name = "email", .sql_type = "TEXT", .is_nullable = true, .is_primary_key = false, .is_auto_increment = false, .default_value = null, .max_length = null },
    };
    var table_columns = std.StringHashMap([]const codegen.Column).init(al);
    try table_columns.put("users", columns[0..]);

    const draft = try buildDiffDraft(al, desired_tables[0..], desired_indexes[0..], &table_columns, &actual);
    try std.testing.expect(std.mem.indexOf(u8, draft, "ALTER TABLE users ADD COLUMN email TEXT;") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft, "ADD COLUMN id") == null); // existing column untouched
    try std.testing.expect(std.mem.indexOf(u8, draft, "CREATE TABLE posts") != null); // new table verbatim
    try std.testing.expect(std.mem.indexOf(u8, draft, "CREATE INDEX idx_users_email") != null); // missing index
    try std.testing.expect(std.mem.indexOf(u8, draft, "-- DROP TABLE legacy") != null); // removals are comments
}
