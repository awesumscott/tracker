// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! ULID — Universally Unique Lexicographically Sortable Identifier.
//!
//! 128 bits = 48-bit big-endian millisecond timestamp + 80 bits of randomness,
//! Crockford-base32 encoded to a fixed 26-char string. Time-sortable (the
//! timestamp is the high bits, encoded MSB-first) and collision-safe across
//! independent writers (80 random bits). We mint a Ulid once at task creation
//! and never regenerate it — the merge ruling (issue-tracker.md) needs ids that
//! are unique-at-birth so two worktrees never collide.
//!
//! NOTE (Zig 0.16): `std.time.milliTimestamp` and `std.crypto.random` were
//! removed; time + randomness are now `Io` services. `mint` therefore takes an
//! `Io` and reads the wall clock via `Io.Timestamp.now(io, .real)` and
//! randomness via `io.random`.

const std = @import("std");
const Io = std.Io;

/// Crockford base32 alphabet (no I, L, O, U — they look like 1/1/0/V).
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Reverse map: base32 char -> 5-bit value, or 0xFF for an invalid char.
const decode_table = blk: {
    var t = [_]u8{0xFF} ** 256;
    for (crockford, 0..) |c, i| {
        t[c] = @intCast(i);
        // Crockford decoding is case-insensitive.
        if (c >= 'A' and c <= 'Z') t[c - 'A' + 'a'] = @intCast(i);
    }
    // Crockford aliases: I/L -> 1, O -> 0 (defensive on the read path only).
    t['i'] = t['1'];
    t['I'] = t['1'];
    t['l'] = t['1'];
    t['L'] = t['1'];
    t['o'] = t['0'];
    t['O'] = t['0'];
    break :blk t;
};

pub const len = 26;

pub const ParseError = error{
    BadLength,
    BadChar,
    /// First char encodes only the top 3 bits of a 130-bit field; a value > 7
    /// would overflow 128 bits. Crockford ULIDs cap the first char at '7'.
    Overflow,
};

/// A 26-char Crockford-base32 ULID. Stored as the encoded text (fixed size,
/// trivially comparable, hashable, and JSON-friendly without a conversion).
pub const Ulid = struct {
    text: [len]u8,

    pub fn eql(a: Ulid, b: Ulid) bool {
        return std.mem.eql(u8, &a.text, &b.text);
    }

    /// Lexicographic compare == chronological-then-random compare (the whole
    /// point of the format). Returns std.math.Order.
    pub fn order(a: Ulid, b: Ulid) std.math.Order {
        return std.mem.order(u8, &a.text, &b.text);
    }

    pub fn lessThan(_: void, a: Ulid, b: Ulid) bool {
        return a.order(b) == .lt;
    }

    pub fn slice(self: *const Ulid) []const u8 {
        return &self.text;
    }
};

/// Build the 128-bit value: 48-bit ms timestamp (high) | 80 random bits (low).
fn assemble(ms: u48, rand: [10]u8) u128 {
    // Build the 80-bit random tail in the LOW bits first, then OR the timestamp
    // into the high 48 bits. (Folding the bytes into an already-shifted `ms`
    // would shift the timestamp off the top of the u128 — losing it entirely,
    // which silently destroys the time-sortable property.)
    var r: u128 = 0;
    for (rand) |b| r = (r << 8) | b;
    return (@as(u128, ms) << 80) | r;
}

/// Encode a 128-bit value to 26 Crockford chars, MSB-first.
fn encode128(v: u128) Ulid {
    var out: [len]u8 = undefined;
    var x = v;
    // Emit least-significant char first, then reverse — 26 chars cover 130 bits.
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        out[i] = crockford[@intCast(x & 0x1f)];
        x >>= 5;
    }
    return .{ .text = out };
}

/// Mint a fresh ULID: timestamp from the real clock, 80 random bits from `io`.
pub fn mint(io: Io) Ulid {
    const ms_signed = Io.Timestamp.now(io, .real).toMilliseconds();
    const ms: u48 = @intCast(@as(i64, @max(0, ms_signed)) & 0xFFFF_FFFF_FFFF);
    var rand: [10]u8 = undefined;
    io.random(&rand);
    return encode128(assemble(ms, rand));
}

/// Mint with an explicit timestamp (testing: assert time-ordering deterministically).
pub fn mintAt(io: Io, ms: u48) Ulid {
    var rand: [10]u8 = undefined;
    io.random(&rand);
    return encode128(assemble(ms, rand));
}

/// Parse a 26-char ULID string. Validates length, charset, and the 128-bit cap.
pub fn parse(s: []const u8) ParseError!Ulid {
    if (s.len != len) return error.BadLength;
    // Decode to verify it's well-formed + within 128 bits, then re-canonicalize
    // (upper-case, alias-normalized) so two spellings of the same id compare equal.
    var v: u128 = 0;
    for (s, 0..) |c, i| {
        const d = decode_table[c];
        if (d == 0xFF) return error.BadChar;
        if (i == 0 and d > 7) return error.Overflow; // top char holds only 3 usable bits
        v = (v << 5) | d;
    }
    return encode128(v);
}

// ----- tests -----

const testing = std.testing;

test "encode/parse round-trip" {
    const u = mintAt(testing.io, 0x0123_4567_89AB);
    const back = try parse(&u.text);
    try testing.expect(u.eql(back));
}

test "two mints are distinct and time-ordered" {
    const a = mintAt(testing.io, 1000);
    const b = mintAt(testing.io, 2000);
    try testing.expect(!a.eql(b));
    // Later timestamp -> lexicographically greater.
    try testing.expect(a.order(b) == .lt);
}

test "same-ms mints differ in the random tail" {
    const a = mintAt(testing.io, 5000);
    const b = mintAt(testing.io, 5000);
    // Astronomically unlikely to collide on 80 random bits.
    try testing.expect(!a.eql(b));
}

test "parse rejects bad length and bad char" {
    try testing.expectError(error.BadLength, parse("TOOSHORT"));
    var s = [_]u8{'0'} ** len;
    s[3] = 'U'; // U is not in the Crockford alphabet
    try testing.expectError(error.BadChar, parse(&s));
}

test "parse is case-insensitive and canonicalizes" {
    const u = mintAt(testing.io, 12345);
    var lower: [len]u8 = u.text;
    for (&lower) |*c| c.* = std.ascii.toLower(c.*);
    const back = try parse(&lower);
    try testing.expect(u.eql(back)); // re-canonicalized to upper
}
