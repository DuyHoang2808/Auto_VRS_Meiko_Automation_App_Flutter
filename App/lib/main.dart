import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'core/app_runtime_config.dart';
import 'core/app_theme.dart';
import 'core/routes.dart';
import 'providers/auth_provider.dart';
import 'providers/navigation_provider.dart';
import 'providers/statistics_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/vrs_provider.dart';
import 'services/ai_detection_service.dart';
import 'services/autovrs_websocket_service.dart';
import 'services/local_database_service.dart';
import 'services/qcamber_gerber_service.dart';
import 'services/flutter_camera_service.dart';
import 'services/startup_health_check.dart';

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('Flutter error: ${details.exceptionAsString()}');
    debugPrintStack(stackTrace: details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught platform error: $error');
    debugPrintStack(stackTrace: stack);
    return false;
  };

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  try {
    if (Platform.isWindows) {
      final directory = Directory.current;
      await Hive.initFlutter('${directory.path}/hive_data');
    } else {
      await Hive.initFlutter();
    }
  } catch (e) {
    debugPrint(
      'Warning: Hive initialization failed, continuing without Hive: $e',
    );
  }

  try {
    final dbService = LocalDatabaseService();
    final dbPath = await dbService.databasePath;
    debugPrint('SQLite database path: $dbPath');
    await dbService.database;
    debugPrint('Database initialized successfully');
  } catch (e) {
    debugPrint('Warning: Database initialization failed: $e');
    debugPrint('App will continue without local database');
  }

  try {
    await AppRuntimeConfig.instance.initialize();
    debugPrint(
      'Runtime config loaded from: ${AppRuntimeConfig.instance.loadedFilePath}',
    );
  } catch (e) {
    debugPrint('Warning: Runtime config initialization failed: $e');
  }

  // Kiểm tra trạng thái các API backend (QCamber, PLC Gateway, AI Detection)
  // ngay khi khởi động, rồi tiếp tục theo dõi định kỳ mỗi 15s để phát hiện
  // khi một dịch vụ mất kết nối hoặc mới kết nối lại — không chỉ kiểm tra
  // 1 lần lúc mở app.
  StartupHealthCheck.startMonitoring(
    onChange: (status) {
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            status.isUp
                ? '✅ ${status.name} đã kết nối lại'
                : '⚠️ ${status.name} không kết nối được (${status.baseUrl})',
          ),
          backgroundColor: status.isUp ? Colors.green : Colors.red,
          duration: const Duration(seconds: 6),
        ),
      );
    },
  );

  runApp(const AutoVRSApp());
}

class AutoVRSApp extends StatelessWidget {
  const AutoVRSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NavigationProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => VRSProvider()),
        ChangeNotifierProvider(create: (_) => StatisticsProvider()),
        ChangeNotifierProvider(create: (_) => AutoVRSWebSocketService()),
        ChangeNotifierProvider(create: (_) => AIDetectionService()),
        ChangeNotifierProvider(create: (_) => QCamberGerberService()),
        // THÊM CÁI NÀY
        ChangeNotifierProvider(create: (_) => FlutterCameraService()),
      ],
      child: const _AutoVRSBootstrap(child: _AutoVRSMaterialApp()),
    );
  }
}

class _AutoVRSBootstrap extends StatefulWidget {
  final Widget child;

  const _AutoVRSBootstrap({required this.child});

  @override
  State<_AutoVRSBootstrap> createState() => _AutoVRSBootstrapState();
}

class _AutoVRSBootstrapState extends State<_AutoVRSBootstrap> {
  bool _didConnect = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didConnect) return;
    _didConnect = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AutoVRSWebSocketService>().connectLastSource();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AutoVRSMaterialApp extends StatelessWidget {
  const _AutoVRSMaterialApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'AutoVRS - He thong kiem tra tu dong',
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: context.watch<ThemeProvider>().themeMode,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('vi', 'VN'), Locale('en', 'US')],
      locale: const Locale('vi', 'VN'),
      routerConfig: AppRoutes.router,
    );
  }
}
