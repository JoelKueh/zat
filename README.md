
# EE5302 - ZAT

ZAT (Zig sAT) is a CDCL based solver written in the Zig programming language.

## Building

To build this program, you must have a recent copy of the Zig compiler (0.16 or later).
- You can download this from the [zig website](https://ziglang.org/download/).

Once you have done this, you can run `zig build` or `zig build --release=fast` to build the project.
- The resulting binary will be in `./zig-out/bin/zat`

## Project Structure

The source code is all in src.
- `main.zig` handles argument parsing and calls the solver.
- `root.zig` implements the solver itself.
- `types.zig` implements a couple of helper types for the solver including the clause database.
- `flat_map.zig` allows for strongly-typed mapping of variables and literals to values.
- `flat_map_heap.zig` is a custom implementation of a binary heap used in the VSIDS heuristic.

Consistent with recommended practice, the sovler returns 10 for SAT and 20 for UNSAT.
