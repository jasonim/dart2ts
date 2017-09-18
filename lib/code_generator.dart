import 'dart:async';
import 'dart:io';
import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:args/command_runner.dart';
import 'package:logging/logging.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:build_runner/build_runner.dart';
import 'package:path/path.dart' as path;

Logger _logger = new Logger('dart2ts.lib.code_generator');

class Dart2TsCommand extends Command<bool> {
  @override
  String get description => "Build a file";

  @override
  String get name => 'build';

  Dart2TsCommand() {
    this.argParser.addOption('dir',
        defaultsTo: '.',
        abbr: 'd',
        help: 'the base path of the package to process');
  }

  @override
  void run() {
    PackageGraph graph = new PackageGraph.forPath(argResults['dir']);

    build([new BuildAction(new Dart2TsBuilder(), graph.root.name)],
        packageGraph: graph, onLog: (_) {}, deleteFilesByDefault: true);
  }
}

class Dart2TsCommandRunner extends CommandRunner<bool> {
  Dart2TsCommandRunner() : super('dart2ts', 'a better interface to TS') {
    addCommand(new Dart2TsCommand());
  }
}

Builder dart2TsBuilder() {
  return new Dart2TsBuilder();
}

/// A [Builder] wrapping on one or more [Generator]s.
abstract class _BaseBuilder extends Builder {
  /// Wrap [_generators] to form a [Builder]-compatible API.
  _BaseBuilder() {}

  @override
  Future build(BuildStep buildStep) async {
    var resolver = buildStep.resolver;
    if (!await resolver.isLibrary(buildStep.inputId)) return;
    var lib = await buildStep.inputLibrary;
    await generateForLibrary(lib, buildStep);
  }

  Future generateForLibrary(LibraryElement library, BuildStep buildStep);

  @override
  Map<String, List<String>> get buildExtensions => {
        '.dart': ['.ts']
      };
}

class Dart2TsBuilder extends _BaseBuilder {
  @override
  Future generateForLibrary(LibraryElement library, BuildStep buildStep) async {
    AssetId destId = new AssetId(buildStep.inputId.package,
        "${path.withoutExtension(buildStep.inputId.path)}.ts");
    _logger.fine('Processing ${library.location} for ${destId}');
    StringBuffer sink = new StringBuffer();
    Dart2TsVisitor visitor = new Dart2TsVisitor(sink);

    library.unit.accept(visitor);
    //visitor.visitAllNodes(library.unit);

    _logger.fine("Produced : ${sink.toString()}");

    await buildStep.writeAsString(destId, sink.toString());
  }
}

class Dart2TsVisitor extends GeneralizingAstVisitor<dynamic> {
  StringSink _consumer;
  FileContext _context;
  Dart2TsVisitor(this._consumer);

  @override
  visitCompilationUnit(CompilationUnit node) {
    _context = new FileContext(node.element.library);
    _consumer.writeln('// Generated code');
    super.visitCompilationUnit(node);
    _context._prefixes.values.forEach((i)=>_consumer.writeln('import * as ${i.prefix} from "${i.path}";'));
  }

  @override
  visitFunctionDeclaration(FunctionDeclaration node) {
   _consumer.write(node.accept(new _ExpressionBuilderVisitor(_context)));
  }

}

class _ExpressionBuilderVisitor extends GeneralizingAstVisitor<String> {
  _ExpressionBuilderVisitor(this._context);


  @override
  String visitFunctionDeclaration(FunctionDeclaration node) {
    String res = "function ${node.functionExpression.element?.name??''}${node.functionExpression.parameters.accept(this)}${node.functionExpression.body.accept(this)}";

    if (node.element.enclosingElement==_context._current.definingCompilationUnit) {
      return 'export ${res}';
    }
    return res;
  }


  @override
  String visitFunctionDeclarationStatement(FunctionDeclarationStatement node) => '${node.functionDeclaration.accept(this)}';

  @override
  String visitSimpleStringLiteral(SimpleStringLiteral node) {
    return node.literal.toString();
  }

  @override
  String visitSimpleIdentifier(SimpleIdentifier node) {
    return node.name;
  }

  @override
  String visitFunctionExpression(FunctionExpression node) {
    if (node.element is FunctionElement) {
      return "${node.element.name}${node.parameters.accept(this)} => ${node.body.accept(this)}";
    }

    return "/* TODO : ${node.element.toString()}*/";
  }

  FunctionElement _findEnclosingFunction(AstNode node) {
    if (node is FunctionExpression) {
      return node.element;
    }
    return _findEnclosingFunction(node.parent);
  }

  FileContext _context;

  String _resolve(Element ele,{FunctionElement from}) {
    if (ele.library==from.library) {
      return ele.name;
    }

    return "${_context.namespace(ele.library)}.${ele.name}";
  }


  @override
  String visitMethodInvocation(MethodInvocation node) {
    // get the function name for ts
    FunctionElement el = _findEnclosingFunction(node);

    String reference = _resolve(node.methodName.staticElement,from:el);
    
    return "${reference}${node.argumentList.accept(this)}";
  }

  @override
  String visitReturnStatement(ReturnStatement node) =>
      "return ${node.expression.accept(this)};";

  @override
  String visitBlockFunctionBody(BlockFunctionBody node) =>
      node.block.accept(this);


  @override
  String visitExpressionStatement(ExpressionStatement node) => "${node.expression.accept(this)};";

  @override
  String visitBlock(Block node) =>
      "{${node.statements.map((s)=>s.accept(this)).join('\n')}}";

  @override
  String visitExpressionFunctionBody(ExpressionFunctionBody node) =>
      "${node.expression.accept(this)}";

  @override
  String visitSimpleFormalParameter(SimpleFormalParameter node) =>
      "${node.identifier} : ${toTsType(node.type)}";

  @override
  String visitTypeName(TypeName node) => toTsType(node);

  @override
  String visitFormalParameterList(FormalParameterList node) {
    return "(${node.parameters.map((p)=>p.accept(this)).join(',')})";
  }

  @override
  String visitParenthesizedExpression(ParenthesizedExpression node) =>
      "(${node.expression.accept(this)})";

  @override
  String visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    return "${node.function.accept(this)} ${node.argumentList.accept(this)}";
  }

  @override
  String visitArgumentList(ArgumentList node) {
    return "(${node.arguments.map((e)=>e.accept(this)).join(',')})";
  }

  @override
  String visitStringInterpolation(StringInterpolation node) =>
      "`${node.elements.map((e)=>e.accept(this)).join()}`";

  @override
  String visitInterpolationExpression(InterpolationExpression node) =>
      "\${${node.expression.accept(this)}}";

  @override
  String visitInterpolationString(InterpolationString node) => node.value;
}

class _TypeNameVisitor extends GeneralizingAstVisitor<String> {
  @override
  String visitTypeName(TypeName node) {
    return toTsType(node);
  }

  @override
  String visitTypeAnnotation(TypeAnnotation node) {
    return super.visitTypeAnnotation(node);
  }
}

class _TypeArgumentListVisitor extends GeneralizingAstVisitor<String> {
  @override
  String visitTypeArgumentList(TypeArgumentList node) {
    if (node?.arguments == null) {
      return "";
    }
    _TypeNameVisitor v = new _TypeNameVisitor();
    return "<${node.arguments.map((x)=> x.accept(v)).join(',')}>";
  }
}

String toTsType(TypeName annotation) {
  // Todo : check it better if it's a  list
  String actualName;
  if (annotation == null) {
    actualName = "any";
  } else if (annotation.name.name == 'List') {
    actualName = 'Array';
  } else {
    actualName = annotation.name.name;
  }
  String res =
      "${actualName}${annotation?.typeArguments?.accept(new _TypeArgumentListVisitor())??''}";
  return res;
}


class TSImport {
  String prefix;
  String path;
  LibraryElement library;

  TSImport({this.prefix,this.path,this.library});
}

class FileContext {
  LibraryElement _current;
  FileContext(this._current);
  Map<String,TSImport> _prefixes = {};

  String _nextPrefix() => "lib${_prefixes.length}";

  AssetId _toAssetId(String uri) {
    if (uri.startsWith('asset:')) {
      List<String> parts = path.split(uri.substring(7));
      return new AssetId(parts.first, path.joinAll(parts.sublist(1)));
    }
    throw "Cannot convert to assetId : ${uri}";
  }

  String namespace(LibraryElement lib) {
    String uri = lib.source.uri.toString();

    AssetId currentId = _toAssetId(_current.source.uri.toString());
    return _prefixes.putIfAbsent(uri, () {
      if (_current.context.sourceFactory.dartSdk.uris.contains(uri)) {
        // Replace with ts_sdk
        return new TSImport(prefix:_nextPrefix(),path:"./dart_sdk/${lib.name.substring(5)}",library: lib);
      }

      // TODO : If same package produce a relative path

      AssetId id = _toAssetId(uri);

      String libPath;

      if (id.package==currentId.package) {
        libPath = "./${path.withoutExtension(path.relative(id.path,from:path.dirname(currentId.path)))}";
      }

      // TODO : Extract package name and path and produce a nodemodule path
      return new TSImport(prefix: _nextPrefix(),path:libPath,library: lib);

    }).prefix;
  }
}

