

const Variable = u31;
const Literal = packed struct {
    vidx: Variable,
    neg: bool,
};

const Clause = struct {
    start_idx: u32,
    end_idx: u32,
};

const VariableState = packed struct {
    idx: u32,    // Index of the variable in the decision stack.
    level: u32,  // Decision level of the variable.
    reason: u32, // Index of the clause that forced this assignment.
    assigned: bool,
    value: bool,
    forced: bool,
};

const Watch = struct {
    idx: u32,
};

const ClauseDatabase = struct {
    clauses: std.ArrayList(Clause),
    literals: std.ArrayList(Literals),
    watches: std.ArrayList(Watch),
};
