// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 仓颉内置注解名称表。

const std = @import("std");

/// 仓颉内置注解名称表，与参考编译器及 `cangjie_spec` 一致。
const builtin_names = std.StaticStringMap(void).initComptime(.{
    .{ "Annotation", {} },
    .{ "Deprecated", {} },
    .{ "When", {} },
    .{ "Frozen", {} },
    .{ "Intrinsic", {} },
    .{ "Attribute", {} },
    .{ "ConstSafe", {} },
    .{ "OverflowThrowing", {} },
    .{ "OverflowWrapping", {} },
    .{ "OverflowSaturating", {} },
    .{ "C", {} },
    .{ "CallingConv", {} },
    .{ "FastNative", {} },
    .{ "Java", {} },
    .{ "JavaMirror", {} },
    .{ "JavaImpl", {} },
    .{ "JavaHasDefault", {} },
    .{ "ObjC", {} },
    .{ "ObjCMirror", {} },
    .{ "ObjCImpl", {} },
    .{ "ObjCInit", {} },
    .{ "ObjCOptional", {} },
    .{ "ForeignName", {} },
    .{ "ForeignGetterName", {} },
    .{ "ForeignSetterName", {} },
    .{ "EnsurePreparedToMock", {} },
    .{ "NonProduct", {} },
});

/// 判定给定标识符文本是否为仓颉内置注解名称。
pub inline fn isBuiltinAnnotationName(name: []const u8) bool {
    return builtin_names.has(name);
}

test "内置注解名称判定" {
    try std.testing.expect(isBuiltinAnnotationName("When"));
    try std.testing.expect(isBuiltinAnnotationName("ObjC"));
    try std.testing.expect(!isBuiltinAnnotationName("when"));
    try std.testing.expect(!isBuiltinAnnotationName("When2"));
    try std.testing.expect(!isBuiltinAnnotationName(""));
    try std.testing.expect(!isBuiltinAnnotationName("自定义注解"));
}
