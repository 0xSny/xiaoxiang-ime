// Flat binary dictionary format (little-endian, 8-byte aligned sections) and
// the read-only mmap loader. The runtime never copies the file into the heap.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include "common.hpp"

namespace ime {

constexpr uint32_t kDictVersion = 3;
constexpr char kDictMagic[8] = {'X', 'X', 'I', 'M', 'D', 'C', 'T', '1'};

#pragma pack(push, 1)
struct DictHeader {
    char magic[8];
    uint32_t version;
    uint32_t headerSize;
    uint32_t sylHash;
    uint32_t lnTotalQ;  // ln(total weight) * 1024
    uint64_t nodesOff, nodesCnt;
    uint64_t edgesOff, edgesCnt;
    uint64_t wordsOff, wordsCnt;
    uint64_t poolOff, poolSize;
    uint64_t bigOff, bigCnt;  // u64 keys[bigCnt] then u16 weights[bigCnt]
    uint64_t fileSize;
    uint64_t bodyChecksum;    // FNV-1a over [headerSize, fileSize)
    uint64_t headerChecksum;  // FNV-1a over header bytes [0, 120)
};
struct DictNode {
    uint32_t edgeStart;
    uint32_t wordStart;
    uint16_t edgeCount;
    uint16_t wordCount;
    uint16_t maxW;
    uint16_t pad;
};
struct DictEdge {
    uint32_t child;
    uint16_t syl;
    uint16_t pad;
};
struct DictWord {
    uint32_t textOff;
    uint16_t weight;  // ln(count) * 1024
    uint8_t charCount;
    uint8_t textLen;
};
#pragma pack(pop)

static_assert(sizeof(DictHeader) == 128, "header must be 128 bytes");
static_assert(sizeof(DictNode) == 16, "node size");
static_assert(sizeof(DictEdge) == 8, "edge size");
static_assert(sizeof(DictWord) == 8, "word size");

class Dictionary {
public:
    Dictionary() = default;
    ~Dictionary() { close(); }
    Dictionary(const Dictionary&) = delete;
    Dictionary& operator=(const Dictionary&) = delete;

    // Maps the file read-only. Validates magic, version, syllable hash, bounds and header checksum.
    bool open(const char* path, std::string* err = nullptr);
    void close();
    bool isOpen() const { return base_ != nullptr; }
    // Full-body checksum verification (touches every page; for tooling and CI only).
    bool verifyBody() const;

    const DictNode* nodes() const { return nodes_; }
    const DictEdge* edges() const { return edges_; }
    const DictWord* words() const { return words_; }
    const char* pool() const { return pool_; }
    uint64_t wordCount() const { return hdr_->wordsCnt; }
    uint64_t nodeCount() const { return hdr_->nodesCnt; }
    uint64_t bigramCount() const { return hdr_->bigCnt; }
    float lnTotal() const { return hdr_->lnTotalQ / 1024.0f; }
    const DictHeader* header() const { return hdr_; }

    // Binary search for an edge of node n labelled with syllable id; -1 if none.
    int findEdge(const DictNode& n, uint16_t syl) const {
        int lo = 0, hi = static_cast<int>(n.edgeCount) - 1;
        const DictEdge* e = edges_ + n.edgeStart;
        while (lo <= hi) {
            int mid = (lo + hi) >> 1;
            if (e[mid].syl == syl) return static_cast<int>(n.edgeStart) + mid;
            if (e[mid].syl < syl) lo = mid + 1; else hi = mid - 1;
        }
        return -1;
    }
    // Bigram weight (ln(count)*1024) or 0 when absent.
    uint16_t bigram(uint32_t prev, uint32_t next) const;

private:
    void* base_ = nullptr;
    size_t size_ = 0;
#ifdef _WIN32
    void* fileHandle_ = nullptr;
    void* mapHandle_ = nullptr;
#endif
    const DictHeader* hdr_ = nullptr;
    const DictNode* nodes_ = nullptr;
    const DictEdge* edges_ = nullptr;
    const DictWord* words_ = nullptr;
    const char* pool_ = nullptr;
    const uint64_t* bigKeys_ = nullptr;
    const uint16_t* bigW_ = nullptr;
};

}  // namespace ime
