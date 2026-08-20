# Báo Cáo — Nâng Cấp Luồng "Chọn Mã Hàng" (Model) Trong App Flutter

> Ngày: 2026-08-17
> Dự án: AutoVRS Meiko Automation (Flutter App)
> Phạm vi: `select_model_screen.dart`, `select_lot_for_model_screen.dart` (màn mới), `vrs_provider.dart`,
> `local_database_service.dart`, `plc_gateway_service.dart`, `qcamber_gerber_service.dart`
> Trạng thái: đã triển khai xong phần mô tả dưới đây; mục 6 liệt kê hạn chế còn tồn đọng, CHƯA sửa.

---

## 1. Mục tiêu

Trước 14/08/2026, "chọn mã hàng" trong app chỉ là 1 thao tác đơn: operator bấm 1 dòng model,
xác nhận, app tự đoán 1 lot rồi đóng màn hình - không tích hợp gì với hệ thống ngoài. Đợt nâng cấp
này nhắm tới 4 mục tiêu cụ thể phát sinh từ đó:

1. **Cho operator tự chọn đúng lot cần xử lý** - vì 1 model giờ có thể có nhiều lot theo thời gian
   (mỗi lần AOI mở lot mới = 1 lot mới, không còn tái sử dụng mãi 1 lot như trước), việc app tự
   đoán "lot cũ nhất" không còn đáng tin cậy.
2. **Đồng bộ mã hàng đang chạy trên app với PLC Offset Gateway** - để Gateway luôn dùng đúng
   weights YOLO + file calib của mã hàng operator vừa chọn, thay vì vẫn chạy mã hàng cũ mà không
   ai biết.
3. **Giảm độ trễ ở điểm lỗi đầu tiên khi soi ảnh thiết kế qua QCamber** - trước đây job chỉ được mở
   khi có lỗi đầu tiên cần soi, khiến điểm đó luôn chậm hơn hẳn các điểm sau.
4. **Phát hiện và cảnh báo khi có sai lệch**, thay vì lặng lẽ sai: mở nhầm file thiết kế trong
   QCamber, hoặc state cũ của model trước dính lại sau khi đổi model.

---

## 2. Phương án thực hiện

Với từng mục tiêu, phương án được chọn là:

1. **Thêm 1 màn hình chọn lot riêng**, tách khỏi bước chọn model, chỉ liệt kê lot CHƯA xử lý hết
   bo (không hiện lot đã xong hết để operator khỏi chọn nhầm vào việc đã hoàn tất) - thay vì cố
   "đoán thông minh hơn" trong lúc chọn model.
2. **Gọi thẳng 3 endpoint có sẵn của PLC Offset Gateway** (`/api/products`, `/api/products/active`,
   `/api/products/select`, port 8083) ngay sau khi operator xác nhận xong model+lot; nếu Gateway từ
   chối (thiếu weights/calib cho mã hàng đó) thì **chặn cứng operator** bằng dialog lỗi, không cho
   tiếp tục coi như đã chọn xong - vì chạy sai weights/calib là rủi ro về chất lượng đo, không thể
   chỉ cảnh báo suông.
3. **Gọi 1 endpoint mới bên QCamber** (`/api/preload`) ngay tại thời điểm chọn mã hàng, theo kiểu
   "bắn rồi quên" (`unawaited`, không chờ kết quả) - vì đây chỉ là tối ưu độ trễ, không phải điều
   kiện bắt buộc để operator tiếp tục.
4. **Phát hiện lỗi theo cấu trúc dữ liệu trả về** (không so khớp theo câu chữ, để không bị vỡ khi
   đổi wording) và **dừng hẳn chu trình Auto VRS** khi QCamber báo đang mở sai file thiết kế; song
   song, rà soát riêng luồng "board tiếp theo" khi đổi model và phát hiện + vá thêm 2 bug phát sinh
   ngay trong lúc xây tính năng (không phải lỗi có sẵn từ trước).

---

## 3. Kết quả đạt được

- Operator có màn hình riêng để chọn đúng lot muốn xử lý trong danh sách đã lọc sẵn (chỉ còn lot
  chưa xong), thay vì bị app tự chọn thay và có thể chọn sai lot khi 1 model có nhiều lot.
- App, PLC Gateway, và QCamber luôn được đồng bộ cùng 1 mã hàng tại thời điểm operator xác nhận
  chọn (trừ các hạn chế nêu ở mục 6) - loại bỏ hoàn toàn kiểu lỗi "app hiện mã hàng A nhưng Gateway
  vẫn chạy weights của mã hàng B" từng không được phát hiện.
- Điểm lỗi đầu tiên sau khi chọn mã hàng không còn phải chờ QCamber mở job từ đầu (đã mở sẵn qua
  `/api/preload`) - giảm độ trễ về mặt cơ chế; chưa đo benchmark thời gian thực tế trên máy thật.
- Có cảnh báo + tự dừng chu trình khi QCamber mở sai file thiết kế (409), thay vì trước đây lặng lẽ
  hiện sai ảnh hoặc không hiện gì mà không ai biết.
- Phát hiện và vá xong 2 bug phát sinh ngay trong quá trình xây tính năng trước khi bàn giao:
  state "board tiếp theo" dính lại từ model cũ gây calib nhầm mặt board, và kẹt màn hình chọn lot
  khi model không có lot nào khả dụng.
- `dart analyze` toàn bộ app sạch (không phát sinh lỗi/warning mới) qua tất cả các đợt sửa nói
  trên - đã kiểm tra lại sau mỗi lần đổi.
- Minh bạch hoá 4 hạn chế còn tồn đọng (mục 6) thay vì để ẩn - có cơ sở quyết định làm tiếp hay không.

---

## 4. So sánh nhanh Trước / Sau

| Khía cạnh | TRƯỚC | SAU |
|---|---|---|
| Chọn lot | App **tự đoán** (lot cũ nhất theo `id_lot ASC` của model, `getFirstLotByModelId`) - operator không có lựa chọn nào | Operator **tự chọn lot cụ thể** qua màn hình riêng (`SelectLotForModelScreen`), chỉ liệt kê lot CHƯA xử lý hết bo |
| Số bước thao tác | 1: bấm "Chọn" → xác nhận → xong | 4: bấm "Chọn" → xác nhận → chọn lot → chờ Gateway xác nhận xong mới đóng màn hình |
| PLC Offset Gateway (weights YOLO + file calib) | Không tích hợp - đổi mã hàng trên app không ảnh hưởng gì tới Gateway | Gọi `POST /api/products/select` ngay khi chọn xong lot - hot-swap đúng weights/calib theo mã hàng |
| QCamber (ảnh thiết kế tham chiếu) | Job chỉ mở khi có lỗi ĐẦU TIÊN cần soi → điểm lỗi đầu luôn chậm hơn hẳn các điểm sau | Gọi `POST /api/preload` ngay lúc chọn mã hàng (không chờ) → job đã mở sẵn, điểm lỗi đầu nhanh như các điểm sau |
| Mở nhầm file thiết kế trong QCamber | Không phát hiện - lặng lẽ hiện sai ảnh hoặc không hiện gì | Phát hiện HTTP 409 từ QCamber, **dừng chu trình Auto VRS** + cảnh báo tên file đang mở/tên file cần |
| Đổi model khi model cũ còn "board tiếp theo" chờ xác nhận | **BUG**: dính state cũ, có thể áp calib nhầm mặt board (side A/B) | Đã fix - `_applyLot()` reset sạch state "board tiếp theo" mỗi lần áp dụng lot/model mới |
| Chọn model không có lot nào khả dụng | Chưa có màn hình này (chưa tồn tại) | **BUG mới phát sinh rồi được fix ngay**: màn `SelectLotForModelScreen` ban đầu không có lối thoát khi rỗng, đã thêm nút "Hủy"/"Chọn mã hàng khác" |
| Gateway từ chối mã hàng (thiếu weights/file calib) | Không tồn tại (chưa tích hợp) | Chặn operator bằng dialog lỗi rõ ràng, **không** cập nhật model đang chọn, **không** đóng màn hình |

### 4.1. Luồng TRƯỚC (trước 14/08/2026)

```
Operator bấm "Chọn" trên 1 dòng model
  → Dialog xác nhận
  → vrsProvider.setCurrentModel(modelId)
       → getFirstLotByModelId(modelId)  -- lấy lot CŨ NHẤT (id_lot ASC), không điều kiện gì khác
       → lấy board đầu tiên còn dở của lot đó
  → Đóng màn hình, quay về màn trước
```

Không bước nào liên lạc với hệ thống ngoài.

**Vấn đề của cách làm này:**

- `getFirstLotByModelId` luôn lấy lot **cũ nhất** - điều này chỉ đúng khi 1 model chỉ từng có
  đúng 1 lot suốt vòng đời (quy ước cũ của `AOI_Ingest.get_or_create_lot()`: tái sử dụng mãi 1 lot
  rỗng cho mỗi model, không có khái niệm mã lot thật). Sau khi `AOI_Ingest` được đổi sang tạo **1
  lot MỚI cho mỗi mã lot AOI thực sự ghi ra** (cột `tbLot.lot_code`, xem báo cáo lot_code riêng),
  1 model có thể tích luỹ nhiều lot theo thời gian - "cũ nhất" sẽ đứng yên ở lot đầu tiên mãi mãi,
  không bao giờ tự nhảy sang lot đang thực sự chạy.
- Operator hoàn toàn không có cách nào chọn ĐÚNG lot mình muốn xử lý nếu model có nhiều lot.
- Đổi mã hàng trên app không đồng bộ gì với PLC Gateway (Gateway vẫn chạy weights YOLO + file
  calib của mã hàng CŨ) hay QCamber (vẫn mở file thiết kế CŨ trong khi soi mã hàng MỚI) - rủi ro
  chạy/đo nhầm hoàn toàn không được phát hiện.

### 4.2. Luồng SAU (hiện tại)

```
Operator bấm "Chọn" trên 1 dòng model
  → (1) Dialog xác nhận
  → (2) Chuyển sang SelectLotForModelScreen(modelId)
          - liệt kê CHỈ lot chưa xử lý hết bo (getSelectableLotsForModel)
          - hiện: mã lot thật (lot_code), tổng số bo, số bo còn dở
          - operator tự bấm "Chọn" 1 lot cụ thể + xác nhận
          - có nút "Hủy" / "Chọn mã hàng khác" nếu đổi ý hoặc danh sách rỗng
  → (3) vrsProvider.setCurrentModelAndLot(modelId, idLot) - áp dụng đúng model+lot vừa chọn
  → (4) PlcGatewayService().selectProduct(productCode)   [productCode = tbModel.name]
          - THÀNH CÔNG → setLastSelectedProductCode(...) rồi preloadJob QCamber (không chờ kết quả)
          - THẤT BẠI   → dialog lỗi, CHẶN operator, không cập nhật _selectedModelId, không đóng màn hình
  → Đóng màn hình, quay về màn trước (chỉ khi bước 4 thành công, hoặc model không có productCode)
```

Toàn bộ chuỗi này nằm trong `_selectModel()` tại
[`select_model_screen.dart:293-390`](../App/lib/screens/model_management/select_model_screen.dart#L293-L390).

---

## 5. Chi tiết triển khai từng hạng mục

### 5.1. Chọn lot tường minh thay vì app tự đoán

- **Trước:** `VRSProvider.setCurrentModel()` tự gọi `getFirstLotByModelId()` (đã xoá).
- **Sau:**
  - [`local_database_service.dart:1081`](../App/lib/services/local_database_service.dart#L1081)
    `getCurrentLotForModel()` - vẫn giữ để tự-đoán 1 lot "hợp lý nhất" (lot cũ nhất còn dở, hoặc
    mới nhất nếu mọi lot đã xong) nhưng **chỉ dùng khi khôi phục trạng thái lúc khởi động app**
    (`_resolveFirstLotAndBoardForModel`), không còn dùng trong luồng operator chọn model tương tác.
  - [`local_database_service.dart:1113`](../App/lib/services/local_database_service.dart#L1113)
    `getSelectableLotsForModel()` - liệt kê MỌI lot chưa xong của 1 model (dùng chung điều kiện
    `_unfinishedLotWhere` với hàm trên), kèm `actual_boards`/`pending_boards` đếm thật từ
    `tbBoard` (không dùng cột `tbLot.board_quantity` vì cột đó `AOI_Ingest` không hề ghi vào).
  - Màn hình mới `select_lot_for_model_screen.dart` (route `/select-lot-for-model/:modelId`) hiển
    thị danh sách trên cho operator tự chọn.
  - `VRSProvider.setCurrentModelAndLot(modelId, idLot)` (mới) - áp dụng đúng lot operator chọn,
    khác với `setCurrentModel()` (vẫn tự đoán, chỉ còn dùng nội bộ).

### 5.2. Tích hợp PLC Offset Gateway (product code)

- Thêm `getProducts()`, `getActiveProduct()`, `selectProduct(String)` vào
  `plc_gateway_service.dart`, gọi 3 endpoint có sẵn ở Gateway (`GET /api/products`,
  `GET /api/products/active`, `POST /api/products/select`, port 8083) - Gateway hot-swap
  weights YOLO + file calib theo đúng `product_code`.
- `product_code` = cột `tbModel.name` (KHÔNG PHẢI `id_model`) - quyết định đã chốt qua
  `AskUserQuestion`, xem `BAO_CAO_KIEM_TRA_TICH_HOP_PRODUCT_CODE_GATEWAY.md`.
- Thất bại (weights/calib chưa có trong `products_registry.yaml`) → chặn operator bằng dialog lỗi,
  Gateway vẫn giữ mã hàng cũ, app không cập nhật gì để tránh operator tưởng đã đổi xong.
- `VRSProvider` thêm `_lastSelectedProductCode`/`setLastSelectedProductCode()` để các màn khác có
  thể đối chiếu sau này với `GET /api/products/active` (chưa có màn nào wiring việc đối chiếu này).

### 5.3. Preload job QCamber

- `qcamber_gerber_service.dart` thêm `preloadJob(String jobName)` gọi `POST /api/preload` (endpoint
  mới bên QCamber) - chỉ mở/chuyển job, không chụp ảnh gì.
- Gọi **ngay sau** khi `selectProduct` (PLC Gateway) thành công, bằng `unawaited(...)` - cố ý không
  chờ kết quả vì đây chỉ là tối ưu độ trễ (điểm lỗi đầu tiên khỏi phải chờ QCamber mở job), không
  phải điều kiện bắt buộc để tiếp tục chọn mã hàng.
- `jobName` gửi cho `/api/preload` dùng **đúng cùng giá trị** `productCode` (= `tbModel.name`) đã
  gửi cho `selectProduct` - không tạo thêm 1 nguồn dữ liệu khác.

### 5.4. Cảnh báo mở nhầm file thiết kế trong QCamber (409)

- QCamber trả HTTP 409 kèm `{currentJobName, requestedJobName, ...}` khi file thiết kế đang mở
  KHÁC với mã hàng đang chạy thật. Trước đây bị xử lý như 1 lỗi tải ảnh thông thường - lặng lẽ bỏ
  qua, không cảnh báo, có thể hiện nhầm ảnh thiết kế của board khác.
- Đã thêm phát hiện theo **cấu trúc response** (có đủ 2 field `currentJobName`+`requestedJobName`),
  không so khớp theo câu chữ `error` để không bị vỡ khi đổi câu chữ.
- Auto VRS (`vrs_main_screen.dart`): phát hiện → **dừng hẳn chu trình đang chạy** + dialog cảnh báo.
- Manual VRS (`manual_vrs_screen.dart`): chỉ cảnh báo (không có "chu trình" nào để dừng, vận hành
  viên đã tự soi từng lỗi một theo nhịp riêng).

### 5.5. Fix bug: đổi model khi model cũ còn "board tiếp theo" dở dang

- **Triệu chứng người dùng báo:** dữ liệu trong DB ghi mặt A nhưng calib áp dụng lại là mặt B, xảy
  ra khi đổi model lúc model cũ còn dở mặt B.
- **Nguyên nhân:** `_applyLot()` (dùng chung cho mọi cách "vào" 1 lot) tính đúng
  `_currentBoard`/`_currentBoardSide` cho model MỚI, nhưng không reset các cờ "board tiếp theo"
  (`_nextBoardAvailable`, `_nextBoardId`, `_nextBoardSide`,...) còn sót lại từ model CŨ. Nút "Bắt
  đầu" bị khoá do `nextBoardAvailable=true` (thiết kế cố ý, tránh chạy lại board vừa xong) → operator
  buộc phải bấm "Board tiếp theo" → `advanceToNextBoard()` ghi ĐÈ board/mặt vừa set đúng bằng
  board/mặt CŨ của model trước → Gateway calib nhầm mặt.
- **Đã fix:** `_applyLot()` reset toàn bộ state "board tiếp theo" về mặc định TRƯỚC khi áp dụng lot
  mới. Ảnh hưởng cả Auto VRS lẫn Manual VRS (cùng đọc chung các field này).

### 5.6. Fix bug: kẹt màn hình chọn lot khi model không có lot nào

- **Nguyên nhân:** `MainLayout` (khung bao mọi màn hình) có nút "quay lại" ở top bar, nhưng nút đó
  gọi `NavigationProvider.goBack()` - 1 stack lịch sử điều hướng **tự viết riêng, tách biệt hoàn
  toàn với GoRouter**, không thật sự pop được route đã `push()` qua GoRouter. Màn hình
  `select_lot_for_model_screen.dart` (mới tạo) không có nút thoát riêng, nên khi danh sách lot rỗng
  (không có gì để bấm "Chọn"), operator bị kẹt cứng - không quay lại được để chọn model khác.
- **Đã fix:** thêm nút "Hủy" ở header (mọi trạng thái) + nút "Chọn mã hàng khác" nổi bật ngay trong
  trạng thái rỗng, cả 2 đều gọi `context.pop()` (trả `null`, được `_selectModel()` hiểu là huỷ).

---

## 6. Hạn chế còn tồn đọng (CHƯA sửa, cần quyết định thêm nếu muốn xử lý)

- **Không có debounce/khoá khi đổi model nhanh:** nút "Chọn" trong bảng model chỉ bị khoá cho ĐÚNG
  dòng đang là model hiện tại (`_selectedModelId`) - biến này chỉ cập nhật ở BƯỚC CUỐI của chuỗi
  4 bước. Trong lúc đang chờ `selectProduct`/`preloadJob` của model A, operator vẫn bấm được "Chọn"
  sang model B, tạo ra 2 chuỗi async chạy chồng nhau; vì `preloadJob()` là `unawaited` (không đợi
  kết quả), thứ tự HTTP response về KHÔNG đảm bảo trùng thứ tự bấm - QCamber có thể kết thúc với
  job của model A dù operator chọn cuối cùng là B. `QCamberGerberService` đã có sẵn cơ chế tương tự
  cho `captureGerberImage()` (biến `_requestId` tăng dần, bỏ kết quả cũ) nhưng chưa áp dụng cho
  luồng chọn model này.
- **`tbModel.name` không chuẩn hoá hoa/thường:** cả `AOI_Ingest` (Python, `.strip()`) lẫn
  `add_model_screen.dart` (Dart, `.trim()`) đều cắt khoảng trắng thừa, nhưng không có nơi nào
  chuẩn hoá chữ hoa/thường. Nếu 1 mã hàng bị tạo 2 lần với case khác nhau (AOI tự tạo "ABC123" từ
  file `.vrs`, ai đó tự tay thêm "abc123" tưởng là mã mới), SQLite coi là 2 `tbModel` khác nhau -
  operator có thể chọn nhầm dòng, dẫn tới lot rỗng (mục 5.6 vừa fix ở trên) hoặc `productCode` gửi
  Gateway/QCamber không khớp dữ liệu board thật.
- **Bug `int.parse(modelId)` bị nuốt lặng lẽ:** `vrs_provider.dart` (`setCurrentModel`,
  `setCurrentModelAndLot`) bọc `int.parse(modelId)` trong `try/catch` chỉ `debugPrint` khi lỗi. Nếu
  `modelId` không phải số nguyên hợp lệ, `_currentModel` không được cập nhật nhưng
  `select_model_screen.dart` vẫn tô đậm dòng đó là "Đang chọn" - hiện sai trạng thái. Đã ghi nhận
  từ đợt audit 2026-08-15, chưa sửa, không nằm trong phạm vi đợt nâng cấp này.
- **Chưa có UI đối chiếu `lastSelectedProductCode` với `GET /api/products/active`:** field/setter
  đã có trong `VRSProvider`, nhưng chưa có màn hình nào thực sự gọi API và so sánh để phát hiện nếu
  Gateway bị đổi mã hàng từ nơi khác (vd công cụ calib rời) mà app không biết.

---

## 7. Cách kiểm chứng lại báo cáo này

- Luồng 4 bước: `select_model_screen.dart` hàm `_selectModel()`.
- Hàm tự đoán lot (chỉ còn dùng lúc khởi động app): `local_database_service.dart::getCurrentLotForModel`,
  gọi từ `vrs_provider.dart::_resolveFirstLotAndBoardForModel`.
- Hàm liệt kê lot cho operator chọn: `local_database_service.dart::getSelectableLotsForModel`.
- Reset "board tiếp theo" khi đổi lot: `vrs_provider.dart::_applyLot`, đoạn comment "BUG đã gặp"
  ngay đầu hàm.
- Nút thoát màn chọn lot: `select_lot_for_model_screen.dart`, nút "Hủy" ở header + nút trong
  `_buildEmptyState()`.
- Tích hợp Gateway: `plc_gateway_service.dart::selectProduct`; tích hợp QCamber:
  `qcamber_gerber_service.dart::preloadJob` + phần phát hiện 409 trong `captureGerberImage`.
