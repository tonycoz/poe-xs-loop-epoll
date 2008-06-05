package POE::XS::Loop::EPoll;
use strict;
use vars qw(@ISA $VERSION);
BEGIN {
  $VERSION = '0.001';
  eval {
    # try XSLoader first, DynaLoader has annoying baggage
    require XSLoader;
    XSLoader::load('POE::XS::Loop::EPoll' => $VERSION);
    1;
  } or do {
    require DynaLoader;
    push @ISA, 'DynaLoader';
    bootstrap POE::XS::Loop::EPoll $VERSION;
  }
}

require POE::Loop::PerlSignals;

# everything else is XS
1;

__END__

=head1 NAME

POE::XS::Loop::EPoll - an XS implementation of POE::Loop, using Linux` epoll(2).

=head1 SYNOPSIS

  use POE::Kernel { loop => 'POE::XS::Loop::EPoll' };

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface
written in C using the Linux epoll(2) family of system calls.

Signals are left to POE::Loop::PerlSignals.

=head1 SEE ALSO

POE, POE::Loop.

=head1 BUGS

Relies upon small fd numbers, but then a lot of code does.

=head1 LICENSE

POE::XS::Loop::EPoll is licensed under the same terms as Perl itself.

=head1 AUTHOR

Tony Cook <tonyc@cpan.org>

=cut

=for poe_tests

sub skip_tests {
  my $test = shift;
  $ENV{POE_EVENT_LOOP} = 'POE::XS::Loop::EPoll';
  $test eq 'wheel_readwrite'
    and return "epoll_ctl(2) doesn't work with plain files";
  return;
}

=cut
