import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectWebSocket(Uri uri, {Map<String, dynamic>? headers}) {
  // Browser WebSocket automatically attaches same-origin HttpOnly cookies.
  return WebSocketChannel.connect(uri);
}
