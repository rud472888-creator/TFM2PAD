#import "SteamCredentialStore.h"
#import <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const Service=@"org.tfm2pad.steam-login.v1";
static NSString *const Account=@"active";

@interface TFMSteamCredentialRecord ()
@property(nonatomic,readwrite,copy) NSString *refreshToken;
@property(nonatomic,readwrite,copy) NSString *accountName;
@property(nonatomic,readwrite) uint64_t steamID;
@end
@implementation TFMSteamCredentialRecord
- (NSString *)description {return @"<TFMSteamCredentialRecord redacted>";}
- (NSString *)debugDescription {return self.description;}
@end

static NSDictionary *Result(NSString *status) {return @{@"status":status,@"secret_values_in_diagnostic":@NO};}
static void SetDiagnostic(NSDictionary **output,NSDictionary *value) {if (output) *output=value;}
static BOOL DecimalIdentity(NSString *text,uint64_t *identity) {
    if (![text isKindOfClass:NSString.class] || !text.length || text.length>20) return NO;
    const char *bytes=text.UTF8String;if (!bytes || strlen(bytes)!=text.length) return NO;
    for (const char *c=bytes;*c;c++) if (*c<'0' || *c>'9') return NO;
    char *end=NULL;errno=0;unsigned long long number=strtoull(bytes,&end,10);
    if (errno || !number || !end || *end) return NO;*identity=number;return YES;
}
static BOOL TokenSubject(NSString *token,uint64_t *identity) {
    NSArray *parts=[token componentsSeparatedByString:@"."];if (parts.count!=3) return NO;
    NSString *part=[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    part=[part stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (part.length%4) part=[part stringByAppendingString:@"="];
    NSData *decoded=[[NSData alloc] initWithBase64EncodedString:part options:0];
    id claims=decoded?[NSJSONSerialization JSONObjectWithData:decoded options:0 error:NULL]:nil;
    return [claims isKindOfClass:NSDictionary.class] && DecimalIdentity(claims[@"sub"],identity);
}
TFMSteamCredentialRecord *TFMSteamCredentialCreate(NSString *token,NSString *name,uint64_t identity,NSDictionary **diagnostic) {
    uint64_t subject=0;
    if (![token isKindOfClass:NSString.class] || !token.length || token.length>32768 ||
        ![name isKindOfClass:NSString.class] || !name.length || name.length>256 || !identity ||
        [token rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound ||
        !TokenSubject(token,&subject) || subject!=identity) {
        SetDiagnostic(diagnostic,Result(@"credential_routing_validation_failed"));return nil;
    }
    TFMSteamCredentialRecord *record=[TFMSteamCredentialRecord new];record.refreshToken=token;record.accountName=name;record.steamID=identity;
    SetDiagnostic(diagnostic,Result(@"credential_routing_validated_not_authenticated"));return record;
}
static NSMutableDictionary *Query(void) {
    return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:Service,(__bridge id)kSecAttrAccount:Account,
        (__bridge id)kSecAttrSynchronizable:@NO} mutableCopy];
}
static NSDictionary *KeychainResult(NSString *status,OSStatus code) {
    return @{@"status":status,@"keychain_status":@(code),@"secret_values_in_diagnostic":@NO,
        @"storage":@"app_private_keychain",@"protection":@"when_unlocked_this_device_only",@"synchronizable":@NO};
}
static NSString *ReadFailure(OSStatus status) {
    if (status==errSecItemNotFound) return @"not_found";
    if (status==errSecInteractionNotAllowed) return @"keychain_locked_or_interaction_not_allowed";
    if (status==errSecMissingEntitlement) return @"keychain_signing_entitlement_unavailable";
    return @"keychain_read_failed";
}
TFMSteamCredentialRecord *TFMSteamCredentialLoad(NSDictionary **diagnostic) {
    @synchronized(TFMSteamCredentialRecord.class) {
        NSMutableDictionary *query=Query();query[(__bridge id)kSecReturnData]=@YES;query[(__bridge id)kSecReturnAttributes]=@YES;
        query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
        query[(__bridge id)kSecUseAuthenticationUI]=(__bridge id)kSecUseAuthenticationUIFail;
        CFTypeRef item=NULL;OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&item);
        id value=CFBridgingRelease(item);
        if (status!=errSecSuccess) {SetDiagnostic(diagnostic,KeychainResult(ReadFailure(status),status));return nil;}
        NSDictionary *attributes=[value isKindOfClass:NSDictionary.class]?value:nil;
        NSData *data=attributes[(__bridge id)kSecValueData];
        if (![attributes[(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly] ||
            [attributes[(__bridge id)kSecAttrSynchronizable] boolValue]) {
            SetDiagnostic(diagnostic,KeychainResult(@"saved_credential_protection_policy_mismatch",status));return nil;
        }
        if (![data isKindOfClass:NSData.class] || !data.length || data.length>65536) {
            SetDiagnostic(diagnostic,KeychainResult(@"saved_credential_record_invalid",status));return nil;
        }
        id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        NSDictionary *record=[object isKindOfClass:NSDictionary.class]?object:nil;uint64_t identity=0;
        if (![record[@"schema_version"] isEqual:@1] || !DecimalIdentity(record[@"steam_id"],&identity)) {
            SetDiagnostic(diagnostic,KeychainResult(@"saved_credential_record_invalid",status));return nil;
        }
        TFMSteamCredentialRecord *result=TFMSteamCredentialCreate(record[@"refresh_token"],record[@"account_name"],identity,NULL);
        SetDiagnostic(diagnostic,KeychainResult(result?@"saved_credential_loaded":@"saved_credential_record_invalid",status));return result;
    }
}
static NSURL *PolicyURL(void) {
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"TFMSteamFreshLogin.json"];
}
NSDictionary *TFMSteamFreshLoginPolicy(void) {
    @synchronized(TFMSteamCredentialRecord.class) {
        NSURL *url=PolicyURL();
        if (!url) return Result(@"fresh_login_policy_unavailable");
        int descriptor=open(url.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
        if (descriptor<0) return errno==ENOENT?@{@"status":@"ok",@"force_fresh_login":@NO}:Result(@"fresh_login_policy_unreadable");
        struct stat info={0};unsigned char bytes[1025];size_t length=0;BOOL valid=fstat(descriptor,&info)==0 && S_ISREG(info.st_mode) && info.st_size>0 && info.st_size<=1024;
        while (valid && length<sizeof bytes) {
            ssize_t count=read(descriptor,bytes+length,sizeof bytes-length);
            if (count<0 && errno==EINTR) continue;
            if (count<0) {valid=NO;break;}
            if (!count) break;
            length+=(size_t)count;
        }
        close(descriptor);
        if (!valid || !length || length>1024) return Result(@"fresh_login_policy_unreadable");
        NSData *data=[NSData dataWithBytes:bytes length:length];
        id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![value isKindOfClass:NSDictionary.class] || ![value[@"schema_version"] isEqual:@1] || ![value[@"force_fresh_login"] isEqual:@YES])
            return Result(@"fresh_login_policy_invalid");
        return @{@"status":@"ok",@"force_fresh_login":@YES};
    }
}
BOOL TFMSteamCredentialSave(TFMSteamCredentialRecord *record,NSDictionary **diagnostic) {
    @synchronized(TFMSteamCredentialRecord.class) {
        if (!record || !TFMSteamCredentialCreate(record.refreshToken,record.accountName,record.steamID,NULL)) {
            SetDiagnostic(diagnostic,Result(@"credential_routing_validation_failed"));return NO;
        }
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1,@"refresh_token":record.refreshToken,
            @"account_name":record.accountName,@"steam_id":[NSString stringWithFormat:@"%llu",(unsigned long long)record.steamID]} options:0 error:NULL];
        if (!data || data.length>65536) {SetDiagnostic(diagnostic,Result(@"credential_encoding_failed"));return NO;}
        NSDictionary *updates=@{(__bridge id)kSecValueData:data,(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
        OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)Query(),(__bridge CFDictionaryRef)updates);
        if (status==errSecItemNotFound) {
            NSMutableDictionary *item=Query();[item addEntriesFromDictionary:updates];status=SecItemAdd((__bridge CFDictionaryRef)item,NULL);
            if (status==errSecDuplicateItem) status=SecItemUpdate((__bridge CFDictionaryRef)Query(),(__bridge CFDictionaryRef)updates);
        }
        NSMutableDictionary *result=[KeychainResult(status==errSecSuccess?@"saved_credential_committed":@"keychain_write_failed",status) mutableCopy];
        result[@"saved"]=@(status==errSecSuccess);
        if (status==errSecSuccess) {
            NSURL *url=PolicyURL();BOOL cleared=url && (unlink(url.fileSystemRepresentation)==0 || errno==ENOENT);
            result[@"fresh_login_policy_cleared"]=@(cleared);
            if (!cleared) result[@"status"]=@"credential_saved_but_fresh_login_policy_clear_failed";
        }
        SetDiagnostic(diagnostic,result);return status==errSecSuccess;
    }
}
NSDictionary *TFMSteamRequestFreshLoginOnNextLaunch(BOOL forget) {
    @synchronized(TFMSteamCredentialRecord.class) {
        NSURL *url=PolicyURL();
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1,@"force_fresh_login":@YES} options:0 error:NULL];
        BOOL ready=url && [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        if (!ready || ![data writeToURL:url options:NSDataWritingAtomic|NSDataWritingFileProtectionComplete error:NULL])
            return @{@"status":@"fresh_login_request_write_failed",@"restart_required":@NO,@"active_native_session_ended":@NO};
        OSStatus removed=forget?SecItemDelete((__bridge CFDictionaryRef)Query()):errSecSuccess;
        BOOL forgotten=forget && (removed==errSecSuccess || removed==errSecItemNotFound);
        return @{@"status":(forget && !forgotten)?@"fresh_login_requested_keychain_delete_failed":@"fresh_login_requested",
            @"restart_required":@YES,@"force_fresh_login":@YES,@"forget_requested":@(forget),@"saved_credential_forgotten":@(forgotten),
            @"keychain_status":@(removed),@"active_native_session_ended":@NO,@"global_token_revocation_performed":@NO};
    }
}
