// Hồi quy cho bug thật đã gặp 2026-09-16 ở "Sửa mã hàng"
// (select_model_screen.dart::_showEditSizesDialog): gõ chữ vào 1 trong 3 ô
// (line_size/space_size/url_gerber) rồi bấm Lưu/Hủy làm crash toàn app.
//
// Nguyên nhân (xác định bằng cách tái hiện + thu hẹp dần trong nhiều vòng
// thử-sai): Future của `showDialog()` hoàn tất NGAY khi `Navigator.pop()`
// được gọi - TRƯỚC KHI animation đóng dialog (mặc định của Material) chạy
// xong. Bản lỗi gốc tạo `TextEditingController` cục bộ rồi `dispose()` chúng
// NGAY sau `await showDialog(...)` - tại thời điểm đó `TextFormField` dùng
// controller đó vẫn còn gắn với 1 Element CHƯA unmount hẳn (đang giữa
// animation đóng); dispose controller lúc này làm 1 rebuild sau đó cố
// `addListener` vào controller đã dispose, ném "A TextEditingController was
// used after being disposed." (hoặc 1 trong vài assertion framework khác
// tuỳ đúng frame nào chạm vào, tất cả cùng 1 gốc race).
//
// Fix (đang dùng trong select_model_screen.dart thật): trễ dispose() lại
// (Future.delayed) qua khỏi thời lượng animation đóng dialog, thay vì
// dispose() ngay lập tức.
//
// Test này KHÔNG import trực tiếp select_model_screen.dart (cần
// LocalDatabaseService/Provider thật, không tiện mock trong 1 test thuần
// widget) - dựng lại ĐÚNG CẤU TRÚC dialog thật (Form + nhiều TextFormField +
// dispose controller trễ sau khi đóng dialog) để test vẫn đúng bản chất fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _EditDialogHost extends StatefulWidget {
  const _EditDialogHost();

  @override
  State<_EditDialogHost> createState() => _EditDialogHostState();
}

class _EditDialogHostState extends State<_EditDialogHost> {
  Future<void> _showEditDialog() async {
    final formKey = GlobalKey<FormState>();
    final lineSizeController = TextEditingController(text: '1.0');
    final spaceSizeController = TextEditingController(text: '1.0');
    final urlGerberController = TextEditingController();

    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sửa mã hàng'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: lineSizeController,
                validator: (v) => (v == null || v.isEmpty) ? 'x' : null,
              ),
              TextFormField(
                controller: spaceSizeController,
                validator: (v) => (v == null || v.isEmpty) ? 'x' : null,
              ),
              TextFormField(controller: urlGerberController),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    // Fix: trễ dispose qua khỏi animation đóng dialog - xem giải thích ở
    // đầu file. Nếu đổi lại thành dispose() ngay lập tức ở đây, test bên
    // dưới sẽ đỏ lại (đã tự xác nhận lúc điều tra bug).
    Future.delayed(const Duration(milliseconds: 300), () {
      lineSizeController.dispose();
      spaceSizeController.dispose();
      urlGerberController.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: _showEditDialog,
          child: const Text('Sửa'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'go chu vao o url_gerber roi bam Luu khong duoc crash (tre dispose controller)',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _EditDialogHost()));
      await tester.tap(find.text('Sửa'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextFormField).last,
        r'D:\Ps_Duy\Project\Qcamber-Meiko\bin\Jobs\23691025-250616-0004-nvq-aoi',
      );
      await tester.pump();

      await tester.tap(find.text('Lưu'));
      // pumpAndSettle() tự bơm frame lặp lại (bao gồm cả đợi Timer/
      // Future.delayed trong FakeAsync) tới khi không còn gì đang chờ, nên tự
      // bao trọn cả 300ms delay của fix mà không cần bơm thêm thủ công.
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );
}
