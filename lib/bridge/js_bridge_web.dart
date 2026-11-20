// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:js' as js;

void implInitBridge(Function(String, String, bool) onMediaAdded) {
  try {
    js.context['agyBridge']?.callMethod('init', [
      (dynamic name, dynamic base64, dynamic isImg) {
        onMediaAdded(name.toString(), base64.toString(), isImg == true);
      }
    ]);
  } catch (e) {
    // ignore
  }
}

void implPickFile(String accept, bool isImage) {
  try {
    js.context['agyBridge']?.callMethod('pickFile', [accept, isImage]);
  } catch (e) {
    // ignore
  }
}

void implDownloadFile(String url, String name) {
  try {
    js.context['agyBridge']?.callMethod('downloadFile', [url, name]);
  } catch (_) {
    try {
      js.context.callMethod('open', [url, '_blank']);
    } catch (_) {}
  }
}

void implOpenUrl(String url) {
  try {
    js.context.callMethod('open', [url, '_blank']);
  } catch (e) {
    // ignore
  }
}
