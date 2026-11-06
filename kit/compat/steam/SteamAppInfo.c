/* Bounded adaptation of PublicGameBuild in port/steam-engine/AgePadSteamRoute.m
 * https://github.com/chrissotraidis/agepad, commit
 * c0f7cbdc69d8b1dca87a73a94490c3a65405762f. No cache mutation or network request.
 *
 * MIT License — Copyright (c) 2026 Chris Sotraidis
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
#include "SteamAppInfo.h"
#include <stdlib.h>
#include <string.h>
static uint32_t U32(const uint8_t *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static uint64_t U64(const uint8_t *p) { return (uint64_t)U32(p)|((uint64_t)U32(p+4)<<32); }
static TFMAppInfoResult Record(const uint8_t *d,size_t q,size_t stop,const char **names,uint32_t count,uint32_t *build) {
    const char *path[32];size_t depth=0;uint32_t candidate=0;int seen=0;
    while (q<stop) {
        uint8_t type=d[q++];
        if (type==8) {
            if (!depth) {
                if (q!=stop) return TFMAppInfoMalformed;
                if(seen)*build=candidate;
                return seen?TFMAppInfoObserved:TFMAppInfoNotFound;
            }
            depth--;continue;
        }
        if (stop-q<4) return TFMAppInfoMalformed;
        uint32_t key=U32(d+q);q+=4;
        if (key>=count) return TFMAppInfoMalformed;
        const char *name=names[key];
        if (type==0) { if(depth>=32)return TFMAppInfoMalformed;path[depth++]=name;continue; }
        int target=depth==4 && !strcmp(path[0],"appinfo") && !strcmp(path[1],"depots") &&
            !strcmp(path[2],"branches") && !strcmp(path[3],"public") && !strcmp(name,"buildid");
        if (type==1) {
            const uint8_t *end=memchr(d+q,0,stop-q);if(!end || target)return TFMAppInfoMalformed;
            q=(size_t)(end-d)+1;
        } else if (type==2) {
            if(stop-q<4)return TFMAppInfoMalformed;
            uint32_t value=U32(d+q);q+=4;
            if(target) {if(seen || !value || value>INT32_MAX)return TFMAppInfoMalformed;candidate=value;seen=1;}
        } else if (type==7) {if(stop-q<8 || target)return TFMAppInfoMalformed;q+=8;}
        else return TFMAppInfoUnsupported;
    }
    return TFMAppInfoMalformed; /* Record must end, even after a build was seen. */
}
TFMAppInfoResult TFMReadCachedPublicBuild(const uint8_t *d,size_t n,uint32_t app,uint32_t *build) {
    if (build) *build=0;
    if (!d || !build || !app || n<16 || n>64u*1024u*1024u) return TFMAppInfoMalformed;
    if (U32(d)!=0x07564429) return TFMAppInfoUnsupported;
    uint64_t wide=U64(d+8);
    if (wide<16 || wide>n-4) return TFMAppInfoMalformed;
    size_t table=(size_t)wide,q=table+4;
    uint32_t count=U32(d+table);
    if (count>1000000 || count>n-q) return TFMAppInfoMalformed;
    const char **names=calloc(count?count:1,sizeof(*names));
    if (!names) return TFMAppInfoMalformed;
    TFMAppInfoResult result=TFMAppInfoMalformed;uint32_t candidate=0;int found=0;
    for (uint32_t i=0;i<count;i++) {
        if (q>=n) goto done;
        const uint8_t *end=memchr(d+q,0,n-q);
        if (!end) goto done;
        names[i]=(const char *)(d+q);q=(size_t)(end-d)+1;
    }
    if (q!=n) goto done;
    for (size_t p=16;p<table;) {
        if(table-p<4)goto malformed;
        uint32_t id=U32(d+p);
        if (!id) {
            if(table-p!=4)goto malformed;
            result=found?TFMAppInfoObserved:TFMAppInfoNotFound;
            goto done;
        }
        if(table-p<8)goto malformed;
        uint32_t size=U32(d+p+4);
        if (size<60 || size>table-p-8) goto malformed;
        size_t stop=p+8+size;
        if(id==app) {
            if(found)goto malformed; /* Ambiguous duplicate application record. */
            found=1;result=Record(d,p+68,stop,names,count,&candidate);
            if(result!=TFMAppInfoObserved && result!=TFMAppInfoNotFound)goto done;
            if(result==TFMAppInfoNotFound)candidate=0;
        }
        p=stop;
    }
malformed:
    result=TFMAppInfoMalformed;
done:
    if(result==TFMAppInfoObserved && candidate)*build=candidate;
    else if(result==TFMAppInfoObserved)result=TFMAppInfoNotFound;
    free(names);return result;
}
