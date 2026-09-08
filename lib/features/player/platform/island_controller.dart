import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/services/share_service.dart';
import '../../library/application/playlist_providers.dart';
import '../application/lyric_controller.dart';
import '../application/playback_controller.dart';
import '../domain/models/lyric_line.dart';
import '../domain/models/playback_state.dart';
import '../domain/models/song.dart';
import 'audio_handler.dart';

/// 灵动岛歌词控制器：桥接原生悬浮窗与 Flutter 播放/歌词状态。
final islandControllerProvider = Provider<IslandController>((ref) {
  final controller = IslandController(ref);
  ref.onDispose(controller.dispose);
  controller.initialize();
  return controller;
});

class IslandController {
  static const MethodChannel _channel = MethodChannel('com.mintmusic/island');

  final Ref _ref;
  late final MusicAudioHandler _audioHandler;
  Timer? _positionTimer;
  StreamSubscription<Duration>? _positionSub;

  Song? _lastSong;
  List<LyricLine> _lyrics = [];
  bool _hasYrc = false;
  bool _initialized = false;
  bool _isShowing = false;
  Duration _lastPosition = Duration.zero;
  DateTime? _lastOpenPlayerAt;

  IslandController(this._ref);

  void initialize() {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleNativeCommand);

    _audioHandler = _ref.read(audioHandlerProvider);
    _audioHandler.onFavoriteToggle = _handleFavoriteToggle;
    _audioHandler.onIslandToggle = _handleIslandToggle;
    _audioHandler.onLyricToggle = _handleLyricToggle;

    _ref.listen(playbackControllerProvider, (prev, next) {
      _onPlaybackStateChanged(next);
    });

    _ref.listen(lyricControllerProvider, (prev, next) {
      _onLyricStateChanged(next);
    });

    _positionSub = _audioHandler.positionStream.listen((pos) {
      _lastPosition = pos;
    });

    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _pushProgressAndLyric(_lastPosition);
    });

    _consumePendingOpenPlayer();
    _syncLyricOverlayState();
  }

  /// 冷启动时原生已经缓存了"打开播放页"请求（灵动岛点击早于 Dart 监听就绪），此处补取。
  Future<void> _consumePendingOpenPlayer() async {
    try {
      final pending =
          await _channel.invokeMethod('consumeOpenPlayer') as bool? ?? false;
      if (pending) _openPlayerPage();
    } catch (_) {}
  }

  /// 同步桌面歌词悬浮窗当前是否显示（进程重启后原生状态可能与 Dart 不一致）
  Future<void> _syncLyricOverlayState() async {
    try {
      final showing =
          await _channel.invokeMethod('lyricShowing') as bool? ?? false;
      _audioHandler.lyricState.value = showing;
    } catch (_) {}
  }

  /// 打开全屏播放页（原生点击气泡/通知栏触发，无 BuildContext 时用根导航器）
  void _openPlayerPage() {
    // 原生侧可能在冷启动时重复投递（Activity onCreate + Dart 补取），做短时间去重
    final now = DateTime.now();
    if (_lastOpenPlayerAt != null &&
        now.difference(_lastOpenPlayerAt!) < const Duration(milliseconds: 800)) {
      return;
    }
    _lastOpenPlayerAt = now;
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;
    context.push(AppRoutes.fullPlayer);
  }

  void dispose() {
    _positionTimer?.cancel();
    _positionSub?.cancel();
    _channel.setMethodCallHandler(null);
  }

  Future<dynamic> _handleNativeCommand(MethodCall call) async {
    if (call.method == 'openPlayer') {
      _openPlayerPage();
      return;
    }
    if (call.method != 'command') return;
    final cmd = (call.arguments as Map?)?['cmd'] as String?;
    if (cmd == null) return;

    final playback = _ref.read(playbackControllerProvider.notifier);
    final song = _ref.read(playbackControllerProvider).currentSong;

    switch (cmd) {
      case 'prev':
        _ref.read(audioHandlerProvider).skipToPrevious();
        break;
      case 'next':
        _ref.read(audioHandlerProvider).skipToNext();
        break;
      case 'toggle':
        await playback.togglePlayPause();
        break;
      case 'fav':
        if (song != null) await _toggleFavorite(song);
        break;
      case 'toggleDesktopLyric':
        await _handleLyricToggle();
        break;
      case 'toggleDesktopLyricLock':
        await _handleLockToggle();
        break;
      case 'toggleIsland':
        await _handleIslandToggle();
        break;
      case 'close':
        await playback.pause();
        break;
    }
  }

  Future<void> _toggleFavorite(Song song) async {
    try {
      final playlistsAsync = _ref.read(playlistsProvider);
      final fav = playlistsAsync.valueOrNull
          ?.where((p) => p.id == '__favorites__')
          .firstOrNull;
      final isFav = fav?.songs.any((s) => s.id == song.id) ?? false;
      final notifier = _ref.read(playlistsProvider.notifier);
      if (isFav) {
        await notifier.removeSongFromPlaylist('__favorites__', song.id);
      } else {
        await notifier.addSongToPlaylist('__favorites__', song);
      }
      // 刷新收藏状态到悬浮窗
      final state = _ref.read(playbackControllerProvider);
      await _pushMeta(state.currentSong, state.isPlaying);
      _audioHandler.favState.value = !isFav;
    } catch (_) {}
  }

  Future<void> _handleFavoriteToggle() async {
    final song = _ref.read(playbackControllerProvider).currentSong;
    if (song != null) {
      await _toggleFavorite(song);
    }
  }

  Future<void> _handleIslandToggle() async {
    final showing = await toggle();
    _isShowing = showing;
    _audioHandler.islandState.value = showing;
  }

  /// 通知栏"桌面歌词"按钮：切换原生桌面歌词悬浮窗
  Future<void> _handleLyricToggle() async {
    await toggleDesktopLyric();
  }

  /// 通知栏"桌面歌词锁定"按钮：切换锁定状态（开锁=可拖动，关锁=触摸穿透）
  Future<void> _handleLockToggle() async {
    final locked = await toggleDesktopLyricLock();
    _audioHandler.lockState.value = locked;
  }

  void _onPlaybackStateChanged(PlaybackState state) {
    final song = state.currentSong;
    if (song != null && song != _lastSong) {
      _lastSong = song;
      _pushMeta(song, state.isPlaying);
      _pushCover(song);
    } else {
      _pushMeta(song, state.isPlaying);
    }
    _pushProgressAndLyric(state.position);
  }

  void _onLyricStateChanged(LyricState state) {
    _lyrics = state.lines;
    _hasYrc = state.hasYrc;
  }

  Future<void> _pushMeta(Song? song, bool playing) async {
    final isFav = song != null ? _isFavorite(song) : false;
    _audioHandler.favState.value = isFav;
    try {
      await _channel.invokeMethod('setMeta', {
        'title': song?.title ?? '',
        'artist': song?.artist ?? '',
        'playing': playing,
        'fav': isFav,
      });
    } catch (_) {}
  }

  bool _isFavorite(Song song) {
    try {
      final playlistsAsync = _ref.read(playlistsProvider);
      final fav = playlistsAsync.valueOrNull
          ?.where((p) => p.id == '__favorites__')
          .firstOrNull;
      return fav?.songs.any((s) => s.id == song.id) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pushCover(Song song) async {
    Uint8List? bytes;
    final url = song.coverUrl;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('http')) {
        bytes = await ShareService.downloadCover(url);
      } else if (url.startsWith('content://')) {
        // 本地 content uri 交给原生处理
        try {
          await _channel.invokeMethod('setCover', {'path': url});
        } catch (_) {}
        return;
      } else {
        try {
          final file = File(url);
          if (await file.exists()) {
            bytes = await file.readAsBytes();
          }
        } catch (_) {}
      }
    }
    try {
      await _channel.invokeMethod('setCover', {'bytes': bytes});
    } catch (_) {}
  }

  Future<void> _pushProgressAndLyric(Duration position) async {
    final state = _ref.read(playbackControllerProvider);
    final duration = state.duration;
    try {
      await _channel.invokeMethod('setProgress', {
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
      });
    } catch (_) {}

    _updateLyric(position);
  }

  void _updateLyric(Duration position) {
    if (_lyrics.isEmpty) return;
    final posMs = position.inMilliseconds;
    final line = _findLine(posMs);
    if (line == null) return;

    final text = line.plainText;
    final start = line.startTimeMs;
    final end = line.endTimeMs;

    if (_hasYrc && line.isYrc) {
      final words = line.words.map((w) {
        return <num>[w.startTimeMs, w.endTimeMs, w.word.length];
      }).toList();
      _channel.invokeMethod('setLyricWords', {
        'text': text,
        'start': start,
        'end': end,
        'words': words,
      });
    } else {
      _channel.invokeMethod('setLyric', {
        'text': text,
        'start': start,
        'end': end,
      });
    }
  }

  LyricLine? _findLine(int posMs) {
    for (int i = 0; i < _lyrics.length; i++) {
      if (posMs >= _lyrics[i].startTimeMs && posMs < _lyrics[i].endTimeMs) {
        return _lyrics[i];
      }
    }
    if (_lyrics.isNotEmpty && posMs >= _lyrics.last.endTimeMs) {
      return _lyrics.last;
    }
    return null;
  }

  Future<void> show() async {
    try {
      await _channel.invokeMethod('show');
      _isShowing = true;
      _audioHandler.islandState.value = true;
    } catch (_) {}
  }

  Future<void> hide() async {
    try {
      await _channel.invokeMethod('hide');
      _isShowing = false;
      _audioHandler.islandState.value = false;
    } catch (_) {}
  }

  Future<bool> toggle() async {
    try {
      final showing = await _channel.invokeMethod('toggle') as bool?;
      _isShowing = showing ?? false;
      _audioHandler.islandState.value = _isShowing;
      return _isShowing;
    } catch (_) {
      return false;
    }
  }

  /// 桌面歌词悬浮窗开关；返回操作后是否显示中
  Future<bool> toggleDesktopLyric() async {
    try {
      final showing = await _channel.invokeMethod('toggleLyric') as bool?;
      _audioHandler.lyricState.value = showing ?? false;
      return _audioHandler.lyricState.value;
    } catch (_) {
      return false;
    }
  }

  /// 桌面歌词锁定开关；返回操作后是否锁定中
  Future<bool> toggleDesktopLyricLock() async {
    try {
      final next = !(await _channel.invokeMethod('desktopLyricLocked') as bool? ?? false);
      await _channel.invokeMethod('setDesktopLyricLocked', {'locked': next});
      return next;
    } catch (_) {
      return false;
    }
  }
}
