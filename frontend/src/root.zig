// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 解析器前端的库入口，供 `cjfrontend` 以及其它项目依赖。

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const tree = @import("tree.zig");

pub const GreenBuilder = tree.GreenBuilder;
pub const treeBuild = tree.treeBuild;

test {
    _ = @import("./lexer.zig");
    _ = @import("./parser.zig");
    _ = @import("./tree.zig");
}
