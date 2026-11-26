// Offline dictionary compiler: rime-ice (雾凇拼音) text dictionaries -> flat binary dict (.bin).
//
//   dictbuilder build <out.bin> --single <file> [--single <file>...] --words <file> [--words <file>...]
//                     [--max-words N] [--min-weight W] [--max-bigrams N]
//   dictbuilder verify <dict.bin>
//   dictbuilder query  <dict.bin> <syl> [<syl> ...]
//
// Strict cleaning: only CJK unified ideographs (U+4E00..U+9FFF), every syllable must be a legal
// toneless pinyin syllable, syllable count must equal character count, single characters are
// accepted only from the --single (通用规范汉字表 8105) sources.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <unordered_map>
#include <unordered_set>

#include "../Core/dict.hpp"
#include "../Core/syllables.hpp"

using namespace ime;

namespace {

struct Entry {
    std::string text;
    std::vector<uint16_t> syls;
    double weight = 1.0;
    int chars = 0;
};

bool decodeCJK(const std::string& s, std::vector<uint32_t>* cps) {
    cps->clear();
    size_t i = 0;
    while (i < s.size()) {
        uint8_t c = static_cast<uint8_t>(s[i]);
        uint32_t cp;
        int n;
        if (c < 0x80) { cp = c; n = 1; }
        else if ((c >> 5) == 6) { cp = c & 0x1F; n = 2; }
        else if ((c >> 4) == 14) { cp = c & 0x0F; n = 3; }
        else if ((c >> 3) == 30) { cp = c & 0x07; n = 4; }
        else return false;
        if (i + n > s.size()) return false;
        for (int k = 1; k < n; k++) {
            uint8_t cc = static_cast<uint8_t>(s[i + k]);
            if ((cc & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (cc & 0x3F);
        }
        i += n;
        if (cp < 0x4E00 || cp > 0x9FFF) return false;  // strict: no latin, kana, emoji, ext-A/B rare forms
        cps->push_back(cp);
    }
    return !cps->empty();
}

std::vector<std::string> splitTab(const std::string& line) {
    std::vector<std::string> out;
    size_t st = 0;
    while (true) {
        size_t p = line.find('\t', st);
        if (p == std::string::npos) { out.push_back(line.substr(st)); break; }
        out.push_back(line.substr(st, p - st));
        st = p + 1;
    }
    return out;
}

// Normalise one pinyin token: lowercase, u-umlaut -> v, strip digits; returns syllable id or -1.
int parseSyllable(const std::string& tok) {
    std::string t;
    for (size_t i = 0; i < tok.size(); i++) {
        unsigned char c = static_cast<unsigned char>(tok[i]);
        if (c == 0xC3 && i + 1 < tok.size() && static_cast<unsigned char>(tok[i + 1]) == 0xBC) { t += 'v'; i++; continue; }
        if (c >= 'A' && c <= 'Z') c = static_cast<unsigned char>(c - 'A' + 'a');
        if (c >= '0' && c <= '9') continue;
        if (c < 'a' || c > 'z') return -1;
        t += static_cast<char>(c);
    }
    return SyllableTable::get().findLoose(t.data(), static_cast<int>(t.size()));
}

struct Stats { size_t lines = 0, kept = 0, badText = 0, badPinyin = 0, badLen = 0, lowWeight = 0; };

// single character -> readings sorted by weight (filled from the single sources)
std::unordered_map<std::string, std::vector<std::pair<uint16_t, double>>> gReadings;

void loadFile(const std::string& path, bool single, double minWeight, std::vector<Entry>* out, Stats* st) {
    std::ifstream rf(path, std::ios::binary);
    if (!rf) { std::cerr << "cannot open " << path << "\n"; std::exit(2); }
    std::string content((std::istreambuf_iterator<char>(rf)), std::istreambuf_iterator<char>());
    rf.close();
    // Rime dictionaries have a YAML header terminated by "...". Files without one are accepted too.
    size_t startPos = 0;
    size_t dots = content.find("\n...");
    if (dots != std::string::npos && dots < 20000) startPos = dots + 4;
    if (single) {
        // The 8105 table keeps rare / on-demand sections before "### 字表"; only the main table is used.
        size_t m = content.find("### 字表");
        if (m != std::string::npos) startPos = m;
    }
    std::istringstream f(content.substr(startPos));
    std::string line;
    std::vector<uint32_t> cps;
    double minSingle = 20.0;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        st->lines++;
        auto parts = splitTab(line);
        if (parts.size() < 2) { st->badLen++; continue; }
        const std::string& text = parts[0];
        if (!decodeCJK(text, &cps)) { st->badText++; continue; }
        int chars = static_cast<int>(cps.size());
        if (single ? chars != 1 : (chars < 2 || chars > 8)) { st->badLen++; continue; }
        // Reading-less phrase lists (tencent): annotate from the single-character table, like Rime does.
        bool numeric2 = !single && parts.size() == 2 && !parts[1].empty() &&
                        parts[1].find_first_not_of("0123456789.") == std::string::npos;
        if (numeric2) {
            double w = std::max(1.0, std::atof(parts[1].c_str()));
            if (w < minWeight) { st->lowWeight++; continue; }
            if (chars > 6) { st->badLen++; continue; }
            std::vector<std::vector<uint16_t>> combos(1);
            bool ok2 = true;
            size_t b = 0;
            for (int ci = 0; ci < chars && ok2; ci++) {
                size_t e2 = b + 1;
                while (e2 < text.size() && (static_cast<uint8_t>(text[e2]) & 0xC0) == 0x80) e2++;
                auto it = gReadings.find(text.substr(b, e2 - b));
                b = e2;
                if (it == gReadings.end() || it->second.empty()) { ok2 = false; break; }
                double maxw = it->second[0].second;
                std::vector<uint16_t> opts;
                for (auto& r : it->second) {
                    if (opts.size() >= 2) break;
                    if (r.second >= 0.15 * maxw) opts.push_back(r.first);
                }
                if (combos.size() * opts.size() > 3) opts.resize(1);
                std::vector<std::vector<uint16_t>> nc;
                for (auto& c : combos)
                    for (uint16_t o : opts) { auto d = c; d.push_back(o); nc.push_back(std::move(d)); }
                combos = std::move(nc);
            }
            if (!ok2) { st->badPinyin++; continue; }
            for (auto& c : combos) {
                Entry e;
                e.text = text;
                e.syls = c;
                e.weight = w;
                e.chars = chars;
                out->push_back(std::move(e));
                st->kept++;
            }
            continue;
        }
        std::vector<uint16_t> syls;
        std::istringstream ss(parts[1]);
        std::string tok;
        bool ok = true;
        while (ss >> tok) {
            int id = parseSyllable(tok);
            if (id < 0) { ok = false; break; }
            syls.push_back(static_cast<uint16_t>(id));
        }
        if (!ok) { st->badPinyin++; continue; }
        if (static_cast<int>(syls.size()) != chars) { st->badLen++; continue; }
        double w = 1.0;
        if (parts.size() >= 3 && !parts[2].empty()) {
            const std::string& ws = parts[2];
            if (ws.back() == '%') w = std::max(1.0, std::atof(ws.c_str()));
            else w = std::atof(ws.c_str());
            if (w < 1.0) w = 1.0;
        }
        if (!single && w < minWeight) { st->lowWeight++; continue; }
        if (single && w < minSingle) { st->lowWeight++; continue; }
        Entry e;
        e.text = text;
        e.syls = std::move(syls);
        e.weight = w;
        e.chars = chars;
        out->push_back(std::move(e));
        st->kept++;
    }
}

uint16_t quantize(double w) {
    double q = std::round(std::log(std::max(w, 1.0)) * 1024.0);
    if (q < 1) q = 1;
    if (q > 65535) q = 65535;
    return static_cast<uint16_t>(q);
}

template <class T>
void writeVec(std::ofstream& f, const std::vector<T>& v) {
    if (!v.empty()) f.write(reinterpret_cast<const char*>(v.data()), static_cast<std::streamsize>(v.size() * sizeof(T)));
}

void pad8(std::ofstream& f) {
    std::streamoff pos = f.tellp();
    static const char zero[8] = {0};
    size_t padn = static_cast<size_t>((8 - (pos & 7)) & 7);
    if (padn) f.write(zero, static_cast<std::streamsize>(padn));
}

int cmdBuild(int argc, char** argv) {
    if (argc < 3) { std::cerr << "usage: build <out.bin> --single f --words f\n"; return 2; }
    std::string outPath = argv[2];
    std::vector<std::string> singles, wordFiles;
    size_t maxWords = 600000, maxBigrams = 300000;
    double minWeight = 1.0;
    for (int i = 3; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : std::string(); };
        if (a == "--single") singles.push_back(next());
        else if (a == "--words") wordFiles.push_back(next());
        else if (a == "--max-words") maxWords = static_cast<size_t>(std::atoll(next().c_str()));
        else if (a == "--min-weight") minWeight = std::atof(next().c_str());
        else if (a == "--max-bigrams") maxBigrams = static_cast<size_t>(std::atoll(next().c_str()));
    }
    std::vector<Entry> all;
    Stats sst, wst;
    for (auto& p : singles) loadFile(p, true, 0, &all, &sst);
    size_t singleCount = all.size();
    for (auto& e : all) gReadings[e.text].push_back({e.syls[0], e.weight});
    for (auto& kv : gReadings)
        std::sort(kv.second.begin(), kv.second.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
    for (auto& p : wordFiles) loadFile(p, false, minWeight, &all, &wst);
    std::cerr << "singles: lines=" << sst.lines << " kept=" << sst.kept << " badText=" << sst.badText
              << " badPinyin=" << sst.badPinyin << " badLen=" << sst.badLen << "\n";
    std::cerr << "words:   lines=" << wst.lines << " kept=" << wst.kept << " badText=" << wst.badText
              << " badPinyin=" << wst.badPinyin << " badLen=" << wst.badLen << " lowWeight=" << wst.lowWeight << "\n";

    // De-duplicate by (text, syllables); keep the highest weight.
    std::unordered_map<std::string, size_t> seen;
    std::vector<Entry> uniq;
    uniq.reserve(all.size());
    for (size_t i = 0; i < all.size(); i++) {
        std::string key = all[i].text;
        key.push_back('\x01');
        key.append(reinterpret_cast<const char*>(all[i].syls.data()), all[i].syls.size() * 2);
        auto it = seen.find(key);
        if (it == seen.end()) { seen[key] = uniq.size(); uniq.push_back(std::move(all[i])); }
        else if (all[i].weight > uniq[it->second].weight) uniq[it->second].weight = all[i].weight;
    }
    all.clear();
    (void)singleCount;

    // Cap the multi-character entries by weight; singles are always retained.
    std::vector<Entry> singlesV, multiV;
    for (auto& e : uniq) (e.chars == 1 ? singlesV : multiV).push_back(std::move(e));
    uniq.clear();
    if (multiV.size() > maxWords) {
        auto better = [](const Entry& a, const Entry& b) {
            if (a.weight != b.weight) return a.weight > b.weight;
            if (a.chars != b.chars) return a.chars < b.chars;
            return a.text < b.text;
        };
        std::nth_element(multiV.begin(), multiV.begin() + static_cast<long>(maxWords), multiV.end(), better);
        multiV.resize(maxWords);
    }
    std::vector<Entry> entries;
    entries.reserve(singlesV.size() + multiV.size());
    for (auto& e : singlesV) entries.push_back(std::move(e));
    for (auto& e : multiV) entries.push_back(std::move(e));
    std::cerr << "entries after clean: " << entries.size() << " (singles " << singlesV.size() << ")\n";

    double total = 0;
    for (auto& e : entries) total += e.weight;

    std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
        if (a.syls != b.syls) return a.syls < b.syls;
        return a.weight > b.weight;
    });

    // ---- trie serialisation (BFS) ----
    std::vector<DictNode> nodes(1);
    std::vector<DictEdge> edges;
    std::vector<DictWord> words;
    std::string pool;
    std::unordered_map<std::string, uint32_t> poolIdx;
    std::vector<uint32_t> entryToId(entries.size(), 0);
    struct Item { uint32_t lo, hi, depth, node; };
    std::deque<Item> q;
    q.push_back({0, static_cast<uint32_t>(entries.size()), 0, 0});
    std::vector<uint16_t> ownMax(1, 0);
    while (!q.empty()) {
        Item it = q.front();
        q.pop_front();
        uint32_t i = it.lo;
        while (i < it.hi && entries[i].syls.size() == it.depth) i++;
        // words ending at this node: entries[lo..i) already sorted by weight desc
        uint32_t wordStart = static_cast<uint32_t>(words.size());
        uint16_t mx = 0;
        for (uint32_t k = it.lo; k < i; k++) {
            const Entry& e = entries[k];
            auto pit = poolIdx.find(e.text);
            uint32_t off;
            if (pit == poolIdx.end()) {
                off = static_cast<uint32_t>(pool.size());
                pool += e.text;
                poolIdx[e.text] = off;
            } else off = pit->second;
            DictWord w;
            w.textOff = off;
            w.weight = quantize(e.weight);
            w.charCount = static_cast<uint8_t>(e.chars);
            w.textLen = static_cast<uint8_t>(e.text.size());
            entryToId[k] = static_cast<uint32_t>(words.size());
            words.push_back(w);
            mx = std::max(mx, w.weight);
        }
        uint32_t wc = i - it.lo;
        if (wc > 65535) wc = 65535;
        uint32_t edgeStart = static_cast<uint32_t>(edges.size());
        uint32_t j = i;
        while (j < it.hi) {
            uint16_t s = entries[j].syls[it.depth];
            uint32_t k = j;
            while (k < it.hi && entries[k].syls[it.depth] == s) k++;
            uint32_t child = static_cast<uint32_t>(nodes.size());
            nodes.emplace_back();
            ownMax.push_back(0);
            DictEdge e;
            e.child = child;
            e.syl = s;
            e.pad = 0;
            edges.push_back(e);
            q.push_back({j, k, it.depth + 1, child});
            j = k;
        }
        DictNode& n = nodes[it.node];
        n.wordStart = wordStart;
        n.wordCount = static_cast<uint16_t>(wc);
        n.edgeStart = edgeStart;
        n.edgeCount = static_cast<uint16_t>(edges.size() - edgeStart);
        n.pad = 0;
        ownMax[it.node] = mx;
    }
    for (size_t n = nodes.size(); n-- > 0;) {
        uint16_t m = ownMax[n];
        for (uint32_t e = 0; e < nodes[n].edgeCount; e++)
            m = std::max(m, nodes[edges[nodes[n].edgeStart + e].child].maxW);
        nodes[n].maxW = m;
    }
    std::cerr << "nodes=" << nodes.size() << " edges=" << edges.size() << " words=" << words.size()
              << " pool=" << pool.size() << "\n";

    // ---- bigram co-occurrence derived from long phrases ----
    // Every phrase of >= 3 characters is segmented into known shorter dictionary words (max total log
    // frequency, fewer pieces preferred); adjacent pieces form (prev, next) pairs weighted by the
    // phrase frequency.
    std::unordered_map<std::string, uint32_t> bestWord;  // text -> entry index of highest weight
    for (uint32_t k = 0; k < entries.size(); k++) {
        const Entry& e = entries[k];
        if (e.chars > 4) continue;
        auto it = bestWord.find(e.text);
        if (it == bestWord.end() || entries[it->second].weight < e.weight) bestWord[e.text] = k;
    }
    std::unordered_map<uint64_t, double> pairCount;
    size_t dbgSeg = 0, dbgOk = 0;
    std::vector<size_t> cpStart;
    for (uint32_t k = 0; k < entries.size(); k++) {
        const Entry& e = entries[k];
        if (e.chars < 3) continue;
        cpStart.clear();
        for (size_t b = 0; b < e.text.size(); b++)
            if ((static_cast<uint8_t>(e.text[b]) & 0xC0) != 0x80) cpStart.push_back(b);
        int n = e.chars;
        cpStart.push_back(e.text.size());
        std::vector<double> best(n + 1, -1e18);
        std::vector<int> from(n + 1, -1);
        std::vector<uint32_t> pieceEntry(n + 1, 0);
        best[0] = 0;
        for (int a = 0; a < n; a++) {
            if (best[a] < -1e17) continue;
            for (int len = 1; len <= 4 && a + len <= n; len++) {
                if (len == n) continue;  // do not use the phrase itself
                std::string sub = e.text.substr(cpStart[a], cpStart[a + len] - cpStart[a]);
                auto it = bestWord.find(sub);
                if (it == bestWord.end()) continue;
                double sc = best[a] + std::log(std::max(entries[it->second].weight, 1.0)) - 100.0;  // fewest pieces first
                if (sc > best[a + len]) { best[a + len] = sc; from[a + len] = a; pieceEntry[a + len] = it->second; }
            }
        }
        dbgSeg++;
        if (from[n] < 0) continue;
        dbgOk++;
        std::vector<uint32_t> pieces;
        bool multi = false;
        for (int p = n; p > 0; p = from[p]) {
            pieces.push_back(entryToId[pieceEntry[p]]);
            if (p - from[p] >= 2) multi = true;
        }
        std::reverse(pieces.begin(), pieces.end());
        if (pieces.size() < 2 || !multi) continue;
        for (size_t t = 0; t + 1 < pieces.size(); t++)
            pairCount[(static_cast<uint64_t>(pieces[t]) << 32) | pieces[t + 1]] += e.weight;
    }
    std::vector<std::pair<uint64_t, double>> pairs(pairCount.begin(), pairCount.end());
    pairCount.clear();
    if (pairs.size() > maxBigrams) {
        std::nth_element(pairs.begin(), pairs.begin() + static_cast<long>(maxBigrams), pairs.end(),
                         [](const auto& a, const auto& b) { return a.second > b.second; });
        pairs.resize(maxBigrams);
    }
    std::sort(pairs.begin(), pairs.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    std::vector<uint64_t> bigKeys;
    std::vector<uint16_t> bigW;
    for (auto& p : pairs) { bigKeys.push_back(p.first); bigW.push_back(quantize(p.second)); }
    std::cerr << "bigrams=" << bigKeys.size() << " (phrases=" << dbgSeg << " segmented=" << dbgOk << ")\n";

    // ---- write file ----
    std::ofstream f(outPath, std::ios::binary | std::ios::trunc);
    if (!f) { std::cerr << "cannot write " << outPath << "\n"; return 2; }
    DictHeader h;
    std::memset(&h, 0, sizeof(h));
    std::memcpy(h.magic, kDictMagic, 8);
    h.version = kDictVersion;
    h.headerSize = sizeof(DictHeader);
    h.sylHash = SyllableTable::get().hash();
    h.lnTotalQ = static_cast<uint32_t>(std::round(std::log(std::max(total, 2.0)) * 1024.0));
    f.write(reinterpret_cast<const char*>(&h), sizeof(h));
    h.nodesOff = static_cast<uint64_t>(f.tellp());
    h.nodesCnt = nodes.size();
    writeVec(f, nodes);
    pad8(f);
    h.edgesOff = static_cast<uint64_t>(f.tellp());
    h.edgesCnt = edges.size();
    writeVec(f, edges);
    pad8(f);
    h.wordsOff = static_cast<uint64_t>(f.tellp());
    h.wordsCnt = words.size();
    writeVec(f, words);
    pad8(f);
    h.poolOff = static_cast<uint64_t>(f.tellp());
    h.poolSize = pool.size();
    f.write(pool.data(), static_cast<std::streamsize>(pool.size()));
    pad8(f);
    h.bigOff = static_cast<uint64_t>(f.tellp());
    h.bigCnt = bigKeys.size();
    writeVec(f, bigKeys);
    writeVec(f, bigW);
    pad8(f);
    h.fileSize = static_cast<uint64_t>(f.tellp());
    f.flush();
    f.close();

    // body checksum: re-read
    std::ifstream rf(outPath, std::ios::binary);
    std::string body((std::istreambuf_iterator<char>(rf)), std::istreambuf_iterator<char>());
    rf.close();
    h.bodyChecksum = fnv1a(body.data() + sizeof(DictHeader), body.size() - sizeof(DictHeader));
    h.headerChecksum = fnv1a(&h, 120);
    std::fstream wf(outPath, std::ios::binary | std::ios::in | std::ios::out);
    wf.seekp(0);
    wf.write(reinterpret_cast<const char*>(&h), sizeof(h));
    wf.close();
    std::cerr << "wrote " << outPath << " (" << h.fileSize << " bytes)\n";
    return 0;
}

int cmdVerify(const char* path) {
    Dictionary d;
    std::string err;
    if (!d.open(path, &err)) { std::cerr << "VERIFY FAILED: " << err << "\n"; return 1; }
    if (!d.verifyBody()) { std::cerr << "VERIFY FAILED: body checksum mismatch\n"; return 1; }
    if (d.wordCount() < 1000 || d.nodeCount() < 1000) { std::cerr << "VERIFY FAILED: dictionary too small\n"; return 1; }
    std::printf("OK magic=%.8s version=%u words=%llu nodes=%llu bigrams=%llu size=%llu\n", d.header()->magic,
                d.header()->version, static_cast<unsigned long long>(d.wordCount()),
                static_cast<unsigned long long>(d.nodeCount()), static_cast<unsigned long long>(d.bigramCount()),
                static_cast<unsigned long long>(d.header()->fileSize));
    return 0;
}

int cmdQuery(int argc, char** argv) {
    Dictionary d;
    std::string err;
    if (argc < 4 || !d.open(argv[2], &err)) { std::cerr << "query failed " << err << "\n"; return 1; }
    uint32_t node = 0;
    for (int i = 3; i < argc; i++) {
        int sid = SyllableTable::get().find(argv[i], static_cast<int>(std::strlen(argv[i])));
        if (sid < 0) { std::cerr << "unknown syllable " << argv[i] << "\n"; return 1; }
        int e = d.findEdge(d.nodes()[node], static_cast<uint16_t>(sid));
        if (e < 0) { std::cout << "(no path)\n"; return 0; }
        node = d.edges()[e].child;
    }
    const DictNode& n = d.nodes()[node];
    for (uint32_t k = 0; k < n.wordCount && k < 30; k++) {
        const DictWord& w = d.words()[n.wordStart + k];
        std::cout << std::string(d.pool() + w.textOff, w.textLen) << " " << w.weight / 1024.0 << "\n";
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { std::cerr << "usage: dictbuilder build|verify|query ...\n"; return 2; }
    std::string c = argv[1];
    if (c == "build") return cmdBuild(argc, argv);
    if (c == "verify" && argc >= 3) return cmdVerify(argv[2]);
    if (c == "query") return cmdQuery(argc, argv);
    std::cerr << "unknown command\n";
    return 2;
}
