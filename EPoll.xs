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

#define XS_LOOP_DEBUG

#if defined(MEM_DEBUG) || defined(XS_LOOP_DEBUG)
/* sizes that should require re-allocation of the arrays */
#define START_FD_ALLOC 5
#define START_LOOKUP_ALLOC 10
#else
/* more than we need on average */
#define START_FD_ALLOC 50
#define START_LOOKUP_ALLOC 100
#endif

#ifdef XS_LOOP_DEBUG
static void check_state_fl(char const *file, int line);
#define CHECK_STATE() check_state_fl(__FILE__, __LINE__)
#else
#define CHECK_STATE()
#endif

/* these functions don't need the kernel argument, do don't supply it */
#define lpm_loop_resume_time_watcher(self, next_time) lp_loop_resume_time_watcher(next_time)
#define lpm_loop_reset_time_watcher(self, next_time) lp_loop_reset_time_watcher(next_time)
#define lpm_loop_watch_filehandle(self, handle, mode) lp_loop_watch_filehandle(handle, mode)
#define lpm_loop_ignore_filehandle(self, handle, mode) lp_loop_ignore_filehandle(handle, mode)
#define lpm_loop_pause_filehandle(self, handle, mode) lp_loop_pause_filehandle(handle, mode)
#define lpm_loop_resume_filehandle(self, handle, mode) lp_loop_resume_filehandle(handle, mode)

/* no ops */
#define lp_loop_attach_uidestroy(kernel)
#define lp_loop_halt(kernel)

/* the next time-based event to be dispatched */
static double lp_next_time;

#ifdef XS_LOOP_TRACE
/* when we started working, used only for tracing */
static double lp_start_time;
#endif

static double
time_h(void);

typedef struct {
  int fd;

  /* the events currently set with epoll_ctl() */
  int current_events;

  /* the events as set by watch/ignore/pause/resume */
  int want_events;

  /* the requested watch/ignore state, this is only used to check if
     we want to keep an fd entry for this fd.
     I want a better name.
  */
  int global_events;

  /* whether we got an eperm adding this
     this means it's a normal file, which we always return
     readable/writable for
  */
  int eperm;

  /* whether changes to this fd have been queued for later changes */
  int queued;
} fd_state;

/* the fd returned by epoll_create() and passed to
   epoll_ctl()/epoll_wait() */
static int epoll_fd = -1;

static fd_state *fds;
static int fd_count;
static int fd_alloc;
static int *fd_queue;
static int fd_queue_size;
static int fd_queue_alloc;

static int *fd_lookup;
static int fd_lookup_count;

/* functions should be static, hopefully the compiler will inline them
   into the XS code */

static void
lp_loop_initialize(SV *kernel) {
  int i;

  POE_TRACE_CALL(("<cl> loop_initialize()\n"));

  if (epoll_fd != -1) {
    warn("loop_initialize() called while loop is active");
  }

  lp_next_time = 0;
  epoll_fd = epoll_create(START_FD_ALLOC);
  fds = mymalloc(sizeof(*fds) * START_FD_ALLOC);
  fd_count = 0;
  fd_alloc = START_FD_ALLOC;

  fd_lookup = mymalloc(sizeof(int) * START_LOOKUP_ALLOC);
  fd_lookup_count = START_LOOKUP_ALLOC;
  for (i = 0; i < fd_lookup_count; ++i) {
    fd_lookup[i] = -1;
  }

  fd_queue = mymalloc(sizeof(*fd_queue) * START_FD_ALLOC);
  fd_queue_size = 0;
  fd_queue_alloc = START_FD_ALLOC;

  CHECK_STATE();

#ifdef XS_LOOP_TRACE
  lp_start_time = time_h();
#endif
}

static void
lp_loop_finalize(SV *kernel) {
  POE_TRACE_CALL(("<cl> loop_finalize()\n"));

  CHECK_STATE();

  if (epoll_fd != -1) {
    close(epoll_fd);
    epoll_fd = -1;
  }
  myfree(fds);
  fds = NULL;
  myfree(fd_lookup);
  fd_lookup = NULL;
  myfree(fd_queue);
  fd_queue = NULL;
}

static void
_expand_fd_lookup(int fd) {
  int i;
  int new_alloc = fd_lookup_count * 2;
  if (fd >= new_alloc)
    new_alloc = fd + 1;

  fd_lookup = myrealloc(fd_lookup, sizeof(*fd_lookup) * new_alloc);
  for (i = fd_lookup_count; i < new_alloc; ++i)
    fd_lookup[i] = -1;
  fd_lookup_count = new_alloc;

  CHECK_STATE();
}

static void
_expand_fds(void) {
  int new_alloc = fd_alloc * 2;
  fds = myrealloc(fds, sizeof(*fds) * new_alloc);
  fd_alloc = new_alloc;

  CHECK_STATE();
}

static int
_get_fd_entry(int fd) {
  if (fd < 0 && fd >= fd_lookup_count)
    return -1;

  return fd_lookup[fd];
}

static int
_make_fd_entry(int fd) {
  int entry;

  CHECK_STATE();

  if (fd < 0)
    return -1;
  if (fd > fd_lookup_count)
    _expand_fd_lookup(fd);

  if (fd_lookup[fd] != -1)
    return fd_lookup[fd];

  if (fd_count == fd_alloc) {
    _expand_fds();
  }
  entry = fd_count++;
  fd_lookup[fd] = entry;
  fds[entry].fd = fd;
  fds[entry].current_events = 0;
  fds[entry].want_events = 0;
  fds[entry].global_events = 0;
  fds[entry].eperm = 0;
  fds[entry].queued = 0;

  CHECK_STATE();

  return entry;
}

static void
_release_fd_entry(int fd) {
  int entry = _get_fd_entry(fd);

  if (entry < 0) {
    warn("Attempt to release entry for unused fd");
    return;
  }

  if (entry != fd_count-1) {
    fds[entry] = fds[fd_count-1];
    fd_lookup[fds[entry].fd] = entry;
  }

  --fd_count;
  fd_lookup[fd] = -1;

  CHECK_STATE();
}

static void
_queue_fd_change(int entry) {
  if (!fds[entry].queued
      && fds[entry].want_events != fds[entry].current_events) {
    int fd = fds[entry].fd;

    if (fd_queue_size >= fd_queue_alloc) {
      int new_alloc = fd_queue_alloc * 2;

      fd_queue = myrealloc(fd_queue, sizeof(*fd_queue) * new_alloc);
      fd_queue_alloc = new_alloc;
    }

    fd_queue[fd_queue_size++] = fd;
    fds[entry].queued = 1;
  }
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
    return "none";
    
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
wrap_ctl(int entry) {
  int cmd;
  struct epoll_event event;

  if (fds[entry].current_events == fds[entry].want_events)
    return;

  event.data.fd = fds[entry].fd;
  event.events = fds[entry].want_events;
  if (fds[entry].current_events) {
    if (fds[entry].want_events) {
      cmd = EPOLL_CTL_MOD;
    }
    else {
      cmd = EPOLL_CTL_DEL;
    }
  }
  else {
    cmd = EPOLL_CTL_ADD;
  }
  POE_TRACE_CALL(("<cl> epoll_ctl(%d, %d %s, %d, %x (%s))\n", epoll_fd, cmd, epoll_cmd_names(cmd), event.data.fd, event.events, epoll_mode_names(event.events)));
  if (epoll_ctl(epoll_fd, cmd, event.data.fd, &event) == -1)
    warn("epoll_ctl failed: %d\n", errno);
  fds[entry].current_events = fds[entry].want_events;
}

static int
test_masks[] =
  {
    EPOLLIN | EPOLLERR,
    EPOLLOUT | EPOLLERR,
    EPOLLPRI | EPOLLHUP | EPOLLERR,
  };

static void
lp_loop_do_timeslice(SV *kernel) {
  double delay = 3600;
  double now;
  int count;
  int check_count = fd_count ? fd_count : 1;
  struct epoll_event *events = mymalloc(sizeof(struct epoll_event) * check_count);
  int i;
  
  POE_TRACE_CALL(("<cl> loop_do_timeslice()\n - entry, fd_count %d\n", fd_count));

  poe_test_if_kernel_idle(kernel);

  /* scan for any ctl calls that need to be made */
  for (i = 0; i < fd_queue_size; ++i) {
    int fd = fd_queue[i];
    int entry = _get_fd_entry(fd);
    if (entry != -1) {
      if (fds[entry].want_events != fds[entry].current_events)
	wrap_ctl(entry);
      fds[entry].queued = 0;
    }
  }
  fd_queue_size = 0;

  now = time_h();
  if (lp_next_time) {
    delay = lp_next_time - now;
    if (delay > 3600)
      delay = 3600;
  }
  if (delay < 0)
    delay = 0;

#ifdef XS_LOOP_TRACE
  {
    int i;
    POE_TRACE_FILE(("<fh> ,---- XS EPOLL FDS IN ----\n"));
    for (i = 0; i < fd_count; ++i) {
      POE_TRACE_FILE(("<fh>  fd %3d mask %x (%s)\n", fds[i].fd, fds[i].want_events, epoll_mode_names(fds[i].want_events)));
    }
    POE_TRACE_FILE(("<fh> `-------------------------\n"));
  }
#endif
  POE_TRACE_EVENT(("<ev> Kernel::run() iterating (XS) now(%.4f) timeout(%.4f)"
    " then(%.4f)\n", now - lp_start_time, delay, (now - lp_start_time) + delay));
  count = epoll_wait(epoll_fd, events, check_count, (int)(delay * 1000));

#ifdef XS_LOOP_TRACE
  {
    int i;
    POE_TRACE_FILE(("<fh> epoll_wait() => %d\n", count));
    POE_TRACE_FILE(("<fh> /---- XS EPOLL FDS OUT ----\n"));
    for (i = 0; i < count; ++i) {
      POE_TRACE_FILE(("<fh> | Index %d fd %d mask %x (%s)\n", i,
		      events[i].data.fd, events[i].events, epoll_mode_names(events[i].events)));
		      
    }
    POE_TRACE_FILE(("<fh> `-------------------------\n"));
  }
#endif

  if (count < 0) {
    warn("epoll() error: %d\n", errno);
  }
  else if (count) {
    int mode;
    int i;
    int *queue_fds[3] = { NULL };
    int counts[3] = { 0, 0, 0 };

    queue_fds[0] = mymalloc(sizeof(int) * fd_count * 3);
    queue_fds[1] = queue_fds[0] + fd_count;
    queue_fds[2] = queue_fds[1] + fd_count;

    /* build an array of fds for each event */
    for (i = 0; i < count; ++i) {
      int revents = events[i].events;
      for (mode = MODE_RD; mode <= MODE_EX; ++mode) {
	if (revents & test_masks[mode]) {
	  queue_fds[mode][counts[mode]++] = events[i].data.fd;
	}
      }
    }

    for (mode = MODE_RD; mode <= MODE_EX; ++mode) {
      if (counts[mode])
	poe_enqueue_data_ready(kernel, mode, queue_fds[mode], counts[mode]);
    }
    myfree(queue_fds[0]);
  }
  myfree(events);

  poe_data_ev_dispatch_due(kernel);
}

static void
lp_loop_run(SV *kernel) {
  POE_TRACE_CALL(("<cl> loop_run()\n"));
  while (poe_data_ses_count(kernel)) {
    lp_loop_do_timeslice(kernel);
  }
}

static void
lp_loop_resume_time_watcher(double next_time) {
  POE_TRACE_CALL(("<cl> loop_resume_time_watcher(%.3f) %.3f from now\n",
	  next_time, next_time - time_h()));
  lp_next_time = next_time;
}

static void
lp_loop_reset_time_watcher(double next_time) {
  POE_TRACE_CALL(("<cl> loop_reset_time_watcher(%.3f) %.3f from now\n", 
	  next_time, next_time - time_h()));
  lp_next_time = next_time;
}

static void
lp_loop_pause_time_watcher(SV *kernel) {
  POE_TRACE_CALL(("<cl> loop_pause_time_watcher()\n"));
  lp_next_time = 0;
}

static void
lp_loop_watch_filehandle(PerlIO *handle, int mode) {
  int fd = PerlIO_fileno(handle);
  int entry;
  int mask = _epoll_from_poe_mode(mode);

  if (fd_lookup_count <= fd)
    _expand_fd_lookup(fd);

  POE_TRACE_CALL(("<cl> loop_watch_filehandle(%d, %d %s)\n", fd, mode, poe_mode_names(mode)));

  entry = _make_fd_entry(fd);
  fds[entry].want_events |= mask;
  fds[entry].global_events |= mask;
  _queue_fd_change(entry);
}

static void
lp_loop_ignore_filehandle(PerlIO *handle, int mode) {
  int fd = PerlIO_fileno(handle);
  int entry = _get_fd_entry(fd);
  int mask = _epoll_from_poe_mode(mode);
  
  POE_TRACE_CALL(("<cl> loop_ignore_filehandle(%d, %d %s)\n", fd, mode, poe_mode_names(mode)));

  if (entry == -1) {
    POE_TRACE_FILE(("<fh> loop_ignore_filehandle: attempt to remove unwatched filehandle\n"));
    return;
  }

  fds[entry].want_events &= ~mask;
  fds[entry].global_events &= ~mask;
  if (!fds[entry].want_events) {
    if (fds[entry].current_events) {
      wrap_ctl(entry);
    }
    if (!fds[entry].global_events)
      _release_fd_entry(fd);
  }
  else {
    _queue_fd_change(entry);
  }
}

static void
lp_loop_pause_filehandle(PerlIO *handle, int mode) {
  int fd = PerlIO_fileno(handle);
  int entry = _get_fd_entry(fd);
  
  POE_TRACE_CALL(("<cl> loop_pause_filehandle(%d, %d %s)\n", fd, mode, poe_mode_names(mode)));

  if (entry == -1) {
    POE_TRACE_FILE(("loop_pause_filehandle: attempt to remove unwatched filehandle\n"));
    return;
  }

  fds[entry].want_events &= ~_epoll_from_poe_mode(mode);
  _queue_fd_change(entry);
}

static void
lp_loop_resume_filehandle(PerlIO *handle, int mode) {
  int fd = PerlIO_fileno(handle);
  int entry;

  if (fd_lookup_count <= fd)
    _expand_fd_lookup(fd);

  POE_TRACE_CALL(("<cl> loop_resume_filehandle(%d, %d %s)\n", fd, mode, poe_mode_names(mode)));

  entry = _make_fd_entry(fd);
  fds[entry].want_events |= _epoll_from_poe_mode(mode);
  _queue_fd_change(entry);
}

#ifdef XS_LOOP_DEBUG

static void 
fail_check(const char *file, int line, const char *fmt, ...) {
  va_list args;

  fprintf(stderr, "Check failed %s:%d - ", file, line);
  va_start(args, fmt);
  vfprintf(stderr, fmt, args);
  va_end(args);
  croak("POE::XS::Loop::EPoll internal consistency check failed");
}

/* check the consistency of the state */
static void
check_state_fl(const char *file, int line) {
  int i;
  int found_fds = 0;

  if (fd_alloc < fd_count) {
    fail_check(file, line, "fd_alloc (%d) < fd_count (%d)\n", 
		fd_alloc, fd_count);
  }

  for (i = 0; i < fd_lookup_count; ++i) {
    int entry = fd_lookup[i];
    if (entry != -1) {
      ++found_fds;
      if (entry < 0 || entry >= fd_count) {
	fail_check(file, line, "entry %d for fd %d is outside the range 0 .. fd_count (%d) - 1\n", entry, i, fd_count);
      }

      if (i != fds[entry].fd) {
	fail_check(file, line, "entry %d for fd %d has fd %d\n",
		    entry, i, fds[entry].fd);
      }
    }
  }
  if (found_fds != fd_count) {
    /* there's an fd entry with no fd_lookup pointing at it */
    for (i = 0; i < fd_count; ++i) {
      int fd = fds[i].fd;
      if (fd < 0 || fd >= fd_lookup_count) {
	fail_check(file, line, "entry %d fd %d is out of range 0 .. fd_lookup_count (%d)\n", i, fd, fd_lookup_count);
      }
      if (fd_lookup[fd] != fd) {
	fail_check(file, line, "entry %d fd %d doesn't match fd_lookup[fd] (%d)\n", i, fd, fd_lookup[fd]);
      }
    }
  }
}

#endif

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
