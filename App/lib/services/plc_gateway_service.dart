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
    try {
      print('🔍 Inspecting defect at ($defectX, $defectY)...');

      final requestBody = {
        'defect_x': defectX,
        'defect_y': defectY,
        'board_id': boardId,
        'defect_id': defectId,
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
      } else {
        throw Exception('Inspection failed: ${response.statusCode}');
      }
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

/// Response from inspect-defect endpoint
class InspectDefectResponse {
  final bool success;
  final String message;
  final String
  step; // "plc_sent", "camera_captured", "ai_detected", "completed", "error"

  // PLC
  final Map<String, dynamic>? plcCoords;

  // Camera
  final bool imageCaptured;
  final String? imageBase64;

  // AI Detection
  final List<dynamic>? aiDetections;
  final String? aiVerdict;
  final Map<String, dynamic>? aiStatistics;

  // Timing
  final Map<String, dynamic>? timing;
  final String? errorDetails;

  InspectDefectResponse({
    required this.success,
    required this.message,
    required this.step,
    this.plcCoords,
    this.imageCaptured = false,
    this.imageBase64,
    this.aiDetections,
    this.aiVerdict,
    this.aiStatistics,
    this.timing,
    this.errorDetails,
  });

  factory InspectDefectResponse.fromJson(Map<String, dynamic> json) {
    return InspectDefectResponse(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      step: json['step'] ?? 'unknown',
      plcCoords: json['plc_coords'],
      imageCaptured: json['image_captured'] ?? false,
      imageBase64: json['image_base64'],
      aiDetections: json['ai_detections'],
      aiVerdict: json['ai_verdict'],
      aiStatistics: json['ai_statistics'],
      timing: json['timing'],
      errorDetails: json['error_details'],
    );
  }

  bool get hasAiResults => aiDetections != null && aiDetections!.isNotEmpty;

  int get defectCount => aiDetections?.length ?? 0;

  bool get isOk => aiVerdict == 'OK';

  double? get totalTime => timing?['total'];
}
