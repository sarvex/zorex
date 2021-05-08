usingnamespace @import("../engine/engine.zig");
const Literal = @import("../parser/literal.zig").Literal;
const LiteralValue = @import("../parser/literal.zig").LiteralValue;

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

pub fn RepeatedContext(comptime Value: type) type {
    return struct {
        /// The parser which should be repeatedly parsed.
        parser: *const Parser(Value),

        /// The minimum number of times the parser must successfully match.
        min: usize,

        /// The maximum number of times the parser can match, or -1 for unlimited.
        max: isize,
    };
}

/// Represents a single value in the stream of repeated values.
///
/// In the case of a non-ambiguous grammar, a `Repeated` combinator will yield:
///
/// ```
/// stream(value1, value2)
/// ```
///
/// In the case of an ambiguous grammar, it would yield a stream with only the first parse path.
/// Use RepeatedAmbiguous if ambiguou parse paths are desirable.
pub fn RepeatedValue(comptime Value: type) type {
    return Value;
}

/// Matches the `input` repeatedly, between `[min, max]` times (inclusive.) If ambiguous parse paths
/// are desirable, use RepeatedAmbiguous.
///
/// The `input` parsers must remain alive for as long as the `Repeated` parser will be used.
pub fn Repeated(comptime Input: type, comptime Value: type) type {
    return struct {
        parser: Parser(RepeatedValue(Value)) = Parser(RepeatedValue(Value)).init(parse, nodeName),
        input: RepeatedContext(Value),

        const Self = @This();

        pub fn init(input: RepeatedContext(Value)) Self {
            return Self{ .input = input };
        }

        pub fn nodeName(parser: *const Parser(RepeatedValue(Value)), node_name_cache: *std.AutoHashMap(usize, ParserNodeName)) Error!u64 {
            const self = @fieldParentPtr(Self, "parser", parser);

            var v = std.hash_map.hashString("Repeated");
            v +%= try self.input.parser.nodeName(node_name_cache);
            v +%= std.hash_map.getAutoHashFn(usize)(self.input.min);
            v +%= std.hash_map.getAutoHashFn(isize)(self.input.max);
            return v;
        }

        pub fn parse(parser: *const Parser(RepeatedValue(Value)), in_ctx: *const Context(void, RepeatedValue(Value))) callconv(.Async) Error!void {
            const self = @fieldParentPtr(Self, "parser", parser);
            var ctx = in_ctx.with(self.input);
            defer ctx.results.close();

            // Invoke the child parser repeatedly to produce each of our results. Each time we ask
            // the child parser to parse, it can produce a set of results (its result stream) which
            // are varying parse paths / interpretations, we take the first successful one.

            // Return early if we're not trying to parse anything (stream close signals to the
            // consumer there were no matches).
            if (ctx.input.max == 0) {
                return;
            }

            var num_values: usize = 0;
            var offset: usize = 0;
            while (true) {
                const child_node_name = try self.input.parser.nodeName(&in_ctx.memoizer.node_name_cache);
                var child_ctx = try ctx.with({}).initChild(Value, child_node_name, offset);
                defer child_ctx.deinitChild();
                if (!child_ctx.existing_results) try self.input.parser.parse(&child_ctx);

                var num_local_values: usize = 0;
                var sub = child_ctx.results.subscribe(ctx.key, ctx.path, Result(Value).initError(ctx.offset, "matches only the empty language"));
                while (sub.next()) |next| {
                    switch (next.result) {
                        .err => {
                            if (num_values < ctx.input.min) {
                                try ctx.results.add(Result(RepeatedValue(Value)).initError(next.offset, next.result.err));
                            }
                            return;
                        },
                        else => {
                            // TODO(slimsag): need path committal functionality
                            if (num_local_values == 0) {
                                // TODO(slimsag): if no consumption, could get stuck forever!
                                offset = next.offset;
                                try ctx.results.add(next);
                            }
                            num_local_values += 1;
                        },
                    }
                }

                num_values += 1;
                if (num_values >= ctx.input.max and ctx.input.max != -1) break;
            }
        }
    };
}

test "repeated" {
    nosuspend {
        const allocator = testing.allocator;

        const ctx = try Context(void, RepeatedValue(LiteralValue)).init(allocator, "abcabcabc123abc", {});
        defer ctx.deinit();

        var abcInfinity = Repeated(void, LiteralValue).init(.{
            .parser = &Literal.init("abc").parser,
            .min = 0,
            .max = -1,
        });
        try abcInfinity.parser.parse(&ctx);

        var sub = ctx.results.subscribe(ctx.key, ctx.path, Result(RepeatedValue(LiteralValue)).initError(ctx.offset, "matches only the empty language"));
        testing.expectEqual(@as(usize, 3), sub.next().?.offset);
        testing.expectEqual(@as(usize, 6), sub.next().?.offset);
        testing.expectEqual(@as(usize, 9), sub.next().?.offset);
        testing.expect(sub.next() == null); // stream closed
    }
}
