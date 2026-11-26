// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 供其它项目依赖的公共库。

pub const common = @import("common.zig");
pub const token = @import("token.zig");
pub const syntax = @import("syntax.zig");
pub const source = @import("source.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const parse_error = @import("parse_error.zig");
pub const event = @import("event.zig");
pub const annotation = @import("annotation.zig");
pub const utf8 = @import("utf8.zig");
pub const tree = @import("tree.zig");

pub const Span = common.Span;

pub const TokenTag = token.TokenTag;
pub const Token = token.Token;

pub const SyntaxKind = syntax.SyntaxKind;
pub const toSyntaxKind = syntax.toSyntaxKind;
pub const classifyComment = syntax.classifyComment;
pub const tokenToSyntaxKind = syntax.tokenToSyntaxKind;

pub const ParseErrorCode = parse_error.ParseErrorCode;
pub const ParseError = parse_error.ParseError;

pub const TokenEvent = event.TokenEvent;
pub const Event = event.Event;
pub const CompactEvent = event.CompactEvent;

pub const isBuiltinAnnotationName = annotation.isBuiltinAnnotationName;

pub const Source = source.Source;
pub const FileId = source.FileId;
pub const File = source.File;
pub const FileKind = source.FileKind;
pub const FileExtraInfo = source.FileExtraInfo;
pub const PackageNameConstraint = source.PackageNameConstraint;
pub const FileType = source.FileType;
pub const Edit = source.Edit;
pub const TextRange = source.TextRange;
pub const Position = source.Position;
pub const LineIndex = source.LineIndex;

pub const Severity = diagnostic.Severity;
pub const DiagnosticSource = diagnostic.Source;
pub const RelatedInfo = diagnostic.RelatedInfo;
pub const Diagnostic = diagnostic.Diagnostic;

pub const Codepoint = utf8.Codepoint;

pub const GreenNode = tree.GreenNode;
pub const GreenTree = tree.GreenTree;
pub const SyntaxTree = tree.SyntaxTree;

test {
    _ = common;
    _ = token;
    _ = syntax;
    _ = source;
    _ = diagnostic;
    _ = parse_error;
    _ = event;
    _ = annotation;
    _ = utf8;
    _ = tree;
}
