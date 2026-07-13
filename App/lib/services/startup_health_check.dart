import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_runtime_config.dart';
import 'ai_detection_service.dart';
import 'plc_gateway_service.dart';
import 'qcamber_gerber_service.dart';

/// Trạng thái kết nối của một API backend.
class ApiStatus {
  final String name;
  final String baseUrl;
  final bool isUp;

  const ApiStatus(this.name, this.baseUrl, this.isUp);
}

/// Kiểm tra trạng thái các API backend (QCamber, PLC Gateway, AI Detection)
/// khi app khởi động, rồi tiếp tục theo dõi định kỳ để phát hiện khi một
/// dịch vụ bị mất kết nối hoặc mới kết nối lại.
///
/// Tối ưu so với bản kiểm tra cố định mỗi 15s:
/// - Interval thích ứng: kiểm tra nhanh ([_fastInterval]) khi có dịch vụ
///   đang down (phát hiện phục hồi sớm), giãn ra ([_slowInterval]) khi mọi
///   thứ đều ổn (giảm request/log khi không cần thiết).
/// - Chỉ in báo cáo đầy đủ ở lần đầu và khi có thay đổi trạng thái, tránh
///   spam console khi chạy hàng giờ.
/// - Dùng lại 1 instance service cố định thay vì tạo mới mỗi lần tick.
/// - Có thể tạm dừng ([setBusy]) khi auto workflow đang chạy nhiều request
///   liên tục tới QCamber, tránh chồng request health-check lên request
///   capture thật (QCamber xử lý HTTP trên 1 luồng GUI duy nhất).
class StartupHealthCheck {
  static const Duration _fastInterval = Duration(seconds: 5);
  static const Duration _slowInterval = Duration(seconds: 60);

  static final QCamberGerberService _qcamber = QCamberGerberService();
  static final PlcGatewayService _plcGateway = PlcGatewayService();
  static final AIDetectionService _aiDetection = AIDetectionService();

  static Timer? _timer;
  static final Map<String, bool> _lastStatus = {};
  static bool _isFirstTick = true;
  static bool _busy = false;

  /// Kiểm tra 1 lần, trả về kết quả của cả 3 dịch vụ (không in log, không
  /// ảnh hưởng lịch trình theo dõi định kỳ).
  static Future<List<ApiStatus>> run() async {
    final config = AppRuntimeConfig.instance;

    return Future.wait([
      _qcamber
          .isServerRunning()
          .then((up) => ApiStatus('QCamber', config.qcamberBaseUrl, up)),
      _plcGateway
          .isApiAvailable()
          .then((up) => ApiStatus('PLC Gateway', config.plcGatewayBaseUrl, up)),
      _aiDetection
          .checkServerHealth()
          .then((up) => ApiStatus('AI Detection', config.aiBaseUrl, up)),
    ]);
  }

  /// Đánh dấu app đang bận xử lý workflow (nhiều request QCamber liên tiếp).
  /// Trong lúc bận, health-check sẽ không gọi API — chỉ tự thử lại sau khi
  /// hết bận, tránh chồng lên các request thật.
  static void setBusy(bool busy) {
    _busy = busy;
  }

  /// Bắt đầu kiểm tra ngay lập tức rồi tự lên lịch lặp lại. Gọi [onChange]
  /// mỗi khi một dịch vụ đổi trạng thái so với lần kiểm tra trước — bao gồm
  /// cả lúc mất kết nối lẫn lúc kết nối lại. Lần đầu chỉ báo dịch vụ đang
  /// DOWN, không báo dịch vụ vốn đã UP ngay từ đầu.
  static void startMonitoring({
    required void Function(ApiStatus status) onChange,
  }) {
    _timer?.cancel();
    _lastStatus.clear();
    _isFirstTick = true;
    _scheduleTick(onChange, Duration.zero);
  }

  static void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
  }

  static void _scheduleTick(
    void Function(ApiStatus status) onChange,
    Duration delay,
  ) {
    _timer = Timer(delay, () => _tick(onChange));
  }

  static Future<void> _tick(void Function(ApiStatus status) onChange) async {
    if (_busy) {
      // Workflow đang chạy — bỏ qua lần này, thử lại sau một khoảng ngắn
      // thay vì gọi API chồng lên request capture thật.
      _scheduleTick(onChange, _fastInterval);
      return;
    }

    final results = await run();
    var anyChanged = false;

    for (final r in results) {
      final previouslyUp = _lastStatus[r.name];
      final isNewDownAtStartup = previouslyUp == null && !r.isUp;
      final isTransition = previouslyUp != null && previouslyUp != r.isUp;
      if (isNewDownAtStartup || isTransition) {
        onChange(r);
        anyChanged = true;
      }
      _lastStatus[r.name] = r.isUp;
    }

    if (_isFirstTick || anyChanged) {
      _printReport(results);
    }
    _isFirstTick = false;

    final anyDown = results.any((r) => !r.isUp);
    _scheduleTick(onChange, anyDown ? _fastInterval : _slowInterval);
  }

  static void _printReport(List<ApiStatus> results) {
    final line = ''.padRight(60, '=');
    debugPrint(line);
    debugPrint('🔍 KIỂM TRA TRẠNG THÁI API');
    debugPrint(line);
    for (final r in results) {
      final icon = r.isUp ? '✅' : '❌';
      final status = r.isUp ? 'OK' : 'KHÔNG PHẢN HỒI';
      debugPrint('$icon ${r.name.padRight(14)} ${r.baseUrl} -> $status');
    }
    final downCount = results.where((r) => !r.isUp).length;
    if (downCount > 0) {
      debugPrint('⚠️  $downCount/${results.length} dịch vụ KHÔNG hoạt động');
    } else {
      debugPrint('✅ Tất cả ${results.length} dịch vụ đang hoạt động');
    }
    debugPrint(line);
  }
}
