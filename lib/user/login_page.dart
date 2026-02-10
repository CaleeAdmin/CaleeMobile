import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/controllers/app_controller.dart';
import 'package:caleesync/controllers/auth_controller.dart';
import 'package:caleesync/models/nextcloud_auth_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

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
  Worker? _authStateWorker;

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

    // 获取AuthController实例
    final authController = Get.find<AuthController>();

    // 监听认证状态变化
    _authStateWorker = ever(authController.authStateRx, (NextcloudAuthState state) {
      // 检查页面是否还挂载
      if (!mounted) return;

      if (state.isAuthenticated) {
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

      if (state.hasError && state.status == NextcloudAuthStatus.error) {
        // 显示登录失败错误信息
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

  /// 保存登录凭据并跳转到主页
  Future<void> _saveCredentialsAndNavigate(NextcloudAuthState state) async {
    if (state.serverUrl == null ||
        state.loginName == null ||
        state.appPassword == null) {
      return;
    }

    try {
      // 保存登录凭据到 MMKV
      MMKVUtils.instance.setString(AppConstant.Server, state.serverUrl!);
      MMKVUtils.instance.setString(AppConstant.loginName, state.loginName!);
      MMKVUtils.instance.setString(AppConstant.password, state.appPassword!);

      // 使用GetX的AppController处理登录成功
      final appController = Get.find<AppController>();
      appController.onLoginSuccess();
    } catch (e) {
      // 如果保存失败，显示错误信息
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('保存用户数据失败: $e'),
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

    // 使用用户名密码登录
    final loginName = _accountController.text.trim();
    final password = _passwordController.text.trim();

    final authController = Get.find<AuthController>();
    authController.loginWithCredentials(
      loginName: loginName,
      password: password,
    );
  }

  @override
  Widget build(BuildContext context) {
    final authController = Get.find<AuthController>();
    final isLoading = authController.authState.isLoading;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FB),
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
                      color: const Color(0xFF2E7AFE),
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
                                  color: Color(0xFF2E7AFE),
                                  decoration: TextDecoration.underline,
                                ),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = () {
                                    // TODO: open terms page
                                  },
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
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: isLoading
                            ? null
                            : () {
                                Get.toNamed(RouteConstant.register);
                              },
                        child: const Text(
                          'SignUp',
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFF2E7AFE),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: isLoading
                            ? null
                            : () {
                                // TODO: navigate to Forgot password page
                              },
                        child: const Text(
                          'Forgot password?',
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFF2E7AFE),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
        fillColor: enabled ? const Color(0xFFF4F3F7) : Colors.grey.shade200,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        suffixIcon: suffixIcon,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300, width: 0.8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2E7AFE), width: 1.2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300, width: 0.8),
        ),
      ),
    );
  }
}
