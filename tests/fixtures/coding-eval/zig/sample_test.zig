const std = @import("std");
const sample = @import("sample.zig");

test "divide" {
    try std.testing.expectEqual(@as(u32, 3), try sample.divide(5, 2));
    try std.testing.expectError(error.DivisionByZero, sample.divide(1, 0));
}

test "label" {
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings("entry:alpha", try sample.label("alpha", &output));
}

test "normalize" {
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "alpha beta",
        try sample.normalizeName("  Alpha   BETA ", &output),
    );
}

test "active" {
    try std.testing.expect(sample.active(.{ .state = "active" }));
    try std.testing.expect(!sample.active(.{ .state = "paused" }));
}
