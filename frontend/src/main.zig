const std = @import("std");
const Io = std.Io;

const frontend = @import("frontend");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("用法：{s} <源文件>\n", .{args[0]});
        return error.MissingSourceFile;
    }

    const io = init.io;
    const source = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 * 1024 * 1024));
    const tokens = try frontend.tokenize(arena, source);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    for (tokens) |token| {
        try stdout_writer.print("{s}\t{s}\n", .{ @tagName(token.kind), token.text });
    }
    try stdout_writer.flush();
}
