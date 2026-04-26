const std = @import("std");
const cdb = @import("./cdb.zig");

pub fn bufferedPrint() !void {
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
