# CHECKLIST TEST — Auto Board Offset Calibration

> Ngày tạo: 2026-07-30
> Phiên bản: v1.0 — Tích hợp auto board offset vào Flutter VRS App

---

## Điều kiện tiên quyết

- [ ] PLC Gateway đang chạy (`http://localhost:8083`) — port 8083 (tích hợp sẵn điều khiển camera + PLC Omron)
- [ ] Fiducial Detector Service đang chạy (`http://127.0.0.1:8191`)
- [ ] AI Detection Service đang chạy (`http://localhost:8082`)
- [ ] QCamber Gerber Service đang chạy (`http://localhost:8686`)
- [ ] Database `autovrs.db` có dữ liệu board với `layer_id` và `board_code`
- [ ] File `vrs_calib_4diem.json` tồn tại (ma trận calib gốc)
- [ ] Board vật lý có marker fiducial (vòng tròn mốc) tại các điểm A, C

---

## 1. Health Check — Fiducial Detector (Bước 7)

### 1.1 Khởi động app khi Fiducial Service đang chạy
- [ ] Console in ra báo cáo 4 dịch vụ (QCamber, PLC Gateway, AI Detection, **Fiducial YOLO**)
- [ ] Fiducial YOLO hiện ✅ OK
- [ ] Không có snackbar cảnh báo

### 1.2 Khởi động app khi Fiducial Service CHƯA chạy
- [ ] Console in ❌ cho Fiducial YOLO
- [ ] Snackbar hiện "⚠️ Fiducial YOLO không kết nối được (http://127.0.0.1:8191)"
- [ ] Health check poll nhanh (5s) vì có service down

### 1.3 Fiducial Service phục hồi sau khi app đã khởi động
- [ ] Bật Fiducial Service lên
- [ ] Snackbar hiện "✅ Fiducial YOLO đã kết nối lại"
- [ ] Health check chuyển sang poll chậm (60s) nếu tất cả 4 service đều UP

### 1.4 Config URL tùy chỉnh
- [ ] Sửa `fiducial_detector_base_url` trong `app_config.json`
- [ ] Restart app → health check dùng URL mới

---

## 2. Gateway — Offset Apply trên /api/inspect-defect (Bước 1+2)

### 2.1 Có offset_runtime.json + apply_board_offset = true (mặc định)
- [ ] Gọi `/api/inspect-defect` với tọa độ defect
- [ ] Response có `offset_applied: true`
- [ ] Response có `nominal_coords` (tọa độ gốc) và `plc_coords` (tọa độ đã bù)
- [ ] `nominal_coords` ≠ `plc_coords` (lệch theo theta/tx/ty)
- [ ] `offset_info` chứa `theta_deg`, `tx`, `ty`, `source`, `board_id`, `board_side`
- [ ] Log gateway hiện "📐 Offset applied: Nominal=(...) → Compensated=(...)"

### 2.2 Không có offset_runtime.json
- [ ] Gọi `/api/inspect-defect` → `offset_applied: false`
- [ ] `plc_coords` = `nominal_coords` (tọa độ gốc, không bù)
- [ ] Log gateway hiện "⚠️ apply_board_offset=True nhưng không có offset_runtime.json"

### 2.3 apply_board_offset = false
- [ ] Gọi `/api/inspect-defect` với `apply_board_offset: false`
- [ ] `offset_applied: false` dù có offset_runtime.json
- [ ] PLC nhận tọa độ gốc

### 2.4 Port thống nhất
- [ ] Gateway chạy trên port 8083 (cả khi chạy trực tiếp `plc_offset_gateway.py` và qua `run_gateway.py`)

---

## 3. Flutter Service — triggerAutoBoardOffset (Bước 3)

### 3.1 Gọi thành công
- [ ] `PlcGatewayService().triggerAutoBoardOffset(boardSide: 'A')` trả `AutoBoardOffsetResponse`
- [ ] `success: true`, `thetaDeg`, `tx`, `ty`, `rmsErrorMm` có giá trị
- [ ] Timeout 90s (không bị timeout khi PLC di chuyển 2 điểm mốc)

### 3.2 Gọi thất bại (fiducial service down)
- [ ] `success: false`, `message` mô tả lỗi
- [ ] Không crash, không throw unhandled exception

### 3.3 getOffsetStatus
- [ ] `getOffsetStatus()` trả nội dung `offset_runtime.json` hiện tại
- [ ] Nếu chưa có file → trả `{"has_offset": false}`

---

## 4. VRSProvider — Side Detection + Calibration Flag (Bước 4)

### 4.1 boardSideFromLayerId() helper
- [ ] `boardSideFromLayerId('l1')` → `'A'`
- [ ] `boardSideFromLayerId('l4')` → `'A'`
- [ ] `boardSideFromLayerId('l5')` → `'B'`
- [ ] `boardSideFromLayerId('l8')` → `'B'`
- [ ] `boardSideFromLayerId(null)` → `'A'` (safe default)
- [ ] `boardSideFromLayerId('')` → `'A'`
- [ ] `boardSideFromLayerId('L3')` → `'A'` (uppercase)

### 4.2 completeCurrentBoardAndCheckNext — cùng board_code, đổi mặt (l1→l8)
- [ ] Board hiện tại: board_code='6722', layer_id='l1'
- [ ] Board tiếp theo: board_code='6722', layer_id='l8'
- [ ] `nextBoardIsNewPhysical` = `false` (cùng board_code)
- [ ] `nextBoardSide` = `'B'`
- [ ] `calibrationNeeded` = `true` (đổi mặt A→B)

### 4.3 completeCurrentBoardAndCheckNext — đổi board vật lý (khác board_code)
- [ ] Board hiện tại: board_code='6722', layer_id='l8'
- [ ] Board tiếp theo: board_code='6725', layer_id='l1'
- [ ] `nextBoardIsNewPhysical` = `true`
- [ ] `nextBoardSide` = `'A'`
- [ ] `calibrationNeeded` = `true` (board mới)

### 4.4 completeCurrentBoardAndCheckNext — cùng board_code, cùng mặt (l1→l2)
- [ ] Board hiện tại: board_code='6722', layer_id='l1'
- [ ] Board tiếp theo: board_code='6722', layer_id='l2'
- [ ] `nextBoardIsNewPhysical` = `false`
- [ ] `nextBoardSide` = `'A'`
- [ ] `calibrationNeeded` = `false` (cùng board, cùng mặt → skip calib)

### 4.5 advanceToNextBoard
- [ ] `currentBoardSide` được cập nhật = `nextBoardSide`
- [ ] `calibrationNeeded` reset = `false`

### 4.6 checkForNewBoard (polling)
- [ ] AOI_Ingest thêm board mới vào DB
- [ ] Polling phát hiện board mới, set `nextBoardSide` và `calibrationNeeded` đúng

---

## 5. Auto VRS Screen — Calibration Flow (Bước 5)

### 5.1 Board xong → hiện prompt với thông tin calib
- [ ] Workflow chạy xong hết defect của board
- [ ] UI hiện panel xanh "Đã xong board hiện tại..."
- [ ] Nếu `calibrationNeeded=true`: hiện thêm dòng "⚙️ Sẽ tự động calib bù lệch board (mặt X)"
- [ ] Nếu `calibrationNeeded=false`: KHÔNG hiện dòng calib

### 5.2 Bấm "Board tiếp theo" → calib tự động chạy
- [ ] Bấm nút → nút biến thành spinner + text "Đang calib bù lệch board..."
- [ ] PLC di chuyển đến điểm mốc A, chụp, detect marker
- [ ] PLC di chuyển đến điểm mốc C, chụp, detect marker
- [ ] Calib xong → log "📐 Calib OK: θ=... tx=... ty=... RMS=..."
- [ ] Spinner biến mất → workflow board mới bắt đầu tự động

### 5.3 Calib thành công nhưng có warning (RMS cao)
- [ ] Snackbar cam hiện warning text từ gateway
- [ ] Workflow vẫn tiếp tục bình thường

### 5.4 Calib thất bại → dialog 3 nút
- [ ] Dialog hiện "Calib bù lệch thất bại" + message lỗi
- [ ] Bấm **"Thử lại"** → retry calib (đệ quy)
- [ ] Bấm **"Bỏ qua"** → advance board + start workflow KHÔNG có offset mới
- [ ] Bấm **"Hủy"** → quay về trạng thái chờ (không advance, không start workflow)

### 5.5 calibrationNeeded = false → skip calib
- [ ] Bấm "Board tiếp theo" khi cùng board + cùng mặt
- [ ] KHÔNG gọi triggerAutoBoardOffset
- [ ] Advance + start workflow ngay lập tức

### 5.6 Lot kết thúc
- [ ] Board cuối trong lot xong → hiện panel xanh lá "Đã hoàn tất toàn bộ board..."
- [ ] Polling hoạt động — phát hiện board mới khi AOI_Ingest thêm vào

---

## 6. Manual VRS Screen — Calibration (Bước 6)

### 6.1 Hiển thị thông tin mặt board
- [ ] Info panel hiện "Mặt board: Mặt A (Top)" hoặc "Mặt B (Bot)"
- [ ] Giá trị đúng theo layer_id của board hiện tại

### 6.2 Nút "Calib bù lệch board"
- [ ] Nút OutlinedButton hiện dưới dòng "Mặt board"
- [ ] Bấm → spinner thay thế nút
- [ ] Calib thành công → snackbar xanh hiện kết quả θ/tx/ty/RMS
- [ ] Calib thất bại → snackbar đỏ hiện message lỗi
- [ ] Spinner biến mất sau khi xong (dù thành công hay thất bại)

### 6.3 Calib xong → inspect defect dùng offset mới
- [ ] Sau khi calib thủ công, di chuyển camera đến defect
- [ ] Gateway apply offset mới (verify qua log hoặc response)

---

## 7. End-to-End Full Flow

### Kịch bản 1: Board mới hoàn toàn
1. [ ] AOI_Ingest ghi board mới (board_code='7001', layer_id='l1') vào DB
2. [ ] App phát hiện board mới (polling hoặc chọn model)
3. [ ] Operator đặt board lên bàn, bấm "Board tiếp theo" hoặc "Bắt đầu"
4. [ ] Auto calib chạy: PLC di chuyển → camera chụp → YOLO detect → Kabsch tính offset
5. [ ] offset_runtime.json được tạo/cập nhật
6. [ ] Workflow bắt đầu: PLC di chuyển đến defect 1 với tọa độ ĐÃ BÙ
7. [ ] Camera chụp, AI detect, hiện kết quả
8. [ ] Lặp cho hết defect → board complete

### Kịch bản 2: Lật bo (cùng board_code, đổi l1→l8)
1. [ ] Board l1 xong → UI hiện "Lật bo rồi bấm tiếp tục" + "⚙️ Sẽ tự động calib (mặt B)"
2. [ ] Operator lật bo, bấm "Board tiếp theo"
3. [ ] Calib chạy với `boardSide='B'` → gateway dùng tọa độ anchor lật gương
4. [ ] Offset mới lưu với `board_side: "B"`
5. [ ] Workflow chạy defect trên mặt B với offset đúng

### Kịch bản 3: Cùng mặt, cùng board (l1→l2)
1. [ ] Board l1 xong, board tiếp theo cùng board_code, layer_id='l2'
2. [ ] UI hiện "Lật bo rồi bấm tiếp tục" nhưng KHÔNG hiện dòng calib
3. [ ] Bấm "Board tiếp theo" → KHÔNG gọi calib → workflow bắt đầu ngay

### Kịch bản 4: Calib fail → retry → success
1. [ ] Tắt Fiducial Service
2. [ ] Bấm "Board tiếp theo" → calib fail → dialog hiện
3. [ ] Bật Fiducial Service lên
4. [ ] Bấm "Thử lại" → calib thành công → workflow bắt đầu

### Kịch bản 5: Manual mode re-calib
1. [ ] Đang ở manual VRS screen
2. [ ] Board đã có offset cũ → bấm "Calib bù lệch board"
3. [ ] Calib mới chạy → snackbar hiện kết quả
4. [ ] Di chuyển camera đến defect → tọa độ dùng offset mới

---

## 8. Edge Cases

- [ ] Board không có `layer_id` (dữ liệu cũ trước migration) → `boardSideFromLayerId(null)` = `'A'`, `calibrationNeeded` = `true` (an toàn)
- [ ] Board không có `board_code` → `nextBoardIsNewPhysical` = `true`, `calibrationNeeded` = `true` (an toàn)
- [ ] Gateway chưa chạy khi bấm calib → timeout 90s → dialog lỗi → không crash
- [ ] Bấm "Board tiếp theo" rất nhanh 2 lần → `_calibrating=true` chặn nút, không gọi calib 2 lần
- [ ] Đóng app giữa lúc đang calib → `mounted` check ngăn setState trên widget đã dispose
- [ ] offset_runtime.json bị xóa giữa workflow → gateway log warning, dùng tọa độ gốc

---

## Ký xác nhận

| Hạng mục | Người test | Ngày | Kết quả |
|----------|-----------|------|---------|
| Health Check (mục 1) | | | ☐ Pass ☐ Fail |
| Gateway Offset (mục 2) | | | ☐ Pass ☐ Fail |
| Flutter Service (mục 3) | | | ☐ Pass ☐ Fail |
| VRSProvider Logic (mục 4) | | | ☐ Pass ☐ Fail |
| Auto VRS Screen (mục 5) | | | ☐ Pass ☐ Fail |
| Manual VRS Screen (mục 6) | | | ☐ Pass ☐ Fail |
| End-to-End (mục 7) | | | ☐ Pass ☐ Fail |
| Edge Cases (mục 8) | | | ☐ Pass ☐ Fail |
