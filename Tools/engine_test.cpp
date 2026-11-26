// Command line harness for the core engine (used locally and in CI as a smoke test).
//   engine_test <dict.bin> <pinyin|xiaohe> <input> [fuzzyMask] [userdir]
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include "../Core/engine.hpp"

using namespace ime;

static void show(Engine& e, int scheme, const std::string& in, int maxShow) {
    std::vector<KeyStroke> keys;
    for (char c : in) {
        KeyStroke k;
        k.n = 1; k.c[0] = c; k.p[0] = 1.f; k.c[1] = k.c[2] = 0; k.p[1] = k.p[2] = 0;
        keys.push_back(k);
    }
    auto t0 = std::chrono::steady_clock::now();
    uint64_t g = e.bumpGeneration();
    auto res = e.decode(keys.data(), static_cast<int>(keys.size()), g);
    auto t1 = std::chrono::steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    std::printf("[%s] '%s'  %.2f ms  seg='%s'  cands=%zu\n", scheme ? "xiaohe" : "pinyin", in.c_str(), ms,
                e.quickSegment(in.data(), static_cast<int>(in.size()), scheme, true).c_str(), res ? res->cands.size() : 0);
    if (!res) return;
    for (int i = 0; i < static_cast<int>(res->cands.size()) && i < maxShow; i++) {
        const Candidate& c = res->cands[i];
        std::printf("  %2d %s%s%s  (consumed=%d score=%.2f)\n", i, std::string(res->pool.data() + c.textOff, c.textLen).c_str(),
                    (c.flags & kCandSentence) ? " [S]" : "", (c.flags & kCandUser) ? " [U]" : "", c.consumed, c.score);
    }
}

int main(int argc, char** argv) {
    if (argc < 4) { std::fprintf(stderr, "usage: engine_test dict scheme input...\n"); return 2; }
    Engine e;
    std::string err;
    auto t0 = std::chrono::steady_clock::now();
    if (!e.loadDictionary(argv[1], &err)) { std::fprintf(stderr, "load failed: %s\n", err.c_str()); return 1; }
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    std::printf("dictionary opened in %.3f ms (words=%llu)\n", ms, static_cast<unsigned long long>(e.dictionary().wordCount()));
    EngineSettings s;
    s.scheme = std::string(argv[2]) == "xiaohe" ? kSchemeXiaohe : kSchemePinyin;
    if (const char* f = std::getenv("IME_FUZZY")) s.fuzzy = static_cast<uint16_t>(std::atoi(f));
    e.setSettings(s);
    if (const char* d = std::getenv("IME_USERDIR")) e.openUserData(d);
    for (int i = 3; i < argc; i++) show(e, s.scheme, argv[i], 12);
    if (const char* pick = std::getenv("IME_LEARN")) {
        // learning scenario: pick candidate #N for the first input, commit, decode again
        std::string in = argv[3];
        std::vector<KeyStroke> keys;
        for (char c : in) { KeyStroke k{}; k.n = 1; k.c[0] = c; k.p[0] = 1.f; keys.push_back(k); }
        auto res = e.decode(keys.data(), static_cast<int>(keys.size()), e.bumpGeneration());
        int idx = std::atoi(pick);
        const Candidate& c = res->cands[idx];
        CommitSeg seg;
        seg.text.assign(res->pool.data() + c.textOff, c.textLen);
        seg.syls.assign(res->syls.begin() + c.sylOff, res->syls.begin() + c.sylOff + c.sylCount);
        seg.baseLn = c.baseLn; seg.key = c.key; seg.wordId = c.wordId;
        e.commit({seg});
        std::printf("-- committed '%s'; user words=%zu\n", seg.text.c_str(), e.userWordCount());
        show(e, s.scheme, in, 6);
        e.rollbackLastCommit();
        std::printf("-- rolled back; user words=%zu\n", e.userWordCount());
        show(e, s.scheme, in, 6);
    }
    return 0;
}
