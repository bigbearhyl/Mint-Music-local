import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// QQ 音乐扫码登录（与 iMusic 同一套流程：tk.27xk.cn 中转服务）。
///
/// 流程：① action=get_qr 拿 identifier + 二维码 base64
///      ② action=checking_qr&identifier=xx 轮询 → done 后返回 credential
///      ③ 解析 credential：musickey(登录态 key) + str_musicid(账号) + encryptUin
///      ④ action=refresh_key 用 credential 续期。
///
/// 登录只是可选增强：未登录时内置 QQ 源走匿名，听歌不受影响。
class QqLoginService {
  QqLoginService._();

  static final QqLoginService instance = QqLoginService._();

  static const String base = 'https://tk.27xk.cn/zmcw/qqyylogin.php';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const _kUin = 'qq_login_uin';
  static const _kKey = 'qq_login_key';
  static const _kEncryptUin = 'qq_login_euin';
  static const _kCredential = 'qq_login_credential';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 35),
      headers: {'User-Agent': _ua},
    ),
  );

  /// 已保存的登录态（未登录返回 null）
  Future<QqLoginInfo?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final uin = prefs.getString(_kUin) ?? '';
    final key = prefs.getString(_kKey) ?? '';
    if (uin.isEmpty || key.isEmpty) return null;
    return QqLoginInfo(
      uin: uin,
      musickey: key,
      encryptUin: prefs.getString(_kEncryptUin) ?? '',
      credential: prefs.getString(_kCredential) ?? '',
    );
  }

  Future<bool> isLoggedIn() async => (await load()) != null;

  /// 拉取二维码：返回轮询标识与 PNG 字节
  Future<QrStart> getQr() async {
    final resp = await _dio.get('$base?action=get_qr');
    final data = resp.data;
    final root = data is String ? jsonDecode(data) : data;
    final d = root is Map ? root['data'] : null;
    if (d is! Map) throw Exception('获取二维码失败：返回无 data');
    final q = d['qrcode'];
    if (q is! Map) throw Exception('获取二维码失败：缺少 qrcode');
    final identifier = q['identifier']?.toString() ?? '';
    var img = q['data']?.toString() ?? '';
    if (img.startsWith('data:')) img = img.substring(img.indexOf(',') + 1);
    if (identifier.isEmpty || img.isEmpty) {
      throw Exception('获取二维码失败：数据不完整');
    }
    return QrStart(identifier: identifier, bytes: base64Decode(img));
  }

  /// 轮询扫码状态。返回 [QrPoll.anomalous] 表示中转服务异常
  /// （如 mqtt 会话失效 500001），调用方可据此换新二维码重试。
  Future<QrPoll> poll(String identifier) async {
    try {
      final resp = await _dio.get(
        '$base?action=checking_qr&identifier=${Uri.encodeComponent(identifier)}&timeout=8',
      );
      final data = resp.data;
      final root = data is String ? jsonDecode(data) : data;
      if (root is! Map) return const QrPoll(status: QrStatus.waiting, anomalous: true);
      final d = root['data'];
      if (d is! Map) {
        // 中转服务故障（success=false / 无 data）：不算正常等待
        return QrPoll(
          status: QrStatus.waiting,
          anomalous: root['success'] != true,
        );
      }

      Object? cred;
      String event = '';
      var done = false;
      var hasEvent = false;

      final results = d['results'];
      if (results is List && results.isNotEmpty) {
        final r = results.first;
        if (r is Map) {
          event = (r['event']?.toString() ?? '').toUpperCase();
          done = r['done'] == true;
          cred = r['credential'];
          hasEvent = event.isNotEmpty;
        }
      } else {
        cred = d['credential'];
        event = (d['event']?.toString() ?? '').toUpperCase();
        done = d['done'] == true;
        hasEvent = event.isNotEmpty;
      }

      if (done || event == 'SUCCESS' || event == 'DONE' || _isReal(cred)) {
        if (!_isReal(cred)) return const QrPoll(status: QrStatus.confirmed);
        final credStr = cred is Map ? jsonEncode(cred) : cred.toString();
        final info = _parseCredential(credStr);
        if (info == null) {
          return const QrPoll(status: QrStatus.error, message: '凭证解析失败');
        }
        await _save(info.copyWith(credential: credStr));
        return QrPoll(status: QrStatus.done, info: info);
      }
      switch (event) {
        case 'SCAN':
          return const QrPoll(status: QrStatus.scanned);
        case 'CONFIRM':
        case 'CONF':
          return const QrPoll(status: QrStatus.confirmed);
        case 'EXPIRED':
        case 'TIMEOUT_QR':
          return const QrPoll(status: QrStatus.expired);
        case 'REFUSE':
        case 'DENY':
          return const QrPoll(status: QrStatus.refused);
      }
      // 无事件的超时属正常长轮询空转；连 results 都没有则视为服务端异常
      return QrPoll(status: QrStatus.waiting, anomalous: !hasEvent);
    } on DioException {
      // 轮询超时属正常（服务端长轮询超时返回空）
      return const QrPoll(status: QrStatus.waiting);
    }
  }

  /// 凭证续期（失败返回 false）
  Future<bool> refresh() async {
    final current = await load();
    if (current == null || current.credential.isEmpty) return false;
    try {
      final resp = await _dio.get(
        '$base?action=refresh_key&credential='
        '${Uri.encodeComponent(current.credential)}',
      );
      final data = resp.data;
      final root = data is String ? jsonDecode(data) : data;
      Object? cred;
      if (root is Map) {
        cred = root['credential'];
        if (!_isReal(cred) && root['data'] is Map) {
          cred = (root['data'] as Map)['credential'];
        }
      }
      if (!_isReal(cred)) return false;
      final credStr = cred is Map ? jsonEncode(cred) : cred.toString();
      final info = _parseCredential(credStr);
      if (info == null) return false;
      await _save(info.copyWith(credential: credStr));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUin);
    await prefs.remove(_kKey);
    await prefs.remove(_kEncryptUin);
    await prefs.remove(_kCredential);
  }

  Future<void> _save(QqLoginInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUin, info.uin);
    await prefs.setString(_kKey, info.musickey);
    await prefs.setString(_kEncryptUin, info.encryptUin);
    await prefs.setString(_kCredential, info.credential);
  }

  QqLoginInfo? _parseCredential(String credential) {
    try {
      final c = jsonDecode(credential);
      if (c is! Map) return null;
      var musicid = (c['str_musicid'] ?? c['musicid'] ?? c['uin'] ?? '')
          .toString()
          .replaceAll(RegExp(r'[^0-9]'), '');
      final key = (c['musickey'] ?? '').toString();
      if (musicid.isEmpty || key.isEmpty) return null;
      return QqLoginInfo(
        uin: musicid,
        musickey: key,
        encryptUin: (c['encryptUin'] ?? c['encrypt_uin'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  bool _isReal(Object? o) {
    if (o == null) return false;
    final s = o.toString();
    return s.isNotEmpty && s != 'null' && s != '{}';
  }
}

/// 登录态
class QqLoginInfo {
  final String uin; // 账号（纯数字）
  final String musickey; // Q_H_L_ 开头
  final String encryptUin; // 加密 uin（歌单接口需要）
  final String credential;

  const QqLoginInfo({
    required this.uin,
    required this.musickey,
    this.encryptUin = '',
    this.credential = '',
  });

  QqLoginInfo copyWith({String? credential}) => QqLoginInfo(
    uin: uin,
    musickey: musickey,
    encryptUin: encryptUin,
    credential: credential ?? this.credential,
  );

  /// web 侧鉴权 cookie（iMusic 同款）
  String get cookie =>
      'uin=o$uin; qqmusic_uin=o$uin; qm_keyst=$musickey; '
      'qqmusic_key=$musickey; tmeLoginType=2; qqmusic_fromtag=66';

  /// g_tk（QQ 签名用）
  int get gTk {
    var hash = 5381;
    for (var i = 0; i < musickey.length; i++) {
      hash += (hash << 5) + musickey.codeUnitAt(i);
    }
    return hash & 0x7fffffff;
  }
}

class QrStart {
  final String identifier;
  final List<int> bytes;
  const QrStart({required this.identifier, required this.bytes});
}

enum QrStatus { waiting, scanned, confirmed, done, expired, refused, error }

class QrPoll {
  final QrStatus status;
  final QqLoginInfo? info;
  final String? message;

  /// true = 中转服务异常（mqtt 会话失效等），而非正常等待
  final bool anomalous;

  const QrPoll({
    required this.status,
    this.info,
    this.message,
    this.anomalous = false,
  });
}
