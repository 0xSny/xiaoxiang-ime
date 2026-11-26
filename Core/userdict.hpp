// Incremental self-learning user dictionary: append-only log + periodic compacted snapshot.
// Everything lives in memory while typing; disk is touched only by flush() (called when the
// keyboard is dismissed / backgrounded / idle) so typing never blocks on I/O.
#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>
#include "common.hpp"

namespace ime {

struct UWord {
    std::vector<uint16_t> syls;
    std::string text;
    float count = 0;
    uint32_t last = 0;
    float baseLn = -12.f;
    uint64_t key = 0;  // FNV of text
    bool alive = true;
};

class UserDict {
public:
    struct Node {
        std::vector<std::pair<uint16_t, int>> edges;  // sorted by syllable
        std::vector<int> words;
    };

    UserDict();

    // --- queries (decode thread) ---
    const Node& node(int i) const { return nodes_[i]; }
    int child(int node, uint16_t syl) const;
    const UWord& word(int idx) const { return words_[idx]; }
    bool empty() const { return aliveWords_ == 0; }
    bool hasBigrams() const { return !bigrams_.empty(); }
    float effective(float count, uint32_t last, uint32_t now) const;
    float boost(const UWord& w, uint32_t now) const;
    float bigramBonus(uint64_t k1, uint64_t k2, uint32_t now) const;
    size_t wordCount() const { return aliveWords_; }
    size_t bigramCount() const { return bigrams_.size(); }
    int find(const std::vector<uint16_t>& syls, const std::string& text) const;

    // --- mutation ---
    // Adds delta to the word weight (creating it when needed). Returns word index or -1.
    int addWord(const std::vector<uint16_t>& syls, const std::string& text, float delta, float baseLn,
                uint32_t now, bool log = true);
    void addBigram(uint64_t k1, uint64_t k2, float delta, uint32_t now, bool log = true);
    bool deleteWord(const std::vector<uint16_t>& syls, const std::string& text, bool log = true);
    void reset(bool log = true);

    // --- persistence ---
    bool open(const std::string& dir);
    // Writes pending records; compacts to a snapshot when the log grew large (or force is true).
    bool flush(bool force = false);
    bool dirty() const { return !pending_.empty(); }

private:
    struct BV { float count; uint32_t last; uint64_t h1, h2; };
    void insertNode(int idx);
    void removeFromNode(int idx);
    void apply(uint8_t op, const uint8_t* p, size_t n, bool fromLog);
    void appendRecord(std::vector<uint8_t>& buf, uint8_t op, const std::vector<uint8_t>& payload);
    bool writeSnapshot();
    static void putU16(std::vector<uint8_t>& b, uint16_t v) { b.push_back(v & 0xFF); b.push_back(v >> 8); }
    static void putU32(std::vector<uint8_t>& b, uint32_t v) { for (int i = 0; i < 4; i++) b.push_back((v >> (8 * i)) & 0xFF); }
    static void putU64(std::vector<uint8_t>& b, uint64_t v) { for (int i = 0; i < 8; i++) b.push_back((v >> (8 * i)) & 0xFF); }
    static void putF32(std::vector<uint8_t>& b, float f) { uint32_t u; std::memcpy(&u, &f, 4); putU32(b, u); }
    void logWord(uint8_t op, const std::vector<uint16_t>& syls, const std::string& text, float val, uint32_t ts, float baseLn);

    std::vector<Node> nodes_;
    std::vector<UWord> words_;
    std::unordered_map<std::string, int> index_;
    std::unordered_map<uint64_t, BV> bigrams_;
    size_t aliveWords_ = 0;
    std::string dir_;
    std::vector<uint8_t> pending_;
    size_t logBytes_ = 0;
    bool replaying_ = false;
};

}  // namespace ime
