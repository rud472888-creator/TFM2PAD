#pragma once
#include <stdint.h>

// Exact CVTime field ABI from Apple's CVBase.h. This adapter represents unknown
// nominal refresh as indefinite, never UIScreen.maximumFramesPerSecond as a
// fixed display period. Only the three imported display-link functions exist.
typedef struct TFMCVDisplayLink *TFMCVDisplayLinkRef;
typedef struct { int64_t timeValue; int32_t timeScale; int32_t flags; } TFMCVTime;
enum { TFMCVTimeIsIndefinite=1<<0 };

#ifdef __cplusplus
extern "C" {
#endif
int32_t TFMCVDisplayLinkCreateWithCGDisplay(uint32_t display,TFMCVDisplayLinkRef *link) __asm__("_CVDisplayLinkCreateWithCGDisplay");
TFMCVTime TFMCVDisplayLinkGetNominalOutputVideoRefreshPeriod(TFMCVDisplayLinkRef link) __asm__("_CVDisplayLinkGetNominalOutputVideoRefreshPeriod");
void TFMCVDisplayLinkRelease(TFMCVDisplayLinkRef link) __asm__("_CVDisplayLinkRelease");
#ifdef __cplusplus
}
#endif
