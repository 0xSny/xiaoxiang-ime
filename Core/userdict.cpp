#include "userdict.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <ctime>

namespace ime {

namespace {
constexpr double kHalfLifeSec = 30.0 * 86400.0;
constexpr size_t kCompactBytes = 96 * 1024;
constexpr size_t kMaxBigrams = 30000;

std::string wordKey(const std::vector<uint16_t>& syls, const std::string& text) {
    std::string k(reinterpret_cast<const char*>(syls.data()), syls.size() * 2);
    k.push_back('\x01');
    k += text;
    return k;
}

struct Reader {
    const uint8_t* p;
    size_t n;
    size_t i = 0;
    bool ok = true;
    uint16_t u16() { if (i + 2 > n) { ok = false; return 0; } uint16_t v = p[i] | (p[i + 1] << 8); i += 2; return v; }
    uint32_t u32() { if (i + 4 > n) { ok = false; return 0; } uint32_t v = 0; for (int k = 0; k < 4; k++) v |= static_cast<uint32_t>(p[i + k]) << (8 * k); i += 4; return v; }
    uint64_t u64() { if (i + 8 > n) { ok = false; return 0; } uint64_t v = 0; for (int k = 0; k < 8; k++) v |= static_cast<uint64_t>(p[i + k]) << (8 * k); i += 8; return v; }
    float f32() { uint32_t u = u32(); float f; std::memcpy(&f, &u, 4); return f; }
    uint8_t u8() { if (i + 1 > n) { ok = false; return 0; } return p[i++]; }
};
}  // namespace

UserDict::UserDict() { nodes_.emplace_back(); }

int UserDict::child(int node, uint16_t syl) const {
    const auto& e = nodes_[node].edges;
    int lo = 0, hi = static_cast<int>(e.size()) - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        if (e[mid].first == syl) return e[mid].second;
        if (e[mid].first < syl) lo = mid + 1; else hi = mid - 1;
    }
    return -1;
}

float UserDict::effective(float count, uint32_t last, uint32_t now) const {
    double dt = now > last ? static_cast<double>(now - last) : 0.0;
    return static_cast<float>(count * std::exp2(-dt / kHalfLifeSec));
}

float UserDict::boost(const UWord& w, uint32_t now) const {
    float eff = effective(w.count, w.last, now);
    if (eff < 0.08f) return 0.f;
    float b = 3.5f + 1.5f * std::log(1.f + eff);
    return std::min(b, 9.f);
}

float UserDict::bigramBonus(uint64_t k1, uint64_t k2, uint32_t now) const {
    auto it = bigrams_.find(mixPair(k1, k2));
    if (it == bigrams_.end()) return 0.f;
    float eff = effective(it->second.count, it->second.last, now);
    if (eff < 0.08f) return 0.f;
    return std::min(3.5f, 1.0f + 0.8f * std::log(1.f + eff));
}

int UserDict::find(const std::vector<uint16_t>& syls, const std::string& text) const {
    auto it = index_.find(wordKey(syls, text));
    if (it == index_.end() || !words_[it->second].alive) return -1;
    return it->second;
}

void UserDict::insertNode(int idx) {
    int cur = 0;
    for (uint16_t s : words_[idx].syls) {
        int c = child(cur, s);
        if (c < 0) {
            c = static_cast<int>(nodes_.size());
            nodes_.emplace_back();
            auto& e = nodes_[cur].edges;
            auto pos = std::lower_bound(e.begin(), e.end(), std::make_pair(s, 0),
                                        [](const std::pair<uint16_t, int>& a, const std::pair<uint16_t, int>& b) { return a.first < b.first; });
            e.insert(pos, std::make_pair(s, c));
        }
        cur = c;
    }
    nodes_[cur].words.push_back(idx);
}

void UserDict::removeFromNode(int idx) {
    int cur = 0;
    for (uint16_t s : words_[idx].syls) {
        cur = child(cur, s);
        if (cur < 0) return;
    }
    auto& w = nodes_[cur].words;
    w.erase(std::remove(w.begin(), w.end(), idx), w.end());
}

void UserDict::logWord(uint8_t op, const std::vector<uint16_t>& syls, const std::string& text, float val,
                       uint32_t ts, float baseLn) {
    std::vector<uint8_t> pl;
    if (op == 1 || op == 5) { putF32(pl, val); putU32(pl, ts); putF32(pl, baseLn); }
    pl.push_back(static_cast<uint8_t>(syls.size()));
    for (uint16_t s : syls) putU16(pl, s);
    putU16(pl, static_cast<uint16_t>(text.size()));
    pl.insert(pl.end(), text.begin(), text.end());
    appendRecord(pending_, op, pl);
}

void UserDict::appendRecord(std::vector<uint8_t>& buf, uint8_t op, const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> body;
    body.push_back(op);
    body.insert(body.end(), payload.begin(), payload.end());
    putU32(buf, static_cast<uint32_t>(body.size()));
    buf.insert(buf.end(), body.begin(), body.end());
    putU32(buf, fnv32(body.data(), body.size()));
}

int UserDict::addWord(const std::vector<uint16_t>& syls, const std::string& text, float delta, float baseLn,
                      uint32_t now, bool log) {
    if (syls.empty() || syls.size() > 12 || text.empty() || text.size() > 120) return -1;
    std::string k = wordKey(syls, text);
    auto it = index_.find(k);
    int idx;
    if (it == index_.end()) {
        if (delta <= 0) return -1;
        UWord w;
        w.syls = syls;
        w.text = text;
        w.count = delta;
        w.last = now;
        w.baseLn = baseLn;
        w.key = fnv1a(text.data(), text.size());
        idx = static_cast<int>(words_.size());
        words_.push_back(std::move(w));
        index_[k] = idx;
        insertNode(idx);
        aliveWords_++;
    } else {
        idx = it->second;
        UWord& w = words_[idx];
        if (!w.alive) {
            if (delta <= 0) return -1;
            w.alive = true;
            w.count = delta;
            w.baseLn = baseLn;
            insertNode(idx);
            aliveWords_++;
        } else {
            // fold decay into the stored count before adding
            w.count = effective(w.count, w.last, now) + delta;
            if (delta > 0) w.baseLn = baseLn;
        }
        w.last = now;
        if (w.count < 0.05f) {
            w.alive = false;
            removeFromNode(idx);
            aliveWords_--;
        }
    }
    if (log && !replaying_) logWord(1, syls, text, delta, now, baseLn);
    return idx;
}

void UserDict::addBigram(uint64_t k1, uint64_t k2, float delta, uint32_t now, bool log) {
    if (k1 == 0 || k2 == 0) return;
    uint64_t k = mixPair(k1, k2);
    auto it = bigrams_.find(k);
    if (it == bigrams_.end()) {
        if (delta <= 0) return;
        bigrams_[k] = BV{delta, now, k1, k2};
    } else {
        it->second.count = effective(it->second.count, it->second.last, now) + delta;
        it->second.last = now;
        if (it->second.count < 0.05f) bigrams_.erase(it);
    }
    if (log && !replaying_) {
        std::vector<uint8_t> pl;
        putU64(pl, k1); putU64(pl, k2); putF32(pl, delta); putU32(pl, now);
        appendRecord(pending_, 2, pl);
    }
}

bool UserDict::deleteWord(const std::vector<uint16_t>& syls, const std::string& text, bool log) {
    int idx = find(syls, text);
    if (idx < 0) return false;
    words_[idx].alive = false;
    removeFromNode(idx);
    aliveWords_--;
    if (log && !replaying_) logWord(3, syls, text, 0, 0, 0);
    return true;
}

void UserDict::reset(bool log) {
    nodes_.clear();
    nodes_.emplace_back();
    words_.clear();
    index_.clear();
    bigrams_.clear();
    aliveWords_ = 0;
    if (log && !replaying_) {
        pending_.clear();
        appendRecord(pending_, 4, {});
        // a reset must hit the disk: compact into an empty snapshot on the next flush
        logBytes_ = kCompactBytes + 1;
    }
}

void UserDict::apply(uint8_t op, const uint8_t* p, size_t n, bool) {
    Reader r{p, n};
    switch (op) {
        case 1:
        case 5: {
            float val = r.f32(); uint32_t ts = r.u32(); float base = r.f32();
            uint8_t ns = r.u8();
            std::vector<uint16_t> syls;
            for (int i = 0; i < ns; i++) syls.push_back(r.u16());
            uint16_t tl = r.u16();
            if (!r.ok || r.i + tl > n) return;
            std::string text(reinterpret_cast<const char*>(p + r.i), tl);
            if (op == 1) addWord(syls, text, val, base, ts, false);
            else {
                int idx = find(syls, text);
                if (idx >= 0) { words_[idx].count = val; words_[idx].last = ts; words_[idx].baseLn = base; }
                else if (val > 0) {
                    idx = addWord(syls, text, val, base, ts, false);
                    if (idx >= 0) { words_[idx].count = val; words_[idx].last = ts; }
                }
            }
            break;
        }
        case 2:
        case 6: {
            uint64_t h1 = r.u64(), h2 = r.u64(); float d = r.f32(); uint32_t ts = r.u32();
            if (!r.ok) return;
            if (op == 2) addBigram(h1, h2, d, ts, false);
            else bigrams_[mixPair(h1, h2)] = BV{d, ts, h1, h2};
            break;
        }
        case 3: {
            uint8_t ns = r.u8();
            std::vector<uint16_t> syls;
            for (int i = 0; i < ns; i++) syls.push_back(r.u16());
            uint16_t tl = r.u16();
            if (!r.ok || r.i + tl > n) return;
            deleteWord(syls, std::string(reinterpret_cast<const char*>(p + r.i), tl), false);
            break;
        }
        case 4: reset(false); break;
        default: break;
    }
}

static bool readAll(const std::string& path, std::vector<uint8_t>* out) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz > 0) {
        out->resize(static_cast<size_t>(sz));
        if (std::fread(out->data(), 1, out->size(), f) != out->size()) out->clear();
    }
    std::fclose(f);
    return true;
}

bool UserDict::open(const std::string& dir) {
    dir_ = dir;
    reset(false);
    pending_.clear();
    replaying_ = true;
    auto replay = [&](const std::vector<uint8_t>& buf) {
        size_t i = 0;
        while (i + 4 <= buf.size()) {
            uint32_t len = buf[i] | (buf[i + 1] << 8) | (buf[i + 2] << 16) | (static_cast<uint32_t>(buf[i + 3]) << 24);
            if (len == 0 || i + 4 + len + 4 > buf.size()) break;
            const uint8_t* body = buf.data() + i + 4;
            uint32_t crc = buf[i + 4 + len] | (buf[i + 5 + len] << 8) | (buf[i + 6 + len] << 16) | (static_cast<uint32_t>(buf[i + 7 + len]) << 24);
            if (crc != fnv32(body, len)) break;  // torn write: stop replaying
            apply(body[0], body + 1, len - 1, true);
            i += 4 + len + 4;
        }
        return i;
    };
    std::vector<uint8_t> snap, log;
    if (readAll(dir_ + "/user.snap", &snap)) replay(snap);
    if (readAll(dir_ + "/user.log", &log)) { replay(log); logBytes_ = log.size(); }
    replaying_ = false;
    return true;
}

bool UserDict::writeSnapshot() {
    uint32_t now = static_cast<uint32_t>(std::time(nullptr));
    std::vector<uint8_t> buf;
    for (const UWord& w : words_) {
        if (!w.alive) continue;
        float eff = effective(w.count, w.last, now);
        if (eff < 0.05f) continue;
        std::vector<uint8_t> pl;
        putF32(pl, w.count); putU32(pl, w.last); putF32(pl, w.baseLn);
        pl.push_back(static_cast<uint8_t>(w.syls.size()));
        for (uint16_t s : w.syls) putU16(pl, s);
        putU16(pl, static_cast<uint16_t>(w.text.size()));
        pl.insert(pl.end(), w.text.begin(), w.text.end());
        appendRecord(buf, 5, pl);
    }
    std::vector<const BV*> bs;
    for (auto& kv : bigrams_) bs.push_back(&kv.second);
    if (bs.size() > kMaxBigrams) {
        std::nth_element(bs.begin(), bs.begin() + kMaxBigrams, bs.end(), [&](const BV* a, const BV* b) {
            return effective(a->count, a->last, now) > effective(b->count, b->last, now);
        });
        bs.resize(kMaxBigrams);
    }
    for (const BV* b : bs) {
        std::vector<uint8_t> pl;
        putU64(pl, b->h1); putU64(pl, b->h2); putF32(pl, b->count); putU32(pl, b->last);
        appendRecord(buf, 6, pl);
    }
    std::string tmp = dir_ + "/user.snap.tmp", dst = dir_ + "/user.snap";
    FILE* f = std::fopen(tmp.c_str(), "wb");
    if (!f) return false;
    bool ok = buf.empty() || std::fwrite(buf.data(), 1, buf.size(), f) == buf.size();
    ok = (std::fflush(f) == 0) && ok;
    std::fclose(f);
    if (!ok) { std::remove(tmp.c_str()); return false; }
#ifdef _WIN32
    std::remove(dst.c_str());
#endif
    if (std::rename(tmp.c_str(), dst.c_str()) != 0) return false;
    std::remove((dir_ + "/user.log").c_str());
    logBytes_ = 0;
    return true;
}

bool UserDict::flush(bool force) {
    if (dir_.empty()) return false;
    if (pending_.empty() && !force && logBytes_ < kCompactBytes) return true;
    bool needCompact = force || logBytes_ + pending_.size() >= kCompactBytes;
    if (needCompact) {
        bool ok = writeSnapshot();
        if (ok) pending_.clear();
        return ok;
    }
    FILE* f = std::fopen((dir_ + "/user.log").c_str(), "ab");
    if (!f) return false;
    bool ok = std::fwrite(pending_.data(), 1, pending_.size(), f) == pending_.size();
    std::fclose(f);
    if (ok) { logBytes_ += pending_.size(); pending_.clear(); }
    return ok;
}

}  // namespace ime
