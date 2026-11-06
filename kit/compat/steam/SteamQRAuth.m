// QR/protobuf principles selectively adapted from AgePad SteamQRSignIn.m.
// Copyright (c)2026 Chris Sotraidis; MIT permission notice in NOTICE.md.
// Field numbers verified against the pinned Valve client's embedded descriptor.
#import "SteamQRAuth.h"
#import <CoreImage/CoreImage.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static atomic_bool AuthAttempted,AuthCancelled;
void TFMSteamCancelQRAuthentication(void) { atomic_store(&AuthCancelled,true); }
BOOL TFMSteamQRAuthenticationCancelled(void) { return atomic_load(&AuthCancelled); }

static void PutVarint(NSMutableData *data,uint64_t value) {
    do { uint8_t byte=value&127; value>>=7; if (value) byte|=128; [data appendBytes:&byte length:1]; } while (value);
}
static void PutInteger(NSMutableData *data,int field,uint64_t value) { PutVarint(data,(uint64_t)field<<3); PutVarint(data,value); }
static void PutBytes(NSMutableData *data,int field,NSData *bytes) { PutVarint(data,((uint64_t)field<<3)|2); PutVarint(data,bytes.length); [data appendData:bytes]; }
static void PutString(NSMutableData *data,int field,NSString *value) { PutBytes(data,field,[value dataUsingEncoding:NSUTF8StringEncoding]); }
static BOOL Varint(const uint8_t *data,NSUInteger size,NSUInteger *offset,uint64_t *value) {
    *value=0;
    for (unsigned shift=0;shift<64 && *offset<size;shift+=7) {
        uint8_t byte=data[(*offset)++];
        if (shift==63 && (byte&0xfe)) return NO;
        *value|=(uint64_t)(byte&127)<<shift;
        if (!(byte&128)) return YES;
    }
    return NO;
}
static NSDictionary *ParseProtobuf(NSData *input) {
    const uint8_t *bytes=input.bytes; NSUInteger offset=0; NSMutableDictionary *fields=[NSMutableDictionary dictionary];
    while (offset<input.length) {
        uint64_t key=0,value=0;
        if (!Varint(bytes,input.length,&offset,&key) || !(key>>3)) return nil;
        NSNumber *field=@(key>>3); unsigned wire=(unsigned)(key&7);
        if (wire==0) { if (!Varint(bytes,input.length,&offset,&value)) return nil; fields[field]=@(value); }
        else if (wire==2) {
            if (!Varint(bytes,input.length,&offset,&value) || value>input.length-offset) return nil;
            fields[field]=[input subdataWithRange:NSMakeRange(offset,(NSUInteger)value)]; offset+=(NSUInteger)value;
        } else if (wire==5) {
            if (input.length-offset<4) return nil;
            float number; memcpy(&number,bytes+offset,4); fields[field]=@(number); offset+=4;
        } else if (wire==1) {
            if (input.length-offset<8) return nil;
            memcpy(&value,bytes+offset,8); fields[field]=@(value); offset+=8;
        } else return nil;
    }
    return fields;
}
static NSString *Text(id field) {
    if ([field isKindOfClass:NSString.class]) return field;
    return [field isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:field encoding:NSUTF8StringEncoding] : nil;
}
static NSDictionary *NormalizeJSON(NSDictionary *object,BOOL begin) {
    NSDictionary *response=[object[@"response"] isKindOfClass:NSDictionary.class] ? object[@"response"] : object;
    NSDictionary *names=begin ? @{@"client_id":@1,@"challenge_url":@2,@"request_id":@3,@"interval":@4} : @{@"new_client_id":@1,@"new_challenge_url":@2,@"refresh_token":@3,@"access_token":@4,@"had_remote_interaction":@5,@"account_name":@6,@"new_guard_data":@7,@"agreement_session_url":@8};
    NSMutableDictionary *fields=[NSMutableDictionary dictionary];
    for (NSString *name in names) if (response[name]) fields[names[name]]=response[name];
    if (begin && [fields[@3] isKindOfClass:NSString.class]) fields[@3]=[[NSData alloc] initWithBase64EncodedString:fields[@3] options:0];
    return fields;
}

@interface TFMSteamAuthHTTPDelegate : NSObject <NSURLSessionTaskDelegate> @end
@implementation TFMSteamAuthHTTPDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)session; (void)task; (void)response;
    BOOL allowed=[request.URL.scheme isEqual:@"https"] && [request.URL.host isEqual:@"api.steampowered.com"] && [request.URL.path hasPrefix:@"/IAuthenticationService/"];
    completionHandler(allowed ? request : nil);
}
@end

static BOOL Publish(NSMutableDictionary *report,NSURL *url,NSString *phase,TFMSteamAuthStatusHandler onStatus) {
    report[@"phase"]=phase;
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    BOOL saved=json && [json writeToURL:url options:NSDataWritingAtomic error:NULL];
    // Phase codes only. Never log URL/request/response/credential contents.
    fprintf(stderr,"TFM_STEAM_QR phase=%s\n",phase.UTF8String); fflush(stderr);
    if (onStatus) dispatch_async(dispatch_get_main_queue(),^{onStatus(phase);});
    return saved;
}
static NSDictionary *Call(NSURLSession *session,NSString *method,NSData *body,NSTimeInterval deadline,NSMutableDictionary *report) {
    NSTimeInterval remaining=deadline-NSProcessInfo.processInfo.systemUptime;
    if (remaining<=0 || TFMSteamQRAuthenticationCancelled()) return nil;
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"https://api.steampowered.com/IAuthenticationService/%@/v1/",method]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:MIN(20,remaining)];
    request.HTTPMethod=@"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSString *encoded=[[body base64EncodedStringWithOptions:0] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    request.HTTPBody=[[@"input_protobuf_encoded=" stringByAppendingString:encoded] dataUsingEncoding:NSUTF8StringEncoding];
    __block NSData *reply=nil; __block NSHTTPURLResponse *response=nil; __block NSError *failure=nil;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *result,NSError *error) {
        reply=data; response=[result isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)result : nil; failure=error; dispatch_semaphore_signal(done);
    }];
    [task resume]; NSTimeInterval callDeadline=MIN(deadline,NSProcessInfo.processInfo.systemUptime+20);
    while (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))) {
        if (TFMSteamQRAuthenticationCancelled() || NSProcessInfo.processInfo.systemUptime>=callDeadline) { [task cancel]; report[@"failure_code"]=TFMSteamQRAuthenticationCancelled() ? @"cancelled" : @"https_request_timeout"; return nil; }
    }
    report[@"last_http_status"]=@(response.statusCode);
    if (failure) { report[@"transport_error_code"]=@(failure.code); report[@"failure_code"]=@"https_transport_failed"; return nil; }
    if (!response || response.statusCode!=200 || reply.length>1024*1024) { report[@"failure_code"]=@"unexpected_http_response"; return nil; }
    NSString *header=[response valueForHTTPHeaderField:@"x-eresult"];
    NSInteger eresult=header ? header.integerValue : 1; report[@"last_eresult"]=@(eresult);
    if (eresult!=1) { report[@"failure_code"]=@"steam_authentication_service_refused"; return nil; }
    id json=[NSJSONSerialization JSONObjectWithData:reply options:0 error:NULL];
    NSDictionary *result=[json isKindOfClass:NSDictionary.class] ? NormalizeJSON(json,[method isEqual:@"BeginAuthSessionViaQR"]) : ParseProtobuf(reply);
    if (!result) report[@"failure_code"]=@"invalid_authentication_response_encoding";
    return result;
}
static BOOL ValidChallenge(NSString *value) {
    NSURL *url=value ? [NSURL URLWithString:value] : nil;
    return url && [url.scheme isEqual:@"https"] && [url.host isEqual:@"s.team"] && [url.path hasPrefix:@"/q/"] && !url.user.length && !url.password.length;
}
static UIImage *QRCode(NSString *challenge) {
    CIFilter *filter=[CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[challenge dataUsingEncoding:NSISOLatin1StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *code=filter.outputImage; if (!code) return nil;
    CGRect extent=CGRectIntegral(code.extent); CGFloat unit=floor(768/(extent.size.width+8)); if (unit<1) return nil;
    CGImageRef image=[[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}] createCGImage:code fromRect:extent];
    if (!image) return nil;
    CGFloat size=(extent.size.width+8)*unit;
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat]; format.scale=1; format.opaque=YES;
    UIImage *result=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size,size) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.whiteColor setFill]; UIRectFill(CGRectMake(0,0,size,size));
        CGContextSetInterpolationQuality(context.CGContext,kCGInterpolationNone);
        [[UIImage imageWithCGImage:image] drawInRect:CGRectMake(4*unit,4*unit,extent.size.width*unit,extent.size.height*unit)];
    }];
    CGImageRelease(image); return result;
}
static BOOL IdentityFromFreshToken(NSString *token,uint64_t *identity) {
    NSArray *parts=[token componentsSeparatedByString:@"."]; if (parts.count!=3) return NO;
    NSString *part=[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    part=[part stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (part.length%4) part=[part stringByAppendingString:@"="];
    NSData *data=[[NSData alloc] initWithBase64EncodedString:part options:0];
    id claims=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSString *subject=[claims isKindOfClass:NSDictionary.class] && [claims[@"sub"] isKindOfClass:NSString.class] ? claims[@"sub"] : nil;
    if (!subject.length || subject.length>20 || [subject rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound) return NO;
    const char *text=subject.UTF8String; char *end=NULL; errno=0; unsigned long long number=strtoull(text,&end,10);
    if (errno || !number || !end || *end) return NO;
    *identity=number; return YES;
}

NSDictionary *TFMSteamQRAuthenticate(NSTimeInterval timeout,TFMSteamQRCodeHandler onQRCode,TFMSteamAuthStatusHandler onStatus,TFMSteamFreshTokenConsumer consume) {
    NSMutableDictionary *report=[@{@"schema_version":@1,@"status":@"starting",@"protocol":@"Steam-client audience QR authentication via genuine HTTPS service",
        @"scope":@"HTTPS module only; native client cache persistence is not measured",
        @"password_requested":@NO,@"existing_account_or_token_read":@NO,@"toolkit_token_persistence":@"memory_only_no_keychain",@"credentials_recorded":@NO,
        @"qr_url_recorded":@NO,@"steam_engine_logged_on_claimed":@NO,@"token_consumed_by_engine":@NO,@"poll_count":@0,@"qr_update_count":@0} mutableCopy];
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *progress=[documents URLByAppendingPathComponent:@"steam-auth-progress.json"];
    if (!Publish(report,progress,@"auth_preconditions",onStatus)) return @{@"status":@"failed",@"failure_code":@"auth_progress_file_unwritable"};
    bool expected=false;
    if (NSThread.isMainThread || !onQRCode || !consume || !isfinite(timeout) || timeout<=0 || !atomic_compare_exchange_strong(&AuthAttempted,&expected,true)) {
        report[@"status"]=@"failed"; report[@"failure_code"]=@"background_single_fresh_session_and_callbacks_required"; Publish(report,progress,@"failed",onStatus); return report;
    }
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+MIN(timeout,240);
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPCookieStorage=nil; configuration.HTTPShouldSetCookies=NO; configuration.URLCredentialStorage=nil; configuration.URLCache=nil;
    configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData; configuration.timeoutIntervalForRequest=20; configuration.timeoutIntervalForResource=20;
    TFMSteamAuthHTTPDelegate *delegate=[TFMSteamAuthHTTPDelegate new];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
    @try {
        do {
            if (TFMSteamQRAuthenticationCancelled()) { report[@"failure_code"]=@"cancelled"; break; }
            NSMutableData *details=[NSMutableData data],*begin=[NSMutableData data];
            PutString(details,1,@"TFM2 iPad diagnostic"); PutInteger(details,2,1);
            PutString(begin,1,@"TFM2 iPad diagnostic"); PutInteger(begin,2,1); PutBytes(begin,3,details); PutString(begin,4,@"Client");
            if (!Publish(report,progress,@"requesting_fresh_qr",onStatus)) { report[@"failure_code"]=@"auth_progress_file_unwritable"; break; }
            NSDictionary *started=Call(session,@"BeginAuthSessionViaQR",begin,deadline,report);
            uint64_t clientID=[started[@1] respondsToSelector:@selector(unsignedLongLongValue)] ? [started[@1] unsignedLongLongValue] : 0;
            NSData *requestID=[started[@3] isKindOfClass:NSData.class] ? started[@3] : nil;
            NSString *challenge=Text(started[@2]);
            double interval=[started[@4] respondsToSelector:@selector(doubleValue)] ? [started[@4] doubleValue] : 5;
            if (!started || !clientID || !requestID.length || !ValidChallenge(challenge) || !isfinite(interval) || interval<=0) { if (!report[@"failure_code"]) report[@"failure_code"]=@"invalid_begin_qr_fields"; break; }
            interval=MAX(1,interval); UIImage *image=QRCode(challenge);
            if (!image) { report[@"failure_code"]=@"qr_image_generation_failed"; break; }
            report[@"qr_update_count"]=@1; report[@"status"]=@"awaiting_user_scan";
            dispatch_async(dispatch_get_main_queue(),^{onQRCode(image);}); Publish(report,progress,@"awaiting_mobile_approval",onStatus);
            BOOL approved=NO;
            while (NSProcessInfo.processInfo.systemUptime<deadline && !TFMSteamQRAuthenticationCancelled()) {
                NSTimeInterval next=MIN(deadline,NSProcessInfo.processInfo.systemUptime+interval);
                while (NSProcessInfo.processInfo.systemUptime<next && !TFMSteamQRAuthenticationCancelled()) usleep(100000);
                if (TFMSteamQRAuthenticationCancelled() || NSProcessInfo.processInfo.systemUptime>=deadline) break;
                NSMutableData *poll=[NSMutableData data]; PutInteger(poll,1,clientID); PutBytes(poll,2,requestID);
                NSDictionary *answer=Call(session,@"PollAuthSessionStatus",poll,deadline,report);
                report[@"poll_count"]=@([report[@"poll_count"] unsignedIntegerValue]+1);
                if (!answer) break;
                if ([answer[@1] respondsToSelector:@selector(unsignedLongLongValue)] && [answer[@1] unsignedLongLongValue]) clientID=[answer[@1] unsignedLongLongValue];
                NSString *nextChallenge=Text(answer[@2]);
                if (nextChallenge.length && ![nextChallenge isEqual:challenge]) {
                    if (!ValidChallenge(nextChallenge)) { report[@"failure_code"]=@"invalid_rotated_qr_url"; break; }
                    challenge=nextChallenge; UIImage *updated=QRCode(challenge);
                    if (!updated) { report[@"failure_code"]=@"qr_image_generation_failed"; break; }
                    report[@"qr_update_count"]=@([report[@"qr_update_count"] unsignedIntegerValue]+1);
                    dispatch_async(dispatch_get_main_queue(),^{onQRCode(updated);});
                }
                if (Text(answer[@8]).length) { report[@"failure_code"]=@"steam_additional_agreement_confirmation_required"; break; }
                NSString *token=Text(answer[@3]);
                if (token.length) {
                    NSString *account=Text(answer[@6]); uint64_t identity=0;
                    if (token.length>32768 || !account.length || account.length>256 || !IdentityFromFreshToken(token,&identity)) { report[@"failure_code"]=@"invalid_fresh_token_or_account_routing_fields"; break; }
                    if (TFMSteamQRAuthenticationCancelled()) break;
                    report[@"qr_approval_received"]=@YES;
                    if (!Publish(report,progress,@"mobile_approval_received",onStatus)) { report[@"failure_code"]=@"auth_progress_file_unwritable"; break; }
                    dispatch_async(dispatch_get_main_queue(),^{onQRCode(nil);});
                    BOOL consumed=consume(token,account,identity);
                    report[@"token_consumed_by_engine"]=@(consumed); approved=consumed;
                    if (!consumed) report[@"failure_code"]=@"guarded_engine_token_consumer_rejected";
                    break;
                }
                Publish(report,progress,@"awaiting_mobile_approval",onStatus);
            }
            if (approved) { report[@"status"]=@"qr_approved_token_delivered_to_engine"; break; }
            if (!report[@"failure_code"]) report[@"failure_code"]=TFMSteamQRAuthenticationCancelled() ? @"cancelled" : @"qr_approval_timeout";
        } while (0);
    } @catch (__unused NSException *exception) {
        report[@"failure_code"]=@"auth_protocol_exception";
    } @finally {
        [session invalidateAndCancel];
        dispatch_async(dispatch_get_main_queue(),^{onQRCode(nil);});
    }
    if (report[@"failure_code"]) report[@"status"]=TFMSteamQRAuthenticationCancelled() ? @"cancelled" : @"failed";
    Publish(report,progress,report[@"status"],onStatus);
    return [report copy];
}
