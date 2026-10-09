// bl_android_nif.c — the BEAM ⇄ JVM seam for beam-lisp on Android.
//
// Two directions, one rule each:
//
//   BEAM → JVM   bl_android_nif:call(Json) — a JSON request handed to
//                io.beamlisp.android.BlBridge.call(String): String and answered
//                synchronously. Runs on a DIRTY IO scheduler: reflection may
//                wait on the main thread, and Android runs the BEAM with one
//                normal scheduler, so a normal-scheduler wait would stop every
//                process on the device.
//
//   JVM → BEAM   BlBridge.nativeEmit(Tag, Json) — sends {android, Tag, Json}
//                to the process registered as `android_events`. The JVM never
//                runs BEAM code; it only sends. Returns false when nothing is
//                registered, so a service can buffer or drop knowingly.
//
// Linked statically into lib<app>.so (STATIC_ERLANG_NIF_LIBNAME=bl_android_nif,
// listed in the driver table), next to mob's own NIF. `g_jvm` is defined by the
// app's beam_jni.c; `get_jenv`/`detachIfAttached` semantics follow mob_nif.zig.

#include <jni.h>
#include <string.h>
#include <android/log.h>
#include "erl_nif.h"

#define TAG "BlAndroid"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

extern JavaVM *g_jvm;

static jclass    s_bridge = NULL;   // global ref to io.beamlisp.android.BlBridge
static jmethodID s_call   = NULL;   // static byte[] callBytes(byte[])

// Set by the NIF's load callback: until erts has loaded this module, no enif_*
// call is safe (enif_alloc_env dereferences allocator state that does not
// exist yet). Services start before the BEAM, so emits must check this first.
static volatile int s_beam_up = 0;

// enif_whereis_pid/enif_send take the CALLER's env when the caller is an ERTS
// thread, and NULL only from foreign threads. An emit can happen from inside
// bl_android_nif:call (the JVM code it runs may emit, e.g. BlBridge.flush),
// i.e. on a dirty scheduler — there NULL crashes. nif_call parks its env here
// for the duration of the JVM call.
static __thread ErlNifEnv *tl_caller_env = NULL;

static JNIEnv *attach(int *attached) {
    JNIEnv *env = NULL;
    *attached = 0;
    if (!g_jvm) return NULL;
    jint r = (*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6);
    if (r == JNI_EDETACHED) {
        if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) != JNI_OK) return NULL;
        *attached = 1;
    } else if (r != JNI_OK) {
        return NULL;
    }
    return env;
}

static void detach(int attached) {
    if (attached && g_jvm) (*g_jvm)->DetachCurrentThread(g_jvm);
}

static ERL_NIF_TERM mk_error(ErlNifEnv *env, const char *why) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"),
                            enif_make_string(env, why, ERL_NIF_LATIN1));
}

static ERL_NIF_TERM mk_binary(ErlNifEnv *env, const char *s, size_t n) {
    ERL_NIF_TERM t;
    unsigned char *p = enif_make_new_binary(env, n, &t);
    memcpy(p, s, n);
    return t;
}

// ── JNI: called by BlBridge.attach on the main thread ────────────────────────
JNIEXPORT void JNICALL
Java_io_beamlisp_android_BlBridge_nativeRegister(JNIEnv *env, jclass cls) {
    if (s_bridge) return;
    s_bridge = (*env)->NewGlobalRef(env, cls);
    // Bytes, not jstring: JNI's string functions speak MODIFIED UTF-8, which
    // mangles anything outside the BMP (emoji) and trips CheckJNI in debug
    // builds. A byte[] of real UTF-8 crosses unchanged both ways.
    s_call = (*env)->GetStaticMethodID(env, cls, "callBytes", "([B)[B");
    if (!s_call) {
        (*env)->ExceptionClear(env);
        LOGE("BlBridge.callBytes(byte[]) not found");
    }
}

// ── JNI: JVM → BEAM ──────────────────────────────────────────────────────────
JNIEXPORT jboolean JNICALL
Java_io_beamlisp_android_BlBridge_nativeEmit(JNIEnv *env, jclass cls, jstring jtag, jbyteArray jjson) {
    if (!s_beam_up) return JNI_FALSE;
    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env) return JNI_FALSE;
    ErlNifPid pid;
    ErlNifEnv *caller = tl_caller_env;
    if (!enif_whereis_pid(caller, enif_make_atom(msg_env, "android_events"), &pid)) {
        enif_free_env(msg_env);
        return JNI_FALSE;
    }
    // Tags are ASCII by construction; the payload is UTF-8 bytes.
    const char *tag = (*env)->GetStringUTFChars(env, jtag, NULL);
    jsize json_len = (*env)->GetArrayLength(env, jjson);
    jbyte *json = (*env)->GetByteArrayElements(env, jjson, NULL);
    ERL_NIF_TERM m = enif_make_tuple3(msg_env,
        enif_make_atom(msg_env, "android"),
        mk_binary(msg_env, tag, strlen(tag)),
        mk_binary(msg_env, (const char *)json, (size_t)json_len));
    (*env)->ReleaseStringUTFChars(env, jtag, tag);
    (*env)->ReleaseByteArrayElements(env, jjson, json, JNI_ABORT);
    int sent = enif_send(caller, &pid, msg_env, m);
    enif_free_env(msg_env);
    return sent ? JNI_TRUE : JNI_FALSE;
}

// ── NIF: BEAM → JVM ──────────────────────────────────────────────────────────
static ERL_NIF_TERM nif_call(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary req;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &req)) return enif_make_badarg(env);
    if (!s_bridge || !s_call) return mk_error(env, "bridge not attached (BlBridge.attach never ran)");

    int attached;
    JNIEnv *jenv = attach(&attached);
    if (!jenv) return mk_error(env, "no JNI env");

    jbyteArray jreq = (*jenv)->NewByteArray(jenv, (jsize)req.size);
    if (!jreq) { detach(attached); return mk_error(env, "out of JVM memory"); }
    (*jenv)->SetByteArrayRegion(jenv, jreq, 0, (jsize)req.size, (const jbyte *)req.data);

    tl_caller_env = env;
    jbyteArray jres = (jbyteArray)(*jenv)->CallStaticObjectMethod(jenv, s_bridge, s_call, jreq);
    tl_caller_env = NULL;
    ERL_NIF_TERM out;
    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionDescribe(jenv);
        (*jenv)->ExceptionClear(jenv);
        out = mk_error(env, "BlBridge.call threw");
    } else if (!jres) {
        out = mk_error(env, "BlBridge.call returned null");
    } else {
        jsize n = (*jenv)->GetArrayLength(jenv, jres);
        ERL_NIF_TERM bin;
        unsigned char *p = enif_make_new_binary(env, (size_t)n, &bin);
        (*jenv)->GetByteArrayRegion(jenv, jres, 0, n, (jbyte *)p);
        out = enif_make_tuple2(env, enif_make_atom(env, "ok"), bin);
        (*jenv)->DeleteLocalRef(jenv, jres);
    }
    (*jenv)->DeleteLocalRef(jenv, jreq);
    detach(attached);
    return out;
}

static ERL_NIF_TERM nif_attached(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, (s_bridge && s_call) ? "true" : "false");
}

static ErlNifFunc nif_funcs[] = {
    {"call", 1, nif_call, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"attached", 0, nif_attached, 0},
};

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    s_beam_up = 1;
    return 0;
}

ERL_NIF_INIT(bl_android_nif, nif_funcs, on_load, NULL, NULL, NULL)
