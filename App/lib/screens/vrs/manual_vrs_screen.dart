import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../services/autovrs_websocket_service.dart';
// import '../../services/video_frame_service.dart'; // Disabled - using AutoVRSWebSocketService
import '../../services/ai_detection_service.dart';
import '../../services/qcamber_gerber_service.dart';
import '../../services/plc_gateway_service.dart';
import '../../providers/vrs_provider.dart';
import '../../main.dart';
import '../../widgets/defect_list_widget.dart';
import '../../widgets/gerber_image_widget.dart';
import '../../widgets/last_board_dialog.dart';
import '../../widgets/stream_source_control.dart';
import '../../services/local_database_service.dart';

class ManualVRSScreen extends StatefulWidget {
  const ManualVRSScreen({super.key});

  @override
  State<ManualVRSScreen> createState() => _ManualVRSScreenState();
}

class _ManualVRSScreenState extends State<ManualVRSScreen> {
  final double _magnification = 100; // Keep for InteractiveViewer zoom
  // index in _defects (0-based). If no defects, stays at 0.
  int _currentDefectIndex = 0;
  // Tăng mỗi lần _currentDefectIndex đổi (chuyển lỗi, đổi board...). Các thao
  // tác bất đồng bộ gắn với 1 lỗi cụ thể (chụp+phân tích AI, tải ảnh AOI) chốt
  // lại giá trị này lúc bắt đầu rồi so sánh khi có kết quả trả về - khác thì
  // bỏ kết quả, tránh ghi nhầm dữ liệu/ảnh của lỗi cũ vào lỗi đang xem. Bug
  // thật đã gặp: bấm "Chụp lại" ở lỗi #3 rồi chuyển ngay sang #4 trước khi AI
  // trả kết quả -> kết quả của #3 bị lưu vào #4.
  int _currentDefectToken = 0;
  List<Map<String, dynamic>> _defects = [];
  int _defectListReloadToken = 0;
  String? _currentBoardId;
  // Tăng mỗi lần bắt đầu load danh sách lỗi; lần load nào có token cũ thì bỏ
  // kết quả, tránh 2 lần load chồng nhau hoàn tất trái thứ tự.
  int _loadDefectsToken = 0;
  // Provider được giữ lại để bỏ listener trong dispose (không đọc context ở
  // dispose vì lúc đó cây widget đã tháo).
  VRSProvider? _vrsProvider;
  final _db = LocalDatabaseService();

  // Streamlined state management for capture + AI detection
  late AIDetectionService _aiDetectionService;
  // VideoFrameService disabled - using AutoVRSWebSocketService for SICK camera (port 8999)
  // late VideoFrameService _videoFrameService;
  late QCamberGerberService _gerberService;
  final PlcGatewayService _plcGateway = PlcGatewayService();
  final int _selectedVideoSource = 0; // 0: AutoVRS, 1: Video Stream

  // Camera movement state
  bool _isSendingCoords = false;
  // Camera đã được di chuyển tới ĐÚNG vị trí lỗi đang xem chưa - false ngay
  // sau khi tải board mới (camera còn đang ở gốc/vị trí calib để lại), true
  // sau khi `_moveCameraToDefect` chạy thành công. BẮT BUỘC phải có cờ này:
  // nếu không, phím Enter (chụp + xử lý AI) có thể chụp ngay sau khi vừa
  // calib xong - lúc đó PLC vẫn đang ở gốc (calib luôn đưa PLC về gốc trước
  // khi tính offset) chứ CHƯA di chuyển tới lỗi nào cả - chụp lúc này ra ảnh
  // sai vị trí (ảnh ở gốc, không phải ảnh lỗi) - bug thật đã gặp.
  bool _cameraPositionedForDefect = false;
  // Auto board offset calibration
  bool _calibrating = false;
  // Đang mở hộp thoại "chưa calib" - chặn mở chồng nhiều hộp khi operator giữ
  // phím mũi tên (mỗi lần đổi lỗi đều gọi _moveCameraToDefect).
  bool _calibPromptOpen = false;
  // Mặt đang được calib - phải hiện cho operator biết, vì khi calib trong lúc
  // "Chuyển Bo" thì đó là mặt của board ĐÍCH, khác mặt đang hiển thị ở trên.
  String? _calibratingSide;
  // Đang trong chuỗi "Chuyển Bo" (hỏi xác nhận -> calib -> đổi board). Phải là
  // cờ riêng, không dùng _calibrating: chuỗi này còn bao cả phần hỏi/đổi board
  // ngoài giai đoạn calib.
  bool _advancingBoard = false;

  // Capture state management
  bool _isAnalyzing = false;
  bool _hasAnalysisResult = false;
  AIDetectionResult? _analysisResult;
  Uint8List? _latestCapturedFrame;
  String?
  _pendingJudgement; // 'OK' or 'NG' when user selects but not yet confirmed
  bool _isLoadingGerber = false;

  // ✅ AOI Image state
  File? _aoiImageFile;
  String? _aoiImageSource;
  String? _aoiImageError;
  bool _aoiImageIsNetwork = false;
  bool _isLoadingAoiImage = false;

  @override
  void initState() {
    super.initState();

    // Initialize AI Detection Service
    _aiDetectionService = AIDetectionService();
    // _videoFrameService = VideoFrameService(); // Disabled
    _gerberService = context.read<QCamberGerberService>();

    // Đăng ký listener tường minh để bắt được thay đổi board từ provider
    // (didChangeDependencies không đủ - xem _syncBoardFromProvider).
    _vrsProvider = context.read<VRSProvider>();
    _vrsProvider!.addListener(_syncBoardFromProvider);

    // Kết nối AutoVRS WebSocket khi khởi tạo màn hình
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final webSocketService = Provider.of<AutoVRSWebSocketService>(
        context,
        listen: false,
      );
      _connectToBackend(webSocketService);

      // Auto load Gerber and AOI for first defect if available
      if (_defects.isNotEmpty) {
        _loadGerberForCurrentDefect();
        _loadAOIImageForCurrentDefect();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBoardFromProvider();
  }

  /// Đồng bộ board đang xem theo `VRSProvider.currentBoard`.
  ///
  /// Được gọi từ listener đăng ký trong [initState]. Trước đây chỉ nằm trong
  /// `didChangeDependencies` với `Provider.of(listen: false)` - không đăng ký
  /// dependency nào nên KHÔNG bao giờ chạy lại; chỗ đọc `listen: true` duy nhất
  /// lại nằm trong context của `LayoutBuilder` (rebuild subtree đó, không gọi
  /// `didChangeDependencies` của State). Việc đồng bộ board chỉ "tình cờ" hoạt
  /// động nhờ màn hình bị dispose + tạo lại mỗi lần điều hướng.
  void _syncBoardFromProvider() {
    if (!mounted) return;
    final board = Provider.of<VRSProvider>(context, listen: false).currentBoard;
    if (board == _currentBoardId) return;
    _currentBoardId = board;
    // Post-frame để không setState giữa lúc build (listener có thể được gọi
    // trong lúc provider notify ở giữa một frame).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadDefectsForBoard(board);
    });
  }

  Future<void> _loadDefectsForBoard(
    String? boardIdStr, {
    int? selectedDefectId,
  }) async {
    // Token chống race: 2 lần load chồng nhau có thể hoàn tất trái thứ tự, để
    // lại `_defects` của board cũ trong khi `_currentBoardId` đã là board mới.
    // Hậu quả thật: `_moveCameraToDefect` ghép boardId mới với plc_coor cũ ->
    // PLC chạy tới toạ độ của board khác.
    final myToken = ++_loadDefectsToken;

    final id = int.tryParse(boardIdStr ?? '');
    if (id == null) {
      if (!mounted) return;
      setState(() {
        _defects = [];
        _currentDefectIndex = 0;
        _currentDefectToken++;
        _aoiImageFile = null;
        _aoiImageSource = null;
        _aoiImageError = null;
        _aoiImageIsNetwork = false;
        _cameraPositionedForDefect = false;
      });
      _resetJudgementState();
      // Schedule clearImage after build to avoid setState during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _gerberService.clearImage();
      });
      return;
    }

    final list = await _db.getDefectsByBoard(id);
    if (!mounted || myToken != _loadDefectsToken) return;
    // Đổi board -> bỏ mọi phán định/ảnh chụp còn treo của board cũ, nếu không
    // `_makeJudgment` sẽ gắn loại lỗi AI và ảnh của board cũ cho lỗi board mới.
    if (selectedDefectId == null) _resetJudgementState();
    setState(() {
      _defects = list;
      _currentDefectToken++;
      // Board/lỗi vừa tải "từ đầu" (không phải vừa lưu 1 phán định và ở lại
      // đúng lỗi đó) - camera chưa chắc đang ở đúng vị trí lỗi này (vd vừa
      // "Chuyển Bo" xong, camera còn ở gốc do calib để lại).
      if (selectedDefectId == null) _cameraPositionedForDefect = false;
      if (_defects.isEmpty) {
        _currentDefectIndex = 0;
      } else if (selectedDefectId != null) {
        final selectedIndex = _defects.indexWhere((defect) {
          final rawId =
              defect['id'] ?? defect['id_defect'] ?? defect['defect_id'];
          return (rawId is int
                  ? rawId
                  : int.tryParse(rawId?.toString() ?? '')) ==
              selectedDefectId;
        });
        _currentDefectIndex = selectedIndex >= 0 ? selectedIndex : 0;
      } else {
        // Không truyền selectedDefectId - đây là lần tải danh sách "từ đầu"
        // (mở lại app sau khi crash, đổi board, v.v.), KHÔNG phải vừa lưu 1
        // phán định. Tự tìm lỗi đầu tiên CHƯA phán định thay vì luôn về lỗi
        // số 1 - phán định cũ vẫn nằm nguyên trong DB (lưu ngay khi bấm xác
        // nhận), chỉ là trước đây màn hình không dùng lại thông tin đó khi
        // tải lại, khiến operator tưởng "mất tiến trình" sau khi app
        // crash/khởi động lại giữa chừng 1 board nhiều lỗi.
        final firstUnjudged = firstUnjudgedDefectIndex(_defects);
        _currentDefectIndex = firstUnjudged >= 0 ? firstUnjudged : 0;
      }
    });

    // Auto-load Gerber and AOI for first defect
    if (_defects.isNotEmpty) {
      _loadGerberForCurrentDefect();
      _loadAOIImageForCurrentDefect();
    } else {
      setState(() => _aoiImageFile = null);
    }
  }

  Future<void> _connectToBackend(
    AutoVRSWebSocketService webSocketService,
  ) async {
    try {
      final success = webSocketService.isConnected
          ? true
          : await webSocketService.connectLastSource();
      if (success) {
        debugPrint('Connected to AutoVRS Backend');
      } else {
        debugPrint('Failed to connect to backend');
      }
    } catch (e) {
      debugPrint('Connection error: $e');
    }
  }

  Future<void> _moveCameraToHome() async {
    setState(() => _isSendingCoords = true);

    try {
      final boardId = int.tryParse(_currentBoardId ?? '0') ?? 0;

      debugPrint('📤 Moving PLC to HOME (0, 0) via PLC Gateway API');

      // Move camera via direct HTTP call to plc_gateway_api.py (/api/plc/move),
      // replacing the old CoordWsClient -> ws_coord_server.py relay.
      final result = await _plcGateway.movePlc(
        x: 0.0,
        y: 0.0,
        boardId: boardId,
        defectId: 0,
      );

      if (!mounted) return;

      setState(() => _isSendingCoords = false);

      if (result.success) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('Da di chuyen ve goc (0, 0)'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        debugPrint('✅ Home move completed: ${result.message}');
      } else {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Loi di chuyen ve goc: ${result.message}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        debugPrint('❌ Home move failed: ${result.message}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSendingCoords = false);

        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Loi gui lenh ve goc: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      debugPrint('❌ Error sending home coordinates: $e');
    }
  }

  /// Board/mặt hiện tại không còn gì để soi nữa.
  ///
  /// Là điều kiện để Enter chuyển thành lệnh "Chuyển Bo" (xem _handleKeyEvent)
  /// và để nút "Chuyển Bo" hiện nhắc phím - để 1 chỗ duy nhất, tránh phím tắt
  /// và nhãn nút nói 2 chuyện khác nhau.
  ///
  /// Board KHÔNG CÓ LỖI NÀO cũng tính là xong: AOI vẫn tạo dòng tbBoard cho
  /// mặt sạch (defect_quantity=0), lúc đó `_defects` rỗng và
  /// `firstUnjudgedDefectIndex` trả -1. Trước đây hàm này đòi thêm
  /// `_defects.isNotEmpty` nên mặt sạch KHÔNG được coi là xong, Enter rơi
  /// xuống nhánh di chuyển camera và chỉ báo "Không có lỗi để di chuyển đến" -
  /// operator kẹt, phải rời bàn phím đi bấm nút "Chuyển Bo".
  ///
  /// Vẫn đòi phải có board đang mở: chưa chọn board nào (vd vừa hết đợt) thì
  /// `_defects` cũng rỗng, nhưng lúc đó Enter không có nghĩa "chuyển bo".
  bool get _boardFullyJudged {
    final boardId = _currentBoardId;
    if (boardId == null || boardId.isEmpty || boardId == 'Chưa có') {
      return false;
    }
    return firstUnjudgedDefectIndex(_defects) == -1;
  }

  /// Bo đang gá đã calib bù lệch chưa - điều kiện BẮT BUỘC trước khi soi lỗi.
  ///
  /// Chưa bù lệch thì gateway dùng toạ độ chưa hiệu chỉnh: camera chạy lệch
  /// khỏi lỗi thật, ảnh chụp sai chỗ, AI phán định trên ảnh sai - hỏng dữ liệu
  /// cả board mà không ai biết. Auto VRS chặn sẵn ở nút "Bắt đầu" (xem
  /// `_startWithCalibrationInner`), nhưng màn thủ công trước đây soi thẳng
  /// được từ board đầu tiên mà không calib lần nào.
  ///
  /// Trả `true` nếu được phép soi (đã calib, hoặc operator vừa calib xong).
  Future<bool> _ensureCalibratedBeforeInspect() async {
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    final boardId = vrs.currentBoard;
    // Chưa mở board nào -> không có gì để calib, để các guard khác xử lý.
    if (boardId.isEmpty || boardId == 'Chưa có') return true;
    final side = vrs.currentBoardSide;
    final boardCode = vrs.currentBoardCode;

    if (vrs.isCalibratedForPhysical(boardCode: boardCode, side: side) ||
        vrs.isCalibratedFor(boardId: boardId, side: side)) {
      // Ghi nhận trong app mới là điều kiện CẦN - file offset của gateway có
      // thể đã mất/bị ghi đè (gateway restart, dọn thư mục runtime, Auto_calib
      // chạy riêng). Hỏi lại gateway đúng id_board đã ghi vào file offset.
      final stillValid = await _plcGateway.hasValidOffsetFor(
        boardSide: side,
        boardId: vrs.calibratedBoardId,
      );
      if (!mounted) return false;
      if (stillValid) return true;
      debugPrint(
        'ManualVRS: app ghi nhan da calib nhung gateway khong con offset hop '
        'le (board ${vrs.calibratedBoardId} mat $side) -> bat calib lai',
      );
      vrs.invalidateCalibration();
    }

    // Chặn nhiều hộp thoại chồng nhau: mỗi lần bấm mũi tên đổi lỗi đều gọi
    // _moveCameraToDefect, giữ mũi tên là ra cả chồng dialog.
    if (_calibPromptOpen) return false;
    _calibPromptOpen = true;
    final calibNow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.settings, size: 40, color: Colors.orange.shade700),
        title: const Text('Chưa calib bù lệch cho bo này'),
        content: Text(
          'Bo ${boardCode.isNotEmpty ? boardCode : boardId} - mặt $side'
          '${side == "B" ? " (Top)" : " (Bot)"} chưa được calib bù lệch.\n\n'
          'Chưa calib mà kiểm tra thì máy chạy theo toạ độ chưa hiệu chỉnh, '
          'camera sẽ tới sai vị trí lỗi và ảnh chụp/phán định AI đều sai.',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Để sau'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.settings, size: 16),
            label: const Text('Calib ngay'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange.shade600,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
    _calibPromptOpen = false;
    if (calibNow != true || !mounted) return false;

    return await _runCalibration(
      boardId: boardId,
      side: side,
      boardCode: boardCode,
    );
  }

  Future<void> _moveCameraToDefect() async {
    if (_defects.isEmpty || _currentDefectIndex >= _defects.length) {
      scaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Khong co loi de di chuyen den'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Chưa calib thì KHÔNG được đưa camera tới toạ độ lỗi - toạ độ chưa bù
    // lệch sẽ đưa camera tới sai chỗ.
    if (!await _ensureCalibratedBeforeInspect()) return;
    if (!mounted) return;

    setState(() => _isSendingCoords = true);

    try {
      final defect = _defects[_currentDefectIndex];

      // plc_coor lưu toạ độ Board (Gerber/design), CHƯA quy đổi sang PLC -
      // xem comment ở local_database_service.dart. Gateway sẽ tự board_to_plc +
      // bù lệch board (giống hệt luồng /api/inspect-defect của Auto VRS).
      double boardX = 0.0, boardY = 0.0;
      final plcCoordStr = defect['plc_coor'] as String?;

      if (plcCoordStr != null && plcCoordStr.isNotEmpty) {
        try {
          // Parse plc_coor format: "19.887;5.86" (semicolon separator)
          if (plcCoordStr.contains(';')) {
            final parts = plcCoordStr.split(';');
            if (parts.length >= 2) {
              boardX = double.tryParse(parts[0].trim()) ?? 0.0;
              boardY = double.tryParse(parts[1].trim()) ?? 0.0;
            }
          }
        } catch (e) {
          debugPrint('⚠️ Failed to parse plc_coor: $e');
        }
      }

      if (boardX == 0.0 && boardY == 0.0) {
        throw Exception('Toa do loi khong hop le (0,0)');
      }

      final boardId = int.tryParse(_currentBoardId ?? '0') ?? 0;
      final rawDefectId = defect['id'] ?? defect['id_defect'] ?? 0;
      final defectId = rawDefectId is int
          ? rawDefectId
          : int.tryParse(rawDefectId.toString()) ?? 0;

      final vrs = Provider.of<VRSProvider>(context, listen: false);
      final boardSide = vrs.currentBoardSide;

      debugPrint(
        '📤 Moving PLC via Gateway API (move_bulech): board=$boardId, '
        'defect=$defectId, boardXY=($boardX,$boardY), side=$boardSide',
      );

      // Move camera qua /api/plc/move_bulech: gateway tự board_to_plc + bù
      // lệch board trước khi gửi PLC — thay cho /api/plc/move (gửi thô, không
      // mapping/không bù lệch).
      final result = await _plcGateway.movePlcWithOffset(
        boardX: boardX,
        boardY: boardY,
        boardSide: boardSide,
        boardId: boardId.toString(),
        defectId: defectId,
      );

      if (!mounted) return;

      setState(() {
        _isSendingCoords = false;
        // Camera đã thật sự di chuyển (PLC nhận lệnh thành công) - kể cả khi
        // offset chưa áp dụng (nhánh else dưới, tọa độ có thể hơi lệch),
        // camera vẫn KHÔNG còn ở gốc như lúc mới calib xong nữa - an toàn để
        // Enter chuyển sang "chụp lại" từ giờ.
        if (result.success) _cameraPositionedForDefect = true;
      });

      if (result.success) {
        if (result.offsetApplied) {
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text(
                'Da di chuyen toi PLC (${result.plcX?.toStringAsFixed(3)}, '
                '${result.plcY?.toStringAsFixed(3)}) - da bu lech mat $boardSide',
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        } else {
          // Chưa có offset_runtime cho mặt board này - cảnh báo rõ để operator
          // biết toạ độ có thể lệch, cần calib trước.
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text(
                '⚠️ Da di chuyen toi PLC (${result.plcX?.toStringAsFixed(3)}, '
                '${result.plcY?.toStringAsFixed(3)}) NHUNG CHUA bu lech board '
                'mat $boardSide - toa do co the khong chinh xac. Hay bam '
                '"Calib bù lệch board" truoc khi kiem tra.',
              ),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        debugPrint('✅ Move to defect completed: ${result.message}');
      } else {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Loi di chuyen camera: ${result.message}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        debugPrint('❌ Move to defect failed: ${result.message}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSendingCoords = false);

        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Loi gui toa do: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      debugPrint('❌ Error sending coordinates: $e');
    }
  }

  /// Calib bù lệch thủ công — operator bấm khi muốn re-calib board hiện tại.
  Future<void> _triggerManualCalibration() async {
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    final targetBoardId =
        vrs.currentBoard.isNotEmpty && vrs.currentBoard != 'Chưa có'
        ? vrs.currentBoard
        : '';

    // Đang có board kế chờ chuyển: nút này vẫn calib cho board HIỆN TẠI (mặt
    // hiện tại), nên nếu operator vừa lật bo / đổi bo thì calib này sai board
    // lẫn sai mặt, và sẽ bị "Chuyển Bo" calib lại. Hỏi trước cho rõ.
    if (vrs.nextBoardAvailable) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Đang chờ chuyển bo'),
          content: Text(
            'Nút này calib cho board đang mở ($targetBoardId - mặt '
            '${vrs.currentBoardSide}), KHÔNG phải board kế tiếp '
            '(${vrs.nextBoardId} - mặt ${vrs.nextBoardSide}).\n\n'
            'Nếu bạn vừa lật bo / đặt bo mới thì hãy bấm "Chuyển Bo" - thao tác '
            'đó tự calib đúng cho board kế tiếp.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Để tôi bấm "Chuyển Bo"'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Vẫn calib board hiện tại'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    await _runCalibration(
      boardId: targetBoardId,
      side: vrs.currentBoardSide,
      boardCode: vrs.currentBoardCode,
    );
  }

  /// Chạy calib bù lệch cho board [boardId] mặt [side]. Trả `true` nếu thành
  /// công (đã ghi nhận lên provider), `false` nếu thất bại.
  ///
  /// Tách riêng khỏi [_triggerManualCalibration] để chuỗi "Chuyển Bo" dùng lại
  /// được: khi đổi board/mặt thì phải calib cho board ĐÍCH, không phải board
  /// hiện tại (nếu ghi nhận sai id_board thì `isCalibratedFor` ở tab Auto sẽ
  /// khớp sai và bỏ qua calib cho board thực sự mới).
  Future<bool> _runCalibration({
    required String boardId,
    required String side,
    required String boardCode,
  }) async {
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    setState(() {
      _calibrating = true;
      _calibratingSide = side;
    });

    final result = await _plcGateway.triggerAutoBoardOffset(
      boardSide: side,
      boardId: boardId.isNotEmpty ? boardId : null,
    );

    if (!mounted) return false;
    setState(() {
      _calibrating = false;
      _calibratingSide = null;
    });

    if (result.success) {
      // Ghi nhận lên provider để tab Auto VRS công nhận lần calib này và không
      // bắt operator calib lại khi quay về bấm "Bắt đầu".
      vrs.markCalibrated(boardId: boardId, side: side, boardCode: boardCode);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Calib OK: θ=${result.thetaDeg?.toStringAsFixed(4)}° '
            'tx=${result.tx?.toStringAsFixed(4)} ty=${result.ty?.toStringAsFixed(4)} '
            'RMS=${result.rmsErrorMm?.toStringAsFixed(4)}mm'
            '${result.warning != null ? " ⚠️" : ""}',
          ),
          backgroundColor: result.warning != null
              ? Colors.orange
              : Colors.green,
          duration: const Duration(seconds: 4),
        ),
      );
      return true;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Calib thất bại: ${result.message}'),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ),
    );
    return false;
  }

  Future<void> _captureAndAnalyze() async {
    if (_hasAnalysisResult) {
      // User clicked "Tiếp theo" - resume live stream
      setState(() {
        _hasAnalysisResult = false;
        _analysisResult = null;
      });

      // Return to live camera view
      final webSocketService = Provider.of<AutoVRSWebSocketService>(
        context,
        listen: false,
      );
      webSocketService.returnToLiveCamera();

      return;
    }

    // Chưa calib thì ảnh chụp được là ảnh ở sai vị trí (camera chưa từng được
    // đưa tới đúng lỗi), AI phán định trên ảnh đó là rác - chặn từ đây.
    if (!await _ensureCalibratedBeforeInspect()) return;
    if (!mounted) return;

    // User clicked "Chụp lại" - capture and analyze
    // Chốt lỗi đang chụp lúc này - nút/phím chuyển lỗi đã bị khoá trong lúc
    // _isAnalyzing=true (xem _previousDefect/_nextDefect), nhưng lỗi vẫn có
    // thể đổi qua đường khác (vd board mới tới từ VRSProvider khi đang thao
    // tác) - so sánh lại token này trước khi áp kết quả để không lỡ ghi kết
    // quả AI của lỗi cũ vào lỗi đang xem.
    final myDefectToken = _currentDefectToken;
    setState(() {
      _isAnalyzing = true;
    });

    try {
      // Get current frame from active video source
      Uint8List? currentFrame;

      if (_selectedVideoSource == 0) {
        // AutoVRS WebSocket
        final webSocketService = Provider.of<AutoVRSWebSocketService>(
          context,
          listen: false,
        );
        // CHỈ chụp 1 lần. Trước đây khối này chốt ảnh từ frame preview trước,
        // rồi `captureImage()` lại chụp thêm 1 khung full-res và ghi đè lên -
        // operator thấy ảnh nhảy 2 lần, đúng như "bị chụp 2 lần".
        //
        // enableDetection: false vì màn này TỰ gọi AI ở dưới bằng
        // `_aiDetectionService` (kết quả đó mới là cái hiển thị lên UI). Bật lên
        // là gửi CÙNG một ảnh cho API detection 2 lần, đồng thời ghi kết quả vào
        // `lastDetectionResults` của service app-scoped -> tab Auto VRS hiện lẫn
        // kết quả của board đang phán định thủ công.
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filename = 'defect_${_currentDefectIndex + 1}_$timestamp.jpg';
        await webSocketService.captureImage(
          filename: filename,
          enableDetection: false,
        );
        if (!mounted) return;
        // `captureImage` đã setCapturedImage + chuyển sang xem ảnh chụp. Lấy
        // đúng ảnh nó chốt: ở nguồn RTSP frame live bị scale xuống
        // AutoVRSWebSocketService.rtspPreviewWidth cho nhẹ pipe, còn
        // `capturedImage` là khung full-res - đó mới là ảnh nên đưa vào AI.
        currentFrame = webSocketService.capturedImage;
        if (currentFrame != null) {
          _latestCapturedFrame = currentFrame;
        }
      }

      if (currentFrame == null) {
        throw Exception('Khong co frame de phan tich');
      }

      // Store captured frame for analysis (no need to store separately)
      // _capturedFrame = currentFrame;

      // Run AI detection - kem lot_code + board_code de log truy vet duoc
      // theo lo/board (BE ghi vao ten file anh + inspection_log.jsonl).
      final result = await _aiDetectionService.detectDefects(
        imageData: currentFrame,
        lotCode: _vrsProvider?.currentLotCode ?? '',
        boardCode: _vrsProvider?.currentBoardCode ?? '',
      );

      if (result != null && result.success) {
        if (!mounted) return;
        if (myDefectToken != _currentDefectToken) {
          // Lỗi đã đổi trong lúc đang phân tích (board mới tới, v.v.) - bỏ
          // kết quả của lỗi CŨ, chỉ tắt cờ đang phân tích để không kẹt nút
          // "Chụp lại" của lỗi đang xem.
          setState(() => _isAnalyzing = false);
          return;
        }
        setState(() {
          _analysisResult = result;
          _hasAnalysisResult = true;
          _pendingJudgement =
              null; // reset any previous selection on new analysis
          _isAnalyzing = false;
        });
        // Do NOT persist verdict here. Wait for user to press OK/NG to
        // confirm judgment. Persistence will be handled in _makeJudgment().
      } else {
        throw Exception(_aiDetectionService.lastError ?? "Phan tich that bai");
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
        });

        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Loi: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    _vrsProvider?.removeListener(_syncBoardFromProvider);
    _aiDetectionService.dispose();
    // _videoFrameService.dispose(); // Disabled - using AutoVRSWebSocketService
    super.dispose();
  }

  /// Xoá phán định / kết quả AI / ảnh chụp còn treo. Gọi khi đổi board và sau
  /// khi lưu phán định, để không mang state của lỗi (hoặc board) cũ sang lỗi mới.
  void _resetJudgementState() {
    if (!mounted) return;
    setState(() {
      _pendingJudgement = null;
      _analysisResult = null;
      _hasAnalysisResult = false;
      _latestCapturedFrame = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Phím tắt cho OP: ←/→ chuyển lỗi, ↑/↓ chọn OK/NG, Enter chụp + xử lý AI
    // (giống bấm "Chụp lại"), Space chốt phán định đã chọn (giống bấm "Xác
    // nhận và chuyển lỗi"), Esc bỏ lựa chọn OK/NG hiện tại. Xem
    // `_handleKeyEvent` để biết chi tiết điều kiện bật/tắt (khớp với điều
    // kiện enable của các nút bấm tương ứng).
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenWidth = MediaQuery.of(context).size.width;
          final isSmallScreen = screenWidth < 1200;
          final padding = isSmallScreen ? 16.0 : 24.0;
          final vrsProvider = Provider.of<VRSProvider>(context);
          final webSocketService = Provider.of<AutoVRSWebSocketService>(
            context,
            listen: false,
          );

          return Padding(
            // Khung ảnh live là HÌNH VUÔNG (squareSize = min(width, height) -
            // xem LayoutBuilder bên dưới), và chiều CAO mới là chiều giới hạn
            // ở hầu hết kích thước màn hình (chiều rộng luôn dư ra, để lại 2
            // dải trắng 2 bên ảnh) - giảm padding dọc để nhường không gian cho
            // ô vuông, giữ nguyên padding ngang. Cùng cách đã áp dụng cho
            // vrs_main_screen.dart.
            padding: EdgeInsets.symmetric(
              horizontal: padding,
              vertical: padding / 2,
            ),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Image Display Panel
                      Expanded(
                        flex: 3,
                        child: Row(
                          children: [
                            // Main VRS Image with navigation - Left side
                            Expanded(
                              // Ảnh live từ VRS là nơi operator thao tác chính -
                              // ưu tiên nhiều không gian hơn hẳn so với 2 ảnh
                              // tham chiếu bên phải (Gerber + AOI, chỉ để so
                              // sánh). 3:1 (trước là 2:1) để khi ẩn sidebar (xem
                              // NavigationProvider.toggleSidebar), phần diện
                              // tích tăng thêm dồn phần lớn vào ảnh live thay vì
                              // chia đều.
                              flex: 3,
                              child: Card(
                                child: Padding(
                                  // Giảm padding dọc của Card, cùng lý do với
                                  // Padding ngoài - nhường thêm chiều cao cho
                                  // ô vuông.
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Dùng Wrap (không phải Row cứng) cho cả
                                      // dòng tiêu đề: tiêu đề và cụm điều
                                      // hướng lỗi + StreamSourceControl nằm
                                      // sát nhau bên cạnh nhau trên CÙNG 1
                                      // dòng (gộp từ dòng riêng cũ để tiết
                                      // kiệm chiều cao cho ảnh live); khi
                                      // không đủ chỗ (cửa sổ hẹp), tự xuống
                                      // dòng thay vì tràn/vỡ layout.
                                      // Alignment.start (không phải
                                      // spaceBetween) để cụm nút nằm ngay sau
                                      // tiêu đề thay vì bị đẩy dạt ra hết mép
                                      // phải của Card.
                                      Wrap(
                                        alignment: WrapAlignment.start,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        spacing: 16,
                                        runSpacing: 8,
                                        children: [
                                          // Dynamic title based on viewing mode
                                          Consumer<AutoVRSWebSocketService>(
                                            builder:
                                                (
                                                  context,
                                                  webSocketService,
                                                  child,
                                                ) {
                                                  return Text(
                                                    webSocketService
                                                            .isViewingCapturedImage
                                                        ? 'Anh da chup'
                                                        : 'Ảnh Live từ VRS',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color:
                                                          webSocketService
                                                              .isViewingCapturedImage
                                                          ? Colors.blue
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .onSurface,
                                                    ),
                                                  );
                                                },
                                          ),
                                          Wrap(
                                            spacing: 12,
                                            runSpacing: 8,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  IconButton(
                                                    onPressed:
                                                        _defects.isNotEmpty &&
                                                            _currentDefectIndex >
                                                                0 &&
                                                            !_isSendingCoords &&
                                                            !_isAnalyzing
                                                        ? _previousDefect
                                                        : null,
                                                    icon: const Icon(
                                                      FeatherIcons.arrowLeft,
                                                    ),
                                                    tooltip: 'Loi truoc',
                                                  ),
                                                  Text(
                                                    '${_defects.isNotEmpty ? _currentDefectIndex + 1 : 0} / ${_defects.length}',
                                                  ),
                                                  IconButton(
                                                    onPressed:
                                                        _defects.isNotEmpty &&
                                                            _currentDefectIndex <
                                                                _defects.length -
                                                                    1 &&
                                                            !_isSendingCoords &&
                                                            !_isAnalyzing
                                                        ? _nextDefect
                                                        : null,
                                                    icon: const Icon(
                                                      FeatherIcons.arrowRight,
                                                    ),
                                                    tooltip: 'Loi tiep theo',
                                                  ),
                                                ],
                                              ),
                                              const StreamSourceControl(),
                                            ],
                                          ),
                                        ],
                                      ),

                                      const SizedBox(height: 16),

                                      Expanded(
                                        child: LayoutBuilder(
                                          builder: (context, constraints) {
                                            // Calculate square size based on available space
                                            final availableWidth =
                                                constraints.maxWidth;
                                            final availableHeight =
                                                constraints.maxHeight;
                                            final squareSize =
                                                availableWidth < availableHeight
                                                ? availableWidth
                                                : availableHeight;
                                            // Kích thước DECODE của ảnh preview.
                                            // `width`/`height` của Image chỉ là
                                            // kích thước vẽ - không có
                                            // cacheHeight thì mỗi frame vẫn
                                            // decode ở nguyên độ phân giải
                                            // nguồn (1080p = 8,3 MB bitmap),
                                            // 15 lần/giây, để rồi vẽ vào ô vài
                                            // trăm px. Chỉ đặt cacheHeight
                                            // (không đặt cả hai chiều): dart:ui
                                            // giữ đúng tỉ lệ khi chỉ có một
                                            // chiều, đặt cả hai sẽ bóp méo ảnh.
                                            // Nhân theo mức phóng đại để zoom
                                            // không bị mờ; ResizeImage tự kẹp
                                            // lại nếu vượt kích thước nguồn.
                                            final previewDecodeHeight =
                                                squareSize.isFinite &&
                                                    squareSize > 0
                                                ? (squareSize *
                                                          (_magnification /
                                                                  100.0)
                                                              .clamp(1.0, 8.0))
                                                      .round()
                                                : null;

                                            return Center(
                                              child: SizedBox(
                                                width: squareSize,
                                                height: squareSize,
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: Colors.black,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  child: Stack(
                                                    children: [
                                                      // Live video feed or captured image from AutoVRS WebSocket
                                                      ValueListenableBuilder<
                                                        Uint8List?
                                                      >(
                                                        valueListenable:
                                                            Provider.of<
                                                                  AutoVRSWebSocketService
                                                                >(
                                                                  context,
                                                                  listen: false,
                                                                )
                                                                .currentFrameNotifier,
                                                        builder: (context, frameData, child) {
                                                          final webSocketService =
                                                              Provider.of<
                                                                AutoVRSWebSocketService
                                                              >(
                                                                context,
                                                                listen: false,
                                                              );

                                                          // Đã có kết quả AI + có ảnh AI đã vẽ sẵn bounding box
                                                          // (processedImage) -> hiện ảnh ĐÓ thay vì ảnh chụp
                                                          // trơn, để operator thấy đúng vị trí AI phát hiện lỗi.
                                                          if (_hasAnalysisResult &&
                                                              _analysisResult
                                                                      ?.processedImage !=
                                                                  null) {
                                                            return ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child: InteractiveViewer(
                                                                panEnabled:
                                                                    _magnification >
                                                                    100,
                                                                scaleEnabled:
                                                                    false,
                                                                child: Transform.scale(
                                                                  scale:
                                                                      _magnification /
                                                                      100.0,
                                                                  child: Image.memory(
                                                                    _analysisResult!
                                                                        .processedImage!,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    width:
                                                                        squareSize,
                                                                    height:
                                                                        squareSize,
                                                                    cacheHeight:
                                                                        previewDecodeHeight,
                                                                    gaplessPlayback:
                                                                        true,
                                                                  ),
                                                                ),
                                                              ),
                                                            );
                                                          }
                                                          // If we have analysis result or currently analyzing, show captured image instead of live stream
                                                          if ((_hasAnalysisResult ||
                                                                  _isAnalyzing) &&
                                                              webSocketService
                                                                      .capturedImage !=
                                                                  null) {
                                                            return ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child: InteractiveViewer(
                                                                panEnabled:
                                                                    _magnification >
                                                                    100,
                                                                scaleEnabled:
                                                                    false,
                                                                child: Transform.scale(
                                                                  scale:
                                                                      _magnification /
                                                                      100.0,
                                                                  child: Image.memory(
                                                                    webSocketService
                                                                        .capturedImage!,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    width:
                                                                        squareSize,
                                                                    height:
                                                                        squareSize,
                                                                    cacheHeight:
                                                                        previewDecodeHeight,
                                                                    gaplessPlayback:
                                                                        true,
                                                                  ),
                                                                ),
                                                              ),
                                                            );
                                                          } else if (!_hasAnalysisResult &&
                                                              !_isAnalyzing &&
                                                              webSocketService
                                                                      .displayImage !=
                                                                  null) {
                                                            // Backend đã vẽ bounding boxes vào ảnh rồi, chỉ cần hiển thị
                                                            return ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child: InteractiveViewer(
                                                                panEnabled:
                                                                    _magnification >
                                                                    100,
                                                                scaleEnabled:
                                                                    false,
                                                                child: Transform.scale(
                                                                  scale:
                                                                      _magnification /
                                                                      100.0,
                                                                  child: Image.memory(
                                                                    webSocketService
                                                                        .displayImage!,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    width:
                                                                        squareSize,
                                                                    height:
                                                                        squareSize,
                                                                    cacheHeight:
                                                                        previewDecodeHeight,
                                                                    gaplessPlayback:
                                                                        true, // Optimize for smooth video playback
                                                                  ),
                                                                ),
                                                              ),
                                                            );
                                                          } else if (frameData !=
                                                              null) {
                                                            return ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child: InteractiveViewer(
                                                                panEnabled:
                                                                    _magnification >
                                                                    100,
                                                                scaleEnabled:
                                                                    false,
                                                                child: Transform.scale(
                                                                  scale:
                                                                      _magnification /
                                                                      100.0,
                                                                  child: Image.memory(
                                                                    frameData,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    width:
                                                                        squareSize,
                                                                    height:
                                                                        squareSize,
                                                                    cacheHeight:
                                                                        previewDecodeHeight,
                                                                    gaplessPlayback:
                                                                        true, // Optimize for smooth video playback
                                                                  ),
                                                                ),
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
                                                                    color: Colors
                                                                        .white,
                                                                  ),
                                                                  SizedBox(
                                                                    height: 8,
                                                                  ),
                                                                  Text(
                                                                    'Dang khoi tao camera...',
                                                                    style: TextStyle(
                                                                      color: Colors
                                                                          .white,
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
                                                                    Icons
                                                                        .wifi_off,
                                                                    color: Colors
                                                                        .red,
                                                                    size: 48,
                                                                  ),
                                                                  SizedBox(
                                                                    height: 8,
                                                                  ),
                                                                  Text(
                                                                    'AutoVRS Disconnected',
                                                                    style: TextStyle(
                                                                      color: Colors
                                                                          .white,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            );
                                                          }
                                                        },
                                                      ),

                                                      // Connection status indicator
                                                      Positioned(
                                                        top: 8,
                                                        right: 8,
                                                        child:
                                                            Consumer<
                                                              AutoVRSWebSocketService
                                                            >(
                                                              builder:
                                                                  (
                                                                    context,
                                                                    webSocketService,
                                                                    child,
                                                                  ) {
                                                                    return Container(
                                                                      padding: const EdgeInsets.symmetric(
                                                                        horizontal:
                                                                            8,
                                                                        vertical:
                                                                            4,
                                                                      ),
                                                                      decoration: BoxDecoration(
                                                                        color:
                                                                            webSocketService.isConnected
                                                                            ? Colors.green.withValues(
                                                                                alpha: 0.8,
                                                                              )
                                                                            : Colors.red.withValues(
                                                                                alpha: 0.8,
                                                                              ),
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              12,
                                                                            ),
                                                                      ),
                                                                      child: Row(
                                                                        mainAxisSize:
                                                                            MainAxisSize.min,
                                                                        children: [
                                                                          Icon(
                                                                            webSocketService.isConnected
                                                                                ? Icons.wifi
                                                                                : Icons.wifi_off,
                                                                            color:
                                                                                Colors.white,
                                                                            size:
                                                                                16,
                                                                          ),
                                                                          const SizedBox(
                                                                            width:
                                                                                4,
                                                                          ),
                                                                          Text(
                                                                            webSocketService.isConnected
                                                                                ? 'AutoVRS'
                                                                                : 'OFF',
                                                                            style: const TextStyle(
                                                                              color: Colors.white,
                                                                              fontSize: 12,
                                                                              fontWeight: FontWeight.bold,
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    );
                                                                  },
                                                            ),
                                                      ),

                                                      // Frame counter
                                                      Positioned(
                                                        bottom: 8,
                                                        left: 8,
                                                        child:
                                                            Consumer<
                                                              AutoVRSWebSocketService
                                                            >(
                                                              builder:
                                                                  (
                                                                    context,
                                                                    webSocketService,
                                                                    child,
                                                                  ) {
                                                                    return Container(
                                                                      padding: const EdgeInsets.symmetric(
                                                                        horizontal:
                                                                            8,
                                                                        vertical:
                                                                            4,
                                                                      ),
                                                                      decoration: BoxDecoration(
                                                                        color: Colors
                                                                            .black
                                                                            .withValues(
                                                                              alpha: 0.6,
                                                                            ),
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              8,
                                                                            ),
                                                                      ),
                                                                      child:
                                                                          const SizedBox.shrink(), // Ẩn Frame count
                                                                    );
                                                                  },
                                                            ),
                                                      ),
                                                    ],
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Ảnh từ thiết kế Gerber',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Expanded(
                                              child: GerberImageWidget(
                                                isLoading: _isLoadingGerber,
                                                errorMessage:
                                                    _gerberService.lastError,
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Anh tu PCI AOI',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: IconButton(
                                                tooltip: 'Tai lai anh AOI',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                icon: const Icon(
                                                  Icons.refresh,
                                                  size: 18,
                                                ),
                                                onPressed:
                                                    _loadAOIImageForCurrentDefect,
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
                                                      availableWidth <
                                                          availableHeight
                                                      ? availableWidth
                                                      : availableHeight;

                                                  return Center(
                                                    child: SizedBox(
                                                      width: squareSize,
                                                      height: squareSize,
                                                      child: Container(
                                                        decoration: BoxDecoration(
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .surfaceContainerHighest,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                6,
                                                              ),
                                                        ),
                                                        child:
                                                            _buildAOIImageWidget(),
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
                            side: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Phán định thủ công',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Divider(height: 24),
                                  // Info rows
                                  _buildInfoRow(
                                    'Mã Lô:',
                                    vrsProvider.currentLotCode.isNotEmpty
                                        ? vrsProvider.currentLotCode
                                        : 'Chưa có',
                                  ),
                                  const SizedBox(height: 12),
                                  // Hiện board_code (mã board AOI) thay vì
                                  // currentBoard (id_board, khoá DB nội bộ,
                                  // không có ý nghĩa với vận hành viên) - chỉ
                                  // đổi HIỂN THỊ, các chỗ khác trong file vẫn
                                  // dùng currentBoard/_currentBoardId (id_board)
                                  // cho truy vấn DB như cũ.
                                  _buildInfoRow(
                                    'Số thứ tự bo:',
                                    vrsProvider.currentBoardCode.isNotEmpty
                                        ? vrsProvider.currentBoardCode
                                        : 'Chưa có',
                                  ),
                                  const SizedBox(height: 12),
                                  _buildInfoRow(
                                    'Mặt board:',
                                    'Mặt ${vrsProvider.currentBoardSide}'
                                        '${vrsProvider.currentBoardSide == "B" ? " (Top)" : " (Bot)"}',
                                  ),
                                  const SizedBox(height: 8),
                                  // Nút calib bù lệch thủ công
                                  SizedBox(
                                    width: double.infinity,
                                    child: _calibrating
                                        ? Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 8,
                                            ),
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                const SizedBox(
                                                  height: 16,
                                                  width: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                ),
                                                const SizedBox(width: 8),
                                                // Nói rõ đang calib mặt nào: khi
                                                // calib trong lúc "Chuyển Bo" thì
                                                // là mặt của board đích, không
                                                // phải mặt hiện ở dòng trên.
                                                Text(
                                                  'Đang calib mặt '
                                                  '${_calibratingSide ?? vrsProvider.currentBoardSide}'
                                                  '${(_calibratingSide ?? vrsProvider.currentBoardSide) == "B" ? " (Top)" : " (Bot)"}'
                                                  '...',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          )
                                        : OutlinedButton.icon(
                                            // Chặn calib rời trong lúc chuỗi
                                            // "Chuyển Bo" đang chạy: chuỗi đó tự
                                            // calib cho board đích.
                                            onPressed: _advancingBoard
                                                ? null
                                                : _triggerManualCalibration,
                                            icon: const Icon(
                                              Icons.settings,
                                              size: 16,
                                            ),
                                            label: const Text(
                                              'Calib bù lệch board',
                                            ),
                                            style: OutlinedButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 8,
                                                  ),
                                              textStyle: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                  ),
                                  // Nhắc TRƯỚC khi operator bấm soi, thay vì
                                  // để họ bấm rồi mới bị hộp thoại chặn lại.
                                  // Chỉ dựa vào ghi nhận trong app (đọc được
                                  // đồng bộ lúc build); việc xác minh với
                                  // gateway nằm ở _ensureCalibratedBeforeInspect.
                                  if (!_calibrating &&
                                      vrsProvider.currentBoard.isNotEmpty &&
                                      vrsProvider.currentBoard != 'Chưa có' &&
                                      !vrsProvider.isCalibratedForPhysical(
                                        boardCode: vrsProvider.currentBoardCode,
                                        side: vrsProvider.currentBoardSide,
                                      ) &&
                                      !vrsProvider.isCalibratedFor(
                                        boardId: vrsProvider.currentBoard,
                                        side: vrsProvider.currentBoardSide,
                                      )) ...[
                                    const SizedBox(height: 8),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade50,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: Colors.orange.shade300,
                                        ),
                                      ),
                                      child: Text(
                                        'Bo này chưa calib bù lệch - phải calib '
                                        'xong mới kiểm tra lỗi được.',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.orange.shade900,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  _buildAiVerdictPanel(),
                                  const SizedBox(height: 16),

                                  // Defect list for curret board
                                  DefectListWidget(
                                    boardId: int.tryParse(
                                      vrsProvider.currentBoard,
                                    ),
                                    height: 220,
                                    reloadToken: _defectListReloadToken,
                                  ),

                                  const SizedBox(height: 24),

                                  // Capture and Analyze Button (hidden when analysis result exists or when viewing captured image)
                                  if (!_hasAnalysisResult &&
                                      !webSocketService
                                          .isViewingCapturedImage) ...[
                                    // Camera movement buttons
                                    Row(
                                      children: [
                                        // Về gốc button
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: _isSendingCoords
                                                ? null
                                                : _moveCameraToHome,
                                            icon: _isSendingCoords
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child: CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                            Color
                                                          >(Colors.white),
                                                    ),
                                                  )
                                                : const Icon(
                                                    FeatherIcons.home,
                                                    size: 16,
                                                  ),
                                            label: Text(
                                              _isSendingCoords
                                                  ? 'Đang gửi...'
                                                  : 'Về gốc',
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.blueGrey,
                                              foregroundColor: Colors.white,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 12,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        // Di chuyển Camera button
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: _isSendingCoords
                                                ? null
                                                : _moveCameraToDefect,
                                            icon: _isSendingCoords
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child: CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                            Color
                                                          >(Colors.white),
                                                    ),
                                                  )
                                                : const Icon(
                                                    FeatherIcons.navigation,
                                                    size: 16,
                                                  ),
                                            label: Text(
                                              _isSendingCoords
                                                  ? 'Đang gửi...'
                                                  : 'Di chuyển Camera',
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.orange,
                                              foregroundColor: Colors.white,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 12,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    // Chụp lại button
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: _isAnalyzing
                                                ? null
                                                : _captureAndAnalyze,
                                            icon: _isAnalyzing
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child: CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                            Color
                                                          >(Colors.white),
                                                    ),
                                                  )
                                                : const Icon(
                                                    FeatherIcons.camera,
                                                    size: 16,
                                                  ),
                                            label: Text(
                                              _isAnalyzing
                                                  ? 'Đang phân tích...'
                                                  : 'Chụp lại',
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.blue,
                                              foregroundColor: Colors.white,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 12,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],

                                  const SizedBox(height: 16),

                                  // Return to Live Camera Button - chỉ hiển thị khi đang xem ảnh đã chụp
                                  Consumer<AutoVRSWebSocketService>(
                                    builder: (context, webSocketService, child) {
                                      if (webSocketService
                                          .isViewingCapturedImage) {
                                        return Column(
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: ElevatedButton.icon(
                                                    onPressed: () {
                                                      // Reset về trạng thái ban đầu
                                                      setState(() {
                                                        _hasAnalysisResult =
                                                            false;
                                                        _analysisResult = null;
                                                      });

                                                      // Quay lại live camera
                                                      webSocketService
                                                          .returnToLiveCamera();
                                                    },
                                                    icon: const Icon(
                                                      FeatherIcons.video,
                                                      size: 16,
                                                    ),
                                                    label: const Text(
                                                      'Quay lai Live Camera',
                                                    ),
                                                    style: ElevatedButton.styleFrom(
                                                      backgroundColor:
                                                          Colors.orange,
                                                      foregroundColor:
                                                          Colors.white,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            vertical: 12,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 12),
                                            // (Removed) defect detection summary card to reduce UI clutter
                                            const SizedBox.shrink(),
                                            const SizedBox(height: 16),
                                          ],
                                        );
                                      }
                                      return const SizedBox.shrink();
                                    },
                                  ),

                                  // Manual review: select OK/NG first, then confirm
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed:
                                                  (!_hasAnalysisResult ||
                                                      (_pendingJudgement !=
                                                              null &&
                                                          _pendingJudgement !=
                                                              'OK'))
                                                  ? null
                                                  : () {
                                                      setState(() {
                                                        // select OK, deselect NG
                                                        if (_pendingJudgement ==
                                                            'OK') {
                                                          _pendingJudgement =
                                                              null;
                                                        } else {
                                                          _pendingJudgement =
                                                              'OK';
                                                        }
                                                      });
                                                    },
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    _pendingJudgement == 'OK'
                                                    ? Colors.green
                                                    : Colors.green.shade600,
                                                foregroundColor: Colors.white,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 16,
                                                    ),
                                              ),
                                              child: const Text(
                                                'OK',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed:
                                                  (!_hasAnalysisResult ||
                                                      (_pendingJudgement !=
                                                              null &&
                                                          _pendingJudgement !=
                                                              'NG'))
                                                  ? null
                                                  : () {
                                                      setState(() {
                                                        if (_pendingJudgement ==
                                                            'NG') {
                                                          _pendingJudgement =
                                                              null;
                                                        } else {
                                                          _pendingJudgement =
                                                              'NG';
                                                        }
                                                      });
                                                    },
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    _pendingJudgement == 'NG'
                                                    ? Colors.red
                                                    : Colors.red.shade600,
                                                foregroundColor: Colors.white,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 16,
                                                    ),
                                              ),
                                              child: const Text(
                                                'NG',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),

                                      const SizedBox(height: 12),

                                      // Confirm button: only enabled after user selects OK/NG
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          onPressed:
                                              (_pendingJudgement != null &&
                                                  _hasAnalysisResult &&
                                                  _defects.isNotEmpty)
                                              ? () => _makeJudgment(
                                                  _pendingJudgement == 'OK',
                                                )
                                              : null,
                                          icon: const Icon(FeatherIcons.check),
                                          label: const Text(
                                            'Xác nhận và chuyển lỗi',
                                          ),
                                          style: ElevatedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 24),

                                  // Sang LỖI kế tiếp trong cùng board. Nút này
                                  // trước đây bị gắn nhãn "Chuyển Bo" nên không
                                  // ai chuyển được board từ màn thủ công.
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed:
                                          _defects.isNotEmpty &&
                                              _currentDefectIndex <
                                                  _defects.length - 1 &&
                                              !_isSendingCoords &&
                                              !_isAnalyzing
                                          ? _nextDefect
                                          : null,
                                      icon: const Icon(FeatherIcons.arrowRight),
                                      label: const Text('Lỗi tiếp theo'),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 8),

                                  // Sang BOARD / MẶT kế tiếp
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed:
                                          (_advancingBoard ||
                                              _calibrating ||
                                              _isSendingCoords)
                                          ? null
                                          : _advanceToNextBoardFromManual,
                                      icon: _advancingBoard
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                      Color
                                                    >(Colors.white),
                                              ),
                                            )
                                          : const Icon(FeatherIcons.refreshCw),
                                      // Nhắc "(Enter)" khi board đã phán định
                                      // hết: đúng lúc đó Enter mới là lệnh
                                      // chuyển bo (xem _handleKeyEvent), và
                                      // đó cũng là lúc operator cần biết.
                                      label: Text(
                                        _advancingBoard
                                            ? 'Đang chuyển bo...'
                                            : vrsProvider.nextBoardAvailable
                                            ? 'Chuyển Bo (mặt '
                                                  '${vrsProvider.nextBoardSide})'
                                                  '${_boardFullyJudged ? " · Enter" : ""}'
                                            : 'Chuyển Bo'
                                                  '${_boardFullyJudged ? " · Enter" : ""}',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            vrsProvider.nextBoardAvailable
                                            ? Colors.green
                                            : null,
                                        foregroundColor:
                                            vrsProvider.nextBoardAvailable
                                            ? Colors.white
                                            : null,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Đợt (khoảng board) đang chạy đã hết việc -
                                  // không có nghĩa là lô đã hết board, chỉ là
                                  // cần chọn khoảng board (đợt) MỚI để tiếp
                                  // tục. Trước đây màn thủ công không có
                                  // đường nào tới `/select-board-batch`, nên
                                  // operator bị kẹt khi hết đợt (xem
                                  // VRSProvider.batchFinished).
                                  if (vrsProvider.batchFinished) ...[
                                    const SizedBox(height: 12),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade50,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            vrsProvider
                                                    .lastBatchStartCode
                                                    .isNotEmpty
                                                ? 'Đã xử lý xong đợt '
                                                      '(${vrsProvider.lastBatchStartCode} → '
                                                      '${vrsProvider.lastBatchEndCode}). '
                                                      'Lô này còn board chưa kiểm tra.'
                                                : 'Lô này chưa có đợt (khoảng '
                                                      'board) nào đang chạy.',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: Colors.orange.shade800,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          ElevatedButton.icon(
                                            onPressed: () async {
                                              final idLot = int.tryParse(
                                                vrsProvider.currentLot,
                                              );
                                              if (idLot == null) return;
                                              final idBatch = await context
                                                  .push<int>(
                                                    '/select-board-batch/$idLot',
                                                  );
                                              if (idBatch != null) {
                                                await vrsProvider
                                                    .refreshActiveBatch();
                                              }
                                            },
                                            icon: const Icon(
                                              FeatherIcons.list,
                                              size: 16,
                                            ),
                                            label: const Text('Chọn đợt mới'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  Colors.orange.shade600,
                                              foregroundColor: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Xử lý phím tắt cho thao tác thủ công (Manual VRS):
  /// ← lỗi trước · → lỗi tiếp theo (chỉ điều hướng, không phán định)
  /// ↑ chọn OK · ↓ chọn NG (giống bấm nút OK/NG, CHƯA lưu)
  /// Enter: PHÍM CHÍNH đi xuyên suốt quy trình, tuỳ trạng thái hiện tại. Thứ
  /// tự xét đúng bằng thứ tự dưới đây, KHÔNG đổi được tuỳ tiện:
  ///   - Đã phân tích VÀ đã chọn OK/NG (bằng ↑/↓): chốt phán định + tự
  ///     chuyển lỗi (giống "Xác nhận và chuyển lỗi"). Xét ĐẦU TIÊN để phán
  ///     định đang chờ không bị nhánh "chuyển bo" nuốt mất khi soi lại 1 lỗi
  ///     trên board đã xong.
  ///   - Board đã phán định HẾT lỗi, HOẶC mặt/board không có lỗi nào: chuyển
  ///     sang board/mặt kế tiếp (giống bấm "Chuyển Bo"). An toàn vì
  ///     _advanceToNextBoardFromManual luôn hỏi xác nhận trước khi đụng vào
  ///     PLC. Xem _boardFullyJudged về trường hợp mặt sạch (0 lỗi).
  ///   - Chưa chụp/phân tích + camera CHƯA tới vị trí lỗi (vd vừa "Chuyển
  ///     Bo"/calib xong, camera còn ở gốc): di chuyển camera tới đó trước
  ///     (giống bấm "Di chuyển Camera") - KHÔNG được chụp lúc này, vì calib
  ///     luôn đưa PLC về gốc nên ảnh chụp sẽ là ảnh ở gốc, không phải ảnh
  ///     lỗi (bug thật đã gặp).
  ///   - Chưa chụp/phân tích + camera ĐÃ tới vị trí lỗi: chụp + xử lý AI
  ///     (giống bấm "Chụp lại")
  ///   - Đã phân tích nhưng CHƯA chọn OK/NG: không làm gì (ignored) - chưa
  ///     có gì để xác nhận.
  ///
  /// Hệ quả đã biết: trên board đã phán định hết, Enter là "Chuyển Bo" nên
  /// KHÔNG còn chụp lại được bằng Enter - muốn soi lại 1 lỗi thì bấm nút
  /// "Chụp lại", sau đó Enter lại chốt phán định như bình thường.
  /// Space: xác nhận phán định đã chọn - giữ lại làm phím dự phòng, làm ĐÚNG
  /// việc Enter làm ở nhánh đầu tiên phía trên.
  /// Esc bỏ lựa chọn OK/NG hiện tại (an toàn vì chưa lưu gì)
  ///
  /// Điều kiện bật/tắt ở đây PHẢI khớp với điều kiện enable của nút bấm tương
  /// ứng trong build(), để phím tắt không làm được việc mà nút bấm đang chặn.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (_defects.isNotEmpty &&
            _currentDefectIndex > 0 &&
            !_isSendingCoords &&
            !_isAnalyzing) {
          _previousDefect();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;

      case LogicalKeyboardKey.arrowRight:
        if (_defects.isNotEmpty &&
            _currentDefectIndex < _defects.length - 1 &&
            !_isSendingCoords &&
            !_isAnalyzing) {
          _nextDefect();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;

      case LogicalKeyboardKey.arrowUp:
        if (_hasAnalysisResult &&
            (_pendingJudgement == null || _pendingJudgement == 'OK')) {
          setState(() {
            _pendingJudgement = _pendingJudgement == 'OK' ? null : 'OK';
          });
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;

      case LogicalKeyboardKey.arrowDown:
        if (_hasAnalysisResult &&
            (_pendingJudgement == null || _pendingJudgement == 'NG')) {
          setState(() {
            _pendingJudgement = _pendingJudgement == 'NG' ? null : 'NG';
          });
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;

      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        {
          final webSocketService = Provider.of<AutoVRSWebSocketService>(
            context,
            listen: false,
          );
          // Nhánh 1: đã có kết quả + đã chọn OK/NG -> chốt phán định, khớp
          // đúng điều kiện enable của nút "Xác nhận và chuyển lỗi".
          //
          // Phải xét TRƯỚC nhánh "chuyển bo" bên dưới: khi soi lại 1 lỗi trên
          // board đã phán định hết, phán định đang chờ vẫn phải chốt được
          // bằng Enter chứ không bị nuốt thành lệnh chuyển bo.
          if (_pendingJudgement != null &&
              _hasAnalysisResult &&
              _defects.isNotEmpty) {
            _makeJudgment(_pendingJudgement == 'OK');
            return KeyEventResult.handled;
          }

          if (!_hasAnalysisResult &&
              !webSocketService.isViewingCapturedImage &&
              !_isAnalyzing) {
            // Nhánh 2: board đã phán định hết lỗi -> Enter chính là "Chuyển
            // Bo" (sang board hoặc sang mặt kế tiếp). Không có nhánh này thì
            // Enter sau lỗi cuối lại rơi xuống nhánh chụp bên dưới và chụp
            // lại chính cái lỗi vừa phán định xong.
            //
            // Không tự ý làm gì thêm: _advanceToNextBoardFromManual luôn hỏi
            // xác nhận trước (và tự calib nếu đổi bo/đổi mặt), nên Enter lỡ
            // tay chỉ mở hộp thoại chứ không kéo PLC đi ngay.
            if (_boardFullyJudged) {
              if (!_advancingBoard && !_calibrating && !_isSendingCoords) {
                _advanceToNextBoardFromManual();
              }
              return KeyEventResult.handled;
            }
            // Nhánh 3a: camera CHƯA tới đúng vị trí lỗi đang xem (vd vừa
            // "Chuyển Bo"/calib xong, camera còn ở gốc) - di chuyển tới đó
            // trước, khớp điều kiện enable của nút "Di chuyển Camera".
            // BẮT BUỘC phải có bước này trước khi chụp: calib luôn đưa PLC
            // về gốc trước khi tính offset, nên chụp ngay lúc đó sẽ ra ảnh ở
            // gốc chứ không phải ảnh lỗi - bug thật đã gặp.
            if (!_cameraPositionedForDefect) {
              if (!_isSendingCoords) {
                _moveCameraToDefect();
              }
              return KeyEventResult.handled;
            }
            // Nhánh 3b: camera đã ở đúng vị trí - chụp + xử lý AI, khớp điều
            // kiện enable của nút "Chụp lại".
            _captureAndAnalyze();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

      case LogicalKeyboardKey.space:
        if (_pendingJudgement != null &&
            _hasAnalysisResult &&
            _defects.isNotEmpty) {
          _makeJudgment(_pendingJudgement == 'OK');
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;

      case LogicalKeyboardKey.escape:
        if (_pendingJudgement != null) {
          setState(() => _pendingJudgement = null);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;

      default:
        return KeyEventResult.ignored;
    }
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: const TextStyle(color: Colors.grey, fontSize: 14),
          ),
        ),
        Expanded(
          flex: 1,
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
        ),
      ],
    );
  }

  Future<String?> _saveCapturedAOIImage({
    required Uint8List imageBytes,
    required String? boardId,
    required int defectId,
  }) async {
    try {
      final userProfile =
          Platform.environment['USERPROFILE'] ?? Directory.current.path;
      final safeBoardId = (boardId == null || boardId.isEmpty)
          ? 'unknown_board'
          : 'board_$boardId';
      final outputDir = Directory(
        p.join(
          userProfile,
          'Documents',
          'AutoVRS',
          'aoi_captures',
          safeBoardId,
        ),
      );
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      final now = DateTime.now();
      final timestamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}_${now.millisecond.toString().padLeft(3, '0')}';
      final outputPath = p.join(
        outputDir.path,
        'defect_${defectId}_$timestamp.jpg',
      );
      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(imageBytes, flush: true);
      debugPrint('Saved AOI capture for defect $defectId: $outputPath');
      return outputPath;
    } catch (e) {
      debugPrint('Failed to save AOI capture for defect $defectId: $e');
      return null;
    }
  }

  Future<void> _loadGerberForCurrentDefect() async {
    if (_defects.isEmpty || _currentDefectIndex >= _defects.length) {
      _gerberService.clearImage();
      return;
    }

    if (mounted) {
      setState(() => _isLoadingGerber = true);
    }

    try {
      // Get current defect
      final defect = _defects[_currentDefectIndex];

      // Get model name from database hierarchy: Board -> Lot -> Model
      final boardId =
          int.tryParse(
            Provider.of<VRSProvider>(context, listen: false).currentBoard,
          ) ??
          0;

      final board = await _db.getBoardById(boardId);
      if (board == null) throw Exception('Board not found');

      final lotId = board['tbLotid_lot'];
      final lot = await _db.getLotById(lotId);
      if (lot == null) throw Exception('Lot not found');

      final modelId = lot['tbModelid_model'];
      final model = await _db.getModelById(modelId);
      if (model == null) throw Exception('Model not found');

      // Extract coordinates from defect
      Map<String, dynamic> coordinates = {};
      final coordinatesStr = defect['coordinates'] as String?;

      if (coordinatesStr != null && coordinatesStr.isNotEmpty) {
        try {
          coordinates =
              QCamberGerberService.parseCoordinatesString(coordinatesStr) ?? {};
        } catch (e) {
          debugPrint('Error parsing coordinates: $e');
        }
      }

      // Request Gerber image from QCamber (Port 8686)
      final success = await _gerberService.captureGerberImage(
        modelName: QCamberGerberService.resolveJobName(model),
        coordinates: coordinates,
        // Chỉ đi vào metadata hiển thị của QCamberGerberService (payload gửi
        // QCamber không có field này), nên dùng luôn tên để đọc log dễ hơn.
        defectType: defectTypeForDisplay(defect),
        layerName: board['layer_id']?.toString() ?? 'l8',
        zoom: 8192.0,
      );

      if (success) {
        debugPrint(
          '✅ Gerber image loaded for defect ${_currentDefectIndex + 1}',
        );
      } else {
        debugPrint('❌ Failed to load Gerber: ${_gerberService.lastError}');
        // QCamber đang mở nhầm file thiết kế mạch (job) so với mã hàng đang
        // chạy - cảnh báo rõ vì ảnh Gerber tham chiếu đang hiển thị là của
        // board KHÁC, operator có thể đối chiếu lỗi nhầm sang thiết kế đó.
        if (_gerberService.wrongJobOpen && mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              icon: const Icon(Icons.error, color: Colors.red, size: 48),
              title: const Text('Mở nhầm file thiết kế mạch'),
              content: Text(
                'QCamber đang mở file "${_gerberService.openJobName}" nhưng '
                'mã hàng đang chạy cần file '
                '"${_gerberService.requestedJobNameOnError}".\n\n'
                'Ảnh thiết kế đang hiển thị KHÔNG đáng tin. Vui lòng mở đúng '
                'file thiết kế mạch trong QCamber rồi tải lại.',
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Đã hiểu'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error loading Gerber: $e');
      if (mounted) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Loi tai anh Gerber: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingGerber = false);
      }
    }
  }

  void _previousDefect() {
    // !_isAnalyzing: chặn chuyển lỗi trong lúc đang chụp+phân tích AI - nếu
    // không, kết quả AI của lỗi VỪA RỜI ĐI có thể trả về sau khi đã sang lỗi
    // khác và bị áp nhầm vào đó (xem _captureAndAnalyze/_currentDefectToken).
    if (_defects.isNotEmpty &&
        _currentDefectIndex > 0 &&
        !_isSendingCoords &&
        !_isAnalyzing) {
      // Xoá phán định/kết quả AI còn treo của lỗi cũ TRƯỚC khi đổi lỗi - nếu
      // không, UI có thể thoáng hiện kết quả của lỗi cũ trong lúc ảnh/Gerber
      // của lỗi mới chưa tải xong.
      _resetJudgementState();
      setState(() {
        _currentDefectIndex--;
        _currentDefectToken++;
        // Reset trước khi gọi _moveCameraToDefect() bên dưới - nếu lệnh di
        // chuyển đó thất bại, cờ này phải phản ánh đúng "chưa tới nơi" cho
        // lỗi MỚI, không được giữ nguyên true từ lỗi cũ.
        _cameraPositionedForDefect = false;
      });
      _loadGerberForCurrentDefect();
      _loadAOIImageForCurrentDefect();
      // Di chuyển camera đến lỗi mới được chọn - trước đây chỉ đổi ảnh xem
      // trước mà không di chuyển PLC, khiến camera thực tế vẫn ở lỗi cũ.
      _moveCameraToDefect();
    }
  }

  void _nextDefect() {
    // !_isAnalyzing: xem giải thích ở _previousDefect.
    if (_defects.isNotEmpty &&
        _currentDefectIndex < _defects.length - 1 &&
        !_isSendingCoords &&
        !_isAnalyzing) {
      _resetJudgementState();
      setState(() {
        _currentDefectIndex++;
        _currentDefectToken++;
        _cameraPositionedForDefect = false;
      });
      _loadGerberForCurrentDefect();
      _loadAOIImageForCurrentDefect();
      // Di chuyển camera đến lỗi mới được chọn - trước đây chỉ đổi ảnh xem
      // trước mà không di chuyển PLC, khiến camera thực tế vẫn ở lỗi cũ.
      _moveCameraToDefect();
    }
  }

  /// Lớp lỗi AI đang dự đoán cho ảnh hiện tại, đã đưa về tên lớp chuẩn - dùng
  /// để chọn sẵn trong hộp thoại chọn loại lỗi: AI đoán đúng thì người vận
  /// hành chỉ cần Enter, không phải tìm trong danh sách.
  String? _aiDetectedClass() {
    final ngDetections = _analysisResult?.detections.where(
      (d) => d.verdict == 'NG',
    );
    if (ngDetections == null || ngDetections.isEmpty) {
      // Lỗi gây ra NG có thể không nằm trong TOP-N `detections[]` - vẫn chọn
      // sẵn được nhờ `statistics.primary_defect`.
      return canonicalDefectClass(_analysisResult?.primaryDefectClassName) ??
          canonicalDefectClass(_analysisResult?.primaryDefectName);
    }
    final first = ngDetections.first;
    return canonicalDefectClass(first.className) ??
        canonicalDefectClass(first.classNameVi);
  }

  /// Hỏi người vận hành lỗi này là loại gì (khi họ phán định NG).
  ///
  /// Trả về tên lớp chuẩn (key của [kDefectClassNames]), hoặc `null` nếu họ
  /// bấm Huỷ/Esc - khi đó KHÔNG lưu gì cả, lựa chọn NG vẫn còn để họ bấm lại.
  Future<String?> _askDefectType({String? initial}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DefectTypePickerDialog(initial: initial),
    );
  }

  Future<void> _makeJudgment(bool isOK) async {
    final result = isOK ? 'OK' : 'NG';

    // NG thì phải biết là lỗi GÌ: hỏi loại lỗi TRƯỚC khi lưu bất cứ thứ gì.
    // Nhãn này (human_type) là dữ liệu để huấn luyện/đánh giá lại mô hình sau
    // này - khi AI đoán sai loại, hoặc bảo OK mà người vận hành thấy NG, thì
    // đây là chỗ DUY NHẤT trong cả hệ thống có nhãn đúng cho ảnh đó.
    String? humanType;
    if (!isOK) {
      humanType = await _askDefectType(initial: _aiDetectedClass());
      if (!mounted) return;
      // Huỷ hộp thoại = huỷ luôn thao tác phán định (chưa ghi gì vào DB), để
      // không có lỗi NG nào lọt vào DB mà thiếu loại lỗi.
      if (humanType == null) return;
    }

    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          'Da phan dinh loi ${_defects.isNotEmpty ? _currentDefectIndex + 1 : 0}: $result',
        ),
        backgroundColor: isOK ? Colors.green : Colors.red,
        duration: const Duration(seconds: 2),
      ),
    );

    // Persist judgment to DB for the current defect
    if (_defects.isNotEmpty &&
        _currentDefectIndex >= 0 &&
        _currentDefectIndex < _defects.length) {
      final current = _defects[_currentDefectIndex];
      final dynamic rawId =
          current['id'] ?? current['id_defect'] ?? current['defect_id'];
      final int? id = rawId is int
          ? rawId
          : int.tryParse(rawId?.toString() ?? '');

      if (id != null) {
        // Determine detected type from latest analysis if available - CHỈ
        // lấy từ detection có verdict THẬT SỰ là NG (xem
        // AIDetectionResult.systemVerdict): 1 detection có thể được trả về
        // (vd nghi ngờ ban đầu) nhưng verdict riêng của nó vẫn là OK, không
        // nên gán tên loại lỗi cho trường hợp đó.
        String detectedType = '';
        final ngDetections = _analysisResult?.detections.where(
          (d) => d.verdict == 'NG',
        );
        if (ngDetections != null && ngDetections.isNotEmpty) {
          final first = ngDetections.first;
          detectedType = first.classNameVi.isNotEmpty
              ? first.classNameVi
              : (first.className.isNotEmpty ? first.className : '');
        } else {
          // AI kết luận NG nhưng lỗi gây ra NG không nằm trong TOP-N trả về ở
          // `detections[]` - lấy tên từ `statistics.primary_defect`, nếu
          // không `ai_type` sẽ bị ghi rỗng dù AI có nói rõ là lỗi gì (xem
          // AIDetectionResult.primaryDefectName).
          detectedType = _analysisResult?.primaryDefectName ?? '';
        }

        final webSocketService = Provider.of<AutoVRSWebSocketService>(
          context,
          listen: false,
        );
        final capturedFrame =
            _latestCapturedFrame ?? webSocketService.capturedImage;
        final savedAoiPath = capturedFrame == null
            ? null
            : await _saveCapturedAOIImage(
                imageBytes: capturedFrame,
                boardId: _currentBoardId,
                defectId: id,
              );
        // Ghi vào ai_type, KHÔNG ghi đè `type` (loại lỗi gốc AOI báo). Trước
        // đây ghi 'type': detectedType, mà detectedType rỗng khi AI không phát
        // hiện gì (_hasAnalysisResult vẫn true nếu detections rỗng) → xoá mất
        // loại lỗi AOI đúng ở trường hợp phổ biến nhất của soi thủ công.
        // ai_verdict: phán định OK/NG do AI tự đưa ra (xem _aiVerdict()) -
        // lưu ĐỘC LẬP với `judgement` (quyết định cuối cùng của người vận
        // hành ngay phía trên) để sau này so sánh/đánh giá AI, KHÔNG dùng để
        // thay thế judgement ở bất kỳ thống kê nào.
        // human_type: loại lỗi CHÍNH NGƯỜI VẬN HÀNH vừa xác nhận ở hộp thoại
        // trên (tên lớp chuẩn của mô hình). Phán định OK thì ghi null để xoá
        // nhãn cũ - lỗi từng bị chấm NG rồi soi lại thành OK không được giữ
        // lại loại lỗi cũ, nếu không dữ liệu huấn luyện sẽ có ảnh OK mang
        // nhãn lỗi.
        final updateFields = <String, dynamic>{
          'time': DateTime.now().toIso8601String(),
          'ai_type': detectedType,
          'judgement': result,
          'ai_verdict': _aiVerdict(),
          'human_type': isOK ? null : humanType,
        };
        if (savedAoiPath != null) {
          updateFields['url_image'] = savedAoiPath;
        }

        int rowsAffected;
        try {
          rowsAffected = await _db.updateDefect(id, updateFields);
        } catch (e) {
          debugPrint('Failed to persist judgment for defect $id: $e');
          if (!mounted) return;
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text('Loi luu phan dinh: $e'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
          return;
        }

        debugPrint(
          '✅ Judgment persisted: defect_id=$id, result=$result, rows=$rowsAffected',
        );

        // Reload list from DB to show updated data (this will update in-memory list)
        setState(() {
          _defectListReloadToken++;
        });

        try {
          await _loadDefectsForBoard(_currentBoardId, selectedDefectId: id);
          debugPrint('✅ Defect list reloaded from database');
        } catch (reloadError) {
          debugPrint('⚠️ Failed to reload defect list: $reloadError');
          // Don't show error to user - data is already saved
        }

        // Show success message
        if (mounted) {
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text('Da luu phan dinh: $result'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 1),
            ),
          );
        }

        // Reset local analysis/selection and return to live camera for next defect
        if (!mounted) return;
        setState(() {
          _pendingJudgement = null;
          _analysisResult = null;
          _hasAnalysisResult = false;
        });
        webSocketService.returnToLiveCamera();

        // Board đã phán định hết chưa? Dùng list VỪA reload từ DB (`_defects`
        // đã được _loadDefectsForBoard cập nhật ở trên), không dùng snapshot cũ.
        // Trước đây VRS thủ công không bao giờ đánh dấu board hoàn tất, nên
        // operator chỉ dùng chế độ thủ công sẽ không bao giờ sang được board kế.
        if (_defects.isNotEmpty && firstUnjudgedDefectIndex(_defects) == -1) {
          await _completeBoardFromManual();
          return;
        }

        if (_defects.isNotEmpty && _currentDefectIndex < _defects.length - 1) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) {
            _nextDefect();
          }
        }
      }
    }
  }

  /// Đã phán định hết lỗi của board hiện tại ở chế độ thủ công -> đánh dấu
  /// board hoàn tất + tìm board kế, rồi đưa camera về gốc.
  ///
  /// Không tự chuyển sang board kế: cần operator lật bo / đặt board mới lên bàn
  /// trước, nên chỉ nhắc họ bấm "Chuyển Bo".
  Future<void> _completeBoardFromManual() async {
    final vrs = Provider.of<VRSProvider>(context, listen: false);
    final boardId = int.tryParse(_currentBoardId ?? '');
    await vrs.completeCurrentBoardAndCheckNext();

    // Đưa camera về gốc để operator lật bo / đặt board mới an toàn - giống hệt
    // đuôi hoàn tất board ở chế độ Auto.
    try {
      final moveResult = await _plcGateway.movePlc(
        x: 0.0,
        y: 0.0,
        boardId: boardId,
      );
      if (!moveResult.success) {
        // Không throw khi PLC đang bận / gateway trả lỗi, chỉ báo trong log.
        debugPrint(
          'Dua camera ve goc sau khi xong board (thu cong) that bai: '
          '${moveResult.message}',
        );
      }
    } catch (e) {
      debugPrint('Loi dua camera ve goc sau khi xong board (thu cong): $e');
    }

    if (!mounted) return;
    final hasNext = vrs.nextBoardAvailable;
    if (!hasNext) {
      // Board CUỐI CÙNG: SnackBar tự tắt sau vài giây, người vận hành đang cúi
      // xuống bàn máy là bỏ lỡ hẳn. Popup chặn hẳn + kèm nút "Chọn đợt mới".
      await showLastBoardDialog(context);
      return;
    }
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          'Đã phán định hết lỗi của board này. Lật bo / đặt board mới lên '
          'bàn rồi bấm "Chuyển Bo" để sang board kế tiếp.',
        ),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// Bấm "Chuyển Bo" — chuyển sang board (hoặc mặt) kế tiếp ngay tại màn thủ
  /// công: hoàn tất board hiện tại nếu cần -> calib bù lệch cho board đích ->
  /// đổi `currentBoard` trên provider.
  ///
  /// Trước đây nút "Chuyển Bo" gọi `_nextDefect`, tức chỉ sang LỖI kế tiếp
  /// trong cùng board (dù comment ngay trên nó ghi "Navigation for next board").
  /// Màn thủ công do đó KHÔNG có đường nào gọi `advanceToNextBoard()`, nên
  /// operator buộc phải sang tab Auto VRS bấm "Board tiếp theo" mới đổi được
  /// board/mặt.
  Future<void> _advanceToNextBoardFromManual() async {
    // Guard đồng bộ trước mọi await: calib mất tới 90s, 2 lần bấm nhanh = 2
    // chuỗi calib song song ghi cùng thanh ghi PLC.
    if (_advancingBoard || _calibrating || _isSendingCoords) {
      debugPrint('ManualVRS: bo qua "Chuyen Bo" - dang co thao tac khac');
      return;
    }
    setState(() => _advancingBoard = true);
    try {
      final vrs = Provider.of<VRSProvider>(context, listen: false);

      // Chưa có board kế trong provider -> phải hoàn tất board hiện tại trước
      // (chính `completeCurrentBoardAndCheckNext` mới đi tìm board kế tiếp).
      if (!vrs.nextBoardAvailable) {
        final ready = await _finishCurrentBoardBeforeAdvance(vrs);
        if (!ready || !mounted) return;
      }

      // Vẫn chưa có -> hỏi lại DB, vì AOI_Ingest (tiến trình riêng) có thể vừa
      // ghi thêm board mới sau lần check trước.
      if (!vrs.nextBoardAvailable) {
        await vrs.checkForNewBoard();
        if (!mounted) return;
      }
      if (!vrs.nextBoardAvailable) {
        // Bấm "Chuyển Bo" mà hết board = đúng tình huống "board cuối cùng",
        // báo bằng CÙNG popup với lúc soi xong board cuối - cùng 1 trạng thái
        // mà báo 2 kiểu khác nhau thì người vận hành phải đoán.
        if (vrs.lotFinished || vrs.batchFinished) {
          await showLastBoardDialog(context);
          return;
        }
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: const Text('Chưa có board kế tiếp trong lô này.'),
            backgroundColor: Colors.grey.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      final targetBoardId = vrs.nextBoardId;
      final targetSide = vrs.nextBoardSide;
      final needCalib = vrs.calibrationNeeded;

      final confirmed = await _confirmAdvanceBoardDialog(
        boardId: targetBoardId,
        side: targetSide,
        isNewPhysicalBoard: vrs.nextBoardIsNewPhysical,
        willCalibrate: needCalib,
      );
      if (confirmed != true || !mounted) return;

      // Calib cho board ĐÍCH trước khi đổi (giống hệt `_runCalibrationIfNeeded`
      // của tab Auto). Calib xong mới `advanceToNextBoard` để lần ghi nhận
      // calib này không bị hàm đó xoá.
      if (needCalib) {
        final ok = await _runCalibration(
          boardId: targetBoardId,
          side: targetSide,
          boardCode: vrs.nextBoardCode,
        );
        if (!mounted) return;
        if (!ok) {
          // Không âm thầm chuyển board khi calib fail: gateway sẽ dùng toạ độ
          // chưa bù cho cả board mới.
          scaffoldMessengerKey.currentState?.showSnackBar(
            const SnackBar(
              content: Text(
                'Chưa chuyển bo vì calib bù lệch thất bại. Kiểm tra gá bo / '
                'ánh sáng rồi bấm "Chuyển Bo" lại.',
              ),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
          return;
        }
      }

      await vrs.advanceToNextBoard();
      if (!mounted) return;
      // Danh sách lỗi của board mới do listener `_syncBoardFromProvider` tải
      // (provider vừa notifyListeners) - không tự gọi ở đây để tránh load 2 lần.
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Đã chuyển sang board $targetBoardId - mặt $targetSide '
            '${targetSide == "B" ? "(Top)" : "(Bot)"}. '
            'Bấm "Di chuyển Camera" để tới lỗi đầu tiên.',
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _advancingBoard = false);
    }
  }

  /// Hoàn tất board hiện tại để `completeCurrentBoardAndCheckNext` đi tìm được
  /// board kế. Trả `false` nếu operator hủy.
  Future<bool> _finishCurrentBoardBeforeAdvance(VRSProvider vrs) async {
    if (vrs.currentBoard.isEmpty || vrs.currentBoard == 'Chưa có') {
      return true; // không có board nào đang mở -> để checkForNewBoard xử lý
    }

    // Đếm lỗi chưa phán định từ DB, không dùng `_defects` trong state: state có
    // thể cũ nếu board vừa được soi ở tab Auto.
    final boardId = int.tryParse(vrs.currentBoard);
    int unjudged = 0;
    if (boardId != null) {
      final rows = await _db.getDefectsByBoard(boardId);
      unjudged = rows.where((d) => !isDefectJudged(d)).length;
    }
    if (!mounted) return false;

    if (unjudged > 0) {
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Board hiện tại chưa kiểm tra hết'),
          content: Text(
            'Board ${vrs.currentBoard} còn $unjudged lỗi CHƯA phán định.\n\n'
            'Chọn "Vẫn chuyển bo" là board này bị đánh dấu ĐÃ XONG ngay (kể cả '
            'khi bạn hủy ở bước xác nhận sau): nó không còn xuất hiện trong '
            'danh sách board chờ, $unjudged lỗi trên sẽ vĩnh viễn không có '
            'phán định.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'stay'),
              child: const Text('Ở lại kiểm tra tiếp'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'force'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Vẫn chuyển bo'),
            ),
          ],
        ),
      );
      if (choice != 'force' || !mounted) return false;
      debugPrint(
        'ManualVRS: operator chuyen bo khi board ${vrs.currentBoard} '
        'con $unjudged loi chua phan dinh',
      );
    }

    await vrs.completeCurrentBoardAndCheckNext();
    return mounted;
  }

  /// Xác nhận trước khi đổi board: operator cần lật bo / đặt board mới lên bàn
  /// trước, và cần biết sắp mất ~90 giây cho calib.
  Future<bool?> _confirmAdvanceBoardDialog({
    required String boardId,
    required String side,
    required bool isNewPhysicalBoard,
    required bool willCalibrate,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            Navigator.pop(ctx, true);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.pop(ctx, false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: AlertDialog(
          title: const Text('Chuyển sang board kế tiếp'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isNewPhysicalBoard
                    ? 'Board vật lý MỚI - hãy lấy bo cũ ra và đặt bo mới lên bàn.'
                    : 'Cùng bo, đổi mặt - hãy LẬT bo lại.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text('Board đích: $boardId'),
              Text('Mặt: $side ${side == "B" ? "(Top)" : "(Bot)"}'),
              const SizedBox(height: 12),
              Text(
                willCalibrate
                    ? '⚙️ Sẽ tự động calib bù lệch cho board này (khoảng 90 giây).'
                    : 'Không cần calib lại cho lần chuyển này.',
                style: const TextStyle(fontSize: 13, color: Colors.orange),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Đã đặt bo - Chuyển'),
            ),
          ],
        ),
      ),
    );
  }

  /// Build widget hiển thị kết quả defect detection
  // ignore: unused_element
  Widget _buildDefectDetectionResults(
    AutoVRSWebSocketService webSocketService,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    // Prefer local analysis result (from immediate AI detection). If absent,
    // fall back to websocket-provided analysis/detectionResults.
    final local = _analysisResult;
    final detectionResults = webSocketService.lastDetectionResults;
    final analysis = webSocketService.lastAnalysis;

    if (local == null && detectionResults == null && analysis == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FeatherIcons.search, size: 16, color: Colors.blue[600]),
              const SizedBox(width: 8),
              Text(
                'Ket qua phat hien loi',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blue[600],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Hiển thị số lượng lỗi tổng -- prefer local result
          if (local != null) ...[
            Row(
              children: [
                const Text('Tong so loi: '),
                Text(
                  '${local.detections.length}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: local.detections.isNotEmpty
                        ? Colors.red
                        : Colors.green,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 4),
            ..._buildLocalDefectTypeRows(local),
          ] else if (analysis != null) ...[
            Row(
              children: [
                const Text('Tong so loi: '),
                Text(
                  '${analysis['total_defects'] ?? 0}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: (analysis['total_defects'] ?? 0) > 0
                        ? Colors.red
                        : Colors.green,
                  ),
                ),
              ],
            ),

            if (analysis['defects_by_type'] != null) ...[
              const SizedBox(height: 4),
              ...((analysis['defects_by_type'] as Map<String, dynamic>).entries
                  .map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(left: 16, top: 2),
                      child: Row(
                        children: [
                          Text('- ${_getDefectDisplayName(entry.key)}: '),
                          Text(
                            '${entry.value}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    );
                  })
                  .toList()),
            ],

            if (analysis['has_critical_defects'] == true) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  border: Border.all(color: Colors.red[300]!),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(
                      FeatherIcons.alertTriangle,
                      size: 14,
                      color: Colors.red[600],
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Phat hien loi nghiem trong!',
                      style: TextStyle(
                        color: Colors.red[600],
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ] else if (detectionResults != null) ...[
            // Fallback hiển thị cơ bản nếu không có analysis
            Text('So loi phat hien: ${detectionResults['num_defects'] ?? 0}'),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildLocalDefectTypeRows(AIDetectionResult local) {
    final Map<String, int> counts = {};
    for (final d in local.detections) {
      final key = (d.classNameVi.isNotEmpty)
          ? d.classNameVi
          : (d.className.isNotEmpty ? d.className : 'Unknown');
      counts[key] = (counts[key] ?? 0) + 1;
    }

    if (counts.isEmpty) return [const Text('Không phát hiện lỗi')];

    final rows = <Widget>[];
    counts.forEach((k, v) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 2),
          child: Row(
            children: [
              Text('- ${_getDefectDisplayName(k)}: '),
              Text('$v', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );
    });
    return rows;
  }

  /// Chuyển đổi tên lỗi kỹ thuật sang tên hiển thị
  String _getDefectDisplayName(String technicalName) {
    switch (technicalName.toLowerCase()) {
      case 'bamdinhkhongtot':
        return 'Bam Dinh Khong Tot';
      case 'chamkim':
        return 'Cham Kim';
      case 'divat':
        return 'Di Vat';
      case 'divatduongmach':
        return 'Di Vat duong mach';
      case 'khuyetmach':
        return 'Khuyet mach';
      case 'nganmach':
        return 'Ngan Mach';
      case 'thieudong':
        return 'Thieu Dong';
      case 'thieudongduongmach':
        return 'Thieu Dong Duong Mach';
      case 'thuadong':
        return 'Thua Dong';
      case 'thuadongduongmach':
        return 'Thua Dong Duong Mach';
      case 'vetlom':
        return 'Vet Lom';
      case 'xuoc':
        return 'Xuoc';
      case 'other':
        return 'Khac';
      // Legacy names for backward compatibility
      case 'short_circuit':
        return 'Chap mach';
      case 'missing_component':
        return 'Thieu linh kien';
      case 'damaged_track':
        return 'Duong mach hong';
      case 'solder_bridge':
        return 'Cau han';
      case 'crack':
        return 'Vet nut';
      case 'person':
        return 'Nguoi'; // Neu van detect nguoi
      default:
        return technicalName;
    }
  }

  /// Phán định OK/NG do AI tự đưa ra (KHÁC với `_pendingJudgement`/judgement
  /// cuối cùng - đó là lựa chọn của NGƯỜI vận hành, có thể trùng hoặc lệch
  /// với AI). null = chưa chụp+phân tích lần nào cho lỗi đang xem.
  ///
  /// Dùng `AIDetectionResult.systemVerdict` (verdict THẬT của backend) -
  /// KHÔNG tự suy từ `detections.isEmpty`: 1 detection có thể được trả về
  /// (vẽ lên ảnh) nhưng verdict riêng của nó vẫn là 'OK' - bug thật đã gặp
  /// 2026-09-25 (ảnh có detection "ThieuDong" nhưng backend log "Overall
  /// verdict: OK", app cũ lại báo NG vì chỉ nhìn detections có rỗng không).
  String? _aiVerdict() {
    final result = _analysisResult;
    if (result == null) return null;
    return result.systemVerdict;
  }

  /// Panel "Kết quả phán định AI" - cùng kiểu hiển thị (khung màu + chữ lớn
  /// OK/NG) với vrs_main_screen.dart để nhất quán giữa 2 màn, nhưng nguồn dữ
  /// liệu là `_analysisResult` CỤC BỘ của lần chụp vừa rồi (chưa lưu DB) -
  /// chỉ để tham khảo trước khi người vận hành tự bấm OK/NG xác nhận, KHÔNG
  /// tự động điền vào lựa chọn `_pendingJudgement`.
  Widget _buildAiVerdictPanel() {
    final verdict = _aiVerdict();
    final String verdictShort;
    final Color bgColor;
    final Color txtColor;
    final String detailText;

    if (verdict == null) {
      verdictShort = '—';
      bgColor = Colors.grey.shade200;
      txtColor = Colors.grey.shade700;
      detailText = 'Chưa có kết quả phán định';
    } else if (verdict == 'OK') {
      verdictShort = 'OK';
      bgColor = Colors.green.shade50;
      txtColor = Colors.green.shade600;
      detailText = 'Không phát hiện lỗi';
    } else {
      verdictShort = 'NG';
      bgColor = Colors.red.shade50;
      txtColor = Colors.red.shade600;
      detailText = _getAIPredictionText();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Kết quả phán định AI',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Text(
                verdictShort,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: txtColor,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                detailText,
                style: TextStyle(
                  fontSize: 12,
                  color: txtColor.withValues(alpha: 0.9),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Get AI prediction text for display - CHỈ liệt kê detection có verdict
  // THẬT là NG (xem AIDetectionResult.systemVerdict/_aiVerdict) - 1
  // detection được trả về không có nghĩa verdict riêng của nó là NG.
  String _getAIPredictionText() {
    final ngDetections =
        _analysisResult?.detections.where((d) => d.verdict == 'NG') ?? const [];
    if (ngDetections.isEmpty) {
      // `detections[]` chỉ có TOP-N lỗi theo confidence, lỗi gây ra NG có thể
      // không nằm trong đó - lấy tên từ `statistics.primary_defect` (xem
      // AIDetectionResult.primaryDefectName). Không có nhánh này thì panel
      // báo "NG" kèm "Không phát hiện lỗi", vô nghĩa với người vận hành.
      final primary = _analysisResult?.primaryDefectName;
      if (primary != null) return primary;
      return 'Khong phat hien loi';
    }

    // Get unique defect types (prefer Vietnamese name, fallback to className)
    final defectTypes = <String>{};
    for (final detection in ngDetections) {
      final t = detection.classNameVi.isNotEmpty
          ? detection.classNameVi
          : (detection.className.isNotEmpty
                ? detection.className
                : 'Khong xac dinh');
      defectTypes.add(t);
    }

    return defectTypes.join(', ');
  }

  /// Load AOI image for current defect from database url_image field
  Future<void> _loadAOIImageForCurrentDefect() async {
    if (_defects.isEmpty || _currentDefectIndex >= _defects.length) {
      setState(() {
        _aoiImageFile = null;
        _aoiImageSource = null;
        _aoiImageError = null;
        _aoiImageIsNetwork = false;
        _isLoadingAoiImage = false;
      });
      return;
    }

    // Chốt lỗi đang tải NGAY LÚC NÀY - đây là hàm bất đồng bộ duy nhất (qua
    // _db.getDefectById bên dưới) từng có bug thật: operator chuyển lỗi
    // (hoặc board mới tới) trong lúc đang chờ CSDL trả về, hàm chỉ kiểm tra
    // index còn hợp lệ (không kiểm tra có còn ĐÚNG lỗi lúc bắt đầu hay không)
    // rồi ghi dữ liệu/ảnh của lỗi CŨ vào đúng vị trí lỗi MỚI trong `_defects`.
    final myDefectToken = _currentDefectToken;
    var defect = _defects[_currentDefectIndex];
    final rawDefectId =
        defect['id'] ?? defect['id_defect'] ?? defect['defect_id'];
    final defectId = rawDefectId is int
        ? rawDefectId
        : int.tryParse(rawDefectId?.toString() ?? '');
    if (defectId != null) {
      final freshDefect = await _db.getDefectById(defectId);
      if (!mounted || myDefectToken != _currentDefectToken) {
        // Lỗi đã đổi trong lúc chờ CSDL - bỏ kết quả, KHÔNG ghi gì vào
        // `_defects` và KHÔNG tải ảnh AOI của lỗi cũ này nữa. Lần gọi hàm này
        // cho lỗi MỚI (do _previousDefect/_nextDefect/_loadDefectsForBoard tự
        // gọi lại) sẽ tự lo phần của nó.
        return;
      }
      if (freshDefect != null) {
        final mutableFreshDefect = Map<String, dynamic>.from(freshDefect);
        defect = mutableFreshDefect;
        setState(() {
          final updatedDefects = List<Map<String, dynamic>>.from(_defects);
          updatedDefects[_currentDefectIndex] = mutableFreshDefect;
          _defects = updatedDefects;
        });
      }
    }

    final urlImage = (defect['url_image'] ?? '').toString().trim();
    if (urlImage.isEmpty) {
      if (!mounted) return;
      setState(() {
        _aoiImageFile = null;
        _aoiImageSource = null;
        _aoiImageError = null;
        _aoiImageIsNetwork = false;
        _isLoadingAoiImage = false;
      });
      debugPrint('No url_image for defect ${_currentDefectIndex + 1}');
      return;
    }

    debugPrint('Loading AOI image from latest defect data: $urlImage');
    await _loadAOIImage(urlImage);
  }

  /// Load AOI image from local path or network URL.
  Future<void> _loadAOIImage(String source) async {
    final trimmed = source.trim();
    final unquoted =
        (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
            (trimmed.startsWith("'") && trimmed.endsWith("'"))
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;

    if (!mounted) return;
    setState(() {
      _isLoadingAoiImage = true;
      _aoiImageFile = null;
      _aoiImageSource = unquoted;
      _aoiImageError = null;
      _aoiImageIsNetwork = false;
    });

    try {
      final uri = Uri.tryParse(unquoted);
      final scheme = uri?.scheme.toLowerCase();
      final isNetwork = scheme == 'http' || scheme == 'https';

      if (isNetwork) {
        if (!mounted) return;
        setState(() {
          _aoiImageFile = null;
          _aoiImageSource = unquoted;
          _aoiImageError = null;
          _aoiImageIsNetwork = true;
          _isLoadingAoiImage = false;
        });
        return;
      }

      var localPath = unquoted;
      if (scheme == 'file') {
        localPath = uri!.toFilePath(windows: Platform.isWindows);
      } else if (Platform.isWindows &&
          RegExp(r'^[A-Za-z]:/').hasMatch(localPath)) {
        localPath = localPath.replaceAll('/', '\\');
      }

      final normalizedPath = p.normalize(localPath);
      final file = File(normalizedPath);
      final exists = await file.exists();

      if (!mounted) return;
      if (exists) {
        setState(() {
          _aoiImageFile = file;
          _aoiImageSource = normalizedPath;
          _aoiImageError = null;
          _aoiImageIsNetwork = false;
          _isLoadingAoiImage = false;
        });
      } else {
        setState(() {
          _aoiImageFile = null;
          _aoiImageSource = normalizedPath;
          _aoiImageError = 'Khong tim thay anh AOI';
          _aoiImageIsNetwork = false;
          _isLoadingAoiImage = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aoiImageFile = null;
        _aoiImageSource = unquoted;
        _aoiImageError = 'Khong the load anh AOI';
        _aoiImageIsNetwork = false;
        _isLoadingAoiImage = false;
      });
      debugPrint('Error loading AOI image: $e');
    }
  }

  Widget _buildAOIImageWidget() {
    if (_isLoadingAoiImage) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 8),
            Text(
              'Dang tai anh AOI...',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    if (_aoiImageIsNetwork && _aoiImageSource != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Column(
          children: [
            Expanded(
              child: Image.network(
                _aoiImageSource!,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return const Center(child: CircularProgressIndicator());
                },
                errorBuilder: (context, error, stackTrace) {
                  return _buildAOIError(
                    _aoiImageError ?? 'Khong the load anh tu network',
                    details: _aoiImageSource,
                  );
                },
              ),
            ),
            if (_aoiImageSource != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _aoiImageSource!,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      );
    }

    if (_aoiImageFile != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Column(
          children: [
            Expanded(
              child: Image.file(
                _aoiImageFile!,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return _buildAOIError(
                    _aoiImageError ?? 'Khong the load anh',
                    details: _aoiImageFile?.path,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _aoiImageFile!.path,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    if (_latestCapturedFrame != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Column(
          children: [
            Expanded(
              child: Image.memory(
                _latestCapturedFrame!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) {
                  return _buildAOIError('Khong the hien thi frame vua chup');
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Anh tam tu frame vua chup',
                style: TextStyle(fontSize: 10, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    // Mặt sạch (board đang mở nhưng 0 lỗi) là trường hợp RẤT hay gặp - nói
    // thẳng ra và chỉ luôn việc cần làm, thay vì để operator nhìn "chưa có dữ
    // liệu lỗi" rồi tưởng máy chưa tải xong.
    final placeholderText = _defects.isEmpty
        ? (_boardFullyJudged
              ? 'Mặt này không có lỗi nào.\n'
                    'Bấm Enter để chuyển sang mặt / bo kế tiếp.'
              : 'Chua co du lieu loi')
        : (_aoiImageError ?? 'Khong co anh AOI');

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_not_supported, size: 48, color: Colors.grey[400]),
          const SizedBox(height: 8),
          Text(
            placeholderText,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          if (_aoiImageSource != null && _aoiImageSource!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                _aoiImageSource!,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAOIError(String message, {String? details}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.broken_image, size: 48, color: Colors.red),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(fontSize: 12, color: Colors.red),
            textAlign: TextAlign.center,
          ),
          if (details != null && details.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                details,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Hộp thoại chọn loại lỗi khi người vận hành phán định NG (xem
/// `_ManualVRSScreenState._askDefectType`). Trả về tên lớp chuẩn qua
/// `Navigator.pop`, hoặc `null` nếu huỷ.
///
/// Điều khiển được HOÀN TOÀN bằng bàn phím (↑/↓ chọn, Enter xác nhận, Esc
/// huỷ): cả quy trình soi thủ công đều làm bằng bàn phím, bắt người vận hành
/// rời tay ra chuột chỉ để chọn loại lỗi sẽ làm chậm hẳn nhịp soi.
class _DefectTypePickerDialog extends StatefulWidget {
  /// Lớp AI đang đoán - chọn sẵn để AI đúng thì chỉ cần Enter.
  final String? initial;

  const _DefectTypePickerDialog({this.initial});

  @override
  State<_DefectTypePickerDialog> createState() =>
      _DefectTypePickerDialogState();
}

class _DefectTypePickerDialogState extends State<_DefectTypePickerDialog> {
  static const double _itemHeight = 44;
  static const double _listHeight = 320;

  final List<String> _keys = kDefectClassNames.keys.toList();
  final ScrollController _scrollController = ScrollController();
  late int _index;

  @override
  void initState() {
    super.initState();
    final found = widget.initial == null ? -1 : _keys.indexOf(widget.initial!);
    _index = found >= 0 ? found : 0;
    // Lớp AI đoán có thể nằm dưới đáy danh sách - cuộn tới ngay khi mở, nếu
    // không người vận hành tưởng chưa chọn gì.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!_scrollController.hasClients) return;
    final target = (_index * _itemHeight) - (_listHeight / 2) + _itemHeight / 2;
    _scrollController.jumpTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
    );
  }

  void _move(int delta) {
    setState(() {
      _index = (_index + delta).clamp(0, _keys.length - 1);
    });
    _scrollToSelected();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        Navigator.of(context).pop(_keys[_index]);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        Navigator.of(context).pop();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        title: const Text('Lỗi này là loại gì?'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Chọn đúng loại lỗi bạn nhìn thấy. Nhãn này được lưu lại để '
                'huấn luyện AI chính xác hơn về sau.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: _listHeight,
                child: ListView.builder(
                  controller: _scrollController,
                  itemExtent: _itemHeight,
                  itemCount: _keys.length,
                  itemBuilder: (context, i) {
                    final key = _keys[i];
                    final selected = i == _index;
                    final isAiGuess = key == widget.initial;
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(key),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: selected ? Colors.blue.shade50 : null,
                          border: Border(
                            left: BorderSide(
                              width: 4,
                              color: selected
                                  ? Colors.blue.shade600
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                kDefectClassNames[key]!,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: selected
                                      ? Colors.blue.shade900
                                      : Colors.black87,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isAiGuess)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade100,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  'AI đoán',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.orange.shade900,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '↑ ↓ chọn · Enter xác nhận · Esc huỷ',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Huỷ'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(_keys[_index]),
            child: const Text('Xác nhận'),
          ),
        ],
      ),
    );
  }
}
