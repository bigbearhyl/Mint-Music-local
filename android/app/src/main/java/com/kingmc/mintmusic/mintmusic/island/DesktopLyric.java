package com.kingmc.mintmusic.mintmusic.island;

import android.content.Context;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 桌面歌词悬浮窗（与 iMusic 通知栏"词"按钮同款）：
 * 上方绿色歌词文字 + 下方 A-/A+ 字号调整条，可拖动；双击锁定（触摸穿透，打游戏不误触）。
 *
 * 复用灵动岛的 TYPE_APPLICATION_OVERLAY 悬浮窗通道与 SYSTEM_ALERT_WINDOW 权限。
 */
public final class DesktopLyric {

    private static final String PREF_SIZE = "desktop_lyric_size";
    private static final String PREF_LOCKED = "desktop_lyric_locked";
    private static final int GREEN = 0xFF3BF787;
    /** 默认 Y 偏移（dp）：300dp ≈ 屏幕 50% 位置，避开状态栏/灵动岛/通知栏的顶部遮挡区。
     *  之前默认 260dp 在 density 3 下落到 780px 仍靠近顶部，且用户拖动后可能滑到 100-200px
     *  顶部被通知栏覆盖，桌面歌词"看起来没出现"。 */
    private static final int DEFAULT_Y_DP = 300;

    private static Context sCtx;
    private static WindowManager sWm;
    private static WindowManager.LayoutParams sParams;
    private static LinearLayout sBox;
    private static TextView sText;
    private static View sCtrlShrink, sCtrlGrow;

    private static volatile String sLyric = "";
    private static volatile boolean sShowing;
    private static volatile boolean sLocked;
    private static volatile int sTextSize = 16;   // sp

    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private DesktopLyric() {}

    public static boolean isShowing() {
        return sShowing;
    }

    public static boolean isLocked() {
        return sLocked;
    }

    /** 设置桌面歌词锁定状态（立即应用并持久化），用于通知栏开关同步 */
    public static void setLocked(boolean lock) {
        MAIN.post(() -> {
            applyLock(lock);
        });
    }

    /** 打开/关闭；返回操作后是否显示中 */
    public static boolean toggle(Context ctx) {
        if (sShowing) {
            hide();
            return false;
        }
        show(ctx);
        return sShowing;
    }

    public static void show(Context ctx) {
        if (sShowing) return;
        sCtx = ctx.getApplicationContext();
        final android.content.SharedPreferences prefs =
                sCtx.getSharedPreferences("mintmusic", Context.MODE_PRIVATE);
        sTextSize = prefs.getInt(PREF_SIZE, 16);
        sLocked = prefs.getBoolean(PREF_LOCKED, false);
        // 同步置位：调用方（MethodChannel）需要立刻拿到"已显示"的结果
        sShowing = true;
        MAIN.post(() -> {
            try {
                build();
            } catch (Throwable e) {
                android.util.Log.e("MintLyric", "desktop lyric show failed", e);
                sShowing = false;
            }
        });
    }

    public static void hide() {
        MAIN.post(() -> {
            if (sBox != null && sWm != null) {
                try {
                    sWm.removeView(sBox);
                } catch (Exception ignored) {
                }
            }
            sBox = null;
            sText = null;
            sCtrlShrink = null;
            sCtrlGrow = null;
            sWm = null;
            sParams = null;
            sShowing = false;
        });
    }

    /** 当前歌词行（任意线程） */
    public static void setLyric(String text) {
        final String line = text == null ? "" : text;
        if (line.equals(sLyric)) return;
        sLyric = line;
        MAIN.post(() -> {
            if (sText != null) sText.setText(line.isEmpty() ? "♪ 桌面歌词" : line);
        });
    }

    private static float density() {
        return android.content.res.Resources.getSystem().getDisplayMetrics().density;
    }

    private static void build() {
        float d = density();
        int screenW = android.content.res.Resources.getSystem().getDisplayMetrics().widthPixels;
        int totalW = screenW - Math.round(32 * d);

        sBox = new LinearLayout(sCtx);
        sBox.setOrientation(LinearLayout.VERTICAL);
        sBox.setGravity(Gravity.CENTER_HORIZONTAL);
        int padH = Math.round(18 * d);
        sBox.setPadding(padH, Math.round(8 * d), padH, Math.round(8 * d));
        sBox.setBackground(roundedBg(0xE622242A, 12 * d));

        sText = new TextView(sCtx);
        sText.setText(sLyric.isEmpty() ? "♪ 桌面歌词" : sLyric);
        sText.setTextColor(GREEN);
        sText.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, sTextSize);
        sText.setTypeface(Typeface.DEFAULT_BOLD);
        sText.setMaxLines(2);
        sText.setGravity(Gravity.CENTER);
        sText.setShadowLayer(6f, 0f, 0f, 0xF2000000);
        int textW = totalW - padH * 2;
        LinearLayout.LayoutParams tlp =
                new LinearLayout.LayoutParams(textW, LinearLayout.LayoutParams.WRAP_CONTENT);
        tlp.gravity = Gravity.CENTER_HORIZONTAL;
        sBox.addView(sText, tlp);

        LinearLayout bar = new LinearLayout(sCtx);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams blp =
                new LinearLayout.LayoutParams(textW, LinearLayout.LayoutParams.WRAP_CONTENT);
        blp.topMargin = Math.round(4 * d);

        sCtrlShrink = ctrlBtn("A-", v -> applySize(sTextSize - 2));
        bar.addView(sCtrlShrink);

        View spacer = new View(sCtx);
        spacer.setLayoutParams(new LinearLayout.LayoutParams(0, 1, 1f));
        bar.addView(spacer);

        sCtrlGrow = ctrlBtn("A+", v -> applySize(sTextSize + 2));
        bar.addView(sCtrlGrow);

        sBox.addView(bar, blp);

        // 拖动歌词；双击锁定/解锁
        sText.setOnTouchListener(new DragListener());

        sWm = (WindowManager) sCtx.getSystemService(Context.WINDOW_SERVICE);
        int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;
        sParams = new WindowManager.LayoutParams(
                totalW, WindowManager.LayoutParams.WRAP_CONTENT, type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        sParams.gravity = Gravity.TOP | Gravity.START;
        sParams.x = Math.round(16 * d);
        sParams.y = Math.round(DEFAULT_Y_DP * d);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            sParams.setFitInsetsTypes(0);
        }

        applyLockInternal(sLocked);
        sWm.addView(sBox, sParams);
    }

    private static TextView ctrlBtn(String text, View.OnClickListener click) {
        TextView b = new TextView(sCtx);
        b.setText(text);
        b.setTextColor(0xCCFFFFFF);
        b.setTextSize(13);
        b.setShadowLayer(3f, 1f, 1f, 0xCC000000);
        b.setGravity(Gravity.CENTER);
        b.setPadding(Math.round(10 * density()), 0, Math.round(10 * density()), 0);
        b.setOnClickListener(click);
        return b;
    }

    private static void applySize(int size) {
        sTextSize = Math.max(14, Math.min(34, size));
        if (sText != null) {
            sText.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, sTextSize);
        }
        if (sCtx != null) {
            sCtx.getSharedPreferences("mintmusic", Context.MODE_PRIVATE)
                    .edit()
                    .putInt(PREF_SIZE, sTextSize)
                    .apply();
        }
    }

    private static void applyLock(boolean lock) {
        sLocked = lock;
        if (sCtx != null) {
            sCtx.getSharedPreferences("mintmusic", Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PREF_LOCKED, lock)
                    .apply();
        }
        applyLockInternal(lock);
    }

    /** 锁定：触摸穿透（打游戏不误触），隐藏 A-/A+，去掉黑底只留绿字 */
    private static void applyLockInternal(boolean lock) {
        if (sBox == null || sParams == null) return;
        int cv = lock ? View.GONE : View.VISIBLE;
        if (sCtrlShrink != null) sCtrlShrink.setVisibility(cv);
        if (sCtrlGrow != null) sCtrlGrow.setVisibility(cv);
        sBox.setBackground(lock ? null : roundedBg(0xE622242A, 12 * density()));
        if (sText != null) {
            if (lock) sText.setShadowLayer(0f, 0f, 0f, 0);
            else sText.setShadowLayer(6f, 0f, 0f, 0xF2000000);
        }
        if (lock) sParams.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        else sParams.flags &= ~WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        if (sWm != null && sShowing) {
            try {
                sWm.updateViewLayout(sBox, sParams);
            } catch (Exception ignored) {
            }
        }
    }

    private static void clampToScreen() {
        if (sParams == null) return;
        int screenW = android.content.res.Resources.getSystem().getDisplayMetrics().widthPixels;
        sParams.x = Math.max(0, Math.min(screenW - sParams.width, sParams.x));
        sParams.y = Math.max(0, sParams.y);
    }

    private static GradientDrawable roundedBg(int color, float radius) {
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(color);
        bg.setCornerRadius(radius);
        return bg;
    }

    /** 歌词拖动 + 双击锁定：状态保存在监听器实例里，不依赖 View tag 资源 id */
    private static final class DragListener implements View.OnTouchListener {
        private float downX, downY;
        private int initX, initY;
        private long lastTap;

        @Override
        public boolean onTouch(View v, MotionEvent ev) {
            if (sParams == null) return false;
            switch (ev.getAction()) {
                case MotionEvent.ACTION_DOWN:
                    downX = ev.getRawX();
                    downY = ev.getRawY();
                    initX = sParams.x;
                    initY = sParams.y;
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (sLocked) return true;
                    sParams.x = initX + Math.round(ev.getRawX() - downX);
                    sParams.y = initY + Math.round(ev.getRawY() - downY);
                    clampToScreen();
                    if (sWm != null) {
                        try {
                            sWm.updateViewLayout(sBox, sParams);
                        } catch (Exception ignored) {
                        }
                    }
                    return true;
                case MotionEvent.ACTION_UP: {
                    long now = System.currentTimeMillis();
                    if (now - lastTap < 300) {
                        applyLock(!sLocked);
                        lastTap = 0;
                    } else {
                        lastTap = now;
                    }
                    return true;
                }
            }
            return false;
        }
    }
}
