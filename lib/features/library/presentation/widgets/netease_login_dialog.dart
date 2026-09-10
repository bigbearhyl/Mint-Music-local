import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../shared/widgets/song_list_item.dart';
import '../../../player/application/playback_controller.dart';
import '../../../player/domain/models/song.dart';
import '../../../plugin/data/netease_login_service.dart';
import '../../../plugin/data/netease_user_service.dart';
import '../../../plugin/data/netease_music_source.dart';
import 'netease_web_login_page.dart';

/// 网易云扫码登录弹窗。
///
/// 显示二维码 + 轮询扫码状态；登录成功后保存 cookie 并注入内置网易云源。
Future<bool?> showNeteaseLoginDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => const _NeteaseLoginDialog(),
  );
}

class _NeteaseLoginDialog extends ConsumerStatefulWidget {
  const _NeteaseLoginDialog();

  @override
  ConsumerState<_NeteaseLoginDialog> createState() => _NeteaseLoginDialogState();
}

class _NeteaseLoginDialogState extends ConsumerState<_NeteaseLoginDialog> {
  String? _unikey;
  String _status = '初始化中...';
  Timer? _pollTimer;
  bool _scanned = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final key = await NeteaseLoginService.instance.getQrKey();
    if (!mounted) return;
    if (key == null || key.isEmpty) {
      setState(() {
        _status = '获取二维码失败，请重试';
        _loading = false;
      });
      return;
    }
    setState(() {
      _unikey = key;
      _status = '请用网易云 App 扫码';
      _loading = false;
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    final key = _unikey;
    if (key == null) return;
    final r = await NeteaseLoginService.instance.checkQrStatus(key);
    if (!mounted) return;
    if (r == null) {
      setState(() => _status = '等待扫码...');
    } else if (r == 'scan') {
      if (!_scanned) {
        setState(() {
          _status = '已扫码，请在手机上点确认';
          _scanned = true;
        });
      }
    } else if (r == 'expire') {
      _pollTimer?.cancel();
      setState(() => _status = '二维码已过期，正在重新生成...');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      setState(() {
        _unikey = null;
        _loading = true;
        _scanned = false;
      });
      _start();
    } else if (r is Map) {
      _pollTimer?.cancel();
      setState(() => _status = '登录失败：${r['message'] ?? '未知错误'}');
    } else if (r is NeteaseLoginInfo) {
      _pollTimer?.cancel();
      // 注入到内置源
      NeteaseMusicSource.loginCookie = r.cookie;
      setState(() => _status = '登录成功 ✓');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  /// 打开网易云「官方网页登录」：内嵌官方页面登录，避开第三方 API 的 8821 风控。
  Future<void> _openWebLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const NeteaseWebLoginPage()),
    );
    if (!mounted) return;
    if (ok == true) {
      _pollTimer?.cancel();
      setState(() => _status = '登录成功 ✓');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  /// 「粘贴 Cookie 登录」：网易云扫码被行为验证码风控时的最稳替代方案。
  Future<void> _openCookieInput() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('粘贴 Cookie 登录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '1. 电脑浏览器登录 music.163.com\n'
              '2. 按 F12 → Network → 刷新页面 → 点任一请求\n'
              '3. 复制 Request Headers 里 Cookie 的整段内容\n'
              '4. 粘贴到下面（需含 MUSIC_U）',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'MUSIC_U=...; __csrf=...; NMTID=...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    final svc = NeteaseLoginService.instance;
    final ok = await svc.importCookie(text);
    if (!mounted) return;
    if (!ok) {
      setState(() => _status = 'Cookie 无效：未找到 MUSIC_U');
      return;
    }
    // 用 Cookie 拉一次用户资料，补全昵称/头像/uid（uid 是「我的歌单」接口必需）
    try {
      final p = await NeteaseUserService.instance.getUserAccount();
      await svc.updateProfile(
        nickname: p.nickname,
        avatarUrl: p.avatarUrl,
        uid: p.uid,
      );
    } catch (_) {}
    final info = await svc.load();
    NeteaseMusicSource.loginCookie = info?.cookie ?? '';
    if (!mounted) return;
    setState(() => _status = '登录成功 ✓');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final qrUrl = _unikey == null
        ? ''
        : 'https://music.163.com/login?codekey=$_unikey';
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_sync, color: Color(0xFFC62F2F)),
                const SizedBox(width: 8),
                Text(
                  '网易云音乐登录',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, color: colors.textSecondary),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _loading
                  ? const SizedBox(
                      height: 200,
                      width: 200,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : (_unikey == null || _unikey!.isEmpty
                      ? GestureDetector(
                          onTap: () {
                            setState(() {
                              _loading = true;
                              _status = '重试中...';
                            });
                            _start();
                          },
                          child: Container(
                            height: 200,
                            width: 200,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.refresh,
                                    size: 36, color: Colors.grey),
                                SizedBox(height: 8),
                                Text('点击重试',
                                    style: TextStyle(color: Colors.grey)),
                              ],
                            ),
                          ),
                        )
                      : QrImageView(
                          data: qrUrl,
                          size: 200,
                          backgroundColor: Colors.white,
                        )),
            ),
            const SizedBox(height: 12),
            Text(
              _status,
              style: TextStyle(color: colors.textSecondary, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              '登录后可在「我的音乐」查看喜欢的音乐和歌单',
              style: TextStyle(color: colors.textHint, fontSize: 11),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _openWebLogin,
              child: const Text('打开网易云官方登录页（推荐）'),
            ),
            TextButton(
              onPressed: _openCookieInput,
              child: const Text('或：手动粘贴 Cookie 登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「我的音乐」页：账号信息 + 喜欢的音乐 + 我的歌单（Tab 视图）。
class NeteaseMusicPage extends ConsumerStatefulWidget {
  const NeteaseMusicPage({super.key});

  @override
  ConsumerState<NeteaseMusicPage> createState() => _NeteaseMusicPageState();
}

class _NeteaseMusicPageState extends ConsumerState<NeteaseMusicPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        title: const Text('我的音乐 · 网易云'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Color(0xFFC62F2F)),
            tooltip: '退出登录',
            onPressed: _logout,
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          labelColor: const Color(0xFFC62F2F),
          unselectedLabelColor: colors.textSecondary,
          indicatorColor: const Color(0xFFC62F2F),
          tabs: const [
            Tab(text: '账号'),
            Tab(text: '我喜欢的'),
            Tab(text: '我的歌单'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _NeteaseAccountTab(),
          _NeteaseLikedTab(),
          _NeteasePlaylistsTab(),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出网易云登录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await NeteaseLoginService.instance.clear();
    NeteaseMusicSource.loginCookie = '';
    if (mounted) Navigator.of(context).pop();
  }
}

class _NeteaseAccountTab extends ConsumerStatefulWidget {
  const _NeteaseAccountTab();

  @override
  ConsumerState<_NeteaseAccountTab> createState() => _NeteaseAccountTabState();
}

class _NeteaseAccountTabState extends ConsumerState<_NeteaseAccountTab> {
  NeteaseUserProfile? _profile;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await NeteaseUserService.instance.getUserAccount();
      if (!mounted) return;
      setState(() {
        _profile = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: colors.textHint, size: 48),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: colors.textSecondary)),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final p = _profile!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundImage:
                    p.avatarUrl.isNotEmpty ? NetworkImage(p.avatarUrl) : null,
                radius: 32,
                child: p.avatarUrl.isEmpty
                    ? const Icon(Icons.person, size: 32)
                    : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.nickname,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'UID: ${p.uid}',
                      style: TextStyle(
                          color: colors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (p.signature.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                p.signature,
                style: TextStyle(color: colors.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NeteaseLikedTab extends ConsumerStatefulWidget {
  const _NeteaseLikedTab();

  @override
  ConsumerState<_NeteaseLikedTab> createState() => _NeteaseLikedTabState();
}

class _NeteaseLikedTabState extends ConsumerState<_NeteaseLikedTab> {
  List<Song> _songs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ids = await NeteaseUserService.instance.getLikelist();
      final songs = await NeteaseUserService.instance.getSongsByIds(ids);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: colors.textSecondary)));
    }
    if (_songs.isEmpty) {
      return const Center(child: Text('还没有喜欢的音乐'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _songs.length,
        itemBuilder: (ctx, i) {
          final s = _songs[i];
          return SongListItem(
            song: s,
            onTap: () {
              ref
                  .read(playbackControllerProvider.notifier)
                  .setQueue([..._songs.sublist(i), ..._songs.sublist(0, i)]);
            },
          );
        },
      ),
    );
  }
}

class _NeteasePlaylistsTab extends ConsumerStatefulWidget {
  const _NeteasePlaylistsTab();

  @override
  ConsumerState<_NeteasePlaylistsTab> createState() =>
      _NeteasePlaylistsTabState();
}

class _NeteasePlaylistsTabState extends ConsumerState<_NeteasePlaylistsTab> {
  List<NeteaseUserPlaylist> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await NeteaseUserService.instance.getUserPlaylist();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: colors.textSecondary)));
    }
    if (_items.isEmpty) {
      return const Center(child: Text('还没有歌单'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (ctx, i) {
          final p = _items[i];
          return ListTile(
            leading: SizedBox(
              width: 48,
              height: 48,
              child: p.coverUrl.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        p.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: colors.surface,
                          child: Icon(Icons.queue_music, color: colors.textHint),
                        ),
                      ),
                    )
                  : Container(
                      color: colors.surface,
                      child: Icon(Icons.queue_music, color: colors.textHint),
                    ),
            ),
            title: Text(p.name, style: TextStyle(color: colors.textPrimary)),
            subtitle: Text(
              '${p.trackCount} 首',
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NeteasePlaylistDetailPage(playlist: p),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class NeteasePlaylistDetailPage extends ConsumerStatefulWidget {
  final NeteaseUserPlaylist playlist;
  const NeteasePlaylistDetailPage({super.key, required this.playlist});

  @override
  ConsumerState<NeteasePlaylistDetailPage> createState() =>
      _NeteasePlaylistDetailPageState();
}

class _NeteasePlaylistDetailPageState
    extends ConsumerState<NeteasePlaylistDetailPage> {
  List<Song> _songs = const [];
  List<Song> _displaySongs = const [];
  bool _loading = true;
  String? _error;
  int _sortMode = 0; // 0 默认 1 歌名 2 歌手 3 时长

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final songs = await NeteaseUserService.instance
          .getPlaylistSongs(widget.playlist.id);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loading = false;
      });
      _applySort();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _applySort() {
    final list = [..._songs];
    if (_sortMode == 1) {
      list.sort((a, b) => a.title.compareTo(b.title));
    } else if (_sortMode == 2) {
      list.sort((a, b) => a.artist.compareTo(b.artist));
    } else if (_sortMode == 3) {
      list.sort((a, b) => a.duration.compareTo(b.duration));
    }
    if (!mounted) return;
    setState(() => _displaySongs = list);
  }

  void _cycleSort() {
    setState(() => _sortMode = (_sortMode + 1) % 4);
    _applySort();
  }

  String get _sortLabel {
    switch (_sortMode) {
      case 1:
        return '按歌名';
      case 2:
        return '按歌手';
      case 3:
        return '按时长';
      default:
        return '默认排序';
    }
  }

  Future<void> _playAt(int index) async {
    if (_displaySongs.isEmpty) return;
    final queue = [
      ..._displaySongs.sublist(index),
      ..._displaySongs.sublist(0, index),
    ];
    await ref.read(playbackControllerProvider.notifier).setQueue(queue);
  }

  Widget _actionButton(
    ThemeColors colors,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFC62F2F),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sortButton(ThemeColors colors) {
    return GestureDetector(
      onTap: _cycleSort,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert, size: 14, color: colors.textSecondary),
            const SizedBox(width: 4),
            Text(
              _sortLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: colors.surface,
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.playlist.coverUrl.isNotEmpty
                ? Image.network(
                    widget.playlist.coverUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.queue_music,
                      size: 36,
                      color: colors.textHint,
                    ),
                  )
                : Icon(Icons.queue_music, size: 36, color: colors.textHint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.playlist.name,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '来自网易云音乐 · ${_songs.length}首歌曲',
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _actionButton(
                      colors,
                      Icons.play_arrow,
                      context.tr('播放全部'),
                      () => _playAt(0),
                    ),
                    const SizedBox(width: 8),
                    _actionButton(
                      colors,
                      Icons.shuffle,
                      context.tr('随机播放'),
                      () {
                        final songs = [..._displaySongs]..shuffle();
                        if (songs.isEmpty) return;
                        ref
                            .read(playbackControllerProvider.notifier)
                            .setQueue(songs);
                      },
                    ),
                    const SizedBox(width: 8),
                    _sortButton(colors),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        title: Text(widget.playlist.name),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _songs.isEmpty
                  ? const Center(child: Text('空歌单'))
                  : CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: _buildHeader(colors),
                        ),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (ctx, i) {
                              final s = _displaySongs[i];
                              return SongListItem(
                                song: s,
                                onTap: () => _playAt(i),
                              );
                            },
                            childCount: _displaySongs.length,
                          ),
                        ),
                      ],
                    ),
    );
  }
}