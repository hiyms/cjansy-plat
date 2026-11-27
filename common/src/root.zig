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
pub const hir = @import("hir.zig");

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
pub const LocatedGreen = tree.LocatedGreen;
pub const GreenTree = tree.GreenTree;
pub const SyntaxTree = tree.SyntaxTree;
pub const QueryContext = tree.QueryContext;
pub const RedNode = tree.RedNode;
pub const AncestorIter = tree.AncestorIter;
pub const GreenTraversal = tree.GreenTraversal;

pub const BinaryOp = hir.BinaryOp;
pub const AssignOp = hir.AssignOp;
pub const UnaryOp = hir.UnaryOp;
pub const IncDecOp = hir.IncDecOp;
pub const JumpOp = hir.JumpOp;

pub const Name = hir.Name;
pub const Modifier = hir.Modifier;
pub const Annotation = hir.Annotation;
pub const IntSuffix = hir.IntSuffix;
pub const FloatSuffix = hir.FloatSuffix;
pub const BindingKind = hir.BindingKind;
pub const StrKind = hir.StrKind;

pub const TypePathSegment = hir.TypePathSegment;
pub const PathType = hir.PathType;
pub const HirTypeElement = hir.HirTypeElement;
pub const OptionalType = hir.OptionalType;
pub const TupleType = hir.TupleType;
pub const FuncType = hir.FuncType;
pub const VArrayType = hir.VArrayType;
pub const ThisType = hir.ThisType;
pub const HirType = hir.HirType;

pub const IntLit = hir.IntLit;
pub const FloatLit = hir.FloatLit;
pub const RuneLit = hir.RuneLit;
pub const StringLit = hir.StringLit;
pub const StrText = hir.StrText;
pub const StrInterpolation = hir.StrInterpolation;
pub const StrPart = hir.StrPart;
pub const StrInterp = hir.StrInterp;
pub const BoolLit = hir.BoolLit;
pub const Bare = hir.Bare;

pub const ExprPathSegment = hir.ExprPathSegment;
pub const PathExpr = hir.PathExpr;
pub const FieldExpr = hir.FieldExpr;
pub const OptionalExpr = hir.OptionalExpr;
pub const HirCallArg = hir.HirCallArg;
pub const CallExpr = hir.CallExpr;
pub const IndexExpr = hir.IndexExpr;
pub const IncDecExpr = hir.IncDecExpr;
pub const UnaryExpr = hir.UnaryExpr;
pub const BinaryExpr = hir.BinaryExpr;
pub const AssignExpr = hir.AssignExpr;
pub const RangeExpr = hir.RangeExpr;
pub const IsExpr = hir.IsExpr;
pub const AsExpr = hir.AsExpr;
pub const TypeConvExpr = hir.TypeConvExpr;
pub const VArrayExpr = hir.VArrayExpr;
pub const TupleLit = hir.TupleLit;
pub const ArrayElement = hir.ArrayElement;
pub const ArrayLit = hir.ArrayLit;
pub const BlockExpr = hir.BlockExpr;
pub const LetDestructor = hir.LetDestructor;
pub const HirCondition = hir.HirCondition;
pub const IfExpr = hir.IfExpr;
pub const PatternCase = hir.PatternCase;
pub const ExprCase = hir.ExprCase;
pub const MatchCase = hir.MatchCase;
pub const MatchExpr = hir.MatchExpr;
pub const WhileExpr = hir.WhileExpr;
pub const DoWhileExpr = hir.DoWhileExpr;
pub const ForInExpr = hir.ForInExpr;
pub const Resource = hir.Resource;
pub const CatchClause = hir.CatchClause;
pub const HandleClause = hir.HandleClause;
pub const TryClause = hir.TryClause;
pub const TryExpr = hir.TryExpr;
pub const ThrowExpr = hir.ThrowExpr;
pub const ReturnExpr = hir.ReturnExpr;
pub const JumpExpr = hir.JumpExpr;
pub const LambdaExpr = hir.LambdaExpr;
pub const SpawnExpr = hir.SpawnExpr;
pub const SynchronizedExpr = hir.SynchronizedExpr;
pub const UnsafeExpr = hir.UnsafeExpr;
pub const QuoteExpr = hir.QuoteExpr;
pub const QuotePart = hir.QuotePart;
pub const MacroCall = hir.MacroCall;
pub const MacroCallExpr = hir.MacroCallExpr;
pub const IfAvailableExpr = hir.IfAvailableExpr;
pub const PerformExpr = hir.PerformExpr;
pub const ResumeModifier = hir.ResumeModifier;
pub const ResumeExpr = hir.ResumeExpr;
pub const HirExpr = hir.HirExpr;

pub const WildcardPattern = hir.WildcardPattern;
pub const BindingPattern = hir.BindingPattern;
pub const ConstPattern = hir.ConstPattern;
pub const TuplePattern = hir.TuplePattern;
pub const EnumPattern = hir.EnumPattern;
pub const TypePattern = hir.TypePattern;
pub const ClausePattern = hir.ClausePattern;
pub const HirPattern = hir.HirPattern;

pub const Binding = hir.Binding;
pub const ExprStmt = hir.ExprStmt;
pub const HirStmt = hir.HirStmt;

pub const HirParam = hir.HirParam;
pub const ParamMacro = hir.ParamMacro;
pub const Param = hir.Param;
pub const FuncName = hir.FuncName;
pub const GenericConstraint = hir.GenericConstraint;
pub const WhereClause = hir.WhereClause;

pub const FuncItem = hir.FuncItem;
pub const MainItem = hir.MainItem;
pub const ClassItem = hir.ClassItem;
pub const StructItem = hir.StructItem;
pub const EnumConstructor = hir.EnumConstructor;
pub const EnumPayloadType = hir.EnumPayloadType;
pub const EnumPayloadElement = hir.EnumPayloadElement;
pub const VariantMacro = hir.VariantMacro;
pub const EnumVariant = hir.EnumVariant;
pub const EnumItem = hir.EnumItem;
pub const InterfaceItem = hir.InterfaceItem;
pub const ExtendItem = hir.ExtendItem;
pub const PropAccessor = hir.PropAccessor;
pub const PropItem = hir.PropItem;
pub const TypeAliasItem = hir.TypeAliasItem;
pub const InitItem = hir.InitItem;
pub const FinalizerItem = hir.FinalizerItem;
pub const PrimaryCtorItem = hir.PrimaryCtorItem;
pub const MacroItem = hir.MacroItem;
pub const MacroExpandItem = hir.MacroExpandItem;
pub const ForeignItem = hir.ForeignItem;
pub const ImportAlias = hir.ImportAlias;
pub const ImportKind = hir.ImportKind;
pub const ImportItem = hir.ImportItem;
pub const PackageHeader = hir.PackageHeader;
pub const FeatureId = hir.FeatureId;
pub const FeaturesDirective = hir.FeaturesDirective;
pub const HirItem = hir.HirItem;
pub const HirFile = hir.HirFile;

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
    _ = hir;
}
