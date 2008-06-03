#include "poexs.h"

void
poe_enqueue_data_ready(SV *kernel, int mode, int *fds, int fd_count) {
  dSP;
  int i;

  TRACEF(("poe_enqueue_data_ready(mode %d (%s)", mode, poe_mode_names(mode)));

  ENTER;
  SAVETMPS;
  EXTEND(SP, fd_count+2);
  PUSHMARK(SP);
  PUSHs(sv_2mortal(newSVsv(kernel)));
  PUSHs(sv_2mortal(newSViv(mode)));
  for (i = 0; i < fd_count; ++i) {
    TRACEF((", %d", fds[i]));
    PUSHs(sv_2mortal(newSViv(fds[i])));
  }
  TRACEF((")\n"));
  PUTBACK;

  perl_call_method("_data_handle_enqueue_ready", G_DISCARD);

  FREETMPS;
  LEAVE;
}

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

  /*TRACEF(("_data_ses_count => %d\n", result));*/

  PUTBACK;
  FREETMPS;
  LEAVE;

  return result;
}

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

#ifdef XS_LOOP_TRACE

void
poexs_tracef(const char *fmt, ...) {
  va_list va;

  va_start(va, fmt);
  vfprintf(stderr, fmt, va);
  va_end(va);
}

#endif

