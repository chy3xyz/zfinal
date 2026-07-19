const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// Production circuit breaker (Resilience4j-style).
/// States: closed → open (after failure_threshold) → half_open (after reset_timeout)
/// → closed (after half_open_max successes) or open again on failure.
pub const CircuitBreaker = struct {
    failure_threshold: u32 = 5,
    reset_timeout_ms: u64 = 30_000,
    half_open_max: u32 = 3,
    state: State = .closed,
    failures: u32 = 0,
    half_open_successes: u32 = 0,
    opened_at_ms: i64 = 0,
    mutex: std.Io.Mutex = .init,

    pub const State = enum { closed, open, half_open };

    pub fn init() CircuitBreaker {
        return .{};
    }

    pub fn initWith(failure_threshold: u32, reset_timeout_ms: u64, half_open_max: u32) CircuitBreaker {
        return .{
            .failure_threshold = failure_threshold,
            .reset_timeout_ms = reset_timeout_ms,
            .half_open_max = half_open_max,
        };
    }

    fn nowMs() i64 {
        return std.Io.Timestamp.now(io_instance.io, .real).toMilliseconds();
    }

    /// Transition open → half_open when the reset window elapses.
    fn maybeTransition(self: *CircuitBreaker) void {
        if (self.state != .open) return;
        const elapsed = nowMs() - self.opened_at_ms;
        if (elapsed >= @as(i64, @intCast(self.reset_timeout_ms))) {
            self.state = .half_open;
            self.half_open_successes = 0;
        }
    }

    pub fn allowRequest(self: *CircuitBreaker) bool {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        self.maybeTransition();
        return switch (self.state) {
            .closed, .half_open => true,
            .open => false,
        };
    }

    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        switch (self.state) {
            .closed => {
                self.failures = 0;
            },
            .half_open => {
                self.half_open_successes += 1;
                if (self.half_open_successes >= self.half_open_max) {
                    self.state = .closed;
                    self.failures = 0;
                    self.half_open_successes = 0;
                }
            },
            .open => {},
        }
    }

    pub fn recordFailure(self: *CircuitBreaker) void {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        switch (self.state) {
            .closed => {
                self.failures += 1;
                if (self.failures >= self.failure_threshold) {
                    self.state = .open;
                    self.opened_at_ms = nowMs();
                }
            },
            .half_open => {
                self.state = .open;
                self.opened_at_ms = nowMs();
                self.half_open_successes = 0;
            },
            .open => {},
        }
    }

    pub fn isOpen(self: *CircuitBreaker) bool {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        self.maybeTransition();
        return self.state == .open;
    }

    pub fn getState(self: *CircuitBreaker) State {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        self.maybeTransition();
        return self.state;
    }

    /// Run `func(args)` if the circuit allows; record success/failure automatically.
    pub fn call(self: *CircuitBreaker, comptime func: anytype, args: anytype) !@typeInfo(@TypeOf(func)).@"fn".return_type.? {
        if (!self.allowRequest()) return error.CircuitOpen;
        const result = @call(.auto, func, args) catch |err| {
            self.recordFailure();
            return err;
        };
        self.recordSuccess();
        return result;
    }
};

test "circuit breaker: opens after threshold" {
    var cb = CircuitBreaker.initWith(3, 60_000, 2);
    try std.testing.expect(cb.allowRequest());
    cb.recordFailure();
    cb.recordFailure();
    try std.testing.expect(cb.getState() == .closed);
    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);
    try std.testing.expect(!cb.allowRequest());
}

test "circuit breaker: success resets failures in closed" {
    var cb = CircuitBreaker.initWith(3, 60_000, 2);
    cb.recordFailure();
    cb.recordFailure();
    cb.recordSuccess();
    try std.testing.expectEqual(@as(u32, 0), cb.failures);
    try std.testing.expect(cb.getState() == .closed);
}

test "circuit breaker: call helper" {
    var cb = CircuitBreaker.initWith(1, 60_000, 1);
    const ok = struct {
        fn run() !u32 {
            return 42;
        }
    }.run;
    try std.testing.expectEqual(@as(u32, 42), try cb.call(ok, .{}));

    const boom = struct {
        fn run() !void {
            return error.Boom;
        }
    }.run;
    try std.testing.expectError(error.Boom, cb.call(boom, .{}));
    try std.testing.expect(cb.isOpen());
    try std.testing.expectError(error.CircuitOpen, cb.call(ok, .{}));
}
