import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      final resp = await _dio.get(
        '$base/api/login/qrcode/unikey?type=1',
        options: Options(responseType: ResponseType.json),
      );
      final data = resp.data;
      if (data is! Map) return null;
      final unikey = (data['unikey'] as String?) ?? '';
      if (unikey.isEmpty) return null;
      _csrf = _extractCookie(resp.headers, 'csrf_token') ?? _csrf;
      return unikey;
    } catch (_) {
      return null;
    }
  }

  /// 步骤 2：轮询扫码状态。
  /// 返回：null=继续等待（801）；'scan'=已扫码待确认（802）；
  /// NeteaseLoginInfo=登录成功（803，已含 MUSIC_U cookie）。
  Future<dynamic> checkQrStatus(String unikey) async {
    try {
      // 保持会话：把 unikey 接口的 cookie（特别是 csrf_token）继续带过来
      final pollCookie = _csrf == null ? '' : 'csrf_token=$_csrf';
      final resp = await _dio.get(
        '$base/api/login/qrcode/client/login?key=$unikey&type=1',
        options: Options(
          headers: pollCookie.isEmpty ? null : {'Cookie': pollCookie},
          responseType: ResponseType.json,
        ),
      );
      final data = resp.data;
      if (data is! Map) return null;
      final code = (data['code'] as int?) ?? 0;
      if (code == 803) {
        final profile =
            data['profile'] is Map ? data['profile'] as Map : const {};
        final cookie = _joinCookies(resp.headers, _csrf);
        if (!cookie.contains('MUSIC_U=')) {
          // 兜底：从 profile 拿不到时尝试 NMTID 之类的不算登录态
          return null;
        }
        final info = NeteaseLoginInfo(
          cookie: cookie,
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
      return null;
    } catch (_) {
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

  /// 合并 Set-Cookie 中需要持久化的 key（：MUSIC_U / __csrf / csrf_token / NMTID 等）。
  String _joinCookies(Headers headers, String? csrf) {
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
    if (csrf != null && !map.containsKey('__csrf')) map['__csrf'] = csrf;
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