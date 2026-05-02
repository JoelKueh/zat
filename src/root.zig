const std = @import("std");
const ts = @import("./types.zig");

pub const Instance = []bool;

pub const Zat = struct {
    clauses: ts.ClauseDatabase,
    clause_inc: f64,
    clause_decay: f64,

    activity: []ts.Activity,
    var_inc: ts.Activity,
    var_decay: ts.Activity,
    order_heap: ts.ActivityHeap,

    watches: []std.ArrayList(ts.Watcher),
    prop_queue: std.Deque(ts.Literal),

    assignments: []?u1,
    trail: std.ArrayList(ts.Literal),
    trail_levels: std.ArrayList(i32),
    reason: []?ts.ClauseRef,
    level: []i32,
    current_level: i32,
    max_var: ts.Variable,

    pub fn init() Zat {
        return .{
            .clauses = .init(),
            .clause_inc = 0.0,
            .clause_decay = 0.0,

            .activity = &.{},
            .var_inc = 0.0,
            .var_decay = 0.0,
            .order_heap = .empty,

            .watches = &.{},
            .prop_queue = .empty,

            .assignments = &.{},
            .trail = .empty,
            .trail_levels = .empty,
            .reason = &.{},
            .level = &.{},
            .current_level = 0,
            .max_var = 0,
        };
    }

    pub fn loadCnf(self: *Zat, io: std.Io, gpa: std.mem.Allocator, file: std.Io.File) !bool {
        errdefer self.clear(gpa);
        self.clear(gpa);

        // Prepare pool of literals to parse the cnf file
        var max_var: ts.Variable = 0;
        var file_literals: std.ArrayList(ts.Literal) = .empty;
        defer file_literals.deinit(gpa);
        var indicies: std.ArrayList(u32) = .empty;
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
                if (@abs(num) > max_var) max_var = @intCast(@abs(num));
                if (num == 0) break;

                const lit: ts.Literal = .{
                    .variable = @intCast(@abs(num)),
                    .neg = @intFromBool(num < 0)
                };
                try lits.append(gpa, lit);
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

    pub fn solve(self: *Zat, gpa: std.mem.Allocator) !bool {
        while (true) {
            const cref: ?ts.ClauseRef = try self.propagate(gpa);
            if (cref != null) {
                if (self.current_level == 0) return false;
                var resolution: ts.Resolution = try self.analyze(gpa, cref orelse unreachable);
                defer resolution.deinit(gpa);
                try self.backjump(gpa, resolution.level);
                try self.learnClause(gpa, resolution.lits);
                continue;
            }

            if (self.order_heap.items.len == 0) {
                return true;
            } else {
                _ = try self.decide(gpa);
            }
        }
    }

    // Returns the instance that is the solution to the SAT problem.
    // The slice returned by this function is owned by the caller and must be freed with 'gpa'.
    pub fn getResultOwned(self: *Zat, gpa: std.mem.Allocator) ![]bool {
        const inst: Instance = gpa.alloc(bool, self.max_var+1);
        for (self.assignments, 0..) |v, i| {
            inst[i] = v orelse error.Invalid;
        }
        return inst;
    }

    // Returns a Resolution struct containing the backjump level and resolution clause.
    // This struct is owned by the caller and must be deinitialized with 'gpa'.
    fn analyze(self: *Zat, gpa: std.mem.Allocator, cref: ts.ClauseRef) !ts.Resolution {
        const conflict_vars: []bool = try gpa.alloc(bool, self.max_var+1);
        defer gpa.free(conflict_vars);
        var res_literals: std.ArrayList(ts.Literal) = .empty;
        defer res_literals.deinit(gpa);

        var conflict_literal: ts.Literal = undefined;
        var backjump_level: u32 = 0;
        var conflict_var_cnt: u32 = 0;
        for (conflict_vars) |*v| v.* = false;
        try res_literals.append(gpa, undefined);

        var conflict: ts.Clause = self.clauses.getClause(cref);
        const conflict_lits: []const ts.Literal = conflict.getConflict();
        while (true) {
            // Analyze the reason for the current assignment.
            for (conflict_lits) |lit| {
                if (conflict_vars[lit.variable]) continue;
                if (self.level[lit.variable] == 0) continue;
                if (self.level[lit.variable] == self.current_level) {
                    conflict_var_cnt += 1;
                    continue;
                }

                // Only add variables that are in the range (0..current_level)
                try res_literals.append(gpa, lit);
                backjump_level = @max(backjump_level, self.level[lit.variable]);
            }

            // Select another literal to look at.
            while (true) {
                conflict_literal = self.trail.getLast();
                const reason = self.reason[conflict_literal.raw()] orelse unreachable;
                conflict = self.clauses.getClause(reason);
                try self.undo(gpa);
            }

            conflict_var_cnt -= 1;
            if (conflict_var_cnt == 0) break;
        }

        // Add the decision literal to the start of the clause.
        res_literals[0] = conflict_literal;

        // Remove duplicate literals
        var i: u32 = 0;
        const resolution: []ts.Literal = res_literals.toOwnedSlice();
        std.mem.sort(u32, @ptrCast(resolution), {}, comptime std.sort.asc(u32));
        for (resolution[0..resolution.len - 1], resolution[1..]) |a, b| {
            if (a.variable != b.variable) i += 1;
            resolution[i] = a;
        }

        return .{ .level = backjump_level, .lits = resolution };
    }

    // TODO: Don't only decide false
    fn decide(self: *Zat, gpa: std.mem.Allocator) !bool {
        const v: ts.Variable = self.order_heap.pop() orelse unreachable;
        const lit: ts.Literal = .{ .neg = 1, .variable = v };
        return try self.assign(gpa, lit, null);
    }

    fn undo(self: *Zat, gpa: std.mem.Allocator) !void {
        const lit: ts.Literal = self.trail.pop() orelse unreachable;
        const v: ts.Variable = lit.variable;
        self.assignments[v] = null;
        self.reason[v] = null;
        self.level[v] = -1;
        self.current_level = self.level[self.trail.getLast().variable];
        try self.order_heap.push(gpa, v);
    }

    fn backtrack(self: *Zat, gpa: std.mem.Allocator) !void {
        const cnt: u32 = @as(u32, @intCast(self.trail.items.len))
            - @as(u32, @intCast(self.trail_levels.getLast()));
        for (0..cnt) |_| {
            try self.undo(gpa);
        }
        _ = self.trail_levels.pop() orelse unreachable;
    }

    fn backjump(self: *Zat, gpa: std.mem.Allocator, level: u32) !void {
        while (self.current_level > level) {
            try self.backtrack(gpa);
        }
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
            if (a.raw() == b.inv().raw()) return true;
            i += if (a.variable != b.variable) 1 else 0;
            lits[i] = a;
        }
        const reduced_lits = lits[0..i];

        // Skip empty clauses. Propagate and skip unit clauses.
        if (reduced_lits.len == 0) return false;
        if (reduced_lits.len == 1) return try self.assign(gpa, reduced_lits[0], null);
        const cref: ts.ClauseRef = try self.clauses.addClause(gpa, true, reduced_lits);

        // Clause has two or more literals. Add TWL watches.
        const w1: ts.Watcher = .{ .cref = cref, .blocker = reduced_lits[1] };
        try self.watches[reduced_lits[0].inv().raw()].append(gpa, w1);
        const w2: ts.Watcher = .{ .cref = cref, .blocker = reduced_lits[0] };
        try self.watches[reduced_lits[1].inv().raw()].append(gpa, w2);

        return true;
    }

    // TODO: This duplicate literal logic will go into backjump.
    fn learnClause(self: *Zat, gpa: std.mem.Allocator, lits: []ts.Literal) !void {
        std.debug.assert(lits.len > 1);

        // Clause has two or more literals. Add TWL watches.
        const cref: ts.ClauseRef = try self.clauses.addClause(gpa, true, lits);
        const w1: ts.Watcher = .{ .cref = cref, .blocker = lits[1] };
        try self.watches[lits[0].inv().raw()].append(gpa, w1);
        const w2: ts.Watcher = .{ .cref = cref, .blocker = lits[0] };
        try self.watches[lits[1].inv().raw()].append(gpa, w2);
    }

    // TODO: Evaluate whether or not to push reason 0 when propagating constraints.
    fn assign(self: *Zat, gpa: std.mem.Allocator, lit: ts.Literal, reason: ?ts.ClauseRef) !bool {
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

    fn propagate(self: *Zat, gpa: std.mem.Allocator) !?ts.ClauseRef {
        while (self.prop_queue.len > 0) {
            const lit: ts.Literal = self.prop_queue.popFront() orelse unreachable;
            const watchlist: []ts.Watcher = try self.watches[lit.raw()].toOwnedSlice(gpa);
            for (watchlist) |watch| {
                if (watch.blocker == lit) continue;
                const clause: ts.Clause = self.clauses.getClause(watch.cref);
                if (try self.visitClause(gpa, clause, lit) == false) return clause.cref;
            }
            gpa.free(watchlist);
        }

        return null;
    }

    fn visitClause(self: *Zat, gpa: std.mem.Allocator, clause: ts.Clause, lit: ts.Literal) !bool {
        // Invariant - Propagated literal is always at lits[0].
        if (clause.lits[0] == lit.inv()) {
            std.mem.swap(ts.Literal, &clause.lits[0], &clause.lits[1]);
        }

        // Search for a new watcher in the list of literals.
        for (2..self.max_var+1) |i| {
            // Invariant - Watched literals are always at 0 and 1 in the list.
            if (self.litValue(clause.lits[0]) == false) continue;
            std.mem.swap(ts.Literal, &clause.lits[1], &clause.lits[i]);
            const watcher: ts.Watcher = .{ .blocker = clause.lits[0], .cref = clause.cref };
            try self.watches[lit.raw()].append(gpa, watcher);
        }

        // Clause is unit if another watcher was not found.
        const watcher: ts.Watcher = .{ .blocker = clause.lits[0], .cref = clause.cref };
        try self.watches[lit.raw()].append(gpa, watcher);
        return self.assign(gpa, clause.lits[0], clause.cref);
    }

    // Allocates space for the internal datastructures.
    // deinit() and clear() both saftely clean up after this allocation.
    fn allocSpace(self: *Zat, gpa: std.mem.Allocator, max_var: ts.Variable) !void {
        errdefer self.clear(gpa);

        self.activity = try gpa.alloc(f64, max_var + 1);

        self.watches = try gpa.alloc(std.ArrayList(ts.Watcher), 2 * (max_var + 1));
        for (self.watches) |*watch_list| watch_list.* = .empty;
        try self.prop_queue.ensureTotalCapacity(gpa, max_var + 1);

        self.assignments = try gpa.alloc(?u1, max_var + 1);
        for (self.assignments) |*assignment| assignment.* = null;
        try self.trail.ensureTotalCapacity(gpa, max_var + 1);
        try self.trail_levels.ensureTotalCapacity(gpa, max_var + 1);
        self.reason = try gpa.alloc(?ts.ClauseRef, max_var + 1);
        for (self.reason) |*reason| reason.* = null;
        self.level = try gpa.alloc(i32, max_var + 1);
        self.current_level = 0;
        self.max_var = max_var;
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
        self.order_heap.deinit(gpa);
        self.order_heap = .empty;

        for (self.watches) |*watch_list| watch_list.deinit(gpa);
        gpa.free(self.watches);
        self.watches = &.{};
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
        self.max_var = 0;
    }

    pub fn deinit(self: *Zat, gpa: std.mem.Allocator) void {
        self.clauses.deinit(gpa);

        gpa.free(self.activity);
        self.order_heap.deinit(gpa);

        for (self.watches) |*watch_list| watch_list.deinit(gpa);
        gpa.free(self.watches);
        self.prop_queue.deinit(gpa);

        gpa.free(self.assignments);
        self.trail.deinit(gpa);
        self.trail_levels.deinit(gpa);
        gpa.free(self.reason);
        gpa.free(self.level);
    }
};
