# Báo Cáo — Kiểm Tra Tiền Đề Trước Khi Tích Hợp "Chọn Mã Hàng" Với PLC Offset Gateway

> Ngày: 2026-08-15
> Dự án: AutoVRS Meiko Automation (Flutter App) + Auto_calib/AutoBoardOffset_YOLO_2Mat (Gateway)
> Trạng thái: **ĐÃ TRIỂN KHAI XONG** — xem mục 6 (cập nhật sau khi pull repo gateway). Phần 1-5
> dưới đây là báo cáo gốc lúc dừng lại lần đầu (trước khi biết cần `git pull`), giữ nguyên để
> đối chiếu.

> **CẬP NHẬT QUAN TRỌNG (cùng ngày, sau khi có phản hồi từ người dùng):** Kết luận ở mục 2.1
> bên dưới ("3 endpoint chưa tồn tại") là **SAI** — sai không phải vì suy luận sai, mà vì kiểm
> tra trên bản local của repo `AutoBoardOffset_YOLO_2Mat` (sibling repo, có git riêng) **chưa
> được `git pull`** trước khi kết luận. Sau khi `git fetch && git merge --ff-only origin/main`
> (repo đó nhảy từ commit `5895d30` lên `cefdde6`), cả 3 endpoint + `products_registry.yaml` +
> cơ chế hot-swap weights đều đã có, đúng y như người dùng mô tả ban đầu. Bài học: với các repo
> con có git riêng nằm trong Auto_VRS (khác với thư mục gốc, không phải git repo), phải
> `git pull`/`git fetch` trước rồi mới kết luận "thiếu code", không chỉ dựa vào việc `grep`
> bản đang có trên máy.

---

## 1. Yêu cầu ban đầu

Gắn thêm 1 lệnh gọi API vào luồng "chọn bộ tham số/mã hàng" đã có sẵn trong
`select_model_screen.dart`, để khi operator chọn mã hàng, app tự động báo cho PLC Offset
Gateway (port 8083) biết đang chạy mã hàng nào, qua 3 endpoint được mô tả là **"đã có sẵn,
không cần sửa gì"**:

- `GET /api/products`
- `GET /api/products/active`
- `POST /api/products/select` (body `{"product_code": "..."}`)

Yêu cầu ban đầu giả định cột `tbModel.name` chính là "mã hàng" (product_code), và yêu cầu
**xác nhận giả định này trước khi code** — nếu không khớp thì hỏi lại thay vì tự ý code hoặc
tự ý tạo màn hình mới.

---

## 2. Đã kiểm tra gì

### 2.1. Backend — 3 endpoint `/api/products*` có tồn tại không?

Đã `grep` toàn bộ cây thư mục `Auto_VRS` (không chỉ riêng app Flutter) với các từ khóa:
`product_code`, `products_registry`, `ProductRegistry`, `weights_path`+`calib_dir` cùng lúc.
**Kết quả: 0 match** ở bất kỳ file nguồn nào (chỉ có match nhiễu ở thư viện bên thứ 3 như
sympy/torch, không liên quan).

Xác nhận gateway đang thực sự chạy trên port 8083 là file nào: `run_gateway.py` import
`"plc_offset_gateway:app"` — tức file `Auto_calib\AutoBoardOffset_YOLO_2Mat\gateway\plc_offset_gateway.py`
chính là gateway thật. Liệt kê toàn bộ route đã đăng ký trong file này bằng grep
`@app.(get|post)`, danh sách đầy đủ:

```
GET  /
POST /api/plc/move
POST /api/plc/move_bulech
POST /api/inspect-defect
GET  /api/test-plc
GET  /api/test-plc-feedback
GET  /api/test-camera
GET  /api/test-fiducial
GET  /api/camera-config
PUT  /api/camera-config
POST /api/calib/auto-board-offset
GET  /api/calib/anchor-info
POST /api/calib/camera-axis
POST /api/calib/board-to-plc
GET  /api/calib/offset-status
```

Không có route nào bắt đầu bằng `/api/products`.

Kiểm tra thêm `fiducial_detector/fiducial_service.py` (service YOLO phát hiện fiducial
marker, port 8193) — service này nạp **một** `weights_path` cố định từ
`fiducial_service_config.yaml` lúc khởi động (`WEIGHTS_PATH = CONFIG["weights_path"]`,
dòng 102), **không có cơ chế hot-swap weights theo mã hàng**. Không tìm thấy cơ chế tương tự
ở `BE_tensorRT/plc_gateway_api.py` (service AI Detection, port 8082) khi grep `weights|model_path`.

**Kết luận**: 3 endpoint mô tả trong yêu cầu, file `products_registry.yaml`, và cơ chế
hot-swap weights YOLO theo mã hàng — **đều CHƯA tồn tại trong repo này**. Đây là phần backend
cần được xây dựng mới, không phải "đã có sẵn, chỉ cần gọi".

### 2.2. Cột nào trong `tbModel` thực sự là "mã hàng" trên UI?

`add_model_screen.dart` (màn thêm mã hàng mới) có 2 field nhập liệu tách biệt:

- Dòng 49-61: field `_modelIdController` → cột `id_model`, label **"Mã hàng (id_model)"**,
  validator chỉ kiểm tra không rỗng.
- Dòng 66-78: field `_modelNameController` → cột `name`, label **"Tên mã hàng (name)"**,
  validator chỉ kiểm tra không rỗng.

`select_model_screen.dart` (bảng danh sách để chọn), `_buildModelTable()` dòng 187-288:
cột hiển thị **"Mã hàng "** (dòng 192-197) bind vào `model['id_model']` (dòng 224-237); cột
**"Tên"** (dòng 198-200) bind vào `model['name']` (dòng 238).

**Kết luận**: Theo đúng label và layout UI hiện tại, `id_model` mới là "mã hàng" operator
nhìn thấy dưới cột "Mã hàng"; `name` là một nhãn mô tả riêng biệt dưới cột "Tên" — **ngược
lại** với giả định ban đầu trong yêu cầu (rằng `name` là mã hàng).

### 2.3. Phát hiện thêm (không nằm trong câu hỏi ban đầu, nhưng ảnh hưởng trực tiếp)

`vrs_provider.dart`:
- Dòng 212: `setCurrentModel(String modelId)` → `await _db.getModelById(int.parse(modelId))`
- Dòng 230: `setCurrentModelAndLot(String modelId, int idLot)` → `await _db.getModelById(int.parse(modelId))`

Cả hai đều bọc trong `try/catch` chỉ `debugPrint(...)` khi lỗi (dòng 221-223, 238-240) — nếu
`modelId` không parse được thành số nguyên (ví dụ mã hàng dạng chuỗi như
`"23691025-250616-0004-nvq-aoi"`), `int.parse` ném `FormatException`, bị nuốt lặng lẽ,
`_currentModel`/`_currentModelName` **không được cập nhật**, nhưng `select_model_screen.dart`
dòng 331-333 vẫn set `_selectedModelId = modelId` và tô đậm dòng đó là "Đang chọn" — **app tự
tin hiển thị sai model đang chọn khi model_id không phải số nguyên hợp lệ**. Phát hiện này đã
được ghi nhận độc lập trong đợt audit toàn dự án ngày 2026-08-15 (finding #4 trong memory
`project_auto_vrs_full_audit_2026_08_15`).

Điều này có nghĩa: nếu chọn `id_model` làm product_code gửi cho gateway, và mã hàng thật có
dạng chuỗi (không phải số), luồng chọn model trong app hiện tại **đã vỡ từ trước** khi gặp
mã hàng dạng đó — độc lập với việc có tích hợp gateway hay không.

---

## 3. Quyết định của người dùng (đã chốt qua AskUserQuestion)

1. **Backend**: 3 endpoint chưa tồn tại → **dừng lại**, không tự build backend, không tự
   code phần Flutter lúc này. Người dùng sẽ tự đối chiếu báo cáo này ở một phiên Claude Code
   khác để xác minh việc kiểm tra ở trên có đúng không, trước khi quyết định bước tiếp theo.
2. **Cột "mã hàng"**: chọn **`name`** làm giá trị gửi làm `product_code` cho gateway
   (không phải `id_model`).

---

## 4. Việc CHƯA làm (còn tồn đọng nếu tiếp tục triển khai)

- **Backend gateway** (`plc_offset_gateway.py`) chưa có `products_registry.yaml` + 3 endpoint
  `/api/products`, `/api/products/active`, `/api/products/select`. Chưa có cơ chế hot-swap
  weights YOLO (`fiducial_service.py`) và file hiệu chỉnh toạ độ theo mã hàng.
- Nếu dùng `name` làm product_code: `name` hiện chỉ có validator "không rỗng"
  (`add_model_screen.dart` dòng 72-77), **không có ràng buộc unique, không có format check** —
  rủi ro operator gõ sai/không nhất quán giữa các lần thêm mã hàng, dẫn đến `name` trong local
  DB không khớp chính xác với danh mục `product_code` phía gateway (khác biệt hoa/thường,
  khoảng trắng thừa, gõ nhầm...). Nếu tiếp tục theo hướng `name`, nên cân nhắc thêm
  validator/chuẩn hoá cho field này.
- Chưa thêm method nào vào `plc_gateway_service.dart` (`getProducts`, `getActiveProduct`,
  `selectProduct`).
- Chưa gắn lệnh gọi nào vào `select_model_screen.dart` (điểm neo dự kiến: ngay sau dòng 328,
  `await vrsProvider.setCurrentModelAndLot(modelId, idLot);` — lưu ý biến `modelId` ở đó đang
  là `model['id_model'].toString()` (dòng 317), phải lấy `model['name']` riêng làm product_code).
- Chưa thêm field tracking nào vào `VRSProvider`.
- Bug `int.parse(modelId)` ở `vrs_provider.dart:212,230` (mục 2.3) vẫn còn nguyên, chưa sửa.

---

## 5. Cách xác minh lại báo cáo này (cho phiên Claude Code khác)

- Danh sách route gateway: `grep -n "@app\.\(get\|post\)" Auto_calib/AutoBoardOffset_YOLO_2Mat/gateway/plc_offset_gateway.py`
- Xác nhận file gateway thật đang chạy: `Auto_calib/AutoBoardOffset_YOLO_2Mat/gateway/run_gateway.py` dòng 15
- Label 2 field trong màn thêm mã hàng: `Auto_VRS_Meiko_Automation_App_Flutter/App/lib/screens/model_management/add_model_screen.dart` dòng 52 và 69
- Cột bảng chọn mã hàng: `Auto_VRS_Meiko_Automation_App_Flutter/App/lib/screens/model_management/select_model_screen.dart` dòng 192-238
- Bug int.parse: `Auto_VRS_Meiko_Automation_App_Flutter/App/lib/providers/vrs_provider.dart` dòng 212, 230

---

## 6. Cập nhật — Đã pull backend + triển khai xong (cùng ngày 2026-08-15)

Người dùng phản hồi: 3 endpoint có thật, nằm ở repo `AutoBoardOffset_YOLO_2Mat` (sibling repo,
git riêng, remote GitHub `origin` + GitLab `gitlab`), đã commit + push lên `origin/main` tới
commit `cefdde6`. Máy này khi kiểm tra lần đầu (mục 2.1) chưa `git pull` nên chỉ thấy bản cũ ở
commit `5895d30`, dẫn tới kết luận sai "endpoint chưa tồn tại".

**Đã làm để xác minh + đồng bộ:**
1. `cd Auto_calib/AutoBoardOffset_YOLO_2Mat && git status` — xác nhận đây là git repo riêng,
   có 1 thay đổi local chưa commit ở `gateway/plc_offset_gateway.py` (đổi nhãn log
   "soi lỗi" → "kiểm tra lỗi", 1 dòng, không liên quan tính năng).
2. `git fetch origin` — kéo về commit mới, xác nhận `origin/main` nhảy từ `5895d30` lên
   `cefdde6` (tag đi kèm: `truoc_khi_them_ma_hang_20260815`). Xác nhận `git log --oneline
   origin/main..main` rỗng (local không có commit riêng nào, an toàn fast-forward).
3. `git stash` thay đổi local 1 dòng đó → `git merge --ff-only origin/main` → `git stash pop`
   (auto-merge thành công, không conflict). Các commit mới kéo về gồm
   `ae67880 Add multi-product-code (ma hang) support...`, `8edf80a Gather calib/offset files
   of ma hang 23691025-250616-0004-nvq-aoi...`, `cefdde6 Remove dead PA2 single-product calib
   config, superseded by products_registry.yaml`.
4. Đọc lại `gateway/plc_offset_gateway.py` sau khi pull: xác nhận cả 3 route
   `GET /api/products`, `GET /api/products/active`, `POST /api/products/select` đã có (dòng
   1450, 1462, 1475), cùng class `ProductSelectRequest`/`ProductSelectResponse` (dòng 563-573)
   — field khớp 100% với spec người dùng đưa (`success`, `product_code`, `message`,
   `weights_path`, `calib_dir`, `fiducial_class_names`, đều `Optional`). Đọc
   `gateway/products_registry.yaml` — xác nhận format, có sẵn 1 mã hàng
   `23691025-250616-0004-nvq-aoi`.

**Đã code (đúng theo phần "Việc cần code" ở đầu file này):**

| File | Thay đổi |
|------|----------|
| `App/lib/services/plc_gateway_service.dart` | Thêm 3 method `getProducts()`, `getActiveProduct()`, `selectProduct(String)` theo đúng pattern các method khác (timeout, decode JSON, lấy `detail` khi non-200, bắt exception mạng trả `success:false`). Thêm 3 class `ProductsListResponse`, `ActiveProductResponse`, `ProductSelectResponse` cạnh các class response khác trong cùng file. |
| `App/lib/providers/vrs_provider.dart` | Thêm field `_lastSelectedProductCode` + getter `lastSelectedProductCode` + method `setLastSelectedProductCode(String)` — chỉ gọi khi gateway xác nhận `success:true`. |
| `App/lib/screens/model_management/select_model_screen.dart` | Sau dòng `await vrsProvider.setCurrentModelAndLot(modelId, idLot);`: lấy `model['name']` làm `productCode`, gọi `PlcGatewayService().selectProduct(productCode)`. Nếu `success:false` → hiện dialog lỗi rõ ràng (nêu message từ gateway + hướng dẫn liên hệ kỹ thuật viên sửa `products_registry.yaml`), **không** cập nhật `_selectedModelId`, **không** pop về màn trước — chặn operator tiếp tục với mã hàng chưa sẵn sàng. Nếu thành công → gọi `vrsProvider.setLastSelectedProductCode(productCode)` rồi mới tiếp tục luồng cũ (highlight + pop). |

**Đã kiểm tra:** `flutter analyze` toàn bộ app — 0 lỗi mới, chỉ còn các cảnh báo/info có sẵn từ
trước (đã tồn tại trước khi sửa: `avoid_print` toàn file `plc_gateway_service.dart` theo đúng
convention cũ, 1 `use_build_context_synchronously` info có sẵn ở dòng 41 không liên quan đến
đoạn code mới thêm).

**Chưa làm** (nằm ngoài phạm vi yêu cầu lần này, không tự ý thêm):
- Chưa sửa bug `int.parse(modelId)` ở `vrs_provider.dart:212,230` (mục 2.3) — vẫn tồn tại độc
  lập với tính năng này, đã ghi nhận trong audit `project_auto_vrs_full_audit_2026_08_15`.
- Chưa thêm validator/chuẩn hoá cho cột `name` (mục 4) dù đã chọn dùng làm product_code — rủi
  ro gõ sai/không nhất quán vẫn còn nguyên, cần quyết định riêng nếu muốn xử lý.
- Chưa sửa `vrs_main_screen.dart`/`manual_vrs_screen.dart` để tự động so sánh
  `lastSelectedProductCode` với `GET /api/products/active` — yêu cầu ban đầu chỉ nói "thêm field
  để màn hình khác CÓ THỂ so sánh", không yêu cầu wiring logic so sánh đó ngay.
