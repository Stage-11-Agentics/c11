//! Runs the pinned production libxev backend against a real nonblocking PTY.
//! No subprocess, operator terminal, or dependency-source edits are involved.
const std = @import("std");
const posix = std.posix;
const xev = @import("xev").Dynamic;
const c = @cImport({
    @cInclude("util.h");
    @cInclude("termios.h");
});
const count = 8192;
const State = struct {
    queue: xev.WriteQueue = .{},
    callbacks: usize = 0,
    would_block: usize = 0,
    other_errors: usize = 0,
    read_bytes: usize = 0,
    mismatches: usize = 0,
    filler_bytes: usize = 0,
};
const Write = struct {
    req: xev.WriteRequest,
    data: [64]u8,
    state: *State,
    index: usize,
};
fn completed(w_: ?*Write, _: *xev.Loop, _: *xev.Completion, _: xev.Stream, _: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
    const w = w_.?;
    w.state.callbacks += 1;
    _ = r catch |err| {
        if (err == error.WouldBlock) {
            w.state.would_block += 1;
            if (w.state.would_block <= 8) std.debug.print("WOULD_BLOCK request={} popped={} callbacks={}\n", .{ w.index, w.state.queue.head != &w.req, w.state.callbacks });
        } else {
            w.state.other_errors += 1;
            std.debug.print("WRITE_ERROR request={} error={}\n", .{ w.index, err });
        }
        return .disarm;
    };
    return .disarm;
}
const RaceWriter = struct {
    fd: posix.fd_t,
    stop: std.atomic.Value(bool) = .init(false),
    fn run(self: *RaceWriter) void {
        const filler: [64]u8 = @splat(255);
        while (!self.stop.load(.acquire)) {
            _ = posix.write(self.fd, &filler) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return,
            };
        }
    }
};
pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    const race = args.len > 1 and std.mem.eql(u8, args[1], "--race");
    var master: c_int = undefined;
    var slave: c_int = undefined;
    if (c.openpty(&master, &slave, null, null, null) != 0) return error.OpenPty;
    defer posix.close(master);
    defer posix.close(slave);
    var attrs: c.termios = undefined;
    if (c.tcgetattr(slave, &attrs) != 0) return error.GetTermios;
    c.cfmakeraw(&attrs);
    if (c.tcsetattr(slave, c.TCSANOW, &attrs) != 0) return error.SetTermios;
    for ([_]c_int{ master, slave }) |fd| {
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    }
    std.debug.print("backend={s} master_flags={} bytes={}\n", .{ @tagName(xev.backend), try posix.fcntl(master, posix.F.GETFL, 0), count * 64 });
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var stream = xev.Stream.initFd(master);
    // Stream.deinit is intentionally omitted: this watcher does not own fd.
    var state: State = .{};
    const writes = try std.heap.page_allocator.alloc(Write, count);
    defer std.heap.page_allocator.free(writes);
    for (writes, 0..) |*w, i| {
        w.state = &state;
        w.index = i;
        for (&w.data, 0..) |*v, j| v.* = @truncate((i * 64 + j) % 251);
        stream.queueWrite(&loop, &state.queue, &w.req, .{ .slice = &w.data }, Write, w, completed);
    }
    var race_writer: RaceWriter = .{ .fd = master };
    const race_thread = if (race) try std.Thread.spawn(.{}, RaceWriter.run, .{&race_writer}) else null;
    defer if (race_thread) |thread| {
        race_writer.stop.store(true, .release);
        thread.join();
    };
    std.debug.print("competing_writer={} (race mode probes advisory readiness; not a Ghostty workload)\n", .{race});
    var timer = try std.time.Timer.start();
    var buffer: [4096]u8 = undefined;
    while (timer.read() < 5 * std.time.ns_per_s) {
        if (race and timer.read() > 400 * std.time.ns_per_ms) race_writer.stop.store(true, .release);
        try loop.run(.no_wait);
        // First stop the PTY consumer entirely to force real backpressure.
        if (timer.read() > 200 * std.time.ns_per_ms) {
            const n = posix.read(slave, &buffer) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            for (buffer[0..n]) |value| {
                if (race and value == 255) {
                    state.filler_bytes += 1;
                    continue;
                }
                if (value != state.read_bytes % 251) state.mismatches += 1;
                state.read_bytes += 1;
            }
        }
        if (state.callbacks == count and state.read_bytes == count * 64) break;
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
    std.debug.print("callbacks={} would_block={} other_errors={} received={} expected={} mismatches={} filler_bytes={} elapsed_ns={}\n", .{ state.callbacks, state.would_block, state.other_errors, state.read_bytes, count * 64, state.mismatches, state.filler_bytes, timer.read() });
    if (state.would_block != 0) return error.BackpressureDropsWrite;
    if (state.other_errors != 0 or state.read_bytes != count * 64 or state.mismatches != 0) return error.IncompleteOrCorruptDelivery;
    std.debug.print("PASS delivery under PTY saturation; absence of WouldBlock is not a reachability disproof.\n", .{});
}
