// Pinyin syllable table, fuzzy-sound tables, transposition tables and the
// official Xiaohe (小鹤) double-pinyin scheme.
#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>
#include "common.hpp"

namespace ime {

constexpr int kInitialCount = 24;  // 0 = zero initial

struct Syl {
    char s[8];
    uint8_t len;
    uint8_t ini;     // initial id (0 = none)
    uint8_t iniLen;  // length of the initial in letters
};

// 11 independent fuzzy-sound groups (bit index).
enum FuzzyBit {
    kFuzzyZZh = 0, kFuzzyCCh, kFuzzySSh, kFuzzyAnAng, kFuzzyEnEng, kFuzzyInIng,
    kFuzzyIanIang, kFuzzyUanUang, kFuzzyLN, kFuzzyFH, kFuzzyRL
};

class SyllableTable {
public:
    static const SyllableTable& get();

    int count() const { return static_cast<int>(syls_.size()); }
    const Syl& at(int id) const { return syls_[id]; }
    uint32_t hash() const { return hash_; }

    // Exact lookup (canonical spelling with v = u-umlaut). -1 if absent.
    int find(const char* s, int len) const;
    // Lookup accepting aliases (lue->lve, nue->nve, u-umlaut char forms already normalized).
    int findLoose(const char* s, int len) const;

    // All syllables whose first letter is c (a..z).
    const std::vector<uint16_t>& byFirst(char c) const { return byFirst_[c - 'a']; }
    const Mask& initialMask(int ini) const { return initMask_[ini]; }
    // Initial id of a single typed letter (b p m f d t n l g k h j q x r z c s y w) or -1.
    int initialOfLetter(char c) const;
    // Initial id for a two-letter initial (zh/ch/sh) or -1.
    int initialOfPair(char a, char b) const;
    const char* initialText(int ini) const;

    // True when s[0..len) is a prefix (possibly equal) of some syllable.
    bool isPrefix(const char* s, int len) const;
    // Build mask of all syllables having s as prefix.
    void prefixMask(const char* s, int len, Mask& out) const;

    // Fuzzy alternatives: typing syllable T also matches each S in alts(T).
    std::vector<std::vector<uint16_t>> buildFuzzyAlts(uint16_t fuzzyBits) const;
    // Transposition tolerant typed strings -> syllable ids.
    const std::vector<uint16_t>* transposed(uint64_t packed) const;

    static uint64_t pack(const char* s, int len) {
        uint64_t v = 0;
        for (int i = 0; i < len && i < 8; i++) v = (v << 8) | static_cast<uint8_t>(s[i]);
        return v | (static_cast<uint64_t>(len) << 56);
    }

private:
    SyllableTable();
    std::vector<Syl> syls_;
    std::unordered_map<uint64_t, uint16_t> index_;
    std::array<std::vector<uint16_t>, 26> byFirst_;
    Mask initMask_[kInitialCount];
    std::unordered_map<uint64_t, std::vector<uint16_t>> transposed_;
    uint32_t hash_ = 0;
};

// Official Xiaohe double pinyin scheme.
class Xiaohe {
public:
    static const Xiaohe& get();
    // Syllables encoded by the two-key code (k1,k2); preferred (longest spelling) first.
    const std::vector<uint16_t>& codes(char k1, char k2) const {
        return pair_[(k1 - 'a') * 26 + (k2 - 'a')];
    }
    // Initial ids a first key may denote (consonant keys only). -1 when the key is a zero-initial key.
    int initialOfKey(char k) const { return keyInitial_[k - 'a']; }
    // Letters (for the first key) that are zero-initial markers: a, o, e
    bool isZeroKey(char k) const { return k == 'a' || k == 'o' || k == 'e'; }
    // Mask of all valid second keys after first key k1 (bit = letter index)
    uint32_t validSecond(char k1) const { return second_[k1 - 'a']; }
    // Reverse: the two-letter code that produces the given syllable (for display), or false.
    bool codeOf(int sid, char* k1, char* k2) const;

private:
    Xiaohe();
    std::vector<uint16_t> pair_[26 * 26];
    int keyInitial_[26];
    uint32_t second_[26];
    char rev1_[512];
    char rev2_[512];
};

}  // namespace ime
