import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../plugin/data/netease_login_service.dart';
import '../../../plugin/data/netease_music_source.dart';
import '../../../plugin/data/netease_user_service.dart';

/// 网易云「官方网页登录」。
///
/// 背景：第三方直连网易云扫码接口会被网易云「行为验证码」风控（返回 8821，
/// 提示"请切换其他登录方式或升级新版本"），而 `music.163.com` 官方页面是官方环境，
/// 在其内登录（手机验证码 / 扫码）不受该风控影响。
///
/// 做法：内嵌官方登录页，用户在页面内完成登录后，
/// 从 WebView 的 cookie 中读取 `MUSIC_U` 作为登录态。
class NeteaseWebLoginPage extends StatefulWidget {
  const NeteaseWebLoginPage({super.key});

  @override
  State<NeteaseWebLoginPage> createState() => _NeteaseWebLoginPageState();
}

class _NeteaseWebLoginPageState extends State<NeteaseWebLoginPage> {
  late final WebViewController _controller;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => _detect()),
      )
      ..loadRequest(Uri.parse('https://music.163.com/login'));
    // 官方页面登录后不一定触发导航，这里轮询检查 cookie
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _detect());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _detect() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      final cookies = await WebViewCookieManager()
          .getCookies(domain: Uri.parse('https://music.163.com'));
      final hasMusicU = cookies.any(
        (c) => c.name == 'MUSIC_U' && c.value.isNotEmpty,
      );
      if (!hasMusicU) return;
      final cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      final ok = await NeteaseLoginService.instance.importCookie(cookieStr);
      if (!ok) return;
      // 补全昵称 / 头像 / uid（uid 是「我的歌单」接口必需）
      try {
        final p = await NeteaseUserService.instance.getUserAccount();
        await NeteaseLoginService.instance.updateProfile(
          nickname: p.nickname,
          avatarUrl: p.avatarUrl,
          uid: p.uid,
        );
      } catch (_) {}
      final info = await NeteaseLoginService.instance.load();
      NeteaseMusicSource.loginCookie = info?.cookie ?? '';
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      // 忽略：等待下一次轮询
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('网易云官方登录'),
        actions: [
          TextButton(
            onPressed: _detect,
            child: const Text('我已登录完成'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF3F3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: const Text(
              '在下方官方页面里用「手机号验证码」或「扫码」登录，登录成功后会自动返回。',
              style: TextStyle(fontSize: 12, color: Color(0xFF8A3030)),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
