import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/feather_icons.dart';
import '../providers/aoi_machine_provider.dart';
import '../services/local_database_service.dart';

/// Dialog chọn máy AOI đang vận hành - gợi ý các tên máy đã từng ghi dữ liệu
/// (`SELECT DISTINCT aoi_machine`) + cho phép gõ tay (máy mới lắp, chưa có
/// board nào sẽ không có trong gợi ý). Tên phải khớp CHÍNH XÁC giá trị
/// `aoi_machine` trong aoi_ingest_config.yaml của máy đó, nếu không mọi danh
/// sách model/lot/board sẽ trống rỗng.
///
/// Dùng [AoiMachineDialog.show] - tự lưu lựa chọn vào [AoiMachineProvider]
/// khi xác nhận, trả về tên máy vừa chọn (hoặc `null` nếu huỷ). Nơi gọi tự
/// quyết định có cần gọi `VRSProvider.resetSelection()` hay không (khi tên
/// máy trả về KHÁC với lựa chọn trước đó).
class AoiMachineDialog extends StatefulWidget {
  /// false = bắt buộc chọn (lần đầu vào quy trình vận hành, chưa từng chọn
  /// máy nào) - ẩn nút Huỷ, không cho bấm ra ngoài để đóng.
  final bool canCancel;

  const AoiMachineDialog({super.key, this.canCancel = true});

  static Future<String?> show(BuildContext context, {bool canCancel = true}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: canCancel,
      builder: (_) => AoiMachineDialog(canCancel: canCancel),
    );
  }

  @override
  State<AoiMachineDialog> createState() => _AoiMachineDialogState();
}

class _AoiMachineDialogState extends State<AoiMachineDialog> {
  final TextEditingController _controller = TextEditingController();
  List<String> _knownMachines = [];
  bool _isLoading = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final current = context.read<AoiMachineProvider>().selectedMachine;
    if (current != null) _controller.text = current;
    _loadKnownMachines();
  }

  Future<void> _loadKnownMachines() async {
    try {
      final machines = await LocalDatabaseService().getKnownAoiMachines();
      if (!mounted) return;
      setState(() {
        _knownMachines = machines;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _confirm() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _errorText = 'Vui lòng chọn hoặc nhập tên máy');
      return;
    }
    await context.read<AoiMachineProvider>().selectMachine(value);
    if (!mounted) return;
    Navigator.of(context).pop(value);
  }

  @override
  void dispose() {
    // Không có race dispose-ngay-sau-showDialog ở đây (khác select_model_screen
    // ::_showEditSizesDialog) - controller không được ĐỌC lại sau khi dialog
    // đóng (Navigator.pop chỉ trả String đã lấy TRƯỚC đó qua .text.trim()),
    // nên dispose() ngay tại đây an toàn.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.canCancel,
      child: AlertDialog(
        icon: const Icon(
          FeatherIcons.monitor,
          size: 40,
          color: Color(0xFF1E40AF),
        ),
        title: const Text('Chọn máy AOI'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Chọn đúng máy AOI đang vận hành - danh sách mã hàng/lô/board '
                'sẽ chỉ hiện dữ liệu của máy này. Có thể đổi lại bất cứ lúc '
                'nào ở góc trên bên phải.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Tên máy (vd: YMZ-1, YMZ-2, YMZ-3)',
                  border: const OutlineInputBorder(),
                  errorText: _errorText,
                ),
                onChanged: (_) {
                  if (_errorText != null) setState(() => _errorText = null);
                },
                onSubmitted: (_) => _confirm(),
              ),
              const SizedBox(height: 12),
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (_knownMachines.isNotEmpty) ...[
                const Text(
                  'Máy đã từng ghi dữ liệu:',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _knownMachines
                      .map(
                        (m) => ChoiceChip(
                          label: Text(m),
                          selected: _controller.text.trim() == m,
                          onSelected: (_) => setState(() {
                            _controller.text = m;
                            _errorText = null;
                          }),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (widget.canCancel)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Hủy'),
            ),
          ElevatedButton(onPressed: _confirm, child: const Text('Xác nhận')),
        ],
      ),
    );
  }
}
