#include "syllables.hpp"
#include <algorithm>
#include <cstring>

namespace ime {

namespace {

// Canonical spelling: v stands for the u-umlaut (nv, lv, nve, lve).
const char* kSyllableList =
    "a ai an ang ao e ei en eng er o ou "
    "ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu "
    "pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu "
    "ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu "
    "fa fan fang fei fen feng fo fou fu "
    "da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo "
    "ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo "
    "na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nun nuo nv nve "
    "la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve "
    "ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo "
    "ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo "
    "ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo "
    "ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun "
    "qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun "
    "xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun "
    "zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo "
    "cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo "
    "sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo "
    "ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo "
    "za zai zan zang zao ze zei zen zeng zi zong zou zu zuan zui zun zuo "
    "ca cai can cang cao ce cen ceng ci cong cou cu cuan cui cun cuo "
    "sa sai san sang sao se sen seng si song sou su suan sui sun suo "
    "ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun "
    "wa wai wan wang wei wen weng wo wu";

const char* kInitialText[kInitialCount] = {
    "", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
    "j", "q", "x", "zh", "ch", "sh", "r", "z", "c", "s", "y", "w"};

int detectInitial(const char* s, int len, int* iniLen) {
    if (len >= 2 && s[1] == 'h' && (s[0] == 'z' || s[0] == 'c' || s[0] == 's')) {
        *iniLen = 2;
        return s[0] == 'z' ? 15 : (s[0] == 'c' ? 16 : 17);
    }
    static const char* letters = "bpmfdtnlgkhjqxrzcsyw";
    static const int ids[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 18, 19, 20, 21, 22, 23};
    const char* p = std::strchr(letters, s[0]);
    if (p && s[0] != 'a' && s[0] != 'e' && s[0] != 'o' && s[0] != 0) {
        *iniLen = 1;
        return ids[p - letters];
    }
    *iniLen = 0;
    return 0;
}

}  // namespace

const SyllableTable& SyllableTable::get() {
    static SyllableTable inst;
    return inst;
}

SyllableTable::SyllableTable() {
    const char* p = kSyllableList;
    uint64_t h = kFnvBasis;
    while (*p) {
        while (*p == ' ') p++;
        const char* b = p;
        while (*p && *p != ' ') p++;
        int len = static_cast<int>(p - b);
        if (len <= 0) continue;
        uint64_t key = pack(b, len);
        if (index_.count(key)) continue;
        Syl sy;
        std::memset(&sy, 0, sizeof(sy));
        std::memcpy(sy.s, b, len);
        sy.len = static_cast<uint8_t>(len);
        int il = 0;
        sy.ini = static_cast<uint8_t>(detectInitial(b, len, &il));
        sy.iniLen = static_cast<uint8_t>(il);
        index_[key] = static_cast<uint16_t>(syls_.size());
        h = fnv1a(b, len, h);
        h = fnv1a(" ", 1, h);
        syls_.push_back(sy);
    }
    hash_ = static_cast<uint32_t>(h ^ (h >> 32));
    for (auto& m : initMask_) m.clear();
    for (size_t i = 0; i < syls_.size(); i++) {
        byFirst_[syls_[i].s[0] - 'a'].push_back(static_cast<uint16_t>(i));
        initMask_[syls_[i].ini].set(static_cast<int>(i));
    }
    // Transposition table: swap adjacent letters inside the final of a syllable.
    for (size_t i = 0; i < syls_.size(); i++) {
        const Syl& sy = syls_[i];
        for (int k = std::max<int>(sy.iniLen, 1) - 0; k + 1 < sy.len; k++) {
            if (k < sy.iniLen) continue;
            if (sy.s[k] == sy.s[k + 1]) continue;
            char t[8];
            std::memcpy(t, sy.s, sy.len);
            std::swap(t[k], t[k + 1]);
            if (find(t, sy.len) >= 0) continue;  // a legal syllable stays untouched
            transposed_[pack(t, sy.len)].push_back(static_cast<uint16_t>(i));
        }
    }
}

int SyllableTable::find(const char* s, int len) const {
    if (len <= 0 || len > 6) return -1;
    auto it = index_.find(pack(s, len));
    return it == index_.end() ? -1 : it->second;
}

int SyllableTable::findLoose(const char* s, int len) const {
    int r = find(s, len);
    if (r >= 0) return r;
    if (len == 3 && s[1] == 'u' && s[2] == 'e' && (s[0] == 'l' || s[0] == 'n')) {
        char t[4] = {s[0], 'v', 'e', 0};
        return find(t, 3);
    }
    return -1;
}

int SyllableTable::initialOfLetter(char c) const {
    switch (c) {
        case 'b': return 1; case 'p': return 2; case 'm': return 3; case 'f': return 4;
        case 'd': return 5; case 't': return 6; case 'n': return 7; case 'l': return 8;
        case 'g': return 9; case 'k': return 10; case 'h': return 11; case 'j': return 12;
        case 'q': return 13; case 'x': return 14; case 'r': return 18; case 'z': return 19;
        case 'c': return 20; case 's': return 21; case 'y': return 22; case 'w': return 23;
        default: return -1;
    }
}

int SyllableTable::initialOfPair(char a, char b) const {
    if (b != 'h') return -1;
    if (a == 'z') return 15;
    if (a == 'c') return 16;
    if (a == 's') return 17;
    return -1;
}

const char* SyllableTable::initialText(int ini) const { return kInitialText[ini]; }

bool SyllableTable::isPrefix(const char* s, int len) const {
    if (len <= 0 || len > 6) return false;
    const auto& v = byFirst_[s[0] - 'a'];
    for (uint16_t id : v) {
        const Syl& sy = syls_[id];
        if (sy.len >= len && std::memcmp(sy.s, s, len) == 0) return true;
    }
    return false;
}

void SyllableTable::prefixMask(const char* s, int len, Mask& out) const {
    out.clear();
    if (len <= 0 || len > 6) return;
    const auto& v = byFirst_[s[0] - 'a'];
    for (uint16_t id : v) {
        const Syl& sy = syls_[id];
        if (sy.len >= len && std::memcmp(sy.s, s, len) == 0) out.set(id);
    }
}

const std::vector<uint16_t>* SyllableTable::transposed(uint64_t packed) const {
    auto it = transposed_.find(packed);
    return it == transposed_.end() ? nullptr : &it->second;
}

std::vector<std::vector<uint16_t>> SyllableTable::buildFuzzyAlts(uint16_t bits) const {
    std::vector<std::vector<uint16_t>> alts(syls_.size());
    auto add = [&](size_t t, const std::string& s) {
        int id = find(s.data(), static_cast<int>(s.size()));
        if (id >= 0 && id != static_cast<int>(t)) {
            auto& v = alts[t];
            if (std::find(v.begin(), v.end(), id) == v.end()) v.push_back(static_cast<uint16_t>(id));
        }
    };
    struct IniRule { int bit; int a; int b; };
    static const IniRule iniRules[] = {
        {kFuzzyZZh, 19, 15}, {kFuzzyCCh, 20, 16}, {kFuzzySSh, 21, 17},
        {kFuzzyLN, 8, 7}, {kFuzzyFH, 4, 11}, {kFuzzyRL, 18, 8}};
    struct FinRule { int bit; const char* a; const char* b; };
    static const FinRule finRules[] = {
        {kFuzzyAnAng, "an", "ang"}, {kFuzzyEnEng, "en", "eng"}, {kFuzzyInIng, "in", "ing"},
        {kFuzzyIanIang, "ian", "iang"}, {kFuzzyUanUang, "uan", "uang"}};
    for (size_t t = 0; t < syls_.size(); t++) {
        const Syl& sy = syls_[t];
        std::string fin(sy.s + sy.iniLen, sy.len - sy.iniLen);
        for (const auto& r : iniRules) {
            if (!(bits & (1u << r.bit))) continue;
            if (sy.ini == r.a) add(t, std::string(kInitialText[r.b]) + fin);
            else if (sy.ini == r.b) add(t, std::string(kInitialText[r.a]) + fin);
        }
        std::string ini(sy.s, sy.iniLen);
        for (const auto& r : finRules) {
            if (!(bits & (1u << r.bit))) continue;
            if (fin == r.a) add(t, ini + r.b);
            else if (fin == r.b) add(t, ini + r.a);
        }
    }
    return alts;
}

// ---------------------------------------------------------------------------
// Xiaohe double pinyin
// ---------------------------------------------------------------------------

const Xiaohe& Xiaohe::get() {
    static Xiaohe inst;
    return inst;
}

Xiaohe::Xiaohe() {
    const SyllableTable& T = SyllableTable::get();
    std::memset(rev1_, 0, sizeof(rev1_));
    std::memset(rev2_, 0, sizeof(rev2_));
    for (int i = 0; i < 26; i++) { keyInitial_[i] = -1; second_[i] = 0; }

    // Initial keys.
    const char* direct = "bpmfdtnlgkhjqxrzcswy";
    for (const char* p = direct; *p; p++) keyInitial_[*p - 'a'] = T.initialOfLetter(*p);
    keyInitial_['u' - 'a'] = 17;  // sh
    keyInitial_['i' - 'a'] = 16;  // ch
    keyInitial_['v' - 'a'] = 15;  // zh

    // Final keys (official Xiaohe layout).
    static const char* finals[26][3] = {
        {"a"}, {"in"}, {"ao"}, {"ai"}, {"e"}, {"en"}, {"eng"}, {"ang"}, {"i"}, {"an"},
        {"ing", "uai"}, {"iang", "uang"}, {"ian"}, {"iao"}, {"o", "uo"}, {"ie"}, {"iu"}, {"uan"},
        {"ong", "iong"}, {"ue", "ve"}, {"u"}, {"ui", "v"}, {"ei"}, {"ia", "ua"}, {"un"}, {"ou"}};

    auto addCode = [&](char k1, char k2, int sid) {
        auto& v = pair_[(k1 - 'a') * 26 + (k2 - 'a')];
        if (std::find(v.begin(), v.end(), sid) == v.end()) v.push_back(static_cast<uint16_t>(sid));
        second_[k1 - 'a'] |= (1u << (k2 - 'a'));
        if (!rev1_[sid]) { rev1_[sid] = k1; rev2_[sid] = k2; }
    };

    for (int k1 = 0; k1 < 26; k1++) {
        int ini = keyInitial_[k1];
        if (ini < 0) continue;
        std::string is = T.initialText(ini);
        bool umlautInitial = (is == "j" || is == "q" || is == "x" || is == "y");
        bool nl = (is == "n" || is == "l");
        for (int k2 = 0; k2 < 26; k2++) {
            for (int f = 0; f < 3; f++) {
                const char* fin = finals[k2][f];
                if (!fin) break;
                std::string cand;
                std::string fs = fin;
                if (fs == "v") cand = umlautInitial ? is + "u" : is + "v";
                else if (fs == "ue" || fs == "ve") {
                    if (nl) cand = is + "ve";
                    else if (fs == "ue") cand = is + "ue";
                    else continue;
                } else cand = is + fs;
                int sid = T.find(cand.data(), static_cast<int>(cand.size()));
                if (sid >= 0) addCode(static_cast<char>('a' + k1), static_cast<char>('a' + k2), sid);
            }
        }
    }
    // Zero-initial rules.
    struct Z { char a, b; const char* syl; };
    static const Z zero[] = {
        {'a', 'a', "a"}, {'a', 'i', "ai"}, {'a', 'n', "an"}, {'a', 'h', "ang"}, {'a', 'o', "ao"},
        {'o', 'o', "o"}, {'o', 'u', "ou"}, {'e', 'e', "e"}, {'e', 'i', "ei"}, {'e', 'n', "en"},
        {'e', 'g', "eng"}, {'e', 'r', "er"}};
    for (const Z& z : zero) {
        int sid = T.find(z.syl, static_cast<int>(std::strlen(z.syl)));
        if (sid >= 0) addCode(z.a, z.b, sid);
    }
    // Prefer the longer spelling first (luo over lo).
    for (auto& v : pair_) {
        std::stable_sort(v.begin(), v.end(), [&](uint16_t a, uint16_t b) {
            return T.at(a).len > T.at(b).len;
        });
    }
}

bool Xiaohe::codeOf(int sid, char* k1, char* k2) const {
    if (sid < 0 || sid >= 512 || !rev1_[sid]) return false;
    *k1 = rev1_[sid];
    *k2 = rev2_[sid];
    return true;
}

}  // namespace ime
