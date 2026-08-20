import 'dart:convert';
import 'package:autovrs_app/core/app_runtime_config.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Service để kết nối với QCamber API (Port 8686)
/// Lấy ảnh Gerber từ tọa độ defect
class QCamberGerberService extends ChangeNotifier {
  static const String _defaultLayer = 'l1'; // Changed from l2 to l1
  static const double _defaultZoom = 2024.0;

  bool _isLoading = false;
  String? _lastError;
  Uint8List? _gerberImage;
  Map<String, dynamic>? _lastMetadata;
  // Tăng mỗi lần captureGerberImage được gọi; dùng để bỏ qua kết quả của
  // request cũ khi nó trả về sau một request mới hơn (tránh hiển thị nhầm
  // ảnh Gerber của defect trước đó).
  int _requestId = 0;

  // QCamber trả HTTP 409 kèm {currentJobName, requestedJobName, ...} khi file
  // thiết kế đang mở trong QCamber KHÁC với mã hàng đang chạy - tức operator
  // (hoặc ai đó) đã mở nhầm file thiết kế mạch. Tách riêng khỏi `_lastError`
  // (chỉ là chuỗi hiển thị) để màn hình gọi phân biệt được với lỗi tải ảnh
  // thông thường và có thể cảnh báo rõ + dừng chu trình.
  bool _wrongJobOpen = false;
  String? _openJobName;
  String? _requestedJobNameOnError;

  bool get isLoading => _isLoading;
  String? get lastError => _lastError;
  Uint8List? get gerberImage => _gerberImage;
  Map<String, dynamic>? get lastMetadata => _lastMetadata;
  bool get hasImage => _gerberImage != null;
  bool get wrongJobOpen => _wrongJobOpen;
  String? get openJobName => _openJobName;
  String? get requestedJobNameOnError => _requestedJobNameOnError;
  String get _baseUrl => AppRuntimeConfig.instance.qcamberBaseUrl;

  /// Cắt ngắn body của response để đưa vào log / `lastError`.
  ///
  /// Response của QCamber có thể mang ảnh (base64) nên phải giới hạn: chuỗi này
  /// vừa vào console vừa được hiển thị lên UI.
  static String _shortBody(String body, {int maxChars = 200}) {
    if (body.length <= maxChars) return body;
    return '${body.substring(0, maxChars)}... (${body.length} ký tự)';
  }

  /// Kiểm tra QCamber server có đang chạy không (GET /api/status)
  Future<bool> isServerRunning({int timeout = 2}) async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/status'))
          .timeout(Duration(seconds: timeout));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Báo trước cho QCamber mở sẵn job [jobName] - gọi ngay khi operator chọn
  /// model, TRƯỚC khi máy bắt đầu chạy (xem select_model_screen.dart), để lúc
  /// soi lỗi thật (`captureGerberImage`/`/api/capture`) job đã mở sẵn -
  /// `ensureJobOpen` phía QCamber bỏ qua toàn bộ bước mở job, nên điểm lỗi
  /// đầu tiên nhanh như các điểm sau, không còn bị delay do phải mở job.
  ///
  /// Không chụp ảnh gì cả, chỉ mở/chuyển job rồi trả về ngay. An toàn khi gọi
  /// nhiều lần cho cùng 1 job - QCamber trả `alreadyOpen:true` gần như tức
  /// thì nếu job đó đã mở sẵn, không tốn công mở lại. Timeout dài (job có thể
  /// mất vài chục giây để mở lần đầu) nhưng bên gọi nên gọi không chờ
  /// (`unawaited`) vì đây chỉ là tối ưu độ trễ, không phải điều kiện bắt buộc.
  Future<PreloadJobResponse> preloadJob(String jobName) async {
    try {
      debugPrint('🔍 QCamber: Preloading job=$jobName');

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/preload'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'jobName': jobName}),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final result = PreloadJobResponse.fromJson(jsonDecode(response.body));
        debugPrint(
          '✅ QCamber Preload: job=$jobName alreadyOpen=${result.alreadyOpen}',
        );
        return result;
      }

      final message =
          'HTTP ${response.statusCode}: ${_shortBody(response.body)}';
      debugPrint('❌ QCamber Preload Error: $message');
      return PreloadJobResponse(
        success: false,
        jobName: jobName,
        message: message,
      );
    } catch (e) {
      debugPrint('❌ QCamber Preload Exception: $e');
      return PreloadJobResponse(
        success: false,
        jobName: jobName,
        message: 'Error: $e',
      );
    }
  }

  /// Gửi request tới QCamber để lấy ảnh Gerber
  ///
  /// Parameters:
  /// - modelName: Tên model (job name) từ tbModel.name
  /// - coordinates: Map chứa x, y từ defect ('{"x": 150, "y": 250}')
  /// - defectType: (optional) Loại defect để hiển thị
  /// - layerName: (default: 'l2') Tên layer
  /// - zoom: (default: 128.0) Mức zoom
  /// - timeout: (default: 8) Timeout in seconds
  ///
  /// Returns: true nếu thành công, false nếu lỗi
  Future<bool> captureGerberImage({
    required String modelName,
    required Map<String, dynamic> coordinates,
    String? defectType,
    String layerName = _defaultLayer,
    double zoom = _defaultZoom,
    int timeout = 8,
  }) async {
    final requestId = ++_requestId;
    _isLoading = true;
    _lastError = null;
    _gerberImage = null;
    _lastMetadata = null;
    _wrongJobOpen = false;
    _openJobName = null;
    _requestedJobNameOnError = null;
    notifyListeners();

    try {
      debugPrint(
        '🔍 QCamber: Requesting gerber image for model=$modelName, coords=$coordinates, layer=$layerName, zoom=$zoom',
      );

      // Extract x, y từ coordinates
      final x = _extractCoordinate(coordinates, 'x');
      final y = _extractCoordinate(coordinates, 'y');

      if (x == null || y == null) {
        throw Exception(
          'Tọa độ không hợp lệ: x=$x, y=$y. Coordinates format: {"x": 150, "y": 250}',
        );
      }

      // Build request payload
      final payload = {
        'jobName': modelName,
        'layerName': layerName,
        'x': x,
        'y': y,
        'zoom': zoom,
      };

      debugPrint('📤 QCamber Payload: ${jsonEncode(payload)}');

      // Send POST request
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/capture'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(
            Duration(seconds: timeout),
            onTimeout: () {
              throw TimeoutException(
                'QCamber request timeout after $timeout seconds',
              );
            },
          );

      // Nếu đã có request mới hơn bắt đầu trong lúc chờ QCamber phản hồi,
      // bỏ kết quả này để tránh đè lên ảnh của defect hiện tại.
      if (requestId != _requestId) {
        debugPrint(
          '⚠️ QCamber: discarding stale response (request=$requestId, current=$_requestId)',
        );
        return false;
      }

      debugPrint('📥 QCamber Response: Status=${response.statusCode}');

      if (response.statusCode != 200) {
        // Cắt ngắn body: cùng lý do như nhánh JSON bên dưới.
        _lastError = 'HTTP ${response.statusCode}: ${_shortBody(response.body)}';
        debugPrint('❌ QCamber Error: $_lastError');

        // QCamber báo đang mở SAI file thiết kế (job) so với mã hàng đang
        // chạy - ảnh Gerber hiển thị sẽ là của board KHÁC, nguy hiểm hơn hẳn
        // 1 lỗi tải ảnh thông thường vì operator có thể đối chiếu nhầm thiết
        // kế. Nhận diện qua đúng shape QCamber trả (409 + currentJobName +
        // requestedJobName) thay vì so khớp chuỗi `error` - bền hơn nếu message
        // đổi chữ.
        if (response.statusCode == 409) {
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map &&
                decoded['currentJobName'] != null &&
                decoded['requestedJobName'] != null) {
              _wrongJobOpen = true;
              _openJobName = decoded['currentJobName'].toString();
              _requestedJobNameOnError = decoded['requestedJobName'].toString();
            }
          } catch (_) {}
        }

        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Check content type
      final contentType = response.headers['content-type'] ?? '';
      debugPrint('📋 Content-Type: $contentType');

      if (contentType.contains('image/png')) {
        // Nhận trực tiếp ảnh PNG
        _gerberImage = response.bodyBytes;
        _lastMetadata = {
          'modelName': modelName,
          'layerName': layerName,
          'x': x,
          'y': y,
          'zoom': zoom,
          'defectType': defectType,
          'imageSize': _gerberImage!.length,
          'timestamp': DateTime.now().toIso8601String(),
        };

        debugPrint(
          '✅ QCamber Success: Received PNG image (${_gerberImage!.length} bytes)',
        );
        _isLoading = false;
        notifyListeners();
        return true;
      } else if (contentType.contains('application/json')) {
        // JSON response (acknowledgment) - KHÔNG đưa body vào thông báo.
        //
        // QCamber trả ảnh dạng base64 trong JSON, nên in cả `jsonResponse` là đổ
        // vài trăm KB base64 vào console MỖI lần tải Gerber (tức mỗi lần chuyển
        // lỗi ở VRS thủ công). Chuỗi này còn gán vào `_lastError` - thứ được
        // hiện lên UI - nên base64 có thể tràn cả ra màn hình.
        final jsonResponse = jsonDecode(response.body);
        final keys = jsonResponse is Map
            ? jsonResponse.keys.join(', ')
            : jsonResponse.runtimeType.toString();
        _lastMetadata = {
          'modelName': modelName,
          'layerName': layerName,
          'responseKeys': keys,
          'responseBytes': response.bodyBytes.length,
        };
        _lastError =
            'QCamber trả JSON chứ không phải ảnh PNG '
            '(khoá: $keys; ${response.bodyBytes.length} byte).';
        debugPrint('⚠️ QCamber: $_lastError');
        _isLoading = false;
        notifyListeners();
        return false;
      } else {
        _lastError = 'Unexpected content type: $contentType';
        debugPrint('❌ QCamber: $_lastError');
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } on TimeoutException catch (e) {
      if (requestId != _requestId) return false;
      _lastError = 'Timeout: ${e.message}';
      debugPrint('❌ QCamber Timeout: $_lastError');
      _isLoading = false;
      notifyListeners();
      return false;
    } on http.ClientException catch (e) {
      if (requestId != _requestId) return false;
      _lastError =
          'Không kết nối được QCamber tại $_baseUrl. Vui lòng kiểm tra QCamber đã mở chưa. ($e)';
      debugPrint('❌ QCamber Connection Error: $_lastError');
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      if (requestId != _requestId) return false;
      _lastError = 'Error: $e';
      debugPrint('❌ QCamber Exception: $_lastError');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Extract numeric value từ coordinates map
  /// Hỗ trợ cả JSON string và Map object
  double? _extractCoordinate(Map<String, dynamic> coordinates, String key) {
    try {
      final value = coordinates[key];
      if (value == null) return null;

      if (value is num) {
        return value.toDouble();
      } else if (value is String) {
        return double.tryParse(value);
      }
      return null;
    } catch (e) {
      debugPrint('Error extracting coordinate $key: $e');
      return null;
    }
  }

  /// Parse coordinates string thành Map
  /// Hỗ trợ các format:
  /// 1. JSON format: '{"x": 150.5, "y": 250.3}'
  /// 2. Comma format: '180.3,95.1'
  /// 3. Semicolon format: '1.518795;2.0109942'
  static Map<String, dynamic>? parseCoordinatesString(String coordinatesStr) {
    try {
      if (coordinatesStr.isEmpty) return null;

      // Format 1: JSON string '{"x": 150, "y": 250}'
      if (coordinatesStr.startsWith('{')) {
        final parsed = jsonDecode(coordinatesStr);
        if (parsed is Map<String, dynamic>) {
          return parsed;
        }
        return null;
      }

      // Format 2: Comma-separated 'x,y' (e.g., '180.3,95.1')
      if (coordinatesStr.contains(',')) {
        final parts = coordinatesStr.split(',');
        if (parts.length >= 2) {
          final x = double.tryParse(parts[0].trim());
          final y = double.tryParse(parts[1].trim());
          if (x != null && y != null) {
            return {'x': x, 'y': y};
          }
        }
        return null;
      }

      // Format 3: Semicolon-separated 'x;y' (e.g., '1.518795;2.0109942')
      if (coordinatesStr.contains(';')) {
        final parts = coordinatesStr.split(';');
        if (parts.length >= 2) {
          final x = double.tryParse(parts[0].trim());
          final y = double.tryParse(parts[1].trim());
          if (x != null && y != null) {
            return {'x': x, 'y': y};
          }
        }
        return null;
      }

      // Không nhận diện được format
      debugPrint('Warning: Unknown coordinate format: $coordinatesStr');
      return null;
    } catch (e) {
      debugPrint('Error parsing coordinates: $e');
      return null;
    }
  }

  /// Clear cached image
  void clearImage() {
    _gerberImage = null;
    _lastMetadata = null;
    _lastError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    clearImage();
    super.dispose();
  }
}

/// Response from POST /api/preload
class PreloadJobResponse {
  final bool success;
  final String? jobName;
  final bool alreadyOpen;
  final String? requestId;
  final String? message;

  PreloadJobResponse({
    required this.success,
    this.jobName,
    this.alreadyOpen = false,
    this.requestId,
    this.message,
  });

  factory PreloadJobResponse.fromJson(Map<String, dynamic> json) {
    return PreloadJobResponse(
      success: json['status'] == 'ok',
      jobName: json['jobName']?.toString(),
      alreadyOpen: json['alreadyOpen'] ?? false,
      requestId: json['requestId']?.toString(),
    );
  }
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);

  @override
  String toString() => 'TimeoutException: $message';
}
