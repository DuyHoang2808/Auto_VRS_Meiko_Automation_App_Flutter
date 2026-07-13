import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class AppRuntimeConfig extends ChangeNotifier {
  AppRuntimeConfig._();

  static final AppRuntimeConfig instance = AppRuntimeConfig._();

  static const String apiBaseUrlKey = 'api_base_url';
  static const String coordWsUrlKey = 'coord_ws_url';
  static const String autoVrsWsUrlKey = 'autovrs_ws_url';
  static const String autoVrsRtspUrlKey = 'autovrs_rtsp_url';
  static const String videoFrameWsUrlKey = 'video_frame_ws_url';
  static const String cameraWsUrlKey = 'camera_ws_url';
  static const String aiBaseUrlKey = 'ai_base_url';
  static const String qcamberBaseUrlKey = 'qcamber_base_url';
  static const String plcGatewayBaseUrlKey = 'plc_gateway_base_url';
  static const String ffmpegPathKey = 'ffmpeg_path';
  static const String rtspFpsKey = 'rtsp_fps';

  static const Map<String, String> _defaultValues = {
    apiBaseUrlKey: 'http://localhost:8000',
    coordWsUrlKey: 'ws://127.0.0.1:8765',
    autoVrsWsUrlKey: 'ws://192.168.10.165:8999',
    autoVrsRtspUrlKey: 'rtsp://192.168.10.165:8554/mystream',
    videoFrameWsUrlKey: 'ws://localhost:8081',
    cameraWsUrlKey: 'ws://localhost:8999',
    aiBaseUrlKey: 'http://localhost:8082',
    qcamberBaseUrlKey: 'http://localhost:8686',
    plcGatewayBaseUrlKey: 'http://localhost:8083',
    ffmpegPathKey: 'ffmpeg',
    rtspFpsKey: '15',
  };

  final Map<String, String> _fileValues = <String, String>{};
  bool _initialized = false;
  String? _loadedFilePath;

  bool get isInitialized => _initialized;
  String? get loadedFilePath => _loadedFilePath;

  String get apiBaseUrl => getString(apiBaseUrlKey);
  String get coordWsUrl => getString(coordWsUrlKey);
  String get autoVrsWsUrl => getString(autoVrsWsUrlKey);
  String get autoVrsRtspUrl => getString(autoVrsRtspUrlKey);
  String get videoFrameWsUrl => getString(videoFrameWsUrlKey);
  String get cameraWsUrl => getString(cameraWsUrlKey);
  String get aiBaseUrl => getString(aiBaseUrlKey);
  String get qcamberBaseUrl => getString(qcamberBaseUrlKey);
  String get plcGatewayBaseUrl => getString(plcGatewayBaseUrlKey);
  String get ffmpegPath => getString(ffmpegPathKey);
  int get rtspFps => int.tryParse(getString(rtspFpsKey)) ?? 15;

  String get aiDetectionUrl => '${_trimTrailingSlash(aiBaseUrl)}/api/ai-detection';

  Future<void> initialize() async {
    await reload(notify: false);
  }

  Future<void> reload({bool notify = true}) async {
    await _loadFileConfig();
    _initialized = true;
    if (notify) {
      notifyListeners();
    }
  }

  String getString(String key) {
    return _fileValues[key] ?? _defaultValues[key] ?? '';
  }

  Future<void> updateValues(
    Map<String, String> values, {
    bool notify = true,
  }) async {
    for (final entry in values.entries) {
      final normalized = entry.value.trim();
      if (_defaultValues.containsKey(entry.key) && normalized.isNotEmpty) {
        _fileValues[entry.key] = normalized;
      }
    }

    await _writeFileConfig();

    if (notify) {
      notifyListeners();
    }
  }

  Future<void> clearOverrides(
    Iterable<String> keys, {
    bool notify = true,
  }) async {
    for (final key in keys) {
      final defaultValue = _defaultValues[key];
      if (defaultValue != null) {
        _fileValues[key] = defaultValue;
      }
    }

    await _writeFileConfig();

    if (notify) {
      notifyListeners();
    }
  }

  static String _trimTrailingSlash(String value) {
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  Future<void> _loadFileConfig() async {
    _fileValues.clear();
    _loadedFilePath = null;

    final userConfigPath = await _userConfigPath();
    final candidatePaths = await _candidateConfigPaths(userConfigPath);

    File? selectedFile;
    for (final candidate in candidatePaths) {
      final file = File(candidate);
      if (await file.exists()) {
        selectedFile = file;
        break;
      }
    }

    selectedFile ??= await _ensureDefaultConfigFile(userConfigPath);
    _loadedFilePath = selectedFile.path;

    try {
      final raw = await selectedFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        for (final entry in decoded.entries) {
          if (_defaultValues.containsKey(entry.key) && entry.value != null) {
            _fileValues[entry.key] = entry.value.toString().trim();
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load runtime config file: $e');
    }

    for (final entry in _defaultValues.entries) {
      _fileValues.putIfAbsent(entry.key, () => entry.value);
    }
  }

  Future<void> _writeFileConfig() async {
    final targetPath = _loadedFilePath ?? await _userConfigPath();
    final file = File(targetPath);
    final directory = file.parent;

    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    for (final entry in _defaultValues.entries) {
      _fileValues.putIfAbsent(entry.key, () => entry.value);
    }

    final data = <String, String>{
      for (final key in _defaultValues.keys) key: getString(key),
    };
    final encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(data)}\n');
    _loadedFilePath = file.path;
  }

  Future<List<String>> _candidateConfigPaths(String userConfigPath) async {
    final paths = <String>[];

    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      paths.add(p.join(exeDir, 'app_config.json'));
    } catch (_) {}

    try {
      paths.add(p.join(Directory.current.path, 'app_config.json'));
    } catch (_) {}

    paths.add(userConfigPath);

    return paths.toSet().toList();
  }

  Future<File> _ensureDefaultConfigFile(String userConfigPath) async {
    final file = File(userConfigPath);
    final directory = file.parent;
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    if (!await file.exists()) {
      final encoder = const JsonEncoder.withIndent('  ');
      await file.writeAsString('${encoder.convert(_defaultValues)}\n');
    }
    return file;
  }

  Future<String> _userConfigPath() async {
    if (Platform.isWindows) {
      final userProfile =
          Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
      return p.join(userProfile, 'Documents', 'AutoVRS', 'app_config.json');
    }

    final homeDir =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return p.join(homeDir, '.autovrs', 'app_config.json');
  }
}
