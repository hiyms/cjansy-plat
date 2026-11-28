// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 面向消费端的轻量级只读语法树节点视图（`SyntaxNode`）。

const common = @import("common");

/// 轻量级只读语法树节点视图（借用自 `FileQueryState.ast_hir_arena`，不跨 `Database.updateFile` 持有，调用者不得释放）。
pub const SyntaxNode = struct {
    green: *const common.GreenNode,
    file: common.FileId,
    version: u32,
    offset: u32,

    /// 获取节点语法标签。
    pub inline fn kind(self: SyntaxNode) common.SyntaxKind {
        return self.green.kind;
    }

    /// 获取节点覆盖的左闭右开源码字节区间。
    pub inline fn range(self: SyntaxNode) common.TextRange {
        return .{ .start = self.offset, .end = self.offset + self.green.text_len };
    }

    /// 判定当前节点是否为叶子词法单元。
    pub inline fn isLeaf(self: SyntaxNode) bool {
        return self.green.isLeaf();
    }

    /// 获取叶子节点文本切片（内部节点返回 `null`）；借用自 `ast_hir_arena`，调用者不得释放。
    pub inline fn tokenText(self: SyntaxNode) ?[]const u8 {
        return self.green.tokenText();
    }

    /// 获取直接子节点个数（叶子返回 `0`）。
    pub inline fn childCount(self: SyntaxNode) usize {
        return self.green.childCount();
    }

    /// 按下标获取直接子节点视图；越界返回 `null`。
    pub fn childAt(self: SyntaxNode, index: usize) ?SyntaxNode {
        const list = self.green.children();
        if (index >= list.len) return null;
        var cur = self.offset;
        for (list[0..index]) |child| cur += child.text_len;
        return .{
            .green = list[index],
            .file = self.file,
            .version = self.version,
            .offset = cur,
        };
    }

    /// 创建遍历直接子节点的轻量迭代器（无堆内存分配）。
    pub inline fn children(self: SyntaxNode) ChildIter {
        return .{ .parent = self, .cur_offset = self.offset };
    }

    /// 遍历直接子节点的顺序迭代器。
    pub const ChildIter = struct {
        parent: SyntaxNode,
        idx: usize = 0,
        cur_offset: u32,

        /// 返回下一个子节点视图；遍历完毕返回 `null`。
        pub fn next(self: *ChildIter) ?SyntaxNode {
            const list = self.parent.green.children();
            if (self.idx >= list.len) return null;
            const child = list[self.idx];
            const node: SyntaxNode = .{
                .green = child,
                .file = self.parent.file,
                .version = self.parent.version,
                .offset = self.cur_offset,
            };
            self.idx += 1;
            self.cur_offset += child.text_len;
            return node;
        }
    };
};
