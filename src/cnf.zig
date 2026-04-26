const std = @import("std");
const types = @import("./types.zig");

const CnfSat = struct {
    clauses: types.ClauseDatabase,
    watches: []std.ArrayList(types.Watcher),
    undos: []std.ArrayList(types.ClauseRef),

    unit_clauses: 
};
