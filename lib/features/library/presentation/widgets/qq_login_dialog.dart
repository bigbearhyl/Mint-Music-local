import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/theme_provider.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../shared/widgets/song_action_sheet.dart';
import '../../../../shared/widgets/song_list_item.dart';
import '../../../player/application/playback_controller.dart';
import '../../../player/domain/models/song.dart';
import '../../../plugin/application/plugin_providers.dart';
import '../../../plugin/data/qq_login_service.dart';
import '../../../plugin/data/qq_user_service.dart';

/// QQ 音乐扫码登录弹窗（iMusic 同款流程）。
///
/// 未登录：显示二维码 + 轮询扫码状态；已登录：显示账号与退出登录。
/// 登录成功后把 cookie 注入内置 QQ 音源并重载，音质可提升到 320k/flac。
Future<bool?> showQqLoginDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => const _QqLoginDialog(),
  );
}

class _QqLoginDialog extends ConsumerStatefulWidget {
  const _QqLoginDialog();

  @override
  ConsumerState<_QqLoginDialog> createState() => _QqLoginDialogState();
}

class _QqLoginDialogState extends ConsumerState<_QqLoginDialog> {
  QrStart? _qr;
  String _statusText = '';
  bool _loading = true;
  bool _done = false;
  bool _stopped = false;
  QqLoginInfo? _loggedIn;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final info = await QqLoginService.instance.load();
    if (!mounted) return;
    if (info != null) {
      setState(() {
        _loggedIn = info;
        _loading = false;
      });
      // 静默续期：credential 里的 refresh_key 换新 musickey，成功后重载注入
      unawaited(_refreshCredential());
      return;
    }
    await _startQr();
    unawaited(_pollLoop());
  }

  Future<void> _refreshCredential() async {
    final ok = await QqLoginService.instance.refresh();
    if (!ok) return;
    final info = await QqLoginService.instance.load();
    if (!mounted || info == null) return;
    setState(() => _loggedIn = info);
    await ref.read(pluginServiceProvider).reloadBuiltInSources();
  }

  Future<void> _startQr() async {
    try {
      final qr = await QqLoginService.instance.getQr();
      if (!mounted) return;
      setState(() {
        _qr = qr;
        _loading = false;
        _statusText = context.tr('请使用 QQ 音乐 App 扫码');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _qr = null;
        _statusText = context.tr('二维码获取失败，请检查网络后重试');
      });
    }
  }

  /// 串行轮询：服务端长轮询约 15s，绝不能并发叠请求（会把中转服务的
  /// mqtt 会话打到 500001），上一轮返回后再发起下一轮。
  Future<void> _pollLoop() async {
    var anomalies = 0;
    while (mounted && !_stopped && !_done && _qr != null) {
      final r = await QqLoginService.instance.poll(_qr!.identifier);
      if (!mounted || _stopped || _done) return;
      switch (r.status) {
        case QrStatus.done:
          _done = true;
          // 先关弹窗，再后台重载注入 cookie：重载会重建 JS 引擎耗时较长，
          // 不能阻塞在弹窗上
          final service = ref.read(pluginServiceProvider);
          Navigator.of(context).pop(true);
          unawaited(service.reloadBuiltInSources());
          return;
        case QrStatus.scanned:
          anomalies = 0;
          setState(() => _statusText = context.tr('已扫码，请在手机上确认'));
          break;
        case QrStatus.confirmed:
          anomalies = 0;
          setState(() => _statusText = context.tr('确认中...'));
          break;
        case QrStatus.expired:
          setState(() => _statusText = context.tr('二维码已过期，正在刷新...'));
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!mounted || _stopped) return;
          await _startQr();
          continue;
        case QrStatus.refused:
          _qr = null;
          setState(() => _statusText = context.tr('已取消登录'));
          return;
        case QrStatus.error:
          _qr = null;
          setState(() => _statusText = r.message ?? context.tr('登录失败'));
          return;
        case QrStatus.waiting:
          // 连续拿不到有效事件（中转服务 mqtt 会话失效等）→ 换新二维码重来
          if (r.anomalous) {
            anomalies++;
            if (anomalies >= 3) {
              anomalies = 0;
              await _startQr();
              continue;
            }
          } else {
            anomalies = 0;
          }
          break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  Future<void> _restart() async {
    setState(() => _loading = true);
    await _startQr();
    unawaited(_pollLoop());
  }

  Future<void> _logout() async {
    _stopped = true;
    await QqLoginService.instance.logout();
    final service = ref.read(pluginServiceProvider);
    if (!mounted) return;
    Navigator.of(context).pop(true);
    unawaited(service.reloadBuiltInSources());
  }

  @override
  void dispose() {
    _stopped = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr('QQ 音乐扫码登录'),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 20),
            if (_loading)
              const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loggedIn != null)
              _buildLoggedIn(colors)
            else if (_qr != null)
              Image.memory(
                Uint8List.fromList(_qr!.bytes),
                width: 200,
                height: 200,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.broken_image, size: 60),
              )
            else
              const SizedBox(
                height: 200,
                child: Center(child: Icon(Icons.error_outline, size: 60)),
              ),
            const SizedBox(height: 16),
            Text(
              _loggedIn != null
                  ? context.tr('登录态已注入内置 QQ 音源')
                  : _statusText,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_loggedIn == null && _qr == null && !_loading)
                  TextButton(
                    onPressed: _restart,
                    child: Text(context.tr('重新获取')),
                  ),
                if (_loggedIn != null)
                  TextButton(
                    onPressed: _logout,
                    child: Text(
                      context.tr('退出登录'),
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(context.tr('关闭')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoggedIn(ThemeColors colors) {
    return Column(
      children: [
        const Icon(Icons.check_circle, size: 64, color: Color(0xFF31C27C)),
        const SizedBox(height: 12),
        Text(
          context.tr('已登录 QQ 音乐'),
          style: TextStyle(fontSize: 16, color: colors.textPrimary),
        ),
        const SizedBox(height: 6),
        Text(
          'QQ 号 ${_loggedIn!.uin}',
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// QQ 我的音乐页：三个分类胶囊（我的喜欢 / 自建歌单 / 收藏歌单），
/// 数据与 QQ 音乐 App 同步，与 iMusic 收藏页同款交互。
class QqMusicPage extends ConsumerStatefulWidget {
  const QqMusicPage({super.key});

  @override
  ConsumerState<QqMusicPage> createState() => _QqMusicPageState();
}

enum _QqTab { likes, self, collected }

class _QqMusicPageState extends ConsumerState<QqMusicPage> {
  final _service = QqUserService();
  bool _loading = true;
  String? _error;
  QqUserSnapshot? _snapshot;
  _QqTab _tab = _QqTab.likes;

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
      final snap = await _service.loadSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snap;
        _loading = false;
        if (snap != null) {
          if (_tab == _QqTab.self && snap.selfPlaylists.isEmpty) {
            _tab = _QqTab.likes;
          }
          if (_tab == _QqTab.collected && snap.collectedPlaylists.isEmpty) {
            _tab = _QqTab.likes;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _playFav(List<Song> songs, int index) async {
    if (songs.isEmpty) return;
    await ref
        .read(playbackControllerProvider.notifier)
        .setQueue(songs, startIndex: index);
  }

  Future<void> _openPlaylist(QqPlaylist p) async {
    // 进入歌单详情页查看歌曲列表，点选歌曲播放
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => QqPlaylistDetailPage(playlist: p)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final snap = _snapshot;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        title: Text(
          context.tr('QQ 我的音乐'),
          style: TextStyle(color: colors.textPrimary, fontSize: 18),
        ),
        iconTheme: IconThemeData(color: colors.textPrimary),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: context.tr('刷新'),
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: context.tr('退出登录'),
            onPressed: () async {
              await QqLoginService.instance.logout();
              final service = ref.read(pluginServiceProvider);
              if (!mounted) return;
              Navigator.of(context).pop();
              unawaited(service.reloadBuiltInSources());
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : snap == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.tr('尚未登录 QQ'),
                    style: TextStyle(color: colors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      final ok = await showQqLoginDialog(context);
                      if (ok == true) _load();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF31C27C),
                    ),
                    child: Text(context.tr('扫码登录')),
                  ),
                ],
              ),
            )
          : _error != null
          ? Center(
              child: Text(
                _error!,
                style: TextStyle(color: colors.textSecondary),
              ),
            )
          : Column(
              children: [
                _buildChips(colors, snap),
                Expanded(child: _buildContent(colors, snap)),
              ],
            ),
    );
  }

  Widget _buildChip(ThemeColors colors, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF31C27C) : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildChips(ThemeColors colors, QqUserSnapshot snap) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildChip(
              colors,
              '${context.tr('我的喜欢')}(${snap.favTotal})',
              _tab == _QqTab.likes,
              () => setState(() => _tab = _QqTab.likes),
            ),
            const SizedBox(width: 10),
            _buildChip(
              colors,
              '${context.tr('自建歌单')}(${snap.selfPlaylists.length})',
              _tab == _QqTab.self,
              () => setState(() => _tab = _QqTab.self),
            ),
            const SizedBox(width: 10),
            _buildChip(
              colors,
              '${context.tr('收藏歌单')}(${snap.collectedPlaylists.length})',
              _tab == _QqTab.collected,
              () => setState(() => _tab = _QqTab.collected),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(ThemeColors colors, QqUserSnapshot snap) {
    switch (_tab) {
      case _QqTab.likes:
        return _buildFavSongs(colors, snap.favSongs);
      case _QqTab.self:
        return _buildPlaylists(colors, snap.selfPlaylists, emptyText: context.tr('还没有自建歌单\n在QQ音乐APP里创建后点「刷新」即可显示'));
      case _QqTab.collected:
        return _buildPlaylists(colors, snap.collectedPlaylists, emptyText: context.tr('还没有收藏的歌单\n在QQ音乐APP里收藏后点「刷新」即可显示'));
    }
  }

  Widget _buildFavSongs(ThemeColors colors, List<Song> songs) {
    if (songs.isEmpty) {
      return Center(
        child: Text(
          context.tr('还没有喜欢的歌曲\n在QQ音乐APP里收藏后点「刷新」即可显示'),
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textSecondary, fontSize: 13, height: 1.6),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: songs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, i) {
        final s = songs[i];
        return ListTile(
          dense: true,
          leading: SizedBox(
            width: 26,
            child: Text(
              '${i + 1}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontStyle: FontStyle.italic,
                color: i < 3 ? const Color(0xFF31C27C) : colors.textHint,
              ),
            ),
          ),
          title: Text(
            s.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14.5, color: colors.textPrimary),
          ),
          subtitle: Text(
            s.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          trailing: s.coverUrl != null && s.coverUrl!.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    s.coverUrl!,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                )
              : null,
          onTap: () => _playFav(songs, i),
        );
      },
    );
  }

  Widget _buildPlaylists(ThemeColors colors, List<QqPlaylist> list, {required String emptyText}) {
    if (list.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textSecondary, fontSize: 13, height: 1.6),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, i) {
        final p = list[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: p.coverUrl.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    p.coverUrl,
                    width: 52,
                    height: 52,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.queue_music,
                      size: 36,
                    ),
                  ),
                )
              : const Icon(Icons.queue_music, size: 36),
          title: Text(
            p.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14.5, color: colors.textPrimary),
          ),
          subtitle: Text(
            '${p.songCount} ${context.tr('首')} · ${context.tr('点击查看')}',
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: colors.textSecondary,
          ),
          onTap: () => _openPlaylist(p),
        );
      },
    );
  }
}

/// QQ 歌单详情页：与本地歌单详情页同款布局
/// （大封面 + 播放全部/随机播放/排序 + SongListItem 列表 + 三点菜单）。
class QqPlaylistDetailPage extends ConsumerStatefulWidget {
  const QqPlaylistDetailPage({super.key, required this.playlist});

  final QqPlaylist playlist;

  @override
  ConsumerState<QqPlaylistDetailPage> createState() =>
      _QqPlaylistDetailPageState();
}

enum _QqSortMode { defaultOrder, title, artist }

class _QqPlaylistDetailPageState extends ConsumerState<QqPlaylistDetailPage> {
  final _service = QqUserService();
  bool _loading = true;
  String? _error;
  List<Song> _songs = const [];
  _QqSortMode _sortMode = _QqSortMode.defaultOrder;

  QqPlaylist get _p => widget.playlist;

  List<Song> get _displaySongs {
    switch (_sortMode) {
      case _QqSortMode.title:
        return [..._songs]..sort((a, b) => a.title.compareTo(b.title));
      case _QqSortMode.artist:
        return [..._songs]..sort((a, b) => a.artist.compareTo(b.artist));
      case _QqSortMode.defaultOrder:
        return _songs;
    }
  }

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
      final songs = await _service.playlistSongs(
        tid: _p.tid,
        dirid: _p.dirid,
        encHostUin: _p.encHostUin,
      );
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

  Future<void> _playAt(int index) async {
    final songs = _displaySongs;
    if (songs.isEmpty) return;
    await ref
        .read(playbackControllerProvider.notifier)
        .setQueue(songs, startIndex: index);
  }

  void _cycleSort() {
    final labels = {
      _QqSortMode.defaultOrder: context.tr('默认排序'),
      _QqSortMode.title: context.tr('已按歌名排序'),
      _QqSortMode.artist: context.tr('已按歌手排序'),
    };
    setState(() {
      _sortMode = _QqSortMode
          .values[(_sortMode.index + 1) % _QqSortMode.values.length];
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(labels[_sortMode] ?? ''),
      duration: const Duration(seconds: 1),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final songs = _displaySongs;
    return Scaffold(
      backgroundColor: colors.background,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.tr('加载失败，请下拉重试'),
                    style: TextStyle(color: colors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: Text(context.tr('重试'))),
                ],
              ),
            )
          : Column(
              children: [
                _buildHeader(colors),
                Expanded(
                  child: songs.isEmpty
                      ? Center(
                          child: Text(
                            context.tr('该歌单暂无可播放歌曲'),
                            style: TextStyle(color: colors.textSecondary),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(top: 4, bottom: 24),
                          itemCount: songs.length,
                          itemBuilder: (context, i) {
                            final song = songs[i];
                            return SongListItem(
                              song: song,
                              index: i,
                              onPlayTap: () => _playAt(i),
                              onMenuTap: () => SongActionSheet.show(
                                context,
                                song: song,
                                playlistSongs: songs,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colors.primary.withValues(alpha: 0.15),
            colors.background,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Icon(Icons.arrow_back, size: 24, color: colors.textPrimary),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _loading ? null : _load,
                child: Icon(Icons.refresh, size: 22, color: colors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: colors.surfaceVariant,
                ),
                clipBehavior: Clip.antiAlias,
                child: _p.coverUrl.isNotEmpty
                    ? Image.network(
                        _p.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.queue_music,
                          size: 40,
                          color: colors.textHint,
                        ),
                      )
                    : Icon(Icons.queue_music, size: 40, color: colors.textHint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _p.title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.tr('来自 QQ 音乐'),
                      style: TextStyle(fontSize: 13, color: colors.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.tr('${_songs.length}首歌曲'),
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                    const SizedBox(height: 12),
                    // Wrap 代替 Row：窄屏时三个胶囊按钮会横向溢出（黄黑溢出条）
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _actionButton(
                          colors,
                          Icons.play_arrow,
                          context.tr('播放全部'),
                          () => _playAt(0),
                        ),
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
                        _sortButton(colors),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
          color: colors.primary,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colors.textOnPrimary),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.textOnPrimary,
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(Icons.sort, size: 14, color: colors.textOnPrimary),
      ),
    );
  }
}
