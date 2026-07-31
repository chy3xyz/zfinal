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
                self.releaseCached(name_z[0 .. name_z.len - 1 :0]) catch {};
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
            c.ZF_OIDOID => {
                const v = c.PQgetvalue(res, row, col);
                return .{ .int = std.mem.readInt(u32, v[0..4], .big) };
            },
            else => {
                const v = c.PQgetvalue(res, row, col);
                const len: usize = @intCast(c.PQgetlength(res, row, col));
                const raw = v[0..len];

                // Types below have a binary form that differs from their text
                // form. Decoding is best-effort: a malformed/unexpected length
                // falls through to the generic path rather than erroring out.
                const decoded: ?[]const u8 = switch (oid) {
                    c.ZF_UUIDOID => formatUuid(allocator, raw) catch null,
                    c.ZF_TIMESTAMPTZOID => formatTimestamp(allocator, raw, "Z") catch null,
                    // `timestamp` carries no zone; emit it bare so callers do
                    // not mistake a local wall-clock reading for UTC.
                    c.ZF_TIMESTAMPOID => formatTimestamp(allocator, raw, "") catch null,
                    c.ZF_DATEOID => formatDate(allocator, raw) catch null,
                    c.ZF_TIMEOID => formatTime(allocator, raw) catch null,
                    c.ZF_TIMETZOID => formatTimeTz(allocator, raw) catch null,
                    c.ZF_JSONBOID => formatJsonb(allocator, raw) catch null,
                    c.ZF_NUMERICOID => formatNumeric(allocator, raw) catch null,
                    c.ZF_INETOID, c.ZF_CIDROID => formatInet(allocator, raw) catch null,
                    else => null,
                };
                if (decoded) |d| return .{ .text = d };

                // Generic path: text, varchar, bpchar, name, json, xml and
                // user-defined enums all encode as their UTF-8 text. Anything
                // that is not valid UTF-8 is some binary type we have no
                // decoder for — surface it as a blob instead of fabricating a
                // `.text` cell full of bytes that would poison JSON output and
                // trip `22021 invalid byte sequence` if echoed back to PG.
                if (std.unicode.utf8ValidateSlice(raw)) {
                    return .{ .text = try allocator.dupe(u8, raw) };
                }
                return .{ .blob = try allocator.dupe(u8, raw) };
            },
        }
    }
};

// --- PostgreSQL binary wire-format decoders ---------------------------------
//
// `queryParams` requests `result_format = 1`, so libpq returns each value in
// its native binary representation rather than as text. The helpers below turn
// the handful of types zserver-style apps actually store — uuid, timestamps,
// jsonb, numeric, inet — back into the same strings PostgreSQL would have
// produced in text mode, with one deliberate exception: timestamps are
// rendered as RFC 3339 UTC (`2026-07-31T06:40:40.5149Z`) rather than
// PostgreSQL's session-dependent `2026-07-31 14:40:40.5149+08`. RFC 3339 is
// what every JSON client expects, sorts correctly as a plain string, and
// matches what a Go `time.Time` marshals to.

/// Seconds between the Unix epoch (1970-01-01) and the PostgreSQL epoch
/// (2000-01-01), both UTC.
const pg_epoch_unix_secs: i64 = 946_684_800;
/// Days between the Unix epoch and the PostgreSQL epoch.
const pg_epoch_unix_days: i64 = pg_epoch_unix_secs / std.time.s_per_day;

const CivilDate = struct { year: i64, month: u32, day: u32 };

/// Days-since-1970-01-01 → calendar date, via Howard Hinnant's `civil_from_days`.
/// Valid across the whole proleptic Gregorian range, negative days included.
fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// Zig's `{d:0>4}` emits an explicit `+` for signed integers, so the year has
/// to be formatted through an unsigned value. Years at or below zero use ISO
/// 8601 expanded form (astronomical numbering, where year 0 is 1 BC) rather
/// than PostgreSQL's `BC` suffix.
fn writeYear(buf: []u8, year: i64) !usize {
    if (year < 0) {
        const s = try std.fmt.bufPrint(buf, "-{d:0>4}", .{@as(u64, @intCast(-year))});
        return s.len;
    }
    const s = try std.fmt.bufPrint(buf, "{d:0>4}", .{@as(u64, @intCast(year))});
    return s.len;
}

/// Append `.ffffff` with trailing zeros trimmed, matching Go's RFC3339Nano
/// and PostgreSQL's own text output (both omit a zero fraction entirely).
fn appendFraction(buf: []u8, at: usize, micros: u32) usize {
    if (micros == 0) return at;
    var digits: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{micros}) catch return at;
    var end: usize = 6;
    while (end > 0 and digits[end - 1] == '0') end -= 1;
    buf[at] = '.';
    @memcpy(buf[at + 1 ..][0..end], digits[0..end]);
    return at + 1 + end;
}

/// 16 raw bytes → canonical lowercase 8-4-4-4-12 hyphenated form.
fn formatUuid(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len != 16) return error.InvalidUuid;
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var o: usize = 0;
    for (raw, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[byte >> 4];
        out[o + 1] = hex[byte & 0x0f];
        o += 2;
    }
    return allocator.dupe(u8, &out);
}

/// int64 microseconds since 2000-01-01 → `YYYY-MM-DDTHH:MM:SS[.ffffff]<suffix>`.
fn formatTimestamp(allocator: std.mem.Allocator, raw: []const u8, suffix: []const u8) ![]const u8 {
    if (raw.len != 8) return error.InvalidTimestamp;
    const micros = std.mem.readInt(i64, raw[0..8], .big);
    // PostgreSQL encodes the special values `infinity` / `-infinity` as the
    // int64 extremes.
    if (micros == std.math.maxInt(i64)) return allocator.dupe(u8, "infinity");
    if (micros == std.math.minInt(i64)) return allocator.dupe(u8, "-infinity");

    // i128 keeps the epoch shift from overflowing at the extremes of the
    // representable timestamp range (year 294276).
    const unix_us: i128 = @as(i128, micros) + @as(i128, pg_epoch_unix_secs) * std.time.us_per_s;
    const secs: i64 = @intCast(@divFloor(unix_us, std.time.us_per_s));
    const frac: u32 = @intCast(unix_us - @as(i128, secs) * std.time.us_per_s);
    const days = @divFloor(secs, std.time.s_per_day);
    const sod: u32 = @intCast(secs - days * std.time.s_per_day);
    const civil = civilFromDays(days);

    var buf: [64]u8 = undefined;
    var len = try writeYear(&buf, civil.year);
    const rest = try std.fmt.bufPrint(buf[len..], "-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        civil.month, civil.day,
        sod / 3600,  (sod % 3600) / 60,
        sod % 60,
    });
    len = appendFraction(&buf, len + rest.len, frac);
    if (len + suffix.len > buf.len) return error.InvalidTimestamp;
    @memcpy(buf[len..][0..suffix.len], suffix);
    len += suffix.len;
    return allocator.dupe(u8, buf[0..len]);
}

/// int32 days since 2000-01-01 → `YYYY-MM-DD`.
fn formatDate(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len != 4) return error.InvalidDate;
    const days = std.mem.readInt(i32, raw[0..4], .big);
    if (days == std.math.maxInt(i32)) return allocator.dupe(u8, "infinity");
    if (days == std.math.minInt(i32)) return allocator.dupe(u8, "-infinity");

    const civil = civilFromDays(@as(i64, days) + pg_epoch_unix_days);
    var buf: [32]u8 = undefined;
    var len = try writeYear(&buf, civil.year);
    const rest = try std.fmt.bufPrint(buf[len..], "-{d:0>2}-{d:0>2}", .{ civil.month, civil.day });
    len += rest.len;
    return allocator.dupe(u8, buf[0..len]);
}

fn writeTimeOfDay(buf: []u8, micros: i64) !usize {
    if (micros < 0) return error.InvalidTime;
    const secs: u64 = @intCast(@divFloor(micros, std.time.us_per_s));
    const frac: u32 = @intCast(micros - @as(i64, @intCast(secs)) * std.time.us_per_s);
    const head = try std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ secs / 3600, (secs % 3600) / 60, secs % 60 });
    return appendFraction(buf, head.len, frac);
}

/// int64 microseconds since midnight → `HH:MM:SS[.ffffff]`.
fn formatTime(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len != 8) return error.InvalidTime;
    var buf: [32]u8 = undefined;
    const len = try writeTimeOfDay(&buf, std.mem.readInt(i64, raw[0..8], .big));
    return allocator.dupe(u8, buf[0..len]);
}

/// int64 microseconds since midnight + int32 zone → `HH:MM:SS[.ffffff]±HH[:MM]`.
fn formatTimeTz(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len != 12) return error.InvalidTime;
    var buf: [48]u8 = undefined;
    var len = try writeTimeOfDay(&buf, std.mem.readInt(i64, raw[0..8], .big));

    // PostgreSQL stores the zone as seconds *west* of UTC, so the sign of the
    // displayed offset is inverted.
    const zone = -std.mem.readInt(i32, raw[8..12], .big);
    const abs: u32 = @intCast(if (zone < 0) -zone else zone);
    const hh = abs / 3600;
    const mm = (abs % 3600) / 60;
    const tail = if (mm == 0)
        try std.fmt.bufPrint(buf[len..], "{c}{d:0>2}", .{ @as(u8, if (zone < 0) '-' else '+'), hh })
    else
        try std.fmt.bufPrint(buf[len..], "{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (zone < 0) '-' else '+'), hh, mm });
    len += tail.len;
    return allocator.dupe(u8, buf[0..len]);
}

/// jsonb is a single version byte followed by the JSON text.
fn formatJsonb(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 1 or raw[0] != 1) return error.InvalidJsonb;
    return allocator.dupe(u8, raw[1..]);
}

/// Binary numeric: `int16 ndigits, int16 weight, uint16 sign, int16 dscale`
/// followed by `ndigits` base-10000 groups. Rendered exactly as PostgreSQL
/// would in text mode, including trailing zeros implied by `dscale`.
fn formatNumeric(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 8) return error.InvalidNumeric;
    const ndigits = std.mem.readInt(i16, raw[0..2], .big);
    const weight = std.mem.readInt(i16, raw[2..4], .big);
    const sign = std.mem.readInt(u16, raw[4..6], .big);
    const dscale = std.mem.readInt(i16, raw[6..8], .big);

    switch (sign) {
        0xC000 => return allocator.dupe(u8, "NaN"),
        0xD000 => return allocator.dupe(u8, "Infinity"),
        0xF000 => return allocator.dupe(u8, "-Infinity"),
        0x0000, 0x4000 => {},
        else => return error.InvalidNumeric,
    }
    if (ndigits < 0 or dscale < 0) return error.InvalidNumeric;
    const n: i32 = ndigits;
    if (raw.len < 8 + @as(usize, @intCast(n)) * 2) return error.InvalidNumeric;

    const group = struct {
        fn at(bytes: []const u8, count: i32, idx: i32) u16 {
            if (idx < 0 or idx >= count) return 0;
            const off = 8 + @as(usize, @intCast(idx)) * 2;
            return std.mem.readInt(u16, bytes[off..][0..2], .big);
        }
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (sign == 0x4000) try out.append(allocator, '-');

    var scratch: [8]u8 = undefined;
    if (weight < 0) {
        try out.append(allocator, '0');
    } else {
        var i: i32 = 0;
        while (i <= weight) : (i += 1) {
            const g = group.at(raw, n, i);
            // Only the most significant group is printed unpadded.
            const s = if (i == 0)
                try std.fmt.bufPrint(&scratch, "{d}", .{g})
            else
                try std.fmt.bufPrint(&scratch, "{d:0>4}", .{g});
            try out.appendSlice(allocator, s);
        }
    }

    if (dscale > 0) {
        try out.append(allocator, '.');
        var produced: i32 = 0;
        // Group index i holds the digits for 10000^(weight - i), so the first
        // fractional group is at weight + 1 regardless of weight's sign.
        var i: i32 = weight + 1;
        while (produced < dscale) : ({
            i += 1;
            produced += 4;
        }) {
            const s = try std.fmt.bufPrint(&scratch, "{d:0>4}", .{group.at(raw, n, i)});
            const take: usize = @intCast(@min(@as(i32, 4), dscale - produced));
            try out.appendSlice(allocator, s[0..take]);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Binary inet/cidr: `family, bits, is_cidr, addr_len` then the address bytes.
fn formatInet(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 4) return error.InvalidInet;
    const family = raw[0];
    const bits = raw[1];
    const is_cidr = raw[2] != 0;
    const nb: usize = raw[3];
    if (raw.len < 4 + nb) return error.InvalidInet;
    const addr = raw[4 .. 4 + nb];

    // libpq uses its own address family constants, not the host's AF_INET.
    const pgsql_af_inet = 2;
    const pgsql_af_inet6 = 3;

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    if (family == pgsql_af_inet and nb == 4) {
        const s = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ addr[0], addr[1], addr[2], addr[3] });
        len = s.len;
    } else if (family == pgsql_af_inet6 and nb == 16) {
        len = try writeIpv6(&buf, addr);
    } else return error.InvalidInet;

    // `inet` hides the prefix when it covers the whole address; `cidr` always
    // shows it. This matches PostgreSQL's own text output.
    const full_bits: u8 = if (nb == 4) 32 else 128;
    if (is_cidr or bits != full_bits) {
        const s = try std.fmt.bufPrint(buf[len..], "/{d}", .{bits});
        len += s.len;
    }
    return allocator.dupe(u8, buf[0..len]);
}

/// RFC 5952 IPv6 text: lowercase hex, longest run of zero groups (length >= 2)
/// collapsed to `::`.
fn writeIpv6(buf: []u8, addr: []const u8) !usize {
    var groups: [8]u16 = undefined;
    for (0..8) |i| groups[i] = std.mem.readInt(u16, addr[i * 2 ..][0..2], .big);

    var best_start: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and groups[j] == 0) j += 1;
        if (j - i > best_len) {
            best_start = i;
            best_len = j - i;
        }
        i = j;
    }
    if (best_len < 2) best_len = 0;

    var len: usize = 0;
    var g: usize = 0;
    while (g < 8) {
        if (best_len > 0 and g == best_start) {
            @memcpy(buf[len..][0..2], "::");
            len += 2;
            g += best_len;
            continue;
        }
        if (g > 0 and !(best_len > 0 and g == best_start + best_len)) {
            buf[len] = ':';
            len += 1;
        }
        const s = try std.fmt.bufPrint(buf[len..], "{x}", .{groups[g]});
        len += s.len;
        g += 1;
    }
    return len;
}
