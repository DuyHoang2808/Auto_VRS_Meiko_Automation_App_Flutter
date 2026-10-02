import 'package:flutter/foundation.dart';
import '../services/local_database_service.dart';
import 'aoi_machine_provider.dart';

class VRSProvider extends ChangeNotifier {
  final LocalDatabaseService _db = LocalDatabaseService();
  // Máy AOI đang chọn - mọi truy vấn model/lot/board bên dưới phải lọc theo
  // đúng máy này (1 dòng tbLot/board_code có thể bị nhiều máy dùng chung, xem
  // AoiMachineProvider + local_database_service.dart). Nhận qua constructor
  // (không đọc trực tiếp AoiMachineProvider.instance vì lớp này không phải
  // widget, không có BuildContext) - xem main.dart nơi khởi tạo.
  final AoiMachineProvider _aoiMachine;

  VRSProvider(this._aoiMachine);

  // Current system status
  String _systemStatus = 'Loading...';
  bool _isAutoMode = true;
  String _currentModel = '';
  String _currentModelName = '';
  // Mã hàng (product_code) vừa báo THÀNH CÔNG cho PLC Gateway lúc operator
  // chọn mã hàng (xem select_model_screen.dart). Dùng để các màn hình khác
  // đối chiếu với GET /api/products/active - phát hiện lệch nếu gateway bị
  // đổi mã hàng từ nơi khác (vd công cụ calib rời) mà app không hề biết.
  String? _lastSelectedProductCode;
  String _currentLot = '';
  // Mã lot thật (lot_code từ AOI_Ingest, xem tbLot.lot_code) - tên hiển thị
  // cho vận hành viên, khác với id_lot (khóa DB nội bộ). Lot tạo trước khi
  // cột này tồn tại không có mã, xem nơi gán để biết fallback.
  String _currentLotCode = '';
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

  // Đợt (board batch) đang active cho lot hiện tại - xem _applyLot,
  // completeCurrentBoardAndCheckNext(), checkForNewBoard(). `_batchFinished`
  // có nghĩa RỘNG hơn "vừa hết đợt": còn bao gồm "lot còn board pending nhưng
  // CHƯA có đợt nào đang chạy" (vd lúc khởi động app tự chọn lại 1 lot cũ
  // chưa từng tạo đợt) - cả 2 trường hợp đều cần vận hành viên chọn đợt mới.
  int? _activeBatchId;
  String _activeBatchStartCode = '';
  String _activeBatchEndCode = '';
  int? _activeBatchStartIdBoard;
  int? _activeBatchEndIdBoard;
  bool _batchFinished = false;
  // Mã đợt VỪA xong - tách riêng khỏi các field active ở trên (bị xoá ngay
  // khi biết hết đợt) để vẫn hiện được thông báo, cùng lý do
  // _lastCompletedBoardId tách khỏi _currentBoard.
  String _lastBatchStartCode = '';
  String _lastBatchEndCode = '';

  // Board side tracking + calibration flag
  // "B" = mặt top (l1-l4), "A" = mặt bottom (l5-l8)
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
  // board_code của lần calib đó. Song song với _calibratedBoardId chứ không
  // thay thế: 1 board VẬT LÝ có NHIỀU dòng tbBoard (mỗi layer 1 dòng, cùng
  // board_code cùng mặt - dữ liệu thật: mỗi board_code 2 dòng). Chuyển sang
  // dòng kế của CÙNG bo CÙNG mặt thì không có gì xê dịch trên bàn máy, khoá
  // theo id_board sẽ bắt calib lại thêm 90s cho mỗi dòng mà không được gì.
  String _calibratedBoardCode = '';
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
  String get currentLotCode => _currentLotCode;
  String get currentBoard => _currentBoard;
  String get currentBoardCode => _currentBoardCode;
  String get systemStatus => _systemStatus;
  bool get isAutoMode => _isAutoMode;
  String get currentModel => _currentModel;
  String get currentModelName => _currentModelName;
  String? get lastSelectedProductCode => _lastSelectedProductCode;
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
  String get nextBoardCode => _nextBoardCode;
  bool get lotFinished => _lotFinished;
  String get lastCompletedBoardId => _lastCompletedBoardId;
  int? get activeBatchId => _activeBatchId;
  String get activeBatchStartCode => _activeBatchStartCode;
  String get activeBatchEndCode => _activeBatchEndCode;
  bool get batchFinished => _batchFinished;
  String get lastBatchStartCode => _lastBatchStartCode;
  String get lastBatchEndCode => _lastBatchEndCode;
  String get currentBoardSide => _currentBoardSide;
  String get nextBoardSide => _nextBoardSide;
  bool get calibrationNeeded => _calibrationNeeded;

  /// id_board đã ghi vào file offset của gateway ở lần calib gần nhất - dùng
  /// để hỏi `PlcGatewayService.hasValidOffsetFor` cho ĐÚNG id đó, vì bo vật lý
  /// có thể đang mở ở 1 dòng tbBoard khác (xem isCalibratedForPhysical).
  String get calibratedBoardId => _calibratedBoardId;

  /// Xác định mặt board từ layer_id: l1-l4 → "B" (top), l5-l8 → "A" (bottom).
  /// Format layer_id từ AOI_Ingest: lowercase "l1", "l2", ..., "l8".
  /// Trả "B" (top) nếu không parse được (an toàn hơn, giữ nguyên ý định mặc
  /// định = mặt top như trước khi đổi quy ước A/B).
  static String boardSideFromLayerId(String? layerId) {
    if (layerId == null || layerId.isEmpty) return 'B';
    // Bỏ prefix "l"/"L", parse số
    final numeric = int.tryParse(layerId.replaceFirst(RegExp(r'^[lL]'), ''));
    if (numeric == null) return 'B';
    return numeric >= 5 ? 'A' : 'B';
  }

  /// Xác định mặt board của 1 dòng `tbBoard`: ưu tiên cột `board_side` (ghi
  /// THẲNG từ tên file AOI xuất ra, "A.vrs"/"B.vrs" - xem
  /// AOI_Ingest/aoi_ingest_service.py::process_board_once, biến
  /// `side = vrs_path.stem`) - đây là nguồn THẬT, không suy đoán. Chỉ
  /// fallback về [boardSideFromLayerId] (suy từ layer_id, có thể sai với các
  /// layer_id không theo mẫu `l<số>` như "core_1"/"conf_8"/"top_p_ok" - bug
  /// thật gặp phải: board có layer_id lạ không bao giờ được coi là có mặt A)
  /// cho các dòng board ghi TRƯỚC khi có cột `board_side` (giá trị NULL).
  static String boardSideOf(Map<String, dynamic>? board) {
    final raw = board?['board_side']?.toString().trim().toUpperCase();
    if (raw == 'A' || raw == 'B') return raw!;
    return boardSideFromLayerId(board?['layer_id']?.toString());
  }

  /// true nếu [boardSideOf] suy được mặt board một cách CHẮC CHẮN (từ cột
  /// `board_side`, hoặc `layer_id` khớp đúng mẫu `l<số>`) - false nếu nó chỉ
  /// đang TRẢ VỀ GIÁ TRỊ MẶC ĐỊNH 'B' vì không suy được gì (xem
  /// [boardSideFromLayerId]).
  ///
  /// BUG THẬT đã gặp 2026-09-28: cột `board_side` hiện 100% NULL trong DB
  /// thật (AOI_Ingest CHƯA ghi cột này, dù code đã sẵn sàng ưu tiên đọc) nên
  /// mọi board đều rơi về suy từ `layer_id` - mà layer_id thực tế phong phú
  /// hơn hẳn mẫu "l1".."l8" code giả định (đã thấy thật trong DB: "core_1",
  /// "core_8", "conf_1", "conf_8", "l8_dummy", "l1_dummy", "top_p_ok",
  /// "bot_p_ok"...). Các tên này không khớp regex `^[lL]<số>` nên đều IM
  /// LẶNG rơi về mặc định 'B' - nếu 2 board liền kề (1 mặt vừa xong, 1 mặt
  /// sắp tới) đều rơi vào default này, `_calibrationNeeded` tính sai thành
  /// false (coi như "không đổi mặt") dù có thể ĐÃ đổi mặt thật - bỏ sót
  /// calib bù lệch khi lật bo, sai toạ độ PLC cho cả mặt mới.
  ///
  /// Dùng ở nơi quyết định có ép calib hay không: nếu KHÔNG chắc chắn (trả
  /// về false), phải coi như "cần calib" (an toàn hơn calib thừa 90 giây,
  /// còn hơn bỏ sót calib làm sai toạ độ PLC) - xem
  /// completeCurrentBoardAndCheckNext/checkForNewBoard.
  static bool isSideConfident(Map<String, dynamic>? board) {
    final raw = board?['board_side']?.toString().trim().toUpperCase();
    if (raw == 'A' || raw == 'B') return true;
    final layerId = board?['layer_id']?.toString();
    if (layerId == null || layerId.isEmpty) return false;
    final numeric = int.tryParse(layerId.replaceFirst(RegExp(r'^[lL]'), ''));
    return numeric != null;
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

  /// Áp dụng 1 lot đã xác định (hoặc `null` = model chưa có lot khả dụng)
  /// vào state hiện tại: currentLot/currentLotCode + board đầu tiên còn dở
  /// của lot đó. Dùng chung bởi mọi đường "vào" 1 lot - tự động chọn
  /// (setCurrentModel/khởi động app) hay vận hành viên tự chọn thủ công
  /// (setCurrentModelAndLot) - để logic áp dụng lot luôn nhất quán.
  Future<void> _applyLot(Map<String, dynamic>? lot) async {
    // Đổi lot/model -> "board tiếp theo" đã tìm thấy trước đó (nếu có) thuộc
    // về model/lot CŨ, không còn liên quan gì tới board/mặt sắp áp dụng bên
    // dưới. BUG đã gặp: chuyển từ model A (vừa hoàn tất 1 board nên
    // nextBoardAvailable=true, trỏ board+mặt của model A) sang model B (đang
    // dở dang mặt B) - _applyLot set đúng _currentBoard/_currentBoardSide
    // theo model B, NHƯNG nextBoardAvailable còn true từ model A khiến nút
    // "Bắt đầu" bị khoá; bấm "Board tiếp theo" thay vào đó thì
    // advanceToNextBoard() ghi đè _currentBoard/_currentBoardSide vừa set
    // đúng ở trên bằng board+mặt CŨ của model A -> gateway calib/soi nhầm mặt.
    // Phải xoá sạch state "board tiếp theo" mỗi khi áp dụng 1 lot/model mới.
    _nextBoardAvailable = false;
    _nextBoardIsNewPhysical = false;
    _nextBoardId = '';
    _nextBoardCode = '';
    _nextBoardSide = 'A';
    _lotFinished = false;
    _calibrationNeeded = false;
    _lastCompletedBoardId = '';
    _batchFinished = false;
    _activeBatchId = null;
    _activeBatchStartCode = '';
    _activeBatchEndCode = '';
    _activeBatchStartIdBoard = null;
    _activeBatchEndIdBoard = null;

    if (lot == null) {
      _currentLot = 'Chưa có';
      _currentLotCode = '';
      _currentBoard = 'Chưa có';
      _currentBoardCode = '';
      _currentBoardSide = 'A';
      return;
    }

    _currentLot = lot['id_lot'].toString();
    _currentLotCode = lot['lot_code']?.toString() ?? _currentLot;
    final idLot = lot['id_lot'] as int;

    final activeBatch = await _db.getActiveBatchForLot(
      idLot,
      aoiMachine: _aoiMachine.selectedMachine,
    );
    // Đợt được coi là "còn việc" nhưng không lấy ra được board pending nào
    // trong đợt đó = 2 truy vấn lệch điều kiện nhau (bug đã gặp: bộ lọc máy
    // AOI). KHÔNG nhận đợt rỗng đó làm đợt đang chạy - nhận vào sẽ ra trạng
    // thái câm: currentBoard = 'Chưa có' mà batchFinished vẫn false, nên
    // KHÔNG màn hình nào (Auto lẫn thủ công) hiện được nút "Chọn đợt mới",
    // operator kẹt hẳn. Bỏ qua đợt đó thì rơi xuống nhánh dưới -> batchFinished
    // -> vẫn chọn được đợt mới để chạy lượt tiếp theo.
    Map<String, dynamic>? batchBoard;
    if (activeBatch != null) {
      batchBoard = await _db.getFirstPendingBoardInBatch(
        idLot,
        activeBatch['start_id_board'] as int,
        activeBatch['end_id_board'] as int,
        aoiMachine: _aoiMachine.selectedMachine,
      );
    }
    if (activeBatch != null && batchBoard != null) {
      _activeBatchId = activeBatch['id_batch'] as int;
      _activeBatchStartCode = activeBatch['start_board_code']?.toString() ?? '';
      _activeBatchEndCode = activeBatch['end_board_code']?.toString() ?? '';
      _activeBatchStartIdBoard = activeBatch['start_id_board'] as int;
      _activeBatchEndIdBoard = activeBatch['end_id_board'] as int;
      _currentBoard = batchBoard['id_board'].toString();
      _currentBoardCode = batchBoard['board_code']?.toString() ?? '';
      _currentBoardSide = boardSideOf(batchBoard);
      return;
    }

    // Không có đợt còn việc cho lot này - lot đã xong hoàn toàn, hay chỉ đang
    // chờ chọn đợt mới? Đặt xử lý ở ĐÂY (không chỉ ở
    // completeCurrentBoardAndCheckNext/checkForNewBoard) vì setCurrentModel
    // (tự chọn lot lúc khởi động app, KHÔNG qua màn hình nào) cũng đi qua
    // _applyLot - nếu không, app khởi động vào 1 lot còn việc nhưng chưa từng
    // tạo đợt sẽ rơi vào trạng thái không ai biết, không có đường nào cho vận
    // hành viên chọn đợt.
    _currentBoard = 'Chưa có';
    _currentBoardCode = '';
    _currentBoardSide = 'A';
    final anyPending = await _db.getFirstBoardByLotId(
      _currentLot,
      aoiMachine: _aoiMachine.selectedMachine,
    );
    if (anyPending == null) {
      // Phân biệt "lot đã TỪNG có board, giờ xong hết" (lotFinished đúng)
      // với "lot chưa hề có board nào" (mới, AOI chưa ghi gì tới - KHÔNG
      // được báo "đã hoàn tất" cho 1 lot chưa từng làm gì).
      if (await _db.lotHasAnyBoard(idLot)) {
        _lotFinished = true;
      }
      return;
    }

    _batchFinished = true;
    final mostRecent = await _db.getMostRecentBatchForLot(
      idLot,
      aoiMachine: _aoiMachine.selectedMachine,
    );
    if (mostRecent != null) {
      _lastBatchStartCode = mostRecent['start_board_code']?.toString() ?? '';
      _lastBatchEndCode = mostRecent['end_board_code']?.toString() ?? '';
      // Self-heal: đợt gần nhất coi như đã hết việc thật - đồng bộ lại status
      // cho đúng audit. Không có logic nào DỰA vào cột này để quyết định
      // hành vi (xem getActiveBatchForLot), nên an toàn để tự sửa ở đây.
      if (mostRecent['status'] != 'completed') {
        await _db.markBatchCompleted(mostRecent['id_batch'] as int);
      }
    }
  }

  /// Chọn model, TỰ ĐỘNG chọn lot theo getCurrentLotForModel (lot cũ nhất
  /// còn dở, hoặc mới nhất nếu mọi lot đã xong). Dùng khi không có màn hình
  /// chọn lot thủ công ở giữa (vd khôi phục trạng thái lúc khởi động app -
  /// xem _resolveFirstLotAndBoardForModel).
  Future<void> setCurrentModel(String modelId) async {
    try {
      final model = await _db.getModelById(int.parse(modelId));
      if (model != null) {
        // Đổi model -> đổi board, offset đã calib không còn đúng.
        invalidateCalibration();
        _currentModel = model['id_model'].toString();
        _currentModelName = 'Model ${model['id_model']}';
        await _applyLot(
          await _db.getCurrentLotForModel(
            modelId,
            aoiMachine: _aoiMachine.selectedMachine,
          ),
        );
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error setting current model: $e');
    }
  }

  /// Chọn model VÀ lot cụ thể (vận hành viên tự chọn ở màn hình chọn lot,
  /// xem SelectLotForModelScreen) - không tự đoán lot như setCurrentModel.
  Future<void> setCurrentModelAndLot(String modelId, int idLot) async {
    try {
      final model = await _db.getModelById(int.parse(modelId));
      if (model != null) {
        invalidateCalibration();
        _currentModel = model['id_model'].toString();
        _currentModelName = 'Model ${model['id_model']}';
        await _applyLot(await _db.getLotById(idLot));
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error setting current model and lot: $e');
    }
  }

  /// Xoá sạch model/lot/board/đợt đang chọn - gọi NGAY sau khi vận hành viên
  /// ĐỔI máy AOI đang chọn (xem AoiMachineDialog/main_layout.dart), TRƯỚC khi
  /// họ chọn model mới. Máy khác có thể có/không có model/lot/board vừa chọn
  /// (board_code của máy cũ hoàn toàn có thể trùng số nhưng khác nội dung với
  /// máy mới - xem local_database_service.dart) - không reset sẽ để lại
  /// board/đợt "ma" của máy cũ, hiện sai cho tới khi vận hành viên tự chọn
  /// lại model.
  Future<void> resetSelection() async {
    invalidateCalibration();
    _currentModel = '';
    _currentModelName = '';
    _lastSelectedProductCode = null;
    await _applyLot(null);
    notifyListeners();
  }

  /// Ghi nhận mã hàng (product_code) vừa báo THÀNH CÔNG cho PLC Gateway - gọi
  /// từ select_model_screen.dart ngay sau khi `PlcGatewayService.selectProduct`
  /// trả `success: true`. KHÔNG gọi khi thất bại - lúc đó gateway vẫn đang
  /// chạy mã hàng cũ, ghi nhận mã hàng mới vào đây sẽ làm màn hình khác so
  /// sánh sai (tưởng đã khớp trong khi thực ra chưa đổi).
  void setLastSelectedProductCode(String productCode) {
    _lastSelectedProductCode = productCode;
    notifyListeners();
  }

  /// Gọi sau khi vận hành viên vừa tạo 1 đợt mới cho lot ĐANG chọn (không đổi
  /// model/lot) - nút "Chọn đợt mới" khi `batchFinished` (xem
  /// vrs_main_screen.dart). Nạp lại đúng lot hiện tại rồi chạy lại _applyLot
  /// để lấy đúng đợt + board vừa tạo.
  Future<void> refreshActiveBatch() async {
    final lotId = int.tryParse(_currentLot);
    if (lotId == null) return;
    try {
      // Board mới của đợt mới -> offset calib cũ không còn đúng, cùng lý do
      // mọi đường vào lot khác đều gọi hàm này.
      invalidateCalibration();
      await _applyLot(await _db.getLotById(lotId));
      notifyListeners();
    } catch (e) {
      debugPrint('Error refreshing active batch: $e');
    }
  }

  Future<void> _resolveFirstLotAndBoardForModel(String modelId) async {
    // Chuyển sang board đầu tiên của model -> offset calib cũ không còn đúng.
    invalidateCalibration();
    await _applyLot(
      await _db.getCurrentLotForModel(
        modelId,
        aoiMachine: _aoiMachine.selectedMachine,
      ),
    );
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

      // Có đợt đang active -> PHẢI dùng truy vấn có biên trên (không lùi về
      // trước, không vượt qua đợt). BUG đã gặp: dùng getNextPendingBoard
      // (không biên, tìm khắp cả lot) rồi chỉ so sánh `> biên trên` để phát
      // hiện "vượt đợt" - nếu board vừa hoàn tất đã là board có id_board LỚN
      // NHẤT của CẢ LOT (vd đợt sau chạy trước đợt đầu), getNextPendingBoard
      // trả null NGAY, code cũ nhảy thẳng vào nhánh "lotFinished" dù lot vẫn
      // còn nguyên 1 khoảng trống board pending TRƯỚC đợt hiện tại - báo sai
      // "đã hoàn tất toàn bộ" trong khi thực ra chỉ mới hết ĐÚNG đợt này.
      final currentBoardCode = currentBoardRow?['board_code']?.toString();
      final nextBoardRow = _activeBatchEndIdBoard != null
          ? await _db.getNextPendingBoardInBatch(
              lotId,
              boardId,
              currentBoardCode,
              _activeBatchEndIdBoard!,
              aoiMachine: _aoiMachine.selectedMachine,
            )
          : await _db.getNextPendingBoard(
              lotId,
              boardId,
              currentBoardCode,
              aoiMachine: _aoiMachine.selectedMachine,
            );

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
        _nextBoardSide = boardSideOf(nextBoardRow);
        // Cần calib nếu: board vật lý mới HOẶC đổi mặt (A↔B) HOẶC không chắc
        // chắn mặt của 1 trong 2 board (xem isSideConfident - an toàn hơn là
        // calib thừa, còn hơn bỏ sót khi lật bo mà không biết).
        _calibrationNeeded =
            _nextBoardIsNewPhysical ||
            boardSideOf(currentBoardRow) != _nextBoardSide ||
            !isSideConfident(currentBoardRow) ||
            !isSideConfident(nextBoardRow);
      } else if (_activeBatchId != null) {
        // Hết board TRONG đợt (dù có thể lot còn board khác NGOÀI đợt, vd 1
        // khoảng trống operator chủ ý bỏ qua) - đóng đợt, KHÔNG được kết
        // luận lotFinished chỉ vì không tìm được gì "tiến tới" từ đây.
        _lastCompletedBoardId = _currentBoard;
        _lastBatchStartCode = _activeBatchStartCode;
        _lastBatchEndCode = _activeBatchEndCode;
        await _db.markBatchCompleted(_activeBatchId!);
        _currentBoard = 'Chưa có';
        _currentBoardCode = '';
        _activeBatchId = null;
        _activeBatchStartCode = '';
        _activeBatchEndCode = '';
        _activeBatchStartIdBoard = null;
        _activeBatchEndIdBoard = null;
        _nextBoardAvailable = false;
        _nextBoardId = '';
        _nextBoardCode = '';
        _calibrationNeeded = false;

        // Đợt vừa đóng có thể đã bao trọn phần còn lại của lot (màn chọn đợt
        // điền sẵn TOÀN BỘ board khả dụng, chỉ cần bấm Xác nhận - nên đây là
        // trường hợp thường gặp, không phải hiếm). Lúc đó lot đã xong thật:
        // báo "còn board chưa kiểm tra" rồi đẩy operator sang màn chọn đợt
        // TRỐNG là bế tắc. Hỏi lại DB đúng như _applyLot để 2 đường vào (mở
        // lại app vs đang chạy) không kết luận khác nhau trên cùng 1 dữ liệu.
        //
        // Tới đây chắc chắn không còn đợt nào khác còn việc (nếu có,
        // getNextPendingBoardInBatch phía trên đã trả về board rồi), nên board
        // pending còn lại - nếu có - chắc chắn chưa thuộc đợt nào và chọn được.
        final anyPending = await _db.getFirstBoardByLotId(
          _currentLot,
          aoiMachine: _aoiMachine.selectedMachine,
        );
        if (anyPending == null) {
          _lotFinished = true;
        } else {
          _batchFinished = true;
        }
      } else {
        // Không có đợt active (trường hợp hiếm) VÀ không còn board nào khác
        // trong lot - đây thật sự là board cuối cùng.
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
    // Chưa có đợt nào đang chạy (_batchFinished đã được _applyLot set) -
    // không tự tìm board mới, phải chờ vận hành viên chọn đợt trước. Trước
    // đây hàm này dùng getFirstBoardByLotId (không có biên dưới) - nếu vận
    // hành viên chủ ý chọn đợt bỏ qua 1 khoảng trống sớm hơn, hàm sẽ lùi về
    // board pending sớm nhất của CẢ LOT (ngoài đợt) chứ không phải trong đợt,
    // phá vỡ đúng tính năng giới hạn đợt.
    if (_activeBatchId == null ||
        _activeBatchStartIdBoard == null ||
        _activeBatchEndIdBoard == null) {
      return false;
    }

    try {
      final idLot = int.parse(_currentLot);
      final nextBoardRow = await _db.getFirstPendingBoardInBatch(
        idLot,
        _activeBatchStartIdBoard!,
        _activeBatchEndIdBoard!,
        aoiMachine: _aoiMachine.selectedMachine,
      );
      if (nextBoardRow == null) {
        // Hết việc trong đợt hiện tại.
        _lastBatchStartCode = _activeBatchStartCode;
        _lastBatchEndCode = _activeBatchEndCode;
        await _db.markBatchCompleted(_activeBatchId!);
        _activeBatchId = null;
        _activeBatchStartCode = '';
        _activeBatchEndCode = '';
        _activeBatchStartIdBoard = null;
        _activeBatchEndIdBoard = null;
        _batchFinished = true;
        notifyListeners();
        return false;
      }

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

      // Xác định mặt board + cần calib - xem ghi chú ở isSideConfident về vì
      // sao phải ép calib khi không chắc chắn mặt của 1 trong 2 board.
      _nextBoardSide = boardSideOf(nextBoardRow);
      _calibrationNeeded =
          _nextBoardIsNewPhysical ||
          boardSideOf(lastCompletedBoardRow) != _nextBoardSide ||
          !isSideConfident(lastCompletedBoardRow) ||
          !isSideConfident(nextBoardRow);

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
    // Giữ lại ghi nhận calib khi board kế vẫn là CÙNG bo vật lý CÙNG mặt (chỉ
    // khác dòng layer) - bo không rời bàn máy thì offset vẫn đúng nguyên.
    if (!isCalibratedFor(boardId: _nextBoardId, side: _nextBoardSide) &&
        !isCalibratedForPhysical(
          boardCode: _nextBoardCode,
          side: _nextBoardSide,
        )) {
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
  ///
  /// [boardCode] là mã bo VẬT LÝ vừa calib - truyền vào để
  /// [isCalibratedForPhysical] nhận ra các dòng tbBoard khác cùng bo cùng mặt.
  /// Bỏ trống thì chỉ còn khoá được theo id_board (dữ liệu cũ không có
  /// board_code), tức vẫn chạy đúng, chỉ là calib lại nhiều hơn cần thiết.
  void markCalibrated({
    required String boardId,
    required String side,
    String boardCode = '',
  }) {
    if (boardId.isEmpty) return;
    _calibratedBoardId = boardId;
    _calibratedSide = side;
    _calibratedBoardCode = boardCode;
    debugPrint(
      '📐 Da ghi nhan calib: board=$boardId (code=$boardCode) side=$side',
    );
    notifyListeners();
  }

  /// Bo VẬT LÝ đang gá trên bàn (board_code + mặt) đã calib trong phiên chưa.
  ///
  /// Khác [isCalibratedFor] (khoá theo id_board): dùng cho câu hỏi "cái bo
  /// đang nằm trên bàn máy đã bù lệch chưa", đúng thứ cần biết trước khi cho
  /// soi lỗi - xem ghi chú ở [_calibratedBoardCode] về việc 1 bo có nhiều dòng.
  ///
  /// Cũng CHỈ là điều kiện cần: bên gọi vẫn phải xác minh với gateway bằng
  /// [calibratedBoardId] (id thật đã ghi vào file offset), vì file có thể mất.
  bool isCalibratedForPhysical({
    required String boardCode,
    required String side,
  }) {
    if (boardCode.isEmpty || _calibratedBoardCode.isEmpty) return false;
    return _calibratedBoardCode == boardCode && _calibratedSide == side;
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
    if (_calibratedBoardId.isEmpty &&
        _calibratedSide.isEmpty &&
        _calibratedBoardCode.isEmpty) {
      return;
    }
    _calibratedBoardId = '';
    _calibratedSide = '';
    _calibratedBoardCode = '';
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
