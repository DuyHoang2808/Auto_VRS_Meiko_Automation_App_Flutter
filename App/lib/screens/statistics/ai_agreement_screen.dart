import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/aoi_machine_provider.dart';
import '../../services/local_database_service.dart';

/// Báo cáo độ khớp giữa phán định CUỐI của người vận hành (`judgement`) và
/// phán định riêng của AI (`ai_verdict`) - xem LocalDatabaseService.
/// getAiHumanAgreementStats. Mục đích: theo dõi AI đang báo THỪA (báo NG mà
/// người xác nhận OK) hay báo THIẾU (báo OK mà người xác nhận NG) bao nhiêu
/// qua thời gian, lọc được theo lô và khoảng ngày.
class AiAgreementScreen extends StatefulWidget {
  const AiAgreementScreen({super.key});

  @override
  State<AiAgreementScreen> createState() => _AiAgreementScreenState();
}

class _AiAgreementScreenState extends State<AiAgreementScreen> {
  final LocalDatabaseService _db = LocalDatabaseService();

  List<Map<String, dynamic>> _lots = [];
  int? _selectedLotId; // null = tất cả các lô
  // Ô tìm lô do Autocomplete tạo ra - giữ tham chiếu để nút "Tất cả các lô"
  // xoá được nội dung đang gõ (xem _buildLotSearch/fieldViewBuilder).
  TextEditingController? _lotSearchController;

  List<Map<String, dynamic>> _models = [];
  int? _selectedModelId; // null = tất cả các model

  List<String> _knownMachines = [];
  // Mặc định theo máy AOI đang chọn ở top bar (đồng bộ với cách mọi màn
  // hình khác trong app đã lọc theo máy) - vẫn cho đổi sang "Tất cả các
  // máy" hoặc máy khác ngay tại đây để xem báo cáo liên máy.
  String? _selectedMachine;

  DateTime? _fromDate;
  DateTime? _toDate;

  bool _isLoading = true;
  Map<String, dynamic>? _stats;

  @override
  void initState() {
    super.initState();
    _selectedMachine = context.read<AoiMachineProvider>().selectedMachine;
    _loadFiltersThenStats();
  }

  /// Tải cả 3 tầng lọc (máy -> model -> lô) theo đúng thứ tự phụ thuộc rồi
  /// mới tính thống kê - dùng lúc mở màn lần đầu.
  Future<void> _loadFiltersThenStats() async {
    setState(() => _isLoading = true);
    try {
      final knownMachines = await _db.getKnownAoiMachines();
      final models = await _db.getAllModels(aoiMachine: _selectedMachine);
      final lots = await _db.getLotsForReport(
        idModel: _selectedModelId,
        aoiMachine: _selectedMachine,
      );
      if (!mounted) return;
      setState(() {
        _knownMachines = knownMachines;
        _models = models;
        _lots = lots;
      });
    } catch (e) {
      debugPrint('Lỗi tải bộ lọc (máy/model/lô): $e');
    }
    await _loadStats();
  }

  /// Đổi máy AOI -> danh sách model VÀ lô đều phải tải lại theo đúng máy
  /// mới (model/lô của máy cũ có thể không liên quan gì tới máy mới) - reset
  /// luôn lựa chọn model/lô đang chọn vì rất có thể không còn hợp lệ.
  Future<void> _onMachineChanged(String? value) async {
    setState(() {
      _selectedMachine = value;
      _selectedModelId = null;
      _selectedLotId = null;
    });
    _lotSearchController?.clear();

    setState(() => _isLoading = true);
    try {
      final models = await _db.getAllModels(aoiMachine: _selectedMachine);
      final lots = await _db.getLotsForReport(
        idModel: _selectedModelId,
        aoiMachine: _selectedMachine,
      );
      if (!mounted) return;
      setState(() {
        _models = models;
        _lots = lots;
      });
    } catch (e) {
      debugPrint('Lỗi tải model/lô theo máy: $e');
    }
    await _loadStats();
  }

  /// Đổi model -> chỉ danh sách LÔ cần tải lại (máy giữ nguyên) - reset lựa
  /// chọn lô đang chọn vì có thể không thuộc model mới.
  Future<void> _onModelChanged(int? value) async {
    setState(() {
      _selectedModelId = value;
      _selectedLotId = null;
    });
    _lotSearchController?.clear();

    setState(() => _isLoading = true);
    try {
      final lots = await _db.getLotsForReport(
        idModel: _selectedModelId,
        aoiMachine: _selectedMachine,
      );
      if (!mounted) return;
      setState(() => _lots = lots);
    } catch (e) {
      debugPrint('Lỗi tải lô theo model: $e');
    }
    await _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _isLoading = true);
    try {
      // Bao trọn hết ngày "đến" (date picker chỉ cho giờ 00:00:00) - nếu
      // không, mọi lỗi phán định TRONG ngày đó (trừ đúng lúc nửa đêm) sẽ bị
      // loại khỏi khoảng lọc.
      final toDateInclusive = _toDate == null
          ? null
          : DateTime(
              _toDate!.year,
              _toDate!.month,
              _toDate!.day,
              23,
              59,
              59,
              999,
            );
      final stats = await _db.getAiHumanAgreementStats(
        idLot: _selectedLotId,
        idModel: _selectedModelId,
        fromDate: _fromDate,
        toDate: toDateInclusive,
        aoiMachine: _selectedMachine,
      );
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Lỗi tải thống kê: $e')));
    }
  }

  String _lotLabel(Map<String, dynamic> lot) =>
      lot['lot_code']?.toString() ?? 'LOT-${lot['id_lot']}';

  String _modelLabel(Map<String, dynamic> model) =>
      model['name']?.toString() ?? 'Model ${model['id_model']}';

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = (isFrom ? _fromDate : _toDate) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _fromDate = picked;
      } else {
        _toDate = picked;
      }
    });
    await _loadStats();
  }

  void _clearDates() {
    setState(() {
      _fromDate = null;
      _toDate = null;
    });
    _loadStats();
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
              const Text(
                'Độ khớp phán định AI vs Người',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'So sánh phán định cuối cùng của người vận hành với phán '
                'định riêng của AI cho cùng 1 lỗi - chỉ tính lỗi đã phán '
                'định VÀ đã từng chạy qua AI.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 20),
              _buildFilterRow(),
              const SizedBox(height: 24),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildResult(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterRow() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(width: 220, child: _buildMachineDropdown()),
        SizedBox(width: 360, child: _buildModelDropdown()),
        SizedBox(width: 260, child: _buildLotSearch()),
        if (_selectedLotId != null)
          TextButton.icon(
            onPressed: () {
              _lotSearchController?.clear();
              setState(() => _selectedLotId = null);
              _loadStats();
            },
            icon: const Icon(Icons.clear, size: 16),
            label: const Text('Tất cả các lô'),
          ),
        OutlinedButton.icon(
          onPressed: () => _pickDate(isFrom: true),
          icon: const Icon(Icons.calendar_today, size: 16),
          label: Text(
            _fromDate == null ? 'Từ ngày' : 'Từ ${_formatDate(_fromDate!)}',
          ),
        ),
        OutlinedButton.icon(
          onPressed: () => _pickDate(isFrom: false),
          icon: const Icon(Icons.calendar_today, size: 16),
          label: Text(
            _toDate == null ? 'Đến ngày' : 'Đến ${_formatDate(_toDate!)}',
          ),
        ),
        if (_fromDate != null || _toDate != null)
          TextButton.icon(
            onPressed: _clearDates,
            icon: const Icon(Icons.clear, size: 16),
            label: const Text('Bỏ lọc ngày'),
          ),
        IconButton(
          onPressed: _isLoading ? null : _loadStats,
          icon: const Icon(Icons.refresh),
          tooltip: 'Làm mới',
        ),
      ],
    );
  }

  /// Dropdown chọn máy AOI - lô/board có thể bị nhiều máy dùng chung (xem
  /// AoiMachineProvider), nên báo cáo cần lọc đúng máy chứ không gộp lẫn.
  /// "Tất cả các máy" (value null) để xem báo cáo liên máy khi cần.
  Widget _buildMachineDropdown() {
    // `initialValue`/`value` của DropdownButtonFormField BẮT BUỘC phải khớp
    // đúng 1 item trong `items`, kể cả ở khung hình ĐẦU TIÊN - _knownMachines
    // chỉ lấy từ DISTINCT aoi_machine của board ĐÃ CÓ trong DB, nên máy đang
    // chọn (vd đang tải dở lúc _knownMachines còn rỗng, hoặc máy mới thêm
    // chưa có board nào) có thể không nằm trong đó -> crash "There should be
    // exactly one item with value". Luôn chèn thêm máy đang chọn vào danh
    // sách item nếu nó chưa có sẵn, để không bao giờ rơi vào tình huống đó.
    final machineOptions = <String>{
      ..._knownMachines,
      if (_selectedMachine != null) _selectedMachine!,
    }.toList();

    return DropdownButtonFormField<String?>(
      initialValue: _selectedMachine,
      // isExpanded: bắt buộc phải có khi item có thể dài hơn bề rộng ô chọn
      // - thiếu nó, Text bên trong Row của nút chọn tràn ra ngoài, ném lỗi
      // "A RenderFlex overflowed" (khung vàng đen quen thuộc) thay vì co lại.
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Máy AOI',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('Tất cả các máy', overflow: TextOverflow.ellipsis),
        ),
        ...machineOptions.map(
          (m) => DropdownMenuItem<String?>(
            value: m,
            child: Text(m, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: _onMachineChanged,
    );
  }

  /// Dropdown chọn model - danh sách đã được lọc theo đúng máy AOI đang chọn
  /// (xem _onMachineChanged/getAllModels(aoiMachine:...)), đứng giữa Máy và
  /// Lô theo đúng thứ tự phụ thuộc máy -> model -> lô.
  Widget _buildModelDropdown() {
    // Cùng lý do phòng thủ như _buildMachineDropdown - đảm bảo model đang
    // chọn luôn có mặt trong items dù _models có tải kịp hay chưa.
    final modelIds = <int>{
      ..._models.map((m) => m['id_model'] as int),
      if (_selectedModelId != null) _selectedModelId!,
    };
    final modelOptions = modelIds
        .map(
          (id) => _models.firstWhere(
            (m) => m['id_model'] == id,
            orElse: () => {'id_model': id},
          ),
        )
        .toList();

    return DropdownButtonFormField<int?>(
      initialValue: _selectedModelId,
      // Tên model có thể dài hơn nhiều so với tên máy - isExpanded +
      // overflow: ellipsis là bắt buộc để không tràn chữ ra ngoài (xem
      // ghi chú ở _buildMachineDropdown).
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Model',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem<int?>(
          value: null,
          child: Text('Tất cả các model', overflow: TextOverflow.ellipsis),
        ),
        ...modelOptions.map(
          (m) => DropdownMenuItem<int?>(
            value: m['id_model'] as int,
            child: Text(_modelLabel(m), overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: _onModelChanged,
    );
  }

  /// Ô tìm lô theo tên (gõ để lọc gợi ý) thay cho dropdown liệt kê hết mọi
  /// lô - danh sách lô thực tế có thể rất dài, khó tìm bằng cách cuộn.
  Widget _buildLotSearch() {
    return Autocomplete<Map<String, dynamic>>(
      displayStringForOption: _lotLabel,
      optionsBuilder: (textEditingValue) {
        final query = textEditingValue.text.trim().toLowerCase();
        if (query.isEmpty) return _lots;
        return _lots.where(
          (lot) => _lotLabel(lot).toLowerCase().contains(query),
        );
      },
      onSelected: (lot) {
        setState(() => _selectedLotId = lot['id_lot'] as int);
        _loadStats();
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        _lotSearchController = controller;
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: const InputDecoration(
            labelText: 'Tìm lô (gõ mã lô)...',
            border: OutlineInputBorder(),
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
          ),
        );
      },
    );
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Widget _buildResult() {
    final stats = _stats;
    if (stats == null) return const SizedBox.shrink();

    final total = stats['total'] as int;
    if (total == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.info_outline, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              'Chưa có đủ dữ liệu để so sánh trong phạm vi đang lọc',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            Text(
              'Cần lỗi đã được người phán định VÀ đã từng chạy qua AI '
              '(có cả judgement lẫn ai_verdict).',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final agree = stats['agree'] as int;
    final aiNgHumanOk = stats['aiNgHumanOk'] as int;
    final aiOkHumanNg = stats['aiOkHumanNg'] as int;
    final agreeRate = agree / total * 100;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Text(
                  '${agreeRate.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Độ khớp tổng ($agree/$total lỗi trùng phán định)',
                  style: TextStyle(fontSize: 13, color: Colors.blue.shade900),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _buildMismatchRow(
            label: 'AI báo NG nhưng người xác nhận OK',
            sub: 'AI báo lỗi THỪA (false positive) - có thể AI quá nhạy',
            count: aiNgHumanOk,
            total: total,
            color: Colors.orange,
          ),
          const SizedBox(height: 12),
          _buildMismatchRow(
            label: 'AI báo OK nhưng người xác nhận NG',
            sub:
                'AI báo lỗi THIẾU (false negative) - AI có thể bỏ sót lỗi thật',
            count: aiOkHumanNg,
            total: total,
            color: Colors.red,
          ),
        ],
      ),
    );
  }

  /// Chỉ hiển thị số liệu - KHÔNG mở ảnh.
  ///
  /// Từng có bản bấm vào để xem lại lưới ảnh của đúng nhóm lệch đó, đã gỡ bỏ
  /// 2026-09-29 vì giải mã hàng trăm ảnh AOI (mỗi tấm vài MB) làm cả app giật.
  /// Việc xem lại ảnh nay tách hẳn sang công cụ rời `VRS_Review` (Python +
  /// PySide6, đọc cùng file autovrs.db ở chế độ chỉ đọc) để máy đang chạy dây
  /// chuyền không phải gánh thêm.
  Widget _buildMismatchRow({
    required String label,
    required String sub,
    required int count,
    required int total,
    required Color color,
  }) {
    final pct = total > 0 ? count / total * 100 : 0.0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          Text(
            '$count (${pct.toStringAsFixed(1)}%)',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
