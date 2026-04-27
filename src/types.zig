const std = @import("std");

pub const Variable = u31;
pub const Literal = packed struct(u32) {
    neg: u1,
    variable: Variable,
};

pub const ClauseRef = u31;
pub const ClauseHeader = packed struct(u32) {
    size: u27,
    locked: bool,
    learned: bool,
    forgotten: bool,
    relocated: bool,
    simplified: bool,
};

pub const Watcher = struct {
    cref: ClauseRef,
    blocker: Literal,
};

// A custom arena allocator based clause database.
pub const ClauseDatabase = struct {
    data: []u32,
    size: ClauseRef,
    capacity: u32,
    waste: u32,

    pub fn init() ClauseDatabase {
        return .{
            .data = &[_]u32{},
            .size = 0,
            .capacity = 0,
            .waste = 0,
        };
    }

    pub fn addClause(self: *ClauseDatabase, alloc: std.mem.Allocator,
            learned: bool, literals: []Literal) !ClauseRef {
        if (self.size + literals.len + 1 > self.capacity) {
            if (std.math.cast(u32, (self.size + literals.len + 1) << 1)) |val| {
                self.capacity = val;
            } else {
                return error.Overflow;
            }
            self.data = try alloc.realloc(self.data, self.capacity * @sizeOf(u32));
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

        const dest: []Literal = self.getLiterals(cref);
        @memcpy(dest, literals);
        
        self.size += @intCast(literals.len + 1);
        return cref;
    }

    pub fn getHeader(self: ClauseDatabase, cref: ClauseRef) *ClauseHeader {
        return self.data[cref];
    }

    pub fn getLiterals(self: ClauseDatabase, cref: ClauseRef) []Literal {
        const header: ClauseHeader = @bitCast(self.data[cref]);
        return @ptrCast(self.data[cref+1..cref+header.size+1]);
    }

    pub fn clear(self: *ClauseDatabase) void {
        self.size = 0;
        self.waste = 0;
    }

    pub fn deinit(self: *ClauseDatabase, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
    }
};
