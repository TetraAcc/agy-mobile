import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_connector_io.dart' if (dart.library.js_interop) 'ws_connector_web.dart' as impl;

typedef WebSocketConnectFn = WebSocketChannel Function(Uri uri, {Map<String, dynamic>? headers});

WebSocketChannel connectWebSocket(Uri uri, {Map<String, dynamic>? headers}) =>
    impl.connectWebSocket(uri, headers: headers);
