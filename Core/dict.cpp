#include "dict.hpp"
#include "syllables.hpp"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace ime {

static bool fail(std::string* err, const char* m) {
    if (err) *err = m;
    return false;
}

bool Dictionary::open(const char* path, std::string* err) {
    close();
#ifdef _WIN32
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return fail(err, "cannot open dictionary file");
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(f, &sz) || sz.QuadPart < static_cast<long long>(sizeof(DictHeader))) {
        CloseHandle(f);
        return fail(err, "dictionary too small");
    }
    HANDLE m = CreateFileMappingA(f, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (!m) { CloseHandle(f); return fail(err, "CreateFileMapping failed"); }
    void* p = MapViewOfFile(m, FILE_MAP_READ, 0, 0, 0);
    if (!p) { CloseHandle(m); CloseHandle(f); return fail(err, "MapViewOfFile failed"); }
    fileHandle_ = f;
    mapHandle_ = m;
    base_ = p;
    size_ = static_cast<size_t>(sz.QuadPart);
#else
    int fd = ::open(path, O_RDONLY);
    if (fd < 0) return fail(err, "cannot open dictionary file");
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < static_cast<off_t>(sizeof(DictHeader))) {
        ::close(fd);
        return fail(err, "dictionary too small");
    }
    void* p = mmap(nullptr, static_cast<size_t>(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0);
    ::close(fd);
    if (p == MAP_FAILED) return fail(err, "mmap failed");
    base_ = p;
    size_ = static_cast<size_t>(st.st_size);
    madvise(base_, size_, MADV_RANDOM);
#endif
    const DictHeader* h = static_cast<const DictHeader*>(base_);
    bool ok = std::memcmp(h->magic, kDictMagic, 8) == 0;
    if (!ok) { close(); return fail(err, "bad magic"); }
    if (h->version != kDictVersion || h->headerSize != sizeof(DictHeader)) { close(); return fail(err, "bad version"); }
    if (h->sylHash != SyllableTable::get().hash()) { close(); return fail(err, "syllable table mismatch"); }
    if (h->fileSize != size_) { close(); return fail(err, "size mismatch"); }
    if (fnv1a(h, 120) != h->headerChecksum) { close(); return fail(err, "header checksum mismatch"); }
    auto inRange = [&](uint64_t off, uint64_t bytes) { return off <= size_ && bytes <= size_ - off; };
    if (!inRange(h->nodesOff, h->nodesCnt * sizeof(DictNode)) || !inRange(h->edgesOff, h->edgesCnt * sizeof(DictEdge)) ||
        !inRange(h->wordsOff, h->wordsCnt * sizeof(DictWord)) || !inRange(h->poolOff, h->poolSize) ||
        !inRange(h->bigOff, h->bigCnt * 10)) {
        close();
        return fail(err, "section out of range");
    }
    hdr_ = h;
    const char* b = static_cast<const char*>(base_);
    nodes_ = reinterpret_cast<const DictNode*>(b + h->nodesOff);
    edges_ = reinterpret_cast<const DictEdge*>(b + h->edgesOff);
    words_ = reinterpret_cast<const DictWord*>(b + h->wordsOff);
    pool_ = b + h->poolOff;
    bigKeys_ = reinterpret_cast<const uint64_t*>(b + h->bigOff);
    bigW_ = reinterpret_cast<const uint16_t*>(b + h->bigOff + h->bigCnt * 8);
    return true;
}

void Dictionary::close() {
    if (base_) {
#ifdef _WIN32
        UnmapViewOfFile(base_);
        if (mapHandle_) CloseHandle(mapHandle_);
        if (fileHandle_) CloseHandle(fileHandle_);
        mapHandle_ = fileHandle_ = nullptr;
#else
        munmap(base_, size_);
#endif
    }
    base_ = nullptr;
    size_ = 0;
    hdr_ = nullptr;
    nodes_ = nullptr; edges_ = nullptr; words_ = nullptr; pool_ = nullptr;
    bigKeys_ = nullptr; bigW_ = nullptr;
}

bool Dictionary::verifyBody() const {
    if (!hdr_) return false;
    const char* b = static_cast<const char*>(base_);
    return fnv1a(b + hdr_->headerSize, size_ - hdr_->headerSize) == hdr_->bodyChecksum;
}

uint16_t Dictionary::bigram(uint32_t prev, uint32_t next) const {
    if (!hdr_ || hdr_->bigCnt == 0) return 0;
    uint64_t key = (static_cast<uint64_t>(prev) << 32) | next;
    uint64_t lo = 0, hi = hdr_->bigCnt;
    while (lo < hi) {
        uint64_t mid = (lo + hi) >> 1;
        if (bigKeys_[mid] < key) lo = mid + 1; else hi = mid;
    }
    if (lo < hdr_->bigCnt && bigKeys_[lo] == key) return bigW_[lo];
    return 0;
}

}  // namespace ime
