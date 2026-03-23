const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const Parser = @import("parser.zig").Parser;

const Writer = std.Io.Writer;

const Config = struct {
    port: u16 = 4739,
    bind_addr: []const u8 = "0.0.0.0",
};

/// Parses command-line arguments and returns a Config struct.
fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--port") or mem.eql(u8, args[i], "-p")) {
            i += 1;
            if (i < args.len) {
                config.port = try std.fmt.parseInt(u16, args[i], 10);
            }
        } else if (mem.eql(u8, args[i], "--bind") or mem.eql(u8, args[i], "-b")) {
            i += 1;
            if (i < args.len) {
                config.bind_addr = args[i];
            }
        }
    }

    return config;
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

    var write_buf: [8192]u8 = undefined;
    var file_writer = std.fs.File.writerStreaming(std.fs.File.stdout(), &write_buf);
    const w = &file_writer.interface;

    var parser = try Parser.init(allocator, w);
    defer parser.deinit();

    try w.print("IPFIX collector listening on {s}:{d}\n", .{ config.bind_addr, config.port });
    try w.flush();

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
            try w.print("recvfrom error: {}\n", .{err});
            try w.flush();
            continue;
        };

        parser.parseMessage(recv_buf[0..n]) catch |err| {
            try w.print("parse error: {}\n", .{err});
        };
        try w.flush();
    }
}
