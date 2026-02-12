import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/user_profile_timezones.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/controllers/app_controller.dart';
import 'package:caleesync/services/user_profile_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Profile Settings page
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final UserProfileService _profileService = UserProfileService();
  // Personal Information controllers
  final _fullNameController = TextEditingController(text: 'John Doe');
  final _emailController = TextEditingController(text: 'john.doe@example.com');
  final _postCodeController = TextEditingController(text: '10001');
  String _selectedTimezone = 'UTC';
  
  // Account name from stored credentials
  String? _accountName;
  bool _isSyncingProfile = false;

  @override
  void initState() {
    super.initState();
    // Load account name from stored credentials
    _loadAccountName();
    _loadProfileFromNextcloud();
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
    super.dispose();
  }



  Future<void> _loadProfileFromNextcloud() async {
    try {
      final profile = await _profileService.fetchCurrentProfile();
      if (!mounted) return;
      setState(() {
        _fullNameController.text = profile['displayname'] ?? '';
        _emailController.text = profile['email'] ?? '';
        _postCodeController.text = profile['address'] ?? '';
        _selectedTimezone = _normalizeTimezone(profile['timezone']);
      });
    } catch (_) {
      // Keep local defaults when remote profile is unavailable.
    }
  }

  void _onLogout() {
    // 使用GetX的AppController处理登出
    final appController = Get.find<AppController>();
    appController.logout();
  }

  Future<void> _onSavePersonalInfo() async {
    final displayName = _fullNameController.text.trim();
    final email = _emailController.text.trim();
    final address = _postCodeController.text.trim();
    final timezone = _selectedTimezone.trim();

    if (displayName.isEmpty || email.isEmpty || timezone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Full name, email, and timezone are required'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSyncingProfile = true;
    });

    try {
      await _profileService.updateCurrentProfile(
        displayName: displayName,
        email: email,
        address: address,
        timezone: timezone,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Personal information synced to Nextcloud'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sync failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _isSyncingProfile = false;
      });
    }
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
            if (Get.previousRoute.isNotEmpty) {
              Get.back();
            } else {
              Get.offAllNamed(RouteConstant.home);
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

                    // Postcode
                    _buildLabel('Postcode'),
                    const SizedBox(height: 6),
                    _buildInput(
                      controller: _postCodeController,
                      hint: 'Enter your postcode',
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 20),

                    // Timezone
                    _buildLabel('Timezone'),
                    const SizedBox(height: 6),
                    _buildTimezoneDropdown(),
                    const SizedBox(height: 24),

                    // Save Changes button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isSyncingProfile ? null : _onSavePersonalInfo,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0D0C14),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: _isSyncingProfile
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Text(
                          'Save Changes',
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


  String _normalizeTimezone(dynamic timezone) {
    final raw = timezone?.toString().trim() ?? '';
    if (raw.isEmpty) {
      return 'UTC';
    }

    return kNextcloudTimezones.contains(raw) ? raw : 'UTC';
  }

  Widget _buildTimezoneDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _selectedTimezone,
      isExpanded: true,
      decoration: InputDecoration(
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
      items: kNextcloudTimezones
          .map(
            (timezone) => DropdownMenuItem<String>(
              value: timezone,
              child: Text(
                timezone,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _selectedTimezone = value;
        });
      },
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
}
