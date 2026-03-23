const std = @import("std");
const ie_registry = @import("ie_registry.zig");
const rd = @import("reader.zig");

const Writer = std.Io.Writer;
pub const DataType = ie_registry.DataType;

pub const Error = Writer.Error || error{ UnsupportedLength, InvalidValue };

/// Formatter interface. Implementations embed this struct and use @fieldParentPtr to recover self.
pub const Formatter = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        messageBegin: *const fn (self: *Formatter, export_time: u32, sequence_number: u32, observation_domain_id: u32, length: u16) Error!void,
        messageEnd: *const fn (self: *Formatter) Error!void,
        setHeader: *const fn (self: *Formatter, set_id: u16, set_length: u16) Error!void,
        templateRecordBegin: *const fn (self: *Formatter, record_num: u32, template_id: u16, field_count: u16) Error!void,
        templateField: *const fn (self: *Formatter, pen: ?u32, id: u16, length: u16, name: ?[]const u8, data_type: ?DataType) Error!void,
        templateRecordEnd: *const fn (self: *Formatter) Error!void,
        optionsTemplateRecordBegin: *const fn (self: *Formatter, record_num: u32, template_id: u16, field_count: u16, scope_field_count: u16) Error!void,
        dataSetBegin: *const fn (self: *Formatter, set_id: u16, is_options: bool) Error!void,
        dataSetEnd: *const fn (self: *Formatter) Error!void,
        unknownDataSet: *const fn (self: *Formatter, set_id: u16) Error!void,
        recordBegin: *const fn (self: *Formatter, record_num: u32, sequence_num: u32, observation_domain_id: u32, template_id: u16, sampler_address: ?[16]u8) Error!void,
        recordEnd: *const fn (self: *Formatter, sampling_rate: ?u32) Error!void,
        field: *const fn (self: *Formatter, name: []const u8, id: u16, pen: ?u32, is_scope: bool, data_type: DataType, value: []const u8) Error!void,
        unknownField: *const fn (self: *Formatter, id: u16, pen: ?u32, is_scope: bool, value: []const u8) Error!void,
    };

    pub fn messageBegin(self: *Formatter, export_time: u32, sequence_number: u32, observation_domain_id: u32, length: u16) Error!void {
        return self.vtable.messageBegin(self, export_time, sequence_number, observation_domain_id, length);
    }

    pub fn messageEnd(self: *Formatter) Error!void {
        return self.vtable.messageEnd(self);
    }

    pub fn setHeader(self: *Formatter, set_id: u16, set_length: u16) Error!void {
        return self.vtable.setHeader(self, set_id, set_length);
    }

    pub fn templateRecordBegin(self: *Formatter, record_num: u32, template_id: u16, field_count: u16) Error!void {
        return self.vtable.templateRecordBegin(self, record_num, template_id, field_count);
    }

    pub fn templateField(self: *Formatter, pen: ?u32, id: u16, length: u16, name: ?[]const u8, data_type: ?DataType) Error!void {
        return self.vtable.templateField(self, pen, id, length, name, data_type);
    }

    pub fn templateRecordEnd(self: *Formatter) Error!void {
        return self.vtable.templateRecordEnd(self);
    }

    pub fn optionsTemplateRecordBegin(self: *Formatter, record_num: u32, template_id: u16, field_count: u16, scope_field_count: u16) Error!void {
        return self.vtable.optionsTemplateRecordBegin(self, record_num, template_id, field_count, scope_field_count);
    }

    pub fn dataSetBegin(self: *Formatter, set_id: u16, is_options: bool) Error!void {
        return self.vtable.dataSetBegin(self, set_id, is_options);
    }

    pub fn dataSetEnd(self: *Formatter) Error!void {
        return self.vtable.dataSetEnd(self);
    }

    pub fn unknownDataSet(self: *Formatter, set_id: u16) Error!void {
        return self.vtable.unknownDataSet(self, set_id);
    }

    pub fn recordBegin(self: *Formatter, record_num: u32, sequence_num: u32, observation_domain_id: u32, template_id: u16, sampler_address: ?[16]u8) Error!void {
        return self.vtable.recordBegin(self, record_num, sequence_num, observation_domain_id, template_id, sampler_address);
    }

    pub fn recordEnd(self: *Formatter, sampling_rate: ?u32) Error!void {
        return self.vtable.recordEnd(self, sampling_rate);
    }

    pub fn field(self: *Formatter, name: []const u8, id: u16, pen: ?u32, is_scope: bool, data_type: DataType, value: []const u8) Error!void {
        return self.vtable.field(self, name, id, pen, is_scope, data_type, value);
    }

    pub fn unknownField(self: *Formatter, id: u16, pen: ?u32, is_scope: bool, value: []const u8) Error!void {
        return self.vtable.unknownField(self, id, pen, is_scope, value);
    }
};

pub fn formatValue(w: *Writer, data_type: DataType, value: []const u8) Error!void {
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

const readFloat = rd.readFloat;
const readUnsigned = rd.readUnsigned;
const readSigned = rd.readSigned;
const readBoolean = rd.readBoolean;

pub fn formatIpv4Address(w: *Writer, value: []const u8) Writer.Error!void {
    if (value.len == 4) {
        try w.print("{d}.{d}.{d}.{d}", .{ value[0], value[1], value[2], value[3] });
    } else try formatHex(w, value);
}

pub fn formatIpv6Address(w: *Writer, value: []const u8) Writer.Error!void {
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

pub fn formatMacAddress(w: *Writer, value: []const u8) Writer.Error!void {
    if (value.len == 6) {
        try w.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            value[0], value[1], value[2], value[3], value[4], value[5],
        });
    } else try formatHex(w, value);
}

pub fn formatDateTime(w: *Writer, epoch_secs: u64, sub_secs: u64, comptime precision: enum { seconds, millis, micros, nanos }) Writer.Error!void {
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

pub fn dataTypeName(dt: DataType) []const u8 {
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

pub fn needsQuoting(data_type: DataType) bool {
    return switch (data_type) {
        .unsigned, .signed, .float, .boolean => false,
        else => true,
    };
}

fn formatDateTimeSeconds(w: *Writer, value: []const u8) Error!void {
    const secs = try readUnsigned(value);
    try formatDateTime(w, secs, 0, .seconds);
}

fn formatDateTimeMilliseconds(w: *Writer, value: []const u8) Error!void {
    const millis = try readUnsigned(value);
    try formatDateTime(w, millis / 1000, millis % 1000, .millis);
}

fn formatDateTimeMicroseconds(w: *Writer, value: []const u8) Error!void {
    const ntp = try rd.readNtpTimestamp(value);
    const micros = ntp.frac * 1_000_000 / 0x100000000;
    try formatDateTime(w, ntp.epoch_secs, micros, .micros);
}

fn formatDateTimeNanoseconds(w: *Writer, value: []const u8) Error!void {
    const ntp = try rd.readNtpTimestamp(value);
    const nanos = ntp.frac * 1_000_000_000 / 0x100000000;
    try formatDateTime(w, ntp.epoch_secs, nanos, .nanos);
}

pub fn formatHex(w: *Writer, value: []const u8) Writer.Error!void {
    for (value) |b| {
        try w.print("{x:0>2}", .{b});
    }
}
