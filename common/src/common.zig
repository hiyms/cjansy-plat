// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 公共库中与具体词法单元无关的通用定义。

const std = @import("std");

/// 源文件中的字节区间，`start` 与 `end` 是相对于文件起始的偏移量，区间左闭右开。
pub const Span = struct {
    start: u32,
    end: u32,
};

/// 解析器前端与公共库之间的通用错误集合。
pub const ParseError = error{ UnexpectedToken, UnexpectedEndOfInput, InvalidCharacter, UnsupportFeature };
