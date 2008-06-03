#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <string.h> /* for memmove() mostly */
#include <errno.h> /* errno values */
#include <sys/epoll.h>
#include <sys/time.h>
#include <time.h>
#include "alloc.h"
#include "poexs.h"

/*#define XS_LOOP_DEBUG*/

#if defined(MEM_DEBUG) || defined(XS_LOOP_DEBUG)
/* sizes that should require re-allocation of the arrays */
#define START_FD_ALLOC 5
#define START_LOOKUP_ALLOC 10
#else
/* more than we need on average */
#define START_FD_ALLOC 50
#define START_LOOKUP_ALLOC 100
#endif

#define lpm_loop_resume_time_watcher(self, next_time) lp_loop_resume_time_watcher(next_time)
#define lpm_loop_reset_time_watcher(self, next_time) lp_loop_reset_time_watcher(next_time)
#define lpm_loop_watch_filehandle(self, handle, mode) lp_loop_watch_filehandle(handle, mode)
#define lpm_loop_ignore_filehandle(self, handle, mode) lp_loop_ignore_filehandle(handle, mode)
#define lpm_loop_pause_filehandle(self, handle, mode) lp_loop_ignore_filehandle(handle, mode)
#define lpm_loop_resume_filehandle(self, handle, mode) lp_loop_watch_filehandle(handle, mode)

/* no ops */
#define lp_loop_attach_uidestroy(kernel)
#define lp_loop_halt(kernel)

/* the next time-based event to be dispatched */
static double lp_next_time;

static int epoll_fd = -1;
static int *fd_modes;
static int fd_mode_count;

/* functions should be static, hopefully the compiler will inline them
   into the XS code */

static void
lp_loop_initialize(SV *kernel) {
  int i;

  TRACEF(("loop_initialize()\n"));

  if (epoll_fd != -1) {
    warn("loop_initialize() called while loop is active");
  }

  lp_next_time = 0;
  epoll_fd = epoll_create(START_FD_ALLOC);
  fd_modes = mymalloc(sizeof(*fd_modes) * START_LOOKUP_ALLOC);
  fd_mode_count = START_LOOKUP_ALLOC;
  for (i = 0; i < fd_mode_count; ++i) {
    fd_modes[i] = 0;
  }
}

static void
lp_loop_finalize(SV *kernel) {
  TRACEF(("loop_finalize()\n"));

  if (epoll_fd != -1) {
    close(epoll_fd);
    epoll_fd = -1;
  }
  myfree(fd_modes);
  fd_modes = NULL;
}

static void
_expand_fd_modes(int fd) {
  int i;
  int new_alloc = fd_mode_count * 2;
  if (fd >= new_alloc)
    new_alloc = fd + 1;

  fd_modes = myrealloc(fd_modes, sizeof(*fd_modes) * new_alloc);
  for (i = fd_mode_count; i < new_alloc; ++i)
    fd_modes[i] = 0;
  fd_mode_count = new_alloc;
}

static double
time_h(void) {
  struct timeval tv;

  gettimeofday(&tv, NULL);

  return tv.tv_sec + 1e-6 * tv.tv_usec;
}

static int
_epoll_from_poe_mode(int mode) {
  switch (mode) {
  case MODE_RD:
    return EPOLLIN;

  case MODE_WR:
    return EPOLLOUT;

  case MODE_EX:
    return EPOLLPRI;

  default:
    croak("Unknown filehandle watch mode %d", mode);
  }  
}

#ifdef XS_LOOP_TRACE

static const char *
epoll_mode_names(int mask) {
  switch (mask) {
  case 0:
  case EPOLLIN:
    return "EPOLLIN";

  case EPOLLOUT:
    return "EPOLLOUT";

  case EPOLLPRI:
    return "EPOLLPRI";

  case EPOLLIN | EPOLLOUT:
    return "EPOLLIN | EPOLLOUT";

  case EPOLLIN | EPOLLPRI:
    return "EPOLLIN | EPOLLPRI";

  case EPOLLOUT | EPOLLPRI:
    return "EPOLLOUT | EPOLLPRI";

  case EPOLLOUT | EPOLLIN | EPOLLPRI:
    return "EPOLLOUT | EPOLLIN | EPOLLPRI";

  default:
    return "Unknown";
  }
}

static char const *
epoll_cmd_names(int cmd) {
  switch (cmd) {
  case EPOLL_CTL_ADD:
    return "EPOLL_CTL_ADD";
  case EPOLL_CTL_MOD:
    return "EPOLL_CTL_MOD";
  case EPOLL_CTL_DEL:
    return "EPOLL_CTL_DEL";
  default:
    return "Unknown";
  }
}

#endif

static void
lp_loop_do_timeslice(SV *kernel) {
  double delay = 3600;
  int count;
  struct epoll_event *events = mymalloc(sizeof(struct epoll_event) * fd_mode_count);
  
  TRACEF(("loop_do_timeslice()\n - entry\n"));

  poe_test_if_kernel_idle(kernel);

  if (lp_next_time) {
    delay = lp_next_time - time_h();
    if (delay > 3600)
      delay = 3600;
  }
  if (delay < 0)
    delay = 0;

#ifdef XS_LOOP_TRACE
  {
    int i;
    TRACEF(("  Delay %f\n", delay));
    for (i = 0; i < fd_mode_count; ++i) {
      if (fd_modes[i]) {
	TRACEF(("  fd %3d mask %x (%s)\n", i, fd_modes[i], epoll_mode_names(fd_modes[i])));
      }
    }
  }
#endif
  count = epoll_wait(epoll_fd, events, fd_mode_count, (int)(delay * 1000));

  TRACEF(("epoll_wait() => %d\n", count));

  if (count < 0) {
    warn("epoll() error: %d\n", errno);
  }
  else if (count) {
    int mode;
    int i;
    int *fds[3] = { NULL };
    int counts[3] = { 0, 0, 0 };
    int masks[3];

    fds[0] = mymalloc(sizeof(int) * fd_mode_count * 3);
    fds[1] = fds[0] + fd_mode_count;
    fds[2] = fds[1] + fd_mode_count;
    for (mode = MODE_RD; mode <= MODE_EX; ++mode) {
      masks[mode] = _epoll_from_poe_mode(mode);
    }

    /* build an array of fds for each event */
    for (i = 0; i < count; ++i) {
      int revents = events[i].events;
      for (mode = MODE_RD; mode <= MODE_EX; ++mode) {
	if (revents & masks[mode]) {
	  fds[mode][counts[mode]++] = events[i].data.fd;
	}
      }
    }

    TRACEF((" - queueing events\n"));
    for (mode = MODE_RD; mode <= MODE_EX; ++mode) {
      if (counts[mode])
	poe_enqueue_data_ready(kernel, mode, fds[mode], counts[mode]);
    }
    myfree(fds[0]);
  }

  TRACEF((" - dispatching events\n"));
  poe_data_ev_dispatch_due(kernel);
  TRACEF((" - exit\n"));
}

static void
lp_loop_run(SV *kernel) {
  TRACEF(("loop_run()\n"));
  while (poe_data_ses_count(kernel)) {
    lp_loop_do_timeslice(kernel);
  }
}

static void
lp_loop_resume_time_watcher(double next_time) {
  TRACEF(("loop_resume_time_watcher(%.3f) %.3f from now\n",
	  next_time, next_time - time_h()));
  lp_next_time = next_time;
}

static void
lp_loop_reset_time_watcher(double next_time) {
  TRACEF(("loop_reset_time_watcher(%.3f) %.3f from now\n", 
	  next_time, next_time - time_h()));
  lp_next_time = next_time;
}

static void
lp_loop_pause_time_watcher(SV *kernel) {
  TRACEF(("loop_pause_time_watcher()\n"));
  lp_next_time = 0;
}

static void
lp_loop_watch_filehandle(PerlIO *handle, int mode) {
  int fd = PerlIO_fileno(handle);
  int old_mode;
  struct epoll_event event;
  int cmd;

  if (fd_mode_count <= fd)
    _expand_fd_modes(fd);

  TRACEF(("loop_watch_filehandle(%d, %d %s)\n", fd, mode, poe_mode_names(mode)));

  old_mode = fd_modes[fd];
  event.events = old_mode | _epoll_from_poe_mode(mode);
  event.data.fd = fd;
  cmd = old_mode ? EPOLL_CTL_MOD : EPOLL_CTL_ADD;
  TRACEF(("epoll_ctl(%d, %d %s, %d, %x (%s))\n", epoll_fd, cmd, epoll_cmd_names(cmd), fd, event.events, epoll_mode_names(event.events)));
  if (epoll_ctl(epoll_fd, cmd, fd, &event) == -1)
    warn("epoll_ctl failed: %d\n", errno);
  fd_modes[fd] = event.events;
}

static void
lp_loop_ignore_filehandle(PerlIO *handle, int mode) {
  int fd = PerlIO_fileno(handle);
  
  TRACEF(("loop_ignore_filehandle(%d, %d %s)\n", fd, mode, poe_mode_names(mode)));

  if (fd <= fd_mode_count && fd_modes[fd]) {
    int new_mode = fd_modes[fd] & ~_epoll_from_poe_mode(mode);
    int cmd = new_mode ? EPOLL_CTL_MOD : EPOLL_CTL_DEL;
    struct epoll_event event;

    event.events = new_mode;
    event.data.fd = fd;
    
    if (epoll_ctl(epoll_fd, cmd, fd, &event) == -1)
      warn("epoll_ctl failed: %d\n", errno);
    fd_modes[fd] = new_mode;
    TRACEF(("epoll_ctl(%d, %d %s, %d, %x (%s))\n", epoll_fd, cmd, epoll_cmd_names(cmd), fd, event.events, epoll_mode_names(event.events)));
  }
}

MODULE = POE::XS::Loop::EPoll  PACKAGE = POE::Kernel PREFIX = lp_

PROTOTYPES: DISABLE

void
lp_loop_initialize(kernel)
  SV *kernel

void
lp_loop_finalize(kernel)
  SV *kernel

void
lp_loop_do_timeslice(kernel)
  SV *kernel

void
lp_loop_run(kernel)
  SV *kernel

void
lp_loop_halt(kernel)

void
lp_loop_pause_time_watcher(kernel)
  SV *kernel

void
lp_loop_attach_uidestroy(kernel)

MODULE = POE::XS::Loop::EPoll  PACKAGE = POE::Kernel PREFIX = lpm_

void
lpm_loop_resume_time_watcher(self, next_time)
  double next_time

void
lpm_loop_reset_time_watcher(self, next_time);
  double next_time

void
lpm_loop_watch_filehandle(self, fh, mode)
  PerlIO *fh
  int mode

void
lpm_loop_ignore_filehandle(self, fh, mode)
  PerlIO *fh
  int mode

void
lpm_loop_pause_filehandle(self, fh, mode)
  PerlIO *fh
  int mode

void
lpm_loop_resume_filehandle(self, fh, mode)
  PerlIO *fh
  int mode
