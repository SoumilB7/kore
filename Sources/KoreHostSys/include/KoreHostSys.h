#ifndef KORE_HOST_SYS_H
#define KORE_HOST_SYS_H

/// Turns transparent huge pages off for this process (Linux `prctl(PR_SET_THP_DISABLE)`), so an
/// idle kore-host keeps small pages it can give back. 0 when done; -1 elsewhere or on failure.
int kore_host_disable_thp(void);

#endif
