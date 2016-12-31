library angel_framework.http.controller;

import 'dart:async';
import 'dart:mirrors';
import 'package:angel_route/angel_route.dart';
import 'angel_http_exception.dart';
import 'metadata.dart';
import 'request_context.dart';
import 'response_context.dart';
import 'routable.dart';
import 'server.dart' show Angel;

/// Contains a list of the data required for a DI-enabled method to run.
///
/// This improves performance by removing the necessity to reflect a method
/// every time it is requested.
///
/// Regular request handlers can also skip DI entirely, lowering response time
/// and memory use.
class InjectionRequest {
  /// A list of the data required for a DI-enabled method to run.
  final List required = [];
}

/// Supports grouping routes with shared functionality.
class Controller {
  Angel _app;

  Angel get app => _app;
  final bool debug;
  List middleware = [];
  Map<String, Route> routeMappings = {};
  Expose exposeDecl;

  Controller({this.debug: false});

  Future call(Angel app) async {
    _app = app;

    // Load global expose decl
    ClassMirror classMirror = reflectClass(this.runtimeType);
    Expose exposeDecl = classMirror.metadata
        .map((m) => m.reflectee)
        .firstWhere((r) => r is Expose, orElse: () => null);

    if (exposeDecl == null) {
      throw new Exception(
          "All controllers must carry an @Expose() declaration.");
    }

    var routable = new Routable(debug: debug);

    app.use(exposeDecl.path, routable);
    TypeMirror typeMirror = reflectType(this.runtimeType);
    String name = exposeDecl.as?.isNotEmpty == true
        ? exposeDecl.as
        : MirrorSystem.getName(typeMirror.simpleName);

    app.controllers[name] = this;

    // Pre-reflect methods
    InstanceMirror instanceMirror = reflect(this);
    final handlers = []..addAll(exposeDecl.middleware)..addAll(middleware);
    final routeBuilder = _routeBuilder(instanceMirror, routable, handlers);
    classMirror.instanceMembers.forEach(routeBuilder);
    configureRoutes(routable);
  }

  Function _routeBuilder(
      InstanceMirror instanceMirror, Routable routable, List handlers) {
    return (Symbol methodName, MethodMirror method) {
      if (method.isRegularMethod &&
          methodName != #toString &&
          methodName != #noSuchMethod &&
          methodName != #call &&
          methodName != #equals &&
          methodName != #==) {
        Expose exposeDecl = method.metadata
            .map((m) => m.reflectee)
            .firstWhere((r) => r is Expose, orElse: () => null);

        if (exposeDecl == null) return;

        var reflectedMethod = instanceMirror.getField(methodName).reflectee;
        var middleware = []..addAll(handlers)..addAll(exposeDecl.middleware);
        var injection = new InjectionRequest();

        // Check if normal
        if (method.parameters.length == 2 &&
            method.parameters[0].type.reflectedType == RequestContext &&
            method.parameters[1].type.reflectedType == ResponseContext) {
          // Create a regular route
          routable.addRoute(exposeDecl.method, exposeDecl.path, reflectedMethod,
              middleware: middleware);
          return;
        }

        // Load parameters
        for (var parameter in method.parameters) {
          var name = MirrorSystem.getName(parameter.simpleName);
          var type = parameter.type.reflectedType;

          if (type == RequestContext || type == ResponseContext) {
            injection.required.add(type);
          } else if (name == 'req') {
            injection.required.add(RequestContext);
          } else if (name == 'res') {
            injection.required.add(ResponseContext);
          } else if (type == dynamic) {
            injection.required.add(name);
          } else {
            injection.required.add([name, type]);
          }
        }

        routable.addRoute(exposeDecl.method, exposeDecl.path,
            handleContained(reflectedMethod, injection),
            middleware: middleware);
      }
    };
  }

  /// Used to add additional routes to the router from within a [Controller].
  void configureRoutes(Routable routable) {}
}

/// Handles a request with a DI-enabled handler.
RequestHandler handleContained(handler, InjectionRequest injection) {
  return (RequestContext req, ResponseContext res) async {
    List args = [];

    void inject(requirement) {
      for (var requirement in injection.required) {
        if (requirement == RequestContext) {
          args.add(req);
        } else if (requirement == ResponseContext) {
          args.add(res);
        } else if (requirement is String) {
          if (req.params.containsKey(requirement)) {} else if (req.injections
              .containsKey(requirement))
            args.add(req.injections[requirement]);
          else {
            throw new Exception(
                "Cannot resolve parameter '$requirement' within handler.");
          }
          args.add(req.params[requirement]);
        } else if (requirement is List) {
          for (var child in requirement) {
            try {
              inject(child);
              break;
            } catch (e) {
              rethrow;
            }
          }
        } else if (requirement is Type && requirement != dynamic) {
          args.add(
              req.app.container.make(requirement, injecting: req.injections));
        } else {
          throw new ArgumentError(
              '$requirement cannot be injected into a request handler.');
        }
      }
    }

    injection.required.forEach(inject);
    return Function.apply(handler, args);
  };
}
