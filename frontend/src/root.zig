// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 解析器前端的库入口，供 `cjfrontend` 以及其它项目依赖。

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const tree = @import("tree.zig");
pub const lower = @import("lower.zig");

pub const GreenBuilder = tree.GreenBuilder;
pub const treeBuild = tree.treeBuild;
pub const Lowerer = lower.Lowerer;
pub const LoweredItem = lower.LoweredItem;
pub const LoweredFile = lower.LoweredFile;
pub const lowerItem = lower.lowerItem;
pub const lowerFile = lower.lowerFile;

test {
    _ = @import("./lexer.zig");
    _ = @import("./parser.zig");
    _ = @import("./tree.zig");
    _ = @import("./lower.zig");
}
