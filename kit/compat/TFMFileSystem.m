// Original app-scoped filesystem adaptation; no original game code is changed.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

static int (*NativeChdir)(const char *);
static void Record(NSURL *documents, NSString *status, int result, int error) {
    NSDictionary *value=@{@"status":status,@"pid":@(getpid()),@"result":@(result),@"errno":@(error),
        @"timestamp_unix":@(NSDate.date.timeIntervalSince1970),
        @"scope":@"Only chdir to this signed app bundle is redirected to Documents/GameRuntime; asset symlink is read-only bundled data, config/save writes remain in the app container."};
    [[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:NULL]
        writeToURL:[documents URLByAppendingPathComponent:@"filesystem-progress.json"] atomically:YES];
}
int TFMGameChdir(const char *path) __asm__("_chdir");
int TFMGameChdir(const char *path) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *system=dlopen("/usr/lib/libSystem.B.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
        NativeChdir=system?dlsym(system,"chdir"):NULL;
    });
    if (!NativeChdir) { errno=ENOSYS;return -1; }
    if (!path) { errno=EFAULT;return -1; }
    @autoreleasepool {
        char actual[PATH_MAX],bundle[PATH_MAX];
        if (!realpath(path,actual) || !realpath(NSBundle.mainBundle.bundlePath.fileSystemRepresentation,bundle) || strcmp(actual,bundle))
            return NativeChdir(path);
        // The original desktop executable resets cwd to its executable's folder.
        // iOS app bundles are sealed; preserve relative game paths in Documents.
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *runtime=[documents URLByAppendingPathComponent:@"GameRuntime" isDirectory:YES];
        NSString *expected=[documents.URLByResolvingSymlinksInPath.path stringByAppendingPathComponent:@"GameRuntime"];
        struct stat directory;
        BOOL exists=lstat(runtime.fileSystemRepresentation,&directory)==0;
        int directoryError=errno;
        if (![runtime.URLByResolvingSymlinksInPath.path isEqual:expected] ||
            (exists && !S_ISDIR(directory.st_mode)) ||
            (!exists && (directoryError!=ENOENT || ![NSFileManager.defaultManager createDirectoryAtURL:runtime withIntermediateDirectories:NO attributes:nil error:NULL]))) {
            Record(documents,@"runtime_directory_unavailable",-1,EPERM);errno=EPERM;return -1;
        }
        NSURL *source=[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"bundle.game_data"];
        NSURL *link=[runtime URLByAppendingPathComponent:@"bundle.game_data"];
        struct stat asset,existing;
        if (stat(source.fileSystemRepresentation,&asset) || !S_ISREG(asset.st_mode)) {
            Record(documents,@"bundled_asset_missing",-1,ENOENT);errno=ENOENT;return -1;
        }
        if (lstat(link.fileSystemRepresentation,&existing)==0) {
            // Never replace a user's regular file or directory.
            if (!S_ISLNK(existing.st_mode)) { Record(documents,@"asset_link_collision",-1,EEXIST);errno=EEXIST;return -1; }
            char destination[PATH_MAX];ssize_t length=readlink(link.fileSystemRepresentation,destination,sizeof destination-1);
            if (length<0) return -1;destination[length]=0;
            if (strcmp(destination,source.fileSystemRepresentation)) {
                NSString *prior=@(destination);
                if (![prior.lastPathComponent isEqual:@"bundle.game_data"] ||
                    ![prior.stringByDeletingLastPathComponent.lastPathComponent isEqual:@"TFM2Probe.app"]) {
                    Record(documents,@"unmanaged_asset_symlink",-1,EEXIST);errno=EEXIST;return -1;
                }
                if (unlink(link.fileSystemRepresentation)) return -1;
                if (symlink(source.fileSystemRepresentation,link.fileSystemRepresentation)) return -1;
            }
        } else {
            if (errno!=ENOENT || symlink(source.fileSystemRepresentation,link.fileSystemRepresentation)) return -1;
        }
        int result=NativeChdir(runtime.fileSystemRepresentation),saved=errno;
        Record(documents,result?@"redirect_failed":@"game_cwd_redirected",result,result?saved:0);
        errno=saved;return result;
    }
}
