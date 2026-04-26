const std = @import("std");
const zat = @import("zat");

pub fn main(init: std.process.Init) anyerror!void {
    _ = init;
}

test "cnf" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    // defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
