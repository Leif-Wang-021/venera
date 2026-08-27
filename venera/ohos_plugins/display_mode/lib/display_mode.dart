import 'package:flutter/services.dart';

class FlutterDisplayMode {
  static Future<void> setHighRefreshRate() async {
    const MethodChannel('display_mode').invokeMethod('setHighRefreshRate');
  }
}
