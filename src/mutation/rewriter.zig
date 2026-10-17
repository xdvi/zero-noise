const std = @import("std");
const common = @import("rewrite_common.zig");
const ternaries = @import("rewrite_ternaries.zig");
const double_neg = @import("rewrite_double_negation.zig");
const de_morgan = @import("rewrite_de_morgan.zig");

pub const RewriteResult = common.RewriteResult;

pub fn simplify(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const res = try rewrite(allocator, source);
    return res.output;
}

pub fn rewrite(allocator: std.mem.Allocator, source: []const u8) !RewriteResult {
    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);

    var total_changes: usize = 0;
    var pass: usize = 0;
    var seen_hashes: [10][32]u8 = undefined;
    var seen_count: usize = 0;

    while (pass < 10) : (pass += 1) {
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        sha.update(current);
        var cur_hash: [32]u8 = undefined;
        sha.final(&cur_hash);

        var already_seen = false;
        for (seen_hashes[0..seen_count]) |h| {
            if (std.mem.eql(u8, &h, &cur_hash)) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) break;
        seen_hashes[seen_count] = cur_hash;
        seen_count += 1;

        var changed_in_pass = false;

        const ternary_res = try ternaries.rewriteTernaries(allocator, current);
        if (ternary_res.changes_count > 0) {
            allocator.free(current);
            current = ternary_res.output;
            total_changes += ternary_res.changes_count;
            changed_in_pass = true;
        } else {
            allocator.free(ternary_res.output);
        }

        const de_morgan_res = try de_morgan.rewriteDeMorgan(allocator, current);
        if (de_morgan_res.changes_count > 0) {
            allocator.free(current);
            current = de_morgan_res.output;
            total_changes += de_morgan_res.changes_count;
            changed_in_pass = true;
        } else {
            allocator.free(de_morgan_res.output);
        }

        const double_neg_res = try double_neg.rewriteDoubleNegation(allocator, current);
        if (double_neg_res.changes_count > 0) {
            allocator.free(current);
            current = double_neg_res.output;
            total_changes += double_neg_res.changes_count;
            changed_in_pass = true;
        } else {
            allocator.free(double_neg_res.output);
        }

        if (!changed_in_pass) break;
    }

    return RewriteResult{
        .output = current,
        .changes_count = total_changes,
    };
}

// Re-exports for backward compatibility
pub const rewriteTernaries = ternaries.rewriteTernaries;
pub const rewriteDoubleNegation = double_neg.rewriteDoubleNegation;
pub const rewriteDeMorgan = de_morgan.rewriteDeMorgan;
pub const skipTriviaOrLiteral = common.skipTriviaOrLiteral;
pub const findMatchingParen = common.findMatchingParen;
pub const findConditionStart = common.findConditionStart;
pub const findConditionEnd = common.findConditionEnd;
pub const invertCondition = common.invertCondition;
pub const isIdentChar = common.isIdentChar;
pub const skipWhitespace = common.skipWhitespace;
pub const matchKeyword = common.matchKeyword;
pub const isAlreadyBoolean = common.isAlreadyBoolean;
pub const parseDeMorganInner = common.parseDeMorganInner;
pub const shouldWrapDeMorgan = common.shouldWrapDeMorgan;
pub const isOperatorChar = common.isOperatorChar;

test "redundant ternary simplification - true/false" {
    const allocator = std.testing.allocator;
    const input = "return x === \"admin\" ? true : false;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("return x === \"admin\";", res);
}

test "redundant ternary simplification - single identifier" {
    const allocator = std.testing.allocator;
    const input = "const valid = isReady ? true : false;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const valid = isReady;", res);
}

test "inverted ternary simplification" {
    const allocator = std.testing.allocator;
    const input1 = "return isValid ? false : true;";
    const res1 = try simplify(allocator, input1);
    defer allocator.free(res1);
    try std.testing.expectEqualStrings("return !isValid;", res1);

    const input2 = "return !isReady ? false : true;";
    const res2 = try simplify(allocator, input2);
    defer allocator.free(res2);
    try std.testing.expectEqualStrings("return isReady;", res2);

    const input3 = "return x > 0 ? false : true;";
    const res3 = try simplify(allocator, input3);
    defer allocator.free(res3);
    try std.testing.expectEqualStrings("return !(x > 0);", res3);
}

test "double negation simplification" {
    const allocator = std.testing.allocator;
    const input1 = "const a = !!x;";
    const res1 = try simplify(allocator, input1);
    defer allocator.free(res1);
    try std.testing.expectEqualStrings("const a = x;", res1);

    const input2 = "return !(!isValid);";
    const res2 = try simplify(allocator, input2);
    defer allocator.free(res2);
    try std.testing.expectEqualStrings("return isValid;", res2);
}

test "de morgan law simplification" {
    const allocator = std.testing.allocator;
    const input1 = "return !(!a || !b);";
    const res1 = try simplify(allocator, input1);
    defer allocator.free(res1);
    try std.testing.expectEqualStrings("return a && b;", res1);

    const input2 = "return !(!a && !b);";
    const res2 = try simplify(allocator, input2);
    defer allocator.free(res2);
    try std.testing.expectEqualStrings("return a || b;", res2);

    const input3 = "return !(!foo.bar || !baz.qux);";
    const res3 = try simplify(allocator, input3);
    defer allocator.free(res3);
    try std.testing.expectEqualStrings("return foo.bar && baz.qux;", res3);
}

test "skips string literals and comments" {
    const allocator = std.testing.allocator;
    const input = "const msg = \"x ? true : false\"; // !(!a || !b)\nconst y = !!z;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const msg = \"x ? true : false\"; // !(!a || !b)\nconst y = z;", res);
}

test "multi-pass combined simplification" {
    const allocator = std.testing.allocator;
    const input = "const res = !(!a || !b) ? true : false;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const res = (a && b);", res);
}

test "de morgan with outer comparison operator wrapping" {
    const allocator = std.testing.allocator;
    const input = "const ok = x == !(!a || !b);";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const ok = x == (a && b);", res);
}

test "findConditionStart stops at arrow" {
    const src = "const fn = x => cond ? true : false;";
    const q_idx = std.mem.indexOf(u8, src, "?").?;
    const start = findConditionStart(src, q_idx);
    const cond = std.mem.trim(u8, src[start..q_idx], " \t\r\n");
    try std.testing.expectEqualStrings("cond", cond);
}

test "arrow function ternary condition does not capture arrow" {
    const allocator = std.testing.allocator;
    const input = "const fn = x => cond ? false : true;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const fn = x => !cond;", res);
}

test "python comment in de morgan and double negation not corrupted" {
    const allocator = std.testing.allocator;
    const input = "# !(!a || !b)\nconst x = !!y;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("# !(!a || !b)\nconst x = y;", res);
}

test "raw strings in de morgan and double negation not corrupted" {
    const allocator = std.testing.allocator;
    const input = "const s = r#\"odd \" quote !(!a || !b) and !!x\"#;";
    const res = try simplify(allocator, input);
    defer allocator.free(res);
    try std.testing.expectEqualStrings("const s = r#\"odd \" quote !(!a || !b) and !!x\"#;", res);
}

test "string literals containing paren in ternary and negation" {
    const allocator = std.testing.allocator;
    const input1 = "const res = fn(\")\") ? false : true;";
    const res1 = try simplify(allocator, input1);
    defer allocator.free(res1);
    try std.testing.expectEqualStrings("const res = !fn(\")\");", res1);

    const input2 = "return !(!fn(\")\"));";
    const res2 = try simplify(allocator, input2);
    defer allocator.free(res2);
    try std.testing.expectEqualStrings("return fn(\")\");", res2);

    const input3 = "const x = !(!fn(\")\") || !b);";
    const res3 = try simplify(allocator, input3);
    defer allocator.free(res3);
    try std.testing.expectEqualStrings("const x = (fn(\")\") && b);", res3);
}

test "rewriteTernaries does not emit Boolean in C# or if already boolean" {
    const allocator = std.testing.allocator;

    const js_bool = "return x === \"admin\" ? true : false;";
    const res_js_bool = try simplify(allocator, js_bool);
    defer allocator.free(res_js_bool);
    try std.testing.expectEqualStrings("return x === \"admin\";", res_js_bool);

    const cs_input = "public class C { bool Check(User user) { return user.enabled ? true : false; } }";
    const res_cs = try simplify(allocator, cs_input);
    defer allocator.free(res_cs);
    try std.testing.expectEqualStrings("public class C { bool Check(User user) { return user.enabled; } }", res_cs);
}
