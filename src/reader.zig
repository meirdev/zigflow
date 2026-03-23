const std = @import("std");

pub fn readUnsigned(value: []const u8) error{UnsupportedLength}!u64 {
    return switch (value.len) {
        1 => value[0],
        2 => std.mem.readInt(u16, value[0..2], .big),
        4 => std.mem.readInt(u32, value[0..4], .big),
        8 => std.mem.readInt(u64, value[0..8], .big),
        else => error.UnsupportedLength,
    };
}

pub fn readSigned(value: []const u8) error{UnsupportedLength}!i64 {
    return switch (value.len) {
        1 => @as(i8, @bitCast(value[0])),
        2 => std.mem.readInt(i16, value[0..2], .big),
        4 => std.mem.readInt(i32, value[0..4], .big),
        8 => std.mem.readInt(i64, value[0..8], .big),
        else => error.UnsupportedLength,
    };
}

pub fn readFloat(value: []const u8) error{UnsupportedLength}!f64 {
    return switch (value.len) {
        4 => @as(f32, @bitCast(std.mem.readInt(u32, value[0..4], .big))),
        8 => @as(f64, @bitCast(std.mem.readInt(u64, value[0..8], .big))),
        else => error.UnsupportedLength,
    };
}

// NTP epoch (1900-01-01) to Unix epoch (1970-01-01) offset in seconds.
const ntp_epoch_offset: u64 = 2208988800;

pub const NtpTimestamp = struct {
    epoch_secs: u64,
    frac: u64,
};

pub fn readNtpTimestamp(value: []const u8) error{UnsupportedLength}!NtpTimestamp {
    if (value.len != 8) return error.UnsupportedLength;
    const ntp_secs = try readUnsigned(value[0..4]);
    const frac = try readUnsigned(value[4..8]);
    return .{
        .epoch_secs = ntp_secs -| ntp_epoch_offset,
        .frac = frac,
    };
}

pub fn readBoolean(value: []const u8) error{ UnsupportedLength, InvalidValue }!bool {
    if (value.len != 1) return error.UnsupportedLength;
    return switch (value[0]) {
        1 => true,
        2 => false,
        else => error.InvalidValue,
    };
}
