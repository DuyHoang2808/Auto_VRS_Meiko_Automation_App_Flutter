import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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

  /// Chiều rộng khung PREVIEW lấy ra từ RTSP.
  ///
  /// Luồng gốc là 1080p. Trước đây ffmpeg được yêu cầu encode MJPEG `-q:v 5`
  /// ở nguyên 1920x1080 rồi bơm qua pipe stdout: mỗi JPEG ~150-250 KB, lớn
  /// hơn cả buffer pipe (~64 KB) của Windows, nên ffmpeg block ở `write()`
  /// gần như mỗi frame. Trong lúc block nó KHÔNG đọc socket RTSP nữa ->
  /// mediamtx coi reader quá chậm và đóng kết nối, đúng chuỗi lỗi thấy trong
  /// log: `corrupted macroblock` -> `Failed reading RTSP data: End of file`
  /// -> `Error number -10054` (WSAECONNRESET).
  ///
  /// Preview chỉ được vẽ trong một ô vuông vài trăm px nên 960 là dư. Ảnh đưa
  /// vào AI thì KHÔNG dùng frame preview này - xem [grabFullResolutionFrame].
  static const int rtspPreviewWidth = 960;

  /// Ngưỡng coi như mất đồng bộ khung JPEG. Một JPEG preview ở
  /// [rtspPreviewWidth] chỉ cỡ vài chục KB, nên vượt mức này nghĩa là buffer
  /// đang chứa rác chứ không phải một frame chưa đủ.
  static const int _rtspMaxFrameBytes = 4 * 1024 * 1024;

  static const Duration _rtspRetryBaseDelay = Duration(seconds: 2);
  static const Duration _rtspRetryMaxDelay = Duration(seconds: 30);

  /// Khớp mọi dòng log ffmpeg phát ra từ DECODER h264 - tag dạng
  /// `[h264 @ 0x...]`, `[dec:h264 @ 0x...]`, `[vist#0:0/h264 @ 0x...]`.
  ///
  /// Mỗi macroblock hỏng sinh 2-3 dòng nên chúng làm loãng hết terminal, trong
  /// khi thông tin thì gần như bằng 0: corruption đến từ phía nguồn/đường mạng
  /// chứ không phải từ app (một reader ffmpeg không có backpressure cũng thấy
  /// y hệt), và ffmpeg tự bỏ macroblock hỏng rồi giải mã tiếp.
  ///
  /// Lọc theo TAG chứ không theo nội dung: decoder có hàng chục thông báo khác
  /// nhau (`Invalid level prefix`, `out of range intra chroma pred mode`,
  /// `cbp too large`, `Missing reference picture`...) nên liệt kê nội dung sẽ
  /// luôn thiếu. Quan trọng hơn, cách này KHÔNG chặn log của demuxer RTSP
  /// (`[in#0/rtsp @ ...] Failed reading RTSP data`, `Error during demuxing`) -
  /// đó là dấu hiệu luồng chết, phải luôn thấy.
  static final RegExp _ffmpegDecoderNoise = RegExp(r'\[[^\]]*h264 @ ');

  /// Bao lâu thì in 1 dòng tổng kết số log đã bỏ qua. Giữ lại tín hiệu này để
  /// nếu tỉ lệ corruption tăng vọt thì vẫn nhận ra, mà không phải chịu hàng
  /// trăm dòng mỗi phút.
  static const Duration _ffmpegNoiseReportInterval = Duration(seconds: 60);

  // SICK Camera WebSocket Stream (port 8999)
  // Old C++ module was on ws://127.0.0.1:12345/

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Process? _rtspProcess;
  StreamSubscription<List<int>>? _rtspStdoutSubscription;
  StreamSubscription<String>? _rtspStderrSubscription;

  // Buffer byte thô đọc từ stdout của ffmpeg.
  //
  // Dùng Uint8List + độ dài tường minh thay cho `List<int>`: việc tìm marker
  // phải quét tuyến tính toàn buffer, và trên growable List<int> mỗi phần tử
  // là một slot Object? nên vòng quét chậm hơn nhiều lần - chính vòng quét đó
  // chạy trên UI isolate và là một phần lý do pipe không được hút kịp.
  Uint8List _rtspBuffer = Uint8List(0);
  int _rtspBufferLength = 0;

  // Vị trí đã quét xong khi đi tìm EOI (0xFFD9). Bản cũ luôn quét lại từ
  // index 2 mỗi lần có chunk mới -> O(n^2) trên mỗi frame.
  int _rtspScanOffset = 0;

  // Bộ đếm log decoder đã bỏ qua, để in tổng kết định kỳ.
  final Stopwatch _ffmpegNoiseWindow = Stopwatch();
  int _ffmpegNoiseCount = 0;
  // Dòng ffmpeg vừa rồi có bị bỏ qua hay không - dùng để bỏ luôn dòng
  // "Last message repeated N times" đi kèm, nếu không nó sẽ đứng trơ ra mà
  // không còn thông báo gốc nào ở trên.
  bool _lastFfmpegLineSuppressed = false;

  Timer? _rtspRetryTimer;
  int _rtspRetryAttempt = 0;
  // true khi luồng bị ngắt do người dùng/đổi nguồn video, để retry tự động
  // không hồi sinh một luồng đã được chủ động tắt.
  bool _rtspStoppedByUser = false;

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

  /// Mở luồng RTSP theo yêu cầu của người dùng (dialog nguồn video, khởi động
  /// app, đổi endpoint). Reset bộ đếm backoff để lần thử đầu tiên không bị
  /// trễ theo lịch retry của phiên trước.
  Future<bool> connectRtsp({
    String? rtspUrl,
    String? ffmpegPath,
    int? fps,
  }) async {
    _cancelRtspRetry();
    _rtspRetryAttempt = 0;
    return _openRtspStream(rtspUrl: rtspUrl, ffmpegPath: ffmpegPath, fps: fps);
  }

  Future<bool> _openRtspStream({
    String? rtspUrl,
    String? ffmpegPath,
    int? fps,
  }) async {
    try {
      await disconnect(notify: false);
      // `disconnect` bật cờ "người dùng tự tắt" để chặn retry; ở đây ta đang
      // chủ động mở lại nên phải hạ cờ, nếu không luồng sẽ không bao giờ tự
      // kết nối lại sau lần chết đầu tiên.
      _rtspStoppedByUser = false;
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
        // scale=W:-2 giữ đúng tỉ lệ khung và làm tròn chiều cao về số chẵn
        // (yuvj420p của MJPEG yêu cầu kích thước chia hết cho 2).
        '-vf',
        'fps=$_rtspFps,scale=$rtspPreviewWidth:-2',
        '-f',
        'image2pipe',
        '-vcodec',
        'mjpeg',
        // q:v 8 thay vì 5: preview không cần chất lượng lưu trữ, và mỗi bậc
        // q cắt thêm byte phải đi qua pipe.
        '-q:v',
        '8',
        'pipe:1',
      ];

      final process = await Process.start(
        _ffmpegPath,
        args,
      ).timeout(const Duration(seconds: 8));
      _rtspProcess = process;
      _resetRtspBuffer();

      _rtspStdoutSubscription = process.stdout.listen(
        (chunk) => _handleRtspBytes(chunk, token),
        onError: (error) => _handleError(error, token),
      );
      _rtspStderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleFfmpegLogLine);

      process.exitCode.then((code) {
        if (_isDisposed) return;
        if (token == _connectionToken &&
            _streamSource == AutoVRSStreamSource.rtsp &&
            identical(_rtspProcess, process)) {
          _setConnected(false);
          // KHÔNG xoá frame cuối: giữ nó lại để preview đứng hình trong lúc
          // chờ kết nối lại thay vì nháy sang "AutoVRS Disconnected" rồi
          // quay lại. Badge trạng thái đã đổi sang đỏ nhờ _setConnected.
          _lastError = code == 0
              ? 'RTSP stream stopped'
              : 'RTSP stream stopped (ffmpeg exit code $code)';
          _notifyListenersIfAlive();
          _scheduleRtspRetry();
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
      // Server chưa lên / mất mạng cũng phải thử lại, không chỉ trường hợp
      // ffmpeg chạy được rồi mới chết.
      _scheduleRtspRetry();
      return false;
    }
  }

  /// Hẹn kết nối lại RTSP với backoff luỹ tiến (2s, 4s, 8s... tối đa 30s).
  ///
  /// Trước đây khi ffmpeg chết không có cơ chế nào thử lại: luồng chỉ sống lại
  /// nếu người dùng tình cờ điều hướng qua Manual VRS (nơi có gọi
  /// `connectLastSource`). Đó là lý do log cũ có những dòng "Connected to RTSP
  /// stream" rải rác không theo chu kỳ nào.
  void _scheduleRtspRetry() {
    if (_isDisposed || _rtspStoppedByUser) return;
    if (_streamSource != AutoVRSStreamSource.rtsp) return;
    // Đã có hẹn rồi thì không xếp thêm - cả `exitCode` lẫn `onError` của
    // stdout đều có thể bắn khi luồng chết, và hai lần hẹn sẽ tạo ra hai
    // tiến trình ffmpeg cùng đọc một stream.
    if (_rtspRetryTimer != null) return;

    _rtspRetryAttempt++;
    final backoffMs =
        _rtspRetryBaseDelay.inMilliseconds *
        (1 << (_rtspRetryAttempt - 1).clamp(0, 5));
    final delay = Duration(
      milliseconds: backoffMs.clamp(
        _rtspRetryBaseDelay.inMilliseconds,
        _rtspRetryMaxDelay.inMilliseconds,
      ),
    );

    debugPrint(
      'RTSP: mất luồng, thử kết nối lại lần #$_rtspRetryAttempt '
      'sau ${delay.inSeconds}s',
    );

    _rtspRetryTimer = Timer(delay, () {
      _rtspRetryTimer = null;
      if (_isDisposed || _rtspStoppedByUser) return;
      if (_streamSource != AutoVRSStreamSource.rtsp) return;
      _openRtspStream();
    });
  }

  void _cancelRtspRetry() {
    _rtspRetryTimer?.cancel();
    _rtspRetryTimer = null;
  }

  /// In log của ffmpeg, nhưng chặn phần nhiễu từ decoder h264
  /// (xem [_ffmpegDecoderNoise]) và thay bằng 1 dòng tổng kết mỗi
  /// [_ffmpegNoiseReportInterval].
  void _handleFfmpegLogLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return;

    final isNoise =
        _ffmpegDecoderNoise.hasMatch(text) ||
        (_lastFfmpegLineSuppressed &&
            text.startsWith('Last message repeated'));

    if (!isNoise) {
      _lastFfmpegLineSuppressed = false;
      debugPrint('RTSP/ffmpeg: $text');
      return;
    }

    _lastFfmpegLineSuppressed = true;
    _ffmpegNoiseCount++;
    if (!_ffmpegNoiseWindow.isRunning) {
      _ffmpegNoiseWindow.start();
      return;
    }
    if (_ffmpegNoiseWindow.elapsed < _ffmpegNoiseReportInterval) return;

    debugPrint(
      'RTSP/ffmpeg: bỏ qua $_ffmpegNoiseCount dòng lỗi giải mã h264 trong '
      '${_ffmpegNoiseWindow.elapsed.inSeconds}s (corruption từ phía nguồn, '
      'không phải từ app)',
    );
    _ffmpegNoiseCount = 0;
    _ffmpegNoiseWindow
      ..reset()
      ..start();
  }

  /// Ngắt kết nối WebSocket
  Future<void> disconnect({bool notify = true}) async {
    _connectionToken++;
    _notifierUpdateToken++;
    // Ngắt chủ động: huỷ mọi lịch retry đang treo, nếu không luồng RTSP vừa
    // tắt sẽ tự bật lại sau vài giây (kể cả khi người dùng đã đổi sang nguồn
    // WebSocket).
    _rtspStoppedByUser = true;
    _cancelRtspRetry();

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
    _resetRtspBuffer();

    // Xả nốt phần đã đếm trước khi reset, nếu không một luồng chết trước mốc
    // 60s sẽ mang theo toàn bộ số liệu corruption mà không in ra dòng nào.
    if (_ffmpegNoiseCount > 0) {
      debugPrint(
        'RTSP/ffmpeg: bỏ qua $_ffmpegNoiseCount dòng lỗi giải mã h264 trong '
        '${_ffmpegNoiseWindow.elapsed.inSeconds}s (luồng vừa dừng)',
      );
    }
    _ffmpegNoiseCount = 0;
    _lastFfmpegLineSuppressed = false;
    _ffmpegNoiseWindow
      ..stop()
      ..reset();

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
      _appendToRtspBuffer(chunk);

      // Chỉ đẩy frame MỚI NHẤT của lượt parse này lên UI.
      //
      // Bản cũ gọi `_setCurrentFrame` cho mọi frame tìm thấy trong buffer, và
      // mỗi lần lại schedule một `addPostFrameCallback` giữ tham chiếu tới cả
      // buffer JPEG (xem `_setValueNotifierIfAlive`). Khi app render không
      // kịp - hoặc cửa sổ bị minimize nên Flutter ngừng sinh frame - hàng
      // callback đó dồn lại và giữ sống toàn bộ frame trong bộ nhớ, trong khi
      // UI cuối cùng cũng chỉ vẽ được frame cuối.
      Uint8List? latestFrame;

      while (true) {
        final start = _indexOfRtspMarker(0xd8, 0);
        if (start < 0) {
          // Chưa thấy SOI: dữ liệu đang có là rác. Giữ lại 1 byte cuối vì nó
          // có thể là nửa đầu (0xFF) của marker bị chunk cắt đôi.
          if (_rtspBufferLength > 1) {
            _discardRtspBufferFront(_rtspBufferLength - 1);
          }
          break;
        }
        if (start > 0) {
          _discardRtspBufferFront(start);
        }

        final end = _indexOfRtspMarker(
          0xd9,
          _rtspScanOffset < 2 ? 2 : _rtspScanOffset,
        );
        if (end < 0) {
          if (_rtspBufferLength > _rtspMaxFrameBytes) {
            // Không JPEG preview nào lớn thế này -> đã mất đồng bộ. Xả SẠCH.
            // Bản cũ giữ lại 2 byte cuối, và chính 2 byte rác đó lại nằm
            // trước SOI của frame kế tiếp.
            debugPrint(
              'RTSP: buffer $_rtspBufferLength byte không tìm thấy EOI, '
              'xả buffer để đồng bộ lại',
            );
            _resetRtspBuffer();
            break;
          }
          // Nhớ đã quét tới đâu để chunk sau không quét lại từ đầu. Lùi 1
          // byte vì marker có thể vắt qua ranh giới hai chunk.
          _rtspScanOffset = _rtspBufferLength > 1 ? _rtspBufferLength - 1 : 2;
          break;
        }

        final frame = Uint8List(end + 2);
        frame.setRange(0, end + 2, _rtspBuffer);
        latestFrame = frame;

        _discardRtspBufferFront(end + 2);
        _rtspScanOffset = 0;
      }

      if (latestFrame != null) {
        // Đã nhận được frame thật -> luồng lành, reset backoff để lần chết
        // sau được thử lại ngay từ 2s chứ không kế thừa delay 30s cũ.
        _rtspRetryAttempt = 0;
        _setCurrentFrame(latestFrame);
      }
    } catch (e) {
      _lastError = 'RTSP frame parse error: $e';
      debugPrint(_lastError);
    }
  }

  /// Tìm marker JPEG `0xFF <second>` trong phần đang dùng của [_rtspBuffer].
  int _indexOfRtspMarker(int second, int startIndex) {
    final buffer = _rtspBuffer;
    final limit = _rtspBufferLength - 1;
    for (var i = startIndex; i < limit; i++) {
      if (buffer[i] == 0xff && buffer[i + 1] == second) {
        return i;
      }
    }
    return -1;
  }

  void _appendToRtspBuffer(List<int> chunk) {
    final needed = _rtspBufferLength + chunk.length;
    if (needed > _rtspBuffer.length) {
      var capacity = _rtspBuffer.isEmpty ? 128 * 1024 : _rtspBuffer.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      final grown = Uint8List(capacity);
      grown.setRange(0, _rtspBufferLength, _rtspBuffer);
      _rtspBuffer = grown;
    }
    _rtspBuffer.setRange(_rtspBufferLength, needed, chunk);
    _rtspBufferLength = needed;
  }

  /// Bỏ [count] byte đầu buffer, dồn phần còn lại về đầu.
  void _discardRtspBufferFront(int count) {
    if (count <= 0) return;
    if (count >= _rtspBufferLength) {
      _resetRtspBuffer();
      return;
    }
    // setRange trên cùng một Uint8List có ngữ nghĩa memmove nên phần chồng
    // lấn được xử lý đúng.
    _rtspBuffer.setRange(0, _rtspBufferLength - count, _rtspBuffer, count);
    _rtspBufferLength -= count;
    _rtspScanOffset = _rtspScanOffset > count ? _rtspScanOffset - count : 0;
  }

  void _resetRtspBuffer() {
    _rtspBufferLength = 0;
    _rtspScanOffset = 0;
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
            debugPrint('❌ JSON không phải Map: ${_previewForLog(data)}');
          }
        } catch (e) {
          // Cắt ngắn: message có thể là 1 frame JPEG base64 vài trăm KB.
          debugPrint('❌ Không parse được JSON: ${_previewForLog(message)}');
        }
      } else {
        debugPrint(
          '❓ Message không xác định kiểu: ${_previewForLog(message)}',
        );
      }
    } catch (e) {
      debugPrint('❌ Lỗi khi xử lý message: $e');
    }
  }

  /// Rút ngắn 1 payload để đưa vào log.
  ///
  /// Message trên kênh này có thể là 1 khung JPEG base64 vài trăm KB; in thẳng
  /// ra console vừa không đọc được vừa làm chậm cả app.
  static String _previewForLog(Object? value, {int maxChars = 200}) {
    final text = value?.toString() ?? 'null';
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}... (${text.length} ký tự)';
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
        // Chỉ log số lượng. In cả list (và từng phần tử) làm console không đọc
        // được, mà bản thân payload có thể mang ảnh base64.
        debugPrint('🔍 DETECTION DATA: $numDefects defects found');
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
    final previewFrame = _currentFrame;
    if (previewFrame == null) {
      debugPrint('📤 ERROR: No current frame available');
      throw Exception('No frame available to capture');
    }

    try {
      // Với RTSP, frame preview đã bị scale xuống `rtspPreviewWidth` nên
      // không dùng được làm input cho AI. Lấy riêng một khung full-res; nếu
      // không lấy được thì mới đành dùng frame preview.
      final fullFrame = await grabFullResolutionFrame();
      final frameToCapture = fullFrame ?? previewFrame;

      // Save current frame as captured image
      _setCapturedImage(frameToCapture);
      _setViewingCapturedImage(true);

      debugPrint(
        '📸 Frame captured (${frameToCapture.length} bytes, '
        '${fullFrame != null ? 'full-res' : 'preview'})',
      );

      // Send to AI detection API if enabled
      if (enableDetection) {
        await _sendToAIDetection(frameToCapture);
      }

      _notifyListenersIfAlive();
    } catch (e) {
      _lastError = 'Capture failed: $e';
      debugPrint('❌ Capture error: $e');
      _notifyListenersIfAlive();
      rethrow;
    }
  }

  /// Chụp 1 khung ở ĐỘ PHÂN GIẢI GỐC từ RTSP bằng một ffmpeg one-shot.
  ///
  /// Luồng preview bị scale xuống [rtspPreviewWidth] để không làm nghẽn pipe
  /// stdout (xem ghi chú ở [rtspPreviewWidth]), nhưng ảnh đưa vào AI detection
  /// thì phải là ảnh gốc: lỗi mạch cỡ vài chục micromet biến mất khi ảnh bị
  /// thu nhỏ 2 lần. Tiến trình này chỉ sống vài trăm ms mỗi lần người dùng bấm
  /// chụp nên không ảnh hưởng tới luồng preview đang chạy.
  ///
  /// Trả `null` nếu nguồn video không phải RTSP hoặc không lấy được khung -
  /// caller tự fallback sang frame preview.
  Future<Uint8List?> grabFullResolutionFrame() async {
    if (_streamSource != AutoVRSStreamSource.rtsp) return null;
    if (_rtspUrl.isEmpty || _ffmpegPath.isEmpty) return null;

    Process? process;
    try {
      process = await Process.start(_ffmpegPath, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-rtsp_transport',
        'tcp',
        '-i',
        _rtspUrl,
        '-frames:v',
        '1',
        '-an',
        '-f',
        'image2pipe',
        '-vcodec',
        'mjpeg',
        '-q:v',
        '2',
        'pipe:1',
      ]).timeout(const Duration(seconds: 8));

      // stderr phải được drain, nếu không ffmpeg có thể block khi ghi log và
      // treo luôn cả việc ghi stdout.
      final stderrDrained = process.stderr.drain<void>().catchError((_) {});

      final builder = BytesBuilder(copy: false);
      await process.stdout
          .forEach(builder.add)
          .timeout(const Duration(seconds: 12));
      await stderrDrained;

      final bytes = builder.takeBytes();
      if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
        debugPrint(
          'RTSP snapshot: dữ liệu trả về không phải JPEG '
          '(${bytes.length} byte), dùng frame preview',
        );
        return null;
      }
      debugPrint('RTSP snapshot: lấy được khung full-res ${bytes.length} byte');
      return bytes;
    } catch (e) {
      debugPrint('RTSP snapshot thất bại ($e), dùng frame preview');
      return null;
    } finally {
      process?.kill();
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
        // KHÔNG log cả `data`: response chứa `processed_image_base64`, in ra là
        // đổ vài trăm KB base64 vào console mỗi lần chụp.
        debugPrint('✅ AI Detection complete: $numDefects defects');

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
    _rtspStoppedByUser = true;
    _cancelRtspRetry();
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
    _rtspBuffer = Uint8List(0);
    _resetRtspBuffer();

    super.dispose();
    debugPrint('🗑️ AutoVRSWebSocketService disposed and cleaned up');
  }
}
