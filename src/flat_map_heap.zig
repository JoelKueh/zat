const std = @import("std");
const FlatMap = @import("flat_map.zig").FlatMap;
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const assert = std.debug.assert;
const Index = u31;

// Custom heap datastructure that utilizes a FlatMap for indexing.
pub fn FlatMapHeap(
    comptime K: type,
    comptime Context: type,
    comptime compareFn: fn (context: Context, a: K, b: K) Order,
    comptime indexFn: fn (key: K) u32
) type {
    return struct {
        const Self = @This();
        pub const empty: Self = .{ .data = &.{}, .count = 0, .map = .empty, .context = undefined };

        data: []K,
        count: u32,
        map: FlatMap(K, ?Index, indexFn),
        context: Context,

        // Initialize a FlatMapHeap to the desired capacity.
        // FlatMapHeap cannot be resized and all memory must be allocated up front.
        pub fn initCapacity(gpa: Allocator, context: Context, capacity: Index) !Self {
            const self: Self = .{
                .data = try gpa.alloc(K, capacity),
                .count = 0,
                .map = try .initCapacity(gpa, capacity),
                .context = context,
            };
            for (self.map.items) |*item| item.* = null;
            return self;
        }

        // Free memory used by the queue.
        pub fn deinit(self: Self, gpa: Allocator) void {
            gpa.free(self.data);
            self.map.deinit(gpa);
        }

        // Check if the queue contains the specified element.
        pub fn contains(self: Self, elem: K) bool {
            return self.map.get(elem) != null;
        }

        // Add an element to the heap.
        pub fn addUnchecked(self: *Self, elem: K) void {
            assert(self.count < self.data.len);
            assert(self.map.get(elem) == null);
            
            self.map.getPtr(elem).* = @intCast(self.count);
            self.data[self.count] = elem;
            siftUp(self, @as(Index, @intCast(self.count)));
            self.count += 1;
        }

        // Remove and return the highest priority element in the queue.
        pub fn pop(self: *Self) ?K {
            if (self.count == 0) return null;
            const last_item = self.data[self.count - 1];
            const removed_item = self.data[0];

            self.map.getPtr(removed_item).* = null;
            self.count -= 1;
            if (self.count > 0) {
                self.map.getPtr(last_item).* = 0;
                self.data[0] = last_item;
                siftDown(self, 0);
            }

            return removed_item;
        }

        // Move a value op the heap (call this after the priority for elem has been updated).
        pub fn percolate(self: *Self, elem: K) void {
            if (self.map.get(elem) == null) return;
            const update_index = self.map.get(elem).?;
            assert(self.data[update_index] == elem);
            siftUp(self, update_index);
        }

        // Perform recursive swaps to move a child up the heap.
        fn siftUp(self: *Self, start_index: Index) void {
            const child = self.data[start_index];
            var child_index = start_index;
            while (child_index > 0) {
                // Get the index of the parent node.
                const parent_index = ((child_index - 1) >> 1);
                const parent = self.data[parent_index];

                // Swap the child with the parent if necessary.
                if (compareFn(self.context, child, parent) != .gt) break;
                self.map.getPtr(parent).* = child_index;
                self.data[child_index] = parent;
                child_index = parent_index;
            }
            self.map.getPtr(child).* = child_index;
            self.data[child_index] = child;
        }

        // Perform recursive swaps to move a parent down the heap.
        fn siftDown(self: *Self, start_index: Index) void {
            const parent = self.data[start_index];
            var parent_index = start_index;
            while (true) {
                // Get the left and right children of the parent.
                const left_child_index = (std.math.mul(Index, parent_index, 2) catch break) | 1;
                if (left_child_index >= @as(Index, @intCast(self.count))) break;
                const left_child = self.data[left_child_index];
                const right_child_index = left_child_index + 1;

                // Get the lesser child.
                var child_index = left_child_index;
                if (right_child_index < self.count) {
                    const right_child = self.data[right_child_index];
                    const left_vs_right = compareFn(self.context, left_child, right_child);
                    if (left_vs_right == .lt) child_index = right_child_index;
                }
                const child = self.data[child_index];

                // Swap the parent with the lesser child if necessary.
                if (compareFn(self.context, parent, child) != .lt) break;
                self.map.getPtr(child).* = parent_index;
                self.data[parent_index] = child;
                parent_index = child_index;
            }
            self.map.getPtr(parent).* = parent_index;
            self.data[parent_index] = parent;
        }

        // Dump the heap to standard out for debugging.
        pub fn dump(self: *Self) void {
            const print = std.debug.print;
            print("{{ ", .{});
            print("items: ", .{});
            for (self.data[0..self.count]) |e| {
                print("{}, ", .{e});
            }
            print("\nprios: ", .{});
            for (self.data[0..self.count]) |e| {
                print("{}, ", .{self.context.get(e)});
            }
            print("len: {} ", .{self.data.len});
            print(" }}\n", .{});
        }
    };
}
