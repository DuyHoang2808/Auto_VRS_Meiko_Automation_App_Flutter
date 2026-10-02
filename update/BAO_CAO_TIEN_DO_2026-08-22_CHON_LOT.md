# Báo Cáo Tiến Độ — 22/08/2026

> Dự án: AutoVRS Meiko Automation (Flutter App)
> Hạng mục: Chọn mã Lot cho app Flutter, đồng bộ PLC Offset Gateway + QCamber
> Chi tiết kỹ thuật đầy đủ: xem `BAO_CAO_SO_SANH_LUONG_CHON_MA_HANG_CU_MOI.md` trong cùng thư mục.

---

**22/Aug/2026:**

**Vấn đề kỹ thuật:**

Trước đây, "chọn mã hàng" trên app Flutter chỉ là 1 thao tác đơn giản: operator bấm chọn 1 model,
app tự động đoán 1 lot (luôn lấy lot có id cũ nhất của model) rồi đóng màn hình - không đồng bộ gì
với hệ thống bên ngoài. Việc này phát sinh 4 vấn đề cụ thể:

- Kể từ khi `AOI_Ingest` đổi sang tạo **1 lot mới cho mỗi mã lot AOI thực sự ghi ra** (thay vì tái
  sử dụng mãi 1 lot rỗng như quy ước cũ), 1 model có thể tích luỹ nhiều lot theo thời gian - việc
  app tự đoán "lot cũ nhất" không còn đáng tin cậy, có thể khiến operator xử lý nhầm lot cũ trong
  khi lot đang thực sự chạy bị bỏ qua.
- Đổi mã hàng trên app không đồng bộ với PLC Offset Gateway - Gateway vẫn chạy weights YOLO + file
  calib của mã hàng cũ mà không ai biết, trong khi operator tưởng đã đổi xong.
- Job (file thiết kế) trên QCamber chỉ được mở khi có lỗi đầu tiên cần soi, khiến điểm lỗi đầu tiên
  của mỗi lần kiểm tra luôn chậm hơn hẳn các điểm sau.
- Không có cơ chế phát hiện khi QCamber đang mở nhầm file thiết kế, hoặc khi state "board tiếp
  theo" của model cũ còn dính lại sau khi đổi model - cả 2 trường hợp đều âm thầm sai mà không có
  cảnh báo.

**Tiến độ hiện tại:** Thay đổi cơ chế và thêm chức năng "chọn mã Lot" cho phần app Flutter, các
thay đổi bao gồm:

- Cho operator tự chọn đúng lot cần xử lý - vì 1 model giờ có thể có nhiều lot theo thời gian (mỗi
  lần AOI mở lot mới = 1 lot mới, không còn tái sử dụng mãi 1 lot như trước), việc app tự đoán "lot
  cũ nhất" không còn đáng tin cậy.
- Đồng bộ mã hàng đang chạy trên app Flutter với PLC Offset Gateway - để Gateway luôn dùng đúng
  weights YOLO + file calib của mã hàng operator vừa chọn, thay vì vẫn chạy mã hàng cũ mà không ai
  biết.
- Giảm độ trễ ở điểm lỗi đầu tiên khi kiểm tra, khi lấy ảnh thiết kế qua QCamber - trước đây job
  (file thiết kế) chỉ được mở khi có lỗi đầu tiên cần kiểm tra, khiến điểm đầu tiên luôn chậm hơn
  hẳn các điểm sau.
- Phát hiện và cảnh báo khi có sai lệch: mở nhầm file thiết kế trong QCamber, hoặc state cũ của
  model trước dính lại sau khi đổi model.

**Kết quả:**

- Operator có màn hình riêng để chọn đúng lot muốn xử lý trong danh sách đã lọc sẵn (chỉ còn lot
  chưa kiểm tra), thay vì để app tự chọn thay và có thể chọn sai lot khi 1 model có nhiều lot.
- App, PLC Gateway, và QCamber luôn được đồng bộ cùng 1 mã hàng tại thời điểm operator xác nhận
  chọn - loại bỏ hoàn toàn kiểu lỗi "app hiện mã hàng A nhưng Gateway vẫn chạy weights của mã hàng
  B".
- Điểm lỗi đầu tiên sau khi chọn mã hàng không còn phải chờ QCamber mở job từ đầu (đã mở sẵn qua
  `/api/preload`) - giảm độ trễ về mặt cơ chế.
- Có cảnh báo + tự dừng chu trình khi QCamber mở sai file thiết kế (409), thay vì trước đây lặng lẽ
  hiện sai ảnh hoặc không hiện gì mà không ai biết.
