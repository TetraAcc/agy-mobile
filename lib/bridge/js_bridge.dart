import 'js_bridge_stub.dart'
    if (dart.library.js) 'js_bridge_web.dart';

abstract class JsBridge {
  static void initBridge(Function(String, String, bool) onMediaAdded) {
    implInitBridge(onMediaAdded);
  }

  static void pickFile(String accept, bool isImage) {
    implPickFile(accept, isImage);
  }

  static void downloadFile(String url, String name) {
    implDownloadFile(url, name);
  }

  static void openUrl(String url) {
    implOpenUrl(url);
  }
}
