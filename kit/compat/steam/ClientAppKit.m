#import "AppPresence.h"
#include "../UnimplementedBoundary.h"
#include <objc/runtime.h>
#include <unistd.h>

// Measured from the public macOS AppKit string variables; see constants.json.
NSString *const NSWorkspaceLaunchConfigurationArguments=@"NSWorkspaceLaunchConfigurationArguments";
NSString *const NSWorkspaceLaunchConfigurationEnvironment=@"NSWorkspaceLaunchConfigurationEnvironment";

@interface TFMSteamAppKitObject : NSObject @end
@implementation TFMSteamAppKitObject
- (void)doesNotRecognizeSelector:(SEL)selector { TFMAbortUnimplementedBoundary(object_getClassName(self),sel_getName(selector)); }
+ (void)doesNotRecognizeSelector:(SEL)selector { TFMAbortUnimplementedBoundary(object_getClassName(self),sel_getName(selector)); }
@end

// This object represents the current host process only, not a global macOS
// application registry. Unavailable cross-process queries return nil, never an
// invented complete empty/one-element system application list.
@interface NSRunningApplication : TFMSteamAppKitObject
+ (instancetype)currentApplication;
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid;
+ (NSArray *)runningApplicationsWithBundleIdentifier:(NSString *)identifier;
- (pid_t)processIdentifier;
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
- (NSURL *)bundleURL;
- (NSURL *)executableURL;
- (BOOL)isActive;
- (BOOL)isTerminated;
@end
@implementation NSRunningApplication
+ (instancetype)currentApplication { static NSRunningApplication *app; static dispatch_once_t once; dispatch_once(&once,^{app=[self new];}); return app; }
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid { return pid==getpid() ? [self currentApplication] : nil; }
+ (NSArray *)runningApplicationsWithBundleIdentifier:(NSString *)identifier { return [identifier isEqual:NSBundle.mainBundle.bundleIdentifier] ? @[[self currentApplication]] : nil; }
- (pid_t)processIdentifier { return getpid(); }
- (NSString *)bundleIdentifier { return NSBundle.mainBundle.bundleIdentifier; }
- (NSString *)localizedName { return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: NSBundle.mainBundle.bundleURL.lastPathComponent; }
- (NSURL *)bundleURL { return NSBundle.mainBundle.bundleURL; }
- (NSURL *)executableURL { return NSBundle.mainBundle.executableURL; }
- (BOOL)isActive { return TFMSteamOwnAppIsActive(); }
- (BOOL)isTerminated { return NO; } // this method is running inside this live process
@end

@interface NSWorkspace : TFMSteamAppKitObject
+ (instancetype)sharedWorkspace;
- (NSArray *)runningApplications;
- (NSRunningApplication *)frontmostApplication;
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)identifier;
- (id)launchApplicationAtURL:(NSURL *)url options:(NSUInteger)options configuration:(NSDictionary *)configuration error:(NSError **)error;
@end
@implementation NSWorkspace
+ (instancetype)sharedWorkspace { static NSWorkspace *workspace; static dispatch_once_t once; dispatch_once(&once,^{workspace=[self new];}); return workspace; }
- (NSArray *)runningApplications { return nil; } // global enumeration unavailable
- (NSRunningApplication *)frontmostApplication { return TFMSteamOwnAppIsActive() ? NSRunningApplication.currentApplication : nil; }
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)identifier { return [identifier isEqual:NSBundle.mainBundle.bundleIdentifier] ? NSBundle.mainBundle.bundleURL : nil; }
- (id)launchApplicationAtURL:(NSURL *)url options:(NSUInteger)options configuration:(NSDictionary *)configuration error:(NSError **)error {
    (void)url; (void)options; (void)configuration;
    if (error) *error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:@{NSLocalizedDescriptionKey:@"Cross-process application launch is unavailable in this app-scoped compatibility layer"}];
    return nil;
}
@end
