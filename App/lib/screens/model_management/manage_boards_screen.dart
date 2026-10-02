import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/aoi_machine_provider.dart';
import '../../services/local_database_service.dart';

/// Màn hình xoá từng board (chưa xử lý) trong 1 lot - đẩy sang từ
/// SelectModelScreen (nút "Quản lý board" ở mỗi hàng mã hàng, yêu cầu xác
/// thực Admin trước) -> SelectLotForModelScreen (chọn lot) -> màn này.
///
/// KHÔNG dùng chung luồng chọn model/lot vận hành (setCurrentModelAndLot +
/// PlcGatewayService.selectProduct) - đây thuần tuý là công cụ quản lý dữ
/// liệu, không được có tác dụng phụ đổi mã hàng đang chạy trên PLC Gateway.
///
/// Chỉ cho xoá board đang pending (chưa hoàn tất) VÀ chưa thuộc đợt nào -
/// xem LocalDatabaseService.deletePendingBoard để biết lý do.
class ManageBoardsScreen extends StatefulWidget {
  final int idLot;

  const ManageBoardsScreen({super.key, required this.idLot});

  @override
  State<ManageBoardsScreen> createState() => _ManageBoardsScreenState();
}

class _ManageBoardsScreenState extends State<ManageBoardsScreen> {
  final LocalDatabaseService _db = LocalDatabaseService();
  List<Map<String, dynamic>> _boards = [];
  bool _isLoading = true;
  // Mã board đang xoá dở (disable đúng nút đó, không khoá cả màn hình) -
  // null nếu không có thao tác xoá nào đang chạy.
  String? _deletingCode;

  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  /// Máy AOI đang chọn - board_code có thể trùng giữa 2 máy dùng chung lô,
  /// xem local_database_service.dart.
  String? get _aoiMachine => context.read<AoiMachineProvider>().selectedMachine;

  Future<void> _loadBoards() async {
    setState(() => _isLoading = true);
    try {
      final boards = await _db.getPendingBoardsForLotManagement(
        widget.idLot,
        aoiMachine: _aoiMachine,
      );
      if (!mounted) return;
      setState(() {
        _boards = boards;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Lỗi tải danh sách board: $e')));
    }
  }

  Future<void> _deleteBoard(Map<String, dynamic> row) async {
    final code = row['board_code'].toString();
    final layerCount = row['layer_count'] ?? 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: Colors.orange,
          size: 48,
        ),
        title: const Text('Xác nhận xoá board'),
        content: Text(
          'Xoá board "$code" ($layerCount dòng layer/mặt) và TOÀN BỘ lỗi đã '
          'ghi nhận của board này?\n\n'
          'Thao tác KHÔNG THỂ hoàn tác. Chỉ nên dùng cho board bị ghi sai/'
          'thừa - board đã kiểm tra xong sẽ không xoá được.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingCode = code);
    try {
      await _db.deletePendingBoard(widget.idLot, code, aoiMachine: _aoiMachine);
      if (!mounted) return;
      await _loadBoards();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã xoá board "$code"'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is StateError ? e.message : 'Lỗi khi xoá board: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _deletingCode = null);
    }
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
                      'Quản lý / xoá board trong lô',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // MainLayout's top-bar back button không pop() được route đã
                  // push() (xem NavigationProvider) - cần nút Hủy riêng, giống
                  // select_lot_for_model_screen.dart/select_board_batch_screen.dart.
                  TextButton(
                    onPressed: () => context.pop(),
                    child: const Text('Đóng'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _isLoading ? null : _loadBoards,
                    icon: const Icon(FeatherIcons.refreshCw),
                    tooltip: 'Làm mới danh sách',
                    color: Colors.blue.shade600,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Chỉ xoá được board CHƯA kiểm tra xong và CHƯA thuộc đợt nào. '
                'Board đang "Trong đợt" phải chờ đợt đó hoàn tất (hoặc huỷ đợt) '
                'trước khi xoá được.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _boards.isEmpty
                    ? _buildEmptyState()
                    : _buildBoardTable(),
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
            'Không còn board nào đang chờ xử lý trong lô này',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
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
              'Trạng thái',
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
        rows: _boards.map((row) {
          final code = row['board_code'].toString();
          final inBatch = (row['in_batch'] as int? ?? 0) != 0;
          final isDeleting = _deletingCode == code;
          return DataRow(
            cells: [
              DataCell(Text(code)),
              DataCell(Text('${row['layer_count'] ?? 1}')),
              DataCell(
                inBatch
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.blue.shade200),
                        ),
                        child: Text(
                          'Trong đợt',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blue.shade800,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : const Text('-'),
              ),
              DataCell(
                isDeleting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        tooltip: inBatch
                            ? 'Board đang thuộc 1 đợt - không thể xoá'
                            : 'Xoá board này',
                        icon: Icon(
                          Icons.delete,
                          color: inBatch ? Colors.grey.shade400 : Colors.red,
                        ),
                        onPressed: inBatch || _deletingCode != null
                            ? null
                            : () => _deleteBoard(row),
                      ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}
