import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/music_api_service.dart';
import '../../../core/network/netease_crypto.dart';
import '../../player/domain/models/song.dart';
import 'netease_login_service.dart';

/// 网易云用户数据：账号 / 喜欢的音乐 / 歌单。
///
/// 所有方法要求已登录（[NeteaseLoginService.isLoggedIn] = true），未登录调用会抛 [NeedLogin]。
class NeteaseUserService {
  NeteaseUserService._();

  static final NeteaseUserService instance = NeteaseUserService._();

  static const String _host = 'https://music.163.com';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

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

  /// 当前用户基本信息
  Future<NeteaseUserProfile> getUserAccount() async {
    final info = await _requireLogin();
    final data = await _weApiPost(
      path: '/weapi/nuser/account/get',
      params: const {},
      cookie: info.cookie,
    );
    final profile = data['profile'] is Map ? data['profile'] as Map : data;
    return NeteaseUserProfile(
      uid: (profile['userId'] as num?)?.toInt() ?? info.uid,
      nickname: (profile['nickname'] as String?) ?? info.nickname,
      avatarUrl: (profile['avatarUrl'] as String?) ?? info.avatarUrl,
      signature: (profile['signature'] as String?) ?? '',
    );
  }

  /// 喜欢的音乐 ID 列表（"我喜欢的音乐"歌单的内容）
  Future<List<int>> getLikelist() async {
    final info = await _requireLogin();
    final data = await _weApiPost(
      path: '/weapi/song/like/get',
      params: {'uid': info.uid.toString()},
      cookie: info.cookie,
    );
    final ids = data['ids'];
    if (ids is List) {
      return ids.map((e) => (e as num).toInt()).toList();
    }
    return const [];
  }

  /// 把 liked IDs 转成 [Song]（批量请求 /song/detail）。
  Future<List<Song>> getSongsByIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final info = await _requireLogin();
    final c = ids.map((id) => {'id': id}).toList();
    final data = await _weApiPost(
      path: '/weapi/v3/song/detail',
      params: {
        'c': c.map((e) => jsonEncode(e)).toList(),
      },
      cookie: info.cookie,
    );
    final songs = data['songs'];
    if (songs is! List) return const [];
    return songs
        .map((s) => _songFromDetail(s as Map, source: 'netease'))
        .toList(growable: false);
  }

  /// 用户创建 + 收藏的歌单（默认创建歌单在前面，含「我喜欢的音乐」）。
  Future<List<NeteaseUserPlaylist>> getUserPlaylist({int uid = 0}) async {
    final info = await _requireLogin();
    final targetUid = uid == 0 ? info.uid : uid;
    final data = await _weApiPost(
      path: '/weapi/user/playlist',
      params: {
        'uid': targetUid.toString(),
        'offset': '0',
        'limit': '1000',
      },
      cookie: info.cookie,
    );
    final list = data['playlist'];
    if (list is! List) return const [];
    return list
        .map((p) {
          final m = p as Map;
          return NeteaseUserPlaylist(
            id: (m['id'] as num).toInt(),
            name: (m['name'] as String?) ?? '',
            coverUrl: (m['coverImgUrl'] as String?) ?? '',
            trackCount: (m['trackCount'] as num?)?.toInt() ?? 0,
            creatorId: (m['creator'] is Map)
                ? ((m['creator'] as Map)['userId'] as num?)?.toInt() ?? 0
                : 0,
            creatorName: (m['creator'] is Map)
                ? ((m['creator'] as Map)['nickname'] as String?) ?? ''
                : '',
          );
        })
        .toList(growable: false);
  }

  /// 歌单详情（含每首歌的 id + name + 歌手 + 专辑）
  Future<List<Song>> getPlaylistSongs(int playlistId) async {
    final info = await _requireLogin();
    final data = await _weApiPost(
      path: '/weapi/v3/playlist/detail',
      params: {
        'id': playlistId.toString(),
        'n': '1000',
        's': '0',
      },
      cookie: info.cookie,
    );
    final pl = data['playlist'];
    if (pl is! Map) return const [];
    final tracks = pl['tracks'];
    if (tracks is! List) return const [];
    return tracks
        .map((t) => _songFromDetail(t as Map, source: 'netease'))
        .toList(growable: false);
  }

  // --- 私有 ---

  Future<NeteaseLoginInfo> _requireLogin() async {
    final info = await NeteaseLoginService.instance.load();
    if (info == null || !info.cookie.contains('MUSIC_U=')) {
      throw const NeedLogin();
    }
    if (info.uid > 0) return info;
    // uid 缺失（Cookie 导入 / WebView 官方登录场景）：先拉一次账号信息补全，
    // 否则「我喜欢的」「我的歌单」会因为 uid=0 拉不到任何数据。
    try {
      final data = await _weApiPost(
        path: '/weapi/nuser/account/get',
        params: const {},
        cookie: info.cookie,
      );
      final profile = data['profile'] is Map ? data['profile'] as Map : const {};
      final uid = (profile['userId'] as num?)?.toInt() ?? 0;
      if (uid > 0) {
        final nickname = (profile['nickname'] as String?) ?? '';
        final avatarUrl = (profile['avatarUrl'] as String?) ?? '';
        await NeteaseLoginService.instance.updateProfile(
          nickname: nickname,
          avatarUrl: avatarUrl,
          uid: uid,
        );
        return NeteaseLoginInfo(
          cookie: info.cookie,
          nickname: nickname,
          avatarUrl: avatarUrl,
          uid: uid,
        );
      }
    } catch (e) {
      debugPrint('[NeteaseUser] fill uid failed: $e');
    }
    return info;
  }

  Future<Map> _weApiPost({
    required String path,
    required Map<String, dynamic> params,
    required String cookie,
  }) async {
    final encoded = NeteaseCrypto.weapi(params);
    // weapi 接口需要在 URL 带上 csrf_token（取自 cookie 的 __csrf），否则可能被服务端拒绝
    final csrf = RegExp(r'__csrf=([^;]+)').firstMatch(cookie)?.group(1) ?? '';
    final sep = path.contains('?') ? '&' : '?';
    // 手动 urlencode 请求体：避免 Dio 对「Map + formUrlEncoded」的自动编码差异
    // 导致最终发出的 body 不是 params&encSecKey 形式（服务端会返回空）。
    final body = 'params=${Uri.encodeComponent(encoded['params'] ?? '')}'
        '&encSecKey=${Uri.encodeComponent(encoded['encSecKey'] ?? '')}';
    final resp = await _dio.post(
      '$_host$path${sep}csrf_token=$csrf',
      data: body,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Cookie': 'os=pc; appver=3.1.17; $cookie'},
        responseType: ResponseType.plain,
      ),
    );
    final raw = resp.data is String ? resp.data as String : '';
    debugPrint(
      '[NeteaseUser] $path status=${resp.statusCode} len=${raw.length} '
      '${raw.isEmpty ? '(empty)' : (raw.length > 220 ? raw.substring(0, 220) : raw)}',
    );
    if (raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    // 服务端 code=301 = 需要登录 / 登录态已失效
    if ((decoded['code'] as num?)?.toInt() == 301) {
      throw const NeteaseAuthExpired();
    }
    return decoded;
  }

  Song _songFromDetail(Map m, {required String source}) {
    final artists = (m['ar'] as List?) ?? (m['artists'] as List?) ?? const [];
    final artistNames = artists
        .map((a) => (a is Map ? (a['name'] as String?) : null) ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    final album = m['al'] is Map
        ? m['al'] as Map
        : (m['album'] is Map ? m['album'] as Map : const {});
    final id = ((m['id'] as num?) ?? 0).toInt();
    final durationMs = (m['dt'] as num?)?.toInt() ?? (m['duration'] as num?)?.toInt() ?? 0;
    return Song(
      id: id.toString(),
      title: (m['name'] as String?) ?? '',
      artist: artistNames.isEmpty ? '未知' : artistNames.join('、'),
      album: (album['name'] as String?) ?? '',
      duration: (durationMs / 1000).round(),
      source: source,
      coverUrl: (album['picUrl'] as String?) ?? (m['picUrl'] as String?) ?? '',
    );
  }
}

class NeteaseUserProfile {
  final int uid;
  final String nickname;
  final String avatarUrl;
  final String signature;

  const NeteaseUserProfile({
    required this.uid,
    required this.nickname,
    required this.avatarUrl,
    required this.signature,
  });
}

class NeteaseUserPlaylist {
  final int id;
  final String name;
  final String coverUrl;
  final int trackCount;
  final int creatorId;
  final String creatorName;

  const NeteaseUserPlaylist({
    required this.id,
    required this.name,
    required this.coverUrl,
    required this.trackCount,
    required this.creatorId,
    required this.creatorName,
  });
}

class NeedLogin implements Exception {
  const NeedLogin();
  @override
  String toString() => '需要先登录网易云音乐';
}

/// 网易云登录态已失效（服务端返回 code=301），需要重新登录。
/// 与 [NeedLogin]（从未登录）区分开，便于 UI 给出「登录已过期，请重新登录」的提示。
class NeteaseAuthExpired implements Exception {
  const NeteaseAuthExpired();
  @override
  String toString() => '网易云登录已过期，请重新登录';
}