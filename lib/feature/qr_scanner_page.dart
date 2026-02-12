import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({Key? key}) : super(key: key);

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _isProcessing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return;

    String? raw;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        raw = value;
        break;
      }
    }

    if (raw == null) return;

    _isProcessing = true;
    if (mounted) {
      Navigator.of(context).pop(raw);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final scanWindow = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * 0.82,
      height: size.width * 0.82,
    );

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('Scan QR Code'),
        leading: SafeArea(
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => context.pop(),
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              scanWindow: scanWindow,
              fit: BoxFit.contain,
            ),
          ),
          Center(
            child: SizedBox(
              width: size.width * 0.82,
              height: size.width * 0.82,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 1.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  Positioned(top: -1, left: -1, child: _corner()),
                  Positioned(top: -1, right: -1, child: _corner(rotation: 90)),
                  Positioned(bottom: -1, left: -1, child: _corner(rotation: -90)),
                  Positioned(bottom: -1, right: -1, child: _corner(rotation: 180)),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 36,
            left: 24,
            right: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Place the full QR code inside the frame for automatic detection',
                    style: TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _actionButton(
                      icon: Icons.flash_on,
                      label: 'Torch',
                      onPressed: () => _controller.toggleTorch(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({required IconData icon, required String label, required VoidCallback onPressed}) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onPressed,
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _corner({double rotation = 0}) {
    return Transform.rotate(
      angle: rotation * 3.1415926535 / 180,
      child: const SizedBox(
        width: 28,
        height: 28,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: Colors.greenAccent, width: 3),
              left: BorderSide(color: Colors.greenAccent, width: 3),
            ),
          ),
        ),
      ),
    );
  }
}
