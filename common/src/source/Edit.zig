//! 文本区间与单次修改的描述。编辑只影响内存中的文本，不触碰磁盘文件。

const std = @import("std");

/// 源文件中的字节区间，左闭右开。
///
/// 所有偏移都是相对于所属文件起点的字节偏移，`start == end` 表示一个空区间，可以用作
/// 插入位置。
pub const TextRange = struct {
    start: u32, // 半开区间起点，包含
    end: u32, // 半开区间终点，不包含

    /// 空区间，作为插入的默认位置。
    pub const zero: TextRange = .{ .start = 0, .end = 0 };

    /// 区间覆盖的字节数。要求 `start <= end`。
    pub fn len(self: TextRange) u32 {
        return self.end - self.start;
    }

    pub fn isEmpty(self: TextRange) bool {
        return self.start == self.end;
    }

    /// 半开区间的成员判定：`start` 在内，`end` 不在内。
    pub fn contains(self: TextRange, offset: u32) bool {
        return self.start <= offset and offset < self.end;
    }
};

/// 描述单次修改内容：把 `range` 覆盖的旧文本换成 `new_text`。
///
/// `range` 以应用这一批 Edit 之前的文本为基准。`new_text` 不得指向被编辑文件的内容
/// 缓冲，需要引用自身片段时调用方先复制。
pub const Edit = struct { range: TextRange, new_text: []const u8 };
