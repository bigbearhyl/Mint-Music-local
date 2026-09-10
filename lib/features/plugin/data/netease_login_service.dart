import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/netease_crypto.dart';

/// 网易云音乐扫码登录（直连官方明文 API：`/api/login/qrcode/*`，不需要 weapi 加密）
///
/// 流程：
/// ① GET `/api/login/qrcode/unikey?type=1` → { unikey, code } + Set-Cookie 拿到 csrf_token
/// ② 二维码地址：https://music.163.com/login?codekey=<unikey>
/// ③ GET `/api/login/qrcode/client/login?key=<unikey>&type=1` 轮询：
///   - code=801 等待扫码
///   - code=802 已扫码未点确认
///   - code=803 已确认，返回 profile.nickname/avatarUrl/userId 等
///   同时 Set-Cookie 含 MUSIC_U（登录态，30 天有效）
/// ④ 持久化 MUSIC_U 等 cookie，注入到 [NeteaseMusicSource.loginCookie]
///
/// 登录只是可选增强：未登录时内置网易云源走匿名，听歌受影响（周杰伦等会被替换成翻唱）。
class NeteaseLoginService {
  NeteaseLoginService._();

  static final NeteaseLoginService instance = NeteaseLoginService._();

  static const String base = 'https://music.163.com';

  /// 客户端标识 cookie：网易云要求声明「PC 网页客户端」，缺失时 weapi 接口会返回空响应。
  /// 参考 missuo/kumone 的实现：Cookie 恒定带上 os=pc; appver=3.1.17。
  static const String _clientCookie = 'os=pc; appver=3.1.17';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const _kCookie = 'netease_login_cookie';
  static const _kNickname = 'netease_login_nickname';
  static const _kAvatar = 'netease_login_avatar';
  static const _kUid = 'netease_login_uid';
  static const _kCsrf = 'netease_login_csrf';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: const {
        'User-Agent': _ua,
        'Referer': 'https://music.163.com/',
        'Origin': 'https://music.163.com',
      },
    ),
  );

  /// csrf_token（来自第一次 unikey 请求的 Set-Cookie，用于后续 cookie 关联）
  String? _csrf;

  /// 扫码会话 cookie（unikey 请求下发的 NMTID 等），轮询时原样带回。
  /// 明文裸接口不带会话是触发网易云 8821 风控的主要原因之一。
  String _sessionCookie = '';

  /// 已保存的登录态（未登录返回 null）
  Future<NeteaseLoginInfo?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final cookie = prefs.getString(_kCookie) ?? '';
    if (cookie.isEmpty || !cookie.contains('MUSIC_U=')) return null;
    _csrf = prefs.getString(_kCsrf);
    return NeteaseLoginInfo(
      cookie: cookie,
      nickname: prefs.getString(_kNickname) ?? '',
      avatarUrl: prefs.getString(_kAvatar) ?? '',
      uid: int.tryParse(prefs.getString(_kUid) ?? '') ?? 0,
    );
  }

  /// 步骤 1：拿 unikey（扫码用的 codekey）。
  /// 同时从响应 Cookie 里取 csrf_token。
  Future<String?> getQrKey() async {
    try {
      // weapi 加密 + PC 客户端 cookie（os=pc; appver=3.1.17）
      final encoded = NeteaseCrypto.weapi({'type': 1});
      final body = _weapiBody(encoded);
      debugPrint('[NeteaseLogin] unikey body => $body');
      final resp = await _dio.post(
        '$base/weapi/login/qrcode/unikey',
        data: body,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: const {'Cookie': _clientCookie},
          responseType: ResponseType.plain,
        ),
      );
      final raw = resp.data is String ? resp.data as String : '';
      debugPrint(
        '[NeteaseLogin] unikey raw => $raw | status=${resp.statusCode} '
        'ct=${resp.headers.value('content-type')} cl=${resp.headers.value('content-length')}',
      );
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final unikey = (decoded['unikey'] as String?) ?? '';
      if (unikey.isEmpty) return null;
      // 保留会话 cookie（NMTID 等），轮询时带回
      final sc = _cookiesFrom(resp.headers);
      if (sc.isNotEmpty) _sessionCookie = '$_clientCookie; $sc';
      _csrf = _extractCookie(resp.headers, 'csrf_token') ?? _csrf;
      return unikey;
    } catch (e, s) {
      debugPrint('[NeteaseLogin] unikey error: $e\n$s');
      return null;
    }
  }

  /// 把 weapi 加密结果拼成 application/x-www-form-urlencoded 请求体。
  /// （手动拼接，避免 Dio 对 Map 的自动编码差异。）
  String _weapiBody(Map<String, String> encoded) =>
      'params=${Uri.encodeComponent(encoded['params'] ?? '')}'
      '&encSecKey=${Uri.encodeComponent(encoded['encSecKey'] ?? '')}';

  /// 步骤 2：轮询扫码状态。
  /// 返回：null=继续等待（801）；'scan'=已扫码待确认（802）；
  /// NeteaseLoginInfo=登录成功（803，已含 MUSIC_U cookie）。
  Future<dynamic> checkQrStatus(String unikey) async {
    try {
      final encoded = NeteaseCrypto.weapi({'key': unikey, 'type': 1});
      final cookie = _sessionCookie.isEmpty ? _clientCookie : _sessionCookie;
      final resp = await _dio.post(
        '$base/weapi/login/qrcode/client/login',
        data: _weapiBody(encoded),
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {'Cookie': cookie},
          responseType: ResponseType.plain,
        ),
      );
      final raw = resp.data is String ? resp.data as String : '';
      debugPrint('[NeteaseLogin] poll raw => $raw');
      if (raw.isEmpty) return null;
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final code = (data['code'] as num?)?.toInt() ?? 0;
      if (code == 803) {
        final profile =
            data['profile'] is Map ? data['profile'] as Map : const {};
        // 会话 cookie + 本次下发的登录态 cookie（含 MUSIC_U）
        final merged = _mergeCookies(cookie, _cookiesFrom(resp.headers));
        if (!merged.contains('MUSIC_U=')) {
          // 没有 MUSIC_U 的不算登录态
          return null;
        }
        final info = NeteaseLoginInfo(
          cookie: merged,
          nickname: (profile['nickname'] as String?) ?? '',
          avatarUrl: (profile['avatarUrl'] as String?) ?? '',
          uid: (profile['userId'] as num?)?.toInt() ??
              (profile['id'] as num?)?.toInt() ??
              0,
        );
        await save(info);
        return info;
      }
      if (code == 802) return 'scan';
      if (code == 800) return 'expire';
      if (code == 801 || code == 0) return null;
      // 其他错误码（如 8821 安全风控）：回传给 UI 展示真实原因
      return <String, dynamic>{
        'error': true,
        'code': code,
        'message': (data['message'] as String?) ?? '登录失败（code=$code）',
      };
    } catch (e, s) {
      debugPrint('[NeteaseLogin] poll error: $e\n$s');
      return null;
    }
  }

  Future<void> save(NeteaseLoginInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCookie, info.cookie);
    await prefs.setString(_kNickname, info.nickname);
    await prefs.setString(_kAvatar, info.avatarUrl);
    await prefs.setString(_kUid, info.uid.toString());
    if (_csrf != null) await prefs.setString(_kCsrf, _csrf!);
  }

  /// 从浏览器「已登录网易云网页版」复制的 Cookie 导入登录态。
  ///
  /// 背景：网易云已对第三方扫码登录加行为验证码风控（返回 8821），
  /// 复用官方网页会话 Cookie 是最稳的方式（社区同类工具的通用做法）。
  /// [raw] 支持直接粘贴整段 Cookie（可含 `Cookie:` 前缀 / 换行 / 引号）。
  Future<bool> importCookie(String raw) async {
    final cookie = _normalizeCookie(raw);
    if (!cookie.contains('MUSIC_U=')) return false;
    await save(NeteaseLoginInfo(
      cookie: cookie,
      nickname: '',
      avatarUrl: '',
      uid: 0,
    ));
    return true;
  }

  /// 导入 Cookie 后拉到的资料补写（昵称 / 头像 / uid）。
  Future<void> updateProfile({
    String? nickname,
    String? avatarUrl,
    int? uid,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (nickname != null && nickname.isNotEmpty) {
      await prefs.setString(_kNickname, nickname);
    }
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      await prefs.setString(_kAvatar, avatarUrl);
    }
    if (uid != null && uid > 0) {
      await prefs.setString(_kUid, uid.toString());
    }
  }

  String _normalizeCookie(String raw) {
    var s = raw.trim();
    s = s.replaceAll('\r', ' ').replaceAll('\n', '; ');
    if (s.toLowerCase().startsWith('cookie:')) {
      s = s.substring(7).trim();
    }
    s = s.replaceAll('"', '').replaceAll("'", '');
    final parts =
        s.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty);
    return parts.join('; ');
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCookie);
    await prefs.remove(_kNickname);
    await prefs.remove(_kAvatar);
    await prefs.remove(_kUid);
    await prefs.remove(_kCsrf);
    _csrf = null;
  }

  Future<bool> isLoggedIn() async {
    final info = await load();
    return info != null && info.cookie.contains('MUSIC_U=');
  }

  String? _extractCookie(Headers headers, String name) {
    final raw = headers['set-cookie'];
    if (raw == null) return null;
    for (final c in raw) {
      final kv = c.split(';').firstWhere(
            (e) => e.trim().startsWith('$name='),
            orElse: () => '',
          );
      if (kv.isNotEmpty) {
        return kv.substring(name.length + 1);
      }
    }
    return null;
  }

  /// 从响应 Set-Cookie 取出全部 name=value，拼成请求用的 Cookie 串。
  String _cookiesFrom(Headers headers) {
    final raw = headers['set-cookie'];
    final Map<String, String> map = {};
    if (raw != null) {
      for (final c in raw) {
        final first = c.split(';').first.trim();
        final eq = first.indexOf('=');
        if (eq > 0) {
          map[first.substring(0, eq)] = first.substring(eq + 1);
        }
      }
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 合并两段 cookie 串（后者优先），用于「会话 cookie + 登录态 cookie」。
  String _mergeCookies(String a, String b) {
    final map = <String, String>{};
    for (final src in <String>[a, b]) {
      for (final part in src.split(';')) {
        final t = part.trim();
        final eq = t.indexOf('=');
        if (eq > 0) map[t.substring(0, eq)] = t.substring(eq + 1);
      }
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

}

class NeteaseLoginInfo {
  final String cookie;
  final String nickname;
  final String avatarUrl;
  final int uid;

  const NeteaseLoginInfo({
    required this.cookie,
    required this.nickname,
    required this.avatarUrl,
    required this.uid,
  });
}