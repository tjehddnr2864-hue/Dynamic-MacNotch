// MediaRemote 어댑터: Apple 서명 바이너리(/usr/bin/perl)에 로드되어 시스템 Now Playing 정보를
// 한 줄짜리 JSON으로 stdout에 흘려보내고, stdin 명령(toggle/next/prev/seek <초>)을 실행한다.
// macOS 15.4+에서 서드파티 프로세스의 MediaRemote 직접 호출이 막혀 이 방식을 쓴다 (가이드라인 5.7).
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientBundleFn)(id);

static GetInfoFn getInfo;
static GetPlayingFn getPlaying;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static GetClientFn getClient;
static ClientBundleFn clientBundle;
static NSUInteger lastArtworkHash;

static id S(NSDictionary *d, NSString *key) {
    id v = d[key];
    return v ?: [NSNull null];
}

static void emit(void) {
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef ref) {
        NSDictionary *info = (__bridge NSDictionary *)ref;
        getPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            void (^finish)(NSString *) = ^(NSString *bundle) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = @(playing);
                out[@"bundle"] = bundle ?: (id)[NSNull null];
                out[@"title"] = S(info, @"kMRMediaRemoteNowPlayingInfoTitle");
                out[@"artist"] = S(info, @"kMRMediaRemoteNowPlayingInfoArtist");
                out[@"album"] = S(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
                out[@"duration"] = S(info, @"kMRMediaRemoteNowPlayingInfoDuration");
                out[@"elapsed"] = S(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
                out[@"rate"] = S(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
                NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = ts ? @([ts timeIntervalSince1970]) : (id)[NSNull null];
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                // 앨범아트는 바뀌었을 때만 보낸다 (줄 길이 절약).
                if (art && art.hash != lastArtworkHash) {
                    lastArtworkHash = art.hash;
                    out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                } else if (!art) {
                    lastArtworkHash = 0;
                }
                if (info == nil) out[@"empty"] = @YES;
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                if (json) {
                    fwrite(json.bytes, 1, json.length, stdout);
                    fputc('\n', stdout);
                    fflush(stdout);
                }
            };
            if (getClient && clientBundle) {
                getClient(dispatch_get_main_queue(), ^(id client) {
                    finish(client ? (__bridge NSString *)clientBundle(client) : nil);
                });
            } else {
                finish(nil);
            }
        });
    });
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char line[256];
        while (fgets(line, sizeof line, stdin)) {
            NSString *cmd = [[NSString stringWithUTF8String:line]
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([cmd isEqualToString:@"toggle"]) sendCommand(2, NULL);
                else if ([cmd isEqualToString:@"next"]) sendCommand(4, NULL);
                else if ([cmd isEqualToString:@"prev"]) sendCommand(5, NULL);
                else if ([cmd hasPrefix:@"seek "] && setElapsed) setElapsed([[cmd substringFromIndex:5] doubleValue]);
                else if ([cmd isEqualToString:@"refresh"]) emit();
            });
        }
        exit(0);   // 앱이 종료되어 stdin이 닫히면 함께 끝난다
    });
}

// perl의 DynaLoader::dl_install_xsub로 불리는 진입점. 인자는 쓰지 않는다.
void adapter_run(void *interp, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stdout, "{\"error\":\"load\"}\n"); fflush(stdout); exit(1); }
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    RegisterFn reg = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getPlaying || !sendCommand || !reg) { fprintf(stdout, "{\"error\":\"symbols\"}\n"); fflush(stdout); exit(1); }

    reg(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *n) { emit(); }];
    }
    readCommands();
    emit();
    CFRunLoopRun();
}
