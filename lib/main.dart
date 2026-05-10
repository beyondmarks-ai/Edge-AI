import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

void main() {
  runApp(const EdgeApp());
}

class EdgeApp extends StatelessWidget {
  const EdgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF16833B);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Edge',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: green,
          primary: green,
          surface: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF4FBF6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD8EBDD)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD8EBDD)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: green, width: 1.6),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: green,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      initialRoute: SignInScreen.routeName,
      routes: {
        AiPreparationScreen.routeName: (_) => const AiPreparationScreen(),
        SignInScreen.routeName: (_) => const SignInScreen(),
        SignUpScreen.routeName: (_) => const SignUpScreen(),
        DashboardScreen.routeName: (_) => const DashboardScreen(),
        AttendenceScreen.routeName: (_) => const AttendenceScreen(),
        RagScreen.routeName: (_) => const RagScreen(),
        SettingScreen.routeName: (_) => const SettingScreen(),
      },
    );
  }
}

class AiPreparationScreen extends StatefulWidget {
  const AiPreparationScreen({super.key});

  static const routeName = '/prepare-ai';

  @override
  State<AiPreparationScreen> createState() => _AiPreparationScreenState();
}

class ModelDownloadCoordinator {
  ModelDownloadCoordinator({this.onChanged});

  static const channel = MethodChannel('edge/model_downloader');
  static const modelUrl =
      'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf';
  static const modelFileName = 'qwen2.5-1.5b-instruct-q4_k_m.gguf';
  static const minimumReadyBytes = 1000 * 1024 * 1024;

  final VoidCallback? onChanged;
  Timer? _pollTimer;

  double progress = 0;
  String statusText = 'Offline AI model is not ready.';
  String progressLabel = 'Tap prepare to download the Qwen model.';
  String? errorText;
  bool isBusy = false;
  bool isReady = false;
  String modelPath = '';
  int fileSize = 0;
  int downloadedBytes = 0;
  int totalBytes = 0;
  int availableMemoryBytes = 0;
  int totalMemoryBytes = 0;
  String nativeStatus = 'idle';
  int nativeReason = 0;
  bool isEmulator = false;
  String supportedAbis = '';

  Future<void> refresh() async {
    final status = await modelStatus();
    _applyStatus(status);
  }

  Future<void> startDownload() async {
    isBusy = true;
    errorText = null;
    statusText = 'Downloading Qwen offline model...';
    progressLabel = 'Starting download...';
    onChanged?.call();

    try {
      await channel.invokeMethod('startModelDownload', {
        'url': modelUrl,
        'fileName': modelFileName,
      });
      _startPolling();
      await pollDownload();
    } on PlatformException catch (error) {
      _fail(error.message ?? error.code);
    }
  }

  Future<void> resetDownload() async {
    _pollTimer?.cancel();
    await channel.invokeMethod('resetModelDownload', {
      'fileName': modelFileName,
    });
    isBusy = false;
    isReady = false;
    progress = 0;
    errorText = null;
    await refresh();
  }

  Future<void> pollDownload() async {
    final status = await modelStatus();
    _applyStatus(status);

    if (isReady) {
      _pollTimer?.cancel();
      isBusy = false;
      isReady = true;
      progress = 1;
      statusText = 'Offline AI ready';
      progressLabel = 'Qwen model is downloaded and ready for Rag.';
      onChanged?.call();
      return;
    }

    if (status['status'] == 'failed') {
      _pollTimer?.cancel();
      _fail('Model download failed. Reason: ${status['reason']}');
    }
  }

  Future<Map<String, dynamic>> modelStatus() async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'modelStatus',
      {'fileName': modelFileName, 'expectedBytes': minimumReadyBytes},
    );

    return result ?? <String, dynamic>{};
  }

  void dispose() {
    _pollTimer?.cancel();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(pollDownload()),
    );
  }

  void _applyStatus(Map<String, dynamic> status) {
    final downloaded = _asDouble(status['downloadedBytes']);
    final total = _asDouble(status['totalBytes']);
    modelPath = status['path']?.toString() ?? '';
    fileSize = _asInt(status['fileSize']);
    downloadedBytes = _asInt(status['downloadedBytes']);
    totalBytes = _asInt(status['totalBytes']);
    availableMemoryBytes = _asInt(status['availableMemoryBytes']);
    totalMemoryBytes = _asInt(status['totalMemoryBytes']);
    nativeStatus = status['status']?.toString() ?? 'idle';
    nativeReason = _asInt(status['reason']);
    isEmulator = status['isEmulator'] == true;
    supportedAbis = _asStringList(status['supportedAbis']).join(', ');
    isReady = status['exists'] == true && downloaded >= minimumReadyBytes;
    progress = isReady
        ? 1
        : total > 0
        ? (downloaded / total).clamp(0.0, 0.98).toDouble()
        : 0;

    if (isReady) {
      isBusy = false;
      statusText = 'Offline AI ready';
      progressLabel = 'Qwen model is downloaded and ready for Rag.';
    } else {
      final currentStatus = status['status']?.toString() ?? 'idle';
      isBusy = currentStatus == 'running' || currentStatus == 'pending';
      statusText = isBusy
          ? 'Preparing offline AI model...'
          : 'Offline AI model is not ready.';
      progressLabel = isBusy
          ? 'Downloaded ${(progress * 100).round()}%'
          : 'Tap prepare to download the Qwen model.';
    }

    onChanged?.call();
  }

  void _fail(String message) {
    isBusy = false;
    errorText = message;
    statusText = 'Offline model is not ready.';
    progressLabel = 'Download could not finish.';
    onChanged?.call();
  }

  double _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }

    return 0;
  }

  int _asInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }

    return 0;
  }

  List<String> _asStringList(Object? value) {
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }

    return const [];
  }
}

class _AiPreparationScreenState extends State<AiPreparationScreen>
    with SingleTickerProviderStateMixin {
  static const _channel = MethodChannel('edge/model_downloader');
  static const _modelUrl =
      'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf';
  static const _modelFileName = 'qwen2.5-1.5b-instruct-q4_k_m.gguf';
  static const _minimumReadyBytes = 1000 * 1024 * 1024;

  late final AnimationController _animationController;
  Timer? _pollTimer;
  double _progress = 0;
  String _statusText = 'Checking offline AI model...';
  String? _errorText;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      lowerBound: 0.88,
      upperBound: 1.08,
    )..repeat(reverse: true);
    unawaited(_prepareModel());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _prepareModel() async {
    setState(() {
      _errorText = null;
      _statusText = 'Checking offline AI model...';
    });

    final status = await _modelStatus();
    if (_isModelReady(status)) {
      _openSignIn();
      return;
    }

    await _startDownload();
  }

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _statusText = 'Downloading Qwen offline model...';
      _errorText = null;
    });

    try {
      await _channel.invokeMethod('startModelDownload', {
        'url': _modelUrl,
        'fileName': _modelFileName,
      });
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_pollDownload()),
      );
      await _pollDownload();
    } on PlatformException catch (error) {
      _showDownloadError(error.message ?? error.code);
    }
  }

  Future<void> _pollDownload() async {
    final status = await _modelStatus();

    if (_isModelReady(status)) {
      _pollTimer?.cancel();
      _openSignIn();
      return;
    }

    final downloaded = _asDouble(status['downloadedBytes']);
    final total = _asDouble(status['totalBytes']);
    final progress = total > 0
        ? (downloaded / total).clamp(0.0, 0.98).toDouble()
        : 0.0;
    final currentStatus = status['status']?.toString() ?? 'running';

    setState(() {
      _progress = progress;
      _statusText = currentStatus == 'pending'
          ? 'Waiting to start model download...'
          : 'Preparing offline AI model... ${(_progress * 100).round()}%';
    });

    if (currentStatus == 'failed') {
      _pollTimer?.cancel();
      _showDownloadError('Model download failed. Reason: ${status['reason']}');
    }
  }

  Future<Map<String, dynamic>> _modelStatus() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'modelStatus',
      {'fileName': _modelFileName, 'expectedBytes': _minimumReadyBytes},
    );

    return result ?? <String, dynamic>{};
  }

  bool _isModelReady(Map<String, dynamic> status) {
    return status['exists'] == true &&
        _asDouble(status['downloadedBytes']) >= _minimumReadyBytes;
  }

  double _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }

    return 0;
  }

  void _showDownloadError(String message) {
    setState(() {
      _isDownloading = false;
      _errorText = message;
      _statusText = 'Offline model is not ready.';
    });
  }

  void _openSignIn() {
    if (!mounted) {
      return;
    }

    Navigator.pushReplacementNamed(context, SignInScreen.routeName);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScaleTransition(
                scale: _animationController,
                child: Container(
                  width: 96,
                  height: 96,
                  margin: const EdgeInsets.only(bottom: 28),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE7F6EB),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFD8EBDD)),
                  ),
                  child: Icon(
                    Icons.psychology_alt_rounded,
                    color: primary,
                    size: 50,
                  ),
                ),
              ),
              const Text(
                'Preparing offline AI',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF123D22),
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Please wait while Edge prepares Qwen for offline RAG.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF5D7465), height: 1.4),
              ),
              const SizedBox(height: 30),
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 9,
                borderRadius: BorderRadius.circular(12),
                backgroundColor: const Color(0xFFE7F6EB),
              ),
              const SizedBox(height: 14),
              Text(
                _statusText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF123D22),
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_isDownloading && _errorText == null) ...[
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: _openSignIn,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Use app while downloading'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'You can minimize the app. Android will keep downloading the model.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF5D7465), fontSize: 12),
                ),
              ],
              if (_errorText != null) ...[
                const SizedBox(height: 16),
                Text(
                  _errorText!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFB3261E)),
                ),
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  onPressed: _isDownloading ? null : _prepareModel,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
                TextButton(
                  onPressed: _openSignIn,
                  child: const Text('Continue with backend mode'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});

  static const routeName = '/';

  @override
  Widget build(BuildContext context) {
    return AuthFrame(
      title: 'Welcome back',
      subtitle: 'Sign in to continue to your dashboard.',
      actionText: 'Sign In',
      footerText: 'Do not have an account?',
      footerActionText: 'Sign Up',
      fields: const [
        AuthTextField(
          label: 'Email',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
        ),
        AuthTextField(
          label: 'Password',
          icon: Icons.lock_outline,
          obscureText: true,
        ),
      ],
      onAction: () => _goToDashboard(context),
      onFooterAction: () =>
          Navigator.pushNamed(context, SignUpScreen.routeName),
    );
  }
}

class SignUpScreen extends StatelessWidget {
  const SignUpScreen({super.key});

  static const routeName = '/sign-up';

  @override
  Widget build(BuildContext context) {
    return AuthFrame(
      title: 'Create account',
      subtitle: 'Join Edge and get started in a few seconds.',
      actionText: 'Sign Up',
      footerText: 'Already have an account?',
      footerActionText: 'Sign In',
      fields: const [
        AuthTextField(
          label: 'Full name',
          icon: Icons.person_outline,
          textInputAction: TextInputAction.next,
        ),
        AuthTextField(
          label: 'Email',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
        AuthTextField(
          label: 'Password',
          icon: Icons.lock_outline,
          obscureText: true,
        ),
      ],
      onAction: () => _goToDashboard(context),
      onFooterAction: () => Navigator.pop(context),
    );
  }
}

class AuthFrame extends StatelessWidget {
  const AuthFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.actionText,
    required this.footerText,
    required this.footerActionText,
    required this.fields,
    required this.onAction,
    required this.onFooterAction,
  });

  final String title;
  final String subtitle;
  final String actionText;
  final String footerText;
  final String footerActionText;
  final List<Widget> fields;
  final VoidCallback onAction;
  final VoidCallback onFooterAction;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 36,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => _goToDashboard(context),
                        child: const Text('Skip'),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _BrandHeader(primary: primary),
                    const SizedBox(height: 38),
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: const Color(0xFF123D22),
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: const Color(0xFF5D7465),
                      ),
                    ),
                    const SizedBox(height: 30),
                    ...fields.expand(
                      (field) => [field, const SizedBox(height: 16)],
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: onAction,
                      child: Text(actionText),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            footerText,
                            style: const TextStyle(color: Color(0xFF52685A)),
                          ),
                        ),
                        TextButton(
                          onPressed: onFooterAction,
                          child: Text(footerActionText),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class AuthTextField extends StatelessWidget {
  const AuthTextField({
    super.key,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.done,
  });

  final String label;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;

  @override
  Widget build(BuildContext context) {
    return TextField(
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.primary});

  final Color primary;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: primary,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: primary.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(Icons.eco_rounded, color: Colors.white, size: 32),
        ),
        const SizedBox(width: 14),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edge',
              style: TextStyle(
                color: Color(0xFF123D22),
                fontSize: 28,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              'Green account access',
              style: TextStyle(color: Color(0xFF5D7465)),
            ),
          ],
        ),
      ],
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  static const routeName = '/dashboard';

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final ModelDownloadCoordinator _modelCoordinator;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      lowerBound: 0.92,
      upperBound: 1.06,
    )..repeat(reverse: true);
    _modelCoordinator = ModelDownloadCoordinator(
      onChanged: () {
        if (mounted) {
          setState(() {});
        }
      },
    );
    unawaited(_modelCoordinator.refresh());
  }

  @override
  void dispose() {
    _modelCoordinator.dispose();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Dashboard',
      selectedRoute: DashboardScreen.routeName,
      child: DashboardSetupPanel(
        animation: _animationController,
        coordinator: _modelCoordinator,
      ),
    );
  }
}

class DashboardSetupPanel extends StatelessWidget {
  const DashboardSetupPanel({
    super.key,
    required this.animation,
    required this.coordinator,
  });

  final Animation<double> animation;
  final ModelDownloadCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final progress = coordinator.progress;
    final isReady = coordinator.isReady;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: const Color(0xFFF4FBF6),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFD8EBDD)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ScaleTransition(
                      scale: animation,
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: isReady ? primary : const Color(0xFFE7F6EB),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isReady
                              ? Icons.check_rounded
                              : Icons.psychology_alt_rounded,
                          color: isReady ? Colors.white : primary,
                          size: 34,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Setup the app',
                            style: TextStyle(
                              color: Color(0xFF123D22),
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            coordinator.statusText,
                            style: const TextStyle(color: Color(0xFF5D7465)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                LinearProgressIndicator(
                  value: progress > 0 && !isReady
                      ? progress
                      : isReady
                      ? 1.0
                      : null,
                  minHeight: 9,
                  borderRadius: BorderRadius.circular(12),
                  backgroundColor: const Color(0xFFE7F6EB),
                ),
                const SizedBox(height: 12),
                Text(
                  isReady
                      ? 'Offline Qwen model is ready.'
                      : coordinator.progressLabel,
                  style: const TextStyle(
                    color: Color(0xFF123D22),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (coordinator.errorText != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    coordinator.errorText!,
                    style: const TextStyle(color: Color(0xFFB3261E)),
                  ),
                ],
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFD8EBDD)),
                  ),
                  child: Text(
                    'Model status: ${coordinator.nativeStatus}\n'
                    'File size: ${_formatBytes(coordinator.fileSize)}\n'
                    'Downloaded: ${_formatBytes(coordinator.downloadedBytes)} / ${_formatBytes(coordinator.totalBytes)}\n'
                    'Device: ${coordinator.isEmulator ? 'emulator' : 'phone'} ${coordinator.supportedAbis.isEmpty ? '' : '(${coordinator.supportedAbis})'}\n'
                    'RAM: ${_formatBytes(coordinator.availableMemoryBytes)} free / ${_formatBytes(coordinator.totalMemoryBytes)} total\n'
                    'Reason: ${coordinator.nativeReason}\n'
                    'Path: ${coordinator.modelPath.isEmpty ? 'not available' : coordinator.modelPath}',
                    style: const TextStyle(
                      color: Color(0xFF52685A),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  onPressed: coordinator.isBusy || isReady
                      ? null
                      : () => unawaited(coordinator.startDownload()),
                  icon: Icon(
                    isReady ? Icons.check_rounded : Icons.download_rounded,
                  ),
                  label: Text(
                    isReady ? 'Offline AI ready' : 'Prepare offline AI',
                  ),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: coordinator.isBusy
                      ? null
                      : () => unawaited(coordinator.resetDownload()),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Reset model download'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.pushNamed(context, RagScreen.routeName),
                  icon: const Icon(Icons.analytics_outlined),
                  label: const Text('Open Rag'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const FeaturePanel(
            icon: Icons.dashboard_rounded,
            title: 'Dashboard',
            description:
                'Upload study files in Rag, prepare offline AI here, and use the assistant with or without backend support.',
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }

  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unitIndex = 0;

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }

  return '${size.toStringAsFixed(unitIndex == 0 ? 0 : 2)} ${units[unitIndex]}';
}

class AttendenceScreen extends StatelessWidget {
  const AttendenceScreen({super.key});

  static const routeName = '/attendence';

  @override
  Widget build(BuildContext context) {
    return const AppShell(
      title: 'Attendence',
      selectedRoute: routeName,
      child: FeaturePanel(
        icon: Icons.fact_check_outlined,
        title: 'Attendence',
        description:
            'Track daily presence, class records, and status updates here.',
      ),
    );
  }
}

class RagScreen extends StatefulWidget {
  const RagScreen({super.key});

  static const routeName = '/rag';

  @override
  State<RagScreen> createState() => _RagScreenState();
}

class _RagScreenState extends State<RagScreen> {
  static const _filePickerChannel = MethodChannel('edge/file_picker');

  final _backendController = TextEditingController(
    text: 'http://10.0.2.2:8000',
  );
  final _questionController = TextEditingController();
  final _offlineQwen = OfflineQwenService();
  final List<RagMessage> _messages = [
    const RagMessage(
      text: 'Ask a question or attach a document.',
      isUser: false,
    ),
  ];
  final List<OfflineRagDocument> _offlineDocuments = [];

  bool _isSending = false;
  bool _isUploadingFile = false;
  bool _useOfflineQwen = false;

  RagApiClient get _client => RagApiClient(_backendController.text.trim());

  @override
  void dispose() {
    _backendController.dispose();
    _questionController.dispose();
    unawaited(_offlineQwen.dispose());
    super.dispose();
  }

  Future<void> _sendQuestion() async {
    final question = _questionController.text.trim();
    if (question.isEmpty || _isSending) {
      return;
    }

    Object? offlineQwenError;

    setState(() {
      _messages.add(RagMessage(text: question, isUser: true));
      _isSending = true;
      _questionController.clear();
    });

    try {
      final context = _offlineContext(question);
      try {
        if (_useOfflineQwen && await _offlineQwen.isReady()) {
          final answer = context.isNotEmpty
              ? await _offlineQwen.answer(question: question, context: context)
              : await _offlineQwen.chat(question);

          setState(() {
            _messages.add(
              RagMessage(
                text: answer,
                isUser: false,
                sources: context.isEmpty
                    ? const []
                    : _offlineDocuments.map((document) => document.id).toList(),
              ),
            );
          });
          return;
        }
      } catch (error) {
        offlineQwenError = error;
        // Continue to backend or extractive local fallback.
      }

      final answer = await _client.ask(question);

      setState(() {
        _messages.add(
          RagMessage(
            text: offlineQwenError == null
                ? answer.answer
                : 'Offline Qwen error: $offlineQwenError\n\nBackend answer: ${answer.answer}',
            isUser: false,
            sources: answer.sources,
          ),
        );
      });
    } catch (error) {
      final offlineAnswer = _offlineAnswer(question);
      setState(() {
        _messages.add(
          RagMessage(
            text:
                offlineAnswer ??
                _offlineFailureMessage(
                  question,
                  backendError: error,
                  offlineQwenError: offlineQwenError,
                ),
            isUser: false,
            sources: offlineAnswer == null
                ? const []
                : _offlineDocuments.map((document) => document.id).toList(),
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  String _offlineFailureMessage(
    String question, {
    required Object backendError,
    Object? offlineQwenError,
  }) {
    if (_isGreeting(question)) {
      return 'Hi. Attach a document for Rag answers, or start Offline Qwen for general questions.';
    }

    final parts = <String>[
      'Backend is not reachable. Start the Python backend on port 8000, or attach a document so the app can answer locally.',
    ];

    if (offlineQwenError != null) {
      parts.add('Offline Qwen did not run: $offlineQwenError');
    }

    if (_offlineDocuments.isEmpty) {
      parts.add('No local Rag document is loaded yet. Tap the paperclip to add a file.');
    }

    parts.add('Backend detail: $backendError');
    return parts.join('\n\n');
  }

  bool _isGreeting(String question) {
    final clean = question.toLowerCase().replaceAll(
      RegExp(r'[^a-z ]'),
      '',
    ).trim();
    return clean == 'hi' ||
        clean == 'hello' ||
        clean == 'hey' ||
        clean == 'hii';
  }

  Future<void> _attachDocument() async {
    if (_isUploadingFile) {
      return;
    }

    try {
      final result = await _filePickerChannel.invokeMapMethod<String, dynamic>(
        'pickFile',
      );

      if (result == null) {
        return;
      }

      final bytes = result['bytes'];
      final name = result['name'];

      if (bytes is Uint8List && name is String) {
        final file = PickedRagFile(name: name, bytes: bytes);
        setState(() => _isUploadingFile = true);

        try {
          final ids = await _client.ingestFile(file);

          if (!mounted) {
            return;
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Uploaded ${ids.length} document chunk(s).')),
          );
        } catch (_) {
          _addOfflineDocument(file.name, _decodeOfflineFile(file.bytes));
          if (!mounted) {
            return;
          }

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Document added locally.')),
          );
        } finally {
          if (mounted) {
            setState(() => _isUploadingFile = false);
          }
        }
      }
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File picker failed: ${error.message}')),
      );
    }
  }

  void _addOfflineDocument(String id, String text) {
    final cleanText = text.trim();
    if (cleanText.isEmpty) {
      return;
    }

    _offlineDocuments.removeWhere((document) => document.id == id);
    _offlineDocuments.add(OfflineRagDocument(id: id, text: cleanText));
  }

  String? _offlineAnswer(String question) {
    if (_offlineDocuments.isEmpty) {
      return null;
    }

    final queryTokens = _ragTokens(question);
    final scoredLines = <ScoredLine>[];

    for (final document in _offlineDocuments) {
      for (final line in document.text.split('\n')) {
        final score = _scoreRagText(queryTokens, line);
        if (score > 0) {
          scoredLines.add(
            ScoredLine(
              score: score,
              text: line.replaceFirst(RegExp(r'^\d+\.\s*'), '').trim(),
            ),
          );
        }
      }
    }

    scoredLines.sort((a, b) => b.score.compareTo(a.score));
    final answerLines = <String>[];

    for (final line in scoredLines) {
      if (line.text.isNotEmpty && !answerLines.contains(line.text)) {
        answerLines.add(line.text);
      }
      if (answerLines.length == 4) {
        break;
      }
    }

    if (answerLines.isEmpty) {
      return 'I could not find matching information in the local Rag documents.';
    }

    return answerLines.join(' ');
  }

  String _offlineContext(String question) {
    if (_offlineDocuments.isEmpty) {
      return '';
    }

    final queryTokens = _ragTokens(question);
    final scoredLines = <ScoredLine>[];

    for (final document in _offlineDocuments) {
      for (final line in document.text.split('\n')) {
        final score = _scoreRagText(queryTokens, line);
        if (score > 0) {
          scoredLines.add(
            ScoredLine(
              score: score,
              text:
                  '[${document.id}] ${line.replaceFirst(RegExp(r'^\d+\.\s*'), '').trim()}',
            ),
          );
        }
      }
    }

    scoredLines.sort((a, b) => b.score.compareTo(a.score));
    return scoredLines.take(12).map((line) => line.text).join('\n');
  }

  String _decodeOfflineFile(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Rag',
      selectedRoute: RagScreen.routeName,
      bodyPadding: EdgeInsets.zero,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: TextButton.icon(
            onPressed: _isSending
                ? null
                : () => setState(() => _useOfflineQwen = !_useOfflineQwen),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: 0.16),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            icon: Icon(
              _useOfflineQwen
                  ? Icons.check_circle_rounded
                  : Icons.memory_rounded,
              size: 18,
            ),
            label: Text(_useOfflineQwen ? 'Qwen on' : 'Offline Qwen'),
          ),
        ),
      ],
      child: RagWorkspace(
        questionController: _questionController,
        messages: _messages,
        isSending: _isSending,
        isUploadingFile: _isUploadingFile,
        onSend: _sendQuestion,
        onAttachDocument: _attachDocument,
      ),
    );
  }
}

class RagWorkspace extends StatelessWidget {
  const RagWorkspace({
    super.key,
    required this.questionController,
    required this.messages,
    required this.isSending,
    required this.isUploadingFile,
    required this.onSend,
    required this.onAttachDocument,
  });

  final TextEditingController questionController;
  final List<RagMessage> messages;
  final bool isSending;
  final bool isUploadingFile;
  final VoidCallback onSend;
  final VoidCallback onAttachDocument;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: const Border(
                bottom: BorderSide(color: Color(0xFFE2EFE5)),
              ),
            ),
            child: ListView.separated(
              itemCount: messages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                return RagMessageBubble(message: messages[index]);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFF4FBF6),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFD8EBDD)),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Attach document',
                  onPressed: isUploadingFile ? null : onAttachDocument,
                  icon: isUploadingFile
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: primary,
                          ),
                        )
                      : const Icon(Icons.attach_file_rounded),
                ),
                Expanded(
                  child: TextField(
                    controller: questionController,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    decoration: const InputDecoration.collapsed(
                      hintText: 'Ask anything...',
                    ),
                  ),
                ),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: isSending ? null : onSend,
                  icon: isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ),
        ),
      ],
    );
  }
}

class RagMessageBubble extends StatelessWidget {
  const RagMessageBubble({super.key, required this.message});

  final RagMessage message;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final background = message.isUser ? primary : const Color(0xFFF4FBF6);
    final foreground = message.isUser ? Colors.white : const Color(0xFF123D22);

    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: message.isUser
              ? null
              : Border.all(color: const Color(0xFFD8EBDD)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(color: foreground, height: 1.35),
            ),
            if (message.sources.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Sources: ${message.sources.join(', ')}',
                style: const TextStyle(
                  color: Color(0xFF5D7465),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class RagMessage {
  const RagMessage({
    required this.text,
    required this.isUser,
    this.sources = const [],
  });

  final String text;
  final bool isUser;
  final List<String> sources;
}

class RagAnswer {
  const RagAnswer({required this.answer, required this.sources});

  final String answer;
  final List<String> sources;
}

class PickedRagFile {
  const PickedRagFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class OfflineQwenService {
  static const _channel = MethodChannel('edge/model_downloader');
  static const _modelFileName = 'qwen2.5-1.5b-instruct-q4_k_m.gguf';
  static const _minimumReadyBytes = 1000 * 1024 * 1024;
  static const _minimumTotalMemoryBytes = 3 * 1024 * 1024 * 1024;
  static const _minimumAvailableMemoryBytes = 900 * 1024 * 1024;

  final LlamaController _controller = LlamaController();
  Future<void>? _loadFuture;
  bool _loaded = false;

  Future<bool> isReady() async {
    return await _validatedModelPath() != null;
  }

  Future<String> answer({
    required String question,
    required String context,
  }) async {
    return _generate(
      messages: [
        ChatMessage(
          role: 'system',
          content:
              'You are an offline RAG assistant for students. Answer only from the supplied context. If the answer is not in the context, say you do not know.',
        ),
        ChatMessage(
          role: 'user',
          content: 'Context:\n$context\n\nQuestion:\n$question\n\nAnswer:',
        ),
      ],
      temperature: 0.2,
      maxTokens: 120,
    );
  }

  Future<String> chat(String question) async {
    return _generate(
      messages: [
        ChatMessage(
          role: 'system',
          content:
              'You are Qwen running offline inside the Edge Android app. Be helpful, concise, and clear for a student.',
        ),
        ChatMessage(role: 'user', content: question),
      ],
      temperature: 0.6,
      maxTokens: 140,
    );
  }

  Future<String> _generate({
    required List<ChatMessage> messages,
    required double temperature,
    required int maxTokens,
  }) async {
    await _ensureLoaded();

    final buffer = StringBuffer();
    final stream = _controller.generateChat(
      messages: messages,
      template: 'chatml',
      maxTokens: maxTokens,
      temperature: temperature,
      topP: 0.85,
      topK: 30,
      minP: 0.05,
      repeatPenalty: 1.12,
      repeatLastN: 64,
      seed: DateTime.now().millisecondsSinceEpoch,
    );

    await for (final token in stream.timeout(
      const Duration(seconds: 90),
      onTimeout: (sink) {
        sink.addError(
          TimeoutException('Offline Qwen took too long to answer.'),
        );
        sink.close();
      },
    )) {
      buffer.write(token);
    }

    final answer = buffer.toString().trim();
    return answer.isEmpty ? 'I could not generate an offline answer.' : answer;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded && await _controller.isModelLoaded()) {
      return;
    }

    _loadFuture ??= _loadModelSafely();
    await _loadFuture;
  }

  Future<void> _loadModelSafely() async {
    try {
      final modelPath = await _modelPath();
      if (modelPath == null) {
        throw Exception('Offline Qwen model is not ready yet.');
      }

      await _validateRuntimeDevice();
      await _controller.loadModel(
        modelPath: modelPath,
        threads: 2,
        contextSize: 512,
        gpuLayers: 0,
      ).timeout(const Duration(minutes: 3));
      _loaded = true;
    } catch (_) {
      _loadFuture = null;
      _loaded = false;
      rethrow;
    }
  }

  Future<void> dispose() async {
    try {
      await _controller.dispose();
    } catch (_) {
      // App shutdown should not be blocked by native cleanup failure.
    }
  }

  Future<String?> _modelPath() async {
    return _validatedModelPath();
  }

  Future<String?> _validatedModelPath() async {
    final status = await _modelStatus();
    final path = status['path'];
    if (path is! String || path.isEmpty) {
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      debugPrint('Model not found: $path');
      return null;
    }

    final size = await file.length();
    debugPrint('Model path: $path');
    debugPrint('Model size: $size');

    if (size < _minimumReadyBytes) {
      debugPrint('Model incomplete: $size < $_minimumReadyBytes');
      return null;
    }

    return path;
  }

  Future<void> _validateRuntimeDevice() async {
    final status = await _modelStatus();
    final isEmulator = status['isEmulator'] == true;
    final abis = status['supportedAbis'];
    final totalMemory = _asInt(status['totalMemoryBytes']);
    final availableMemory = _asInt(status['availableMemoryBytes']);

    if (isEmulator) {
      throw Exception(
        'Offline Qwen is blocked on emulator because native llama loading can close the app. Test it on a real ARM64 phone.',
      );
    }

    if (abis is List && !abis.contains('arm64-v8a')) {
      throw Exception(
        'Offline Qwen needs an ARM64 Android device. This device reports: ${abis.join(', ')}.',
      );
    }

    if (totalMemory > 0 && totalMemory < _minimumTotalMemoryBytes) {
      throw Exception(
        'Device RAM is too low for Qwen 1.5B. Use a phone with at least 4 GB RAM.',
      );
    }

    if (availableMemory > 0 && availableMemory < _minimumAvailableMemoryBytes) {
      throw Exception(
        'Not enough free RAM to load Qwen 1.5B. Close other apps and try again.',
      );
    }
  }

  Future<Map<String, dynamic>> _modelStatus() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'modelStatus',
      {'fileName': _modelFileName, 'expectedBytes': _minimumReadyBytes},
    );

    return result ?? <String, dynamic>{};
  }

  double _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }

    return 0;
  }

  int _asInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }

    return 0;
  }
}

class OfflineRagDocument {
  const OfflineRagDocument({required this.id, required this.text});

  final String id;
  final String text;
}

class ScoredLine {
  const ScoredLine({required this.score, required this.text});

  final int score;
  final String text;
}

List<String> _ragTokens(String text) {
  const stopWords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'by',
    'for',
    'from',
    'in',
    'is',
    'it',
    'of',
    'on',
    'or',
    'the',
    'to',
    'what',
    'when',
    'where',
    'which',
    'who',
  };

  return RegExp(r'[a-zA-Z0-9]+')
      .allMatches(text.toLowerCase())
      .map((match) => match.group(0)!)
      .where((word) => word.length > 1 && !stopWords.contains(word))
      .toList();
}

int _scoreRagText(List<String> queryTokens, String text) {
  final tokens = _ragTokens(text);
  var score = 0;

  for (final token in queryTokens) {
    score += tokens.where((word) => word == token).length;
  }

  return score;
}

class RagApiClient {
  RagApiClient(this.baseUrl);

  final String baseUrl;

  Future<List<String>> ingestText(String fileName, String text) async {
    final payload = await _post('/rag/ingest-text', {
      'file_name': fileName,
      'text': text,
    });

    final ids = payload['document_ids'];
    if (ids is List) {
      return ids.map((id) => id.toString()).toList();
    }

    return const [];
  }

  Future<List<String>> ingestPmSample() async {
    final payload = await _post(
      '/rag/ingest-sample-pm',
      {},
      timeout: const Duration(seconds: 2),
    );
    return _documentIds(payload);
  }

  Future<List<String>> ingestFile(PickedRagFile file) async {
    final boundary = 'edge-rag-${DateTime.now().microsecondsSinceEpoch}';
    Object? lastError;

    for (final candidate in _candidateBaseUrls()) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final uri = Uri.parse('$candidate/rag/ingest-file');

      try {
        final request = await client
            .postUrl(uri)
            .timeout(const Duration(seconds: 3));
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary',
        );
        request.add(utf8.encode('--$boundary\r\n'));
        request.add(
          utf8.encode(
            'Content-Disposition: form-data; name="file"; filename="${file.name}"\r\n',
          ),
        );
        request.add(
          utf8.encode('Content-Type: application/octet-stream\r\n\r\n'),
        );
        request.add(file.bytes);
        request.add(utf8.encode('\r\n--$boundary--\r\n'));

        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        final text = await response.transform(utf8.decoder).join();
        final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);

        if (response.statusCode >= 400) {
          final detail = decoded is Map ? decoded['detail'] : text;
          lastError = Exception(detail ?? 'HTTP ${response.statusCode}');
          continue;
        }

        if (decoded is Map<String, dynamic>) {
          return _documentIds(decoded);
        }

        lastError = const FormatException('Unexpected backend response');
      } catch (error) {
        lastError = error;
      } finally {
        client.close();
      }
    }

    throw Exception('Backend not reachable. Last error: $lastError');
  }

  Future<RagAnswer> ask(String message) async {
    final payload = await _post('/rag/chat', {'message': message});
    final sources = payload['sources'];

    return RagAnswer(
      answer: payload['answer']?.toString() ?? '',
      sources: sources is List
          ? sources.map((source) => source.toString()).toList()
          : const [],
    );
  }

  List<String> _documentIds(Map<String, dynamic> payload) {
    final ids = payload['document_ids'];
    if (ids is List) {
      return ids.map((id) => id.toString()).toList();
    }

    return const [];
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object> body, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    Object? lastError;

    for (final candidate in _candidateBaseUrls()) {
      final client = HttpClient();
      client.connectionTimeout = timeout;
      final uri = Uri.parse('$candidate$path');

      try {
        final request = await client.postUrl(uri).timeout(timeout);
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));

        final response = await request.close().timeout(timeout);
        final text = await response.transform(utf8.decoder).join();
        final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);

        if (response.statusCode >= 400) {
          final detail = decoded is Map ? decoded['detail'] : text;
          lastError = Exception(detail ?? 'HTTP ${response.statusCode}');
          continue;
        }

        if (decoded is Map<String, dynamic>) {
          return decoded;
        }

        lastError = const FormatException('Unexpected backend response');
      } catch (error) {
        lastError = error;
      } finally {
        client.close();
      }
    }

    throw Exception('Backend not reachable. Last error: $lastError');
  }

  List<String> _candidateBaseUrls() {
    final typed = _usableBaseUrl(baseUrl);
    final urls = <String>[
      if (typed.isNotEmpty) typed,
      'http://10.0.2.2:8000',
      'http://127.0.0.1:8000',
      'http://localhost:8000',
    ];
    final seen = <String>{};

    return [
      for (final url in urls)
        if (seen.add(url.replaceAll(RegExp(r'/+$'), '')))
          url.replaceAll(RegExp(r'/+$'), ''),
    ];
  }

  String _usableBaseUrl(String value) {
    final clean = value.trim().replaceAll(RegExp(r'/+$'), '');
    if (clean.isEmpty) {
      return '';
    }

    final uri = Uri.tryParse(clean);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return '';
    }

    final isLocalHost = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (isLocalHost && uri.hasPort && uri.port != 8000) {
      return '';
    }

    return clean;
  }
}

class SettingScreen extends StatelessWidget {
  const SettingScreen({super.key});

  static const routeName = '/setting';

  @override
  Widget build(BuildContext context) {
    return const AppShell(
      title: 'Setting',
      selectedRoute: routeName,
      child: FeaturePanel(
        icon: Icons.settings_outlined,
        title: 'Setting',
        description:
            'Manage app preferences, profile options, and account settings.',
      ),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.title,
    required this.selectedRoute,
    required this.child,
    this.actions,
    this.bodyPadding = const EdgeInsets.all(24),
  });

  final String title;
  final String selectedRoute;
  final Widget child;
  final List<Widget>? actions;
  final EdgeInsetsGeometry bodyPadding;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: primary,
        foregroundColor: Colors.white,
        actions: actions,
      ),
      drawer: AppNavigationDrawer(selectedRoute: selectedRoute),
      body: Padding(padding: bodyPadding, child: child),
    );
  }
}

class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({super.key, required this.selectedRoute});

  final String selectedRoute;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
              color: const Color(0xFFF4FBF6),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.eco_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Edge',
                        style: TextStyle(
                          color: Color(0xFF123D22),
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text('Menu', style: TextStyle(color: Color(0xFF5D7465))),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            DrawerMenuItem(
              icon: Icons.dashboard_outlined,
              label: 'Dashboard',
              routeName: DashboardScreen.routeName,
              selectedRoute: selectedRoute,
            ),
            DrawerMenuItem(
              icon: Icons.fact_check_outlined,
              label: 'Attendence',
              routeName: AttendenceScreen.routeName,
              selectedRoute: selectedRoute,
            ),
            DrawerMenuItem(
              icon: Icons.analytics_outlined,
              label: 'Rag',
              routeName: RagScreen.routeName,
              selectedRoute: selectedRoute,
            ),
            DrawerMenuItem(
              icon: Icons.settings_outlined,
              label: 'Setting',
              routeName: SettingScreen.routeName,
              selectedRoute: selectedRoute,
            ),
          ],
        ),
      ),
    );
  }
}

class DrawerMenuItem extends StatelessWidget {
  const DrawerMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.routeName,
    required this.selectedRoute,
  });

  final IconData icon;
  final String label;
  final String routeName;
  final String selectedRoute;

  @override
  Widget build(BuildContext context) {
    final isSelected = selectedRoute == routeName;
    final primary = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: ListTile(
        selected: isSelected,
        selectedTileColor: const Color(0xFFE7F6EB),
        iconColor: isSelected ? primary : const Color(0xFF52685A),
        textColor: isSelected ? primary : const Color(0xFF24382B),
        leading: Icon(icon),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onTap: () {
          Navigator.pop(context);

          if (!isSelected) {
            Navigator.pushReplacementNamed(context, routeName);
          }
        },
      ),
    );
  }
}

class FeaturePanel extends StatelessWidget {
  const FeaturePanel({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String description;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final primary = iconColor ?? Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFFF4FBF6),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFD8EBDD)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: primary, size: 38),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF123D22),
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: const TextStyle(color: Color(0xFF5D7465), height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

void _goToDashboard(BuildContext context) {
  Navigator.pushNamedAndRemoveUntil(
    context,
    DashboardScreen.routeName,
    (route) => false,
  );
}
