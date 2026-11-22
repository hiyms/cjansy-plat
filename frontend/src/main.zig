// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const Io = std.Io;
const clap = @import("clap");
const build_options = @import("build_options");

const frontend = @import("frontend");

const SubCommand = enum {
    lexer,
};

/// 在编译期判定指定子命令是否已通过构建选项启用。
fn isSubCommandEnabled(comptime cmd: SubCommand) bool {
    return switch (cmd) {
        .lexer => build_options.exec_lexer,
    };
}

/// 返回指定子命令的帮助说明文本。
/// 返回编译期静态字符串切片，调用者无需释放。
fn subCommandDescription(comptime cmd: SubCommand) []const u8 {
    return switch (cmd) {
        .lexer => "Lex a Cangjie source file.",
    };
}

/// 仅接受当前编译选项启用的子命令名称。
fn parseEnabledSubCommand(in: []const u8) clap.parsers.EnumError!SubCommand {
    const cmd = std.meta.stringToEnum(SubCommand, in) orelse return error.NameNotPartOfEnum;
    return switch (cmd) {
        inline else => |c| if (comptime isSubCommandEnabled(c)) c else error.NameNotPartOfEnum,
    };
}

const main_option_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\
);

const main_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>
    \\
);

const main_parsers = .{
    .command = parseEnabledSubCommand,
};

const OutputFormat = enum {
    plain,
    json,
};

const lexer_option_params = clap.parseParamsComptime(
    \\-h, --help         Display this help and exit.
    \\--output <format>  Output format: plain or json.
    \\
);

const lexer_params = clap.parseParamsComptime(
    \\-h, --help         Display this help and exit.
    \\--output <format>  Output format: plain or json.
    \\<file>...          Input file path (exactly one required).
    \\
);

const lexer_parsers = .{
    .format = clap.parsers.enumeration(OutputFormat),
    .file = clap.parsers.string,
};

/// 刷新文件写入器缓冲区，若底层文件写入已记录系统错误则优先返回底层错误。
fn flushFileWriter(writer: *Io.File.Writer) !void {
    writer.interface.flush() catch |err| return writer.err orelse err;
}

/// 将顶层帮助信息及当前启用的子命令列表写入 `writer`。
fn writeMainHelp(writer: *Io.Writer) !void {
    try writer.writeAll("Usage: cjfrontend [options] {");
    comptime var first = true;
    inline for (std.enums.values(SubCommand)) |cmd| {
        if (comptime isSubCommandEnabled(cmd)) {
            if (!first) try writer.writeByte('|');
            first = false;
            try writer.writeAll(@tagName(cmd));
        }
    }
    try writer.writeAll("}\n\nOptions:\n");
    try clap.help(writer, clap.Help, &main_option_params, .{});
    try writer.writeAll("\nSubcommands:\n");
    inline for (std.enums.values(SubCommand)) |cmd| {
        if (comptime isSubCommandEnabled(cmd)) {
            try writer.print("    {s}\n            {s}\n", .{
                @tagName(cmd),
                comptime subCommandDescription(cmd),
            });
        }
    }
}

/// 将顶层帮助信息输出到标准错误流并刷新缓冲区。
fn printMainHelpToStderr(io: Io) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buf);
    writeMainHelp(&stderr_writer.interface) catch |err| return stderr_writer.err orelse err;
    try flushFileWriter(&stderr_writer);
}

/// 将 `lexer` 子命令的帮助信息写入 `writer`。
fn writeLexerHelp(writer: *Io.Writer) !void {
    try writer.writeAll("Usage: cjfrontend lexer [options] <file>\n\nOptions:\n");
    try clap.help(writer, clap.Help, &lexer_option_params, .{});
    try writer.writeAll("\nArguments:\n    <file>\n            Input file path (exactly one required).\n");
}

/// 将 `lexer` 子命令的帮助信息输出到标准错误流并刷新缓冲区。
fn printLexerHelpToStderr(io: Io) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buf);
    writeLexerHelp(&stderr_writer.interface) catch |err| return stderr_writer.err orelse err;
    try flushFileWriter(&stderr_writer);
}

/// 程序入口：解析顶层选项与子命令并分发执行，正常结束返回 `0`，参数或执行失败返回 `1`。
pub fn main(init: std.process.Init) !u8 {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();

    // 跳过可执行文件名
    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        // 在解析完子命令后停止，保留剩余参数交由对应子命令解析
        .terminating_positional = 0,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try diag.reportToFile(init.io, .stderr(), err);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printMainHelpToStderr(init.io);
        return 0;
    }

    const command = res.positionals[0] orelse {
        var stderr_buf: [256]u8 = undefined;
        var stderr_writer = Io.File.stderr().writerStreaming(init.io, &stderr_buf);
        stderr_writer.interface.writeAll("error: missing subcommand\n") catch |err|
            return stderr_writer.err orelse err;
        try flushFileWriter(&stderr_writer);
        try printMainHelpToStderr(init.io);
        return 1;
    };

    return dispatchSubCommand(command, init.io, init.gpa, &iter);
}

/// 根据已启用的 `SubCommand` 分发到对应子命令处理函数并返回进程退出码。
fn dispatchSubCommand(
    command: SubCommand,
    io: Io,
    gpa: std.mem.Allocator,
    iter: anytype,
) !u8 {
    return switch (command) {
        inline else => |cmd| {
            if (comptime !isSubCommandEnabled(cmd)) unreachable;
            return switch (cmd) {
                .lexer => lexerMain(io, gpa, iter),
            };
        },
    };
}

const ParsedLexerArgs = struct {
    show_help: bool = false,
    output: ?OutputFormat = null,
    file_path: ?[]const u8 = null,
    file_count: usize = 0,
};

/// 解析 `lexer` 子命令的参数并返回原始 `clap` 解析结果及提取后的字段。
/// 调用者须在结束使用后调用返回值的 `res.deinit()` 释放由 `gpa` 分配的资源；
/// `parsed.file_path` 借用自 `iter` 与 `res`，不可通过 `gpa` 单独释放，且生命周期不超过 `iter` 与 `res`。
/// 本函数不负责释放 `iter` 底层内存。
fn parseLexerArgs(
    gpa: std.mem.Allocator,
    iter: anytype,
    diag: *clap.Diagnostic,
) !struct {
    res: clap.ResultEx(clap.Help, &lexer_params, lexer_parsers),
    parsed: ParsedLexerArgs,
} {
    const res = try clap.parseEx(clap.Help, &lexer_params, lexer_parsers, iter, .{
        .diagnostic = diag,
        .allocator = gpa,
    });

    const files = res.positionals[0];
    return .{
        .res = res,
        .parsed = .{
            .show_help = res.args.help != 0,
            .output = res.args.output,
            .file_path = if (files.len == 1) files[0] else null,
            .file_count = files.len,
        },
    };
}

/// 执行 `lexer` 子命令：校验单文件输入、确定输出格式、读取源码并将词法单元输出到 `stdout`。
/// 成功返回 `0`，参数错误、文件读取错误或词法分析错误返回 `1`。
fn lexerMain(io: Io, gpa: std.mem.Allocator, iter: anytype) !u8 {
    var diag = clap.Diagnostic{};
    var args_bundle = parseLexerArgs(gpa, iter, &diag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try diag.reportToFile(io, .stderr(), err);
        return 1;
    };
    defer args_bundle.res.deinit();

    if (args_bundle.parsed.show_help) {
        try printLexerHelpToStderr(io);
        return 0;
    }

    const file_path = args_bundle.parsed.file_path orelse {
        var stderr_buf: [256]u8 = undefined;
        var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buf);
        stderr_writer.interface.print(
            "error: expected exactly 1 input file, got {d}\n",
            .{args_bundle.parsed.file_count},
        ) catch |err| return stderr_writer.err orelse err;
        try flushFileWriter(&stderr_writer);
        return 1;
    };

    const stdout_file: Io.File = .stdout();
    const format: OutputFormat = args_bundle.parsed.output orelse
        if (try stdout_file.isTty(io)) .plain else .json;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writerStreaming(io, &stdout_buf);
    const out = &stdout_writer.interface;

    // 与 Lexer 的 u32 长度上限保持一致，超出该上限时立即中止读取
    const max_source_limit = Io.Limit.limited64(@as(u64, std.math.maxInt(u32)) + 1);
    const source = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, max_source_limit) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const err_name = if (err == error.StreamTooLong) "SourceTooLarge" else @errorName(err);
        writeError(gpa, out, format, err_name, null) catch |write_err|
            return stdout_writer.err orelse write_err;
        try flushFileWriter(&stdout_writer);
        return 1;
    };
    defer gpa.free(source);

    const ok = lexSource(gpa, source, format, out) catch |err|
        return stdout_writer.err orelse err;
    try flushFileWriter(&stdout_writer);
    return if (ok) 0 else 1;
}

/// 将源码按指定格式逐个词法单元写入 `out`。
/// 词法分析过程中出现 `Lexer.Error` 时按对应格式输出错误并返回 `false`。
fn lexSource(
    gpa: std.mem.Allocator,
    source: []const u8,
    format: OutputFormat,
    out: *Io.Writer,
) !bool {
    var lexer = frontend.lexer.Lexer.new(source) catch |err| {
        try writeError(gpa, out, format, @errorName(err), null);
        return false;
    };

    while (true) {
        const tok = lexer.gen() catch |err| {
            try writeError(gpa, out, format, @errorName(err), lexer.index);
            return false;
        };
        if (tok.tag == .end) break;

        switch (format) {
            .plain => {
                try out.print("{s} {d} {d}\n", .{ @tagName(tok.tag), tok.span.start, tok.span.end });
            },
            .json => {
                const json_line = try std.json.Stringify.valueAlloc(gpa, tok, .{});
                defer gpa.free(json_line);
                try out.writeAll(json_line);
                try out.writeByte('\n');
            },
        }
    }

    return true;
}

/// 按 `format` 将错误信息（及可选的字节游标位置）写入 `out`。
fn writeError(
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    format: OutputFormat,
    err_name: []const u8,
    index: ?u32,
) !void {
    switch (format) {
        .plain => {
            if (index) |idx| {
                try out.print("error: {s} at {d}\n", .{ err_name, idx });
            } else {
                try out.print("error: {s}\n", .{err_name});
            }
        },
        .json => {
            const json_line = try std.json.Stringify.valueAlloc(gpa, .{ .@"error" = err_name }, .{});
            defer gpa.free(json_line);
            try out.writeAll(json_line);
            try out.writeByte('\n');
        },
    }
}

test "lexSource plain 格式输出词法单元" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const ok = try lexSource(gpa, "let x = 42\n", .plain, &aw.writer);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings(
        \\kw_let 0 3
        \\identifier 4 5
        \\assign 6 7
        \\integer_literal 8 10
        \\nl 10 11
        \\
    , aw.written());
}

test "lexSource json 格式每行输出一个序列化后的 Token" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const ok = try lexSource(gpa, "let x = 1", .json, &aw.writer);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings(
        \\{"tag":"kw_let","span":{"start":0,"end":3}}
        \\{"tag":"identifier","span":{"start":4,"end":5}}
        \\{"tag":"assign","span":{"start":6,"end":7}}
        \\{"tag":"integer_literal","span":{"start":8,"end":9}}
        \\
    , aw.written());
}

test "lexSource 空输入与仅空白输入输出为空" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "", "   \t\x0c  " }) |src| {
        for ([_]OutputFormat{ .plain, .json }) |fmt| {
            var aw: Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();

            const ok = try lexSource(gpa, src, fmt, &aw.writer);
            try std.testing.expect(ok);
            try std.testing.expectEqualStrings("", aw.written());
        }
    }
}

test "lexSource 含非法词法单元时继续产出 illegal" {
    const gpa = std.testing.allocator;

    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const ok = try lexSource(gpa, "`unclosed", .plain, &aw.writer);
        try std.testing.expect(ok);
        try std.testing.expectEqualStrings("illegal 0 9\n", aw.written());
    }

    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const ok = try lexSource(gpa, "`unclosed", .json, &aw.writer);
        try std.testing.expect(ok);
        try std.testing.expectEqualStrings(
            "{\"tag\":\"illegal\",\"span\":{\"start\":0,\"end\":9}}\n",
            aw.written(),
        );
    }
}

test "lexSource 产生 Error 时 plain 输出错误与游标位置" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // 构造 129 层嵌套字符串插值，触发 InterpolationDepthExceeded
    var src_buf: Io.Writer.Allocating = .init(gpa);
    defer src_buf.deinit();
    try src_buf.writer.writeAll("let a = ");
    for (0..129) |_| {
        try src_buf.writer.writeAll("\"${");
    }
    for (0..129) |_| {
        try src_buf.writer.writeAll("}\"");
    }

    const ok = try lexSource(gpa, src_buf.written(), .plain, &aw.writer);
    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings(
        \\kw_let 0 3
        \\identifier 4 5
        \\assign 6 7
        \\error: InterpolationDepthExceeded at 393
        \\
    , aw.written());
}

test "lexSource 产生 Error 时 json 输出 error 对象" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var src_buf: Io.Writer.Allocating = .init(gpa);
    defer src_buf.deinit();
    for (0..129) |_| {
        try src_buf.writer.writeAll("\"${");
    }
    for (0..129) |_| {
        try src_buf.writer.writeAll("}\"");
    }

    const ok = try lexSource(gpa, src_buf.written(), .json, &aw.writer);
    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings("{\"error\":\"InterpolationDepthExceeded\"}\n", aw.written());
}

test "writeError 无游标位置时的 plain 与 json 输出" {
    const gpa = std.testing.allocator;

    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeError(gpa, &aw.writer, .plain, "SourceTooLarge", null);
        try std.testing.expectEqualStrings("error: SourceTooLarge\n", aw.written());
    }

    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeError(gpa, &aw.writer, .json, "SourceTooLarge", null);
        try std.testing.expectEqualStrings("{\"error\":\"SourceTooLarge\"}\n", aw.written());
    }
}

test "parseEnabledSubCommand 仅接受已启用子命令" {
    inline for (std.enums.values(SubCommand)) |cmd| {
        if (comptime isSubCommandEnabled(cmd)) {
            try std.testing.expectEqual(cmd, try parseEnabledSubCommand(@tagName(cmd)));
        } else {
            try std.testing.expectError(error.NameNotPartOfEnum, parseEnabledSubCommand(@tagName(cmd)));
        }
    }
    try std.testing.expectError(error.NameNotPartOfEnum, parseEnabledSubCommand("unknown_cmd"));
}

test "parseLexerArgs 校验输入文件数量、帮助参数与 --output 选项" {
    const gpa = std.testing.allocator;

    // 恰好 1 个文件 + --output=plain
    {
        const raw = [_][]const u8{ "--output=plain", "foo.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expect(!bundle.parsed.show_help);
        try std.testing.expectEqual(@as(?OutputFormat, .plain), bundle.parsed.output);
        try std.testing.expectEqual(@as(usize, 1), bundle.parsed.file_count);
        try std.testing.expectEqualStrings("foo.cj", bundle.parsed.file_path.?);
    }

    // --output=json 放在文件路径之后
    {
        const raw = [_][]const u8{ "foo.cj", "--output=json" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(?OutputFormat, .json), bundle.parsed.output);
        try std.testing.expectEqualStrings("foo.cj", bundle.parsed.file_path.?);
    }

    // 空格分隔形式的 --output 与重复指定时后值覆盖前值
    {
        const raw = [_][]const u8{ "--output", "plain", "--output=json", "foo.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(?OutputFormat, .json), bundle.parsed.output);
        try std.testing.expectEqualStrings("foo.cj", bundle.parsed.file_path.?);
    }

    // -h 与 --help 标志
    for ([_][]const u8{ "-h", "--help" }) |flag| {
        const raw = [_][]const u8{flag};
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expect(bundle.parsed.show_help);
    }

    // 通过 `--` 传入以 `-` 开头的文件名
    {
        const raw = [_][]const u8{ "--", "-foo.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(usize, 1), bundle.parsed.file_count);
        try std.testing.expectEqualStrings("-foo.cj", bundle.parsed.file_path.?);
    }

    // 缺少输入文件
    {
        const raw = [_][]const u8{};
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(usize, 0), bundle.parsed.file_count);
        try std.testing.expectEqual(@as(?[]const u8, null), bundle.parsed.file_path);
    }

    // 传入 2 个输入文件
    {
        const raw = [_][]const u8{ "a.cj", "b.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(usize, 2), bundle.parsed.file_count);
        try std.testing.expectEqual(@as(?[]const u8, null), bundle.parsed.file_path);
    }

    // 非法 --output 值
    {
        const raw = [_][]const u8{ "--output=xml", "a.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        try std.testing.expectError(error.NameNotPartOfEnum, parseLexerArgs(gpa, &iter, &diag));
    }
}

test "writeMainHelp 明确列出已启用的子命令" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeMainHelp(&aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "<command>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--help") != null);

    inline for (std.enums.values(SubCommand)) |cmd| {
        const found = std.mem.indexOf(u8, out, @tagName(cmd)) != null;
        try std.testing.expectEqual(comptime isSubCommandEnabled(cmd), found);
    }
}

test "writeLexerHelp 展示单文件用法与选项" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeLexerHelp(&aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "Usage: cjfrontend lexer [options] <file>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--output <format>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<file>...") == null);
}
