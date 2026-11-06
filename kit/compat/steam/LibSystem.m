#include <stdarg.h>
#include <syslog.h>
void TFMSteamSyslogExtended(int priority,const char *format,...) __asm__("_syslog$DARWIN_EXTSN");
void TFMSteamSyslogExtended(int priority,const char *format,...) {
    va_list arguments; va_start(arguments,format); vsyslog(priority,format,arguments); va_end(arguments);
}
