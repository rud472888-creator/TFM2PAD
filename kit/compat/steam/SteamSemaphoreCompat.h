// App-local SysV semaphore sets for the single-process genuine Steam engine.
#pragma once
#include <stdint.h>
#include <sys/sem.h>

// Deliberately bounded implementation limits, not reported OS capabilities.
enum { TFMSteamSemaphoreSetLimit=256,TFMSteamSemaphorePerSetLimit=256,
       TFMSteamSemaphoreOperationLimit=256,TFMSteamSemaphoreValueMax=32767 };
int TFMSteamSemGet(key_t key,int count,int flags) __asm__("_semget");
int TFMSteamSemOp(int id,struct sembuf *operations,size_t count) __asm__("_semop");
int TFMSteamSemCtl(int id,int number,int command,...) __asm__("_semctl");
struct TFMSteamSemaphoreStats {
    uint64_t get_calls,op_calls,ctl_calls,created_sets,removed_sets,blocking_waits,errors;
    unsigned active_sets,blocked_operations;
};
void TFMSteamSemaphoreCopyStats(struct TFMSteamSemaphoreStats *stats);
// Scope: process-local only, shared through ONE TFMSteamIPC.dylib. No fork or
// cross-process synchronization. SEM_UNDO is accepted as process-lifetime-only:
// all sets cease to exist on process exit, so no surviving caller can observe
// exit adjustments; thread exit does NOT undo operations. IPC_SET is ENOTSUP.
// Deferred pthread cancellation cleans up wait counters and unlocks the mutex.
// Signal-driven EINTR and kernel validation of arbitrary invalid user pointers
// are not provided; NULL pointers fail EFAULT. No system sem* syscall is called.
