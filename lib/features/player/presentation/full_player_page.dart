import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../application/playback_controller.dart';
import '../application/lyric_controller.dart';
import '../domain/models/playback_state.dart';
import '../domain/models/play_mode.dart';
import '../domain/models/song.dart';
import '../domain/services/cover_color_extractor.dart';
import '../../library/application/playlist_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/services/amll_toggle_service.dart';
import 'widgets/lyric_scroll_view.dart';
import 'widgets/amll_lyric_player.dart';
import 'widgets/player_controls.dart';
import '../platform/audio_effect_service.dart';
import '../platform/audio_handler.dart';
import '../platform/island_controller.dart';

class FullPlayerPage extends ConsumerStatefulWidget {
  const FullPlayerPage({super.key});

  @override
  ConsumerState<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends ConsumerState<FullPlayerPage> {
  final _pageController = PageController(initialPage: 0);
  int _currentPage = 0;
  bool _lyricsRequested = false;
  bool _lyricsPageBuilt = false;

  /// Tablet landscape: when true, lyrics occupy the full area (cover hidden).
  bool _tabletLyricsFullMode = false;

  /// 退出动画期间隐藏 AMLL WebView：滑动阶段平台视图不参与合成，
  /// 中低端手机上也能流畅滑动（平台视图随路由变换会导致严重掉帧/闪回）。
  bool _isLeaving = false;
  bool _exiting = false;
  final GlobalKey<AmllLyricPlayerState> _amllKey = GlobalKey();

  @override
  void initState() {
    super.initState();
  }

  /// 退出全屏播放页：先冻结 AMLL WebView 的 JS 动画（若在歌词页），
  /// 再隐藏平台视图并 pop。滑动动画只剩纯 Flutter 图层（背景 + 控件），
  /// 与「封面页退出」一致，无闪烁、不掉帧。
  Future<void> _beginExit() async {
    if (_exiting || _isLeaving) return;
    _exiting = true;
    FocusManager.instance.primaryFocus?.unfocus();

    final amllState = _amllKey.currentState;
    final amllEnabled = AmllToggleService().enabled;
    if (amllEnabled && amllState != null) {
      // 等待 JS rAF 循环真正停止（WebView 画布稳定为静态帧）
      await amllState.freeze();
    }
    if (!mounted) return;
    setState(() => _isLeaving = true);
    context.pop();
  }

  void _ensureLyricsLoaded() {
    if (_lyricsRequested) return;
    _lyricsRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final song = ref.read(
        playbackControllerProvider.select((s) => s.currentSong),
      );
      if (song != null) {
        ref.read(lyricControllerProvider.notifier).loadLyrics(song);
      }
    });
  }

  void _activateLyricsPage() {
    if (mounted && !_lyricsPageBuilt) {
      setState(() => _lyricsPageBuilt = true);
    }
    _ensureLyricsLoaded();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    final bgMode = ref.watch(fullScreenBackgroundModeProvider);
    final bgAnimation = ref.watch(appearanceBgAnimationProvider);
    final audioVisualizer = ref.watch(audioVisualizerEnabledProvider);
    final coverColorAsync = ref.watch(currentCoverColorProvider);

    final Color? dominantColor = coverColorAsync.whenOrNull(
      data: (result) => result?.dominantColor,
    );

    return PopScope<void>(
      // 拦截系统返回键，统一走 _beginExit（先冻结/隐藏 AMLL WebView 再 pop，
      // 避免滑动动画卡顿/闪回）
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _beginExit();
      },
      child: Scaffold(
        body: Stack(
          children: [
            RepaintBoundary(
              child: _BackgroundLayer(
                dominantColor: dominantColor,
                coverUrl: song?.coverUrl,
                mode: bgMode,
                animate: bgAnimation,
              ),
            ),
            if (audioVisualizer)
              const Positioned(
                left: 28,
                right: 28,
                bottom: 148,
                child: _AudioVisualizer(),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.02,
                  child: Container(color: Colors.white),
                ),
              ),
            ),
            SafeArea(
              child: Builder(
                builder: (context) {
                  final isTabletLandscape = ResponsiveLayout.isTabletLandscape(context);
                  if (isTabletLandscape) {
                    // Tablet landscape: side-by-side cover + lyrics layout
                    return _buildTabletLandscapeLayout(
                      isPlaying: isPlaying,
                      audioVisualizer: audioVisualizer,
                    );
                  }
                  // Phone / tablet portrait: vertical layout with PageView
                  return Column(
                    children: [
                      _PlayerHeader(
                        currentPage: _currentPage,
                        onBack: () => _beginExit(),
                        onTogglePage: () {
                          final next = _currentPage == 0 ? 1 : 0;
                          if (next == 1) _activateLyricsPage();
                          _pageController.jumpToPage(next);
                        },
                      ),
                      Expanded(
                        child: ListenableBuilder(
                          listenable: AmllToggleService(),
                          builder: (context, _) {
                            final amllEnabled = AmllToggleService().enabled;
                            return PageView.builder(
                              controller: _pageController,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: 2,
                              onPageChanged: (index) {
                                if (mounted) {
                                  setState(() => _currentPage = index);
                                }
                                if (index == 1) _activateLyricsPage();
                              },
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return _KeepAlivePage(
                                    child: _PlayerCoverPage(
                                      isPlaying: isPlaying,
                                      onTapCover: () {
                                        if (_currentPage == 0) {
                                          _activateLyricsPage();
                                          _pageController.jumpToPage(1);
                                        }
                                      },
                                    ),
                                  );
                                }
                                if (!_lyricsPageBuilt)
                                  return const SizedBox.expand();
                                return _KeepAlivePage(
                                  child: _PlayerLyricsPage(
                                    amllKey: _amllKey,
                                    hideWebView: _isLeaving,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      _PlayerSongInfo(),
                      _PlayerProgressBar(),
                      const SizedBox(height: 12),
                      _PlayerControls(
                        onQueue: () {
                          final playbackState = ref.read(
                            playbackControllerProvider,
                          );
                          final controller = ref.read(
                            playbackControllerProvider.notifier,
                          );
                          _showPlayQueue(playbackState, controller);
                        },
                      ),
                      SizedBox(height: 16),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tablet landscape layout with two modes:
  ///
  /// Split mode (_tabletLyricsFullMode == false):
  /// ┌─────────────────────────────────────────────┐
  /// │  ⬇ 返回          播放模式          🎵 歌词  │
  /// ├──────────────┬──────────────────────────────┤
  /// │              │                              │
  /// │   封面图片    │         歌词显示区域          │
  /// │   歌曲信息    │                              │
  /// │   进度条      │         (50% / 50%)          │
  /// │   播放控制    │                              │
  /// └──────────────┴──────────────────────────────┘
  ///
  /// Full-lyrics mode (_tabletLyricsFullMode == true):
  /// ┌─────────────────────────────────────────────┐
  /// │  ⬇ 返回          播放模式          🖼 封面  │
  /// │                                             │
  /// │            歌词显示区域 (全屏)               │
  /// │                                             │
  /// └─────────────────────────────────────────────┘
  Widget _buildTabletLandscapeLayout({
    required bool isPlaying,
    required bool audioVisualizer,
  }) {
    return Column(
      children: [
        // Full-width header: back (left) — play mode (center) — toggle (right)
        _PlayerHeader(
          currentPage: _tabletLyricsFullMode ? 1 : 0,
          onBack: () => _beginExit(),
          onTogglePage: () {
            setState(() => _tabletLyricsFullMode = !_tabletLyricsFullMode);
          },
        ),
        // Main content
        Expanded(
          child: _tabletLyricsFullMode
              ? _buildTabletFullLyricsMode(isPlaying: isPlaying)
              : _buildTabletSplitMode(isPlaying: isPlaying),
        ),
      ],
    );
  }

  /// Split mode: cover on left (centered/upper), controls at bottom,
  /// lyrics on right. Layout inspired by CeruMusic's side-by-side player.
  Widget _buildTabletSplitMode({required bool isPlaying}) {
    return Row(
      children: [
        // Left side: cover (centered) + controls (bottom)
        Expanded(
          flex: 5,
          child: Column(
            children: [
              const SizedBox(height: 16),
              // Cover takes up available space, centered vertically
              Expanded(
                child: _PlayerCoverPage(
                  isPlaying: isPlaying,
                  onTapCover: null,
                ),
              ),
              const SizedBox(height: 8),
              // Controls pinned to bottom
              _PlayerSongInfo(),
              _PlayerProgressBar(),
              const SizedBox(height: 8),
              _PlayerControls(
                onQueue: () {
                  final playbackState = ref.read(
                    playbackControllerProvider,
                  );
                  final controller = ref.read(
                    playbackControllerProvider.notifier,
                  );
                  _showPlayQueue(playbackState, controller);
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        // Right side: lyrics (full height)
        Expanded(
          flex: 5,
          child: _buildTabletLyricsPanel(),
        ),
      ],
    );
  }

  /// Full-lyrics mode: lyrics occupy the entire area.
  Widget _buildTabletFullLyricsMode({required bool isPlaying}) {
    return _buildTabletLyricsPanel();
  }

  /// Shared lyrics panel builder.
  Widget _buildTabletLyricsPanel() {
    return ListenableBuilder(
      listenable: AmllToggleService(),
      builder: (context, _) {
        if (!_lyricsPageBuilt) {
          // Defer setState to after the current build frame to avoid
          // "setState() called during build" error.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _activateLyricsPage();
          });
        }
        return _KeepAlivePage(
          child: _PlayerLyricsPage(
            amllKey: _amllKey,
            hideWebView: _isLeaving,
          ),
        );
      },
    );
  }

  void _showPlayQueue(
    PlaybackState playbackState,
    PlaybackController controller,
  ) {
    final queue = playbackState.queue;
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          minimum: const EdgeInsets.only(bottom: 70),
          child: DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        context.tr('播放队列'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Row(
                        children: [
                          Text(
                            context.tr('${queue.length}首'),
                            style: const TextStyle(color: AppColors.textHint),
                          ),
                          const SizedBox(width: 16),
                          GestureDetector(
                            onTap: () {
                              controller.clearQueue();
                              Navigator.pop(ctx);
                            },
                            child: Text(
                              context.tr('清空'),
                              style: const TextStyle(
                                color: AppColors.primary,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (queue.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        context.tr('播放队列为空'),
                        style: const TextStyle(color: AppColors.textHint),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: queue.length,
                      itemBuilder: (context, index) {
                        final queueSong = queue[index];
                        final isCurrent = index == playbackState.currentIndex;
                        return ListTile(
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: AppColors.surfaceVariant,
                            ),
                            child:
                                queueSong.coverUrl != null &&
                                    queueSong.coverUrl!.isNotEmpty
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: MusicCoverImage(
                                      url: queueSong.coverUrl,
                                      fit: BoxFit.cover,
                                      errorWidget: Icon(
                                        Icons.music_note,
                                        size: 20,
                                        color: isCurrent
                                            ? AppColors.primary
                                            : AppColors.textHint,
                                      ),
                                    ),
                                  )
                                : Icon(
                                    Icons.music_note,
                                    size: 20,
                                    color: isCurrent
                                        ? AppColors.primary
                                        : AppColors.textHint,
                                  ),
                          ),
                          title: Text(
                            queueSong.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: isCurrent
                                  ? AppColors.primary
                                  : AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${queueSong.artist} - ${queueSong.album}',
                            style: TextStyle(
                              fontSize: 12,
                              color: isCurrent
                                  ? AppColors.primary.withValues(alpha: 0.7)
                                  : AppColors.textHint,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: isCurrent
                              ? const Icon(
                                  Icons.volume_up,
                                  size: 18,
                                  color: AppColors.primary,
                                )
                              : IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    size: 18,
                                    color: AppColors.textHint,
                                  ),
                                  onPressed: () {
                                    controller.removeFromQueue(index);
                                    Navigator.pop(ctx);
                                  },
                                ),
                          onTap: () {
                            controller.playSongAt(index);
                            Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerHeader extends ConsumerWidget {
  final int currentPage;
  final VoidCallback onTogglePage;
  final VoidCallback onBack;
  const _PlayerHeader({
    required this.currentPage,
    required this.onTogglePage,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playMode = ref.watch(
      playbackControllerProvider.select((s) => s.playMode),
    );
    String modeTitle;
    switch (playMode) {
      case PlayMode.singleLoop:
        modeTitle = context.tr('单曲循环');
        break;
      case PlayMode.shuffle:
        modeTitle = context.tr('随机播放');
        break;
      case PlayMode.listLoop:
        modeTitle = context.tr('列表循环');
        break;
    }

    return Padding(
      padding: EdgeInsets.only(top: 8, left: 8, right: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.keyboard_arrow_down, size: 28),
            color: Colors.white.withValues(alpha: 0.6),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.05),
            ),
          ),
          const Spacer(),
          Text(
            modeTitle,
            style: const TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              color: Color(0x80FFFFFF),
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onTogglePage,
            icon: Icon(currentPage == 0 ? Icons.lyrics : Icons.album, size: 20),
            color: Colors.white.withValues(alpha: 0.6),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.05),
            ),
          ),
        ],
      ),
    );
  }
}

/// 封面页：iMusic 同款旋转唱片（黑胶底 + 中心圆封面 + 唱臂起落）。
/// 点击进入歌词页（外层 onTapCover 接线）。转速 10°/s，暂停停在当前角度。
class _PlayerCoverPage extends ConsumerStatefulWidget {
  final bool isPlaying;
  final VoidCallback? onTapCover;
  const _PlayerCoverPage({required this.isPlaying, this.onTapCover});

  /// 唱臂角度（SVG 同款）：暂停抬起 / 播放落碟
  static const _armRestDeg = 44.0;
  static const _armPlayDeg = 26.0;

  @override
  ConsumerState<_PlayerCoverPage> createState() => _PlayerCoverPageState();
}

class _PlayerCoverPageState extends ConsumerState<_PlayerCoverPage>
    with SingleTickerProviderStateMixin {
  // iMusic 同款转速：10°/s（36s 一圈），暂停 controller.stop 保留角度
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 36),
  );

  @override
  void initState() {
    super.initState();
    if (widget.isPlaying) _spin.repeat();
  }

  @override
  void didUpdateWidget(covariant _PlayerCoverPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      widget.isPlaying ? _spin.repeat() : _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final size =
        (MediaQuery.of(context).size.width * 0.62).clamp(200.0, 300.0);

    return Center(
      child: GestureDetector(
        onTap: widget.onTapCover,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              RepaintBoundary(
                child: RotationTransition(
                  turns: _spin,
                  child: _buildDisc(song, size),
                ),
              ),
              // 唱臂：相对唱片 right -11% / top -9% / 56% 宽，随播放起落
              Positioned(
                right: -size * 0.11,
                top: -size * 0.09,
                width: size * 0.56,
                height: size * 0.56,
                child: AnimatedRotation(
                  turns:
                      (widget.isPlaying
                          ? _PlayerCoverPage._armPlayDeg
                          : _PlayerCoverPage._armRestDeg) /
                      360,
                  // SVG transform-origin 86.5% 13.5%
                  alignment: const Alignment(0.73, -0.73),
                  duration: const Duration(milliseconds: 720),
                  curve: Curves.easeOutBack,
                  child: const RepaintBoundary(child: _Tonearm()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDisc(Song? song, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: const [
          // iMusic: 0 12px 46px rgba(0,0,0,.55)
          BoxShadow(
            color: Color(0x8C000000),
            blurRadius: 46,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: CustomPaint(
        painter: const _VinylPainter(),
        child: Center(child: _buildCenterCover(song, size * 0.62)),
      ),
    );
  }

  /// 中心圆封面：直径 62%，外圈 2px 黑环 + 1px 白高光环
  Widget _buildCenterCover(Song? song, double diameter) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.black.withValues(alpha: 0.5),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.06),
            blurRadius: 0,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipOval(child: _buildCoverImage(song)),
    );
  }

  static Widget _buildCoverImage(Song? song) {
    if (song == null) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0x4D6366F1), Color(0xFF1E1E2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Icon(Icons.music_note, size: 60, color: Colors.white24),
      );
    }
    // 优先使用 coverUrl（精准匹配后的在线封面），再回退到设备本地封面
    if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      return MusicCoverImage(
        url: song.coverUrl,
        fit: BoxFit.cover,
        cacheWidth: 1536,
        cacheHeight: 1536,
        filterQuality: FilterQuality.high,
        errorWidget: _fallbackCover(song),
      );
    }
    if (song.mediaStoreId != null) {
      return QueryArtworkWidget(
        key: ValueKey(song.mediaStoreId),
        id: song.mediaStoreId!,
        type: ArtworkType.AUDIO,
        keepOldArtwork: true,
        artworkFit: BoxFit.cover,
        nullArtworkWidget: _fallbackCover(song),
      );
    }
    return _fallbackCover(song);
  }

  static Widget _fallbackCover(Song? song) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0x4D6366F1), Color(0xFF1E1E2E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.music_note, size: 60, color: Colors.white24),
    );
  }
}

/// 黑胶底纹：iMusic .disc-vinyl 同款
/// （细密纹路 repeating-radial + 偏光径向渐变 + 边缘内阴影）
class _VinylPainter extends CustomPainter {
  const _VinylPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // radial-gradient(circle at 38% 32%, #1a1a1f 0%, #0a0a0c 55%, #030304 100%)
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.24, -0.36),
          colors: [Color(0xFF1A1A1F), Color(0xFF0A0A0C), Color(0xFF030304)],
          stops: [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    // 细密纹路：每 5px 一道 1px 白 2.8% 环
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.028);
    for (double r = radius * 0.62; r <= radius - 1; r += 5) {
      canvas.drawCircle(center, r, groove);
    }

    // inset 0 0 30px rgba(0,0,0,.75)
    canvas.drawCircle(
      center,
      radius - 12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 24
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
        ..color = Colors.black.withValues(alpha: 0.5),
    );

    // inset 0 0 0 1px rgba(255,255,255,.06)
    canvas.drawCircle(
      center,
      radius - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.06),
    );
  }

  @override
  bool shouldRepaint(covariant _VinylPainter oldDelegate) => false;
}

/// 唱臂：按 iMusic 的 SVG viewBox 100x100 逐部件复刻
class _Tonearm extends StatelessWidget {
  const _Tonearm();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: const _TonearmPainter());
  }
}

class _TonearmPainter extends CustomPainter {
  const _TonearmPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width == 0) return;
    canvas.scale(size.width / 100);
    const pivot = Offset(86, 14);
    const tip = Offset(40.6, 52.6);
    final white = Colors.white;

    void circle(Offset c, double r, Paint p) => canvas.drawCircle(c, r, p);
    Paint fill(Color color) =>
        Paint()..color = color..style = PaintingStyle.fill;
    Paint stroke(Color color, double w) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;

    // 轴座底座
    circle(pivot, 10.8, fill(const Color(0xFF2A2E36)));
    circle(pivot, 10.8, stroke(white.withValues(alpha: 0.08), 1.2));
    circle(pivot, 6.4, fill(const Color(0xFF4A4E56)));
    circle(pivot, 1.7, fill(const Color(0xFF8A8E96)));
    circle(const Offset(84.2, 11.6), 1.5, fill(white.withValues(alpha: 0.16)));

    // 配重块（轴座后方，rotate -20°）
    canvas.save();
    canvas.translate(91.2, 8.8);
    canvas.rotate(-20 * 3.14159265 / 180);
    canvas.drawOval(Offset.zero & const Size(10.4, 7.2),
        fill(const Color(0xFF3A3E46)));
    canvas.drawOval(const Offset(-1.2, -1.4) & const Size(4.2, 1.9),
        fill(white.withValues(alpha: 0.22)));
    canvas.restore();

    // 臂管：阴影 + 主体 + 高光
    final rodShadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.38)
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pivot, tip, rodShadow);
    final rod = Paint()
      ..color = const Color(0xFFE9ECF1)
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pivot, tip, rod);
    final rodHl = Paint()
      ..color = white.withValues(alpha: 0.42)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(82, 18.2), const Offset(44.2, 50.1), rodHl);

    // 唱头（rotate 32° 围绕 tip）
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(32 * 3.14159265 / 180);
    canvas.translate(-tip.dx, -tip.dy);
    RRect rrect(double l, double t, double w, double h, double r) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(l, t, w, h), Radius.circular(r));
    canvas.drawRRect(rrect(33.2, 48.4, 14.6, 8.4, 1.9),
        fill(const Color(0xFF1A1D22)));
    canvas.drawRRect(rrect(33.2, 48.4, 14.6, 8.4, 1.9),
        stroke(white.withValues(alpha: 0.08), 1));
    canvas.drawRRect(rrect(34.2, 49.1, 12.2, 1.7, 0.85),
        fill(white.withValues(alpha: 0.12)));
    canvas.drawRRect(
        rrect(46.5, 49.9, 4.6, 1.15, 0.55), fill(const Color(0xFF9AA0AA)));
    canvas.drawRRect(rrect(33.6, 52.1, 7.4, 3.3, 0.65),
        fill(const Color(0xFF0D0F13)));
    circle(const Offset(36.8, 56.9), 1.05, fill(Colors.black.withValues(alpha: 0.38)));
    circle(const Offset(36.8, 56.4), 1.0, fill(const Color(0xFFE9ECF1)));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TonearmPainter oldDelegate) => false;
}

class _PlayerLyricsPage extends ConsumerWidget {
  final GlobalKey<AmllLyricPlayerState> amllKey;

  /// 退出动画期间隐藏 AMLL WebView（平台视图不参与滑动合成）。
  final bool hideWebView;

  const _PlayerLyricsPage({required this.amllKey, required this.hideWebView});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricState = ref.watch(lyricControllerProvider);
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    final showTranslation = ref.watch(lyricShowTranslationProvider);
    final showRoman = ref.watch(lyricShowRomanProvider);
    final enableBlur = ref.watch(lyricEnableBlurProvider);
    final enableScale = ref.watch(lyricEnableScaleProvider);
    final enableJumpLyric = ref.watch(appearanceJumpLyricProvider);
    final immersiveColor = ref.watch(lyricImmersiveColorProvider);
    final fontSizeScale = ref.watch(lyricFontSizeProvider);
    final coverColorAsync = ref.watch(currentCoverColorProvider);
    final lightColor = coverColorAsync.whenOrNull(
      data: (result) => result?.lightColor,
    );

    final Color activeColor;
    if (immersiveColor && lightColor != null) {
      activeColor = lightColor;
    } else {
      activeColor = Colors.white;
    }
    final inactiveColor = Colors.white.withValues(alpha: 0.4);
    final hasYrc = lyricState.hasYrc;
    final baseFontSize = 22.0 * fontSizeScale;
    final transFontSize = 15.0 * fontSizeScale;
    final romanFontSize = 13.0 * fontSizeScale;
    final watchFontFamily = ref.watch(lyricFontFamilyProvider);
    final watchFontRate = ref.watch(lyricFontRateProvider);
    final watchFontWeight = ref.watch(lyricFontWeightProvider);
    final lyricCenterAlign = ref.watch(lyricCenterAlignProvider);
    final amllCenterAlign = ref.watch(amllCenterAlignProvider);

    return ListenableBuilder(
      listenable: AmllToggleService(),
      builder: (context, _) {
        final amll = AmllToggleService().enabled;
        if (lyricState.isLoading && lyricState.lines.isEmpty) {
          return Center(
            child: Text(
              context.tr('加载歌词中...'),
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.4),
                letterSpacing: 2,
              ),
            ),
          );
        }
        if (lyricState.error != null && lyricState.lines.isEmpty) {
          return Center(
            child: Text(
              lyricState.error!,
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.4),
                letterSpacing: 2,
              ),
            ),
          );
        }
        if (lyricState.lines.isEmpty) {
          return Center(
            child: Text(
              context.tr('暂无歌词'),
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.4),
                letterSpacing: 2,
              ),
            ),
          );
        }
        return Stack(
          children: [
            // Keep the native AMLL WebView mounted in a stable platform-view
            // slot. Switching only the Flutter lyric layer prevents the first
            // WebView detach/attach from flashing after a cold app start.
            RepaintBoundary(
              child: TickerMode(
                enabled: !hideWebView,
                child: Offstage(
                  offstage: hideWebView,
                  child: AmllLyricPlayer(
                    key: amllKey,
                    lines: lyricState.lines,
                    currentTimeMs: position.inMilliseconds,
                    isPlaying: isPlaying,
                    fontSizeRate: watchFontRate,
                    fontFamily: watchFontFamily,
                    fontWeight: watchFontWeight,
                    showTranslation: showTranslation,
                    showRoman: showRoman,
                    enableBlur: enableBlur,
                    enableScale: enableScale,
                    enableJumpLyric: enableJumpLyric,
                    centerAlign: amllCenterAlign,
                    isVisible: amll,
                    isActive: !hideWebView,
                    onLineClick: (startTimeMs) {
                      ref
                          .read(playbackControllerProvider.notifier)
                          .seek(Duration(milliseconds: startTimeMs));
                    },
                  ),
                ),
              ),
            ),
            IgnorePointer(
              ignoring: amll,
              child: Visibility(
                visible: !amll,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                maintainInteractivity: false,
                child: LyricScrollView(
                  lines: lyricState.lines,
                  currentTimeMs: position.inMilliseconds,
                  isPlaying: isPlaying,
                  hasYrc: hasYrc,
                  activeColor: activeColor,
                  inactiveColor: inactiveColor,
                  mainFontSize: baseFontSize,
                  transFontSize: transFontSize,
                  romanFontSize: romanFontSize,
                  fontSizeRate: watchFontRate,
                  showTranslation: showTranslation,
                  showRoman: showRoman,
                  enableBlur: enableBlur,
                  enableScale: enableScale,
                  enableJumpLyric: enableJumpLyric,
                  centerAlign: lyricCenterAlign,
                  fontFamily: watchFontFamily,
                  fontWeight: watchFontWeight,
                  onSeek: (startTimeMs) {
                    ref
                        .read(playbackControllerProvider.notifier)
                        .seek(Duration(milliseconds: startTimeMs));
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlayerSongInfo extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currentSongIdentityProvider);
    final song = ref.read(playbackControllerProvider).currentSong;
    final playlistsAsync = ref.watch(playlistsProvider);

    final isFavorite =
        playlistsAsync.whenOrNull(
          data: (playlists) {
            final fav = playlists
                .where((p) => p.id == '__favorites__')
                .firstOrNull;
            return fav?.songs.any((s) => s.id == song?.id) ?? false;
          },
        ) ??
        false;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song?.title ?? context.tr('未知歌曲'),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  song?.artist ?? context.tr('未知歌手'),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // 灵动岛歌词开关（开=绿色高亮，与通知栏"岛"按钮同一效果）
          ValueListenableBuilder<bool>(
            valueListenable: ref.watch(audioHandlerProvider).islandState,
            builder: (context, on, _) => IconButton(
              onPressed: () => ref.read(islandControllerProvider).toggle(),
              tooltip: context.tr('灵动岛歌词'),
              icon: Text(
                '岛',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: on
                      ? const Color(0xFF31C27C)
                      : Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: () {
              if (song == null) return;
              final playlistsAsyncVal = ref.read(playlistsProvider);
              playlistsAsyncVal.whenData((playlists) {
                final fav = playlists
                    .where((p) => p.id == '__favorites__')
                    .firstOrNull;
                final isFavorited =
                    fav?.songs.any((s) => s.id == song.id) ?? false;
                if (isFavorited) {
                  ref
                      .read(playlistsProvider.notifier)
                      .removeSongFromPlaylist('__favorites__', song.id);
                } else {
                  ref
                      .read(playlistsProvider.notifier)
                      .addSongToPlaylist('__favorites__', song);
                }
              });
            },
            icon: Icon(
              isFavorite ? Icons.favorite : Icons.favorite_border,
              size: 24,
              color: isFavorite
                  ? Colors.red
                  : Colors.white.withValues(alpha: 0.7),
            ),
          ),
          IconButton(
            onPressed: song != null
                ? () => SongActionSheet.showPlayerMenu(context, song: song)
                : null,
            icon: Icon(
              Icons.more_horiz,
              size: 24,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerProgressBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );
    final duration = ref.watch(
      playbackControllerProvider.select((s) => s.duration),
    );
    final currentQuality = ref.watch(
      playbackControllerProvider.select((s) => s.currentQuality),
    );
    final availableQualities = ref.watch(
      playbackControllerProvider.select((s) => s.availableQualities),
    );

    return PlayerProgressBar(
      progress:
          (duration.inMilliseconds > 0
                  ? position.inMilliseconds / duration.inMilliseconds
                  : 0.0)
              .clamp(0.0, 1.0),
      position: position,
      duration: duration,
      currentQuality: currentQuality,
      availableQualities: availableQualities,
      onQualityTap: (quality) =>
          ref.read(playbackControllerProvider.notifier).setQuality(quality),
      onSeek: (value) {
        ref
            .read(playbackControllerProvider.notifier)
            .seek(
              Duration(milliseconds: (value * duration.inMilliseconds).round()),
            );
      },
    );
  }
}

class _PlayerControls extends ConsumerWidget {
  final VoidCallback onQueue;
  const _PlayerControls({required this.onQueue});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    final isLoading = ref.watch(
      playbackControllerProvider.select((s) => s.isLoading),
    );
    final playMode = ref.watch(
      playbackControllerProvider.select((s) => s.playMode),
    );
    final controller = ref.read(playbackControllerProvider.notifier);

    return PlaybackControlRow(
      isPlaying: isPlaying,
      isLoading: isLoading,
      playMode: playMode,
      onPlayPause: () => controller.togglePlayPause(),
      onPrevious: () => controller.previous(),
      onNext: () => controller.next(),
      onCycleMode: () => controller.cyclePlayMode(),
      onQueue: onQueue,
    );
  }
}

class _BackgroundLayer extends StatefulWidget {
  final Color? dominantColor;
  final String? coverUrl;
  final FullScreenBackgroundMode mode;
  final bool animate;

  const _BackgroundLayer({
    required this.dominantColor,
    required this.coverUrl,
    required this.mode,
    required this.animate,
  });

  @override
  State<_BackgroundLayer> createState() => _BackgroundLayerState();
}

class _BackgroundLayerState extends State<_BackgroundLayer>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Color? _displayedDominantColor;

  @override
  void initState() {
    super.initState();
    _displayedDominantColor = widget.dominantColor;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _BackgroundLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Color extraction is asynchronous. Keep the previous palette while the
    // next cover's FutureProvider is loading instead of briefly falling back
    // to the dark background.
    if (widget.dominantColor != null) {
      _displayedDominantColor = widget.dominantColor;
    }
    if (oldWidget.animate != widget.animate ||
        oldWidget.mode != widget.mode ||
        oldWidget.coverUrl != widget.coverUrl) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final shouldAnimate =
        widget.animate &&
        widget.mode == FullScreenBackgroundMode.cover &&
        widget.coverUrl != null &&
        widget.coverUrl!.isNotEmpty;
    if (shouldAnimate) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 16),
      )..repeat(reverse: true);
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return _buildLayer(context, 0);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _buildLayer(context, controller.value),
    );
  }

  Widget _buildLayer(BuildContext context, double animationValue) {
    final mode = widget.mode;
    final dominantColor = _displayedDominantColor;
    return Stack(
      children: [
        Container(color: const Color(0xFF09090B)),
        if (dominantColor != null && mode == FullScreenBackgroundMode.theme)
          AnimatedContainer(
            duration: widget.animate
                ? const Duration(seconds: 1)
                : Duration.zero,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  HSLColor.fromColor(dominantColor!)
                      .withLightness(
                        (HSLColor.fromColor(
                          dominantColor!,
                        ).lightness).clamp(0.15, 0.45),
                      )
                      .toColor(),
                  HSLColor.fromColor(dominantColor!)
                      .withLightness(
                        (HSLColor.fromColor(dominantColor!).lightness - 0.08)
                            .clamp(0.05, 0.35),
                      )
                      .toColor(),
                ],
              ),
            ),
          ),
        if (widget.coverUrl != null &&
            widget.coverUrl!.isNotEmpty &&
            mode == FullScreenBackgroundMode.cover)
          Stack(
            children: [
              // iMusic 同款：封面模糊 blur(80px) brightness(.62) saturate(1.65) scale(1.4)
              Positioned.fill(
                child: ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    0.9372, -0.2882, -0.0290, 0, 0, //
                    -0.0858, 0.7349, -0.0290, 0, 0, //
                    -0.0858, -0.2882, 0.9940, 0, 0, //
                    0, 0, 0, 1, 0, //
                  ]),
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: Transform.scale(
                      scale: 1.4,
                      child: widget.animate
                          ? Transform.scale(
                              scale: 1.0 + animationValue * 0.018,
                              child: MusicCoverImage(
                                url: widget.coverUrl,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                height: double.infinity,
                                cacheWidth: 256,
                                cacheHeight: 256,
                                filterQuality: FilterQuality.low,
                              ),
                            )
                          : MusicCoverImage(
                              url: widget.coverUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              cacheWidth: 256,
                              cacheHeight: 256,
                              filterQuality: FilterQuality.low,
                            ),
                    ),
                  ),
                ),
              ),
              // iMusic .pmask 暗罩：rgba(10,12,16,.22) → rgba(10,12,16,.66)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFF0A0C10).withValues(alpha: 0.22),
                        const Color(0xFF0A0C10).withValues(alpha: 0.66),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (mode == FullScreenBackgroundMode.dark ||
            (dominantColor == null && mode == FullScreenBackgroundMode.theme))
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF18181B),
                  Color(0xFF09090B),
                  Color(0xFF000000),
                ],
              ),
            ),
          ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            height: MediaQuery.of(context).size.height * 0.6,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 0.8,
                colors: [
                  Colors.white.withValues(alpha: 0.06),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AudioVisualizer extends ConsumerWidget {
  const _AudioVisualizer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    return StreamBuilder<List<double>>(
      stream: audioEffectService.visualizerStream,
      builder: (context, snapshot) {
        final values = snapshot.data ?? const <double>[];
        final bars = List<double>.generate(24, (index) {
          if (!isPlaying) return 0.08;
          if (values.isEmpty) return 0.18 + (index % 5) * 0.05;
          final sourceIndex = (index * values.length / 24).floor();
          return values[sourceIndex.clamp(0, values.length - 1).toInt()];
        });
        return SizedBox(
          height: 42,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: bars
                .map(
                  (value) => AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 3,
                    height: 6 + value.clamp(0.0, 1.0).toDouble() * 32,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }
}

/// 保持 PageView 页面存活，避免页面切换时 WebView 被销毁重建
class _KeepAlivePage extends StatefulWidget {
  final Widget child;
  const _KeepAlivePage({required this.child});
  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
