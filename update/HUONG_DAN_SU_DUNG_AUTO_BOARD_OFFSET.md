# Hướng Dẫn Sử Dụng — Tự Động Bù Lệch Board (Auto Board Offset Calibration)

> Phiên bản: v1.0 — Tháng 7/2026
> Áp dụng cho: AutoVRS Flutter App + PLC Offset Gateway

---

## 1. Tổng quan

Khi đặt board PCB lên bàn máy VRS, board có thể bị lệch 1-2mm so với vị trí chuẩn do khe hở cơ khí của jig. Tính năng **Auto Board Offset Calibration** tự động phát hiện độ lệch này và bù trừ tọa độ cho tất cả các điểm kiểm tra defect, đảm bảo camera luôn di chuyển đúng vị trí cần kiểm tra.

Trước đây, quy trình bù lệch phải thực hiện thủ công (operator jog PLC bằng mắt, đọc tọa độ, nhập vào script Python). Phiên bản mới tự động hóa toàn bộ: PLC tự di chuyển đến các điểm mốc, camera chụp, AI (YOLO) tìm vị trí marker trên board, hệ thống tính toán và áp dụng bù lệch — tất cả chỉ mất khoảng 15-30 giây.

---

## 2. Quy trình tự động (Chế độ Auto VRS)

### 2.1 Khi nào hệ thống tự calib?

Hệ thống tự động calib khi phát hiện một trong hai điều kiện:

- **Board vật lý mới**: `board_code` của board tiếp theo khác board hiện tại (ví dụ: từ board 6722 → board 6725)
- **Đổi mặt board**: cùng `board_code` nhưng chuyển từ mặt Top (layer l1-l4) sang mặt Bottom (layer l5-l8) hoặc ngược lại

Hệ thống **KHÔNG calib** khi cùng board, cùng mặt nhưng khác layer (ví dụ: l1 → l2) vì board vẫn ở nguyên vị trí.

### 2.2 Luồng hoạt động

1. Workflow auto chạy hết các defect trên board hiện tại
2. Hệ thống tự động tìm board tiếp theo trong lot
3. Màn hình hiện panel thông báo:
   - Nếu cần calib: **"⚙️ Sẽ tự động calib bù lệch board (mặt A/B)"**
   - Nếu board mới: "Đặt board mới lên bàn rồi bấm tiếp tục"
   - Nếu lật bo: "Lật bo rồi bấm tiếp tục"
4. Operator thực hiện thao tác tay (đặt board / lật bo)
5. Bấm **"Board tiếp theo"**
6. Nếu cần calib → hệ thống tự chạy:
   - PLC di chuyển đến điểm mốc A → camera chụp → YOLO detect marker
   - PLC di chuyển đến điểm mốc C → camera chụp → YOLO detect marker
   - Tính toán Kabsch rigid transform (xoay + tịnh tiến)
   - Lưu kết quả vào `offset_runtime.json`
   - Hiện spinner "Đang calib bù lệch board..." trong quá trình
7. Calib xong → workflow board mới bắt đầu tự động với tọa độ đã bù

### 2.3 Xử lý khi calib thất bại

Nếu calib không thành công (camera không chụp được, YOLO không tìm thấy marker, PLC không kết nối...), hệ thống hiện dialog với 3 lựa chọn:

- **Thử lại**: Chạy lại calib (sử dụng khi vấn đề đã khắc phục, ví dụ điều chỉnh ánh sáng)
- **Bỏ qua**: Tiếp tục workflow không bù lệch (dùng tọa độ gốc — chỉ nên dùng khi biết board đặt đúng vị trí)
- **Hủy**: Quay về trạng thái chờ, không chuyển sang board mới

### 2.4 Cảnh báo RMS cao

Nếu calib thành công nhưng sai số dư (RMS) vượt ngưỡng an toàn, hệ thống hiện snackbar cảnh báo cam. Offset vẫn được áp dụng nhưng nên kiểm tra lại (board có thể bị méo, marker bị che, ánh sáng không đều...).

---

## 3. Calib thủ công (Chế độ Manual VRS)

Ở màn hình Manual VRS, operator có thể chủ động chạy calib bất cứ lúc nào:

1. Kiểm tra thông tin "Mặt board" hiện trên panel bên phải (Mặt A = Top, Mặt B = Bot)
2. Bấm nút **"Calib bù lệch board"** (nút viền, nằm dưới dòng "Mặt board")
3. Hệ thống chạy calib giống như chế độ auto
4. Kết quả hiện trên snackbar:
   - **Xanh**: Thành công — hiện θ (góc lệch), tx/ty (dịch chuyển), RMS (sai số)
   - **Cam**: Thành công nhưng có cảnh báo RMS
   - **Đỏ**: Thất bại — hiện mô tả lỗi

Sau khi calib thủ công, tất cả lệnh di chuyển camera tiếp theo sẽ tự động dùng offset mới.

---

## 4. Kiểm tra trạng thái hệ thống (Health Check)

App tự động theo dõi 4 dịch vụ backend:

| Dịch vụ | Mặc định | Chức năng |
|---------|----------|-----------|
| QCamber | localhost:8686 | Hiển thị ảnh Gerber PCB |
| PLC Gateway | localhost:8083 | Điều khiển PLC + camera + calib |
| AI Detection | localhost:8082 | Nhận diện defect |
| **Fiducial YOLO** | **127.0.0.1:8191** | **Detect marker bù lệch (mới)** |

Khi một dịch vụ mất kết nối → snackbar đỏ cảnh báo. Khi kết nối lại → snackbar xanh thông báo.

**Lưu ý**: Nếu Fiducial YOLO không chạy, tính năng auto board offset sẽ thất bại nhưng app vẫn hoạt động bình thường cho các chức năng khác (inspect defect dùng tọa độ gốc nếu không có offset).

---

## 5. Cấu hình

Tất cả URL dịch vụ có thể thay đổi trong file `app_config.json`:

```json
{
  "plc_gateway_base_url": "http://localhost:8083",
  "fiducial_detector_base_url": "http://127.0.0.1:8191",
  "ai_base_url": "http://localhost:8082",
  "qcamber_base_url": "http://localhost:8686"
}
```

Vị trí file config (Windows): `%USERPROFILE%\Documents\AutoVRS\app_config.json`

Hoặc đặt `app_config.json` cùng thư mục với file `.exe` của app.

---

## 6. Câu hỏi thường gặp

**Q: Camera di chuyển không đúng vị trí defect sau khi calib?**
A: Kiểm tra RMS trong log. Nếu RMS > 0.1mm, nên calib lại. Đảm bảo ánh sáng đều, marker không bị che.

**Q: Có thể dùng 3 điểm mốc thay vì 2?**
A: Có. Sửa `anchor_mode` trong request gửi từ app (mặc định = 2). Dùng 3 điểm mốc (A, C, D) sẽ chậm hơn 1 lần đo nhưng có kiểm tra chéo lỗi đo.

**Q: Calib có ảnh hưởng khi chuyển giữa auto và manual mode?**
A: Không. Offset được lưu trong file `offset_runtime.json` trên gateway — cả hai chế độ đều dùng chung. Calib ở manual mode cũng có hiệu lực khi quay lại auto mode.

**Q: Muốn tắt bù lệch tạm thời?**
A: Xóa file `offset_runtime.json` trên gateway. Hoặc gọi API với `apply_board_offset: false`.

**Q: Board cũ (trước migration) không có layer_id/board_code?**
A: Hệ thống mặc định coi là board mới (calib an toàn). Mặt board mặc định là "A".
