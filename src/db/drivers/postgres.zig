const std = @import("std");
const DBConfig = @import("../config.zig").DBConfig;
const Cell = @import("../result.zig").Cell;
const Row = @import("../result.zig").Row;
const ResultSet = @import("../result.zig").ResultSet;
const SqlParam = @import("../sql_param.zig").SqlParam;
const diag = @import("../diag.zig");

const c = @import("c_pg");

// PG_DIAG_* field codes — character constants from <libpq-fe.h>:
//   'C' SQLSTATE, 'M' primary message, 't' table, 'c' column, 'n' constraint.
const PG_DIAG_SQLSTATE: c_int = 'C';
const PG_DIAG_TABLE_NAME: c_int = 't';
const PG_DIAG_COLUMN_NAME: c_int = 'c';
const PG_DIAG_CONSTRAINT_NAME: c_int = 'n';
const PG_DIAG_MESSAGE_PRIMARY: c_int = 'M';

pub const PostgresDB = struct {
    conn: ?*c.PGconn,
    allocator: std.mem.Allocator,
    last_affected: i64 = 0,
    /// Server-side prepared statement cache. Each entry maps a stable
    /// `name` to the server-prepared statement. Re-running the same
    /// `execCached(name, ...)` / `queryCached(name, ...)` avoids the
    /// parse + plan cost of `PQexecParams` on every call.
    ///
    /// Use `prepareCached` to install, `releaseCached` to DEALLOCATE.
    /// On `close`, all entries are released automatically.
    stmt_cache: ?std.ArrayList(CachedStmt) = null,

    const CachedStmt = struct {
        name: []const u8,
        sql: []const u8,
        n_params: c_int,
    };

    pub fn connect(allocator: std.mem.Allocator, config: DBConfig) !PostgresDB {
        var conn_buf: [1024]u8 = undefined;
        // Build the conninfo string. If unix_socket is set, the host is
        // the socket path (libpq accepts `host=/path/to/socket` directly)
        // and the port is irrelevant — we omit it to avoid libpq errors.
        const base = if (config.unix_socket) |sock| try std.fmt.bufPrint(
            &conn_buf,
            "host={s} dbname={s} user={s} password={s} connect_timeout={d} client_encoding=UTF8",
            .{
                sock,
                config.database,
                config.username orelse "",
                config.password orelse "",
                config.timeout,
            },
        ) else try std.fmt.bufPrint(
            &conn_buf,
            "host={s} port={d} dbname={s} user={s} password={s} connect_timeout={d} client_encoding=UTF8",
            .{
                config.host orelse "localhost",
                config.port orelse 5432,
                config.database,
                config.username orelse "",
                config.password orelse "",
                config.timeout,
            },
        );
        conn_buf[base.len] = 0;

        // Append sslmode= if non-default. libpq's default is 'prefer' which
        // silently downgrades to non-SSL on failure — cloud DBs (RDS, Cloud SQL)
        // require an explicit 'require' or stricter.
        var ssl_buf: [64]u8 = undefined;
        const ssl_suffix: []const u8 = switch (config.ssl_mode) {
            .disable => blk: {
                const s = try std.fmt.bufPrint(&ssl_buf, " sslmode=disable", .{});
                break :blk s;
            },
            .prefer => "", // libpq default — no need to append
            .require => blk: {
                const s = try std.fmt.bufPrint(&ssl_buf, " sslmode=require", .{});
                break :blk s;
            },
            .verify_ca => blk: {
                const s = try std.fmt.bufPrint(&ssl_buf, " sslmode=verify-ca", .{});
                break :blk s;
            },
            .verify_full => blk: {
                const s = try std.fmt.bufPrint(&ssl_buf, " sslmode=verify-full", .{});
                break :blk s;
            },
        };

        // Compose final conninfo: base + suffix
        var final_buf: [1100]u8 = undefined;
        const final_len = base.len + ssl_suffix.len;
        if (final_len > final_buf.len) return error.ConnectionFailed;
        @memcpy(final_buf[0..base.len], base);
        @memcpy(final_buf[base.len..final_len], ssl_suffix);
        final_buf[final_len] = 0;
        const conn_str: [:0]const u8 = final_buf[0..final_len :0];

        const conn = c.PQconnectdb(conn_str);
        @memset(&conn_buf, 0);
        @memset(&ssl_buf, 0);
        @memset(&final_buf, 0);
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            const msg = c.PQerrorMessage(conn);
            std.debug.print("PostgreSQL connect failed: {s}\n", .{msg});
            c.PQfinish(conn);
            return error.ConnectionFailed;
        }

        return .{ .conn = conn, .allocator = allocator };
    }

    pub fn close(self: *PostgresDB) void {
        // Release any cached prepared statements (DEALLOCATE on server).
        if (self.stmt_cache) |*cache| {
            for (cache.items) |entry| {
                const name_z = std.fmt.allocPrint(self.allocator, "{s}\x00", .{entry.name}) catch continue;
                defer self.allocator.free(name_z);
                self.releaseCached(name_z[0..name_z.len - 1 :0]) catch {};
                self.allocator.free(entry.name);
                self.allocator.free(entry.sql);
            }
            cache.deinit(self.allocator);
            self.stmt_cache = null;
        }
        if (self.conn) |cxn| {
            c.PQfinish(cxn);
            self.conn = null;
        }
    }

    pub fn ping(self: *PostgresDB) bool {
        const cxn = self.conn orelse return false;
        // Defensive: verify pointer isn't a poisoned debug-allocator fill
        if (@intFromPtr(cxn) >= 0xaaaaaaaaaaaaaaaa) return false;
        return c.PQstatus(cxn) == c.CONNECTION_OK;
    }

    pub fn exec(self: *PostgresDB, sql: [:0]const u8) !void {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const res = c.PQexec(cxn, sql.ptr);
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            const d = extractPgDiag(res);
            std.debug.print("PostgreSQL exec failed [{s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        const s = std.mem.span(c.PQcmdTuples(res));
        self.last_affected = if (s.len > 0) std.fmt.parseInt(i64, s, 10) catch 0 else 0;
    }

    pub fn execParams(self: *PostgresDB, sql: [:0]const u8, params: []const SqlParam) !void {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const bind = try buildParams(self.allocator, params);
        defer freeParams(self.allocator, bind);

        const res = c.PQexecParams(
            cxn,
            sql.ptr,
            @intCast(params.len),
            null,
            bind.values.ptr,
            bind.lengths.ptr,
            bind.formats.ptr,
            0, // input param format: 0 = text
        );
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            const d = extractPgDiag(res);
            std.debug.print("PostgreSQL execParams failed [{s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        const s = std.mem.span(c.PQcmdTuples(res));
        self.last_affected = if (s.len > 0) std.fmt.parseInt(i64, s, 10) catch 0 else 0;
    }

    pub fn query(self: *PostgresDB, sql: [:0]const u8) !ResultSet {
        return self.queryParams(sql, &.{});
    }

    pub fn queryParams(self: *PostgresDB, sql: [:0]const u8, params: []const SqlParam) !ResultSet {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const bind = try buildParams(self.allocator, params);
        defer freeParams(self.allocator, bind);

        // resultFormats[0] = 1 → binary output. libpq sends column values
        // in their native wire format (i64 for INT8, f64 for FLOAT8, etc.)
        // and we decode directly into the matching Cell variant. Saves the
        // server-side to_text() and the client-side parseInt() round-trip.
        const result_format: c_int = 1;
        const res = c.PQexecParams(
            cxn,
            sql.ptr,
            @intCast(params.len),
            null,
            bind.values.ptr,
            bind.lengths.ptr,
            bind.formats.ptr,
            result_format,
        );
        defer c.PQclear(res);
        const res_ptr = res orelse return error.ConnectionFailed;

        if (c.PQresultStatus(res_ptr) != c.PGRES_TUPLES_OK) {
            const d = extractPgDiag(res_ptr);
            std.debug.print("PostgreSQL query failed [{s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        return resultSetFromPgRes(self, res_ptr);
    }

    /// Convert a materialized PGresult into a fully-owned ResultSet.
    /// The PGresult remains owned by the caller and must be PQclear'd.
    /// ResultSet copies all column names and cell payloads, so it is safe
    /// to clear `res` immediately after this call returns.
    fn resultSetFromPgRes(self: *PostgresDB, res: *c.PGresult) !ResultSet {
        const n_cols: usize = @intCast(c.PQnfields(res));
        const n_rows: usize = @intCast(c.PQntuples(res));

        var columns = try self.allocator.alloc([]const u8, n_cols);
        errdefer self.allocator.free(columns);
        for (0..n_cols) |i| {
            columns[i] = try self.allocator.dupe(u8, std.mem.span(c.PQfname(res, @intCast(i))));
        }

        var result_set = ResultSet.init(self.allocator, columns);
        errdefer result_set.deinit();

        // Cache column OIDs once — PQftype is O(n*rows) otherwise.
        var col_oids = try self.allocator.alloc(c.Oid, n_cols);
        defer self.allocator.free(col_oids);
        for (0..n_cols) |i| {
            col_oids[i] = c.PQftype(res, @intCast(i));
        }

        for (0..n_rows) |ri| {
            var cells = try self.allocator.alloc(Cell, n_cols);
            errdefer {
                for (cells) |cell| switch (cell) {
                    .text => |t| self.allocator.free(t),
                    .blob => |b| self.allocator.free(b),
                    else => {},
                };
                self.allocator.free(cells);
            }
            for (0..n_cols) |ci| {
                cells[ci] = try readPgCell(self.allocator, res, @intCast(ri), @intCast(ci), col_oids[ci]);
            }
            try result_set.addRow(cells);
        }

        return result_set;
    }

    /// Open an incremental query iterator. Uses libpq's single-row mode
    /// (set BEFORE the query) so `PQgetResult` returns one row at a time
    /// instead of materializing the full result set.
    ///
    /// Memory usage is O(1) per row. Caller MUST call `iter.deinit()`
    /// to consume any trailing status from the connection, even if the
    /// iteration was aborted early.
    pub fn queryIter(self: *PostgresDB, sql: [:0]const u8, params: []const SqlParam) !PgIter {
        const cxn = self.conn orelse return error.ConnectionFailed;

        // Enable single-row mode for the NEXT query. Returns 1 on success.
        if (c.PQsetSingleRowMode(cxn) != 1) {
            return error.QueryFailed;
        }

        const bind = try buildParams(self.allocator, params);
        defer freeParams(self.allocator, bind);

        // resultFormats[0] = 1 → binary output for typed reads.
        const result_format: c_int = 1;
        const res = c.PQexecParams(
            cxn,
            sql.ptr,
            @intCast(params.len),
            null,
            bind.values.ptr,
            bind.lengths.ptr,
            bind.formats.ptr,
            result_format,
        );

        if (res == null) {
            // Connection-level failure during query.
            const d = extractPgDiag(null);
            std.debug.print("PostgreSQL queryIter PQexec returned NULL: {s}\n", .{d.message});
            return diag.toError(d.code);
        }

        const n_cols: usize = @intCast(c.PQnfields(res));

        // Cache column OIDs for typed reads.
        var col_oids = try self.allocator.alloc(c.Oid, n_cols);
        errdefer self.allocator.free(col_oids);
        for (0..n_cols) |i| {
            col_oids[i] = c.PQftype(res, @intCast(i));
        }

        // Build column name slice (borrowed from res — must dup).
        var col_names = try self.allocator.alloc([]const u8, n_cols);
        errdefer {
            for (col_names) |n| self.allocator.free(n);
            self.allocator.free(col_names);
        }
        for (0..n_cols) |i| {
            col_names[i] = try self.allocator.dupe(u8, std.mem.span(c.PQfname(res, @intCast(i))));
        }

        return .{
            .conn = cxn,
            .current_res = res,
            .n_cols = n_cols,
            .col_names = col_names,
            .col_oids = col_oids,
            .allocator = self.allocator,
            .done = false,
            .err = null,
        };
    }

    /// Incremental query iterator. Holds the live libpq connection open
    /// and yields one Row at a time via repeated `PQgetResult` calls.
    ///
    /// libpq requires that we keep calling `PQgetResult` after the last
    /// row to consume the trailing status (including errors). `deinit()`
    /// does this automatically.
    pub const PgIter = struct {
        conn: *c.PGconn,
        current_res: ?*c.PGresult,
        n_cols: usize,
        col_names: [][]const u8,
        col_oids: []c.Oid,
        allocator: std.mem.Allocator,
        done: bool,
        err: ?anyerror = null,

        /// Fetch the next row. Returns null when iteration completes.
        /// On error the iterator is poisoned — caller should still deinit.
        pub fn next(self: *PgIter) !?Row {
            if (self.done) return null;
            if (self.err) |e| return e;

            // First call: current_res was set by queryIter (first row OR NULL).
            // Subsequent calls: current_res is null, call PQgetResult to advance.
            const res = self.current_res orelse blk: {
                const next_res = c.PQgetResult(self.conn);
                if (next_res == null) {
                    // No more rows. We still need to consume the final
                    // PQgetResult call to drain libpq's trailing status.
                    // Caller does this in deinit().
                    self.done = true;
                    return null;
                }
                break :blk next_res;
            };

            const status = c.PQresultStatus(res);
            if (status == c.PGRES_TUPLES_OK) {
                // Single row is in `res` (n_tuples == 1 typically).
                const n_tuples = c.PQntuples(res);
                if (n_tuples == 0) {
                    // Empty single-row response — treat as completion.
                    c.PQclear(res);
                    self.current_res = null;
                    self.done = true;
                    return null;
                }
                var cells = try self.allocator.alloc(Cell, self.n_cols);
                errdefer {
                    for (cells) |cell| switch (cell) {
                        .text => |t| self.allocator.free(t),
                        .blob => |b| self.allocator.free(b),
                        else => {},
                    };
                    self.allocator.free(cells);
                }
                for (0..self.n_cols) |ci| {
                    cells[ci] = try readPgCell(self.allocator, res, 0, @intCast(ci), self.col_oids[ci]);
                }
                // Clear this res, advance to next via PQgetResult on next .next() call.
                c.PQclear(res);
                self.current_res = null;
                return Row{ .cells = cells, .allocator = self.allocator };
            } else if (status == c.PGRES_SINGLE_TUPLE) {
                // Older libpq versions return this for single-row mode.
                var cells = try self.allocator.alloc(Cell, self.n_cols);
                errdefer {
                    for (cells) |cell| switch (cell) {
                        .text => |t| self.allocator.free(t),
                        .blob => |b| self.allocator.free(b),
                        else => {},
                    };
                    self.allocator.free(cells);
                }
                for (0..self.n_cols) |ci| {
                    cells[ci] = try readPgCell(self.allocator, res, 0, @intCast(ci), self.col_oids[ci]);
                }
                c.PQclear(res);
                self.current_res = null;
                return Row{ .cells = cells, .allocator = self.allocator };
            } else {
                // Error or unexpected status. Capture and finalize.
                const d = extractPgDiag(res);
                std.debug.print("PostgreSQL queryIter error [{s}]: {s}\n", .{ d.raw, d.message });
                c.PQclear(res);
                self.current_res = null;
                self.done = true;
                self.err = diag.toError(d.code);
                return self.err;
            }
        }

        pub fn columns(self: *const PgIter) []const []const u8 {
            return self.col_names;
        }

        /// Finalize the iterator. Drains any remaining PQgetResult calls
        /// (required by libpq to release connection state), frees column
        /// names + OID cache. Idempotent.
        pub fn deinit(self: *PgIter) void {
            // Drain any pending PQgetResult calls until null is returned,
            // plus one more to consume trailing status (libpq requires this).
            if (!self.done) {
                // Caller exited early without exhausting — drain.
                while (true) {
                    const r = c.PQgetResult(self.conn);
                    if (r == null) break;
                    c.PQclear(r);
                }
            }
            // Final drain call (after null result) — required by libpq.
            _ = c.PQgetResult(self.conn);

            for (self.col_names) |n| self.allocator.free(n);
            if (self.col_names.len > 0) self.allocator.free(self.col_names);
            if (self.col_oids.len > 0) self.allocator.free(self.col_oids);
        }
    };

    pub fn affectedRows(self: *PostgresDB) i64 {
        return self.last_affected;
    }

    /// Install a server-side prepared statement under `name`. Subsequent
    /// `execCached(name, ...)` / `queryCached(name, ...)` reuse it without
    /// re-parsing. Naming convention: prefix with your app to avoid
    /// collisions (e.g. "myapp_users_get").
    ///
    /// On error, any partial server-side state is rolled back.
    pub fn prepareCached(self: *PostgresDB, name: [:0]const u8, sql: [:0]const u8, n_params: c_int) !void {
        const cxn = self.conn orelse return error.ConnectionFailed;
        // PQprepare server-parses + plans the statement and binds it to
        // `name`. The returned PGresult is just an ack — PQclear it.
        const res = c.PQprepare(cxn, name, sql, n_params, null);
        defer c.PQclear(res);
        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            const d = extractPgDiag(res);
            std.debug.print("PostgreSQL prepareCached failed [{s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }
        if (self.stmt_cache == null) {
            self.stmt_cache = std.ArrayList(CachedStmt).empty;
        }
        try self.stmt_cache.?.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .sql = try self.allocator.dupe(u8, sql),
            .n_params = n_params,
        });
    }

    /// Execute a previously-prepared statement. Result rows (if any) are
    /// returned; caller must `result.deinit()`. `result_format = 1` →
    /// binary output (typed reads).
    pub fn execCached(
        self: *PostgresDB,
        name: [:0]const u8,
        params: []const ?[*:0]const u8,
        param_lengths: []const c_int,
        param_formats: []const c_int,
        result_format: c_int,
    ) !*c.PGresult {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const res = c.PQexecPrepared(
            cxn,
            name,
            @intCast(params.len),
            params.ptr,
            param_lengths.ptr,
            param_formats.ptr,
            result_format,
        );
        // Caller owns the result and must PQclear it.
        return res orelse return error.ConnectionFailed;
    }

    /// Execute a previously-prepared statement and return the result set.
    /// Uses binary result format (`result_format = 1`) for typed cell reads.
    /// The returned `ResultSet` owns all row/column memory; the underlying
    /// `PGresult` is cleared before returning.
    pub fn queryCached(
        self: *PostgresDB,
        name: [:0]const u8,
        params: []const SqlParam,
    ) !ResultSet {
        const bind = try buildParams(self.allocator, params);
        defer freeParams(self.allocator, bind);

        const res = try self.execCached(name, bind.values, bind.lengths, bind.formats, 1);
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_TUPLES_OK) {
            const d = extractPgDiag(res);
            std.debug.print("PostgreSQL queryCached failed [{s}]: {s}\n", .{ d.raw, d.message });
            return diag.toError(d.code);
        }

        return resultSetFromPgRes(self, res);
    }

    /// DEALLOCATE a server-side prepared statement. After this call,
    /// `execCached(name, ...)` / `queryCached(name, ...)` will fail until
    /// `prepareCached(name, ...)` is called again.
    pub fn releaseCached(self: *PostgresDB, name: [:0]const u8) !void {
        const cxn = self.conn orelse return error.ConnectionFailed;
        const dealloc_sql = try std.fmt.allocPrint(self.allocator, "DEALLOCATE \"{s}\"", .{name});
        defer self.allocator.free(dealloc_sql);
        const res = c.PQexec(cxn, dealloc_sql.ptr);
        defer c.PQclear(res);
        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            return error.PrepareFailed;
        }
        // Remove from local cache.
        if (self.stmt_cache) |*cache| {
            for (cache.items, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.name, name)) {
                    self.allocator.free(entry.name);
                    self.allocator.free(entry.sql);
                    _ = cache.orderedRemove(i);
                    return;
                }
            }
        }
    }

    pub fn lastInsertId(self: *PostgresDB) !i64 {
        var result = try self.query("SELECT lastval()");
        defer result.deinit();
        if (result.next()) {
            if (try result.getInt(0)) |id| return id;
        }
        return error.NoLastInsertId;
    }

    const Params = struct { values: []?[*:0]const u8, lengths: []c_int, formats: []c_int, strings: [][]const u8, owned: []bool };

    fn buildParams(allocator: std.mem.Allocator, params: []const SqlParam) !Params {
        var values = try allocator.alloc(?[*:0]const u8, params.len);
        errdefer allocator.free(values);
        var lengths = try allocator.alloc(c_int, params.len);
        errdefer allocator.free(lengths);
        var formats = try allocator.alloc(c_int, params.len);
        errdefer allocator.free(formats);
        var strings = try allocator.alloc([]const u8, params.len);
        errdefer allocator.free(strings);
        var owned = try allocator.alloc(bool, params.len);
        errdefer allocator.free(owned);
        @memset(owned, false);

        for (params, 0..) |p, i| {
            formats[i] = 0;
            switch (p) {
                .null => {
                    values[i] = null;
                    lengths[i] = 0;
                },
                .int => |v| {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                    defer allocator.free(s);
                    const s0 = try allocator.alloc(u8, s.len + 1);
                    @memcpy(s0[0..s.len], s);
                    s0[s.len] = 0;
                    strings[i] = s0;
                    owned[i] = true;
                    values[i] = @ptrCast(s0.ptr);
                    lengths[i] = 0;
                },
                .real => |v| {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                    defer allocator.free(s);
                    const s0 = try allocator.alloc(u8, s.len + 1);
                    @memcpy(s0[0..s.len], s);
                    s0[s.len] = 0;
                    strings[i] = s0;
                    owned[i] = true;
                    values[i] = @ptrCast(s0.ptr);
                    lengths[i] = 0;
                },
                .text => |v| {
                    const s = try allocator.alloc(u8, v.len + 1);
                    @memcpy(s[0..v.len], v);
                    s[v.len] = 0;
                    strings[i] = s;
                    owned[i] = true;
                    values[i] = @ptrCast(s.ptr);
                    lengths[i] = 0;
                },
                .blob => |v| {
                    values[i] = @ptrCast(@constCast(v.ptr));
                    lengths[i] = @intCast(v.len);
                    formats[i] = 1;
                },
            }
        }
        return .{ .values = values, .lengths = lengths, .formats = formats, .strings = strings, .owned = owned };
    }

    fn freeParams(allocator: std.mem.Allocator, p: Params) void {
        for (p.strings, p.owned) |s, own| if (own) allocator.free(s);
        allocator.free(p.strings);
        allocator.free(p.owned);
        allocator.free(p.values);
        allocator.free(p.lengths);
        allocator.free(p.formats);
    }

    /// Extract SQLSTATE + table/column/constraint from a failed PG result.
    /// All returned slices are borrowed from libpq-owned memory — do NOT
    /// free them. Caller must keep `res` alive until diag is consumed.
    fn extractPgDiag(res_opt: ?*c.PGresult) diag.Diag {
        const res = res_opt orelse {
            // No result — PQexec itself failed. Use PQerrorMessage on conn.
            return .{
                .code = .connection_lost,
                .message = "(no result)",
                .raw = "",
            };
        };
        const sqlstate_ptr = c.PQresultErrorField(res, PG_DIAG_SQLSTATE);
        const sqlstate = if (sqlstate_ptr) |p| std.mem.span(p) else "";
        const code = diag.pgCode(sqlstate);

        const msg_ptr = c.PQresultErrorField(res, PG_DIAG_MESSAGE_PRIMARY);
        const message = if (msg_ptr) |p| std.mem.span(p) else "";

        const table_ptr = c.PQresultErrorField(res, PG_DIAG_TABLE_NAME);
        const table: ?[]const u8 = if (table_ptr) |p| std.mem.span(p) else null;

        const col_ptr = c.PQresultErrorField(res, PG_DIAG_COLUMN_NAME);
        const column: ?[]const u8 = if (col_ptr) |p| std.mem.span(p) else null;

        const cn_ptr = c.PQresultErrorField(res, PG_DIAG_CONSTRAINT_NAME);
        const constraint: ?[]const u8 = if (cn_ptr) |p| std.mem.span(p) else null;

        return .{
            .code = code,
            .message = message,
            .table = table,
            .column = column,
            .constraint = constraint,
            .raw = sqlstate,
        };
    }

    /// Decode a single binary-result cell into the matching Cell variant.
    /// We dispatch on PQftype OID — common types mapped to native Cell:
    ///   INT2/INT4/INT8 → .int, FLOAT4/FLOAT8/NUMERIC → .float,
    ///   BOOL → .bool, TEXT/VARCHAR/CHAR/UNKNOWN → .text (always works),
    ///   BYTEA → .blob, DATE/TIME/TIMESTAMP → .text (ISO wire format).
    /// Unknown OIDs fall back to .text via PQgetvalue.
    fn readPgCell(allocator: std.mem.Allocator, res: *c.PGresult, row: c_int, col: c_int, oid: c.Oid) !Cell {
        if (c.PQgetisnull(res, row, col) == 1) return .null;

        // Native binary reads. Endian: server is big-endian; Zig host is
        // typically little-endian on x86/aarch64. We use std.mem.nativeToBig
        // for ints (network byte order = big).
        switch (oid) {
            c.ZF_INT8OID => {
                const v = c.PQgetvalue(res, row, col);
                const big = std.mem.readInt(i64, v[0..8], .big);
                return .{ .int = big };
            },
            c.ZF_INT4OID => {
                const v = c.PQgetvalue(res, row, col);
                const big = std.mem.readInt(i32, v[0..4], .big);
                return .{ .int = big };
            },
            c.ZF_INT2OID => {
                const v = c.PQgetvalue(res, row, col);
                const big = std.mem.readInt(i16, v[0..2], .big);
                return .{ .int = big };
            },
            c.ZF_FLOAT8OID => {
                const v = c.PQgetvalue(res, row, col);
                const bits = std.mem.readInt(u64, v[0..8], .big);
                return .{ .float = @bitCast(bits) };
            },
            c.ZF_FLOAT4OID => {
                const v = c.PQgetvalue(res, row, col);
                const bits = std.mem.readInt(u32, v[0..4], .big);
                return .{ .float = @as(f32, @bitCast(bits)) };
            },
            c.ZF_BOOLOID => {
                const v = c.PQgetvalue(res, row, col);
                return .{ .bool = v[0] != 0 };
            },
            c.ZF_BYTEAOID => {
                const v = c.PQgetvalue(res, row, col);
                const len: usize = @intCast(c.PQgetlength(res, row, col));
                return .{ .blob = try allocator.dupe(u8, v[0..len]) };
            },
            else => {
                // text, varchar, char, date, time, timestamp, json, uuid, numeric, ...
                // Either true binary (uuid=16 bytes, numeric=variable) or already
                // text-encoded. For correctness over speed, use text for these.
                const v = c.PQgetvalue(res, row, col);
                const len: usize = @intCast(c.PQgetlength(res, row, col));
                return .{ .text = try allocator.dupe(u8, v[0..len]) };
            },
        }
    }
};
