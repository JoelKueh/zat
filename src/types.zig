


const Watch = struct {
    idx: u32,
};

const Cnf = struct {
    clauses: std.ArrayList(Clause),
    literals: std.ArrayList(Literal),
    watches: std.ArrayList(Watch),

    var_cnt: u32,
    max_var: u32,
    clause_cnt: u32,
    level: u32,

    conflict_literals: std.ArrayList(Literal)
    conflict_clause: u32,

    fn init(alloc: Allocator, path: u8[]) !void {
        
    }

    fn deinit(alloc: Allocator) void {

    }
};
