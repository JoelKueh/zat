const std = @import("std");
const zat = @import("zat");

fn progress(title: []const u8, cur: usize, total: usize, last_elapsed: f64) void {
    std.debug.print("\r\x1b[2K", .{});
    std.debug.print("{s} [", .{title});

    const bar_width = 50;
    const threshold = @as(f64, @floatFromInt(cur)) / @as(f64, @floatFromInt(total));
    const filled_width = @as(usize, @intFromFloat(threshold * bar_width));
    for (0..bar_width) |i| {
        if (i < filled_width) {
            std.debug.print("#", .{});
        } else {
            std.debug.print(" ", .{});
        }
    }

    std.debug.print("] {d:.2}ms", .{last_elapsed});
}

fn solve(io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) !bool {
    var solver: zat.Zat = .init();
    defer solver.deinit(gpa);
    if (try solver.loadCnf(io, gpa, file) == false) return false;
    return try solver.solve(gpa);
}

fn test_dir(io: std.Io, gpa: std.mem.Allocator, path: []const u8, expected: bool) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var total: u32 = 0;
    while (try walker.next(io)) |_| {
        total += 1;
    }
    walker.deinit();
    walker = try dir.walk(gpa);

    var i: u32 = 0;
    var total_elapsed: f64 = 0;
    var last_elapsed: f64 = 0;
    while (try walker.next(io)) |entry| {
        progress(path, i, total, last_elapsed);
        const start = std.Io.Clock.real.now(io);
        var file = try dir.openFile(io, entry.path, .{ .mode = .read_only });
        defer file.close(io);
        if (try solve(io, gpa, file) != expected) {
            std.debug.print("\nERROR\n", .{});
        }
        i += 1;
        const end = std.Io.Clock.real.now(io);
        last_elapsed = @as(f64, @floatFromInt(
            std.Io.Timestamp.durationTo(start, end).toNanoseconds())) / 1_000_000.0;
        total_elapsed += last_elapsed;
    }
    progress(path, i, total, last_elapsed);
    std.debug.print("{s} - \r\x1b[2KAverage Time: {}\n", .{path, total_elapsed / @as(f64, @floatFromInt(total))});
}

pub fn main(init: std.process.Init) anyerror!void {
    try test_dir(init.io, init.gpa, "./test/uuf75-325", false);
}

