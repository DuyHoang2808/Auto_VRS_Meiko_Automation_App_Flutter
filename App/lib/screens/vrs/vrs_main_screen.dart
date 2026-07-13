import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/vrs_provider.dart';
// import '../../services/autovrs_websocket_service.dart';
import '../../widgets/defect_list_widget.dart';
import '../../widgets/gerber_image_widget.dart';
import '../../widgets/stream_source_control.dart';
import '../../services/local_database_service.dart';
import '../../services/plc_gateway_service.dart';
import '../../services/autovrs_websocket_service.dart';
import '../../services/qcamber_gerber_service.dart';
import '../../services/startup_health_check.dart';

// Map technical defect names to display names (updated for new AI models)
String _getDefectDisplayName(String technicalName) {
  switch (technicalName.toLowerCase()) {
    case 'bamdinhkhongtot':
      return 'Bám Dính Không Tốt';
    case 'chamkim':
      return 'Châm Kim';
    case 'divat':
      return 'Dị vật';
    case 'divatduongmach':
      return 'Dị vật đường mạch';
    case 'khuyetmach':
      return 'Khuyết mạch';
    case 'nganmach':
      return 'Ngắn Mạch';
    case 'thieudong':
      return 'Thiếu Đồng';
    case 'thieudongduongmach':
      return 'Thiếu Đồng Đường Mạch';
    case 'thuadong':
      return 'Thừa Đồng';
    case 'thuadongduongmach':
      return 'Thừa Đồng Đường Mạch';
    case 'vetlom':
      return 'Vết Lõm';
    case 'xuoc':
      return 'Xước';
    case 'other':
      return 'Khác';
    // Legacy names for backward compatibility
    case 'short_circuit':
      return 'Chập mạch';
    case 'missing_component':
      return 'Thiếu linh kiện';
    case 'damaged_track':
      return 'Đường mạch hỏng';
    case 'solder_bridge':
      return 'Cầu hàn';
    case 'crack':
      return 'Vết nứt';
    case 'person':
      return 'Người';
    default:
      return technicalName;
  }
}

class VRSMainScreen extends StatefulWidget {
  const VRSMainScreen({super.key});

  @override
  State<VRSMainScreen> createState() => _VRSMainScreenState();
}

class _VRSMainScreenState extends State<VRSMainScreen> {
  final PlcGatewayService _plcGateway = PlcGatewayService();
  bool _running = false;
  List<Map<String, dynamic>> _defects = [];
  int _currentIndex = 0;
  // Token to force defect list widget to reload its cached future
  int _defectListReloadToken = 0;
  // Track the last persisted AI verdict so the result panel shows the most
  // recent decision even if _currentIndex advances to the next defect.
  int? _lastPersistedDefectId;
  String? _lastPersistedVerdict;
  String? _lastPersistedType;
  // Ảnh AOI capture nhận về từ response của /api/inspect-defect
  Uint8List? _lastCapturedImageBytes;

  // Gerber service for displaying PCB design images
  late QCamberGerberService _gerberService;
  final bool _isLoadingGerber = false;

  @override
  void initState() {
    super.initState();
    _gerberService = context.read<QCamberGerberService>();
  }

  @override
  void dispose() {
    // Đề phòng màn hình bị đóng giữa lúc workflow đang chạy, tránh cờ
    // "busy" bị kẹt vĩnh viễn khiến health-check không bao giờ chạy lại.
    StartupHealthCheck.setBusy(false);
    super.dispose();
  }

  /// Parse the `plc_coor` column (e.g. "19.887;5.86") into numeric (x, y).
  ({double x, double y}) _parsePlcCoords(dynamic plcCoords) {
    double x = 0;
    double y = 0;
    if (plcCoords is String) {
      final sep = plcCoords.contains(';')
          ? ';'
          : (plcCoords.contains(',') ? ',' : null);
      if (sep != null) {
        final parts = plcCoords.split(sep);
        if (parts.length >= 2) {
          x = double.tryParse(parts[0].trim()) ?? 0;
          y = double.tryParse(parts[1].trim()) ?? 0;
        }
      }
    } else if (plcCoords is Map) {
      x = (plcCoords['x'] ?? 0) is num
          ? (plcCoords['x'] as num).toDouble()
          : double.tryParse('${plcCoords['x']}') ?? 0;
      y = (plcCoords['y'] ?? 0) is num
          ? (plcCoords['y'] as num).toDouble()
          : double.tryParse('${plcCoords['y']}') ?? 0;
    }
    return (x: x, y: y);
  }

  /// Move the PLC to the current defect's coordinates, capture and run AI
  /// detection, persist the verdict, then advance to the next defect.
  ///
  /// This replaces the old CoordWsClient -> ws_coord_server.py -> PLC Gateway
  /// relay: PlcGatewayService now calls `/api/inspect-defect` directly over
  /// HTTP and gets the full move+capture+AI result back in one response, so
  /// there is no separate "process" push message to wait for anymore.
  Future<void> _inspectCurrentDefect() async {
    if (!_running) {
      debugPrint(
        'VRSMainScreen: _inspectCurrentDefect called but workflow not running',
      );
      return;
    }
    debugPrint(
      'VRSMainScreen: _inspectCurrentDefect start - defectsLoaded=${_defects.length}',
    );

    try {
      // If we already loaded defects for this run, prefer them; otherwise fetch
      List<Map<String, dynamic>> defectsForBoard = _defects;
      if (defectsForBoard.isEmpty) {
        final vrsProvider = Provider.of<VRSProvider>(context, listen: false);
        final parsedBoardId = int.tryParse(vrsProvider.currentBoard);
        if (parsedBoardId != null) {
          defectsForBoard = await LocalDatabaseService().getDefectsByBoard(
            parsedBoardId,
          );
        }
      }

      if (defectsForBoard.isEmpty) {
        debugPrint('VRSMainScreen: no defects found for board after DB fetch');
        return;
      }

      final int idx =
          (_currentIndex >= 0 && _currentIndex < defectsForBoard.length)
          ? _currentIndex
          : 0;
      final current = defectsForBoard[idx];
      final boardIdRaw = current['tbBoardid_board'] ?? current['board_id'];
      final defectIdRaw =
          current['id'] ?? current['id_defect'] ?? current['defect_id'];
      final defectId = (defectIdRaw is int)
          ? defectIdRaw
          : int.tryParse(defectIdRaw?.toString() ?? '');

      final coords = _parsePlcCoords(current['plc_coor']);
      debugPrint(
        'VRSMainScreen: inspecting defect index=$idx (of ${defectsForBoard.length}) '
        'board=$boardIdRaw defect=$defectId x=${coords.x} y=${coords.y}',
      );

      // Tải ảnh thiết kế Gerber song song với bước PLC/AI (không await) — nếu
      // QCamber treo/timeout, nó không còn làm chậm việc xử lý defect khi chạy
      // qua nhiều ảnh liên tiếp. QCamberGerberService tự bỏ qua response cũ nhờ
      // requestId guard nên ảnh hiển thị vẫn luôn khớp defect hiện tại.
      unawaited(
        _loadGerberForDefect(
          current,
          int.tryParse(boardIdRaw?.toString() ?? ''),
        ),
      );

      if (!mounted) return;

      final result = await _plcGateway.inspectDefect(
        defectX: coords.x,
        defectY: coords.y,
        boardId: boardIdRaw?.toString(),
        defectId: defectId,
      );

      if (!mounted) return;

      if (result.imageBase64 != null && result.imageBase64!.isNotEmpty) {
        try {
          final bytes = base64Decode(result.imageBase64!);
          setState(() => _lastCapturedImageBytes = bytes);
        } catch (e) {
          debugPrint('VRSMainScreen: failed to decode AOI capture image: $e');
        }
      }

      if (!result.success) {
        debugPrint(
          'VRSMainScreen: inspect-defect failed (${result.message}); stopping workflow',
        );
        setState(() {
          _running = false;
        });
        StartupHealthCheck.setBusy(false);
        return;
      }

      final hasDetections = result.hasAiResults;
      final verdict = hasDetections ? 'NG' : 'OK';
      final detectedType = hasDetections
          ? (result.aiDetections!.first['class_name']?.toString() ?? 'none')
          : 'none';

      if (defectId != null) {
        debugPrint(
          'VRSMainScreen: persisting AI result for defect id=$defectId '
          '(detectedType=$detectedType verdict=$verdict)',
        );
        try {
          await LocalDatabaseService().updateDefect(defectId, {
            'type': detectedType,
            'judgement': verdict,
            'time': DateTime.now().toIso8601String(),
          });
        } catch (e) {
          debugPrint('Failed to persist AI result: $e');
        }

        _lastPersistedDefectId = defectId;
        _lastPersistedVerdict = verdict;
        _lastPersistedType = detectedType;
      }

      // Reload defects for the board so the list widget and index stay in sync
      final vrsProviderForReload = Provider.of<VRSProvider>(
        context,
        listen: false,
      );
      final boardIdFromProvider = int.tryParse(
        vrsProviderForReload.currentBoard,
      );

      List<Map<String, dynamic>> reloaded = defectsForBoard;
      if (boardIdFromProvider != null) {
        try {
          reloaded = await LocalDatabaseService().getDefectsByBoard(
            boardIdFromProvider,
          );
        } catch (e) {
          debugPrint('Error reloading defects after persist: $e');
        }
      }

      final foundIndex = reloaded.indexWhere((d) {
        final did = d['id_defect'] ?? d['id'] ?? d['defect_id'];
        if (did == null || defectId == null) return false;
        final parsed = (did is int) ? did : int.tryParse(did.toString());
        return parsed == defectId;
      });

      int nextIndex;
      if (foundIndex != -1 && foundIndex < reloaded.length - 1) {
        nextIndex = foundIndex + 1;
      } else if (foundIndex == -1) {
        final clamped = (_currentIndex >= reloaded.length)
            ? reloaded.length - 1
            : _currentIndex;
        nextIndex = clamped < 0 ? 0 : clamped;
      } else {
        // processed last defect -> stop workflow
        nextIndex = reloaded.length;
      }

      setState(() {
        _defects = reloaded;
        _currentIndex = nextIndex;
        _defectListReloadToken++;
        if (_currentIndex >= _defects.length) {
          _running = false;
          debugPrint('VRSMainScreen: no more defects - stopping workflow');
        }
      });
      StartupHealthCheck.setBusy(_running);

      if (mounted && _running && _currentIndex < _defects.length) {
        await _inspectCurrentDefect();
      }
    } catch (e) {
      debugPrint('Error inspecting current defect: $e');
    }
  }

  /// Tải ảnh thiết kế Gerber (qua QCamber) tại tọa độ của [defect].
  Future<void> _loadGerberForDefect(
    Map<String, dynamic> defect,
    int? boardId,
  ) async {
    if (boardId == null) return;
    try {
      final db = LocalDatabaseService();
      final board = await db.getBoardById(boardId);
      if (board == null) return;
      final lot = await db.getLotById(board['tbLotid_lot']);
      if (lot == null) return;
      final model = await db.getModelById(lot['tbModelid_model']);
      if (model == null) return;

      final coordinatesStr = defect['coordinates'] as String?;
      if (coordinatesStr == null || coordinatesStr.isEmpty) return;
      final coordinates = QCamberGerberService.parseCoordinatesString(
        coordinatesStr,
      );
      if (coordinates == null) return;

      await _gerberService.captureGerberImage(
        modelName: model['name'] ?? 'Model_${model['id_model']}',
        coordinates: coordinates,
        defectType: defect['type'],
        layerName: 'l8',
        zoom: 8192.0,
      );
    } catch (e) {
      debugPrint('VRSMainScreen: error loading gerber image: $e');
    }
  }

  Future<void> _startWorkflow(int boardId) async {
    // load defects
    final list = await LocalDatabaseService().getDefectsByBoard(boardId);
    setState(() {
      _defects = list;
      _currentIndex = 0;
      _running = true;
    });
    // Báo health-check tạm dừng trong lúc workflow chạy nhiều request
    // QCamber liên tiếp, tránh chồng request health-check lên request thật.
    StartupHealthCheck.setBusy(true);

    // Inspect the first defect; this call chains through the rest via
    // _inspectCurrentDefect's own recursion, no WebSocket connection needed.
    await _inspectCurrentDefect();
  }

  Future<void> _stopWorkflow() async {
    StartupHealthCheck.setBusy(false);
    setState(() {
      _running = false;
    });
    debugPrint('VRSMainScreen: stopped workflow');
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isSmallScreen = screenWidth < 1200;
        final padding = isSmallScreen ? 16.0 : 24.0;

        // read providers early in the builder so UI below can use dynamic values
        final vrsProvider = Provider.of<VRSProvider>(context);
        final webSocketService = Provider.of<AutoVRSWebSocketService>(
          context,
          listen: false,
        );

        // compute display values
        final lotText =
            (vrsProvider.currentLot.isNotEmpty &&
                vrsProvider.currentLot != 'Chưa có')
            ? vrsProvider.currentLot
            : 'Chưa có';
        final boardText =
            (vrsProvider.currentBoard.isNotEmpty &&
                vrsProvider.currentBoard != 'Chưa có')
            ? vrsProvider.currentBoard
            : 'Chưa có';

        String aiText = 'Không phát hiện lỗi';
        final analysis = webSocketService.lastAnalysis;
        final detectionResults = webSocketService.lastDetectionResults;

        // DEBUG: Log raw data
        debugPrint('🔍 VRSMain aiText calculation:');
        debugPrint(
          '  detectionResults: ${detectionResults != null ? 'EXISTS' : 'NULL'}',
        );
        debugPrint('  analysis: ${analysis != null ? 'EXISTS' : 'NULL'}');

        // Ưu tiên lấy từ lastDetectionResults vì có class_name_vi
        if (detectionResults != null && detectionResults.isNotEmpty) {
          // lastDetectionResults là Map, cần lấy 'detections' array bên trong
          final detections = detectionResults['detections'];
          debugPrint(
            '  detectionResults[detections]: ${detections != null ? 'List of ${(detections as List?)?.length}' : 'NULL'}',
          );
          if (detections != null &&
              detections is List &&
              detections.isNotEmpty) {
            // Chỉ lấy lỗi có confidence cao nhất
            var highestConfDetection = detections[0];
            double highestConf = (highestConfDetection['confidence'] ?? 0.0)
                .toDouble();

            for (final d in detections) {
              final conf = (d['confidence'] ?? 0.0).toDouble();
              if (conf > highestConf) {
                highestConf = conf;
                highestConfDetection = d;
              }
            }

            final nameVi =
                highestConfDetection['class_name_vi'] ??
                highestConfDetection['className'] ??
                'Unknown';
            aiText = '$nameVi (${(highestConf * 100).toStringAsFixed(1)}%)';
            debugPrint(
              '  ✅ aiText from detectionResults (highest conf): $aiText',
            );
          }
        } else if (analysis != null) {
          // Fallback: dùng analysis nhưng lấy từ detections nếu có
          final detections = analysis['detections'];
          debugPrint(
            '  analysis[detections]: ${detections != null ? 'List of ${(detections as List?)?.length}' : 'NULL'}',
          );
          if (detections != null &&
              detections is List &&
              detections.isNotEmpty) {
            // Chỉ lấy lỗi có confidence cao nhất từ analysis
            var highestConfDetection = detections[0];
            double highestConf = (highestConfDetection['confidence'] ?? 0.0)
                .toDouble();

            for (final d in detections) {
              final conf = (d['confidence'] ?? 0.0).toDouble();
              if (conf > highestConf) {
                highestConf = conf;
                highestConfDetection = d;
              }
            }

            final nameVi =
                highestConfDetection['class_name_vi'] ??
                highestConfDetection['class_name'] ??
                'Unknown';
            final displayName = _getDefectDisplayName(nameVi.toString());
            aiText =
                '$displayName (${(highestConf * 100).toStringAsFixed(1)}%)';
            debugPrint('  ✅ aiText from analysis (highest conf): $aiText');
          } else if ((analysis['total_defects'] ?? 0) > 0) {
            aiText = 'Có lỗi';
            debugPrint('  ⚠️ aiText fallback: $aiText');
          }
        }
        debugPrint('  FINAL aiText: $aiText');

        return Padding(
          padding: EdgeInsets.all(padding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Image Display Panel
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    // Main VRS Image - Left side
                    Expanded(
                      flex: 2, // Increased from 1 to 2 for wider camera view
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Ảnh Live từ VRS',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const StreamSourceControl(),
                              const SizedBox(height: 12),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    // Calculate square size based on available space
                                    final availableWidth = constraints.maxWidth;
                                    final availableHeight =
                                        constraints.maxHeight;
                                    final squareSize =
                                        availableWidth < availableHeight
                                        ? availableWidth
                                        : availableHeight;

                                    return Center(
                                      child: SizedBox(
                                        width: squareSize,
                                        height: squareSize,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.black,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: ValueListenableBuilder<Uint8List?>(
                                            valueListenable:
                                                Provider.of<
                                                      AutoVRSWebSocketService
                                                    >(context, listen: false)
                                                    .currentFrameNotifier,
                                            builder: (context, frameData, child) {
                                              final webSocketService =
                                                  Provider.of<
                                                    AutoVRSWebSocketService
                                                  >(context, listen: false);

                                              if (webSocketService
                                                      .displayImage !=
                                                  null) {
                                                // Backend đã vẽ bounding boxes vào ảnh rồi, chỉ cần hiển thị
                                                return ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: Image.memory(
                                                    webSocketService
                                                        .displayImage!,
                                                    fit: BoxFit.cover,
                                                    width: squareSize,
                                                    height: squareSize,
                                                    gaplessPlayback:
                                                        true, // Optimize for smooth video playback
                                                  ),
                                                );
                                              } else if (frameData != null) {
                                                return ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: Image.memory(
                                                    frameData,
                                                    fit: BoxFit.cover,
                                                    width: squareSize,
                                                    height: squareSize,
                                                    gaplessPlayback:
                                                        true, // Optimize for smooth video playback
                                                  ),
                                                );
                                              } else if (webSocketService
                                                  .isConnected) {
                                                return const Center(
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      CircularProgressIndicator(
                                                        color: Colors.white,
                                                      ),
                                                      SizedBox(height: 8),
                                                      Text(
                                                        'Đang khởi tạo camera...',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              } else {
                                                return const Center(
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Icon(
                                                        Icons.wifi_off,
                                                        color: Colors.red,
                                                        size: 48,
                                                      ),
                                                      SizedBox(height: 8),
                                                      Text(
                                                        'AutoVRS Disconnected',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 16),

                    // Comparison Images - Right side (stacked)
                    Expanded(
                      flex: 1,
                      child: Column(
                        children: [
                          // Gerber View
                          Expanded(
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Ảnh từ Thiết kế Gerber',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: GerberImageWidget(
                                        isLoading: _isLoadingGerber,
                                        errorMessage: _gerberService.lastError,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // AOI Capture
                          Expanded(
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Ảnh từ PCI AOI',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final availableWidth =
                                              constraints.maxWidth;
                                          final availableHeight =
                                              constraints.maxHeight;
                                          final squareSize =
                                              availableWidth < availableHeight
                                              ? availableWidth
                                              : availableHeight;

                                          return Center(
                                            child: SizedBox(
                                              width: squareSize,
                                              height: squareSize,
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: Colors.grey.shade200,
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  child:
                                                      _lastCapturedImageBytes !=
                                                          null
                                                      ? Image.memory(
                                                          _lastCapturedImageBytes!,
                                                          fit: BoxFit.contain,
                                                          errorBuilder:
                                                              (
                                                                context,
                                                                error,
                                                                stackTrace,
                                                              ) => const Center(
                                                                child: Text(
                                                                  'Không thể hiển thị ảnh',
                                                                  style: TextStyle(
                                                                    color: Colors
                                                                        .black,
                                                                    fontSize:
                                                                        12,
                                                                  ),
                                                                ),
                                                              ),
                                                        )
                                                      : const Center(
                                                          child: Text(
                                                            'AOI Capture',
                                                            style: TextStyle(
                                                              color: Colors
                                                                  .black,
                                                              fontSize: 12,
                                                            ),
                                                          ),
                                                        ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 24),

              // Info & Action Panel
              SizedBox(
                width: isSmallScreen ? 280 : 320,
                child: Card(
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: Colors.grey.shade300, width: 1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Giám sát VRS Auto',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),

                          const Divider(height: 24),

                          // Info rows (dynamic from providers)
                          _buildInfoRow('Mã Lô (id_lot):', lotText),
                          const SizedBox(height: 12),
                          _buildInfoRow('Số thứ tự bo:', boardText),
                          const SizedBox(height: 12),
                          _buildInfoRow('Loại lỗi AI dự đoán:', aiText),
                          const SizedBox(height: 12),
                          // Total defects for current board
                          FutureBuilder<List<Map<String, dynamic>>>(
                            future: (int.tryParse(boardText) != null)
                                ? LocalDatabaseService().getDefectsByBoard(
                                    int.parse(boardText),
                                  )
                                : Future.value([]),
                            builder: (context, snap) {
                              final total = snap.hasData
                                  ? snap.data!.length
                                  : 0;
                              return _buildInfoRow(
                                'Số lỗi trên bo:',
                                total.toString(),
                              );
                            },
                          ),

                          const SizedBox(height: 24),

                          // AI Result
                          const Text(
                            'Kết quả phán định AI',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 12),

                          // Dynamic AI Result Panel - shows OK (green) or NG (red)
                          Builder(
                            builder: (context) {
                              String verdictShort = 'OK';
                              Color bgColor = Colors.green.shade50;
                              Color txtColor = Colors.green.shade600;
                              String detailText = aiText;

                              // Prefer the last persisted verdict/type when available.
                              // This ensures the result card shows the most recent
                              // persisted AI decision even if _currentIndex has moved on.
                              if (_lastPersistedVerdict != null) {
                                verdictShort = _lastPersistedVerdict!
                                    .toUpperCase();
                                if (verdictShort == 'OK') {
                                  bgColor = Colors.green.shade50;
                                  txtColor = Colors.green.shade600;
                                  detailText = 'Không phát hiện lỗi';
                                } else {
                                  bgColor = Colors.red.shade50;
                                  txtColor = Colors.red.shade600;
                                  if (_lastPersistedType != null &&
                                      _lastPersistedType!.isNotEmpty) {
                                    detailText = _getDefectDisplayName(
                                      _lastPersistedType!,
                                    );
                                  } else {
                                    detailText = aiText;
                                  }
                                }
                              } else if (_defects.isNotEmpty &&
                                  _currentIndex < _defects.length) {
                                final cur = _defects[_currentIndex];
                                final j = cur['judgement']
                                    ?.toString()
                                    .toUpperCase();
                                if (j != null && j.isNotEmpty) {
                                  verdictShort = j;
                                  if (verdictShort == 'OK') {
                                    bgColor = Colors.green.shade50;
                                    txtColor = Colors.green.shade600;
                                    detailText = 'Không phát hiện lỗi';
                                  } else {
                                    bgColor = Colors.red.shade50;
                                    txtColor = Colors.red.shade600;
                                    // show detected type if available
                                    detailText =
                                        (cur['type'] != null &&
                                            cur['type'].toString().isNotEmpty)
                                        ? _getDefectDisplayName(
                                            cur['type'].toString(),
                                          )
                                        : aiText;
                                  }
                                } else {
                                  // no persisted judgement yet - fallback to lastAnalysis
                                  if (analysis != null) {
                                    final hasDefects =
                                        (analysis['total_defects'] ?? 0) > 0 ||
                                        (analysis['defects_by_type'] is Map &&
                                            (analysis['defects_by_type'] as Map)
                                                .keys
                                                .isNotEmpty);
                                    if (hasDefects) {
                                      verdictShort = 'NG';
                                      bgColor = Colors.red.shade50;
                                      txtColor = Colors.red.shade600;
                                    } else {
                                      verdictShort = 'OK';
                                      bgColor = Colors.green.shade50;
                                      txtColor = Colors.green.shade600;
                                    }
                                  }
                                }
                              } else {
                                // no defect in memory - use analysis
                                if (analysis != null) {
                                  final hasDefects =
                                      (analysis['total_defects'] ?? 0) > 0 ||
                                      (analysis['defects_by_type'] is Map &&
                                          (analysis['defects_by_type'] as Map)
                                              .keys
                                              .isNotEmpty);
                                  if (hasDefects) {
                                    verdictShort = 'NG';
                                    bgColor = Colors.red.shade50;
                                    txtColor = Colors.red.shade600;
                                  } else {
                                    verdictShort = 'OK';
                                    bgColor = Colors.green.shade50;
                                    txtColor = Colors.green.shade600;
                                  }
                                }
                              }

                              return Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: bgColor,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      verdictShort,
                                      style: TextStyle(
                                        fontSize: 32,
                                        fontWeight: FontWeight.bold,
                                        color: txtColor,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      detailText,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: txtColor.withOpacity(0.9),
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),

                          const SizedBox(height: 16),

                          // Defect list for currently selected board
                          DefectListWidget(
                            boardId: int.tryParse(boardText),
                            height: 200,
                            reloadToken: _defectListReloadToken,
                          ),

                          const SizedBox(height: 16),

                          // Start / Stop operator-driven workflow
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed:
                                      (boardText != 'Chưa có' && !_running)
                                      ? () {
                                          final bId = int.tryParse(boardText);
                                          if (bId != null) _startWorkflow(bId);
                                        }
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                  ),
                                  child: const Text('Bắt đầu'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _running ? _stopWorkflow : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                  ),
                                  child: const Text('Dừng'),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // Statistics Button
                          Consumer<AuthProvider>(
                            builder: (context, authProvider, _) {
                              return SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: authProvider.isAdminAuthenticated
                                      ? () => context.push('/statistics')
                                      : null,
                                  icon: const Icon(FeatherIcons.barChart),
                                  label: const Text('Xem thống kê'),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),

                          const SizedBox(height: 16),

                          // // Manual review button
                          // SizedBox(
                          //   width: double.infinity,
                          //   child: ElevatedButton.icon(
                          //     onPressed: () {
                          //       Navigator.of(context).push(
                          //         MaterialPageRoute(
                          //           builder: (context) => ManualVRSScreen(),
                          //         ),
                          //       );
                          //     },
                          //     icon: const Icon(FeatherIcons.edit3),
                          //     label: const Text('Phán định thủ công'),
                          //     style: ElevatedButton.styleFrom(
                          //       backgroundColor: Colors.orange,
                          //       foregroundColor: Colors.white,
                          //       padding: const EdgeInsets.symmetric(vertical: 12),
                          //     ),
                          //   ),
                          // ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
