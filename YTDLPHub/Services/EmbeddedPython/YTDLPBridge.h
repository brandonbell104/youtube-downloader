#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const YTDLPBridgeErrorDomain;

typedef NS_ERROR_ENUM(YTDLPBridgeErrorDomain, YTDLPBridgeErrorCode) {
    YTDLPBridgeErrorRuntimeUnavailable = 1,
    YTDLPBridgeErrorInitializationFailed = 2,
    YTDLPBridgeErrorCallFailed = 3,
};

/// Hosts an embedded CPython interpreter and calls yt-dlp inside it.
///
/// iOS forbids spawning subprocesses, so yt-dlp cannot be run as a program.
/// It can, however, be imported as a library: the interpreter and yt-dlp's
/// pure-Python source both ship inside the app bundle, signed as part of the
/// app, and `resolve` calls straight into them. Nothing is downloaded or
/// executed at runtime beyond what shipped with the build.
///
/// Every call is serialised onto one queue and takes the GIL, so this is safe
/// to call from anywhere but will not run two extractions at once.
@interface YTDLPBridge : NSObject

@property (class, nonatomic, readonly) YTDLPBridge *shared;

/// YES when the runtime and the bundled packages are all present. NO means the
/// build was made without running `Scripts/fetch-python.sh`; callers should
/// fall back to another resolver rather than showing an error.
@property (nonatomic, readonly) BOOL available;

/// The bundled yt-dlp version, or nil if it can't be determined.
- (nullable NSString *)ytDlpVersion;

/// Runs `ytdlp_bridge.resolve(url)` and returns the JSON string it produced.
/// The JSON itself may describe a failure via an `error` key — that is yt-dlp
/// declining the link, not a bridge fault, and is reported through the JSON
/// rather than through `error`.
- (nullable NSString *)resolveJSONForURL:(NSString *)url error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
