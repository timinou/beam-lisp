// BlBridge.kt — beam-lisp's door into the JVM.
//
// ONE entry point, `call(json): String`, invoked from the bl_android NIF on a
// dirty scheduler. A request is a JSON object; the answer is a JSON object
// `{"ok": value}` or `{"error": "…"}`. Every Android API is reachable through
// four verbs — new, call, static, field — over OBJECT HANDLES: Java objects never
// cross into the BEAM, a handle does, as `{"$h": id, "class": "…"}`.
//
// The JVM never calls BEAM code. It SENDS: `BlBridge.emit(tag, json)` delivers a
// message `{:android, tag, json}` to the BEAM process registered as
// `:android_events` (and to whoever it fans out to). Services use the same door.
//
// Threading: reflection that touches views must run on the main thread. A
// request carrying `"ui": true` is posted to the main looper and awaited (with a
// timeout); everything else runs on the calling (dirty scheduler) thread.
package io.beamlisp.android

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.Array as JArray
import java.lang.reflect.Constructor
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

object BlBridge {
    private const val TAG = "BlBridge"

    @Volatile @JvmStatic var context: Context? = null
    @Volatile @JvmStatic var activity: Activity? = null

    private val handles = ConcurrentHashMap<Long, Any>()
    private val nextHandle = AtomicLong(1)
    private val main = Handler(Looper.getMainLooper())

    // ── wiring ────────────────────────────────────────────────────────────
    @JvmStatic fun attach(act: Activity) {
        activity = act
        context = act.applicationContext
        nativeRegister()
        registered = true
    }

    // True once the app's native lib is loaded and registered (the Activity
    // attached). A service-only process has neither lib nor BEAM: its events
    // are held, not sent.
    @Volatile private var registered = false

    // Services start before (or without) the activity; they hand over the app
    // context so a listener can deliver while the UI is gone.
    @JvmStatic fun attachContext(ctx: Context) {
        if (context == null) context = ctx.applicationContext
    }

    // Implemented in bl_android_nif.c: caches this class + emit target.
    @JvmStatic external fun nativeRegister()
    // Implemented in bl_android_nif.c: enif_send {android, Tag, Json} to the
    // process registered as android_events. Returns false when nothing listens.
    // The payload is UTF-8 bytes (see callBytes).
    @JvmStatic external fun nativeEmit(tag: String, json: ByteArray): Boolean

    // Events that found no listener: services start before the BEAM (and
    // before the native lib, in a service-only process). They wait here, the
    // newest PENDING_MAX, until the bl router starts and calls `flush`.
    private const val PENDING_MAX = 256
    private val pending = java.util.ArrayDeque<Pair<String, ByteArray>>()

    /** Deliver an event to the BEAM, or hold it until someone listens. Safe from any thread. */
    @JvmStatic fun emit(tag: String, payload: JSONObject): Boolean {
        val bytes = payload.toString().toByteArray(Charsets.UTF_8)
        val sent = registered && try { nativeEmit(tag, bytes) } catch (e: UnsatisfiedLinkError) { false }
        if (!sent) synchronized(pending) {
            if (pending.size >= PENDING_MAX) pending.removeFirst()
            pending.addLast(tag to bytes)
        }
        return sent
    }

    /** Re-send held events, oldest first. Returns how many were delivered. */
    @JvmStatic fun flush(): Int {
        var n = 0
        while (true) {
            val ev = synchronized(pending) { pending.peekFirst() } ?: return n
            if (!nativeEmit(ev.first, ev.second)) return n
            synchronized(pending) { pending.pollFirst() }
            n++
        }
    }

    // ── the one entry point ───────────────────────────────────────────────
    // The NIF crosses as UTF-8 bytes: JNI strings are modified UTF-8, which
    // would mangle emoji on the way in and out.
    @JvmStatic fun callBytes(req: ByteArray): ByteArray =
        call(String(req, Charsets.UTF_8)).toByteArray(Charsets.UTF_8)

    @JvmStatic fun call(json: String): String {
        val req = try { JSONObject(json) } catch (e: Exception) {
            return err("request is not JSON: ${e.message}")
        }
        return if (req.optBoolean("ui", false) && Looper.myLooper() != Looper.getMainLooper()) {
            onMain(req, req.optLong("timeout", 5000))
        } else {
            dispatch(req)
        }
    }

    private fun onMain(req: JSONObject, timeoutMs: Long): String {
        val out = AtomicReference<String>()
        val done = CountDownLatch(1)
        main.post { try { out.set(dispatch(req)) } finally { done.countDown() } }
        return if (done.await(timeoutMs, TimeUnit.MILLISECONDS)) out.get()
        else err("main thread did not answer in ${timeoutMs} ms")
    }

    private fun dispatch(req: JSONObject): String = try {
        val v: Any? = when (val op = req.getString("op")) {
            "new" -> construct(classOf(req.getString("class")), args(req))
            "call" -> invoke(target(req), req.getString("method"), args(req), false)
            "static" -> invoke(classOf(req.getString("class")), req.getString("method"), args(req), true)
            "field" -> field(req)
            "set-field" -> setField(req)
            "context" -> context
            "activity" -> activity
            "class" -> classOf(req.getString("class"))
            "release" -> { req.getJSONArray("handles").let { a -> for (i in 0 until a.length()) handles.remove(a.getLong(i)) }; null }
            "handles" -> handles.size
            "proxy" -> proxy(req)
            "describe" -> describe(target(req))
            "ping" -> "pong"
            else -> throw IllegalArgumentException("unknown op: $op")
        }
        ok(v)
    } catch (e: java.lang.reflect.InvocationTargetException) {
        err(describeThrowable(e.targetException ?: e))
    } catch (e: Throwable) {
        err(describeThrowable(e))
    }

    // ── values: JSON ⇄ Java ───────────────────────────────────────────────
    //
    // JSON → Java: null, boolean, number, string, array (→ List), object (→ Map)
    // plus two tagged objects: {"$h": id} is a handle, {"$class": "a.b.C"} a
    // Class. Java → JSON: primitives and String by value; List/array/Map by value
    // when every element is; everything else becomes a handle.
    private fun ok(v: Any?): String = JSONObject().put("ok", toJson(v)).toString()
    private fun err(msg: String): String = JSONObject().put("error", msg).toString()

    private fun describeThrowable(t: Throwable): String =
        "${t.javaClass.name}: ${t.message ?: ""}".trimEnd(' ', ':')

    @JvmStatic fun toJson(v: Any?): Any = when (v) {
        null -> JSONObject.NULL
        is Unit -> JSONObject.NULL
        is Boolean, is Int, is Long, is Double, is String -> v
        is Float -> v.toDouble()
        is Short -> v.toInt()
        is Byte -> v.toInt()
        is Char -> v.toString()
        is CharSequence -> v.toString()
        is Enum<*> -> JSONObject().put("\$enum", v.name).put("class", v.javaClass.name)
        is Collection<*> -> JSONArray().also { a -> v.forEach { a.put(toJson(it)) } }
        is Map<*, *> -> JSONObject().also { o -> v.forEach { (k, x) -> o.put(k.toString(), toJson(x)) } }
        is IntArray -> JSONArray().also { a -> v.forEach { a.put(it) } }
        is LongArray -> JSONArray().also { a -> v.forEach { a.put(it) } }
        is FloatArray -> JSONArray().also { a -> v.forEach { a.put(it.toDouble()) } }
        is DoubleArray -> JSONArray().also { a -> v.forEach { a.put(it) } }
        is BooleanArray -> JSONArray().also { a -> v.forEach { a.put(it) } }
        is Array<*> -> JSONArray().also { a -> v.forEach { a.put(toJson(it)) } }
        is JSONObject, is JSONArray -> v
        else -> handleOf(v)
    }

    @JvmStatic fun handleOf(v: Any): JSONObject {
        val id = nextHandle.getAndIncrement()
        handles[id] = v
        return JSONObject().put("\$h", id).put("class", v.javaClass.name)
    }

    private fun fromJson(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> when {
            v.has("\$h") -> handles[v.getLong("\$h")] ?: throw IllegalStateException("released handle ${v.getLong("\$h")}")
            v.has("\$class") -> classOf(v.getString("\$class"))
            v.has("\$enum") -> {
                @Suppress("UNCHECKED_CAST")
                val c = classOf(v.getString("class")) as Class<out Enum<*>>
                c.enumConstants!!.first { it.name == v.getString("\$enum") }
            }
            v.has("\$float") -> v.getDouble("\$float").toFloat()
            v.has("\$long") -> v.getLong("\$long")
            v.has("\$char") -> v.getString("\$char")[0]
            else -> LinkedHashMap<String, Any?>().also { m -> v.keys().forEach { k -> m[k] = fromJson(v.get(k)) } }
        }
        is JSONArray -> ArrayList<Any?>().also { l -> for (i in 0 until v.length()) l.add(fromJson(v.get(i))) }
        else -> v
    }

    private fun args(req: JSONObject): List<Any?> {
        val a = req.optJSONArray("args") ?: return emptyList()
        return (0 until a.length()).map { fromJson(a.get(it)) }
    }

    private fun target(req: JSONObject): Any =
        fromJson(req.get("target")) ?: throw NullPointerException("call on nil target")

    private val classCache = ConcurrentHashMap<String, Class<*>>()
    @JvmStatic fun classOf(name: String): Class<*> = classCache.getOrPut(name) {
        when (name) {
            "int" -> Int::class.javaPrimitiveType!!
            "long" -> Long::class.javaPrimitiveType!!
            "boolean" -> Boolean::class.javaPrimitiveType!!
            "float" -> Float::class.javaPrimitiveType!!
            "double" -> Double::class.javaPrimitiveType!!
            // The APP's loader: it sees the app's classes and delegates to the
            // framework. (The Application's own class sits in the boot loader,
            // which cannot see io.beamlisp.* — never resolve through it.)
            else -> Class.forName(name, true, BlBridge::class.java.classLoader)
        }
    }

    // ── overload resolution ───────────────────────────────────────────────
    //
    // JSON numbers arrive as Int/Long/Double; Java wants int/long/float/double
    // and boxes. A candidate matches when every argument COERCES to its
    // parameter; among matches the one with the fewest widening coercions wins.
    private fun cost(p: Class<*>, a: Any?): Int {
        if (a == null) return if (p.isPrimitive) -1 else 1
        val b = box(p)
        if (b.isInstance(a)) return 0
        if (a is Number) {
            return when (b) {
                java.lang.Integer::class.java -> if (a is Int || (a is Long && a in Int.MIN_VALUE..Int.MAX_VALUE)) 1 else -1
                java.lang.Long::class.java -> if (a is Int || a is Long) 1 else -1
                java.lang.Double::class.java -> 2
                java.lang.Float::class.java -> 3
                java.lang.Short::class.java -> if (a is Int) 4 else -1
                java.lang.Byte::class.java -> if (a is Int) 4 else -1
                else -> -1
            }
        }
        if (a is String) {
            if (b == java.lang.Character::class.java && a.length == 1) return 2
            if (CharSequence::class.java.isAssignableFrom(b)) return 0
        }
        if (a is List<*> && (b.isArray)) return 3
        if (a is List<*> && b.isAssignableFrom(java.util.ArrayList::class.java)) return 1
        if (a is Map<*, *> && b.isAssignableFrom(java.util.LinkedHashMap::class.java)) return 1
        return -1
    }

    private fun coerce(p: Class<*>, a: Any?): Any? {
        if (a == null) return null
        val b = box(p)
        if (b.isInstance(a)) return a
        if (a is Number) return when (b) {
            java.lang.Integer::class.java -> a.toInt()
            java.lang.Long::class.java -> a.toLong()
            java.lang.Double::class.java -> a.toDouble()
            java.lang.Float::class.java -> a.toFloat()
            java.lang.Short::class.java -> a.toShort()
            java.lang.Byte::class.java -> a.toByte()
            else -> a
        }
        if (a is String && b == java.lang.Character::class.java) return a[0]
        if (a is List<*> && p.isArray) {
            val ct = p.componentType!!
            val arr = JArray.newInstance(ct, a.size)
            a.forEachIndexed { i, x -> JArray.set(arr, i, coerce(ct, x)) }
            return arr
        }
        return a
    }

    private fun box(p: Class<*>): Class<*> = if (!p.isPrimitive) p else when (p) {
        Int::class.javaPrimitiveType -> java.lang.Integer::class.java
        Long::class.javaPrimitiveType -> java.lang.Long::class.java
        Boolean::class.javaPrimitiveType -> java.lang.Boolean::class.java
        Float::class.javaPrimitiveType -> java.lang.Float::class.java
        Double::class.javaPrimitiveType -> java.lang.Double::class.java
        Short::class.javaPrimitiveType -> java.lang.Short::class.java
        Byte::class.javaPrimitiveType -> java.lang.Byte::class.java
        Char::class.javaPrimitiveType -> java.lang.Character::class.java
        else -> p
    }

    private fun score(params: Array<Class<*>>, a: List<Any?>): Int {
        if (params.size != a.size) return -1
        var s = 0
        for (i in params.indices) { val c = cost(params[i], a[i]); if (c < 0) return -1; s += c }
        return s
    }

    private fun construct(c: Class<*>, a: List<Any?>): Any {
        val k: Constructor<*> = c.constructors
            .map { it to score(it.parameterTypes, a) }.filter { it.second >= 0 }
            .minByOrNull { it.second }?.first
            ?: throw NoSuchMethodException("${c.name}.<init>/${a.size} for (${a.joinToString { it?.javaClass?.simpleName ?: "nil" }})")
        return k.newInstance(*a.mapIndexed { i, x -> coerce(k.parameterTypes[i], x) }.toTypedArray())
    }

    // Kotlin-friendly names: `foo-bar` → `fooBar`, so bl can write
    // `(call nm :create-notification-channel ch)`.
    private fun camel(n: String): String =
        if (!n.contains('-')) n else n.split('-').mapIndexed { i, s -> if (i == 0) s else s.replaceFirstChar { it.uppercase() } }.joinToString("")

    private fun methodsNamed(c: Class<*>, name: String, static: Boolean): List<Method> {
        val out = ArrayList<Method>()
        var k: Class<*>? = c
        val seen = HashSet<String>()
        while (k != null) {
            for (m in k.declaredMethods) if (m.name == name && Modifier.isStatic(m.modifiers) == static) {
                val sig = m.name + m.parameterTypes.joinToString(",") { it.name }
                if (seen.add(sig) && Modifier.isPublic(m.modifiers)) out.add(m)
            }
            k = k.superclass
        }
        for (i in c.interfaces + c.interfaces.flatMap { it.interfaces.toList() }) for (m in i.methods)
            if (m.name == name && !static) out.add(m)
        return out
    }

    private fun invoke(t: Any, name0: String, a: List<Any?>, static: Boolean): Any? {
        val name = camel(name0)
        val c = if (static) t as Class<*> else t.javaClass
        val m = methodsNamed(c, name, static)
            .map { it to score(it.parameterTypes, a) }.filter { it.second >= 0 }
            .minByOrNull { it.second }?.first
            ?: throw NoSuchMethodException("${c.name}.$name/${a.size} for (${a.joinToString { it?.javaClass?.simpleName ?: "nil" }})")
        m.isAccessible = true
        return m.invoke(if (static) null else t, *a.mapIndexed { i, x -> coerce(m.parameterTypes[i], x) }.toTypedArray())
    }

    private fun field(req: JSONObject): Any? {
        val name = req.getString("field")
        return if (req.has("class")) classOf(req.getString("class")).getField(name).get(null)
        else target(req).let { it.javaClass.getField(name).get(it) }
    }

    private fun setField(req: JSONObject): Any? {
        val v = fromJson(req.get("value"))
        val o = target(req)
        val f = o.javaClass.getField(req.getString("field"))
        f.set(o, coerce(f.type, v))
        return null
    }

    // A dynamic proxy implementing an interface: every call becomes an event
    // `{:android, "proxy", {"id": …, "method": …, "args": […]}}`. Enough for
    // listeners and callbacks whose return value does not matter.
    private fun proxy(req: JSONObject): Any {
        val iface = classOf(req.getString("interface"))
        val id = req.getString("id")
        val h = InvocationHandler { _, m, a ->
            when (m.name) {
                "toString" -> "BlProxy($id)"
                "hashCode" -> id.hashCode()
                "equals" -> a?.getOrNull(0) === null
                else -> {
                    emit("proxy", JSONObject().put("id", id).put("method", m.name)
                        .put("args", JSONArray().also { arr -> a?.forEach { arr.put(toJson(it)) } }))
                    defaultReturn(m.returnType)
                }
            }
        }
        return Proxy.newProxyInstance(iface.classLoader, arrayOf(iface), h)
    }

    private fun defaultReturn(t: Class<*>): Any? = when (t) {
        java.lang.Boolean.TYPE -> false
        Integer.TYPE, java.lang.Short.TYPE, java.lang.Byte.TYPE -> 0
        java.lang.Long.TYPE -> 0L
        java.lang.Float.TYPE -> 0f
        java.lang.Double.TYPE -> 0.0
        else -> null
    }

    private fun describe(t: Any): JSONObject {
        val c = t as? Class<*> ?: t.javaClass
        return JSONObject()
            .put("class", c.name)
            .put("super", c.superclass?.name ?: JSONObject.NULL)
            .put("methods", JSONArray(c.methods.map { m ->
                (if (Modifier.isStatic(m.modifiers)) "static " else "") + m.name + "(" + m.parameterTypes.joinToString(",") { it.simpleName } + "):" + m.returnType.simpleName
            }.sorted()))
            .put("fields", JSONArray(c.fields.map { it.name }.sorted()))
    }
}
