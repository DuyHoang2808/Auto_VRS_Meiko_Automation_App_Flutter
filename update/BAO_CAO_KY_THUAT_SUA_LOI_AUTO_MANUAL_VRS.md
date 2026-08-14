# Báo Cáo Kỹ Thuật — Sửa Lỗi Mất Tiến Độ & Calib Lại Khi Chuyển Auto VRS ↔ VRS Thủ Công

> Ngày: 2026-08-06
> Dự án: AutoVRS Meiko Automation
> Phạm vi: Flutter App (`App/lib`) + PLC Offset Gateway (`AutoBoardOffset_YOLO_2Mat/gateway`)

---

## 1. Lỗi được báo

**Hiện tượng**: Đang chạy Auto VRS → bấm "Dừng" → chuyển sang VRS thủ công (board đã calib bù lệch) → xác nhận 1 lỗi → quay lại Auto VRS → bấm "Bắt đầu". Kết quả: hệ thống **calib lại từ đầu** và **soi lại từ lỗi #1**, kể cả các lỗi đã phán định.

**Nguyên nhân gốc**: Router dùng `GoRoute(builder:)` (`core/routes.dart:36-45`), sidebar dùng `context.go` → chuyển tab **dispose** `VRSMainScreen`. Toàn bộ tiến độ soi nằm trong state tạm của widget:

```dart
List<Map<String, dynamic>> _defects = [];   // mất khi dispose
int _currentIndex = 0;                       // con trỏ tiến độ - mất khi dispose
bool _running = false;
int _runId = 0;
```

Khi quay lại, `initState` chạy lại từ đầu → `_defects = []`, `_currentIndex = 0`, dẫn tới:

1. `_hasPausedProgressFor()` mở đầu bằng `if (_defects.isEmpty ... ) return false` → **không hiện dialog resume**.
2. `_startWithCalibration()` rơi thẳng xuống nhánh calib → chạy đủ chu kỳ calib 90s.
3. `_startWorkflow()` set `_currentIndex = 0` → soi lại lỗi #1 đã phán định.

**Nguyên tắc sửa**: `tbDefect.judgement` trong DB làm nguồn sự thật cho tiến độ (AOI_Ingest chèn lỗi mới **không** kèm cột `judgement` nên lỗi chưa soi luôn có `judgement IS NULL` — xem `insert_defects` trong `aoi_ingest_service.py:405-414`). Trạng thái calib chuyển sang `VRSProvider` (được tạo TRÊN router trong `main.dart` nên sống suốt phiên), **có xác minh lại với gateway** trước khi tin.

---

## 2. Tổng hợp các lỗi đã sửa

| # | Lỗi | Mức độ | File |
|---|-----|--------|------|
| 1 | Auto ghi `type='none'` cho mọi lỗi OK → xoá dần loại lỗi gốc AOI | **Mất dữ liệu** | `vrs_main_screen.dart`, `manual_vrs_screen.dart`, `local_database_service.dart` |
| 2 | `offset_applied` không được parse → soi cả board ở toạ độ chưa bù lệch | **An toàn máy** | `plc_gateway_service.dart`, `vrs_main_screen.dart` |
| 3 | Không có lock PLC → 2 lệnh cùng ghi D2810/D2910 | **An toàn máy** | `plc_offset_gateway.py`, `plc_gateway_service.dart` |
| 4 | Board 0 lỗi làm `_running` kẹt true vĩnh viễn + treo health-check | Cao | `vrs_main_screen.dart` |
| 5 | Double-tap "Bắt đầu" → 2 chu kỳ calib 90s song song | **An toàn máy** | `vrs_main_screen.dart` |
| 6 | Mất tiến độ soi khi chuyển tab (lỗi được báo) | Cao | `vrs_main_screen.dart`, `local_database_service.dart` |
| 7 | Calib lại dù board đã calib (lỗi được báo) | Cao | `vrs_provider.dart`, `plc_gateway_service.dart`, 2 screen |
| 8 | `didChangeDependencies` ở màn manual không bao giờ chạy lại | Trung bình | `manual_vrs_screen.dart` |
| 9 | VRS thủ công không bao giờ hoàn tất board | Trung bình | `manual_vrs_screen.dart` |
| 10 | Nút "Bắt đầu" còn bật khi `currentBoard` trỏ board đã xong | Cao | `vrs_main_screen.dart` |
| 11 | `getOffsetStatus()` không truyền `board_side` → luôn đọc mặt A | Trung bình | `plc_gateway_service.dart` |
| 12 | `inspectDefect` nuốt `detail` của lỗi non-200 | Thấp | `plc_gateway_service.dart` |

---

## 3. Chi tiết từng lỗi

### 3.1. Ghi đè `type` làm mất loại lỗi gốc AOI (mất dữ liệu)

**Vấn đề**: `vrs_main_screen.dart` khi lưu kết quả AI:

```dart
final detectedType = hasDetections
    ? (result.aiDetections!.first['class_name']?.toString() ?? 'none')
    : 'none';
...
final updateFields = {'type': detectedType, ...};   // ← ghi ĐÈ lên type
```

Mỗi lỗi phán định **OK** (AI không thấy gì) sẽ biến `type` thành chuỗi `'none'`. Vì auto là luồng chính, cột `type` bị xoá dần trên toàn DB.

Màn thủ công cũng vậy nhưng hẹp hơn: `detectedType` khởi tạo `''` và chỉ được gán khi `detections.isNotEmpty`. Đáng lưu ý là `_hasAnalysisResult` vẫn `true` khi AI trả về 0 detection (`manual_vrs_screen.dart:515-528`, điều kiện chỉ là `result != null && result.success`), nên nút OK/NG vẫn bật và ghi `type = ''` — đúng ở trường hợp phổ biến nhất của soi thủ công.

**Ảnh hưởng**:
- `getDefectStatistics()` (`GROUP BY type`) → sinh ra một nhóm `'none'` phình dần.
- Tiêu đề trong `DefectListWidget`.
- 2 chỗ load Gerber truyền `defectType: defect['type']`. **Đính chính so với bản báo cáo đầu**: field này KHÔNG được gửi cho QCamber — payload chỉ có `jobName`/`layerName`/`x`/`y`/`zoom`, `defectType` chỉ vào `_lastMetadata` để hiển thị/ghi log. Nên nhánh Gerber **không** bị sai về mặt chức năng như đã nêu trước đó.

**Cách sửa**: tách cột, không sửa điều kiện ghi.

```
tbDefect:
  type      TEXT   ← loại lỗi AOI báo. CHỈ AOI_Ingest ghi, không ai ghi đè
  ai_type   TEXT   ← MỚI: loại lỗi AI/người vận hành nhận định khi soi
  judgement TEXT   ← OK/NG
```

- Migration theo đúng pattern `PRAGMA table_info` có sẵn: `ALTER TABLE tbDefect ADD COLUMN ai_type TEXT`.
- Thêm `ai_type` vào cả `_createTables` **và** `_rebuildTbDefectWithTextUrlImage` — hàm rebuild `SELECT ai_type` nên cột phải tồn tại trước; migration được đặt trước chỗ gọi rebuild.
- Thêm hàm dùng chung `defectTypeForDisplay()` trong `local_database_service.dart` (cả 3 file đều đã import file này) cho mọi chỗ *hiển thị*: ưu tiên `ai_type`, fallback `type`. Thứ tự ưu tiên này được chốt ở §8.1 — bản đầu làm ngược và gây lỗi hiển thị mã số AOI.
- Việc *lưu trữ* thì ngược lại: `type` là nguồn sự thật của AOI, không ai ghi đè; `getDefectStatistics()` (`GROUP BY type`) dựa vào nó để truy vết.

> **Lưu ý vận hành**: dữ liệu đã bị ghi `'none'`/`''` trước bản sửa này **không phục hồi được**. Bản sửa chỉ chặn từ nay. Cần thông báo cho bên dùng số liệu thống kê.

### 3.2. Soi ở toạ độ chưa bù lệch mà không có dấu hiệu nào (an toàn máy)

**Vấn đề**: Khi không tìm thấy offset runtime cho mặt board, gateway **âm thầm dùng toạ độ nominal chưa bù** và vẫn trả `success: true`:

```python
# plc_offset_gateway.py — nhánh else của apply_board_offset
logger.warning("⚠️ apply_board_offset=True nhưng không có offset runtime ... → dùng tọa độ nominal")
```

Gateway *có* báo qua field `offset_applied: false`, nhưng `InspectDefectResponse.fromJson` **không parse field này**. Kết quả: Auto VRS có thể soi hết cả board ở toạ độ sai mà operator không biết gì.

**Cách sửa**:
- Thêm `offsetApplied` + `offsetInfo` vào `InspectDefectResponse`.
- Auto: `offset_applied == false` → **dừng workflow + dialog** (không phải snackbar), và **KHÔNG lưu phán định** — lưu vào sẽ là verdict sai gắn cho lỗi đó.
- Truyền `boardId` vào cả 3 chỗ gọi `triggerAutoBoardOffset` (trước đây không nơi nào truyền, nên `offset_info.board_id` luôn `null`, không thể xác minh danh tính — điều kiện bắt buộc cho §3.7).

### 3.3. Không có lock PLC (an toàn máy)

**Vấn đề**: Mỗi endpoint tạo `PLCService()` riêng, kèm comment sai:

```python
plc = PLCService()  # instance riêng mỗi request -> an toàn khi có request đồng thời
```

Comment này chỉ đúng về state Python. Cả 7 endpoint đều ghi vào **cùng các thanh ghi vật lý** `D2810/D2910/D3000` của **một** con PLC. Hai request song song sẽ ghi toạ độ đan xen, rồi mỗi bên `wait_for_plc_position` trên vị trí do bên kia vừa đặt.

Phía app cũng không chặn được: mỗi màn hình tự tạo instance riêng (`vrs_main_screen.dart` và `manual_vrs_screen.dart` đều có `final PlcGatewayService _plcGateway = PlcGatewayService();`) nên cờ mức instance vô dụng.

Kịch bản thật: Auto đang `/api/inspect-defect` trong khi operator bấm "Di chuyển Camera" ở tab thủ công.

**Cách sửa — 2 tầng**:

*Gateway* (`plc_offset_gateway.py`) — decorator dùng `asyncio.Lock`, trả **409 Conflict** khi đang bận:

```python
@app.post("/api/plc/move", response_model=MoveResponse)
@plc_exclusive("di chuyển PLC (/api/plc/move)")
async def move_camera_simple(request: MoveRequest): ...
```

Đặt decorator **dưới** `@app.post(...)` để FastAPI vẫn đọc được signature gốc (`functools.wraps` giữ `__wrapped__` nên `inspect.signature` xuyên qua được).

Cố tình **trả 409 thay vì xếp hàng**: một lệnh calib 90s âm thầm chờ rồi bất ngờ chạy sau khi operator đã quên mình từng bấm thì nguy hiểm hơn là báo "đang bận" ngay.

7 endpoint được bọc: `/api/plc/move`, `/api/plc/move_bulech`, `/api/inspect-defect`, `/api/test-plc`, `/api/test-plc-feedback`, `/api/calib/auto-board-offset`, `/api/calib/camera-axis`.

*App* (`plc_gateway_service.dart`) — single-flight **static** (phải static vì 2 instance riêng), trả thông báo "PLC đang bận" thay vì gửi lệnh.

> Chốt ở tầng gateway là bắt buộc, không thể chỉ chốt ở app: gateway còn có client khác — các script/GUI trong `Auto_calib` gọi trực tiếp cùng cổng.

### 3.4. Board 0 lỗi làm treo Auto VRS

**Vấn đề**: `_startWorkflow` set `_running = true` + `StartupHealthCheck.setBusy(true)`, rồi `_inspectCurrentDefect` gặp danh sách rỗng và chỉ `return` mà **không reset gì**:

```dart
if (defectsForBoard.isEmpty) {
  debugPrint('...no defects found...');
  return;                       // ← _running vẫn true mãi
}
```

AOI_Ingest **có** tạo board 0 lỗi cho board tốt (`insert_defects` trả 0 khi rỗng, `insert_board` nhận `defect_quantity=len(defects)`).

Hậu quả: nút "Bắt đầu" tắt vĩnh viễn (chỉ "Dừng" thoát được), board không bao giờ `completed`, và `setBusy(true)` treo health-check cả session — `StartupHealthCheck._tick` cứ reschedule rồi skip, nên operator **không còn nhận được cảnh báo service chết** nữa.

Cùng lớp lỗi: `catch` cuối `_inspectCurrentDefect` chỉ `debugPrint`, để lại `_running=true` + `_processingDefectId` (chấm xanh "đang xử lý" không tắt) + `setBusy(true)`. Trigger cụ thể: `getDefectsByBoard` không có retry khi DB bị AOI_Ingest lock (chỉ `updateDefect` có retry).

**Cách sửa**: thêm `_abortWorkflow(reason)` — reset `_running`, `_processingDefectId`, `setBusy(false)`, bump `_runId`, hiện snackbar. Mọi đường thoát bất thường đi qua đây. Board 0 lỗi thì đi đường hoàn tất tử tế (`_finishBoard`) kèm thông báo.

### 3.5. Double-tap "Bắt đầu" → 2 chu kỳ calib song song

**Vấn đề**: `_startWithCalibration` `await getBoardById(...)` **trước khi** set `_calibrating = true`. Trong khoảng đó nút vẫn bật → 2 lần bấm nhanh = 2 chuỗi calib 90s cùng ghi vào D2810/D2910. Việc thêm pre-flight đọc DB ở §3.6 còn làm cửa sổ này rộng hơn.

Ngoài ra `_running = false` được set **trước** đuôi hoàn tất (`completeCurrentBoardAndCheckNext` + `movePlc` về gốc, timeout 30s) → bấm "Bắt đầu" trong giai đoạn đó chạy calib song song với lệnh về gốc.

**Cách sửa**:
- Cờ `_busy` set **đồng bộ** (trước mọi `await`) trong wrapper `_startWithCalibration`, phủ trọn: pre-flight → calib → soi → đuôi hoàn tất. Nút gate theo cờ này.
- Bump `_runId` ngay đầu `_startWithCalibration` **và** `_advanceToNextBoard` — trước đây chỉ `_startWorkflow` bump, nên trong suốt 90s calib không có gì vô hiệu hoá chuỗi cũ đang chờ PLC.

### 3.6. Tiến độ soi lấy từ DB (lỗi được báo)

**Cách sửa**:

Thêm 2 hàm thuần trong `local_database_service.dart`:

```dart
bool isDefectJudged(Map<String, dynamic> defect);            // judgement null/rỗng = chưa phán định
int  firstUnjudgedDefectIndex(List<Map<String, dynamic>>);   // -1 nếu đã phán định hết
```

Thêm `resetBoardForReinspection(idBoard)` — xoá `judgement`/`ai_type`/`time` của board + đưa `tbBoard.status` về `'pending'`. **Bắt buộc** vì `getNextPendingBoard` và `getFirstBoardByLotId` đều lọc bỏ board `'completed'`; không reset thì board đã hoàn tất **không bao giờ chọn lại được**. Chỉ xoá `judgement`, giữ nguyên `type` — đây là lý do §3.1 phải làm trước.

**Pre-flight 4 trạng thái, chạy TRƯỚC calib** (thay cho `_hasPausedProgressFor`):

| Trạng thái | Điều kiện | Xử lý |
|---|---|---|
| `empty` | 0 lỗi | Hoàn tất board ngay, **không calib** |
| `fresh` | chưa lỗi nào phán định | Calib + soi từ lỗi đầu |
| `partial` | có lỗi đã phán định, còn lỗi chưa | Dialog resume/restart |
| `complete` | phán định hết | Dialog "đã soi xong" → chọn hoàn tất hoặc soi lại từ đầu |

Phải chạy **trước** calib: nếu để sau, board rỗng/đã xong vẫn tốn nguyên chu kỳ PLC 90s rồi mới phát hiện chẳng có gì để làm. Trạng thái `complete` **không được âm thầm hoàn tất** — lý do ở đoạn `resetBoardForReinspection` phía trên.

Các sửa đi kèm:
- Dialog resume lấy số liệu từ DB, không lấy từ `_defects`/`_currentIndex` — đúng lúc cần dialog này thì state widget đang rỗng, nên trước đây nó hiện *"đang dừng ở lỗi 1/0"*.
- **Nhánh `resume` phải nạp `_defects` + `_currentIndex` + board meta.** Đây mới là chỗ sửa thật: trước đây nhánh này không nạp gì, nên `_currentIndex = 0` vẫn *trong khoảng* → `idx` ở `_inspectCurrentDefect` ra 0 → vẫn soi lại từ lỗi #1 **dù operator đã chọn "Tiếp tục"**.
- `_startWorkflow` bắt đầu từ `firstUnjudgedDefectIndex` thay vì 0.
- `_inspectCurrentDefect`: fallback khi index ngoài khoảng đổi từ `0` → lỗi chưa phán định đầu tiên; sau khi tính `nextIndex` thì **nhảy qua** các lỗi vừa bị màn thủ công phán định; nhảy hết list thì rơi vào nhánh hoàn tất, **không quay về 0**.
- Gom `_finishBoard()` dùng chung cho mọi đường hoàn tất (kể cả `movePlc` về gốc) — trước đây đường early-out không đưa camera về gốc, operator với tay vào lật bo khi camera còn đứng ở vị trí lỗi cuối.

**Đệ quy → vòng lặp**: `_inspectCurrentDefect` gọi đệ quy chính nó cho mỗi lỗi. Mỗi frame giữ riêng `defectsForBoard` + `reloaded`, và mỗi vòng lại `getDefectsByBoard` cả board. AOI_Ingest ghi chú "tối đa ~2000 lỗi"/layer → 2000 frame × list 2000 Map = nguy cơ OOM, kèm O(n²) lượt đọc DB. Đã tách thành `_inspectOneDefect()` trả `bool` + vòng `while`.

> **Chốt chống đứng yên** (rủi ro do chính việc chuyển sang vòng lặp sinh ra): nếu `_currentIndex` không tiến — ví dụ `updateDefect` ghi 0 dòng nên lỗi vẫn "chưa phán định" — thì bản đệ quy vô tình *thoát* nhờ tràn stack, còn vòng lặp sẽ **quay vô hạn và bắn lệnh PLC liên tục**. Đã thêm phát hiện đứng yên và abort với thông báo rõ.

### 3.7. Bỏ calib lại, có xác minh với gateway (lỗi được báo)

Thêm vào `VRSProvider` (sống suốt phiên): `_calibratedBoardId` + `_calibratedSide`, kèm `markCalibrated()` / `isCalibratedFor()` / `invalidateCalibration()`.

Ba quyết định thiết kế quan trọng:

**a) Key theo `id_board`, KHÔNG theo `board_code`.** `board_code` không unique trong lot và hợp lệ khi rỗng (`''`) — key rỗng sẽ trùng giữa các board khác nhau, dẫn tới bỏ qua calib cho board thực sự mới.

**b) Không tin cache trong app — phải xác minh với gateway.** Hướng sai nguy hiểm nhất là: *provider bảo "đã calib" nhưng gateway không còn file offset → app bỏ qua calib → gateway lặng lẽ dùng toạ độ chưa bù → soi sai cả board*. Các cách file offset biến mất mà app không biết: gateway restart / dọn thư mục runtime; công cụ calib rời trong `Auto_calib` ghi đè; và **offset lưu theo từng MẶT chứ không theo board** nên calib board khác cùng mặt sẽ ghi đè lên. Vì vậy thêm:

```dart
Future<bool> hasValidOffsetFor({required String boardSide, required String boardId})
```
— kiểm tra offset tồn tại **và** `board_id` khớp. Cách này còn sống qua cả restart app, điều mà cache trong provider không làm được.

**c) Vẫn hỏi operator, mặc định là bỏ qua.** Chỉ operator biết board có bị tháo ra / xê dịch hay không.

Vô hiệu hoá ghi nhận calib ở **mọi** chỗ đổi board: `setCurrentModel`, `_resolveFirstLotAndBoardForModel`, `advanceToNextBoard`, `resetSystem`. Riêng `advanceToNextBoard` phải xoá **có điều kiện** — `_runCalibrationIfNeeded()` calib cho board *kế* rồi mới gọi hàm này, xoá vô điều kiện sẽ mất luôn lần calib vừa làm cho đúng board đang chuyển tới.

`_triggerManualCalibration` ở màn thủ công cũng gọi `markCalibrated` → **calib làm ở tab thủ công được tab Auto công nhận**, đúng kịch bản lỗi được báo.

### 3.8. `didChangeDependencies` ở màn manual không bao giờ chạy lại

**Vấn đề**: Hàm được viết như thể phản ứng với thay đổi provider, nhưng nó đọc bằng `Provider.of(listen: false)` → **không đăng ký dependency nào**. Chỗ đọc `listen: true` duy nhất lại nằm trong context của **`LayoutBuilder`**, không phải của `State` — nên `notifyListeners()` chỉ rebuild subtree đó, không gọi `didChangeDependencies` của State.

Việc đồng bộ board hiện chỉ "tình cờ" hoạt động nhờ màn hình bị dispose + tạo lại mỗi lần điều hướng.

**Cách sửa**: đăng ký listener tường minh trong `initState`, bỏ trong `dispose`.

**Kèm theo (bắt buộc)**: sửa xong subscription sẽ làm *sống* một race đang tiềm ẩn trong `_loadDefectsForBoard` — 2 lần load chồng nhau có thể hoàn tất trái thứ tự, để lại `_defects` của board cũ trong khi `_currentBoardId` đã là board mới → `_moveCameraToDefect` ghép `boardId` mới với `plc_coor` cũ và **PLC chạy tới toạ độ của board khác**. Đã thêm request token. Đồng thời reset `_pendingJudgement`/`_analysisResult`/`_latestCapturedFrame` khi đổi board, nếu không `_makeJudgment` sẽ gắn loại lỗi AI và ảnh chụp của board cũ cho lỗi board mới.

### 3.9. VRS thủ công không bao giờ hoàn tất board

**Vấn đề**: `_makeJudgment` không gọi `completeCurrentBoardAndCheckNext()`. Board được soi hết bằng chế độ thủ công sẽ không bao giờ có `status='completed'`, `nextBoardAvailable` không bao giờ được set → operator chỉ dùng chế độ thủ công **không bao giờ sang được board kế tiếp**.

**Cách sửa**: khi lỗi cuối được phán định → hoàn tất board + đưa camera về gốc. Quyết định "lỗi cuối" dựa trên list **đã reload sau update**, không dùng snapshot cũ. Vì màn thủ công không có nút "Board tiếp theo", snackbar chỉ rõ operator sang tab Auto VRS.

### 3.10. Nút "Bắt đầu" còn bật trên board đã xong

**Vấn đề**: `completeCurrentBoardAndCheckNext` chỉ reset `_currentBoard` ở nhánh board **cuối lot**; khi còn board kế thì `currentBoard` vẫn trỏ vào board **vừa xong**. Do đó `boardText != 'Chưa có'`, `_running == false` → nút "Bắt đầu" vẫn bật, bấm vào là calib + soi lại board đã xong và **ghi đè hết phán định**. Đây thực chất là nửa còn lại của lỗi được báo, độc lập với việc điều hướng.

**Cách sửa**: disable "Bắt đầu" khi `vrsProvider.nextBoardAvailable == true` — operator phải dùng nút "Board tiếp theo".

### 3.11 & 3.12. Hai lỗi nhỏ ở tầng service

- `getOffsetStatus()` không truyền `board_side` trong khi endpoint gateway nhận `board_side: str = "A"` → **luôn đọc trạng thái mặt A**, mặt B báo sai. Đã thêm tham số.
- `inspectDefect` với response non-200 ném `Exception('Inspection failed: <status>')`, **nuốt mất `detail`** — kể cả 409 "PLC đang bận" kèm lý do rõ ràng. Đã đổi sang trích `detail` từ body như các method khác.

---

## 4. Ba lỗi tự phát sinh trong lúc sửa (đã phát hiện và sửa)

Ghi lại để tránh tái diễn khi refactor tiếp:

1. **Nút "Thử lại" khi calib thất bại bị vô hiệu.** Nhánh retry gọi `_startWithCalibration(boardId)` — chính wrapper vừa thêm cờ `_busy`. Lúc đó vẫn đang trong phạm vi `_busy` của lần bấm "Bắt đầu", nên wrapper early-return và **bấm Thử lại không làm gì cả**. Đã đổi sang gọi `_startWithCalibrationInner`.

2. **Vòng lặp vô hạn bắn lệnh PLC** — xem hộp cảnh báo ở §3.6.

3. **Bảng lỗi hiện mã số AOI thay vì tên lỗi (do người dùng phát hiện).** Sau khi tách cột ở §3.1, hàm hiển thị được viết ưu tiên `type` (AOI) → bảng trạng thái hiện `"2"` thay vì tên lỗi AI như trước. Nguyên nhân: `type` của AOI là **mã số** (`str(type_code)`) và **không có bảng ánh xạ** sang tên lỗi ở đâu trong hệ thống; trước khi tách cột thì auto ghi đè `type` bằng tên lỗi AI nên vô tình hiển thị đúng. Đã sửa: xem §8.

---

## 5. Danh sách file đã thay đổi

### Flutter App
| File | Thay đổi |
|------|----------|
| `lib/services/local_database_service.dart` | +migration `ai_type` (+ `_createTables`, `_rebuildTbDefectWithTextUrlImage`), +`isDefectJudged()`, +`firstUnjudgedDefectIndex()`, +`resolveDefectType()`, +`resetBoardForReinspection()`, +`updateModelSizes()` |
| `lib/services/plc_gateway_service.dart` | +single-flight static (`_withPlcLock`), +`offsetApplied`/`offsetInfo` vào `InspectDefectResponse`, +`hasValidOffsetFor()`, `getOffsetStatus(boardSide:)`, sửa parse lỗi non-200 của `inspectDefect` |
| `lib/providers/vrs_provider.dart` | +`_calibratedBoardId`/`_calibratedSide`, +`markCalibrated()`/`isCalibratedFor()`/`invalidateCalibration()`, +getter `nextBoardId`, gắn invalidate vào 4 chỗ đổi board |
| `lib/screens/vrs/vrs_main_screen.dart` | +`_abortWorkflow()`, +`_finishBoard()`, +`_busy`, +pre-flight 4 trạng thái, +`_showAllJudgedDialog()`, +`_showAlreadyCalibratedDialog()`, bỏ `_hasPausedProgressFor()`, đệ quy→vòng lặp + chốt chống đứng yên, ghi `ai_type`, chặn khi `!offsetApplied` |
| `lib/screens/vrs/manual_vrs_screen.dart` | +listener `VRSProvider`, +`_loadDefectsToken`, +`_resetJudgementState()`, +`_completeBoardFromManual()`, ghi `ai_type`, `markCalibrated` sau calib |
| `lib/widgets/defect_list_widget.dart` | Dùng `resolveDefectType()` |
| `test/defect_progress_test.dart` | **MỚI** — 13 test cho helper tiến độ |
| `test/defect_reset_sql_test.dart` | **MỚI** — 4 test trên SQLite thật cho migration + reset |

### Gateway (Python)
| File | Thay đổi |
|------|----------|
| `gateway/plc_offset_gateway.py` | +`import functools`, +`_plc_lock`/`_plc_lock_holder`, +decorator `plc_exclusive()`, gắn vào 7 endpoint điều khiển PLC |

---

## 6. Kiểm chứng đã thực hiện

**Tự động — đã chạy và pass:**
- `flutter analyze`: **22 issues, không error**. Baseline trước khi sửa là 21 (2 thêm là `avoid_print` cùng kiểu với 12 `print` đã có sẵn trong `plc_gateway_service.dart`; 1 giảm do bỏ được một `use_build_context_synchronously`).
- **17/17 test mới pass**, gồm đúng kịch bản lỗi được báo (auto soi 1 lỗi → thủ công phán định lỗi #2 → phải soi tiếp từ lỗi #3) và test trên SQLite thật xác nhận "soi lại từ đầu" **không** phá `type` gốc của AOI.
- Gateway: `python -m py_compile` OK; kiểm chứng lock thật — 409 khi song song, nhả khoá cả khi thành công **và** khi có exception; xác nhận **đúng 7/7** endpoint PLC được bọc, không thừa không thiếu; xác nhận decorator giữ nguyên request model của FastAPI cho cả 7 endpoint.
- `test/widget_test.dart` **fail** — đây là boilerplate mặc định của Flutter tìm counter với `Icons.add`; app này không có counter nào (`Icons.add` duy nhất là hằng alias trong `feather_icons.dart`), tức test này chưa từng pass được. **Không liên quan** đợt sửa này.

**Chưa kiểm chứng được — cần máy thật + gateway chạy:**

| # | Kịch bản | Kết quả mong đợi |
|---|----------|------------------|
| 1 | Auto soi → Dừng giữa board → thủ công phán định 1 lỗi → về Auto → "Bắt đầu" | Hiện dialog resume, **không** calib lại, soi tiếp từ lỗi chưa phán định |
| 2 | Board đã phán định hết → "Bắt đầu" | Dialog "đã soi xong" + tuỳ chọn soi lại; **không** hoàn tất im lặng |
| 3 | Board 0 lỗi → "Bắt đầu" | Hoàn tất gọn, không kẹt "đang chạy", nút bật lại được |
| 4 | Soi 1 lỗi phán định OK → kiểm tra DB | `type` giữ nguyên giá trị AOI, `ai_type` = `'none'` |
| 5 | Auto đang soi + bấm "Di chuyển Camera" ở thủ công | Báo "PLC đang bận" (409), máy không nhận 2 lệnh |
| 6 | Xoá/đổi tên `offset_runtime` của mặt đang dùng rồi soi | Auto **dừng + dialog**, không âm thầm soi toạ độ thô |
| 7 | Bấm "Bắt đầu" 2 lần thật nhanh | Chỉ 1 chu kỳ calib |
| 8 | Thủ công phán định lỗi cuối của board | Board được đánh `completed`, camera về gốc, có hướng dẫn sang tab Auto |

---

## 7. Việc còn lại (chưa làm trong đợt này)

Xếp theo mức độ, đã cân nhắc và cố ý để lại:

1. **Ảnh chụp ở chế độ thủ công bị hiện dưới nhãn "Ảnh Live từ VRS" ở tab Auto khi máy đang chạy.** `dispose()` của màn thủ công không gọi `returnToLiveCamera()`, mà `AutoVRSWebSocketService` là app-scoped. Tab Auto render `displayImage` vô điều kiện dưới tiêu đề "Ảnh Live từ VRS" và không có chỉ báo nào (khác màn thủ công vốn có badge "Chế độ xem ảnh"). Operator **xem ảnh tĩnh trong lúc máy đang di chuyển** → đây là mục đáng ưu tiên nhất trong danh sách này.
2. Gom 1 parser `plc_coor` dùng chung: màn thủ công chỉ nhận `';'`, màn auto nhận `';'`/`','`/Map → cùng một lỗi chạy được ở auto nhưng fail ở thủ công. Việc chặn `(0,0)` cũng loại oan lỗi nằm đúng gốc board.
3. `completeCurrentBoardAndCheckNext` nhánh lot-finished không reset `_currentBoardSide`/`_calibrationNeeded` → màn thủ công hiển thị "Mặt A/B" cho board không còn tồn tại.
4. Route sai `/vrs/light-adjust` ở `manual_vrs_screen.dart` (đúng là `/light-adjust`) → nút "Điều chỉnh đèn" rơi vào trang lỗi của GoRouter.
5. **Xoá `lib/core/routes_new.dart`** — file này là code chết, không nơi nào import (`main.dart` dùng `core/routes.dart`). Nên xoá sớm để không ai sửa nhầm file rồi tưởng đã sửa xong.
6. `vrs_main_screen.dart` tạo future `getDefectsByBoard` mới **mỗi lần build** (mà `setState` chạy theo từng lỗi), kèm ~10 dòng `debugPrint` mỗi build.
7. ~~Rework panel kết quả AI~~ → **đã làm ở §8**. Còn lại: `_lastPersistedDefectId` vẫn được gán mà không đọc (analyzer báo `unused_field`) — hoặc dùng nó để gate hiển thị, hoặc bỏ hẳn.
8. **Đã cân nhắc và đề xuất hoãn**: chuyển `/vrs-main` và `/manual-vrs` sang `StatefulShellRoute.indexedStack` để không dispose màn hình. Nó xoá nguyên nhân trực tiếp của lỗi được báo và giữ được cả state camera/Gerber, **nhưng không thay thế được** §3.6 (tiến độ vẫn phải sống qua restart app, và phải xử lý được việc màn thủ công phán định không theo thứ tự), đồng thời làm sống lại các lỗi tiềm ẩn ở §3.8. Nên làm sau khi §3.6-3.9 đã chạy ổn định trên máy thật.

---

## 8. Bổ sung — Sửa phần hiển thị phán định lỗi (2026-08-11)

Do người dùng phát hiện sau khi chạy thử: bảng trạng thái hiện `"2"` thay vì tên lỗi,
và panel "Kết quả phán định AI" báo **OK** trong khi dòng lỗi duy nhất bên dưới ghi **NG**.

### 8.1. Bảng lỗi hiện mã số AOI thay vì tên lỗi (regression từ §3.1)

**Nguyên nhân**: sau khi tách cột, hàm hiển thị được viết ưu tiên `type` (AOI) rồi mới
đến `ai_type`. Nhưng `type` của AOI là **mã số** — `aoi_ingest_service.py` ghi
`"type": str(type_code)` (ví dụ `"2"`) — và **không có bảng ánh xạ mã → tên lỗi** ở bất
kỳ đâu trong hệ thống (`_getDefectDisplayName` chỉ map theo tên, gặp mã số thì trả lại
chính nó). Trước khi tách cột, auto ghi đè `type` bằng tên lỗi AI nên bảng *vô tình*
hiển thị đúng.

**Cách sửa**: đổi thứ tự ưu tiên của hàm hiển thị và đổi tên cho rõ ý định —
`resolveDefectType()` → `defectTypeForDisplay()`, ưu tiên `ai_type` → fallback `type`:

- Lỗi **đã soi** → hiện tên lỗi AI (`_getDefectDisplayName` dịch được sang tiếng Việt).
- Lỗi **chưa soi** → fallback mã AOI, giống hệt hành vi trước đây.

Việc lưu trữ **không đổi**: `type` vẫn là nguồn sự thật của AOI, không ai ghi đè, và
`getDefectStatistics()` (`GROUP BY type`) vẫn dựa vào nó để truy vết. Tức bản sửa §3.1
(chống mất dữ liệu) được giữ nguyên, chỉ sửa tầng *hiển thị*.

Áp dụng cho cả 4 chỗ hiển thị: `DefectListWidget`, panel kết quả AI, và metadata Gerber
ở 2 màn hình.

### 8.2. Panel kết quả AI mặc định "OK" khi không có dữ liệu

**Nguyên nhân**: panel khởi tạo sẵn `verdictShort = 'OK'` + màu xanh + "Không phát hiện
lỗi", rồi mới đi qua chuỗi nguồn dữ liệu. Nếu không nguồn nào có gì (board đã soi xong
nên `_currentIndex` vượt cuối danh sách, `_lastPersistedVerdict` null vì màn hình vừa
mount, `analysis` null) thì panel **giữ nguyên trạng thái xanh "OK"** — vừa sai vừa mâu
thuẫn với bảng lỗi bên dưới đang ghi NG.

**Cách sửa**: viết lại chuỗi quyết định, thứ tự ưu tiên:

1. Phán định vừa lưu trong lượt soi này (`_lastPersistedVerdict`)
2. Phán định của lỗi đang ở `_currentIndex`
3. Phán định của lỗi **đã soi gần nhất** trên board — xử lý đúng trường hợp board soi
   xong / vừa quay lại màn hình
4. Không có gì → trạng thái **trung tính** (xám, `—`, "Chưa có kết quả phán định"),
   **không** khẳng định OK

Đồng thời **bỏ nhánh fallback sang `analysis`** của `AutoVRSWebSocketService`: service đó
app-scoped và màn auto không bao giờ clear, nên nó có thể hiện verdict của **board khác**
(do màn thủ công chụp) cho board chưa soi gì. Luồng soi trực tiếp không bị ảnh hưởng vì
đã được nguồn (1) phủ.

### 8.3. Kiểm chứng

- `flutter analyze`: 22 issues, không error (giữ nguyên baseline).
- 17/17 test pass; nhóm test `defectTypeForDisplay` được viết lại theo thứ tự ưu tiên
  mới, thêm case "lỗi đã soi hiện tên lỗi AI, không hiện mã số thô".
- **Cần xác nhận trên máy thật**: bảng trạng thái hiện tên lỗi tiếng Việt sau khi soi;
  panel hiện `—`/"Chưa có kết quả phán định" (xám) cho board chưa soi thay vì OK xanh;
  panel và bảng lỗi không còn mâu thuẫn OK/NG.
