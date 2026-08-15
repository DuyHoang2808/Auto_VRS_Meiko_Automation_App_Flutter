import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import '../../services/local_database_service.dart';

/// Màn hình chọn lot cho 1 model đã chọn (đẩy sang từ SelectModelScreen sau
/// khi vận hành viên xác nhận model) - chỉ liệt kê lot CHƯA xử lý hết board,
/// xem LocalDatabaseService.getSelectableLotsForModel. Trả `id_lot` đã chọn
/// qua context.pop(idLot); back tay (không chọn) trả `null`.
class SelectLotForModelScreen extends StatefulWidget {
  final String modelId;

  const SelectLotForModelScreen({super.key, required this.modelId});

  @override
  State<SelectLotForModelScreen> createState() =>
      _SelectLotForModelScreenState();
}

class _SelectLotForModelScreenState extends State<SelectLotForModelScreen> {
  final LocalDatabaseService _db = LocalDatabaseService();
  List<Map<String, dynamic>> _lots = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLots();
  }

  Future<void> _loadLots() async {
    setState(() => _isLoading = true);
    try {
      final lots = await _db.getSelectableLotsForModel(widget.modelId);
      if (!mounted) return;
      setState(() {
        _lots = lots;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Lỗi tải danh sách lô: $e')));
    }
  }

  String _lotLabel(Map<String, dynamic> lot) =>
      lot['lot_code']?.toString() ?? 'LOT-${lot['id_lot']}';

  Future<void> _selectLot(Map<String, dynamic> lot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xác nhận lựa chọn'),
        content: Text('Bạn có chắc chắn muốn xử lý lô ${_lotLabel(lot)}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Xác nhận'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    context.pop(lot['id_lot'] as int);
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
                  Expanded(
                    child: Text(
                      'Chọn lô cho mã hàng ${widget.modelId}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // MainLayout's top-bar back button chạy qua
                  // NavigationProvider (stack view-history riêng, tách biệt
                  // GoRouter) - không thật sự pop() được route đã push() như
                  // màn này, nên phải tự có nút Hủy riêng (giống
                  // add_model_screen.dart) - nếu không, model không có lot
                  // nào sẽ bị KẸT không thoát ra được để chọn model khác.
                  TextButton(
                    onPressed: () => context.pop(),
                    child: const Text('Hủy'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _isLoading ? null : _loadLots,
                    icon: const Icon(FeatherIcons.refreshCw),
                    tooltip: 'Làm mới danh sách',
                    color: Colors.blue.shade600,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _lots.isEmpty
                    ? _buildEmptyState()
                    : _buildLotTable(),
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
            'Chưa có lô nào đang chờ xử lý cho mã hàng này',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            'AOI ghi lô mới ở nền, hoặc mọi lô hiện có đã xử lý xong hết - '
            'thử bấm làm mới',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => context.pop(),
            icon: const Icon(FeatherIcons.arrowLeft, size: 18),
            label: const Text('Chọn mã hàng khác'),
          ),
        ],
      ),
    );
  }

  Widget _buildLotTable() {
    return SingleChildScrollView(
      child: DataTable(
        columnSpacing: 40,
        columns: const [
          DataColumn(
            label: Text('Mã Lô', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          DataColumn(
            label: Text(
              'Tổng số bo',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          DataColumn(
            label: Text(
              'Bo còn chưa xử lý',
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
        rows: _lots.map((lot) {
          return DataRow(
            cells: [
              DataCell(
                Text(
                  _lotLabel(lot),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              DataCell(Text('${lot['actual_boards'] ?? 0}')),
              DataCell(Text('${lot['pending_boards'] ?? 0}')),
              DataCell(
                ElevatedButton(
                  onPressed: () => _selectLot(lot),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade500,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Chọn'),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}
