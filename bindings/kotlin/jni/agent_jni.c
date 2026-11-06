/* JNI glue for the Kotlin/JVM/Android binding of agent.lean (bindings/kotlin).
 *
 * Hand-written over the stable C ABI in agent.h; no code generators. Every payload crosses JNI as
 * a byte[] holding UTF-8, never as a jstring: NewStringUTF/GetStringUTFChars use modified UTF-8,
 * which encodes U+0000 and non-BMP characters differently from the core's UTF-8 JSON. The Kotlin
 * side does the String <-> UTF-8 conversion.
 *
 * Handles are agent_t pointers carried as jlong. The Kotlin class serializes calls on one handle
 * (the ABI allows one thread at a time per handle); this file adds no locking of its own.
 *
 * @tg: implements:: [[openspec:host-abi#Native bindings]]
 */
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "agent.h"

#define AGENT_PTR(h) ((agent_t *)(intptr_t)(h))
#define EXC_CLASS "dev/agentlean/AgentException"

/* Copy a Java byte[] into a malloc'd buffer (the ABI takes pointer + length). NULL on OOM. */
static uint8_t *copy_in(JNIEnv *env, jbyteArray arr, size_t *len) {
  jsize n = arr ? (*env)->GetArrayLength(env, arr) : 0;
  uint8_t *p = (uint8_t *)malloc(n > 0 ? (size_t)n : 1);
  if (!p) return NULL;
  if (n > 0) (*env)->GetByteArrayRegion(env, arr, 0, n, (jbyte *)p);
  *len = (size_t)n;
  return p;
}

/* A new byte[] with the buffer's bytes; frees the buffer. NULL (with a pending Java exception) on OOM. */
static jbyteArray take_out(JNIEnv *env, agent_buf_t b) {
  jbyteArray arr = (*env)->NewByteArray(env, (jsize)b.len);
  if (arr && b.len) (*env)->SetByteArrayRegion(env, arr, 0, (jsize)b.len, (const jbyte *)b.data);
  agent_buf_free(b);
  return arr;
}

static void throw_bytes(JNIEnv *env, const uint8_t *msg, size_t len) {
  jclass cls = (*env)->FindClass(env, EXC_CLASS);
  if (!cls) return; /* NoClassDefFoundError is pending */
  jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "([B)V");
  if (!ctor) return;
  jbyteArray arr = (*env)->NewByteArray(env, (jsize)len);
  if (!arr) return;
  if (len) (*env)->SetByteArrayRegion(env, arr, 0, (jsize)len, (const jbyte *)msg);
  jobject exc = (*env)->NewObject(env, cls, ctor, arr);
  if (exc) (*env)->Throw(env, (jthrowable)exc);
}

static void throw_text(JNIEnv *env, const char *msg) { throw_bytes(env, (const uint8_t *)msg, strlen(msg)); }

typedef agent_t *(*ctor_fn)(const uint8_t *, size_t, agent_buf_t *);

static jlong create(JNIEnv *env, jbyteArray input, ctor_fn fn, const char *what) {
  size_t len;
  uint8_t *p = copy_in(env, input, &len);
  if (!p) { throw_text(env, "out of memory"); return 0; }
  agent_buf_t err = {NULL, 0};
  agent_t *a = fn(p, len, &err);
  free(p);
  if (!a) {
    if (err.data) throw_bytes(env, err.data, err.len);
    else throw_text(env, what);
    agent_buf_free(err);
    return 0;
  }
  agent_buf_free(err);
  return (jlong)(intptr_t)a;
}

JNIEXPORT jint JNICALL Java_dev_agentlean_AgentNative_abiVersion(JNIEnv *env, jclass cls) {
  (void)env; (void)cls;
  return AGENT_LEAN_ABI_VERSION;
}

JNIEXPORT jlong JNICALL Java_dev_agentlean_AgentNative_create(JNIEnv *env, jclass cls, jbyteArray config) {
  (void)cls;
  return create(env, config, agent_new, "agent_new failed");
}

JNIEXPORT jlong JNICALL Java_dev_agentlean_AgentNative_restore(JNIEnv *env, jclass cls, jbyteArray snapshot) {
  (void)cls;
  return create(env, snapshot, agent_restore, "agent_restore failed");
}

JNIEXPORT jint JNICALL Java_dev_agentlean_AgentNative_feed(JNIEnv *env, jclass cls, jlong h, jbyteArray event) {
  (void)cls;
  size_t len;
  uint8_t *p = copy_in(env, event, &len);
  if (!p) return AGENT_FAILED;
  int code = agent_feed(AGENT_PTR(h), p, len);
  free(p);
  return code;
}

/* The next pending effect as UTF-8 JSON, or null when none is pending. */
JNIEXPORT jbyteArray JNICALL Java_dev_agentlean_AgentNative_nextEffect(JNIEnv *env, jclass cls, jlong h) {
  (void)cls;
  agent_buf_t b = {NULL, 0};
  if (!agent_next_effect(AGENT_PTR(h), &b)) return NULL;
  return take_out(env, b);
}

JNIEXPORT jbyteArray JNICALL Java_dev_agentlean_AgentNative_snapshot(JNIEnv *env, jclass cls, jlong h) {
  (void)cls;
  return take_out(env, agent_snapshot(AGENT_PTR(h)));
}

JNIEXPORT jbyteArray JNICALL Java_dev_agentlean_AgentNative_trace(JNIEnv *env, jclass cls, jlong h) {
  (void)cls;
  return take_out(env, agent_trace(AGENT_PTR(h)));
}

JNIEXPORT jbyteArray JNICALL Java_dev_agentlean_AgentNative_audit(JNIEnv *env, jclass cls, jlong h) {
  (void)cls;
  return take_out(env, agent_audit(AGENT_PTR(h)));
}

JNIEXPORT jbyteArray JNICALL Java_dev_agentlean_AgentNative_lastError(JNIEnv *env, jclass cls, jlong h) {
  (void)cls;
  return take_out(env, agent_last_error(AGENT_PTR(h)));
}

JNIEXPORT jlong JNICALL Java_dev_agentlean_AgentNative_traceLen(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  return (jlong)agent_trace_len(AGENT_PTR(h));
}

JNIEXPORT jboolean JNICALL Java_dev_agentlean_AgentNative_isDone(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  return agent_is_done(AGENT_PTR(h)) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_dev_agentlean_AgentNative_isSensitive(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  return agent_is_sensitive(AGENT_PTR(h)) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_dev_agentlean_AgentNative_free(JNIEnv *env, jclass cls, jlong h) {
  (void)env; (void)cls;
  agent_free(AGENT_PTR(h));
}
