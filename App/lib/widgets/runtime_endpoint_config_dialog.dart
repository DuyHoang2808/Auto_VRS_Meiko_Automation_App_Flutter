import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/feather_icons.dart';
import '../core/app_runtime_config.dart';
import '../services/autovrs_websocket_service.dart';

class RuntimeEndpointConfigButton extends StatelessWidget {
  const RuntimeEndpointConfigButton({super.key});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () {
        showDialog<void>(
          context: context,
          useRootNavigator: true,
          builder: (dialogContext) => const _RuntimeEndpointConfigDialog(),
        );
      },
      icon: const Icon(FeatherIcons.settings, size: 16),
      label: const Text('Cau hinh server'),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    );
  }
}

class _RuntimeEndpointConfigDialog extends StatefulWidget {
  const _RuntimeEndpointConfigDialog();

  @override
  State<_RuntimeEndpointConfigDialog> createState() =>
      _RuntimeEndpointConfigDialogState();
}

class _RuntimeEndpointConfigDialogState
    extends State<_RuntimeEndpointConfigDialog> {
  final _controllers = <String, TextEditingController>{};
  bool _isSaving = false;
  String? _errorText;

  static const _configFields = <_ConfigField>[
    _ConfigField(AppRuntimeConfig.autoVrsWsUrlKey, 'AutoVRS WebSocket'),
    _ConfigField(AppRuntimeConfig.autoVrsRtspUrlKey, 'AutoVRS RTSP'),
    _ConfigField(AppRuntimeConfig.coordWsUrlKey, 'Coordinator WebSocket'),
    _ConfigField(AppRuntimeConfig.aiBaseUrlKey, 'AI Base URL'),
    _ConfigField(AppRuntimeConfig.plcGatewayBaseUrlKey, 'PLC Gateway Base URL'),
    _ConfigField(AppRuntimeConfig.qcamberBaseUrlKey, 'QCamber Base URL'),
    _ConfigField(AppRuntimeConfig.videoFrameWsUrlKey, 'Video Frame WebSocket'),
    _ConfigField(AppRuntimeConfig.cameraWsUrlKey, 'Camera Backend WebSocket'),
    _ConfigField(AppRuntimeConfig.apiBaseUrlKey, 'App API Base URL'),
    _ConfigField(AppRuntimeConfig.ffmpegPathKey, 'ffmpeg path'),
    _ConfigField(AppRuntimeConfig.rtspFpsKey, 'RTSP FPS'),
  ];

  @override
  void initState() {
    super.initState();
    final config = AppRuntimeConfig.instance;
    for (final field in _configFields) {
      _controllers[field.key] = TextEditingController(
        text: config.getString(field.key),
      );
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save({required bool reconnectVideo}) async {
    if (_isSaving) return;

    setState(() {
      _isSaving = true;
      _errorText = null;
    });

    final config = AppRuntimeConfig.instance;
    final values = <String, String>{
      for (final field in _configFields)
        field.key: _controllers[field.key]!.text.trim(),
    };

    try {
      final videoService = reconnectVideo
          ? context.read<AutoVRSWebSocketService>()
          : null;
      final validationError = _validateValues(values);
      if (validationError != null) {
        if (!mounted) return;
        setState(() {
          _isSaving = false;
          _errorText = validationError;
        });
        return;
      }

      await config.updateValues(values);

      if (reconnectVideo && videoService != null) {
        final fps = int.tryParse(values[AppRuntimeConfig.rtspFpsKey] ?? '');
        final bool reconnectOk;
        if (videoService.streamSource == AutoVRSStreamSource.rtsp) {
          reconnectOk = await videoService.connectRtsp(
            rtspUrl: values[AppRuntimeConfig.autoVrsRtspUrlKey],
            ffmpegPath: values[AppRuntimeConfig.ffmpegPathKey],
            fps: fps,
          );
        } else {
          reconnectOk = await videoService.connect(
            serverUrl: values[AppRuntimeConfig.autoVrsWsUrlKey],
          );
        }

        if (!reconnectOk) {
          if (!mounted) return;
          setState(() {
            _isSaving = false;
            _errorText =
                videoService.lastError ??
                'Reconnect video that bai. Kiem tra lai endpoint.';
          });
          return;
        }
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorText = 'Khong luu duoc cau hinh: $e';
      });
    }
  }

  String? _validateValues(Map<String, String> values) {
    final requiredFields = <String>[
      AppRuntimeConfig.autoVrsWsUrlKey,
      AppRuntimeConfig.autoVrsRtspUrlKey,
      AppRuntimeConfig.coordWsUrlKey,
      AppRuntimeConfig.aiBaseUrlKey,
      AppRuntimeConfig.plcGatewayBaseUrlKey,
      AppRuntimeConfig.qcamberBaseUrlKey,
      AppRuntimeConfig.videoFrameWsUrlKey,
      AppRuntimeConfig.cameraWsUrlKey,
      AppRuntimeConfig.apiBaseUrlKey,
      AppRuntimeConfig.ffmpegPathKey,
    ];

    for (final key in requiredFields) {
      if ((values[key] ?? '').trim().isEmpty) {
        return 'Khong duoc de trong ${_labelForKey(key)}.';
      }
    }

    final fps = int.tryParse(values[AppRuntimeConfig.rtspFpsKey] ?? '');
    if (fps == null || fps < 1 || fps > 60) {
      return 'RTSP FPS phai nam trong khoang 1 den 60.';
    }

    final uriChecks = <String, List<String>>{
      AppRuntimeConfig.autoVrsWsUrlKey: ['ws', 'wss'],
      AppRuntimeConfig.coordWsUrlKey: ['ws', 'wss'],
      AppRuntimeConfig.videoFrameWsUrlKey: ['ws', 'wss'],
      AppRuntimeConfig.cameraWsUrlKey: ['ws', 'wss'],
      AppRuntimeConfig.autoVrsRtspUrlKey: ['rtsp'],
      AppRuntimeConfig.aiBaseUrlKey: ['http', 'https'],
      AppRuntimeConfig.plcGatewayBaseUrlKey: ['http', 'https'],
      AppRuntimeConfig.qcamberBaseUrlKey: ['http', 'https'],
      AppRuntimeConfig.apiBaseUrlKey: ['http', 'https'],
    };

    for (final entry in uriChecks.entries) {
      final value = values[entry.key] ?? '';
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.scheme.isEmpty ||
          !entry.value.contains(uri.scheme.toLowerCase())) {
        return '${_labelForKey(entry.key)} khong dung dinh dang.';
      }
    }

    return null;
  }

  String _labelForKey(String key) {
    for (final field in _configFields) {
      if (field.key == key) return field.label;
    }
    return key;
  }

  Future<void> _resetOverrides() async {
    if (_isSaving) return;

    setState(() {
      _isSaving = true;
      _errorText = null;
    });

    try {
      await AppRuntimeConfig.instance.clearOverrides(
        _configFields.map((field) => field.key),
      );
      await AppRuntimeConfig.instance.reload();

      for (final field in _configFields) {
        _controllers[field.key]!.text =
            AppRuntimeConfig.instance.getString(field.key);
      }

      if (!mounted) return;
      setState(() {
        _isSaving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorText = 'Khong reset duoc override: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loadedFilePath =
        AppRuntimeConfig.instance.loadedFilePath ?? 'Khong xac dinh';

    return AlertDialog(
      title: const Text('Cau hinh endpoint'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'File config mac dinh: $loadedFilePath',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              for (final field in _configFields) ...[
                TextField(
                  controller: _controllers[field.key],
                  enabled: !_isSaving,
                  keyboardType: field.key == AppRuntimeConfig.rtspFpsKey
                      ? TextInputType.number
                      : TextInputType.url,
                  decoration: InputDecoration(labelText: field.label),
                ),
                const SizedBox(height: 12),
              ],
              if (_errorText != null)
                Text(
                  _errorText!,
                  style: const TextStyle(color: Colors.red),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : _resetOverrides,
          child: const Text('Reset mac dinh'),
        ),
        TextButton(
          onPressed: _isSaving
              ? null
              : () => Navigator.of(context, rootNavigator: true).pop(),
          child: const Text('Huy'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : () => _save(reconnectVideo: false),
          child: Text(_isSaving ? 'Dang luu...' : 'Luu'),
        ),
        FilledButton.icon(
          onPressed: _isSaving ? null : () => _save(reconnectVideo: true),
          icon: const Icon(FeatherIcons.refreshCw, size: 16),
          label: const Text('Luu va reconnect video'),
        ),
      ],
    );
  }
}

class _ConfigField {
  final String key;
  final String label;

  const _ConfigField(this.key, this.label);
}
