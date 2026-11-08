#include "KoreHostSys.h"

#if defined(__linux__)
#include <sys/prctl.h>
#ifndef PR_SET_THP_DISABLE
#define PR_SET_THP_DISABLE 41
#endif

int kore_host_disable_thp(void) { return prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0); }
#else
int kore_host_disable_thp(void) { return -1; }
#endif
