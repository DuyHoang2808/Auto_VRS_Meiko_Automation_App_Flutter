// Kiểm chứng thực nghiệm: khi 1 dialog (showDialog) có Focus(onKeyEvent:...)
// riêng chỉ xử lý Enter/Escape, phím KHÁC (vd ArrowRight) có "lọt" xuống
// Focus(onKeyEvent:...) của MÀN HÌNH DƯỚI (đã bị dialog che) hay không -
// đúng cấu trúc thật của manual_vrs_screen.dart/vrs_main_screen.dart.
//
// Bối cảnh (2026-09-17): 1 subagent review khẳng định phím CÓ lọt xuống
// (dựa trên suy luận lý thuyết về cách Flutter dispatch key event), nhưng 1
// subagent khác review file tương tự lại khẳng định KHÔNG lọt. Test này viết
// ra để phân xử bằng thực nghiệm thay vì tin theo suy luận: kết quả xác nhận
// KHÔNG lọt - dialog route nằm ở 1 nhánh Overlay khác (anh em, không phải con
// của Focus màn hình dưới), nên phím không handled trong dialog KHÔNG bao giờ
// bubble ngược sang Focus của route khác. Giữ lại test này như hồi quy: nếu
// sau này ai đó đổi cấu trúc dialog theo cách làm phím rò rỉ thật, test sẽ đỏ.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _HostScreen extends StatefulWidget {
  final VoidCallback onScreenArrowRight;
  const _HostScreen({required this.onScreenArrowRight});

  @override
  State<_HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<_HostScreen> {
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onScreenArrowRight();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _showDialog() async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter) {
            Navigator.pop(ctx, true);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.pop(ctx, false);
            return KeyEventResult.handled;
          }
          // Y HET code that: mọi phim khac (bao gom ArrowRight) tra ignored.
          return KeyEventResult.ignored;
        },
        child: AlertDialog(
          title: const Text('Xac nhan'),
          content: const Text('noi dung'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Huy'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Dong y'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: _showDialog,
            child: const Text('Mo dialog'),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'ArrowRight trong luc dialog dang mo co lot xuong Focus cua man hinh duoi khong',
    (tester) async {
      var screenArrowRightCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _HostScreen(
            onScreenArrowRight: () => screenArrowRightCount++,
          ),
        ),
      );

      // Nhan ArrowRight LUC CHUA mo dialog - phai tang bo dem (xac nhan
      // handler man hinh hoat dong dung, loai tru false-negative do setup sai).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        screenArrowRightCount,
        1,
        reason: 'Focus man hinh phai nhan phim khi chua co dialog nao mo',
      );

      // Mo dialog.
      await tester.tap(find.text('Mo dialog'));
      await tester.pumpAndSettle();
      expect(find.text('Xac nhan'), findsOneWidget);

      // Trong luc dialog dang mo, nhan ArrowRight (dialog KHONG xu ly phim
      // nay - tra ignored). Cau hoi: co tang screenArrowRightCount them lan
      // nua khong?
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(
        screenArrowRightCount,
        1,
        reason:
            'ArrowRight bấm trong lúc dialog đang mở KHÔNG được lọt xuống '
            'Focus của màn hình dưới - nếu số này tăng lên 2, nghĩa là '
            'pattern Focus-trong-dialog không còn cô lập được bàn phím nữa '
            '(có thể do đổi Flutter SDK hoặc đổi cấu trúc dialog) và '
            'manual_vrs_screen.dart/vrs_main_screen.dart cần được xem lại.',
      );

      // Dong dialog bang Enter, kiem tra dialog dong dung.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Xac nhan'), findsNothing);
    },
  );
}
