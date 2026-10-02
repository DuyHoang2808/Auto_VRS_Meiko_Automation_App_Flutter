import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/vrs_provider.dart';

/// Hiện popup khi vừa soi xong BOARD CUỐI CÙNG (không còn board kế tiếp).
///
/// Dùng chung cho cả Auto VRS (`_finishBoard`) lẫn VRS Thủ công
/// (`_completeBoardFromManual`) - 2 màn hình phải báo giống hệt nhau, người
/// vận hành đổi qua lại giữa 2 chế độ trong cùng 1 ca.
///
/// Trước đây chỉ có SnackBar (tự tắt sau vài giây) + banner nằm trong panel
/// bên phải: cả 2 đều dễ bỏ sót khi người vận hành đang nhìn bo trên bàn máy
/// chứ không nhìn màn hình, nên họ không biết đã hết board và phải làm gì
/// tiếp. Popup chặn hẳn, kèm luôn nút đi tới việc cần làm.
///
/// Không tự làm gì cả nếu vẫn còn board kế tiếp - gọi vô điều kiện sau khi
/// hoàn tất board là an toàn.
Future<void> showLastBoardDialog(BuildContext context) async {
  final vrs = Provider.of<VRSProvider>(context, listen: false);
  if (vrs.nextBoardAvailable) return;

  final lotFinished = vrs.lotFinished;
  final batchFinished = vrs.batchFinished;
  // Không rơi vào trạng thái nào trong 2 cái trên = chưa kết luận được gì
  // (vd board vừa xong nhưng provider chưa kịp cập nhật) - im lặng còn hơn
  // hiện popup sai.
  if (!lotFinished && !batchFinished) return;

  final lotCode = vrs.currentLotCode.isNotEmpty
      ? vrs.currentLotCode
      : vrs.currentLot;
  final batchRange = vrs.lastBatchStartCode.isNotEmpty
      ? '${vrs.lastBatchStartCode} → ${vrs.lastBatchEndCode}'
      : '';

  final wantNewBatch = await showDialog<bool>(
    context: context,
    // Người vận hành phải chủ động chọn: bấm ra ngoài đóng mất thì lại rơi
    // đúng vào cảnh "không biết phải làm gì tiếp" mà popup này sinh ra để chữa.
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: Icon(
        lotFinished ? FeatherIcons.check : FeatherIcons.list,
        size: 44,
        color: lotFinished ? Colors.green.shade600 : Colors.orange.shade700,
      ),
      title: Text(
        lotFinished
            ? 'Đã kiểm tra xong board cuối cùng của lô'
            : 'Đã kiểm tra xong board cuối cùng của đợt',
      ),
      content: Text(
        lotFinished
            ? 'Lô $lotCode đã kiểm tra hết board. Chờ máy AOI xuất thêm board '
                  'mới, hoặc chọn lô khác để tiếp tục.'
            : batchRange.isNotEmpty
            ? 'Đã kiểm tra hết đợt ($batchRange). Lô $lotCode vẫn còn board '
                  'chưa kiểm tra - chọn đợt mới để chạy lượt tiếp theo.'
            : 'Đã kiểm tra hết đợt đang chạy. Lô $lotCode vẫn còn board chưa '
                  'kiểm tra - chọn đợt mới để chạy lượt tiếp theo.',
        style: const TextStyle(fontSize: 14),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(lotFinished ? 'Đã hiểu' : 'Để sau'),
        ),
        if (!lotFinished)
          ElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(FeatherIcons.list, size: 16),
            label: const Text('Chọn đợt mới'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange.shade600,
              foregroundColor: Colors.white,
            ),
          ),
      ],
    ),
  );

  if (wantNewBatch != true || !context.mounted) return;

  // Điều hướng SAU KHI popup đã đóng (không push từ trong dialog) - push lồng
  // trong route của dialog thì màn chọn đợt hiện đè lên dialog và pop nhầm cấp.
  final idLot = int.tryParse(vrs.currentLot);
  if (idLot == null) return;
  final idBatch = await context.push<int>('/select-board-batch/$idLot');
  if (idBatch == null || !context.mounted) return;
  await vrs.refreshActiveBatch();
}
