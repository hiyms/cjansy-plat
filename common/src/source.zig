// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 全局源文件管理：为每个文件分配 FileId，持有内容、附加信息、换行缓存与两个内存池。
//!
//! 文件分为两类：工作区文件允许在程序运行期间通过应用 Edit 变更内容；非工作区文件
//! 通常由磁盘上的真实文件载入，内容在运行期间不变。两类可以相互转换。
//!
//! `Source` 只读取磁盘，从不写回：Edit 只修改内存中的内容，磁盘上的文件保持原样。

const std = @import("std");
const Io = std.Io;

const source_edit = @import("source/Edit.zig");
const source_file = @import("source/File.zig");
const source_line = @import("source/LineIndex.zig");

pub const Edit = source_edit.Edit;
pub const TextRange = source_edit.TextRange;
pub const file = source_file;
pub const line_index = source_line;
pub const File = source_file.File;
pub const FileKind = source_file.FileKind;
pub const FileExtraInfo = source_file.FileExtraInfo;
pub const PackageNameConstraint = source_file.PackageNameConstraint;
pub const FileType = source_file.FileType;
pub const Position = source_line.Position;
pub const LineIndex = source_line.LineIndex;

/// 从磁盘读取单个文件时的内容上限。超过上限的读取返回 `error.StreamTooLong`。
pub const max_file_bytes: usize = 64 * 1024 * 1024;

/// 文件标识。
///
/// `index` 是槽位数组下标，`generation` 是槽位的代次。删除文件时代次递增，旧标识
/// 永远不会指向新文件，因此上层可以安全地把 FileId 存进诊断、断点、符号表等长期
/// 缓存。`FileId` 是 8 字节的值类型，按下标寻址是 O(1)。
pub const FileId = struct {
    index: u32,
    generation: u32,

    /// 占位值，不属于任何槽位。
    pub const invalid: FileId = .{ .index = std.math.maxInt(u32), .generation = 0 };
};

/// `Source` 的错误集合。每个错误对应一个明确的失败点，没有尽力而为的分支。
pub const Error = std.mem.Allocator.Error || error{
    /// FileId 下标越界、代次不符或槽位空。
    InvalidFileId,
    /// 对非工作区文件应用 Edit。
    ReadOnlyFile,
    /// 区间起点大于终点，或终点超出文本长度。
    InvalidRange,
    /// 批量编辑乱序或相交。
    OverlappingEdits,
    /// 行列转换越界。
    InvalidPosition,
    /// 行号越界。
    InvalidLine,
    /// 路径已对应另一个文件。`loadExternal` 走幂等分支，不返回这个错误。
    PathAlreadyRegistered,
    /// 路径不是规范化之后的绝对路径。
    InvalidPath,
    /// 内容或单次编辑结果超过 `u32` 偏移上限。
    TooLarge,
};

const Slot = struct { generation: u32 = 0, file: ?File = null };

/// 代码源。管理若干源文件。
///
/// 槽位数组只增不减，删除时只把槽位置空并压入 `free_slots`，新建优先复用，因此长期
/// 运行不会因反复增删而持续膨胀。
pub const Source = struct {
    gpa: std.mem.Allocator,
    /// 槽位，下标即 `FileId.index`。
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    /// 可复用的空槽位下标。
    free_slots: std.ArrayListUnmanaged(u32) = .empty,
    /// 规范化绝对路径到 FileId 的映射。键与 `File.path` 是同一块内存。
    path_index: std.StringHashMapUnmanaged(FileId) = .empty,
    /// 当前存活的文件数，包含未进入路径索引的工作区文件。
    live_count: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Source {
        return .{ .gpa = gpa };
    }

    /// 释放所有文件的全部堆内存与三个容器本身。
    pub fn deinit(self: *Source) void {
        for (self.slots.items) |*slot| {
            if (slot.file) |*f| f.deinit(self.gpa);
        }
        self.slots.deinit(self.gpa);
        self.free_slots.deinit(self.gpa);
        self.path_index.deinit(self.gpa);
        self.* = undefined;
    }

    /// 查文件。同时校验下标范围、代次相等与槽位占用，任一不符返回 `null`。
    ///
    /// 返回的指针指向槽位内部的 `File`，在下次创建文件（可能重新分配槽位数组）、
    /// `remove` 或 `deinit` 之前有效；内容写入仍然只经过 `applyEdits`。需要跨调用保留
    /// 文件访问时存 FileId，不要缓存指针。
    pub fn get(self: *Source, id: FileId) ?*File {
        if (id.index >= self.slots.items.len) return null;
        const slot = &self.slots.items[id.index];
        if (slot.generation != id.generation) return null;
        return if (slot.file) |*f| f else null;
    }

    fn getOrError(self: *Source, id: FileId) Error!*File {
        return self.get(id) orelse error.InvalidFileId;
    }

    /// 按规范化绝对路径查 FileId，未登记返回 `null`。
    pub fn find(self: *const Source, path: []const u8) ?FileId {
        return self.path_index.get(path);
    }

    /// 当前存活的文件数。
    pub fn count(self: *const Source) usize {
        return self.live_count;
    }

    /// 遍历所有存活的文件，跳过空槽位。产出顺序按槽位下标升序。
    ///
    /// 迭代期间不得创建或删除文件：创建可能重新分配槽位数组，使迭代器持有的
    /// 指针失效。
    pub const Iterator = struct {
        source: *Source,
        index: u32 = 0,

        pub const Item = struct { id: FileId, file: *File };

        pub fn next(self: *Iterator) ?Item {
            while (self.index < self.source.slots.items.len) {
                const slot = &self.source.slots.items[self.index];
                const index = self.index;
                self.index += 1;
                if (slot.file) |*f| return .{
                    .id = .{ .index = index, .generation = slot.generation },
                    .file = f,
                };
            }
            return null;
        }
    };

    pub fn iterator(self: *Source) Iterator {
        return .{ .source = self };
    }

    /// 创建工作区文件，内容立即复制一份。
    ///
    /// `path` 为 null 时不进入路径索引，只能通过 FileId 访问；非 null 时必须是规范化
    /// 之后的绝对路径，且不得已被其他文件占用。`extra` 会被深拷贝，成功后调用方可以
    /// 立即释放传入的那份。
    pub fn addWorkspace(
        self: *Source,
        path: ?[]const u8,
        text: []const u8,
        extra: FileExtraInfo,
    ) Error!FileId {
        return self.addInternal(.workspace, path, text, extra);
    }

    /// 创建非工作区文件，内容由调用方读好后传入。要求与 `addWorkspace` 一致，
    /// 区别在于创建之后内容不再变更。
    pub fn addExternal(
        self: *Source,
        path: []const u8,
        text: []const u8,
        extra: FileExtraInfo,
    ) Error!FileId {
        return self.addInternal(.external, path, text, extra);
    }

    /// 两类文件共同的创建路径。
    ///
    /// 先完成所有可能失败的分配与校验，再把文件放进槽位并登记路径，因此失败时不会
    /// 留下半初始化的槽位。
    fn addInternal(
        self: *Source,
        kind: FileKind,
        path: ?[]const u8,
        text: []const u8,
        extra: FileExtraInfo,
    ) Error!FileId {
        if (path) |p| {
            if (!std.fs.path.isAbsolute(p)) return error.InvalidPath;
            if (self.path_index.contains(p)) return error.PathAlreadyRegistered;
        }
        if (text.len > std.math.maxInt(u32)) return error.TooLarge;

        var f: File = .{
            .kind = kind,
            .extra = try extra.clone(self.gpa),
            .arena = .init(self.gpa),
            .contract_arena = .init(self.gpa),
        };
        errdefer f.deinit(self.gpa);
        try f.text.appendSlice(self.gpa, text);
        if (path) |p| f.path = try self.gpa.dupe(u8, p);

        // 槽位与索引的容量先预留，之后的登记步骤不会失败
        if (self.free_slots.items.len == 0) try self.slots.ensureUnusedCapacity(self.gpa, 1);
        if (path != null) try self.path_index.ensureUnusedCapacity(self.gpa, 1);

        const id = self.takeSlot(f);
        if (f.path) |p| self.path_index.putAssumeCapacity(p, id);
        self.live_count += 1;
        return id;
    }

    /// 从空闲列表或数组末尾取一个槽位，并写入文件。调用前必须已预留槽位容量。
    fn takeSlot(self: *Source, f: File) FileId {
        if (self.free_slots.pop()) |index| {
            const slot = &self.slots.items[index];
            std.debug.assert(slot.file == null);
            slot.file = f;
            return .{ .index = index, .generation = slot.generation };
        }
        const index: u32 = @intCast(self.slots.items.len);
        self.slots.appendAssumeCapacity(.{ .file = f });
        return .{ .index = index, .generation = 0 };
    }

    /// 从磁盘读取并创建非工作区文件。
    ///
    /// `sub_path` 相对 `dir` 解析，用 `realPathFileAlloc` 规范化之后再查路径索引，
    /// 因此 `./a.cj`、`sub/../a.cj` 与绝对路径形式命中同一个文件。同一路径已存在时
    /// 直接返回原 FileId，不读盘，也不接管 `extra`。读取超过 `max_file_bytes` 返回
    /// `error.StreamTooLong`。
    pub fn loadExternal(
        self: *Source,
        io: Io,
        dir: Io.Dir,
        sub_path: []const u8,
        extra: FileExtraInfo,
    ) !FileId {
        const real_path = try dir.realPathFileAlloc(io, sub_path, self.gpa);
        defer self.gpa.free(real_path);

        if (self.path_index.get(real_path)) |id| return id;

        const text = try dir.readFileAlloc(io, real_path, self.gpa, .limited(max_file_bytes));
        defer self.gpa.free(text);

        return self.addInternal(.external, real_path, text, extra);
    }

    /// 删除文件，释放内容、换行缓存、两个内存池、附加信息与路径，并从路径索引中
    /// 移除。
    ///
    /// 槽位保留并递增代次，之后压入空闲列表供复用。删除不会对磁盘产生任何副作用。
    pub fn remove(self: *Source, id: FileId) Error!void {
        const f = try self.getOrError(id);
        try self.free_slots.ensureUnusedCapacity(self.gpa, 1);

        if (f.path) |p| {
            _ = self.path_index.fetchRemove(p);
        }
        f.deinit(self.gpa);

        const slot = &self.slots.items[id.index];
        slot.file = null;
        slot.generation +%= 1;
        self.free_slots.appendAssumeCapacity(id.index);
        self.live_count -= 1;
    }

    /// 当前文本。切片在下次 `applyEdits` 之前有效。
    pub fn content(self: *Source, id: FileId) Error![]const u8 {
        const f = try self.getOrError(id);
        return f.content();
    }

    /// 非工作区文件转为工作区文件，此后可以应用 Edit。
    ///
    /// 只修改可编辑性标志，内容与换行缓存原样保留。已经是工作区文件时是空操作。
    pub fn openForEdit(self: *Source, id: FileId) Error!void {
        const f = try self.getOrError(id);
        f.kind = .workspace;
    }

    /// 工作区文件转为非工作区文件，此后内容冻结。路径关联保留，再次 `loadExternal`
    /// 同一路径返回同一个 FileId 与当前内存内容。
    pub fn freeze(self: *Source, id: FileId) Error!void {
        const f = try self.getOrError(id);
        f.kind = .external;
    }

    /// 应用单条 Edit，等价于只含一条的 `applyEdits`。
    pub fn applyEdit(self: *Source, id: FileId, edit: Edit) Error!void {
        return self.applyEdits(id, &.{edit});
    }

    /// 应用一批 Edit。
    ///
    /// 所有区间都以**调用前**的文本为基准，要求按 `start` 升序且两两不重叠
    /// （`edits[i].end <= edits[i+1].start`）。相邻允许，相交返回
    /// `error.OverlappingEdits`。
    ///
    /// 所有校验与容量预留都在修改之前完成：区间非法、编辑相交、文件非工作区、容量
    /// 不足时，文本与 `version` 均保持不变。预留的容量按倒序应用时的峰值计算，因此
    /// 修改阶段不会分配、不会失败。
    ///
    /// `new_text` 不得指向本文件的内容缓冲（复制自身片段时调用方先拷贝）。
    pub fn applyEdits(self: *Source, id: FileId, edits: []const Edit) Error!void {
        if (edits.len == 0) return;
        const f = try self.getOrError(id);
        if (f.kind != .workspace) return error.ReadOnlyFile;

        const current = f.text.items;
        var net: i64 = 0;
        var min_prefix: i64 = 0;
        var prev_end: u32 = 0;
        for (edits, 0..) |edit, i| {
            if (edit.range.start > edit.range.end or edit.range.end > current.len) return error.InvalidRange;
            if (i > 0 and edit.range.start < prev_end) return error.OverlappingEdits;
            prev_end = edit.range.end;
            std.debug.assert(!overlaps(edit.new_text, current));
            net += @as(i64, @intCast(edit.new_text.len)) - @as(i64, @intCast(edit.range.len()));
            min_prefix = @min(min_prefix, net);
        }

        const final_len = @as(i64, @intCast(current.len)) + net;
        if (final_len > std.math.maxInt(u32)) return error.TooLarge;
        const peak = @as(usize, @intCast(final_len - min_prefix));
        try f.text.ensureTotalCapacity(self.gpa, peak);

        // 倒序应用：每条区间相对原文本的偏移在应用时仍然成立
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const edit = edits[i];
            f.text.replaceRangeAssumeCapacity(edit.range.start, edit.range.len(), edit.new_text);
        }

        f.version +%= 1;
        f.line_index.invalidate(edits[0].range.start);
    }

    /// 总行数。首次调用会扫描整份文本，之后只处理新增部分。
    pub fn lineCount(self: *Source, id: FileId) Error!u32 {
        const f = try self.getOrError(id);
        return f.line_index.lineCount(self.gpa, f.text.items);
    }

    /// 包含 `offset` 的行号。
    pub fn lineOf(self: *Source, id: FileId, offset: u32) Error!u32 {
        const f = try self.getOrError(id);
        return f.line_index.lineOf(self.gpa, f.text.items, offset);
    }

    /// 字节偏移对应的行列。列号按字节计。
    pub fn positionOf(self: *Source, id: FileId, offset: u32) Error!Position {
        const f = try self.getOrError(id);
        return f.line_index.positionOf(self.gpa, f.text.items, offset);
    }

    /// 行列对应的字节偏移，与 `positionOf` 互为逆运算。
    pub fn offsetOf(self: *Source, id: FileId, pos: Position) Error!u32 {
        const f = try self.getOrError(id);
        return f.line_index.offsetOf(self.gpa, f.text.items, pos);
    }

    /// 行区间，半开，包含该行末尾的换行符。
    pub fn lineRange(self: *Source, id: FileId, line: u32) Error!TextRange {
        const f = try self.getOrError(id);
        return f.line_index.lineRange(self.gpa, f.text.items, line);
    }
};

/// 判断两个字节区间是否重叠。`new_text` 指向文件内容时 `replaceRange` 的复制行为
/// 未定义，应用之前用这个函数做调试断言。
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start < b_start + b.len and b_start < a_start + a.len;
}

test {
    _ = source_edit;
    _ = source_file;
    _ = source_line;
}

test "槽位复用之后旧 FileId 失效" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const first = try source.addWorkspace(null, "abc", .{});
    try std.testing.expect(source.get(first) != null);
    try std.testing.expectEqual(@as(usize, 1), source.count());

    try source.remove(first);
    try std.testing.expect(source.get(first) == null);
    try std.testing.expectEqual(@as(usize, 0), source.count());

    const second = try source.addWorkspace(null, "xyz", .{});
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expect(source.get(first) == null);
    try std.testing.expect(source.get(second) != null);
    try std.testing.expectError(error.InvalidFileId, source.content(first));
}

test "内容与附加信息在创建时复制" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "hello");

    var features: std.StringHashMapUnmanaged(bool) = .empty;
    defer features.deinit(gpa);
    const key = try gpa.dupe(u8, "feat");
    try features.put(gpa, key, true);

    const id = try source.addWorkspace(null, text.items, .{ .features = features });

    text.items[0] = 'H';
    features.getPtr("feat").?.* = false;
    gpa.free(key);

    const f = source.get(id).?;
    try std.testing.expectEqualStrings("hello", f.content());
    try std.testing.expectEqual(true, f.extra.features.get("feat").?);
}

test "单条编辑与版本递增" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const id = try source.addWorkspace(null, "abcdef", .{});
    const f = source.get(id).?;

    try source.applyEdit(id, .{ .range = .{ .start = 2, .end = 4 }, .new_text = "XY" });
    try std.testing.expectEqualStrings("abXYef", f.content());
    try std.testing.expectEqual(@as(u32, 1), f.version);

    try source.applyEdit(id, .{ .range = .{ .start = 0, .end = 0 }, .new_text = ">>" });
    try std.testing.expectEqualStrings(">>abXYef", f.content());

    try source.applyEdit(id, .{ .range = .{ .start = 6, .end = 8 }, .new_text = "" });
    try std.testing.expectEqualStrings(">>abXY", f.content());
    try std.testing.expectEqual(@as(u32, 3), f.version);
}

test "批量编辑以调用前文本为基准，先删后增不发生重分配" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const id = try source.addWorkspace(null, "0123456789", .{});
    const f = source.get(id).?;

    try source.applyEdits(id, &.{
        .{ .range = .{ .start = 0, .end = 5 }, .new_text = "" },
        .{ .range = .{ .start = 7, .end = 7 }, .new_text = "ABCDE" },
    });
    try std.testing.expectEqualStrings("56ABCDE789", f.content());
    try std.testing.expectEqual(@as(u32, 1), f.version);
}

test "编辑失败不改变内容与版本" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const id = try source.addWorkspace(null, "abcdef", .{});
    const f = source.get(id).?;

    try std.testing.expectError(error.InvalidRange, source.applyEdit(id, .{ .range = .{ .start = 4, .end = 2 }, .new_text = "x" }));
    try std.testing.expectError(error.InvalidRange, source.applyEdit(id, .{ .range = .{ .start = 0, .end = 7 }, .new_text = "x" }));
    try std.testing.expectError(error.OverlappingEdits, source.applyEdits(id, &.{
        .{ .range = .{ .start = 0, .end = 3 }, .new_text = "x" },
        .{ .range = .{ .start = 2, .end = 4 }, .new_text = "y" },
    }));
    try std.testing.expectEqualStrings("abcdef", f.content());
    try std.testing.expectEqual(@as(u32, 0), f.version);
}

test "空编辑序列不做任何事" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const id = try source.addWorkspace(null, "abc", .{});
    try source.applyEdits(id, &.{});
    try std.testing.expectEqual(@as(u32, 0), source.get(id).?.version);
}

test "两个内存池不随编辑清空" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const id = try source.addWorkspace(null, "let a = 1;\n", .{});
    const f = source.get(id).?;

    const scratch = try f.allocator().dupe(u8, "scratch");
    const nodes = try f.contractAlloc(u32, 2);
    nodes[0] = 11;
    nodes[1] = 13;
    const name = try f.contractDupe(u8, "Drawable");
    const empty = try f.contractDupe(u8, "");

    try source.applyEdits(id, &.{
        .{ .range = .{ .start = 0, .end = 3 }, .new_text = "var" },
        .{ .range = .{ .start = 8, .end = 9 }, .new_text = "2" },
    });

    // 新建文件可能重新分配槽位数组，两个内存池里已经写入的内容仍然有效
    _ = try source.addWorkspace(null, "let b = 2;\n", .{});

    try std.testing.expectEqualStrings("var a = 2;\n", try source.content(id));
    try std.testing.expectEqualStrings("scratch", scratch);
    try std.testing.expectEqualStrings("Drawable", name);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqualSlices(u32, &.{ 11, 13 }, nodes);
}

test "删除文件释放两个内存池" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const id = try source.addWorkspace(null, "abc", .{});
    const f = source.get(id).?;
    _ = try f.allocator().dupe(u8, "internal");
    _ = try f.contractDupe(u8, "contract");
    try source.remove(id);
}

test "两类文件相互转换" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const external = try source.addExternal("/virtual/a.cj", "abc", .{});
    try std.testing.expectEqual(FileKind.external, source.get(external).?.kind);
    try std.testing.expectError(error.ReadOnlyFile, source.applyEdit(external, .{ .range = TextRange.zero, .new_text = "x" }));

    try source.openForEdit(external);
    try std.testing.expectEqual(FileKind.workspace, source.get(external).?.kind);
    try source.applyEdit(external, .{ .range = TextRange.zero, .new_text = "x" });
    try std.testing.expectEqualStrings("xabc", try source.content(external));

    try source.freeze(external);
    try std.testing.expectEqual(FileKind.external, source.get(external).?.kind);
    try std.testing.expectError(error.ReadOnlyFile, source.applyEdit(external, .{ .range = TextRange.zero, .new_text = "y" }));
    try std.testing.expectEqualStrings("xabc", try source.content(external));

    try source.openForEdit(external);
    try source.openForEdit(external);
    try std.testing.expectEqualStrings("xabc", try source.content(external));
}

test "路径索引与重复登记" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    try std.testing.expectError(error.InvalidPath, source.addExternal("rel/a.cj", "abc", .{}));

    const id = try source.addExternal("/virtual/b.cj", "abc", .{});
    try std.testing.expectEqual(id, source.find("/virtual/b.cj").?);
    try std.testing.expectError(error.PathAlreadyRegistered, source.addWorkspace("/virtual/b.cj", "x", .{}));

    try source.remove(id);
    try std.testing.expect(source.find("/virtual/b.cj") == null);
    const again = try source.addExternal("/virtual/b.cj", "abc", .{});
    try std.testing.expect(again.generation != id.generation);
}

test "从磁盘加载并重复命中" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.cj", .data = "let x = 1\n" });

    const first = try source.loadExternal(std.testing.io, tmp.dir, "a.cj", .{});
    try std.testing.expectEqualStrings("let x = 1\n", try source.content(first));
    try std.testing.expectEqual(FileKind.external, source.get(first).?.kind);

    const second = try source.loadExternal(std.testing.io, tmp.dir, "./a.cj", .{});
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), source.count());
}

test "换行缓存与编辑联动" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const id = try source.addWorkspace(null, "ab\ncd\nef", .{});
    try std.testing.expectEqual(@as(u32, 3), try source.lineCount(id));
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 3 }, try source.lineRange(id, 0));
    try std.testing.expectEqual(TextRange{ .start = 3, .end = 6 }, try source.lineRange(id, 1));
    try std.testing.expectEqual(TextRange{ .start = 6, .end = 8 }, try source.lineRange(id, 2));
    try std.testing.expectEqual(Position{ .line = 1, .column = 1 }, try source.positionOf(id, 4));
    try std.testing.expectEqual(@as(u32, 1), try source.lineOf(id, 4));
    try std.testing.expectError(error.InvalidPosition, source.lineOf(id, 9));

    try source.applyEdit(id, .{ .range = .{ .start = 2, .end = 3 }, .new_text = "\n\n" });
    try std.testing.expectEqual(@as(u32, 4), try source.lineCount(id));
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 3 }, try source.lineRange(id, 0));
    try std.testing.expectEqual(TextRange{ .start = 3, .end = 4 }, try source.lineRange(id, 1));
    try std.testing.expectEqual(TextRange{ .start = 4, .end = 7 }, try source.lineRange(id, 2));
    try std.testing.expectEqual(TextRange{ .start = 7, .end = 9 }, try source.lineRange(id, 3));
    try std.testing.expectEqual(Position{ .line = 2, .column = 0 }, try source.positionOf(id, 4));
    try std.testing.expectEqual(@as(u32, 4), try source.offsetOf(id, .{ .line = 2, .column = 0 }));
}

test "迭代器跳过空槽位" {
    const gpa = std.testing.allocator;
    var source = Source.init(gpa);
    defer source.deinit();

    const a = try source.addWorkspace(null, "a", .{});
    const b = try source.addWorkspace(null, "b", .{});
    const c = try source.addWorkspace(null, "c", .{});
    try source.remove(b);

    var it = source.iterator();
    var seen: usize = 0;
    var ids: [2]FileId = undefined;
    while (it.next()) |item| : (seen += 1) {
        ids[seen] = item.id;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expectEqual(a, ids[0]);
    try std.testing.expectEqual(c, ids[1]);
}

test "创建文件在任意分配失败点上不泄漏" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createWithEverything, .{});
}

fn createWithEverything(gpa: std.mem.Allocator) !void {
    var source = Source.init(gpa);
    defer source.deinit();

    const key = try gpa.dupe(u8, "feat");
    defer gpa.free(key);
    var features: std.StringHashMapUnmanaged(bool) = .empty;
    defer features.deinit(gpa);
    try features.put(gpa, key, true);

    const sub = try gpa.alloc([]const u8, 1);
    defer gpa.free(sub);
    sub[0] = "inner";

    const id = try source.addExternal("/virtual/c.cj", "let x = 1\n", .{
        .requirePackageName = .{ .org = "org", .root_package = "root", .sub_package = sub },
        .features = features,
    });

    try std.testing.expectEqualStrings("let x = 1\n", try source.content(id));
    try std.testing.expectEqual(id, source.find("/virtual/c.cj").?);
    try std.testing.expectEqual(@as(usize, 1), source.count());
    try std.testing.expectEqual(@as(u32, 2), try source.lineCount(id));

    try source.remove(id);
    try std.testing.expectEqual(@as(usize, 0), source.count());
}

pub const t = Source;
