const std = @import("std");
const ie_registry = @import("ie_registry.zig");
const fmt = @import("formatter.zig");
const rd = @import("reader.zig");

const Writer = std.Io.Writer;
const Formatter = fmt.Formatter;
const DataType = fmt.DataType;
const Error = fmt.Error;
const IeId = ie_registry.IeId;
const readUnsigned = rd.readUnsigned;

pub const ProtobufFormatter = struct {
    w: *Writer,
    current_flow: ?Flow = null,
    skip_set: bool = false,
    interface: Formatter,

    pub fn init(w: *Writer) ProtobufFormatter {
        return .{ .w = w, .interface = .{ .vtable = &vtable } };
    }

    const vtable = Formatter.VTable{
        .messageBegin = messageBegin,
        .messageEnd = messageEnd,
        .setHeader = setHeader,
        .templateRecordBegin = templateRecordBegin,
        .templateField = templateField,
        .templateRecordEnd = templateRecordEnd,
        .optionsTemplateRecordBegin = optionsTemplateRecordBegin,
        .dataSetBegin = dataSetBegin,
        .dataSetEnd = dataSetEnd,
        .unknownDataSet = unknownDataSet,
        .recordBegin = recordBegin,
        .recordEnd = recordEnd,
        .field = field,
        .unknownField = unknownField,
    };

    fn self(f: *Formatter) *ProtobufFormatter {
        return @alignCast(@fieldParentPtr("interface", f));
    }

    fn messageBegin(_: *Formatter, _: u32, _: u32, _: u32, _: u16) Error!void {}
    fn messageEnd(_: *Formatter) Error!void {}
    fn setHeader(_: *Formatter, _: u16, _: u16) Error!void {}
    fn templateRecordBegin(_: *Formatter, _: u32, _: u16, _: u16) Error!void {}
    fn templateField(_: *Formatter, _: ?u32, _: u16, _: u16, _: ?[]const u8, _: ?DataType) Error!void {}
    fn templateRecordEnd(_: *Formatter) Error!void {}
    fn optionsTemplateRecordBegin(_: *Formatter, _: u32, _: u16, _: u16, _: u16) Error!void {}
    fn dataSetBegin(f: *Formatter, _: u16, is_options: bool) Error!void {
        self(f).skip_set = is_options;
    }
    fn dataSetEnd(f: *Formatter) Error!void {
        self(f).skip_set = false;
    }
    fn unknownDataSet(_: *Formatter, _: u16) Error!void {}

    fn recordBegin(f: *Formatter, _: u32, sequence_num: u32, observation_domain_id: u32, template_id: u16, sampler_address: ?[16]u8) Error!void {
        const s = self(f);
        if (s.skip_set) return;
        s.current_flow = .{
            .time_received_ns = @intCast(std.time.nanoTimestamp()),
            .sequence_num = sequence_num,
            .observation_domain_id = observation_domain_id,
            .template_id = template_id,
            .sampler_address = if (sampler_address) |*a| blk: {
                var addr: Addr = .{};
                addr.set(addrSlice(a));
                break :blk addr;
            } else .{},
        };
    }

    fn recordEnd(f: *Formatter, sampling_rate: ?u32) Error!void {
        const s = self(f);
        if (s.current_flow) |*flow| {
            flow.sampling_rate = sampling_rate;
            try flow.encode(s.w);
        }
        s.current_flow = null;
    }

    fn field(f: *Formatter, _: []const u8, id: u16, pen: ?u32, _: bool, data_type: DataType, value: []const u8) Error!void {
        if (self(f).current_flow) |*flow| {
            if (pen != null) return;
            flow.mapField(id, data_type, value);
        }
    }

    fn unknownField(_: *Formatter, _: u16, _: ?u32, _: bool, _: []const u8) Error!void {}
};

const Addr = struct {
    buf: [16]u8 = undefined,
    len: u8 = 0,

    fn set(self: *Addr, value: []const u8) void {
        if (value.len <= 16) {
            @memcpy(self.buf[0..value.len], value);
            self.len = @intCast(value.len);
        }
    }

    fn slice(self: *const Addr) []const u8 {
        return self.buf[0..self.len];
    }
};

const Flow = struct {
    time_received_ns: u64 = 0,
    sequence_num: u32 = 0,
    observation_domain_id: u32 = 0,
    template_id: u16 = 0,
    bytes: u64 = 0,
    packets: u64 = 0,
    sampling_rate: ?u32 = null,
    sampler_address: Addr = .{},
    time_flow_start_ns: ?u64 = null,
    time_flow_end_ns: ?u64 = null,
    src_addr: Addr = .{},
    dst_addr: Addr = .{},
    etype: ?u16 = null,
    proto: ?u8 = null,
    src_port: ?u16 = null,
    dst_port: ?u16 = null,
    in_if: ?u32 = null,
    out_if: ?u32 = null,
    tcp_flags: ?u8 = null,
    src_as: ?u32 = null,
    dst_as: ?u32 = null,
    next_hop: Addr = .{},
    src_net: ?u8 = null,
    dst_net: ?u8 = null,

    fn mapField(f: *Flow, id: u16, data_type: DataType, value: []const u8) void {
        const ie: IeId = @enumFromInt(id);
        switch (ie) {
            // Address fields — store raw bytes (4 for IPv4, 16 for IPv6).
            .source_ipv4_address, .source_ipv6_address => f.src_addr.set(value),
            .destination_ipv4_address, .destination_ipv6_address => f.dst_addr.set(value),
            .ip_next_hop_ipv4_address, .ip_next_hop_ipv6_address => f.next_hop.set(value),
            // Timestamp fields — need both the integer and raw bytes for NTP conversion.
            .flow_start_seconds, .flow_start_milliseconds, .flow_start_microseconds, .flow_start_nanoseconds => {
                const u = readUnsigned(value) catch return;
                f.time_flow_start_ns = toNanos(data_type, u, value);
            },
            .flow_end_seconds, .flow_end_milliseconds, .flow_end_microseconds, .flow_end_nanoseconds => {
                const u = readUnsigned(value) catch return;
                f.time_flow_end_ns = toNanos(data_type, u, value);
            },
            // Numeric fields.
            else => {
                const u = readUnsigned(value) catch return;
                switch (ie) {
                    .octet_delta_count => f.bytes = u,
                    .packet_delta_count => f.packets = u,
                    .protocol_identifier => f.proto = @truncate(u),
                    .tcp_control_bits => f.tcp_flags = @truncate(u),
                    .source_transport_port => f.src_port = std.math.cast(u16, u) orelse return,
                    .source_ipv4_prefix_length, .source_ipv6_prefix_length => f.src_net = @truncate(u),
                    .ingress_interface => f.in_if = std.math.cast(u32, u) orelse return,
                    .destination_transport_port => f.dst_port = std.math.cast(u16, u) orelse return,
                    .destination_ipv4_prefix_length, .destination_ipv6_prefix_length => f.dst_net = @truncate(u),
                    .egress_interface => f.out_if = std.math.cast(u32, u) orelse return,
                    .bgp_source_as_number => f.src_as = std.math.cast(u32, u) orelse return,
                    .bgp_destination_as_number => f.dst_as = std.math.cast(u32, u) orelse return,
                    .ethernet_type => f.etype = std.math.cast(u16, u) orelse return,
                    .sampling_interval, .sampler_random_interval, .sampling_packet_interval => {},
                    else => {},
                }
            },
        }
    }

    fn encode(self: *const Flow, w: *Writer) Writer.Error!void {
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const bw = fbs.writer();

        if (self.time_received_ns != 0) writeVarintField(bw, 1, self.time_received_ns);
        if (self.sequence_num != 0) writeVarintField(bw, 2, self.sequence_num);
        if (self.sampling_rate) |v| writeVarintField(bw, 3, v);
        if (self.sampler_address.len > 0) writeBytesField(bw, 4, self.sampler_address.slice());
        if (self.time_flow_start_ns) |v| writeVarintField(bw, 5, v);
        if (self.time_flow_end_ns) |v| writeVarintField(bw, 6, v);
        if (self.bytes != 0) writeVarintField(bw, 7, self.bytes);
        if (self.packets != 0) writeVarintField(bw, 8, self.packets);
        if (self.src_addr.len > 0) writeBytesField(bw, 9, self.src_addr.slice());
        if (self.dst_addr.len > 0) writeBytesField(bw, 10, self.dst_addr.slice());
        if (self.etype) |v| writeVarintField(bw, 11, v);
        if (self.proto) |v| writeVarintField(bw, 12, v);
        if (self.src_port) |v| writeVarintField(bw, 13, v);
        if (self.dst_port) |v| writeVarintField(bw, 14, v);
        if (self.in_if) |v| writeVarintField(bw, 15, v);
        if (self.out_if) |v| writeVarintField(bw, 16, v);
        if (self.tcp_flags) |v| writeVarintField(bw, 17, v);
        if (self.src_as) |v| writeVarintField(bw, 18, v);
        if (self.dst_as) |v| writeVarintField(bw, 19, v);
        if (self.next_hop.len > 0) writeBytesField(bw, 20, self.next_hop.slice());
        if (self.src_net) |v| writeVarintField(bw, 21, v);
        if (self.dst_net) |v| writeVarintField(bw, 22, v);
        if (self.observation_domain_id != 0) writeVarintField(bw, 23, self.observation_domain_id);
        if (self.template_id != 0) writeVarintField(bw, 24, self.template_id);

        const payload = fbs.getWritten();
        // Length-delimited framing: varint-encoded length prefix.
        try writeVarintFallible(w, payload.len);
        try w.writeAll(payload);
    }
};

/// Return a 4-byte slice if the [16]u8 looks like a zero-padded IPv4, otherwise the full 16 bytes.
fn addrSlice(a: *const [16]u8) []const u8 {
    if (std.mem.eql(u8, a[4..16], &(.{0} ** 12))) return a[0..4];
    return a;
}

fn toNanos(data_type: DataType, u: u64, value: []const u8) ?u64 {
    return switch (data_type) {
        .date_time_seconds => u * 1_000_000_000,
        .date_time_milliseconds => u * 1_000_000,
        .date_time_microseconds, .date_time_nanoseconds => blk: {
            const ntp = rd.readNtpTimestamp(value) catch break :blk null;
            break :blk ntp.epoch_secs * 1_000_000_000 + ntp.frac * 1_000_000_000 / 0x100000000;
        },
        else => null,
    };
}

const wire_varint: u3 = 0;
const wire_bytes: u3 = 2;

fn writeVarint(w: anytype, value: u64) void {
    var v = value;
    while (v > 0x7f) {
        w.writeByte(@as(u8, @truncate(v & 0x7f)) | 0x80) catch unreachable;
        v >>= 7;
    }
    w.writeByte(@truncate(v)) catch unreachable;
}

fn writeVarintFallible(w: *Writer, value: u64) Writer.Error!void {
    var v = value;
    while (v > 0x7f) {
        try w.writeByte(@as(u8, @truncate(v & 0x7f)) | 0x80);
        v >>= 7;
    }
    try w.writeByte(@truncate(v));
}

fn writeTag(w: anytype, field_number: u32, wire_type: u3) void {
    writeVarint(w, (@as(u64, field_number) << 3) | wire_type);
}

fn writeVarintField(w: anytype, field_number: u32, value: u64) void {
    writeTag(w, field_number, wire_varint);
    writeVarint(w, value);
}

fn writeBytesField(w: anytype, field_number: u32, data: []const u8) void {
    writeTag(w, field_number, wire_bytes);
    writeVarint(w, data.len);
    w.writeAll(data) catch unreachable;
}
