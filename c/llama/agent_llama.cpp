// agent_llama: in-process local inference as a byte transport (ADR 0004). See agent_llama.h.
//
// One request is handled the way llama-server handles /v1/chat/completions, with llama.cpp's own
// `common` chat machinery: the model's chat template renders messages + tools into a prompt, the
// tools' JSON schemas become a (lazy) decoding grammar for tool calls, and the generated text is
// parsed back into content and tool_calls. Sampling is greedy, the KV cache is cleared per request,
// and ids are derived from a per-handle counter, so equal requests on a fresh handle give equal bytes.
#include "agent_llama.h"

#include "chat.h"
#include "common.h"
#include "json.h"
#include "llama.h"
#include "log.h"
#include "sampling.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

struct agent_llama {
  llama_model *model = nullptr;
  llama_context *ctx = nullptr;
  const llama_vocab *vocab = nullptr;
  common_chat_templates_ptr tmpls;
  bool parallel_tool_calls = false; // what the chat template supports
  uint64_t n_requests = 0;
};

namespace {

struct request_error : std::runtime_error {
  int status;
  request_error(int status, const std::string &msg) : std::runtime_error(msg), status(status) {}
};

agent_buf_t make_buf(const std::string &s) {
  agent_buf_t b;
  b.data = static_cast<uint8_t *>(std::malloc(s.size() + 1));
  if (!b.data) { b.len = 0; return b; }
  std::memcpy(b.data, s.data(), s.size());
  b.data[s.size()] = 0;
  b.len = s.size();
  return b;
}

std::string error_body(int status, const std::string &msg) {
  common_json e = common_json::object();
  e["error"] = common_json::object();
  e["error"]["message"] = msg;
  e["error"]["type"] = status == 400 ? "invalid_request_error" : "server_error";
  return e.dump();
}

void quiet_log(enum ggml_log_level level, const char *text, void *) {
  if (level >= GGML_LOG_LEVEL_ERROR || std::getenv("AGENT_LLAMA_VERBOSE")) std::fputs(text, stderr);
}

std::once_flag backend_once;

// Evaluate `tokens` at positions [pos0, pos0 + n), in batches of at most n_batch; logits for the last.
void decode(llama_context *ctx, llama_batch_ext *batch, const llama_token *tokens, size_t n, llama_pos pos0) {
  const size_t n_batch = llama_n_batch(ctx);
  for (size_t off = 0; off < n; off += n_batch) {
    const size_t m = std::min(n_batch, n - off);
    llama_batch_ext_clear(batch);
    for (size_t i = 0; i < m; i++) {
      const int32_t idx = llama_batch_ext_add_token(batch, 0, tokens[off + i]);
      if (idx < 0) throw request_error(500, "batch is full");
      const llama_pos pos = pos0 + (llama_pos)(off + i);
      llama_batch_ext_set_pos(batch, idx, &pos);
    }
    llama_batch_ext_set_output_logits(batch, (int32_t)m - 1, off + m == n);
    if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch) != 0) throw request_error(500, "decode failed");
  }
}

// Sampling for one request: greedy (top-k 1, so the result does not depend on a seed), plus the chat
// session's tool-call grammar. For templates with native tool calls the grammar is lazy: free text
// is unconstrained, and once the model emits the tool-call trigger (e.g. Qwen's <tool_call>) every
// following token must keep the output inside the grammar compiled from the request's tool
// schemas -- a known tool name and arguments that validate against that tool's JSON schema
// (required keys, types, integer bounds, additionalProperties:false).
// @tg: implements:: [[openspec:llm-codecs#Local constrained decoding]]
common_sampler *constrained_sampler(const llama_model *model, const common_chat_session &session) {
  common_params_sampling sp;
  sp.samplers = {COMMON_SAMPLER_TYPE_TOP_K};
  sp.top_k = 1;
  sp.temp = 0.0f;
  sp.seed = 0;
  sp.n_probs = 0;
  session.apply_sampling(sp); // grammar, grammar_lazy, triggers, preserved tokens, generation prompt
  if (std::getenv("AGENT_LLAMA_DEBUG"))
    std::fprintf(stderr, "agent_llama: format %s, grammar %s (%zu bytes), %zu triggers\n%s\n",
                 common_chat_format_name(session.format()), sp.grammar_lazy ? "lazy" : "strict",
                 session.grammar().size(), sp.grammar_triggers.size(), session.grammar().c_str());
  common_sampler *smpl = common_sampler_init(model, sp);
  if (!smpl) throw request_error(500, "cannot build the tool-call grammar for this request");
  return smpl;
}

std::string complete(agent_llama &l, const std::string &text) {
  common_json body = common_json::parse_no_throw(text);
  if (body.is_discarded() || !body.is_object()) throw request_error(400, "request body is not a JSON object");
  if (!body.contains("messages") || !body.at("messages").is_array())
    throw request_error(400, "'messages' must be an array");
  if (body.contains("stream") && body.at("stream").is_boolean() && body.at("stream").get<bool>())
    throw request_error(400, "streaming is not supported by the local adapter");

  const uint64_t req = ++l.n_requests;

  common_chat_templates_inputs inputs;
  try {
    inputs.messages = common_chat_msgs_parse_oaicompat(body.at("messages"));
    if (body.contains("tools") && body.at("tools").is_array())
      inputs.tools = common_chat_tools_parse_oaicompat(body.at("tools"));
    if (body.contains("tool_choice") && body.at("tool_choice").is_string())
      inputs.tool_choice = common_chat_tool_choice_parse_oaicompat(body.at("tool_choice").get<std::string>());
  } catch (const std::exception &e) {
    throw request_error(400, e.what());
  }
  inputs.use_jinja = true;
  inputs.add_generation_prompt = true;
  inputs.parallel_tool_calls = body.value("parallel_tool_calls", l.parallel_tool_calls);
  inputs.enable_thinking = false;
  inputs.now = {}; // templates that print the date must not make the prompt time-dependent

  common_chat_session session;
  try {
    session = common_chat_session(l.tmpls.get(), l.vocab, inputs);
  } catch (const std::exception &e) {
    throw request_error(400, std::string("chat template: ") + e.what());
  }

  std::vector<std::string> stops = session.additional_stops();
  if (body.contains("stop")) {
    const common_json &s = body.at("stop");
    if (s.is_string()) stops.push_back(s.get<std::string>());
    else if (s.is_array())
      for (size_t i = 0; i < s.size(); i++)
        if (s.at(i).is_string()) stops.push_back(s.at(i).get<std::string>());
  }

  const std::vector<llama_token> prompt = common_tokenize(l.vocab, session.prompt().str(), true, true);
  const int n_ctx = (int)llama_n_ctx(l.ctx);
  if ((int)prompt.size() >= n_ctx) throw request_error(400, "prompt does not fit the context window");
  long max_tokens = body.value("max_completion_tokens", body.value("max_tokens", 1024L));
  if (max_tokens <= 0 || max_tokens > n_ctx - (long)prompt.size()) max_tokens = n_ctx - (long)prompt.size();

  common_sampler *smpl = constrained_sampler(l.model, session);
  llama_batch_ext *batch = llama_batch_ext_init(l.ctx);
  common_chat_input generated;
  const char *finish = "stop";
  long n_gen = 0;
  try {
    llama_memory_clear(llama_get_memory(l.ctx), true);
    decode(l.ctx, batch, prompt.data(), prompt.size(), 0);
    llama_pos pos = (llama_pos)prompt.size();
    for (;;) {
      if (n_gen >= max_tokens) { finish = "length"; break; }
      const llama_token tok = common_sampler_sample(smpl, l.ctx, -1);
      common_sampler_accept(smpl, tok, true);
      if (llama_vocab_is_eog(l.vocab, tok)) break;
      n_gen++;
      // control tokens of the tool-call syntax (e.g. <tool_call>) are kept so the parser sees them
      generated.append(common_token_to_piece(l.vocab, tok, true), tok);
      bool stopped = false;
      for (const auto &s : stops) {
        if (s.empty()) continue;
        const size_t from = generated.text.size() > s.size() + 64 ? generated.text.size() - s.size() - 64 : 0;
        const size_t at = generated.text.find(s, from);
        if (at != std::string::npos) { generated.truncate(at); stopped = true; break; }
      }
      if (stopped) break;
      decode(l.ctx, batch, &tok, 1, pos++);
    }
  } catch (...) {
    llama_batch_ext_free(batch);
    common_sampler_free(smpl);
    throw;
  }
  llama_batch_ext_free(batch);
  common_sampler_free(smpl);

  common_chat_msg msg;
  try {
    msg = session.finish(generated);
  } catch (const std::exception &e) {
    throw request_error(500, std::string("cannot parse the model output: ") + e.what());
  }
  msg.role = "assistant";
  for (size_t i = 0; i < msg.tool_calls.size(); i++)
    if (msg.tool_calls[i].id.empty()) msg.tool_calls[i].id = "call_" + std::to_string(req) + "_" + std::to_string(i + 1);

  common_json message = msg.to_json_oaicompat();
  if (!msg.tool_calls.empty() && msg.content.empty() && msg.content_parts.empty()) message["content"] = nullptr;

  common_json choice = common_json::object();
  choice["index"] = 0;
  choice["message"] = message;
  choice["finish_reason"] = msg.tool_calls.empty() ? finish : "tool_calls";

  common_json usage = common_json::object();
  usage["prompt_tokens"] = (long)prompt.size();
  usage["completion_tokens"] = n_gen;
  usage["total_tokens"] = (long)prompt.size() + n_gen;

  common_json resp = common_json::object();
  resp["id"] = "chatcmpl-local-" + std::to_string(req);
  resp["object"] = "chat.completion";
  resp["model"] = body.value("model", std::string("local"));
  resp["choices"] = common_json::array();
  resp["choices"].push_back(choice);
  resp["usage"] = usage;
  return resp.dump();
}

} // namespace

extern "C" agent_llama_t *agent_llama_open(const char *gguf_path, int n_ctx, agent_buf_t *err) {
  if (err) *err = agent_buf_t{nullptr, 0};
  auto fail = [&](const std::string &m) -> agent_llama_t * {
    if (err) *err = make_buf(m);
    return nullptr;
  };
  if (!gguf_path) return fail("no model path");
  std::call_once(backend_once, [] {
    llama_log_set(quiet_log, nullptr);
    common_log_set_verbosity_thold(-1);
    llama_backend_init();
  });
  auto *l = new (std::nothrow) agent_llama();
  if (!l) return fail("out of memory");
  llama_model_params mp = llama_model_default_params();
  mp.n_gpu_layers = 999; // everything on Metal when available; CPU builds ignore it
  mp.progress_callback = [](float, void *) { return true; }; // no progress dots on stderr
  l->model = llama_model_load_from_file(gguf_path, mp);
  if (!l->model) { delete l; return fail(std::string("cannot load model ") + gguf_path); }
  l->vocab = llama_model_get_vocab(l->model);
  llama_context_params cp = llama_context_default_params();
  cp.n_ctx = n_ctx > 0 ? (uint32_t)n_ctx : 4096;
  cp.n_batch = cp.n_ctx;
  cp.n_seq_max = 1;
  l->ctx = llama_init_from_model(l->model, cp);
  if (!l->ctx) { llama_model_free(l->model); delete l; return fail("cannot create the llama context"); }
  try {
    l->tmpls = common_chat_templates_init(l->model, "");
    common_json caps = common_chat_templates_get_caps(l->tmpls.get());
    l->parallel_tool_calls = caps.value("supports_parallel_tool_calls", false);
  } catch (const std::exception &e) {
    agent_llama_close(l);
    return fail(std::string("chat template: ") + e.what());
  }
  return l;
}

// The local model is reached through the same bytes as a remote endpoint: an OpenAI-compatible
// request body in, an OpenAI-compatible response body out, which the host feeds back as an
// ordinary llm_response event.
// @tg: implements:: [[openspec:llm-codecs#Transport neutrality]]
extern "C" agent_buf_t agent_llama_complete(agent_llama_t *l, const uint8_t *request_body, size_t len, int *status) {
  int st = 500;
  std::string out;
  if (!l) {
    st = 500;
    out = error_body(st, "no adapter handle");
  } else {
    try {
      out = complete(*l, std::string(reinterpret_cast<const char *>(request_body), request_body ? len : 0));
      st = 200;
    } catch (const request_error &e) {
      st = e.status;
      out = error_body(st, e.what());
    } catch (const std::exception &e) {
      st = 500;
      out = error_body(st, e.what());
    } catch (...) {
      st = 500;
      out = error_body(st, "unknown error");
    }
  }
  if (status) *status = st;
  return make_buf(out);
}

extern "C" void agent_llama_close(agent_llama_t *l) {
  if (!l) return;
  l->tmpls.reset();
  if (l->ctx) llama_free(l->ctx);
  if (l->model) llama_model_free(l->model);
  delete l;
}
