#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Read-only cached observation; never requests server data or changes Steam state.
NSDictionary *TFMCheckCachedGameUpdate(void);
// Same bounded checker with explicit inputs for host fixtures; no status-file writes.
NSDictionary *TFMCheckCachedGameUpdateAtURLs(NSURL *installedRecord, NSURL *cache);
// Once per process: background checks now/20s/70s; sanitized Documents report.
// Only a cached newer build can show one informational alert on the main thread.
void TFMStartCachedGameUpdateChecks(void);
NS_ASSUME_NONNULL_END
