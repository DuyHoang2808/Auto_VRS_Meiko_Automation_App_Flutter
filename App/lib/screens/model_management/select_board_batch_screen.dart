import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/aoi_machine_provider.dart';
import '../../services/local_database_service.dart';

/// Màn hình chọn "đợt" (khoảng board_code bắt đầu-kết thúc) cho 1 lot đã
/// chọn - đẩy sang từ SelectModelScreen NGAY SAU khi chọn lot, chỉ khi lot đó
/// chưa có đợt nào đang chạy (xem LocalDatabaseService.getActiveBatchForLot).
///
/// Máy VRS thật chỉ tải được 1 số board hạn chế mỗi lần (~100 hoặc ít hơn),
/// trong khi 1 lot có thể có nhiều board hơn hẳn - "đợt" giới hạn Auto VRS
/// chỉ chạy trong đúng khoảng board đang nằm trên máy, lưu lại trong DB để
/// nhớ qua các lần chạy/ca khác nhau (xem tbBoardBatch).
///
/// Luôn hiện (cả lot nhỏ) - mặc định điền sẵn board đầu/cuối còn khả dụng
/// (chưa vào đợt nào), lot nhỏ chỉ cần bấm Xác nhận. Trả `id_batch` vừa tạo
/// qua context.pop(idBatch); back tay (không chọn) trả `null`.
class SelectBoardBatchScreen extends StatefulWidget {
  final int idLot;

  const SelectBoardBatchScreen({super.key, required this.idLot});

  @override
  State<SelectBoardBatchScreen> createState() => _SelectBoardBatchScreenState();
}

class _SelectBoardBatchScreenState extends State<SelectBoardBatchScreen> {
  final LocalDatabaseService _db = LocalDatabaseService();
  final TextEditingController _startController = TextEditingController();
  final TextEditingController _endController = TextEditingController();

  List<Map<String, dynamic>> _eligibleBoards = [];
  bool _isLoading = true;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _loadEligibleBoards();
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  /// Máy AOI đang chọn - dùng cho MỌI truy vấn DB trong màn này (lô có thể bị
  /// nhiều máy dùng chung, xem local_database_service.dart). Đọc 1 lần ở
  /// đây (không đọc lại mỗi hàm) vì các hàm dưới đều được gọi từ callback
  /// (không phải build()), context vẫn hợp lệ suốt vòng đời màn hình này.
  String? get _aoiMachine => context.read<AoiMachineProvider>().selectedMachine;

  Future<void> _loadEligibleBoards() async {
    setState(() => _isLoading = true);
    try {
      final boards = await _db.getEligibleBoardsForBatch(
        widget.idLot,
        aoiMachine: _aoiMachine,
      );
      if (!mounted) return;
      setState(() {
        _eligibleBoards = boards;
        _isLoading = false;
        // Mặc định: board đầu tiên còn khả dụng -> board cuối cùng hiện có -
        // lot nhỏ chỉ cần bấm Xác nhận, không cần gõ gì. CHỈ điền khi cả 2 ô
        // đang rỗng - nút "Làm mới danh sách" cũng gọi lại hàm này, không
        // được âm thầm xoá mã operator đã tự gõ/chọn trước đó.
        if (boards.isNotEmpty &&
            _startController.text.isEmpty &&
            _endController.text.isEmpty) {
          _startController.text = boards.first['board_code'].toString();
          _endController.text = boards.last['board_code'].toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Lỗi tải danh sách board: $e')));
    }
  }

  Map<String, dynamic>? _findEligible(String boardCode) {
    for (final row in _eligibleBoards) {
      if (row['board_code'].toString() == boardCode) return row;
    }
    return null;
  }

  Future<void> _confirmBatch() async {
    final startCode = _startController.text.trim();
    final endCode = _endController.text.trim();

    if (startCode.isEmpty || endCode.isEmpty) {
      await _showError('Vui lòng nhập cả mã board bắt đầu và kết thúc.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final startRange = await _resolveOrExplain(startCode);
      if (startRange == null || !mounted) return;
      final endRange = await _resolveOrExplain(endCode);
      if (endRange == null || !mounted) return;

      final startMin = startRange['min_id_board'] as int;
      final endMax = endRange['max_id_board'] as int;
      if (endMax < startMin) {
        await _showError(
          'Mã board kết thúc "$endCode" phải nằm sau (hoặc cùng vị trí) mã '
          'bắt đầu "$startCode" trong lô.',
        );
        return;
      }

      // Chỉ kiểm tra riêng 2 đầu là CHƯA đủ: getEligibleBoardsForBatch trả
      // về HỢP của mọi khoảng trống rời rạc (chưa thuộc đợt nào), nên nếu
      // lot có 2 khoảng trống tách biệt (vd 51-59 và 101-150, còn 60-100 đã
      // thuộc 1 đợt khác), mặc định điền sẵn "đầu=51, cuối=150" của app vẫn
      // khiến 2 đầu ĐỀU hợp lệ riêng lẻ - phải kiểm tra thêm cả khoảng ở
      // giữa có chồng lên đợt khác không.
      final overlaps = await _db.rangeOverlapsExistingBatch(
        widget.idLot,
        startMin,
        endMax,
        aoiMachine: _aoiMachine,
      );
      if (!mounted) return;
      if (overlaps) {
        await _showError(
          'Khoảng board từ "$startCode" đến "$endCode" chồng lên 1 đợt khác '
          'đã có (có thể do gộp 2 khoảng trống rời rạc lại thành 1 khoảng '
          'liên tục). Hãy thu hẹp lại hoặc tạo riêng từng khoảng.',
        );
        return;
      }

      final idBatch = await _db.createBoardBatch(
        idLot: widget.idLot,
        startBoardCode: startCode,
        endBoardCode: endCode,
        startIdBoard: startMin,
        endIdBoard: endMax,
        aoiMachine: _aoiMachine,
      );
      if (!mounted) return;
      context.pop(idBatch);
    } catch (e) {
      if (mounted) await _showError('Lỗi tạo đợt: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// Trả về range (min/max id_board) nếu [boardCode] hợp lệ để dùng làm biên
  /// đợt (tồn tại trong lot VÀ chưa thuộc đợt nào khác - theo đúng quyết định
  /// "chặn, báo lỗi rõ" khi gõ trùng mã đã thuộc đợt khác), `null` nếu không
  /// hợp lệ (đã tự hiện dialog lỗi rõ nguyên nhân).
  Future<Map<String, dynamic>?> _resolveOrExplain(String boardCode) async {
    final eligible = _findEligible(boardCode);
    if (eligible != null) return eligible;

    // Không có trong danh sách khả dụng - tra DB để báo đúng lý do.
    final anyMatch = await _db.resolveBoardCodeRange(
      widget.idLot,
      boardCode,
      aoiMachine: _aoiMachine,
    );
    if (!mounted) return null;
    if (anyMatch == null) {
      await _showError('Mã board "$boardCode" không có trong lô này.');
    } else {
      await _showError(
        'Mã board "$boardCode" đã thuộc 1 đợt khác (đang chạy hoặc đã xong) '
        'hoặc đã kiểm tra xong, không thể chọn lại.',
      );
    }
    return null;
  }

  Future<void> _showError(String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error, color: Colors.red, size: 48),
        title: const Text('Không thể tạo đợt'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Chọn đợt (khoảng board) cho lô này',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Giống SelectLotForModelScreen: back button của MainLayout
                  // không pop được route push() - cần nút Hủy riêng.
                  TextButton(
                    onPressed: () => context.pop(),
                    child: const Text('Hủy'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _isLoading ? null : _loadEligibleBoards,
                    icon: const Icon(FeatherIcons.refreshCw),
                    tooltip: 'Làm mới danh sách',
                    color: Colors.blue.shade600,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Máy chỉ tải được 1 số board hạn chế mỗi lần - chọn đúng '
                'khoảng board đang nạp lên máy. Mặc định đã điền sẵn toàn bộ '
                'board còn khả dụng, chỉ cần bấm Xác nhận nếu muốn xử lý hết.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _startController,
                      decoration: const InputDecoration(
                        labelText: 'Mã board bắt đầu',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _endController,
                      decoration: const InputDecoration(
                        labelText: 'Mã board kết thúc',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _eligibleBoards.isEmpty
                    ? _buildEmptyState()
                    : _buildBoardTable(),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _confirmBatch,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade500,
                    foregroundColor: Colors.white,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Xác nhận'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(FeatherIcons.package, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'Lô này không còn board nào khả dụng để tạo đợt mới',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => context.pop(),
            icon: const Icon(FeatherIcons.arrowLeft, size: 18),
            label: const Text('Quay lại'),
          ),
        ],
      ),
    );
  }

  Widget _buildBoardTable() {
    return SingleChildScrollView(
      child: DataTable(
        columnSpacing: 32,
        columns: const [
          DataColumn(
            label: Text(
              'Mã board',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          DataColumn(
            label: Text(
              'Số layer',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          DataColumn(
            label: Text(
              'Thao tác',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
        rows: _eligibleBoards.map((row) {
          final code = row['board_code'].toString();
          final isStart = _startController.text.trim() == code;
          final isEnd = _endController.text.trim() == code;
          return DataRow(
            color: (isStart || isEnd)
                ? WidgetStateProperty.all(Colors.blue.shade50)
                : null,
            cells: [
              DataCell(
                Text(
                  code,
                  style: TextStyle(
                    fontWeight: (isStart || isEnd)
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: (isStart || isEnd) ? Colors.blue.shade800 : null,
                  ),
                ),
              ),
              DataCell(Text('${row['layer_count'] ?? 1}')),
              DataCell(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton(
                      onPressed: () =>
                          setState(() => _startController.text = code),
                      child: const Text('Đặt làm đầu'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () =>
                          setState(() => _endController.text = code),
                      child: const Text('Đặt làm cuối'),
                    ),
                  ],
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}
