import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Máy AOI đang được chọn để vận hành - toàn bộ danh sách model/lot/board
/// trong "Cài đặt Model" phải lọc theo giá trị này (xem
/// local_database_service.dart, các tham số `aoiMachine`).
///
/// Lưu qua SharedPreferences (không dùng app_config.json/AppRuntimeConfig):
/// đây là lựa chọn VẬN HÀNH của operator (đổi được bất cứ lúc nào qua top
/// bar), cùng bản chất với ThemeProvider (dark/light mode) - khác với
/// app_config.json vốn là cấu hình HẠ TẦNG (URL server...) do kỹ thuật viên
/// sửa tay.
class AoiMachineProvider extends ChangeNotifier {
  static const _selectedMachineKey = 'aoi_machine';

  String? _selectedMachine;
  bool _isLoaded = false;

  AoiMachineProvider() {
    _load();
  }

  /// null = CHƯA từng chọn máy nào (lần đầu mở app trên máy tính này, hoặc
  /// SharedPreferences vừa bị xoá) - các màn hình dùng giá trị này để biết
  /// có cần bắt buộc chọn máy trước khi cho vào quy trình hay không.
  String? get selectedMachine => _selectedMachine;
  bool get isSelected => _selectedMachine != null;

  /// true sau khi đã đọc xong SharedPreferences lần đầu - tránh 1 khung hình
  /// đầu tiên hiểu nhầm "chưa chọn máy" (null) trong lúc _load() còn đang
  /// await, dù thật ra đã có lựa chọn lưu từ trước.
  bool get isLoaded => _isLoaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_selectedMachineKey);
    _selectedMachine = (saved != null && saved.trim().isNotEmpty)
        ? saved.trim()
        : null;
    _isLoaded = true;
    notifyListeners();
  }

  /// Đổi máy đang chọn. KHÔNG tự reset state model/lot/board đang chọn ở
  /// VRSProvider - nơi gọi hàm này (xem AoiMachineDialog) phải tự gọi
  /// VRSProvider.resetSelection() ngay sau khi đổi máy, để tránh lẫn trạng
  /// thái của máy cũ (bẫy đã biết - xem yêu cầu tính năng).
  Future<void> selectMachine(String machine) async {
    final trimmed = machine.trim();
    if (trimmed.isEmpty) return;
    _selectedMachine = trimmed;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedMachineKey, trimmed);
  }
}
