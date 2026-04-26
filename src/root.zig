const std = @import("std");
const ts = @import("./types.zig");

pub const Zat = struct {
    clauses: ts.ClauseDatabase,
    clause_inc: f64,
    clause_decay: f64,

    activity: std.ArrayList(f64),
    var_inc: f64,
    var_decay: f64,

    watches: []std.ArrayList(ts.Watcher),
    undos: []std.ArrayList(ts.ClauseRef),
    prop_queue: std.Deque,

    assignments: std.ArrayList(ts.Assignment),
    trail: std.ArrayList(ts.Literal),
    trail_levels: std.ArrayList(i32),
    reason: std.ArrayList(ts.ClauseRef),
    level: std.ArrayList(i32),

    pub fn init() Zat {
        return .{
            .assignments = .empty,
            .trail = .empty,
            .trail_levels = .empty,
            .reason = .empty,
            .level = .empty,
            .clauses = .init(),

            .watches = &[_]ts.Watcher{},
            .undos = &[_]ts.ClauseRef{},
            .prop_queue = .empty,

            .clause_inc = 0.0,
            .clause_decay = 0.0,
            .var_inc = 0.0,
            .var_decay = 0.0,
        };
    }

    pub fn loadCnf(self: *Zat, io: std.Io, alloc: std.Allocator, file: std.fs.File) !void {
        var file_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &file_buffer);
        while (try reader.interface.takeDelimiter('\n')) |line| {
            var lits: std.ArrayList(ts.Literal) = .init();
            var it = std.mem.splitAny(u8, line, " ");
            while (it.next()) |token| {
                if (token.len == 0) continue;
                if (token[0] == 'c') break;
                if (token[0] == 'p') break;
                if (token[0] == '%') return;

                const num: i32 = try std.fmt.parseInt(i32, token, 10);
                if (num == 0) break;
                lits.append(ts.Literal{.variable = @abs(num), .neg = num < 0});
            }
            try self.clauses.addClause(alloc, false, lits);
        }
    }

    pub fn solve(self: *Zat, alloc: std.Allocator) !void {
        _ = self;
        _ = alloc;
    }

    pub fn deinit(self: *Zat, alloc: std.Allocator) !void {
        self.clauses.deinit();
        self.assignments.deinit();
        self.trail.deinit();
        self.trail_levels.deinit();
        self.reason.deinit();
        self.level.deinit();

        for (self.watches) |watch_list| {
            watch_list.deinit();
        }
        alloc.free(self.watches);

        for (self.undos) |undo_list| {
            undo_list.deinit();
        }
        alloc.free(self.undos);
    }
};
