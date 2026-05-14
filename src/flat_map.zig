const std = @import("std");

// Datasturcture that supports a strongly typed map from type K to type V.
pub fn FlatMap(comptime K: type, comptime V: type, comptime idxFn: fn (key: K) u32) type {
    return struct {
        const Self = @This();
        pub const empty: Self = .{ .items = &.{} };

        items: []V,

        pub fn initCapacity(gpa: std.mem.Allocator, capacity: u32) !Self {
            return Self {
                .items = try gpa.alloc(V, capacity),
            };
        }

        pub fn get(self: Self, key: K) V {
            return self.items[idxFn(key)];
        }

        pub fn getPtr(self: Self, key: K) *V {
            return &self.items[idxFn(key)];
        }

        pub fn deinit(self: Self, gpa: std.mem.Allocator) void {
            gpa.free(self.items);
        }
    };
}

