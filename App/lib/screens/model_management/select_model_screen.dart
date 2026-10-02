import 'dart:async';
import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/aoi_machine_provider.dart';
import '../../providers/vrs_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/local_database_service.dart';
import '../../services/plc_gateway_service.dart';
import '../../services/qcamber_gerber_service.dart';
import '../../widgets/password_dialog.dart';
import '../../widgets/aoi_machine_dialog.dart';
import '../../main.dart';

class SelectModelScreen extends StatefulWidget {
  const SelectModelScreen({super.key});

  @override
  State<SelectModelScreen> createState() => _SelectModelScreenState();
}

class _SelectModelScreenState extends State<SelectModelScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _models = [];
  List<Map<String, dynamic>> _filteredModels = [];
  bool _isLoading = true;
  String? _selectedModelId; // Track the currently selected model

  // Đây là "đầu quy trình vận hành" (chọn model -> lot -> bo) - bắt buộc đã
  // chọn máy AOI trước khi tải danh sách model, xem didChangeDependencies.
  bool _didCheckMachineSelected = false;
  String? _machineAtLastLoad;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterModels);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final aoiMachineProvider = context.watch<AoiMachineProvider>();
    // Đợi SharedPreferences đọc xong (isLoaded=false) - tránh hiểu nhầm
    // "chưa từng chọn máy" trong lúc _load() còn đang await, dù thật ra đã
    // có lựa chọn lưu từ trước.
    if (!aoiMachineProvider.isLoaded) return;

    if (!_didCheckMachineSelected) {
      _didCheckMachineSelected = true;
      if (aoiMachineProvider.selectedMachine == null) {
        // Chưa từng chọn máy nào - bắt buộc chọn trước khi cho xem danh sách
        // model (canCancel: false, không có nút Huỷ/bấm ra ngoài để đóng).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) AoiMachineDialog.show(context, canCancel: false);
        });
        return;
      }
    }

    // Tải lại khi máy đổi (kể cả đổi từ chip trên top bar trong lúc đang mở
    // màn này) - so sánh với máy của lần tải gần nhất để không tải lặp lại
    // vô ích mỗi lần build.
    final machine = aoiMachineProvider.selectedMachine;
    if (machine != null && machine != _machineAtLastLoad) {
      _machineAtLastLoad = machine;
      _loadModels();
    }
  }

  Future<void> _loadModels() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final dbService = LocalDatabaseService();
      final aoiMachine = context.read<AoiMachineProvider>().selectedMachine;
      final models = await dbService.getAllModels(aoiMachine: aoiMachine);

      // Get current model from provider to highlight it
      final vrsProvider = Provider.of<VRSProvider>(context, listen: false);
      final currentModelId = vrsProvider.currentModel;

      setState(() {
        _models = models;
        _filteredModels = models;
        _selectedModelId = currentModelId;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Lỗi tải dữ liệu: $e')),
        );
      }
    }
  }

  void _filterModels() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredModels = _models.where((model) {
        final idModelStr = model['id_model']?.toString().toLowerCase() ?? '';
        final nameStr = model['name']?.toString().toLowerCase() ?? '';
        return idModelStr.contains(query) || nameStr.contains(query);
      }).toList();
    });
  }

  /// Xác thực Admin (nếu chưa) trước khi cho phép thêm/sửa/xóa mã hàng hoặc
  /// quản lý board. Worker được vào màn này để chọn model/lot/đợt board
  /// chạy (xem sidebar_navigation.dart), nhưng KHÔNG có quyền chỉnh sửa hay
  /// xóa - mọi thao tác đổi dữ liệu đều phải xác thực Admin ngay tại đây,
  /// độc lập với gate ở cấp màn hình/route.
  Future<bool> _requireAdmin(String title) async {
    final authProvider = context.read<AuthProvider>();
    if (authProvider.isAdminAuthenticated) return true;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PasswordDialog(
        title: title,
        onAuthenticated: (password) => authProvider.authenticateAdmin(password),
      ),
    );

    if (!mounted) return false;
    return authProvider.isAdminAuthenticated;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Chọn bộ tham số mã hàng',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  Row(
                    children: [
                      // ✅ Nút Refresh
                      IconButton(
                        onPressed: _isLoading ? null : _loadModels,
                        icon: const Icon(FeatherIcons.refreshCw),
                        tooltip: 'Làm mới danh sách',
                        color: Colors.blue.shade600,
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () async {
                          if (!await _requireAdmin(
                            'Xác thực Admin - Thêm mã hàng',
                          )) {
                            return;
                          }
                          if (!mounted) return;
                          // ✅ Đợi quay lại từ màn hình Add Model
                          await context.push('/add-model');
                          // ✅ Refresh danh sách sau khi quay lại
                          if (mounted) {
                            _loadModels();
                          }
                        },
                        icon: const Icon(FeatherIcons.plus, size: 18),
                        label: const Text('Thêm mã hàng mới'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade600,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Search
              TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: 'Tìm kiếm theo mã hàng hoặc tên...',
                  prefixIcon: Icon(FeatherIcons.search),
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 24),

              // Content
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _models.isEmpty
                    ? _buildEmptyState()
                    : _buildModelTable(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(FeatherIcons.package, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'Chưa có mã hàng nào',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            'Hãy thêm mã hàng mới để bắt đầu',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
              if (!await _requireAdmin('Xác thực Admin - Thêm mã hàng')) {
                return;
              }
              if (!mounted) return;
              // ✅ Đợi quay lại từ màn hình Add Model
              await context.push('/add-model');
              // ✅ Refresh danh sách sau khi quay lại
              if (mounted) {
                _loadModels();
              }
            },
            icon: const Icon(FeatherIcons.plus, size: 18),
            label: const Text('Thêm mã hàng mới'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade600,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelTable() {
    return SingleChildScrollView(
      child: DataTable(
        columnSpacing: 40,
        columns: const [
          DataColumn(
            label: Text(
              'Mã hàng ',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          DataColumn(
            label: Text('Tên', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          DataColumn(
            label: Text(
              'Kích thước Line',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          DataColumn(
            label: Text(
              'Kích thước Space',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          DataColumn(
            label: Text(
              'Thao tác',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
        rows: _filteredModels
            .map(
              (model) => DataRow(
                cells: [
                  DataCell(
                    Text(
                      model['id_model']?.toString() ?? 'Unknown',
                      style: TextStyle(
                        fontWeight:
                            model['id_model']?.toString() == _selectedModelId
                            ? FontWeight.bold
                            : FontWeight.w500,
                        color: model['id_model']?.toString() == _selectedModelId
                            ? Colors.blue
                            : Colors.black,
                      ),
                    ),
                  ),
                  DataCell(Text(model['name']?.toString() ?? 'N/A')),
                  DataCell(Text(model['line_size']?.toString() ?? 'N/A')),
                  DataCell(Text(model['space_size']?.toString() ?? 'N/A')),
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ElevatedButton(
                          onPressed:
                              model['id_model']?.toString() == _selectedModelId
                              ? null
                              : () => _selectModel(model),
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                model['id_model']?.toString() ==
                                    _selectedModelId
                                ? Colors.grey.shade400
                                : Colors.green.shade500,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          child: Text(
                            model['id_model']?.toString() == _selectedModelId
                                ? 'Đang chọn'
                                : 'Chọn',
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Sửa kích thước Line/Space (yêu cầu Admin)',
                          icon: Icon(Icons.edit, color: Colors.blue.shade600),
                          onPressed: () async {
                            if (!await _requireAdmin(
                              'Xác thực Admin - Sửa mã hàng',
                            )) {
                              return;
                            }
                            if (!mounted) return;
                            _showEditSizesDialog(model);
                          },
                        ),
                        IconButton(
                          tooltip: 'Quản lý / xoá board (yêu cầu Admin)',
                          icon: Icon(
                            FeatherIcons.list,
                            color: Colors.orange.shade700,
                          ),
                          onPressed: () => _manageBoards(model),
                        ),
                        IconButton(
                          tooltip: 'Xóa (yêu cầu Admin)',
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () async {
                            if (!await _requireAdmin(
                              'Xác thực Admin - Xóa mã hàng',
                            )) {
                              return;
                            }
                            if (!mounted) return;
                            _onDeleteModel(model);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
            .toList(),
      ),
    );
  }

  void _selectModel(Map<String, dynamic> model) async {
    // Hiển thị dialog xác nhận
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xác nhận lựa chọn'),
        content: Text(
          'Bạn có chắc chắn muốn sử dụng bộ tham số ${model['id_model'].toString()}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Xác nhận'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      // Capture router before async gaps to avoid using context after await
      final router = GoRouter.of(context);
      final modelId = model['id_model'].toString();

      // Sau khi xác nhận model, chuyển tiếp sang màn chọn lot cụ thể (chỉ
      // liệt kê lot chưa xử lý hết bo) - thay vì để app tự đoán lot như
      // trước đây. Màn đó trả về id_lot đã chọn qua context.pop(idLot);
      // null nếu vận hành viên bấm back mà không chọn gì.
      final idLot = await router.push<int>('/select-lot-for-model/$modelId');
      if (idLot == null || !mounted) return;

      // Máy VRS thật chỉ tải được 1 số board hạn chế mỗi lần (~100 hoặc ít
      // hơn) - nếu lot này chưa có "đợt" (khoảng board) nào đang chạy, bắt
      // vận hành viên chọn 1 đợt TRƯỚC khi vào VRS (xem
      // SelectBoardBatchScreen). Đặt TRƯỚC setCurrentModelAndLot để
      // _applyLot (gọi trong đó) nạp đúng đợt mới tạo trong 1 lượt.
      final db = LocalDatabaseService();
      final activeBatch = await db.getActiveBatchForLot(idLot);
      if (!mounted) return;
      if (activeBatch == null) {
        // Lot có thể vừa được AOI_Ingest tạo (tbLot) nhưng chưa ghi board
        // nào - màn chọn đợt sẽ trống, không có gì để chọn (dead-end). Bỏ
        // qua bước chọn đợt cho trường hợp này, vào thẳng như trước khi có
        // tính năng đợt; _applyLot sẽ tự hiện "Chưa có" cho tới khi board
        // đầu tiên tới, KHÔNG báo nhầm thành "đã hoàn tất".
        final hasAnyBoard = await db.lotHasAnyBoard(idLot);
        if (!mounted) return;
        if (hasAnyBoard) {
          final idBatch = await router.push<int>('/select-board-batch/$idLot');
          if (idBatch == null || !mounted) return; // hủy -> không đổi gì
        }
      }

      // Cập nhật model + lot trong Provider
      final vrsProvider = Provider.of<VRSProvider>(context, listen: false);
      await vrsProvider.setCurrentModelAndLot(modelId, idLot);

      // Báo cho PLC Gateway đổi sang đúng mã hàng (weights YOLO + file calib
      // tương ứng) - product_code lấy từ cột `name`, KHÔNG PHẢI id_model (xem
      // update/BAO_CAO_KIEM_TRA_TICH_HOP_PRODUCT_CODE_GATEWAY.md).
      final productCode = model['name']?.toString();
      if (productCode != null && productCode.isNotEmpty) {
        final selectResult = await PlcGatewayService().selectProduct(
          productCode,
        );
        if (!mounted) return;
        if (!selectResult.success) {
          // CHẶN operator: không cập nhật _selectedModelId, không pop về màn
          // trước - gateway vẫn đang chạy mã hàng cũ, để operator tiếp tục
          // như đã chọn xong sẽ chạy nhầm model YOLO + calib.
          await showDialog(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                icon: const Icon(Icons.error, color: Colors.red, size: 48),
                title: const Text('Không thể đổi mã hàng trên Gateway'),
                content: Text(
                  'Mã hàng "$productCode" chưa sẵn sàng trên PLC Gateway:\n\n'
                  '${selectResult.message}\n\n'
                  'Gateway vẫn đang chạy mã hàng trước đó. Liên hệ kỹ thuật '
                  'viên để thêm/sửa mã hàng này trong products_registry.yaml '
                  'trước khi chạy VRS với mã hàng "$productCode".',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Đóng'),
                  ),
                ],
              );
            },
          );
          return;
        }
        vrsProvider.setLastSelectedProductCode(productCode);

        // Báo trước QCamber mở sẵn job của mã hàng này ngay bây giờ (trước khi
        // máy bắt đầu chạy) - không chờ kết quả, vì đây chỉ là tối ưu độ trễ
        // cho điểm lỗi đầu tiên (/api/capture) chứ không phải điều kiện bắt
        // buộc để tiếp tục chọn mã hàng. Không gọi khi selectProduct thất bại
        // ở trên (đã return) - operator bị chặn với mã hàng đó rồi, mở job
        // Gerber lúc này là vô ích.
        // jobName QCamber dùng để mở job suy ra từ url_gerber nếu có cấu
        // hình riêng (tên mã hàng ≠ tên thư mục job thật) - KHÔNG dùng thẳng
        // productCode (= model['name'], chỉ đúng cho PLC Gateway ở trên) -
        // xem QCamberGerberService.resolveJobName.
        unawaited(
          Provider.of<QCamberGerberService>(
            context,
            listen: false,
          ).preloadJob(QCamberGerberService.resolveJobName(model)),
        );
      }

      // Update selected model ID for UI highlighting
      setState(() {
        _selectedModelId = modelId;
      });

      // ✅ Bỏ snackbar vì đã có thông báo model đang chọn ở UI

      // Quay lại màn hình trước nếu có thể (use captured router)
      if (!mounted) return;
      if (router.canPop()) {
        router.pop();
      }
    } catch (e) {
      // Hiển thị lỗi bằng Dialog để nhất quán
      if (!mounted) return;

      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            icon: const Icon(Icons.error, color: Colors.red, size: 48),
            title: const Text('Lỗi'),
            content: Text('Không thể chọn model: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Đóng'),
              ),
            ],
          );
        },
      );
    }
  }

  /// Xác thực Admin (nếu chưa) rồi đẩy sang chọn lot -> quản lý/xoá board
  /// của mã hàng này. KHÔNG đi qua setCurrentModelAndLot/
  /// PlcGatewayService.selectProduct như `_selectModel` - đây thuần công cụ
  /// quản lý dữ liệu, không được có tác dụng phụ đổi mã hàng đang chạy trên
  /// PLC Gateway.
  Future<void> _manageBoards(Map<String, dynamic> model) async {
    if (!await _requireAdmin('Xác thực Admin - Quản lý board')) return;

    if (!mounted) return;
    final router = GoRouter.of(context);
    final modelId = model['id_model'].toString();
    final idLot = await router.push<int>('/select-lot-for-model/$modelId');
    if (idLot == null || !mounted) return;
    await router.push('/manage-boards/$idLot');
  }

  Future<void> _showEditSizesDialog(Map<String, dynamic> model) async {
    final formKey = GlobalKey<FormState>();
    final lineSizeController = TextEditingController(
      text: model['line_size']?.toString() ?? '',
    );
    final spaceSizeController = TextEditingController(
      text: model['space_size']?.toString() ?? '',
    );
    // Đường dẫn đầy đủ tới thư mục job QCamber thật - dùng khi tên mã hàng
    // không trùng tên thư mục job (xem QCamberGerberService.resolveJobName).
    // Rỗng = chưa cấu hình, tiếp tục dùng tên mã hàng làm tên job như mặc định.
    final urlGerberController = TextEditingController(
      text: model['url_gerber']?.toString() ?? '',
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Sửa mã hàng - ${model['id_model']}'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: lineSizeController,
                  decoration: const InputDecoration(
                    labelText: 'Kích thước Line (line_size)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Vui lòng nhập kích thước Line';
                    }
                    if (double.tryParse(value) == null) {
                      return 'Vui lòng nhập số hợp lệ';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: spaceSizeController,
                  decoration: const InputDecoration(
                    labelText: 'Kích thước Space (space_size)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Vui lòng nhập kích thước Space';
                    }
                    if (double.tryParse(value) == null) {
                      return 'Vui lòng nhập số hợp lệ';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 20),
                const Text(
                  'Đường dẫn file thiết kế (nếu tên mã hàng KHÁC tên thư '
                  'mục job trong QCamber)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: urlGerberController,
                  decoration: const InputDecoration(
                    labelText: 'Đường dẫn thư mục job (url_gerber)',
                    hintText:
                        r'vd D:\...\Qcamber-Meiko\bin\Jobs\23691025-250616-0004-nvq-aoi',
                    border: OutlineInputBorder(),
                  ),
                  // Chỉ có tác dụng đổi tên job QCamber (xem
                  // resolveJobName), không phải input bắt buộc.
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tên job QCamber sẽ dùng: '
                  '${QCamberGerberService.resolveJobName({...model, 'url_gerber': urlGerberController.text})}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(dialogContext, true);
                }
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      final idModel = model['id_model'];
      if (idModel is int) {
        try {
          await LocalDatabaseService().updateModelSizes(
            idModel,
            lineSize: double.parse(lineSizeController.text.trim()),
            spaceSize: double.parse(spaceSizeController.text.trim()),
            urlGerber: urlGerberController.text.trim(),
          );
          if (mounted) {
            await _loadModels();
            scaffoldMessengerKey.currentState?.showSnackBar(
              SnackBar(
                content: Text('Đã cập nhật mã hàng $idModel'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            scaffoldMessengerKey.currentState?.showSnackBar(
              SnackBar(
                content: Text('Lỗi khi cập nhật: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    }

    // KHÔNG dispose() ngay - Future của showDialog() hoàn tất ngay khi
    // Navigator.pop() được gọi, TRƯỚC KHI animation đóng dialog chạy xong.
    // Dispose controller còn đang gắn với TextFormField mà Element của nó
    // CHƯA unmount hẳn (còn giữa animation) làm hỏng state nội bộ của
    // framework - lỗi thật đã gặp và tái hiện được 100% bằng widget test:
    // "'_dependents.isEmpty': is not true" ngay khi bấm Lưu/Hủy sau khi gõ
    // vào 1 trong 3 ô. Trễ 300ms (dư so với thời lượng animation dialog mặc
    // định của Material) trước khi dispose để tránh race này.
    Future.delayed(const Duration(milliseconds: 300), () {
      lineSizeController.dispose();
      spaceSizeController.dispose();
      urlGerberController.dispose();
    });
  }

  Future<void> _onDeleteModel(Map<String, dynamic> model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xác nhận xóa'),
        content: Text(
          'Bạn có chắc chắn muốn xóa mã hàng ${model['id_model']} không?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final db = LocalDatabaseService();
      final id = model['id_model'];
      if (id is int) {
        final deleted = await db.deleteModel(id);
        if (deleted > 0) {
          await _loadModels();
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text('Xóa thành công mã hàng $id'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          scaffoldMessengerKey.currentState?.showSnackBar(
            const SnackBar(
              content: Text('Không tìm thấy mã hàng để xóa'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('ID mã hàng không hợp lệ'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Lỗi khi xóa: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}
