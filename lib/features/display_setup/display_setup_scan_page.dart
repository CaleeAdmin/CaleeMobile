import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import 'display_activation_controller.dart';
import 'display_activation_success_page.dart';
import 'display_setup_repository.dart';

class DisplaySetupScanPage extends StatefulWidget {
  const DisplaySetupScanPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.onDone,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;

  /// Called when setup is complete or the user skips.
  final VoidCallback onDone;

  @override
  State<DisplaySetupScanPage> createState() => _DisplaySetupScanPageState();
}

class _DisplaySetupScanPageState extends State<DisplaySetupScanPage> {
  final _cameraController = MobileScannerController();
  late final DisplayActivationController _activationController;
  bool _scanned = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _activationController = DisplayActivationController(
      repository: DisplaySetupRepository(hubClient: widget.hubClient),
    );
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _activationController.dispose();
    super.dispose();
  }

  String? _extractToken(String? rawValue) {
    if (rawValue == null) return null;
    final uri = Uri.tryParse(rawValue);
    if (uri == null) return null;
    if (uri.scheme != 'https') return null;
    if (uri.host != 'hub.calee.com.au') return null;
    if (uri.pathSegments.length != 2) return null;
    if (uri.pathSegments.first != 'native-login') return null;
    final token = uri.pathSegments.last;
    return token.isNotEmpty ? token : null;
  }

  void _finish(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    widget.onDone();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_scanned) return;
    final barcode = capture.barcodes.firstOrNull;
    final token = _extractToken(barcode?.rawValue);
    if (token == null) {
      setState(() {
        _errorMessage =
            'This QR code is not a valid Calee display QR. '
            'Please scan the QR code shown on your Calee display.';
      });
      return;
    }

    setState(() {
      _scanned = true;
      _errorMessage = null;
    });
    await _cameraController.stop();

    final success = await _activationController.activate(
      accessToken: widget.accessToken,
      token: token,
    );

    if (!mounted) return;

    if (success) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DisplayActivationSuccessPage(
            hubClient: widget.hubClient,
            accessToken: widget.accessToken,
            services: widget.services,
            accountId: widget.accountId,
            onDone: () => _finish(context),
          ),
        ),
      );
    } else {
      setState(() {
        _scanned = false;
        _errorMessage = _activationController.errorMessage;
      });
      await _cameraController.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan display QR')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _cameraController,
              onDetect: _onDetect,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Connect your Calee display',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Scan the QR code shown on your Calee display.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorMessage!,
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                AnimatedBuilder(
                  animation: _activationController,
                  builder: (context, _) {
                    if (_activationController.isLoading) {
                      return const CircularProgressIndicator();
                    }
                    return TextButton(
                      onPressed: () => _finish(context),
                      child: const Text('Skip for now'),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
