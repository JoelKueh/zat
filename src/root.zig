const std = @import("std");
const ts = @import("./types.zig");

pub const Instance = []bool;

const VAR_INC_INIT: f64 = 1.0;
const VAR_DECAY_INIT: f64 = 0.95;
const CLAUSE_INC_INIT: f64 = 1.0;
const CLAUSE_DECAY_INIT: f64 = 0.95;

pub const Zat = struct {
    clauses: ts.ClauseDatabase,
    clause_inc: f64,
    clause_decay: f64,

    activity: ts.VariableMap(ts.Activity),
    var_inc: ts.Activity,
    var_decay: ts.Activity,
    order_heap: ts.ActivityHeap,

    watches: ts.LiteralMap(std.ArrayList(ts.Watcher)),
    prop_queue: std.Deque(ts.Literal),

    assignments: ts.VariableMap(?u1),
    trail: std.ArrayList(ts.Literal),
    trail_levels: std.ArrayList(i32),
    reason: ts.VariableMap(?ts.ClauseRef),
    level: ts.VariableMap(i32),
    current_level: i32,
    max_var: ts.Variable,

    pub fn init() Zat {
        return .{
            .clauses = .init(),
            .clause_inc = CLAUSE_INC_INIT,
            .clause_decay = CLAUSE_DECAY_INIT,

            .activity = .empty,
            .var_inc = VAR_INC_INIT,
            .var_decay = VAR_DECAY_INIT,
            .order_heap = .empty,

            .watches = .empty,
            .prop_queue = .empty,

            .assignments = .empty,
            .trail = .empty,
            .trail_levels = .empty,
            .reason = .empty,
            .level = .empty,
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
        _ = try self.assignFact(gpa, .{ .neg = 1, .variable = 0 });

        return true;
    }

    pub fn solve(self: *Zat, gpa: std.mem.Allocator) !bool {
        while (true) {
            const cref: ?ts.ClauseRef = try self.propagate(gpa);
            if (cref != null) {
                if (self.current_level == 0) return false;
                var resolution: ts.Resolution = try self.analyze(gpa, cref orelse unreachable);
                defer resolution.deinit(gpa);
                self.backjump(resolution.level);
                try self.learnClause(gpa, resolution.lits);
                self.varDecayActivity();
                continue;
            }

            if (self.order_heap.count == 0) {
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
        for (self.assignments.items, 0..) |v, i| {
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

        var conflict_ref: ?ts.ClauseRef = cref;
        var conflict_literal: ?ts.Literal = null;
        var backjump_level: u32 = 0;
        var conflict_var_cnt: i32 = 0;
        for (conflict_vars) |*v| v.* = false;
        try res_literals.append(gpa, undefined);

        var trail_idx: usize = self.trail.items.len - 1;

        // TODO: Remove
        const new_trail: []u32 = try gpa.alloc(u32, self.trail.items.len);
        defer gpa.free(new_trail);
        for (new_trail, self.trail.items) |*i, j| i.* = j.variable;
        const new_levels: []i32 = try gpa.alloc(i32, self.trail.items.len);
        defer gpa.free(new_levels);
        for (new_levels, self.trail.items) |*i, j| i.* = self.level.get(j.variable);
        while (true) {
            // Grab the literals for the new conflict clause.
            std.debug.assert(conflict_ref != null);
            const conflict: ts.Clause = self.clauses.getClause(conflict_ref.?);
            const conflict_lits: []const ts.Literal = conflict.getReason(conflict_literal);
            
            // Analyze the reason for the current assignment.
            for (conflict_lits) |lit| {
                // Skip duplicates and facts that are false at level 0.
                if (conflict_vars[lit.variable]) continue;
                conflict_vars[lit.variable] = true;
                if (self.level.get(lit.variable) == 0) continue;

                // Skip all variables at the current decision level as they will be resolved.
                if (self.level.get(lit.variable) == self.current_level) {
                    conflict_var_cnt += 1;
                    continue;
                }

                // Only add variables that are in the range (0..current_level)
                try res_literals.append(gpa, lit);
                backjump_level = @max(backjump_level, self.level.get(lit.variable));
            }

            // Select another literal to look at.
            while (!conflict_vars[self.trail.items[trail_idx].variable]) trail_idx -= 1;
            conflict_literal = self.trail.items[trail_idx];
            conflict_ref = self.reason.get(conflict_literal.?.variable);
            trail_idx -= 1;

            // Stop if there are no variables at the current decision level in the resolution.
            conflict_var_cnt -= 1;
            if (conflict_var_cnt <= 0) break;
        }

        // Add the decision literal to the start of the clause.
        res_literals.items[0] = conflict_literal.?.inv();
        const resolution: []ts.Literal = try res_literals.toOwnedSlice(gpa);
        if (resolution.len == 1) backjump_level = 0;
        return .{ .level = backjump_level, .lits = resolution };
    }

    // TODO: Don't only decide false
    fn decide(self: *Zat, gpa: std.mem.Allocator) !bool {
        var v: ?ts.Variable = self.order_heap.pop();
        while (v != null and self.assignments.get(v.?) != null) v = self.order_heap.pop();
        if (v == null) return false;
        const lit: ts.Literal = .{ .neg = 1, .variable = v.? };
        return try self.assign(gpa, lit, null);
    }

    fn undo(self: *Zat) void {
        const lit: ts.Literal = self.trail.pop() orelse unreachable;
        const v: ts.Variable = lit.variable;
        self.assignments.getPtr(v).* = null;
        self.reason.getPtr(v).* = null;
        self.level.getPtr(v).* = -1;
        if (!self.order_heap.contains(v)) self.order_heap.addUnchecked(v);
        self.current_level = self.level.get(self.trail.getLast().variable);
    }

    fn backtrack(self: *Zat) void {
        const start: u32 = @as(u32, @intCast(self.trail_levels.getLast()));
        const end: u32 = @as(u32, @intCast(self.trail.items.len));
        for (start..end) |_| {
            self.undo();
        }
        _ = self.trail_levels.pop() orelse unreachable;
    }

    fn backjump(self: *Zat, level: u32) void {
        while (self.current_level > level) {
            self.backtrack();
        }
    }

    fn litIsFalse(self: Zat, lit: ts.Literal) bool {
        if (self.assignments.get(lit.variable) == null) return false;
        return self.assignments.get(lit.variable).? ^ lit.neg != 1;
    }

    fn litIsTrue(self: Zat, lit: ts.Literal) bool {
        if (self.assignments.get(lit.variable) == null) return false;
        return self.assignments.get(lit.variable).? ^ lit.neg != 0;
    }

    fn litIsNull(self: Zat, lit: ts.Literal) bool {
        return self.assignments.get(lit.variable) == null;
    }

    fn varRescaleActivity(self: *Zat) void {
        for (1..self.max_var+1) |i| self.activity.getPtr(@intCast(i)).* *= 1e-100;
        self.var_inc *= 1e-100;
    }

    fn varDecayActivity(self: *Zat) void {
        self.var_inc *= 1.0 / self.var_decay;
    }

    fn varBumpActivity(self: *Zat, variable: ts.Variable) void {
        self.activity.getPtr(variable).* += self.var_inc;
        self.order_heap.percolate(variable);
        if (self.activity.get(variable) > 1e100) self.varRescaleActivity();
    }

    // TODO: Maybe don't include trivial satisfiability check.
    fn addConstraint(self: *Zat, gpa: std.mem.Allocator, lits: []ts.Literal) !bool {
        // Check for trivially satisfied clauses and remove false literals.
        var i: u32 = 0;
        var reduced_lits: []ts.Literal = lits;
        for (reduced_lits[0..reduced_lits.len]) |lit| {
            if (self.litIsTrue(lit)) return true;
            reduced_lits[i] = lit;
            if (self.litIsNull(lit)) i += 1;
        }
        reduced_lits = lits[0..i];

        // Remove duplicate literals and detect trivially satisfied clauses.
        i = 0;
        std.mem.sort(u32, @ptrCast(reduced_lits), {}, comptime std.sort.asc(u32));
        var window_it = std.mem.window(ts.Literal, reduced_lits, 2, 1);
        while (window_it.next()) |window| {
            if (window.len < 2) break;
            if (window[0].raw() == window[1].inv().raw()) return true;
            if (window[0].raw() != window[1].raw()) i += 1;
            lits[i] = window[1];
        }
        const reduced_len: u32 = @min(reduced_lits.len, i+1);
        reduced_lits = lits[0..reduced_len];

        // Skip empty clauses. Propagate and skip unit clauses.
        if (reduced_lits.len == 0) return false;
        if (reduced_lits.len == 1) return try self.assignFact(gpa, reduced_lits[0]);
        const cref: ts.ClauseRef = try self.clauses.addClause(gpa, true, reduced_lits);

        // Clause has two or more literals. Add TWL watches.
        const w1: ts.Watcher = .{ .cref = cref, .blocker = reduced_lits[1] };
        try self.watches.getPtr(reduced_lits[0].inv()).append(gpa, w1);
        const w2: ts.Watcher = .{ .cref = cref, .blocker = reduced_lits[0] };
        try self.watches.getPtr(reduced_lits[1].inv()).append(gpa, w2);

        return true;
    }

    fn learnClause(self: *Zat, gpa: std.mem.Allocator, lits: []ts.Literal) !void {
        std.debug.assert(lits.len > 0);
        std.debug.assert(self.assignments.get(lits[0].variable) == null);
        if (lits.len == 1) {
            _ = try self.assignFact(gpa, lits[0]);
            return;
        }

        // Add the clause to the database and perform unit propagation on it.
        const cref: ts.ClauseRef = try self.clauses.addClause(gpa, true, lits);
        _ = try self.assign(gpa, lits[0], cref);

        // Bump priorities of the variables in the clause.
        for (lits) |literal| self.varBumpActivity(literal.variable);

        // Add TWL watches to support backtracking.
        const w1: ts.Watcher = .{ .cref = cref, .blocker = lits[1] };
        try self.watches.getPtr(lits[0].inv()).append(gpa, w1);
        const w2: ts.Watcher = .{ .cref = cref, .blocker = lits[0] };
        try self.watches.getPtr(lits[1].inv()).append(gpa, w2);
    }

    fn assign(self: *Zat, gpa: std.mem.Allocator, lit: ts.Literal, reason: ?ts.ClauseRef) !bool {
        // Don't try to assign a variable that is already assigned.
        if (self.litIsFalse(lit)) return false; // fail on conflicting assignment
        if (self.litIsTrue(lit)) return true;   // skip on similar assignment

        // Assign the variable if it hasn't been assigned.
        if (reason == null) {
            self.current_level += 1;
            try self.trail_levels.append(gpa, @intCast(self.trail.items.len));
        }
        self.assignments.getPtr(lit.variable).* = if (lit.neg == 1) 0 else 1;
        self.level.getPtr(lit.variable).* = self.current_level;
        self.reason.getPtr(lit.variable).* = reason;
        try self.trail.append(gpa, lit);

        // Append to the assignment propagation queue.
        try self.prop_queue.pushBack(gpa, lit);
        return true;
    }

    // Assigns a fact at the lowest decision level.
    fn assignFact(self: *Zat, gpa: std.mem.Allocator, lit: ts.Literal) !bool {
        std.debug.assert(self.current_level == 0);
        if (self.litIsFalse(lit)) return false; // fail on conflicting assignment
        if (self.litIsTrue(lit)) return true;   // skip on similar assignment
        
        self.assignments.getPtr(lit.variable).* = if (lit.neg == 1) 0 else 1;
        self.level.getPtr(lit.variable).* = self.current_level;
        self.reason.getPtr(lit.variable).* = null;
        try self.trail.append(gpa, lit);

        try self.prop_queue.pushBack(gpa, lit);
        return true;
    }

    fn propagate(self: *Zat, gpa: std.mem.Allocator) !?ts.ClauseRef {
        while (self.prop_queue.len > 0) {
            const lit: ts.Literal = self.prop_queue.popFront() orelse unreachable;
            const watchlist: *std.ArrayList(ts.Watcher) = self.watches.getPtr(lit);
            const conflict: ?ts.ClauseRef = try self.walkWatchlist(gpa, watchlist, lit);
            if (conflict != null) {
                while (self.prop_queue.popFront()) |_| {}
                return conflict;
            }
        }

        return null;
    }

    fn walkWatchlist(
        self: *Zat,
        gpa: std.mem.Allocator,
        watchlist: *std.ArrayList(ts.Watcher),
        lit: ts.Literal,
    ) !?ts.ClauseRef {
        var conflict: ?ts.ClauseRef = null;
        var write_idx: u32 = 0;

        watchlist: for (watchlist.items, 0..) |watch, read_idx| {
            // Skip watches that are already true.
            if (self.litIsTrue(watch.blocker)) {
                watchlist.items[write_idx] = watch;
                write_idx += 1;
                continue;
            }

            // Invariant - Propagated literal is always at lits[0].
            const clause: ts.Clause = self.clauses.getClause(watch.cref);
            if (clause.lits[0] == lit.inv()) {
                std.mem.swap(ts.Literal, &clause.lits[0], &clause.lits[1]);
            }

            // Search for a new watcher in the list of literals.
            const new_watch: ts.Watcher = .{ .blocker = clause.lits[0], .cref = clause.cref };
            for (2..clause.lits.len) |lit_idx| {
                // Invariant - Watched literals are always at 0 and 1 in the list.
                if (self.litIsFalse(clause.lits[lit_idx])) continue;
                std.mem.swap(ts.Literal, &clause.lits[1], &clause.lits[lit_idx]);
                try self.watches.getPtr(clause.lits[1].inv()).append(gpa, new_watch);
                continue :watchlist;
            }

            // Clause is unit if another watcher was not found.
            watchlist.items[write_idx] = new_watch;
            write_idx += 1;
            const result: bool = try self.assign(gpa, clause.lits[0], clause.cref);

            // If there was a conflict, copy remaining watches and break.
            if (!result) {
                conflict = clause.cref;
                for (read_idx+1..watchlist.items.len) |idx| {
                    watchlist.items[write_idx] = watchlist.items[idx];
                    write_idx += 1;
                }
                break :watchlist;
            }
        }

        // Shrink the old watchlist to the new size.
        watchlist.shrinkRetainingCapacity(write_idx);

        return conflict;
    }

    // Allocates space for the internal datastructures.
    // deinit() and clear() both saftely clean up after this allocation.
    fn allocSpace(self: *Zat, gpa: std.mem.Allocator, max_var: ts.Variable) !void {
        errdefer self.clear(gpa);

        // TODO: Remove me and implement real priority
        self.activity = try .initCapacity(gpa, max_var + 1);
        for (self.activity.items) |*activity| activity.* = 0.0;
        self.order_heap = try ts.ActivityHeap.initCapacity(gpa, self.activity, max_var + 1);
        for (1..max_var+1) |i| self.order_heap.addUnchecked(@intCast(i));

        self.watches = try .initCapacity(gpa, 2 * (max_var + 1));
        for (self.watches.items) |*watch_list| watch_list.* = .empty;
        try self.prop_queue.ensureTotalCapacity(gpa, max_var + 1);

        self.assignments = try .initCapacity(gpa, max_var + 1);
        for (self.assignments.items) |*assignment| assignment.* = null;
        try self.trail.ensureTotalCapacity(gpa, max_var + 1);
        try self.trail_levels.ensureTotalCapacity(gpa, max_var + 1);
        self.reason = try .initCapacity(gpa, max_var + 1);
        for (self.reason.items) |*reason| reason.* = null;
        self.level = try .initCapacity(gpa, max_var + 1);
        for (self.level.items) |*level| level.* = -1;
        self.current_level = 0;
        self.max_var = max_var;
    }

    // Removes any CNF data from the solver if it existed.
    // Brings the solver back to the state it was in immediately after .init().
    fn clear(self: *Zat, gpa: std.mem.Allocator) void {
        self.clauses.clear();
        self.clause_inc = CLAUSE_INC_INIT;
        self.clause_decay = CLAUSE_DECAY_INIT;

        self.activity.deinit(gpa);
        self.activity = .empty;
        self.var_inc = VAR_INC_INIT;
        self.var_decay = VAR_DECAY_INIT;
        self.order_heap.deinit(gpa);
        self.order_heap = .empty;

        for (self.watches.items) |*watch_list| watch_list.deinit(gpa);
        self.watches.deinit(gpa);
        self.watches = .empty;
        self.prop_queue.deinit(gpa);
        self.prop_queue = .empty;

        self.assignments.deinit(gpa);
        self.assignments = .empty;
        self.trail.clearAndFree(gpa);
        self.trail_levels.clearAndFree(gpa);
        self.reason.deinit(gpa);
        self.reason = .empty;
        self.level.deinit(gpa);
        self.level = .empty;
        self.current_level = 0;
        self.max_var = 0;
    }

    pub fn deinit(self: *Zat, gpa: std.mem.Allocator) void {
        self.clauses.deinit(gpa);

        self.activity.deinit(gpa);
        self.order_heap.deinit(gpa);

        for (self.watches.items) |*watch_list| watch_list.deinit(gpa);
        self.watches.deinit(gpa);
        self.prop_queue.deinit(gpa);

        self.assignments.deinit(gpa);
        self.trail.deinit(gpa);
        self.trail_levels.deinit(gpa);
        self.reason.deinit(gpa);
        self.level.deinit(gpa);
    }
};
