import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_runtime_config.dart';

class ApiService extends ChangeNotifier {
  bool _isConnected = false;
  
  String get baseUrl => AppRuntimeConfig.instance.apiBaseUrl;
  bool get isConnected => _isConnected;
  
  void updateBaseUrl(String newBaseUrl) {
    unawaited(
      AppRuntimeConfig.instance.updateValues({
        AppRuntimeConfig.apiBaseUrlKey: newBaseUrl,
      }),
    );
    notifyListeners();
  }
  
  void setConnectionStatus(bool connected) {
    _isConnected = connected;
    notifyListeners();
  }
  
  // Test connection to the backend
  Future<bool> testConnection() async {
    try {
      // Add connection test logic here
      setConnectionStatus(true);
      return true;
    } catch (e) {
      setConnectionStatus(false);
      return false;
    }
  }
}
