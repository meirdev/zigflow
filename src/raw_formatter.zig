const std = @import("std");
const fmt = @import("formatter.zig");

const Writer = std.Io.Writer;
const Formatter = fmt.Formatter;
const DataType = fmt.DataType;
const Error = fmt.Error;

pub const RawFormatter = struct {
    w: *Writer,
    interface: Formatter,

    pub fn init(w: *Writer) RawFormatter {
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

    fn self(f: *Formatter) *RawFormatter {
        return @alignCast(@fieldParentPtr("interface", f));
    }

    fn messageBegin(f: *Formatter, export_time: u32, sequence_number: u32, observation_domain_id: u32, length: u16) Error!void {
        try self(f).w.print("IPFIX Message Header:\n\tLength: {d}\n\tExport time: {d}\n\tSequence number: {d}\n\tObservation domain ID: {d}\n", .{
            length, export_time, sequence_number, observation_domain_id,
        });
    }

    fn messageEnd(_: *Formatter) Error!void {}

    fn setHeader(f: *Formatter, set_id: u16, set_length: u16) Error!void {
        try self(f).w.print("Set Header:\n\tLength: {d}\n\tSet ID: {d}\n", .{ set_length, set_id });
    }

    fn templateRecordBegin(f: *Formatter, record_num: u32, template_id: u16, field_count: u16) Error!void {
        try self(f).w.print("Template Record {d}:\n\tTemplate ID: {d}\n\tField Count: {d}\n", .{
            record_num, template_id, field_count,
        });
    }

    fn templateField(f: *Formatter, pen: ?u32, id: u16, length: u16, name: ?[]const u8, _: ?DataType) Error!void {
        const w = self(f).w;
        try w.print("\tPEN: {d}, ID: {d}, Length: {d}", .{ pen orelse 0, id, length });
        if (name) |n| try w.print(", Name: {s}", .{n});
        try w.writeAll("\n");
    }

    fn templateRecordEnd(_: *Formatter) Error!void {}

    fn optionsTemplateRecordBegin(f: *Formatter, record_num: u32, template_id: u16, field_count: u16, scope_field_count: u16) Error!void {
        try self(f).w.print("Options Template Record {d}:\n\tTemplate ID: {d}\n\tField Count: {d}\n\tScope Field Count: {d}\n", .{
            record_num, template_id, field_count, scope_field_count,
        });
    }

    fn dataSetBegin(_: *Formatter, _: u16, _: bool) Error!void {}
    fn dataSetEnd(_: *Formatter) Error!void {}

    fn unknownDataSet(f: *Formatter, set_id: u16) Error!void {
        try self(f).w.print("Data Set {d}: no template\n", .{set_id});
    }

    fn recordBegin(f: *Formatter, record_num: u32, _: u32, _: u32, _: u16, _: ?[16]u8) Error!void {
        try self(f).w.print("Data Record {d}:\n", .{record_num});
    }

    fn recordEnd(_: *Formatter, _: ?u32) Error!void {}

    fn field(f: *Formatter, name: []const u8, id: u16, _: ?u32, is_scope: bool, data_type: DataType, value: []const u8) Error!void {
        const w = self(f).w;
        if (is_scope) {
            try w.print("\t[scope] ", .{});
        } else {
            try w.print("\t", .{});
        }
        try w.print("{s} ({d}): ", .{ name, id });
        try fmt.formatValue(w, data_type, value);
        try w.writeAll("\n");
    }

    fn unknownField(f: *Formatter, id: u16, pen: ?u32, is_scope: bool, value: []const u8) Error!void {
        const w = self(f).w;
        if (is_scope) {
            try w.print("\t[scope] ", .{});
        } else {
            try w.print("\t", .{});
        }
        if (pen) |p| {
            try w.print("ie{d} (pen={d}): ", .{ id, p });
        } else {
            try w.print("ie{d}: ", .{id});
        }
        try fmt.formatHex(w, value);
        try w.writeAll("\n");
    }
};
