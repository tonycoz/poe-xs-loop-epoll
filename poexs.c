#include "poexs.h"

/*
=head1 NAME

poexs.c - provide XS functions useful in implementing a POE::Loop implementation

=head1 SYNOPSIS

  #include "poexs.h"

  int fds[] = { ready fds };
  poe_enqueue_data_ready(kernel, MODE_RD, fds, fd_count);
  poe_data_ev_dispatch_due(kernel);
  poe_test_if_kernel_idle(kernel);
  int count = poe_data_ses_count(kernel);
  const char *mode_name = poe_mode_names(MODE_RD);

  // tracing enabled
  POE_TRACE_FILE(("<fh> something to do with files\n", ...));
  POE_TRACE_EVENT(("<ev> something to do with events\n", ...));
  POE_TRACE_CALL(("<cl> trace a function call\n", ...));

=head1 DESCRIPTION

This C source file provides functions and macros useful for
implementing a POE::Loop class in XS.

=head1 CONSTANTS

=over

=item MODE_RD

=item MODE_WR

=item MODE_EX

Filehandle modes supplied to loop_watch_filehandle(),
loop_ignore_filehandle(), loop_pause_filehandle(),
loop_resume_filehandle(), and supplied to poe_enqueue_data_ready()
when filehandles become ready.

=item POE_SV_FORMAT

The format string perl's sprintf() style formatters recognize to
format a SV*.  This is "%_" up to perl 5.9 and "%-p" from 5.10
onwards.  This isn't really POE specific, but it's useful for
formatting SVs.

=back

=head1 FUNCTIONS

=over

=item poe_enqueue_data_ready(kernel, mode, fds, fd_count)

Calls the _enqueue_data_ready() perl method on the given kernel
object.

Enqueues events with the POE kernel that the the given fds are ready
for the type of I/O indicated by mode.

This should be called by your loop_do_timeslice() implementation when
those filehandles are ready for I/O.

I<kernel> should be the kernel SV supplied to loop_do_timeslice(),
mode should be any of MODE_RD, MODE_WR or MODE_EX.

Warning: POE will make calls to loop_pause_filehandle() in processing
filehandles, make sure your filehandle structures can handle this
re-entrancy.

Return: void

=cut
*/

void
poe_enqueue_data_ready(SV *kernel, int mode, int *fds, int fd_count) {
  dSP;
  int i;

  POE_TRACE_CALL(("<cl> poe_enqueue_data_ready(mode %d (%s)", mode, poe_mode_names(mode)));

  ENTER;
  SAVETMPS;
  EXTEND(SP, fd_count+2);
  PUSHMARK(SP);
  PUSHs(sv_2mortal(newSVsv(kernel)));
  PUSHs(sv_2mortal(newSViv(mode)));
  for (i = 0; i < fd_count; ++i) {
    POE_TRACE_CALL((", %d", fds[i]));
    PUSHs(sv_2mortal(newSViv(fds[i])));
  }
  POE_TRACE_CALL((")\n"));
  PUTBACK;

  perl_call_method("_data_handle_enqueue_ready", G_DISCARD);

  FREETMPS;
  LEAVE;
}

/*
=item poe_data_ev_dispatch_due(kernel)

Calls the _data_ev_dispatch_due() method on the given kernel object.

This should be called at the end of your loop_do_timeslice()
implementation to dispatch any waiting events.

Return: void

=cut
*/

void
poe_data_ev_dispatch_due(SV *kernel) {
  dSP;

  ENTER;
  SAVETMPS;
  EXTEND(SP, 1);
  PUSHMARK(SP);
  PUSHs(sv_2mortal(newSVsv(kernel)));
  PUTBACK;

  perl_call_method("_data_ev_dispatch_due", G_DISCARD);

  FREETMPS;
  LEAVE;
}

/*
=item poe_test_if_kernel_idle(kernel)

Calls the _test_if_kernel_is_idle() method on the given POE kernel
object.

This should be called at the beginning of your loop_do_timeslice()
implementation.

Return: void

=cut
*/

void
poe_test_if_kernel_idle(SV *kernel) {
  dSP;

  ENTER;
  SAVETMPS;
  EXTEND(SP, 1);
  PUSHMARK(SP);
  PUSHs(sv_2mortal(newSVsv(kernel)));
  PUTBACK;

  perl_call_method("_test_if_kernel_is_idle", G_DISCARD);

  FREETMPS;
  LEAVE;
}

/*
=item poe_data_ses_count(kernel)

Calls the _data_ses_count() perl method on the given kernel object.

Your loop_run() implementation should call your loop_do_timeslice()
implementation while this function returns non-zero.

Returns non-zero if there are active POE sessions.

=cut
*/

int
poe_data_ses_count(SV *kernel) {
  dSP;
  int count;
  SV *result_sv;
  int result;

  ENTER;
  SAVETMPS;
  EXTEND(SP, 1);
  PUSHMARK(SP);
  PUSHs(sv_2mortal(newSVsv(kernel)));
  PUTBACK;

  count = perl_call_method("_data_ses_count", G_SCALAR);

  SPAGAIN;

  if (count != 1)
    croak("Result of perl_call_method(..., G_SCALAR) != 1");

  result_sv = POPs;
  result = SvTRUE(result_sv);

  PUTBACK;
  FREETMPS;
  LEAVE;

  return result;
}

/*
=item poe_mode_names(mode)

Returns a string describing a POE I/O mode, any of MODE_RD, MODE_WR,
MODE_EX.

Supplying any other value will croak()

Returns: a const char *.

=cut

=back
*/

const char *
poe_mode_names(int mode) {
  switch (mode) {
  case MODE_RD:
    return "MODE_RD";

  case MODE_WR:
    return "MODE_WR";

  case MODE_EX:
    return "MODE_EX";

  default:
    croak("Unknown filehandle watch mode %d", mode);
  }  
}

/*
=item poe_timeh()

Returns the current epoch time as a floating point value.

=cut
*/

double
poe_timeh(void) {
  struct timeval tv;

  gettimeofday(&tv, NULL);

  return tv.tv_sec + 1e-6 * tv.tv_usec;
}

/*
=item poe_trap(fmt, ...);

Call POE::Kernel::_trap() with the formatted string as the parameter.

=cut
*/
void
poe_trap(const char *fmt, ...) {
  SV *out = sv_2mortal(newSVpv("", 0));
  va_list va;
  dSP;
  int count;

  va_start(va, fmt);
  sv_vcatpvf(out, fmt, &va);
  va_end(va);

  ENTER;
  SAVETMPS;
  EXTEND(SP, 1);
  PUSHMARK(SP);
  PUSHs(out);
  PUTBACK;

  count = perl_call_pv("POE::Kernel::_trap", G_VOID | G_DISCARD);

  /* not sure we ever get here */
  FREETMPS;
  LEAVE;
}

#ifdef XS_LOOP_TRACE

static int trace_initialized;

static int trace_files;
static int trace_events;
static int trace_calls;
static int trace_statistics;

static int
get_trace_flag(const char *name) {
  dSP;
  int result;
  int count;
  SV *result_sv;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  PUTBACK;

  count = perl_call_pv(name, G_SCALAR);

  SPAGAIN;

  if (count != 1)
    croak("Result of perl_call_pv(\"%s\", G_SCALAR) != 1 %d", name, count);

  result_sv = POPs;
  result = SvTRUE(result_sv);

  FREETMPS;
  LEAVE;

  return result;
}


static void
do_trace_initialize(void) {
  trace_files = get_trace_flag("POE::Kernel::TRACE_FILES");
  trace_events = get_trace_flag("POE::Kernel::TRACE_EVENTS");
  trace_statistics = get_trace_flag("POE::Kernel::TRACE_STATISTICS");
  trace_calls = get_trace_flag("POE::Kernel::TRACE_CALLS");
  trace_initialized = 1;
}

static PerlIO *
get_trace_file(void) {
  return IoIFP(sv_2io(sv_2mortal(newSVpv("POE::Kernel::TRACE_FILE", 0))));
}

/*
=head1 TRACE MACROS

These macros are used for writing trace output to POE's trace file.

When trace is not enabled these macros are replaced with nothing.

Note the doubles parentheses on the POE_TRACE_ macros.

=over

=item POE_TRACE_FILE((format, ...))

Trace a file handle change, controlled by the POE TRACE_FILES
constant.

=item POE_TRACE_EVENT((format, ...))

Trace an event, controlled by the POE TRACE_EVENTS constant.

=item POE_TRACE_CALL((format, ...))

Trace a function call, controlled by the POE::Kernel::TRACE_CALLS
constant.  This must be set by your .pm if not set by POE's
mechanisms.

#define POE_STAT_ADD(kernel, name, value)

Update a statistic, controlled by the POE TRACE_STATISTICS constant.

=cut
*/

void
poexs_trace_file(const char *fmt, ...) {
  va_list va;

  if (!trace_initialized)
    do_trace_initialize();
  if (!trace_files)
    return;

  va_start(va, fmt);
  PerlIO_vprintf(get_trace_file(), fmt, va);
  va_end(va);
}

void
poexs_trace_event(const char *fmt, ...) {
  va_list va;

  if (!trace_initialized)
    do_trace_initialize();
  if (!trace_events)
    return;

  va_start(va, fmt);
  PerlIO_vprintf(get_trace_file(), fmt, va);
  va_end(va);
}

void
poexs_trace_call(const char *fmt, ...) {
  va_list va;

  if (!trace_initialized)
    do_trace_initialize();
  if (!trace_calls)
    return;

  va_start(va, fmt);
  PerlIO_vprintf(get_trace_file(), fmt, va);
  va_end(va);
}

void
poexs_data_stat_add(SV *kernel, const char *name, double value) {
  dSP;

  if (!trace_initialized)
    do_trace_initialize();
  if (!trace_statistics)
    return;

  ENTER;
  SAVETMPS;
  EXTEND(SP, 3);
  PUSHMARK(SP);
  PUSHs(sv_2mortal(newSVsv(kernel)));
  PUSHs(sv_2mortal(newSVpv(name, 0)));
  PUSHs(sv_2mortal(newSVnv(value)));
  PUTBACK;

  perl_call_pv("_data_stat_add", G_DISCARD);

  FREETMPS;
  LEAVE;
}

#endif

