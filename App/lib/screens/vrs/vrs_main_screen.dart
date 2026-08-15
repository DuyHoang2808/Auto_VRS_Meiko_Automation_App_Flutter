import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../main.dart';
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
  bool _checkingNewBoard = false;
  // Có một thao tác board đang chạy (pre-flight → calib → soi → đuôi hoàn tất).
  // Khác `_running`: `_running` chỉ đúng trong lúc soi, còn `_busy` phủ cả giai
  // đoạn trước khi soi (đọc DB, calib) và sau khi soi (đưa camera về gốc) - đó
  // là những khoảng mà nút "Bắt đầu" từng bật lại được và bấm vào sẽ gửi lệnh
  // PLC chồng lên lệnh đang chạy.
  bool _busy = false;
  List<Map<String, dynamic>> _defects = [];
  int _currentIndex = 0;
  // Token to force defect list widget to reload its cached future
  int _defectListReloadToken = 0;
  // id_defect đang được PLC/AI xử lý ngay lúc này (hiện chấm màu xanh dương
  // trên DefectListWidget) - null khi không có gì đang chạy.
  int? _processingDefectId;
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

  // Trạng thái bù lệch của board đang mở, để hiện cho vận hành viên biết đã
  // calib hay chưa - kể cả khi lần calib đó được làm ở màn VRS thủ công (màn đó
  // gọi VRSProvider.markCalibrated). Trước đây tab Auto không hiện gì cả, nên
  // operator không có cách nào biết ngoài việc bấm "Bắt đầu" xem có calib lại.
  //   'none'    = provider không ghi nhận lần calib nào cho board+mặt này
  //   'valid'   = gateway xác nhận còn đúng dữ liệu bù lệch của board+mặt này
  //   'invalid' = provider có ghi nhận nhưng gateway không còn dữ liệu đúng
  //   'unknown' = chưa hỏi được gateway (offline / lỗi mạng)
  String _offsetStatus = 'none';
  // "boardId|mặt" mà `_offsetStatus` nói về. Phải so khớp trước khi hiển thị,
  // không thì đổi board xong vẫn còn hiện trạng thái của board cũ.
  String? _offsetStatusKey;
  // Đang có 1 lượt hỏi gateway. Timeout của getOffsetStatus là 5s, trùng chu kỳ
  // poll 5s, nên khi gateway offline các lượt hỏi sẽ chồng lên nhau.
  bool _checkingOffset = false;

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
      _refreshOffsetStatus();
    });
    // Màn hình này bị dispose khi điều hướng sang tab khác, nên mỗi lần quay về
    // phải hỏi lại gateway - đây cũng là đường để calib làm ở VRS thủ công hiện
    // lên đúng ở tab Auto.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshOffsetStatus());
  }

  /// Đối chiếu ghi nhận calib trong provider với dữ liệu bù lệch gateway đang
  /// giữ, để hiện trạng thái thật thay vì chỉ tin cache trong app.
  Future<void> _refreshOffsetStatus() async {
    if (!mounted) return;
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    final boardId = vrs.currentBoard;
    final side = vrs.currentBoardSide;
    final key = '$boardId|$side';

    if (boardId.isEmpty ||
        boardId == 'Chưa có' ||
        !vrs.isCalibratedFor(boardId: boardId, side: side)) {
      if (_offsetStatus != 'none' || _offsetStatusKey != key) {
        setState(() {
          _offsetStatus = 'none';
          _offsetStatusKey = key;
        });
      }
      return;
    }

    // Đang chạy PLC/calib: dữ liệu bù lệch không đổi trong lúc đó, hỏi thêm chỉ
    // thêm nhiễu (và trong 90s calib thì kết quả cũ chắc chắn còn đúng).
    if (_busy || _calibrating || _running || _checkingOffset) return;

    _checkingOffset = true;
    final Map<String, dynamic> status;
    try {
      status = await _plcGateway.getOffsetStatus(boardSide: side);
    } finally {
      _checkingOffset = false;
    }
    if (!mounted) return;

    final String next;
    if (status['success'] == false) {
      next = 'unknown'; // gateway không trả lời được, KHÔNG kết luận là chưa calib
    } else {
      final data = status['data'];
      final savedId = data is Map ? data['board_id']?.toString() : null;
      next = (status['exists'] == true && savedId != null && savedId == boardId)
          ? 'valid'
          : 'invalid';
    }
    if (next != _offsetStatus || key != _offsetStatusKey) {
      setState(() {
        _offsetStatus = next;
        _offsetStatusKey = key;
      });
    }
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
  /// Soi lần lượt các lỗi còn lại của board hiện tại.
  ///
  /// Dùng VÒNG LẶP chứ không đệ quy: 1 layer có thể tới ~2000 lỗi (xem ghi chú
  /// trong aoi_ingest_service.py) và mỗi lần gọi lại giữ riêng 1 bản
  /// `defectsForBoard` + `reloaded` (mỗi bản là list ~2000 Map), nên đệ quy vừa
  /// phình stack vừa giữ sống toàn bộ các list trung gian.
  Future<void> _inspectCurrentDefect([int? runId]) async {
    final myRunId = runId ?? _runId;
    // Chốt chống đứng yên: mỗi lượt phải làm `_currentIndex` tiến lên. Nếu
    // không (vd updateDefect ghi 0 dòng nên lỗi vẫn "chưa phán định", hoặc lỗi
    // vừa soi không còn trong list khi reload) thì vòng lặp sẽ soi lại đúng lỗi
    // đó mãi và bắn lệnh PLC liên tục. Bản đệ quy cũ vô tình "thoát" nhờ tràn
    // stack; vòng lặp thì không, nên phải chặn tường minh.
    int lastIndex = -1;
    int stuckCount = 0;
    while (true) {
      if (!_running || myRunId != _runId) {
        debugPrint(
          'VRSMainScreen: _inspectCurrentDefect stop - workflow not running or stale run (myRunId=$myRunId, current=$_runId)',
        );
        return;
      }

      final indexBefore = _currentIndex;
      final keepGoing = await _inspectOneDefect(myRunId);
      if (!keepGoing) return;

      if (_currentIndex == indexBefore && _currentIndex == lastIndex) {
        stuckCount++;
        if (stuckCount >= 2) {
          _abortWorkflow(
            'không lưu được phán định cho lỗi thứ ${_currentIndex + 1} '
            '(kiểm tra lại nhiều lần không tiến triển)',
          );
          return;
        }
      } else {
        stuckCount = 0;
      }
      lastIndex = indexBefore;
    }
  }

  /// Soi đúng 1 lỗi (di chuyển PLC + chụp + AI + lưu phán định).
  /// Trả `true` nếu còn lỗi tiếp theo cần soi, `false` nếu phải dừng vòng lặp.
  Future<bool> _inspectOneDefect(int myRunId) async {
    debugPrint(
      'VRSMainScreen: _inspectOneDefect start - defectsLoaded=${_defects.length}',
    );

    try {
      final vrsProvider = Provider.of<VRSProvider>(context, listen: false);

      // If we already loaded defects for this run, prefer them; otherwise fetch
      List<Map<String, dynamic>> defectsForBoard = _defects;
      if (defectsForBoard.isEmpty) {
        final parsedBoardId = int.tryParse(vrsProvider.currentBoard);
        if (parsedBoardId != null) {
          defectsForBoard = await LocalDatabaseService().getDefectsByBoard(
            parsedBoardId,
          );
        }
      }

      if (defectsForBoard.isEmpty) {
        // Board không có lỗi nào (AOI_Ingest vẫn tạo board với defect_quantity=0
        // cho board tốt). Trước đây chỉ `return` nên _running kẹt true vĩnh
        // viễn: nút "Bắt đầu" tắt, board không bao giờ completed, và
        // setBusy(true) treo health-check cả session. Phải đóng board tử tế.
        debugPrint(
          'VRSMainScreen: board khong co loi nao -> hoan tat board',
        );
        final boardIdForFinish = int.tryParse(vrsProvider.currentBoard);
        setState(() {
          _running = false;
          _processingDefectId = null;
        });
        StartupHealthCheck.setBusy(false);
        if (myRunId == _runId) {
          await _finishBoard(boardIdForFinish);
          if (mounted) {
            scaffoldMessengerKey.currentState?.showSnackBar(
              const SnackBar(
                content: Text('Board này không có lỗi nào - đã hoàn tất'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 3),
              ),
            );
          }
        }
        return false;
      }

      // Nếu _currentIndex ra ngoài khoảng thì nhảy tới lỗi CHƯA phán định đầu
      // tiên - trước đây fallback về 0, tức soi lại lỗi #1 đã phán định xong.
      int idx = (_currentIndex >= 0 && _currentIndex < defectsForBoard.length)
          ? _currentIndex
          : firstUnjudgedDefectIndex(defectsForBoard);
      // Bỏ qua các lỗi đã được phán định (vd VRS thủ công vừa phán định trong
      // lúc chuỗi này đang chờ PLC).
      while (idx >= 0 &&
          idx < defectsForBoard.length &&
          isDefectJudged(defectsForBoard[idx])) {
        idx++;
      }
      if (idx < 0 || idx >= defectsForBoard.length) {
        // Đã phán định hết -> đóng board qua đúng đường hoàn tất.
        debugPrint(
          'VRSMainScreen: khong con loi chua phan dinh -> hoan tat board',
        );
        final boardIdForFinish = int.tryParse(vrsProvider.currentBoard);
        setState(() {
          _defects = defectsForBoard;
          _currentIndex = defectsForBoard.length;
          _running = false;
          _processingDefectId = null;
          _defectListReloadToken++;
        });
        StartupHealthCheck.setBusy(false);
        if (myRunId == _runId) await _finishBoard(boardIdForFinish);
        return false;
      }
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

      setState(() => _processingDefectId = defectId);

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

      if (!mounted || myRunId != _runId) return false;

      final result = await _plcGateway.inspectDefect(
        defectX: coords.x,
        defectY: coords.y,
        boardId: boardIdRaw?.toString(),
        defectId: defectId,
        boardSide: vrsProvider.currentBoardSide,
      );

      if (!mounted || myRunId != _runId) return false;

      if (result.imageBase64 != null && result.imageBase64!.isNotEmpty) {
        try {
          final bytes = base64Decode(result.imageBase64!);
          setState(() => _lastCapturedImageBytes = bytes);
        } catch (e) {
          debugPrint('VRSMainScreen: failed to decode AOI capture image: $e');
        }
      }

      if (!result.success) {
        _abortWorkflow('không kiểm tra được lỗi: ${result.message}');
        return false;
      }

      // Gateway báo KHÔNG áp được bù lệch board -> nó đã gửi PLC toạ độ nominal
      // chưa bù, nên camera đã đi sai vị trí và ảnh vừa chụp không đáng tin.
      // Dừng hẳn + dialog, KHÔNG lưu phán định (lưu vào sẽ là verdict sai gắn
      // cho lỗi này). Đây là dialog chứ không phải snackbar vì operator bắt
      // buộc phải biết trước khi soi tiếp cả board.
      if (!result.offsetApplied) {
        _abortWorkflow(
          'chưa bù lệch board mặt ${vrsProvider.currentBoardSide}',
          showSnackBar: false,
        );
        if (mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: Row(
                children: const [
                  Icon(Icons.error, color: Colors.red),
                  SizedBox(width: 8),
                  Expanded(child: Text('Chưa bù lệch board')),
                ],
              ),
              content: Text(
                'Gateway không tìm thấy dữ liệu bù lệch cho mặt '
                '${vrsProvider.currentBoardSide} nên đã dùng toạ độ gốc chưa bù.\n\n'
                'Camera có thể đã đi sai vị trí, kết quả kiểm tra không đáng tin '
                'nên KHÔNG được lưu. Hãy chạy "Calib bù lệch board" rồi kiểm '
                'tra lại.',
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Đã hiểu'),
                ),
              ],
            ),
          );
        }
        return false;
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
          // Ghi vào ai_type, KHÔNG ghi đè `type` — `type` là loại lỗi gốc AOI
          // báo. Trước đây dòng này ghi 'type': detectedType nên mỗi lỗi OK
          // biến `type` thành 'none', mất vĩnh viễn loại lỗi AOI (sai thống kê
          // + sai defectType gửi cho QCamber ở lần soi sau).
          final updateFields = <String, dynamic>{
            'ai_type': detectedType,
            'judgement': verdict,
            'time': DateTime.now().toIso8601String(),
          };
          if (result.aiImagePath != null && result.aiImagePath!.isNotEmpty) {
            updateFields['url_image'] = result.aiImagePath;
          }
          await LocalDatabaseService().updateDefect(defectId, updateFields);
        } catch (e) {
          debugPrint('Failed to persist AI result: $e');
        }

        _lastPersistedDefectId = defectId;
        _lastPersistedVerdict = verdict;
        _lastPersistedType = detectedType;
      }

      if (!mounted || myRunId != _runId) return false;

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

      // Nhảy qua các lỗi đã có phán định: VRS thủ công có thể vừa phán định
      // thêm trong lúc chuỗi này đang chờ PLC/AI. Nếu nhảy hết list thì rơi
      // vào nhánh hoàn tất bên dưới (nextIndex >= length), KHÔNG quay về 0.
      while (nextIndex < reloaded.length && isDefectJudged(reloaded[nextIndex])) {
        nextIndex++;
      }

      setState(() {
        _defects = reloaded;
        _currentIndex = nextIndex;
        _defectListReloadToken++;
        // Lỗi vừa xong đã được lưu judgement - không còn "đang xử lý" nữa.
        // Nếu còn lỗi tiếp theo, _inspectCurrentDefect sẽ set lại ngay.
        _processingDefectId = null;
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
        await _finishBoard(boardIdFromProvider);
      }

      // Còn lỗi tiếp theo -> để vòng lặp ở _inspectCurrentDefect gọi lượt sau.
      return mounted &&
          _running &&
          myRunId == _runId &&
          _currentIndex < _defects.length;
    } catch (e) {
      // Trước đây chỉ debugPrint, để lại _running=true + _processingDefectId +
      // setBusy(true) treo vĩnh viễn. Ví dụ có thật: getDefectsByBoard ở trên
      // không có retry khi DB bị AOI_Ingest lock, ném ra là kẹt cả session.
      _abortWorkflow('lỗi khi kiểm tra: $e');
      return false;
    }
  }

  /// Đóng board hiện tại: đánh dấu completed + tìm board kế trong lot, rồi đưa
  /// camera về gốc (0,0) để operator lật bo / đặt board mới mà không va vào
  /// camera đang đứng ở vị trí lỗi cuối.
  ///
  /// Mọi đường hoàn tất board phải đi qua đây (soi hết lỗi, board 0 lỗi, board
  /// đã phán định hết từ trước) - nếu không, có đường bỏ qua bước về gốc.
  Future<void> _finishBoard(int? boardId) async {
    if (!mounted) return;
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    await vrs.completeCurrentBoardAndCheckNext();

    try {
      final moveResult = await _plcGateway.movePlc(
        x: 0.0,
        y: 0.0,
        boardId: boardId,
      );
      if (!moveResult.success) {
        debugPrint(
          'VRSMainScreen: move PLC ve goc sau khi xong board that bai: '
          '${moveResult.message}',
        );
      }
    } catch (e) {
      debugPrint('VRSMainScreen: loi move PLC ve goc sau khi xong board: $e');
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
        // Chỉ đi vào metadata hiển thị của QCamberGerberService (payload gửi
        // QCamber không có field này), nên dùng luôn tên để đọc log dễ hơn.
        defectType: defectTypeForDisplay(defect),
        layerName: board['layer_id']?.toString() ?? 'l8',
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
    final List<Map<String, dynamic>> list;
    try {
      list = await LocalDatabaseService().getDefectsByBoard(boardId);
    } catch (e) {
      _abortWorkflow('không đọc được danh sách lỗi: $e');
      return;
    }
    if (myRunId != _runId || !mounted) return; // đã có lượt chạy mới hơn khác

    // Bắt đầu từ lỗi CHƯA phán định đầu tiên chứ không phải index 0, để không
    // soi lại các lỗi đã phán định (vd VRS thủ công vừa phán định vài lỗi).
    final startIdx = firstUnjudgedDefectIndex(list);
    if (list.isEmpty || startIdx == -1) {
      // Không còn gì để soi -> đóng board, KHÔNG bật _running (bật rồi return
      // là nguyên nhân treo "đang chạy" vĩnh viễn trước đây).
      debugPrint(
        'VRSMainScreen: board $boardId khong con loi chua phan dinh -> hoan tat',
      );
      setState(() {
        _defects = list;
        _currentIndex = list.length;
        _running = false;
        _processingDefectId = null;
        _defectListReloadToken++;
      });
      StartupHealthCheck.setBusy(false);
      if (myRunId == _runId) await _finishBoard(boardId);
      return;
    }

    setState(() {
      _defects = list;
      _currentIndex = startIdx;
      _running = true;
      _processingDefectId = null;
      // Board có thể đã được VRS thủ công phán định thêm -> buộc list reload.
      _defectListReloadToken++;
      // Xoá kết quả AI của board/lượt trước để panel không hiện verdict cũ.
      _lastPersistedDefectId = null;
      _lastPersistedVerdict = null;
      _lastPersistedType = null;
      _lastCapturedImageBytes = null;
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
      _processingDefectId = null;
    });
    debugPrint('VRSMainScreen: stopped workflow');
  }

  /// Dừng workflow vì lỗi/điều kiện bất thường, đảm bảo KHÔNG để lại state
  /// treo. Trước đây mỗi đường thoát tự reset một phần (hoặc không reset gì -
  /// vd `catch` cuối `_inspectCurrentDefect`, hay board 0 lỗi), làm `_running`
  /// kẹt `true` vĩnh viễn: nút "Bắt đầu" tắt, chấm xanh "đang xử lý" không
  /// tắt, và `setBusy(true)` treo luôn health-check cả session.
  /// Mọi đường thoát bất thường phải đi qua đây.
  void _abortWorkflow(String reason, {bool showSnackBar = true}) {
    debugPrint('VRSMainScreen: aborting workflow - $reason');
    // Vô hiệu hoá chuỗi đang chạy (nếu có) để nó không tiếp tục sau await.
    _runId++;
    StartupHealthCheck.setBusy(false);
    if (mounted) {
      setState(() {
        _running = false;
        _processingDefectId = null;
      });
      if (showSnackBar) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Đã dừng kiểm tra: $reason'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } else {
      _running = false;
      _processingDefectId = null;
    }
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

    // Truyền boardId để gateway ghi vào offset_runtime.json - cần cho việc xác
    // minh "offset đang lưu có đúng của board này không" (xem isCalibratedFor).
    final targetBoardId = vrs.nextBoardId;
    final targetSide = vrs.nextBoardSide;

    // Board+mặt này đã được calib rồi (thường là calib bên tab VRS thủ công) -
    // cho operator bỏ qua 90 giây calib. Vẫn phải hỏi gateway chứ không tin
    // ghi nhận trong app: nếu file offset đã mất mà ta bỏ qua calib thì gateway
    // lặng lẽ dùng toạ độ chưa bù cho cả board.
    if (vrs.isCalibratedFor(boardId: targetBoardId, side: targetSide)) {
      final stillValid = await _plcGateway.hasValidOffsetFor(
        boardSide: targetSide,
        boardId: targetBoardId,
      );
      if (!mounted) return false;
      if (stillValid) {
        final choice = await _showAlreadyCalibratedDialog(targetSide);
        if (choice == null || !mounted) return false; // Hủy -> không đổi board
        if (choice == 'skip') return true;
      } else {
        debugPrint(
          'VRSMainScreen: provider bao da calib board $targetBoardId mat '
          '$targetSide nhung gateway khong con offset hop le -> calib lai',
        );
        vrs.invalidateCalibration();
      }
    }

    setState(() => _calibrating = true);

    final result = await _plcGateway.triggerAutoBoardOffset(
      boardSide: targetSide,
      boardId: targetBoardId.isNotEmpty ? targetBoardId : null,
    );

    if (!mounted) return false;
    setState(() => _calibrating = false);

    if (result.success) {
      debugPrint(
        '📐 Calib OK: θ=${result.thetaDeg?.toStringAsFixed(4)}° '
        'tx=${result.tx?.toStringAsFixed(4)} ty=${result.ty?.toStringAsFixed(4)} '
        'RMS=${result.rmsErrorMm?.toStringAsFixed(4)}mm',
      );
      vrs.markCalibrated(boardId: targetBoardId, side: targetSide);
      if (!mounted) return false;
      _refreshOffsetStatus();
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

  /// Board này đã calib bù lệch trong phiên và gateway vẫn còn dữ liệu offset
  /// hợp lệ. Trả `'skip'` để soi luôn không calib lại, `'recalib'` để calib lại,
  /// `null` nếu Hủy.
  ///
  /// Vẫn phải hỏi operator chứ không tự bỏ qua: chỉ operator biết board có bị
  /// tháo ra / gá lại / xê dịch trong lúc họ làm việc khác hay không. Mặc định
  /// (nút nổi bật) là bỏ qua, vì trường hợp thường gặp là board không bị động.
  Future<String?> _showAlreadyCalibratedDialog(String side) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Board đã calib bù lệch'),
        content: Text(
          'Board này đã được calib bù lệch cho mặt $side và dữ liệu bù lệch vẫn '
          'còn hiệu lực.\n\n'
          'Nếu board KHÔNG bị tháo ra / xê dịch từ lúc calib: bỏ qua calib và '
          'kiểm tra luôn.\n\n'
          'Nếu board đã bị động vào: nên calib lại (mất khoảng 90 giây).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Hủy'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'recalib'),
            child: const Text('Calib lại'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'skip'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Bỏ qua, kiểm tra luôn'),
          ),
        ],
      ),
    );
  }

  /// Board đã phán định hết toàn bộ lỗi (thường do VRS thủ công soi xong, hoặc
  /// đã soi ở lượt trước). Trả `'restart'` để xoá phán định và soi lại từ đầu,
  /// `'finish'` để đóng board và sang board kế, `null` nếu Hủy.
  ///
  /// KHÔNG được tự động chọn 'finish': `markBoardCompleted` + bộ lọc của
  /// `getNextPendingBoard`/`getFirstBoardByLotId` khiến board đã hoàn tất không
  /// bao giờ chọn lại được, nên đóng board phải là quyết định của operator.
  Future<String?> _showAllJudgedDialog(int total) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Board đã kiểm tra xong'),
        content: Text(
          'Cả $total lỗi của board này đều đã được phán định.\n\n'
          'Chọn "Hoàn tất" để đóng board và chuyển sang board kế tiếp, hoặc '
          '"Kiểm tra lại từ đầu" nếu muốn kiểm tra lại (sẽ xoá toàn bộ $total '
          'phán định đã có).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Hủy'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'restart'),
            child: const Text('Kiểm tra lại từ đầu'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'finish'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Hoàn tất'),
          ),
        ],
      ),
    );
  }

  /// Hỏi operator khi resume 1 board đang dừng giữa chừng: tiếp tục đúng lỗi
  /// đang dừng (KHÔNG calib lại - board chưa bị động vào), hay coi như board
  /// vừa được gá lại (calib lại + soi từ đầu). Trả null nếu bấm "Hủy".
  ///
  /// [judged]/[total] lấy từ DB, KHÔNG từ `_defects`/`_currentIndex`: đúng vào
  /// lúc cần dialog này (vừa quay lại từ VRS thủ công) thì state widget rỗng,
  /// nên trước đây dialog hiện "đang dừng ở lỗi 1/0".
  Future<String?> _showResumeOrRestartDialog(int judged, int total) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Tiếp tục board đang dừng?'),
        content: Text(
          'Board này đã phán định $judged/$total lỗi, sẽ kiểm tra tiếp từ lỗi '
          'thứ ${judged + 1}.\n\n'
          'Nếu board KHÔNG bị di chuyển trong lúc dừng: tiếp tục kiểm tra tiếp, '
          'không cần calib lại.\n\n'
          'Nếu board đã bị tháo ra / gá lại / lật mặt: nên calib lại và kiểm '
          'tra lại từ đầu (sẽ xoá $judged phán định đã có).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Hủy'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'restart'),
            child: const Text('Board đã bị động, calib lại'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'resume'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Tiếp tục, không calib'),
          ),
        ],
      ),
    );
  }

  /// Bấm "Bắt đầu" — calib bù lệch board trước rồi mới chạy workflow.
  /// Luôn calib khi bắt đầu board mới (board đầu tiên hoặc board bất kỳ khi
  /// operator bấm Start thủ công) vì board vừa được đặt/lật lên bàn - TRỪ
  /// khi đang resume đúng board vừa dừng giữa chừng, lúc đó hỏi operator
  /// (xem [_showResumeOrRestartDialog]) vì chỉ operator mới biết board có bị
  /// động vào lúc dừng hay không.
  ///
  /// Wrapper đặt cờ `_busy` ĐỒNG BỘ (trước mọi await) rồi mới gọi phần thân.
  /// Cần thiết vì trước đây thân hàm await `getBoardById` xong mới set
  /// `_calibrating=true`; trong khoảng đó nút "Bắt đầu" vẫn bật, nên 2 lần bấm
  /// nhanh sẽ chạy 2 chu kỳ calib 90s song song cùng ghi vào D2810/D2910.
  /// `_busy` cũng phủ cả đuôi hoàn tất board (`_finishBoard` đưa camera về gốc,
  /// timeout 30s) - giai đoạn mà `_running` đã là false nên nút bật lại được.
  Future<void> _startWithCalibration(int boardId) async {
    if (_busy) {
      debugPrint('VRSMainScreen: bo qua "Bat dau" - dang co thao tac chay');
      return;
    }
    _busy = true;
    // Vô hiệu hoá mọi chuỗi _inspectCurrentDefect cũ ngay tại đây. Trước đây
    // chỉ _startWorkflow bump _runId, nên trong suốt 90s calib không có gì
    // ngăn chuỗi cũ (đang chờ PLC) ghi tiếp vào _defects/_currentIndex.
    _runId++;
    try {
      await _startWithCalibrationInner(boardId);
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _startWithCalibrationInner(int boardId) async {
    final db = LocalDatabaseService();

    // ---- Pre-flight: hỏi DB xem board này còn gì để soi, TRƯỚC khi calib ----
    // Phải chạy trước calib: board 0 lỗi hoặc board đã soi xong mà calib trước
    // thì tốn nguyên 1 chu kỳ PLC 90s rồi mới phát hiện chẳng có gì để làm.
    List<Map<String, dynamic>> defects;
    try {
      defects = await db.getDefectsByBoard(boardId);
    } catch (e) {
      _abortWorkflow('không đọc được danh sách lỗi: $e');
      return;
    }
    if (!mounted) return;

    final total = defects.length;
    final judged = defects.where(isDefectJudged).length;
    final startIdx = firstUnjudgedDefectIndex(defects);

    // empty: board không có lỗi nào -> đóng board luôn, KHÔNG calib.
    if (total == 0) {
      debugPrint('VRSMainScreen: board $boardId khong co loi -> hoan tat');
      await _finishBoard(boardId);
      if (mounted) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('Board này không có lỗi nào - đã hoàn tất'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // complete: đã phán định hết -> KHÔNG được âm thầm hoàn tất (board bị đánh
    // 'completed' là không chọn lại được nữa). Hỏi operator.
    if (startIdx == -1) {
      final choice = await _showAllJudgedDialog(total);
      if (choice == null || !mounted) return; // Hủy
      if (choice == 'finish') {
        await _finishBoard(boardId);
        return;
      }
      // 'restart' -> xoá phán định rồi soi lại từ đầu như board mới gá.
      await db.resetBoardForReinspection(boardId);
      if (!mounted) return;
    } else if (judged > 0) {
      // partial: đang dừng giữa chừng. Chỉ operator biết board có bị động vào
      // trong lúc dừng hay không, nên phải hỏi.
      final choice = await _showResumeOrRestartDialog(judged, total);
      if (choice == null || !mounted) return; // Hủy
      if (choice == 'resume') {
        // Nạp _defects + _currentIndex từ DB rồi mới soi. Trước đây nhánh này
        // không nạp gì, nên _currentIndex=0 vẫn "trong khoảng" và
        // _inspectCurrentDefect soi lại từ lỗi #1 dù operator chọn "Tiếp tục".
        final boardRow = await db.getBoardById(boardId);
        if (!mounted) return;
        Provider.of<VRSProvider>(context, listen: false).setCurrentBoardMeta(
          code: boardRow?['board_code']?.toString() ?? '',
          side: VRSProvider.boardSideFromLayerId(
            boardRow?['layer_id']?.toString(),
          ),
        );
        final myRunId = _runId; // đã bump ở wrapper
        setState(() {
          _defects = defects;
          _currentIndex = startIdx;
          _running = true;
          _processingDefectId = null;
          _defectListReloadToken++;
        });
        StartupHealthCheck.setBusy(true);
        await _inspectCurrentDefect(myRunId);
        return;
      }
      // 'restart' -> xoá phán định cũ rồi calib + soi lại từ đầu.
      await db.resetBoardForReinspection(boardId);
      if (!mounted) return;
    }

    // Đọc board row để xác định layer_id → board side
    final boardRow = await db.getBoardById(boardId);
    if (!mounted) return;
    final layerId = boardRow?['layer_id']?.toString();
    final side = VRSProvider.boardSideFromLayerId(layerId);

    // Đồng bộ currentBoardSide/currentBoardCode trên provider NGAY (không
    // đợi advanceToNextBoard) - Manual VRS screen đọc currentBoardSide để
    // gọi bù lệch, nên phải đúng ngay từ lúc board này bắt đầu chạy.
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    vrs.setCurrentBoardMeta(
      code: boardRow?['board_code']?.toString() ?? '',
      side: side,
    );

    // ---- Board này đã calib trong phiên này chưa? ----
    // Đúng kịch bản bug được báo: operator đã calib rồi sang VRS thủ công, quay
    // về Auto bấm "Bắt đầu" và bị calib lại từ đầu. Ghi nhận calib nằm ở
    // provider (sống qua điều hướng), NHƯNG phải xác minh với gateway trước khi
    // tin: nếu file offset đã mất mà vẫn bỏ qua calib thì gateway sẽ lặng lẽ
    // soi cả board bằng toạ độ chưa bù.
    if (vrs.isCalibratedFor(boardId: boardId.toString(), side: side)) {
      final offsetStillValid = await _plcGateway.hasValidOffsetFor(
        boardSide: side,
        boardId: boardId.toString(),
      );
      if (!mounted) return;
      if (offsetStillValid) {
        final choice = await _showAlreadyCalibratedDialog(side);
        if (choice == null || !mounted) return; // Hủy
        if (choice == 'skip') {
          await _startWorkflow(boardId);
          return;
        }
        // 'recalib' -> rơi xuống dưới, calib lại như bình thường.
      } else {
        debugPrint(
          'VRSMainScreen: provider bao da calib nhung gateway khong con '
          'offset hop le cho board $boardId mat $side -> calib lai',
        );
        vrs.invalidateCalibration();
      }
    }

    setState(() => _calibrating = true);

    final result = await _plcGateway.triggerAutoBoardOffset(
      boardSide: side,
      boardId: boardId.toString(),
    );

    if (!mounted) return;
    setState(() => _calibrating = false);

    if (result.success) {
      debugPrint(
        '📐 Calib OK (start): θ=${result.thetaDeg?.toStringAsFixed(4)}° '
        'tx=${result.tx?.toStringAsFixed(4)} ty=${result.ty?.toStringAsFixed(4)} '
        'RMS=${result.rmsErrorMm?.toStringAsFixed(4)}mm',
      );
      vrs.markCalibrated(boardId: boardId.toString(), side: side);
      if (!mounted) return;
      _refreshOffsetStatus();
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
      // Gọi _startWithCalibrationInner, KHÔNG gọi _startWithCalibration:
      // wrapper đó chặn khi `_busy` đang true, mà ta vẫn đang ở trong phạm vi
      // `_busy` của lần bấm "Bắt đầu" này -> gọi wrapper sẽ im lặng không làm gì.
      await _startWithCalibrationInner(boardId);
    } else if (action == 'skip') {
      await _startWorkflow(boardId);
    }
    // cancel → không làm gì
  }

  /// Vận hành viên đã bấm "Board tiếp theo" (sau khi lật bo / đặt board mới
  /// lên bàn) - chạy calib bù lệch nếu cần, rồi chuyển provider sang board
  /// kế tiếp và tự bắt đầu workflow luôn.
  Future<void> _advanceToNextBoard() async {
    // Guard đồng bộ + bump _runId trước mọi await, cùng lý do như
    // _startWithCalibration (calib ở đây cũng mất tới 90s).
    if (_busy) {
      debugPrint('VRSMainScreen: bo qua "Board tiep theo" - dang co thao tac');
      return;
    }
    _busy = true;
    _runId++;
    try {
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
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  /// Bấm "Tải lại dữ liệu" ở panel "Đã hoàn tất lô" - kiểm tra ngay DB xem
  /// AOI_Ingest đã ghi thêm board mới chưa, thay vì đợi timer poll 5s ở
  /// [_newBoardPollTimer]. Chỉ cần thiết khi vận hành viên muốn biết ngay
  /// (vd đang đứng chờ AOI xuất board tiếp theo).
  Future<void> _checkForNewBoardManually() async {
    if (_checkingNewBoard) return;
    setState(() => _checkingNewBoard = true);

    final vrsProvider = Provider.of<VRSProvider>(context, listen: false);
    final found = await vrsProvider.checkForNewBoard();

    if (!mounted) return;
    setState(() => _checkingNewBoard = false);

    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          found
              ? '✅ Đã tìm thấy board mới - bấm "Board tiếp theo" để xử lý'
              : 'Chưa có board mới nào trong lô này',
        ),
        backgroundColor: found ? Colors.green : Colors.grey.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Phán định + loại lỗi gần nhất của board đang mở, theo thứ tự ưu tiên:
  ///   1. phán định vừa lưu trong lượt này (`_lastPersisted*`)
  ///   2. lỗi đang chỉ tới, nếu đã phán định
  ///   3. lỗi ĐÃ phán định gần nhất trong danh sách (board vừa xong / vừa quay
  ///      lại màn hình nên `_currentIndex` đã vượt cuối danh sách)
  /// Trả cả hai `null` nếu board chưa phán định lỗi nào.
  ({String? verdict, String? type}) _latestVerdict() {
    if (_lastPersistedVerdict != null) {
      return (verdict: _lastPersistedVerdict, type: _lastPersistedType);
    }
    if (_currentIndex >= 0 && _currentIndex < _defects.length) {
      final cur = _defects[_currentIndex];
      if (isDefectJudged(cur)) {
        return (
          verdict: cur['judgement']?.toString(),
          type: defectTypeForDisplay(cur),
        );
      }
    }
    for (final d in _defects.reversed) {
      if (isDefectJudged(d)) {
        return (
          verdict: d['judgement']?.toString(),
          type: defectTypeForDisplay(d),
        );
      }
    }
    return (verdict: null, type: null);
  }

  /// Banner trạng thái bù lệch của board đang mở.
  ///
  /// Nguồn dữ liệu là [VRSProvider] (dùng chung cho cả 2 tab) đối chiếu với
  /// gateway, nên calib làm ở màn VRS thủ công hiện lên ngay ở đây.
  Widget _buildOffsetStatusBanner(VRSProvider vrs, String boardText) {
    if (boardText.isEmpty || boardText == 'Chưa có') {
      return const SizedBox.shrink();
    }
    final side = vrs.currentBoardSide;
    final sideLabel = 'mặt $side${side == "A" ? " - Top" : " - Bot"}';
    final claimed = vrs.isCalibratedFor(boardId: boardText, side: side);
    // Chỉ dùng kết quả xác minh nếu nó thuộc đúng board+mặt đang hiển thị.
    final checked = _offsetStatusKey == '$boardText|$side' ? _offsetStatus : 'none';

    final Color color;
    final IconData icon;
    final String text;
    if (!claimed) {
      color = Colors.orange;
      icon = Icons.warning_amber_rounded;
      text = 'Chưa calib bù lệch cho $sideLabel — bấm "Bắt đầu" sẽ tự calib.';
    } else if (checked == 'valid') {
      color = Colors.green;
      icon = Icons.check_circle_outline;
      text = 'Đã calib bù lệch $sideLabel — gateway còn dữ liệu, sẽ bỏ qua '
          'bước calib.';
    } else if (checked == 'invalid') {
      color = Colors.red;
      icon = Icons.error_outline;
      text = 'Đã calib $sideLabel trong phiên này nhưng gateway KHÔNG còn dữ '
          'liệu bù lệch đúng của board này — sẽ phải calib lại.';
    } else {
      color = Colors.blue;
      icon = Icons.sync;
      text = 'Đã calib $sideLabel — đang xác nhận với gateway...';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
          ],
        ),
      ),
    );
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

        // compute display values
        final lotText =
            (vrsProvider.currentLotCode.isNotEmpty &&
                vrsProvider.currentLotCode != 'Chưa có')
            ? vrsProvider.currentLotCode
            : 'Chưa có';
        final boardText =
            (vrsProvider.currentBoard.isNotEmpty &&
                vrsProvider.currentBoard != 'Chưa có')
            ? vrsProvider.currentBoard
            : 'Chưa có';

        // "Loại lỗi AI dự đoán": lấy từ phán định ĐÃ LƯU của board này.
        //
        // Trước đây lấy từ AutoVRSWebSocketService.lastDetectionResults /
        // lastAnalysis. Service đó app-scoped, mà ở chế độ tự động nó KHÔNG BAO
        // GIỜ được ghi (auto đi qua /api/inspect-defect của gateway, không qua
        // websocket capture) - nên giá trị duy nhất có thể có là kết quả do màn
        // VRS thủ công chụp, tức tab Auto hiện loại lỗi của board KHÁC. Kèm theo
        // đó là ~10 dòng debugPrint chạy MỖI lần build.
        final latestVerdict = _latestVerdict();
        final String aiText;
        if (latestVerdict.verdict == null) {
          aiText = 'Chưa có';
        } else if (latestVerdict.verdict!.toUpperCase() == 'OK') {
          aiText = 'Không phát hiện lỗi';
        } else if (latestVerdict.type != null &&
            latestVerdict.type!.isNotEmpty &&
            latestVerdict.type != 'none') {
          aiText = _getDefectDisplayName(latestVerdict.type!);
        } else {
          aiText = 'Có lỗi';
        }

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
                                    // Kích thước DECODE của frame preview.
                                    // `width`/`height` của Image chỉ là kích
                                    // thước vẽ - không có cacheHeight thì mỗi
                                    // frame vẫn được decode ở nguyên độ phân
                                    // giải nguồn (1080p = 8,3 MB bitmap), 15
                                    // lần/giây, để rồi vẽ vào ô vài trăm px.
                                    // Chỉ đặt cacheHeight (không đặt cả hai):
                                    // dart:ui giữ đúng tỉ lệ khi chỉ có một
                                    // chiều, còn đặt cả hai sẽ bóp méo ảnh.
                                    // Với BoxFit.cover vào ô vuông thì chiều
                                    // cao là chiều quyết định.
                                    final previewDecodeHeight =
                                        squareSize.isFinite && squareSize > 0
                                        ? squareSize.round()
                                        : null;

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
                                                    cacheHeight:
                                                        previewDecodeHeight,
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
                                                    cacheHeight:
                                                        previewDecodeHeight,
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
                          _buildInfoRow('Mã Lô:', lotText),
                          const SizedBox(height: 12),
                          _buildInfoRow('Số thứ tự bo:', boardText),
                          const SizedBox(height: 12),
                          _buildInfoRow(
                            'Tên board (AOI):',
                            vrsProvider.currentBoardCode.isNotEmpty
                                ? vrsProvider.currentBoardCode
                                : 'Chưa có',
                          ),
                          const SizedBox(height: 12),
                          _buildInfoRow(
                            'Mặt board:',
                            boardText != 'Chưa có'
                                ? '${vrsProvider.currentBoardSide}'
                                      '${vrsProvider.currentBoardSide == "A" ? " (Top)" : " (Bot)"}'
                                : 'Chưa có',
                          ),
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
                              // Nguồn dữ liệu cho panel, theo thứ tự ưu tiên:
                              //  1. Phán định vừa lưu trong lượt soi này
                              //  2. Phán định của lỗi đang ở _currentIndex
                              //  3. Phán định của lỗi ĐÃ SOI gần nhất trên board
                              //     (board soi xong / vừa quay lại màn hình -
                              //     _currentIndex đã vượt cuối danh sách)
                              //  4. Không có gì -> trạng thái TRUNG TÍNH
                              //
                              // Trước đây panel khởi tạo sẵn 'OK' + màu xanh, và
                              // nếu không nguồn nào có dữ liệu thì giữ nguyên -
                              // tức báo "OK / Không phát hiện lỗi" cho board chưa
                              // soi, hoặc mâu thuẫn với bảng lỗi bên dưới đang ghi
                              // NG. Giờ không có dữ liệu thì nói rõ là chưa có.
                              //
                              // Cũng đã bỏ nhánh fallback sang `analysis` của
                              // AutoVRSWebSocketService: service đó app-scoped và
                              // màn auto không bao giờ clear, nên nó có thể hiện
                              // verdict của board KHÁC (do màn thủ công chụp) cho
                              // board chưa soi gì.
                              final verdict = latestVerdict.verdict;
                              final verdictType = latestVerdict.type;

                              final String verdictShort;
                              final Color bgColor;
                              final Color txtColor;
                              final String detailText;

                              if (verdict == null) {
                                verdictShort = '—';
                                bgColor = Colors.grey.shade200;
                                txtColor = Colors.grey.shade700;
                                detailText = 'Chưa có kết quả phán định';
                              } else if (verdict.toUpperCase() == 'OK') {
                                verdictShort = 'OK';
                                bgColor = Colors.green.shade50;
                                txtColor = Colors.green.shade600;
                                detailText = 'Không phát hiện lỗi';
                              } else {
                                verdictShort = verdict.toUpperCase();
                                bgColor = Colors.red.shade50;
                                txtColor = Colors.red.shade600;
                                detailText =
                                    (verdictType != null &&
                                        verdictType.isNotEmpty)
                                    ? _getDefectDisplayName(verdictType)
                                    : aiText;
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
                            processingDefectId: _processingDefectId,
                          ),

                          const SizedBox(height: 16),

                          // Trạng thái bù lệch của board đang mở - bao gồm cả
                          // lần calib làm ở tab VRS thủ công.
                          if (!_calibrating)
                            _buildOffsetStatusBanner(vrsProvider, boardText),

                          // Thông báo đang calib mặt nào (tránh nhồi chữ vào
                          // nút "Bắt đầu" gây tràn nút - hiện riêng ở đây).
                          if (_calibrating) ...[
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.blue.shade200),
                              ),
                              child: Column(
                                children: [
                                  const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Đang calib bù lệch board (mặt '
                                    '${vrsProvider.currentBoardSide}'
                                    '${vrsProvider.currentBoardSide == "A" ? " - Top" : " - Bot"})...',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.blue.shade700,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],

                          // Start / Stop operator-driven workflow
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  // Chặn thêm khi `_busy` (đang pre-flight/calib/
                                  // đưa camera về gốc) và khi `nextBoardAvailable`:
                                  // lúc đó `currentBoard` vẫn trỏ vào board VỪA
                                  // XONG (completeCurrentBoardAndCheckNext chỉ
                                  // reset ở nhánh board cuối lot), nên bấm "Bắt
                                  // đầu" sẽ calib + soi lại board đã xong và ghi
                                  // đè hết phán định. Operator phải dùng nút
                                  // "Board tiếp theo".
                                  onPressed:
                                      (boardText != 'Chưa có' &&
                                          !_running &&
                                          !_calibrating &&
                                          !_busy &&
                                          !vrsProvider.nextBoardAvailable)
                                      ? () {
                                          final bId = int.tryParse(boardText);
                                          if (bId != null) _startWithCalibration(bId);
                                        }
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                  ),
                                  child: _calibrating
                                      ? const SizedBox(
                                          height: 16,
                                          width: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
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
                                  // Thông báo sẽ tự động calib nếu cần. Board
                                  // kế đã được calib (vd làm bên tab VRS thủ
                                  // công) thì nói rõ là sẽ hỏi bỏ qua, để
                                  // operator không tưởng phải chờ thêm 90s.
                                  if (vrsProvider.calibrationNeeded) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      vrsProvider.isCalibratedFor(
                                            boardId: vrsProvider.nextBoardId,
                                            side: vrsProvider.nextBoardSide,
                                          )
                                          ? '✅ Board này đã được calib bù lệch '
                                                '(mặt ${vrsProvider.nextBoardSide}) '
                                                '- sẽ hỏi bỏ qua bước calib'
                                          : '⚙️ Sẽ tự động calib bù lệch board '
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
                                                'Đang calib bù lệch board (mặt '
                                                '${vrsProvider.nextBoardSide}'
                                                '${vrsProvider.nextBoardSide == "A" ? " - Top" : " - Bot"})...',
                                                textAlign: TextAlign.center,
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    vrsProvider.lastCompletedBoardId.isNotEmpty
                                        ? 'Đã hoàn tất board cuối cùng (Board #${vrsProvider.lastCompletedBoardId}). '
                                              'Không còn board nào khác trong lô này.'
                                        : 'Đã hoàn tất toàn bộ board trong lô này.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.green.shade800,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    onPressed: _checkingNewBoard
                                        ? null
                                        : _checkForNewBoardManually,
                                    icon: _checkingNewBoard
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            FeatherIcons.refreshCw,
                                            size: 16,
                                          ),
                                    label: Text(
                                      _checkingNewBoard
                                          ? 'Đang kiểm tra...'
                                          : 'Tải lại dữ liệu (kiểm tra board mới)',
                                    ),
                                  ),
                                ],
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
