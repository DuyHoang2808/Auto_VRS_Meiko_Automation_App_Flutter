import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class SidebarNavigation extends StatelessWidget {
  const SidebarNavigation({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: 230,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // Logo/Header
          _buildHeader(),

          // Navigation Menu
          Expanded(child: _buildNavigationMenu(context)),

          // Footer
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 80,
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(color: Color(0xFF1E40AF)),
      child: const Row(
        children: [
          Icon(FeatherIcons.monitor, color: Colors.white, size: 32),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'AutoVRS\nSystem',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationMenu(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final menuItems = _getMenuItems(authProvider);

        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: menuItems
              .map((item) => _buildMenuItem(context, item))
              .toList(),
        );
      },
    );
  }

  List<NavigationItem> _getMenuItems(AuthProvider authProvider) {
    return [
      NavigationItem(
        title: 'Trang chủ',
        icon: FeatherIcons.home,
        route: '/',
        requiredAuth: null,
      ),
      NavigationItem(
        title: 'Cài đặt Model',
        icon: FeatherIcons.settings,
        route: '/select-model',
        // Worker được vào để chọn model/lot/đợt board chạy - thao tác sửa
        // (kích thước Line/Space, url_gerber), thêm mã hàng mới, xóa mã
        // hàng, quản lý/xóa board đều yêu cầu xác thực Admin riêng ngay tại
        // nút bấm (xem select_model_screen.dart), không phụ thuộc vào gate
        // ở cấp màn hình này.
        requiredAuth: 'worker',
      ),
      NavigationItem(
        title: 'Giám sát Auto VRS',
        icon: FeatherIcons.monitor,
        route: '/vrs-main',
        requiredAuth: 'worker',
      ),
      NavigationItem(
        title: 'VRS Thủ công',
        icon: FeatherIcons.eye,
        route: '/manual-vrs',
        requiredAuth: 'worker',
      ),
      NavigationItem(
        title: 'Thống kê',
        icon: FeatherIcons.barChart,
        route: '/statistics',
        requiredAuth: 'worker',
      ),
    ];
  }

  Widget _buildMenuItem(BuildContext context, NavigationItem item) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final isAccessible =
            item.requiredAuth == null ||
            authProvider.canAccessFeature(item.requiredAuth!);

        final currentRoute = GoRouterState.of(context).uri.path;
        final isSelected = currentRoute == item.route;
        final colorScheme = Theme.of(context).colorScheme;
        final selectedColor = colorScheme.primary;
        final defaultColor = colorScheme.onSurface.withValues(alpha: 0.82);
        final mutedColor = colorScheme.onSurface.withValues(alpha: 0.55);
        final disabledColor = colorScheme.onSurface.withValues(alpha: 0.32);

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Material(
            color: isSelected
                ? selectedColor.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: isAccessible ? () => context.go(item.route) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      color: isAccessible
                          ? (isSelected ? selectedColor : mutedColor)
                          : disabledColor,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item.title,
                        style: TextStyle(
                          color: isAccessible
                              ? (isSelected ? selectedColor : defaultColor)
                              : disabledColor,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (!isAccessible)
                      Icon(FeatherIcons.lock, color: disabledColor, size: 16),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.grey.withValues(alpha: 0.35)),
        ),
      ),
      child: const Column(
        children: [
          Text(
            'AutoVRS v1.0.0',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          SizedBox(height: 4),
          Text(
            '© 2025 Meiko Automation',
            style: TextStyle(color: Colors.grey, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class NavigationItem {
  final String title;
  final IconData icon;
  final String route;
  final String? requiredAuth;

  NavigationItem({
    required this.title,
    required this.icon,
    required this.route,
    this.requiredAuth,
  });
}
