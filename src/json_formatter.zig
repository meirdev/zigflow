const std = @import("std");
const fmt = @import("formatter.zig");

const Writer = std.Io.Writer;
const Formatter = fmt.Formatter;
const DataType = fmt.DataType;
const Error = fmt.Error;

pub const JsonFormatter = struct {
    w: *Writer,
    first_set: bool = true,
    first_record: bool = true,
    first_field: bool = true,
    interface: Formatter,

    pub fn init(w: *Writer) JsonFormatter {
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

    fn self(f: *Formatter) *JsonFormatter {
        return @alignCast(@fieldParentPtr("interface", f));
    }

    fn messageBegin(f: *Formatter, export_time: u32, sequence_number: u32, observation_domain_id: u32, _: u16) Error!void {
        const s = self(f);
        try s.w.print("{{\"version\":{d},\"observationDomainId\":{d},\"exportTime\":{d},\"sequenceNumber\":{d},\"sets\":[", .{
            @as(u16, 10), observation_domain_id, export_time, sequence_number,
        });
        s.first_set = true;
    }

    fn messageEnd(f: *Formatter) Error!void {
        try self(f).w.writeAll("]}\n");
    }

    fn setHeader(_: *Formatter, _: u16, _: u16) Error!void {}

    fn templateRecordBegin(f: *Formatter, _: u32, template_id: u16, _: u16) Error!void {
        const s = self(f);
        if (!s.first_set) try s.w.writeAll(",");
        try s.w.print("{{\"setType\":\"template\",\"templateId\":{d},\"fields\":[", .{template_id});
        s.first_set = false;
        s.first_field = true;
    }

    fn templateField(f: *Formatter, pen: ?u32, id: u16, length: u16, name: ?[]const u8, data_type: ?DataType) Error!void {
        const s = self(f);
        if (!s.first_field) try s.w.writeAll(",");
        try s.w.writeAll("{");
        if (name) |n| try s.w.print("\"name\":\"{s}\",", .{n});
        if (data_type) |dt| try s.w.print("\"type\":\"{s}\",", .{fmt.dataTypeName(dt)});
        try s.w.print("\"id\":{d},\"length\":{d}", .{ id, length });
        if (pen) |p| try s.w.print(",\"pen\":{d}", .{p});
        try s.w.writeAll("}");
        s.first_field = false;
    }

    fn templateRecordEnd(f: *Formatter) Error!void {
        try self(f).w.writeAll("]}");
    }

    fn optionsTemplateRecordBegin(f: *Formatter, _: u32, template_id: u16, _: u16, scope_field_count: u16) Error!void {
        const s = self(f);
        if (!s.first_set) try s.w.writeAll(",");
        try s.w.print("{{\"setType\":\"optionsTemplate\",\"templateId\":{d},\"scopeFieldCount\":{d},\"fields\":[", .{
            template_id, scope_field_count,
        });
        s.first_set = false;
        s.first_field = true;
    }

    fn dataSetBegin(f: *Formatter, set_id: u16, _: bool) Error!void {
        const s = self(f);
        if (!s.first_set) try s.w.writeAll(",");
        try s.w.print("{{\"setType\":\"data\",\"templateId\":{d},\"records\":[", .{set_id});
        s.first_set = false;
        s.first_record = true;
    }

    fn dataSetEnd(f: *Formatter) Error!void {
        try self(f).w.writeAll("]}");
    }

    fn unknownDataSet(_: *Formatter, _: u16) Error!void {}

    fn recordBegin(f: *Formatter, _: u32, _: u32, _: u32, _: u16, _: ?[16]u8) Error!void {
        const s = self(f);
        if (!s.first_record) try s.w.writeAll(",");
        try s.w.writeAll("{");
        s.first_record = false;
        s.first_field = true;
    }

    fn recordEnd(f: *Formatter, _: ?u32) Error!void {
        try self(f).w.writeAll("}");
    }

    fn field(f: *Formatter, name: []const u8, _: u16, _: ?u32, _: bool, data_type: DataType, value: []const u8) Error!void {
        const s = self(f);
        if (!s.first_field) try s.w.writeAll(",");
        try s.w.print("\"{s}\":", .{name});
        if (data_type == .string) {
            try s.w.writeAll("\"");
            try writeJsonEscaped(s.w, value);
            try s.w.writeAll("\"");
        } else if (fmt.needsQuoting(data_type)) {
            try s.w.writeAll("\"");
            try fmt.formatValue(s.w, data_type, value);
            try s.w.writeAll("\"");
        } else {
            try fmt.formatValue(s.w, data_type, value);
        }
        s.first_field = false;
    }

    fn writeJsonEscaped(w: *Writer, s: []const u8) Writer.Error!void {
        for (s) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                },
            }
        }
    }

    fn unknownField(f: *Formatter, id: u16, pen: ?u32, _: bool, value: []const u8) Error!void {
        const s = self(f);
        if (!s.first_field) try s.w.writeAll(",");
        if (pen) |p| {
            try s.w.print("\"ie{d}_pen{d}\":\"", .{ id, p });
        } else {
            try s.w.print("\"ie{d}\":\"", .{id});
        }
        try fmt.formatHex(s.w, value);
        try s.w.writeAll("\"");
        s.first_field = false;
    }
};
