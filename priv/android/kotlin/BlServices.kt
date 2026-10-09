// BlServices.kt — the system services beam-lisp ships for Android.
//
// Each one is an Android component the OS binds on its own schedule, and each
// speaks to the BEAM the same way: BlBridge.emit(tag, json) → the message
// {android, Tag, Json} at the process registered as `android_events`. They keep
// a static `instance` so bl can reach the live service through reflection
// (`(jvm/static "io.beamlisp.android.BlNotificationListener" "getInstance")`).
//
//   BlNotificationListener   every posted/removed notification, from any app
//   BlReader                 the accessibility tree of whatever is on screen
//   BlOverlay                a window above every app (SYSTEM_ALERT_WINDOW)
//
// One file on purpose: the build copies it as-is next to the app's sources.
package io.beamlisp.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Notification
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject

// ── notifications ─────────────────────────────────────────────────────────────

class BlNotificationListener : NotificationListenerService() {
    companion object {
        @Volatile @JvmStatic var instance: BlNotificationListener? = null
        @JvmStatic fun connected(): Boolean = instance != null

        /** A StatusBarNotification as plain data — what bl sees. */
        @JvmStatic fun describe(sbn: StatusBarNotification): JSONObject {
            val n = sbn.notification
            val x = n.extras
            val o = JSONObject()
                .put("key", sbn.key)
                .put("id", sbn.id)
                .put("tag", sbn.tag ?: JSONObject.NULL)
                .put("package", sbn.packageName)
                .put("posted-at", sbn.postTime)
                .put("ongoing", sbn.isOngoing)
                .put("clearable", sbn.isClearable)
                .put("group", sbn.groupKey ?: JSONObject.NULL)
                .put("category", n.category ?: JSONObject.NULL)
                .put("channel", if (Build.VERSION.SDK_INT >= 26) n.channelId ?: JSONObject.NULL else JSONObject.NULL)
                .put("when", n.`when`)
                .put("title", x?.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: JSONObject.NULL)
                .put("text", x?.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: JSONObject.NULL)
                .put("sub-text", x?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: JSONObject.NULL)
                .put("big-text", x?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString() ?: JSONObject.NULL)
                .put("conversation", x?.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString() ?: JSONObject.NULL)
            val lines = x?.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            if (lines != null) o.put("lines", JSONArray(lines.map { it.toString() }))
            // MessagingStyle: the individual messages, sender + text + time.
            val msgs = x?.getParcelableArray(Notification.EXTRA_MESSAGES)
            if (msgs != null) {
                val arr = JSONArray()
                for (p in msgs) if (p is Bundle) arr.put(JSONObject()
                    .put("sender", p.getCharSequence("sender")?.toString() ?: JSONObject.NULL)
                    .put("text", p.getCharSequence("text")?.toString() ?: JSONObject.NULL)
                    .put("time", p.getLong("time")))
                o.put("messages", arr)
            }
            val actions = n.actions
            if (actions != null) o.put("actions", JSONArray(actions.map { a ->
                JSONObject().put("title", a.title?.toString() ?: "")
                    .put("reply", a.remoteInputs?.isNotEmpty() == true)
            }))
            return o
        }
    }

    override fun onListenerConnected() {
        instance = this
        BlBridge.attachContext(this)
        BlBridge.emit("notify/connected", JSONObject().put("active", activeNotifications?.size ?: 0))
    }

    override fun onListenerDisconnected() {
        instance = null
        BlBridge.emit("notify/disconnected", JSONObject())
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        BlBridge.emit("notify/posted", describe(sbn))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap?, reason: Int) {
        BlBridge.emit("notify/removed", describe(sbn).put("reason", reason))
    }

    /** Every notification on the shade now, as data. */
    fun active(): String = JSONArray((activeNotifications ?: emptyArray()).map { describe(it) }).toString()

    /** Fire the action at `index` of notification `key`; with `reply` for inline replies. */
    fun act(key: String, index: Int, reply: String?): Boolean {
        val sbn = activeNotifications?.firstOrNull { it.key == key } ?: return false
        val a = sbn.notification.actions?.getOrNull(index) ?: return false
        return try {
            if (reply != null && a.remoteInputs?.isNotEmpty() == true) {
                val intent = android.content.Intent()
                val b = Bundle()
                for (ri in a.remoteInputs) b.putCharSequence(ri.resultKey, reply)
                android.app.RemoteInput.addResultsToIntent(a.remoteInputs, intent, b)
                a.actionIntent.send(this, 0, intent)
            } else a.actionIntent.send()
            true
        } catch (e: Exception) { Log.w("BlNotify", "act failed: $e"); false }
    }

    fun open(key: String): Boolean {
        val sbn = activeNotifications?.firstOrNull { it.key == key } ?: return false
        return try { sbn.notification.contentIntent?.send(); true } catch (e: Exception) { false }
    }

    fun dismiss(key: String) = cancelNotification(key)
}

// Taps on notifications bl posted (android.notify/post!): body and actions
// arrive here as broadcasts and leave as the event `notify/action`, with the
// inline reply text when there is one.
class BlNotifyReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: android.content.Intent) {
        BlBridge.attachContext(context)
        val o = JSONObject()
            .put("notification", intent.getStringExtra("notification")?.toIntOrNull() ?: JSONObject.NULL)
            .put("action", intent.getStringExtra("action") ?: "tap")
        android.app.RemoteInput.getResultsFromIntent(intent)?.getCharSequence("bl_reply")?.let {
            o.put("reply", it.toString())
        }
        BlBridge.emit("notify/action", o)
    }
}

// ── reading any screen ───────────────────────────────────────────────────────

class BlReader : AccessibilityService() {
    companion object {
        @Volatile @JvmStatic var instance: BlReader? = null
        @JvmStatic fun connected(): Boolean = instance != null
        @Volatile @JvmStatic var streaming: Boolean = false

        fun nodeJson(n: AccessibilityNodeInfo, depth: Int, maxDepth: Int): JSONObject {
            val r = Rect(); n.getBoundsInScreen(r)
            val o = JSONObject()
                .put("class", n.className?.toString() ?: JSONObject.NULL)
                .put("text", n.text?.toString() ?: JSONObject.NULL)
                .put("desc", n.contentDescription?.toString() ?: JSONObject.NULL)
                .put("id", n.viewIdResourceName ?: JSONObject.NULL)
                .put("bounds", JSONArray(listOf(r.left, r.top, r.right, r.bottom)))
                .put("clickable", n.isClickable)
                .put("editable", n.isEditable)
                .put("focused", n.isFocused)
                .put("selected", n.isSelected)
                .put("checked", n.isChecked)
            if (depth < maxDepth && n.childCount > 0) {
                val kids = JSONArray()
                for (i in 0 until n.childCount) n.getChild(i)?.let { kids.put(nodeJson(it, depth + 1, maxDepth)) }
                o.put("children", kids)
            }
            return o
        }
    }

    override fun onServiceConnected() {
        instance = this
        BlBridge.attachContext(this)
        serviceInfo = serviceInfo.apply {
            eventTypes = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_CLICKED
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
            notificationTimeout = 150
        }
        BlBridge.emit("reader/connected", JSONObject())
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        BlBridge.emit("reader/disconnected", JSONObject())
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(e: AccessibilityEvent) {
        if (!streaming) return
        // Content changes fire in bursts; only window changes and user actions
        // are forwarded as they happen. bl pulls the tree when it wants it.
        val kind = when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> "window"
            AccessibilityEvent.TYPE_VIEW_CLICKED -> "click"
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> "text"
            else -> return
        }
        BlBridge.emit("reader/event", JSONObject()
            .put("kind", kind)
            .put("package", e.packageName?.toString() ?: JSONObject.NULL)
            .put("class", e.className?.toString() ?: JSONObject.NULL)
            .put("text", JSONArray(e.text.map { it.toString() })))
    }

    override fun onInterrupt() {}

    /** The foreground window as a tree (depth-limited). */
    fun tree(maxDepth: Int): String {
        val root = rootInActiveWindow ?: return JSONObject.NULL.toString()
        return JSONObject()
            .put("package", root.packageName?.toString() ?: JSONObject.NULL)
            .put("root", nodeJson(root, 0, maxDepth)).toString()
    }

    /** Every visible text on screen, top-to-bottom, as a flat list. */
    fun texts(): String {
        val out = JSONArray()
        val root = rootInActiveWindow ?: return out.toString()
        fun walk(n: AccessibilityNodeInfo) {
            val t = n.text?.toString() ?: n.contentDescription?.toString()
            if (!t.isNullOrBlank()) {
                val r = Rect(); n.getBoundsInScreen(r)
                out.put(JSONObject().put("text", t).put("bounds", JSONArray(listOf(r.left, r.top, r.right, r.bottom))))
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let { walk(it) }
        }
        walk(root)
        return out.toString()
    }

    /** Click the first node whose text or description equals `label`. */
    fun clickText(label: String): Boolean {
        val root = rootInActiveWindow ?: return false
        fun click(h: AccessibilityNodeInfo): Boolean {
            var n: AccessibilityNodeInfo? = h
            while (n != null && !n.isClickable) n = n.parent
            if (n == null) return false
            // A WebView's DOM nodes answer ACTION_CLICK inconsistently
            // (measured on Chromium: false, or true with no click event in
            // the page), so a web node is TAPPED at the centre of its bounds,
            // as a finger would; native views take the action.
            if (!isWeb(n) && n.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            n.refresh()
            val r = Rect(); n.getBoundsInScreen(r)
            return !r.isEmpty && tapAt(r.exactCenterX(), r.exactCenterY())
        }
        for (h in root.findAccessibilityNodeInfosByText(label) ?: emptyList()) if (click(h)) return true
        // The platform search misses nodes a virtual provider exposes (a
        // WebView's DOM): walk the tree the way `texts` reads it.
        fun walk(n: AccessibilityNodeInfo): Boolean {
            val t = n.text?.toString() ?: n.contentDescription?.toString()
            if (t == label && click(n)) return true
            for (i in 0 until n.childCount) { val c = n.getChild(i) ?: continue; if (walk(c)) return true }
            return false
        }
        return walk(root)
    }

    /** Whether `n` sits inside a WebView (its DOM, exposed as virtual nodes). */
    private fun isWeb(n: AccessibilityNodeInfo): Boolean {
        var p: AccessibilityNodeInfo? = n
        while (p != null) { if (p.className?.toString() == "android.webkit.WebView") return true; p = p.parent }
        return false
    }

    /** A single-finger tap at screen coordinates; true when the system took it. */
    fun tapAt(x: Float, y: Float): Boolean {
        val p = android.graphics.Path().apply { moveTo(x, y) }
        val g = android.accessibilityservice.GestureDescription.Builder()
            .addStroke(android.accessibilityservice.GestureDescription.StrokeDescription(p, 0, 60))
            .build()
        return dispatchGesture(g, null, null)
    }

    fun global(action: String): Boolean {
        val code = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            else -> return false
        }
        return performGlobalAction(code)
    }
}

// ── drawing over any screen ──────────────────────────────────────────────────
//
// An overlay is a list of CARDS placed on the screen, described by bl as data:
//   {"id": "nudge", "gravity": "top", "y": 120, "title": "…", "body": "…",
//    "bg": "#1F2A24", "fg": "#F4EFE6", "touchable": true}
// A tap on a touchable card emits {:android "overlay/tap" {"id": …}}.

object BlOverlay {
    private val main = Handler(Looper.getMainLooper())
    private val views = HashMap<String, View>()

    @JvmStatic fun permitted(): Boolean {
        val ctx = BlBridge.context ?: return false
        return Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(ctx)
    }

    @JvmStatic fun shown(): String = JSONArray(synchronized(views) { views.keys.toList() }).toString()

    @JvmStatic fun show(spec: String): Boolean {
        val ctx = BlBridge.context ?: return false
        if (!permitted()) return false
        val s = JSONObject(spec)
        val id = s.getString("id")
        main.post {
            hideNow(id)
            val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val v = card(ctx, s)
            val touchable = s.optBoolean("touchable", true)
            val lp = WindowManager.LayoutParams(
                if (s.has("width")) dp(ctx, s.getInt("width")) else WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    (if (touchable) 0 else WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE),
                PixelFormat.TRANSLUCENT)
            lp.gravity = when (s.optString("gravity", "top")) {
                "bottom" -> Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                "center" -> Gravity.CENTER
                else -> Gravity.TOP or Gravity.CENTER_HORIZONTAL
            }
            lp.y = dp(ctx, s.optInt("y", 48))
            if (touchable) v.setOnClickListener {
                BlBridge.emit("overlay/tap", JSONObject().put("id", id))
            }
            wm.addView(v, lp)
            synchronized(views) { views[id] = v }
            BlBridge.emit("overlay/shown", JSONObject().put("id", id))
        }
        return true
    }

    @JvmStatic fun hide(id: String): Boolean { main.post { hideNow(id) }; return true }

    @JvmStatic fun hideAll(): Boolean {
        main.post { synchronized(views) { views.keys.toList() }.forEach { hideNow(it) } }
        return true
    }

    private fun hideNow(id: String) {
        val v = synchronized(views) { views.remove(id) } ?: return
        val ctx = BlBridge.context ?: return
        try { (ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(v) } catch (_: Exception) {}
        BlBridge.emit("overlay/hidden", JSONObject().put("id", id))
    }

    private fun dp(ctx: Context, v: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), ctx.resources.displayMetrics).toInt()

    private fun card(ctx: Context, s: JSONObject): View {
        val fg = Color.parseColor(s.optString("fg", "#F4EFE6"))
        val box = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 20), dp(ctx, 16), dp(ctx, 20), dp(ctx, 16))
            background = GradientDrawable().apply {
                setColor(Color.parseColor(s.optString("bg", "#1F2A24")))
                cornerRadius = dp(ctx, s.optInt("radius", 18)).toFloat()
                if (s.has("border")) setStroke(dp(ctx, 2), Color.parseColor(s.getString("border")))
            }
            elevation = dp(ctx, 8).toFloat()
            contentDescription = "bl-overlay:" + s.getString("id")
        }
        if (s.has("kicker")) box.addView(TextView(ctx).apply {
            text = s.getString("kicker"); setTextColor(fg); alpha = 0.7f
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f); letterSpacing = 0.08f
        })
        if (s.has("title")) box.addView(TextView(ctx).apply {
            text = s.getString("title"); setTextColor(fg)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            typeface = android.graphics.Typeface.SERIF
        })
        if (s.has("body")) box.addView(TextView(ctx).apply {
            text = s.getString("body"); setTextColor(fg); alpha = 0.9f
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setPadding(0, dp(ctx, 6), 0, 0)
        })
        val frame = FrameLayout(ctx)
        frame.setPadding(dp(ctx, 12), 0, dp(ctx, 12), 0)
        frame.addView(box)
        return frame
    }
}
