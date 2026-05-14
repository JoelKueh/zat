const std = @import("std");
const FlatMap = @import("flat_map.zig").FlatMap;
const FlatMapHeap = @import("flat_map_heap.zig").FlatMapHeap;

// Type definitions for working with variables.
pub const Variable = u31;
pub const Literal = packed struct(u32) {
    neg: u1,
    variable: Variable,

    pub fn raw(self: Literal) u32 {
        return @as(u32, @bitCast(self));
    }

    pub fn inv(self: Literal) Literal {
        return @bitCast(@as(u32, @bitCast(self)) ^ 1);
    }
};

// Type definitions for working with variable and literal FlatMaps.
fn variableIdxFn(a: Variable) u32 {
    return a;
}
pub fn VariableMap(comptime V: type) type {
    return FlatMap(Variable, V, variableIdxFn);
}

fn literalIdxFn(a: Literal) u32 {
    return a.raw();
}
pub fn LiteralMap(comptime V: type) type {
    return FlatMap(Literal, V, literalIdxFn);
}

// Type definitions for handling activities.
pub const Activity = f64;
pub const ActivityMap = FlatMap(Variable, Activity, variableIdxFn);
pub const ActivityHeap = FlatMapHeap(Variable, ActivityMap, activityCompare, variableIdxFn);
fn activityCompare(context: ActivityMap, a: Variable, b: Variable) std.math.Order {
    return std.math.order(context.get(a), context.get(b));
}

// Type definitions for clauses.
pub const ClauseRef = u31;
pub const ClauseHeader = packed struct(u32) {
    size: u27,
    locked: bool,
    learned: bool,
    forgotten: bool,
    relocated: bool,
    simplified: bool,
};
pub const Clause = struct {
    cref: ClauseRef,
    header: ClauseHeader,
    lits: []Literal,

    // Get the specific literals who's assignment propagated self.lits[0].
    pub fn getReason(self: Clause, lit: ?Literal) []const Literal {
        if (lit == null) return self.lits;
        std.debug.assert(lit == self.lits[0]);
        return self.lits[1..];
    }

    // Pretty-printer for the clause.
    pub fn format(
        self: Clause,
        writer: anytype
    ) !void {
        for (self.lits) |lit| {
            if (lit.neg == 1) try writer.print("-", .{});
            try writer.print("{} ", .{lit.variable});
        }
    }
};

// Type definition for a resolution found during the Zat.analyze routine.
pub const Resolution = struct {
    level: u32,
    lits: []Literal,

    pub const empty: Resolution = .{ .level = 0, .lits = &.{} };
    pub fn deinit(self: *Resolution, gpa: std.mem.Allocator) void {
        gpa.free(self.lits);
    }
};

// Watcher definition for the two watched literals scheme.
pub const Watcher = struct {
    cref: ClauseRef,
    blocker: Literal,
};

// A custom arena allocator based clause database.
pub const ClauseDatabase = struct {
    data: []u32,
    clauses: std.ArrayList(ClauseRef),
    size: ClauseRef,
    capacity: u32,
    waste: u32,

    pub fn init() ClauseDatabase {
        return .{
            .data = &[_]u32{},
            .size = 0,
            .clauses = .empty,
            .capacity = 0,
            .waste = 0,
        };
    }

    // Add a clause to the database.
    pub fn addClause(self: *ClauseDatabase, gpa: std.mem.Allocator,
            learned: bool, literals: []Literal) !ClauseRef {
        if (self.size + literals.len + 1 > self.capacity) {
            if (std.math.cast(u32, (self.size + literals.len + 1) << 1)) |val| {
                self.capacity = val;
            } else {
                return error.Overflow;
            }
            self.data = try gpa.realloc(self.data, self.capacity);
        }
                
        const cref: ClauseRef = self.size;
        self.data[cref] = @bitCast(ClauseHeader {
            .size = @intCast(literals.len),
            .locked = false,
            .learned = learned,
            .forgotten = false,
            .relocated = false,
            .simplified = false,
        });
        try self.clauses.append(gpa, cref);

        const dest: []Literal = self.getLiterals(cref);
        @memcpy(dest, literals);
        
        self.size += @intCast(literals.len + 1);
        return cref;
    }

    // Get a clause from the database based on its cref.
    pub fn getClause(self: *ClauseDatabase, cref: ClauseRef) Clause {
        return Clause {
            .cref = cref,
            .header = self.getHeader(cref).*,
            .lits = self.getLiterals(cref),
        };
    }

    // Get the header for a clause from the database.
    pub fn getHeader(self: ClauseDatabase, cref: ClauseRef) *ClauseHeader {
        return @ptrCast(&self.data[cref]);
    }

    // Get the literals for a clause from the database.
    pub fn getLiterals(self: ClauseDatabase, cref: ClauseRef) []Literal {
        const header: ClauseHeader = @bitCast(self.data[cref]);
        return @ptrCast(self.data[cref+1..cref+header.size+1]);
    }

    // Clear the clause database.
    pub fn clear(self: *ClauseDatabase) void {
        self.size = 0;
        self.waste = 0;
    }

    // Cleanup memory for the clause database.
    pub fn deinit(self: *ClauseDatabase, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        self.clauses.deinit(gpa);
    }

    // Pretty-printer for the clause database.
    pub fn printDebug(self: *ClauseDatabase) void {
        for (self.clauses.items) |cref| {
            const clause: Clause = self.getClause(cref);
            std.debug.print("{f}\n", .{clause});
        }
    }
};
