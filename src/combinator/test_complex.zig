usingnamespace @import("gll_parser.zig");
usingnamespace @import("parser_literal.zig");
usingnamespace @import("comb_sequence.zig");
usingnamespace @import("comb_mapto.zig");

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

// Confirms that a direct left-recursive grammar for an empty languages actually rejects
// all input strings, and does not just hang indefinitely:
//
// ```ebnf
// Expr = Expr ;
// Grammar = Expr ;
// ```
//
// See https://cs.stackexchange.com/q/138447/134837
test "direct_left_recursion_empty_language" {
    nosuspend {
        const allocator = testing.allocator;

        const node = struct {
            name: []const u8,
        };

        const ctx = try Context(void, node).init(allocator, "abcabcabc123abc", {});
        defer ctx.deinit();

        var parsers = [_]*Parser(node){
            undefined, // placeholder for left-recursive Expr itself
        };
        var expr = MapTo(void, SequenceValue(node), node).init(.{
            .parser = &Sequence(void, node).init(&parsers).parser,
            .mapTo = struct {
                fn mapTo(in: Result(SequenceValue(node)), _allocator: *mem.Allocator, state_hash: u64, path: ParserPath) Error!Result(node) {
                    switch (in.result) {
                        .err => return Result(node).initError(in.offset, in.result.err),
                        else => {
                            var flattened = try in.result.value.flatten(_allocator, state_hash, path);
                            defer flattened.deinit();
                            return Result(node).init(in.offset, node{ .name = "Expr" });
                        },
                    }
                }
            }.mapTo,
        });
        parsers[0] = &expr.parser;
        try expr.parser.parse(&ctx);

        var sub = ctx.results.subscribe(ctx.state_hash, ctx.path);
        testing.expect(sub.next() == null); // stream closed
    }
}