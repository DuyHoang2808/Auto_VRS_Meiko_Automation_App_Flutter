// PLC Gateway Service
// Giao tiếp với PLC Gateway API (Python Backend)
// Port: 8083

import 'dart:convert';
import 'package:autovrs_app/core/app_runtime_config.dart';
import 'package:http/http.dart' as http;

class PlcGatewayService {
  final String? baseUrl;

  PlcGatewayService({this.baseUrl});

  String get _resolvedBaseUrl =>
      baseUrl ?? AppRuntimeConfig.instance.plcGatewayBaseUrl;

  // ===== Single-flight cho các lệnh điều khiển PLC =====
  // PHẢI là static: mỗi màn hình tự tạo instance riêng
  // (`vrs_main_screen.dart` và `manual_vrs_screen.dart` đều có
  // `final PlcGatewayService _plcGateway = PlcGatewayService();`), nên cờ mức
  // instance sẽ không chặn được trường hợp nguy hiểm nhất: Auto VRS đang soi
  // trong khi VRS thủ công bấm "Di chuyển Camera" → 2 lệnh cùng ghi vào
  // D2810/D2910 của một con PLC.
  //
  // Đây là lớp chặn phía app cho phản hồi nhanh; gateway vẫn có asyncio.Lock
  // riêng trả 409 (xem `plc_exclusive` trong plc_offset_gateway.py) vì gateway
  // còn phục vụ client khác ngoài app này.
  static bool _plcBusy = false;
  static String? _plcBusyWith;

  /// PLC có đang chạy một lệnh nào không (dùng để hiện trạng thái trên UI).
  static bool get isPlcBusy => _plcBusy;
  static String? get plcBusyWith => _plcBusyWith;

  /// Chạy [action] độc quyền trên PLC. Trả `null` NGAY nếu đã có lệnh khác
  /// đang chạy - cố tình không xếp hàng, để lệnh calib 90s không âm thầm chờ
  /// rồi bất ngờ chạy sau khi operator đã quên mình từng bấm.
  static Future<T?> _withPlcLock<T>(
    String operation,
    Future<T> Function() action,
  ) async {
    if (_plcBusy) {
      print('⛔ Bỏ qua "$operation": PLC đang bận với "$_plcBusyWith"');
      return null;
    }
    _plcBusy = true;
    _plcBusyWith = operation;
    try {
      return await action();
    } finally {
      _plcBusy = false;
      _plcBusyWith = null;
    }
  }

  /// Thông báo chuẩn khi bị chặn vì PLC đang chạy lệnh khác.
  static String get _busyMessage =>
      'PLC đang bận (${_plcBusyWith ?? "lệnh khác"}). '
      'Đợi lệnh hiện tại xong rồi thử lại.';

  /// Test PLC connection
  Future<Map<String, dynamic>> testPlcConnection() async {
    try {
      final response = await http
          .get(Uri.parse('$_resolvedBaseUrl/api/test-plc'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('PLC test failed: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ PLC test error: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Test camera capture
  Future<Map<String, dynamic>> testCameraCapture() async {
    try {
      final response = await http
          .get(Uri.parse('$_resolvedBaseUrl/api/test-camera'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Camera test failed: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ Camera test error: $e');
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Inspect defect: Send coordinates to PLC, capture image, run AI detection
  ///
  /// This is the main workflow:
  /// 1. Send X,Y coordinates to PLC Omron
  /// 2. Wait for PLC to move camera (timeout)
  /// 3. Capture image from SICK camera
  /// 4. Send image to AI Detection API
  /// 5. Return AI results
  Future<InspectDefectResponse> inspectDefect({
    required double defectX,
    required double defectY,
    String? boardId,
    int? defectId,
    String boardSide = 'A',

    // PLC Configuration
    String plcPcIp = '192.168.3.101',
    String plcIp = '192.168.3.1',
    int plcPort = 9600,
    String plcMemArea = 'D',
    int plcXAddr = 2810,
    int plcYAddr = 2910,
    int plcTriggerAddr = 3000,

    // Timing
    int plcMoveTimeoutMs = 2000, // 2 seconds
    // AI
    double aiConfidenceThreshold = 0.25,
    String? aiApiUrl,
  }) async {
    final result = await _withPlcLock('kiểm tra lỗi', () async {
      return await _inspectDefectUnlocked(
        defectX: defectX,
        defectY: defectY,
        boardId: boardId,
        defectId: defectId,
        boardSide: boardSide,
        plcPcIp: plcPcIp,
        plcIp: plcIp,
        plcPort: plcPort,
        plcMemArea: plcMemArea,
        plcXAddr: plcXAddr,
        plcYAddr: plcYAddr,
        plcTriggerAddr: plcTriggerAddr,
        plcMoveTimeoutMs: plcMoveTimeoutMs,
        aiConfidenceThreshold: aiConfidenceThreshold,
        aiApiUrl: aiApiUrl,
      );
    });
    return result ??
        InspectDefectResponse(
          success: false,
          message: _busyMessage,
          step: 'error',
          errorDetails: 'plc_busy',
        );
  }

  Future<InspectDefectResponse> _inspectDefectUnlocked({
    required double defectX,
    required double defectY,
    String? boardId,
    int? defectId,
    String boardSide = 'A',
    String plcPcIp = '192.168.3.101',
    String plcIp = '192.168.3.1',
    int plcPort = 9600,
    String plcMemArea = 'D',
    int plcXAddr = 2810,
    int plcYAddr = 2910,
    int plcTriggerAddr = 3000,
    int plcMoveTimeoutMs = 2000,
    double aiConfidenceThreshold = 0.25,
    String? aiApiUrl,
  }) async {
    try {
      print('🔍 Inspecting defect at ($defectX, $defectY)...');

      final requestBody = {
        'defect_x': defectX,
        'defect_y': defectY,
        'board_id': boardId,
        'defect_id': defectId,
        'board_side': boardSide,
        'plc_pc_ip': plcPcIp,
        'plc_ip': plcIp,
        'plc_port': plcPort,
        'plc_mem_area': plcMemArea,
        'plc_x_addr': plcXAddr,
        'plc_y_addr': plcYAddr,
        'plc_trigger_addr': plcTriggerAddr,
        'plc_move_timeout_ms': plcMoveTimeoutMs,
        'ai_confidence_threshold': aiConfidenceThreshold,
        'ai_api_url': aiApiUrl ?? AppRuntimeConfig.instance.aiDetectionUrl,
      };

      final response = await http
          .post(
            Uri.parse('$_resolvedBaseUrl/api/inspect-defect'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(requestBody),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('✅ Inspection completed: ${data['message']}');
        return InspectDefectResponse.fromJson(data);
      }

      // Lấy `detail` từ body thay vì chỉ ném status code - gateway trả 409 kèm
      // lý do rõ ràng ("PLC đang bận (...)"), trước đây bị nuốt mất.
      String detail = 'HTTP ${response.statusCode}';
      try {
        final decoded = json.decode(response.body);
        if (decoded is Map && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        }
      } catch (_) {}
      print('❌ Inspection failed: $detail');
      return InspectDefectResponse(
        success: false,
        message: detail,
        step: 'error',
        errorDetails: 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      print('❌ Inspect defect error: $e');
      return InspectDefectResponse(
        success: false,
        message: 'Error: $e',
        step: 'error',
        errorDetails: e.toString(),
      );
    }
  }

  /// Move camera to PLC coordinates only (no capture/AI) — used by the manual
  /// VRS screen's "Về gốc" / "Di chuyển Camera" buttons. Replaces the old
  /// path of sending coords over CoordWsClient (ws://127.0.0.1:8765) to
  /// ws_coord_server.py, which then relayed to this same PLC Gateway.
  /// Flutter now calls `/api/plc/move` directly.
  Future<MoveResponse> movePlc({
    required double x,
    required double y,
    int? boardId,
    int? defectId,
  }) async {
    final result = await _withPlcLock('di chuyển camera', () async {
      return await _movePlcUnlocked(
        x: x,
        y: y,
        boardId: boardId,
        defectId: defectId,
      );
    });
    return result ?? MoveResponse(success: false, message: _busyMessage);
  }

  Future<MoveResponse> _movePlcUnlocked({
    required double x,
    required double y,
    int? boardId,
    int? defectId,
  }) async {
    try {
      final requestBody = {
        'x': x,
        'y': y,
        if (boardId != null) 'board_id': boardId,
        if (defectId != null) 'defect_id': defectId,
      };

      print('📤 PlcGatewayService: moving PLC to x=$x y=$y');

      final response = await http
          .post(
            Uri.parse('$_resolvedBaseUrl/api/plc/move'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(requestBody),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return MoveResponse.fromJson(data);
      }

      String detail = 'HTTP ${response.statusCode}';
      try {
        final decoded = json.decode(response.body);
        if (decoded is Map && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        }
      } catch (_) {}
      return MoveResponse(success: false, message: detail);
    } catch (e) {
      print('❌ PlcGatewayService: move PLC error: $e');
      return MoveResponse(success: false, message: 'Network error: $e');
    }
  }

  /// Move camera to a BOARD-space coordinate (Gerber/design), with the
  /// gateway doing board→PLC mapping (`board_to_plc`) + rigid board-offset
  /// compensation before sending to the PLC — same pipeline `/api/inspect-defect`
  /// uses for Auto VRS. Replaces the old [movePlc] (raw x/y, no mapping/offset)
  /// for the manual VRS screen's "Di chuyển Camera" button, which previously
  /// sent `plc_coor` straight to the PLC unmapped and uncompensated.
  Future<MoveBuLechResponse> movePlcWithOffset({
    required double boardX,
    required double boardY,
    required String boardSide,
    String? boardId,
    int? defectId,
    bool applyBoardOffset = true,
  }) async {
    final result = await _withPlcLock('di chuyển camera (bù lệch)', () async {
      return await _movePlcWithOffsetUnlocked(
        boardX: boardX,
        boardY: boardY,
        boardSide: boardSide,
        boardId: boardId,
        defectId: defectId,
        applyBoardOffset: applyBoardOffset,
      );
    });
    return result ?? MoveBuLechResponse(success: false, message: _busyMessage);
  }

  Future<MoveBuLechResponse> _movePlcWithOffsetUnlocked({
    required double boardX,
    required double boardY,
    required String boardSide,
    String? boardId,
    int? defectId,
    bool applyBoardOffset = true,
  }) async {
    try {
      final requestBody = {
        'board_x': boardX,
        'board_y': boardY,
        'board_side': boardSide,
        'apply_board_offset': applyBoardOffset,
        if (boardId != null) 'board_id': boardId,
        if (defectId != null) 'defect_id': defectId,
      };

      print(
        '📤 PlcGatewayService: move_bulech board=($boardX,$boardY) side=$boardSide',
      );

      final response = await http
          .post(
            Uri.parse('$_resolvedBaseUrl/api/plc/move_bulech'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(requestBody),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return MoveBuLechResponse.fromJson(data);
      }

      String detail = 'HTTP ${response.statusCode}';
      try {
        final decoded = json.decode(response.body);
        if (decoded is Map && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        }
      } catch (_) {}
      return MoveBuLechResponse(success: false, message: detail);
    } catch (e) {
      print('❌ PlcGatewayService: move_bulech error: $e');
      return MoveBuLechResponse(success: false, message: 'Network error: $e');
    }
  }

  /// Trigger auto board offset calibration (YOLO fiducial detection + Kabsch)
  ///
  /// Gọi khi: đổi board vật lý mới hoặc đổi mặt board (A↔B).
  /// PLC sẽ di chuyển đến các điểm mốc, camera chụp, YOLO detect marker,
  /// tính Kabsch rigid transform, lưu offset_runtime.json.
  /// Timeout 90s vì PLC cần di chuyển tới 2-3 điểm mốc + chụp + detect.
  Future<AutoBoardOffsetResponse> triggerAutoBoardOffset({
    required String boardSide,
    String? boardId,
    int anchorMode = 2,
  }) async {
    final result = await _withPlcLock('calib bù lệch board', () async {
      return await _triggerAutoBoardOffsetUnlocked(
        boardSide: boardSide,
        boardId: boardId,
        anchorMode: anchorMode,
      );
    });
    return result ??
        AutoBoardOffsetResponse(success: false, message: _busyMessage);
  }

  Future<AutoBoardOffsetResponse> _triggerAutoBoardOffsetUnlocked({
    required String boardSide,
    String? boardId,
    int anchorMode = 2,
  }) async {
    try {
      print('📐 Triggering auto board offset: side=$boardSide boardId=$boardId anchorMode=$anchorMode');

      final requestBody = {
        'anchor_mode': anchorMode,
        'board_side': boardSide,
        if (boardId != null) 'board_id': boardId,
      };

      final response = await http
          .post(
            Uri.parse('$_resolvedBaseUrl/api/calib/auto-board-offset'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(requestBody),
          )
          .timeout(const Duration(seconds: 90));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('✅ Auto board offset: ${data['message']}');
        return AutoBoardOffsetResponse.fromJson(data);
      } else {
        String detail = 'HTTP ${response.statusCode}';
        try {
          final decoded = json.decode(response.body);
          if (decoded is Map && decoded['detail'] != null) {
            detail = decoded['detail'].toString();
          }
        } catch (_) {}
        return AutoBoardOffsetResponse(success: false, message: detail);
      }
    } catch (e) {
      print('❌ Auto board offset error: $e');
      return AutoBoardOffsetResponse(success: false, message: 'Error: $e');
    }
  }

  /// Get current offset status (offset_runtime.json contents)
  /// Đọc offset runtime đang lưu cho [boardSide].
  ///
  /// Offset được lưu THEO TỪNG MẶT (file riêng cho A và B), nên phải truyền
  /// `board_side` - trước đây không truyền nên luôn đọc mặt A, tức mặt B báo
  /// sai trạng thái.
  Future<Map<String, dynamic>> getOffsetStatus({String boardSide = 'A'}) async {
    try {
      final response = await http
          .get(
            Uri.parse(
              '$_resolvedBaseUrl/api/calib/offset-status?board_side=$boardSide',
            ),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {'success': false, 'message': 'HTTP ${response.statusCode}'};
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Gateway có đang giữ dữ liệu bù lệch ĐÚNG của board [boardId] mặt
  /// [boardSide] hay không.
  ///
  /// Dùng để quyết định có được bỏ qua calib khi bắt đầu soi. Phải hỏi gateway
  /// chứ không tin cache trong app, vì file offset có thể mất/bị thay mà app
  /// không hề biết (gateway restart, dọn thư mục runtime, hoặc công cụ calib
  /// rời trong Auto_calib ghi đè). Tin cache sai hướng là nguy hiểm nhất: app
  /// bỏ qua calib -> gateway lặng lẽ dùng toạ độ chưa bù -> soi sai cả board.
  ///
  /// Offset lưu theo MẶT chứ không theo board, nên phải so cả `board_id`:
  /// calib board khác cùng mặt sẽ ghi đè lên file của mặt đó.
  Future<bool> hasValidOffsetFor({
    required String boardSide,
    required String boardId,
  }) async {
    if (boardId.isEmpty) return false;
    final status = await getOffsetStatus(boardSide: boardSide);
    if (status['exists'] != true) return false;
    final data = status['data'];
    if (data is! Map) return false;
    final savedBoardId = data['board_id']?.toString();
    if (savedBoardId == null || savedBoardId.isEmpty) return false;
    return savedBoardId == boardId;
  }

  /// Danh sách mã hàng có trong products_registry.yaml của gateway - dùng để
  /// hiện danh sách/so sánh, KHÔNG đổi mã hàng đang active.
  Future<ProductsListResponse> getProducts() async {
    try {
      final response = await http
          .get(Uri.parse('$_resolvedBaseUrl/api/products'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return ProductsListResponse.fromJson(json.decode(response.body));
      }
      return ProductsListResponse(products: []);
    } catch (e) {
      print('❌ Get products error: $e');
      return ProductsListResponse(products: []);
    }
  }

  /// Mã hàng đang active hiện tại ở gateway - dùng để đối chiếu với mã hàng
  /// app đang nghĩ là đang chọn (xem `VRSProvider.lastSelectedProductCode`),
  /// phát hiện lệch nếu gateway bị đổi mã hàng từ nơi khác mà app không biết.
  Future<ActiveProductResponse> getActiveProduct() async {
    try {
      final response = await http
          .get(Uri.parse('$_resolvedBaseUrl/api/products/active'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return ActiveProductResponse.fromJson(json.decode(response.body));
      }
      return ActiveProductResponse();
    } catch (e) {
      print('❌ Get active product error: $e');
      return ActiveProductResponse();
    }
  }

  /// Báo cho gateway đổi sang mã hàng [productCode]: gateway sẽ đổi weights
  /// YOLO của Fiducial Detector Service + trỏ file calib sang đúng thư mục
  /// của mã hàng này (xem `products_registry.yaml` bên gateway).
  ///
  /// AN TOÀN: nếu thất bại (thiếu file weights của mã hàng, fiducial service
  /// down...), gateway vẫn trả HTTP 200 với `success:false` (trừ mã hàng
  /// hoàn toàn chưa có trong registry -> HTTP 400) và GIỮ NGUYÊN mã hàng
  /// đang active trước đó. Bên gọi PHẢI tự chặn operator tiếp tục khi
  /// `success:false` - không được coi như đã đổi mã hàng xong.
  Future<ProductSelectResponse> selectProduct(String productCode) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_resolvedBaseUrl/api/products/select'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'product_code': productCode}),
          )
          .timeout(const Duration(seconds: 40));

      if (response.statusCode == 200) {
        return ProductSelectResponse.fromJson(json.decode(response.body));
      }

      String detail = 'HTTP ${response.statusCode}';
      try {
        final decoded = json.decode(response.body);
        if (decoded is Map && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        }
      } catch (_) {}
      return ProductSelectResponse(
        success: false,
        productCode: productCode,
        message: detail,
      );
    } catch (e) {
      print('❌ Select product error: $e');
      return ProductSelectResponse(
        success: false,
        productCode: productCode,
        message: 'Network error: $e',
      );
    }
  }

  /// Check if PLC Gateway API is running
  Future<bool> isApiAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('$_resolvedBaseUrl/'))
          .timeout(const Duration(seconds: 2));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Check if Fiducial Detector Service (YOLO) is running.
  /// Gọi trực tiếp Fiducial Service (port 8191) thay vì qua gateway,
  /// vì gateway có thể UP nhưng fiducial service chưa khởi động.
  static Future<bool> checkFiducialHealth({String? baseUrl}) async {
    try {
      final url = baseUrl ??
          AppRuntimeConfig.instance.fiducialDetectorBaseUrl;
      final response = await http
          .get(Uri.parse('$url/'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['status'] == 'running';
      }
      return false;
    } catch (e) {
      return false;
    }
  }
}

/// Response from /api/plc/move endpoint (move only, no capture/AI)
class MoveResponse {
  final bool success;
  final String message;
  final double? plcX;
  final double? plcY;
  final double? elapsedSeconds;

  MoveResponse({
    required this.success,
    required this.message,
    this.plcX,
    this.plcY,
    this.elapsedSeconds,
  });

  factory MoveResponse.fromJson(Map<String, dynamic> json) {
    return MoveResponse(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      plcX: (json['plc_x'] as num?)?.toDouble(),
      plcY: (json['plc_y'] as num?)?.toDouble(),
      elapsedSeconds: (json['elapsed_seconds'] as num?)?.toDouble(),
    );
  }
}

/// Response from /api/plc/move_bulech endpoint (board→PLC mapping + rigid
/// board-offset compensation applied before moving, no capture/AI).
class MoveBuLechResponse {
  final bool success;
  final String message;
  final Map<String, dynamic>? boardCoords;
  final Map<String, dynamic>? nominalCoords;
  final double? plcX;
  final double? plcY;
  final String? boardSide;
  final bool offsetApplied;
  final Map<String, dynamic>? offsetInfo;
  final double? elapsedSeconds;

  MoveBuLechResponse({
    required this.success,
    required this.message,
    this.boardCoords,
    this.nominalCoords,
    this.plcX,
    this.plcY,
    this.boardSide,
    this.offsetApplied = false,
    this.offsetInfo,
    this.elapsedSeconds,
  });

  factory MoveBuLechResponse.fromJson(Map<String, dynamic> json) {
    return MoveBuLechResponse(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      boardCoords: json['board_coords'] as Map<String, dynamic>?,
      nominalCoords: json['nominal_coords'] as Map<String, dynamic>?,
      plcX: (json['plc_x'] as num?)?.toDouble(),
      plcY: (json['plc_y'] as num?)?.toDouble(),
      boardSide: json['board_side'] as String?,
      offsetApplied: json['offset_applied'] ?? false,
      offsetInfo: json['offset_info'] as Map<String, dynamic>?,
      elapsedSeconds: (json['elapsed_seconds'] as num?)?.toDouble(),
    );
  }
}

/// Response from inspect-defect endpoint
class InspectDefectResponse {
  final bool success;
  final String message;
  final String
  step; // "plc_sent", "camera_captured", "ai_detected", "completed", "error"

  // PLC
  final Map<String, dynamic>? plcCoords;

  // Bù lệch board: gateway trả `offset_applied: false` khi KHÔNG tìm thấy
  // offset runtime cho mặt board này và đã âm thầm dùng toạ độ nominal (chưa
  // bù lệch). Trước đây 2 field này không được parse nên app không hề biết —
  // có thể soi cả board ở toạ độ sai mà không có dấu hiệu gì.
  final bool offsetApplied;
  final Map<String, dynamic>? offsetInfo;

  // Camera
  final bool imageCaptured;
  final String? imageBase64;

  // AI Detection
  final List<dynamic>? aiDetections;
  final String? aiVerdict;
  final Map<String, dynamic>? aiStatistics;
  final String? aiImagePath;

  // Timing
  final Map<String, dynamic>? timing;
  final String? errorDetails;

  InspectDefectResponse({
    required this.success,
    required this.message,
    required this.step,
    this.plcCoords,
    this.offsetApplied = false,
    this.offsetInfo,
    this.imageCaptured = false,
    this.imageBase64,
    this.aiDetections,
    this.aiVerdict,
    this.aiStatistics,
    this.aiImagePath,
    this.timing,
    this.errorDetails,
  });

  factory InspectDefectResponse.fromJson(Map<String, dynamic> json) {
    return InspectDefectResponse(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      step: json['step'] ?? 'unknown',
      plcCoords: json['plc_coords'],
      offsetApplied: json['offset_applied'] ?? false,
      offsetInfo: json['offset_info'],
      imageCaptured: json['image_captured'] ?? false,
      imageBase64: json['image_base64'],
      aiDetections: json['ai_detections'],
      aiVerdict: json['ai_verdict'],
      aiStatistics: json['ai_statistics'],
      aiImagePath: json['ai_image_path'],
      timing: json['timing'],
      errorDetails: json['error_details'],
    );
  }

  bool get hasAiResults => aiDetections != null && aiDetections!.isNotEmpty;

  int get defectCount => aiDetections?.length ?? 0;

  bool get isOk => aiVerdict == 'OK';

  double? get totalTime => timing?['total'];
}

/// Response from /api/calib/auto-board-offset endpoint
class AutoBoardOffsetResponse {
  final bool success;
  final String message;
  final int? anchorMode;
  final double? thetaDeg;
  final double? tx;
  final double? ty;
  final double? rmsErrorMm;
  final double? maxErrorMm;
  final String? warning;
  final String? boardId;
  final String? boardSide;
  final Map<String, dynamic>? timing;

  AutoBoardOffsetResponse({
    required this.success,
    required this.message,
    this.anchorMode,
    this.thetaDeg,
    this.tx,
    this.ty,
    this.rmsErrorMm,
    this.maxErrorMm,
    this.warning,
    this.boardId,
    this.boardSide,
    this.timing,
  });

  factory AutoBoardOffsetResponse.fromJson(Map<String, dynamic> json) {
    return AutoBoardOffsetResponse(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      anchorMode: json['anchor_mode'] as int?,
      thetaDeg: (json['theta_deg'] as num?)?.toDouble(),
      tx: (json['tx'] as num?)?.toDouble(),
      ty: (json['ty'] as num?)?.toDouble(),
      rmsErrorMm: (json['rms_error_mm'] as num?)?.toDouble(),
      maxErrorMm: (json['max_error_mm'] as num?)?.toDouble(),
      warning: json['warning'] as String?,
      boardId: json['board_id'] as String?,
      boardSide: json['board_side'] as String?,
      timing: json['timing'] as Map<String, dynamic>?,
    );
  }
}

/// Response from GET /api/products
class ProductsListResponse {
  final List<String> products;
  final String? defaultProduct;
  final String? activeProduct;

  ProductsListResponse({
    required this.products,
    this.defaultProduct,
    this.activeProduct,
  });

  factory ProductsListResponse.fromJson(Map<String, dynamic> json) {
    return ProductsListResponse(
      products:
          (json['products'] as List?)?.map((e) => e.toString()).toList() ??
          [],
      defaultProduct: json['default_product'] as String?,
      activeProduct: json['active_product'] as String?,
    );
  }
}

/// Response from GET /api/products/active
class ActiveProductResponse {
  final String? activeProduct;
  final Map<String, dynamic>? config;

  ActiveProductResponse({this.activeProduct, this.config});

  factory ActiveProductResponse.fromJson(Map<String, dynamic> json) {
    return ActiveProductResponse(
      activeProduct: json['active_product'] as String?,
      config: json['config'] as Map<String, dynamic>?,
    );
  }
}

/// Response from POST /api/products/select
class ProductSelectResponse {
  final bool success;
  final String productCode;
  final String message;
  final String? weightsPath;
  final String? calibDir;
  final Map<String, dynamic>? fiducialClassNames;

  ProductSelectResponse({
    required this.success,
    required this.productCode,
    required this.message,
    this.weightsPath,
    this.calibDir,
    this.fiducialClassNames,
  });

  factory ProductSelectResponse.fromJson(Map<String, dynamic> json) {
    return ProductSelectResponse(
      success: json['success'] ?? false,
      productCode: json['product_code']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      weightsPath: json['weights_path'] as String?,
      calibDir: json['calib_dir'] as String?,
      fiducialClassNames: json['fiducial_class_names'] as Map<String, dynamic>?,
    );
  }
}
