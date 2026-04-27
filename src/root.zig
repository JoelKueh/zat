const std = @import("std");
const ts = @import("./types.zig");

pub const Zat = struct {
    clauses: ts.ClauseDatabase,
    clause_inc: f64,
    clause_decay: f64,

    activity: []f64,
    var_inc: f64,
    var_decay: f64,

    watches: []std.ArrayListUnmanaged(ts.Watcher),
    undos: []std.ArrayListUnmanaged(ts.ClauseRef),
    prop_queue: std.Deque(ts.Literal),

    assignments: []?u1,
    trail: std.ArrayListUnmanaged(ts.Literal),
    trail_levels: std.ArrayListUnmanaged(i32),
    reason: []?ts.ClauseRef,
    level: []i32,
    current_level: i32,

    pub fn init() Zat {
        return .{
            .clauses = .init(),
            .clause_inc = 0.0,
            .clause_decay = 0.0,

            .activity = &.{},
            .var_inc = 0.0,
            .var_decay = 0.0,

            .watches = &.{},
            .undos = &.{},
            .prop_queue = .empty,

            .assignments = &.{},
            .trail = .empty,
            .trail_levels = .empty,
            .reason = &.{},
            .level = &.{},
            .current_level = 0,
        };
    }

    // Removes any CNF data from the solver if it existed.
    // Brings the solver back to the state it was in immediately after .init().
    fn clear(self: *Zat, gpa: std.mem.Allocator) void {
        self.clauses.clear();
        self.clause_inc = 0.0;
        self.clause_decay = 0.0;

        gpa.free(self.activity);
        self.activity = &.{};
        self.var_inc = 0.0;
        self.var_decay = 0.0;

        for (self.watches) |*watch_list| watch_list.deinit(gpa);
        gpa.free(self.watches);
        self.watches = &.{};
        for (self.undos) |*undo_list| undo_list.deinit(gpa);
        gpa.free(self.undos);
        self.undos = &.{};
        self.prop_queue.deinit(gpa);
        self.prop_queue = .empty;

        gpa.free(self.assignments);
        self.assignments = &.{};
        self.trail.clearAndFree(gpa);
        self.trail_levels.clearAndFree(gpa);
        gpa.free(self.reason);
        self.reason = &.{};
        gpa.free(self.level);
        self.level = &.{};
        self.current_level = 0;
    }

    // Allocates space for the internal datastructures.
    // deinit() and clear() both saftely clean up after this allocation.
    fn allocSpace(self: *Zat, gpa: std.mem.Allocator, max_var: u32) !void {
        errdefer self.clear(gpa);

        self.activity = try gpa.alloc(f64, max_var + 1);

        self.watches = try gpa.alloc(std.ArrayListUnmanaged(ts.Watcher), 2 * (max_var + 1));
        for (self.watches) |*watch_list| watch_list.* = .empty;
        self.undos = try gpa.alloc(std.ArrayListUnmanaged(ts.ClauseRef), max_var + 1);
        for (self.undos) |*undo_list| undo_list.* = .empty;
        try self.prop_queue.ensureTotalCapacity(gpa, max_var + 1);

        self.assignments = try gpa.alloc(?u1, max_var + 1);
        for (self.assignments) |*assignment| assignment.* = null;
        try self.trail.ensureTotalCapacity(gpa, max_var + 1);
        try self.trail_levels.ensureTotalCapacity(gpa, max_var + 1);
        self.reason = try gpa.alloc(?ts.ClauseRef, max_var + 1);
        for (self.reason) |*reason| reason.* = null;
        self.level = try gpa.alloc(i32, max_var + 1);
    }

    pub fn loadCnf(self: *Zat, io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) !bool {
        errdefer self.clear(gpa);
        self.clear(gpa);

        // Prepare pool of literals to parse the cnf file
        var max_var: u32 = 0;
        var file_literals: std.ArrayListUnmanaged(ts.Literal) = .empty;
        defer file_literals.deinit(gpa);
        var indicies: std.ArrayListUnmanaged(u32) = .empty;
        defer indicies.deinit(gpa);
        try indicies.append(gpa, 0);

        // Parse the cnf file
        var file_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &file_buffer);
        while (try reader.interface.takeDelimiter('\n')) |line| {
            var lits: std.ArrayList(ts.Literal) = .empty;
            defer lits.deinit(gpa);
            var it = std.mem.splitAny(u8, line, " ");
            while (it.next()) |token| {
                if (token.len == 0) continue;
                if (token[0] == 'c') break;
                if (token[0] == 'p') break;
                if (token[0] == '%') break;

                const num: i32 = try std.fmt.parseInt(i32, token, 10);
                if (@abs(num) > max_var) max_var = @abs(num);
                if (num == 0) break;
                try lits.append(gpa, ts.Literal{ .variable = @intCast(@abs(num)), .neg = @intFromBool(num < 0) });
            }

            if (lits.items.len > 0) {
                try file_literals.appendSlice(gpa, lits.items);
                try indicies.append(gpa, @intCast(file_literals.items.len));
            }
        }

        // Allocate space for the internal datastructures
        try self.allocSpace(gpa, max_var);

        // Add all of the clauses to the internal datastructures
        for (indicies.items[0 .. indicies.items.len - 1], indicies.items[1..]) |sidx, eidx| {
            if (try self.addConstraint(gpa, file_literals.items[sidx..eidx]) == false) {
                return false;
            }
        }

        return true;
    }

    pub fn solve(self: *Zat, gpa: std.mem.Allocator) !void {
        _ = self;
        _ = gpa;
    }

    fn decide(self: *Zat) ?bool {
        
    }

    fn litValue(self: Zat, lit: ts.Literal) ?bool {
        if (self.assignments[lit.variable] == null) return null;
        return self.assignments[lit.variable].? ^ lit.neg != 0;
    }

    // TODO: Maybe don't include trivial satisfiability check.
    fn addConstraint(self: *Zat, gpa: std.mem.Allocator, lits: []ts.Literal) !bool {
        // Check for trivially satisfied clauses and remove duplicate literals
        var i: u32 = 0;
        std.mem.sort(u32, @ptrCast(lits), {}, comptime std.sort.asc(u32));
        for (lits[0 .. lits.len - 1], lits[1..]) |a, b| {
            if (self.litValue(a) orelse false) return true;
            if (@as(u32, @bitCast(a)) == @as(u32, @bitCast(b)) ^ 1) return true;
            i += if (a.variable != b.variable) 1 else 0;
            lits[i] = a;
        }
        const nlits = lits[0..i];

        // Skip empty clauses. Propagate and skip unit clauses.
        if (nlits.len == 0) return false;
        if (nlits.len == 1) return try self.enqueue(gpa, nlits[0], 0);
        const cref: ts.ClauseRef = try self.clauses.addClause(gpa, true, nlits);

        // Clause has two or more literals. Add TWL watches.
        try self.watches[@as(u32, @bitCast(nlits[0])) ^ 1].append(
            gpa, .{ .cref = cref, .blocker = nlits[1] });
        try self.watches[@as(u32, @bitCast(nlits[1])) ^ 1].append(
            gpa, .{ .cref = cref, .blocker = nlits[0] });
        return true;
    }

    // TODO: This duplicate literal logic will go into backjump.
    fn learnClause(self: *Zat, gpa: std.mem.Allocator, lits: []ts.Literal) !bool {
        // Remove duplicate literals
        var i: u32 = 0;
        std.mem.sort(u32, lits, {}, comptime std.sort.asc(u32));
        for (lits[0 .. lits.len - 1], lits[1..]) |a, b| {
            i += if (a.variable != b.variable) 1 else 0;
            lits[i] = a;
        }
        lits = lits[0..i];

        // Skip empty claueses.
        if (lits.len == 0) return;

        const cref: ts.ClauseRef = try self.clauses.addClause(gpa, true, lits);
        _ = cref;
        if (lits.len == 1) try self.prop_queue.enqueue(gpa, lits[0]);
    }

    // TODO: Evaluate whether or not to push reason 0 when propagating constraints.
    fn enqueue(self: *Zat, gpa: std.mem.Allocator, lit: ts.Literal, reason: ?ts.ClauseRef) !bool {
        // Don't try to assign a variable that is already assigned.
        if (self.litValue(lit) == false) return false; // fail on conflicting assignment
        if (self.litValue(lit) == true) return true;   // skip on similar assignment

        // Assign the variable if it hasn't been assigned.
        if (reason == null) {
            self.current_level += 1;
            try self.trail_levels.append(gpa, @intCast(self.trail.items.len));
        }
        self.assignments[lit.variable] = if (lit.neg == 1) 0 else 1;
        self.level[lit.variable] = self.current_level;
        self.reason[lit.variable] = reason;
        try self.trail.append(gpa, lit);

        // Append to the assignment propagation queue.
        try self.prop_queue.pushBack(gpa, lit);
        return true;
    }

    fn propagate(self: *Zat, gpa: std.mem.Allocator, lit: ts.Literal) void {


    }

    pub fn deinit(self: *Zat, gpa: std.mem.Allocator) void {
        self.clauses.deinit(gpa);

        gpa.free(self.activity);

        for (self.watches) |*watch_list| watch_list.deinit(gpa);
        gpa.free(self.watches);
        for (self.undos) |*undo_list| undo_list.deinit(gpa);
        gpa.free(self.undos);
        self.prop_queue.deinit(gpa);

        gpa.free(self.assignments);
        self.trail.deinit(gpa);
        self.trail_levels.deinit(gpa);
        gpa.free(self.reason);
        gpa.free(self.level);
    }
};
