import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/models/ios_caldav_setup_info.dart';
import 'package:caleesync/services/ios_caldav_setup_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class IosCalDavSetupPage extends StatefulWidget {
  const IosCalDavSetupPage({super.key});

  @override
  State<IosCalDavSetupPage> createState() => _IosCalDavSetupPageState();
}

class _IosCalDavSetupPageState extends State<IosCalDavSetupPage> {
  final IosCalDavSetupService _setupService = IosCalDavSetupService();
  IosCaldavSetupInfo? _setupInfo;
  bool _loading = true;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _loadSetupInfo();
  }

  Future<void> _loadSetupInfo() async {
    final info = _setupService.loadSetupInfo();
    if (!mounted) {
      return;
    }
    setState(() {
      _setupInfo = info;
      _loading = false;
    });
  }

  Future<void> _copyValue(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  Widget _buildBlockedState() {
    final reason = _setupInfo?.missingReason ?? 'Missing account details. Please reconnect and sign in again.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.lock_outline, color: Colors.deepOrange),
                SizedBox(width: 8),
                Text('Setup blocked', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Text(reason),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => Get.back(),
                  child: const Text('Back'),
                ),
                FilledButton(
                  onPressed: () => Get.toNamed(RouteConstant.login),
                  child: const Text('Go to Login'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildValueRow(String label, String value, {bool sensitive = false}) {
    final displayValue = sensitive && !_showPassword ? '••••••••••' : value;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(displayValue),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (sensitive)
            IconButton(
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
            ),
          IconButton(
            tooltip: 'Copy $label',
            onPressed: () => _copyValue(label, value),
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupCard() {
    final info = _setupInfo!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('CalDAV account values', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildValueRow('Server', info.server),
            const Divider(height: 1),
            _buildValueRow('Username', info.username),
            const Divider(height: 1),
            _buildValueRow('Password', info.password, sensitive: true),
            const Divider(height: 1),
            _buildValueRow('Description', info.description),
          ],
        ),
      ),
    );
  }

  Widget _buildStepsCard() {
    const steps = [
      'Settings',
      'Apps',
      'Calendar',
      'Calendar Accounts',
      'Add Account',
      'Add Other Account',
      'CalDAV account',
      'Enter Server / Username / Password / Description',
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('iPhone setup steps', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${i + 1}. ${steps[i]}'),
              ),
            const SizedBox(height: 8),
            const Text(
              'This is Apple Calendar’s native two-way path for Calee.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAfterSetupCard() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('After setup', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            SizedBox(height: 10),
            Text('• Open Apple Calendar and ensure the Calee calendar appears.'),
            SizedBox(height: 6),
            Text('• Create a test event to confirm two-way sync if needed.'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Calee Calendar to iPhone')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_setupInfo?.isReady != true) _buildBlockedState() else ...[
                      _buildSetupCard(),
                      const SizedBox(height: 12),
                      _buildStepsCard(),
                      const SizedBox(height: 12),
                      _buildAfterSetupCard(),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
