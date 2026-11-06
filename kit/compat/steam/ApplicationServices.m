// Current-process subset adapted from AgePad ApplicationServicesClient.m.
#import "AppPresence.h"
#include <unistd.h>
typedef struct { uint32_t highLongOfPSN,lowLongOfPSN; } TFMSteamPSN;
enum { TFMSteamParamErr=-50, TFMSteamProcNotFound=-600, TFMSteamCurrentProcess=2 };
int16_t TFMSteamGetCurrentProcess(TFMSteamPSN *psn) __asm__("_GetCurrentProcess");
int16_t TFMSteamGetFrontProcess(TFMSteamPSN *psn) __asm__("_GetFrontProcess");
int32_t TFMSteamGetProcessPID(const TFMSteamPSN *psn,pid_t *pid) __asm__("_GetProcessPID");
int16_t TFMSteamGetCurrentProcess(TFMSteamPSN *psn) {
    if (!psn) return TFMSteamParamErr;
    // kCurrentProcess is an app-compatibility sentinel, not a global macOS PSN.
    psn->highLongOfPSN=0; psn->lowLongOfPSN=TFMSteamCurrentProcess; return 0;
}
int16_t TFMSteamGetFrontProcess(TFMSteamPSN *psn) {
    if (!psn) return TFMSteamParamErr;
    psn->highLongOfPSN=psn->lowLongOfPSN=0;
    if (!TFMSteamOwnAppIsActive()) return TFMSteamProcNotFound;
    return TFMSteamGetCurrentProcess(psn);
}
int32_t TFMSteamGetProcessPID(const TFMSteamPSN *psn,pid_t *pid) {
    if (!psn || !pid) return TFMSteamParamErr;
    *pid=0;
    if (psn->highLongOfPSN!=0 || psn->lowLongOfPSN!=TFMSteamCurrentProcess) return TFMSteamProcNotFound;
    *pid=getpid(); return 0;
}
