# Báo Cáo Kỹ Thuật — Tích Hợp Auto Board Offset Calibration

> Ngày: 2026-07-30
> Dự án: AutoVRS Meiko Automation
> Phạm vi: PLC Offset Gateway (Python) + Flutter App

---

## 1. Mục tiêu

Tích hợp quy trình bù lệch board tự động vào workflow Flutter VRS App. Khi chuyển sang board vật lý mới hoặc đổi mặt board (Top ↔ Bottom), hệ thống tự động gọi gateway thực hiện YOLO fiducial detection + Kabsch rigid transform để tính offset, sau đó áp dụng offset cho tất cả tọa độ kiểm tra defect gửi đến PLC.

---

## 2. Tóm tắt thay đổi

| Bước | File | Loại | Mô tả |
|------|------|------|-------|
| 1 | `plc_offset_gateway.py` | Sửa | `/api/inspect-defect` apply offset tự động |
| 2 | `plc_offset_gateway.py` | Sửa | Thống nhất port 8083 |
| 3 | `plc_gateway_service.dart` | Thêm | Methods `triggerAutoBoardOffset()`, `getOffsetStatus()`, class `AutoBoardOffsetResponse` |
| 4 | `vrs_provider.dart` | Sửa+Thêm | Board side tracking, `calibrationNeeded` flag, `boardSideFromLayerId()` |
| 5 | `vrs_main_screen.dart` | Sửa+Thêm | `_runCalibrationIfNeeded()`, UI calib loading + error dialog |
| 6 | `manual_vrs_screen.dart` | Thêm | Nút calib thủ công, hiển thị mặt board |
| 7 | `startup_health_check.dart`, `app_runtime_config.dart`, `plc_gateway_service.dart` | Thêm | Health check Fiducial YOLO service |

---

## 3. Chi tiết kỹ thuật theo bước

### Bước 1+2: Gateway — `/api/inspect-defect` apply offset + port

**File**: `D:\Camera\Dev\AutoBoardOffset_YOLO\gateway\plc_offset_gateway.py`

**Vấn đề**: Endpoint `/api/inspect-defect` gửi tọa độ defect thô đến PLC mà không bù lệch, dù `offset_runtime.json` đã tồn tại từ quá trình calib. Ngoài ra, port không nhất quán giữa chạy trực tiếp (8183) và qua `run_gateway.py` (8083).

**Giải pháp**:

Thêm field vào `InspectDefectRequest`:
```python
apply_board_offset: bool = True
```

Thêm fields vào `InspectDefectResponse`:
```python
nominal_coords: Optional[Dict[str, float]] = None
offset_applied: bool = False
offset_info: Optional[Dict[str, Any]] = None
```

Sửa body function `inspect_defect()` — trước khi gửi tọa độ cho PLC:
```python
nominal_x, nominal_y = request.defect_x, request.defect_y
final_x, final_y = nominal_x, nominal_y

if request.apply_board_offset:
    loaded = load_saved_rigid_offset(offset_path)
    if loaded is not None:
        R, t, raw = loaded
        final_x, final_y = apply_rigid_offset(nominal_x, nominal_y, R, t)
        offset_applied = True
```

PLC nhận `final_x, final_y` (đã bù) thay vì `request.defect_x, defect_y` (gốc). Response trả cả hai để client biết tọa độ trước/sau bù.

Port thống nhất: sửa `port=8183` → `port=8083` ở cuối file.

---

### Bước 3: Flutter — PlcGatewayService

**File**: `D:\Camera\Dev\Auto_VRS_Meiko_Automation_App_Flutter\App\lib\services\plc_gateway_service.dart`

**Thêm mới**:

1. **`triggerAutoBoardOffset()`** — POST `/api/calib/auto-board-offset`
   - Params: `boardSide` (required, "A"/"B"), `boardId` (optional), `anchorMode` (default 2)
   - Timeout: 90 giây (PLC cần di chuyển 2-3 điểm mốc)
   - Error handling: trả `AutoBoardOffsetResponse(success: false)` thay vì throw

2. **`getOffsetStatus()`** — GET `/api/calib/offset-status`
   - Trả nội dung `offset_runtime.json` hiện tại
   - Timeout: 5 giây

3. **`checkFiducialHealth()`** — static method, GET fiducial service root
   - Check `status == 'running'` trong response JSON
   - Dùng bởi `StartupHealthCheck`

4. **`AutoBoardOffsetResponse`** class
   - Fields: `success`, `message`, `anchorMode`, `thetaDeg`, `tx`, `ty`, `rmsErrorMm`, `maxErrorMm`, `warning`, `boardId`, `boardSide`, `timing`
   - Factory `fromJson()` parse response gateway

---

### Bước 4: Flutter — VRSProvider

**File**: `D:\Camera\Dev\Auto_VRS_Meiko_Automation_App_Flutter\App\lib\providers\vrs_provider.dart`

**Thêm state**:
```dart
String _currentBoardSide = 'A';   // mặt board hiện tại
String _nextBoardSide = 'A';      // mặt board sắp chuyển tới
bool _calibrationNeeded = false;   // có cần calib trước khi advance không
```

**Thêm helper**:
```dart
static String boardSideFromLayerId(String? layerId)
```
Parse `layer_id` từ DB (format lowercase `"l1"` ... `"l8"` — đã verify từ production DB và AOI_Ingest source code):
- `l1`-`l4` → `"A"` (mặt Top)
- `l5`-`l8` → `"B"` (mặt Bottom)
- `null`/rỗng/parse fail → `"A"` (safe default)

**Sửa `completeCurrentBoardAndCheckNext()`**:
Sau khi tìm được board tiếp theo, thêm logic xác định mặt board và cần calib:
```dart
_nextBoardSide = boardSideFromLayerId(nextLayerId);
_calibrationNeeded = _nextBoardIsNewPhysical ||
    boardSideFromLayerId(currentLayerId) != _nextBoardSide;
```

Quy tắc `calibrationNeeded`:
- Board vật lý mới (khác `board_code`) → **true** (luôn calib)
- Cùng `board_code`, đổi mặt (A→B hoặc B→A) → **true**
- Cùng `board_code`, cùng mặt (l1→l2) → **false** (skip calib)

**Sửa `checkForNewBoard()`**: Logic tương tự cho polling board mới từ AOI_Ingest.

**Sửa `advanceToNextBoard()`**: Cập nhật `_currentBoardSide = _nextBoardSide`, reset `_calibrationNeeded = false`.

---

### Bước 5: Flutter — vrs_main_screen (Auto mode)

**File**: `D:\Camera\Dev\Auto_VRS_Meiko_Automation_App_Flutter\App\lib\screens\vrs\vrs_main_screen.dart`

**Thêm state**: `bool _calibrating = false`

**Thêm method `_runCalibrationIfNeeded()`**:
```
Luồng:
1. Check vrs.calibrationNeeded → false → return true (skip)
2. setState(_calibrating = true) → UI hiện spinner
3. Gọi plcGateway.triggerAutoBoardOffset(boardSide: nextBoardSide)
4. setState(_calibrating = false)
5. Nếu success:
   - Log kết quả θ/tx/ty/RMS
   - Nếu có warning → snackbar cam
   - Return true
6. Nếu fail → showDialog:
   - "Thử lại" → đệ quy _runCalibrationIfNeeded()
   - "Bỏ qua" → return true (advance không có offset mới)
   - "Hủy" → return false (không advance)
```

**Sửa `_advanceToNextBoard()`**: Chèn `_runCalibrationIfNeeded()` TRƯỚC `advanceToNextBoard()`. Nếu return false → không advance, không start workflow.

**Sửa UI panel "Board tiếp theo"**:
- Thêm dòng "⚙️ Sẽ tự động calib bù lệch board (mặt X)" khi `calibrationNeeded=true`
- Thay nút bằng spinner + "Đang calib bù lệch board..." khi `_calibrating=true`

---

### Bước 6: Flutter — manual_vrs_screen (Manual mode)

**File**: `D:\Camera\Dev\Auto_VRS_Meiko_Automation_App_Flutter\App\lib\screens\vrs\manual_vrs_screen.dart`

**Thêm state**: `bool _calibrating = false`

**Thêm method `_triggerManualCalibration()`**:
- Gọi `triggerAutoBoardOffset(boardSide: currentBoardSide)`
- Snackbar kết quả: xanh (OK), cam (warning), đỏ (fail)

**Sửa UI info panel**:
- Thêm dòng "Mặt board: Mặt A (Top)" hoặc "Mặt B (Bot)"
- Thêm nút `OutlinedButton` "Calib bù lệch board" (chuyển thành spinner khi đang chạy)

---

### Bước 7: Health Check — Fiducial YOLO

**Files sửa**: `app_runtime_config.dart`, `plc_gateway_service.dart`, `startup_health_check.dart`

**`app_runtime_config.dart`**:
- Thêm key `fiducial_detector_base_url` + default `http://127.0.0.1:8191`
- Thêm getter `fiducialDetectorBaseUrl`

**`plc_gateway_service.dart`**:
- Thêm `static checkFiducialHealth()` — GET root endpoint fiducial service, check `status == 'running'`

**`startup_health_check.dart`**:
- Thêm check thứ 4 `Fiducial YOLO` vào `Future.wait` song song 4 service
- Sử dụng cùng logic adaptive interval: down → poll 5s, up → poll 60s
- `onChange` callback tự động trigger snackbar cho service mới (generic pattern)

---

## 4. Luồng dữ liệu tổng thể

```
AOI_Ingest (Python)
  │  Ghi board_code + layer_id vào tbBoard (SQLite)
  ▼
Flutter App (VRSProvider)
  │  Polling checkForNewBoard() mỗi 5s
  │  boardSideFromLayerId(layer_id) → "A"/"B"
  │  So sánh board_code + side → set calibrationNeeded
  ▼
Flutter App (vrs_main_screen)
  │  User bấm "Board tiếp theo"
  │  _runCalibrationIfNeeded()
  │    ├─ calibrationNeeded=false → skip
  │    └─ calibrationNeeded=true ─┐
  ▼                               │
PlcGatewayService.triggerAutoBoardOffset()
  │  POST /api/calib/auto-board-offset
  ▼
PLC Offset Gateway (Python FastAPI :8083)
  │  Với mỗi điểm mốc (A, C):
  │    1. board_to_plc(anchor_xy, calib_matrix) → PLC kỳ vọng
  │    2. PLC di chuyển → đến vị trí kỳ vọng
  │    3. Gateway chụp ảnh (camera tích hợp trong gateway)
  │    4. Gọi Fiducial Detector (:8191)
  │    5. YOLO detect marker → pixel offset
  │    6. pixel_offset × camera_axis_matrix⁻¹ → mm offset
  │    7. PLC "đo được" = PLC kỳ vọng - mm offset
  │  kabsch_2d(expected, measured) → R (xoay), t (tịnh tiến)
  │  Lưu offset_runtime.json
  ▼
Flutter App (advanceToNextBoard → _startWorkflow)
  │  Gọi /api/inspect-defect cho mỗi defect
  ▼
PLC Offset Gateway (/api/inspect-defect)
  │  Load offset_runtime.json → R, t
  │  apply_rigid_offset(defect_x, defect_y, R, t) → compensated_x, compensated_y
  │  Gửi compensated coords đến PLC Omron
  ▼
PLC Omron → di chuyển camera → đúng vị trí defect trên board thực tế
```

---

## 5. Thuật toán cốt lõi

**Kabsch 2D Rigid Transform** (file `bu_lech_board.py`):

Cho N ≥ 2 cặp điểm tương ứng (kỳ vọng P, đo thực tế Q):

1. Tính centroid: `c_P = mean(P)`, `c_Q = mean(Q)`
2. Trừ centroid: `P_c = P - c_P`, `Q_c = Q - c_Q`
3. Ma trận hiệp phương sai: `H = P_c^T · Q_c`
4. SVD: `U, S, V^T = SVD(H)`
5. Xoay: `R = V · diag(1, det(V·U^T)) · U^T` (đảm bảo không phản chiếu gương)
6. Tịnh tiến: `t = c_Q - R · c_P`

Apply offset: `p_compensated = R · p_nominal + t`

Với N=2: khớp tuyệt đối. Với N=3: có residual để kiểm tra lỗi đo.

---

## 6. Danh sách file đã thay đổi

### Gateway (Python)
| File | Dòng sửa | Thay đổi |
|------|----------|----------|
| `gateway/plc_offset_gateway.py` | ~321, ~328, ~1259-1285, ~1852 | InspectDefectRequest/Response fields, offset apply logic, port |

### Flutter App
| File | Thay đổi |
|------|----------|
| `lib/services/plc_gateway_service.dart` | +`triggerAutoBoardOffset()`, +`getOffsetStatus()`, +`checkFiducialHealth()`, +`AutoBoardOffsetResponse` class |
| `lib/providers/vrs_provider.dart` | +state `_currentBoardSide`/`_nextBoardSide`/`_calibrationNeeded`, +`boardSideFromLayerId()`, sửa `completeCurrentBoardAndCheckNext()`/`checkForNewBoard()`/`advanceToNextBoard()` |
| `lib/screens/vrs/vrs_main_screen.dart` | +`_calibrating` state, +`_runCalibrationIfNeeded()`, sửa `_advanceToNextBoard()`, sửa UI panel "Board tiếp theo" |
| `lib/screens/vrs/manual_vrs_screen.dart` | +`_calibrating` state, +`_triggerManualCalibration()`, +UI hiển thị mặt board + nút calib |
| `lib/services/startup_health_check.dart` | +check Fiducial YOLO (service thứ 4) |
| `lib/core/app_runtime_config.dart` | +`fiducialDetectorBaseUrlKey` + default + getter |

---

## 7. Backward Compatibility

- Board cũ không có `layer_id`/`board_code` (trước migration): `boardSideFromLayerId(null)` = `"A"`, `nextBoardIsNewPhysical` = `true` → luôn calib (an toàn)
- `apply_board_offset` default `true` nhưng nếu không có `offset_runtime.json` → dùng tọa độ gốc + log warning (không fail)
- Config mới `fiducial_detector_base_url` có default value → không cần sửa `app_config.json` nếu dùng port mặc định
- Health check mở rộng từ 3 → 4 service: `main.dart` dùng generic `onChange` callback nên không cần sửa

---

## 8. Rủi ro và hạn chế

| Rủi ro | Mức độ | Biện pháp |
|--------|--------|-----------|
| Marker bị che/hư → YOLO detect fail | Trung bình | Dialog retry/skip, operator kiểm tra board |
| Ánh sáng thay đổi → detect không chính xác | Thấp | RMS warning, retry calib |
| PLC timeout khi di chuyển đến điểm mốc | Thấp | 90s timeout, retry dialog |
| offset_runtime.json bị xóa giữa workflow | Thấp | Gateway log warning, dùng tọa độ gốc |
| Calib 2 điểm không phát hiện được board méo | Trung bình | Có thể nâng lên 3 điểm (anchorMode=3) |
