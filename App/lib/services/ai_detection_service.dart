import 'dart:convert';
import 'dart:io';
import 'package:autovrs_app/core/app_runtime_config.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Bộ loại lỗi CHUẨN của mô hình AI - chép đúng từ `class_names_vi` trong
/// `BE_tensorRT/ai_detection_api.py` (key = tên lớp mô hình dùng, value = tên
/// hiển thị tiếng Việt cho người vận hành).
///
/// Dùng làm danh sách cho người vận hành chọn loại lỗi khi phán định NG ở VRS
/// Thủ công. LƯU vào DB (`tbDefect.human_type`) là KEY, không phải value: nhãn
/// phải trùng đúng tên lớp mô hình thì sau này mới đem đi huấn luyện/đánh giá
/// lại được. Cột `ai_type` cũ đang lẫn cả 2 cách viết cho cùng 1 loại lỗi
/// ('DiVat' lẫn 'Di Vat') vì code cũ ghi `classNameVi` - đó là lý do cột mới
/// chỉ nhận key.
///
/// Nếu mô hình đổi bộ lớp, sửa file Python TRƯỚC rồi đồng bộ lại đây.
const Map<String, String> kDefectClassNames = {
  'BamDinhKhongTot': 'Bám Dính Không Tốt',
  'ChamKim': 'Châm Kim',
  'DiVat': 'Dị Vật',
  'DiVatDuongMach': 'Dị Vật Đường Mạch',
  'KhuyetMach': 'Khuyết Mạch',
  'NganMach': 'Ngắn Mạch',
  'ThieuDong': 'Thiếu Đồng',
  'ThieuDongDuongMach': 'Thiếu Đồng Đường Mạch',
  'ThuaDong': 'Thừa Đồng',
  'ThuaDongDuongMach': 'Thừa Đồng Đường Mạch',
  'VetLom': 'Vết Lõm',
  'Xuoc': 'Xước',
  'Other': 'Khác',
};

/// Đưa 1 chuỗi loại lỗi bất kỳ về đúng KEY trong [kDefectClassNames].
///
/// Cần thiết vì cùng 1 loại lỗi đang tồn tại nhiều cách viết trong hệ thống:
/// tên lớp mô hình ('ThieuDong'), tên tiếng Việt KHÔNG dấu backend trả về ở
/// `class_name_vi` ('Thieu Dong'), và tên tiếng Việt CÓ dấu app hiển thị
/// ('Thiếu Đồng'). Bỏ hết dấu cách rồi so không phân biệt hoa thường với CẢ
/// key lẫn value nên cả 3 dạng đều về đúng 1 key (so với value là cách bắt
/// dạng có dấu mà không cần bảng bỏ dấu tiếng Việt).
///
/// Trả `null` nếu không khớp lớp nào (vd dữ liệu cũ 'none', chuỗi rỗng) - khi
/// đó KHÔNG đoán bừa, để người vận hành tự chọn.
String? canonicalDefectClass(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final needle = value.replaceAll(' ', '').toLowerCase();
  for (final entry in kDefectClassNames.entries) {
    if (entry.key.toLowerCase() == needle) return entry.key;
    if (entry.value.replaceAll(' ', '').toLowerCase() == needle) {
      return entry.key;
    }
  }
  return null;
}

class AIDetectionResult {
  final bool success;
  final String message;
  final List<DefectDetection> detections;
  final Uint8List? processedImage;
  final String? imagePath;
  final Map<String, dynamic> statistics;
  final DateTime timestamp;

  AIDetectionResult({
    required this.success,
    required this.message,
    required this.detections,
    this.processedImage,
    this.imagePath,
    required this.statistics,
    required this.timestamp,
  });

  factory AIDetectionResult.fromJson(Map<String, dynamic> json) {
    return AIDetectionResult(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      detections:
          (json['detections'] as List?)
              ?.map((d) => DefectDetection.fromJson(d))
              .toList() ??
          [],
      processedImage: json['processed_image_base64'] != null
          ? base64Decode(json['processed_image_base64'])
          : null,
      imagePath: json['image_path'],
      statistics: json['statistics'] ?? {},
      timestamp: DateTime.parse(
        json['timestamp'] ?? DateTime.now().toIso8601String(),
      ),
    );
  }

  /// Verdict OK/NG THẬT SỰ do backend quyết định (`statistics.system_verdict`
  /// - xem ai_detection_api.py::format_results, tính là "NG nếu có ÍT NHẤT 1
  /// detection với verdict='NG'", KHÔNG PHẢI "có detection nào là NG").
  ///
  /// KHÔNG được suy verdict chỉ từ `detections.isEmpty` - 1 detection có thể
  /// ĐƯỢC TRẢ VỀ (vẽ lên ảnh, liệt kê trong `detections[]`) nhưng verdict
  /// riêng của NÓ vẫn là 'OK' (vd nghi ngờ ban đầu nhưng đo đạc/phân loại lại
  /// xác nhận nằm trong dung sai) - bug thật đã gặp 2026-09-25: ảnh có 1
  /// detection "ThieuDong" nhưng backend log "Overall verdict: OK", trong khi
  /// app Flutter (dùng detections.isEmpty) lại báo NG.
  ///
  /// Fallback về suy luận cũ (detections rỗng = OK) CHỈ khi response thiếu
  /// hẳn field này (backend cũ hơn/khác) - để không vỡ hoàn toàn nếu thiếu.
  String get systemVerdict {
    final raw = statistics['system_verdict']?.toString();
    if (raw != null && raw.isNotEmpty) return raw.toUpperCase();
    return detections.isEmpty ? 'OK' : 'NG';
  }

  /// Tên loại lỗi của lỗi NG "chính" - lỗi NG có confidence cao nhất trong
  /// TOÀN BỘ lỗi backend tìm được (`statistics.primary_defect`, xem
  /// ai_detection_api.py::format_results).
  ///
  /// BẮT BUỘC phải dùng tới, không được chỉ dựa vào `detections`: backend chỉ
  /// trả về TOP-N lỗi theo confidence trong `detections[]`
  /// (`max_defects_drawn`, hiện là 3 trong ai_config.yml) trong khi
  /// `system_verdict` tính trên TẤT CẢ lỗi. Nếu lỗi gây ra NG có confidence
  /// thấp hơn 3 lỗi verdict=OK khác thì nó KHÔNG nằm trong `detections[]`:
  /// app báo "NG" mà lọc `detections` theo verdict=='NG' lại chẳng thấy gì,
  /// hiện ra "NG / Không phát hiện lỗi" và ghi `ai_type` rỗng vào DB (bug
  /// thật đã gặp, có dòng trong DB ngày 2026-09-30).
  ///
  /// Trả `null` khi verdict là OK (backend để `primary_defect` = null) hoặc
  /// response cũ không có field này.
  String? get primaryDefectName {
    final raw = statistics['primary_defect'];
    if (raw is! Map) return null;
    final vi = raw['class_name_vi']?.toString().trim();
    if (vi != null && vi.isNotEmpty) return vi;
    final en = raw['class_name']?.toString().trim();
    return (en != null && en.isNotEmpty) ? en : null;
  }

  /// Như [primaryDefectName] nhưng trả TÊN LỚP CHUẨN của mô hình (chưa dịch),
  /// để đối chiếu/chuẩn hoá - xem canonicalDefectClass.
  String? get primaryDefectClassName {
    final raw = statistics['primary_defect'];
    if (raw is! Map) return null;
    final en = raw['class_name']?.toString().trim();
    return (en != null && en.isNotEmpty) ? en : null;
  }
}

class DefectDetection {
  final List<int> bbox;
  final double confidence;
  final int classId;
  final String className;
  final String classNameVi;
  final Map<String, int> coordinates;
  // Verdict OK/NG RIÊNG của detection này (xem ai_detection_api.py::
  // format_results) - 1 detection được trả về/vẽ lên ảnh KHÔNG có nghĩa nó
  // là NG, có thể tự nó đã là 'OK' (xem AIDetectionResult.systemVerdict).
  final String verdict;

  DefectDetection({
    required this.bbox,
    required this.confidence,
    required this.classId,
    required this.className,
    required this.classNameVi,
    required this.coordinates,
    required this.verdict,
  });

  factory DefectDetection.fromJson(Map<String, dynamic> json) {
    return DefectDetection(
      bbox: List<int>.from(json['bbox'] ?? []),
      confidence: (json['confidence'] ?? 0.0).toDouble(),
      classId: json['class_id'] ?? 0,
      className: json['class_name'] ?? '',
      classNameVi: json['class_name_vi'] ?? '',
      coordinates: Map<String, int>.from(json['coordinates'] ?? {}),
      verdict: (json['verdict']?.toString() ?? 'NG').toUpperCase(),
    );
  }
}

class AIDetectionService extends ChangeNotifier {
  bool _isLoading = false;
  String? _lastError;
  AIDetectionResult? _lastResult;

  bool get isLoading => _isLoading;
  String? get lastError => _lastError;
  AIDetectionResult? get lastResult => _lastResult;
  String get _baseUrl => AppRuntimeConfig.instance.aiBaseUrl;

  Future<AIDetectionResult?> detectDefects({
    required Uint8List imageData,
    double confidenceThreshold = 0.25,
    double iouThreshold = 0.1,
    // Ma lo (tbLot.lot_code) + ma board (tbBoard.board_code) hien tai, de BE
    // gan vao ten file anh log + inspection_log.jsonl. De trong neu chua co
    // lo/board (vd test thu cong ngoai luong AOI).
    String lotCode = '',
    String boardCode = '',
  }) async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();

    try {
      // Convert image to base64
      final base64Image = base64Encode(imageData);

      // Prepare request
      final request = {
        'image_base64': base64Image,
        'confidence_threshold': confidenceThreshold,
        'iou_threshold': iouThreshold,
        'lot_code': lotCode,
        'board_code': boardCode,
      };

      debugPrint('🤖 Sending AI detection request...');

      // Send POST request
      final response = await http.post(
        Uri.parse('$_baseUrl/api/ai-detection'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(request),
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        _lastResult = AIDetectionResult.fromJson(responseData);

        debugPrint(
          '✅ AI detection successful: ${_lastResult!.detections.length} defects found',
        );

        // Lưu ảnh processed nếu có
        if (_lastResult!.processedImage != null) {
          await _saveProcessedImage(_lastResult!.processedImage!);
        }

        return _lastResult;
      } else {
        // Cắt ngắn body: API này nhận `image_base64`, lỗi 4xx/5xx có thể trả về
        // kèm request đã gửi -> in cả body là đổ base64 vào console.
        final body = response.body;
        final shortBody = body.length <= 200
            ? body
            : '${body.substring(0, 200)}... (${body.length} ký tự)';
        _lastError = 'HTTP ${response.statusCode}: $shortBody';
        debugPrint('❌ AI detection failed: $_lastError');
        return null;
      }
    } catch (e) {
      _lastError = 'Network error: $e';
      debugPrint('❌ AI detection error: $_lastError');
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Lưu ảnh đã xử lý AI detection vào thư mục
  Future<void> _saveProcessedImage(Uint8List imageBytes) async {
    debugPrint(
      '🖼️ Starting to save processed image: ${imageBytes.length} bytes',
    );
    try {
      final folderPath =
          'C:/Users/sonng/OneDrive/Desktop/APPAutoVRS/BE-AutoVRS/images_ai';
      debugPrint('🖼️ Target folder: $folderPath');

      final dir = Directory(folderPath);
      final dirExists = await dir.exists();
      debugPrint('🖼️ Directory exists: $dirExists');

      if (!dirExists) {
        debugPrint('🖼️ Creating directory...');
        await dir.create(recursive: true);
        debugPrint('🖼️ Directory created successfully');
      }

      final now = DateTime.now();
      final fileName =
          'ai_processed_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}.jpg';
      final filePath = '$folderPath/$fileName';
      debugPrint('🖼️ Full file path: $filePath');

      final file = File(filePath);
      await file.writeAsBytes(imageBytes);

      // Verify file was written
      final fileExists = await file.exists();
      final fileSize = await file.length();
      debugPrint(
        '🖼️ ✅ File written - exists: $fileExists, size: $fileSize bytes',
      );
      debugPrint('🖼️ ✅ Successfully saved AI processed image to: $filePath');
    } catch (e) {
      debugPrint('❌ Error saving processed image: $e');
    }
  }

  Future<bool> checkServerHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('❌ Health check failed: $e');
      return false;
    }
  }

  void clearResults() {
    _lastResult = null;
    _lastError = null;
    notifyListeners();
  }
}
