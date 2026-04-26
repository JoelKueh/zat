const std = @import("std");
const zat = @import("zat");

pub fn main(init: std.process.Init) anyerror!void {
    const file: std.Io.File = try std.Io.Dir.cwd().openFile(init.io, "./test/test.cnf", .{});
    var solver: zat.Zat = .init();
    if (try solver.loadCnf(init.io, init.gpa, file) == false) {
        std.debug.print("UNSATISFIABLE\n", .{});
    }
}

test "cnf" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    // defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
