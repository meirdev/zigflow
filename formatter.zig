const std = @import("std");
const ie_registry = @import("ie_registry.zig");

const Writer = std.Io.Writer;
const DataType = ie_registry.DataType;

pub const OutputFormat = enum {
    raw,
    json,
};

pub const Formatter = struct {
    pub const Error = Writer.Error || error{ UnsupportedLength, InvalidValue };

    w: *Writer,
    format: OutputFormat,
    first_set: bool = true,
    first_record: bool = true,
    first_field: bool = true,

    pub fn init(w: *Writer, format: OutputFormat) Formatter {
        return .{ .w = w, .format = format };
    }

    // --- Message level ---

    pub fn messageBegin(self: *Formatter, export_time: u32, sequence_number: u32, observation_domain_id: u32, length: u16) Error!void {
        switch (self.format) {
            .raw => try self.w.print("IPFIX Message Header:\n\tLength: {d}\n\tExport time: {d}\n\tSequence number: {d}\n\tObservation domain ID: {d}\n", .{
                length, export_time, sequence_number, observation_domain_id,
            }),
            .json => try self.w.print("{{\"version\":{d},\"observationDomainId\":{d},\"exportTime\":{d},\"sequenceNumber\":{d},\"sets\":[", .{
                @as(u16, 10), observation_domain_id, export_time, sequence_number,
            }),
        }
        self.first_set = true;
    }

    pub fn messageEnd(self: *Formatter) Error!void {
        switch (self.format) {
            .raw => {},
            .json => try self.w.writeAll("]}\n"),
        }
    }

    pub fn setHeader(self: *Formatter, set_id: u16, set_length: u16) Error!void {
        switch (self.format) {
            .raw => try self.w.print("Set Header:\n\tLength: {d}\n\tSet ID: {d}\n", .{ set_length, set_id }),
            .json => {},
        }
    }

    pub fn templateRecordBegin(self: *Formatter, record_num: u32, template_id: u16, field_count: u16) Error!void {
        switch (self.format) {
            .raw => try self.w.print("Template Record {d}:\n\tTemplate ID: {d}\n\tField Count: {d}\n", .{
                record_num, template_id, field_count,
            }),
            .json => {
                if (!self.first_set) try self.w.writeAll(",");
                try self.w.print("{{\"setType\":\"template\",\"templateId\":{d},\"fields\":[", .{template_id});
                self.first_set = false;
                self.first_field = true;
            },
        }
    }

    pub fn templateField(self: *Formatter, pen: ?u32, id: u16, length: u16, name: ?[]const u8, data_type: ?DataType) Error!void {
        switch (self.format) {
            .raw => {
                try self.w.print("\tPEN: {d}, ID: {d}, Length: {d}", .{ pen orelse 0, id, length });
                if (name) |n| {
                    try self.w.print(", Name: {s}", .{n});
                }
                try self.w.writeAll("\n");
            },
            .json => {
                if (!self.first_field) try self.w.writeAll(",");
                try self.w.writeAll("{");
                if (name) |n| {
                    try self.w.print("\"name\":\"{s}\",", .{n});
                }
                if (data_type) |dt| {
                    try self.w.print("\"type\":\"{s}\",", .{dataTypeName(dt)});
                }
                try self.w.print("\"id\":{d},\"length\":{d}", .{ id, length });
                if (pen) |p| {
                    try self.w.print(",\"pen\":{d}", .{p});
                }
                try self.w.writeAll("}");
                self.first_field = false;
            },
        }
    }

    pub fn templateRecordEnd(self: *Formatter) Error!void {
        switch (self.format) {
            .raw => {},
            .json => try self.w.writeAll("]}"),
        }
    }

    pub fn optionsTemplateRecordBegin(self: *Formatter, record_num: u32, template_id: u16, field_count: u16, scope_field_count: u16) Error!void {
        switch (self.format) {
            .raw => try self.w.print("Options Template Record {d}:\n\tTemplate ID: {d}\n\tField Count: {d}\n\tScope Field Count: {d}\n", .{
                record_num, template_id, field_count, scope_field_count,
            }),
            .json => {
                if (!self.first_set) try self.w.writeAll(",");
                try self.w.print("{{\"setType\":\"optionsTemplate\",\"templateId\":{d},\"scopeFieldCount\":{d},\"fields\":[", .{
                    template_id, scope_field_count,
                });
                self.first_set = false;
                self.first_field = true;
            },
        }
    }

    pub fn dataSetBegin(self: *Formatter, set_id: u16) Error!void {
        switch (self.format) {
            .raw => {},
            .json => {
                if (!self.first_set) try self.w.writeAll(",");
                try self.w.print("{{\"setType\":\"data\",\"templateId\":{d},\"records\":[", .{set_id});
                self.first_set = false;
                self.first_record = true;
            },
        }
    }

    pub fn dataSetEnd(self: *Formatter) Error!void {
        switch (self.format) {
            .raw => {},
            .json => try self.w.writeAll("]}"),
        }
    }

    pub fn unknownDataSet(self: *Formatter, set_id: u16) Error!void {
        switch (self.format) {
            .raw => try self.w.print("Data Set {d}: no template\n", .{set_id}),
            .json => {},
        }
    }

    pub fn recordBegin(self: *Formatter, record_num: u32) Error!void {
        switch (self.format) {
            .raw => try self.w.print("Data Record {d}:\n", .{record_num}),
            .json => {
                if (!self.first_record) try self.w.writeAll(",");
                try self.w.writeAll("{");
                self.first_record = false;
                self.first_field = true;
            },
        }
    }

    pub fn recordEnd(self: *Formatter) Error!void {
        switch (self.format) {
            .raw => {},
            .json => try self.w.writeAll("}"),
        }
    }

    pub fn field(self: *Formatter, name: []const u8, id: u16, pen: ?u32, is_scope: bool, data_type: DataType, value: []const u8) Error!void {
        switch (self.format) {
            .raw => {
                if (is_scope) {
                    try self.w.print("\t[scope] ", .{});
                } else {
                    try self.w.print("\t", .{});
                }
                try self.w.print("{s} ({d}): ", .{ name, id });
                try formatValue(self.w, data_type, value);
                try self.w.writeAll("\n");
            },
            .json => {
                _ = pen;
                if (!self.first_field) try self.w.writeAll(",");
                try self.w.print("\"{s}\":", .{name});
                if (needsQuoting(data_type)) {
                    try self.w.writeAll("\"");
                    try formatValue(self.w, data_type, value);
                    try self.w.writeAll("\"");
                } else {
                    try formatValue(self.w, data_type, value);
                }
                self.first_field = false;
            },
        }
    }

    pub fn unknownField(self: *Formatter, id: u16, pen: ?u32, is_scope: bool, value: []const u8) Error!void {
        switch (self.format) {
            .raw => {
                if (is_scope) {
                    try self.w.print("\t[scope] ", .{});
                } else {
                    try self.w.print("\t", .{});
                }
                if (pen) |p| {
                    try self.w.print("ie{d} (pen={d}): ", .{ id, p });
                } else {
                    try self.w.print("ie{d}: ", .{id});
                }
                try formatHex(self.w, value);
                try self.w.writeAll("\n");
            },
            .json => {
                if (!self.first_field) try self.w.writeAll(",");
                if (pen) |p| {
                    try self.w.print("\"ie{d}_pen{d}\":\"", .{ id, p });
                } else {
                    try self.w.print("\"ie{d}\":\"", .{id});
                }
                try formatHex(self.w, value);
                try self.w.writeAll("\"");
                self.first_field = false;
            },
        }
    }
};

fn dataTypeName(dt: DataType) []const u8 {
    return switch (dt) {
        .unsigned => "unsigned",
        .signed => "signed",
        .float => "float",
        .boolean => "boolean",
        .ipv4_address => "ipv4Address",
        .ipv6_address => "ipv6Address",
        .mac_address => "macAddress",
        .string => "string",
        .octet_array => "octetArray",
        .date_time_seconds => "dateTimeSeconds",
        .date_time_milliseconds => "dateTimeMilliseconds",
        .date_time_microseconds => "dateTimeMicroseconds",
        .date_time_nanoseconds => "dateTimeNanoseconds",
        .basic_list => "basicList",
        .sub_template_list => "subTemplateList",
        .sub_template_multi_list => "subTemplateMultiList",
    };
}

fn needsQuoting(data_type: DataType) bool {
    return switch (data_type) {
        .unsigned, .signed, .float, .boolean => false,
        else => true,
    };
}

// NTP epoch (1900-01-01) to Unix epoch (1970-01-01) offset in seconds.
const ntp_epoch_offset: u64 = 2208988800;

fn formatValue(w: *Writer, data_type: DataType, value: []const u8) Formatter.Error!void {
    switch (data_type) {
        .unsigned => try w.print("{d}", .{try readUnsigned(value)}),
        .signed => try w.print("{d}", .{try readSigned(value)}),
        .float => try w.print("{d}", .{try readFloat(value)}),
        .boolean => try w.print("{}", .{try readBoolean(value)}),
        .ipv4_address => try formatIpv4Address(w, value),
        .ipv6_address => try formatIpv6Address(w, value),
        .mac_address => try formatMacAddress(w, value),
        .string => try w.print("{s}", .{value}),
        .octet_array, .basic_list, .sub_template_list, .sub_template_multi_list => try formatHex(w, value),
        .date_time_seconds => try formatDateTimeSeconds(w, value),
        .date_time_milliseconds => try formatDateTimeMilliseconds(w, value),
        .date_time_microseconds => try formatDateTimeMicroseconds(w, value),
        .date_time_nanoseconds => try formatDateTimeNanoseconds(w, value),
    }
}

fn readFloat(value: []const u8) error{UnsupportedLength}!f64 {
    return switch (value.len) {
        4 => @as(f32, @bitCast(std.mem.readInt(u32, value[0..4], .big))),
        8 => @as(f64, @bitCast(std.mem.readInt(u64, value[0..8], .big))),
        else => error.UnsupportedLength,
    };
}

fn readUnsigned(value: []const u8) error{UnsupportedLength}!u64 {
    return switch (value.len) {
        1 => value[0],
        2 => std.mem.readInt(u16, value[0..2], .big),
        4 => std.mem.readInt(u32, value[0..4], .big),
        8 => std.mem.readInt(u64, value[0..8], .big),
        else => error.UnsupportedLength,
    };
}

fn readSigned(value: []const u8) error{UnsupportedLength}!i64 {
    return switch (value.len) {
        1 => @as(i8, @bitCast(value[0])),
        2 => std.mem.readInt(i16, value[0..2], .big),
        4 => std.mem.readInt(i32, value[0..4], .big),
        8 => std.mem.readInt(i64, value[0..8], .big),
        else => error.UnsupportedLength,
    };
}

fn readBoolean(value: []const u8) error{ UnsupportedLength, InvalidValue }!bool {
    if (value.len != 1) return error.UnsupportedLength;
    return switch (value[0]) {
        1 => true,
        2 => false,
        else => error.InvalidValue,
    };
}

fn formatIpv4Address(w: *Writer, value: []const u8) Writer.Error!void {
    if (value.len == 4) {
        try w.print("{d}.{d}.{d}.{d}", .{ value[0], value[1], value[2], value[3] });
    } else try formatHex(w, value);
}

fn formatIpv6Address(w: *Writer, value: []const u8) Writer.Error!void {
    if (value.len != 16) return formatHex(w, value);

    if (std.mem.eql(u8, value[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
        try w.print("::ffff:{d}.{d}.{d}.{d}", .{ value[12], value[13], value[14], value[15] });
        return;
    }

    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        groups[i] = std.mem.readInt(u16, value[i * 2 ..][0..2], .big);
    }

    var longest_start: usize = 8;
    var longest_len: usize = 0;
    var current_start: usize = 0;
    var current_len: usize = 0;

    for (groups, 0..) |g, i| {
        if (g == 0) {
            if (current_len == 0) current_start = i;
            current_len += 1;
            if (current_len > longest_len) {
                longest_start = current_start;
                longest_len = current_len;
            }
        } else {
            current_len = 0;
        }
    }

    if (longest_len < 2) {
        longest_start = 8;
        longest_len = 0;
    }

    var i: usize = 0;
    var need_colon = false;
    while (i < 8) : (i += 1) {
        if (i == longest_start) {
            try w.writeAll(if (i == 0) "::" else ":");
            i += longest_len - 1;
            need_colon = false;
            continue;
        }
        if (need_colon) try w.writeAll(":");
        try w.print("{x}", .{groups[i]});
        need_colon = true;
    }
}

fn formatMacAddress(w: *Writer, value: []const u8) Writer.Error!void {
    if (value.len == 6) {
        try w.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            value[0], value[1], value[2], value[3], value[4], value[5],
        });
    } else try formatHex(w, value);
}

fn formatDateTime(w: *Writer, epoch_secs: u64, sub_secs: u64, comptime precision: enum { seconds, millis, micros, nanos }) Writer.Error!void {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        @intFromEnum(md.month),
        @as(u16, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });

    switch (precision) {
        .seconds => {},
        .millis => try w.print(".{d:0>3}", .{sub_secs}),
        .micros => try w.print(".{d:0>6}", .{sub_secs}),
        .nanos => try w.print(".{d:0>9}", .{sub_secs}),
    }
}

fn formatDateTimeSeconds(w: *Writer, value: []const u8) Formatter.Error!void {
    const secs = try readUnsigned(value);
    try formatDateTime(w, secs, 0, .seconds);
}

fn formatDateTimeMilliseconds(w: *Writer, value: []const u8) Formatter.Error!void {
    const millis = try readUnsigned(value);
    try formatDateTime(w, millis / 1000, millis % 1000, .millis);
}

fn formatDateTimeMicroseconds(w: *Writer, value: []const u8) Formatter.Error!void {
    if (value.len != 8) return error.UnsupportedLength;
    const ntp_secs = try readUnsigned(value[0..4]);
    const frac = try readUnsigned(value[4..8]);
    const epoch_secs = ntp_secs - ntp_epoch_offset;
    const micros = frac * 1_000_000 / 0x100000000;
    try formatDateTime(w, epoch_secs, micros, .micros);
}

fn formatDateTimeNanoseconds(w: *Writer, value: []const u8) Formatter.Error!void {
    if (value.len != 8) return error.UnsupportedLength;
    const ntp_secs = try readUnsigned(value[0..4]);
    const frac = try readUnsigned(value[4..8]);
    const epoch_secs = ntp_secs - ntp_epoch_offset;
    const nanos = frac * 1_000_000_000 / 0x100000000;
    try formatDateTime(w, epoch_secs, nanos, .nanos);
}

fn formatHex(w: *Writer, value: []const u8) Writer.Error!void {
    for (value) |b| {
        try w.print("{x:0>2}", .{b});
    }
}
