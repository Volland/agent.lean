// llama_constrained: tool-call arguments produced through the local adapter always satisfy the
// tool's JSON schema.
//
//   llama_constrained --model M.gguf [--ctx N]
//
// For each prompt, a fresh example `assistant` agent is fed the prompt through the C ABI and its
// first llm_request body -- the exact bytes the core would send to an endpoint, with the assistant's
// tool schemas -- is served by the adapter twice: as is (tool_choice auto: the grammar is lazy and
// applies once the model starts a tool call) and with "tool_choice":"required" (the model must call a
// tool). Every returned tool call must name a tool of the request and carry arguments that parse
// as a JSON object satisfying that tool's schema: required keys present, no undeclared keys when
// additionalProperties is false, declared types (integers for `add`), integer bounds. With
// tool_choice required, every prompt must yield at least one tool call.
#include "agent.h"
#include "agent_llama.h"
#include "json.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static bool has_type(const common_json &v, const std::string &t) {
  if (t == "object") return v.is_object();
  if (t == "array") return v.is_array();
  if (t == "string") return v.is_string();
  if (t == "integer") return v.is_number_integer();
  if (t == "number") return v.is_number();
  if (t == "boolean") return v.is_boolean();
  if (t == "null") return v.is_null();
  return true; // a type this check does not know is not checked
}

// The JSON-schema subset the derived tool schemas use. Returns "" when `v` satisfies `schema`.
static std::string check(const common_json &schema, const common_json &v, const std::string &path) {
  if (!schema.is_object()) return "";
  if (schema.contains("type") && schema.at("type").is_string()) {
    const std::string t = schema.at("type").get<std::string>();
    if (!has_type(v, t)) return path + ": expected " + t + ", got " + v.dump();
  }
  if (v.is_number_integer()) {
    const long long n = v.get<long long>();
    if (schema.contains("minimum") && n < schema.at("minimum").get<double>()) return path + ": below minimum";
    if (schema.contains("maximum") && n > schema.at("maximum").get<double>()) return path + ": above maximum";
  }
  if (schema.contains("enum") && schema.at("enum").is_array()) {
    bool found = false;
    for (size_t i = 0; i < schema.at("enum").size(); i++) found = found || schema.at("enum").at(i).dump() == v.dump();
    if (!found) return path + ": not in enum";
  }
  if (v.is_object()) {
    const common_json props = schema.value("properties", common_json::object());
    if (schema.contains("required") && schema.at("required").is_array())
      for (size_t i = 0; i < schema.at("required").size(); i++) {
        const std::string k = schema.at("required").at(i).get<std::string>();
        if (!v.contains(k)) return path + ": missing required key '" + k + "'";
      }
    const bool closed = schema.contains("additionalProperties") && schema.at("additionalProperties").is_boolean() &&
                        !schema.at("additionalProperties").get<bool>();
    for (const auto &kv : v.items()) {
      if (props.contains(kv.key())) {
        std::string e = check(props.at(kv.key()), kv.value(), path + "." + kv.key());
        if (!e.empty()) return e;
      } else if (closed) {
        return path + ": undeclared key '" + kv.key() + "'";
      }
    }
  }
  if (v.is_array() && schema.contains("items"))
    for (size_t i = 0; i < v.size(); i++) {
      std::string e = check(schema.at("items"), v.at(i), path + "[" + std::to_string(i) + "]");
      if (!e.empty()) return e;
    }
  return "";
}

// The request body the example assistant sends for `prompt`, taken from its first llm_request.
static std::string first_request(const std::string &prompt) {
  const std::string cfg = R"({"agent":"assistant","model":"qwen2.5-0.5b-instruct-q4_k_m","endpoint":"http://127.0.0.1:8080/v1/chat/completions","provider":"openai"})";
  agent_buf_t err;
  agent_t *a = agent_new((const uint8_t *)cfg.data(), cfg.size(), &err);
  if (!a) { std::fprintf(stderr, "agent_new: %s\n", (char *)err.data); agent_buf_free(err); return ""; }
  common_json user = common_json::object();
  user["type"] = "user";
  user["text"] = prompt;
  const std::string ev = user.dump();
  std::string body;
  if (agent_feed(a, (const uint8_t *)ev.data(), ev.size()) == AGENT_OK) {
    agent_buf_t eff;
    while (agent_next_effect(a, &eff)) {
      common_json e = common_json::parse(std::string((char *)eff.data, eff.len));
      if (body.empty() && e.value("type", std::string()) == "llm_request") body = e.at("body").get<std::string>();
      agent_buf_free(eff);
    }
  }
  agent_free(a);
  return body;
}

// @tg: verifies:: [[openspec:llm-codecs#Local constrained decoding#Small model cannot emit malformed arguments]] {level: e2e}
int main(int argc, char **argv) {
  std::string model_path;
  int n_ctx = 4096;
  for (int i = 1; i < argc; i++) {
    if (!std::strcmp(argv[i], "--model") && i + 1 < argc) model_path = argv[++i];
    else if (!std::strcmp(argv[i], "--ctx") && i + 1 < argc) n_ctx = std::atoi(argv[++i]);
  }
  if (model_path.empty()) { std::fprintf(stderr, "usage: %s --model M.gguf [--ctx N]\n", argv[0]); return 2; }

  const std::vector<std::string> prompts = {
      "What is 17 plus 25? Use the add tool.",
      "Add 2.5 and 3.7 with the add tool.",
      "Please add one thousand two hundred and thirty-four to minus fifty-six.",
      "Send an email to alice@example.com telling her the meeting moved to 3pm.",
      "Fetch the page https://example.com/news and tell me what it says.",
      "Transfer 20 dollars to bob with the memo 'lunch'.",
      "Look up the configuration value for the key region.",
      "Before you delete anything, ask me to confirm that the temp folder may be wiped.",
  };

  agent_buf_t err;
  agent_llama_t *llm = agent_llama_open(model_path.c_str(), n_ctx, &err);
  if (!llm) { std::fprintf(stderr, "agent_llama_open: %s\n", err.data ? (char *)err.data : "?"); agent_buf_free(err); return 1; }

  int n_requests = 0, n_calls = 0, n_bad = 0, n_failed = 0;
  auto t0 = std::chrono::steady_clock::now();
  for (const auto &prompt : prompts) {
    const std::string base = first_request(prompt);
    if (base.empty()) { std::fprintf(stderr, "no llm_request for: %s\n", prompt.c_str()); n_failed++; continue; }
    for (const char *choice : {"auto", "required"}) {
      common_json req = common_json::parse(base);
      req["tool_choice"] = choice;
      const std::string body = req.dump();
      int status = 0;
      agent_buf_t resp = agent_llama_complete(llm, (const uint8_t *)body.data(), body.size(), &status);
      n_requests++;
      const std::string resp_s((char *)resp.data, resp.len);
      agent_buf_free(resp);
      std::printf("[%-8s] %s\n", choice, prompt.c_str());
      if (status != 200) { std::printf("  FAIL status %d: %s\n", status, resp_s.c_str()); n_failed++; continue; }
      const common_json msg = common_json::parse(resp_s).at("choices").at(0).at("message");
      const common_json calls = msg.value("tool_calls", common_json::array());
      if (calls.empty()) {
        std::printf("  text: %s\n", msg.at("content").is_string() ? msg.at("content").get<std::string>().c_str() : "null");
        if (std::string(choice) == "required") { std::printf("  FAIL no tool call with tool_choice required\n"); n_failed++; }
        continue;
      }
      for (size_t i = 0; i < calls.size(); i++) {
        n_calls++;
        const std::string name = calls.at(i).at("function").at("name").get<std::string>();
        const std::string args = calls.at(i).at("function").at("arguments").get<std::string>();
        std::string why;
        common_json schema;
        bool known = false;
        for (size_t t = 0; t < req.at("tools").size(); t++)
          if (req.at("tools").at(t).at("function").at("name").get<std::string>() == name) {
            schema = req.at("tools").at(t).at("function").at("parameters");
            known = true;
          }
        common_json parsed = common_json::parse_no_throw(args);
        if (!known) why = "unknown tool";
        else if (parsed.is_discarded()) why = "arguments are not JSON";
        else if (!parsed.is_object()) why = "arguments are not a JSON object";
        else why = check(schema, parsed, "$");
        std::printf("  %s %s(%s)%s%s\n", why.empty() ? "ok  " : "BAD ", name.c_str(), args.c_str(), why.empty() ? "" : " -- ", why.c_str());
        if (!why.empty()) n_bad++;
      }
    }
  }
  const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  agent_llama_close(llm);
  std::printf("%d prompts, %d requests, %d tool calls, %d malformed, %d failed, %.0f ms\n", (int)prompts.size(),
              n_requests, n_calls, n_bad, n_failed, ms);
  return (n_bad == 0 && n_failed == 0 && n_calls > 0) ? 0 : 1;
}
