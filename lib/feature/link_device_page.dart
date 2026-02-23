import 'package:caleesync/feature/link_device_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:go_router/go_router.dart';

class LinkDevicePage extends StatelessWidget {
  const LinkDevicePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () {
            // Prefer Navigator pop if possible (covers Material/Get pushes), otherwise fall back to GoRouter
            final nav = Navigator.of(context);
            if (nav.canPop()) {
              nav.pop();
              return;
            }
            if (GoRouter.of(context).canPop()) {
              GoRouter.of(context).pop();
            } else {
              GoRouter.of(context).go(RouteConstant.home);
            }
          },
        ),
        title: const Text('Link a Device', style: TextStyle(fontWeight: FontWeight.w600)),
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCard(context, theme, textTheme),
              const SizedBox(height: 16),
              _howItWorksBox(textTheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, ThemeData theme, TextTheme textTheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0,2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Scan & Authorize Device', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Scan a QR code from another device to authorize it to access your Calee account',
              style: textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              shape: BoxShape.circle,
            ),
            child: const Center(child: Icon(Icons.smartphone, size: 40, color: Colors.blue)),
          ),
          const SizedBox(height: 18),
          Text(
            'Click the button below to open the camera and scan a QR code from the device you want to link',
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
          ),
          const SizedBox(height: 18),
          ElevatedButton.icon(
            onPressed: () async {
              final controller = LinkDeviceController();
              await controller.scanAndAuthorize(context);
            },
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Scan QR Code',style: TextStyle(color: Colors.white),),
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              backgroundColor: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _howItWorksBox(TextTheme textTheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How it works', style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: Colors.blue[800])),
          const SizedBox(height: 8),
          Text('• The other device will display a QR code', style: textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text('• Use this device to scan and authorize the new device', style: textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text('• You can revoke device access anytime from device management', style: textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text('• Only scan QR codes from devices you trust', style: textTheme.bodyMedium),
        ],
      ),
    );
  }
}


