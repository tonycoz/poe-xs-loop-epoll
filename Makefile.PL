#!perl -w
use strict;
use ExtUtils::MakeMaker;
use Getopt::Long;

unless ($^O eq 'linux') {
  die "OS unsupported: this module requires Linux\n";
}

my $trace;
my $default;
GetOptions('trace' => \$trace,
	   'default' => \$default);

if ($^O eq 'MSWin32') {
  die "OS unsupported: this module requires that your system implements the poll(2) API\n";
}

# Switch to default behavior if STDIN isn't a tty.
# maybe POE::Test::Loops should export a function that does all this...
unless (-t STDIN) {
  warn(
       "\n",
       "=============================================\n\n",
       "STDIN is not a terminal.  Assuming --default.\n\n",
       "=============================================\n\n",
    );
  ++$default;
}

# Remind the user she can use --default.

unless ($default) {
  warn(
       "\n",
       "================================================\n\n",
       "Prompts may be bypassed with the --default flag.\n\n",
       "================================================\n\n",
      );
}

# Should we run the network tests?

my $prompt = (
	      "Some of POE's tests require a functional network.\n" .
	      "You can skip these tests if you'd like.\n\n" .
	      "Would you like to skip the network tests?"
	     );

my $ret = "n";
if ($default) {
  print $prompt, " [$ret] $ret\n\n";
}
else {
  $ret = prompt($prompt, "n");
}

my $marker = 'run_network_tests';
unlink $marker;
if ($ret =~ /^n$/i) {
  open(TOUCH,"+>$marker") and close TOUCH;
}

print "\n";

system 
  ( 
   $^X, '-S', 'poe-gen-tests',
   '--dirbase', 't', 
   '--loop', 'POE::XS::Loop::EPoll' 
  )
  and die $!;
  
my %opts = 
  (
   NAME => 'POE::XS::Loop::EPoll',
   VERSION_FROM => 'lib/POE/XS/Loop/EPoll.pm',
   OBJECT => 'EPoll.o alloc.o poexs.o',
   PREREQ_PM => {
		 'POE'    => 1.00,
		},
   test => {
	    TESTS => 't/poe_xs_loop_epoll/*.t',
	   },
  );
my $eu_mmv = eval $ExtUtils::MakeMaker::VERSION;
if ($eu_mmv > 6.06) {
  $opts{AUTHOR} = 'Tony Cook <tonyc@cpan.org>';
  $opts{ABSTRACT} = 'XS loop implementation for POE';
}
if ($trace) {
  warn <<TRACEMSG;
==============================

Building with tracing enabled

==============================

TRACEMSG
  $opts{DEFINE} = '-DXS_LOOP_TRACE';
}
else {
  warn <<TRACEMSG;
========================================

Building with tracing disabled - run:

  perl Makefile.PL --trace

for runtime POE tracing of the loop code

========================================
TRACEMSG
}
if ($eu_mmv > 6.30) {
  $opts{LICENSE} = 'perl';
}

WriteMakefile(%opts);


