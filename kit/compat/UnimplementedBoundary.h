#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

// A load-only boundary may resolve an import while leaving its behavior
// unimplemented. Such entrypoints always terminate with an identifying message;
// they must never report successful capture, mode changes, or desktop GL work.
__attribute__((noreturn, cold)) static inline void TFMAbortUnimplementedBoundary(const char *library, const char *symbol) {
    fprintf(stderr, "TFM2_UNIMPLEMENTED_BOUNDARY library=%s symbol=%s: implementation required; terminating (load-only package, not a runnable game)\n", library, symbol);
    fflush(stderr);
#ifdef __OBJC__
    @autoreleasepool {
        @try {
            NSDictionary *failure = @{@"schema_version": @1, @"stage": @"unimplemented_boundary_call", @"status": @"unsupported", @"library": [NSString stringWithUTF8String:library], @"symbol": [NSString stringWithUTF8String:symbol], @"exit_status": @78};
            NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            [[NSFileManager defaultManager] createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:NULL];
            NSData *json = [NSJSONSerialization dataWithJSONObject:failure options:NSJSONWritingPrettyPrinted error:NULL];
            BOOL saved = [json writeToURL:[documents URLByAppendingPathComponent:@"boundary-failure.json"] options:NSDataWritingAtomic error:NULL];
            if (!saved) fprintf(stderr, "TFM2_UNIMPLEMENTED_BOUNDARY: diagnostic persistence failed\n");
        } @catch (__unused NSException *exception) {
            fprintf(stderr, "TFM2_UNIMPLEMENTED_BOUNDARY: diagnostic persistence exception\n");
        }
    }
#endif
    _exit(78);
}
