const std = @import("std");
const ie_registry = @import("ie_registry.zig");
const fmt = @import("formatter.zig");
const rd = @import("reader.zig");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
pub const Formatter = fmt.Formatter;

const SamplingRateMap = std.AutoHashMap(u32, u32);

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

const ParseError = Reader.Error || fmt.Error || Allocator.Error;

pub const Parser = struct {
    allocator: Allocator,
    templates: TemplateMap,
    registry: ie_registry.Registry,
    formatter: *Formatter,
    sampling_rates: SamplingRateMap,

    pub fn init(allocator: Allocator, formatter: *Formatter) Allocator.Error!Parser {
        return .{
            .allocator = allocator,
            .templates = TemplateMap.init(allocator),
            .registry = try ie_registry.Registry.init(allocator),
            .formatter = formatter,
            .sampling_rates = SamplingRateMap.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        var it = self.templates.valueIterator();
        while (it.next()) |tmpl| {
            self.allocator.free(tmpl.fields);
        }

        self.templates.deinit();
        self.sampling_rates.deinit();
        self.registry.deinit();
    }

    fn templateKey(observation_domain_id: u32, template_id: u16) u64 {
        return (@as(u64, observation_domain_id) << 16) | template_id;
    }

    pub fn parseMessage(self: *Parser, data: []const u8, sampler_address: ?[16]u8) ParseError!void {
        if (data.len < msg_header_len) return;

        var r: Reader = .fixed(data);

        const version = try r.takeInt(u16, .big);
        if (version != ipfix_version) return;

        const length = try r.takeInt(u16, .big);
        if (length < msg_header_len or length > data.len) return;

        const export_time = try r.takeInt(u32, .big);
        const sequence_number = try r.takeInt(u32, .big);
        const observation_domain_id = try r.takeInt(u32, .big);

        try self.formatter.messageBegin(export_time, sequence_number, observation_domain_id, length);

        var offset: usize = msg_header_len;
        while (offset + set_header_len <= length) {
            var set_r: Reader = .fixed(data[offset..length]);

            const set_id = set_r.takeInt(u16, .big) catch break;
            const set_length = set_r.takeInt(u16, .big) catch break;

            if (set_length < set_header_len or offset + set_length > length) break;

            try self.formatter.setHeader(set_id, set_length);

            const set_data = data[offset + set_header_len .. offset + set_length];

            switch (set_id) {
                template_set_id => try self.parseTemplateSet(observation_domain_id, set_data),
                options_template_set_id => try self.parseOptionsTemplateSet(observation_domain_id, set_data),
                min_data_set_id...max_data_set_id => try self.parseDataSet(sequence_number, observation_domain_id, set_id, set_data, sampler_address),
                else => {},
            }

            offset += set_length;
        }

        try self.formatter.messageEnd();
    }

    fn parseTemplateSet(self: *Parser, observation_domain_id: u32, data: []const u8) ParseError!void {
        return self.parseTemplateRecords(observation_domain_id, data, false);
    }

    fn parseOptionsTemplateSet(self: *Parser, observation_domain_id: u32, data: []const u8) ParseError!void {
        return self.parseTemplateRecords(observation_domain_id, data, true);
    }

    fn parseTemplateRecords(
        self: *Parser,
        observation_domain_id: u32,
        data: []const u8,
        is_options: bool,
    ) ParseError!void {
        var r: Reader = .fixed(data);
        var record_num: u32 = 0;

        while (true) {
            const template_id = r.takeInt(u16, .big) catch break;
            const field_count = r.takeInt(u16, .big) catch break;
            const scope_field_count: u16 = if (is_options) r.takeInt(u16, .big) catch break else 0;
            record_num += 1;

            const key = templateKey(observation_domain_id, template_id);

            if (is_options) {
                try self.formatter.optionsTemplateRecordBegin(record_num, template_id, field_count, scope_field_count);
            } else {
                try self.formatter.templateRecordBegin(record_num, template_id, field_count);
            }

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

                const info = self.registry.lookup(field_id, pen);
                const name = if (info) |f| f.name else null;
                const data_type = if (info) |f| f.data_type else null;
                try self.formatter.templateField(pen, field_id, field_length, name, data_type);
            }

            try self.formatter.templateRecordEnd();

            if (!valid) break;

            const old = try self.templates.fetchPut(key, .{ .fields = fields, .scope_count = scope_field_count });
            if (old) |o| self.allocator.free(o.value.fields);
        }
    }

    fn parseDataSet(
        self: *Parser,
        sequence_number: u32,
        observation_domain_id: u32,
        set_id: u16,
        data: []const u8,
        sampler_address: ?[16]u8,
    ) ParseError!void {
        const key = templateKey(observation_domain_id, set_id);

        const template = self.templates.get(key) orelse {
            try self.formatter.unknownDataSet(set_id);
            return;
        };

        const is_options = template.scope_count > 0;
        try self.formatter.dataSetBegin(set_id, is_options);

        var r: Reader = .fixed(data);
        var record_num: u32 = 0;

        records: while (true) {
            record_num += 1;

            const remaining = r.buffered();
            if (remaining.len < minRecordSize(template.fields)) break;

            try self.formatter.recordBegin(record_num, sequence_number, observation_domain_id, set_id, sampler_address);

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
                const is_scope = idx < template.scope_count;

                // Extract sampling rate from options template data records
                if (field.pen == null) {
                    const ie: ie_registry.IeId = @enumFromInt(field.id);
                    if (ie == .sampling_interval or ie == .sampler_random_interval or ie == .sampling_packet_interval) {
                        if (rd.readUnsigned(value)) |rate| {
                            self.sampling_rates.put(observation_domain_id, std.math.cast(u32, rate) orelse 0) catch {};
                        } else |_| {}
                    }
                }

                if (self.registry.lookup(field.id, field.pen)) |info| {
                    try self.formatter.field(info.name, field.id, field.pen, is_scope, info.data_type, value);
                } else {
                    try self.formatter.unknownField(field.id, field.pen, is_scope, value);
                }
            }

            try self.formatter.recordEnd(self.sampling_rates.get(observation_domain_id));
        }

        try self.formatter.dataSetEnd();
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
