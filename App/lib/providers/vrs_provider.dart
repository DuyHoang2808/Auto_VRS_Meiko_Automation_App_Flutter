import 'package:flutter/foundation.dart';
import '../services/local_database_service.dart';

class VRSProvider extends ChangeNotifier {
  final LocalDatabaseService _db = LocalDatabaseService();

  // Current system status
  String _systemStatus = 'Loading...';
  bool _isAutoMode = true;
  String _currentModel = '';
  String _currentModelName = '';
  String _currentLot = '';
  String _currentBoard = '';
  // Mã board (board_code từ AOI_Ingest) - tên hiển thị cho vận hành viên,
  // khác với id_board (khóa DB nội bộ, không có ý nghĩa với người dùng).
  String _currentBoardCode = '';
  int _totalCount = 0;
  int _okCount = 0;
  int _ngCount = 0;

  // "Board tiếp theo" - xem completeCurrentBoardAndCheckNext()/advanceToNextBoard()
  bool _nextBoardAvailable = false;
  bool _nextBoardIsNewPhysical = false;
  String _nextBoardId = '';
  String _nextBoardCode = '';
  bool _lotFinished = false;

  // Board side tracking + calibration flag
  // "A" = mặt top (l1-l4), "B" = mặt bottom (l5-l8)
  String _currentBoardSide = 'A';
  String _nextBoardSide = 'A';
  bool _calibrationNeeded = false;

  // Lần calib bù lệch thành công gần nhất trong phiên này: id_board + mặt.
  // Provider sống suốt phiên (được tạo TRÊN router trong main.dart) nên state
  // này không mất khi chuyển tab Auto VRS <-> VRS thủ công - khác với state của
  // widget, vốn bị xoá sạch vì màn hình bị dispose khi điều hướng.
  //
  // Dùng id_board chứ KHÔNG dùng board_code: board_code không unique trong lot
  // và hợp lệ khi rỗng (xem các chỗ gán ''), nên key rỗng sẽ trùng giữa các
  // board khác nhau -> bỏ qua calib cho board thực sự mới.
  //
  // Đây chỉ là "gợi ý" - trước khi bỏ qua calib vẫn phải xác minh với gateway
  // (PlcGatewayService.hasValidOffsetFor), vì file offset có thể đã mất.
  String _calibratedBoardId = '';
  String _calibratedSide = '';
  // Board cuối cùng vừa hoàn tất khi không còn board nào khác trong lot -
  // giữ lại chỉ để hiển thị thông báo rõ ràng, KHÔNG dùng làm currentBoard
  // nữa (currentBoard phải reset về 'Chưa có', xem completeCurrentBoardAndCheckNext).
  String _lastCompletedBoardId = '';

  // Camera and alignment settings
  double _magnification = 140.0;
  double _lightLevel = 50.0;
  final List<Map<String, dynamic>> _alignmentPoints = [];
  int _currentAlignmentStep = 1;

  // Initialize data from database
  bool _isInitialized = false;

  // Getters
  String get currentLot => _currentLot;
  String get currentBoard => _currentBoard;
  String get currentBoardCode => _currentBoardCode;
  String get systemStatus => _systemStatus;
  bool get isAutoMode => _isAutoMode;
  String get currentModel => _currentModel;
  String get currentModelName => _currentModelName;
  int get totalCount => _totalCount;
  int get okCount => _okCount;
  int get ngCount => _ngCount;
  double get ngRate => _totalCount > 0 ? (_ngCount / _totalCount) * 100 : 0.0;
  double get magnification => _magnification;
  double get lightLevel => _lightLevel;
  List<Map<String, dynamic>> get alignmentPoints =>
      List.unmodifiable(_alignmentPoints);
  int get currentAlignmentStep => _currentAlignmentStep;
  bool get isInitialized => _isInitialized;
  bool get nextBoardAvailable => _nextBoardAvailable;
  bool get nextBoardIsNewPhysical => _nextBoardIsNewPhysical;
  String get nextBoardId => _nextBoardId;
  bool get lotFinished => _lotFinished;
  String get lastCompletedBoardId => _lastCompletedBoardId;
  String get currentBoardSide => _currentBoardSide;
  String get nextBoardSide => _nextBoardSide;
  bool get calibrationNeeded => _calibrationNeeded;

  /// Xác định mặt board từ layer_id: l1-l4 → "A" (top), l5-l8 → "B" (bottom).
  /// Format layer_id từ AOI_Ingest: lowercase "l1", "l2", ..., "l8".
  /// Trả "A" nếu không parse được (an toàn hơn).
  static String boardSideFromLayerId(String? layerId) {
    if (layerId == null || layerId.isEmpty) return 'A';
    // Bỏ prefix "l"/"L", parse số
    final numeric = int.tryParse(layerId.replaceFirst(RegExp(r'^[lL]'), ''));
    if (numeric == null) return 'A';
    return numeric >= 5 ? 'B' : 'A';
  }

  // Initialize provider with database data
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await _loadSystemConfig();
      await _loadCurrentModel();
      await _loadStatistics();
      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Error initializing VRSProvider: $e');
    }
  }

  Future<void> _loadSystemConfig() async {
    try {
      final systemStatus = await _db.getConfigValue('system_status');
      final systemMode = await _db.getConfigValue('system_mode');
      final magnification = await _db.getConfigValue('magnification');
      final lightLevel = await _db.getConfigValue('light_level');

      _systemStatus = systemStatus ?? 'OK';
      _isAutoMode = (systemMode ?? 'auto') == 'auto';
      _magnification = double.tryParse(magnification ?? '140') ?? 140.0;
      _lightLevel = double.tryParse(lightLevel ?? '50') ?? 50.0;
    } catch (e) {
      debugPrint('Error loading system config: $e');
    }
  }

  Future<void> _loadCurrentModel() async {
    try {
      final currentModelId = await _db.getConfigValue('current_model');
      if (currentModelId != null) {
        final modelId = int.tryParse(currentModelId);
        if (modelId != null) {
          final model = await _db.getModelById(modelId);
          if (model != null) {
            _currentModel = model['id_model'].toString();
            _currentModelName = 'Model ${model['id_model']}';
            await _resolveFirstLotAndBoardForModel(_currentModel);
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading current model: $e');
    }
  }

  Future<void> _loadStatistics() async {
    try {
      // Calculate total statistics from all boards
      final allBoards = await _db.getAllBoards();
      _totalCount = allBoards.length;
      _okCount = allBoards
          .where((board) => (board['defect_quantity'] as int) == 0)
          .length;
      _ngCount = allBoards
          .where((board) => (board['defect_quantity'] as int) > 0)
          .length;
    } catch (e) {
      debugPrint('Error loading statistics: $e');
    }
  }

  Future<void> setSystemStatus(String status) async {
    _systemStatus = status;
    await _db.updateConfig('system_status', status);
    notifyListeners();
  }

  Future<void> toggleMode() async {
    _isAutoMode = !_isAutoMode;
    await _db.updateConfig('system_mode', _isAutoMode ? 'auto' : 'manual');
    notifyListeners();
  }

  Future<void> setCurrentModel(String modelId) async {
    try {
      final model = await _db.getModelById(int.parse(modelId));

      if (model != null) {
        // Đổi model -> đổi board, offset đã calib không còn đúng.
        invalidateCalibration();
        _currentModel = model['id_model'].toString();
        _currentModelName = 'Model ${model['id_model']}';

        // Lấy lô đầu tiên liên kết với model
        final lot = await _db.getFirstLotByModelId(modelId);
        if (lot != null) {
          _currentLot = lot['id_lot'].toString();

          // Lấy bo đầu tiên liên kết với lô
          final board = await _db.getFirstBoardByLotId(_currentLot);
          _currentBoard = board != null
              ? board['id_board'].toString()
              : 'Chưa có';
          _currentBoardCode = board?['board_code']?.toString() ?? '';
          _currentBoardSide = boardSideFromLayerId(
            board?['layer_id']?.toString(),
          );
        } else {
          _currentLot = 'Chưa có';
          _currentBoard = 'Chưa có';
          _currentBoardCode = '';
          _currentBoardSide = 'A';
        }

        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error setting current model: $e');
    }
  }

  Future<void> _resolveFirstLotAndBoardForModel(String modelId) async {
    // Chuyển sang board đầu tiên của model -> offset calib cũ không còn đúng.
    invalidateCalibration();
    final lot = await _db.getFirstLotByModelId(modelId);
    if (lot == null) {
      _currentLot = 'Chưa có';
      _currentBoard = 'Chưa có';
      _currentBoardCode = '';
      _currentBoardSide = 'A';
      return;
    }

    _currentLot = lot['id_lot'].toString();

    final board = await _db.getFirstBoardByLotId(_currentLot);
    _currentBoard = board != null ? board['id_board'].toString() : 'Chưa có';
    _currentBoardCode = board?['board_code']?.toString() ?? '';
    _currentBoardSide = boardSideFromLayerId(board?['layer_id']?.toString());
  }

  /// Gọi khi workflow tự động đã chạy hết toàn bộ lỗi của board hiện tại.
  /// Đánh dấu board đó `completed`, rồi tìm board tiếp theo (id_board nhỏ
  /// nhất, lớn hơn board hiện tại) còn `pending` trong cùng lot.
  ///
  /// Không tự chuyển sang board mới ở đây - chỉ cập nhật state để UI hiện
  /// dialog/nút "Board tiếp theo" cho vận hành viên xác nhận trước (khớp
  /// quy trình thật: cần lật bo hoặc đặt board mới lên bàn, là thao tác tay).
  /// Gọi [advanceToNextBoard] sau khi vận hành viên xác nhận.
  Future<void> completeCurrentBoardAndCheckNext() async {
    final boardId = int.tryParse(_currentBoard);
    final lotId = int.tryParse(_currentLot);
    if (boardId == null || lotId == null) return;

    try {
      final currentBoardRow = await _db.getBoardById(boardId);
      await _db.markBoardCompleted(boardId);

      final nextBoardRow = await _db.getNextPendingBoard(lotId, boardId);

      if (nextBoardRow != null) {
        final currentCode = currentBoardRow?['board_code']?.toString();
        final nextCode = nextBoardRow['board_code']?.toString();
        // Không xác định được board_code (dữ liệu cũ trước AOI_Ingest) ->
        // mặc định coi là board vật lý mới để an toàn hơn (nhắc đặt board
        // mới thay vì chỉ lật bo).
        _nextBoardIsNewPhysical =
            currentCode == null || nextCode == null || currentCode != nextCode;
        _nextBoardId = nextBoardRow['id_board'].toString();
        _nextBoardCode = nextCode ?? '';
        _nextBoardAvailable = true;
        _lotFinished = false;
        _lastCompletedBoardId = '';

        // Xác định mặt board tiếp theo + cần calib hay không
        final currentLayerId = currentBoardRow?['layer_id']?.toString();
        final nextLayerId = nextBoardRow['layer_id']?.toString();
        _nextBoardSide = boardSideFromLayerId(nextLayerId);
        // Cần calib nếu: board vật lý mới HOẶC đổi mặt (A↔B)
        _calibrationNeeded = _nextBoardIsNewPhysical ||
            boardSideFromLayerId(currentLayerId) != _nextBoardSide;
      } else {
        // Không còn board nào khác trong lot - đây là board cuối cùng.
        // Reset currentBoard về 'Chưa có' để UI không tiếp tục hiển thị board
        // đã xong như thể vẫn đang là board hiện tại (bug đã gặp: boardText
        // vẫn giữ nguyên id board cũ, nút "Bắt đầu" vẫn bật lại được và chạy
        // lại đúng board vừa xong nếu bấm nhầm).
        _lastCompletedBoardId = _currentBoard;
        _currentBoard = 'Chưa có';
        _currentBoardCode = '';
        _nextBoardAvailable = false;
        _nextBoardId = '';
        _nextBoardCode = '';
        _lotFinished = true;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Error completing board / checking next board: $e');
    }
  }

  /// Gọi định kỳ (polling) từ màn hình VRS trong lúc KHÔNG có board đang xử
  /// lý (`currentBoard == 'Chưa có'` - do lot vừa hoàn tất hoặc do chưa có
  /// board nào tới). DB `autovrs.db` có thể được `AOI_Ingest` (tiến trình
  /// Python độc lập, chạy song song, không qua app) ghi thêm board mới vào
  /// bất kỳ lúc nào - trước đây app không có cơ chế nào tự phát hiện việc
  /// này, vận hành viên phải tự thoát ra chọn lại model mới thấy board mới.
  ///
  /// Không tự động chạy ngay khi tìm thấy board mới - chỉ chuyển sang trạng
  /// thái "board tiếp theo" (giống hệt [completeCurrentBoardAndCheckNext])
  /// để vận hành viên xác nhận trước (đặt board mới lên bàn / lật bo).
  ///
  /// Trả `true` nếu vừa tìm thấy 1 board mới (mới set `nextBoardAvailable`),
  /// `false` nếu không có gì mới - dùng để hiện phản hồi khi vận hành viên
  /// bấm nút "Tải lại dữ liệu" thủ công (xem VRSMainScreen), thay vì chỉ
  /// gọi ngầm từ timer polling.
  Future<bool> checkForNewBoard() async {
    // Đã có board đang xử lý hoặc đã tìm thấy board chờ xác nhận - không cần
    // check lại, tránh query DB thừa mỗi lần timer chạy.
    if (_currentBoard.isNotEmpty && _currentBoard != 'Chưa có') return false;
    if (_nextBoardAvailable) return true;
    if (_currentLot.isEmpty || _currentLot == 'Chưa có') return false;

    try {
      final nextBoardRow = await _db.getFirstBoardByLotId(_currentLot);
      if (nextBoardRow == null) return false; // vẫn chưa có board mới nào

      Map<String, dynamic>? lastCompletedBoardRow;
      final lastId = int.tryParse(_lastCompletedBoardId);
      if (lastId != null) {
        lastCompletedBoardRow = await _db.getBoardById(lastId);
      }

      final currentCode = lastCompletedBoardRow?['board_code']?.toString();
      final nextCode = nextBoardRow['board_code']?.toString();
      _nextBoardIsNewPhysical =
          currentCode == null || nextCode == null || currentCode != nextCode;
      _nextBoardId = nextBoardRow['id_board'].toString();
      _nextBoardCode = nextCode ?? '';
      _nextBoardAvailable = true;
      _lotFinished = false;

      // Xác định mặt board + cần calib
      final lastLayerId = lastCompletedBoardRow?['layer_id']?.toString();
      final nextLayerId = nextBoardRow['layer_id']?.toString();
      _nextBoardSide = boardSideFromLayerId(nextLayerId);
      _calibrationNeeded = _nextBoardIsNewPhysical ||
          boardSideFromLayerId(lastLayerId) != _nextBoardSide;

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error checking for newly ingested board: $e');
      return false;
    }
  }

  /// Vận hành viên đã xác nhận (lật bo / đặt board mới lên bàn) - chuyển
  /// `currentBoard` sang board tiếp theo đã tìm thấy ở
  /// [completeCurrentBoardAndCheckNext]. Không tự bắt đầu workflow - màn
  /// hình gọi hàm này rồi tự gọi `_startWorkflow` với board mới.
  Future<void> advanceToNextBoard() async {
    if (!_nextBoardAvailable || _nextBoardId.isEmpty) return;
    // Bỏ ghi nhận calib của board CŨ. Có điều kiện, không xoá vô điều kiện:
    // `_runCalibrationIfNeeded()` calib cho board KẾ rồi mới gọi hàm này, nên
    // xoá thẳng sẽ mất luôn lần calib vừa làm cho đúng board đang chuyển tới.
    if (!isCalibratedFor(boardId: _nextBoardId, side: _nextBoardSide)) {
      invalidateCalibration();
    }
    _currentBoard = _nextBoardId;
    _currentBoardCode = _nextBoardCode;
    _currentBoardSide = _nextBoardSide;
    _nextBoardAvailable = false;
    _nextBoardIsNewPhysical = false;
    _nextBoardId = '';
    _nextBoardCode = '';
    _lotFinished = false;
    _lastCompletedBoardId = '';
    _calibrationNeeded = false;
    notifyListeners();
  }

  /// Đồng bộ board_code + mặt board hiện tại khi board được khởi động thủ
  /// công (nút "Bắt đầu" → `_startWithCalibration`), tức KHÔNG đi qua
  /// [advanceToNextBoard]. Nếu không gọi hàm này, `currentBoardSide` giữ giá
  /// trị cũ (mặc định 'A' hoặc mặt của board trước) - sai nếu board đầu
  /// tiên của model/lô là mặt B, hoặc khi bấm "Bắt đầu" thay vì "Board tiếp
  /// theo". Các nơi đọc `currentBoardSide` để gọi API bù lệch (vd Manual VRS
  /// screen) phụ thuộc vào giá trị này luôn đúng với board đang xử lý.
  void setCurrentBoardMeta({required String code, required String side}) {
    _currentBoardCode = code;
    _currentBoardSide = side;
    notifyListeners();
  }

  /// Ghi nhận vừa calib bù lệch THÀNH CÔNG cho board [boardId] mặt [side].
  /// Gọi từ cả Auto VRS và VRS thủ công, để calib làm ở màn thủ công cũng được
  /// Auto VRS công nhận (không bắt operator calib lại khi quay về tab Auto).
  void markCalibrated({required String boardId, required String side}) {
    if (boardId.isEmpty) return;
    _calibratedBoardId = boardId;
    _calibratedSide = side;
    debugPrint('📐 Da ghi nhan calib: board=$boardId side=$side');
    notifyListeners();
  }

  /// Board [boardId] mặt [side] có phải chính là lần calib gần nhất không.
  ///
  /// Chỉ là điều kiện CẦN để bỏ qua calib - bên gọi vẫn phải xác minh với
  /// gateway (`PlcGatewayService.hasValidOffsetFor`) vì file offset có thể đã
  /// bị mất/ghi đè mà app không biết.
  bool isCalibratedFor({required String boardId, required String side}) {
    return boardId.isNotEmpty &&
        _calibratedBoardId == boardId &&
        _calibratedSide == side;
  }

  /// Xoá ghi nhận calib - gọi ở MỌI chỗ board hiện tại thay đổi, vì offset cũ
  /// không còn đúng cho board mới.
  void invalidateCalibration() {
    if (_calibratedBoardId.isEmpty && _calibratedSide.isEmpty) return;
    _calibratedBoardId = '';
    _calibratedSide = '';
  }

  Future<void> updateCounts({int? total, int? ok, int? ng}) async {
    if (total != null) _totalCount = total;
    if (ok != null) _okCount = ok;
    if (ng != null) _ngCount = ng;
    notifyListeners();
  }

  Future<void> incrementCount(bool isOK) async {
    _totalCount++;
    if (isOK) {
      _okCount++;
    } else {
      _ngCount++;
    }
    notifyListeners();
  }

  Future<void> setMagnification(double value) async {
    _magnification = value;
    await _db.updateConfig('magnification', value.toString());
    notifyListeners();
  }

  Future<void> setLightLevel(double value) async {
    _lightLevel = value;
    await _db.updateConfig('light_level', value.toString());
    notifyListeners();
  }

  void addAlignmentPoint(double x, double y, String label) {
    _alignmentPoints.add({
      'x': x,
      'y': y,
      'label': label,
      'step': _currentAlignmentStep,
    });
    notifyListeners();
  }

  void clearAlignmentPoints() {
    _alignmentPoints.clear();
    _currentAlignmentStep = 1;
    notifyListeners();
  }

  void setAlignmentStep(int step) {
    _currentAlignmentStep = step;
    notifyListeners();
  }

  void nextAlignmentStep() {
    if (_currentAlignmentStep < 4) {
      _currentAlignmentStep++;
      notifyListeners();
    }
  }

  Future<void> resetSystem() async {
    invalidateCalibration();
    _totalCount = 0;
    _okCount = 0;
    _ngCount = 0;
    _systemStatus = 'OK';
    await _db.updateConfig('system_status', 'OK');
    clearAlignmentPoints();
    notifyListeners();
  }

  // Get available models from database
  Future<List<Map<String, dynamic>>> getAvailableModels() async {
    return await _db.getAllModels();
  }

  // Refresh data from database
  Future<void> refreshData() async {
    await _loadSystemConfig();
    await _loadCurrentModel();
    await _loadStatistics();
    notifyListeners();
  }
}
