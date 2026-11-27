// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const Io = std.Io;
const clap = @import("clap");
const build_options = @import("build_options");
const common = @import("common");

const frontend = @import("frontend");

const SubCommand = enum {
    lexer,
    parser,
};

/// 在编译期判定指定子命令是否已通过构建选项启用。
fn isSubCommandEnabled(comptime cmd: SubCommand) bool {
    return switch (cmd) {
        .lexer => build_options.exec_lexer,
        .parser => build_options.exec_parser,
    };
}

/// 返回指定子命令的帮助说明文本。
/// 返回编译期静态字符串切片，调用者无需释放。
fn subCommandDescription(comptime cmd: SubCommand) []const u8 {
    return switch (cmd) {
        .lexer => "Lex a Cangjie source file.",
        .parser => "Parse Cangjie tokens or a source file into a syntax tree or events.",
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

const ParseOutputType = enum {
    event,
    tree,
};

const lexer_option_params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-f, --format <format>  Output format: plain or json.
    \\
);

const lexer_params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-f, --format <format>  Output format: plain or json.
    \\<file>...              Input file path (exactly one required).
    \\
);

const lexer_parsers = .{
    .format = clap.parsers.enumeration(OutputFormat),
    .file = clap.parsers.string,
};

const parser_params = clap.parseParamsComptime(
    \\-h, --help                Display this help and exit.
    \\-f, --format <format>     Output format: plain or json.
    \\-t <type>                 Output type: event or tree (default: tree).
    \\-s, --source-file <file>  Read and lex a Cangjie source file instead of reading JSON tokens from stdin.
    \\
);

const parser_parsers = .{
    .format = clap.parsers.enumeration(OutputFormat),
    .type = clap.parsers.enumeration(ParseOutputType),
    .file = clap.parsers.string,
};

/// 与 Lexer 的 u32 长度上限保持一致，超出该上限时立即中止读取。
const max_source_limit = Io.Limit.limited64(@as(u64, std.math.maxInt(u32)) + 1);

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

/// 将 `parser` 子命令的帮助信息写入 `writer`。
fn writeParserHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        "Usage: cjfrontend parser [options]\n\n" ++
            "Reads one JSON-serialized Token per line from stdin by default.\n\nOptions:\n",
    );
    try clap.help(writer, clap.Help, &parser_params, .{});
}

/// 将 `parser` 子命令的帮助信息输出到标准错误流并刷新缓冲区。
fn printParserHelpToStderr(io: Io) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buf);
    writeParserHelp(&stderr_writer.interface) catch |err| return stderr_writer.err orelse err;
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
                .parser => parserMain(io, gpa, iter),
            };
        },
    };
}

const ParsedLexerArgs = struct {
    show_help: bool = false,
    format: ?OutputFormat = null,
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
            .format = res.args.format,
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
    const format: OutputFormat = args_bundle.parsed.format orelse
        if (try stdout_file.isTty(io)) .plain else .json;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writerStreaming(io, &stdout_buf);
    const out = &stdout_writer.interface;

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

const ParsedParserArgs = struct {
    show_help: bool = false,
    format: ?OutputFormat = null,
    output_type: ParseOutputType = .tree,
    source_file: ?[]const u8 = null,
};

/// 解析 `parser` 子命令的参数并返回原始 `clap` 解析结果及提取后的字段。
/// 调用者须在结束使用后调用返回值的 `res.deinit()` 释放由 `gpa` 分配的资源；
/// `parsed.source_file` 借用自 `iter` 与 `res`，不可通过 `gpa` 单独释放，且生命周期不超过 `iter` 与 `res`。
/// 本函数不负责释放 `iter` 底层内存。
fn parseParserArgs(
    gpa: std.mem.Allocator,
    iter: anytype,
    diag: *clap.Diagnostic,
) !struct {
    res: clap.ResultEx(clap.Help, &parser_params, parser_parsers),
    parsed: ParsedParserArgs,
} {
    const res = try clap.parseEx(clap.Help, &parser_params, parser_parsers, iter, .{
        .diagnostic = diag,
        .allocator = gpa,
    });

    return .{
        .res = res,
        .parsed = .{
            .show_help = res.args.help != 0,
            .format = res.args.format,
            .output_type = res.args.t orelse .tree,
            .source_file = res.args.@"source-file",
        },
    };
}

/// 执行 `parser` 子命令：默认从 `stdin` 逐行读取 JSON 序列化的 `Token` 并按 `-t` 输出语法树或事件流，
/// 指定 `-s` / `--source-file` 时自动读取并词法扫描对应源文件后再解析。
/// 成功返回 `0`，参数错误、读取错误、词法错误或输入 JSON 非法返回 `1`。
fn parserMain(io: Io, gpa: std.mem.Allocator, iter: anytype) !u8 {
    var diag = clap.Diagnostic{};
    var args_bundle = parseParserArgs(gpa, iter, &diag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try diag.reportToFile(io, .stderr(), err);
        return 1;
    };
    defer args_bundle.res.deinit();

    if (args_bundle.parsed.show_help) {
        try printParserHelpToStderr(io);
        return 0;
    }

    const stdout_file: Io.File = .stdout();
    const format: OutputFormat = args_bundle.parsed.format orelse
        if (try stdout_file.isTty(io)) .plain else .json;
    const output_type = args_bundle.parsed.output_type;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writerStreaming(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const ok = if (args_bundle.parsed.source_file) |file_path| blk: {
        const source = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, max_source_limit) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const err_name = if (err == error.StreamTooLong) "SourceTooLarge" else @errorName(err);
            writeError(gpa, out, format, err_name, null) catch |write_err|
                return stdout_writer.err orelse write_err;
            try flushFileWriter(&stdout_writer);
            return 1;
        };
        defer gpa.free(source);

        break :blk parseSource(gpa, source, format, output_type, out) catch |err|
            return stdout_writer.err orelse err;
    } else blk: {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = Io.File.stdin().readerStreaming(io, &stdin_buf);

        break :blk parseTokenJsonStream(gpa, &stdin_reader.interface, format, output_type, out) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => read_err_blk: {
                const read_err = stdin_reader.err orelse err;
                writeError(gpa, out, format, @errorName(read_err), null) catch |write_err|
                    return stdout_writer.err orelse write_err;
                break :read_err_blk false;
            },
            else => return stdout_writer.err orelse err,
        };
    };

    try flushFileWriter(&stdout_writer);
    return if (ok) 0 else 1;
}

/// 对仓颉源码执行内部词法分析与语法解析，并按 `output_type` 与 `format` 将结果写入 `out`。
/// 词法分析出现 `Lexer.Error` 时按对应格式输出错误并返回 `false`。
fn parseSource(
    gpa: std.mem.Allocator,
    source: []const u8,
    format: OutputFormat,
    output_type: ParseOutputType,
    out: *Io.Writer,
) !bool {
    var lexer = frontend.lexer.Lexer.new(source) catch |err| {
        try writeError(gpa, out, format, @errorName(err), null);
        return false;
    };

    var tokens: std.ArrayList(common.Token) = .empty;
    defer tokens.deinit(gpa);

    while (true) {
        const tok = lexer.gen() catch |err| {
            try writeError(gpa, out, format, @errorName(err), lexer.index);
            return false;
        };
        try tokens.append(gpa, tok);
        if (tok.tag == .end) break;
    }

    try parseTokens(gpa, source, tokens.items, format, output_type, out);
    return true;
}

/// 从 `reader` 逐行读取 JSON 序列化的 `common.Token` 并执行语法解析，按 `output_type` 与 `format` 将结果写入 `out`。
/// 输入行格式非法、包含上游错误对象或区间倒置时按对应格式输出错误并返回 `false`。
fn parseTokenJsonStream(
    gpa: std.mem.Allocator,
    reader: *Io.Reader,
    format: OutputFormat,
    output_type: ParseOutputType,
    out: *Io.Writer,
) !bool {
    const UpstreamError = struct {
        @"error": []const u8,
    };

    var tokens: std.ArrayList(common.Token) = .empty;
    defer tokens.deinit(gpa);

    var line_buf: Io.Writer.Allocating = .init(gpa);
    defer line_buf.deinit();

    var line_num: u32 = 0;
    var max_end: u32 = 0;

    while (true) {
        line_buf.clearRetainingCapacity();
        _ = reader.streamDelimiterEnding(&line_buf.writer, '\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
        };

        const hit_nl = if (reader.peekByte()) |b| blk: {
            std.debug.assert(b == '\n');
            reader.toss(1);
            break :blk true;
        } else |err| switch (err) {
            error.EndOfStream => false,
            error.ReadFailed => return error.ReadFailed,
        };

        const raw_line = line_buf.written();
        if (!hit_nl and raw_line.len == 0) break;

        line_num +|= 1;
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed_tok = std.json.parseFromSlice(common.Token, gpa, trimmed, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (std.json.parseFromSlice(UpstreamError, gpa, trimmed, .{})) |upstream| {
                defer upstream.deinit();
                try writeError(gpa, out, format, upstream.value.@"error", line_num);
                return false;
            } else |up_err| {
                if (up_err == error.OutOfMemory) return error.OutOfMemory;
            }
            try writeError(gpa, out, format, "InvalidTokenJson", line_num);
            return false;
        };
        defer parsed_tok.deinit();

        const tok = parsed_tok.value;
        if (tok.span.start > tok.span.end) {
            try writeError(gpa, out, format, "InvalidTokenSpan", line_num);
            return false;
        }
        max_end = @max(max_end, tok.span.end);
        try tokens.append(gpa, tok);
    }

    // Parser 以 source.len 钳制所有区间并按相邻词法单元间隙合成 whitespace，
    // 仅从词法单元流解析时填充等长空白占位以保留全部原始字节区间。
    const placeholder_source = try gpa.alloc(u8, max_end);
    defer gpa.free(placeholder_source);
    @memset(placeholder_source, ' ');

    try parseTokens(gpa, placeholder_source, tokens.items, format, output_type, out);
    return true;
}

/// 将词法单元切片送入语法解析器，按 `output_type` 与 `format` 输出事件流或绿树到 `out`。
fn parseTokens(
    gpa: std.mem.Allocator,
    source: []const u8,
    tokens: []const common.Token,
    format: OutputFormat,
    output_type: ParseOutputType,
    out: *Io.Writer,
) !void {
    var parser = frontend.parser.Parser.new(gpa, source, tokens);
    defer parser.deinit();
    try parser.parse();

    switch (output_type) {
        .event => {
            for (parser.events.items) |ev| {
                try writeEvent(gpa, out, format, ev);
            }
        },
        .tree => {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const tree = try frontend.treeBuild(gpa, arena.allocator(), source, parser.events.items);
            try writeTree(gpa, out, format, tree);
        },
    }
}

/// 按 `format` 将构建完成的绿树写入 `out`：`plain` 采用类似 `tree` 的树形文本，`json` 输出单个嵌套 JSON 对象。
/// `tree` 与 `out` 均借用自调用者，本函数不释放它们的内存。
fn writeTree(
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    format: OutputFormat,
    tree: common.GreenTree,
) !void {
    switch (format) {
        .plain => {
            try writeTreeNodeLabelPlain(out, tree.root, 0);
            try out.writeByte('\n');

            var branch_continuations: std.ArrayList(bool) = .empty;
            defer branch_continuations.deinit(gpa);
            try writeTreeChildrenPlain(gpa, out, tree.root, 0, &branch_continuations);
        },
        .json => {
            try writeTreeNodeJson(out, tree.root);
            try out.writeByte('\n');
        },
    }
}

/// 将单个绿树节点的类型、字节区间与可选叶子文本写入 `out`（不含前缀树枝与末尾换行）。
fn writeTreeNodeLabelPlain(
    out: *Io.Writer,
    node: *const common.GreenNode,
    start_offset: u32,
) !void {
    const end_offset = start_offset + node.text_len;
    try out.print("{s} [{d}..{d}]", .{ @tagName(node.kind), start_offset, end_offset });
    if (node.tokenText()) |text| {
        try out.writeByte(' ');
        try writePlainLeafText(out, text);
    }
}

/// 将叶子文本编码为单行带双引号的字符串写入 `out`，确保换行、控制字符与非法字节不破坏树形排版。
fn writePlainLeafText(out: *Io.Writer, text: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(text)) {
        try std.json.Stringify.encodeJsonString(text, .{}, out);
        return;
    }

    try out.writeByte('"');
    for (text) |b| {
        switch (b) {
            '\\' => try out.writeAll("\\\\"),
            '"' => try out.writeAll("\\\""),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try out.writeByte(b),
            else => {
                try out.writeAll("\\x");
                try out.printInt(b, 16, .lower, .{ .width = 2, .fill = '0' });
            },
        }
    }
    try out.writeByte('"');
}

/// 递归以类 `tree` 的框线格式将 `node` 的全部子节点写入 `out`。
/// `node`、`out` 与 `branch_continuations` 均借用自调用者，本函数不释放它们。
fn writeTreeChildrenPlain(
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    node: *const common.GreenNode,
    start_offset: u32,
    branch_continuations: *std.ArrayList(bool),
) !void {
    const children = node.children();
    var child_offset = start_offset;
    for (children, 0..) |child, idx| {
        const is_last = idx + 1 == children.len;
        for (branch_continuations.items) |has_next| {
            try out.writeAll(if (has_next) "│   " else "    ");
        }
        try out.writeAll(if (is_last) "└── " else "├── ");
        try writeTreeNodeLabelPlain(out, child, child_offset);
        try out.writeByte('\n');

        if (!child.isLeaf()) {
            try branch_continuations.append(gpa, !is_last);
            defer _ = branch_continuations.pop();
            try writeTreeChildrenPlain(gpa, out, child, child_offset, branch_continuations);
        }
        child_offset += child.text_len;
    }
}

/// 递归将单个绿树节点以紧凑嵌套 JSON 格式写入 `out`。
/// 直接流式写入以避免 `std.json.Stringify` 固定深度检查对深层语法树的限制。
fn writeTreeNodeJson(out: *Io.Writer, node: *const common.GreenNode) !void {
    try out.writeAll("{\"kind\":");
    try std.json.Stringify.encodeJsonString(@tagName(node.kind), .{}, out);
    try out.print(",\"text_len\":{d}", .{node.text_len});
    switch (node.payload) {
        .leaf => |text| {
            try out.writeAll(",\"text\":");
            try std.json.Stringify.value(text, .{}, out);
        },
        .tree => |children| {
            try out.writeAll(",\"children\":[");
            for (children, 0..) |child, idx| {
                if (idx != 0) try out.writeByte(',');
                try writeTreeNodeJson(out, child);
            }
            try out.writeByte(']');
        },
    }
    try out.writeByte('}');
}

/// 按 `format` 将单个语法解析事件写入 `out`。
fn writeEvent(
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    format: OutputFormat,
    ev: frontend.parser.Event,
) !void {
    switch (format) {
        .plain => switch (ev) {
            .start_node => |kind| try out.print("start_node {s}\n", .{@tagName(kind)}),
            .wrap_node => |kind| try out.print("wrap_node {s}\n", .{@tagName(kind)}),
            .token => |tok| try out.print("token {s} {d} {d}\n", .{
                @tagName(tok.kind),
                tok.range.start,
                tok.range.end,
            }),
            .finish_node => try out.writeAll("finish_node\n"),
            .parse_error => |err| try out.print("parse_error {s} {d} {d}\n", .{
                @tagName(err.code),
                err.range.start,
                err.range.end,
            }),
        },
        .json => {
            const json_line = try std.json.Stringify.valueAlloc(gpa, ev, .{});
            defer gpa.free(json_line);
            try out.writeAll(json_line);
            try out.writeByte('\n');
        },
    }
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

test "parseLexerArgs 校验输入文件数量、帮助参数与 -f/--format 选项" {
    const gpa = std.testing.allocator;

    // 恰好 1 个文件 + --format=plain
    {
        const raw = [_][]const u8{ "--format=plain", "foo.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expect(!bundle.parsed.show_help);
        try std.testing.expectEqual(@as(?OutputFormat, .plain), bundle.parsed.format);
        try std.testing.expectEqual(@as(usize, 1), bundle.parsed.file_count);
        try std.testing.expectEqualStrings("foo.cj", bundle.parsed.file_path.?);
    }

    // -f=json 放在文件路径之后
    {
        const raw = [_][]const u8{ "foo.cj", "-f=json" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(?OutputFormat, .json), bundle.parsed.format);
        try std.testing.expectEqualStrings("foo.cj", bundle.parsed.file_path.?);
    }

    // 空格分隔形式的 -f / --format 与重复指定时后值覆盖前值
    {
        const raw = [_][]const u8{ "-f", "plain", "--format=json", "foo.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseLexerArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(?OutputFormat, .json), bundle.parsed.format);
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

    // 非法 --format 与 -f 值
    for ([_][]const u8{ "--format=xml", "-f=xml" }) |arg| {
        const raw = [_][]const u8{ arg, "a.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        try std.testing.expectError(error.NameNotPartOfEnum, parseLexerArgs(gpa, &iter, &diag));
    }

    // 旧 --output 不再受支持
    {
        const raw = [_][]const u8{ "--output=plain", "a.cj" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        try std.testing.expectError(error.InvalidArgument, parseLexerArgs(gpa, &iter, &diag));
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
    try std.testing.expect(std.mem.indexOf(u8, out, "-f, --format <format>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--output") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<file>...") == null);
}

test "writeParserHelp 展示标准输入默认用法与选项" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeParserHelp(&aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "Usage: cjfrontend parser [options]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-f, --format <format>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-t <type>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--output") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-s, --source-file <file>") != null);
}

test "parseParserArgs 校验帮助参数、-f/--format、-t 与 -s/--source-file 选项" {
    const gpa = std.testing.allocator;

    // 默认无参数：从 stdin 读取，-t 默认为 tree
    {
        const raw = [_][]const u8{};
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseParserArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expect(!bundle.parsed.show_help);
        try std.testing.expectEqual(@as(?OutputFormat, null), bundle.parsed.format);
        try std.testing.expectEqual(ParseOutputType.tree, bundle.parsed.output_type);
        try std.testing.expectEqual(@as(?[]const u8, null), bundle.parsed.source_file);
    }

    // --source-file=path、--format=plain 与 -t event
    {
        const raw = [_][]const u8{ "--source-file=foo.cj", "--format=plain", "-t", "event" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseParserArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(?OutputFormat, .plain), bundle.parsed.format);
        try std.testing.expectEqual(ParseOutputType.event, bundle.parsed.output_type);
        try std.testing.expectEqualStrings("foo.cj", bundle.parsed.source_file.?);
    }

    // -s / -f 简写与 -t=tree
    {
        const raw = [_][]const u8{ "-s", "bar.cj", "-f", "json", "-t=tree" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseParserArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(?OutputFormat, .json), bundle.parsed.format);
        try std.testing.expectEqual(ParseOutputType.tree, bundle.parsed.output_type);
        try std.testing.expectEqualStrings("bar.cj", bundle.parsed.source_file.?);
    }

    // -s=path、-f=plain 与 -t 重复指定时后值覆盖前值
    {
        const raw = [_][]const u8{ "-s=baz.cj", "-f=plain", "-t=event", "-t", "tree" };
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseParserArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expectEqual(@as(?OutputFormat, .plain), bundle.parsed.format);
        try std.testing.expectEqual(ParseOutputType.tree, bundle.parsed.output_type);
        try std.testing.expectEqualStrings("baz.cj", bundle.parsed.source_file.?);
    }

    // -h 与 --help 标志
    for ([_][]const u8{ "-h", "--help" }) |flag| {
        const raw = [_][]const u8{flag};
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        var bundle = try parseParserArgs(gpa, &iter, &diag);
        defer bundle.res.deinit();

        try std.testing.expect(bundle.parsed.show_help);
    }

    // 非法 --format / -f / -t 值
    for ([_][]const u8{ "--format=xml", "-f=xml", "-t=ast" }) |arg| {
        const raw = [_][]const u8{arg};
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        try std.testing.expectError(error.NameNotPartOfEnum, parseParserArgs(gpa, &iter, &diag));
    }

    // 旧 --output 不再受支持
    {
        const raw = [_][]const u8{"--output=json"};
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        try std.testing.expectError(error.InvalidArgument, parseParserArgs(gpa, &iter, &diag));
    }

    // 不接受多余位置参数
    {
        const raw = [_][]const u8{"extra.cj"};
        var iter = clap.args.SliceIterator{ .args = &raw };
        var diag = clap.Diagnostic{};
        try std.testing.expectError(error.InvalidArgument, parseParserArgs(gpa, &iter, &diag));
    }
}

test "parseSource event 模式 plain 与 json 输出可往返反序列化为 Event" {
    const gpa = std.testing.allocator;

    // plain 输出
    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const ok = try parseSource(gpa, "let x = 1\n", .plain, .event, &aw.writer);
        try std.testing.expect(ok);
        const out = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, out, "start_node source_file\n"));
        try std.testing.expect(std.mem.indexOf(u8, out, "start_node var_decl\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "token kw_let 0 3\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "token integer_literal 8 9\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, out, "token eof 10 10\nfinish_node\n"));
    }

    // json 输出逐行反序列化回 Event 并校验开闭平衡
    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const ok = try parseSource(gpa, "let x = 1 + 2", .json, .event, &aw.writer);
        try std.testing.expect(ok);

        var open_count: usize = 0;
        var close_count: usize = 0;
        var saw_wrap = false;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.written(), "\n"), '\n');
        while (lines.next()) |line| {
            const parsed_ev = try std.json.parseFromSlice(frontend.parser.Event, gpa, line, .{});
            defer parsed_ev.deinit();
            switch (parsed_ev.value) {
                .start_node => open_count += 1,
                .wrap_node => {
                    open_count += 1;
                    saw_wrap = true;
                },
                .finish_node => close_count += 1,
                .token, .parse_error => {},
            }
        }
        try std.testing.expect(open_count > 0);
        try std.testing.expectEqual(open_count, close_count);
        try std.testing.expect(saw_wrap);
    }
}

test "parseTokenJsonStream event 模式衔接 lexSource json 输出并保留原始字节区间" {
    const gpa = std.testing.allocator;
    const src = "func add(a: Int64, b: Int64): Int64 { a + b }\n";

    var lex_out: Io.Writer.Allocating = .init(gpa);
    defer lex_out.deinit();
    try std.testing.expect(try lexSource(gpa, src, .json, &lex_out.writer));

    var stream_out: Io.Writer.Allocating = .init(gpa);
    defer stream_out.deinit();
    var reader: Io.Reader = .fixed(lex_out.written());
    try std.testing.expect(try parseTokenJsonStream(gpa, &reader, .json, .event, &stream_out.writer));

    var direct_out: Io.Writer.Allocating = .init(gpa);
    defer direct_out.deinit();
    try std.testing.expect(try parseSource(gpa, src, .json, .event, &direct_out.writer));

    try std.testing.expectEqualStrings(direct_out.written(), stream_out.written());
}

test "parseTokenJsonStream 空输入产出完整空 source_file 事件" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var reader: Io.Reader = .fixed("");

    try std.testing.expect(try parseTokenJsonStream(gpa, &reader, .plain, .event, &aw.writer));
    try std.testing.expectEqualStrings(
        \\start_node source_file
        \\token eof 0 0
        \\finish_node
        \\
    , aw.written());
}

test "parseTokenJsonStream 遇到非法 JSON、上游错误或倒置区间时输出错误" {
    const gpa = std.testing.allocator;

    // 非法 JSON 行
    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var reader: Io.Reader = .fixed("{\"tag\":\"kw_let\",\"span\":{\"start\":0,\"end\":3}}\nnot-json\n");
        const ok = try parseTokenJsonStream(gpa, &reader, .plain, .tree, &aw.writer);
        try std.testing.expect(!ok);
        try std.testing.expectEqualStrings("error: InvalidTokenJson at 2\n", aw.written());
    }

    // 上游 lexer 管道输出错误对象
    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var reader: Io.Reader = .fixed("{\"error\":\"InterpolationDepthExceeded\"}\n");
        const ok = try parseTokenJsonStream(gpa, &reader, .json, .tree, &aw.writer);
        try std.testing.expect(!ok);
        try std.testing.expectEqualStrings("{\"error\":\"InterpolationDepthExceeded\"}\n", aw.written());
    }

    // 倒置 span 区间
    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var reader: Io.Reader = .fixed("{\"tag\":\"kw_let\",\"span\":{\"start\":5,\"end\":2}}\n");
        const ok = try parseTokenJsonStream(gpa, &reader, .plain, .event, &aw.writer);
        try std.testing.expect(!ok);
        try std.testing.expectEqualStrings("error: InvalidTokenSpan at 1\n", aw.written());
    }
}

test "parseSource 词法错误时输出对应错误并返回 false" {
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

    const ok = try parseSource(gpa, src_buf.written(), .json, .tree, &aw.writer);
    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings("{\"error\":\"InterpolationDepthExceeded\"}\n", aw.written());
}

test "parseSource event 模式遇到语法错误时输出 parse_error 事件" {
    const gpa = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const ok = try parseSource(gpa, "let = 1", .plain, .event, &aw.writer);
    try std.testing.expect(ok);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "parse_error ") != null);
}

/// 递归遍历 JSON 语法树并按叶子顺序拼接全部 `text` 字符串，供测试验证无损输出。
fn collectJsonTreeText(gpa: std.mem.Allocator, value: std.json.Value, out: *std.ArrayList(u8)) !void {
    const obj = value.object;
    if (obj.get("text")) |text_val| {
        try out.appendSlice(gpa, text_val.string);
        return;
    }
    const children = obj.get("children").?.array.items;
    for (children) |child| {
        try collectJsonTreeText(gpa, child, out);
    }
}

test "parseSource tree 模式 plain 输出类 tree 框线格式" {
    const gpa = std.testing.allocator;

    // 空输入
    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const ok = try parseSource(gpa, "", .plain, .tree, &aw.writer);
        try std.testing.expect(ok);
        try std.testing.expectEqualStrings(
            \\source_file [0..0]
            \\└── eof [0..0] ""
            \\
        , aw.written());
    }

    // 多层嵌套树与特殊字符转义
    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const ok = try parseSource(gpa, "let x = 1\n", .plain, .tree, &aw.writer);
        try std.testing.expect(ok);
        const out = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, out, "source_file [0..10]\n├── var_decl [0..9]\n"));
        try std.testing.expect(std.mem.indexOf(u8, out, "│   ├── kw_let [0..3] \"let\"\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "├── newline [9..10] \"\\n\"\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, out, "└── eof [10..10] \"\"\n"));
    }
}

test "parseSource tree 模式 json 输出单个嵌套 JSON 并无损还原源码" {
    const gpa = std.testing.allocator;
    const src = "let x = 1 + 2\n";

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const ok = try parseSource(gpa, src, .json, .tree, &aw.writer);
    try std.testing.expect(ok);

    const written = aw.written();
    try std.testing.expect(written.len > 0 and written[written.len - 1] == '\n');
    const trimmed = written[0 .. written.len - 1];
    // 整个输出为单个嵌套 JSON，内部无未转义换行
    try std.testing.expect(std.mem.indexOfScalar(u8, trimmed, '\n') == null);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("source_file", root.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(src.len)), root.get("text_len").?.integer);
    try std.testing.expect(root.get("children").?.array.items.len >= 2);

    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    try collectJsonTreeText(gpa, parsed.value, &rebuilt);
    try std.testing.expectEqualStrings(src, rebuilt.items);
}

test "parseTokenJsonStream tree 模式衔接 lexSource json 输出" {
    const gpa = std.testing.allocator;
    const src = "let x = 1\n";

    var lex_out: Io.Writer.Allocating = .init(gpa);
    defer lex_out.deinit();
    try std.testing.expect(try lexSource(gpa, src, .json, &lex_out.writer));

    // tree + json 输出可正常解析并保留总长度与节点结构
    {
        var tree_json: Io.Writer.Allocating = .init(gpa);
        defer tree_json.deinit();
        var reader: Io.Reader = .fixed(lex_out.written());
        try std.testing.expect(try parseTokenJsonStream(gpa, &reader, .json, .tree, &tree_json.writer));

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            std.mem.trimEnd(u8, tree_json.written(), "\n"),
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;
        try std.testing.expectEqualStrings("source_file", root.get("kind").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(src.len)), root.get("text_len").?.integer);
    }

    // tree + plain 输出包含框线与区间
    {
        var tree_plain: Io.Writer.Allocating = .init(gpa);
        defer tree_plain.deinit();
        var reader: Io.Reader = .fixed(lex_out.written());
        try std.testing.expect(try parseTokenJsonStream(gpa, &reader, .plain, .tree, &tree_plain.writer));
        const out = tree_plain.written();
        try std.testing.expect(std.mem.startsWith(u8, out, "source_file [0..10]\n"));
        try std.testing.expect(std.mem.endsWith(u8, out, "└── eof [10..10] \"\"\n"));
    }
}

test "parseSource tree 模式容忍语法错误与非法 UTF-8 字节" {
    const gpa = std.testing.allocator;

    // 语法错误仍正常建树并输出合法嵌套 JSON
    {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try std.testing.expect(try parseSource(gpa, "let = 1", .json, .tree, &aw.writer));

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            std.mem.trimEnd(u8, aw.written(), "\n"),
            .{},
        );
        defer parsed.deinit();

        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(gpa);
        try collectJsonTreeText(gpa, parsed.value, &rebuilt);
        try std.testing.expectEqualStrings("let = 1", rebuilt.items);
    }

    // 非法 UTF-8 字节在 plain 下转义为单行，在 json 下保持合法 JSON
    {
        const bad_utf8 = [_]u8{ 0xff, '\n' };
        var plain_out: Io.Writer.Allocating = .init(gpa);
        defer plain_out.deinit();
        try std.testing.expect(try parseSource(gpa, &bad_utf8, .plain, .tree, &plain_out.writer));
        try std.testing.expect(std.mem.indexOf(u8, plain_out.written(), "\"\\xff\"") != null);

        var json_out: Io.Writer.Allocating = .init(gpa);
        defer json_out.deinit();
        try std.testing.expect(try parseSource(gpa, &bad_utf8, .json, .tree, &json_out.writer));
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            std.mem.trimEnd(u8, json_out.written(), "\n"),
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectEqualStrings("source_file", parsed.value.object.get("kind").?.string);
    }
}
