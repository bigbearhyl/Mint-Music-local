import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../player/domain/models/song.dart';
import 'qq_login_service.dart';

/// QQ 音乐「我的」数据快照：我喜欢的歌曲、自建歌单、收藏（订阅）歌单。
///
/// 全部走 musicu.fcg 带登录态（与 iMusic 同款 comm + authst + cookie）。
/// 未登录时调用返回 null，不影响匿名听歌。
class QqUserService {
  static const String _musicu = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      contentType: 'application/json',
    ),
  );

  /// 固定设备指纹（首次生成后存内存，避免每次随机）
  static final String _guid = _randomHex(32);
  static final String _qimei36 = _randomHex(36);
  static final String _aid = _randomHex(16);

  /// 一次拉齐「我的音乐」三个分类（与 iMusic 收藏页同源数据）：
  /// 我的喜欢(dirid=201) / 自建歌单(GetPlaylistByUin) / 收藏歌单(CgiGetPlaylistFavInfo)
  Future<QqUserSnapshot?> loadSnapshot() async {
    final login = await QqLoginService.instance.load();
    if (login == null) return null;

    var favSongs = const <Song>[];
    var favTotal = 0;
    var selfPlaylists = const <QqPlaylist>[];
    var collectedPlaylists = const <QqPlaylist>[];

    // 我喜欢的音乐（dirid=201）
    final fav = await _dissSongs(
      login,
      tid: 0,
      dirid: 201,
      num: 300,
      encHostUin: login.encryptUin,
    );
    favSongs = fav?.songs ?? const [];
    favTotal = fav?.total ?? 0;

    // 自建歌单（uin 必须是字符串，传数字会 10006）
    try {
      final req = await _musicuAuth(
        login,
        'music.musicasset.PlaylistBaseRead',
        'GetPlaylistByUin',
        {'uin': login.uin},
      );
      final list = _dataList(req, 'v_playlist');
      selfPlaylists = list
          .map((item) => _playlistFrom(item, kind: QqPlaylistKind.self))
          .whereType<QqPlaylist>()
          .toList();
    } catch (_) {}

    // 收藏（订阅）歌单：创建者加密 uin 是必须参数
    final euin = login.encryptUin;
    if (euin.isNotEmpty) {
      try {
        final req = await _musicuAuth(
          login,
          'music.musicasset.PlaylistFavRead',
          'CgiGetPlaylistFavInfo',
          {'uin': euin, 'offset': 0, 'size': 200},
        );
        final list = _dataList(req, 'v_list');
        collectedPlaylists = list
            .map((item) => _playlistFrom(item, kind: QqPlaylistKind.collected))
            .whereType<QqPlaylist>()
            .toList();
      } catch (_) {}
    }

    return QqUserSnapshot(
      favSongs: favSongs,
      favTotal: favTotal > 0 ? favTotal : favSongs.length,
      selfPlaylists: selfPlaylists,
      collectedPlaylists: collectedPlaylists,
    );
  }

  /// 歌单歌曲（tid=歌单 id；dirid 仅"我喜欢"传 201；encHostUin 传歌单创建者加密 uin）
  Future<List<Song>> playlistSongs({
    required int tid,
    int dirid = 0,
    String? encHostUin,
    int begin = 0,
    int num = 300,
  }) async {
    final login = await QqLoginService.instance.load();
    if (login == null) return const [];
    final r = await _dissSongs(
      login,
      tid: tid,
      dirid: dirid,
      begin: begin,
      num: num,
      encHostUin: encHostUin ?? login.encryptUin,
    );
    return r?.songs ?? const [];
  }

  /// 我喜欢的音乐（QQ 收藏歌曲：disstid=0 / dirid=201）
  Future<List<Song>> favoriteSongs({int begin = 0, int num = 300}) async {
    final login = await QqLoginService.instance.load();
    if (login == null) return const [];
    final r = await _dissSongs(
      login,
      tid: 0,
      dirid: 201,
      begin: begin,
      num: num,
      encHostUin: login.encryptUin,
    );
    return r?.songs ?? const [];
  }

  // ---------- 内部 ----------

  Future<QqDissResult?> _dissSongs(
    QqLoginInfo login, {
    required int tid,
    required int dirid,
    int begin = 0,
    int num = 300,
    required String encHostUin,
  }) async {
    try {
      final req = await _musicuAuth(login, 'music.srfDissInfo.DissInfo', 'CgiGetDiss', {
        'disstid': tid,
        'dirid': dirid,
        'tag': true,
        'song_begin': begin,
        'song_num': num,
        'userinfo': true,
        'orderlist': true,
        'enc_host_uin': encHostUin,
      });
      final data = req?['data'];
      final list = data is Map ? data['songlist'] : null;
      final songs = (list is List ? list : const [])
          .map(_songFrom)
          .whereType<Song>()
          .toList();
      var total = 0;
      final dir = data is Map ? data['dirinfo'] : null;
      if (dir is Map) total = _asInt(dir['songnum']);
      if (total <= 0 && data is Map) total = _asInt(data['total_song_num']);
      if (songs.isEmpty && total <= 0) return null;
      return QqDissResult(songs: songs, total: total > 0 ? total : songs.length);
    } catch (_) {
      return null;
    }
  }

  List<dynamic> _dataList(Map<String, dynamic>? req, String key) {
    if (req == null) return const [];
    final data = req['data'];
    if (data is! Map) return const [];
    final list = data[key];
    return list is List ? list : const [];
  }

  // ---------- musicu 带登录态（iMusic 同款） ----------

  Future<Map<String, dynamic>?> _musicuAuth(
    QqLoginInfo login,
    String module,
    String method,
    Map<String, dynamic> param,
  ) async {
    final comm = <String, dynamic>{
      'ct': 11,
      'cv': 14090008,
      'v': 14090008,
      'chid': '10003505',
      'tmeAppID': 'qqmusic',
      'QIMEI': _qimei36,
      'QIMEI36': _qimei36,
      'OpenUDID': _guid,
      'OpenUDID2': _guid,
      'udid': _guid,
      'aid': _aid,
      'os_ver': '14',
      'phonetype': 'Android',
      'devicelevel': '34',
      'newdevicelevel': '34',
      'rom': 'google/webview',
      'uin': int.tryParse(login.uin) ?? login.uin,
      'qm_keyst': login.musickey,
      'tmeLoginType': 2,
      'authst': login.musickey,
      'g_tk': login.gTk,
      'g_tk_new_20200303': login.gTk,
    };
    final payload = {
      'comm': comm,
      'req_0': {'module': module, 'method': method, 'param': param},
    };
    final resp = await _dio.post(
      _musicu,
      data: jsonEncode(payload),
      options: Options(
        headers: {
          'User-Agent': _ua,
          'Referer': 'https://y.qq.com/',
          'Cookie': login.cookie,
        },
      ),
    );
    final root = resp.data is String ? jsonDecode(resp.data) : resp.data;
    if (root is! Map) return null;
    final req = root['req_0'];
    return req is Map ? Map<String, dynamic>.from(req) : null;
  }

  // ---------- 数据映射 ----------

  QqPlaylist? _playlistFrom(dynamic item, {required QqPlaylistKind kind}) {
    if (item is! Map) return null;
    final tid = _asInt(item['tid'] ?? item['dissid'] ?? item['disstid']);
    if (tid <= 0) return null;
    final dirid = _asInt(item['dirid'] ?? item['dirId'] ?? item['dirID']);
    // 201=我喜欢 205/206=系统夹（最近播放等），不算自建/收藏歌单
    if (kind == QqPlaylistKind.self && (dirid == 201 || dirid == 205 || dirid == 206)) {
      return null;
    }
    final name =
        (item['dirName'] ?? item['name'] ?? item['dissname'] ?? item['diss_name'] ?? item['title'])
                ?.toString() ??
            '';
    if (name.isEmpty) return null;
    final songnum = _asInt(
      item['songNum'] ?? item['songnum'] ?? item['song_cnt'] ?? item['song_num'],
    );
    var cover = (item['picUrl'] ?? item['logo'] ?? item['bigpicUrl'] ??
            item['cover'] ?? item['picurl'] ?? item['albumPicUrl'] ?? '')
        .toString();
    if (cover.startsWith('http://')) cover = 'https://${cover.substring(7)}';
    // 创建者加密 uin（收藏歌单取歌时作 encHostUin）
    final hostUin = (item['uin'] ?? item['encrypt_uin'] ?? '').toString();
    return QqPlaylist(
      tid: tid,
      dirid: dirid,
      title: name,
      songCount: songnum,
      coverUrl: cover,
      kind: kind,
      encHostUin: hostUin.startsWith('o') || hostUin.contains('*') ? hostUin : '',
    );
  }

  Song? _songFrom(dynamic item) {
    if (item is! Map) return null;
    final mid = (item['mid'] ?? item['songmid'])?.toString() ?? '';
    if (mid.isEmpty) return null;
    String singerName = '';
    final singers = item['singer'];
    if (singers is List) {
      singerName = singers
          .map((s) => s is Map ? (s['name']?.toString() ?? '') : '')
          .where((s) => s.isNotEmpty)
          .join('、');
    } else if (singers is String) {
      singerName = singers;
    }
    String albumName = '';
    String albumMid = '';
    final album = item['album'];
    if (album is Map) {
      albumName = album['name']?.toString() ?? '';
      albumMid = album['mid']?.toString() ?? '';
    }
    if (albumMid.isEmpty) albumMid = item['albummid']?.toString() ?? '';
    final cover = albumMid.isNotEmpty
        ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg'
        : null;
    final songId = _asInt(item['id'] ?? item['songid']);
    return Song(
      id: 'tx_$mid',
      title: (item['title'] ?? item['name'] ?? '').toString(),
      artist: singerName,
      album: albumName,
      duration: _asInt(item['interval']),
      coverUrl: cover,
      source: 'tx',
      lyricUrl: songId > 0 ? songId.toString() : null,
      lx: {
        'songmid': mid,
        if (songId > 0) 'songId': songId,
        'name': (item['title'] ?? item['name'] ?? '').toString(),
        'singer': singerName,
        'albumName': albumName,
        if (albumMid.isNotEmpty) 'albumMid': albumMid,
        'interval': _asInt(item['interval']).toString(),
      },
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _randomHex(int n) {
    const chars = '0123456789abcdef';
    final rnd = Random();
    return String.fromCharCodes(
      Iterable.generate(n, (_) => chars.codeUnitAt(rnd.nextInt(16))),
    );
  }
}

enum QqPlaylistKind { self, collected }

/// 「我的音乐」一屏数据
class QqUserSnapshot {
  final List<Song> favSongs;
  final int favTotal;
  final List<QqPlaylist> selfPlaylists;
  final List<QqPlaylist> collectedPlaylists;

  const QqUserSnapshot({
    required this.favSongs,
    required this.favTotal,
    required this.selfPlaylists,
    required this.collectedPlaylists,
  });
}

class QqDissResult {
  final List<Song> songs;
  final int total;
  const QqDissResult({required this.songs, required this.total});
}

/// QQ 歌单（自建或收藏）。取歌需要 tid/dirid/创建者加密 uin 三元组。
class QqPlaylist {
  final int tid;
  final int dirid;
  final String title;
  final int songCount;
  final String coverUrl;
  final QqPlaylistKind kind;
  final String encHostUin;

  const QqPlaylist({
    required this.tid,
    required this.dirid,
    required this.title,
    required this.songCount,
    required this.coverUrl,
    required this.kind,
    this.encHostUin = '',
  });
}
