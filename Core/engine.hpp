// Decoding engine: syllable lattice (full pinyin / Xiaohe double pinyin) + spatial Gaussian costs,
// trie walk over the mmap dictionary and the user dictionary, bigram-aware Viterbi beam search.
#pragma once
#include <atomic>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

#include "common.hpp"
#include "dict.hpp"
#include "syllables.hpp"
#include "userdict.hpp"

namespace ime {

enum Scheme { kSchemePinyin = 0, kSchemeXiaohe = 1 };

struct EngineSettings {
    int scheme = kSchemePinyin;
    uint16_t fuzzy = 0;          // FuzzyBit mask (11 groups)
    bool jianpin = true;         // initial-letter abbreviations / mixed input
    bool correction = true;      // neighbour-key + transposition tolerance
    float spatialScale = 1.0f;   // 0 disables spatial correction, up to 2
    bool learning = true;
    bool completion = true;
};

// One touch event: up to three candidate letters with spatial probabilities (Top-3 Gaussian).
struct KeyStroke {
    uint8_t n;
    char c[3];
    float p[3];
};

enum CandFlags : uint8_t {
    kCandUser = 1, kCandSentence = 2, kCandRaw = 4, kCandCompletion = 8, kCandCorrected = 16
};

struct Candidate {
    uint32_t textOff = 0;
    uint16_t textLen = 0;
    uint16_t consumed = 0;   // number of raw keys consumed when selected
    uint8_t sylCount = 0;
    uint8_t flags = 0;
    uint32_t sylOff = 0;
    float score = 0;
    float baseLn = 0;        // unigram log-probability without per-session costs
    uint64_t key = 0;        // FNV of text
    uint32_t wordId = 0xFFFFFFFFu;
};

struct Result {
    std::string pool;                 // UTF-8 texts
    std::vector<uint16_t> syls;       // syllable id sequences
    std::vector<Candidate> cands;
    int rawLen = 0;
    bool fullCover = false;           // some path covers the whole input
};

struct CommitSeg {
    std::string text;
    std::vector<uint16_t> syls;
    float baseLn = -12.f;
    uint64_t key = 0;
    uint32_t wordId = 0xFFFFFFFFu;  // static dictionary id when known (context bigrams)
    bool raw = false;
    bool weak = false;  // not learnable (e.g. a lone initial letter)
};

class Engine {
public:
    Engine();

    bool loadDictionary(const char* path, std::string* err = nullptr);
    bool dictionaryLoaded() const { return dict_.isOpen(); }
    void setSettings(const EngineSettings& s);
    const EngineSettings& settings() const { return set_; }
    bool openUserData(const char* dir);
    bool flushUser(bool force = false) { return user_.flush(force); }
    bool userDirty() const { return user_.dirty(); }

    // Generation tokens (lock-free cancellation).
    uint64_t bumpGeneration() { return gen_.fetch_add(1, std::memory_order_acq_rel) + 1; }
    uint64_t generation() const { return gen_.load(std::memory_order_acquire); }

    // Decodes the key sequence. Returns nullptr when superseded by a newer generation.
    std::shared_ptr<Result> decode(const KeyStroke* keys, int n, uint64_t gen);

    // Cheap, allocation-light helpers safe to call from the main thread.
    std::string quickSegment(const char* letters, int n, int scheme, bool expandShuangpin) const;
    void nextLetterPrior(const char* letters, int n, int scheme, float out[26]) const;

    // Learning.
    void commit(const std::vector<CommitSeg>& segs);
    bool rollbackLastCommit();
    bool deleteUserWord(const std::vector<uint16_t>& syls, const std::string& text);
    void resetUserData();
    void setContext(uint64_t key, uint32_t id) { ctxKey_ = key; ctxId_ = id; }
    void resetContext() { ctxKey_ = 0; ctxId_ = 0xFFFFFFFFu; }
    size_t userWordCount() const { return user_.wordCount(); }
    size_t userBigramCount() const { return user_.bigramCount(); }
    const Dictionary& dictionary() const { return dict_; }

private:
    struct Token {
        uint16_t end;
        int16_t single;
        const Mask* mask;
        float cost;
        uint8_t flags;  // 1 corrected(neighbour/transposition), 2 initial, 4 fuzzy, 8 prefix
    };
    struct LWord {
        uint16_t start, end;
        uint8_t nsyl, flags;  // flags: 1 user, 2 corrected, 4 initial, 8 fuzzy/prefix
        float lnP, cost;
        uint32_t id;
        uint32_t sylOff;
        uint64_t key;
    };
    struct Hyp {
        float score;
        int32_t lw;
        int16_t prevPos, prevIdx;
        uint64_t key;
        uint32_t id;
    };
    struct Frame {
        uint32_t node;
        uint16_t pos;
        uint8_t depth, flags;
        float cost;
        uint16_t syls[12];
    };
    struct UndoOp { std::vector<uint16_t> syls; std::string text; float delta; uint64_t k1, k2; bool bigram; };

    void prepareInput(const KeyStroke* keys, int n);
    void genTokens();
    void addTok(int pos, int end, int single, const Mask* mask, float cost, uint8_t flags);
    void addSyllableTokens(int pos, int end, int sid, float cost, uint8_t flags);
    template <class View> void expand(View& v, int start, bool user);
    void viterbi(bool strict, std::vector<std::vector<Hyp>>& hyps);
    float transBonus(const Hyp& h, const LWord& w, uint32_t now) const;
    void emitStatic(const DictNode& node, const Frame& f, int start, int end);
    void emitUser(int nodeIdx, const Frame& f, int start, int end);
    void emitCompletions(uint32_t node, const Frame& f);
    void pushCand(Result& r, const std::string& text, const uint16_t* syls, int ns, int consumed, uint8_t flags,
                  float score, float baseLn, uint64_t key, uint32_t id, std::unordered_set<uint64_t>& seen, bool dedupe = true);
    std::string wordText(const LWord& w) const;
    float lnTotalOf(uint32_t) const { return lnTotal_; }

    Dictionary dict_;
    UserDict user_;
    EngineSettings set_;
    std::atomic<uint64_t> gen_{0};
    uint64_t curGen_ = 0;
    float lnTotal_ = 24.f;
    std::vector<std::vector<uint16_t>> fuzzyAlts_;
    Mask iniTok_[kInitialCount];
    Mask zeroMask_[26];
    uint64_t ctxKey_ = 0;
    uint32_t ctxId_ = 0xFFFFFFFFu;
    uint32_t now_ = 0;
    std::vector<UndoOp> lastCommitUndo_;
    uint64_t lastCommitPrevKey_ = 0;
    uint32_t lastCommitPrevId_ = 0xFFFFFFFFu;

    // scratch (decode thread only)
    int n_ = 0;
    std::vector<char> primary_;
    std::vector<uint8_t> sep_;
    std::vector<std::array<float, 26>> acost_;
    std::vector<std::vector<Token>> tokens_;
    std::deque<Mask> dynMasks_;
    std::vector<LWord> lw_;
    std::vector<uint16_t> sylPool_;
    std::vector<std::vector<int>> byStart_;
    std::vector<LWord> compl_;
    std::vector<Frame> stack_;
    bool aborted_ = false;
    int budget_ = 0;
};

}  // namespace ime
