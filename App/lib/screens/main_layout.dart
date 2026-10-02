import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import '../providers/aoi_machine_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/vrs_provider.dart';
import '../widgets/sidebar_navigation.dart';
import '../widgets/password_dialog.dart';
import '../widgets/aoi_machine_dialog.dart';

class MainLayout extends StatelessWidget {
  final Widget child;

  const MainLayout({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isSidebarVisible = context
        .watch<NavigationProvider>()
        .isSidebarVisible;
    return Scaffold(
      body: Row(
        children: [
          // Sidebar Navigation - ẩn/hiện được qua nút ở top bar (xem
          // _buildTopBar), state nằm ở NavigationProvider để không mất lựa
          // chọn khi chuyển route (MainLayout bị tạo lại mỗi lần điều hướng).
          if (isSidebarVisible) const SidebarNavigation(),

          // Main Content Area
          Expanded(
            child: Column(
              children: [
                // Top Bar
                _buildTopBar(context),

                // Content
                Expanded(
                  child: Container(
                    color: Theme.of(context).colorScheme.surface,
                    padding: const EdgeInsets.all(16),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Consumer<NavigationProvider>(
      builder: (context, navigationProvider, _) {
        return Container(
          height: 64,
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // Ẩn/hiện thanh menu bên trái - luôn hiện (không phụ thuộc
                // canGoBack) để operator luôn có cách mở lại sidebar.
                IconButton(
                  onPressed: navigationProvider.toggleSidebar,
                  icon: Icon(
                    navigationProvider.isSidebarVisible
                        ? FeatherIcons.menuOpen
                        : FeatherIcons.menu,
                  ),
                  color: Colors.white,
                  tooltip: navigationProvider.isSidebarVisible
                      ? 'Ẩn menu'
                      : 'Hiện menu',
                ),

                // Back Button
                if (navigationProvider.canGoBack)
                  IconButton(
                    onPressed: () => navigationProvider.goBack(),
                    icon: const Icon(FeatherIcons.arrowLeft),
                    color: Colors.white,
                    tooltip: 'Quay lại',
                  ),

                // Title
                Expanded(
                  child: Text(
                    navigationProvider.getViewTitle(
                      GoRouterState.of(context).name ?? 'home',
                    ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

                // Máy AOI đang chọn - đổi được bất cứ lúc nào, xem
                // _buildAoiMachineChip.
                _buildAoiMachineChip(context),

                const SizedBox(width: 16),

                // Current Time
                _buildCurrentTime(),

                const SizedBox(width: 16),

                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, _) {
                    return IconButton(
                      onPressed: themeProvider.toggleTheme,
                      icon: Icon(
                        themeProvider.isDarkMode
                            ? FeatherIcons.sun
                            : FeatherIcons.moon,
                      ),
                      color: Colors.white,
                      tooltip: themeProvider.isDarkMode
                          ? 'Chuyen sang nen sang'
                          : 'Chuyen sang nen toi',
                    );
                  },
                ),

                const SizedBox(width: 8),

                // User Menu
                _buildUserMenu(context),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Chip hiện máy AOI đang chọn (xem AoiMachineProvider) - bấm để đổi bất
  /// cứ lúc nào, không chỉ lúc bắt buộc chọn lần đầu ở SelectModelScreen.
  /// Đặt ở top bar (hiện trên MỌI màn hình qua MainLayout) để vận hành viên
  /// luôn biết đang xem dữ liệu của máy nào.
  Widget _buildAoiMachineChip(BuildContext context) {
    return Consumer<AoiMachineProvider>(
      builder: (context, aoiMachineProvider, _) {
        final selected = aoiMachineProvider.selectedMachine;
        return OutlinedButton.icon(
          onPressed: () async {
            final previous = aoiMachineProvider.selectedMachine;
            final result = await AoiMachineDialog.show(context);
            // Đổi máy -> reset sạch model/lot/board/đợt đang chọn (bẫy đã
            // biết - dữ liệu của máy cũ hoàn toàn không liên quan tới máy
            // mới). KHÔNG reset nếu operator huỷ (result null) hoặc chọn lại
            // đúng máy cũ.
            if (result != null && result != previous && context.mounted) {
              await context.read<VRSProvider>().resetSelection();
            }
          },
          icon: Icon(
            FeatherIcons.monitor,
            size: 16,
            color: selected == null ? Colors.orangeAccent : Colors.white,
          ),
          label: Text(
            selected == null ? 'Chưa chọn máy' : 'Máy: $selected',
            style: TextStyle(
              color: selected == null ? Colors.orangeAccent : Colors.white,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(
              color: selected == null
                  ? Colors.orangeAccent
                  : Colors.white.withValues(alpha: 0.6),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCurrentTime() {
    return StreamBuilder<DateTime>(
      stream: Stream.periodic(
        const Duration(seconds: 1),
        (_) => DateTime.now(),
      ),
      builder: (context, snapshot) {
        final now = snapshot.data ?? DateTime.now();
        return Text(
          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        );
      },
    );
  }

  Widget _buildUserMenu(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        return PopupMenuButton<String>(
          icon: const Icon(FeatherIcons.user, color: Colors.white),
          onSelected: (value) {
            switch (value) {
              case 'logout':
                authProvider.logout();
                break;
              case 'worker_login':
                _showPasswordDialog(context, 'worker');
                break;
              case 'admin_login':
                _showPasswordDialog(context, 'admin');
                break;
            }
          },
          itemBuilder: (context) => [
            if (!authProvider.hasAnyAuth) ...[
              const PopupMenuItem(
                value: 'worker_login',
                child: Row(
                  children: [
                    Icon(FeatherIcons.user),
                    SizedBox(width: 8),
                    Text('Đăng nhập Worker'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'admin_login',
                child: Row(
                  children: [
                    Icon(FeatherIcons.shield),
                    SizedBox(width: 8),
                    Text('Đăng nhập Admin'),
                  ],
                ),
              ),
            ] else ...[
              PopupMenuItem(
                enabled: false,
                child: Row(
                  children: [
                    Icon(
                      authProvider.isAdminAuthenticated
                          ? FeatherIcons.shield
                          : FeatherIcons.user,
                      color: Colors.green,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      authProvider.isAdminAuthenticated ? 'Admin' : 'Worker',
                      style: const TextStyle(color: Colors.green),
                    ),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(FeatherIcons.logOut),
                    SizedBox(width: 8),
                    Text('Đăng xuất'),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  void _showPasswordDialog(BuildContext context, String role) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PasswordDialog(
        title: role == 'admin' ? 'Đăng nhập Admin' : 'Đăng nhập Worker',
        onAuthenticated: (password) async {
          final authProvider = context.read<AuthProvider>();
          bool success = false;

          if (role == 'admin') {
            success = await authProvider.authenticateAdmin(password);
          } else {
            success = await authProvider.authenticateWorker(password);
          }

          return success;
        },
      ),
    );
  }
}
