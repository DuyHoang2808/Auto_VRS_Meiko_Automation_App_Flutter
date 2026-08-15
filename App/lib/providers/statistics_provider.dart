import 'package:flutter/foundation.dart';
import '../services/local_database_service.dart';

class StatisticsProvider extends ChangeNotifier {
  final LocalDatabaseService _db = LocalDatabaseService();

  // Cached data
  Map<String, int> _defectData = {};
  List<Map<String, dynamic>> _lotStatistics = [];
  List<Map<String, dynamic>> _lots = [];
  // Phạm vi của `_defectData`: null = tất cả các lô.
  int? _selectedLotId;
  bool _isLoading = false;

  // Getters
  Map<String, int> get defectData => Map.unmodifiable(_defectData);
  List<Map<String, dynamic>> get lotStatistics =>
      List.unmodifiable(_lotStatistics);
  List<Map<String, dynamic>> get lots => List.unmodifiable(_lots);
  int? get selectedLotId => _selectedLotId;
  bool get isLoading => _isLoading;

  int get totalDefects =>
      _defectData.values.fold(0, (sum, value) => sum + value);

  // Initialize and load data from database
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      await loadDefectStatistics();
      await loadLotStatistics();
      await loadLots();
    } catch (e) {
      debugPrint('Error initializing StatisticsProvider: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Load defect statistics from database (theo phạm vi `_selectedLotId`)
  Future<void> loadDefectStatistics() async {
    try {
      _defectData = await _db.getDefectStatistics(idLot: _selectedLotId);
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading defect statistics: $e');
    }
  }

  // Load lot statistics from database
  Future<void> loadLotStatistics() async {
    try {
      final rawStats = await _db.getAllLotStatistics();
      _lotStatistics = rawStats.map((stat) {
        // lot_code = null cho lot tạo trước migration tbLot.lot_code -
        // fallback về kiểu nhãn cũ tự sinh từ id_lot cho các lot đó.
        final lotLabel = stat['lot_code']?.toString() ?? 'LOT-${stat['id_lot']}';
        return {
          'lotId': lotLabel,
          'lotName': lotLabel,
          'boardCount': stat['actual_boards'] ?? 0,
          'ngRate':
              ((stat['ng_boards'] ?? 0) / (stat['actual_boards'] ?? 1)) * 100,
          'okCount': stat['ok_boards'] ?? 0,
          'ngCount': stat['ng_boards'] ?? 0,
          'createdDate': DateTime.now().toIso8601String().substring(0, 10),
          'falsePositiveRate': stat['fakeDef'] ?? 0.0,
        };
      }).toList();
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading lot statistics: $e');
    }
  }

  // Load available lots
  Future<void> loadLots() async {
    try {
      final allLots = await _db.getAllLots();
      _lots = allLots.map((lot) {
        return {
          'lot_id': 'LOT-${lot['id_lot']}',
          'model_id': lot['tbModelid_model'] ?? 1,
          'total_boards': lot['board_quantity'] ?? 0,
          'id_lot': lot['id_lot'],
        };
      }).toList();
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading lots: $e');
    }
  }

  // Get statistics for specific lot
  Future<Map<String, dynamic>?> getLotStatistics(int lotId) async {
    try {
      return await _db.getLotStatistics(lotId);
    } catch (e) {
      debugPrint('Error getting lot statistics: $e');
      return null;
    }
  }

  // Get defects for specific lot
  Future<List<Map<String, dynamic>>> getDefectsForLot(int lotId) async {
    try {
      final boards = await _db.getBoardsByLot(lotId);
      final defects = <Map<String, dynamic>>[];

      for (var board in boards) {
        final boardDefects = await _db.getDefectsByBoard(board['id_board']);
        for (var defect in boardDefects) {
          defects.add({
            'id': defect['id_defect'],
            'boardId': defect['tbBoardid_board'],
            'type': defect['type'],
            'judgment': defect['judgement'],
            'height': defect['height'],
            'width': defect['width'],
            'time': defect['time'],
            'coordinates': defect['coordinates'],
            'url_image': defect['url_image'],
          });
        }
      }

      return defects;
    } catch (e) {
      debugPrint('Error getting defects for lot: $e');
      return [];
    }
  }

  /// Đổi phạm vi thống kê loại lỗi rồi nạp lại. [lotId] `null` = tất cả các lô.
  ///
  /// Thay cho `selectLot()` + `loadLotDefectStatistics()` cũ: cả hai đều không
  /// nơi nào gọi (`selectLot` chỉ ghi vào 1 biến không ai đọc), và
  /// `loadLotDefectStatistics` còn gom theo cột `type` - tức mã SỐ thô của AOI.
  /// Nay chỉ còn một đường duy nhất, gom theo `ai_type` ở tầng SQL.
  Future<void> selectDefectStatsLot(int? lotId) async {
    if (_selectedLotId == lotId && _defectData.isNotEmpty) return;
    _selectedLotId = lotId;
    _isLoading = true;
    notifyListeners();
    try {
      await loadDefectStatistics();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Refresh all data
  Future<void> refreshData() async {
    await initialize();
  }

  // Chart data helpers
  List<Map<String, dynamic>> getDefectChartData() {
    return _defectData.entries
        .map(
          (entry) => {
            'label': entry.key,
            'value': entry.value,
            'color': _getDefectColor(entry.key),
          },
        )
        .toList();
  }

  // Khóa theo tên kỹ thuật thực tế lưu trong cột `type` của tbDefect (xem
  // `_getDefectDisplayName` trong vrs_main_screen.dart) - KHÔNG phải tên
  // hiển thị tiếng Việt, nếu không mọi loại lỗi đều rơi vào default (xám).
  int _getDefectColor(String defectType) {
    switch (defectType.toLowerCase()) {
      case 'bamdinhkhongtot':
        return 0xFF8D6E63; // Brown
      case 'chamkim':
        return 0xFFEF4444; // Red
      case 'divat':
        return 0xFFF97316; // Orange
      case 'divatduongmach':
        return 0xFFEA580C; // Deep orange
      case 'khuyetmach':
        return 0xFF9333EA; // Purple
      case 'nganmach':
        return 0xFFEC4899; // Pink
      case 'thieudong':
        return 0xFF3B82F6; // Blue
      case 'thieudongduongmach':
        return 0xFF0EA5E9; // Light blue
      case 'thuadong':
        return 0xFF10B981; // Green
      case 'thuadongduongmach':
        return 0xFF14B8A6; // Teal
      case 'vetlom':
        return 0xFF6366F1; // Indigo
      case 'xuoc':
        return 0xFFF59E0B; // Amber
      // Legacy names (tương thích ngược, xem _getDefectDisplayName)
      case 'short_circuit':
        return 0xFFEC4899; // Pink accent
      case 'missing_component':
        return 0xFF3B82F6; // Blue accent
      case 'damaged_track':
        return 0xFF06B6D4; // Cyan
      case 'solder_bridge':
        return 0xFFA3E635; // Lime
      case 'crack':
        return 0xFF7C3AED; // Deep purple
      default:
        return 0xFF6B7280; // Gray
    }
  }

  // Get summary statistics
  Map<String, dynamic> getSummaryStatistics() {
    final totalBoards = _lotStatistics.fold<int>(
      0,
      (sum, lot) => sum + (lot['boardCount'] as int),
    );
    final totalNg = _lotStatistics.fold<int>(
      0,
      (sum, lot) => sum + (lot['ngCount'] as int),
    );
    final totalOk = _lotStatistics.fold<int>(
      0,
      (sum, lot) => sum + (lot['okCount'] as int),
    );
    final overallNgRate = totalBoards > 0 ? (totalNg / totalBoards) * 100 : 0.0;

    return {
      'totalBoards': totalBoards,
      'totalOk': totalOk,
      'totalNg': totalNg,
      'overallNgRate': overallNgRate,
      'totalDefects': totalDefects,
      'totalLots': _lots.length,
    };
  }
}
