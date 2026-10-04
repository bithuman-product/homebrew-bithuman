// bh_llm_jni.cpp — the LLM leg of the Android on-device brain (llama.cpp, CPU).
//
// The Android twin of the LLM stage inside Apple's libconverse: one model, one
// context, one sequence, a chat template applied by llama.cpp, and replies streamed
// token by token. What it adds over a plain completion loop is what the Apple brain
// learned the hard way about turn latency:
//
//  * KV REUSE ACROSS TURNS. The conversation is re-rendered every turn, so almost the
//    whole prompt is a prefix the context already holds. Only the tokens after the
//    longest common prefix are decoded. When the host trims the OLDEST exchange out of
//    the history (capped history), the prompt's prefix changes right after the system
//    prompt; instead of re-prefilling everything after it, the surviving tail is found
//    in the cache and SHIFTED down (llama.cpp's own cache-reuse move: seq_rm + seq_add),
//    so a trimmed history costs a few tokens, not a few hundred. On iPhone, TTFT grew
//    from 166 ms to 1.1 s over 25 turns without this.
//  * CANCEL THAT BITES MID-PREFILL. A barge-in sets a flag the decode's abort callback
//    reads, so a long prefill stops at the next graph node instead of running out.
//  * BYTES, NOT JAVA STRINGS. A token can end in the middle of a UTF-8 sequence (and
//    NewStringUTF is modified UTF-8, which mangles 4-byte emoji), so pieces go up as
//    byte arrays and Kotlin decodes.
//
// Apache-2.0; (c) bitHuman.

#include <jni.h>
#include <android/log.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <string>
#include <vector>

#include "llama.h"

#define TAG "bhbrain"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {

struct Brain {
  llama_model* model = nullptr;
  llama_context* ctx = nullptr;
  const llama_vocab* vocab = nullptr;
  std::string tmpl;                     // the model's own chat template
  std::vector<llama_token> cached;      // tokens currently held in seq 0 of the KV
  std::atomic<bool> cancel{false};
  int n_batch = 512;
  // last-turn numbers, for the caller's log line
  int last_prompt = 0, last_reused = 0, last_shifted = 0, last_decoded = 0, last_gen = 0;
  double last_prefill_ms = 0, last_first_tok_ms = 0, last_gen_ms = 0;
};

double now_ms() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

void log_cb(ggml_log_level level, const char* text, void*) {
  if (level >= GGML_LOG_LEVEL_WARN) __android_log_print(ANDROID_LOG_WARN, "llama", "%s", text);
}

bool abort_cb(void* ud) { return static_cast<Brain*>(ud)->cancel.load(std::memory_order_relaxed); }

std::vector<llama_token> tokenize(const Brain* b, const std::string& text) {
  int n = -llama_tokenize(b->vocab, text.c_str(), (int32_t)text.size(), nullptr, 0, true, true);
  std::vector<llama_token> out(std::max(n, 0));
  if (n > 0 && llama_tokenize(b->vocab, text.c_str(), (int32_t)text.size(), out.data(), n, true, true) < 0) out.clear();
  return out;
}

// Decode tokens[from..) into seq 0 at positions from.. in n_batch slices; false on abort/error.
bool decode_range(Brain* b, const std::vector<llama_token>& toks, size_t from) {
  for (size_t i = from; i < toks.size(); i += b->n_batch) {
    int n = (int)std::min<size_t>(b->n_batch, toks.size() - i);
    llama_batch batch = llama_batch_get_one(const_cast<llama_token*>(toks.data() + i), n);
    int rc = llama_decode(b->ctx, batch);
    if (rc != 0) { if (rc != 2) LOGE("prefill decode rc=%d", rc); return false; }
  }
  return true;
}

// Make seq 0 hold a prefix of `prompt`, reusing what the cache already has. Returns the
// number of prompt tokens that still need decoding (starting at prompt.size() - ret).
size_t reuse_cache(Brain* b, const std::vector<llama_token>& prompt) {
  llama_memory_t mem = llama_get_memory(b->ctx);
  auto& c = b->cached;
  size_t n = 0;
  while (n < c.size() && n < prompt.size() && c[n] == prompt[n]) n++;
  b->last_reused = (int)n; b->last_shifted = 0;
  // Chunk reuse after the prefix: the host dropped the oldest exchange, so the cache is
  // prompt[0..n) + <dropped tokens> + <the rest of prompt>. Find where prompt[n..] resumes
  // in the cache and slide it down over the dropped span (RoPE shift), then keep matching.
  // (The same in-place walk as llama-server's --cache-reuse: head_p <= head_c always, so
  // writing c[head_p + k] never clobbers a cache token not yet read, and every KV cell
  // that is not part of a moved run ends up past `n` and is removed below.)
  if (n < c.size() && n < prompt.size() && llama_memory_can_shift(mem)) {
    const size_t kMinRun = 16;
    size_t head_c = n, head_p = n;
    while (head_c < c.size() && head_p < prompt.size()) {
      size_t run = 0;
      while (head_c + run < c.size() && head_p + run < prompt.size() && c[head_c + run] == prompt[head_p + run]) run++;
      if (run >= kMinRun) {
        const llama_pos shift = (llama_pos)head_p - (llama_pos)head_c;   // <= 0
        llama_memory_seq_rm(mem, 0, (llama_pos)head_p, (llama_pos)head_c);
        llama_memory_seq_add(mem, 0, (llama_pos)head_c, (llama_pos)(head_c + run), shift);
        for (size_t k = 0; k < run; k++) c[head_p + k] = c[head_c + k];
        head_c += run; head_p += run;
        b->last_shifted += (int)run;
      } else {
        head_c++;
      }
    }
    n = head_p;
  }
  // At least one token must be decoded to have fresh logits for the first sample.
  if (n >= prompt.size()) n = prompt.size() - 1;
  b->last_reused = (int)n;
  llama_memory_seq_rm(mem, 0, (llama_pos)n, -1);
  c.resize(n);
  return prompt.size() - n;
}

std::string jstr(JNIEnv* env, jstring s) {
  if (!s) return {};
  const char* c = env->GetStringUTFChars(s, nullptr);
  std::string out = c ? c : "";
  if (c) env->ReleaseStringUTFChars(s, c);
  return out;
}

// Java strings arrive as modified UTF-8 via GetStringUTFChars — fine for the BMP text
// the chat carries; supplementary chars (emoji) come in as byte arrays from Kotlin.
std::string jbytes(JNIEnv* env, jbyteArray a) {
  if (!a) return {};
  jsize n = env->GetArrayLength(a);
  std::string out(n, '\0');
  env->GetByteArrayRegion(a, 0, n, reinterpret_cast<jbyte*>(out.data()));
  return out;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_ai_bithuman_flutter_brain_LlamaBrain_nativeLoad(JNIEnv* env, jclass, jstring jpath, jint n_ctx,
                                                     jint n_threads, jint n_threads_batch, jint n_gpu_layers) {
  static bool inited = false;
  if (!inited) { llama_log_set(log_cb, nullptr); llama_backend_init(); inited = true; }
  const std::string path = jstr(env, jpath);
  auto* b = new Brain();
  llama_model_params mp = llama_model_default_params();
  mp.n_gpu_layers = n_gpu_layers;
  mp.use_mmap = true;
  const double t0 = now_ms();
  b->model = llama_model_load_from_file(path.c_str(), mp);
  if (!b->model) { LOGE("model load failed: %s", path.c_str()); delete b; return 0; }
  llama_context_params cp = llama_context_default_params();
  cp.n_ctx = (uint32_t)n_ctx;
  cp.n_batch = (uint32_t)b->n_batch;
  cp.n_ubatch = (uint32_t)b->n_batch;
  cp.n_threads = n_threads;
  cp.n_threads_batch = n_threads_batch;
  cp.no_perf = false;
  b->ctx = llama_init_from_model(b->model, cp);
  if (!b->ctx) { LOGE("context init failed"); llama_model_free(b->model); delete b; return 0; }
  llama_set_abort_callback(b->ctx, abort_cb, b);
  b->vocab = llama_model_get_vocab(b->model);
  const char* t = llama_model_chat_template(b->model, nullptr);
  b->tmpl = t ? t : "";
  LOGI("llm loaded %s n_ctx=%d threads=%d/%d gpu_layers=%d template=%s in %.0f ms", path.c_str(), n_ctx,
       n_threads, n_threads_batch, n_gpu_layers, b->tmpl.empty() ? "none(chatml)" : "model", now_ms() - t0);
  return reinterpret_cast<jlong>(b);
}

// roles/contents: the whole conversation, system first, ending with the user turn.
// sink.onPiece(byte[]) -> boolean: false stops generation. Returns tokens generated, or -1.
extern "C" JNIEXPORT jint JNICALL
Java_ai_bithuman_flutter_brain_LlamaBrain_nativeGenerate(JNIEnv* env, jclass, jlong h, jobjectArray roles,
                                                         jobjectArray contents, jint max_tokens, jfloat temp,
                                                         jint seed, jobject sink) {
  auto* b = reinterpret_cast<Brain*>(h);
  if (!b) return -1;
  b->cancel.store(false);
  const jsize n_msg = env->GetArrayLength(roles);
  std::vector<std::string> r(n_msg), c(n_msg);
  std::vector<llama_chat_message> msgs(n_msg);
  for (jsize i = 0; i < n_msg; i++) {
    auto jr = (jstring)env->GetObjectArrayElement(roles, i);
    auto jc = (jbyteArray)env->GetObjectArrayElement(contents, i);
    r[i] = jstr(env, jr); c[i] = jbytes(env, jc);
    env->DeleteLocalRef(jr); env->DeleteLocalRef(jc);
  }
  for (jsize i = 0; i < n_msg; i++) msgs[i] = {r[i].c_str(), c[i].c_str()};
  const char* tmpl = b->tmpl.empty() ? "chatml" : b->tmpl.c_str();
  std::vector<char> buf(8192);
  int len = llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, buf.data(), (int32_t)buf.size());
  if (len > (int)buf.size()) { buf.resize(len + 1); len = llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, buf.data(), (int32_t)buf.size()); }
  if (len < 0) { LOGE("chat template failed"); return -1; }
  const std::string prompt(buf.data(), len);
  std::vector<llama_token> toks = tokenize(b, prompt);
  if (toks.empty()) return -1;
  const int n_ctx = (int)llama_n_ctx(b->ctx);
  if ((int)toks.size() + max_tokens >= n_ctx) {
    LOGW("prompt %zu + %d exceeds n_ctx %d — clearing the cache", toks.size(), max_tokens, n_ctx);
    llama_memory_clear(llama_get_memory(b->ctx), true);
    b->cached.clear();
    if ((int)toks.size() + max_tokens >= n_ctx) return -1;
  }

  const double t0 = now_ms();
  const size_t todo = reuse_cache(b, toks);
  const size_t from = toks.size() - todo;
  if (!decode_range(b, toks, from)) {
    // aborted (barge) or failed: the KV past `from` is unknown, drop it
    llama_memory_seq_rm(llama_get_memory(b->ctx), 0, (llama_pos)from, -1);
    b->cached.resize(from);
    return b->cancel.load() ? 0 : -1;
  }
  b->cached = toks;
  const double t1 = now_ms();
  b->last_prompt = (int)toks.size(); b->last_decoded = (int)todo; b->last_prefill_ms = t1 - t0;

  llama_sampler* smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
  llama_sampler_chain_add(smpl, llama_sampler_init_penalties(64, 1.1f, 0.0f, 0.0f));
  llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
  llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9f, 1));
  llama_sampler_chain_add(smpl, llama_sampler_init_min_p(0.05f, 1));
  llama_sampler_chain_add(smpl, llama_sampler_init_temp(temp));
  llama_sampler_chain_add(smpl, llama_sampler_init_dist((uint32_t)seed));

  jclass sink_cls = env->GetObjectClass(sink);
  jmethodID on_piece = env->GetMethodID(sink_cls, "onPiece", "([B)Z");
  int n_gen = 0;
  double t_first = -1;
  char piece[256];
  while (n_gen < max_tokens && !b->cancel.load()) {
    llama_token tok = llama_sampler_sample(smpl, b->ctx, -1);
    if (llama_vocab_is_eog(b->vocab, tok)) break;
    int n = llama_token_to_piece(b->vocab, tok, piece, sizeof(piece), 0, false);
    if (n < 0) n = 0;
    if (t_first < 0) t_first = now_ms();
    jbyteArray arr = env->NewByteArray(n);
    if (n > 0) env->SetByteArrayRegion(arr, 0, n, reinterpret_cast<const jbyte*>(piece));
    const jboolean more = env->CallBooleanMethod(sink, on_piece, arr);
    env->DeleteLocalRef(arr);
    if (env->ExceptionCheck()) { env->ExceptionClear(); break; }
    // The token joins the context even if we stop here, so the cache stays exact.
    llama_batch batch = llama_batch_get_one(&tok, 1);
    if (llama_decode(b->ctx, batch) != 0) break;
    b->cached.push_back(tok);
    n_gen++;
    if (!more) break;
  }
  llama_sampler_free(smpl);
  const double t2 = now_ms();
  b->last_gen = n_gen; b->last_first_tok_ms = t_first < 0 ? -1 : t_first - t0; b->last_gen_ms = t2 - t1;
  return n_gen;
}

extern "C" JNIEXPORT void JNICALL
Java_ai_bithuman_flutter_brain_LlamaBrain_nativeCancel(JNIEnv*, jclass, jlong h) {
  if (auto* b = reinterpret_cast<Brain*>(h)) b->cancel.store(true);
}

extern "C" JNIEXPORT void JNICALL
Java_ai_bithuman_flutter_brain_LlamaBrain_nativeReset(JNIEnv*, jclass, jlong h) {
  auto* b = reinterpret_cast<Brain*>(h);
  if (!b) return;
  llama_memory_clear(llama_get_memory(b->ctx), true);
  b->cached.clear();
}

extern "C" JNIEXPORT jstring JNICALL
Java_ai_bithuman_flutter_brain_LlamaBrain_nativeLastStats(JNIEnv* env, jclass, jlong h) {
  auto* b = reinterpret_cast<Brain*>(h);
  if (!b) return env->NewStringUTF("");
  char s[256];
  snprintf(s, sizeof(s), "prompt=%d reused=%d shifted=%d decoded=%d prefillMs=%.0f firstTokMs=%.0f gen=%d genMs=%.0f tps=%.1f",
           b->last_prompt, b->last_reused, b->last_shifted, b->last_decoded, b->last_prefill_ms, b->last_first_tok_ms,
           b->last_gen, b->last_gen_ms, b->last_gen_ms > 0 ? b->last_gen * 1000.0 / b->last_gen_ms : 0.0);
  return env->NewStringUTF(s);
}

extern "C" JNIEXPORT void JNICALL
Java_ai_bithuman_flutter_brain_LlamaBrain_nativeFree(JNIEnv*, jclass, jlong h) {
  auto* b = reinterpret_cast<Brain*>(h);
  if (!b) return;
  if (b->ctx) llama_free(b->ctx);
  if (b->model) llama_model_free(b->model);
  delete b;
}
