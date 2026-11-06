// Service-unavailable subset adapted from AgePad DiskArbitrationUnavailable.m.
#import <Foundation/Foundation.h>
const CFStringRef TFMSteamMediaUUIDKey __asm__("_kDADiskDescriptionMediaUUIDKey")=CFSTR("DAMediaUUID");
void *TFMSteamDASessionCreate(CFAllocatorRef allocator) __asm__("_DASessionCreate");
void *TFMSteamDADiskCreate(CFAllocatorRef allocator,void *session,const char *name) __asm__("_DADiskCreateFromBSDName");
CFDictionaryRef TFMSteamDADiskCopyDescription(void *disk) __asm__("_DADiskCopyDescription");
void *TFMSteamDASessionCreate(CFAllocatorRef allocator) { (void)allocator; return NULL; }
void *TFMSteamDADiskCreate(CFAllocatorRef allocator,void *session,const char *name) { (void)allocator; (void)session; (void)name; return NULL; }
CFDictionaryRef TFMSteamDADiskCopyDescription(void *disk) { (void)disk; return NULL; }
