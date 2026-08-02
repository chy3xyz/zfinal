//! Multi-endpoint provider registry: weighted / least-inflight selection + failover.
//! Assemble manually; Agent continues to use a single `*AiProvider` (or call
//! `ProviderRegistry.chatWith` from app code).

const std = @import("std");
const provider_mod = @import("provider.zig");
const time_util = @import("time_util.zig");

pub const AiProvider = provider_mod.AiProvider;

pub const ProviderSpec = struct {
    name: []const u8,
    /// Borrowed provider pointer (caller owns lifetime).
    provider: *AiProvider,
    weight: u32 = 1,
    /// Temporary cooldown after retryable failures (ms wall clock).
    cooldown_until_ms: i64 = 0,
    inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

pub const ProviderRegistry = struct {
    io: std.Io,
    mutex: std.Io.Mutex,
    specs: []ProviderSpec,
    rr: usize = 0,
    failovers: usize = 0,

    pub fn init(io: std.Io, specs: []ProviderSpec) ProviderRegistry {
        return .{
            .io = io,
            .mutex = .init,
            .specs = specs,
        };
    }

    pub fn deinit(self: *ProviderRegistry) void {
        self.* = undefined;
    }

    fn pickIndex(self: *ProviderRegistry) !usize {
        self.mutex.lock(self.io) catch return error.NoProviderAvailable;
        defer self.mutex.unlock(self.io);

        const now = time_util.nowMillis();
        const n = self.specs.len;
        if (n == 0) return error.NoProviderAvailable;

        var best_i: ?usize = null;
        var best_score: i64 = std.math.maxInt(i64);
        var best_rr: usize = n;

        var tried: usize = 0;
        while (tried < n) : (tried += 1) {
            const i = (self.rr + tried) % n;
            const s = &self.specs[i];
            if (s.cooldown_until_ms > now) continue;
            const inflight: i64 = @intCast(s.inflight.load(.monotonic));
            const weight: i64 = @intCast(@max(s.weight, 1));
            // Lower score = better: inflight / weight, then RR distance.
            const score = @divTrunc(inflight * 1000, weight);
            if (score < best_score or (score == best_score and tried < best_rr)) {
                best_score = score;
                best_rr = tried;
                best_i = i;
            }
        }

        const idx = best_i orelse return error.NoProviderAvailable;
        self.rr = (idx + 1) % n;
        return idx;
    }

    pub fn chatWith(
        self: *ProviderRegistry,
        messages: []const AiProvider.ChatMsg,
        opts: AiProvider.ChatOpts,
    ) !AiProvider.ChatResponse {
        const max_attempts = @max(self.specs.len, 1);
        var attempt: usize = 0;
        var last_err: anyerror = error.NoProviderAvailable;

        while (attempt < max_attempts) : (attempt += 1) {
            const idx = self.pickIndex() catch |err| {
                last_err = err;
                break;
            };
            const spec = &self.specs[idx];
            _ = spec.inflight.fetchAdd(1, .monotonic);
            defer _ = spec.inflight.fetchSub(1, .monotonic);

            const result = spec.provider.chatWith(messages, opts);
            if (result) |resp| return resp else |err| {
                last_err = err;
                if (isFailover(err)) {
                    self.failovers += 1;
                    if (self.mutex.lock(self.io)) |_| {
                        defer self.mutex.unlock(self.io);
                        spec.cooldown_until_ms = time_util.nowMillis() + 2_000;
                    } else |_| {}
                    continue;
                }
                return err;
            }
        }
        return last_err;
    }

    pub fn freeResponse(self: *ProviderRegistry, resp: *AiProvider.ChatResponse) void {
        // Prefer first provider's allocator (all share app allocator typically).
        if (self.specs.len == 0) return;
        self.specs[0].provider.freeResponse(resp);
    }
};

fn isFailover(err: anyerror) bool {
    return err == error.RateLimited or
        err == error.UpstreamError or
        err == error.ConnectionError or
        err == error.AllKeysExhausted or
        err == error.AuthError;
}

test "ProviderRegistry picks weighted provider" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Lightweight stubs: only need pickIndex logic — use fake providers with empty http.
    // We test pickIndex via cooldown skipping without network.
    var http_a: provider_mod.AiProvider = undefined;
    var http_b: provider_mod.AiProvider = undefined;
    // Minimal init without real HttpClient — set fields used by registry only.
    http_a = .{
        .allocator = allocator,
        .http = undefined,
        .endpoint = "http://a",
        .api_key = "a",
        .model = "m",
    };
    http_b = .{
        .allocator = allocator,
        .http = undefined,
        .endpoint = "http://b",
        .api_key = "b",
        .model = "m",
    };

    var specs = [_]ProviderSpec{
        .{ .name = "a", .provider = &http_a, .weight = 1 },
        .{ .name = "b", .provider = &http_b, .weight = 10 },
    };
    var reg = ProviderRegistry.init(io, &specs);

    // Cool down A → always pick B.
    specs[0].cooldown_until_ms = time_util.nowMillis() + 60_000;
    const idx = try reg.pickIndex();
    try std.testing.expectEqual(@as(usize, 1), idx);
}

test "ProviderRegistry exhausts when all cooling" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var p: provider_mod.AiProvider = .{
        .allocator = allocator,
        .http = undefined,
        .endpoint = "http://x",
        .api_key = "x",
        .model = "m",
    };
    var specs = [_]ProviderSpec{
        .{ .name = "x", .provider = &p, .weight = 1, .cooldown_until_ms = time_util.nowMillis() + 60_000 },
    };
    var reg = ProviderRegistry.init(io, &specs);
    try std.testing.expectError(error.NoProviderAvailable, reg.pickIndex());
}
