import 'package:flutter/material.dart';
import 'package:autovrs_app/core/feather_icons.dart';
import 'package:provider/provider.dart';

import '../services/autovrs_websocket_service.dart';
import 'runtime_endpoint_config_dialog.dart';

class StreamSourceControl extends StatelessWidget {
  const StreamSourceControl({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AutoVRSWebSocketService>(
      builder: (context, service, child) {
        final isRtsp = service.streamSource == AutoVRSStreamSource.rtsp;
        final sourceLabel = isRtsp ? 'RTSP' : 'WebSocket';
        final color = service.isConnected ? Colors.green : Colors.red;

        return Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: color.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    service.isConnected
                        ? FeatherIcons.video
                        : FeatherIcons.videoOff,
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$sourceLabel ${service.isConnected ? "Connected" : "Disconnected"}',
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: () {
                final navigatorContext = Navigator.of(
                  context,
                  rootNavigator: true,
                ).context;
                _showSourceDialog(navigatorContext, service);
              },
              icon: const Icon(FeatherIcons.settings, size: 16),
              label: const Text('Nguon video'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
            ),
            const RuntimeEndpointConfigButton(),
          ],
        );
      },
    );
  }

  Future<void> _showSourceDialog(
    BuildContext context,
    AutoVRSWebSocketService service,
  ) async {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => _StreamSourceDialog(service: service),
    );
  }
}

class _StreamSourceDialog extends StatefulWidget {
  final AutoVRSWebSocketService service;

  const _StreamSourceDialog({required this.service});

  @override
  State<_StreamSourceDialog> createState() => _StreamSourceDialogState();
}

class _StreamSourceDialogState extends State<_StreamSourceDialog> {
  late final TextEditingController _wsController;
  late final TextEditingController _rtspController;
  late final TextEditingController _ffmpegController;
  late final TextEditingController _fpsController;
  late AutoVRSStreamSource _selectedSource;
  bool _isConnecting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final service = widget.service;
    _wsController = TextEditingController(text: service.serverUrl);
    _rtspController = TextEditingController(text: service.rtspUrl);
    _ffmpegController = TextEditingController(text: service.ffmpegPath);
    _fpsController = TextEditingController(text: service.rtspFps.toString());
    _selectedSource = service.streamSource;
  }

  @override
  void dispose() {
    _wsController.dispose();
    _rtspController.dispose();
    _ffmpegController.dispose();
    _fpsController.dispose();
    super.dispose();
  }

  Future<void> _connectSelected() async {
    if (_isConnecting) return;

    final navigator = Navigator.of(context);
    setState(() {
      _isConnecting = true;
      _errorText = null;
    });

    final service = widget.service;
    final fps = int.tryParse(_fpsController.text.trim()) ?? 15;
    final ok = _selectedSource == AutoVRSStreamSource.rtsp
        ? await service.connectRtsp(
            rtspUrl: _rtspController.text.trim(),
            ffmpegPath: _ffmpegController.text.trim(),
            fps: fps,
          )
        : await service.connect(serverUrl: _wsController.text.trim());

    if (!mounted) return;

    if (ok) {
      navigator.pop();
      return;
    }

    setState(() {
      _isConnecting = false;
      _errorText = service.lastError ?? 'Khong ket noi duoc nguon video';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cau hinh nguon video'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<AutoVRSStreamSource>(
                  segments: const [
                    ButtonSegment(
                      value: AutoVRSStreamSource.websocket,
                      label: Text('WebSocket'),
                      icon: Icon(FeatherIcons.radio),
                    ),
                    ButtonSegment(
                      value: AutoVRSStreamSource.rtsp,
                      label: Text('RTSP'),
                      icon: Icon(FeatherIcons.video),
                    ),
                  ],
                  selected: {_selectedSource},
                  onSelectionChanged: _isConnecting
                      ? null
                      : (value) =>
                            setState(() => _selectedSource = value.first),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _wsController,
                enabled:
                    !_isConnecting &&
                    _selectedSource == AutoVRSStreamSource.websocket,
                decoration: const InputDecoration(
                  labelText: 'WebSocket URL',
                  hintText: 'ws://127.0.0.1:8999',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _rtspController,
                enabled:
                    !_isConnecting &&
                    _selectedSource == AutoVRSStreamSource.rtsp,
                decoration: const InputDecoration(
                  labelText: 'RTSP URL',
                  hintText: 'rtsp://user:pass@192.168.1.10/stream1',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _ffmpegController,
                      enabled:
                          !_isConnecting &&
                          _selectedSource == AutoVRSStreamSource.rtsp,
                      decoration: const InputDecoration(
                        labelText: 'ffmpeg path',
                        hintText: 'ffmpeg',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _fpsController,
                      enabled:
                          !_isConnecting &&
                          _selectedSource == AutoVRSStreamSource.rtsp,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'FPS'),
                    ),
                  ),
                ],
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _errorText!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isConnecting ? null : () => Navigator.of(context).pop(),
          child: const Text('Huy'),
        ),
        FilledButton.icon(
          onPressed: _isConnecting ? null : _connectSelected,
          icon: _isConnecting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(FeatherIcons.link, size: 16),
          label: Text(_isConnecting ? 'Dang ket noi...' : 'Ket noi'),
        ),
      ],
    );
  }
}
