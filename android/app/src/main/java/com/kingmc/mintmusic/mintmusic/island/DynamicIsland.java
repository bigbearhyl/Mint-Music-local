package com.kingmc.mintmusic.mintmusic.island;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.Context;
import android.content.Intent;

import com.kingmc.mintmusic.mintmusic.MainActivity;
import com.kingmc.mintmusic.mintmusic.R;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Outline;
import android.graphics.Paint;
import android.graphics.ColorMatrix;
import android.graphics.ColorMatrixColorFilter;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 灵动岛 (Dynamic Island) 歌词悬浮窗。
 *
 * 收起态: 黑色药丸 = 专辑封面 + 当前歌词横向滚动(marquee) + 播放律动条
 * 展开态: 大卡片   = 专辑封面 + 歌名/歌手 + 播放暂停/下一首 + 大号歌词
 *
 * 交互: 点击切换展开/收起(带尺寸+圆角过渡动画), 拖动可移动位置。
 * 复用桌面歌词已有的 TYPE_APPLICATION_OVERLAY 悬浮窗通道与 SYSTEM_ALERT_WINDOW 权限。
 */
public final class DynamicIsland {

    private static Context sCtx;
    private static WindowManager sWm;
    private static WindowManager.LayoutParams sParams;
    private static FrameLayout sRoot;
    private static BlurBgDrawable sBg;
    private static float sRadius;          // 背景圆角(随展开动画插值)
    private static boolean sShowing;
    private static boolean sExpanded;
    private static boolean sBackground;          // 应用是否切后台(打游戏): 降级悬浮窗动画
    private static ValueAnimator sSizeAnim;

    private static View sMini;
    private static View sFull;
    private static ImageView sCoverMini, sCoverFull, sBtnToggle, sBtnNext, sBtnPrev, sBtnFav;
    private static ScrollLyricView sLyricMini, sLyricFull;
    private static TextView sTitleFull, sArtistFull;
    private static SongProgressView sProgressFull;   // 展开态: 歌词上方的播放进度条
    private static EqView sEq;

    private static volatile String sLyric = "";
    private static volatile long sLyricStart, sLyricEnd;   // 当前句时间(ms), 用于按演唱进度滚动
    private static volatile long[][] sWords = null;        // 逐字时间轴 [起ms,止ms,字符数]... (QRC); null=无
    private static volatile String sTitle = "";
    private static volatile String sArtist = "";
    private static volatile boolean sPlaying = false;
    private static volatile boolean sFavState = false;     // 当前歌曲收藏状态: 红心/白描边
    private static volatile Bitmap sCover = null;

    private static int sWMini, sHMini, sWFull, sHFull;
    private static int sStatusBarH;
    private static int sSavedMiniX, sSavedMiniY;    // 展开前药丸的位置, 收起时恢复

    /** 收藏状态 (与通知栏爱心一致): 已收藏=红心填充, 未收藏=白色描边 */
    public static void setFav(boolean fav) {
        if (fav == sFavState && sBtnFav != null) return;
        sFavState = fav;
        MAIN.post(DynamicIsland::applyMeta);
    }

    /** 打开全屏播放页(Idempotent): 页面未加载完时由 MusicService.jsWhenReady 兜底 */
    private static final String JS_OPEN_PLAYER =
            "(function(){var p=document.getElementById('player');if(p)p.classList.add('open');})();";

    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    /** 外部命令回调: 播放/暂停/上/下/收藏等 */
    public interface CommandCallback { void onCommand(String cmd); }
    private static volatile CommandCallback sCallback;
    public static void setCommandCallback(CommandCallback cb) { sCallback = cb; }

    private static volatile long sPositionMs = -1;
    private static volatile long sDurationMs = 0;
    public static void setProgress(long pos, long dur) {
        sPositionMs = pos;
        sDurationMs = dur;
    }
    /** 与播放器/桌面歌词一致的"正在唱的歌词"高亮绿 */
    private static final int GREEN = 0xFF3BF787;
    /** 背景压暗: 用户要求"背景有颜色且迷糊但不透桌面"(2026-09): 封面主色渐变 alpha=1, 暗罩压到足够深同时保留色调 */
    private static final int DIM_A_MINI = 0x99;  // 60%
    private static final int DIM_A_FULL = 0xB3;  // 70%
    private static final int DIM_MINI = (DIM_A_MINI << 24) | 0x2B2B2F;
    private static final int DIM_FULL = (DIM_A_FULL << 24) | 0x2B2B2F;

    private DynamicIsland() {}

    // ==================== 对外 API ====================

    public static boolean isShowing() { return sShowing; }

    public static void toggle(Context ctx) {
        if (sShowing) hide();
        else show(ctx);
    }

    public static void show(final Context ctx) {
        android.util.Log.i("MintIsland", "island show called, sShowing=" + sShowing);
        if (sShowing) return;
        sCtx = ctx.getApplicationContext();
        // 同步置位：Dart 侧 toggle() 需要立刻拿到"已显示"的结果
        sShowing = true;
        MAIN.post(() -> {
            try {
                build();
                android.util.Log.i("MintIsland", "island build OK, window added");
            } catch (Throwable e) {
                android.util.Log.e("MintIsland", "island show failed", e);
                sShowing = false;
            }
        });
    }

    public static void hide() {
        android.util.Log.i("MintIsland", "island hide called, sRoot=" + (sRoot != null));
        // 同步清位：hide() 后 isShowing() 必须立刻为 false
        sShowing = false;
        MAIN.post(() -> {
            if (sSizeAnim != null) { sSizeAnim.cancel(); sSizeAnim = null; }
            if (sEq != null) sEq.setPlaying(false);
            if (sRoot != null && sWm != null) {
                try { sWm.removeView(sRoot); } catch (Exception ignored) {}
            }
            sRoot = null; sBg = null; sWm = null; sParams = null;
            sMini = null; sFull = null;
            sCoverMini = null; sCoverFull = null; sBtnToggle = null; sBtnNext = null; sBtnPrev = null;
            sBtnFav = null;
            sLyricMini = null; sLyricFull = null; sTitleFull = null; sArtistFull = null;
            sProgressFull = null;
            sEq = null;
            sShowing = false; sExpanded = false;
        });
    }

    /** 当前歌词行 (任意线程), start/end 为该句起止毫秒(用于按演唱进度滚动) */
    public static void setLyric(String text, long start, long end) {
        String t = text == null ? "" : text;
        if (t.equals(sLyric) && start == sLyricStart && end == sLyricEnd && sWords == null) return;
        sLyric = t;
        sLyricStart = start;
        sLyricEnd = end;
        sWords = null;                                  // 行级推送清掉逐字模式
        MAIN.post(DynamicIsland::applyLyric);
    }

    /**
     * 逐字歌词 (QRC): words = [[起ms,止ms,字符数],...], 时间为绝对歌曲毫秒, 与 text 字符对齐。
     * 灵动岛按 NativePlayer 真实进度逐字填色(已唱绿/未唱白)。
     */
    public static void setLyricWords(String text, long start, long end, long[][] words) {
        String t = text == null ? "" : text;
        if (t.equals(sLyric) && start == sLyricStart && end == sLyricEnd
                && words != null && words == sWords) return;
        sLyric = t;
        sLyricStart = start;
        sLyricEnd = end;
        sWords = (words == null || words.length == 0) ? null : words;
        MAIN.post(DynamicIsland::applyLyric);
    }

    /** 歌名/歌手/播放状态 (任意线程) */
    public static void setMeta(String title, String artist, boolean playing) {
        sTitle = title == null ? "" : title;
        sArtist = artist == null ? "" : artist;
        sPlaying = playing;
        MAIN.post(() -> { applyMeta(); applyLyric(); });
    }

    /** 专辑封面 (任意线程) */
    public static void setCover(Bitmap bmp) {
        sCover = bmp;
        MAIN.post(DynamicIsland::applyCover);
    }

    /** 应用切后台(打游戏)时暂停律动条/歌词滚动动画, 减少主线程与 GPU 争抢,
     *  间接缓解 WebView 音频渲染进程被系统挤占导致的卡顿; 回到前台恢复。 */
    public static void setBackgroundMode(boolean bg) {
        // 2026-09-04 用户要求: 切到别的软件时气泡动画保持播放器里看到的效果,
        // 不再停律动条/歌词滚动/进度动画。动画是否跳动的语义由播放状态驱动
        // (applyMeta 里 sEq.setPlaying(sPlaying)): 暂停时律动条自然静止, 播放中永远跳动。
        sBackground = bg;
    }

    // ==================== 构建 ====================

    private static void build() {
        android.util.DisplayMetrics dm = sCtx.getResources().getDisplayMetrics();
        int screenW = dm.widthPixels;
        float d = dm.density;

        // 收起态: 固定小尺寸(能看到歌词), 停在状态栏下方、靠左对齐
        sWMini = Math.min(screenW - (int) (24 * d), (int) (124 * d));
        sHMini = (int) (24 * d);
        // 展开态: 高度还原 v2.2 的 118dp(用户偏好大气泡观感)
        sWFull = screenW - (int) (24 * d);
        sHFull = (int) (118 * d);

        sWm = (WindowManager) sCtx.getSystemService(Context.WINDOW_SERVICE);

        // 背景 = 模糊专辑封面 + 暗色遮罩(播放器模式观感), 不再纯黑
        sBg = new BlurBgDrawable();
        sBg.setRadius(sHMini / 2f);
        sBg.setDimColor(DIM_MINI);
        sBg.setSolid(1f);            // 初始是收起态: 小气泡纯色 #2b2b2f
        sRadius = sHMini / 2f;

        sRoot = new FrameLayout(sCtx);
        sRoot.setBackground(sBg);
        // 圆角裁剪模糊封面位图(半径随展开动画更新)
        sRoot.setClipToOutline(true);
        sRoot.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View view, Outline outline) {
                outline.setRoundRect(0, 0, view.getWidth(), view.getHeight(), sRadius);
            }
        });

        sMini = buildMini();
        sFull = buildFull();
        sFull.setVisibility(View.GONE);
        sFull.setAlpha(0f);

        sRoot.addView(sMini, new FrameLayout.LayoutParams(sWMini, sHMini, Gravity.CENTER));
        sRoot.addView(sFull, new FrameLayout.LayoutParams(sWFull, sHFull, Gravity.CENTER));

        // MuMu 模拟器的 WMS 会静默丢弃 TYPE_SYSTEM_ERROR(2010) 窗口
        // (应用侧 addView 成功但窗口不进 WMS), 因此用桌面歌词同款
        // TYPE_APPLICATION_OVERLAY 通道; 状态栏区域的点击靠
        // FLAG_WATCH_OUTSIDE_TOUCH 的 ACTION_OUTSIDE 事件兜底(见 attachTouch)
        int type = Build.VERSION.SDK_INT >= 26
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;
        sParams = new WindowManager.LayoutParams(
                sWMini, sHMini, type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                        | WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
                PixelFormat.TRANSLUCENT);
        sParams.gravity = Gravity.TOP | Gravity.START;
        // 停靠在状态栏(系统时间)下面那一行, 靠左对齐
        sParams.x = (int) (10 * d);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 12+ 悬浮窗默认避让状态栏/刘海(坐标原点被压到状态栏底部),
            // 关闭所有避让后 y=0 才对应屏幕物理顶部。
            // 必须同时关两类: fitInsetsTypes=0 关状态栏/导航栏避让,
            // LAYOUT_IN_SCREEN|LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES 关挖孔避让。
            // (真机缺后者时窗口仍被压到状态栏下方, 表现为"没和系统时间同行")
            sParams.setFitInsetsTypes(0);
            sParams.flags |= WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;
            sParams.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        }
        int sbH = sCtx.getResources().getDimensionPixelSize(
                sCtx.getResources().getIdentifier("status_bar_height", "dimen", "android"));
        sStatusBarH = sbH;
        sParams.y = sbH + (int) (4 * d);    // 状态栏下面那一行(系统时间下方)

        attachTouch(sRoot);
        android.util.Log.i("MintIsland", "island addView type=" + type + " x=" + sParams.x + " y=" + sParams.y
                + " w=" + sParams.width + " h=" + sParams.height);
        sWm.addView(sRoot, sParams);
        android.util.Log.i("MintIsland", "island addView returned OK");

        applyLyric();
        applyMeta();
        applyCover();
    }

    /** 收起态: [封面] [滚动歌词] [律动条] */
    private static View buildMini() {
        float d = sCtx.getResources().getDisplayMetrics().density;
        LinearLayout row = new LinearLayout(sCtx);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        int pad = (int) (3 * d);
        row.setPadding(pad, 0, pad, 0);

        sCoverMini = new ImageView(sCtx);
        int cs = (int) (16 * d);
        sCoverMini.setLayoutParams(new LinearLayout.LayoutParams(cs, cs));
        sCoverMini.setScaleType(ImageView.ScaleType.CENTER_CROP);
        roundRect(sCoverMini, cs / 2f);
        row.addView(sCoverMini);

        sLyricMini = new ScrollLyricView(sCtx, 11f, false, 1.65f);    // 小气泡: 字号 11sp; 滚动 1.65x → 句时长约 61% 处即滚到最后一个字, 提前 39% 完成
        LinearLayout.LayoutParams lp =
                new LinearLayout.LayoutParams(0, (int) (16 * d), 1f);
        lp.leftMargin = (int) (6 * d);
        lp.rightMargin = (int) (5 * d);
        sLyricMini.setLayoutParams(lp);
        row.addView(sLyricMini);

        sEq = new EqView(sCtx);
        int e = (int) (10 * d);
        sEq.setLayoutParams(new LinearLayout.LayoutParams(e, e));
        row.addView(sEq);

        return row;
    }

    /** 展开态: 第一行 封面+歌名/歌手+控制, 第二行 大号歌词 (尺寸还原 v2.2) */
    private static View buildFull() {
        float d = sCtx.getResources().getDisplayMetrics().density;
        LinearLayout box = new LinearLayout(sCtx);
        box.setOrientation(LinearLayout.VERTICAL);
        int p = (int) (12 * d);
        box.setPadding(p, p, p, p);

        LinearLayout row = new LinearLayout(sCtx);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));

        sCoverFull = new ImageView(sCtx);
        int cs = (int) (46 * d);
        sCoverFull.setLayoutParams(new LinearLayout.LayoutParams(cs, cs));
        sCoverFull.setScaleType(ImageView.ScaleType.CENTER_CROP);
        roundRect(sCoverFull, 10 * d);
        row.addView(sCoverFull);

        LinearLayout texts = new LinearLayout(sCtx);
        texts.setOrientation(LinearLayout.VERTICAL);
        LinearLayout.LayoutParams tlp =
                new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        tlp.leftMargin = (int) (10 * d);
        tlp.rightMargin = (int) (8 * d);
        texts.setLayoutParams(tlp);

        sTitleFull = new TextView(sCtx);
        sTitleFull.setSingleLine(true);
        sTitleFull.setEllipsize(TextUtils.TruncateAt.END);
        sTitleFull.setTextColor(0xFFFFFFFF);
        sTitleFull.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        sTitleFull.setTypeface(Typeface.DEFAULT_BOLD);
        texts.addView(sTitleFull);

        sArtistFull = new TextView(sCtx);
        sArtistFull.setSingleLine(true);
        sArtistFull.setEllipsize(TextUtils.TruncateAt.END);
        sArtistFull.setTextColor(0x99FFFFFF);
        sArtistFull.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f);
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        alp.topMargin = (int) (2 * d);
        sArtistFull.setLayoutParams(alp);
        texts.addView(sArtistFull);

        row.addView(texts);

        int bs = (int) (34 * d);
        // 顺序: 收藏 → 上一首 → 播放/暂停 → 下一首
        sBtnFav = iconBtn(bs);
        sBtnFav.setImageResource(sFavState ? R.drawable.n_heart_filled : R.drawable.n_heart);
        sBtnFav.setOnClickListener(v -> cmd("fav"));
        row.addView(sBtnFav);

        sBtnPrev = iconBtn(bs);
        sBtnPrev.setImageResource(R.drawable.n_prev);
        sBtnPrev.setOnClickListener(v -> cmd("prev"));
        row.addView(sBtnPrev);

        sBtnToggle = iconBtn(bs);
        sBtnToggle.setOnClickListener(v -> cmd("toggle"));
        row.addView(sBtnToggle);

        sBtnNext = iconBtn(bs);
        sBtnNext.setImageResource(R.drawable.n_next);
        sBtnNext.setOnClickListener(v -> cmd("next"));
        row.addView(sBtnNext);

        box.addView(row);

        // 歌词上方: 播放时间进度条 (两端 当前时间/总时长, 中间胶囊条 高约3.4dp)
        sProgressFull = new SongProgressView(sCtx);
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, (int) (12 * d));
        plp.topMargin = (int) (7 * d);
        sProgressFull.setLayoutParams(plp);
        box.addView(sProgressFull, plp);

        sLyricFull = new ScrollLyricView(sCtx, 15f, true, 1f);   // 大气泡: 滚动保持原速
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, (int) (21 * d));
        llp.topMargin = (int) (5 * d);
        sLyricFull.setLayoutParams(llp);
        box.addView(sLyricFull, llp);

        return box;
    }

    /**
     * 展开态播放进度条: 两端显示 当前播放时间 / 总时长(8.5sp), 中间胶囊条(绿=已播/半透明白=轨道)。
     * 每 250ms 读一次 NativePlayer 真实进度 (暂停/拖动即时正确); 收起态不重绘省 CPU。
     * 纯展示不可拖动 —— 气泡的点击展开/拖动移动手势不与进度条抢触摸。
     */
    private static final class SongProgressView extends View {
        private final Paint mTrack = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint mFill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint mText = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final float mGap;                        // 文字与胶囊条之间的间距
        private String mLeft = "0:00", mRight = "0:00";  // 左=已播时间, 右=总时长
        private float mFrac = 0f;
        private boolean mAttached, mTicking, mBg;

        SongProgressView(Context c) {
            super(c);
            mTrack.setColor(0x30FFFFFF);
            mFill.setColor(GREEN);
            mText.setColor(0xB3FFFFFF);
            mText.setTextSize(TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_SP, 8.5f, c.getResources().getDisplayMetrics()));
            mText.setTypeface(Typeface.DEFAULT_BOLD);
            mGap = TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_DIP, 5f, c.getResources().getDisplayMetrics());
        }

        private final Runnable mTick = new Runnable() {
            @Override public void run() {
                if (!mTicking) return;
                long pos = sPositionMs, dur = sDurationMs;
                if (pos < 0) pos = 0;
                if (dur < 0) dur = 0;
                float f = dur > 0 ? Math.max(0f, Math.min(1f, pos / (float) dur)) : 0f;
                String l = fmtTime(pos), r = fmtTime(dur);
                if (!l.equals(mLeft) || !r.equals(mRight) || Math.abs(f - mFrac) > 0.0005f) {
                    mLeft = l; mRight = r; mFrac = f;
                    if (isShown()) invalidate();
                }
                postDelayed(this, 250);
            }
        };

        /** 毫秒 → m:ss (超过1小时 h:mm:ss) */
        private static String fmtTime(long ms) {
            long s = Math.max(0L, ms) / 1000L;
            if (s >= 3600L)
                return String.format(java.util.Locale.US, "%d:%02d:%02d", s / 3600L, s % 3600L / 60L, s % 60L);
            return String.format(java.util.Locale.US, "%d:%02d", s / 60L, s % 60L);
        }

        private void syncTicking() {
            boolean need = mAttached && !mBg;
            if (need && !mTicking) { mTicking = true; post(mTick); }
            else if (!need) mTicking = false;
        }

        void setBackgroundMode(boolean bg) { mBg = bg; syncTicking(); }

        @Override protected void onAttachedToWindow() { super.onAttachedToWindow(); mAttached = true; syncTicking(); }
        @Override protected void onDetachedFromWindow() { mAttached = false; mTicking = false; super.onDetachedFromWindow(); }

        @Override protected void onDraw(Canvas cv) {
            super.onDraw(cv);
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float textY = h / 2f - (mText.ascent() + mText.descent()) / 2f;
            float lw = mText.measureText(mLeft), rw = mText.measureText(mRight);
            cv.drawText(mLeft, 0, textY, mText);
            cv.drawText(mRight, w - rw, textY, mText);
            // 中间胶囊条: 轨道全宽, 绿色按真实进度填充
            float bx0 = lw + mGap, bx1 = w - rw - mGap, barH = h * 0.28f;
            if (bx1 - bx0 < barH * 2) return;
            float by0 = (h - barH) / 2f, by1 = by0 + barH, r = barH / 2f;
            cv.drawRoundRect(bx0, by0, bx1, by1, r, r, mTrack);
            if (mFrac > 0f) {
                float fw = bx0 + (bx1 - bx0) * mFrac;
                if (fw - bx0 > barH) cv.drawRoundRect(bx0, by0, fw, by1, r, r, mFill);
                else cv.drawCircle(bx0 + r, by0 + r, r, mFill);   // 起播瞬间: 圆点
            }
        }
    }

    private static ImageView iconBtn(int size) {
        ImageView iv = new ImageView(sCtx);
        iv.setLayoutParams(new LinearLayout.LayoutParams(size, size));
        iv.setScaleType(ImageView.ScaleType.CENTER);
        iv.setBackground(pressBg(size));
        int pad = Math.max(2, Math.round(size * 0.15f));
        iv.setPadding(pad, pad, pad, pad);
        return iv;
    }

    private static StateListDrawable pressBg(int sizePx) {
        StateListDrawable sld = new StateListDrawable();
        GradientDrawable pressed = new GradientDrawable();
        pressed.setColor(0x22FFFFFF);
        pressed.setCornerRadius(sizePx / 2f);
        sld.addState(new int[]{android.R.attr.state_pressed}, pressed);
        sld.addState(new int[]{}, new ColorDrawable(Color.TRANSPARENT));
        return sld;
    }

    private static void roundRect(View v, final float radius) {
        v.setClipToOutline(true);
        v.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View view, Outline outline) {
                outline.setRoundRect(0, 0, view.getWidth(), view.getHeight(), radius);
            }
        });
    }

    // ==================== 交互: 点击展开/收起, 拖动移动 ====================

    private static void attachTouch(View v) {
        final float[] down = new float[2];
        final int[] init = new int[2];
        final boolean[] moved = new boolean[1];

        v.setOnTouchListener((view, ev) -> {
            if (sParams == null) return false;
            switch (ev.getAction()) {
                case MotionEvent.ACTION_OUTSIDE:
                    android.util.Log.i("iMusic", "island OUTSIDE raw=(" + ev.getRawX() + "," + ev.getRawY()
                            + ") win=(" + sParams.x + "," + sParams.y + "," + sParams.width + "x" + sParams.height
                            + ") expanded=" + sExpanded);
                    if (sExpanded) {
                        // 点击药丸以外区域 → 收起
                        sExpanded = false;
                        animateTo(false);
                    } else {
                        // 兜底: 药丸停靠状态栏附近时, 部分 ROM 会拦截该区域的直接触摸,
                        // 但 OUTSIDE 事件会携带真实屏幕坐标: 命中药丸范围即视为点击展开
                        float px = ev.getRawX(), py = ev.getRawY();
                        if (px >= sParams.x && px <= sParams.x + sParams.width
                                && py >= sParams.y && py <= sParams.y + sParams.height) {
                            sExpanded = true;
                            animateTo(true);
                        }
                    }
                    return true;
                case MotionEvent.ACTION_DOWN:
                    down[0] = ev.getRawX();
                    down[1] = ev.getRawY();
                    init[0] = sParams.x;
                    init[1] = sParams.y;
                    moved[0] = false;
                    return true;
                case MotionEvent.ACTION_MOVE: {
                    float dx = ev.getRawX() - down[0];
                    float dy = ev.getRawY() - down[1];
                    if (Math.abs(dx) > 8 || Math.abs(dy) > 8) moved[0] = true;
                    sParams.x = init[0] + (int) dx;
                    sParams.y = init[1] + (int) dy;
                    clampToScreen();
                    try { sWm.updateViewLayout(sRoot, sParams); } catch (Exception ignored) {}
                    return true;
                }
                case MotionEvent.ACTION_UP:
                    if (!moved[0]) {
                        if (sExpanded) {
                            // 展开态点击气泡内部(非控制按钮) → 回到 App 播放页
                            openApp();
                        } else {
                            sExpanded = true;
                            animateTo(true);
                        }
                    }
                    return true;
            }
            return false;
        });
    }

    private static void animateTo(final boolean expand) {
        if (sRoot == null || sWm == null || sParams == null || sBg == null) return;
        if (sSizeAnim != null) { sSizeAnim.cancel(); sSizeAnim = null; }

        float d = sCtx.getResources().getDisplayMetrics().density;
        int screenW = sCtx.getResources().getDisplayMetrics().widthPixels;
        final int fromW = sParams.width, fromH = sParams.height;
        final int fromX = sParams.x, fromY = sParams.y;
        final int toW = expand ? sWFull : sWMini;
        final int toH = expand ? sHFull : sHMini;
        // 展开: 大气泡水平居中; 收起: 回到展开前药丸的位置(状态栏下方靠左)
        if (expand) { sSavedMiniX = fromX; sSavedMiniY = fromY; }
        final int toX = expand ? Math.round((screenW - toW) / 2f) : sSavedMiniX;
        // 垂直: 展开时卡片顶部锚定在状态栏下方(避免被状态栏盖住)
        final int toY = expand
                ? Math.max(Math.round(fromY + fromH / 2f - toH / 2f), sStatusBarH)
                : sSavedMiniY;
        final float fromR = fromH / 2f;
        final float toR = expand ? 14 * d : toH / 2f;
        // 遮罩浓度: 小气泡 35% ↔ 大气泡 45%, 随动画插值
        final int fromA = expand ? DIM_A_MINI : DIM_A_FULL;
        final int toA   = expand ? DIM_A_FULL : DIM_A_MINI;

        if (expand) sFull.setVisibility(View.VISIBLE);

        sSizeAnim = ValueAnimator.ofFloat(0f, 1f);
        sSizeAnim.setDuration(320);
        sSizeAnim.setInterpolator(new DecelerateInterpolator());
        sSizeAnim.addUpdateListener(a -> {
            float f = (float) a.getAnimatedValue();
            sParams.width  = Math.round(fromW + (toW - fromW) * f);
            sParams.height = Math.round(fromH + (toH - fromH) * f);
            sParams.x = Math.round(fromX + (toX - fromX) * f);
            sParams.y = Math.round(fromY + (toY - fromY) * f);
            clampToScreen();
            sRadius = fromR + (toR - fromR) * f;
            sBg.setRadius(sRadius);
            if (sRoot != null) sRoot.invalidateOutline();
            int da = Math.round(fromA + (toA - fromA) * f);
            sBg.setDimColor((da << 24) | (DIM_MINI & 0xFFFFFF));
            // 纯色底 ↔ 封面模糊随展开动画过渡: 展开时纯色淡出, 收起时淡入
            sBg.setSolid(expand ? 1f - f : f);
            // 展开: mini 淡出 / full 淡入; 收起: mini 淡入 / full 淡出。
            // (此前收起误用 1-f, 把 mini 也淡成透明, 窗口只剩黑底 → 黑色方块残留)
            sMini.setAlpha(expand ? 1f - f : f);
            sFull.setAlpha(expand ? f : 1f - f);
            try { sWm.updateViewLayout(sRoot, sParams); } catch (Exception ignored) {}
        });
        sSizeAnim.addListener(new AnimatorListenerAdapter() {
            @Override public void onAnimationEnd(Animator animation) {
                // cancel 也会走到这里, 按本次动画目标方向钉死终态, 防止半透明残留
                if (sMini != null) sMini.setAlpha(expand ? 0f : 1f);
                if (sFull != null) {
                    sFull.setAlpha(expand ? 1f : 0f);
                    if (!expand) sFull.setVisibility(View.GONE);
                }
                if (sBg != null) sBg.setSolid(expand ? 0f : 1f);
                sSizeAnim = null;
            }
        });
        sSizeAnim.start();
    }

    /** 把窗口位置钳制在屏幕范围内, 防止拖动/展开后伸出屏幕 */
    private static void clampToScreen() {
        if (sCtx == null || sParams == null) return;
        int screenW = sCtx.getResources().getDisplayMetrics().widthPixels;
        sParams.x = Math.max(0, Math.min(screenW - sParams.width, sParams.x));
        sParams.y = Math.max(0, sParams.y);
    }

    private static void cmd(String c) {
        CommandCallback h = sCallback;
        if (h != null) h.onCommand(c);
    }

    /** 展开态点击气泡内部: 收起小药丸 + 拉起 App 并打开全屏播放页 */
    private static void openApp() {
        sExpanded = false;
        animateTo(false);
        try {
            Intent i = new Intent(sCtx, MainActivity.class)
                    .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra(MainActivity.EXTRA_OPEN_PLAYER, true);
            sCtx.startActivity(i);
            // 拉起 App 后由 Flutter 处理播放页展开
        } catch (Throwable e) {
            android.util.Log.e("MintIsland", "island openApp failed", e);
        }
    }

    // ==================== 数据刷新 ====================

    private static void applyLyric() {
        String t = sLyric.isEmpty()
                ? (sTitle.isEmpty() ? "♪ 薄荷音乐" : "♪ " + sTitle)
                : sLyric;
        long dur = sLyricEnd > sLyricStart ? sLyricEnd - sLyricStart : 0L;
        long[][] words = sWords;
        if (words != null) {
            // QRC 逐字模式: 白句+绿填色, 按 NativePlayer 真实进度推进
            if (sLyricMini != null) sLyricMini.setWords(t, sLyricStart, dur, words);
            if (sLyricFull != null) sLyricFull.setWords(t, sLyricStart, dur, words);
        } else {
            // setText/setWords 内部已去重: 只有换句时才重置到句首重新滚动
            if (sLyricMini != null) sLyricMini.setText(t, dur);
            if (sLyricFull != null) sLyricFull.setText(t, dur);
        }
    }

    private static void applyMeta() {
        if (sTitleFull != null) sTitleFull.setText(sTitle.isEmpty() ? "薄荷音乐" : sTitle);
        if (sArtistFull != null) sArtistFull.setText(sArtist);
        if (sBtnToggle != null) sBtnToggle.setImageResource(sPlaying ? R.drawable.n_pause : R.drawable.n_play);
        if (sBtnFav != null) sBtnFav.setImageResource(sFavState ? R.drawable.n_heart_filled : R.drawable.n_heart);
        if (sEq != null) sEq.setPlaying(sPlaying);
    }

    private static void applyCover() {
        if (sCoverMini != null) {
            if (sCover != null) sCoverMini.setImageBitmap(sCover);
            else sCoverMini.setImageResource(R.mipmap.ic_launcher);
        }
        if (sCoverFull != null) {
            if (sCover != null) sCoverFull.setImageBitmap(sCover);
            else sCoverFull.setImageResource(R.mipmap.ic_launcher);
        }
        if (sBg != null) sBg.setCover(sCover);
    }

    // ==================== 内部 View ====================

    /**
     * 单行歌词: 任何时刻只绘制一份文本。
     *
     * 有句时间信息时跟随演唱进度滚动: 句首从第一个字开始, 唱到句尾时刚好滚到最后一个字,
     * 之后停在句尾等换句 —— 一次只显示一句完整歌词。
     * 无时间信息时匀速滚到句尾停住, 同样不回滚。
     *
     * 不用系统 marquee: 它滚动时会在尾部再补一份同样的文本做无缝循环,
     * 在窄气泡里看起来就是"同一句显示了两次"; 且它不保证换句时回到句首。
     */
    private static final class ScrollLyricView extends View {
        private final Paint mPaintBase = new Paint(Paint.ANTI_ALIAS_FLAG);  // 未唱: 白
        private final Paint mPaintFill = new Paint(Paint.ANTI_ALIAS_FLAG);  // 已唱: 绿
        private final boolean mCenter;
        private String mText = "";
        private long mDur;                       // 本句时长 ms; 0=无时间信息
        private long mStart;                     // 本句起始(歌曲绝对 ms), 逐字模式用
        private long[][] mWords;                 // [起ms,止ms,字符数]...; null=逐行模式(整句绿)
        private float[] mWordX;                  // 每个词末尾的 x 坐标(文本坐标系)
        private float mFillX = -1f;              // 填色前沿 x; -1=不填色
        private float mTextW, mScroll, mMaxScroll;
        private final float mSpeed;                  // 滚动速度倍率(小气泡 1.10 = 快 10%)
        private long mT0 = android.os.SystemClock.uptimeMillis();
        private boolean mAttached, mTicking;

        ScrollLyricView(Context c, float sp, boolean center, float speed) {
            super(c);
            mCenter = center;
            mSpeed = speed;
            mPaintBase.setColor(0xFFFFFFFF);
            mPaintFill.setColor(GREEN);
            mPaintBase.setTextSize(TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_SP, sp, c.getResources().getDisplayMetrics()));
            mPaintFill.setTextSize(mPaintBase.getTextSize());
            mPaintBase.setTypeface(Typeface.DEFAULT_BOLD);
            mPaintFill.setTypeface(Typeface.DEFAULT_BOLD);
            // 深色晕影: 模糊封面背景偏亮时保证白/绿字依然清晰
            mPaintBase.setShadowLayer(4f, 0f, 0f, 0xCC000000);
            mPaintFill.setShadowLayer(4f, 0f, 0f, 0xCC000000);
        }

        /** 换句时重置到句首, 保证显示的始终是当前唱到的那一句 */
        void setText(String t, long durMs) {
            setWords(t, 0L, durMs, null);
        }

        /** 逐字模式: words 为 null 时自动退回逐行行为(整句绿由 fill 关闭+基色实现) */
        void setWords(String t, long startMs, long durMs, long[][] words) {
            String s = t == null ? "" : t;
            long dur = Math.max(0L, durMs);
            if (s.equals(mText) && dur == mDur && startMs == mStart
                    && java.util.Arrays.deepEquals(words, mWords)) return;
            mText = s;
            mDur = dur;
            mStart = startMs;
            mWords = words;
            mTextW = mPaintBase.measureText(s);
            if (words != null) {
                // 预计算每个词末尾的 x: 按词字符数切分文本累计测量
                mWordX = new float[words.length];
                int charIdx = 0;
                for (int i = 0; i < words.length; i++) {
                    charIdx = Math.min(s.length(), charIdx + (int) words[i][2]);
                    mWordX[i] = mPaintBase.measureText(s, 0, charIdx);
                }
            } else {
                mWordX = null;
            }
            mT0 = android.os.SystemClock.uptimeMillis();
            mScroll = 0;
            mFillX = -1f;
            remeasure();
            invalidate();
        }

        private void remeasure() {
            mMaxScroll = Math.max(0f, mTextW - getWidth());
            // 逐字模式下即使不滚动也要走帧(填色前沿随演唱推进)
            boolean need = mAttached && (mMaxScroll > 0.5f || mWords != null);
            if (need && !mTicking) { mTicking = true; post(mTick); }
            else if (!need) mTicking = false;
        }

        @Override protected void onSizeChanged(int w, int h, int ow, int oh) {
            super.onSizeChanged(w, h, ow, oh);
            remeasure();
        }

        @Override protected void onAttachedToWindow() {
            super.onAttachedToWindow();
            mAttached = true;
            remeasure();
        }

        @Override protected void onDetachedFromWindow() {
            mAttached = false;
            mTicking = false;
            super.onDetachedFromWindow();
        }

        /** 后台(打游戏)时停止歌词滚动动画, 回到前台时从句首重新匀速滚动 */
        void setBackgroundMode(boolean bg) {
            if (bg) { mTicking = false; }
            else { mT0 = android.os.SystemClock.uptimeMillis(); remeasure(); invalidate(); }
        }

        private final Runnable mTick = new Runnable() {
            @Override public void run() {
                if (!mTicking) return;
                // 20fps: 匀速滚动在低帧率下已平滑; 不在屏幕上时跳过重绘省 CPU
                step();
                if (isShown()) invalidate();
                postDelayed(this, 50);
            }
        };

        /** 本句内已演唱毫秒: 逐字模式用原生播放器真实进度(暂停/拖动即时正确); 否则按挂钟线性推 */
        private long elapsedMs() {
            if (mWords != null) {
                long pos = sPositionMs;
                if (pos >= 0) return pos - mStart;
            }
            return android.os.SystemClock.uptimeMillis() - mT0;
        }

        /** 填色前沿 x (文本坐标系): 已唱词按词界跳变, 正在唱的词内按演唱进度线性填充。
         *  el 为句内相对毫秒, 词时间轴是绝对歌曲毫秒 → 统一换算成绝对时间再比较 */
        private float fillXAt(long el) {
            long[][] ws = mWords;
            if (ws == null) return -1f;
            long now = mStart + el;
            float prevX = 0f;
            for (int i = 0; i < ws.length; i++) {
                float xEnd = mWordX[i];
                long ws0 = ws[i][0], we0 = ws[i][1];
                if (now < ws0) return prevX;                   // 本词未开始
                if (now < we0) {                               // 本词正在唱: 词内线性
                    float frac = we0 > ws0 ? (now - ws0) / (float) (we0 - ws0) : 1f;
                    return prevX + (xEnd - prevX) * frac;
                }
                prevX = xEnd;
            }
            return prevX;                                      // 全句唱完
        }

        private void step() {
            if (mWords != null) {
                long el = elapsedMs();
                mFillX = fillXAt(el);
                if (mMaxScroll > 0.5f) {
                    // 逐字模式: 滚动跟随填色前沿, 让"正在唱的字"始终留在可视区
                    // (不能按句时长倍速冲到句尾 —— 那样可视窗口会跑到绿色填色前面, 看到的全是白字)
                    float keep = getWidth() * 0.55f;
                    float target = Math.max(0f, mFillX - keep);
                    mScroll = Math.min(mMaxScroll, target);
                }
                return;
            }
            mFillX = -1f;
            if (mMaxScroll <= 0.5f) { mScroll = 0; return; }
            long t = android.os.SystemClock.uptimeMillis() - mT0;
            if (mDur > 0) {
                // 跟随演唱进度匀速推进: 唱到句尾时刚好显示最后一个字, 之后停在句尾
                // (按 mSpeed 提速: 更快滚到句尾, 然后停住等换句)
                float p = Math.min(1f, t * mSpeed / (float) mDur);
                mScroll = mMaxScroll * p;
                return;
            }
            // 无时间信息: 匀速滚到句尾后停住 —— 不往回滚(回滚会让人感觉"歌词倒带")
            float move = Math.min(9000f, Math.max(1200f, mMaxScroll / 0.075f)) / mSpeed;
            float p = Math.min(1f, t / move);
            mScroll = mMaxScroll * p;
        }

        @Override protected void onDraw(Canvas cv) {
            super.onDraw(cv);
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0 || mText.isEmpty()) return;
            float y = h / 2f - (mPaintBase.ascent() + mPaintBase.descent()) / 2f;
            // 文本放得下时不滚动: 小气泡靠左, 大卡片居中
            float x = (mMaxScroll <= 0.5f && mCenter) ? (w - mTextW) / 2f : 0f;
            float drawX = x - mScroll;
            if (mWords == null) {
                // 逐行模式(无QRC): 保持原整句绿色
                cv.drawText(mText, drawX, y, mPaintFill);
                return;
            }
            cv.drawText(mText, drawX, y, mPaintBase);          // 整句白色
            if (mFillX > 0f) {
                cv.save();
                cv.clipRect(drawX, 0f, drawX + mFillX, h);
                cv.drawText(mText, drawX, y, mPaintFill);      // 已唱部分填绿
                cv.restore();
            }
        }
    }

    /**
     * 封面主色"毛玻璃"背景(对应图2红框: 唱片两侧露出的封面主色):
     * 采样封面平均色 → 亮度钳到可见区间 → 竖向微渐变(顶部亮/底部暗, 玻璃层次)
     * → 叠一层轻暗罩。半透明绘制, 悬浮窗背后内容微微透出 = 玻璃微透。
     */
    private static final class BlurBgDrawable extends Drawable {
        private static final int DIM_BASE = 0x22242A;
        /** 小气泡纯色背景(2026-09 用户要求): #2b2b2f, 不再叠封面主色渐变; 大气泡仍是封面模糊 */
        private static final int SOLID_MINI = 0xFF2B2B2F;
        private static final float ALPHA_GLASS = 1.0f;       // 底色完全不透明(2026-09 用户要求): 不透出背后 App 内容
        private final Paint mPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint mBmp = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.ANTI_ALIAS_FLAG);   // 模糊封面(色彩矩阵)
        private final Paint mScrim = new Paint(Paint.ANTI_ALIAS_FLAG);   // 播放页 .pmask 同款遮罩
        private final RectF mRect = new RectF();
        private Bitmap mSmall;                       // 封面 48x48 缩小版, 拉伸铺满 = 播放页 blur(80px) 同款
        private int mMain = 0xFF6B6E76;                      // 封面主色(钳亮度后); 兜底中性灰, 无封面也不再黑底
        private int mDim = DIM_MINI;
        private float mSolid = 1f;                           // 1=小气泡纯色 #2b2b2f, 0=大气泡封面模糊
        private float mRadius;
        private boolean mHasCover;
        private Shader mScrimShader;
        private int mScrimH;

        /** 采样封面主色并重建模糊封面位图(播放页 .pbg 同款配方) */
        void setCover(Bitmap cover) {
            mHasCover = cover != null && !cover.isRecycled();
            if (mSmall != null) { mSmall.recycle(); mSmall = null; }
            if (mHasCover) {
                mMain = avgColorBright(cover);
                // 播放页 .pbg = blur(80px)+brightness(.62)+saturate(1.65):
                // 两步降采样到 16x16, 再拉伸铺满卡片 ≈ blur(80px) 的色块尺度, 颜色每首歌跟随封面
                int s = Math.max(1, cover.getWidth() / 8);
                Bitmap mid = Bitmap.createScaledBitmap(cover, s, s, true);
                mSmall = Bitmap.createScaledBitmap(mid, 16, 16, true);
                if (mSmall != mid) mid.recycle();
                ColorMatrix cm = new ColorMatrix();
                cm.setSaturation(1.65f);                          // saturate(1.65)
                ColorMatrix br = new ColorMatrix();
                br.setScale(0.62f, 0.62f, 0.62f, 1f);             // brightness(.62)
                cm.postConcat(br);
                mBmp.setColorFilter(new ColorMatrixColorFilter(cm));
            }
            mShader = null;
            mScrimShader = null;
            invalidateSelf();
        }

        private Shader mShader;

        void setRadius(float r) { if (mRadius != r) { mRadius = r; invalidateSelf(); } }
        void setDimColor(int c) { if (mDim != c) { mDim = c; invalidateSelf(); } }
        /** 纯色底强度: 1=完全用 #2b2b2f 盖住封面色(小气泡), 0=露出封面模糊(大气泡) */
        void setSolid(float v) { if (mSolid != v) { mSolid = v; invalidateSelf(); } }

        @Override public void draw(Canvas cv) {
            Rect b = getBounds();
            if (b.isEmpty()) return;
            mRect.set(b);
            if (mSmall != null) {
                // 大气泡: 播放页上半部分同款 —— 强模糊封面拉伸铺满(每首歌不同的彩色渐变)
                float strip = Math.max(1.5f, 16f * b.height() / Math.max(1, b.width()));
                float y0 = (16f - strip) * 0.35f;             // 取偏上中段 ≈ 播放页上半部分取色区
                cv.drawBitmap(mSmall, new Rect(0, Math.round(y0), 16, Math.round(y0 + strip)),
                        b, mBmp);
                // 播放页 .pmask 同款上亮下暗遮罩(顶部 .22 → 底部 .66), 白字/绿歌词可读
                if (mScrimShader == null || mScrimH != b.height()) {
                    mScrimH = b.height();
                    mScrimShader = new LinearGradient(0, 0, 0, mScrimH,
                            applyAlpha(0x0A0C10, 0.22f), applyAlpha(0x0A0C10, 0.66f),
                            Shader.TileMode.CLAMP);
                }
                mScrim.setShader(mScrimShader);
                cv.drawRoundRect(mRect, mRadius, mRadius, mScrim);
                mScrim.setShader(null);
            } else {
                // 无封面兜底: 封面主色上下渐变
                if (mShader == null) {
                    float[] hsv = new float[3];
                    Color.colorToHSV(mMain, hsv);
                    float h = hsv[0], s = hsv[1], v = hsv[2];
                    int top = Color.HSVToColor(0xFF, new float[]{h, s * 0.92f, Math.min(1f, v * 1.22f + 0.04f)});
                    int bot = Color.HSVToColor(0xFF, new float[]{h, Math.min(1f, s * 1.06f), v * 0.85f});
                    mShader = new LinearGradient(0, 0, 0, b.height(),
                            applyAlpha(top, ALPHA_GLASS), applyAlpha(bot, ALPHA_GLASS),
                            Shader.TileMode.CLAMP);
                }
                mPaint.setShader(mShader);
                // 关键: shader 只提供颜色, paint 上残留的 alpha(上一帧暗罩 0xB3)会乘进输出,
                // 导致大气泡渐变只有 70% 不透明度 → 背后 App 内容透出。画渐变前必须归位 255。
                mPaint.setAlpha(255);
                cv.drawRoundRect(mRect, mRadius, mRadius, mPaint);
                mPaint.setShader(null);
            }
            if (mSolid > 0f) {
                // 小气泡: 用 #2b2b2f 盖住封面模糊 → 干净纯色底
                mPaint.setColor(applyAlpha(SOLID_MINI, mSolid));
                cv.drawRoundRect(mRect, mRadius, mRadius, mPaint);
            }
            // 旧暗罩仅无封面兜底路径使用(有封面时已换 .pmask 渐变, 颜色不再被灰罩压平)
            if (mSmall == null) {
                float dimScale = 1f - mSolid;
                if (dimScale > 0f) {
                    int a = Math.round(Color.alpha(mDim) * dimScale);
                    mPaint.setColor((a << 24) | DIM_BASE);
                    cv.drawRoundRect(mRect, mRadius, mRadius, mPaint);
                }
            }
        }

        /** 255 不透明度颜色 → 指定比例 alpha */
        private static int applyAlpha(int color, float alpha) {
            return ((Math.round(255 * alpha)) << 24) | (color & 0xFFFFFF);
        }

        /** 封面平均色, 亮度钳到可见区间(暗封面大幅提亮, 否则深色封面气泡近黑), 饱和稍降避免刺眼 */
        private static int avgColorBright(Bitmap src) {
            Bitmap one = Bitmap.createScaledBitmap(src, 1, 1, true);
            int c = one.getPixel(0, 0);
            one.recycle();
            float[] hsv = new float[3];
            Color.colorToHSV(c, hsv);
            hsv[1] = Math.min(1f, hsv[1] * 0.85f + 0.05f);
            hsv[2] = Math.max(0.60f, Math.min(0.78f, hsv[2] * 1.30f));
            return Color.HSVToColor(hsv);
        }

        @Override public void setAlpha(int alpha) { invalidateSelf(); }
        @Override public void setColorFilter(android.graphics.ColorFilter cf) { }
        @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
    }

    /** 三根跳动的律动条 (≈20fps: 游戏时悬浮窗盖在游戏上, 低帧率重绘减少与游戏抢 CPU) */
    private static final class EqView extends View {
        private final Paint mPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF mBar = new RectF();
        private final float[] mH = {0.30f, 0.62f, 0.40f};
        private ValueAnimator mAnim;
        private int mFrame;
        private boolean mPlaying;

        EqView(Context c) {
            super(c);
            mPaint.setColor(GREEN);
        }

        void setPlaying(boolean p) {
            if (mPlaying == p) return;
            mPlaying = p;
            if (p) startAnim(); else stopAnim();
        }

        /** 后台(打游戏)时停止律动条动画, 回到前台且正在播放时恢复跳动 */
        void setBackgroundMode(boolean bg) {
            if (bg) stopAnim();
            else if (mPlaying) startAnim();
        }

        private void startAnim() {
            stopAnim();
            mAnim = ValueAnimator.ofFloat(0f, 1f);
            mAnim.setDuration(760);
            mAnim.setRepeatCount(ValueAnimator.INFINITE);
            mAnim.setRepeatMode(ValueAnimator.RESTART);
            mAnim.addUpdateListener(a -> {
                if (++mFrame % 3 != 0) return;   // 60fps 动画值 → 20fps 重绘
                float t = (float) a.getAnimatedValue() * (float) (Math.PI * 2);
                mH[0] = 0.28f + 0.62f * Math.abs((float) Math.sin(t));
                mH[1] = 0.28f + 0.62f * Math.abs((float) Math.sin(t + 1.1f));
                mH[2] = 0.28f + 0.62f * Math.abs((float) Math.sin(t + 2.3f));
                invalidate();
            });
            mAnim.start();
        }

        private void stopAnim() {
            if (mAnim != null) { mAnim.cancel(); mAnim = null; }
            mH[0] = 0.26f; mH[1] = 0.26f; mH[2] = 0.26f;
            invalidate();
        }

        @Override protected void onAttachedToWindow() {
            super.onAttachedToWindow();
            if (mPlaying) startAnim();
        }

        @Override protected void onDetachedFromWindow() {
            stopAnim();
            super.onDetachedFromWindow();
        }

        @Override protected void onDraw(Canvas cv) {
            super.onDraw(cv);
            float w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            float bw = Math.max(2f, w / 5.5f);
            float gap = (w - bw * 3) / 2f;
            float r = bw / 2f;
            for (int i = 0; i < 3; i++) {
                float x = i * (bw + gap);
                float bh = Math.max(h * 0.16f, h * mH[i]);
                float top = (h - bh) / 2f;
                mBar.set(x, top, x + bw, top + bh);
                cv.drawRoundRect(mBar, r, r, mPaint);
            }
        }
    }
}
