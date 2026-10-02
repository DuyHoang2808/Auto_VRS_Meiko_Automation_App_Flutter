// Backend chỉ trả TOP-N lỗi theo confidence trong `detections[]`
// (`max_defects_drawn` = 3 trong BE_tensorRT/ai_config.yml) nhưng tính
// `system_verdict` trên TẤT CẢ lỗi tìm được. Khi lỗi gây ra NG có confidence
// thấp hơn N lỗi verdict=OK khác, nó KHÔNG nằm trong `detections[]` - app lọc
// detections theo verdict=='NG' sẽ chẳng thấy gì và hiện "NG / Không phát
// hiện lỗi", đồng thời ghi `ai_type` rỗng vào DB.
//
// Payload dưới đây là response THẬT, lấy bằng cách gửi lại đúng tấm ảnh đã
// sinh ra lỗi đó (defect 1465199, bo 7074, 2026-09-30 11:49) cho
// /api/ai-detection: 5 lỗi, hiện 3, verdict NG, nhưng cả 3 mục trong
// detections[] đều verdict=OK. Lỗi NG thật là "Xuoc" (conf 0.4105) bị cắt vì
// thua mục thứ 3 đúng 0.0023 confidence.
import 'package:autovrs_app/services/ai_detection_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _realResponse() => {
  'success': true,
  'message': 'ok',
  'detections': [
    {
      'class_name': 'DiVat',
      'class_name_vi': 'Di Vat',
      'verdict': 'OK',
      'confidence': 0.6104430556297302,
      'bbox': [0, 0, 10, 10],
    },
    {
      'class_name': 'DiVat',
      'class_name_vi': 'Di Vat',
      'verdict': 'OK',
      'confidence': 0.5544360876083374,
      'bbox': [0, 0, 10, 10],
    },
    {
      'class_name': 'DiVat',
      'class_name_vi': 'Di Vat',
      'verdict': 'OK',
      'confidence': 0.41279733180999756,
      'bbox': [0, 0, 10, 10],
    },
  ],
  // Khai báo rõ <String, dynamic>: để suy kiểu tự động thì map này thành
  // Map<String, Object> (non-nullable) và test gán primary_defect = null sẽ
  // ném lỗi kiểu, không phải vì code sai.
  'statistics': <String, dynamic>{
    'total_defects': 5,
    'shown_defects': 3,
    'defect_types': {'Di Vat': 4, 'Xuoc': 1},
    'verdict_counts': {'OK': 4, 'NG': 1},
    'system_verdict': 'NG',
    'primary_defect': {
      'class_name': 'Xuoc',
      'class_name_vi': 'Xuoc',
      'confidence': 0.4105016887187958,
      'reason_code': 'ALWAYS_NG',
      'reason_text': 'Xuoc luôn là NG theo tiêu chuẩn',
    },
  },
  'timestamp': '2026-09-30T11:49:01.650000',
};

void main() {
  group('AIDetectionResult - lỗi NG nằm ngoài TOP-N detections[]', () {
    test('verdict vẫn là NG dù mọi mục trong detections[] đều OK', () {
      final result = AIDetectionResult.fromJson(_realResponse());
      expect(result.systemVerdict, 'NG');
      expect(
        result.detections.where((d) => d.verdict == 'NG'),
        isEmpty,
        reason: 'Đúng tình huống cần bảo vệ: detections[] không có mục NG nào',
      );
    });

    test('primaryDefectName cho đúng tên lỗi gây ra NG', () {
      final result = AIDetectionResult.fromJson(_realResponse());
      expect(result.primaryDefectName, 'Xuoc');
      expect(result.primaryDefectClassName, 'Xuoc');
    });

    test('verdict OK -> không có primary_defect, trả null', () {
      final json = _realResponse();
      (json['statistics'] as Map)['system_verdict'] = 'OK';
      (json['statistics'] as Map)['primary_defect'] = null;
      final result = AIDetectionResult.fromJson(json);
      expect(result.systemVerdict, 'OK');
      expect(result.primaryDefectName, isNull);
      expect(result.primaryDefectClassName, isNull);
    });

    test('response cũ thiếu hẳn primary_defect -> null, không ném lỗi', () {
      final json = _realResponse();
      (json['statistics'] as Map).remove('primary_defect');
      final result = AIDetectionResult.fromJson(json);
      expect(result.primaryDefectName, isNull);
    });

    test('chỉ có class_name (thiếu class_name_vi) vẫn lấy được tên', () {
      final json = _realResponse();
      (json['statistics'] as Map)['primary_defect'] = {
        'class_name': 'NganMach',
      };
      final result = AIDetectionResult.fromJson(json);
      expect(result.primaryDefectName, 'NganMach');
    });

    test('canonicalDefectClass đưa tên đó về đúng lớp chuẩn của mô hình', () {
      final result = AIDetectionResult.fromJson(_realResponse());
      expect(canonicalDefectClass(result.primaryDefectName), 'Xuoc');
      // Tên tiếng Việt có dấu mà app hiển thị cũng phải về đúng lớp đó.
      expect(canonicalDefectClass('Thiếu Đồng'), 'ThieuDong');
      expect(canonicalDefectClass('Thieu Dong'), 'ThieuDong');
      expect(canonicalDefectClass('none'), isNull);
    });
  });
}
