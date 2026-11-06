#import <Foundation/Foundation.h>
#include "../UnimplementedBoundary.h"
#include <objc/runtime.h>
// Class metadata permits import resolution. No system Bluetooth inventory or
// hardware state is invented. nil means this macOS service is unavailable.
@interface IOBluetoothDevice : NSObject
+ (NSArray *)pairedDevices;
+ (instancetype)deviceWithAddressString:(NSString *)address;
@end
@implementation IOBluetoothDevice
+ (NSArray *)pairedDevices { return nil; }
+ (instancetype)deviceWithAddressString:(NSString *)address { (void)address; return nil; }
- (void)doesNotRecognizeSelector:(SEL)selector { TFMAbortUnimplementedBoundary(object_getClassName(self),sel_getName(selector)); }
+ (void)doesNotRecognizeSelector:(SEL)selector { TFMAbortUnimplementedBoundary(object_getClassName(self),sel_getName(selector)); }
@end
