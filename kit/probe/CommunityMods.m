// Signed plugins live in Frameworks; the engine discovers their ordinary mod folders.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static BOOL plainDirectory(NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0) return S_ISDIR(st.st_mode);
    return errno == ENOENT && [NSFileManager.defaultManager createDirectoryAtPath:path
                                      withIntermediateDirectories:NO attributes:nil error:NULL];
}

static BOOL sameResource(NSString *old, NSString *path, NSString *name) {
    if ([old isEqual:path]) return YES;
    // App container UUID changes after an upgrade. Only our own previously installed library is replaceable.
    return old.isAbsolutePath && [old hasSuffix:[@"/TFM2Probe.app/Frameworks/" stringByAppendingString:name]];
}

static BOOL installOne(NSString *root, NSString *modID) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *source = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"TFMCommunityMods"] stringByAppendingPathComponent:modID];
    NSString *target = [root stringByAppendingPathComponent:modID];
    NSString *owner = [target stringByAppendingPathComponent:@".tfm-port-owned"];
    struct stat st;
    if (lstat(target.fileSystemRepresentation,&st) == 0) {
        if (!S_ISDIR(st.st_mode) || ![[NSString stringWithContentsOfFile:owner encoding:NSUTF8StringEncoding error:NULL] isEqual:modID]) return NO;
    } else {
        if (!plainDirectory(target) || ![modID writeToFile:owner atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return NO;
    }
    NSString *name = [modID stringByAppendingPathExtension:@"dylib"];
    NSString *library = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"] stringByAppendingPathComponent:name];
    NSString *link = [target stringByAppendingPathComponent:name];
    if (lstat(library.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode)) return NO;
    NSString *old = [files destinationOfSymbolicLinkAtPath:link error:NULL];
    if (old && !sameResource(old,library,name)) return NO;
    if (![old isEqual:library]) {
        if (!old && lstat(link.fileSystemRepresentation,&st) == 0) return NO;
        NSString *tmp = [target stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        if (symlink(library.fileSystemRepresentation,tmp.fileSystemRepresentation)) return NO;
        if (rename(tmp.fileSystemRepresentation,link.fileSystemRepresentation)) {
            unlink(tmp.fileSystemRepresentation); return NO;
        }
    }
    // A fresh bundle UUID also distinguishes reinstalled builds. Avoid recopying the
    // illustration pack on each launch; write the receipt only after every copy succeeds.
    NSString *stampPath = [target stringByAppendingPathComponent:@".tfm-port-resources"];
    NSString *stamp = NSBundle.mainBundle.bundlePath;
    NSString *previous = [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:NULL];
    if ([stamp isEqual:previous] && [files fileExistsAtPath:[target stringByAppendingPathComponent:@"mod.mod_info"]]) return YES;
    // Copy bundle data into the mod directory, where the game can also write its settings and logs.
    NSDirectoryEnumerator *entries = [files enumeratorAtPath:source];
    if (!entries) return NO;
    for (NSString *relative in entries) {
        NSString *src = [source stringByAppendingPathComponent:relative];
        NSString *dst = [target stringByAppendingPathComponent:relative];
        if (lstat(src.fileSystemRepresentation,&st)) return NO;
        if (S_ISDIR(st.st_mode)) { if (!plainDirectory(dst)) return NO; continue; }
        if (!S_ISREG(st.st_mode)) return NO;
        struct stat existing;
        if (!lstat(dst.fileSystemRepresentation,&existing) && !S_ISREG(existing.st_mode)) return NO;
        NSData *data = [NSData dataWithContentsOfFile:src];
        if (!data || ![data writeToFile:dst options:NSDataWritingAtomic error:NULL]) return NO;
    }
    return [stamp writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

NSDictionary *TFMPrepareCommunityMods(NSURL *documents) {
    NSString *directory = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"TFMCommunityMods"];
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:directory]) return @{};
    NSString *runtime = [documents.path stringByAppendingPathComponent:@"GameRuntime"];
    NSString *root = [runtime stringByAppendingPathComponent:@"mods"];
    if (!plainDirectory(runtime) || !plainDirectory(root)) return @{@"error":@"runtime-directory"};
    NSArray *mods = [[files contentsOfDirectoryAtPath:directory error:NULL] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *installed = [NSMutableArray array], *failed = [NSMutableArray array], *newIDs = [NSMutableArray array];
    for (NSString *modID in mods) {
        if ([modID rangeOfString:@"^[a-z][a-z0-9_]{0,63}$" options:NSRegularExpressionSearch].location == NSNotFound || !installOne(root,modID)) {
            [failed addObject:modID]; continue;
        }
        [installed addObject:modID];
        if (![NSUserDefaults.standardUserDefaults boolForKey:[@"TFMEnrolled/" stringByAppendingString:modID]]) [newIDs addObject:modID];
    }
    if (newIDs.count) {
        NSString *config = [runtime stringByAppendingPathComponent:@"config"];
        NSString *game = [config stringByAppendingPathComponent:@"game"];
        NSString *path = [game stringByAppendingPathComponent:@"mods.json"];
        struct stat st;
        if (!plainDirectory(config) || !plainDirectory(game)) return @{@"error":@"config-directory"};
        BOOL exists = !lstat(path.fileSystemRepresentation,&st);
        if (exists && !S_ISREG(st.st_mode)) return @{@"error":@"config-path"};
        NSData *raw = exists ? [NSData dataWithContentsOfFile:path] : nil;
        id json = raw ? [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingMutableContainers error:NULL] : nil;
        if (!exists) json = [@{@"enabled_mods":[NSMutableArray array], @"known_workshop_mods":@[], @"known_workshop_items":@[], @"accepted_code_mod_warnings":@[], @"accepted_save_mod_mismatch_warnings":@[]} mutableCopy];
        if (![json isKindOfClass:NSMutableDictionary.class] || ![json[@"enabled_mods"] isKindOfClass:NSMutableArray.class]) return @{@"error":@"config-format"};
        for (NSString *modID in newIDs) if (![json[@"enabled_mods"] containsObject:modID]) [json[@"enabled_mods"] addObject:modID];
        NSData *updated = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
        if (!updated || ![updated writeToFile:path options:NSDataWritingAtomic error:NULL]) return @{@"error":@"config-write"};
        for (NSString *modID in newIDs) [NSUserDefaults.standardUserDefaults setBool:YES forKey:[@"TFMEnrolled/" stringByAppendingString:modID]];
    }
    return @{@"installed":installed, @"failed":failed, @"newly_enabled":newIDs};
}
