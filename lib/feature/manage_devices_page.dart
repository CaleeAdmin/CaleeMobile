import 'package:flutter/material.dart';
import 'package:get/get.dart';

class ManagedDevice {
  final String id;
  final String name;
  final String location;
  final String lastActive; // human-readable
  final bool isCurrent;

  ManagedDevice({
    required this.id,
    required this.name,
    required this.location,
    required this.lastActive,
    this.isCurrent = false,
  });
}

class ManageDevicesPage extends StatefulWidget {
  const ManageDevicesPage({super.key});

  @override
  State<ManageDevicesPage> createState() => _ManageDevicesPageState();
}

class _ManageDevicesPageState extends State<ManageDevicesPage> {
  // Placeholder demo data. Replace with real data source later.
  final List<ManagedDevice> _devices = [
    ManagedDevice(id: '1', name: 'iPhone 14 Pro', location: 'New York, USA', lastActive: 'Active now'),
    ManagedDevice(id: '2', name: 'MacBook Pro', location: 'New York, USA', lastActive: 'Active now', isCurrent: true),
    ManagedDevice(id: '3', name: 'iPad Air', location: 'New York, USA', lastActive: '2 hours ago'),
    ManagedDevice(id: '4', name: 'Android Phone', location: 'San Francisco, USA', lastActive: '1 day ago'),
    ManagedDevice(id: '5', name: 'Windows PC', location: 'Los Angeles, USA', lastActive: '3 days ago'),
  ];

  Future<void> _confirmRevoke(ManagedDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Revoke device access'),
          content: Text('Revoke access for "${d.name}"? This will sign the device out.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Revoke', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (ok == true) {
      // placeholder: perform revoke action (call repo/service)
      setState(() {
        _devices.removeWhere((e) => e.id == d.id);
      });
      Get.snackbar('Revoked', 'Access revoked for ${d.name}', snackPosition: SnackPosition.BOTTOM);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Management'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Device Management', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Manage devices that have access to your account. You can revoke access from any device at any time.',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),

            // list of devices
            Column(
              children: _devices.map((d) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    leading: Icon(
                      _iconForName(d.name),
                      size: 28,
                      color: Colors.black54,
                    ),
                    title: Row(
                      children: [
                        Expanded(child: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                        if (d.isCurrent)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text('This device', style: TextStyle(fontSize: 12)),
                          ),
                        if (!d.isCurrent) const SizedBox(width: 8),
                        if (!d.isCurrent)
                          GestureDetector(
                            onTap: () => _confirmRevoke(d),
                            child: Row(
                              children: const [
                                Icon(Icons.delete_outline, color: Colors.red),
                                SizedBox(width: 6),
                                Text('Revoke', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        Text('Last active: ${d.lastActive}', style: const TextStyle(color: Colors.black54)),
                        const SizedBox(height: 4),
                        Text('Location: ${d.location}', style: const TextStyle(color: Colors.black54)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 16),
            // security notice
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.yellow.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.yellow.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Security Notice', style: TextStyle(fontWeight: FontWeight.w700)),
                  SizedBox(height: 8),
                  Text('If you see a device you don\'t recognize, revoke its access immediately and change your password. Revoking a device will sign it out and require re-authentication to access Calee.',
                      style: TextStyle(color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForName(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('iphone') || lower.contains('android') || lower.contains('phone')) return Icons.smartphone;
    if (lower.contains('ipad') || lower.contains('tablet')) return Icons.tablet;
    if (lower.contains('mac') || lower.contains('book')) return Icons.laptop_mac;
    if (lower.contains('windows') || lower.contains('pc')) return Icons.desktop_windows;
    return Icons.devices;
  }
}






