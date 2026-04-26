const std = @import("std");
const ts = @import("./types.zig");

const CnfSat = struct {
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

    pub fn init() CnfSat {
        return .{
            .assignments = .empty,
            .trail = .empty,
            .trail_levels = .empty,
            .reason = .empty,
            .level = .empty,

            .watches = &[_]ts.Watcher{},
            .undos = &[_]ts.ClauseRef{},
            .prop_queue = .empty,

            .clause_inc = 0.0,
            .clause_decay = 0.0,
            .var_inc = 0.0,
            .var_decay = 0.0,
        };
    }

    pub fn loadCnf(self: *CnfSat, io: std.Io, alloc: std.Allocator, file: std.fs.File) !void {
        _ = self;
        _ = alloc;

        var file_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &file_buffer);
        while (try reader.interface.takeDelimiter('\n')) |line| {
            std.debug.print("{d}--{s}\n", .{ line });
        }
    }

    pub fn solve(self: *CnfSat, alloc: std.Allocator, file) !void {

    }

    pub fn deinit(self: *CnfSat, alloc: std.Allocator) !void {
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
