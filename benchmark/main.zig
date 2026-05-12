const std = @import("std");
const zfinal = @import("zfinal");

/// Benchmark Configuration
const Config = struct {
    url: []const u8 = "http://127.0.0.1:8080/",
    concurrency: usize = 50,
    requests: usize = 10000,
    method: std.http.Method = .GET,
};

const Stats = struct {
    requests: usize = 0,
    failures: usize = 0,
    total_duration_ns: u64 = 0,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn add(self: *Stats, duration_ns: u64, failed: bool) void {
        std.Io.Mutex.lock(&self.mutex, zfinal.io_instance.io) catch {};
        defer std.Io.Mutex.unlock(&self.mutex, zfinal.io_instance.io);
        self.requests += 1;
        if (failed) self.failures += 1;
        self.total_duration_ns += duration_ns;
    }
};

fn worker(allocator: std.mem.Allocator, io: std.Io, config: Config, stats: *Stats) !void {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const requests_per_worker = config.requests / config.concurrency;

    const uri = try std.Uri.parse(config.url);

    for (0..requests_per_worker) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        var failed = false;

        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .method = config.method,
        }) catch {
            failed = true;
            stats.add(0, true);
            continue;
        };

        if (result.status != .ok) {
            failed = true;
        }

        const end = std.Io.Timestamp.now(io, .awake);
        const duration_ns = start.durationTo(end).toNanoseconds();
        stats.add(@intCast(duration_ns), failed);
    }
}

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip exe name

    var config = Config{};
    if (args_iter.next()) |a| config.url = a;
    if (args_iter.next()) |a| config.requests = try std.fmt.parseInt(usize, a, 10);
    if (args_iter.next()) |a| config.concurrency = try std.fmt.parseInt(usize, a, 10);
    std.debug.print("\n🚀 Starting Zig Benchmark\n", .{});
    std.debug.print("URL:         {s}\n", .{config.url});
    std.debug.print("Requests:    {d}\n", .{config.requests});
    std.debug.print("Concurrency: {d}\n", .{config.concurrency});
    std.debug.print("--------------------------------------------------\n", .{});

    var stats = Stats{};
    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(allocator);

    const start_time = std.Io.Timestamp.now(zfinal.io_instance.io, .awake);

    for (0..config.concurrency) |_| {
        const thread = try std.Thread.spawn(.{}, worker, .{ allocator, zfinal.io_instance.io, config, &stats });
        try threads.append(allocator, thread);
    }

    for (threads.items) |thread| {
        thread.join();
    }

    const end_time = std.Io.Timestamp.now(zfinal.io_instance.io, .awake);
    const total_time_ns = start_time.durationTo(end_time).toNanoseconds();
    const total_time_s = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0;
    const rps = @as(f64, @floatFromInt(stats.requests)) / total_time_s;
    const avg_latency_ms = if (stats.requests > 0)
        (@as(f64, @floatFromInt(stats.total_duration_ns)) / @as(f64, @floatFromInt(stats.requests))) / 1_000_000.0
    else
        0.0;

    std.debug.print("\n📊 Results:\n", .{});
    std.debug.print("Total Time:    {d:.2} s\n", .{total_time_s});
    std.debug.print("Total Requests: {d}\n", .{stats.requests});
    std.debug.print("Failed:        {d}\n", .{stats.failures});
    std.debug.print("RPS:           {d:.2} req/s\n", .{rps});
    std.debug.print("Avg Latency:   {d:.2} ms\n", .{avg_latency_ms});
    std.debug.print("--------------------------------------------------\n", .{});
}
