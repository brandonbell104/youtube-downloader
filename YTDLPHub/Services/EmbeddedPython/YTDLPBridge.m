#import "YTDLPBridge.h"

// Absent until Scripts/fetch-python.sh has vendored Python.xcframework. The
// guard keeps the app compiling without it, with `available` reporting NO.
#if __has_include(<Python/Python.h>)
#import <Python/Python.h>
#define YTDLPHUB_HAS_PYTHON 1
#else
#define YTDLPHUB_HAS_PYTHON 0
#endif

NSErrorDomain const YTDLPBridgeErrorDomain = @"YTDLPBridgeErrorDomain";

/// Folder references copied verbatim into the bundle by the build.
static NSString *const kStdlibFolder = @"python-stdlib";
static NSString *const kPackagesFolder = @"python-packages";

@implementation YTDLPBridge {
    dispatch_queue_t _queue;
    BOOL _started;
    NSString *_startupFailure;
}

+ (YTDLPBridge *)shared {
    static YTDLPBridge *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[YTDLPBridge alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Serial: CPython is single-threaded, and one extraction at a time is
        // all the app ever needs.
        _queue = dispatch_queue_create("com.ytdlphub.python", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Availability

- (nullable NSString *)stdlibPath {
    return [[NSBundle mainBundle] pathForResource:kStdlibFolder ofType:nil];
}

- (nullable NSString *)packagesPath {
    return [[NSBundle mainBundle] pathForResource:kPackagesFolder ofType:nil];
}

- (BOOL)available {
#if !YTDLPHUB_HAS_PYTHON
    return NO;
#else
    NSString *stdlib = [self stdlibPath];
    NSString *packages = [self packagesPath];
    if (stdlib == nil || packages == nil) {
        return NO;
    }
    // yt-dlp itself, rather than just the folder, has to be there.
    NSString *ytDlp = [packages stringByAppendingPathComponent:@"yt_dlp"];
    return [[NSFileManager defaultManager] fileExistsAtPath:ytDlp];
#endif
}

#pragma mark - Public API

- (nullable NSString *)ytDlpVersion {
    NSString *json = [self callFunction:"version" withArgument:nil error:NULL];
    if (json == nil) {
        return nil;
    }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    id version = [parsed isKindOfClass:[NSDictionary class]] ? parsed[@"version"] : nil;
    return [version isKindOfClass:[NSString class]] ? version : nil;
}

- (nullable NSString *)resolveJSONForURL:(NSString *)url error:(NSError **)error {
    return [self callFunction:"resolve" withArgument:url error:error];
}

#pragma mark - Interpreter

- (nullable NSString *)callFunction:(const char *)function
                       withArgument:(nullable NSString *)argument
                              error:(NSError **)error {
#if !YTDLPHUB_HAS_PYTHON
    [self populate:error
              code:YTDLPBridgeErrorRuntimeUnavailable
           message:@"This build has no embedded Python runtime. Run Scripts/fetch-python.sh and rebuild."];
    return nil;
#else
    if (!self.available) {
        [self populate:error
                  code:YTDLPBridgeErrorRuntimeUnavailable
               message:@"The bundled Python runtime is incomplete. Run Scripts/fetch-python.sh and rebuild."];
        return nil;
    }

    __block NSString *result = nil;
    __block NSError *failure = nil;

    dispatch_sync(_queue, ^{
        if (![self startInterpreter:&failure]) {
            return;
        }

        PyGILState_STATE gil = PyGILState_Ensure();

        PyObject *module = PyImport_ImportModule("ytdlp_bridge");
        if (module == NULL) {
            PyErr_Clear();
            failure = [self errorWithCode:YTDLPBridgeErrorCallFailed
                                  message:@"The bundled ytdlp_bridge module could not be imported."];
            PyGILState_Release(gil);
            return;
        }

        PyObject *value = argument != nil
            ? PyObject_CallMethod(module, function, "s", [argument UTF8String])
            : PyObject_CallMethod(module, function, NULL);
        Py_DECREF(module);

        if (value == NULL) {
            PyErr_Clear();
            failure = [self errorWithCode:YTDLPBridgeErrorCallFailed
                                  message:@"yt-dlp failed in a way it could not report."];
            PyGILState_Release(gil);
            return;
        }

        const char *utf8 = PyUnicode_AsUTF8(value);
        if (utf8 != NULL) {
            result = [NSString stringWithUTF8String:utf8];
        } else {
            PyErr_Clear();
            failure = [self errorWithCode:YTDLPBridgeErrorCallFailed
                                  message:@"yt-dlp returned something that was not text."];
        }
        Py_DECREF(value);

        PyGILState_Release(gil);
    });

    if (result == nil && error != NULL) {
        *error = failure ?: [self errorWithCode:YTDLPBridgeErrorCallFailed message:@"yt-dlp produced no result."];
    }
    return result;
#endif
}

#if YTDLPHUB_HAS_PYTHON

/// Boots CPython once, pointed at the folders inside the app bundle.
/// Must be called on `_queue`.
- (BOOL)startInterpreter:(NSError **)error {
    if (_started) {
        return YES;
    }
    if (_startupFailure != nil) {
        // A failed boot is permanent; Py_InitializeFromConfig cannot be retried
        // meaningfully in the same process.
        if (error != NULL) {
            *error = [self errorWithCode:YTDLPBridgeErrorInitializationFailed message:_startupFailure];
        }
        return NO;
    }

    NSString *stdlib = [self stdlibPath];
    NSString *packages = [self packagesPath];
    NSString *dynload = [stdlib stringByAppendingPathComponent:@"lib-dynload"];

    PyConfig config;
    // Isolated: ignore PYTHONPATH, the user site directory, and argv parsing.
    PyConfig_InitIsolatedConfig(&config);
    // The bundle is read-only, so .pyc files can never be written.
    config.write_bytecode = 0;
    config.user_site_directory = 0;
    config.module_search_paths_set = 1;

    PyStatus status = PyConfig_SetBytesString(&config, &config.home, [stdlib UTF8String]);
    if (PyStatus_Exception(status)) {
        return [self failStartup:&config status:status error:error];
    }

    NSArray<NSString *> *searchPaths = @[stdlib, dynload, packages];
    for (NSString *path in searchPaths) {
        wchar_t *wide = Py_DecodeLocale([path UTF8String], NULL);
        if (wide == NULL) {
            continue;
        }
        status = PyWideStringList_Append(&config.module_search_paths, wide);
        PyMem_RawFree(wide);
        if (PyStatus_Exception(status)) {
            return [self failStartup:&config status:status error:error];
        }
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return [self failStartup:NULL status:status error:error];
    }

    // Py_InitializeFromConfig leaves the GIL held by this thread. Release it so
    // later calls can take it via PyGILState_Ensure from whichever thread the
    // queue happens to be running on.
    PyEval_SaveThread();

    _started = YES;
    return YES;
}

- (BOOL)failStartup:(nullable PyConfig *)config
             status:(PyStatus)status
              error:(NSError **)error {
    if (config != NULL) {
        PyConfig_Clear(config);
    }
    NSString *detail = status.err_msg != NULL
        ? [NSString stringWithUTF8String:status.err_msg]
        : @"unknown error";
    _startupFailure = [NSString stringWithFormat:@"The embedded Python runtime failed to start: %@.", detail];
    if (error != NULL) {
        *error = [self errorWithCode:YTDLPBridgeErrorInitializationFailed message:_startupFailure];
    }
    return NO;
}

#endif

#pragma mark - Errors

- (NSError *)errorWithCode:(YTDLPBridgeErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:YTDLPBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)populate:(NSError **)error code:(YTDLPBridgeErrorCode)code message:(NSString *)message {
    if (error != NULL) {
        *error = [self errorWithCode:code message:message];
    }
}

@end
