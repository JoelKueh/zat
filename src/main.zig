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
    if (try solver.loadCnf(io, gpa, file) == false) {
        std.debug.print("TRIVIALLY UNSATISFIABLE CNF\n", .{});
        return false;
    }
    return try solver.solve(gpa);
}

fn test_dir(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?bool {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var total: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.path[entry.path.len-4..], ".cnf")) continue;
        if (entry.kind != .file) continue;
        total += 1;
    }
    // TODO: This is a double free bug
    walker.deinit();
    walker = try dir.walk(gpa);

    var result: ?bool = null;
    var i: u32 = 0;
    var total_elapsed: f64 = 0;
    var last_elapsed: f64 = 0;
    while (try walker.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.path[entry.path.len-4..], ".cnf")) continue;
        if (entry.kind != .file) continue;
        progress(path, i, total, last_elapsed);
        const start = std.Io.Clock.real.now(io);
        var file = try dir.openFile(io, entry.path, .{ .mode = .read_only });
        defer file.close(io);

        if (result) |res| {
            if (res != try solve(io, gpa, file)) {
                std.debug.print("ERROR\n", .{});
                return null;
            }
        } else {
            result = try solve(io, gpa, file);
        }

        i += 1;
        const end = std.Io.Clock.real.now(io);
        last_elapsed = @as(f64, @floatFromInt(
            std.Io.Timestamp.durationTo(start, end).toNanoseconds())) / 1_000_000.0;
        total_elapsed += last_elapsed;
    }
    progress(path, i, total, last_elapsed);
    std.debug.print("\r\x1b[2K{s} - {s} - Average Time: {}\n", .{
        path, if (result orelse return error.EmptyDir) "SATISFIABLE" else "UNSATISFIABLE",
        total_elapsed / @as(f64, @floatFromInt(total)),
    });
    return result;
}

pub fn main(init: std.process.Init) anyerror!void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 2) {
        std.debug.print("USAGE: {s} <PATH>\n", .{args[0]});
        return;
    }

    const cwd = std.Io.Dir.cwd();
    const path = args[1];
    const stat = try std.Io.Dir.cwd().statFile(init.io, path, .{});
    if (stat.kind == .directory) {
        _ = try test_dir(init.io, init.gpa, path);
    } else {
        var file = try cwd.openFile(init.io, path, .{ .mode = .read_only });
        defer file.close(init.io);
        const result = try solve(init.io, init.gpa, file);
        std.debug.print("{s}\n", .{if (result) "SATISFIABLE" else "UNSATISFIABLE"});
    }
}

