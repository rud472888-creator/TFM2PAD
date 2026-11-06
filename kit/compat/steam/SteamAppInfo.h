#ifndef TFM_STEAM_APP_INFO_H
#define TFM_STEAM_APP_INFO_H
#include <stddef.h>
#include <stdint.h>
typedef enum { TFMAppInfoObserved=0, TFMAppInfoNotFound=1, TFMAppInfoUnsupported=2, TFMAppInfoMalformed=3 } TFMAppInfoResult;
/* Reads only appinfo/depots/branches/public/buildid in v29 cache format.
   A cached observation is not a fresh server query or update authorization. */
TFMAppInfoResult TFMReadCachedPublicBuild(const uint8_t *data,size_t length,uint32_t appID,uint32_t *build);
#endif
