import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/vrs_provider.dart';
// import '../../services/autovrs_websocket_service.dart';
import '../../widgets/defect_list_widget.dart';
import '../../widgets/gerber_image_widget.dart';
import '../../widgets/stream_source_control.dart';
import '../../services/local_database_service.dart';
import '../../services/plc_gateway_service.dart';
import '../../services/autovrs_websocket_service.dart';
import '../../services/qcamber_gerber_service.dart';
import '../../services/startup_health_check.dart';

// Map technical defect names to display names (updated for new AI models)
String _getDefectDisplayName(String technicalName) {
  switch (technicalName.toLowerCase()) {
    case 'bamdinhkhongtot':
      return 'Bám Dính Không Tốt';
    case 'chamkim':
      return 'Châm Kim';
    case 'divat':
      return 'Dị vật';
    case 'divatduongmach':
      return 'Dị vật đường mạch';
    case 'khuyetmach':
      return 'Khuyết mạch';
    case 'nganmach':
      return 'Ngắn Mạch';
    case 'thieudong':
      return 'Thiếu Đồng';
    case 'thieudongduongmach':
      return 'Thiếu Đồng Đường Mạch';
    case 'thuadong':
      return 'Thừa Đồng';
    case 'thuadongduongmach':
      return 'Thừa Đồng Đường Mạch';
    case 'vetlom':
      return 'Vết Lõm';
    case 'xuoc':
      return 'Xước';
    case 'other':
      return 'Khác';
    // Legacy names for backward compatibility
    case 'short_circuit':
      return 'Chập mạch';
    case 'missing_component':
      return 'Thiếu linh kiện';
    case 'damaged_track':
      return 'Đường mạch hỏng';
    case 'solder_bridge':
      return 'Cầu hàn';
    case 'crack':
      return 'Vết nứt';
    case 'person':
      return 'Người';
    default:
      return technicalName;
  }
}

class VRSMainScreen extends StatefulWidget {
  const VRSMainScreen({super.key});

  @override
  State<VRSMainScreen> createState() => _VRSMainScreenState();
}

class _VRSMainScreenState extends State<VRSMainScreen> {
  final PlcGatewayService _plcGateway = PlcGatewayService();
  bool _running = false;
  bool _calibrating = false;
  List<Map<String, dynamic>> _defects = [];
  int _currentIndex = 0;
  // Token to force defect list widget to reload its cached future
  int _defectListReloadToken = 0;
  // Track the last persisted AI verdict so the result panel shows the most
  // recent decision even if _currentIndex advances to the next defect.
  int? _lastPersistedDefectId;
  String? _lastPersistedVerdict;
  String? _lastPersistedType;
  // Ảnh AOI capture nhận về từ response của /api/inspect-defect
  Uint8List? _lastCapturedImageBytes;

  // Gerber service for displaying PCB design images
  late QCamberGerberService _gerberService;
  final bool _isLoadingGerber = false;

  // Tăng lên mỗi lần _startWorkflow/_stopWorkflow được gọi, dùng làm "vé số"
  // cho chuỗi đệ quy _inspectCurrentDefect - phát hiện khi thao tác board tự
  // động ("Board tiếp theo") gọi _startWorkflow trong lúc 1 chuỗi cũ vẫn còn
  // đang await (vd chờ PLC/DB) sẽ khiến 2 chuỗi cùng ghi đè _defects/_currentIndex,
  // xử lý/lưu lỗi trùng hoặc sai board. Chuỗi cũ tự dừng ngay khi phát hiện
  // runId không còn khớp, không cần đợi hết await mới biết.
  int _runId = 0;

  // Poll định kỳ để phát hiện board mới được AOI_Ingest (tiến trình Python
  // độc lập) ghi thêm vào DB trong lúc không có board nào đang xử lý - trước
  // đây không có cơ chế này nên phải thoát ra chọn lại model mới thấy board
  // mới. Xem VRSProvider.checkForNewBoard().
  Timer? _newBoardPollTimer;

  @override
  void initState() {
    super.initState();
    _gerberService = context.read<QCamberGerberService>();
    _newBoardPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      Provider.of<VRSProvider>(
        context,
        listen: false,
      ).checkForNewBoard();
    });
  }

  @override
  void dispose() {
    _newBoardPollTimer?.cancel();
    // Đề phòng màn hình bị đóng giữa lúc workflow đang chạy, tránh cờ
    // "busy" bị kẹt vĩnh viễn khiến health-check không bao giờ chạy lại.
    StartupHealthCheck.setBusy(false);
    super.dispose();
  }

  /// Parse the `plc_coor` column (e.g. "19.887;5.86") into numeric (x, y).
  ({double x, double y}) _parsePlcCoords(dynamic plcCoords) {
    double x = 0;
    double y = 0;
    if (plcCoords is String) {
      final sep = plcCoords.contains(';')
          ? ';'
          : (plcCoords.contains(',') ? ',' : null);
      if (sep != null) {
        final parts = plcCoords.split(sep);
        if (parts.length >= 2) {
          x = double.tryParse(parts[0].trim()) ?? 0;
          y = double.tryParse(parts[1].trim()) ?? 0;
        }
      }
    } else if (plcCoords is Map) {
      x = (plcCoords['x'] ?? 0) is num
          ? (plcCoords['x'] as num).toDouble()
          : double.tryParse('${plcCoords['x']}') ?? 0;
      y = (plcCoords['y'] ?? 0) is num
          ? (plcCoords['y'] as num).toDouble()
          : double.tryParse('${plcCoords['y']}') ?? 0;
    }
    return (x: x, y: y);
  }

  /// Move the PLC to the current defect's coordinates, capture and run AI
  /// detection, persist the verdict, then advance to the next defect.
  ///
  /// This replaces the old CoordWsClient -> ws_coord_server.py -> PLC Gateway
  /// relay: PlcGatewayService now calls `/api/inspect-defect` directly over
  /// HTTP and gets the full move+capture+AI result back in one response, so
  /// there is no separate "process" push message to wait for anymore.
  Future<void> _inspectCurrentDefect([int? runId]) async {
    final myRunId = runId ?? _runId;
    if (!_running || myRunId != _runId) {
      debugPrint(
        'VRSMainScreen: _inspectCurrentDefect called but workflow not running or stale run (myRunId=$myRunId, current=$_runId)',
      );
      return;
    }
    debugPrint(
      'VRSMainScreen: _inspectCurrentDefect start - defectsLoaded=${_defects.length}',
    );

    try {
      // If we already loaded defects for this run, prefer them; otherwise fetch
      List<Map<String, dynamic>> defectsForBoard = _defects;
      if (defectsForBoard.isEmpty) {
        final vrsProvider = Provider.of<VRSProvider>(context, listen: false);
        final parsedBoardId = int.tryParse(vrsProvider.currentBoard);
        if (parsedBoardId != null) {
          defectsForBoard = await LocalDatabaseService().getDefectsByBoard(
            parsedBoardId,
          );
        }
      }

      if (defectsForBoard.isEmpty) {
        debugPrint('VRSMainScreen: no defects found for board after DB fetch');
        return;
      }

      final int idx =
          (_currentIndex >= 0 && _currentIndex < defectsForBoard.length)
          ? _currentIndex
          : 0;
      final current = defectsForBoard[idx];
      final boardIdRaw = current['tbBoardid_board'] ?? current['board_id'];
      final defectIdRaw =
          current['id'] ?? current['id_defect'] ?? current['defect_id'];
      final defectId = (defectIdRaw is int)
          ? defectIdRaw
          : int.tryParse(defectIdRaw?.toString() ?? '');

      final coords = _parsePlcCoords(current['plc_coor']);
      debugPrint(
        'VRSMainScreen: inspecting defect index=$idx (of ${defectsForBoard.length}) '
        'board=$boardIdRaw defect=$defectId x=${coords.x} y=${coords.y}',
      );

      // Tải ảnh thiết kế Gerber song song với bước PLC/AI (không await) — nếu
      // QCamber treo/timeout, nó không còn làm chậm việc xử lý defect khi chạy
      // qua nhiều ảnh liên tiếp. QCamberGerberService tự bỏ qua response cũ nhờ
      // requestId guard nên ảnh hiển thị vẫn luôn khớp defect hiện tại.
      unawaited(
        _loadGerberForDefect(
          current,
          int.tryParse(boardIdRaw?.toString() ?? ''),
        ),
      );

      if (!mounted || myRunId != _runId) return;

      final result = await _plcGateway.inspectDefect(
        defectX: coords.x,
        defectY: coords.y,
        boardId: boardIdRaw?.toString(),
        defectId: defectId,
      );

      if (!mounted || myRunId != _runId) return;

      if (result.imageBase64 != null && result.imageBase64!.isNotEmpty) {
        try {
          final bytes = base64Decode(result.imageBase64!);
          setState(() => _lastCapturedImageBytes = bytes);
        } catch (e) {
          debugPrint('VRSMainScreen: failed to decode AOI capture image: $e');
        }
      }

      if (!result.success) {
        debugPrint(
          'VRSMainScreen: inspect-defect failed (${result.message}); stopping workflow',
        );
        setState(() {
          _running = false;
        });
        StartupHealthCheck.setBusy(false);
        return;
      }

      final hasDetections = result.hasAiResults;
      final verdict = hasDetections ? 'NG' : 'OK';
      final detectedType = hasDetections
          ? (result.aiDetections!.first['class_name']?.toString() ?? 'none')
          : 'none';

      if (defectId != null) {
        debugPrint(
          'VRSMainScreen: persisting AI result for defect id=$defectId '
          '(detectedType=$detectedType verdict=$verdict)',
        );
        try {
          await LocalDatabaseService().updateDefect(defectId, {
            'type': detectedType,
            'judgement': verdict,
            'time': DateTime.now().toIso8601String(),
          });
        } catch (e) {
          debugPrint('Failed to persist AI result: $e');
        }

        _lastPersistedDefectId = defectId;
        _lastPersistedVerdict = verdict;
        _lastPersistedType = detectedType;
      }

      if (!mounted || myRunId != _runId) return;

      // Reload defects for the board so the list widget and index stay in sync
      final vrsProviderForReload = Provider.of<VRSProvider>(
        context,
        listen: false,
      );
      final boardIdFromProvider = int.tryParse(
        vrsProviderForReload.currentBoard,
      );

      List<Map<String, dynamic>> reloaded = defectsForBoard;
      if (boardIdFromProvider != null) {
        try {
          reloaded = await LocalDatabaseService().getDefectsByBoard(
            boardIdFromProvider,
          );
        } catch (e) {
          debugPrint('Error reloading defects after persist: $e');
        }
      }

      final foundIndex = reloaded.indexWhere((d) {
        final did = d['id_defect'] ?? d['id'] ?? d['defect_id'];
        if (did == null || defectId == null) return false;
        final parsed = (did is int) ? did : int.tryParse(did.toString());
        return parsed == defectId;
      });

      int nextIndex;
      if (foundIndex != -1 && foundIndex < reloaded.length - 1) {
        nextIndex = foundIndex + 1;
      } else if (foundIndex == -1) {
        final clamped = (_currentIndex >= reloaded.length)
            ? reloaded.length - 1
            : _currentIndex;
        nextIndex = clamped < 0 ? 0 : clamped;
      } else {
        // processed last defect -> stop workflow
        nextIndex = reloaded.length;
      }

      setState(() {
        _defects = reloaded;
        _currentIndex = nextIndex;
        _defectListReloadToken++;
        if (_currentIndex >= _defects.length) {
          _running = false;
          debugPrint('VRSMainScreen: no more defects - stopping workflow');
        }
      });
      StartupHealthCheck.setBusy(_running);

      // Board vừa hết lỗi (không phải do bấm "Dừng" giữa chừng, không phải
      // do lỗi PLC) -> đánh dấu completed + tìm board tiếp theo trong lot,
      // để UI hiện dialog "Lật bo"/"Đặt board mới" cho vận hành viên xác nhận.
      // Kiểm tra thêm myRunId == _runId: nếu 1 lượt chạy khác đã bắt đầu
      // (vd bấm "Board tiếp theo" trong lúc chuỗi cũ còn đang await) thì
      // chuỗi cũ không được phép đánh dấu board completed nữa - board đó có
      // thể không còn là board mà lượt chạy mới đang xử lý.
      final justFinishedBoard =
          !_running && _defects.isNotEmpty && _currentIndex >= _defects.length;
      if (justFinishedBoard && mounted && myRunId == _runId) {
        final vrsProviderForNextBoard = Provider.of<VRSProvider>(
          context,
          listen: false,
        );
        await vrsProviderForNextBoard.completeCurrentBoardAndCheckNext();
      }

      if (mounted &&
          _running &&
          myRunId == _runId &&
          _currentIndex < _defects.length) {
        await _inspectCurrentDefect(myRunId);
      }
    } catch (e) {
      debugPrint('Error inspecting current defect: $e');
    }
  }

  /// Tải ảnh thiết kế Gerber (qua QCamber) tại tọa độ của [defect].
  Future<void> _loadGerberForDefect(
    Map<String, dynamic> defect,
    int? boardId,
  ) async {
    if (boardId == null) return;
    try {
      final db = LocalDatabaseService();
      final board = await db.getBoardById(boardId);
      if (board == null) return;
      final lot = await db.getLotById(board['tbLotid_lot']);
      if (lot == null) return;
      final model = await db.getModelById(lot['tbModelid_model']);
      if (model == null) return;

      final coordinatesStr = defect['coordinates'] as String?;
      if (coordinatesStr == null || coordinatesStr.isEmpty) return;
      final coordinates = QCamberGerberService.parseCoordinatesString(
        coordinatesStr,
      );
      if (coordinates == null) return;

      await _gerberService.captureGerberImage(
        modelName: model['name'] ?? 'Model_${model['id_model']}',
        coordinates: coordinates,
        defectType: defect['type'],
        layerName: 'l8',
        zoom: 8192.0,
      );
    } catch (e) {
      debugPrint('VRSMainScreen: error loading gerber image: $e');
    }
  }

  Future<void> _startWorkflow(int boardId) async {
    // Phát 1 "vé" runId mới NGAY LẬP TỨC (trước await đầu tiên) để bất kỳ
    // chuỗi _inspectCurrentDefect cũ nào còn đang chạy (vd đang chờ PLC) sẽ
    // tự dừng ở lần kiểm tra myRunId == _runId tiếp theo, không còn ghi đè
    // _defects/_currentIndex của lượt chạy mới này.
    final myRunId = ++_runId;

    // load defects
    final list = await LocalDatabaseService().getDefectsByBoard(boardId);
    if (myRunId != _runId || !mounted) return; // đã có lượt chạy mới hơn khác

    setState(() {
      _defects = list;
      _currentIndex = 0;
      _running = true;
    });
    // Báo health-check tạm dừng trong lúc workflow chạy nhiều request
    // QCamber liên tiếp, tránh chồng request health-check lên request thật.
    StartupHealthCheck.setBusy(true);

    // Inspect the first defect; this call chains through the rest via
    // _inspectCurrentDefect's own recursion, no WebSocket connection needed.
    await _inspectCurrentDefect(myRunId);
  }

  Future<void> _stopWorkflow() async {
    // Huỷ luôn runId hiện tại - chuỗi _inspectCurrentDefect đang chạy (nếu
    // có) sẽ tự dừng ở lần kiểm tra tiếp theo, kể cả trước khi setState bên
    // dưới kịp áp dụng.
    _runId++;
    StartupHealthCheck.setBusy(false);
    setState(() {
      _running = false;
    });
    debugPrint('VRSMainScreen: stopped workflow');
  }

  /// Hiện dialog kết quả calib thành công, chờ operator xác nhận tiếp tục.
  /// Trả `true` nếu bấm "Tiếp tục", `false` nếu bấm "Hủy".
  Future<bool> _showCalibSuccessDialog(AutoBoardOffsetResponse result) async {
    final hasWarning = result.warning != null;
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              hasWarning ? Icons.warning_amber_rounded : Icons.check_circle,
              color: hasWarning ? Colors.orange : Colors.green,
            ),
            const SizedBox(width: 8),
            Text(hasWarning
                ? 'Calib thành công (có cảnh báo)'
                : 'Calib bù lệch thành công'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Góc lệch (θ): ${result.thetaDeg?.toStringAsFixed(4)}°'),
            Text('Dịch X (tx): ${result.tx?.toStringAsFixed(4)} mm'),
            Text('Dịch Y (ty): ${result.ty?.toStringAsFixed(4)} mm'),
            Text('Sai số RMS: ${result.rmsErrorMm?.toStringAsFixed(4)} mm'),
            if (hasWarning) ...[
              const SizedBox(height: 12),
              Text(
                result.warning!,
                style: const TextStyle(color: Colors.orange, fontSize: 13),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'continue'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Tiếp tục'),
          ),
        ],
      ),
    );
    return action == 'continue';
  }

  /// Chạy auto board offset calibration nếu provider báo cần (board mới hoặc
  /// đổi mặt A↔B). Trả `true` nếu OK (hoặc user chọn bỏ qua), `false` nếu
  /// user chọn Hủy (không advance sang board mới).
  Future<bool> _runCalibrationIfNeeded() async {
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    if (!vrs.calibrationNeeded) return true;

    setState(() => _calibrating = true);

    // boardId là metadata tùy chọn (ghi vào offset_runtime.json để truy vết),
    // gateway vẫn calib đúng dù không truyền.
    final result = await _plcGateway.triggerAutoBoardOffset(
      boardSide: vrs.nextBoardSide,
    );

    if (!mounted) return false;
    setState(() => _calibrating = false);

    if (result.success) {
      debugPrint(
        '📐 Calib OK: θ=${result.thetaDeg?.toStringAsFixed(4)}° '
        'tx=${result.tx?.toStringAsFixed(4)} ty=${result.ty?.toStringAsFixed(4)} '
        'RMS=${result.rmsErrorMm?.toStringAsFixed(4)}mm',
      );
      if (!mounted) return false;
      // Hiện kết quả calib, chờ operator xác nhận
      return await _showCalibSuccessDialog(result);
    }

    // Calib thất bại → dialog cho user chọn
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Calib bù lệch thất bại'),
        content: Text(
          '${result.message}\n\n'
          'Thử lại, bỏ qua (dùng tọa độ gốc không bù), hoặc hủy?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'skip'),
            child: const Text('Bỏ qua'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'retry'),
            child: const Text('Thử lại'),
          ),
        ],
      ),
    );

    if (action == 'retry') return _runCalibrationIfNeeded();
    if (action == 'skip') return true;
    return false; // cancel
  }

  /// Bấm "Bắt đầu" — calib bù lệch board trước rồi mới chạy workflow.
  /// Luôn calib khi bắt đầu board mới (board đầu tiên hoặc board bất kỳ khi
  /// operator bấm Start thủ công) vì board vừa được đặt/lật lên bàn.
  Future<void> _startWithCalibration(int boardId) async {
    // Đọc board row để xác định layer_id → board side
    final db = LocalDatabaseService();
    final boardRow = await db.getBoardById(boardId);
    final layerId = boardRow?['layer_id']?.toString();
    final side = VRSProvider.boardSideFromLayerId(layerId);

    // Cập nhật currentBoardSide trên provider (lần đầu chưa set)
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    // Provider chưa expose setter trực tiếp → ta calib với side vừa tính,
    // rồi advanceToNextBoard sẽ sync lại khi chuyển board sau này.

    setState(() => _calibrating = true);

    final result = await _plcGateway.triggerAutoBoardOffset(
      boardSide: side,
    );

    if (!mounted) return;
    setState(() => _calibrating = false);

    if (result.success) {
      debugPrint(
        '📐 Calib OK (start): θ=${result.thetaDeg?.toStringAsFixed(4)}° '
        'tx=${result.tx?.toStringAsFixed(4)} ty=${result.ty?.toStringAsFixed(4)} '
        'RMS=${result.rmsErrorMm?.toStringAsFixed(4)}mm',
      );
      if (!mounted) return;
      // Hiện kết quả calib, chờ operator xác nhận trước khi chạy workflow
      final proceed = await _showCalibSuccessDialog(result);
      if (proceed && mounted) {
        await _startWorkflow(boardId);
      }
      return;
    }

    // Calib thất bại → dialog
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Calib bù lệch thất bại'),
        content: Text(
          '${result.message}\n\n'
          'Thử lại, bỏ qua (dùng tọa độ gốc không bù), hoặc hủy?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'skip'),
            child: const Text('Bỏ qua'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'retry'),
            child: const Text('Thử lại'),
          ),
        ],
      ),
    );

    if (action == 'retry') {
      await _startWithCalibration(boardId);
    } else if (action == 'skip') {
      await _startWorkflow(boardId);
    }
    // cancel → không làm gì
  }

  /// Vận hành viên đã bấm "Board tiếp theo" (sau khi lật bo / đặt board mới
  /// lên bàn) - chạy calib bù lệch nếu cần, rồi chuyển provider sang board
  /// kế tiếp và tự bắt đầu workflow luôn.
  Future<void> _advanceToNextBoard() async {
    // Chạy auto board offset calibration trước khi advance
    final proceed = await _runCalibrationIfNeeded();
    if (!proceed || !mounted) return;

    final vrsProvider = Provider.of<VRSProvider>(context, listen: false);
    await vrsProvider.advanceToNextBoard();
    final newBoardId = int.tryParse(vrsProvider.currentBoard);
    if (newBoardId != null && mounted) {
      // Reset panel hiển thị kết quả AI của board cũ trước khi chạy board mới.
      setState(() {
        _lastPersistedDefectId = null;
        _lastPersistedVerdict = null;
        _lastPersistedType = null;
        _lastCapturedImageBytes = null;
      });
      await _startWorkflow(newBoardId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isSmallScreen = screenWidth < 1200;
        final padding = isSmallScreen ? 16.0 : 24.0;

        // read providers early in the builder so UI below can use dynamic values
        final vrsProvider = Provider.of<VRSProvider>(context);
        final webSocketService = Provider.of<AutoVRSWebSocketService>(
          context,
          listen: false,
        );

        // compute display values
        final lotText =
            (vrsProvider.currentLot.isNotEmpty &&
                vrsProvider.currentLot != 'Chưa có')
            ? vrsProvider.currentLot
            : 'Chưa có';
        final boardText =
            (vrsProvider.currentBoard.isNotEmpty &&
                vrsProvider.currentBoard != 'Chưa có')
            ? vrsProvider.currentBoard
            : 'Chưa có';

        String aiText = 'Không phát hiện lỗi';
        final analysis = webSocketService.lastAnalysis;
        final detectionResults = webSocketService.lastDetectionResults;

        // DEBUG: Log raw data
        debugPrint('🔍 VRSMain aiText calculation:');
        debugPrint(
          '  detectionResults: ${detectionResults != null ? 'EXISTS' : 'NULL'}',
        );
        debugPrint('  analysis: ${analysis != null ? 'EXISTS' : 'NULL'}');

        // Ưu tiên lấy từ lastDetectionResults vì có class_name_vi
        if (detectionResults != null && detectionResults.isNotEmpty) {
          // lastDetectionResults là Map, cần lấy 'detections' array bên trong
          final detections = detectionResults['detections'];
          debugPrint(
            '  detectionResults[detections]: ${detections != null ? 'List of ${(detections as List?)?.length}' : 'NULL'}',
          );
          if (detections != null &&
              detections is List &&
              detections.isNotEmpty) {
            // Chỉ lấy lỗi có confidence cao nhất
            var highestConfDetection = detections[0];
            double highestConf = (highestConfDetection['confidence'] ?? 0.0)
                .toDouble();

            for (final d in detections) {
              final conf = (d['confidence'] ?? 0.0).toDouble();
              if (conf > highestConf) {
                highestConf = conf;
                highestConfDetection = d;
              }
            }

            final nameVi =
                highestConfDetection['class_name_vi'] ??
                highestConfDetection['className'] ??
                'Unknown';
            aiText = '$nameVi (${(highestConf * 100).toStringAsFixed(1)}%)';
            debugPrint(
              '  ✅ aiText from detectionResults (highest conf): $aiText',
            );
          }
        } else if (analysis != null) {
          // Fallback: dùng analysis nhưng lấy từ detections nếu có
          final detections = analysis['detections'];
          debugPrint(
            '  analysis[detections]: ${detections != null ? 'List of ${(detections as List?)?.length}' : 'NULL'}',
          );
          if (detections != null &&
              detections is List &&
              detections.isNotEmpty) {
            // Chỉ lấy lỗi có confidence cao nhất từ analysis
            var highestConfDetection = detections[0];
            double highestConf = (highestConfDetection['confidence'] ?? 0.0)
                .toDouble();

            for (final d in detections) {
              final conf = (d['confidence'] ?? 0.0).toDouble();
              if (conf > highestConf) {
                highestConf = conf;
                highestConfDetection = d;
              }
            }

            final nameVi =
                highestConfDetection['class_name_vi'] ??
                highestConfDetection['class_name'] ??
                'Unknown';
            final displayName = _getDefectDisplayName(nameVi.toString());
            aiText =
                '$displayName (${(highestConf * 100).toStringAsFixed(1)}%)';
            debugPrint('  ✅ aiText from analysis (highest conf): $aiText');
          } else if ((analysis['total_defects'] ?? 0) > 0) {
            aiText = 'Có lỗi';
            debugPrint('  ⚠️ aiText fallback: $aiText');
          }
        }
        debugPrint('  FINAL aiText: $aiText');

        return Padding(
          padding: EdgeInsets.all(padding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Image Display Panel
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    // Main VRS Image - Left side
                    Expanded(
                      flex: 2, // Increased from 1 to 2 for wider camera view
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Ảnh Live từ VRS',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const StreamSourceControl(),
                              const SizedBox(height: 12),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    // Calculate square size based on available space
                                    final availableWidth = constraints.maxWidth;
                                    final availableHeight =
                                        constraints.maxHeight;
                                    final squareSize =
                                        availableWidth < availableHeight
                                        ? availableWidth
                                        : availableHeight;

                                    return Center(
                                      child: SizedBox(
                                        width: squareSize,
                                        height: squareSize,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.black,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: ValueListenableBuilder<Uint8List?>(
                                            valueListenable:
                                                Provider.of<
                                                      AutoVRSWebSocketService
                                                    >(context, listen: false)
                                                    .currentFrameNotifier,
                                            builder: (context, frameData, child) {
                                              final webSocketService =
                                                  Provider.of<
                                                    AutoVRSWebSocketService
                                                  >(context, listen: false);

                                              if (webSocketService
                                                      .displayImage !=
                                                  null) {
                                                // Backend đã vẽ bounding boxes vào ảnh rồi, chỉ cần hiển thị
                                                return ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: Image.memory(
                                                    webSocketService
                                                        .displayImage!,
                                                    fit: BoxFit.cover,
                                                    width: squareSize,
                                                    height: squareSize,
                                                    gaplessPlayback:
                                                        true, // Optimize for smooth video playback
                                                  ),
                                                );
                                              } else if (frameData != null) {
                                                return ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: Image.memory(
                                                    frameData,
                                                    fit: BoxFit.cover,
                                                    width: squareSize,
                                                    height: squareSize,
                                                    gaplessPlayback:
                                                        true, // Optimize for smooth video playback
                                                  ),
                                                );
                                              } else if (webSocketService
                                                  .isConnected) {
                                                return const Center(
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      CircularProgressIndicator(
                                                        color: Colors.white,
                                                      ),
                                                      SizedBox(height: 8),
                                                      Text(
                                                        'Đang khởi tạo camera...',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              } else {
                                                return const Center(
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Icon(
                                                        Icons.wifi_off,
                                                        color: Colors.red,
                                                        size: 48,
                                                      ),
                                                      SizedBox(height: 8),
                                                      Text(
                                                        'AutoVRS Disconnected',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 16),

                    // Comparison Images - Right side (stacked)
                    Expanded(
                      flex: 1,
                      child: Column(
                        children: [
                          // Gerber View
                          Expanded(
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Ảnh từ Thiết kế Gerber',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: GerberImageWidget(
                                        isLoading: _isLoadingGerber,
                                        errorMessage: _gerberService.lastError,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // AOI Capture
                          Expanded(
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Ảnh từ PCI AOI',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final availableWidth =
                                              constraints.maxWidth;
                                          final availableHeight =
                                              constraints.maxHeight;
                                          final squareSize =
                                              availableWidth < availableHeight
                                              ? availableWidth
                                              : availableHeight;

                                          return Center(
                                            child: SizedBox(
                                              width: squareSize,
                                              height: squareSize,
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: Colors.grey.shade200,
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  child:
                                                      _lastCapturedImageBytes !=
                                                          null
                                                      ? Image.memory(
                                                          _lastCapturedImageBytes!,
                                                          fit: BoxFit.contain,
                                                          errorBuilder:
                                                              (
                                                                context,
                                                                error,
                                                                stackTrace,
                                                              ) => const Center(
                                                                child: Text(
                                                                  'Không thể hiển thị ảnh',
                                                                  style: TextStyle(
                                                                    color: Colors
                                                                        .black,
                                                                    fontSize:
                                                                        12,
                                                                  ),
                                                                ),
                                                              ),
                                                        )
                                                      : const Center(
                                                          child: Text(
                                                            'AOI Capture',
                                                            style: TextStyle(
                                                              color: Colors
                                                                  .black,
                                                              fontSize: 12,
                                                            ),
                                                          ),
                                                        ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 24),

              // Info & Action Panel
              SizedBox(
                width: isSmallScreen ? 280 : 320,
                child: Card(
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: Colors.grey.shade300, width: 1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Giám sát VRS Auto',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),

                          const Divider(height: 24),

                          // Info rows (dynamic from providers)
                          _buildInfoRow('Mã Lô (id_lot):', lotText),
                          const SizedBox(height: 12),
                          _buildInfoRow('Số thứ tự bo:', boardText),
                          const SizedBox(height: 12),
                          _buildInfoRow('Loại lỗi AI dự đoán:', aiText),
                          const SizedBox(height: 12),
                          // Total defects for current board
                          FutureBuilder<List<Map<String, dynamic>>>(
                            future: (int.tryParse(boardText) != null)
                                ? LocalDatabaseService().getDefectsByBoard(
                                    int.parse(boardText),
                                  )
                                : Future.value([]),
                            builder: (context, snap) {
                              final total = snap.hasData
                                  ? snap.data!.length
                                  : 0;
                              return _buildInfoRow(
                                'Số lỗi trên bo:',
                                total.toString(),
                              );
                            },
                          ),

                          const SizedBox(height: 24),

                          // AI Result
                          const Text(
                            'Kết quả phán định AI',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 12),

                          // Dynamic AI Result Panel - shows OK (green) or NG (red)
                          Builder(
                            builder: (context) {
                              String verdictShort = 'OK';
                              Color bgColor = Colors.green.shade50;
                              Color txtColor = Colors.green.shade600;
                              String detailText = aiText;

                              // Prefer the last persisted verdict/type when available.
                              // This ensures the result card shows the most recent
                              // persisted AI decision even if _currentIndex has moved on.
                              if (_lastPersistedVerdict != null) {
                                verdictShort = _lastPersistedVerdict!
                                    .toUpperCase();
                                if (verdictShort == 'OK') {
                                  bgColor = Colors.green.shade50;
                                  txtColor = Colors.green.shade600;
                                  detailText = 'Không phát hiện lỗi';
                                } else {
                                  bgColor = Colors.red.shade50;
                                  txtColor = Colors.red.shade600;
                                  if (_lastPersistedType != null &&
                                      _lastPersistedType!.isNotEmpty) {
                                    detailText = _getDefectDisplayName(
                                      _lastPersistedType!,
                                    );
                                  } else {
                                    detailText = aiText;
                                  }
                                }
                              } else if (_defects.isNotEmpty &&
                                  _currentIndex < _defects.length) {
                                final cur = _defects[_currentIndex];
                                final j = cur['judgement']
                                    ?.toString()
                                    .toUpperCase();
                                if (j != null && j.isNotEmpty) {
                                  verdictShort = j;
                                  if (verdictShort == 'OK') {
                                    bgColor = Colors.green.shade50;
                                    txtColor = Colors.green.shade600;
                                    detailText = 'Không phát hiện lỗi';
                                  } else {
                                    bgColor = Colors.red.shade50;
                                    txtColor = Colors.red.shade600;
                                    // show detected type if available
                                    detailText =
                                        (cur['type'] != null &&
                                            cur['type'].toString().isNotEmpty)
                                        ? _getDefectDisplayName(
                                            cur['type'].toString(),
                                          )
                                        : aiText;
                                  }
                                } else {
                                  // no persisted judgement yet - fallback to lastAnalysis
                                  if (analysis != null) {
                                    final hasDefects =
                                        (analysis['total_defects'] ?? 0) > 0 ||
                                        (analysis['defects_by_type'] is Map &&
                                            (analysis['defects_by_type'] as Map)
                                                .keys
                                                .isNotEmpty);
                                    if (hasDefects) {
                                      verdictShort = 'NG';
                                      bgColor = Colors.red.shade50;
                                      txtColor = Colors.red.shade600;
                                    } else {
                                      verdictShort = 'OK';
                                      bgColor = Colors.green.shade50;
                                      txtColor = Colors.green.shade600;
                                    }
                                  }
                                }
                              } else {
                                // no defect in memory - use analysis
                                if (analysis != null) {
                                  final hasDefects =
                                      (analysis['total_defects'] ?? 0) > 0 ||
                                      (analysis['defects_by_type'] is Map &&
                                          (analysis['defects_by_type'] as Map)
                                              .keys
                                              .isNotEmpty);
                                  if (hasDefects) {
                                    verdictShort = 'NG';
                                    bgColor = Colors.red.shade50;
                                    txtColor = Colors.red.shade600;
                                  } else {
                                    verdictShort = 'OK';
                                    bgColor = Colors.green.shade50;
                                    txtColor = Colors.green.shade600;
                                  }
                                }
                              }

                              return Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: bgColor,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      verdictShort,
                                      style: TextStyle(
                                        fontSize: 32,
                                        fontWeight: FontWeight.bold,
                                        color: txtColor,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      detailText,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: txtColor.withOpacity(0.9),
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),

                          const SizedBox(height: 16),

                          // Defect list for currently selected board
                          DefectListWidget(
                            boardId: int.tryParse(boardText),
                            height: 200,
                            reloadToken: _defectListReloadToken,
                          ),

                          const SizedBox(height: 16),

                          // Start / Stop operator-driven workflow
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed:
                                      (boardText != 'Chưa có' && !_running && !_calibrating)
                                      ? () {
                                          final bId = int.tryParse(boardText);
                                          if (bId != null) _startWithCalibration(bId);
                                        }
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                  ),
                                  child: _calibrating
                                      ? const Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            SizedBox(
                                              height: 16,
                                              width: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            ),
                                            SizedBox(width: 8),
                                            Text('Đang calib...'),
                                          ],
                                        )
                                      : const Text('Bắt đầu'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _running ? _stopWorkflow : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                  ),
                                  child: const Text('Dừng'),
                                ),
                              ),
                            ],
                          ),

                          // Board hiện tại đã hết lỗi - chờ vận hành viên xác
                          // nhận (lật bo cùng board_code khác layer, hoặc đặt
                          // board vật lý mới lên bàn) trước khi qua board kế.
                          if (vrsProvider.nextBoardAvailable) ...[
                            const SizedBox(height: 16),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.blue.shade200,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    vrsProvider.nextBoardIsNewPhysical
                                        ? 'Đã xong board hiện tại. Đặt board mới lên bàn rồi bấm tiếp tục.'
                                        : 'Đã xong board hiện tại. Lật bo rồi bấm tiếp tục.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.blue.shade800,
                                    ),
                                  ),
                                  // Thông báo sẽ tự động calib nếu cần
                                  if (vrsProvider.calibrationNeeded) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      '⚙️ Sẽ tự động calib bù lệch board '
                                      '(mặt ${vrsProvider.nextBoardSide})',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.blue.shade600,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: _calibrating
                                        ? Column(
                                            children: [
                                              const SizedBox(
                                                height: 24,
                                                width: 24,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2.5,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                'Đang calib bù lệch board...',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.blue.shade700,
                                                ),
                                              ),
                                            ],
                                          )
                                        : ElevatedButton(
                                            onPressed: _advanceToNextBoard,
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.blue,
                                            ),
                                            child: const Text('Board tiếp theo'),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ] else if (vrsProvider.lotFinished) ...[
                            const SizedBox(height: 16),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                vrsProvider.lastCompletedBoardId.isNotEmpty
                                    ? 'Đã hoàn tất board cuối cùng (Board #${vrsProvider.lastCompletedBoardId}). '
                                          'Không còn board nào khác trong lô này.'
                                    : 'Đã hoàn tất toàn bộ board trong lô này.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.green.shade800,
                                ),
                              ),
                            ),
                          ],

                          const SizedBox(height: 16),

                          // Statistics Button
                          Consumer<AuthProvider>(
                            builder: (context, authProvider, _) {
                              return SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: authProvider.isAdminAuthenticated
                                      ? () => context.push('/statistics')
                                      : null,
                                  icon: const Icon(FeatherIcons.barChart),
                                  label: const Text('Xem thống kê'),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),

                          const SizedBox(height: 16),

                          // // Manual review button
                          // SizedBox(
                          //   width: double.infinity,
                          //   child: ElevatedButton.icon(
                          //     onPressed: () {
                          //       Navigator.of(context).push(
                          //         MaterialPageRoute(
                          //           builder: (context) => ManualVRSScreen(),
                          //         ),
                          //       );
                          //     },
                          //     icon: const Icon(FeatherIcons.edit3),
                          //     label: const Text('Phán định thủ công'),
                          //     style: ElevatedButton.styleFrom(
                          //       backgroundColor: Colors.orange,
                          //       foregroundColor: Colors.white,
                          //       padding: const EdgeInsets.symmetric(vertical: 12),
                          //     ),
                          //   ),
                          // ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
