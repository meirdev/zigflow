const std = @import("std");
const parser_mod = @import("parser.zig");
const raw_fmt = @import("raw_formatter.zig");
const json_fmt = @import("json_formatter.zig");
const proto_fmt = @import("protobuf_formatter.zig");

const mem = std.mem;
const posix = std.posix;
const Parser = parser_mod.Parser;
const Formatter = parser_mod.Formatter;
const Writer = std.Io.Writer;

const OutputFormat = enum { raw, json, protobuf };

const Config = struct {
    port: u16 = 4739,
    bind_addr: []const u8 = "0.0.0.0",
    format: OutputFormat = .raw,
};

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--port") or mem.eql(u8, args[i], "-p")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("{s} requires a value", .{args[i - 1]});
                return error.MissingArgValue;
            }
            config.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (mem.eql(u8, args[i], "--bind") or mem.eql(u8, args[i], "-b")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("{s} requires a value", .{args[i - 1]});
                return error.MissingArgValue;
            }
            config.bind_addr = args[i];
        } else if (mem.eql(u8, args[i], "--json") or mem.eql(u8, args[i], "-j")) {
            config.format = .json;
        } else if (mem.eql(u8, args[i], "--protobuf") or mem.eql(u8, args[i], "--proto")) {
            config.format = .protobuf;
        }
    }

    return config;
}

fn extractSamplerAddr(storage: *const posix.sockaddr.storage) ?[16]u8 {
    const family = @as(*const posix.sockaddr, @ptrCast(storage)).family;
    if (family == posix.AF.INET) {
        const sa: *const posix.sockaddr.in = @ptrCast(@alignCast(storage));
        var addr: [16]u8 = .{0} ** 16;
        addr[0..4].* = @bitCast(sa.addr);
        return addr;
    } else if (family == posix.AF.INET6) {
        const sa: *const posix.sockaddr.in6 = @ptrCast(@alignCast(storage));
        return sa.addr;
    }
    return null;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try parseArgs(args);

    const address = try std.net.Address.parseIp(config.bind_addr, config.port);

    const sockfd = try posix.socket(
        address.any.family,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.UDP,
    );
    defer posix.close(sockfd);

    try posix.bind(sockfd, &address.any, address.getOsSockLen());

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.writerStreaming(std.fs.File.stdout(), &stdout_buf);
    const w = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.writerStreaming(std.fs.File.stderr(), &stderr_buf);
    const err_w = &stderr_writer.interface;

    var raw = raw_fmt.RawFormatter.init(w);
    var json = json_fmt.JsonFormatter.init(w);
    var proto = proto_fmt.ProtobufFormatter.init(w);

    const formatter: *Formatter = switch (config.format) {
        .raw => &raw.interface,
        .json => &json.interface,
        .protobuf => &proto.interface,
    };

    var parser = try Parser.init(allocator, formatter);
    defer parser.deinit();

    try err_w.print("IPFIX collector listening on {s}:{d}\n", .{ config.bind_addr, config.port });
    try err_w.flush();

    var recv_buf: [65535]u8 = undefined;
    while (true) {
        var src_addr: posix.sockaddr.storage = undefined;
        var src_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        const n = posix.recvfrom(
            sockfd,
            &recv_buf,
            0,
            @ptrCast(&src_addr),
            &src_addr_len,
        ) catch |err| {
            try err_w.print("recvfrom error: {}\n", .{err});
            try err_w.flush();
            continue;
        };

        parser.parseMessage(recv_buf[0..n], extractSamplerAddr(&src_addr)) catch |err| {
            try err_w.print("parse error: {}\n", .{err});
            try err_w.flush();
        };
        try w.flush();
    }
}
