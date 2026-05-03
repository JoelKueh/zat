const std = @import("std");

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

pub const Activity = f64;
pub const ActivityHeap = std.PriorityQueue(Variable, []Activity, activityCompare);
fn activityCompare(context: []Activity, a: Variable, b: Variable) std.math.Order {
    return std.math.order(context[a], context[b]);
}

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

    pub fn getConflict(self: Clause) []const Literal {
        return self.lits;
    }

    pub fn getReason(self: Clause) []const Literal {
        return self.lits[1..];
    }

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

pub const Resolution = struct {
    level: u32,
    lits: []Literal,

    pub const empty: Resolution = .{ .level = 0, .lits = &.{} };
    pub fn deinit(self: *Resolution, gpa: std.mem.Allocator) void {
        gpa.free(self.lits);
    }
};

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

    pub fn getClause(self: *ClauseDatabase, cref: ClauseRef) Clause {
        return Clause {
            .cref = cref,
            .header = self.getHeader(cref).*,
            .lits = self.getLiterals(cref),
        };
    }

    pub fn getHeader(self: ClauseDatabase, cref: ClauseRef) *ClauseHeader {
        return @ptrCast(&self.data[cref]);
    }

    pub fn getLiterals(self: ClauseDatabase, cref: ClauseRef) []Literal {
        const header: ClauseHeader = @bitCast(self.data[cref]);
        return @ptrCast(self.data[cref+1..cref+header.size+1]);
    }

    pub fn clear(self: *ClauseDatabase) void {
        self.size = 0;
        self.waste = 0;
    }

    pub fn deinit(self: *ClauseDatabase, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        self.clauses.deinit(gpa);
    }

    pub fn printDebug(self: *ClauseDatabase) void {
        for (self.clauses.items) |cref| {
            const clause: Clause = self.getClause(cref);
            std.debug.print("{f}\n", .{clause});
        }
    }
};
