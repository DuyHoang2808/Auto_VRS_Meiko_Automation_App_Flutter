import 'package:go_router/go_router.dart';
import '../screens/main_layout.dart';
import '../screens/home_screen.dart';
import '../screens/model_management/select_model_screen.dart';
import '../screens/model_management/select_lot_for_model_screen.dart';
import '../screens/model_management/select_board_batch_screen.dart';
import '../screens/model_management/manage_boards_screen.dart';
import '../screens/model_management/add_model_screen.dart';
import '../screens/vrs/vrs_main_screen.dart';
import '../screens/vrs/manual_vrs_screen.dart';
import '../screens/vrs/light_adjust_screen.dart';
import '../screens/alignment/board_align_screen.dart';
import '../screens/statistics/statistics_screen.dart';
import '../screens/statistics/ng_rate_screen.dart';
import '../screens/statistics/select_lot_screen.dart';
import '../screens/statistics/defect_type_screen.dart';
import '../screens/statistics/ai_agreement_screen.dart';
import '../screens/camera_screen.dart';

class AppRoutes {
  static final GoRouter router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'home',
        builder: (context, state) => const MainLayout(child: HomeScreen()),
      ),
      GoRoute(
        path: '/select-model',
        name: 'select_model',
        builder: (context, state) =>
            const MainLayout(child: SelectModelScreen()),
      ),
      GoRoute(
        path: '/add-model',
        name: 'add_model',
        builder: (context, state) => const MainLayout(child: AddModelScreen()),
      ),
      GoRoute(
        // Đẩy sang từ SelectModelScreen sau khi xác nhận model - vận hành
        // viên chọn tiếp 1 lot cụ thể (chỉ liệt kê lot chưa xử lý hết bo).
        // Trả về id_lot qua context.pop(idLot) - xem SelectLotForModelScreen.
        path: '/select-lot-for-model/:modelId',
        name: 'select_lot_for_model',
        builder: (context, state) => MainLayout(
          child: SelectLotForModelScreen(
            modelId: state.pathParameters['modelId']!,
          ),
        ),
      ),
      GoRoute(
        // Đẩy sang từ SelectModelScreen ngay sau khi có idLot, CHỈ khi lot đó
        // chưa có đợt nào đang chạy (xem LocalDatabaseService.
        // getActiveBatchForLot) - vận hành viên chọn khoảng board (đợt) sẽ
        // nạp lên máy VRS thật lần này. Trả về id_batch vừa tạo qua
        // context.pop(idBatch) - xem SelectBoardBatchScreen.
        path: '/select-board-batch/:idLot',
        name: 'select_board_batch',
        builder: (context, state) => MainLayout(
          child: SelectBoardBatchScreen(
            idLot: int.parse(state.pathParameters['idLot']!),
          ),
        ),
      ),
      GoRoute(
        // Đẩy sang từ SelectModelScreen (nút "Quản lý board" mỗi hàng mã
        // hàng, đã yêu cầu Admin xác thực trước) -> SelectLotForModelScreen
        // (chọn lot) -> màn này, liệt kê board pending của lot đó kèm nút
        // xoá. KHÔNG đi qua setCurrentModelAndLot/PlcGatewayService.selectProduct
        // - thuần công cụ quản lý dữ liệu, không đổi mã hàng đang chạy trên
        // PLC Gateway. Xem ManageBoardsScreen.
        path: '/manage-boards/:idLot',
        name: 'manage_boards',
        builder: (context, state) => MainLayout(
          child: ManageBoardsScreen(
            idLot: int.parse(state.pathParameters['idLot']!),
          ),
        ),
      ),
      GoRoute(
        path: '/vrs-main',
        name: 'vrs_main',
        builder: (context, state) => const MainLayout(child: VRSMainScreen()),
      ),
      GoRoute(
        path: '/manual-vrs',
        name: 'manual_vrs',
        builder: (context, state) => const MainLayout(child: ManualVRSScreen()),
      ),
      GoRoute(
        path: '/light-adjust',
        name: 'light_adjust',
        builder: (context, state) =>
            const MainLayout(child: LightAdjustScreen()),
      ),
      GoRoute(
        path: '/board-align/:step',
        name: 'board_align',
        builder: (context, state) {
          final step = int.tryParse(state.pathParameters['step'] ?? '1') ?? 1;
          return MainLayout(child: BoardAlignScreen(step: step));
        },
      ),
      GoRoute(
        path: '/statistics',
        name: 'statistics',
        builder: (context, state) =>
            const MainLayout(child: StatisticsScreen()),
      ),
      GoRoute(
        path: '/ng-rate',
        name: 'ng_rate',
        builder: (context, state) => const MainLayout(child: NGRateScreen()),
      ),
      GoRoute(
        path: '/select-lot',
        name: 'select_lot',
        builder: (context, state) => const MainLayout(child: SelectLotScreen()),
      ),
      GoRoute(
        path: '/defect-type',
        name: 'defect_type',
        // ?lot=<id_lot> giới hạn thống kê vào 1 lô; không có = tất cả các lô.
        // Trước đây SelectLotScreen push sang đây mà KHÔNG truyền gì, nên chọn
        // lô nào cũng ra cùng một con số tổng của toàn bộ DB.
        builder: (context, state) => MainLayout(
          child: DefectTypeScreen(
            lotId: int.tryParse(state.uri.queryParameters['lot'] ?? ''),
          ),
        ),
      ),
      GoRoute(
        path: '/ai-agreement',
        name: 'ai_agreement',
        builder: (context, state) =>
            const MainLayout(child: AiAgreementScreen()),
      ),
      GoRoute(
        path: '/camera',
        name: 'camera',
        builder: (context, state) => const CameraScreen(),
      ),
    ],
  );
}
