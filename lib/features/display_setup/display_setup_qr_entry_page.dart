import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'display_setup_intent.dart';
import 'display_setup_link_controller.dart';

class DisplaySetupQrEntryPage extends StatefulWidget {
  const DisplaySetupQrEntryPage({
    required this.onIntentFound,
    required this.onBack,
    super.key,
  });

  /// Called when a valid display setup QR is scanned.
  final void Function(DisplaySetupIntent intent) onIntentFound;

  /// Called when the user taps the Back button.
  final VoidCallback onBack;

  @override
  State<DisplaySetupQrEntryPage> createState() =>
      _DisplaySetupQrEntryPageState();
}

class _DisplaySetupQrEntryPageState extends State<DisplaySetupQrEntryPage> {
  final _cameraController = MobileScannerController();
  bool _scanned = false;
  String? _errorMessage;

  @override
  void dispose() {
    _cameraController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final barcode = capture.barcodes.firstOrNull;
    final rawValue = barcode?.rawValue;
    if (rawValue == null) return;

    final uri = Uri.tryParse(rawValue);
    final intent = uri != null
        ? DisplaySetupLinkController.parseDisplaySetupUri(uri)
        : null;

    if (intent == null) {
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
    _cameraController.stop();
    widget.onIntentFound(intent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan display QR'),
        leading: BackButton(onPressed: widget.onBack),
      ),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
