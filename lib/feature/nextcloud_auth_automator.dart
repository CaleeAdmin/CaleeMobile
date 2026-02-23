import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class NextcloudAuthAutomator {
  final String loginName;
  final String password;
  final String flowUrl;
  final VoidCallback onAuthComplete;
  final Function(String) onError;

  NextcloudAuthAutomator({
    required this.loginName,
    required this.password,
    required this.flowUrl,
    required this.onAuthComplete,
    required this.onError,
  });

  late final WebViewController controller;

  void start(BuildContext context) async {
    debugPrint('[AuthAutomator] 正在启动半自动授权...');

    // 必须清理 Cookie，否则可能卡在错误的 Session 中
    await WebViewCookieManager().clearCookies();

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
    // 使用标准的桌面端 UserAgent 减少风控
      ..setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            debugPrint('[AuthAutomator] 页面加载完成: $url');
            _injectAuthScript(url, context);
          },
          onWebResourceError: (error) => onError(error.description),
        ),
      )
      ..setOnConsoleMessage((msg) => debugPrint('[JS Console] ${msg.message}'));

    await controller.loadRequest(Uri.parse(flowUrl));
    _showAuthModal(context);
  }

  void _injectAuthScript(String currentUrl, BuildContext context) {
    // 成功跳转逻辑：如果检测到 done 或跳转回 app schema
    if (currentUrl.contains('flow/done') || currentUrl.contains('grant')) {
      // 如果页面已经显示授权成功或包含特定标识，可以自动关闭
      if (currentUrl.contains('flow/done')) {
        Navigator.of(context).pop();
        onAuthComplete();
        return;
      }
    }

    final String js = '''
      (function() {
        const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
        
        async function run() {
          const userField = document.querySelector('input[id="user"]');
          const passField = document.querySelector('input[id="password"]');
          const grantBtn = document.querySelector('button.primary, button#grant-button');

          // 1. 如果已经在授权页，提醒用户点击（或尝试自动点击，此处通常自动点击成功率高）
          if (grantBtn) {
            console.log("Nextcloud: 已到达授权页");
            await sleep(500);
            grantBtn.click(); // 授权按钮通常不带风控，可以尝试自动点击
            return;
          }

          // 2. 如果在登录页，仅负责“填充”，不负责“提交”
          if (userField && passField) {
            console.log("Nextcloud: 正在自动填充账号密码...");
            
            const trigger = (el, val) => {
              el.focus();
              el.value = val;
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              el.blur();
            };

            trigger(userField, '$loginName');
            await sleep(200);
            trigger(passField, '$password');
            
            // 勾选记住我
            const remember = document.querySelector('input[name="remember_login"]');
            if (remember) remember.checked = true;

            console.log("Nextcloud: 填充完毕，请手动点击登录按钮");
          }
        }
        run();
      })();
    ''';

    controller.runJavaScript(js);
  }

  void _showAuthModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.85,
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          children: [
            Container(
              width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 15),
              child: Text("请点击“登录”以完成授权", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Expanded(
              child: WebViewWidget(controller: controller),
            ),
          ],
        ),
      ),
    );
  }
}