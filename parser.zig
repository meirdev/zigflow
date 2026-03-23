const std = @import("std");
const ie_registry = @import("ie_registry.zig");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const DataType = ie_registry.DataType;

/// IPFIX version number.
const ipfix_version = 10;

/// Set IDs for templates and options templates.
const template_set_id = 2;
const options_template_set_id = 3;

/// Valid range for data set IDs (1-255 are reserved for templates).
const min_data_set_id = 256;
const max_data_set_id = 65535;

/// Lengths of fixed headers.
const msg_header_len = 16;
const set_header_len = 4;

/// Special marker for variable-length fields.
const variable_length_marker: u16 = 0xffff;

/// Template field definition.
const TemplateField = struct {
    id: u16,
    length: u16,
    pen: ?u32,
};

/// Parsed template definition.
const Template = struct {
    fields: []const TemplateField,
    scope_count: u16,
};

const TemplateMap = std.AutoHashMap(u64, Template);

const ParseError = Reader.Error || Writer.Error || Allocator.Error || error{ UnsupportedLength, InvalidValue };

pub const Parser = struct {
    allocator: Allocator,
    templates: TemplateMap,
    registry: ie_registry.Registry,
    w: *Writer,

    pub fn init(allocator: Allocator, w: *Writer) Allocator.Error!Parser {
        return .{
            .allocator = allocator,
            .templates = TemplateMap.init(allocator),
            .registry = try ie_registry.Registry.init(allocator),
            .w = w,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.registry.deinit();
        self.templates.deinit();
    }

    /// Generate a unique key for a template based on observation domain and template ID.
    fn templateKey(observation_domain_id: u32, template_id: u16) u64 {
        return (@as(u64, observation_domain_id) << 16) | template_id;
    }

    pub fn parseMessage(self: *Parser, data: []const u8) ParseError!void {
        if (data.len < msg_header_len) return;

        var r: Reader = .fixed(data);

        const version = try r.takeInt(u16, .big);
        if (version != ipfix_version) return;

        const length = try r.takeInt(u16, .big);
        if (length < msg_header_len or length > data.len) return;

        const export_time = try r.takeInt(u32, .big);
        const sequence_number = try r.takeInt(u32, .big);
        const observation_domain_id = try r.takeInt(u32, .big);

        try self.w.print("--- IPFIX Message: export_time={d} seq={d} domain={d} length={d}\n", .{
            export_time, sequence_number, observation_domain_id, length,
        });

        // Parse sets
        var offset: usize = msg_header_len;
        while (offset + set_header_len <= length) {
            var set_r: Reader = .fixed(data[offset..length]);

            const set_id = set_r.takeInt(u16, .big) catch break;
            const set_length = set_r.takeInt(u16, .big) catch break;

            if (set_length < set_header_len or offset + set_length > length) break;

            const set_data = data[offset + set_header_len .. offset + set_length];

            switch (set_id) {
                template_set_id => try self.parseTemplateSet(observation_domain_id, set_data),
                options_template_set_id => try self.parseOptionsTemplateSet(observation_domain_id, set_data),
                min_data_set_id...max_data_set_id => try self.parseDataSet(observation_domain_id, set_id, set_data),
                else => {},
            }

            offset += set_length;
        }
    }

    fn parseTemplateSet(
        self: *Parser,
        observation_domain_id: u32,
        data: []const u8,
    ) ParseError!void {
        var r: Reader = .fixed(data);

        while (true) {
            const template_id = r.takeInt(u16, .big) catch break;
            const field_count = r.takeInt(u16, .big) catch break;

            const key = templateKey(observation_domain_id, template_id);

            const fields = try self.allocator.alloc(TemplateField, field_count);

            var valid = true;
            for (0..field_count) |i| {
                const raw_id = r.takeInt(u16, .big) catch {
                    valid = false;
                    break;
                };
                const pen_bit = raw_id & 0x8000 != 0;
                const field_id = raw_id & 0x7fff;
                const field_length = r.takeInt(u16, .big) catch {
                    valid = false;
                    break;
                };

                var pen: ?u32 = null;
                if (pen_bit) {
                    pen = r.takeInt(u32, .big) catch {
                        valid = false;
                        break;
                    };
                }

                fields[i] = .{
                    .id = field_id,
                    .length = field_length,
                    .pen = pen,
                };
            }

            if (!valid) break;

            try self.templates.put(key, .{ .fields = fields, .scope_count = 0 });
            try self.w.print("  Template {d}: {d} fields\n", .{ template_id, field_count });
        }
    }

    fn parseOptionsTemplateSet(
        self: *Parser,
        observation_domain_id: u32,
        data: []const u8,
    ) ParseError!void {
        var r: Reader = .fixed(data);

        while (true) {
            const template_id = r.takeInt(u16, .big) catch break;
            const total_field_count = r.takeInt(u16, .big) catch break;
            const scope_field_count = r.takeInt(u16, .big) catch break;

            const key = templateKey(observation_domain_id, template_id);

            const fields = try self.allocator.alloc(TemplateField, total_field_count);

            var valid = true;
            for (0..total_field_count) |i| {
                const raw_id = r.takeInt(u16, .big) catch {
                    valid = false;
                    break;
                };
                const pen_bit = raw_id & 0x8000 != 0;
                const field_id = raw_id & 0x7fff;
                const field_length = r.takeInt(u16, .big) catch {
                    valid = false;
                    break;
                };

                var pen: ?u32 = null;
                if (pen_bit) {
                    pen = r.takeInt(u32, .big) catch {
                        valid = false;
                        break;
                    };
                }

                fields[i] = .{
                    .id = field_id,
                    .length = field_length,
                    .pen = pen,
                };
            }

            if (!valid) break;

            try self.templates.put(key, .{ .fields = fields, .scope_count = scope_field_count });
            try self.w.print("  Options Template {d}: {d} fields ({d} scope)\n", .{
                template_id, total_field_count, scope_field_count,
            });
        }
    }

    fn parseDataSet(
        self: *Parser,
        observation_domain_id: u32,
        set_id: u16,
        data: []const u8,
    ) ParseError!void {
        const key = templateKey(observation_domain_id, set_id);

        const template = self.templates.get(key) orelse {
            try self.w.print("  Data Set {d}: no template\n", .{set_id});
            return;
        };

        var r: Reader = .fixed(data);
        var record_num: u32 = 0;

        records: while (true) {
            record_num += 1;

            const remaining = r.buffered();
            if (remaining.len < minRecordSize(template.fields)) break;

            try self.w.print("  Record {d} (set {d}):\n", .{ record_num, set_id });

            for (template.fields, 0..) |field, idx| {
                const actual_length: u16 = if (field.length == variable_length_marker) blk: {
                    const first_byte = r.takeInt(u8, .big) catch break :records;
                    if (first_byte < 255) {
                        break :blk first_byte;
                    } else {
                        break :blk r.takeInt(u16, .big) catch break :records;
                    }
                } else field.length;

                const value = r.take(actual_length) catch break :records;

                // Print scope indicator
                if (idx < template.scope_count) {
                    try self.w.print("    [scope] ", .{});
                } else {
                    try self.w.print("    ", .{});
                }

                // Look up and format field
                if (self.registry.lookup(field.id, field.pen)) |info| {
                    try self.w.print("{s} ({d}): ", .{ info.name, field.id });
                    try formatValue(self.w, info.data_type, value);
                } else {
                    if (field.pen) |pen| {
                        try self.w.print("ie{d} (pen={d}): ", .{ field.id, pen });
                    } else {
                        try self.w.print("ie{d}: ", .{field.id});
                    }
                    try formatHex(self.w, value);
                }

                try self.w.print("\n", .{});
            }
        }
    }
};

fn minRecordSize(fields: []const TemplateField) usize {
    var size: usize = 0;
    for (fields) |f| {
        if (f.length == variable_length_marker) {
            size += 1;
        } else {
            size += f.length;
        }
    }
    return size;
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

    // Copied from std.net.Ipv6Address.format

    // Check for IPv4-mapped address (::ffff:x.x.x.x)
    if (std.mem.eql(u8, value[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
        try w.print("::ffff:{d}.{d}.{d}.{d}", .{ value[12], value[13], value[14], value[15] });
        return;
    }

    // Convert 16 bytes to 8 u16 groups
    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        groups[i] = std.mem.readInt(u16, value[i * 2 ..][0..2], .big);
    }

    // Find longest run of consecutive zero groups (must be >= 2)
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

fn formatBoolean(w: *Writer, value: []const u8) (Writer.Error || error{ UnsupportedLength, InvalidValue })!void {
    try w.print("{}", .{try readBoolean(value)});
}

// NTP epoch (1900-01-01) to Unix epoch (1970-01-01) offset in seconds.
const ntp_epoch_offset: u64 = 2208988800;

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

fn formatDateTimeSeconds(w: *Writer, value: []const u8) (Writer.Error || error{UnsupportedLength})!void {
    const secs = try readUnsigned(value);
    try formatDateTime(w, secs, 0, .seconds);
}

fn formatDateTimeMilliseconds(w: *Writer, value: []const u8) (Writer.Error || error{UnsupportedLength})!void {
    const millis = try readUnsigned(value);
    try formatDateTime(w, millis / 1000, millis % 1000, .millis);
}

fn formatDateTimeMicroseconds(w: *Writer, value: []const u8) (Writer.Error || error{UnsupportedLength})!void {
    if (value.len != 8) return error.UnsupportedLength;
    const ntp_secs = try readUnsigned(value[0..4]);
    const frac = try readUnsigned(value[4..8]);
    const epoch_secs = ntp_secs - ntp_epoch_offset;
    const micros = frac * 1_000_000 / 0x100000000;
    try formatDateTime(w, epoch_secs, micros, .micros);
}

fn formatDateTimeNanoseconds(w: *Writer, value: []const u8) (Writer.Error || error{UnsupportedLength})!void {
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

fn formatValue(w: *Writer, data_type: DataType, value: []const u8) (Writer.Error || error{ UnsupportedLength, InvalidValue })!void {
    switch (data_type) {
        .unsigned => try w.print("{d}", .{try readUnsigned(value)}),
        .signed => try w.print("{d}", .{try readSigned(value)}),
        .float => try w.print("{d}", .{try readFloat(value)}),
        .boolean => try formatBoolean(w, value),
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
