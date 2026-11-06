// llama_run: drive the example `assistant` agent through the C ABI, serving every llm_request
// effect with the in-process llama.cpp adapter, and write the run as a golden trace.
//
//   llama_run --model M.gguf --golden OUT [--ctx N] [PROMPT...]
//
// The golden file has the format of Tests/Golden.lean and `driver_demo --golden`: the config line
// (`C`), then every fed event (`E`) followed by the effects it produced (`X`), verbatim from
// agent_next_effect. The pure tool `add` runs inside the core; host and io tools get fixed stub
// results. scripts/test_llama.sh runs this twice (the local transport must be deterministic) and
// replays the file with llama_conformance (the same response bytes delivered as ordinary events,
// as an HTTP host would deliver them, must produce identical effects).
#include "agent.h"
#include "agent_llama.h"
#include "json.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

static std::string stub_result(const std::string &name, const common_json &args) {
  common_json r = common_json::object();
  if (name == "confirm_user") r["confirmed"] = true;
  else if (name == "web_fetch") return common_json::make("stub page").dump();
  else if (name == "transfer") { r["ok"] = true; r["ref"] = "TX1"; }
  else if (name == "send_email") r["sent"] = true;
  else if (name == "delete_all") r["deleted"] = 0;
  else if (name == "lookup") {
    std::string key = args.is_object() && args.contains("key") && args.at("key").is_string() ? args.at("key").get<std::string>() : "";
    return common_json::make("value-of-" + key).dump();
  } else r["error"] = "no stub for tool " + name;
  return r.dump();
}

// @tg: verifies:: [[openspec:llm-codecs#Transport neutrality#Same trace via local adapter]] {level: e2e}
int main(int argc, char **argv) {
  std::string model_path, golden_path, prompt;
  int n_ctx = 4096;
  for (int i = 1; i < argc; i++) {
    if (!std::strcmp(argv[i], "--model") && i + 1 < argc) model_path = argv[++i];
    else if (!std::strcmp(argv[i], "--golden") && i + 1 < argc) golden_path = argv[++i];
    else if (!std::strcmp(argv[i], "--ctx") && i + 1 < argc) n_ctx = std::atoi(argv[++i]);
    else prompt += (prompt.empty() ? "" : " ") + std::string(argv[i]);
  }
  if (model_path.empty() || golden_path.empty()) {
    std::fprintf(stderr, "usage: %s --model M.gguf --golden OUT [--ctx N] [PROMPT...]\n", argv[0]);
    return 2;
  }
  if (prompt.empty()) prompt = "What is 17 plus 25? Use the add tool.";

  auto t0 = std::chrono::steady_clock::now();
  agent_buf_t err;
  agent_llama_t *llm = agent_llama_open(model_path.c_str(), n_ctx, &err);
  if (!llm) { std::fprintf(stderr, "agent_llama_open: %s\n", err.data ? (char *)err.data : "?"); agent_buf_free(err); return 1; }
  auto t_loaded = std::chrono::steady_clock::now();

  // The endpoint is never contacted: the host serves llm_request effects in-process.
  common_json cfg = common_json::object();
  cfg["agent"] = "assistant";
  cfg["model"] = "qwen2.5-0.5b-instruct-q4_k_m";
  cfg["endpoint"] = "http://127.0.0.1:8080/v1/chat/completions";
  cfg["provider"] = "openai";
  const std::string cfg_s = cfg.dump();
  agent_t *a = agent_new((const uint8_t *)cfg_s.data(), cfg_s.size(), &err);
  if (!a) { std::fprintf(stderr, "agent_new: %s\n", err.data ? (char *)err.data : "?"); agent_buf_free(err); return 1; }

  std::vector<std::string> lines{"C " + cfg_s};
  std::deque<std::string> pending; // effects not yet handled, in order
  int rc = 1, n_llm = 0, n_events = 0;
  bool add_called = false;
  std::string answer;
  double llm_ms = 0;

  auto feed = [&](const std::string &ev) -> bool {
    lines.push_back("E " + ev);
    n_events++;
    int code = agent_feed(a, (const uint8_t *)ev.data(), ev.size());
    if (code != AGENT_OK) {
      agent_buf_t e = agent_last_error(a);
      std::fprintf(stderr, "event rejected (%d): %s\n  %s\n", code, (char *)e.data, ev.c_str());
      agent_buf_free(e);
      return false;
    }
    agent_buf_t eff;
    while (agent_next_effect(a, &eff)) {
      std::string s((char *)eff.data, eff.len);
      lines.push_back("X " + s);
      pending.push_back(s);
      agent_buf_free(eff);
    }
    return true;
  };

  common_json user = common_json::object();
  user["type"] = "user";
  user["text"] = prompt;
  bool ok = feed(user.dump());
  while (ok && !pending.empty() && n_events < 64) {
    common_json eff = common_json::parse(pending.front());
    pending.pop_front();
    const std::string type = eff.value("type", std::string());
    if (type == "llm_request") {
      const std::string body = eff.at("body").get<std::string>();
      int status = 0;
      auto t = std::chrono::steady_clock::now();
      agent_buf_t resp = agent_llama_complete(llm, (const uint8_t *)body.data(), body.size(), &status);
      llm_ms += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
      n_llm++;
      std::fprintf(stderr, "[%s] status %d: %s\n", eff.at("id").get<std::string>().c_str(), status, (char *)resp.data);
      common_json ev = common_json::object();
      ev["type"] = "llm_response";
      ev["id"] = eff.at("id");
      ev["status"] = status;
      ev["body"] = std::string((char *)resp.data, resp.len);
      agent_buf_free(resp);
      ok = feed(ev.dump());
    } else if (type == "tool_call") {
      common_json ev = common_json::object();
      ev["type"] = "tool_result";
      ev["id"] = eff.at("id");
      ev["result"] = common_json::parse(stub_result(eff.value("name", std::string()), eff.value("args", common_json::object())));
      ok = feed(ev.dump());
    } else if (type == "ui") {
      if (eff.value("kind", std::string()) == "tool_start" && eff.value("name", std::string()) == "add") add_called = true;
    } else if (type == "complete") {
      answer = eff.value("answer", std::string());
      rc = eff.value("reason", std::string()) == "final" ? 0 : 1;
      std::printf("complete: %s\n", eff.dump().c_str());
    } else {
      std::fprintf(stderr, "unhandled effect: %s\n", eff.dump().c_str());
    }
  }

  FILE *f = std::fopen(golden_path.c_str(), "wb");
  if (!f) { std::perror(golden_path.c_str()); rc = 1; }
  else {
    for (auto &l : lines) std::fprintf(f, "%s\n", l.c_str());
    std::fclose(f);
  }
  double load_ms = std::chrono::duration<double, std::milli>(t_loaded - t0).count();
  std::printf("prompt: %s\nadd called: %s\nanswer: %s\nllm requests: %d, events: %d, load %.0f ms, inference %.0f ms\n",
              prompt.c_str(), add_called ? "yes" : "no", answer.c_str(), n_llm, n_events, load_ms, llm_ms);
  agent_free(a);
  agent_llama_close(llm);
  return rc;
}
