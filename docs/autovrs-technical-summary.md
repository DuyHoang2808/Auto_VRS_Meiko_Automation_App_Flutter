# Báo Cáo Tóm Tắt Cải Tiến AutoVRS (Flutter + Backend)

## Mục Tiêu

Ổn định luồng kiểm tra tự động (auto VRS workflow) trên ứng dụng Flutter: sửa các lỗi khiến ứng dụng không mở được, khiến ảnh thiết kế QCamber không hiển thị, khiến ảnh kết quả AI hiển thị sai, và bổ sung khả năng giám sát trạng thái các API backend trong lúc vận hành.

## Vấn Đề Ban Đầu

Ứng dụng gặp một chuỗi sự cố độc lập trải từ tầng dữ liệu cục bộ đến tầng tích hợp với QCamber và backend AI:

- Cơ sở dữ liệu SQLite cục bộ rơi vào vòng lặp lỗi `table tbModel already exists` mỗi lần mở app, vì `onCreate` bị gọi lại trên một DB đã có bảng.
- Service gọi QCamber (`QCamberGerberService`) gửi sai giá trị zoom (hardcode, bỏ qua tham số thực tế) và không phân biệt được lỗi kết nối với lỗi logic.
- Luồng kiểm tra tự động (`vrs_main_screen.dart`) chờ tuần tự ảnh thiết kế Gerber xong mới gọi bước PLC/AI — khi QCamber phản hồi chậm, toàn bộ pipeline bị treo theo, cộng dồn tới ~60 giây lãng phí mỗi defect.
- PLC Gateway (`plc_gateway_api_optimized.py`) khi trả kết quả `/api/inspect-defect` bỏ qua ảnh đã được AI đánh dấu lỗi (`processed_image_base64`), tự gửi lại ảnh gốc chưa xử lý.
- Không có cơ chế nào để phát hiện sớm khi QCamber, PLC Gateway, hoặc AI Detection API ngừng phản hồi — chỉ biết được khi thao tác giữa chừng bị lỗi.
- Cache build Windows (`build\windows`) bị stale sau phiên làm việc dài, khiến `flutter run` báo "Unable to determine engine version" và crash `dartaotruntime.exe`.

## Các Cải Tiến Đã Thực Hiện

### Cơ Sở Dữ Liệu Cục Bộ

- Thêm `IF NOT EXISTS` vào toàn bộ 5 câu `CREATE TABLE` trong `_createTables()` (`tbModel`, `tbLot`, `tbBoard`, `tbDefect`, `tbConfig`) — an toàn khi `onCreate` bị gọi lại trên DB đã có bảng.

### Tích Hợp QCamber (Flutter)

- Sửa payload `/api/capture`: dùng đúng giá trị `zoom` truyền vào thay vì hardcode `8096.0`.
- Thêm `isServerRunning()` (`GET /api/status`) và bắt riêng `http.ClientException` để báo rõ "QCamber chưa mở" thay vì lỗi kỹ thuật chung chung.
- Đổi `_loadGerberForDefect()` từ `await` tuần tự sang `unawaited()` trong `_inspectCurrentDefect()` — ảnh Gerber tải song song với bước PLC/AI, không còn chặn pipeline chính; cơ chế `requestId` có sẵn tự loại bỏ response cũ để ảnh luôn khớp defect hiện tại.
- Giảm timeout capture mặc định 30 giây xuống 8 giây.
- Cập nhật giá trị zoom gọi thực tế lên `8192.0` ở cả `manual_vrs_screen.dart` và `vrs_main_screen.dart`.

### Pipeline Ảnh AI (PLC Gateway)

- Sửa `/api/inspect-defect` trong `plc_gateway_api_optimized.py`: ưu tiên trả `ai_result.get("processed_image_base64")` (ảnh đã có bounding box/nhãn lỗi từ AI Detection API), fallback về ảnh gốc nếu AI không trả field đó.
- Đồng bộ cùng bản vá sang 3 bản sao khác của `plc_gateway_api.py` trong repo (`AutoVRS-Application/BE-AutoVRS/`, `BE_tensorRT/`, `BE_tensorRT/PLC_gateway/`) dù không phải bản đang chạy thật, để tránh lệch code khi chuyển đổi bản deploy.

### Giám Sát Trạng Thái API (tính năng mới)

- Thêm `StartupHealthCheck`: kiểm tra QCamber, PLC Gateway, AI Detection Api ngay khi mở app, tái sử dụng các health-check có sẵn (`isServerRunning`, `isApiAvailable`, `checkServerHealth`).
- Interval thích ứng: 5 giây khi có dịch vụ down, 60 giây khi mọi thứ ổn định — thay vì cố định 15 giây.
- Chỉ in báo cáo console khi có thay đổi trạng thái, tránh spam log khi chạy nhiều giờ.
- Thêm `setBusy()` để `vrs_main_screen.dart` báo hiệu đang chạy workflow — health-check tự tạm dừng trong lúc đó, tránh chồng request lên QCamber (vốn xử lý HTTP trên một luồng GUI duy nhất).
- Thêm timeout 3 giây cho `AIDetectionService.checkServerHealth()` (trước đây không giới hạn, có thể treo vô thời hạn với host không phản hồi).
- Hiện SnackBar cảnh báo khi một dịch vụ mất kết nối hoặc kết nối trở lại.

### Môi Trường & Công Cụ Build

- Giải phóng port 8082 bị một tiến trình `python.exe` cũ chiếm giữ, chặn `run_ai_api.py` khởi động.
- Dọn cache build Windows (`flutter clean` → `flutter pub get` → `flutter build windows`) để xử lý lỗi "Unable to determine engine version" và Dart AOT Out of Memory sau phiên làm việc dài.

## Kết Quả Đo Được

| Hạng mục | Trước | Sau | Cải thiện |
| --- | ---: | ---: | ---: |
| Timeout capture QCamber mặc định | 30 s | 8 s | Giảm 73% thời gian chờ tối đa khi lỗi |
| Độ trễ cộng dồn mỗi defect khi QCamber phản hồi chậm | tới ~60 s (chờ tuần tự) | ~0 s (chạy song song) | Loại bỏ hoàn toàn độ trễ cộng dồn trên pipeline chính |
| Tần suất gọi health-check khi hệ thống ổn định | không có cơ chế | 60 s/lần (thích ứng) | Phát hiện sự cố mà không tốn tài nguyên liên tục |
| Số lần crash-loop mở DB trong một phiên chạy trước khi vá | 14 lần | 0 | Mở DB thành công ngay lần đầu |

## Kiểm Chứng

- `flutter analyze` không phát sinh lỗi mới trên toàn bộ file đã sửa (`local_database_service.dart`, `qcamber_gerber_service.dart`, `vrs_main_screen.dart`, `main.dart`, `startup_health_check.dart`, `ai_detection_service.dart`).
- `flutter build windows --debug` build thành công sau khi dọn cache, xác nhận hết lỗi engine version/OOM.
- `python -m py_compile` xác nhận cú pháp hợp lệ trên các file `plc_gateway_api*.py` đã sửa.
- Log runtime xác nhận: DB mở thành công không còn lặp lỗi; sau bản vá QCamber (bên Codex), request capture trả `HTTP 409` rõ ràng thay vì treo; auto workflow không còn cộng dồn timeout khi QCamber chậm.
- Đã kiểm tra kết nối mạng thủ công (`Test-NetConnection`, `ping`) để xác nhận 2 case "server không phản hồi" là do hạ tầng (service chưa chạy, sai IP cấu hình), không phải lỗi code phía Flutter/Python.

## Tác Động Với Người Dùng

- Ứng dụng mở ổn định ngay từ lần đầu, không còn crash-loop cơ sở dữ liệu.
- Quy trình quét tự động qua nhiều lỗi liên tiếp không còn bị treo do QCamber phản hồi chậm.
- Panel "Ảnh từ PCI AOI" hiển thị đúng ảnh đã được AI khoanh vùng lỗi, thay vì ảnh gốc.
- Người vận hành được cảnh báo ngay trên màn hình khi QCamber, PLC Gateway hoặc AI Detection API mất kết nối hoặc kết nối trở lại — không cần mở console theo dõi.

## Khuyến Nghị Vận Hành

Sau khi deploy các bản vá lên đúng máy chạy từng service, nên xác nhận:

1. Đổi tên model trong DB local cho khớp job thật đang mở trong QCamber, tránh lỗi `409 Conflict` do lệch dữ liệu.
2. Chạy thử auto workflow qua một board có nhiều defect liên tiếp, xác nhận cả ảnh Gerber và ảnh AI đều hiển thị đúng mà không bị treo.
3. Xác nhận `ai_api_url` trong `plc_gateway_config.json` trỏ đúng địa chỉ máy chạy AI Detection API, và PLC Gateway đang chạy trên đúng máy/port cấu hình ở Flutter.
4. Theo dõi SnackBar cảnh báo API trong vài phiên đầu để xác nhận health-check phản ánh đúng thực tế (thử tắt/mở lại một service để kiểm chứng).

## Tài Liệu Liên Quan

Báo cáo phía QCamber (C++/Qt) — tối ưu hiệu năng viewer và ổn định REST API — nằm tại:

`D:\Ps_Duy\Project\Qcamber-Meiko\docs\qcamber-technical-summary.md`
