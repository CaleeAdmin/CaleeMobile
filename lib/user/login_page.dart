import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/controllers/app_controller.dart';
import 'package:caleesync/controllers/auth_controller.dart';
import 'package:caleesync/models/auth_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Login page with Nextcloud Login Flow v2 integration.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _agree = false;
  bool _isSubmittingLogin = false;
  Worker? _authStateWorker;
  late final Future<String> _appVersionLabelFuture;

  @override
  void dispose() {
    _authStateWorker?.dispose();
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _appVersionLabelFuture = _loadAppVersionLabel();

    // 获取AuthController实例
    final authController = Get.find<AuthController>();

    // 监听认证状态变化
    _authStateWorker = ever(authController.authStateRx, (AuthState state) {
      // 检查页面是否还挂载
      if (!mounted) return;

      if (state.isAuthenticated) {
        if (_isSubmittingLogin) {
          setState(() {
            _isSubmittingLogin = false;
          });
        }
        // 登录成功
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Login success'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        _saveCredentialsAndNavigate(state);
      }

      if (state.hasError && state.status == AuthStatus.error) {
        if (_isSubmittingLogin) {
          setState(() {
            _isSubmittingLogin = false;
          });
        }
        // 显示登录失败Error信息
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(state.errorMessage ?? 'Login failed'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
  }

  Future<String> _loadAppVersionLabel() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return 'Version ${packageInfo.version} (${packageInfo.buildNumber})';
  }

  /// 保存登录凭据并跳转到主页
  Future<void> _saveCredentialsAndNavigate(AuthState state) async {
    if (state.serverUrl == null ||
        state.loginName == null ||
        state.appPassword == null) {
      return;
    }

    try {
      // 保存登录凭据到 MMKV
      MMKVUtils.instance.setString(AppConstant.serverKey, state.serverUrl!);
      MMKVUtils.instance.setString(AppConstant.loginNameKey, state.loginName!);
      MMKVUtils.instance.setString(AppConstant.appPasswordKey, state.appPassword!);

      // 使用GetX的AppController处理登录成功
      final appController = Get.find<AppController>();
      appController.onLoginSuccess();
    } catch (e) {
      // 如果保存失败，显示Error信息
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save user data: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _onLogin() {
    if (!_formKey.currentState!.validate()) return;
    if (!_agree) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please accept the terms to continue')),
      );
      return;
    }

    if (_isSubmittingLogin) {
      return;
    }

    // 使用用户名密码登录
    final loginName = _accountController.text.trim();
    final password = _passwordController.text.trim();

    final authController = Get.find<AuthController>();
    setState(() {
      _isSubmittingLogin = true;
    });
    authController.loginWithCredentials(
      loginName: loginName,
      password: password,
    );
  }

  Future<void> _openTermsAndConditionsPage() async {
    final termsUri = Uri.https(
      AppConstant.caleeServer,
      '/terms-and-conditions',
    );

    final opened = await launchUrl(
      termsUri,
      mode: LaunchMode.platformDefault,
    );

    if (opened) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open terms and conditions page in browser'),
      ),
    );
  }

  Future<void> _openForgotPasswordPage() async {
    final resetPasswordUri = Uri.https(
      AppConstant.caleeServer,
      '/index.php/login',
    );

    final opened = await launchUrl(
      resetPasswordUri,
      mode: LaunchMode.platformDefault,
    );

    if (opened) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open reset password page in browser'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final authController = Get.find<AuthController>();
      final isLoading = authController.authState.isLoading || _isSubmittingLogin;

      return Scaffold(
      backgroundColor: const Color(0xFFF3FAF3),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 32),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: const Color(0xFF66BB6A),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Image.asset(
                        'assets/images/logo.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Welcome to Calee',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Please login to your account',
                    style: TextStyle(
                      fontSize: 15,
                      color: Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 28),
                  _buildLabel('Account Name'),
                  const SizedBox(height: 6),
                  _buildInput(
                    controller: _accountController,
                    hint: 'Enter your account name',
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Account required' : null,
                    enabled: !isLoading,
                  ),
                  const SizedBox(height: 16),
                  _buildLabel('Password'),
                  const SizedBox(height: 6),
                  _buildInput(
                    controller: _passwordController,
                    hint: 'Enter your password',
                    obscure: _obscurePassword,
                    suffixIcon: IconButton(
                      onPressed: isLoading
                          ? null
                          : () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    validator: (v) =>
                        (v == null || v.length < 6) ? 'Password must be at least 6 characters' : null,
                    enabled: !isLoading,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Checkbox(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        value: _agree,
                        onChanged: isLoading
                            ? null
                            : (v) {
                                setState(() {
                                  _agree = v ?? false;
                                });
                              },
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: RichText(
                          textAlign: TextAlign.left,
                          text: TextSpan(
                            text: 'I accept the ',
                            style: const TextStyle(color: Colors.black87, fontSize: 14),
                            children: [
                              TextSpan(
                                text: 'terms and conditions',
                                style: const TextStyle(
                                  color: Color(0xFF66BB6A),
                                  decoration: TextDecoration.underline,
                                ),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = _openTermsAndConditionsPage,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: isLoading ? null : _onLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0D0C14),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey.shade300,
                        disabledForegroundColor: Colors.grey.shade600,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Text(
                              'Login',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: isLoading ? null : _openForgotPasswordPage,
                        child: const Text(
                          'Forgot password?',
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFF66BB6A),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<String>(
                    future: _appVersionLabelFuture,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const SizedBox.shrink();
                      }

                      return Text(
                        snapshot.data!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black45,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      );
    });
  }

  Widget _buildLabel(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
      ),
    );
  }

  Widget _buildInput({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    bool enabled = true,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      validator: validator,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: enabled ? const Color(0xFFEEF7EE) : Colors.grey.shade200,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        suffixIcon: suffixIcon,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300, width: 0.8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF66BB6A), width: 1.2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300, width: 0.8),
        ),
      ),
    );
  }
}
