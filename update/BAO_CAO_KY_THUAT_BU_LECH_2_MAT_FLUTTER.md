# Báo Cáo Kỹ Thuật — Thay Đổi Cần Làm Trong Flutter App Cho Bù Lệch 2 Mặt (PA2)

> Ngày: 2026-08-05
> Dự án: AutoVRS Meiko Automation
> Phạm vi: **CHỈ Flutter App** (`Auto_VRS_Meiko_Automation_App_Flutter/App`)
> Tài liệu liên quan:
> - `update/BAO_CAO_KY_THUAT_AUTO_BOARD_OFFSET.md` (2026-07-30) — báo cáo PA1, đã triển khai xong, dùng làm baseline.
> - `Auto_calib/AutoBoardOffset_YOLO_2Mat/docs/Ke_hoach_bu_lech_2_mat_PA2.md` — kế hoạch gateway PA2 (bù lệch riêng từng mặt A/B), trạng thái "ĐÃ CODE (bước 1-3, 5-6)", bước 4 (sinh calib mặt B thật) và bước 7 (auto-gen calib) **chưa làm trên máy**.

---

## 1. Kết luận nhanh

Đã đọc lại toàn bộ đường đi `board_side` trong code Flutter hiện tại (không phải đọc tài liệu cũ — đọc trực tiếp `plc_gateway_service.dart`, `vrs_provider.dart`, `vrs_main_screen.dart`, `manual_vrs_screen.dart`). Kết quả:

- **Phần định tuyến theo mặt (A/B) mà PA2 cần ở gateway — Flutter đã sẵn sàng, không cần sửa.** Cả hai endpoint quan trọng nhất, `/api/inspect-defect` và `/api/calib/auto-board-offset`, đã được Flutter gọi kèm `board_side` ở **mọi** call site (4/4), từ đợt code PA1 hôm 2026-07-30. Đây chính là field mà gateway PA2 dùng để chọn đúng file `calib_paths[side]` / `offset_paths[side]`.
- **Nhưng có 1 gap nghiêm trọng đã tồn tại từ PA1, PA2 làm nó rõ ràng và nguy hiểm hơn**: gateway trả về `offset_applied` / `nominal_coords` / `offset_info` trong response của `/api/inspect-defect` (theo đúng thiết kế ở báo cáo PA1 §3 bước 1), nhưng **model Dart `InspectDefectResponse` không khai báo các field này** → Flutter nhận được nhưng âm thầm bỏ, và **operator không có cách nào biết một lần soi defect đã được bù lệch hay đang chạy bằng tọa độ thô**. Với PA2 (2 file offset riêng theo mặt, mặt B ban đầu chưa có calib), nguy cơ "chạy mù không bù lệch mà không ai biết" là thật, không phải giả định.
- Còn 3 gap nhỏ hơn liên quan trực tiếp đến vận hành 2 mặt, chi tiết ở mục 3.

Nói cách khác: **việc cần sửa trong Flutter cho PA2 không phải là "thêm tham số boardSide"** (đã có) mà là **"làm cho operator nhìn thấy được offset có đang được áp dụng hay không, cho đúng mặt nào"** — hiện tại thông tin đó bị gateway gửi lên rồi bị Flutter làm rơi.

---

## 2. Đối chiếu chi tiết: Flutter đã làm gì, còn thiếu gì

### 2.1. Đã có sẵn — xác nhận qua code, không cần sửa

| Việc | Vị trí | Xác nhận |
|---|---|---|
| Xác định mặt A/B từ `layer_id` | [`vrs_provider.dart:76-82`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/providers/vrs_provider.dart#L76-L82) `boardSideFromLayerId()` | Trả đúng `'A'`/`'B'` (l1-l4→A, l5-l8→B), khớp 100% với `side ∈ {A,B}` mà gateway PA2 yêu cầu ở §4. |
| Gửi `board_side` khi soi defect (Auto mode) | [`vrs_main_screen.dart:232-238`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/screens/vrs/vrs_main_screen.dart#L232-L238) | `_plcGateway.inspectDefect(..., boardSide: vrsProvider.currentBoardSide)` |
| Gửi `board_side` khi calib trước khi advance board (Auto mode) | [`vrs_main_screen.dart:535-537`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/screens/vrs/vrs_main_screen.dart#L535-L537) | `_runCalibrationIfNeeded()` → `triggerAutoBoardOffset(boardSide: vrs.nextBoardSide)` |
| Gửi `board_side` khi bắt đầu board có resume/restart (Auto mode) | [`vrs_main_screen.dart:657-676`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/screens/vrs/vrs_main_screen.dart#L657-L676) | Đọc `layer_id` từ DB → `boardSideFromLayerId()` → sync vào provider **trước** khi gọi `triggerAutoBoardOffset(boardSide: side)`, đúng thứ tự cần thiết. |
| Gửi `board_side` khi calib thủ công (Manual mode) | [`manual_vrs_screen.dart:330-336`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/screens/vrs/manual_vrs_screen.dart#L330-L336) | `_triggerManualCalibration()` → `triggerAutoBoardOffset(boardSide: vrs.currentBoardSide)` |
| Class request/response đã có field `boardSide` | [`plc_gateway_service.dart:66,91,185,194`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/services/plc_gateway_service.dart#L66) | `inspectDefect()` và `triggerAutoBoardOffset()` đều nhận `boardSide` bắt buộc/có default, encode đúng key JSON `board_side`. |

→ **Không cần đổi gì ở 5 điểm trên.** Khi gateway PA2 lên production (resolver theo `calib_paths[side]`/`offset_paths[side]`), 4 call site này tự động route đúng vì field đã đúng tên, đúng giá trị.

### 2.2. Gap #1 (mức độ: **CAO** — nên sửa trước khi bật PA2 cho mặt B thật)

**Vị trí**: [`plc_gateway_service.dart:304-366`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/services/plc_gateway_service.dart#L304-L366), class `InspectDefectResponse`.

**Vấn đề**: Theo báo cáo PA1 (§3 bước 1+2), gateway `/api/inspect-defect` đã được sửa để trả thêm:
```python
nominal_coords: Optional[Dict[str, float]]   # tọa độ gốc chưa bù
offset_applied: bool                          # có bù lệch thành công hay không
offset_info: Optional[Dict[str, Any]]         # chi tiết offset đã dùng
```
Nhưng `InspectDefectResponse.fromJson()` hiện tại chỉ parse `success, message, step, plc_coords, image_captured, image_base64, ai_detections, ai_verdict, ai_statistics, ai_image_path, timing, error_details` — **không có `offsetApplied`, `nominalCoords`, `offsetInfo`**. Toàn bộ 3 field này bị `json.decode` giữ trong map nhưng never đọc tới, và **không nơi nào trong UI (`vrs_main_screen.dart`, `manual_vrs_screen.dart`) hiển thị chúng.**

**Tại sao nguy hiểm hơn với PA2 cụ thể**: gateway PA1 đã có sẵn hành vi fallback "không có `offset_runtime.json` → dùng tọa độ gốc + log warning (không fail)" (báo cáo PA1 §7). Với PA2, mặt B có file offset **riêng** (`offset_runtime_side_b.json`) và — theo đúng trạng thái ghi trong `Ke_hoach_bu_lech_2_mat_PA2.md` dòng 3-5 — **file calib tĩnh mặt B (`vrs_calib_side_b.json`) chưa được sinh trên máy thật**. Nghĩa là: ngay khi ai đó chạy board mặt B lần đầu trên PA2, khả năng cao `/api/inspect-defect` sẽ soi bằng **tọa độ thô, không bù lệch**, tự động fallback, không throw lỗi — và Flutter **hoàn toàn không có cách hiển thị điều này cho operator**, vì field `offset_applied` bị rơi mất từ tầng model. Operator sẽ thấy quy trình "chạy bình thường", camera di chuyển, AI detect, lưu kết quả NG/OK — nhưng vị trí camera có thể lệch khỏi vị trí defect thật trên board.

**Đề xuất sửa** (mô tả thay đổi, không code sẵn — theo yêu cầu chỉ viết báo cáo):
1. Thêm 3 field vào `InspectDefectResponse`: `bool offsetApplied`, `Map<String, dynamic>? nominalCoords`, `Map<String, dynamic>? offsetInfo`, parse trong `fromJson()`.
2. Ở `vrs_main_screen.dart` (sau dòng 240, nơi đang xử lý `result`) và `manual_vrs_screen.dart` (nơi gọi flow tương đương): nếu `result.offsetApplied == false`, hiện cảnh báo — **không chỉ 1 snackbar thoáng qua**, vì nếu bỏ qua sẽ lặp lại cho từng defect tiếp theo trong cùng board. Nên là banner/badge cố định trên màn hình trong lúc soi board đó ("⚠️ Đang soi KHÔNG bù lệch — mặt B chưa có calib"), tự tắt khi đổi board/mặt có offset hợp lệ.

### 2.3. Gap #2 (mức độ: trung bình)

**Vị trí**: [`plc_gateway_service.dart:227-240`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/services/plc_gateway_service.dart#L227-L240), method `getOffsetStatus()`.

**Vấn đề**: Method gọi `GET /api/calib/offset-status` **không kèm tham số nào** — trong khi PA2 §4 nói rõ endpoint này "thêm tham số `board_side` để chọn đúng calib/offset file". Đã grep toàn bộ `lib/`: **`getOffsetStatus()` không được gọi ở bất kỳ đâu trong UI hiện tại** — tức là tính năng "xem trạng thái offset hiện tại" được chuẩn bị sẵn ở tầng service từ PA1 nhưng chưa từng được nối vào màn hình nào, và giờ với PA2 gọi nó (nếu không sửa) sẽ luôn trả trạng thái của một mặt cố định (nhiều khả năng mặt A theo fallback key cũ), không phân biệt được A/B.

**Đề xuất sửa**: 
1. Thêm param `required String boardSide` vào `getOffsetStatus()`, gắn `?board_side=$boardSide` vào URL.
2. Cân nhắc wire vào UI: hiển thị trong panel thông tin board (Auto/Manual) dòng dạng "Offset mặt A: θ=0.12°, RMS=0.03mm, lúc 10:32" lấy từ response — hiện tại operator không có cách nào tự kiểm tra offset đang dùng mà không đọc trực tiếp file JSON trên máy gateway.

### 2.4. Gap #3 (mức độ: thấp — làm rõ UX, không phải lỗi)

**Vị trí**: [`vrs_main_screen.dart:527-580`](Auto_VRS_Meiko_Automation_App_Flutter/App/lib/screens/vrs/vrs_main_screen.dart#L527-L580) (dialog khi `triggerAutoBoardOffset` fail — 3 nút "Thử lại"/"Bỏ qua"/"Hủy").

**Vấn đề**: Với PA2, một trong các lý do fail rất có thể là lỗi 400 "chưa khai báo calib cho mặt B" (theo đúng thiết kế resolver ở PA2 §4) — đây là lỗi **cấu hình/vận hành** (cần kỹ thuật viên sinh file calib), khác hẳn về bản chất với lỗi **tạm thời** (marker bị che, PLC timeout, ánh sáng đổi — đã liệt kê ở báo cáo PA1 §8). Dialog hiện tại xử lý đồng nhất mọi loại lỗi bằng cùng 3 nút, trong đó "Thử lại" là vô nghĩa với lỗi thiếu-file-calib (thử lại bao nhiêu lần cũng vẫn 400 y như cũ cho tới khi ai đó sinh file trên máy).

**Đề xuất sửa**: phân loại `result.message`/status code trả về — nếu nhận diện được lỗi dạng "chưa khai báo calib" thì đổi nội dung dialog: bỏ nút "Thử lại" (vô nghĩa), nhấn mạnh cần chạy calib tĩnh Phase 1 cho mặt đó trước (theo PA2 §5a) rồi mới vào lại.

### 2.5. Gap #4 (mức độ: thấp)

**Vị trí**: label hiển thị mặt board hiện tại trong Auto mode.

**Vấn đề**: Đã xác nhận `manual_vrs_screen.dart` có dòng hiển thị rõ "Mặt board: Mặt A (Top)/Mặt B (Bot)" (theo báo cáo PA1 §6). Nhưng ở `vrs_main_screen.dart` (chế độ Auto — chạy không giám sát, thời gian dài), mặt board hiện chỉ xuất hiện trong dòng log debug (`_startWithCalibration`) và trong text điều kiện "sẽ tự động calib mặt X" khi `calibrationNeeded=true` — **không có hiển thị persistent, luôn thấy được, kiểu "Đang chạy: Mặt A"** trong lúc workflow đang chạy bình thường (không phải lúc cần calib). Với PA2, việc luôn biết đang chạy mặt nào là ngữ cảnh quan trọng để operator hiểu tại sao offset áp dụng khác nhau.

**Đề xuất sửa**: thêm 1 badge/chip cố định (ví dụ cạnh tên board đang chạy) hiển thị mặt A/B suốt thời gian Auto mode hoạt động, không chỉ khi `calibrationNeeded`.

---

## 3. Việc KHÔNG cần làm trong Flutter (để tránh làm dư)

- **Không cần sửa `boardSideFromLayerId()`** — logic A/B từ `layer_id` độc lập với việc gateway lưu file calib/offset theo mặt hay không; PA2 không đổi quy tắc l1-l4/l5-l8.
- **Không cần thêm UI cho `/api/calib/board-to-plc` (preview)** hay **`/api/calib/camera-axis`** — 2 endpoint này (PA2 §4) chỉ dùng bởi công cụ calib tĩnh chạy ngoài app (`calibrate_camera_axis.py`, `calculate_4diem.py`), Flutter app không và không cần gọi trực tiếp.
- **Không cần đổi `plc_gateway_service.dart` để chọn "profile mặt B"** kiểu file cấu hình riêng — gateway tự resolve theo `board_side` gửi lên, Flutter chỉ cần tiếp tục gửi đúng giá trị (đã đúng).
- **Không cần sửa gì để "tương thích ngược mặt A"** — theo PA2 §2.6 mặt A giữ nguyên hành vi/file hiện tại, Flutter không phân biệt code-path theo mặt (chỉ khác giá trị field), nên không có rủi ro hồi quy cho mặt A.

---

## 4. Danh sách file cần sửa (tổng hợp)

| # | File | Thay đổi | Mức độ |
|---|------|----------|--------|
| 1 | `lib/services/plc_gateway_service.dart` | Thêm field `offsetApplied`, `nominalCoords`, `offsetInfo` vào `InspectDefectResponse` + parse trong `fromJson()` | **Cao** |
| 2 | `lib/services/plc_gateway_service.dart` | Thêm param `boardSide` vào `getOffsetStatus()`, build query string | Trung bình |
| 3 | `lib/screens/vrs/vrs_main_screen.dart` | Hiện banner cảnh báo cố định khi `result.offsetApplied == false` trong lúc soi board; thêm badge mặt A/B persistent trong Auto mode | Cao + Thấp |
| 4 | `lib/screens/vrs/manual_vrs_screen.dart` | Hiện cảnh báo tương tự khi offset không được áp dụng (nếu Manual mode cũng gọi `inspectDefect`/endpoint tương đương) | Cao |
| 5 | `lib/screens/vrs/vrs_main_screen.dart` | Phân loại lỗi "thiếu calib mặt B" trong dialog fail của `_runCalibrationIfNeeded()`, bỏ nút "Thử lại" khi không phù hợp | Thấp |
| 6 | (Tuỳ chọn) một màn hình/panel mới hoặc mở rộng panel có sẵn | Hiển thị kết quả `getOffsetStatus(boardSide)` — θ, tx, ty, RMS, thời điểm calib gần nhất, theo từng mặt | Trung bình |

---

## 5. Thứ tự triển khai đề xuất

1. **Trước tiên, xác nhận với vận hành**: đã sinh `vrs_calib_side_b.json` trên máy thật chưa (PA2 bước 4, hiện ghi "chưa thực hiện"). Nếu chưa, mọi board mặt B sẽ luôn fallback tọa độ thô cho tới khi làm — đây là việc vận hành/phần cứng, không phải code Flutter, nhưng **phải xong trước khi Gap #1 có ý nghĩa kiểm chứng thật**.
2. Sửa Gap #1 (model response) — ưu tiên cao nhất, vì đây là "mắt" duy nhất để biết offset có chạy đúng không, cả cho mặt A hiện tại (dù ít rủi ro hơn) và mặt B (rủi ro cao).
3. Sửa Gap #3 (phân loại lỗi calib) song song — dùng chung dữ liệu lỗi đã có, không phụ thuộc Gap #1/#2.
4. Sửa Gap #2 + wire UI (nếu muốn có màn hình xem trạng thái offset) — có thể làm sau, không chặn việc chạy mặt B.
5. Gap #4 (badge mặt A/B) — cosmetic, làm bất cứ lúc nào.

---

## 6. Rủi ro nếu KHÔNG sửa Gap #1

| Tình huống | Hậu quả nếu không có cảnh báo trong UI |
|---|---|
| Mặt B chưa có `vrs_calib_side_b.json`, operator vẫn chạy Auto mode trên board mặt B | Toàn bộ defect trên board đó được soi bằng tọa độ gốc (chưa bù lệch gá lắp thực tế) → camera có thể lệch khỏi vị trí defect thật → AI detect sai vị trí/nhận nhầm OK thành NG hoặc ngược lại → **kết quả kiểm tra sai được lưu vào DB, không có dấu hiệu để truy vết sau này vì bản thân dữ liệu lưu (`plc_coor`) không phân biệt "đã bù" hay "chưa bù"** (ghi chú tương tự đã thấy ở `AOI_Ingest/aoi_ingest_service.py` — `plc_coor` lưu tọa độ thô theo thiết kế, không phải tọa độ đã bù). |
| `offset_runtime_side_a.json`/`_side_b.json` bị xoá/hỏng giữa ca làm việc | Gateway tự fallback tọa độ gốc (theo thiết kế PA1 §7) — Flutter tiếp tục soi "bình thường" không báo gì trong suốt phần còn lại của ca. |

Đây là lý do Gap #1 được xếp mức độ **Cao** dù về mặt kỹ thuật chỉ là "thêm field vào model + hiện 1 banner" — chi phí sửa nhỏ, nhưng rủi ro nếu bỏ qua là dữ liệu kiểm tra chất lượng sai mà không ai biết.
