#ifndef POEXS_H
#define POEXS_H

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define MODE_RD 0
#define MODE_WR 1
#define MODE_EX 2

extern void
poe_enqueue_data_ready(SV *kernel, int mode, int *fds, int fd_count);

extern void
poe_data_ev_dispatch_due(SV *kernel);

extern void
poe_test_if_kernel_idle(SV *kernel);

extern const char *
poe_mode_names(int mode);

#ifdef XS_LOOP_TRACE
#include <stdio.h>
#include <stdarg.h>
extern void poexs_tracef(const char *fmt, ...);
#define TRACE(foo) foo
#define TRACEF(foo) poexs_tracef foo
#else
#define TRACE(foo)
#define TRACEF(foo)
#endif


#endif
