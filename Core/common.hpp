// Common helpers for the XiaoXiang IME core engine (pure C++17, no third-party code).
#pragma once
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace ime {

// 512-bit syllable membership mask.
struct Mask {
    uint64_t w[8];
    void clear() { std::memset(w, 0, sizeof(w)); }
    void set(int i) { w[i >> 6] |= (1ULL << (i & 63)); }
    bool test(int i) const { return (w[i >> 6] >> (i & 63)) & 1ULL; }
    bool any() const {
        for (int i = 0; i < 8; i++) if (w[i]) return true;
        return false;
    }
    void orWith(const Mask& o) { for (int i = 0; i < 8; i++) w[i] |= o.w[i]; }
};

constexpr uint64_t kFnvBasis = 1469598103934665603ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;

inline uint64_t fnv1a(const void* p, size_t n, uint64_t h = kFnvBasis) {
    const uint8_t* b = static_cast<const uint8_t*>(p);
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= kFnvPrime; }
    return h;
}

inline uint32_t fnv32(const void* p, size_t n) {
    const uint8_t* b = static_cast<const uint8_t*>(p);
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 16777619u; }
    return h;
}

inline uint64_t mixPair(uint64_t a, uint64_t b) {
    uint64_t h = a * 0x9E3779B97F4A7C15ULL;
    h ^= (b + 0x7F4A7C15ULL + (h << 6) + (h >> 2));
    return h * 0xBF58476D1CE4E5B9ULL;
}

// Count UTF-8 code points.
inline int utf8Length(const char* s, size_t n) {
    int c = 0;
    for (size_t i = 0; i < n; i++) if ((static_cast<uint8_t>(s[i]) & 0xC0) != 0x80) c++;
    return c;
}

}  // namespace ime
