import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Profile Settings page
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  // Personal Information controllers
  final _fullNameController = TextEditingController(text: 'John Doe');
  final _emailController = TextEditingController(text: 'john.doe@example.com');
  final _postCodeController = TextEditingController(text: '10001');
  
  // Password controllers
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  
  // First Day of Week dropdown value
  String _firstDayOfWeek = 'Monday';
  final List<String> _weekDays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  // Account name from stored credentials
  String? _accountName;

  @override
  void initState() {
    super.initState();
    // Load account name from stored credentials
    _loadAccountName();
  }

  void _loadAccountName() {
    final loginName = MMKVUtils.instance.getString(AppConstant.loginName);
    setState(() {
      _accountName = loginName;
    });
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _postCodeController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _onLogout() {
    // Clear stored credentials
    MMKVUtils.instance.remove(AppConstant.Server);
    MMKVUtils.instance.remove(AppConstant.loginName);
    MMKVUtils.instance.remove(AppConstant.password);
    
    // Navigate to login page
    context.go(RouteConstant.login);
  }

  void _onSavePersonalInfo() {
    // TODO: Implement save personal information logic
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Personal information saved successfully'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _onChangePassword() {
    final currentPassword = _currentPasswordController.text.trim();
    final newPassword = _newPasswordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();

    if (currentPassword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter current password'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (newPassword.isEmpty || newPassword.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('New password must be at least 6 characters'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (newPassword != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('New passwords do not match'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // TODO: Implement change password logic
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Password changed successfully'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );

    // Clear password fields
    _currentPasswordController.clear();
    _newPasswordController.clear();
    _confirmPasswordController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FB),
      appBar: AppBar(
        title: const Text(
          'Profile',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: Colors.black87,
          ),
          onPressed: () {
            // 如果可以 pop，则 pop；否则返回到 home
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(RouteConstant.home);
            }
          },
        ),
        actions: [
          TextButton.icon(
            onPressed: _onLogout,
            icon: const Icon(
              Icons.arrow_forward,
              color: Colors.red,
              size: 18,
            ),
            label: const Text(
              'Logout',
              style: TextStyle(
                color: Colors.red,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // White card container
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Personal Information Section
                    _buildSectionTitle(
                      'Personal Information',
                      'Update your personal details',
                    ),
                    const SizedBox(height: 24),

                    // Account Name (read-only)
                    _buildLabel('Account Name'),
                    const SizedBox(height: 6),
                    _buildReadOnlyInput(
                      value: _accountName ?? 'john_doe_2024',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Account name cannot be changed',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Full Name
                    _buildLabel('Full Name'),
                    const SizedBox(height: 6),
                    _buildInput(
                      controller: _fullNameController,
                      hint: 'Enter your full name',
                    ),
                    const SizedBox(height: 20),

                    // Email
                    _buildLabel('Email'),
                    const SizedBox(height: 6),
                    _buildInput(
                      controller: _emailController,
                      hint: 'Enter your email',
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 20),

                    // Post Code
                    _buildLabel('Post Code'),
                    const SizedBox(height: 6),
                    _buildInput(
                      controller: _postCodeController,
                      hint: 'Enter your post code',
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 20),

                    // First Day of Week
                    _buildLabel('First Day of Week'),
                    const SizedBox(height: 6),
                    _buildDropdown(),
                    const SizedBox(height: 24),

                    // Save Changes button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _onSavePersonalInfo,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0D0C14),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text(
                          'Save Changes',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 40),
                    const Divider(),
                    const SizedBox(height: 40),

                    // Change Password Section
                    _buildSectionTitle(
                      'Change Password',
                      'Update your password to keep your account secure',
                    ),
                    const SizedBox(height: 24),

                    // Current Password
                    _buildLabel('Current Password'),
                    const SizedBox(height: 6),
                    _buildInput(
                      controller: _currentPasswordController,
                      hint: 'Enter current password',
                      obscure: true,
                    ),
                    const SizedBox(height: 20),

                    // New Password
                    _buildLabel('New Password'),
                    const SizedBox(height: 6),
                    _buildInput(
                      controller: _newPasswordController,
                      hint: 'Enter new password',
                      obscure: true,
                    ),
                    const SizedBox(height: 20),

                    // Confirm New Password
                    _buildLabel('Confirm New Password'),
                    const SizedBox(height: 6),
                    _buildInput(
                      controller: _confirmPasswordController,
                      hint: 'Confirm new password',
                      obscure: true,
                    ),
                    const SizedBox(height: 24),

                    // Change Password button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _onChangePassword,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0D0C14),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text(
                          'Change Password',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
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
      ),
    );
  }

  Widget _buildSectionTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Colors.black87,
      ),
    );
  }

  Widget _buildInput({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    TextInputType? keyboardType,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFFF4F3F7),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300, width: 0.8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF2E7AFE), width: 1.2),
        ),
      ),
    );
  }

  Widget _buildReadOnlyInput({required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F3F7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300, width: 0.8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F3F7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300, width: 0.8),
      ),
      child: DropdownButton<String>(
        value: _firstDayOfWeek,
        isExpanded: true,
        underline: const SizedBox(),
        icon: Icon(Icons.keyboard_arrow_down, color: Colors.grey.shade600),
        items: _weekDays.map((String day) {
          return DropdownMenuItem<String>(
            value: day,
            child: Text(
              day,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.black87,
              ),
            ),
          );
        }).toList(),
        onChanged: (String? newValue) {
          if (newValue != null) {
            setState(() {
              _firstDayOfWeek = newValue;
            });
          }
        },
      ),
    );
  }
}

