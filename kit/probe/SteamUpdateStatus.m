#import "SteamUpdateStatus.h"
#import "../compat/steam/SteamAppInfo.h"
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

static NSString *DateString(NSDate *date) {
    return date ? [[NSISO8601DateFormatter new] stringFromDate:date] : nil;
}
static NSData *ReadBounded(NSURL *url,NSUInteger maximum,NSDictionary **attributes,NSString **failure) {
    if(!url.isFileURL) {*failure=@"invalid_location";return nil;}
    NSDictionary *before=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
    if (!before) {*failure=@"missing_or_unreadable";return nil;}
    if (![before[NSFileType] isEqual:NSFileTypeRegular] || [before[NSFileSize] unsignedLongLongValue]>maximum) {
        *failure=@"not_regular_or_oversized";return nil;
    }
    NSError *error=nil;NSFileHandle *handle=[NSFileHandle fileHandleForReadingFromURL:url error:&error];
    if (!handle) {*failure=@"unreadable";return nil;}
    NSData *data=nil;
    @try {data=[handle readDataUpToLength:maximum+1 error:&error];}
    @catch (__unused NSException *exception) {error=[NSError errorWithDomain:@"TFMUpdateRead" code:1 userInfo:nil];}
    @finally {[handle closeAndReturnError:NULL];}
    NSDictionary *after=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
    if (!data || error || data.length>maximum || ![before[NSFileSize] isEqual:after[NSFileSize]] ||
        ![before[NSFileModificationDate] isEqual:after[NSFileModificationDate]] || data.length!=[after[NSFileSize] unsignedLongLongValue]) {
        *failure=@"read_failed_or_file_changed";return nil;
    }
    if(attributes)*attributes=after;return data;
}
static uint32_t BuildID(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length]>10) return 0;
    uint64_t result=0;
    for(NSUInteger i=0;i<[value length];i++) {
        unichar c=[value characterAtIndex:i];if(c<'0' || c>'9')return 0;
        result=result*10+(c-'0');if(result>INT32_MAX)return 0;
    }
    return (uint32_t)result;
}
NSDictionary *TFMCheckCachedGameUpdateAtURLs(NSURL *installedURL,NSURL *cacheURL) {
    NSMutableDictionary *result=[@{@"schema_version":@1,@"app_id":@3009300,@"status":@"unknown",
        @"installed_build_id":NSNull.null,@"cached_public_build_id":NSNull.null,@"cache_modified_at":NSNull.null,
        @"checked_at":DateString(NSDate.date),@"source":@"local_steam_appinfo_cache",
        @"server_freshness":@"unverified",@"network_request_initiated":@NO,@"download_started":@NO} mutableCopy];
    NSString *failure=nil;NSData *installed=ReadBounded(installedURL,65536,NULL,&failure);
    if(!installed) {result[@"reason"]=[@"installed_record_" stringByAppendingString:failure];return result;}
    id record=[NSJSONSerialization JSONObjectWithData:installed options:0 error:NULL];
    uint32_t have=[record isKindOfClass:NSDictionary.class] && [record[@"app_id"] isEqual:@"3009300"] ? BuildID(record[@"steam_build_id"]) : 0;
    if(!have) {result[@"reason"]=@"installed_record_missing_valid_build";return result;}
    result[@"installed_build_id"]=@(have);
    NSDictionary *attributes=nil;NSData *cache=ReadBounded(cacheURL,64u*1024u*1024u,&attributes,&failure);
    if(!cache) {result[@"reason"]=[@"cache_" stringByAppendingString:failure];return result;}
    result[@"cache_modified_at"]=DateString(attributes[NSFileModificationDate]) ?: NSNull.null;
    uint32_t cached=0;TFMAppInfoResult parsed=TFMReadCachedPublicBuild(cache.bytes,cache.length,3009300,&cached);
    if(parsed!=TFMAppInfoObserved) {
        result[@"reason"]=parsed==TFMAppInfoNotFound?@"cache_build_not_found":parsed==TFMAppInfoUnsupported?@"cache_format_or_type_unsupported":@"cache_malformed";
        return result;
    }
    result[@"cached_public_build_id"]=@(cached);
    result[@"status"]=cached>have?@"cached_newer_build":cached<have?@"cached_older_build":@"cached_same_build";
    result[@"reason"]=@"cached_observation_not_fresh_server_query";return result;
}
NSDictionary *TFMCheckCachedGameUpdate(void) {
    NSURL *record=[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"asset-stage.json"];
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return TFMCheckCachedGameUpdateAtURLs(record,[support URLByAppendingPathComponent:@"Steam/appcache/appinfo.vdf"]);
}
#if TARGET_OS_IOS
static void ShowNewerBuild(NSDictionary *status) {
    static BOOL shown=NO;
    if(shown || ![status[@"status"] isEqual:@"cached_newer_build"])return;
    UIWindow *window=nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(scene.activationState!=UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *candidate in ((UIWindowScene *)scene).windows)if(candidate.isKeyWindow){window=candidate;break;}
        if(window)break;
    }
    UIViewController *controller=window.rootViewController;
    while(controller.presentedViewController)controller=controller.presentedViewController;
    if(!controller.view.window || controller.isBeingDismissed || [controller isKindOfClass:UIAlertController.class])return;
    NSString *message=[NSString stringWithFormat:@"Steam 캐시에 이 iPad의 빌드 %@보다 새로운 빌드 %@가 기록되어 있습니다. 서버 최신 버전을 새로 조회한 결과는 아닙니다. Mac Steam에서 게임을 업데이트한 뒤 해당 버전을 검토하고 iPad 앱을 재빌드·서명해야 합니다. 자동 다운로드는 시작하지 않습니다.",status[@"installed_build_id"],status[@"cached_public_build_id"]];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"게임 업데이트 정보" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleDefault handler:nil]];
    shown=YES;[controller presentViewController:alert animated:YES completion:nil];
}
#endif
void TFMStartCachedGameUpdateChecks(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        dispatch_queue_t queue=dispatch_queue_create("org.tfm2pad.cached-update",DISPATCH_QUEUE_SERIAL);
        for(NSNumber *delay in @[@0,@20,@70])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),queue,^{
            @autoreleasepool {
                NSDictionary *status=TFMCheckCachedGameUpdate();
                NSData *json=[NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:NULL];
                NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
                [json writeToURL:[documents URLByAppendingPathComponent:@"steam-update-status.json"] options:NSDataWritingAtomic error:NULL];
#if TARGET_OS_IOS
                dispatch_async(dispatch_get_main_queue(),^{ShowNewerBuild(status);});
#endif
            }
        });
    });
}
