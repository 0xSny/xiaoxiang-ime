#import "IMEEngine.h"
#include <memory>
#include <vector>
#include "../Core/engine.hpp"

@interface IMEResult () {
@public
    std::shared_ptr<ime::Result> _r;
}
@end

@implementation IMEResult
- (NSInteger)count { return _r ? static_cast<NSInteger>(_r->cands.size()) : 0; }
- (NSInteger)rawLength { return _r ? _r->rawLen : 0; }
- (BOOL)fullCover { return _r ? _r->fullCover : NO; }
- (NSString *)textAtIndex:(NSInteger)index {
    if (!_r || index < 0 || index >= (NSInteger)_r->cands.size()) return @"";
    const ime::Candidate &c = _r->cands[index];
    NSString *s = [[NSString alloc] initWithBytes:_r->pool.data() + c.textOff length:c.textLen encoding:NSUTF8StringEncoding];
    return s ?: @"";
}
- (NSInteger)consumedAtIndex:(NSInteger)index {
    if (!_r || index < 0 || index >= (NSInteger)_r->cands.size()) return 0;
    return _r->cands[index].consumed;
}
- (NSUInteger)flagsAtIndex:(NSInteger)index {
    if (!_r || index < 0 || index >= (NSInteger)_r->cands.size()) return 0;
    return _r->cands[index].flags;
}
- (NSInteger)syllableCountAtIndex:(NSInteger)index {
    if (!_r || index < 0 || index >= (NSInteger)_r->cands.size()) return 0;
    return _r->cands[index].sylCount;
}
- (NSInteger)characterCountAtIndex:(NSInteger)index {
    if (!_r || index < 0 || index >= (NSInteger)_r->cands.size()) return 0;
    const ime::Candidate &c = _r->cands[index];
    return ime::utf8Length(_r->pool.data() + c.textOff, c.textLen);
}
@end

@interface IMEPick () {
@public
    ime::CommitSeg _seg;
    NSString *_text;
    NSInteger _consumed;
    BOOL _isUser;
    BOOL _isRaw;
}
@end

@implementation IMEPick
- (NSString *)text { return _text; }
- (NSInteger)consumed { return _consumed; }
- (BOOL)isUser { return _isUser; }
- (BOOL)isRaw { return _isRaw; }
@end

@implementation IMEEngine {
    std::unique_ptr<ime::Engine> _engine;
    dispatch_queue_t _queue;
    BOOL _loaded;
    NSString *_loadError;
}

- (instancetype)initWithDictionaryPath:(NSString *)path {
    self = [super init];
    if (self) {
        _engine.reset(new ime::Engine());
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _queue = dispatch_queue_create("com.custom.ime.decode", attr);
        std::string err;
        _loaded = _engine->loadDictionary(path.fileSystemRepresentation, &err);
        _loadError = [NSString stringWithUTF8String:err.c_str()] ?: @"";
    }
    return self;
}

- (BOOL)dictionaryLoaded { return _loaded; }
- (NSString *)loadError { return _loadError; }

- (void)applySettingsScheme:(NSInteger)scheme fuzzy:(NSInteger)fuzzy jianpin:(BOOL)jianpin correction:(BOOL)correction
               spatialScale:(float)spatialScale learning:(BOOL)learning completion:(BOOL)completion {
    ime::EngineSettings s;
    s.scheme = (int)scheme;
    s.fuzzy = (uint16_t)(fuzzy & 0x7FF);
    s.jianpin = jianpin;
    s.correction = correction;
    s.spatialScale = spatialScale;
    s.learning = learning;
    s.completion = completion;
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{ e->setSettings(s); });
}

- (void)openUserDataAtPath:(NSString *)path {
    std::string p = path.fileSystemRepresentation;
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{ e->openUserData(p.c_str()); });
}

- (void)flushUserForce:(BOOL)force completion:(void (^)(void))completion {
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{
        e->flushUser(force);
        if (completion) completion();
    });
}

- (uint64_t)bumpGeneration { return _engine->bumpGeneration(); }

- (void)decodeKeys:(const IMEKeyStroke *)keys count:(NSInteger)count generation:(uint64_t)generation
        completion:(void (^)(IMEResult *, uint64_t))completion {
    std::vector<ime::KeyStroke> copy(count > 0 ? (size_t)count : 0);
    if (count > 0) memcpy(copy.data(), keys, sizeof(ime::KeyStroke) * (size_t)count);
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{
        if (e->generation() != generation) return;  // superseded before it even started
        std::shared_ptr<ime::Result> r = e->decode(copy.data(), (int)copy.size(), generation);
        if (!r || e->generation() != generation) return;
        IMEResult *res = [IMEResult new];
        res->_r = r;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(res, generation); });
    });
}

- (NSString *)quickSegmentLetters:(const char *)letters count:(NSInteger)count scheme:(NSInteger)scheme expand:(BOOL)expand {
    std::string s = _engine->quickSegment(letters, (int)count, (int)scheme, expand);
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)nextLetterPriorLetters:(const char *)letters count:(NSInteger)count scheme:(NSInteger)scheme out:(float *)out26 {
    _engine->nextLetterPrior(letters, (int)count, (int)scheme, out26);
}

- (IMEPick *)pickWithResult:(IMEResult *)result index:(NSInteger)index {
    if (!result->_r || index < 0 || index >= (NSInteger)result->_r->cands.size()) return nil;
    const ime::Result &r = *result->_r;
    const ime::Candidate &c = r.cands[index];
    IMEPick *p = [IMEPick new];
    p->_seg.text.assign(r.pool.data() + c.textOff, c.textLen);
    p->_seg.syls.assign(r.syls.begin() + c.sylOff, r.syls.begin() + c.sylOff + c.sylCount);
    p->_seg.baseLn = c.baseLn;
    p->_seg.key = c.key;
    p->_seg.wordId = c.wordId;
    p->_seg.raw = (c.flags & ime::kCandRaw) != 0;
    p->_seg.weak = (c.consumed == 1);  // a lone initial letter must never enter the user dictionary
    p->_text = [[NSString alloc] initWithBytes:p->_seg.text.data() length:p->_seg.text.size() encoding:NSUTF8StringEncoding] ?: @"";
    p->_consumed = c.consumed;
    p->_isUser = (c.flags & ime::kCandUser) != 0;
    p->_isRaw = p->_seg.raw;
    return p;
}

- (void)commitPicks:(NSArray<IMEPick *> *)picks {
    std::vector<ime::CommitSeg> segs;
    segs.reserve(picks.count);
    for (IMEPick *p in picks) segs.push_back(p->_seg);
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{ e->commit(segs); });
}

- (void)rollbackLastCommit {
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{ e->rollbackLastCommit(); });
}

- (void)deletePick:(IMEPick *)pick {
    std::vector<uint16_t> syls = pick->_seg.syls;
    std::string text = pick->_seg.text;
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{ e->deleteUserWord(syls, text); });
}

- (void)resetUserData {
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{ e->resetUserData(); e->flushUser(true); });
}

- (void)resetContext {
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{ e->resetContext(); });
}

- (void)userStats:(void (^)(NSInteger, NSInteger))completion {
    ime::Engine *e = _engine.get();
    dispatch_async(_queue, ^{
        NSInteger w = (NSInteger)e->userWordCount(), b = (NSInteger)e->userBigramCount();
        dispatch_async(dispatch_get_main_queue(), ^{ completion(w, b); });
    });
}

@end
