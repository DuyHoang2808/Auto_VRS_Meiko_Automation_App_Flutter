# Kiến trúc hệ thống VRS — Flutter App (Meiko) + Backend

> **Phiên bản 3** — cập nhật sau khi xác nhận: PLC Gateway thực tế đang dùng
> nằm ở `BE_tensorRT/PLC_gateway` (không phải bản cũ trong `BE-AutoVRS`),
> việc hiệu chuẩn tọa độ Board→PLC sẽ tái dùng module
> `BE_tensorRT/Calib_Phan_Cung_VRS`, và **camera Sony (FCB-EV9520L) đã thay
> thế hoàn toàn camera SICK** trên máy VRS thực tế (đã xác nhận, xem mục 3.7).
>
> Phạm vi tài liệu:
> **Frontend**: `Auto_VRS_Meiko_Automation/App` (Flutter)
> **Backend**: kết hợp giữa `Auto_VRS_Meiko_Automation/BE-AutoVRS` (AI
> Detection, WebSocket Coordinator) và ba module tái sử dụng từ gốc dự án —
> `BE_tensorRT/PLC_gateway` (điều khiển PLC), `BE_tensorRT/Calib_Phan_Cung_VRS`
> (hiệu chuẩn tọa độ), và `Stream_camera/` (nguồn camera Sony).
>
> Phần inference AI của `BE_tensorRT` (Triton/TensorRT) **không** được dùng —
> AI Detection vẫn chạy từ `BE-AutoVRS/ai_detection_api.py` (ONNX Runtime).
> `PLC-Commutor` và `Docs/SDK_Sony` (SDK gốc) vẫn ngoài phạm vi.
>
> Toàn bộ số liệu được xác minh trực tiếp từ mã nguồn. Tài liệu
> `ARCHITECTURE_ANALYSIS.md` (10/2025) đã lỗi thời — xem mục 8.

---

## 1. Tổng quan hệ thống

VRS (Verification Station) là trạm đứng sau máy AOI để xác minh lại các lỗi
PCB mà AOI phát hiện. Kiến trúc là tập hợp nhiều service Python độc lập
(không phải một backend monolith) được Flutter điều phối, cộng với PLC Omron
để di chuyển bàn/camera và một camera Sony để chụp ảnh xác minh.

Điểm quan trọng: các module chạy thực tế **không nằm gọn trong một thư mục
duy nhất**. `BE-AutoVRS` (dưới `Auto_VRS_Meiko_Automation`) cung cấp AI
Detection và WebSocket Coordinator; còn việc điều khiển PLC, chụp ảnh, và
hiệu chuẩn tọa độ lại nằm ở các module riêng dưới `BE_tensorRT` (gốc dự án)
và một thư mục `Stream_camera/` độc lập. Khi triển khai/vận hành cần chạy
đúng tổ hợp process từ các vị trí này, không chỉ riêng `BE-AutoVRS`.

## 2. Bản đồ service & port (xác minh từ code)

| # | Service | File chính | Vị trí | Port | Giao thức |
|---|---|---|---|---|---|
| 1 | AI Detection API | `ai_detection_api.py` | `Auto_VRS_Meiko_Automation/BE-AutoVRS/` | **8082** | HTTP (FastAPI) |
| 2 | **PLC Gateway API (bản đang dùng)** | `plc_gateway_api.py` | **`BE_tensorRT/PLC_gateway/`** | **8083** | HTTP (FastAPI) |
| 3 | WebSocket Coordinator | `server/ws_coord_server.py` | `Auto_VRS_Meiko_Automation/BE-AutoVRS/` | **8765** | WebSocket (JSON) |
| 4 | Camera Sony — live view | `Stream_camera_Sony_WSK.py` (hoặc bản RTSP `Stream_camera_Sony_20260508.py`) | `Stream_camera/` (gốc dự án) | **8999** (WS) | WebSocket JPEG nhị phân |
| 5 | Camera Sony — snapshot HTTP | cùng file trên | `Stream_camera/` | **9000** (WSK) hoặc **8001** (RTSP) | HTTP GET `/snapshot` |
| 6 | QCamber (Gerber) | ngoài phạm vi | — | 8686 | HTTP REST |
| — | PLC Omron (thiết bị) | qua `ClassLibrary.dll` (pythonnet/CLR) | — | 9600 (UDP) | FINS |

`BE-AutoVRS/sick_camera_stream.py` (camera SICK, cũng cổng 8999) là **kiến
trúc cũ, đã bị thay thế** — đã xác nhận: camera Sony (`Stream_camera/`) là
nguồn camera thật đang dùng trên máy VRS, không còn chạy SICK song song.

## 3. Chi tiết từng service backend

### 3.1. AI Detection API — port 8082 (`BE-AutoVRS/ai_detection_api.py`)

Không đổi so với phiên bản trước: `POST /api/ai-detection` nhận
`image_base64`, chạy pipeline YOLO OBB + verdict engine, trả về
`detections[]`, `processed_image_base64`, `statistics`. Chi tiết đầy đủ ở
mục 3.4–3.6.

### 3.2. PLC Gateway API (bản đang dùng) — `BE_tensorRT/PLC_gateway/plc_gateway_api.py`, port 8083

Đây là **bản thay thế hoàn toàn** cho `BE-AutoVRS/plc_gateway_api.py` (bản
cũ có bug `NameError` đã nêu ở phiên bản 1 của tài liệu này). Bản mới sửa
đúng vấn đề đó và nâng cấp toàn bộ logic chờ PLC. Có file backup của bản
trước đó `plc_gateway_api_backup_260701.py` giữ lại để đối chiếu/rollback.

**Thay đổi cốt lõi so với bản cũ** (chi tiết đầy đủ trong
`PLC_gateway/Thaydoilogic.md`, tự viết bởi người phát triển dự án):

- **Bản cũ**: gửi tọa độ tới PLC → chờ cố định `plc_move_timeout_ms=2000` →
  chụp ảnh. Rủi ro: quãng đường dài thì chụp sớm (ảnh mờ/sai vị trí), quãng
  đường ngắn thì chờ dư (tăng cycle time), không thích nghi khi vùng làm
  việc thực tế tới 400×570mm và tốc độ trục ~60mm/s.
- **Bản mới**: chờ theo trạng thái PLC kết hợp ước lượng thời gian di
  chuyển:
  1. Đọc target hiện tại từ `D2810-D2811`/`D2910-D2911` trước khi gửi lệnh
     mới, tính quãng đường tới target mới (`hypot`).
  2. Ước lượng thời gian di chuyển từ tốc độ trục (`plc_axis_speed_mm_per_s`,
     mặc định 60mm/s) → tự nâng `hard_timeout` động theo quãng đường thay vì
     dùng một con số cố định.
  3. Theo dõi cụm thanh ghi trạng thái chuyển động `D466-D469`
     (`is_motion_status_active`/`is_motion_status_idle`) để biết PLC đã thật
     sự bắt đầu và kết thúc di chuyển.
  4. Chỉ cho phép chụp khi PLC báo idle **ổn định liên tiếp** nhiều lần
     (`plc_motion_idle_confirm_count`, mặc định 10 lần, poll mỗi 50ms), sau
     đó chờ thêm `plc_motion_settle_ms` (mặc định 500ms) để cơ khí dừng hẳn.
  5. Có "already in position" (dung sai 0.5mm — `PLC_ALREADY_IN_POSITION_TOLERANCE_MM`):
     nếu tọa độ mới gần trùng tọa độ hiện tại, chấp nhận ngay không chờ.
  6. Có "silent-motion fallback": nếu chắc chắn có lệnh di chuyển nhưng
     thanh ghi trạng thái không phản ánh (PLC không cập nhật D466-D469),
     hệ thống tự chuyển sang chờ theo thời gian ước lượng thay vì báo lỗi.
  - Toàn bộ tham số này cấu hình được qua `plc_gateway_config.json`
    (`GET`/`PUT /api/camera-config`), không cần sửa code.

- **Camera capture đã đổi nguồn và đã sửa bug**: bản cũ gọi
  `camera_service.capture_frame()` trong khi biến này đã bị comment (lỗi
  `NameError`). Bản mới có class `CameraService` hoàn chỉnh, lấy ảnh bằng
  **HTTP GET tới endpoint snapshot của bộ stream camera Sony**
  (`camera_snapshot_url`, mặc định `http://127.0.0.1:9000/snapshot`), đọc 2
  lần liên tiếp cách nhau 120ms để đảm bảo lấy frame mới nhất (chống cache).
  Xem mục 3.7 để biết chi tiết nguồn camera.
- **AI API URL** trong `InspectDefectRequest` mặc định đã đổi thành
  `http://192.168.0.32:8082/api/ai-detection` (một IP LAN cụ thể) thay vì
  `localhost` — gợi ý AI Detection service có thể chạy trên một máy khác
  trong mạng xưởng, cần xác nhận lại IP này còn đúng không khi triển khai.

**Danh sách endpoint** (xác nhận từ code):
- `GET /` — health check, trả về trạng thái PLC/camera/config.
- `POST /api/inspect-defect` — pipeline đầy đủ: connect PLC → đọc target
  hiện tại → gửi tọa độ mới → chờ thông minh (mục trên) → chụp snapshot Sony
  → gửi AI Detection (8082) → trả `ai_detections`, `ai_verdict`, `timing`
  chi tiết từng bước.
- `POST /api/plc/move` — endpoint đơn giản chỉ di chuyển PLC (dùng bởi
  `ws_coord_server.py`), cũng đã được nâng cấp dùng logic chờ thông minh ở
  trên thay vì `sleep(10s)` cố định như tài liệu cũ mô tả.
- `GET /api/test-plc`, `GET /api/test-plc-feedback`, `GET /api/test-camera` —
  endpoint kiểm tra kết nối từng phần.
- `GET`/`PUT /api/camera-config` — đọc/ghi cấu hình runtime
  (`plc_gateway_config.json`).

Địa chỉ thanh ghi PLC không đổi so với bản cũ: `D2810-D2811` (X, float 2
word), `D2910-D2911` (Y, float 2 word), `D3000` (trigger, int). Mới thêm:
`D466-D469` (cụm trạng thái chuyển động, dùng để chờ thông minh).

### 3.3. WebSocket Coordinator — port 8765 (`BE-AutoVRS/server/ws_coord_server.py`)

Không đổi: nhận `{type:"coords", board_id, defect_id, x, y}` từ Flutter →
gọi `POST http://localhost:8083/api/plc/move` → báo lại Flutter
`{"type":"process"}`. Vì endpoint `/api/plc/move` giờ chạy logic chờ thông
minh (mục 3.2), Coordinator sẽ được lợi tự động mà không cần sửa gì thêm.

### 3.4–3.6. Cấu hình AI, pipeline, verdict engine, ONNX Runtime

Không đổi so với phiên bản 1 của tài liệu — 11 class lỗi PCB, ngưỡng
`CONF=0.10`, pipeline multiclass→singleclass ensemble→SAM, luật OK/NG theo
`verdict_engine.py`/`standards.py`, dùng ONNX Runtime thuần (không Triton).
Về việc train/tối ưu/triển khai model vào thư mục `models/` — **theo xác
nhận của người dùng, đây là quy trình ngoài dự án này, tự đánh giá riêng,
không cần tài liệu hóa ở đây.**

### 3.7. Nguồn camera: Sony FCB-EV9520L (`Stream_camera/`, gốc dự án) — ĐÃ XÁC NHẬN thay thế SICK

Camera dùng để chụp ảnh xác minh **đã được đổi hẳn sang camera Sony
FCB-EV9520L**, không còn dùng SICK. Có 2 biến thể streamer, nằm ngoài cả
`BE-AutoVRS` lẫn `BE_tensorRT`:

**a) `Stream_camera/Stream_camera_socket/Stream_camera_Sony_WSK.py`
(WebSocket — biến thể chính)**
- Mở camera bằng OpenCV: `cv2.VideoCapture(1, cv2.CAP_DSHOW)`, fallback
  sang `cv2.CAP_MSMF` nếu DirectShow lỗi — nghĩa là camera Sony được đọc
  như một thiết bị capture chuẩn (index 1) trên Windows, không dùng giao
  thức VISCA/SDK mạng của Sony (khác với SDK trong `Docs/SDK_Sony`).
  Không có logic điều khiển pan/tilt/zoom trong script này — chỉ thuần thu
  hình.
- Cấu hình: 1920×1080, target 30 FPS, `CAP_PROP_BUFFERSIZE=1` (giảm độ
  trễ), JPEG quality 75 cho stream / 90 cho snapshot.
- **WebSocket** tại `ws://0.0.0.0:8999`, gửi JPEG nhị phân liên tục tới mọi
  client đang kết nối (khớp đúng `autovrs_websocket_service.dart`). Khi
  client vừa kết nối, server gửi ngay một bản tin JSON:
  `{"type":"connection","status":"connected","camera":"Sony_FCB-EV9520L","resolution":"1920x1080","fps":30}`.
  Server còn nhận lệnh JSON từ client: `{"command":"ping"}` → trả `pong`;
  `{"command":"snapshot"}` → trả JPEG base64 ngay qua WebSocket (không cần
  gọi HTTP); `{"command":"stop"}` → dừng server.
- **Snapshot HTTP** tại port **9000** (`ThreadingHTTPServer` riêng, chạy
  song song WebSocket): `GET /snapshot` hoặc `/snapshot.jpg` trả JPEG frame
  mới nhất (no-cache), `GET /` hoặc `/viewer.html` trả trang xem thử. Đây
  chính là endpoint `plc_gateway_api.py` gọi trong `/api/inspect-defect`.

**b) `Stream_camera/Stream_camera_rtsp/Stream_camera_Sony_20260508.py`
(RTSP — biến thể thay thế)**
- Cùng cách đọc camera (OpenCV index 1), nhưng đẩy frame ra ngoài qua
  **subprocess `ffmpeg`** (đường dẫn mặc định
  `D:\Driver\ffmpeg-2026-05-06-...\ffmpeg.exe`, encode H.264
  `libx264 -tune zerolatency`) tới `rtsp://localhost:8554/mystream` — khớp
  chính xác với `autoVrsRtspUrl` mặc định trong `app_runtime_config.dart`
  phía Flutter (`rtsp://192.168.10.165:8554/mystream`) và với đường dẫn
  ffmpeg hard-code từng ghi nhận trong `autovrs_websocket_service.dart`.
  Snapshot HTTP riêng tại port **8001**.

Chọn dùng biến thể nào quyết định giá trị `camera_snapshot_url` trong
`plc_gateway_config.json` (xem `PLC_gateway/camera_config_guide.md`) — biến
thể WebSocket (port 9000) là cấu hình khuyến nghị mặc định.

### 3.8. Hiệu chuẩn tọa độ Board → PLC (`BE_tensorRT/Calib_Phan_Cung_VRS/`)

Theo xác nhận của người dùng: máy VRS **có** cần hiệu chuẩn Board→PLC, và sẽ
**tái sử dụng module này** thay vì viết mới. Module gồm 2 phương pháp độc
lập, cả hai hiện là **công cụ CLI ngoại tuyến** (không phải API/service),
sinh ra file JSON hệ số để nơi khác đọc:

**a) Calib lưới đa điểm — `Calib_OXY/`** (hiệu chuẩn toàn máy, làm 1 lần)
- `Calib_vrs_v2.py`: đọc bảng điểm PLC↔Board thực đo từ Excel
  (`Calibration_Template_VRS2.xlsx`, sheet `GRID_CALIB`), dùng
  `cv2.estimateAffine2D` để fit ma trận affine PLC→Board theo bình phương
  tối thiểu trên toàn bộ điểm, rồi nghịch đảo ma trận đó (Board→PLC), lưu
  vào `vrs_calib_config.json` (`M_inv`, ma trận 2×3).
- `Tinh_XY_PLC_v2.py`: công cụ CLI đọc `M_inv` từ JSON, cho nhập tọa độ
  Board (mm) và in ra tọa độ PLC tương ứng
  (`X_plc = M_inv[0,0]*X_b + M_inv[0,1]*Y_b + M_inv[0,2]`, tương tự cho Y).
  **Đây hiện là công cụ vận hành thủ công, chưa phải hàm/API được gọi tự
  động trong `plc_gateway_api.py`.**

**b) Calib 4 điểm + bù lệch board theo thời gian thực — `Calib_4diem/`**
- `Calib_4diem.py`: hiệu chuẩn ban đầu bằng mô hình bilinear 8 tham số
  (`c0..c3`, `d0..d3`, giải bằng `lstsq` từ ≥4 điểm góc board), lưu vào
  `vrs_calib_4diem.json`. Đây là hiệu chuẩn **gốc, cố định, làm 1 lần lúc
  lắp máy**.
- `bu_lech_board.py`: dùng mỗi khi **gá board mới** (có thể lệch 1-2mm do
  khe hở cơ khí jig) mà không cần calib lại từ đầu — đo lại 3 điểm mốc thực
  tế trên board mới, dùng **thuật toán Kabsch/Procrustes 2D** (SVD) để tìm
  phép xoay + tịnh tiến rigid tối ưu khớp giữa vị trí board mới và calib
  gốc, báo sai số dư RMS, lưu hệ số bù vào `offset_runtime.json`. Sau đó mọi
  điểm gia công trên board mới đều được áp phép bù này
  (`board_to_plc()` bilinear gốc → `apply_rigid_offset()` bằng R, t).

**Khoảng trống cần lưu ý khi tích hợp**: cả hai bộ công cụ calib hiện là CLI
tương tác (nhập tay qua `input()`), sinh ra file JSON tĩnh. `plc_gateway_api.py`
hiện tại (mục 3.2) nhận tọa độ đã ở hệ PLC sẵn (comment trong code:
"already scaled in plc_coor column" — nghĩa là tọa độ PLC được tính sẵn từ
trước, lưu trong cột `plc_coor` của dữ liệu lỗi, chứ gateway không tự quy
đổi Board→PLC tại runtime). Vì vậy, để dùng calib này trong vận hành tự
động, cần **một bước tích hợp còn thiếu**: hoặc (i) nhúng hàm quy đổi
`M_inv`/bilinear+offset vào chính pipeline nạp dữ liệu lỗi (khi ghi cột
`plc_coor` vào SQLite), hoặc (ii) thêm bước gọi hàm quy đổi ngay trong
`plc_gateway_api.py`/`ws_coord_server.py` trước khi gửi lệnh PLC. Đây là
việc cần làm tiếp, không tự động có sẵn.

## 4. Chi tiết Flutter App (Meiko)

### 4.1. Cấu hình & dependency

- Package: `autovrs_app`. State management: **Provider**. Routing:
  **go_router** (`lib/core/routes.dart`; có file `routes_new.dart` tồn tại
  song song nhưng không được import ở đâu — code thừa, có thể xóa).
- Dependency chính (`pubspec.yaml`): `provider ^6.1.2`, `go_router ^14.6.1`,
  `sqflite ^2.3.3` + `sqflite_common_ffi ^2.3.0` (SQLite desktop Windows),
  `web_socket_channel ^2.4.0`, `http ^1.2.2`, `hive ^2.2.3`,
  `flutter_vlc_player ^7.4.4` (khác biệt so với bản AutoVRS-Application
  gốc), `camera ^0.10.6`, `fl_chart ^0.69.2`.

### 4.2. Endpoint thực tế app đang gọi

| Service Flutter | Gọi tới | Khớp backend |
|---|---|---|
| `ai_detection_service.dart` | `POST {aiBaseUrl}/api/ai-detection` → `http://localhost:8082/...` | `ai_detection_api.py` |
| `plc_gateway_service.dart` | `POST {plcGatewayBaseUrl}/api/inspect-defect`, `GET /api/test-plc` → `http://localhost:8083` | `plc_gateway_api.py` (nay là bản `BE_tensorRT/PLC_gateway`) |
| `coord_ws_client.dart` | `ws://127.0.0.1:8765`, gửi `{type:"coords", board_id, defect_id, x, y}` | `ws_coord_server.py` |
| `autovrs_websocket_service.dart` | `ws://192.168.10.165:8999` (IP LAN thật, không phải localhost), nhận JPEG nhị phân; fallback RTSP qua ffmpeg subprocess | camera Sony FCB-EV9520L (`Stream_camera/`, mục 3.7) |
| `qcamber_gerber_service.dart` | `POST http://localhost:8686/api/capture` | QCamber (ngoài BE-AutoVRS) |

Ghi chú kỹ thuật cần dọn trước khi triển khai chính thức:
- `ai_detection_service.dart` và `autovrs_websocket_service.dart` có
  đường dẫn lưu ảnh debug hard-code kiểu máy dev cũ
  (`C:/Users/sonng/OneDrive/Desktop/APPAutoVRS/BE-AutoVRS/images_ai`).
- Đường dẫn ffmpeg hard-code (`D:\Ps_Duy\Driver\ffmpeg-...`) không portable
  sang máy khác.
- `video_frame_service.dart` (cổng 8081) đã bị vô hiệu hóa/không đăng ký
  Provider — thay thế hoàn toàn bởi `autovrs_websocket_service.dart` (8999).
- `api_service.dart` chỉ là wrapper rỗng, không gọi HTTP thật.

### 4.3. Cấu trúc thư mục `lib/`

```
lib/
├── main.dart
├── core/
│   ├── app_runtime_config.dart   # cấu hình endpoint tập trung
│   └── routes.dart               # go_router
├── providers/
│   ├── auth_provider.dart
│   ├── navigation_provider.dart
│   ├── statistics_provider.dart
│   └── vrs_provider.dart
├── services/
│   ├── ai_detection_service.dart
│   ├── plc_gateway_service.dart
│   ├── coord_ws_client.dart
│   ├── autovrs_websocket_service.dart
│   ├── qcamber_gerber_service.dart
│   ├── local_database_service.dart
│   └── flutter_camera_service.dart
├── screens/
│   └── vrs/
│       ├── vrs_main_screen.dart      # chế độ tự động
│       ├── manual_vrs_screen.dart    # chế độ thủ công
│       └── ...
└── widgets/
```

### 4.4. Khởi động app (`main.dart`)

Thứ tự khởi tạo: `sqfliteFfiInit()` (desktop) → `Hive.initFlutter()` →
`LocalDatabaseService` mở DB → `AppRuntimeConfig.instance.initialize()`
(đọc `app_config.json` nếu có) → `runApp` với các Provider:
`NavigationProvider`, `AuthProvider`, `VRSProvider`, `StatisticsProvider`,
`AutoVRSWebSocketService`, `AIDetectionService`, `QCamberGerberService`,
`FlutterCameraService`.

### 4.5. Luồng UX xử lý lỗi AOI

**Chế độ tự động (`vrs_main_screen.dart`)**: lắng nghe message `process` từ
`CoordWsClient` → lấy frame hiện tại từ `AutoVRSWebSocketService` → gọi
`AIDetectionService.detectDefects()` → hiển thị kết quả + gửi ngược lại
Coordinator → lưu verdict vào SQLite → tự động chuyển sang lỗi kế tiếp.

**Chế độ thủ công (`manual_vrs_screen.dart`)**: tự kết nối camera +
Coordinator độc lập, tải danh sách defect theo `board_id` từ SQLite, tải
song song ảnh Gerber (qua `qcamber_gerber_service.dart`) và ảnh AOI để đối
chiếu, cho phép người vận hành tự chọn phán quyết OK/NG ghi vào `tbDefect`.

### 4.6. Schema SQLite (`local_database_service.dart`, version 1)

```sql
tbModel  (id_model PK, name, line_size, space_size, url_gerber)
tbLot    (id_lot PK, NG_rate, fakeDef, board_quantity, tbModelid_model FK)
tbBoard  (id_board PK, defect_quantity, erro_quantity, tbLotid_lot FK)
tbDefect (id_defect PK, type, judgement, height, width, time,
          coordinates, url_image, tbBoardid_board FK)
tbConfig (config_key PK, config_value)
```

Vị trí file DB: `%USERPROFILE%\Documents\AutoVRS\autovrs.db`. Code có logic
migrate cột thủ công — cho thấy schema đã tiến hóa qua nhiều phiên bản, cần
cẩn trọng khi thêm cột mới.

## 5. Luồng nghiệp vụ end-to-end

1. Máy AOI phát hiện bất thường trên PCB. **Cơ chế đưa dữ liệu lỗi (tọa độ +
   ảnh) sang app VRS đã được quyết định là gọi API, nhưng API này CHƯA được
   xây dựng** — hiện tại đây là khoảng trống cần phát triển tiếp (xem mục 6).
2. Vận hành viên chọn model/lot/board, bấm bắt đầu trên `vrs_main_screen.dart`.
3. Flutter gửi tọa độ lỗi qua WebSocket 8765 tới `ws_coord_server.py`.
4. Coordinator gọi `POST /api/plc/move` (port 8083, **nay là
   `BE_tensorRT/PLC_gateway/plc_gateway_api.py`**) → PLC Omron di chuyển bàn
   XY, gateway chờ theo logic thông minh mới (đọc D466-D469, ước lượng theo
   quãng đường, không còn chờ cố định) thay vì timeout 10s cứng như trước.
5. Coordinator báo lại Flutter khi di chuyển xong.
6. Flutter (hoặc trực tiếp `plc_gateway_api.py` nếu dùng `/api/inspect-defect`)
   lấy ảnh — nguồn ảnh là **camera Sony FCB-EV9520L** qua snapshot HTTP
   (port 9000/8001, mục 3.7) — gửi `image_base64` sang
   `POST /api/ai-detection` (port 8082).
7. Backend chạy pipeline YOLO OBB (multiclass → fallback ensemble
   singleclass → SAM nếu cần đo kích thước) → `VerdictEngine` áp luật ra
   OK/NG, trả về ảnh đã annotate + danh sách lỗi.
8. Flutter hiển thị kết quả lớn trên khung phán định, lưu vào SQLite cục
   bộ, gửi kết quả về Coordinator (chỉ để log), rồi tự động chuyển sang
   lỗi kế tiếp trên cùng board.
9. Nếu cần đối chiếu thủ công, vận hành viên chuyển sang
   `manual_vrs_screen.dart` để xem lại từng lỗi, so ảnh AOI với ảnh Gerber
   gốc, tự phán định.

Bước hiệu chuẩn Board→PLC (mục 3.8) hiện xảy ra **trước** toàn bộ luồng này,
mang tính offline/thiết lập máy (calib gốc + bù lệch khi gá board mới), chưa
phải một bước realtime trong pipeline trên.

## 6. Vấn đề kỹ thuật cần xử lý (đã cập nhật theo phản hồi)

- ~~Bug `NameError` ở `/api/inspect-defect`~~ — **đã được sửa** trong bản
  mới tại `BE_tensorRT/PLC_gateway/plc_gateway_api.py`. Chỉ còn tồn tại
  trong bản cũ ở `BE-AutoVRS/plc_gateway_api.py` — **khuyến nghị ngừng chạy
  bản cũ này để tránh nhầm lẫn** (hai bản cùng expose port 8083).
- **Cơ chế nạp dữ liệu lỗi từ AOI vào SQLite: đã quyết định dùng API,
  nhưng API đó CHƯA được xây dựng.** Đây là hạng mục phát triển còn thiếu,
  cần thiết kế: endpoint nhận gì (tọa độ Board mm hay pixel? ảnh AOI gốc?
  định danh board/lot nào?), ai gọi (máy AOI gọi sang VRS, hay VRS poll từ
  AOI?), và ghi vào bảng nào trong schema hiện có (`tbBoard`, `tbDefect`).
- **Tích hợp calib Board→PLC vào pipeline runtime còn thiếu** (mục 3.8) —
  hiện là công cụ CLI ngoại tuyến, cần một bước code nối `M_inv`/bilinear+
  offset vào quy trình ghi `plc_coor` hoặc vào chính gateway.
- ~~Xác nhận nguồn camera thật~~ — **đã xác nhận**: camera Sony
  FCB-EV9520L qua `Stream_camera/` là nguồn thật đang dùng, SICK
  (`BE-AutoVRS/sick_camera_stream.py`) không còn chạy (mục 3.7). **Khuyến
  nghị**: có thể xóa hoặc archive `sick_camera_stream.py`/`run_sick_camera.py`
  trong `BE-AutoVRS` để tránh nhầm lẫn/khởi động nhầm process, vì cả hai
  cùng cố định lắng nghe cổng 8999.
- **AI API URL hard-code `http://192.168.0.32:8082`** trong
  `plc_gateway_api.py` mới — cần xác nhận đây có phải IP máy chạy AI
  Detection thật trong xưởng hay là sót lại từ môi trường dev.
- Model ONNX (11 singleclass + 1 multiclass): theo xác nhận của người
  dùng, việc huấn luyện/tối ưu/triển khai vào `models/` là **quy trình
  ngoài phạm vi dự án này, tự đánh giá riêng** — không cần theo dõi thêm ở
  tài liệu kiến trúc.
- Các mục còn lại từ phiên bản 1 (đường dẫn hard-code máy dev trong
  `ai_detection_service.dart`/`autovrs_websocket_service.dart`, code thừa
  `routes_new.dart`/`video_frame_service.dart`/`api_service.dart`, code
  legacy `multiclass_detector.py`/`singleclass_detector.py` dùng `.pt`) vẫn
  còn nguyên, chưa có xác nhận mới.
- **Bug đường dẫn tương đối** trong `BE-AutoVRS/ai_detection_api.py` sinh ra
  thư mục lồng `BE-AutoVRS\BE-AutoVRS\Image_input|Image_output` — nên đổi
  sang đường dẫn tuyệt đối hoặc dùng `os.path` tương đối theo vị trí file
  script.

## 7. So sánh nhanh với phần AI của `BE_tensorRT` (không dùng ở đây)

| | Đang dùng (Meiko + BE-AutoVRS + module tái dùng từ BE_tensorRT) | BE_tensorRT gốc (không dùng phần AI) |
|---|---|---|
| Inference engine | ONNX Runtime thuần (`BE-AutoVRS`) | Triton Inference Server |
| PLC Gateway | **`BE_tensorRT/PLC_gateway`** (đã nâng cấp, tái dùng) | (không áp dụng — cùng nguồn) |
| Hiệu chuẩn phần cứng | **`BE_tensorRT/Calib_Phan_Cung_VRS`** (tái dùng) | (không áp dụng — cùng nguồn) |
| Camera | Sony FCB-EV9520L qua `Stream_camera/` (đã thay SICK hoàn toàn) | không thuộc phạm vi |

Lưu ý: ba module `PLC_gateway`, `Calib_Phan_Cung_VRS`, và gián tiếp là
`Stream_camera`, tuy nằm trong cây thư mục `BE_tensorRT` nhưng **được tái sử
dụng trực tiếp cho hệ thống Meiko + BE-AutoVRS**, khác với phần AI
inference (Triton/TensorRT) của `BE_tensorRT` là không dùng.

## 8. Đối chiếu với tài liệu cũ `ARCHITECTURE_ANALYSIS.md`

| Nội dung tài liệu cũ (10/2025) | Đánh giá |
|---|---|
| Port 8082 – AI Detection | Đúng |
| Port 8686 – QCamber | Đúng |
| Port 12345 – AutoVRS WebSocket | **Sai/lỗi thời** — đã đổi hẳn sang port 8999 với IP LAN thật, giao thức JPEG nhị phân thô |
| Port 8081 – Video Frame | Giá trị còn trong config mặc định nhưng service tương ứng đã bị vô hiệu hóa, không dùng |
| PLC Gateway API (8083) | **Thiếu hoàn toàn** trong tài liệu cũ — đây là service trung tâm nối AI + PLC |
| WebSocket Coordinator (8765) | **Thiếu hoàn toàn** trong tài liệu cũ — đóng vai trò điều phối chính của luồng tự động |

Kết luận: tài liệu cũ mô tả một phiên bản/nhánh kiến trúc khác hoặc đã lỗi
thời đáng kể, không nên dùng làm tham chiếu cho việc phát triển tiếp trên
cặp Flutter Meiko + BE-AutoVRS. Tài liệu hiện tại (`KIEN_TRUC_HE_THONG_VRS.md`)
thay thế vai trò tham chiếu chính thức đó.

## 9. Câu hỏi còn để ngỏ

- Endpoint nạp dữ liệu lỗi AOI→VRS: thiết kế cụ thể (request/response,
  ai gọi ai, dữ liệu nào) — cần xây dựng mới, xem mục 6.
- Cách tích hợp calib Board→PLC (`Calib_Phan_Cung_VRS`) vào pipeline runtime:
  nhúng vào bước nạp dữ liệu lỗi, hay vào chính `plc_gateway_api.py`/
  `ws_coord_server.py`?
- IP `192.168.0.32` (AI Detection URL mặc định trong `plc_gateway_api.py`
  mới) có phải địa chỉ máy chạy AI Detection thật trong xưởng không?
- Có cần dọn/ngừng hẳn bản `plc_gateway_api.py` cũ trong `BE-AutoVRS` để
  tránh nhầm lẫn hai service cùng expose cổng 8083 không?
