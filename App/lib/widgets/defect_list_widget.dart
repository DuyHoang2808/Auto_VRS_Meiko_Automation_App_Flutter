import 'package:flutter/material.dart';
import '../services/local_database_service.dart';

/// A reusable widget that shows the list of defects for a given board id.
/// This widget caches the Future so that the DB is not queried on every rebuild,
/// preventing a loading flicker when parent widgets rebuild frequently.
class DefectListWidget extends StatefulWidget {
  final int? boardId;
  final double height;

  /// A simple token that parents can bump to force the widget to reload
  /// its cached Future from the database. Increment this to refresh.
  final int reloadToken;

  /// id_defect của lỗi đang được xử lý (PLC di chuyển/chụp/AI) ngay lúc
  /// này, nếu có - hiện chấm màu xanh dương cho lỗi này, bất kể judgement
  /// đã lưu trong DB là gì (đang xử lý lại/soi lại thì vẫn ưu tiên hiện
  /// "đang xử lý" hơn là kết quả cũ).
  final int? processingDefectId;

  const DefectListWidget({
    super.key,
    required this.boardId,
    this.height = 220,
    this.reloadToken = 0,
    this.processingDefectId,
  });

  @override
  State<DefectListWidget> createState() => _DefectListWidgetState();
}

class _DefectListWidgetState extends State<DefectListWidget> {
  Future<List<Map<String, dynamic>>>? _defectsFuture;
  final LocalDatabaseService _db = LocalDatabaseService();

  @override
  void initState() {
    super.initState();
    _prepareFuture();
  }

  @override
  void didUpdateWidget(covariant DefectListWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Recreate the future when board changes or when parent bumps the reloadToken
    if (oldWidget.boardId != widget.boardId ||
        oldWidget.reloadToken != widget.reloadToken) {
      _prepareFuture();
    }
  }

  void _prepareFuture() {
    if (widget.boardId == null) {
      _defectsFuture = null;
    } else {
      _defectsFuture = _db.getDefectsByBoard(widget.boardId!);
    }
  }

  String _getDefectDisplayName(String technicalName) {
    switch (technicalName.toLowerCase()) {
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
        return 'Nguoi';
      default:
        return technicalName;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_defectsFuture == null) {
      return DefaultTextStyle.merge(
        style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.65)),
        child: Container(
          height: widget.height,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outlineVariant, width: 1),
          ),
          child: const Center(child: Text('Chua co bo duoc chon')),
        ),
      );
    }

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _defectsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.outlineVariant, width: 1),
            ),
            child: const Center(child: CircularProgressIndicator()),
          );
        }

        final defects = snapshot.data;
        if (defects == null || defects.isEmpty) {
          return DefaultTextStyle.merge(
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.65),
            ),
            child: Container(
              height: widget.height,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant, width: 1),
              ),
              child: const Center(child: Text('Khong tim thay loi nao')),
            ),
          );
        }

        return Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outlineVariant, width: 1),
          ),
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: defects.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final d = defects[index];
              final type = (d['type'] ?? '').toString();
              final judgement = (d['judgement'] ?? 'Chua xac dinh').toString();
              final time = (d['time'] ?? '').toString();
              final coords = (d['coordinates'] ?? '').toString();
              final defectId = d['id_defect'];
              final isProcessing = widget.processingDefectId != null &&
                  defectId == widget.processingDefectId;
              final statusColor = isProcessing
                  ? Colors.blue
                  : judgement.toUpperCase() == 'OK'
                      ? Colors.green
                      : judgement.toUpperCase() == 'NG'
                          ? Colors.red
                          : colorScheme.outlineVariant;

              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                title: Text(_getDefectDisplayName(type)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Phan dinh: $judgement'),
                    if (time.isNotEmpty)
                      Text(
                        'Thoi gian: $time',
                        style: const TextStyle(fontSize: 12),
                      ),
                    if (coords.isNotEmpty)
                      Text(
                        'Toa do: $coords',
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
                trailing: Text('#${d['id_defect'] ?? (index + 1)}'),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: Text(
                        'Chi tiet loi #${d['id_defect'] ?? (index + 1)}',
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Loai: ${_getDefectDisplayName(type)}'),
                          const SizedBox(height: 8),
                          Text('Phan dinh: $judgement'),
                          if (time.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text('Thoi gian: $time'),
                          ],
                          if (coords.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text('Toa do: $coords'),
                          ],
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Dong'),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}
