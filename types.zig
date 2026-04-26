const std = @import("std");

pub const Variable = u31;
pub const Literal = packed struct {
    variable: Variable,
    neg: bool,
};

pub const Assignment = enum {
    undetermined,
    true,
    false,
};

pub const VariableState = packed struct {
    idx: u32,
    level: u32,
    reason: ClauseRef,
    assigned: bool,
    value: bool,
    forced: bool,
};

pub const ClauseRef = u32;
pub const ClauseHeader = packed struct {
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
const CDB_INIT_SIZE = 0;
const CDB_GROWTH_FACTOR = 2.0;
pub const ClauseDatabase = struct {
    data: []u32,
    size: u32,
    waste: u32,

    fn init(self: *ClauseDatabase, alloc: std.Allocator) !void {
        self.size = 0;
        self.waste = 0;
        self.data = try alloc.alloc(u8, CDB_INIT_SIZE);
    }

    fn addClause(self: *ClauseDatabase, alloc: std.Allocator,
            learned: bool, literals: []Literal) ClauseRef {
        if (self.size + literals.len * @sizeOf(u32) + 1 > self.capacity)
            self.data = try alloc.realloc(self.data, self.size * CDB_GROWTH_FACTOR);
                
        const cref = self.size;
        self.data[cref] = ClauseHeader {
            .size = literals.len,
            .learned = learned,
            .forgotten = false,
            .relocated = false
        };

        const dest: []Literal = getLiterals(cref);
        @memcpy(dest, literals);
        
        self.size += literals.len + 1;
        return cref;
    }

    fn getHeader(self: ClauseDatabase, cref: ClauseRef) ClauseHeader {
        return self.data[cref];
    }

    fn getLiterals(self: ClauseDatabase, cref: ClauseRef) []Literal {
        const header = self.data[cref];
        return self.data[cref+1..cref+header.size+1];
    }

    fn deinit(self: *ClauseDatabase, alloc: std.Allocator) void {
        alloc.free(self.data);
    }
};
