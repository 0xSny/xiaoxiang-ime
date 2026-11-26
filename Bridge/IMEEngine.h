// Objective-C++ bridge between the pure C++17 engine and Swift.
// Candidate texts stay inside the C++ result pool and are converted to NSString lazily, only for
// the handful of cells that are actually visible.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Layout-identical to ime::KeyStroke (uint8 n; char c[3]; float p[3]).
typedef struct {
    uint8_t n;
    char c[3];
    float p[3];
} IMEKeyStroke;

typedef NS_OPTIONS(NSUInteger, IMECandidateFlags) {
    IMECandidateFlagUser = 1,
    IMECandidateFlagSentence = 2,
    IMECandidateFlagRaw = 4,
    IMECandidateFlagCompletion = 8,
    IMECandidateFlagCorrected = 16,
};

@interface IMEResult : NSObject
@property (nonatomic, readonly) NSInteger count;
@property (nonatomic, readonly) NSInteger rawLength;
@property (nonatomic, readonly) BOOL fullCover;
- (NSString *)textAtIndex:(NSInteger)index;
- (NSInteger)consumedAtIndex:(NSInteger)index;
- (NSUInteger)flagsAtIndex:(NSInteger)index;
- (NSInteger)syllableCountAtIndex:(NSInteger)index;
- (NSInteger)characterCountAtIndex:(NSInteger)index;
@end

// A selected candidate, kept opaque; handed back to the engine for learning.
@interface IMEPick : NSObject
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSInteger consumed;
@property (nonatomic, readonly) BOOL isUser;
@property (nonatomic, readonly) BOOL isRaw;
@end

@interface IMEEngine : NSObject
@property (nonatomic, readonly) BOOL dictionaryLoaded;
@property (nonatomic, readonly, copy) NSString *loadError;

- (instancetype)initWithDictionaryPath:(NSString *)path;

- (void)applySettingsScheme:(NSInteger)scheme
                      fuzzy:(NSInteger)fuzzy
                    jianpin:(BOOL)jianpin
                 correction:(BOOL)correction
             spatialScale:(float)spatialScale
                   learning:(BOOL)learning
                 completion:(BOOL)completion;

- (void)openUserDataAtPath:(NSString *)path;
- (void)flushUserForce:(BOOL)force completion:(nullable void (^)(void))completion;

// Lock-free generation token: bump on every keystroke; older decodes abort themselves.
- (uint64_t)bumpGeneration;
- (void)decodeKeys:(const IMEKeyStroke *)keys
             count:(NSInteger)count
        generation:(uint64_t)generation
        completion:(void (^)(IMEResult *result, uint64_t generation))completion;

// Main-thread helpers (pure, allocation-light).
- (NSString *)quickSegmentLetters:(const char *)letters count:(NSInteger)count scheme:(NSInteger)scheme expand:(BOOL)expand;
- (void)nextLetterPriorLetters:(const char *)letters count:(NSInteger)count scheme:(NSInteger)scheme out:(float *)out26;

- (nullable IMEPick *)pickWithResult:(IMEResult *)result index:(NSInteger)index;
- (void)commitPicks:(NSArray<IMEPick *> *)picks;
- (void)rollbackLastCommit;
- (void)deletePick:(IMEPick *)pick;
- (void)resetUserData;
- (void)resetContext;
- (void)userStats:(void (^)(NSInteger words, NSInteger bigrams))completion;

@end

NS_ASSUME_NONNULL_END
