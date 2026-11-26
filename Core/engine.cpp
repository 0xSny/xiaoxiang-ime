#include "engine.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <ctime>
#include <type_traits>

namespace ime {

namespace {
constexpr float kJianpin = -1.8f;
constexpr float kFuzzyCost = -2.2f;
constexpr float kTransCost = -4.0f;
constexpr float kNeighborBase = -2.5f;
constexpr float kPrefixCost = -1.0f;
constexpr float kWordPenalty = 0.4f;
constexpr int kBeam = 10;
constexpr uint32_t kNone = 0xFFFFFFFFu;

struct StaticView {
    const Dictionary& d;
    static constexpr int maxDepth = 8;
    uint32_t root() const { return 0; }
    bool exact(uint32_t node, uint16_t sid, uint32_t* child) const {
        int e = d.findEdge(d.nodes()[node], sid);
        if (e < 0) return false;
        *child = d.edges()[e].child;
        return true;
    }
    template <class F>
    void each(uint32_t node, F f) const {
        const DictNode& nd = d.nodes()[node];
        const DictEdge* e = d.edges() + nd.edgeStart;
        for (uint32_t i = 0; i < nd.edgeCount; i++) f(e[i].syl, e[i].child, d.nodes()[e[i].child].maxW);
    }
};

struct UserView {
    const UserDict& u;
    static constexpr int maxDepth = 12;
    uint32_t root() const { return 0; }
    bool exact(uint32_t node, uint16_t sid, uint32_t* child) const {
        int c = u.child(static_cast<int>(node), sid);
        if (c < 0) return false;
        *child = static_cast<uint32_t>(c);
        return true;
    }
    template <class F>
    void each(uint32_t node, F f) const {
        for (const auto& p : u.node(static_cast<int>(node)).edges) f(p.first, static_cast<uint32_t>(p.second), static_cast<uint16_t>(0));
    }
};

inline bool isLetter(char c) { return c >= 'a' && c <= 'z'; }
}  // namespace

Engine::Engine() {
    EngineSettings s;
    setSettings(s);
    // zero-initial vowel masks
    const SyllableTable& T = SyllableTable::get();
    for (auto& m : zeroMask_) m.clear();
    for (int id = 0; id < T.count(); id++)
        if (T.at(id).ini == 0) zeroMask_[T.at(id).s[0] - 'a'].set(id);
}

bool Engine::loadDictionary(const char* path, std::string* err) {
    if (!dict_.open(path, err)) return false;
    lnTotal_ = dict_.lnTotal();
    return true;
}

void Engine::setSettings(const EngineSettings& s) {
    set_ = s;
    const SyllableTable& T = SyllableTable::get();
    fuzzyAlts_ = T.buildFuzzyAlts(s.fuzzy);
    for (int i = 0; i < kInitialCount; i++) iniTok_[i] = T.initialMask(i);
    auto pair = [&](int bit, int a, int b) {
        if (s.fuzzy & (1u << bit)) {
            iniTok_[a].orWith(T.initialMask(b));
            iniTok_[b].orWith(T.initialMask(a));
        }
    };
    pair(kFuzzyZZh, 19, 15);
    pair(kFuzzyCCh, 20, 16);
    pair(kFuzzySSh, 21, 17);
    pair(kFuzzyLN, 8, 7);
    pair(kFuzzyFH, 4, 11);
    pair(kFuzzyRL, 18, 8);
}

bool Engine::openUserData(const char* dir) { return user_.open(dir); }

// ---------------------------------------------------------------------------
// Input preparation & token generation
// ---------------------------------------------------------------------------

void Engine::prepareInput(const KeyStroke* keys, int n) {
    n_ = n;
    primary_.assign(n, 0);
    sep_.assign(n, 0);
    acost_.resize(n);
    float scale = set_.spatialScale * (set_.scheme == kSchemeXiaohe ? 1.3f : 1.0f);
    bool spatial = set_.correction && scale > 0.01f;
    for (int i = 0; i < n; i++) {
        acost_[i].fill(-1e9f);
        const KeyStroke& k = keys[i];
        if (k.n == 0) { sep_[i] = 1; continue; }
        int best = 0;
        for (int j = 1; j < k.n && j < 3; j++) if (k.p[j] > k.p[best]) best = j;
        char pc = k.c[best];
        primary_[i] = pc;
        if (!isLetter(pc)) { sep_[i] = 1; continue; }
        acost_[i][pc - 'a'] = 0.f;
        if (!spatial) continue;
        float pmax = std::max(k.p[best], 1e-6f);
        for (int j = 0; j < k.n && j < 3; j++) {
            if (j == best || !isLetter(k.c[j])) continue;
            float rel = k.p[j] / pmax;
            if (rel < 0.06f) continue;
            float cost = std::log(rel) * scale + kNeighborBase * std::min(scale, 1.0f);
            float& slot = acost_[i][k.c[j] - 'a'];
            if (cost > slot) slot = cost;
        }
    }
}

void Engine::addTok(int pos, int end, int single, const Mask* mask, float cost, uint8_t flags) {
    auto& v = tokens_[pos];
    if (single >= 0) {
        for (auto& t : v) {
            if (t.single == single && t.end == end) {
                if (cost > t.cost) { t.cost = cost; t.flags = flags; }
                return;
            }
        }
    }
    Token t;
    t.end = static_cast<uint16_t>(end);
    t.single = static_cast<int16_t>(single);
    t.mask = mask;
    t.cost = cost;
    t.flags = flags;
    v.push_back(t);
}

void Engine::addSyllableTokens(int pos, int end, int sid, float cost, uint8_t flags) {
    addTok(pos, end, sid, nullptr, cost, flags);
    for (uint16_t alt : fuzzyAlts_[sid]) addTok(pos, end, alt, nullptr, cost + kFuzzyCost, flags | 4);
}

void Engine::genTokens() {
    const SyllableTable& T = SyllableTable::get();
    tokens_.resize(n_ + 1);
    for (auto& v : tokens_) v.clear();
    dynMasks_.clear();
    if (set_.scheme == kSchemeXiaohe) {
        const Xiaohe& X = Xiaohe::get();
        for (int i = 0; i < n_; i++) {
            if (sep_[i]) continue;
            for (int a = 0; a < 26; a++) {
                float c1 = acost_[i][a];
                if (c1 < -1e8f) continue;
                char k1 = static_cast<char>('a' + a);
                if (i + 1 < n_ && !sep_[i + 1]) {
                    for (int b = 0; b < 26; b++) {
                        float c2 = acost_[i + 1][b];
                        if (c2 < -1e8f) continue;
                        const auto& codes = X.codes(k1, static_cast<char>('a' + b));
                        float cost = c1 + c2;
                        for (size_t ci = 0; ci < codes.size(); ci++) {
                            // the shorter spelling of an ambiguous code (lo vs luo) is a rare reading
                            float extra = ci > 0 ? -1.5f : 0.f;
                            addSyllableTokens(i, i + 2, codes[ci], cost + extra, cost < -1e-6f ? 1 : 0);
                        }
                    }
                }
                if (set_.jianpin) {
                    int ini = X.initialOfKey(k1);
                    uint8_t fl = 2 | (c1 < -1e-6f ? 1 : 0);
                    if (ini >= 0) addTok(i, i + 1, -1, &iniTok_[ini], kJianpin + c1, fl);
                    else if (X.isZeroKey(k1)) addTok(i, i + 1, -1, &zeroMask_[a], kJianpin + c1, fl);
                }
            }
        }
        return;
    }
    // ---- full pinyin ----
    for (int i = 0; i < n_; i++) {
        if (sep_[i]) continue;
        for (int a = 0; a < 26; a++) {
            float c0 = acost_[i][a];
            if (c0 < -1e8f) continue;
            for (uint16_t sid : T.byFirst(static_cast<char>('a' + a))) {
                const Syl& sy = T.at(sid);
                if (i + sy.len > n_) continue;
                float cost = c0;
                bool ok = true;
                for (int k = 1; k < sy.len; k++) {
                    float v = acost_[i + k][sy.s[k] - 'a'];
                    if (v < -1e8f) { ok = false; break; }
                    cost += v;
                }
                if (!ok) continue;
                addSyllableTokens(i, i + sy.len, sid, cost, cost < -1e-6f ? 1 : 0);
            }
            if (set_.jianpin) {
                int ini = T.initialOfLetter(static_cast<char>('a' + a));
                if (ini >= 0) addTok(i, i + 1, -1, &iniTok_[ini], kJianpin + c0, 2 | (c0 < -1e-6f ? 1 : 0));
            }
        }
        if (set_.jianpin && i + 1 < n_ && primary_[i + 1] == 'h') {
            int ini = T.initialOfPair(primary_[i], 'h');
            if (ini >= 0 && acost_[i][primary_[i] - 'a'] == 0.f)
                addTok(i, i + 2, -1, &iniTok_[ini], kJianpin, 2);
        }
        if (set_.correction && set_.spatialScale > 0.01f) {
            for (int L = 3; L <= 6 && i + L <= n_; L++) {
                char buf[8];
                bool ok = true;
                for (int k = 0; k < L; k++) {
                    if (!isLetter(primary_[i + k]) || sep_[i + k]) { ok = false; break; }
                    buf[k] = primary_[i + k];
                }
                if (!ok) break;
                const auto* v = T.transposed(SyllableTable::pack(buf, L));
                if (v) for (uint16_t sid : *v) addTok(i, i + L, sid, nullptr, kTransCost, 1);
            }
        }
        // incomplete trailing syllable (e.g. "zho" -> zhong, "nia" -> nian)
        int L = n_ - i;
        if (L >= 2 && L <= 6) {
            char buf[8];
            bool ok = true;
            for (int k = 0; k < L; k++) {
                if (!isLetter(primary_[i + k]) || sep_[i + k]) { ok = false; break; }
                buf[k] = primary_[i + k];
            }
            if (ok && T.find(buf, L) < 0 && T.isPrefix(buf, L)) {
                dynMasks_.emplace_back();
                T.prefixMask(buf, L, dynMasks_.back());
                addTok(i, n_, -1, &dynMasks_.back(), kPrefixCost, 8);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Trie expansion
// ---------------------------------------------------------------------------

static inline uint8_t lwFlags(uint8_t tokFlags) {
    uint8_t f = 0;
    if (tokFlags & 1) f |= 2;
    if (tokFlags & 2) f |= 4;
    if (tokFlags & (4 | 8)) f |= 8;
    return f;
}

void Engine::emitStatic(const DictNode& nd, const Frame& f, int start, int end) {
    if (!nd.wordCount) return;
    int cap = f.depth == 1 ? (start == 0 ? 90 : 14) : (end >= n_ ? 40 : 16);
    int cnt = std::min<int>(cap, nd.wordCount);
    uint32_t sylOff = static_cast<uint32_t>(sylPool_.size());
    sylPool_.insert(sylPool_.end(), f.syls, f.syls + f.depth);
    for (int k = 0; k < cnt; k++) {
        const DictWord& w = dict_.words()[nd.wordStart + k];
        LWord lw;
        lw.start = static_cast<uint16_t>(start);
        lw.end = static_cast<uint16_t>(end);
        lw.nsyl = f.depth;
        lw.flags = lwFlags(f.flags);
        lw.lnP = w.weight / 1024.f - lnTotal_;
        lw.cost = f.cost;
        lw.id = nd.wordStart + k;
        lw.sylOff = sylOff;
        lw.key = fnv1a(dict_.pool() + w.textOff, w.textLen);
        lw_.push_back(lw);
    }
}

void Engine::emitUser(int nodeIdx, const Frame& f, int start, int end) {
    const auto& ws = user_.node(nodeIdx).words;
    if (ws.empty()) return;
    uint32_t sylOff = static_cast<uint32_t>(sylPool_.size());
    sylPool_.insert(sylPool_.end(), f.syls, f.syls + f.depth);
    for (int idx : ws) {
        const UWord& uw = user_.word(idx);
        float b = user_.boost(uw, now_);
        if (b <= 0.f) continue;
        LWord lw;
        lw.start = static_cast<uint16_t>(start);
        lw.end = static_cast<uint16_t>(end);
        lw.nsyl = f.depth;
        lw.flags = lwFlags(f.flags) | 1;
        lw.lnP = uw.baseLn + b;
        lw.cost = f.cost;
        lw.id = static_cast<uint32_t>(idx);
        lw.sylOff = sylOff;
        lw.key = uw.key;
        lw_.push_back(lw);
    }
}

void Engine::emitCompletions(uint32_t node, const Frame& f) {
    // Greedy best-first descent into the subtree: offers a few frequent longer words (input is their prefix).
    const DictNode& nd = dict_.nodes()[node];
    if (nd.edgeCount == 0) return;
    struct C { uint16_t w; uint32_t e; };
    C top[3];
    int nt = 0;
    const DictEdge* es = dict_.edges() + nd.edgeStart;
    for (uint32_t i = 0; i < nd.edgeCount; i++) {
        uint16_t w = dict_.nodes()[es[i].child].maxW;
        if (nt < 3) { top[nt++] = {w, i}; }
        else {
            int mn = 0;
            for (int k = 1; k < 3; k++) if (top[k].w < top[mn].w) mn = k;
            if (w > top[mn].w) top[mn] = {w, i};
        }
    }
    for (int t = 0; t < nt; t++) {
        uint32_t cur = es[top[t].e].child;
        uint16_t path[12];
        std::memcpy(path, f.syls, sizeof(uint16_t) * f.depth);
        int depth = f.depth;
        path[depth++] = es[top[t].e].syl;
        for (int guard = 0; guard < 6; guard++) {
            const DictNode& c = dict_.nodes()[cur];
            if (c.wordCount > 0 && dict_.words()[c.wordStart].weight == c.maxW) {
                const DictWord& w = dict_.words()[c.wordStart];
                LWord lw;
                lw.start = 0;
                lw.end = static_cast<uint16_t>(n_);
                lw.nsyl = static_cast<uint8_t>(depth);
                lw.flags = 0;
                lw.lnP = w.weight / 1024.f - lnTotal_;
                lw.cost = f.cost - 1.5f;
                lw.id = c.wordStart;
                lw.sylOff = static_cast<uint32_t>(sylPool_.size());
                sylPool_.insert(sylPool_.end(), path, path + depth);
                lw.key = fnv1a(dict_.pool() + w.textOff, w.textLen);
                compl_.push_back(lw);
                break;
            }
            const DictEdge* ce = dict_.edges() + c.edgeStart;
            bool moved = false;
            for (uint32_t i = 0; i < c.edgeCount; i++) {
                if (dict_.nodes()[ce[i].child].maxW == c.maxW && depth < 11) {
                    cur = ce[i].child;
                    path[depth++] = ce[i].syl;
                    moved = true;
                    break;
                }
            }
            if (!moved) break;
        }
    }
}

template <class View>
void Engine::expand(View& v, int start, bool user) {
    stack_.clear();
    Frame root;
    root.node = v.root();
    root.pos = static_cast<uint16_t>(start);
    root.depth = 0;
    root.flags = 0;
    root.cost = 0.f;
    stack_.push_back(root);
    budget_ = user ? 4000 : (start == 0 ? 1600 : 600);
    struct M { uint16_t syl; uint32_t child; uint16_t w; };
    M ms[520];
    while (!stack_.empty()) {
        if (--budget_ < 0) break;
        if ((budget_ & 63) == 0 && gen_.load(std::memory_order_relaxed) != curGen_) { aborted_ = true; return; }
        Frame f = stack_.back();
        stack_.pop_back();
        if (f.depth > 0) {
            if constexpr (std::is_same<View, StaticView>::value) {
                emitStatic(dict_.nodes()[f.node], f, start, f.pos);
                if (f.pos >= n_ && set_.completion && start == 0 && f.depth >= 1 && !(f.flags & 2)) emitCompletions(f.node, f);
            } else {
                emitUser(static_cast<int>(f.node), f, start, f.pos);
            }
        }
        if (f.depth >= View::maxDepth || f.pos >= n_) continue;
        for (const Token& t : tokens_[f.pos]) {
            Frame nf = f;
            nf.depth = static_cast<uint8_t>(f.depth + 1);
            nf.cost = f.cost + t.cost;
            nf.flags = f.flags | t.flags;
            int np = t.end;
            if (np < n_ && sep_[np]) np++;
            nf.pos = static_cast<uint16_t>(np);
            if (t.single >= 0) {
                uint32_t child;
                if (!v.exact(f.node, static_cast<uint16_t>(t.single), &child)) continue;
                nf.node = child;
                nf.syls[f.depth] = static_cast<uint16_t>(t.single);
                stack_.push_back(nf);
            } else {
                int cnt = 0;
                v.each(f.node, [&](uint16_t syl, uint32_t child, uint16_t w) {
                    if (t.mask->test(syl) && cnt < 512) ms[cnt++] = {syl, child, w};
                });
                int keep = user ? cnt : (f.depth == 0 ? 24 : 8);
                if (cnt > keep) {
                    std::nth_element(ms, ms + keep, ms + cnt, [](const M& a, const M& b) { return a.w > b.w; });
                    cnt = keep;
                }
                std::sort(ms, ms + cnt, [](const M& a, const M& b) { return a.w < b.w; });  // best pushed last -> popped first
                for (int k = 0; k < cnt; k++) {
                    nf.node = ms[k].child;
                    nf.syls[f.depth] = ms[k].syl;
                    stack_.push_back(nf);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Viterbi beam search
// ---------------------------------------------------------------------------

float Engine::transBonus(const Hyp& h, const LWord& w, uint32_t now) const {
    float b = 0.f;
    if (h.id != kNone && !(w.flags & 1)) {
        uint16_t bg = dict_.bigram(h.id, w.id);
        if (bg) {
            float pairLn = bg / 1024.f;
            float prevLn = dict_.words()[h.id].weight / 1024.f;
            float cond = std::min(-0.05f, pairLn - prevLn);
            float gain = cond - w.lnP;
            if (gain > 0) b += std::min(5.f, gain * 0.7f);
        }
    }
    if (h.key && user_.hasBigrams()) b += user_.bigramBonus(h.key, w.key, now);
    return b;
}

void Engine::viterbi(bool strict, std::vector<std::vector<Hyp>>& hyps) {
    hyps.assign(n_ + 1, std::vector<Hyp>());
    Hyp h0{0.f, -1, -1, -1, ctxKey_, ctxId_};
    hyps[0].push_back(h0);
    auto insert = [&](std::vector<Hyp>& v, const Hyp& nh) {
        for (auto& e : v) {
            if (e.key == nh.key) {
                if (nh.score > e.score) e = nh;
                return;
            }
        }
        if (static_cast<int>(v.size()) < kBeam) { v.push_back(nh); return; }
        int worst = 0;
        for (int i = 1; i < static_cast<int>(v.size()); i++) if (v[i].score < v[worst].score) worst = i;
        if (nh.score > v[worst].score) v[worst] = nh;
    };
    for (int pos = 0; pos < n_; pos++) {
        auto& v = hyps[pos];
        if (v.empty()) continue;
        if (gen_.load(std::memory_order_relaxed) != curGen_) { aborted_ = true; return; }
        std::sort(v.begin(), v.end(), [](const Hyp& a, const Hyp& b) { return a.score > b.score; });
        for (int hi = 0; hi < static_cast<int>(v.size()); hi++) {
            const Hyp& h = v[hi];
            for (int li : byStart_[pos]) {
                const LWord& w = lw_[li];
                if (strict && (w.flags & 6)) continue;
                float sc = h.score + w.lnP + w.cost + transBonus(h, w, now_) - kWordPenalty;
                Hyp nh{sc, li, static_cast<int16_t>(pos), static_cast<int16_t>(hi), w.key, (w.flags & 1) ? kNone : w.id};
                insert(hyps[w.end], nh);
            }
        }
    }
    std::sort(hyps[n_].begin(), hyps[n_].end(), [](const Hyp& a, const Hyp& b) { return a.score > b.score; });
}

std::string Engine::wordText(const LWord& w) const {
    if (w.flags & 1) return user_.word(static_cast<int>(w.id)).text;
    const DictWord& dw = dict_.words()[w.id];
    return std::string(dict_.pool() + dw.textOff, dw.textLen);
}

void Engine::pushCand(Result& r, const std::string& text, const uint16_t* syls, int ns, int consumed, uint8_t flags,
                      float score, float baseLn, uint64_t key, uint32_t id, std::unordered_set<uint64_t>& seen,
                      bool dedupe) {
    if (dedupe && !seen.insert(key).second) return;
    Candidate c;
    c.textOff = static_cast<uint32_t>(r.pool.size());
    c.textLen = static_cast<uint16_t>(text.size());
    r.pool += text;
    c.consumed = static_cast<uint16_t>(consumed);
    c.sylCount = static_cast<uint8_t>(ns);
    c.flags = flags;
    c.sylOff = static_cast<uint32_t>(r.syls.size());
    for (int i = 0; i < ns; i++) r.syls.push_back(syls[i]);
    c.score = score;
    c.baseLn = baseLn;
    c.key = key;
    c.wordId = id;
    r.cands.push_back(c);
}

std::shared_ptr<Result> Engine::decode(const KeyStroke* keys, int n, uint64_t gen) {
    auto res = std::make_shared<Result>();
    res->rawLen = n;
    if (n <= 0) return res;
    if (n > 60) n = 60;
    curGen_ = gen;
    aborted_ = false;
    now_ = static_cast<uint32_t>(std::time(nullptr));
    if (gen_.load() != gen) return nullptr;

    prepareInput(keys, n);
    genTokens();
    lw_.clear();
    sylPool_.clear();
    compl_.clear();
    if (dict_.isOpen()) {
        StaticView sv{dict_};
        for (int i = 0; i < n_ && !aborted_; i++) {
            if (sep_[i] || tokens_[i].empty()) continue;
            expand(sv, i, false);
        }
    }
    if (!aborted_ && !user_.empty()) {
        UserView uv{user_};
        for (int i = 0; i < n_ && !aborted_; i++) {
            if (sep_[i] || tokens_[i].empty()) continue;
            expand(uv, i, true);
        }
    }
    if (aborted_ || gen_.load() != gen) return nullptr;

    byStart_.resize(n_ + 1);
    for (auto& v : byStart_) v.clear();
    for (int i = 0; i < static_cast<int>(lw_.size()); i++) byStart_[lw_[i].start].push_back(i);

    std::vector<std::vector<Hyp>> hypsA, hypsB;
    viterbi(true, hypsA);
    if (aborted_) return nullptr;
    viterbi(false, hypsB);
    if (aborted_ || gen_.load() != gen) return nullptr;

    std::unordered_set<uint64_t> seen;
    std::string text;
    std::vector<uint16_t> syls;
    auto buildSentence = [&](const std::vector<std::vector<Hyp>>& H, int endPos, int rank, int minWords) -> bool {
        if (static_cast<int>(H[endPos].size()) <= rank) return false;
        if (rank > 0 && H[endPos][rank].score < H[endPos][0].score - 3.0f) return false;
        std::vector<int> path;
        int pos = endPos, idx = rank;
        while (pos > 0) {
            const Hyp& h = H[pos][idx];
            path.push_back(h.lw);
            int pp = h.prevPos, pi = h.prevIdx;
            pos = pp;
            idx = pi;
        }
        if (static_cast<int>(path.size()) < minWords) return false;
        std::reverse(path.begin(), path.end());
        text.clear();
        syls.clear();
        float base = 0.f;
        uint8_t flags = kCandSentence;
        for (int li : path) {
            const LWord& w = lw_[li];
            text += wordText(w);
            syls.insert(syls.end(), sylPool_.begin() + w.sylOff, sylPool_.begin() + w.sylOff + w.nsyl);
            base += (w.flags & 1) ? user_.word(static_cast<int>(w.id)).baseLn : w.lnP;
            if (w.flags & 1) flags |= kCandUser;
            if (w.flags & 2) flags |= kCandCorrected;
        }
        float score = H[endPos][rank].score;
        uint64_t key = fnv1a(text.data(), text.size());
        uint32_t wid = path.size() == 1 && !(lw_[path[0]].flags & 1) ? lw_[path[0]].id : kNone;
        pushCand(*res, text, syls.data(), static_cast<int>(syls.size()), endPos, flags, score, base, key, wid, seen);
        return true;
    };

    res->fullCover = !hypsB[n_].empty();
    int sentences = 0;
    if (!hypsA[n_].empty()) {
        for (int r = 0; r < 2 && sentences < 2; r++) if (buildSentence(hypsA, n_, r, r == 0 ? 1 : 2)) sentences++;
    }
    if (res->fullCover) {
        for (int r = 0; r < 4 && sentences < 3; r++) if (buildSentence(hypsB, n_, r, (r == 0 && sentences == 0) ? 1 : 2)) sentences++;
    } else {
        // no complete cover: offer the best path over the longest reachable prefix
        for (int p = n_ - 1; p > 0; p--) {
            if (!hypsB[p].empty()) { buildSentence(hypsB, p, 0, 2); break; }
        }
    }

    // whole-input matches, prefix matches
    std::vector<int> whole, prefix;
    for (int i = 0; i < static_cast<int>(lw_.size()); i++) {
        const LWord& w = lw_[i];
        if (w.start != 0) continue;
        (w.end >= n_ ? whole : prefix).push_back(i);
    }
    auto wscore = [&](const LWord& w) { return w.lnP + w.cost - ((w.flags & 2) ? 30.f : 0.f); };
    std::sort(whole.begin(), whole.end(), [&](int a, int b) { return wscore(lw_[a]) > wscore(lw_[b]); });
    int added = 0;
    for (int i : whole) {
        if (added >= 70) break;
        const LWord& w = lw_[i];
        std::string t = wordText(w);
        size_t before = res->cands.size();
        pushCand(*res, t, sylPool_.data() + w.sylOff, w.nsyl, w.end, static_cast<uint8_t>(((w.flags & 1) ? kCandUser : 0) | ((w.flags & 2) ? kCandCorrected : 0)),
                 w.lnP + w.cost, (w.flags & 1) ? user_.word(static_cast<int>(w.id)).baseLn : w.lnP, w.key,
                 (w.flags & 1) ? kNone : w.id, seen);
        if (res->cands.size() > before) added++;
    }
    // completions (input is a prefix of the word's reading)
    if (!compl_.empty()) {
        std::sort(compl_.begin(), compl_.end(), [](const LWord& a, const LWord& b) { return a.lnP + a.cost > b.lnP + b.cost; });
        int c = 0;
        for (const LWord& w : compl_) {
            if (c >= 4) break;
            size_t before = res->cands.size();
            pushCand(*res, wordText(w), sylPool_.data() + w.sylOff, w.nsyl, n_, kCandCompletion, w.lnP + w.cost, w.lnP, w.key, w.id, seen);
            if (res->cands.size() > before) c++;
        }
    }
    auto pscore = [&](const LWord& w) {
        return w.lnP + w.cost + 2.5f * (w.nsyl - 1) - ((w.flags & 2) ? 8.f : 0.f) - ((w.flags & 4) ? 3.f : 0.f);
    };
    std::sort(prefix.begin(), prefix.end(), [&](int a, int b) { return pscore(lw_[a]) > pscore(lw_[b]); });
    added = 0;
    for (int i : prefix) {
        if (added >= 90) break;
        const LWord& w = lw_[i];
        size_t before = res->cands.size();
        pushCand(*res, wordText(w), sylPool_.data() + w.sylOff, w.nsyl, w.end, static_cast<uint8_t>(((w.flags & 1) ? kCandUser : 0) | ((w.flags & 2) ? kCandCorrected : 0)),
                 w.lnP + w.cost, (w.flags & 1) ? user_.word(static_cast<int>(w.id)).baseLn : w.lnP, w.key,
                 (w.flags & 1) ? kNone : w.id, seen);
        if (res->cands.size() > before) added++;
    }
    // raw letters last
    std::string raw;
    for (int i = 0; i < n_; i++) if (primary_[i]) raw.push_back(primary_[i]);
    if (!raw.empty()) pushCand(*res, raw, nullptr, 0, n_, kCandRaw, -99.f, -99.f, fnv1a(raw.data(), raw.size()) ^ 0x55AA55AAULL, kNone, seen, false);
    return res;
}

// ---------------------------------------------------------------------------
// Learning
// ---------------------------------------------------------------------------

void Engine::commit(const std::vector<CommitSeg>& segs) {
    uint32_t now = static_cast<uint32_t>(std::time(nullptr));
    lastCommitUndo_.clear();
    lastCommitPrevKey_ = ctxKey_;
    lastCommitPrevId_ = ctxId_;
    uint64_t prevKey = ctxKey_;
    int learnable = 0;
    std::string ctext;
    std::vector<uint16_t> csyls;
    for (const CommitSeg& s : segs) {
        if (s.raw || s.text.empty()) { prevKey = 0; continue; }
        if (set_.learning) {
            if (!s.weak && !s.syls.empty()) {
                if (user_.addWord(s.syls, s.text, 1.0f, s.baseLn, now) >= 0)
                    lastCommitUndo_.push_back({s.syls, s.text, -1.0f, 0, 0, false});
                learnable++;
                ctext += s.text;
                csyls.insert(csyls.end(), s.syls.begin(), s.syls.end());
            }
            if (prevKey && s.key) {
                user_.addBigram(prevKey, s.key, 1.0f, now);
                lastCommitUndo_.push_back({{}, {}, -1.0f, prevKey, s.key, true});
            }
        }
        prevKey = s.key;
    }
    if (set_.learning && segs.size() >= 2 && learnable == static_cast<int>(segs.size()) && csyls.size() <= 12 &&
        !ctext.empty()) {
        float base = -9.f - 0.5f * static_cast<float>(csyls.size());
        if (user_.addWord(csyls, ctext, 1.0f, base, now) >= 0)
            lastCommitUndo_.push_back({csyls, ctext, -1.0f, 0, 0, false});
    }
    // context for the next decode
    const CommitSeg* last = nullptr;
    for (const CommitSeg& s : segs) if (!s.text.empty()) last = &s;
    if (last && !last->raw) { ctxKey_ = last->key; ctxId_ = last->wordId; }
    else resetContext();
}

bool Engine::rollbackLastCommit() {
    if (lastCommitUndo_.empty()) return false;
    uint32_t now = static_cast<uint32_t>(std::time(nullptr));
    for (const UndoOp& u : lastCommitUndo_) {
        if (u.bigram) user_.addBigram(u.k1, u.k2, u.delta, now);
        else user_.addWord(u.syls, u.text, u.delta, -12.f, now);
    }
    lastCommitUndo_.clear();
    ctxKey_ = lastCommitPrevKey_;
    ctxId_ = lastCommitPrevId_;
    return true;
}

bool Engine::deleteUserWord(const std::vector<uint16_t>& syls, const std::string& text) {
    return user_.deleteWord(syls, text);
}

void Engine::resetUserData() {
    user_.reset(true);
    lastCommitUndo_.clear();
    resetContext();
}

// ---------------------------------------------------------------------------
// Display helpers
// ---------------------------------------------------------------------------

std::string Engine::quickSegment(const char* s, int n, int scheme, bool expandShuangpin) const {
    const SyllableTable& T = SyllableTable::get();
    std::string out;
    auto emit = [&](const std::string& piece) {
        if (!out.empty()) out.push_back(' ');
        out += piece;
    };
    int i = 0;
    while (i < n) {
        if (s[i] == '\'') { i++; continue; }
        int j = i;
        while (j < n && s[j] != '\'') j++;
        int len = j - i;
        const char* r = s + i;
        if (scheme == kSchemeXiaohe) {
            const Xiaohe& X = Xiaohe::get();
            for (int k = 0; k < len; k += 2) {
                if (k + 1 < len) {
                    std::string piece;
                    if (expandShuangpin && r[k] >= 'a' && r[k] <= 'z' && r[k + 1] >= 'a' && r[k + 1] <= 'z') {
                        const auto& codes = X.codes(r[k], r[k + 1]);
                        if (!codes.empty()) piece = T.at(codes[0]).s;
                    }
                    if (piece.empty()) piece.assign(r + k, 2);
                    emit(piece);
                } else {
                    std::string piece(1, r[k]);
                    if (expandShuangpin && r[k] >= 'a' && r[k] <= 'z') {
                        int ini = X.initialOfKey(r[k]);
                        if (ini >= 0) piece = T.initialText(ini);
                    }
                    emit(piece);
                }
            }
        } else {
            if (len > 80) { emit(std::string(r, len)); i = j; continue; }
            std::vector<int> best(len + 1, 1 << 28), from(len + 1, -1);
            best[0] = 0;
            for (int e = 1; e <= len; e++) {
                for (int b = std::max(0, e - 6); b < e; b++) {
                    if (best[b] >= (1 << 28)) continue;
                    int L = e - b;
                    int cost;
                    if (r[b] < 'a' || r[b] > 'z') cost = 40;
                    else if (T.find(r + b, L) >= 0) cost = 10;
                    else if (L == 1 && T.initialOfLetter(r[b]) >= 0) cost = 18;
                    else if (L == 2 && T.initialOfPair(r[b], r[b + 1]) >= 0) cost = 17;
                    else if (e == len && L >= 2 && T.isPrefix(r + b, L)) cost = 12;
                    else if (L == 1) cost = 30;
                    else continue;
                    if (best[b] + cost <= best[e]) { best[e] = best[b] + cost; from[e] = b; }
                }
            }
            std::vector<std::pair<int, int>> pieces;
            for (int e = len; e > 0; e = from[e]) {
                if (from[e] < 0) { pieces.clear(); pieces.push_back({0, len}); break; }
                pieces.push_back({from[e], e});
            }
            std::reverse(pieces.begin(), pieces.end());
            for (auto& p : pieces) emit(std::string(r + p.first, p.second - p.first));
        }
        i = j;
    }
    return out;
}

void Engine::nextLetterPrior(const char* s, int n, int scheme, float out[26]) const {
    const SyllableTable& T = SyllableTable::get();
    int start = n;
    while (start > 0 && s[start - 1] != '\'') start--;
    int tail = n - start;
    if (scheme == kSchemeXiaohe) {
        const Xiaohe& X = Xiaohe::get();
        bool second = (tail & 1) == 1;
        uint32_t valid = second ? X.validSecond(s[n - 1]) : 0xFFFFFFFFu;
        for (int c = 0; c < 26; c++) out[c] = (valid >> c) & 1 ? 1.f : 0.45f;
        return;
    }
    char buf[16];
    int tl = std::min(tail, 5);
    std::memcpy(buf, s + n - tl, tl);
    for (int c = 0; c < 26; c++) {
        buf[tl] = static_cast<char>('a' + c);
        bool cont = false;
        int total = tl + 1;
        for (int L = 2; L <= total && !cont; L++) {
            if (T.isPrefix(buf + (total - L), L)) cont = true;
        }
        bool startOk = !T.byFirst(static_cast<char>('a' + c)).empty();
        out[c] = cont ? 1.f : (startOk ? 0.8f : 0.35f);
    }
}

}  // namespace ime
