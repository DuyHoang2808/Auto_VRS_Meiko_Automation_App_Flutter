// Kiểm chứng các helper suy ra tiến độ soi từ DB.
//
// Đây là phần load-bearing của việc sửa lỗi "quay lại Auto VRS thì soi lại từ
// lỗi #1": tiến độ được suy ra từ cột `judgement` trong DB thay vì từ biến đếm
// trong state của widget (state đó mất sạch khi màn hình bị dispose lúc chuyển
// sang tab VRS thủ công).
import 'package:flutter_test/flutter_test.dart';
import 'package:autovrs_app/services/local_database_service.dart';

/// 1 dòng tbDefect giả lập. `judgement == null` = lỗi mới do AOI_Ingest chèn.
Map<String, dynamic> defect({String? judgement, String? type, String? aiType}) =>
    {'judgement': judgement, 'type': type, 'ai_type': aiType};

void main() {
  group('isDefectJudged', () {
    test('lỗi mới từ AOI_Ingest (judgement NULL) là chưa phán định', () {
      expect(isDefectJudged(defect()), isFalse);
    });

    test('chuỗi rỗng / toàn khoảng trắng vẫn là chưa phán định', () {
      expect(isDefectJudged(defect(judgement: '')), isFalse);
      expect(isDefectJudged(defect(judgement: '   ')), isFalse);
    });

    test('OK và NG đều tính là đã phán định', () {
      expect(isDefectJudged(defect(judgement: 'OK')), isTrue);
      expect(isDefectJudged(defect(judgement: 'NG')), isTrue);
    });
  });

  group('firstUnjudgedDefectIndex', () {
    test('board mới chưa soi -> bắt đầu từ lỗi đầu tiên', () {
      expect(
        firstUnjudgedDefectIndex([defect(), defect(), defect()]),
        0,
      );
    });

    test('đã soi 2 lỗi rồi dừng -> soi tiếp từ lỗi thứ 3, không quay lại #1', () {
      final defects = [
        defect(judgement: 'OK'),
        defect(judgement: 'NG'),
        defect(),
        defect(),
      ];
      expect(firstUnjudgedDefectIndex(defects), 2);
    });

    test('phán định hết -> trả -1 (không được soi lại lỗi nào)', () {
      final defects = [defect(judgement: 'OK'), defect(judgement: 'NG')];
      expect(firstUnjudgedDefectIndex(defects), -1);
    });

    test('board 0 lỗi -> trả -1', () {
      expect(firstUnjudgedDefectIndex([]), -1);
    });

    test(
      'VRS thủ công phán định KHÔNG theo thứ tự -> vẫn lấy lỗi chưa phán định '
      'đầu tiên, bỏ qua lỗi đã phán định ở giữa',
      () {
        // Màn thủ công cho nhảy tới lỗi bất kỳ, nên lỗi #3 có thể được phán
        // định trước #1. Con trỏ tiến độ kiểu "đếm số lỗi đã xong" sẽ soi lại
        // #3; hàm này thì không.
        final defects = [
          defect(),
          defect(),
          defect(judgement: 'NG'),
          defect(),
        ];
        expect(firstUnjudgedDefectIndex(defects), 0);
      },
    );

    test('đúng kịch bản bug được báo: thủ công phán định 1 lỗi giữa lượt soi', () {
      // Auto soi xong lỗi #1 -> operator bấm Dừng -> sang thủ công phán định
      // lỗi #2 -> quay lại Auto bấm "Bắt đầu".
      final defects = [
        defect(judgement: 'OK'), // auto đã soi
        defect(judgement: 'NG'), // thủ công vừa phán định
        defect(),
        defect(),
      ];
      // Phải soi tiếp từ lỗi #3, KHÔNG lặp lại #1 và #2.
      expect(firstUnjudgedDefectIndex(defects), 2);
    });
  });

  group('defectTypeForDisplay', () {
    test(
      'lỗi ĐÃ soi -> hiện tên lỗi AI, không hiện mã số thô của AOI',
      () {
        // AOI ghi `type` là mã SỐ (str(type_code), vd "2") và không có bảng ánh
        // xạ sang tên lỗi, nên hiện thẳng ra thì người vận hành không đọc được.
        expect(
          defectTypeForDisplay(defect(type: '2', aiType: 'chamkim')),
          'chamkim',
        );
      },
    );

    test('lỗi CHƯA soi (chưa có ai_type) -> fallback mã AOI', () {
      expect(defectTypeForDisplay(defect(type: '2')), '2');
      expect(defectTypeForDisplay(defect(type: '2', aiType: '')), '2');
    });

    test('không có cả hai -> null (không trả chuỗi rỗng)', () {
      expect(defectTypeForDisplay(defect()), isNull);
      expect(defectTypeForDisplay(defect(type: '', aiType: '')), isNull);
    });

    test("lỗi phán định OK -> hiện 'none' của AI, không phải mã AOI", () {
      // 'none' được _getDefectDisplayName dịch thành 'Khác'; quan trọng là
      // KHÔNG rơi về mã số AOI vô nghĩa.
      expect(
        defectTypeForDisplay(defect(type: '5', aiType: 'none')),
        'none',
      );
    });
  });
}
