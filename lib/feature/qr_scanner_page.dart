import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:go_router/go_router.dart';

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({Key? key}) : super(key: key);

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _isProcessing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return;
    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final raw = barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;
    _isProcessing = true;
    // 返回扫码结果给调用方（通过 GoRouter pop）
    if (mounted) {
      // 使用 Navigator.pop 作为更通用的回退（当页面不是在 GoRouter 上下文中时避免断言）
      Navigator.of(context).pop(raw);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 让相机预览铺满至状态栏下方
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('扫描二维码'),
        leading: SafeArea(
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => context.pop(),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Fullscreen camera preview
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              // 保证画面裁切更自然
              fit: BoxFit.cover,
            ),
          ),

          // 中心扫描框（边框 + 四角标记）
          Center(
            child: SizedBox(
              width: 260,
              height: 260,
              child: Stack(
                children: [
                  // 边框
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 1.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  // 四角标记
                  Positioned(
                    top: -1,
                    left: -1,
                    child: _corner(),
                  ),
                  Positioned(
                    top: -1,
                    right: -1,
                    child: _corner(rotation: 90),
                  ),
                  Positioned(
                    bottom: -1,
                    left: -1,
                    child: _corner(rotation: -90),
                  ),
                  Positioned(
                    bottom: -1,
                    right: -1,
                    child: _corner(rotation: 180),
                  ),
                ],
              ),
            ),
          ),

          // 底部提示与操作按钮
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
                    '将二维码置于取景框内，应用会自动识别',
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
                      label: '手电',
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

  // 四角小标记
  Widget _corner({double rotation = 0}) {
    return Transform.rotate(
      angle: rotation * 3.1415926535 / 180,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.greenAccent, width: 3),
            left: BorderSide(color: Colors.greenAccent, width: 3),
          ),
        ),
      ),
    );
  }
}
