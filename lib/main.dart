import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  var firebaseReady = false;
  String? firebaseError;
  try {
    await Firebase.initializeApp();
    firebaseReady = true;
  } catch (error) {
    firebaseError = error.toString();
  }

  runApp(
    SessionScope(
      notifier: AppSession(),
      child: EdgeApp(
        firebaseReady: firebaseReady,
        firebaseError: firebaseError,
      ),
    ),
  );
}

class EdgeApp extends StatelessWidget {
  const EdgeApp({super.key, required this.firebaseReady, this.firebaseError});

  final bool firebaseReady;
  final String? firebaseError;

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
      home: firebaseReady
          ? const AuthGate()
          : FirebaseSetupScreen(error: firebaseError),
      routes: {
        AiPreparationScreen.routeName: (_) => const AiPreparationScreen(),
        SignInScreen.routeName: (_) => const SignInScreen(),
        SignUpScreen.routeName: (_) => const SignUpScreen(),
        DashboardScreen.routeName: (_) => const DashboardScreen(),
        AttendenceScreen.routeName: (_) => const AttendenceScreen(),
        NewStudentScreen.routeName: (_) => const NewStudentScreen(),
        AdvanceSysScreen.routeName: (_) => const AdvanceSysScreen(),
        StudentApprovalsScreen.routeName: (_) => const StudentApprovalsScreen(),
        RagScreen.routeName: (_) => const RagScreen(),
        SettingScreen.routeName: (_) => const SettingScreen(),
      },
    );
  }
}

class AppSession extends ChangeNotifier {
  AppUserProfile? profile;

  bool get isAdmin => profile?.isAdmin == true;
  bool get isApproved => profile?.isApproved == true;
  bool get isStudent => profile?.role == UserRole.student;

  bool hasProfile(AppUserProfile? value) {
    final current = profile;
    return current?.uid == value?.uid &&
        current?.email == value?.email &&
        current?.displayName == value?.displayName &&
        current?.role == value?.role &&
        current?.status == value?.status &&
        current?.studentId == value?.studentId;
  }

  void setProfile(AppUserProfile? value) {
    if (hasProfile(value)) {
      return;
    }
    profile = value;
    notifyListeners();
  }
}

class SessionScope extends InheritedNotifier<AppSession> {
  const SessionScope({
    super.key,
    required AppSession notifier,
    required super.child,
  }) : super(notifier: notifier);

  static AppSession of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'SessionScope not found.');
    return scope!.notifier!;
  }

  static AppSession read(BuildContext context) {
    final widget = context
        .getElementForInheritedWidgetOfExactType<SessionScope>()
        ?.widget;
    assert(widget is SessionScope, 'SessionScope not found.');
    return (widget as SessionScope).notifier!;
  }
}

void _queueSessionProfile(BuildContext context, AppUserProfile? profile) {
  final session = SessionScope.read(context);
  if (session.hasProfile(profile)) {
    return;
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    session.setProfile(profile);
  });
}

enum UserRole { student, admin }

enum UserStatus { pending, approved, rejected }

class AppUserProfile {
  const AppUserProfile({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.role,
    required this.status,
    required this.studentId,
    this.verificationDocUrl,
    this.rejectionReason,
  });

  final String uid;
  final String email;
  final String displayName;
  final UserRole role;
  final UserStatus status;
  final String studentId;
  final String? verificationDocUrl;
  final String? rejectionReason;

  bool get isAdmin => role == UserRole.admin;
  bool get isApproved => status == UserStatus.approved;

  factory AppUserProfile.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    final role = data['role']?.toString() == 'admin'
        ? UserRole.admin
        : UserRole.student;
    final statusText = data['status']?.toString() ?? 'pending';
    final status = statusText == 'approved'
        ? UserStatus.approved
        : statusText == 'rejected'
        ? UserStatus.rejected
        : UserStatus.pending;

    return AppUserProfile(
      uid: doc.id,
      email: data['email']?.toString() ?? '',
      displayName: data['displayName']?.toString() ?? 'User',
      role: role,
      status: status,
      studentId: data['studentId']?.toString() ?? doc.id,
      verificationDocUrl: data['verificationDocUrl']?.toString(),
      rejectionReason: data['rejectionReason']?.toString(),
    );
  }
}

class FirebaseSetupScreen extends StatelessWidget {
  const FirebaseSetupScreen({super.key, this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 58,
                color: Color(0xFFB3261E),
              ),
              const SizedBox(height: 18),
              const Text(
                'Firebase setup required',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF123D22),
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Add your Firebase Android config before using authentication.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF5D7465), height: 1.4),
              ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFB3261E)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const _SessionLoadingScreen();
        }

        final user = authSnapshot.data;
        if (user == null) {
          _queueSessionProfile(context, null);
          return const SignInScreen();
        }

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .snapshots(),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return const _SessionLoadingScreen();
            }

            final doc = profileSnapshot.data;
            if (doc == null || !doc.exists) {
              _queueSessionProfile(context, null);
              return const MissingProfileScreen();
            }

            final profile = AppUserProfile.fromDoc(doc);
            _queueSessionProfile(context, profile);

            if (!profile.isApproved) {
              return StudentApprovalStatusScreen(profile: profile);
            }

            if (profile.isAdmin) {
              return const DashboardScreen();
            }

            return const RagScreen();
          },
        );
      },
    );
  }
}

class _SessionLoadingScreen extends StatelessWidget {
  const _SessionLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class MissingProfileScreen extends StatelessWidget {
  const MissingProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _AccountStateScreen(
      icon: Icons.manage_accounts_outlined,
      title: 'Profile setup pending',
      message:
          'Your Firebase account exists, but the app profile was not created. Sign out and sign up again.',
      actionText: 'Sign out',
      onAction: () => FirebaseAuth.instance.signOut(),
    );
  }
}

class StudentApprovalStatusScreen extends StatelessWidget {
  const StudentApprovalStatusScreen({super.key, required this.profile});

  final AppUserProfile profile;

  @override
  Widget build(BuildContext context) {
    final rejected = profile.status == UserStatus.rejected;
    return _AccountStateScreen(
      icon: rejected ? Icons.cancel_outlined : Icons.hourglass_top_rounded,
      title: rejected ? 'Verification rejected' : 'Waiting for admin approval',
      message: rejected
          ? (profile.rejectionReason?.isNotEmpty == true
                ? profile.rejectionReason!
                : 'An admin rejected this verification request.')
          : 'Your verification document is submitted. An admin must approve your student account before you can use Rag and attendance.',
      actionText: 'Sign out',
      onAction: () => FirebaseAuth.instance.signOut(),
    );
  }
}

class _AccountStateScreen extends StatelessWidget {
  const _AccountStateScreen({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionText,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionText;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, color: primary, size: 58),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF123D22),
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF5D7465), height: 1.4),
              ),
              const SizedBox(height: 22),
              OutlinedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.logout_rounded),
                label: Text(actionText),
              ),
            ],
          ),
        ),
      ),
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

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  static const routeName = '/sign-in';

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _message;
  bool _isBusy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _isBusy = true;
      _message = null;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } on FirebaseAuthException catch (error) {
      setState(() => _message = error.message ?? error.code);
    } catch (error) {
      setState(() => _message = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthFrame(
      title: 'Welcome back',
      subtitle: 'Sign in to continue to your dashboard.',
      actionText: 'Sign In',
      footerText: 'Do not have an account?',
      footerActionText: 'Sign Up',
      isBusy: _isBusy,
      message: _message,
      fields: [
        AuthTextField(
          controller: _emailController,
          label: 'Email',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
        ),
        AuthTextField(
          controller: _passwordController,
          label: 'Password',
          icon: Icons.lock_outline,
          obscureText: true,
        ),
      ],
      onAction: _signIn,
      onFooterAction: () =>
          Navigator.pushNamed(context, SignUpScreen.routeName),
    );
  }
}

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  static const routeName = '/sign-up';

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  static const _filePickerChannel = MethodChannel('edge/file_picker');
  static const _adminSignupCode = '0209';

  final _nameController = TextEditingController();
  final _studentIdController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _adminCodeController = TextEditingController();
  final List<PickedRagFile> _attendanceImages = [];
  bool _isAdminSignup = false;
  bool _isBusy = false;
  String? _message;

  @override
  void dispose() {
    _nameController.dispose();
    _studentIdController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _adminCodeController.dispose();
    super.dispose();
  }

  Future<void> _pickAttendanceImage() async {
    final result = await _filePickerChannel.invokeMapMethod<String, dynamic>(
      'pickFile',
    );
    if (result == null) {
      return;
    }

    final bytes = result['bytes'];
    final name = result['name'];
    if (bytes is Uint8List && name is String) {
      setState(() {
        _attendanceImages.add(PickedRagFile(name: name, bytes: bytes));
      });
    }
  }

  Future<void> _signUp() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final studentId = _studentIdController.text.trim();

    if (name.isEmpty || email.isEmpty || password.isEmpty) {
      setState(() => _message = 'Name, email, and password are required.');
      return;
    }

    if (!_isAdminSignup &&
        (studentId.isEmpty || _attendanceImages.length < 4)) {
      setState(
        () => _message =
            'Student ID and at least 4 attendance photos are required.',
      );
      return;
    }

    if (_isAdminSignup && _adminCodeController.text.trim().isEmpty) {
      setState(() => _message = 'Admin signup code is required.');
      return;
    }

    setState(() {
      _isBusy = true;
      _message = null;
    });

    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);
      final user = credential.user;
      if (user == null) {
        throw StateError('Firebase did not return a user.');
      }

      await user.updateDisplayName(name);

      if (_isAdminSignup) {
        if (_adminCodeController.text.trim() != _adminSignupCode) {
          await user.delete();
          throw Exception('Invalid admin signup code.');
        }

        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'email': email,
          'displayName': name,
          'role': 'admin',
          'status': 'approved',
          'studentId': user.uid,
          'createdAt': FieldValue.serverTimestamp(),
          'reviewedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } else {
        final imageUrls = <String>[];
        final imageNames = <String>[];
        for (var index = 0; index < _attendanceImages.length; index++) {
          final image = _attendanceImages[index];
          final safeName = _safeStorageName(image.name);
          final path =
              'student_attendance_images/${user.uid}/${index + 1}_$safeName';
          final metadata = SettableMetadata(
            contentType: _verificationContentType(image.name),
          );
          final ref = FirebaseStorage.instance.ref(path);
          await ref.putData(image.bytes, metadata);
          imageUrls.add(await ref.getDownloadURL());
          imageNames.add(image.name);
        }

        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'email': email,
          'displayName': name,
          'role': 'student',
          'status': 'pending',
          'studentId': studentId,
          'attendanceImageUrls': imageUrls,
          'attendanceImageNames': imageNames,
          'attendanceImageCount': imageUrls.length,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } on FirebaseAuthException catch (error) {
      setState(() => _message = error.message ?? error.code);
    } catch (error) {
      setState(() => _message = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthFrame(
      title: 'Create account',
      subtitle: 'Join Edge and get started in a few seconds.',
      actionText: 'Sign Up',
      footerText: 'Already have an account?',
      footerActionText: 'Sign In',
      isBusy: _isBusy,
      message: _message,
      fields: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _isAdminSignup,
          onChanged: _isBusy
              ? null
              : (value) => setState(() => _isAdminSignup = value),
          title: const Text('Create admin account'),
          subtitle: const Text('Admins need the prototype signup code.'),
        ),
        AuthTextField(
          controller: _nameController,
          label: 'Full name',
          icon: Icons.person_outline,
          textInputAction: TextInputAction.next,
        ),
        if (!_isAdminSignup)
          AuthTextField(
            controller: _studentIdController,
            label: 'Student ID',
            icon: Icons.badge_outlined,
            textInputAction: TextInputAction.next,
          ),
        AuthTextField(
          controller: _emailController,
          label: 'Email',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
        AuthTextField(
          controller: _passwordController,
          label: 'Password',
          icon: Icons.lock_outline,
          obscureText: true,
        ),
        if (_isAdminSignup)
          AuthTextField(
            controller: _adminCodeController,
            label: 'Admin signup code',
            icon: Icons.admin_panel_settings_outlined,
            obscureText: true,
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: _isBusy ? null : _pickAttendanceImage,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(
                  'Add attendance photo (${_attendanceImages.length}/4)',
                ),
              ),
              if (_attendanceImages.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (
                      var index = 0;
                      index < _attendanceImages.length;
                      index++
                    )
                      InputChip(
                        label: Text(
                          _attendanceImages[index].name,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onDeleted: _isBusy
                            ? null
                            : () => setState(
                                () => _attendanceImages.removeAt(index),
                              ),
                      ),
                  ],
                ),
              ],
            ],
          ),
      ],
      onAction: _signUp,
      onFooterAction: () => Navigator.pop(context),
    );
  }
}

String _verificationContentType(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.pdf')) {
    return 'application/pdf';
  }
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  return 'image/jpeg';
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
    this.isBusy = false,
    this.message,
  });

  final String title;
  final String subtitle;
  final String actionText;
  final String footerText;
  final String footerActionText;
  final List<Widget> fields;
  final FutureOr<void> Function()? onAction;
  final VoidCallback onFooterAction;
  final bool isBusy;
  final String? message;

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
                    if (message != null) ...[
                      Text(
                        message!,
                        style: const TextStyle(color: Color(0xFFB3261E)),
                      ),
                      const SizedBox(height: 12),
                    ],
                    ElevatedButton.icon(
                      onPressed: isBusy || onAction == null ? null : onAction,
                      icon: isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.arrow_forward_rounded),
                      label: Text(isBusy ? 'Please wait...' : actionText),
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
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.done,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
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
  final _attendanceBackendController = TextEditingController(
    text: AttendanceApiClient.defaultBaseUrl,
  );
  final _rtspController = TextEditingController(
    text:
        'rtsp://username:password@192.168.1.250:554/cam/realmonitor?channel=1&subtype=1',
  );
  String? _streamMessage;
  bool _isSavingStream = false;
  bool _showLiveFeed = false;

  AttendanceApiClient get _attendanceClient =>
      AttendanceApiClient(_attendanceBackendController.text.trim());

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
    _attendanceBackendController.dispose();
    _rtspController.dispose();
    _modelCoordinator.dispose();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _saveStreamConfig() async {
    setState(() {
      _isSavingStream = true;
      _streamMessage = null;
    });

    try {
      await _attendanceClient.setStreamConfig(_rtspController.text.trim());
      if (mounted) {
        setState(() {
          _streamMessage = 'RTSP stream connected.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _streamMessage = 'RTSP setup failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isSavingStream = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Dashboard',
      selectedRoute: DashboardScreen.routeName,
      child: DashboardSetupPanel(
        animation: _animationController,
        coordinator: _modelCoordinator,
        backendController: _attendanceBackendController,
        rtspController: _rtspController,
        streamMessage: _streamMessage,
        isSavingStream: _isSavingStream,
        showLiveFeed: _showLiveFeed,
        onSaveStream: _saveStreamConfig,
        onToggleLiveFeed: () {
          setState(() => _showLiveFeed = !_showLiveFeed);
        },
      ),
    );
  }
}

class DashboardSetupPanel extends StatelessWidget {
  const DashboardSetupPanel({
    super.key,
    required this.animation,
    required this.coordinator,
    required this.backendController,
    required this.rtspController,
    required this.streamMessage,
    required this.isSavingStream,
    required this.showLiveFeed,
    required this.onSaveStream,
    required this.onToggleLiveFeed,
  });

  final Animation<double> animation;
  final ModelDownloadCoordinator coordinator;
  final TextEditingController backendController;
  final TextEditingController rtspController;
  final String? streamMessage;
  final bool isSavingStream;
  final bool showLiveFeed;
  final VoidCallback onSaveStream;
  final VoidCallback onToggleLiveFeed;

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
          const SizedBox(height: 18),
          _RtspDashboardPanel(
            backendController: backendController,
            rtspController: rtspController,
            streamMessage: streamMessage,
            isSavingStream: isSavingStream,
            showLiveFeed: showLiveFeed,
            onSaveStream: onSaveStream,
            onToggleLiveFeed: onToggleLiveFeed,
          ),
        ],
      ),
    );
  }
}

class _RtspDashboardPanel extends StatelessWidget {
  const _RtspDashboardPanel({
    required this.backendController,
    required this.rtspController,
    required this.streamMessage,
    required this.isSavingStream,
    required this.showLiveFeed,
    required this.onSaveStream,
    required this.onToggleLiveFeed,
  });

  final TextEditingController backendController;
  final TextEditingController rtspController;
  final String? streamMessage;
  final bool isSavingStream;
  final bool showLiveFeed;
  final VoidCallback onSaveStream;
  final VoidCallback onToggleLiveFeed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FBF6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD8EBDD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.videocam_outlined, color: Color(0xFF16833B)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Attendance camera',
                  style: TextStyle(
                    color: Color(0xFF123D22),
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (showLiveFeed) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _BackendLiveFrameViewer(
                  key: ValueKey(backendController.text.trim()),
                  client: AttendanceApiClient(backendController.text.trim()),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            onPressed: onToggleLiveFeed,
            icon: Icon(
              showLiveFeed
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
            ),
            label: Text(showLiveFeed ? 'Hide live camera' : 'View live camera'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: rtspController,
            decoration: const InputDecoration(
              labelText: 'RTSP URL',
              prefixIcon: Icon(Icons.link_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: backendController,
            decoration: const InputDecoration(
              labelText: 'Python backend URL',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          if (streamMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              streamMessage!,
              style: const TextStyle(color: Color(0xFF52685A)),
            ),
          ],
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: isSavingStream ? null : onSaveStream,
            icon: isSavingStream
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.settings_input_antenna_rounded),
            label: Text(isSavingStream ? 'Connecting...' : 'Connect RTSP'),
          ),
        ],
      ),
    );
  }
}

class _BackendLiveFrameViewer extends StatefulWidget {
  const _BackendLiveFrameViewer({super.key, required this.client});

  final AttendanceApiClient client;

  @override
  State<_BackendLiveFrameViewer> createState() =>
      _BackendLiveFrameViewerState();
}

class _BackendLiveFrameViewerState extends State<_BackendLiveFrameViewer> {
  final HttpClient _httpClient = HttpClient();
  Timer? _timer;
  int _tick = 0;
  Map<String, String> _headers = const {};
  Uint8List? _frameBytes;
  String? _statusText;
  bool _isLoading = true;
  bool _fetchInFlight = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHeaders());
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      unawaited(_refreshFrame());
    });
    unawaited(_refreshFrame());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _httpClient.close(force: true);
    super.dispose();
  }

  Future<void> _loadHeaders() async {
    final headers = await _firebaseAuthHeaderMap();
    if (mounted) {
      setState(() => _headers = headers);
    }
  }

  Future<void> _refreshFrame() async {
    if (_fetchInFlight) {
      return;
    }
    _fetchInFlight = true;

    final uri = Uri.parse(widget.client.streamFrameUrl(_tick++));
    try {
      final request = await _httpClient.getUrl(uri);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.acceptHeader, 'image/jpeg');
      for (final entry in _headers.entries) {
        request.headers.set(entry.key, entry.value);
      }

      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final bytes = await response.fold<List<int>>(<int>[], (buffer, chunk) {
        buffer.addAll(chunk);
        return buffer;
      });

      if (!mounted) {
        return;
      }

      if (response.statusCode != HttpStatus.ok) {
        final text = utf8.decode(bytes, allowMalformed: true).trim();
        setState(() {
          _frameBytes = null;
          _isLoading = false;
          _statusText = text.isNotEmpty
              ? text
              : 'Frame request failed with HTTP ${response.statusCode}.';
        });
        return;
      }

      setState(() {
        _frameBytes = Uint8List.fromList(bytes);
        _isLoading = false;
        _statusText = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusText = 'Live frame error: $error';
        });
      }
    } finally {
      _fetchInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_frameBytes != null)
            Image.memory(_frameBytes!, fit: BoxFit.cover, gaplessPlayback: true)
          else
            const SizedBox.expand(),
          if (_isLoading && _frameBytes == null)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (_statusText != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    _statusText!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RtspLivePlayer extends StatefulWidget {
  const _RtspLivePlayer({required this.rtspUrl});

  final String rtspUrl;

  @override
  State<_RtspLivePlayer> createState() => _RtspLivePlayerState();
}

class _RtspLivePlayerState extends State<_RtspLivePlayer> {
  VlcPlayerController? _controller;
  Timer? _loadTimer;
  bool _loadingTimedOut = false;
  bool? _rtspPortReachable;
  String? _rtspNetworkMessage;
  int _playAttempt = 0;

  List<_RtspPlaybackProfile> get _playbackProfiles =>
      _rtspPlaybackProfiles(widget.rtspUrl);

  _RtspPlaybackProfile get _activeProfile {
    final profiles = _playbackProfiles;
    final index = _playAttempt < profiles.length
        ? _playAttempt
        : profiles.length - 1;
    return profiles[index];
  }

  @override
  void initState() {
    super.initState();
    _checkRtspReachability();
    _createController();
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_handlePlayerChanged);
      unawaited(controller.stop());
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  void _createController() {
    _loadTimer?.cancel();
    final oldController = _controller;
    if (oldController != null) {
      oldController.removeListener(_handlePlayerChanged);
      unawaited(oldController.stop());
      unawaited(oldController.dispose());
    }

    final profile = _activeProfile;
    final controller = VlcPlayerController.network(
      profile.url,
      hwAcc: profile.hwAcc,
      autoPlay: true,
      options: _vlcOptions(),
    );
    controller.addListener(_handlePlayerChanged);
    _controller = controller;
    _startLoadTimer();
  }

  VlcPlayerOptions _vlcOptions() {
    return VlcPlayerOptions(
      advanced: VlcAdvancedOptions([
        VlcAdvancedOptions.networkCaching(1200),
        VlcAdvancedOptions.liveCaching(700),
        VlcAdvancedOptions.clockSynchronization(0),
        VlcAdvancedOptions.clockJitter(0),
      ]),
      rtp: VlcRtpOptions([VlcRtpOptions.rtpOverRtsp(true)]),
      extras: const ['--no-audio', '--drop-late-frames', '--skip-frames'],
    );
  }

  Future<void> _checkRtspReachability() async {
    final uri = Uri.tryParse(widget.rtspUrl);
    final host = uri?.host ?? '';
    final port = uri == null || uri.port == 0 ? 554 : uri.port;

    if (uri == null || uri.scheme != 'rtsp' || host.isEmpty) {
      if (mounted) {
        setState(() {
          _rtspPortReachable = false;
          _rtspNetworkMessage = 'Invalid RTSP URL.';
        });
      }
      return;
    }

    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 4),
      );
      socket.destroy();

      if (mounted) {
        setState(() {
          _rtspPortReachable = true;
          _rtspNetworkMessage = 'RTSP port reachable at $host:$port.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _rtspPortReachable = false;
          _rtspNetworkMessage =
              'Phone cannot reach RTSP camera at $host:$port. Check same Wi-Fi, camera app, and IP address.';
        });
      }
    }
  }

  void _handlePlayerChanged() {
    final value = _controller?.value;
    if (value == null) {
      return;
    }

    if (value.isPlaying) {
      _loadTimer?.cancel();
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _startLoadTimer() {
    _loadTimer?.cancel();
    _loadingTimedOut = false;
    _loadTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _controller?.value.isPlaying == true) {
        return;
      }

      final profiles = _playbackProfiles;
      if (_rtspPortReachable != false && _playAttempt < profiles.length - 1) {
        setState(() {
          _playAttempt++;
          _loadingTimedOut = false;
        });
        _createController();
      } else {
        setState(() => _loadingTimedOut = true);
      }
    });
  }

  void _retry() {
    final profiles = _playbackProfiles;
    setState(() {
      _playAttempt = (_playAttempt + 1) % profiles.length;
      _loadingTimedOut = false;
      _rtspPortReachable = null;
      _rtspNetworkMessage = null;
    });
    _checkRtspReachability();
    _createController();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = _playbackProfiles;
    final profile = _activeProfile;
    final controller = _controller;
    final value = controller?.value;
    final showStatus =
        controller == null ||
        _rtspPortReachable == false ||
        value == null ||
        value.hasError ||
        _loadingTimedOut ||
        value.isBuffering ||
        value.playingState == PlayingState.initializing ||
        value.playingState == PlayingState.initialized;
    final statusText = _rtspPortReachable == false
        ? _rtspNetworkMessage ?? 'Phone cannot reach the RTSP camera.'
        : value?.hasError == true
        ? 'Camera player error: ${value?.errorDescription ?? 'unknown error'}'
        : _loadingTimedOut
        ? _rtspPortReachable == true
              ? 'RTSP is reachable, but Android VLC did not render video. Use the camera sub-stream or lower H.264 settings.'
              : 'Camera is still not loading. Check the RTSP app is running and the phone is on the same Wi-Fi.'
        : 'Connecting to live camera...';
    final modeText =
        'Trying ${profile.label} (${_playAttempt + 1}/${profiles.length})';

    return Container(
      color: Colors.black,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (controller != null)
            VlcPlayer(
              key: ValueKey('vlc-${profile.url}-$_playAttempt'),
              controller: controller,
              aspectRatio: 16 / 9,
              virtualDisplay: profile.virtualDisplay,
              placeholder: const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          if (showStatus)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 220;
                    final padding = EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: compact ? 8 : 14,
                    );
                    final minHeight = constraints.maxHeight > padding.vertical
                        ? constraints.maxHeight - padding.vertical
                        : 0.0;
                    final indicatorSize = compact ? 22.0 : 28.0;

                    return SingleChildScrollView(
                      padding: padding,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: minHeight),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (value?.hasError != true &&
                                  !_loadingTimedOut &&
                                  _rtspPortReachable != false)
                                SizedBox(
                                  width: indicatorSize,
                                  height: indicatorSize,
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              else
                                Icon(
                                  Icons.videocam_off_outlined,
                                  color: Colors.white,
                                  size: compact ? 26 : 34,
                                ),
                              SizedBox(height: compact ? 8 : 12),
                              Text(
                                _rtspNetworkMessage ?? modeText,
                                textAlign: TextAlign.center,
                                maxLines: compact ? 2 : 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: compact ? 6 : 8),
                              Text(
                                statusText,
                                textAlign: TextAlign.center,
                                maxLines: compact ? 3 : 4,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: compact ? 13 : 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: compact ? 8 : 12),
                              OutlinedButton.icon(
                                onPressed: _retry,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.white70),
                                  minimumSize: Size(0, compact ? 34 : 40),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 12 : 16,
                                    vertical: 0,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Retry camera'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RtspPlaybackProfile {
  const _RtspPlaybackProfile({
    required this.url,
    required this.label,
    required this.virtualDisplay,
    required this.hwAcc,
  });

  final String url;
  final String label;
  final bool virtualDisplay;
  final HwAcc hwAcc;
}

List<_RtspPlaybackProfile> _rtspPlaybackProfiles(String rtspUrl) {
  final trimmedUrl = rtspUrl.trim();
  final subStreamUrl = _dahuaSubStreamUrl(trimmedUrl);
  final profiles = <_RtspPlaybackProfile>[];

  if (subStreamUrl != null && subStreamUrl != trimmedUrl) {
    profiles.add(
      _RtspPlaybackProfile(
        url: subStreamUrl,
        label: 'camera sub-stream, VLC virtual display',
        virtualDisplay: true,
        hwAcc: HwAcc.auto,
      ),
    );
  }

  profiles.addAll([
    _RtspPlaybackProfile(
      url: trimmedUrl,
      label: 'configured stream, VLC virtual display',
      virtualDisplay: true,
      hwAcc: HwAcc.auto,
    ),
    _RtspPlaybackProfile(
      url: trimmedUrl,
      label: 'configured stream, hardware decoder',
      virtualDisplay: true,
      hwAcc: HwAcc.full,
    ),
    _RtspPlaybackProfile(
      url: trimmedUrl,
      label: 'configured stream, software decoder',
      virtualDisplay: true,
      hwAcc: HwAcc.disabled,
    ),
    _RtspPlaybackProfile(
      url: trimmedUrl,
      label: 'configured stream, hybrid view',
      virtualDisplay: false,
      hwAcc: HwAcc.disabled,
    ),
  ]);

  return profiles;
}

String? _dahuaSubStreamUrl(String rtspUrl) {
  if (!RegExp(r'([?&]subtype=)0\b').hasMatch(rtspUrl)) {
    return null;
  }

  return rtspUrl.replaceFirstMapped(
    RegExp(r'([?&]subtype=)0\b'),
    (match) => '${match.group(1)}1',
  );
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

class NewStudentScreen extends StatefulWidget {
  const NewStudentScreen({super.key});

  static const routeName = '/new-student';

  @override
  State<NewStudentScreen> createState() => _NewStudentScreenState();
}

class _NewStudentScreenState extends State<NewStudentScreen> {
  static const _filePickerChannel = MethodChannel('edge/file_picker');

  final _nameController = TextEditingController();
  final _studentIdController = TextEditingController();
  final _backendController = TextEditingController(
    text: AttendanceApiClient.defaultBaseUrl,
  );
  final List<PickedRagFile> _images = [];
  bool _isSaving = false;
  String? _message;

  AttendanceApiClient get _client =>
      AttendanceApiClient(_backendController.text.trim());

  @override
  void dispose() {
    _nameController.dispose();
    _studentIdController.dispose();
    _backendController.dispose();
    super.dispose();
  }

  Future<void> _addImage() async {
    final result = await _filePickerChannel.invokeMapMethod<String, dynamic>(
      'pickFile',
    );
    if (result == null) {
      return;
    }
    final bytes = result['bytes'];
    final name = result['name'];
    if (bytes is Uint8List && name is String) {
      setState(() => _images.add(PickedRagFile(name: name, bytes: bytes)));
    }
  }

  Future<void> _saveStudent() async {
    final name = _nameController.text.trim();
    final studentId = _studentIdController.text.trim();
    if (name.isEmpty || studentId.isEmpty) {
      setState(() => _message = 'Student name and ID are required.');
      return;
    }
    if (_images.length < 4) {
      setState(() => _message = 'Upload at least 4 student images.');
      return;
    }

    setState(() {
      _isSaving = true;
      _message = null;
    });

    try {
      final imageUrls = <String>[];
      for (var index = 0; index < _images.length; index++) {
        final image = _images[index];
        final path =
            'attendance_student_images/${_safeStorageName(studentId)}/${index + 1}_${_safeStorageName(image.name)}';
        final ref = FirebaseStorage.instance.ref(path);
        await ref.putData(
          image.bytes,
          SettableMetadata(contentType: _verificationContentType(image.name)),
        );
        imageUrls.add(await ref.getDownloadURL());
      }

      final result = await _client.createAttendanceStudent(
        name: name,
        studentId: studentId,
        images: _images,
        imageUrls: imageUrls,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _message =
            result['message']?.toString() ?? 'Student saved for attendance.';
        _images.clear();
        _nameController.clear();
        _studentIdController.clear();
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Save failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!SessionScope.of(context).isAdmin) {
      return const RagScreen();
    }

    return AppShell(
      title: 'New Student',
      selectedRoute: NewStudentScreen.routeName,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Student name',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _studentIdController,
              decoration: const InputDecoration(
                labelText: 'Student ID',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _backendController,
              decoration: const InputDecoration(
                labelText: 'Python backend URL',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isSaving ? null : _addImage,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text('Add image (${_images.length}/4)'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_images.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var index = 0; index < _images.length; index++)
                    Chip(
                      label: Text(_images[index].name),
                      onDeleted: _isSaving
                          ? null
                          : () => setState(() => _images.removeAt(index)),
                    ),
                ],
              ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: const TextStyle(color: Color(0xFF52685A))),
            ],
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _saveStudent,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(_isSaving ? 'Saving...' : 'Save student'),
            ),
          ],
        ),
      ),
    );
  }
}

String _safeStorageName(String value) {
  return value
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
}

class AttendenceScreen extends StatefulWidget {
  const AttendenceScreen({super.key});

  static const routeName = '/attendence';

  @override
  State<AttendenceScreen> createState() => _AttendenceScreenState();
}

class _AttendenceScreenState extends State<AttendenceScreen> {
  static const _filePickerChannel = MethodChannel('edge/file_picker');

  final _backendController = TextEditingController(
    text: AttendanceApiClient.defaultBaseUrl,
  );
  Map<String, dynamic>? _status;
  List<dynamic> _records = [];
  List<dynamic> _studentCalendar = [];
  String? _message;
  bool _isLoading = false;
  bool _isBuilding = false;
  bool _isMatching = false;
  bool _isCheckingStream = false;

  AttendanceApiClient get _client =>
      AttendanceApiClient(_backendController.text.trim());

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _backendController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final isAdmin = SessionScope.read(context).isAdmin;
      final status = isAdmin ? await _client.status() : null;
      final records = isAdmin ? await _client.records() : const <dynamic>[];
      final studentCalendar = isAdmin
          ? const <dynamic>[]
          : await _client.myAttendanceCalendar();
      if (!mounted) {
        return;
      }

      setState(() {
        _status = status;
        _records = records;
        _studentCalendar = studentCalendar;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Backend error: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _buildEmbeddings() async {
    setState(() {
      _isBuilding = true;
      _message = null;
    });

    try {
      final result = await _client.buildEmbeddings();
      if (!mounted) {
        return;
      }

      setState(() {
        _message =
            'Built embeddings for ${result['student_count']} student(s).';
      });
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Embedding build failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isBuilding = false);
      }
    }
  }

  Future<void> _matchImage() async {
    if (_isMatching) {
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
      if (bytes is! Uint8List || name is! String) {
        return;
      }

      setState(() {
        _isMatching = true;
        _message = null;
      });

      final match = await _client.matchFile(
        PickedRagFile(name: name, bytes: bytes),
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _message = match['matched'] == true
            ? 'Marked present: ${match['best_match']?['name']}'
            : match['message']?.toString() ?? 'No confident match.';
      });
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Attendance scan failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isMatching = false);
      }
    }
  }

  Future<void> _checkStreamAttendance() async {
    setState(() {
      _isCheckingStream = true;
      _message = null;
    });

    try {
      final match = await _client.checkStream();
      if (!mounted) {
        return;
      }

      setState(() {
        _message = match['matched'] == true
            ? 'Marked present: ${match['best_match']?['name']}'
            : match['message']?.toString() ?? 'No confident match.';
      });
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Camera check failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isCheckingStream = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = SessionScope.of(context).isAdmin;
    final status = _status;
    final students = status?['students'] is List
        ? status!['students'] as List<dynamic>
        : const <dynamic>[];

    if (!isAdmin) {
      return AppShell(
        title: 'Attendence',
        selectedRoute: AttendenceScreen.routeName,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StudentAttendanceSummary(
                isLoading: _isLoading,
                message: _message,
                rows: _studentCalendar,
                onRefresh: _refresh,
              ),
              const SizedBox(height: 18),
              _StudentAttendanceCalendar(rows: _studentCalendar),
            ],
          ),
        ),
      );
    }

    return AppShell(
      title: 'Attendence',
      selectedRoute: AttendenceScreen.routeName,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AttendanceSummaryCard(
              isLoading: _isLoading,
              status: status,
              message: _message,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isBuilding ? null : _buildEmbeddings,
                    icon: _isBuilding
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.auto_fix_high_rounded),
                    label: Text(
                      _isBuilding ? 'Building...' : 'Build embeddings',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isMatching ? null : _matchImage,
                    icon: _isMatching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.person_search_rounded),
                    label: Text(_isMatching ? 'Scanning...' : 'Scan image'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _isCheckingStream ? null : _checkStreamAttendance,
              icon: _isCheckingStream
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.videocam_rounded),
              label: Text(
                _isCheckingStream
                    ? 'Checking camera...'
                    : 'Check attendance from camera',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _backendController,
              decoration: const InputDecoration(
                labelText: 'Python backend URL',
                prefixIcon: Icon(Icons.link_outlined),
              ),
            ),
            const SizedBox(height: 18),
            _AttendanceStudentsList(students: students),
            const SizedBox(height: 18),
            _AttendanceRecordsList(records: _records),
          ],
        ),
      ),
    );
  }
}

class _AttendanceSummaryCard extends StatelessWidget {
  const _AttendanceSummaryCard({
    required this.isLoading,
    required this.status,
    required this.message,
  });

  final bool isLoading;
  final Map<String, dynamic>? status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final consent = status?['biometric_consent_enabled'] == true;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FBF6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8EBDD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, color: primary, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isLoading ? 'Checking attendance backend...' : 'Attendance',
                  style: const TextStyle(
                    color: Color(0xFF123D22),
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Students: ${status?['student_count'] ?? 0}  |  Images: ${status?['image_count'] ?? 0}',
            style: const TextStyle(
              color: Color(0xFF123D22),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            consent
                ? 'Image matching is enabled for this local prototype.'
                : 'Image matching is disabled until consent is enabled on the backend.',
            style: TextStyle(
              color: consent
                  ? const Color(0xFF16833B)
                  : const Color(0xFFB3261E),
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(message!, style: const TextStyle(color: Color(0xFF52685A))),
          ],
        ],
      ),
    );
  }
}

class _StudentAttendanceSummary extends StatelessWidget {
  const _StudentAttendanceSummary({
    required this.isLoading,
    required this.message,
    required this.rows,
    required this.onRefresh,
  });

  final bool isLoading;
  final String? message;
  final List<dynamic> rows;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final present = rows.where((row) {
      final map = _advanceMap(row);
      return map['status'] == 'present';
    }).length;
    final absent = rows.where((row) {
      final map = _advanceMap(row);
      return map['status'] == 'absent';
    }).length;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FBF6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8EBDD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.fact_check_outlined,
                color: Color(0xFF16833B),
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isLoading ? 'Loading attendance...' : 'My attendance',
                  style: const TextStyle(
                    color: Color(0xFF123D22),
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              IconButton(
                onPressed: isLoading ? null : onRefresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Present: $present  |  Absent: $absent',
            style: const TextStyle(
              color: Color(0xFF123D22),
              fontWeight: FontWeight.w800,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(message!, style: const TextStyle(color: Color(0xFF52685A))),
          ],
        ],
      ),
    );
  }
}

class _StudentAttendanceCalendar extends StatelessWidget {
  const _StudentAttendanceCalendar({required this.rows});

  final List<dynamic> rows;

  @override
  Widget build(BuildContext context) {
    return _AttendanceSection(
      title: 'Calendar',
      emptyText: 'No attendance calendar available yet.',
      children: [
        for (final item in rows)
          Builder(
            builder: (context) {
              final row = _advanceMap(item);
              final status = row['status']?.toString() ?? 'no_record';
              final color = status == 'present'
                  ? const Color(0xFF16833B)
                  : status == 'absent'
                  ? const Color(0xFFB3261E)
                  : const Color(0xFF7A5A00);
              return ListTile(
                leading: Icon(
                  status == 'present'
                      ? Icons.check_circle_outline_rounded
                      : status == 'absent'
                      ? Icons.cancel_outlined
                      : Icons.radio_button_unchecked_rounded,
                  color: color,
                ),
                title: Text(row['date']?.toString() ?? ''),
                subtitle: Text(row['timestamp']?.toString() ?? ''),
                trailing: Text(
                  status.replaceAll('_', ' ').toUpperCase(),
                  style: TextStyle(color: color, fontWeight: FontWeight.w800),
                ),
                dense: true,
              );
            },
          ),
      ],
    );
  }
}

class _AttendanceStudentsList extends StatelessWidget {
  const _AttendanceStudentsList({required this.students});

  final List<dynamic> students;

  @override
  Widget build(BuildContext context) {
    return _AttendanceSection(
      title: 'Students',
      emptyText: 'No embeddings yet. Tap Build embeddings.',
      children: [
        for (final student in students)
          ListTile(
            leading: const Icon(Icons.person_outline_rounded),
            title: Text(student['name']?.toString() ?? 'Student'),
            subtitle: Text('${student['image_count'] ?? 0} image(s)'),
            dense: true,
          ),
      ],
    );
  }
}

class _AttendanceRecordsList extends StatelessWidget {
  const _AttendanceRecordsList({required this.records});

  final List<dynamic> records;

  @override
  Widget build(BuildContext context) {
    return _AttendanceSection(
      title: 'Records',
      emptyText: 'No attendance marked yet.',
      children: [
        for (final record in records.reversed.take(20))
          ListTile(
            leading: const Icon(Icons.check_circle_outline_rounded),
            title: Text(record['name']?.toString() ?? 'Student'),
            subtitle: Text(record['timestamp']?.toString() ?? ''),
            trailing: Text(
              record['confidence'] == null
                  ? record['method']?.toString() ?? ''
                  : '${((record['confidence'] as num) * 100).toStringAsFixed(1)}%',
            ),
            dense: true,
          ),
      ],
    );
  }
}

class _AttendanceSection extends StatelessWidget {
  const _AttendanceSection({
    required this.title,
    required this.emptyText,
    required this.children,
  });

  final String title;
  final String emptyText;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8EBDD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFF123D22),
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                emptyText,
                style: const TextStyle(color: Color(0xFF5D7465)),
              ),
            )
          else
            ...children,
        ],
      ),
    );
  }
}

class AdvanceSysScreen extends StatefulWidget {
  const AdvanceSysScreen({super.key});

  static const routeName = '/advance-sys';

  @override
  State<AdvanceSysScreen> createState() => _AdvanceSysScreenState();
}

class _AdvanceSysScreenState extends State<AdvanceSysScreen> {
  final _backendController = TextEditingController(
    text: AttendanceApiClient.defaultBaseUrl,
  );
  Timer? _pollTimer;
  Map<String, dynamic>? _status;
  List<dynamic> _events = [];
  String? _message;
  bool _isLoading = false;
  bool _isStarting = false;
  bool _isStopping = false;
  bool _isClearing = false;

  AttendanceApiClient get _client =>
      AttendanceApiClient(_backendController.text.trim());

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refresh(quiet: true)),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _backendController.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _isLoading = true;
        _message = null;
      });
    }

    try {
      final status = await _client.advanceSysStatus();
      final events = await _client.advanceSysEvents();
      if (!mounted) {
        return;
      }

      setState(() {
        _status = status;
        _events = events;
      });
    } catch (error) {
      if (mounted && !quiet) {
        setState(() => _message = 'Advance Sys backend error: $error');
      }
    } finally {
      if (mounted && !quiet) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _start() async {
    setState(() {
      _isStarting = true;
      _message = null;
    });

    try {
      final status = await _client.advanceSysStart();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = status;
        _message = 'Advance Sys monitoring started.';
      });
      await _refresh(quiet: true);
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Could not start Advance Sys: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isStarting = false);
      }
    }
  }

  Future<void> _stop() async {
    setState(() {
      _isStopping = true;
      _message = null;
    });

    try {
      final status = await _client.advanceSysStop();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = status;
        _message = 'Advance Sys monitoring stopped.';
      });
      await _refresh(quiet: true);
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Could not stop Advance Sys: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isStopping = false);
      }
    }
  }

  Future<void> _clear() async {
    setState(() {
      _isClearing = true;
      _message = null;
    });

    try {
      final events = await _client.advanceSysClearEvents();
      if (!mounted) {
        return;
      }
      setState(() {
        _events = events;
        _message = 'Advance Sys events cleared.';
      });
      await _refresh(quiet: true);
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Could not clear events: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isClearing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _status?['running'] == true;

    return AppShell(
      title: 'Advance Sys',
      selectedRoute: AdvanceSysScreen.routeName,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AdvanceSysStatusCard(
              backendController: _backendController,
              status: _status,
              message: _message,
              isLoading: _isLoading,
              isStarting: _isStarting,
              isStopping: _isStopping,
              isClearing: _isClearing,
              onRefresh: _refresh,
              onStart: running ? null : _start,
              onStop: running ? _stop : null,
              onClear: _clear,
            ),
            const SizedBox(height: 18),
            _AdvanceSysEventsList(client: _client, events: _events),
          ],
        ),
      ),
    );
  }
}

class _AdvanceSysStatusCard extends StatelessWidget {
  const _AdvanceSysStatusCard({
    required this.backendController,
    required this.status,
    required this.message,
    required this.isLoading,
    required this.isStarting,
    required this.isStopping,
    required this.isClearing,
    required this.onRefresh,
    required this.onStart,
    required this.onStop,
    required this.onClear,
  });

  final TextEditingController backendController;
  final Map<String, dynamic>? status;
  final String? message;
  final bool isLoading;
  final bool isStarting;
  final bool isStopping;
  final bool isClearing;
  final Future<void> Function({bool quiet}) onRefresh;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final running = status?['running'] == true;
    final azure = _advanceMap(status?['azure']);
    final azureReady = azure['ready'] == true;
    final lastEvent = _formatAdvanceTimestamp(status?['last_event_at']);
    final lastMotion = _formatAdvanceTimestamp(status?['last_motion_at']);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FBF6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8EBDD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.motion_photos_on_outlined, color: primary, size: 34),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Advance Sys',
                  style: TextStyle(
                    color: Color(0xFF123D22),
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _AdvanceSysPill(
                label: running ? 'Monitoring' : 'Stopped',
                color: running
                    ? const Color(0xFF16833B)
                    : const Color(0xFF7A5A00),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _AdvanceSysMetric(
                icon: Icons.auto_awesome_outlined,
                label: 'Azure',
                value: azureReady ? 'Ready' : 'Needs config',
              ),
              _AdvanceSysMetric(
                icon: Icons.photo_library_outlined,
                label: 'Events',
                value: '${status?['event_count'] ?? 0}',
              ),
              _AdvanceSysMetric(
                icon: Icons.schedule_outlined,
                label: 'Last event',
                value: lastEvent,
              ),
              _AdvanceSysMetric(
                icon: Icons.sensors_outlined,
                label: 'Last motion',
                value: lastMotion,
              ),
            ],
          ),
          if (status?['last_error'] != null) ...[
            const SizedBox(height: 12),
            Text(
              status!['last_error'].toString(),
              style: const TextStyle(color: Color(0xFFB3261E)),
            ),
          ],
          if (!azureReady) ...[
            const SizedBox(height: 12),
            Text(
              azure['message']?.toString() ?? 'Azure OpenAI is not ready.',
              style: const TextStyle(color: Color(0xFF7A5A00)),
            ),
          ],
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(message!, style: const TextStyle(color: Color(0xFF52685A))),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 170,
                child: ElevatedButton.icon(
                  onPressed: isStarting ? null : onStart,
                  icon: isStarting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(isStarting ? 'Starting...' : 'Start'),
                ),
              ),
              SizedBox(
                width: 170,
                child: OutlinedButton.icon(
                  onPressed: isStopping ? null : onStop,
                  icon: isStopping
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.stop_rounded),
                  label: Text(isStopping ? 'Stopping...' : 'Stop'),
                ),
              ),
              SizedBox(
                width: 170,
                child: OutlinedButton.icon(
                  onPressed: isLoading ? null : () => onRefresh(),
                  icon: isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                  label: Text(isLoading ? 'Refreshing...' : 'Refresh'),
                ),
              ),
              SizedBox(
                width: 170,
                child: OutlinedButton.icon(
                  onPressed: isClearing ? null : onClear,
                  icon: isClearing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline_rounded),
                  label: Text(isClearing ? 'Clearing...' : 'Clear All'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: backendController,
            decoration: const InputDecoration(
              labelText: 'Python backend URL',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdvanceSysMetric extends StatelessWidget {
  const _AdvanceSysMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 158,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD8EBDD)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF16833B), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF5D7465),
                    fontSize: 12,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF123D22),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdvanceSysEventsList extends StatelessWidget {
  const _AdvanceSysEventsList({required this.client, required this.events});

  final AttendanceApiClient client;
  final List<dynamic> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFD8EBDD)),
        ),
        child: const Text(
          'No motion events yet. Start monitoring and walk in front of the camera.',
          style: TextStyle(color: Color(0xFF5D7465)),
        ),
      );
    }

    final ordered = events.reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Motion Events',
          style: TextStyle(
            color: Color(0xFF123D22),
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 10),
        for (final event in ordered) ...[
          _AdvanceSysEventCard(client: client, event: _advanceMap(event)),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _AdvanceSysEventCard extends StatelessWidget {
  const _AdvanceSysEventCard({required this.client, required this.event});

  final AttendanceApiClient client;
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final eventId = event['event_id']?.toString() ?? '';
    final frameCount = _advanceInt(event['frame_count'], fallback: 4);
    final analysisStatus = event['analysis_status']?.toString() ?? 'unknown';
    final confidence = _formatAdvanceConfidence(event['confidence']);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8EBDD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.sensors_rounded,
                color: Color(0xFF16833B),
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event['scene_title']?.toString() ?? 'Motion detected',
                      style: const TextStyle(
                        color: Color(0xFF123D22),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      _formatAdvanceTimestamp(event['timestamp']),
                      style: const TextStyle(color: Color(0xFF5D7465)),
                    ),
                  ],
                ),
              ),
              _AdvanceSysPill(
                label: analysisStatus,
                color: analysisStatus == 'ok'
                    ? const Color(0xFF16833B)
                    : const Color(0xFF7A5A00),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            event['summary']?.toString().trim().isNotEmpty == true
                ? event['summary'].toString()
                : 'No scene summary available.',
            style: const TextStyle(color: Color(0xFF24382B), height: 1.35),
          ),
          const SizedBox(height: 12),
          _AdvanceSysDetailRow(
            icon: Icons.group_outlined,
            label: 'Subjects',
            value: event['visible_subjects']?.toString() ?? 'Not visible',
          ),
          _AdvanceSysDetailRow(
            icon: Icons.shopping_bag_outlined,
            label: 'Objects',
            value: event['visible_objects']?.toString() ?? 'Nothing visible',
          ),
          _AdvanceSysDetailRow(
            icon: Icons.directions_walk_outlined,
            label: 'Action',
            value: event['visible_action']?.toString() ?? 'Motion detected',
          ),
          _AdvanceSysDetailRow(
            icon: Icons.place_outlined,
            label: 'Location',
            value: event['location_hint']?.toString() ?? 'Not visible',
          ),
          _AdvanceSysDetailRow(
            icon: Icons.verified_user_outlined,
            label: 'Confidence',
            value: 'Azure $confidence',
          ),
          if (event['analysis_error'] != null) ...[
            const SizedBox(height: 8),
            Text(
              event['analysis_error'].toString(),
              style: const TextStyle(color: Color(0xFFB3261E)),
            ),
          ],
          const SizedBox(height: 12),
          _AdvanceSysFrameGrid(
            urls: [
              for (var index = 1; index <= frameCount; index++)
                client.advanceSysFrameUrl(eventId, index),
            ],
          ),
        ],
      ),
    );
  }
}

class _AdvanceSysDetailRow extends StatelessWidget {
  const _AdvanceSysDetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF52685A), size: 20),
          const SizedBox(width: 8),
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF5D7465),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.trim().isEmpty ? 'Not available' : value,
              style: const TextStyle(color: Color(0xFF24382B)),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdvanceSysFrameGrid extends StatefulWidget {
  const _AdvanceSysFrameGrid({required this.urls});

  final List<String> urls;

  @override
  State<_AdvanceSysFrameGrid> createState() => _AdvanceSysFrameGridState();
}

class _AdvanceSysFrameGridState extends State<_AdvanceSysFrameGrid> {
  Map<String, String> _headers = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadHeaders());
  }

  Future<void> _loadHeaders() async {
    final headers = await _firebaseAuthHeaderMap();
    if (mounted) {
      setState(() => _headers = headers);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 560 ? 4 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.urls.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 16 / 9,
          ),
          itemBuilder: (context, index) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: Colors.black,
                child: Image.network(
                  widget.urls[index],
                  headers: _headers.isEmpty ? null : _headers,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                      ),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _AdvanceSysPill extends StatelessWidget {
  const _AdvanceSysPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

Map<String, dynamic> _advanceMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return [
      for (final item in value)
        if (item != null) item.toString(),
    ];
  }
  return const [];
}

int _advanceInt(Object? value, {required int fallback}) {
  if (value is num) {
    return value.toInt();
  }
  return fallback;
}

String _formatAdvanceTimestamp(Object? value) {
  final text = value?.toString() ?? '';
  if (text.isEmpty) {
    return 'None';
  }

  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    return text;
  }

  final local = parsed.toLocal();
  return '${local.year}-${_advanceTwo(local.month)}-${_advanceTwo(local.day)} '
      '${_advanceTwo(local.hour)}:${_advanceTwo(local.minute)}';
}

String _formatAdvanceConfidence(Object? value) {
  if (value is num) {
    final normalized = value <= 1 ? value * 100 : value;
    return '${normalized.toStringAsFixed(1)}%';
  }
  final text = value?.toString() ?? '';
  return text.isEmpty ? 'n/a' : text;
}

String _advanceTwo(int value) => value.toString().padLeft(2, '0');

class RagScreen extends StatefulWidget {
  const RagScreen({super.key});

  static const routeName = '/rag';

  @override
  State<RagScreen> createState() => _RagScreenState();
}

enum RagDomain { general, medical, engineering }

extension RagDomainDetails on RagDomain {
  String get label {
    switch (this) {
      case RagDomain.medical:
        return 'Medical';
      case RagDomain.engineering:
        return 'Engineering';
      case RagDomain.general:
        return 'General';
    }
  }

  String get apiValue => name;

  IconData get icon {
    switch (this) {
      case RagDomain.medical:
        return Icons.medical_services_outlined;
      case RagDomain.engineering:
        return Icons.engineering_outlined;
      case RagDomain.general:
        return Icons.school_outlined;
    }
  }

  String get qwenInstruction {
    switch (this) {
      case RagDomain.medical:
        return 'Medical mode: answer only educational medical questions. Do not provide diagnosis, prescription, dosage, or emergency advice.';
      case RagDomain.engineering:
        return 'Engineering mode: answer only engineering, technology, math, and technical study questions.';
      case RagDomain.general:
        return 'General study mode: answer student questions clearly and concisely.';
    }
  }
}

class _RagScreenState extends State<RagScreen> {
  static const _filePickerChannel = MethodChannel('edge/file_picker');

  final _backendController = TextEditingController(
    text: RagApiClient.defaultBaseUrl,
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
  RagDomain _selectedDomain = RagDomain.general;

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

    final domainBlock = _domainBlockMessage(question);
    if (domainBlock != null) {
      setState(() {
        _messages.add(RagMessage(text: domainBlock, isUser: false));
        _isSending = false;
      });
      return;
    }

    try {
      final context = _offlineContext(question);
      try {
        if (_useOfflineQwen && await _offlineQwen.isReady()) {
          final answer = context.isNotEmpty
              ? await _offlineQwen.answer(
                  question: question,
                  context: context,
                  domainLabel: _selectedDomain.label,
                  domainInstruction: _selectedDomain.qwenInstruction,
                )
              : await _offlineQwen.chat(
                  question,
                  domainLabel: _selectedDomain.label,
                  domainInstruction: _selectedDomain.qwenInstruction,
                );

          setState(() {
            _messages.add(
              RagMessage(
                text: answer,
                isUser: false,
                sources: context.isEmpty
                    ? const []
                    : _offlineSourceIds(question),
              ),
            );
          });
          return;
        }
      } catch (error) {
        offlineQwenError = error;
        // Continue to backend or extractive local fallback.
      }

      final fastLocalAnswer = _offlineAnswer(question);
      if (fastLocalAnswer != null && !_useOfflineQwen) {
        setState(() {
          _messages.add(
            RagMessage(
              text: fastLocalAnswer,
              isUser: false,
              sources: _offlineSourceIds(question),
            ),
          );
        });
        return;
      }

      if (fastLocalAnswer != null && offlineQwenError != null) {
        setState(() {
          _messages.add(
            RagMessage(
              text: fastLocalAnswer,
              isUser: false,
              sources: _offlineSourceIds(question),
            ),
          );
        });
        return;
      }

      final answer = await _client.ask(
        question,
        domain: _selectedDomain.apiValue,
      );

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
                : _offlineSourceIds(question),
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
      parts.add(
        'No local Rag document is loaded yet. Tap the paperclip to add a file.',
      );
    }

    parts.add('Backend detail: $backendError');
    return parts.join('\n\n');
  }

  bool _isGreeting(String question) {
    final clean = question
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z ]'), '')
        .trim();
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
        final localText = _decodeOfflineFile(file.name, file.bytes);
        setState(() => _isUploadingFile = true);

        try {
          final ids = await _client.ingestFile(
            file,
            domain: _selectedDomain.apiValue,
          );
          _addOfflineDocument(file.name, localText);

          if (!mounted) {
            return;
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Uploaded ${ids.length} document chunk(s).'),
            ),
          );
        } catch (_) {
          if (!mounted) {
            return;
          }

          if (localText.trim().isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Could not extract this file locally. Start the Python backend for PDF/OCR files.',
                ),
              ),
            );
          } else {
            _addOfflineDocument(file.name, localText);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Document added locally to ${_selectedDomain.label}.',
                ),
              ),
            );
          }
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
    _offlineDocuments.add(
      OfflineRagDocument(id: id, text: cleanText, domain: _selectedDomain),
    );
  }

  String? _offlineAnswer(String question) {
    final documents = _documentsForQuestion(question).toList();
    if (documents.isEmpty) {
      return null;
    }

    final queryTokens = _ragTokens(question);
    final scoredLines = <ScoredLine>[];

    for (final document in documents) {
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
    final documents = _documentsForQuestion(question).toList();
    if (documents.isEmpty) {
      return '';
    }

    final queryTokens = _ragTokens(question);
    final scoredLines = <ScoredLine>[];

    for (final document in documents) {
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

  Iterable<OfflineRagDocument> _documentsForQuestion(String question) {
    final inferred = _inferRagDomain(question);

    return _offlineDocuments.where((document) {
      if (_selectedDomain != RagDomain.general) {
        return document.domain == _selectedDomain ||
            document.domain == RagDomain.general;
      }

      if (inferred != null) {
        return document.domain == inferred ||
            document.domain == RagDomain.general;
      }

      return true;
    });
  }

  List<String> _offlineSourceIds(String question) {
    final seen = <String>{};

    return [
      for (final document in _documentsForQuestion(question))
        if (seen.add('${document.id}-${document.domain.name}'))
          '${document.id} (${document.domain.label})',
    ];
  }

  String? _domainBlockMessage(String question) {
    if (_selectedDomain == RagDomain.general || _isGreeting(question)) {
      return null;
    }

    final inferred = _inferRagDomain(question);
    if (inferred == null || inferred == _selectedDomain) {
      return null;
    }

    return 'This Rag workspace is set to ${_selectedDomain.label}. I cannot answer ${inferred.label.toLowerCase()} questions here. Switch the domain to ${inferred.label} or General to ask this.';
  }

  String _decodeOfflineFile(String name, Uint8List bytes) {
    final lowerName = name.toLowerCase();
    final isPdf =
        lowerName.endsWith('.pdf') ||
        (bytes.length >= 4 &&
            bytes[0] == 0x25 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x44 &&
            bytes[3] == 0x46);

    if (isPdf) {
      return '';
    }

    try {
      final decoded = utf8.decode(bytes, allowMalformed: false);
      return _isMostlyReadableText(decoded) ? decoded : '';
    } catch (_) {
      final decoded = latin1.decode(bytes);
      return _isMostlyReadableText(decoded) ? decoded : '';
    }
  }

  bool _isMostlyReadableText(String text) {
    if (text.trim().isEmpty) {
      return false;
    }

    final sample = text.length > 4000 ? text.substring(0, 4000) : text;
    var printable = 0;
    var suspicious = 0;

    for (final unit in sample.codeUnits) {
      final isWhitespace = unit == 9 || unit == 10 || unit == 13 || unit == 32;
      final isAsciiPrintable = unit >= 32 && unit <= 126;
      final isLatinText = unit >= 160 && unit <= 591;

      if (isWhitespace || isAsciiPrintable || isLatinText) {
        printable++;
      } else {
        suspicious++;
      }
    }

    return printable >= 40 && suspicious / sample.length < 0.08;
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Rag',
      selectedRoute: RagScreen.routeName,
      bodyPadding: EdgeInsets.zero,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: PopupMenuButton<RagDomain>(
            initialValue: _selectedDomain,
            onSelected: (domain) => setState(() => _selectedDomain = domain),
            itemBuilder: (context) => [
              for (final domain in RagDomain.values)
                PopupMenuItem(
                  value: domain,
                  child: Row(
                    children: [
                      Icon(domain.icon, size: 18),
                      const SizedBox(width: 10),
                      Text(domain.label),
                    ],
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_selectedDomain.icon, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    _selectedDomain.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
              separatorBuilder: (_, index) => const SizedBox(height: 10),
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

Future<String?> _firebaseIdToken() async {
  try {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    return token == null || token.isEmpty ? null : token;
  } catch (_) {
    // Firebase is not configured yet or the user is signed out.
    return null;
  }
}

Future<Map<String, String>> _firebaseAuthHeaderMap() async {
  final token = await _firebaseIdToken();
  if (token == null) {
    return const {};
  }
  return {HttpHeaders.authorizationHeader: 'Bearer $token'};
}

Future<void> _addFirebaseAuthHeader(HttpHeaders headers) async {
  final token = await _firebaseIdToken();
  if (token != null) {
    headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
}

class AttendanceApiClient {
  AttendanceApiClient(this.baseUrl);

  static const defaultBaseUrl = 'http://192.168.1.6:8000';

  final String baseUrl;

  Future<Map<String, dynamic>> status() async {
    return _get('/attendance/status');
  }

  Future<Map<String, dynamic>> buildEmbeddings() async {
    return _post('/attendance/build-embeddings', {});
  }

  Future<List<dynamic>> records() async {
    final payload = await _get('/attendance/records');
    final records = payload['records'];
    return records is List ? records : const [];
  }

  Future<List<dynamic>> myAttendanceCalendar() async {
    final payload = await _get('/attendance/me/calendar');
    final rows = payload['calendar'];
    return rows is List ? rows : const [];
  }

  Future<Map<String, dynamic>> setStreamConfig(String rtspUrl) async {
    return _post('/attendance/stream/config', {'rtsp_url': rtspUrl});
  }

  Future<Map<String, dynamic>> checkStream() async {
    return _post('/attendance/stream/check', {});
  }

  Future<Map<String, dynamic>> advanceSysStatus() async {
    return _get('/advance-sys/status');
  }

  Future<Map<String, dynamic>> advanceSysStart() async {
    return _post('/advance-sys/start', {});
  }

  Future<Map<String, dynamic>> advanceSysStop() async {
    return _post('/advance-sys/stop', {});
  }

  Future<List<dynamic>> advanceSysEvents() async {
    final payload = await _get('/advance-sys/events');
    final events = payload['events'];
    return events is List ? events : const [];
  }

  Future<List<dynamic>> advanceSysClearEvents() async {
    final payload = await _delete('/advance-sys/events');
    final events = payload['events'];
    return events is List ? events : const [];
  }

  String advanceSysFrameUrl(String eventId, int frameIndex) {
    final base = _candidateBaseUrls().first;
    final encodedId = Uri.encodeComponent(eventId);
    return '$base/advance-sys/events/$encodedId/frames/$frameIndex';
  }

  String streamFrameUrl(int tick) {
    final base = _candidateBaseUrls().first;
    return '$base/attendance/stream/frame?t=$tick';
  }

  Future<Map<String, dynamic>> createAttendanceStudent({
    required String name,
    required String studentId,
    required List<PickedRagFile> images,
    required List<String> imageUrls,
  }) async {
    final boundary =
        'edge-new-student-${DateTime.now().microsecondsSinceEpoch}';
    Object? lastError;

    for (final candidate in _candidateBaseUrls()) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final uri = Uri.parse('$candidate/admin/students/attendance');

      try {
        final request = await client
            .postUrl(uri)
            .timeout(const Duration(seconds: 3));
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary',
        );
        await _addFirebaseAuthHeader(request.headers);
        _addMultipartField(request, boundary, 'name', name);
        _addMultipartField(request, boundary, 'student_id', studentId);
        _addMultipartField(
          request,
          boundary,
          'image_urls',
          jsonEncode(imageUrls),
        );
        for (final image in images) {
          request.add(utf8.encode('--$boundary\r\n'));
          request.add(
            utf8.encode(
              'Content-Disposition: form-data; name="files"; filename="${image.name}"\r\n',
            ),
          );
          request.add(
            utf8.encode(
              'Content-Type: ${_verificationContentType(image.name)}\r\n\r\n',
            ),
          );
          request.add(image.bytes);
          request.add(utf8.encode('\r\n'));
        }
        request.add(utf8.encode('--$boundary--\r\n'));

        final response = await request.close().timeout(
          const Duration(seconds: 60),
        );
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

    throw Exception(
      'Attendance backend is not running at $defaultBaseUrl. Last error: $lastError',
    );
  }

  Future<Map<String, dynamic>> approveStudent(String uid) {
    return _post('/admin/students/${Uri.encodeComponent(uid)}/approve', {});
  }

  Future<Map<String, dynamic>> rejectStudent(String uid, String reason) {
    return _post('/admin/students/${Uri.encodeComponent(uid)}/reject', {
      'reason': reason,
    });
  }

  Future<Map<String, dynamic>> matchFile(PickedRagFile file) async {
    final boundary = 'edge-attendance-${DateTime.now().microsecondsSinceEpoch}';
    Object? lastError;

    for (final candidate in _candidateBaseUrls()) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final uri = Uri.parse('$candidate/attendance/match-file');

      try {
        final request = await client
            .postUrl(uri)
            .timeout(const Duration(seconds: 3));
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary',
        );
        await _addFirebaseAuthHeader(request.headers);
        request.add(utf8.encode('--$boundary\r\n'));
        request.add(
          utf8.encode(
            'Content-Disposition: form-data; name="file"; filename="${file.name}"\r\n',
          ),
        );
        request.add(utf8.encode('Content-Type: image/jpeg\r\n\r\n'));
        request.add(file.bytes);
        request.add(utf8.encode('\r\n--$boundary--\r\n'));

        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
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

    throw Exception(
      'Attendance backend is not running at $defaultBaseUrl. Start it once using install_attendance_backend_startup.ps1. Last error: $lastError',
    );
  }

  void _addMultipartField(
    HttpClientRequest request,
    String boundary,
    String name,
    String value,
  ) {
    request.add(utf8.encode('--$boundary\r\n'));
    request.add(
      utf8.encode('Content-Disposition: form-data; name="$name"\r\n\r\n'),
    );
    request.add(utf8.encode(value));
    request.add(utf8.encode('\r\n'));
  }

  Future<Map<String, dynamic>> _get(String path) async {
    Object? lastError;

    for (final candidate in _candidateBaseUrls()) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);

      try {
        final response = await client
            .getUrl(Uri.parse('$candidate$path'))
            .timeout(const Duration(seconds: 3))
            .then((request) async {
              await _addFirebaseAuthHeader(request.headers);
              return request.close();
            })
            .timeout(const Duration(seconds: 5));
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

    throw Exception(
      'Attendance backend is not running at $defaultBaseUrl. Last error: $lastError',
    );
  }

  Future<Map<String, dynamic>> _delete(String path) async {
    Object? lastError;

    for (final candidate in _candidateBaseUrls()) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);

      try {
        final response = await client
            .deleteUrl(Uri.parse('$candidate$path'))
            .timeout(const Duration(seconds: 3))
            .then((request) async {
              await _addFirebaseAuthHeader(request.headers);
              return request.close();
            })
            .timeout(const Duration(seconds: 10));
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

    throw Exception(
      'Attendance backend is not running at $defaultBaseUrl. Last error: $lastError',
    );
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object> body,
  ) async {
    Object? lastError;

    for (final candidate in _candidateBaseUrls()) {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);

      try {
        final request = await client
            .postUrl(Uri.parse('$candidate$path'))
            .timeout(const Duration(seconds: 3));
        request.headers.contentType = ContentType.json;
        await _addFirebaseAuthHeader(request.headers);
        request.write(jsonEncode(body));

        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
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

    throw Exception(
      'Attendance backend is not running at $defaultBaseUrl. Last error: $lastError',
    );
  }

  List<String> _candidateBaseUrls() {
    final typed = _usableBaseUrl(baseUrl);
    final urls = <String>[
      if (typed.isNotEmpty) typed,
      defaultBaseUrl,
      'http://10.0.2.2:8000',
      'http://127.0.0.1:8000',
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

    final isUnsupportedLocalHost =
        uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (isUnsupportedLocalHost) {
      return '';
    }

    return clean;
  }
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
    required String domainLabel,
    required String domainInstruction,
  }) async {
    return _generate(
      messages: [
        ChatMessage(
          role: 'system',
          content:
              'You are an offline $domainLabel RAG assistant for students. $domainInstruction Answer only from the supplied context. If the answer is not in the context, say you do not know.',
        ),
        ChatMessage(
          role: 'user',
          content: 'Context:\n$context\n\nQuestion:\n$question\n\nAnswer:',
        ),
      ],
      temperature: 0.1,
      maxTokens: 80,
    );
  }

  Future<String> chat(
    String question, {
    required String domainLabel,
    required String domainInstruction,
  }) async {
    return _generate(
      messages: [
        ChatMessage(
          role: 'system',
          content:
              'You are Qwen running offline inside the Edge Android app in $domainLabel mode. $domainInstruction Refuse questions outside this mode.',
        ),
        ChatMessage(role: 'user', content: question),
      ],
      temperature: 0.3,
      maxTokens: 90,
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
      topP: 0.8,
      topK: 20,
      minP: 0.05,
      repeatPenalty: 1.12,
      repeatLastN: 64,
      seed: DateTime.now().millisecondsSinceEpoch,
    );

    try {
      await for (final token in stream.timeout(
        const Duration(seconds: 45),
        onTimeout: (sink) {
          sink.addError(
            TimeoutException('Offline Qwen took too long to answer.'),
          );
          sink.close();
        },
      )) {
        buffer.write(token);
      }
    } on TimeoutException {
      unawaited(_controller.stop());
      rethrow;
    }

    final answer = _cleanGeneratedAnswer(buffer.toString());
    if (_looksLikeBadGeneration(answer)) {
      throw const FormatException('Offline Qwen returned unreadable text.');
    }

    return answer;
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
      await _controller
          .loadModel(
            modelPath: modelPath,
            threads: 4,
            contextSize: 512,
            gpuLayers: 0,
          )
          .timeout(const Duration(minutes: 3));
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

  int _asInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }

    return 0;
  }

  String _cleanGeneratedAnswer(String raw) {
    var text = raw
        .replaceAll('\u0000', '')
        .replaceAll('\uFFFD', '')
        .replaceAll('<|im_start|>', '')
        .replaceAll('<|im_end|>', '')
        .replaceAll('<|endoftext|>', '')
        .replaceAll(RegExp(r'<\|[^>]{1,48}\|>'), ' ')
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

    final lower = text.toLowerCase();
    final answerIndex = lower.lastIndexOf('answer:');
    if (answerIndex >= 0 && answerIndex < text.length - 7) {
      text = text.substring(answerIndex + 7);
    }

    return text.split('\n').map((line) => line.trimRight()).join('\n').trim();
  }

  bool _looksLikeBadGeneration(String text) {
    if (text.isEmpty || text.contains('\uFFFD')) {
      return true;
    }

    final sample = text.length > 1000 ? text.substring(0, 1000) : text;
    var lettersOrDigits = 0;
    var readable = 0;
    var suspicious = 0;

    for (final unit in sample.codeUnits) {
      final isLetterOrDigit =
          (unit >= 48 && unit <= 57) ||
          (unit >= 65 && unit <= 90) ||
          (unit >= 97 && unit <= 122);
      final isWhitespace = unit == 9 || unit == 10 || unit == 13 || unit == 32;
      final isPunctuation = '.,;:!?()[]{}\'"-/%'.codeUnits.contains(unit);

      if (isLetterOrDigit) {
        lettersOrDigits++;
      }

      if (isLetterOrDigit || isWhitespace || isPunctuation) {
        readable++;
      } else {
        suspicious++;
      }
    }

    if (sample.length > 16 && lettersOrDigits < 3) {
      return true;
    }

    if (sample.isNotEmpty && suspicious / sample.length > 0.18) {
      return true;
    }

    return RegExp(r'([^a-zA-Z0-9\s])\1{7,}').hasMatch(sample) || readable == 0;
  }
}

class OfflineRagDocument {
  const OfflineRagDocument({
    required this.id,
    required this.text,
    required this.domain,
  });

  final String id;
  final String text;
  final RagDomain domain;
}

class ScoredLine {
  const ScoredLine({required this.score, required this.text});

  final int score;
  final String text;
}

RagDomain? _inferRagDomain(String text) {
  final normalized = text.toLowerCase();
  final medicalScore = _domainKeywordScore(normalized, _medicalKeywords);
  final engineeringScore = _domainKeywordScore(
    normalized,
    _engineeringKeywords,
  );

  if (medicalScore == 0 && engineeringScore == 0) {
    return null;
  }

  if (medicalScore > engineeringScore) {
    return RagDomain.medical;
  }

  if (engineeringScore > medicalScore) {
    return RagDomain.engineering;
  }

  return null;
}

int _domainKeywordScore(String text, List<String> keywords) {
  var score = 0;

  for (final keyword in keywords) {
    final pattern = RegExp(
      '\\b${RegExp.escape(keyword.toLowerCase())}\\b',
      caseSensitive: false,
    );
    if (pattern.hasMatch(text)) {
      score++;
    }
  }

  return score;
}

const _medicalKeywords = [
  'anatomy',
  'bacteria',
  'blood',
  'cancer',
  'clinical',
  'diagnosis',
  'diabetes',
  'disease',
  'doctor',
  'dosage',
  'drug',
  'fever',
  'health',
  'heart',
  'hospital',
  'infection',
  'kidney',
  'liver',
  'medical',
  'medicine',
  'nursing',
  'pathology',
  'patient',
  'pharmacology',
  'physiology',
  'surgery',
  'symptom',
  'therapy',
  'treatment',
  'vaccine',
  'virus',
];

const _engineeringKeywords = [
  'algorithm',
  'beam',
  'bridge',
  'circuit',
  'civil',
  'coding',
  'compiler',
  'current',
  'database',
  'electrical',
  'electronics',
  'engineer',
  'engineering',
  'fluid',
  'gear',
  'machine',
  'mechanical',
  'mechanics',
  'microcontroller',
  'motor',
  'network',
  'ohm',
  'programming',
  'sensor',
  'software',
  'strain',
  'stress',
  'thermodynamics',
  'torque',
  'transistor',
  'voltage',
];

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

  static const defaultBaseUrl = 'http://192.168.1.6:8000';

  final String baseUrl;

  Future<List<String>> ingestText(
    String fileName,
    String text, {
    String domain = 'general',
  }) async {
    final payload = await _post('/rag/ingest-text', {
      'file_name': fileName,
      'text': text,
      'domain': domain,
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

  Future<List<String>> ingestFile(
    PickedRagFile file, {
    String domain = 'general',
  }) async {
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
        await _addFirebaseAuthHeader(request.headers);
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
        request.add(utf8.encode('\r\n--$boundary\r\n'));
        request.add(
          utf8.encode(
            'Content-Disposition: form-data; name="domain"\r\n\r\n$domain',
          ),
        );
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

  Future<RagAnswer> ask(String message, {String domain = 'general'}) async {
    final payload = await _post('/rag/chat', {
      'message': message,
      'domain': domain,
    });
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
        await _addFirebaseAuthHeader(request.headers);
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
      defaultBaseUrl,
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

class StudentApprovalsScreen extends StatefulWidget {
  const StudentApprovalsScreen({super.key});

  static const routeName = '/student-approvals';

  @override
  State<StudentApprovalsScreen> createState() => _StudentApprovalsScreenState();
}

class _StudentApprovalsScreenState extends State<StudentApprovalsScreen> {
  final _client = AttendanceApiClient(AttendanceApiClient.defaultBaseUrl);
  List<dynamic> _students = [];
  String? _message;
  bool _isLoading = false;
  String? _busyUid;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: 'student')
          .where('status', isEqualTo: 'pending')
          .get();
      final students = [
        for (final doc in snapshot.docs) {'uid': doc.id, ...doc.data()},
      ];
      students.sort(
        (left, right) => (left['displayName'] ?? '').toString().compareTo(
          (right['displayName'] ?? '').toString(),
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() => _students = students);
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Could not load approvals: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _approve(String uid) async {
    try {
      setState(() {
        _busyUid = uid;
        _message = null;
      });
      await _client.approveStudent(uid);
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Approve failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busyUid = null);
      }
    }
  }

  Future<void> _reject(String uid) async {
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Reject student'),
          content: TextField(
            controller: reasonController,
            decoration: const InputDecoration(labelText: 'Reason'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, reasonController.text.trim()),
              child: const Text('Reject'),
            ),
          ],
        );
      },
    );
    reasonController.dispose();

    if (reason == null) {
      return;
    }

    try {
      setState(() {
        _busyUid = uid;
        _message = null;
      });
      await _client.rejectStudent(uid, reason);
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Reject failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busyUid = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!SessionScope.of(context).isAdmin) {
      return const RagScreen();
    }

    return AppShell(
      title: 'Student Approvals',
      selectedRoute: StudentApprovalsScreen.routeName,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFFF4FBF6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFD8EBDD)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.verified_user_outlined,
                    color: Color(0xFF16833B),
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Pending student verification',
                      style: TextStyle(
                        color: Color(0xFF123D22),
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _isLoading ? null : _refresh,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: const TextStyle(color: Color(0xFFB3261E))),
            ],
            const SizedBox(height: 14),
            if (_students.isEmpty)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFD8EBDD)),
                ),
                child: const Text(
                  'No pending students.',
                  style: TextStyle(color: Color(0xFF5D7465)),
                ),
              )
            else
              for (final student in _students) ...[
                _PendingStudentCard(
                  student: _advanceMap(student),
                  isBusy: _busyUid == _advanceMap(student)['uid']?.toString(),
                  onApprove: () =>
                      _approve(_advanceMap(student)['uid']?.toString() ?? ''),
                  onReject: () =>
                      _reject(_advanceMap(student)['uid']?.toString() ?? ''),
                ),
                const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    );
  }
}

class _PendingStudentCard extends StatelessWidget {
  const _PendingStudentCard({
    required this.student,
    required this.isBusy,
    required this.onApprove,
    required this.onReject,
  });

  final Map<String, dynamic> student;
  final bool isBusy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final imageUrls = _stringList(student['attendanceImageUrls']);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8EBDD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            student['displayName']?.toString() ?? 'Student',
            style: const TextStyle(
              color: Color(0xFF123D22),
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${student['email'] ?? ''}  |  Student ID: ${student['studentId'] ?? ''}',
            style: const TextStyle(color: Color(0xFF5D7465)),
          ),
          const SizedBox(height: 12),
          if (imageUrls.isEmpty)
            const Text(
              'No attendance photos submitted.',
              style: TextStyle(color: Color(0xFF52685A)),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1.15,
              ),
              itemCount: imageUrls.length,
              itemBuilder: (context, index) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(imageUrls[index], fit: BoxFit.cover),
                );
              },
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isBusy ? null : onApprove,
                  icon: isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: const Text('Approve + Embed'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isBusy ? null : onReject,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Reject'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
    final session = SessionScope.of(context);
    final profile = session.profile;
    final isAdmin = profile?.isAdmin == true;

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
            if (isAdmin)
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
            if (isAdmin)
              DrawerMenuItem(
                icon: Icons.person_add_alt_1_outlined,
                label: 'New Student',
                routeName: NewStudentScreen.routeName,
                selectedRoute: selectedRoute,
              ),
            if (isAdmin)
              DrawerMenuItem(
                icon: Icons.motion_photos_on_outlined,
                label: 'Advance Sys',
                routeName: AdvanceSysScreen.routeName,
                selectedRoute: selectedRoute,
              ),
            if (isAdmin)
              DrawerMenuItem(
                icon: Icons.verified_user_outlined,
                label: 'Approvals',
                routeName: StudentApprovalsScreen.routeName,
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
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton.icon(
                onPressed: () => FirebaseAuth.instance.signOut(),
                icon: const Icon(Icons.logout_rounded),
                label: Text(
                  profile?.email.isNotEmpty == true ? 'Sign out' : 'Sign out',
                ),
              ),
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
