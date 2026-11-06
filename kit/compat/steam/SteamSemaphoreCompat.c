/*
 * Selectively adapted and corrected from AgePad port/de/SysVSemaphoreCompat.h
 * https://github.com/chrissotraidis/agepad/blob/
 * c0f7cbdc69d8b1dca87a73a94490c3a65405762f/port/de/SysVSemaphoreCompat.h
 *
 * MIT License
 * Copyright (c) 2026 Chris Sotraidis
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * Corrections: sequential tentative evaluation of a multi-op transaction;
 * non-repeating IDs and waiter-safe slot reuse; actual waiter counts/PIDs;
 * range/overflow checks; Darwin semun variadic ABI and IPC_STAT metadata;
 * explicit unsupported IPC_SET; cancellation cleanup. No upstream binary,
 * fixed address, ownership answer, login state or game content is included.
 */
#include "SteamSemaphoreCompat.h"
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

_Static_assert(sizeof(struct sembuf)==6,"Darwin sembuf ABI changed");
_Static_assert(sizeof(union semun)==8,"64-bit Darwin semun ABI required");
_Static_assert(__builtin_offsetof(struct semid_ds,sem_otime)==32,"Darwin sem_otime ABI changed");
typedef struct {
    int id,active,count;
    key_t key;
    struct ipc_perm permissions;
    unsigned short values[TFMSteamSemaphorePerSetLimit];
    unsigned negative_waiters[TFMSteamSemaphorePerSetLimit],zero_waiters[TFMSteamSemaphorePerSetLimit];
    pid_t pids[TFMSteamSemaphorePerSetLimit];
    unsigned waiters;
    time_t operation_time,change_time;
} TFMSet;
static TFMSet Sets[TFMSteamSemaphoreSetLimit];
static pthread_mutex_t Lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t Changed=PTHREAD_COND_INITIALIZER;
static int NextID=0x5000;
static struct TFMSteamSemaphoreStats Stats;

static TFMSet *Find(int id) {
    for(unsigned i=0;i<TFMSteamSemaphoreSetLimit;i++) if(Sets[i].active && Sets[i].id==id) return &Sets[i];
    return NULL;
}
static int CanAccess(const TFMSet *set,unsigned requested) {
    uid_t uid=geteuid();if(!uid) return 1;
    unsigned bits=(uid==set->permissions.uid || uid==set->permissions.cuid)?(set->permissions.mode>>6):
        ((getegid()==set->permissions.gid || getegid()==set->permissions.cgid)?(set->permissions.mode>>3):set->permissions.mode);
    return (bits&requested)==requested;
}
// Called with Lock held. No I/O/cancellation point may occur between removal
// of semop's cleanup handler and this unlock. Diagnostics use CopyStats only.
static int Finish(const char *operation,int result,int error) {
    (void)operation;
    if(error) Stats.errors++;
    pthread_mutex_unlock(&Lock);if(error) errno=error;return result;
}
int TFMSteamSemGet(key_t key,int count,int flags) {
    pthread_mutex_lock(&Lock);Stats.get_calls++;
    if(count<0 || count>TFMSteamSemaphorePerSetLimit || (flags&~(0777|IPC_CREAT|IPC_EXCL))) return Finish("semget",-1,EINVAL);
    TFMSet *slot=NULL;
    for(unsigned i=0;i<TFMSteamSemaphoreSetLimit;i++) {
        TFMSet *set=&Sets[i];
        if(set->active && key!=IPC_PRIVATE && set->key==key) {
            if((flags&IPC_CREAT) && (flags&IPC_EXCL)) return Finish("semget",-1,EEXIST);
            if(count>set->count) return Finish("semget",-1,EINVAL);
            unsigned requested=((unsigned)flags>>6)&6U;
            if(!CanAccess(set,requested)) return Finish("semget",-1,EACCES);
            return Finish("semget",set->id,0);
        }
        // A removed set's blocked callers still own its wait counters until
        // wake/cancel cleanup. Do not recycle its storage before that point.
        if(!set->active && !set->waiters && !slot) slot=set;
    }
    if(key!=IPC_PRIVATE && !(flags&IPC_CREAT)) return Finish("semget",-1,ENOENT);
    if(count<=0) return Finish("semget",-1,EINVAL);
    if(!slot || NextID==INT_MAX) return Finish("semget",-1,ENOSPC);
    memset(slot,0,sizeof(*slot));slot->id=NextID++;slot->active=1;slot->key=key;slot->count=count;
    slot->permissions.uid=slot->permissions.cuid=geteuid();slot->permissions.gid=slot->permissions.cgid=getegid();
    slot->permissions.mode=(mode_t)(flags&0777);slot->permissions._key=key;
    slot->permissions._seq=(unsigned short)(slot->id&USHRT_MAX);slot->change_time=time(NULL);
    Stats.active_sets++;Stats.created_sets++;
    return Finish("semget",slot->id,0);
}
typedef struct { TFMSet *set; unsigned number; int zero,registered; } WaitCleanup;
static void DropWaiter(WaitCleanup *wait) {
    if(!wait->registered) return;
    if(wait->zero) wait->set->zero_waiters[wait->number]--;else wait->set->negative_waiters[wait->number]--;
    wait->set->waiters--;Stats.blocked_operations--;wait->registered=0;
}
static void CancelWait(void *context) {
    DropWaiter(context);pthread_mutex_unlock(&Lock);
}
int TFMSteamSemOp(int id,struct sembuf *operations,size_t count) {
    pthread_mutex_lock(&Lock);Stats.op_calls++;
    if(!operations) return Finish("semop",-1,EFAULT);
    if(!count) return Finish("semop",-1,EINVAL);
    if(count>TFMSteamSemaphoreOperationLimit) return Finish("semop",-1,E2BIG);
    TFMSet *set=Find(id);if(!set) return Finish("semop",-1,EINVAL);
    struct sembuf copied[TFMSteamSemaphoreOperationLimit];memcpy(copied,operations,count*sizeof(*copied));
    unsigned access=0;
    for(size_t i=0;i<count;i++) {
        if(copied[i].sem_num>=set->count) return Finish("semop",-1,EFBIG);
        if(copied[i].sem_flg&~(IPC_NOWAIT|SEM_UNDO)) return Finish("semop",-1,EINVAL);
        access|=copied[i].sem_op?2U:4U;
    }
    if(!CanAccess(set,access)) return Finish("semop",-1,EACCES);
    int result=-1,error=0;WaitCleanup cleanup={.set=set};
    pthread_cleanup_push(CancelWait,&cleanup);
    for(;;) {
        if(!set->active || set->id!=id) { error=EIDRM;break; }
        int tentative[TFMSteamSemaphorePerSetLimit];
        for(int i=0;i<set->count;i++) tentative[i]=set->values[i];
        size_t blocked=count;
        for(size_t i=0;i<count;i++) {
            unsigned number=copied[i].sem_num;int change=copied[i].sem_op;
            if(change>0 && tentative[number]+change>TFMSteamSemaphoreValueMax) { error=ERANGE;break; }
            if((change<0 && tentative[number]<-change) || (!change && tentative[number]!=0)) { blocked=i;break; }
            tentative[number]+=change;
        }
        if(error) break;
        if(blocked==count) {
            for(int i=0;i<set->count;i++) set->values[i]=(unsigned short)tentative[i];
            for(size_t i=0;i<count;i++) set->pids[copied[i].sem_num]=getpid();
            set->operation_time=time(NULL);pthread_cond_broadcast(&Changed);result=0;break;
        }
        if(copied[blocked].sem_flg&IPC_NOWAIT) { error=EAGAIN;break; }
        cleanup.number=copied[blocked].sem_num;cleanup.zero=copied[blocked].sem_op==0;cleanup.registered=1;
        if(cleanup.zero) set->zero_waiters[cleanup.number]++;else set->negative_waiters[cleanup.number]++;
        set->waiters++;Stats.blocking_waits++;Stats.blocked_operations++;
        int status=pthread_cond_wait(&Changed,&Lock);DropWaiter(&cleanup);
        if(status) { error=status;break; }
    }
    // Normal path unlocks below via Finish; cancellation uses the registered
    // cleanup after pthread_cond_wait has reacquired Lock.
    pthread_cleanup_pop(0);
    return Finish("semop",result,error);
}
int TFMSteamSemCtl(int id,int number,int command,...) {
    union semun argument={.val=0};
    // Darwin arm64 caller passes a full 8-byte semun stack slot. Reading only
    // int is ABI-incorrect; audited tier0 SETVAL explicitly stores x8 to sp.
    if(command==SETVAL || command==SETALL || command==GETALL || command==IPC_STAT || command==IPC_SET) {
        va_list args;va_start(args,command);argument=va_arg(args,union semun);va_end(args);
    }
    pthread_mutex_lock(&Lock);Stats.ctl_calls++;
    TFMSet *set=Find(id);if(!set) return Finish("semctl",-1,EINVAL);
    int per_semaphore=command==GETVAL || command==SETVAL || command==GETPID || command==GETNCNT || command==GETZCNT;
    if(per_semaphore && (number<0 || number>=set->count)) return Finish("semctl",-1,EINVAL);
    if(command==IPC_SET) return Finish("semctl",-1,ENOTSUP);
    if(command==IPC_RMID) {
        if(geteuid()!=0 && geteuid()!=set->permissions.uid && geteuid()!=set->permissions.cuid) return Finish("semctl",-1,EPERM);
        set->active=0;Stats.active_sets--;Stats.removed_sets++;pthread_cond_broadcast(&Changed);
        return Finish("semctl",0,0);
    }
    unsigned access=(command==SETVAL || command==SETALL)?2U:4U;
    if(!CanAccess(set,access)) return Finish("semctl",-1,EACCES);
    int result=0;
    switch(command) {
        case GETVAL: result=set->values[number];break;
        case GETPID: result=set->pids[number];break;
        case GETNCNT: result=(int)set->negative_waiters[number];break;
        case GETZCNT: result=(int)set->zero_waiters[number];break;
        case SETVAL:
            if(argument.val<0 || argument.val>TFMSteamSemaphoreValueMax) return Finish("semctl",-1,ERANGE);
            set->values[number]=(unsigned short)argument.val;set->pids[number]=getpid();set->change_time=time(NULL);pthread_cond_broadcast(&Changed);break;
        case GETALL:
            if(!argument.array) return Finish("semctl",-1,EFAULT);
            memcpy(argument.array,set->values,(size_t)set->count*sizeof(*argument.array));break;
        case SETALL:
            if(!argument.array) return Finish("semctl",-1,EFAULT);
            for(int i=0;i<set->count;i++) if(argument.array[i]>TFMSteamSemaphoreValueMax) return Finish("semctl",-1,ERANGE);
            memcpy(set->values,argument.array,(size_t)set->count*sizeof(*argument.array));
            for(int i=0;i<set->count;i++) set->pids[i]=getpid();set->change_time=time(NULL);pthread_cond_broadcast(&Changed);break;
        case IPC_STAT: {
            if(!argument.buf) return Finish("semctl",-1,EFAULT);
            struct semid_ds status;memset(&status,0,sizeof(status));status.sem_perm=set->permissions;
            status.sem_nsems=(unsigned short)set->count;status.sem_otime=set->operation_time;status.sem_ctime=set->change_time;
            memcpy(argument.buf,&status,sizeof(status));break;
        }
        default: return Finish("semctl",-1,EINVAL);
    }
    return Finish("semctl",result,0);
}
void TFMSteamSemaphoreCopyStats(struct TFMSteamSemaphoreStats *stats) {
    if(!stats) return;pthread_mutex_lock(&Lock);*stats=Stats;pthread_mutex_unlock(&Lock);
}
