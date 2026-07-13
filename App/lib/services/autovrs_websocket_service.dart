import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:autovrs_app/core/app_runtime_config.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum AutoVRSStreamSource { websocket, rtsp }

class AutoVRSWebSocketService extends ChangeNotifier {
  static const String windowsFfmpegFallbackPath =
      r'D:\Ps_Duy\Driver\ffmpeg-2026-05-06-git-f2e5eff3ff-essentials_build\bin\ffmpeg.exe';
  // SICK Camera WebSocket Stream (port 8999)
  // Old C++ module was on ws://127.0.0.1:12345/

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Process? _rtspProcess;
  StreamSubscription<List<int>>? _rtspStdoutSubscription;
  StreamSubscription<String>? _rtspStderrSubscription;
  final List<int> _rtspBuffer = <int>[];

  // ValueNotifiers for better performance
  final ValueNotifier<bool> _isConnectedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<Uint8List?> _currentFrameNotifier =
      ValueNotifier<Uint8List?>(null);
  final ValueNotifier<Uint8List?> _capturedImageNotifier =
      ValueNotifier<Uint8List?>(null);
  final ValueNotifier<bool> _isViewingCapturedImageNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<int> _frameCountNotifier = ValueNotifier<int>(0);

  // Legacy properties for compatibility
  bool _isConnected = false;
  Uint8List? _currentFrame;
  Uint8List? _capturedImage;
  bool _isViewingCapturedImage = false;
  Map<String, dynamic>? _lastDetectionResults;
  Map<String, dynamic>? _lastAnalysis;
  List<Map<String, dynamic>>? _capturedDetections;
  String? _lastError;
  int _frameCount = 0;
  bool _isDisposed = false;
  int _connectionToken = 0;
  bool _notifyScheduled = false;
  int _notifierUpdateToken = 0;
  AutoVRSStreamSource _streamSource = AutoVRSStreamSource.websocket;
  String _serverUrl = AppRuntimeConfig.instance.autoVrsWsUrl;
  String _rtspUrl = AppRuntimeConfig.instance.autoVrsRtspUrl;
  String _ffmpegPath = AppRuntimeConfig.instance.ffmpegPath;
  int _rtspFps = AppRuntimeConfig.instance.rtspFps;

  // ValueNotifier getters for optimized UI updates
  ValueNotifier<bool> get isConnectedNotifier => _isConnectedNotifier;
  ValueNotifier<Uint8List?> get currentFrameNotifier => _currentFrameNotifier;
  ValueNotifier<Uint8List?> get capturedImageNotifier => _capturedImageNotifier;
  ValueNotifier<bool> get isViewingCapturedImageNotifier =>
      _isViewingCapturedImageNotifier;
  ValueNotifier<int> get frameCountNotifier => _frameCountNotifier;

  // Legacy getters for backward compatibility
  bool get isConnected => _isConnected;
  Uint8List? get currentFrame => _currentFrame;
  Uint8List? get capturedImage => _capturedImage;
  bool get isViewingCapturedImage => _isViewingCapturedImage;
  Map<String, dynamic>? get lastDetectionResults => _lastDetectionResults;
  Map<String, dynamic>? get lastAnalysis => _lastAnalysis;
  List<Map<String, dynamic>>? get capturedDetections => _capturedDetections;
  String? get lastError => _lastError;
  int get frameCount => _frameCount;
  AutoVRSStreamSource get streamSource => _streamSource;
  String get serverUrl => _serverUrl;
  String get rtspUrl => _rtspUrl;
  String get ffmpegPath => _ffmpegPath;
  int get rtspFps => _rtspFps;

  // Getter để lấy detections từ lastDetectionResults
  List<Map<String, dynamic>>? get detections {
    if (_lastDetectionResults != null &&
        _lastDetectionResults!['detections'] != null) {
      return (_lastDetectionResults!['detections'] as List)
          .cast<Map<String, dynamic>>();
    }
    return null;
  }

  // Phương thức để lấy ảnh hiện tại đang hiển thị
  Uint8List? get displayImage {
    if (_isViewingCapturedImage && _capturedImage != null) {
      return _capturedImage;
    }
    return _currentFrame;
  }

  /// Kết nối đến AutoVRS WebSocket server
  Future<bool> connect({
    String? serverUrl,
    String clientId = 'flutter_client',
  }) async {
    try {
      await disconnect(notify: false); // Đóng kết nối cũ nếu có
      final token = ++_connectionToken;

      _streamSource = AutoVRSStreamSource.websocket;
      _serverUrl = (serverUrl ?? AppRuntimeConfig.instance.autoVrsWsUrl).trim();
      await _saveStreamPreferences();

      // SICK camera doesn't need /ws/clientId path, just direct connection
      final uri = Uri.parse(_serverUrl);
      _channel = WebSocketChannel.connect(uri);

      // Lắng nghe messages từ server
      _subscription = _channel!.stream.listen(
        (message) => _handleMessage(message, token),
        onError: (error) => _handleError(error, token),
        onDone: () => _handleDisconnect(token),
      );

      _setConnected(true);
      _lastError = null;
      _notifyListenersIfAlive();

      // Don't send ping to SICK camera - it only streams binary JPEG
      debugPrint('✅ Connected to SICK camera backend');

      return true;
    } catch (e) {
      _lastError = 'Connection failed: $e';
      _setConnected(false);
      _notifyListenersIfAlive();
      return false;
    }
  }

  Future<bool> connectLastSource() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sourceName =
          prefs.getString('autovrs_stream_source') ??
          AutoVRSStreamSource.websocket.name;
      final runtimeConfig = AppRuntimeConfig.instance;
      _serverUrl = runtimeConfig.autoVrsWsUrl;
      _rtspUrl = runtimeConfig.autoVrsRtspUrl;
      _ffmpegPath = runtimeConfig.ffmpegPath;
      _rtspFps = runtimeConfig.rtspFps;

      if (sourceName == AutoVRSStreamSource.rtsp.name) {
        return connectRtsp(
          rtspUrl: _rtspUrl,
          ffmpegPath: _ffmpegPath,
          fps: _rtspFps,
        );
      }

      return connect(serverUrl: _serverUrl);
    } catch (e) {
      debugPrint('Failed to connect last stream source: $e');
      return connect();
    }
  }

  Future<bool> connectRtsp({
    String? rtspUrl,
    String? ffmpegPath,
    int? fps,
  }) async {
    try {
      await disconnect(notify: false);
      final token = ++_connectionToken;

      final resolvedRtspUrl =
          (rtspUrl ?? AppRuntimeConfig.instance.autoVrsRtspUrl).trim();
      if (!resolvedRtspUrl.toLowerCase().startsWith('rtsp://')) {
        throw Exception('RTSP URL must start with rtsp://');
      }

      _streamSource = AutoVRSStreamSource.rtsp;
      _rtspUrl = resolvedRtspUrl;
      _ffmpegPath = await _resolveFfmpegPath(
        (ffmpegPath ?? AppRuntimeConfig.instance.ffmpegPath).trim(),
      );
      _rtspFps = (fps ?? AppRuntimeConfig.instance.rtspFps).clamp(1, 60).toInt();
      await _saveStreamPreferences();

      final args = <String>[
        '-hide_banner',
        '-loglevel',
        'warning',
        '-rtsp_transport',
        'tcp',
        '-fflags',
        'nobuffer',
        '-flags',
        'low_delay',
        '-probesize',
        '1000000',
        '-analyzeduration',
        '1000000',
        '-i',
        _rtspUrl,
        '-an',
        '-vf',
        'fps=$_rtspFps',
        '-f',
        'image2pipe',
        '-vcodec',
        'mjpeg',
        '-q:v',
        '5',
        'pipe:1',
      ];

      final process = await Process.start(
        _ffmpegPath,
        args,
      ).timeout(const Duration(seconds: 8));
      _rtspProcess = process;
      _rtspBuffer.clear();

      _rtspStdoutSubscription = process.stdout.listen(
        (chunk) => _handleRtspBytes(chunk, token),
        onError: (error) => _handleError(error, token),
      );
      _rtspStderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) {
              debugPrint('RTSP/ffmpeg: $line');
            }
          });

      process.exitCode.then((code) {
        if (_isDisposed) return;
        if (token == _connectionToken &&
            _streamSource == AutoVRSStreamSource.rtsp &&
            identical(_rtspProcess, process)) {
          _setConnected(false);
          _clearCurrentFrame();
          _lastError = code == 0
              ? 'RTSP stream stopped'
              : 'RTSP stream stopped (ffmpeg exit code $code)';
          _notifyListenersIfAlive();
        }
      });

      _setConnected(true);
      _lastError = null;
      _notifyListenersIfAlive();
      debugPrint('Connected to RTSP stream: $_rtspUrl via $_ffmpegPath');
      return true;
    } catch (e) {
      _lastError = 'RTSP connection failed: $e';
      _setConnected(false);
      _notifyListenersIfAlive();
      debugPrint('RTSP connection failed: $e');
      return false;
    }
  }

  /// Ngắt kết nối WebSocket
  Future<void> disconnect({bool notify = true}) async {
    _connectionToken++;
    _notifierUpdateToken++;

    if (_subscription != null) {
      await _subscription!.cancel();
      _subscription = null;
    }

    final channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close().catchError((_) {}));
    }

    await _stopRtspProcess();

    _setConnected(false);
    _clearCurrentFrame();
    if (notify) {
      _notifyListenersIfAlive();
    }
  }

  void _notifyListenersIfAlive() {
    if (_isDisposed) return;

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      notifyListeners();
      return;
    }

    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_isDisposed) {
        notifyListeners();
      }
    });
  }

  void _setConnected(bool value) {
    if (_isDisposed) return;

    _isConnected = value;
    _setValueNotifierIfAlive(_isConnectedNotifier, value);
  }

  void _setCurrentFrame(Uint8List frame) {
    if (_isDisposed) return;

    _currentFrame = frame;
    _frameCount++;
    _setValueNotifierIfAlive(_currentFrameNotifier, frame);
    _setValueNotifierIfAlive(_frameCountNotifier, _frameCount);
  }

  void _clearCurrentFrame() {
    if (_isDisposed) return;

    _currentFrame = null;
    _setValueNotifierIfAlive(_currentFrameNotifier, null);
  }

  void _setCapturedImage(Uint8List? image) {
    if (_isDisposed) return;

    _capturedImage = image;
    _setValueNotifierIfAlive(_capturedImageNotifier, image);
  }

  void _setViewingCapturedImage(bool value) {
    if (_isDisposed) return;

    _isViewingCapturedImage = value;
    _setValueNotifierIfAlive(_isViewingCapturedImageNotifier, value);
  }

  void _setValueNotifierIfAlive<T>(ValueNotifier<T> notifier, T value) {
    if (_isDisposed) return;

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      notifier.value = value;
      return;
    }

    final token = _notifierUpdateToken;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_isDisposed || token != _notifierUpdateToken) return;
      notifier.value = value;
    });
  }

  Future<void> _stopRtspProcess() async {
    await _rtspStdoutSubscription?.cancel();
    _rtspStdoutSubscription = null;
    await _rtspStderrSubscription?.cancel();
    _rtspStderrSubscription = null;

    final process = _rtspProcess;
    _rtspProcess = null;
    _rtspBuffer.clear();

    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        // Best effort; ffmpeg may already be gone.
      }
    }
  }

  Future<String> _resolveFfmpegPath(String rawPath) async {
    final normalizedPath = _stripSurroundingQuotes(rawPath);
    final configuredDefaultPath = AppRuntimeConfig.instance.ffmpegPath;

    if (normalizedPath.isEmpty || normalizedPath == configuredDefaultPath) {
      final fallback = File(windowsFfmpegFallbackPath);
      if (Platform.isWindows && await fallback.exists()) {
        return windowsFfmpegFallbackPath;
      }
      return configuredDefaultPath;
    }

    final ffmpegFile = File(normalizedPath);
    if (await ffmpegFile.exists()) {
      return normalizedPath;
    }

    throw Exception('ffmpeg executable not found: $normalizedPath');
  }

  String _stripSurroundingQuotes(String value) {
    var text = value.trim();
    while (text.length >= 2 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      text = text.substring(1, text.length - 1).trim();
    }
    return text;
  }

  Future<void> _saveStreamPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('autovrs_stream_source', _streamSource.name);
    await AppRuntimeConfig.instance.updateValues({
      AppRuntimeConfig.autoVrsWsUrlKey: _serverUrl,
      AppRuntimeConfig.autoVrsRtspUrlKey: _rtspUrl,
      AppRuntimeConfig.ffmpegPathKey: _ffmpegPath,
      AppRuntimeConfig.rtspFpsKey: _rtspFps.toString(),
    }, notify: false);
  }

  void _handleRtspBytes(List<int> chunk, [int? token]) {
    if (token != null && token != _connectionToken) return;
    if (_isDisposed) return;

    try {
      _rtspBuffer.addAll(chunk);

      while (true) {
        final start = _indexOfJpegMarker(_rtspBuffer, 0xff, 0xd8, 0);
        if (start < 0) {
          if (_rtspBuffer.length > 1024 * 1024) {
            _rtspBuffer.clear();
          }
          return;
        }

        if (start > 0) {
          _rtspBuffer.removeRange(0, start);
        }

        final end = _indexOfJpegMarker(_rtspBuffer, 0xff, 0xd9, 2);
        if (end < 0) {
          if (_rtspBuffer.length > 8 * 1024 * 1024) {
            _rtspBuffer.removeRange(0, _rtspBuffer.length - 2);
          }
          return;
        }

        final frame = Uint8List.fromList(_rtspBuffer.sublist(0, end + 2));
        _rtspBuffer.removeRange(0, end + 2);
        _setCurrentFrame(frame);
      }
    } catch (e) {
      _lastError = 'RTSP frame parse error: $e';
      debugPrint(_lastError);
    }
  }

  int _indexOfJpegMarker(
    List<int> bytes,
    int first,
    int second,
    int startIndex,
  ) {
    for (var i = startIndex; i < bytes.length - 1; i++) {
      if (bytes[i] == first && bytes[i + 1] == second) {
        return i;
      }
    }
    return -1;
  }

  /// Xử lý message từ server
  void _handleMessage(dynamic message, [int? token]) {
    if (token != null && token != _connectionToken) return;

    try {
      if (message is Uint8List) {
        // Nếu là dữ liệu nhị phân (ảnh JPEG)
        // debugPrint('🖼️ Received JPEG frame (${message.length} bytes)');
        // TODO: Xử lý hiển thị ảnh lên UI hoặc lưu frame
        // Ví dụ: _currentFrame = message;
        _setCurrentFrame(message);
        optimizeMemory();
        if (_frameCount % 30 == 0) {
          // debugPrint('📹 Frame processed: $_frameCount')
        }
      } else if (message is String) {
        // Nếu là text (JSON)
        try {
          final data = jsonDecode(message);
          if (data is Map<String, dynamic>) {
            final type =
                data['type'] ?? data['command']; // Hỗ trợ cả type và command
            if (type == 'info' || type == 'connection') {
              // Xử lý thông tin camera hoặc kết nối
              debugPrint('--- Thông tin từ Server ---');
              debugPrint('  Serial Number: ${data['serial_number']}');
              debugPrint('  Sensor: ${data['sensor_name']}');
              debugPrint(
                '  Max Resolution: ${data['max_width']}x${data['max_height']}',
              );
              debugPrint('---------------------------------');
              _handleConnectionMessage(data);
            } else if (type == 'video_frame') {
              _handleVideoFrame(data);
            } else if (type == 'capture_response' || type == 'ai_detection') {
              debugPrint('📥 CAPTURE_RESPONSE/AI_DETECTION received!');
              _handleCaptureResponse(data);
            } else if (type == 'camera_status') {
              _handleCameraStatus(data);
            } else if (type == 'pong') {
              _handlePong(data);
            } else {
              debugPrint('📩 Message type/command: $type');
            }
          } else {
            debugPrint('❌ JSON không phải Map: $data');
          }
        } catch (e) {
          debugPrint('❌ Không parse được JSON: $message');
        }
      } else {
        debugPrint('❓ Message không xác định kiểu: $message');
      }
    } catch (e) {
      debugPrint('❌ Lỗi khi xử lý message: $e');
    }
  }

  /// Xử lý video frame với base64 JPEG từ ngrok
  void _handleVideoFrame(Map<String, dynamic> data) {
    try {
      // Xử lý base64 JPEG data từ ngrok WebSocket
      final base64Data = data['data'] as String?;
      final jpegData = data['jpeg_data'] as String?; // Alternative key for JPEG

      if (base64Data != null && base64Data.isNotEmpty) {
        final frameData = base64Decode(base64Data);
        _setCurrentFrame(frameData);
      } else if (jpegData != null && jpegData.isNotEmpty) {
        final frameData = base64Decode(jpegData);
        _setCurrentFrame(frameData);
      }

      // Memory optimization
      optimizeMemory();

      // Throttle notifications - chỉ notify mỗi 5 frames để tối ưu performance
      // Memory optimization - giới hạn log output
      if (_frameCount % 30 == 0) {
        debugPrint('📹 Frame processed: $_frameCount');
      }
    } catch (e) {
      if (_frameCount % 10 == 0) {
        // Throttle error logs
        debugPrint('Error handling video frame: $e');
      }
    }
  }

  /// Xử lý response của capture request
  Future<void> _handleCaptureResponse(Map<String, dynamic> data) async {
    debugPrint('🚀 _handleCaptureResponse CALLED');
    debugPrint('🚀 Data keys: ${data.keys.toList()}');

    final success = data['success'] as bool;
    final message = data['message'] as String;

    debugPrint('🚀 Success: $success, Message: $message');

    if (success) {
      // Lưu kết quả phát hiện lỗi và phân tích
      _lastDetectionResults =
          data['detection_results'] as Map<String, dynamic>?;
      _lastAnalysis = data['analysis'] as Map<String, dynamic>?;

      // DEBUG: Log detection data
      if (_lastDetectionResults != null) {
        final numDefects = _lastDetectionResults!['num_defects'] ?? 0;
        final detections = _lastDetectionResults!['detections'] as List?;
        debugPrint('🔍 DETECTION DATA: $numDefects defects found');
        debugPrint('🔍 Detection list: $detections');

        if (detections != null) {
          for (int i = 0; i < detections.length; i++) {
            debugPrint('🔍 Defect $i: ${detections[i]}');
          }
        }
      } else {
        debugPrint('🔍 NO DETECTION RESULTS in response');
      }

      // Xử lý ảnh base64 nếu có - kiểm tra nhiều trường có thể
      final imageData =
          data['image_data'] as String? ??
          data['processed_image_base64'] as String? ??
          data['processed_image'] as String?;
      debugPrint(
        '🔍 Image data received: ${imageData != null ? 'YES (${imageData.length} chars)' : 'NO'}',
      );
      debugPrint('🔍 Available data keys: ${data.keys.toList()}');

      if (imageData != null && imageData.isNotEmpty) {
        try {
          final capturedImage = base64Decode(imageData);
          _setCapturedImage(capturedImage);
          _setViewingCapturedImage(true);
          debugPrint('🔍 Decoded image: ${_capturedImage!.length} bytes');
          if (_capturedImage != null) {
            await _saveCapturedImageToFolder(capturedImage);
          }
          _notifyListenersIfAlive();
        } catch (e) {
          _lastError = 'Failed to decode captured image: $e';
          debugPrint('❌ Failed to decode image: $e');
        }
      } else {
        debugPrint('❌ No image data received or empty');
      }
    } else {
      _lastError = message;
      _notifyListenersIfAlive();
    }
  }

  /// Lưu ảnh capture vào thư mục images_ai
  Future<void> _saveCapturedImageToFolder(Uint8List imageBytes) async {
    debugPrint('🖼️ Starting to save image: ${imageBytes.length} bytes');
    try {
      final folderPath =
          'C:/Users/sonng/OneDrive/Desktop/APPAutoVRS/BE-AutoVRS/images_ai';
      debugPrint('🖼️ Target folder: $folderPath');

      final dir = Directory(folderPath);
      if (!await dir.exists()) {
        debugPrint('🖼️ Creating directory...');
        await dir.create(recursive: true);
        debugPrint('🖼️ Directory created successfully');
      } else {
        debugPrint('🖼️ Directory already exists');
      }

      final now = DateTime.now();
      final fileName =
          'capture_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}.jpg';
      final filePath = '$folderPath/$fileName';
      debugPrint('🖼️ Full file path: $filePath');

      final file = File(filePath);

      // Test write simple content first
      debugPrint('🖼️ Testing file write...');
      await file.writeAsString('test');
      debugPrint('🖼️ Test write successful, now writing image bytes...');

      await file.writeAsBytes(imageBytes);

      // Verify file was written
      final fileExists = await file.exists();
      final fileSize = await file.length();
      debugPrint(
        '🖼️ ✅ File written - exists: $fileExists, size: $fileSize bytes',
      );
      debugPrint('🖼️ ✅ Successfully saved captured image to: $filePath');
    } catch (e) {
      debugPrint('❌ Error saving captured image: $e');
      debugPrint('❌ Stack trace: ${StackTrace.current}');
    }
  }

  /// Quay lại chế độ xem live camera
  void returnToLiveCamera() {
    _setViewingCapturedImage(false);
    _setCapturedImage(null);
    _lastDetectionResults = null;
    _lastAnalysis = null;
    debugPrint(
      'State changed: returnToLiveCamera - isViewingCapturedImage = $_isViewingCapturedImage',
    );
    _notifyListenersIfAlive();
  }

  /// Xử lý connection message
  void _handleConnectionMessage(Map<String, dynamic> data) {
    debugPrint('Connected to server: ${data['status']}');
  }

  /// Xử lý pong response
  void _handlePong(Map<String, dynamic> data) {
    debugPrint('Pong received from server');
  }

  /// Xử lý lỗi WebSocket
  void _handleError(Object error, [int? token]) {
    if (token != null && token != _connectionToken) return;

    _lastError = 'WebSocket error: $error';
    _setConnected(false);
    _notifyListenersIfAlive();
    debugPrint('WebSocket error: $error');
  }

  /// Xử lý khi kết nối bị đóng
  void _handleDisconnect([int? token]) {
    if (token != null && token != _connectionToken) return;

    _setConnected(false);
    _clearCurrentFrame();
    _notifyListenersIfAlive();
    debugPrint('WebSocket disconnected');
  }

  void debugSetCapturedState() {
    debugPrint('🔧 DEBUG: Force setting captured state');
    _setCapturedImage(_currentFrame);
    _setViewingCapturedImage(true);
    _capturedDetections = [
      {'x': 100, 'y': 100, 'width': 50, 'height': 50, 'confidence': 0.95},
    ]; // Test detection
    _notifyListenersIfAlive();
    debugPrint(
      '🔧 DEBUG: State set - isViewingCapturedImage: $_isViewingCapturedImage',
    );
  }

  /// Set captured image để hiển thị thay vì live stream
  void setCapturedImage(Uint8List imageData) {
    _setCapturedImage(imageData);
    _notifyListenersIfAlive();
    debugPrint('📸 Captured image set (${imageData.length} bytes)');
  }

  /// Set trạng thái xem captured image hay live stream
  void setViewingCapturedImage(bool isViewing) {
    _setViewingCapturedImage(isViewing);
    _notifyListenersIfAlive();
    debugPrint('🔄 Viewing captured image: $isViewing');
  }

  /// Gửi request chụp ảnh
  Future<void> captureImage({
    String? filename,
    bool enableDetection = true,
  }) async {
    debugPrint('📤 CAPTURE IMAGE CALLED (SICK Camera Mode)');

    if (!_isConnected) {
      debugPrint('📤 ERROR: Not connected to server');
      throw Exception('Not connected to camera server');
    }

    // SICK camera mode: Capture current frame and send to AI API
    if (_currentFrame == null) {
      debugPrint('📤 ERROR: No current frame available');
      throw Exception('No frame available to capture');
    }

    try {
      // Save current frame as captured image
      _setCapturedImage(_currentFrame);
      _setViewingCapturedImage(true);

      debugPrint('📸 Frame captured (${_currentFrame!.length} bytes)');

      // Send to AI detection API if enabled
      if (enableDetection) {
        await _sendToAIDetection(_currentFrame!);
      }

      _notifyListenersIfAlive();
    } catch (e) {
      _lastError = 'Capture failed: $e';
      debugPrint('❌ Capture error: $e');
      _notifyListenersIfAlive();
      rethrow;
    }
  }

  /// Send image to AI Detection API (port 8082)
  Future<void> _sendToAIDetection(Uint8List imageBytes) async {
    try {
      debugPrint('🤖 Sending to AI Detection API (port 8082)...');

      final uri = Uri.parse(AppRuntimeConfig.instance.aiDetectionUrl);

      // Convert image to base64
      final base64Image = base64Encode(imageBytes);

      // Send JSON request
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'image_base64': base64Image,
          'confidence_threshold': 0.25,
          'iou_threshold': 0.45,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // Store detection results
        _lastDetectionResults = data;
        _lastAnalysis = data['statistics'] as Map<String, dynamic>?;

        final numDefects = (data['detections'] as List?)?.length ?? 0;
        debugPrint('✅ AI Detection complete: $numDefects defects');
        debugPrint('🔍 Detection data: $data');

        _notifyListenersIfAlive();
      } else {
        _lastError = 'AI Detection failed: ${response.statusCode}';
        debugPrint('❌ AI API error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      _lastError = 'AI Detection error: $e';
      debugPrint('❌ AI Detection exception: $e');
    }
  }

  /// Gửi request lấy status
  /// DISABLED: SICK camera doesn't support JSON commands
  // Future<void> requestStatus() async {
  //   if (!_isConnected || _channel == null) {
  //     throw Exception('Not connected to server');
  //   }
  //
  //   final message = {'command': 'get_status'};
  //
  //   _channel!.sink.add(jsonEncode(message));
  // }

  /// Bật/tắt defect detection
  /// DISABLED: SICK camera doesn't support JSON commands
  /// Detection is handled separately via AI API (port 8082)
  // Future<void> setDetectionEnabled(bool enabled) async {
  //   if (!_isConnected || _channel == null) {
  //     throw Exception('Not connected to server');
  //   }
  //
  //   final message = {
  //     'command': 'set_detection',
  //     'request_id': 'detection_${DateTime.now().millisecondsSinceEpoch}',
  //     'enabled': enabled,
  //   };
  //
  //   _channel!.sink.add(jsonEncode(message));
  // }

  /// Xử lý camera status messages
  void _handleCameraStatus(Map<String, dynamic> data) {
    final status = data['status'] as String?;
    final message = data['message'] as String?;

    if (status == 'waiting') {
      debugPrint('Camera status: $message');
      // Có thể hiển thị loading indicator trong UI
    }
  }

  /// Gửi ping để test kết nối
  /// DISABLED: SICK camera only streams binary JPEG, doesn't handle JSON commands
  // Future<void> _sendPing() async {
  //   if (!_isConnected || _channel == null) return;
  //
  //   final message = {
  //     'command': 'ping',
  //     'timestamp': DateTime.now().millisecondsSinceEpoch,
  //   };
  //
  //   _channel!.sink.add(jsonEncode(message));
  // }

  /// Memory optimization: Clear old frame data
  void _clearOldFrames() {
    // Keep only current frame, clear any cached data
    // Frames are replaced in-place; keep the latest frame available for UI.

    // Force garbage collection hint
    // debugPrint('🗑️ Cleared old frame data for memory optimization');
  }

  /// Optimize memory usage by cleaning up resources
  void optimizeMemory() {
    if (_frameCount % 100 == 0) {
      // Every 100 frames
      _clearOldFrames();
    }
  }

  /// Send resolution change request to backend
  void sendResolutionChange(int width, int height) {
    if (_streamSource == AutoVRSStreamSource.rtsp) {
      debugPrint('Resolution change is ignored for direct RTSP streams');
      return;
    }

    if (_channel == null || !_isConnected) {
      debugPrint('⚠️ Cannot send resolution change: Not connected');
      return;
    }

    try {
      final message = jsonEncode({
        'type': 'change_resolution',
        'width': width,
        'height': height,
      });

      _channel!.sink.add(message);
      debugPrint('📤 Sent resolution change: ${width}x$height');
    } catch (e) {
      debugPrint('❌ Error sending resolution change: $e');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _connectionToken++;
    _notifierUpdateToken++;
    _subscription?.cancel();
    _rtspStdoutSubscription?.cancel();
    _rtspStderrSubscription?.cancel();
    _rtspProcess?.kill();
    _rtspProcess = null;
    if (_channel != null) {
      unawaited(_channel!.sink.close().catchError((_) {}));
    }
    _subscription = null;
    _channel = null;

    // Dispose ValueNotifiers
    _isConnectedNotifier.dispose();
    _currentFrameNotifier.dispose();
    _capturedImageNotifier.dispose();
    _isViewingCapturedImageNotifier.dispose();
    _frameCountNotifier.dispose();

    // Clear all data
    _currentFrame = null;
    _capturedImage = null;
    _lastDetectionResults = null;
    _lastAnalysis = null;
    _capturedDetections = null;
    _rtspBuffer.clear();

    super.dispose();
    debugPrint('🗑️ AutoVRSWebSocketService disposed and cleaned up');
  }
}
