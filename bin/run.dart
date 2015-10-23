import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";

import "package:http_multi_server/http_multi_server.dart";

import "package:mustache4dart/mustache4dart.dart";

LinkProvider link;

JsonEncoder jsonUglyEncoder = const JsonEncoder();
JsonEncoder jsonEncoder = const JsonEncoder.withIndent("  ");
String toJSON(input) => jsonEncoder.convert(input);

String valuePageHtml = new File("res/value_page.html").readAsStringSync();
String directoryListPageHtml = new File("res/directory_list.html").readAsStringSync();
Function valuePageTemplate = compile(valuePageHtml);
Function directoryListPageTemplate = compile(directoryListPageHtml);

launchServer(bool local, int port, ServerNode serverNode) async {
  List<HttpServer> servers = <HttpServer>[];
  InternetAddress ipv4 = local ? InternetAddress.LOOPBACK_IP_V4 : InternetAddress.ANY_IP_V4;
  InternetAddress ipv6 = local ? InternetAddress.LOOPBACK_IP_V6 : InternetAddress.ANY_IP_V6;

  try {
    servers.add(await HttpServer.bind(ipv4, port));
  } catch (e) {}

  try {
    servers.add(await HttpServer.bind(ipv6, port));
  } catch (e) {}

  HttpMultiServer server = new HttpMultiServer(servers);

  handleRequest(HttpRequest request) async {
    HttpResponse response = request.response;

    Uri uri = request.uri;
    String method = request.method;
    String ourPath = Uri.decodeComponent(uri.normalizePath().path);

    if (ourPath != "/" && ourPath.endsWith("/")) {
      ourPath = ourPath.substring(0, ourPath.length - 1);
    }

    String hostPath = "${serverNode.path}${ourPath}";
    if (hostPath != "/" && hostPath.endsWith("/")) {
      hostPath = hostPath.substring(0, hostPath.length - 1);
    }

    response.headers.set("Cache-Control", "no-cache, no-store, must-revalidate");
    response.headers.set("Pragma", "no-cache");
    response.headers.set("Expires", "0");

    if (method == "OPTIONS") {
      response.headers.set("Access-Control-Allow-Origin", "*");
      response.headers.set("Access-Control-Allow-Methods", "GET, PUT, POST, PATCH, DELETE");
      response.writeln();
      response.close();
      return;
    }

    if (ourPath == "/favicon.ico") {
      response.statusCode = HttpStatus.NOT_FOUND;
      response.writeln("Not Found.");
      response.close();
      return;
    }

    if (ourPath == "/index.html") {
      ourPath = "/.html";
    }

    Path p = new Path(hostPath);

    Future<Map> getRemoteNodeMap(RemoteNode n) async {
      if (n == null) {
        return {
          "error": "No Such Node"
        };
      }

      var p = new Path(n.remotePath);
      var map = {
        "?name": p.name,
        "?path": ourPath,
        "?url": request.uri.path
      };

      map.addAll(n.configs);
      map.addAll(n.attributes);

      for (String key in n.children.keys) {
        RemoteNode child = n.children[key];

        var x = new Path(child.remotePath);
        var trp = (ourPath == "/" ? "" : ourPath) + "/" + key;
        map[key] = {
          "?name": x.name,
          "?path": trp,
          "?url": Uri.encodeFull(trp)
        }..addAll(child.getSimpleMap());
      }

      if (n.configs.containsKey(r"$type")) {
        var val = await link.requester.getNodeValue(ourPath);
        map["?value"] = val.value;
        map["?value_timestamp"] = val.ts;
      }

      return map;
    }

    Map getNodeMap(SimpleNode n) {
      if (n == null) {
        return {
          "error": "No Such Node"
        };
      }

      if (n is! RestNode && n is! ServerNode) {
        return {
          "error": "Not a REST node"
        };
      }

      var p = new Path(n.path);
      var map = {
        "?name": p.name,
        "?path": "/" + hostPath.split("/").skip(2).join("/")
      };

      map.addAll(n.configs);
      map.addAll(n.attributes);

      for (var key in n.children.keys) {
        var child = n.children[key];

        if (child is! RestNode) {
          continue;
        }

        var x = new Path(child.path);
        map[key] = {
          "?name": x.name,
          "?path": "/" + x.path.split("/").skip(2).join("/")
        }..addAll(child.getSimpleMap());
      }

      if (n.lastValueUpdate != null && n.configs.containsKey(r"$type")) {
        map["?value"] = n.lastValueUpdate.value;
        map["?value_timestamp"] = n.lastValueUpdate.ts;
      }

      return map;
    }

    if (method == "GET") {
      if (!serverNode.isDataHost) {
        var isHtml = false;
        if (ourPath.endsWith(".html")) {
          ourPath = ourPath.substring(0, ourPath.length - 5);
          isHtml = true;
        }

        var p = new Path(ourPath);
        if (!p.valid) {
          response.statusCode = HttpStatus.BAD_REQUEST;
          response.writeln(toJSON({
            "error": "Invalid Path: ${p.path}"
          }));
          response.close();
          return;
        }
        var node = await link.requester.getRemoteNode(p.path);
        var json = await getRemoteNodeMap(node);

        if (isHtml) {
          response.headers.contentType = ContentType.HTML;
          if (json[r"$type"] != null) {
            response.writeln(valuePageTemplate({
              "name": json.containsKey(r"$name") ? json[r"$name"] : json["?name"],
              "path": json["?path"]
            }));
          } else {
            response.writeln(directoryListPageTemplate({
              "name": json.containsKey(r"$name") ? json[r"$name"] : json["?name"],
              "path": json["?path"],
              "url": json["?url"],
              "parent": p.parentPath + ".html",
              "children": json.keys.where((String x) => x.isNotEmpty && !((const ["@", "!", "?", r"$"]).contains(x[0]))).map((x) {
                var n = json[x];
                return {
                  "name": n["?name"],
                  "url": n["?url"],
                  "path": n["?path"],
                  "isValue": n[r"$type"] != null,
                  "isAction": n[r"$invokable"] != null,
                  "isNode": n[r"$invokable"] == null && n[r"$type"] == null
                };
              }).toList()
            }));
          }
          response.close();
          return;
        }

        if (uri.queryParameters.containsKey("val") || uri.queryParameters.containsKey("value")) {
          json = json["?value"];
          if (json is Map || json is List) {
            response.headers.contentType = ContentType.JSON;
            response.write(toJSON(json));
          } else {
            response.write(json);
          }
        } else if (uri.queryParameters.containsKey("watch") || uri.queryParameters.containsKey("subscribe")) {
          if (!(await WebSocketTransformer.isUpgradeRequest(request))) {
            request.response.statusCode = HttpStatus.BAD_REQUEST;
            request.response.writeln("Bad Request: Expected WebSocket Upgrad.e");
            request.response.close();
            return;
          }

          var socket = await WebSocketTransformer.upgrade(request);

          ReqSubscribeListener sub;
          Function onValueUpdate;
          onValueUpdate = (ValueUpdate update) {
            if (socket.closeCode != null) {
              return;
            }

            socket.add(jsonUglyEncoder.convert({
              "value": update.value,
              "timestamp": update.ts
            }));
          };
          sub = link.requester.subscribe(ourPath, onValueUpdate);
          socket.done.then((_) {
            sub.cancel();
          });
          return;
        } else {
          response.headers.contentType = ContentType.JSON;
          response.writeln(toJSON(json));
        }
        response.close();
        return;
      }

      SimpleNode n = link.getNode(hostPath);

      if (link.provider.getNode(hostPath) == null) {
        response.statusCode = HttpStatus.NOT_FOUND;
        response.headers.contentType = ContentType.JSON;
        response.writeln(toJSON({
          "error": "No Such Node"
        }));
        response.close();
        return;
      }

      var map = getNodeMap(n);

      if (uri.queryParameters.containsKey("val") || uri.queryParameters.containsKey("value")) {
        map = map["?value"];
        if (map is Map || map is List) {
          response.headers.contentType = ContentType.JSON;
          response.write(toJSON(map));
        } else {
          response.write(map);
        }
      } else if (uri.queryParameters.containsKey("watch") || uri.queryParameters.containsKey("subscribe")) {
        if (!(await WebSocketTransformer.isUpgradeRequest(request))) {
          request.response.statusCode = HttpStatus.BAD_REQUEST;
          request.response.writeln("Bad Request: Expected WebSocket Upgrade.");
          request.response.close();
          return;
        }

        var socket = await WebSocketTransformer.upgrade(request);

        RespSubscribeListener sub;
        sub = n.subscribe((ValueUpdate update) {
          if (socket.closeCode != null) {
            if (sub != null) {
              sub.cancel();
            }
            return;
          }

          socket.add(jsonUglyEncoder.convert({
            "value": update.value,
            "timestamp": update.ts
          }));
        });

        socket.done.then((_) {
          sub.cancel();
          sub = null;
        });
        return;
      } else {
        response.headers.contentType = ContentType.JSON;
        response.writeln(toJSON(map));
      }
      response.close();
      return;
    } else if (method == "PUT") {
      if (!serverNode.isDataHost) {
        response.statusCode = HttpStatus.NOT_IMPLEMENTED;
        response.headers.contentType = ContentType.JSON;
        response.writeln(toJSON({
          "error": "Data Client does not support creating/updating nodes"
        }));
        response.close();
        return;
      }

      var json = await readJSONData(request);
      var mp = p.parent;
      var pathsToCreate = [];
      while (!mp.isRoot) {
        if (link.getNode(mp.path) == null) {
          pathsToCreate.add(mp.path);
        }
        mp = mp.parent;
      }

      if (pathsToCreate.isNotEmpty) {
        pathsToCreate.sort();
        for (var pr in pathsToCreate) {
          link.addNode(pr, {});
        }
      }

      if (link.provider.getNode(hostPath) != null) {
        var node = link.provider.getNode(hostPath);
        Map map;
        if (json.keys.length == 1 && json.keys.contains("?value")) {
          node.updateValue(new ValueUpdate(json["?value"], ts: ValueUpdate.getTs()));
          map = getNodeMap(node);
        } else {
          map = getNodeMap(node);
          map.addAll(json);
          map[r"$is"] = "rest";
          map.keys.where((x) => map[x] == null).toList().forEach(map.remove);
          node.load(map);
        }
        response.headers.contentType = ContentType.JSON;
        response.writeln(toJSON(map));
        response.close();
        changed = true;
        return;
      }

      var node = link.addNode(hostPath, json);
      var map = getNodeMap(node);
      map[r"$is"] = "rest";
      response.headers.contentType = ContentType.JSON;
      response.writeln(toJSON(map));
      response.close();
      changed = true;
      return;
    } else if (method == "POST" || method == "PATCH") {
      var json = await readJSONData(request);

      if (!serverNode.isDataHost) {
        if (json.keys.length == 1 && json.keys.contains("?value")) {
          var val = json["?value"];
          await link.requester.set(ourPath, val);
          response.headers.contentType = ContentType.JSON;
          response.writeln(toJSON(await getRemoteNodeMap(await link.requester.getRemoteNode(ourPath))));
          response.close();
        } else if (uri.queryParameters.containsKey("val") || uri.queryParameters.containsKey("value")) {
          await link.requester.set(ourPath, json);
          response.headers.contentType = ContentType.JSON;
          response.writeln(toJSON(await getRemoteNodeMap(
              await link.requester.getRemoteNode(ourPath))));
          response.close();
          return;
        } else if (uri.queryParameters.containsKey("invoke")) {
          var node = await link.requester.getRemoteNode(ourPath);
          var updates = await link.requester.invoke(ourPath, json).toList().timeout(const Duration(seconds: 20));
          if (node.configs[r"$invokable"] == null) {
            response.statusCode = HttpStatus.NOT_IMPLEMENTED;
            response.headers.contentType = ContentType.JSON;
            response.writeln(toJSON({
              "error": "Node is not invokable"
            }));
            response.close();
            return;
          }

          var result = {};

          result.addAll({
            "columns": [],
            "rows": []
          });
          for (RequesterInvokeUpdate update in updates) {
            if (update.error != null) {
              result.clear();
              result["error"] = {
                "message": update.error.msg,
                "detail": update.error.detail,
                "path": update.error.path,
                "phase": update.error.phase
              };
              response.statusCode = HttpStatus.INTERNAL_SERVER_ERROR;
              break;
            }
            result["columns"].addAll(update.columns.map((x) => x.getData()).toList());
            result["rows"].addAll(update.rows);
          }

          response.headers.contentType = ContentType.JSON;
          response.writeln(toJSON(result));
          response.close();
          return;
        } else {
          response.statusCode = HttpStatus.NOT_IMPLEMENTED;
          response.headers.contentType = ContentType.JSON;
          response.writeln(toJSON({
            "error": "Data Client does not support updating nodes"
          }));
          response.close();
          return;
        }
      }

      SimpleNode node = link.getNode(hostPath);

      if (node == null) {
        node = link.addNode(hostPath, json);
        var map = getNodeMap(node);
        response.headers.contentType = ContentType.JSON;
        response.writeln(toJSON(map));
        response.close();
        changed = true;
        return;
      }

      Map map;
      if (json.keys.length == 1 && json.keys.contains("?value")) {
        node.updateValue(json["?value"]);
        map = getNodeMap(node);
      } else if (uri.queryParameters.containsKey("val") || uri.queryParameters.containsKey("value")) {
        node.updateValue(json);
        map = getNodeMap(node);
      } else {
        map = {};
        map.addAll(json);
        map[r"$is"] = "rest";
        node.load(map);
      }
      response.headers.contentType = ContentType.JSON;
      response.writeln(toJSON(map));
      response.close();
      changed = true;
      return;
    } else if (method == "DELETE") {
      if (!serverNode.isDataHost) {
        response.statusCode = HttpStatus.NOT_IMPLEMENTED;
        response.headers.contentType = ContentType.JSON;
        response.writeln(toJSON({
          "error": "Data Clients do not support DELETE"
        }));
        response.close();
      }

      SimpleNode node = link.getNode(hostPath);
      var map = getNodeMap(node);

      if (node == null) {
        response.statusCode = HttpStatus.NOT_FOUND;
        response.headers.contentType = ContentType.JSON;
        response.writeln(toJSON({
          "error": "No Such Node"
        }));
        response.close();
        return;
      }

      node.remove();
      response.headers.contentType = ContentType.JSON;
      response.writeln(toJSON(map));
      response.close();
      changed = true;
      return;
    }

    response.headers.contentType = ContentType.JSON;
    response.statusCode = HttpStatus.BAD_REQUEST;
    response.writeln(toJSON({
      "error": "Bad Request"
    }));
    response.close();
  }

  server.listen((request) async {
    try {
      await handleRequest(request);
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.INTERNAL_SERVER_ERROR;
      } catch (e) {}
      request.response.writeln("Internal Server Error:");
      request.response.writeln(e);
      request.response.close();
    }
  });

  return server;
}

Future<Map> readJSONData(HttpRequest request) async {
  var content = await request.transform(UTF8.decoder).join();
  return JSON.decode(content);
}

main(List<String> args) async {
  link = new LinkProvider(args, "REST-", profiles: {
    "addServer": (String path) => new SimpleActionNode(path, (Map<String, dynamic> params) async {
      int port = params["port"] is String  ? int.parse(params["port"]) : params["port"];
      bool local = params["local"];
      String type = params["type"];
      if (local == null) local = false;

      try {
        var server = await ServerSocket.bind(InternetAddress.ANY_IP_V4, port);
        await server.close();
      } catch (e) {
        return {
          "message": "Failed to bind to port: ${e}"
        };
      }

      link.addNode("/${params["name"]}", {
        r"$is": "server",
        r"$server_port": port,
        r"$server_local": local,
        r"$server_type": type,
        "Remove": {
          r"$is": "remove",
          r"$invokable": "write"
        }
      });
      changed = true;
      return {
        "message": "Success!"
      };
    }),
    "server": (String path) {
      return new ServerNode(path);
    },
    "rest": (String path) {
      return new RestNode(path);
    },
    "create": (String path) {
      return new SimpleActionNode(path, (Map<String, dynamic> params) {
        var name = params["name"];

        var parent = new Path(path).parent;
        link.addNode("${parent.path}/${name}", {
          r"$is": "rest"
        });
        changed = true;
      });
    },
    "createMetric": (String path) {
      return new SimpleActionNode(path, (Map<String, dynamic> params) {
        var name = params["name"];
        var editor = params["editor"];
        var type = params["type"];

        var parent = new Path(path).parent;
        var node = link.addNode("${parent.path}/${name}", {
          r"$is": "rest",
          r"$type": type,
          r"$writable": "write"
        });

        if (editor != null && editor.isNotEmpty) {
          node.configs[r"$editor"] = editor;
        }

        changed = true;
      });
    },
    "remove": (String path) => new DeleteActionNode.forParent(path, link.provider)
  }, autoInitialize: false, isRequester: true, isResponder: true);

  var nodes = {
    "Add_Server": {
      r"$name": "Add Server",
      r"$invokable": "write",
      r"$params": [
        {
          "name": "name",
          "type": "string",
          "placeholder": "MyServer"
        },
        {
          "name": "local",
          "type": "bool",
          "description": "Bind to Local Interface",
          "default": false
        },
        {
          "name": "port",
          "type": "int",
          "default": 8020
        },
        {
          "name": "type",
          "type": "enum[Data Host,Data Client]",
          "default": "Data Host",
          "description": "Data Type"
        }
      ],
      r"$result": "values",
      r"$columns": [
        {
          "name": "message",
          "type": "string"
        }
      ],
      r"$is": "addServer"
    }
  };

  link.init();

  for (var k in nodes.keys) {
    link.addNode("/${k}", nodes[k]);
  }

  link.connect();

  timer = Scheduler.every(Interval.ONE_SECOND, () async {
    if (changed) {
      changed = false;
      await link.saveAsync();
    }
  });
}

bool changed = false;
Timer timer;

class RestNode extends SimpleNode {
  RestNode(String path) : super(path);

  @override
  onCreated() {
    link.addNode("${path}/Create_Node", {
      r"$name": "Create Node",
      r"$is": "create",
      r"$invokable": "write",
      r"$result": "values",
      r"$params": [
        {
          "name": "name",
          "type": "string"
        }
      ]
    });

    link.addNode("${path}/Create_Value", CREATE_VALUE);

    link.addNode("${path}/Remove_Node", {
      r"$name": "Remove Node",
      r"$is": "remove",
      r"$invokable": "write"
    });
  }

  @override
  onSetValue(Object val) {
    if (configs[r"$type"] == "map" && val is String) {
      try {
        var json = JSON.decode(val);
        updateValue(json);
        return true;
      } catch (e) {
        return super.onSetValue(val);
      }
    } else {
      return super.onSetValue(val);
    }
  }

  @override
  updateValue(Object update, {bool force: false}) {
    super.updateValue(update, force: force);
    changed = true;
  }

  @override
  onRemoving() {
    changed = true;
  }
}

final Map<String, dynamic> CREATE_VALUE = {
  r"$name": "Create Value",
  r"$is": "createMetric",
  r"$invokable": "write",
  r"$result": "values",
  r"$params": [
    {
      "name": "name",
      "type": "string"
    },
    {
      "name": "type",
      "type": "enum",
      "editor": buildEnumType([
        "string",
        "number",
        "bool",
        "color",
        "gradient",
        "fill",
        "array",
        "map"
      ])
    },
    {
      "name": "editor",
      "type": "enum",
      "editor": buildEnumType([
        "none",
        "textarea",
        "password",
        "daterange",
        "date"
      ]),
      "default": "none"
    }
  ],
  r"$columns": []
};

class ServerNode extends SimpleNode {
  HttpServer server;

  ServerNode(String path) : super(path);

  @override
  onCreated() async {
    var port = configs[r"$server_port"];
    var local = configs[r"$server_local"];
    var type = configs[r"$server_type"];
    if (local == null) local = false;
    if (type == null) type = "Data Host";

    configs[r"$server_local"] = local;
    configs[r"$server_type"] = type;

    server = await launchServer(local, port, this);

    if (type == "Data Host") {
      link.addNode("${path}/Create_Node", {
        r"$name": "Create Node",
        r"$is": "create",
        r"$invokable": "write",
        r"$result": "values",
        r"$params": [
          {
            "name": "name",
            "type": "string"
          }
        ]
      });

      link.addNode("${path}/Create_Value", CREATE_VALUE);
    }
  }

  bool get isDataHost => configs[r"$server_type"] == "Data Host";

  @override
  onRemoving() async {
    if (server != null) {
      await server.close(force: true);
      server = null;
    }
  }
}
