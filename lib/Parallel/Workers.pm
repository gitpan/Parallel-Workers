package Parallel::Workers;

use warnings;
use strict;
use Carp;
use Scalar::Util qw(blessed dualvar isweak readonly refaddr reftype tainted
                        weaken isvstring looks_like_number set_prototype);
use threads 1.39;
use threads::shared;
use Thread::Queue;
use Data::Dumper;
use Parallel::Workers::Transaction;
use Parallel::Workers::Backend;
use Parallel::Workers::Shared;

use version; 


our (@ISA, @EXPORT, @EXPORT_OK, $VERSION);
@ISA = qw(Exporter);

@EXPORT = qw($VERSION);
@EXPORT_OK = ();

$VERSION = '0.0.5';



# Flag to inform all threads that application is terminating
my $TERM :shared = 0;

# Prevents double detach attempts
my $DETACHING :shared;

my $ID:shared = 0;

my $shared_jobs;


# maxworkers =>64 , maxjobs=>100, 
# transport=> SSH|XMLRPC|LOCAL, constructor=>%options, 
# transaction=>{pre=>CONT|EXIT, do=>CONT|EXIT, post =>CONT|EXIT}

sub new {
    my $class:shared = shift;
    my %params = @_;
    my $this={};
    
    shared_hash_set($this, "maxworkers",(defined($params{maxworkers}))?$params{maxworkers}:16);
    shared_hash_set($this, "maxjobs", (defined($params{maxjobs}))?$params{maxjobs}:32);
    shared_hash_set($this, "timeout", (defined($params{timeout}))?$params{timeout}:10);
    shared_hash_set($this, "transaction", Parallel::Workers::Transaction->new(%{$params{transaction}}));
    
# Wait for max timeout for threads to finish
    my $backend=(defined $params{backend})?"Parallel::Workers::Backend::".$params{backend}:"Parallel::Workers::Backend::Null";
    
    shared_hash_set($this,'jobsbackend',Parallel::Workers::Backend->new(backend=> $backend, constructor =>(defined $params{constructor})?%{$params{constructor}}:undef));
#    $this->{jobsbackend}=;
    
    
#    $this->{jobs}=%shared_jobs;
    bless $this, $class;
    
    return $this;
}

sub clear{
  my $this = shift;
  $shared_jobs={};
}

# hosts => @hosts, command=>, params=>
# return $jobid
sub create{
  my $this = shift;
  my %params = @_;
  
  my @hosts=@{$params{hosts}};
  my $totaljobs=@hosts;
  my $jobs=0;
  my $current_job=0;
  # Manage the thread pool until signalled to terminate
  my $id=__genid();
  my $commands;
  $shared_jobs->{$id}=&share({});
  $shared_jobs->{$id}->{time}=time();
  $this->{transaction}->commit;
  while (! $TERM && $totaljobs && $this->{transaction}->status() ne "error") {
    $jobs=($totaljobs>$this->{maxworkers})?$this->{maxworkers}:$totaljobs;
    $totaljobs-=$jobs;
    $this->{transaction}->start($jobs);
    for ($jobs=$jobs;$jobs && ! $TERM;$jobs--){
      # New thread
      
      $commands=  { 
                     cmd=>$params{command}, params=>$params{params}, 
                     pre=>$params{pre}, preparams=>$params{preparams},
                     post=>$params{post}, postparams=>$params{postparams}
                   };
      threads->new('jobworker', $this, $shared_jobs->{$id}, $id, $hosts[$current_job++], $commands,$this->{transaction});

    }
    #waiting the end of the pool
    $this->join();
    $this->{transaction}->commit();
  }
  print "terminated\n";
  return $id;
}

# wait infinity for the end of workers
sub join{
  my $self = shift;
  my %params = @_;
  foreach my $thr (threads->list()) {
    $thr->join() ;
  }
}

# stop the current pool after the timeout done
sub stop{
  my $this = shift;
  my %params = @_;
  $TERM=1;
  
  ### CLEANING UP ###

  # Wait for max timeout for threads to finish
  while ((threads->list() > 0) && $this->{timeout}--) {
    sleep(1);
  }

  # Detach and kill any remaining threads
  foreach my $thr (threads->list()) {
    lock($DETACHING);
    $thr->detach() if ! $thr->is_detached();
    $thr->kill('KILL');
  }  
  $TERM=0;
}

sub info{
  my $this = shift;
  return $shared_jobs;
#  return $shared_jobs;
}

sub __genid{
  return "$$-".$ID++;
}

#private fonction called by thread
sub jobworker{
  my ($this, $job, $id, $host, $params, $transaction)=@_;
  my $tid = threads->tid();
  my %host;
  $host{cmd}=$params->{cmd};
  $host{params}=$params->{params};
  shared_hash_set($job,$host,\%host);
#  $job->{$host}=shared_share(\%host);
  eval{
    if (defined $params->{pre}){
      $job->{$host}->{status}="preprocessing";
      my $pre=$this->{jobsbackend}->pre($id, $host, $params->{pre}, $params->{preparams});
      $job->{$host}->{pre}=shared_share($pre);
      $transaction->put($tid,$pre);

      if ($transaction->continue("pre") eq TRANSACTION_TERM){
        print ">>>>>>>>>>transaction return TRANSACTION_TERM\n";
        $job->{$host}->{status}="transaction term";
        return;
      }
    }
    $job->{$host}->{status}="processing";
    my $do=$this->{jobsbackend}->do($id, $host, $params->{cmd}, $params->{params});
    $transaction->put($tid,$do);
    $job->{$host}->{do}=shared_share($do);
    if ($transaction->continue("do") eq TRANSACTION_TERM){
      print ">>>>>>>>>>transaction return TRANSACTION_TERM\n";
      $job->{$host}->{status}="transaction term";
      return;
    }
    
    
    if (defined $params->{post}){
      $job->{$host}->{status}="postprocessing";
      my $post=$this->{jobsbackend}->post($id, $host, $params->{post}, $params->{postparams});
      $job->{$host}->{post}=shared_share($post);
    }
  }; 
  if ($@){
    $job->{$host}->{error}=$@;
    $job->{$host}->{status}="error";
  }
  $job->{$host}->{status}="done";
  return;
}


### Signal Handling ###

# Gracefully terminate application on ^C
# or command line 'kill'
# $SIG{'INT'} = $SIG{'TERM'} =
#     sub {
#         print(">>> Terminating <<<\n");
#         $TERM = 1;
# };

# This signal handler is called inside threads
# that get cancelled by the timer thread
# $SIG{'KILL'} =
#     sub {
# # Tell user we've been terminated
#         printf("           %3d <- Killed\n", threads->tid());
# # Detach and terminate
#         lock($DETACHING);
#         threads->detach() if ! threads->is_detached();
#         threads->exit();
# };

1; # Magic true value required at end of module
__END__

=head1 NAME

Parallel::Workers - [One line description of module's purpose here]


=head1 VERSION

This document describes Parallel::Workers version 0.0.1


=head1 SYNOPSIS

    use Parallel::Workers;

=for author to fill in:
    Brief code example(s) here showing commonest usage(s).
    This section will be as far as many users bother reading
    so make it as educational and exeplary as possible.
  
  
=head1 DESCRIPTION

=for author to fill in:
    Write a full description of the module and its features here.
    Use subsections (=head2, =head3) as appropriate.


=head1 INTERFACE 

=for author to fill in:
    Write a separate section listing the public components of the modules
    interface. These normally consist of either subroutines that may be
    exported, or methods that may be called on objects belonging to the
    classes provided by the module.


=head1 DIAGNOSTICS

=for author to fill in:
    List every single error and warning message that the module can
    generate (even the ones that will "never happen"), with a full
    explanation of each problem, one or more likely causes, and any
    suggested remedies.

=over

=item C<< Error message here, perhaps with %s placeholders >>

[Description of error here]

=item C<< Another error message here >>

[Description of error here]

[Et cetera, et cetera]

=back


=head1 CONFIGURATION AND ENVIRONMENT

=for author to fill in:
    A full explanation of any configuration system(s) used by the
    module, including the names and locations of any configuration
    files, and the meaning of any environment variables or properties
    that can be set. These descriptions must also include details of any
    configuration language used.
  
Parallel::Workers requires no configuration files or environment variables.


=head1 DEPENDENCIES

=for author to fill in:
    A list of all the other modules that this module relies upon,
    including any restrictions on versions, and an indication whether
    the module is part of the standard Perl distribution, part of the
    module's distribution, or must be installed separately. ]

None.


=head1 INCOMPATIBILITIES

=for author to fill in:
    A list of any modules that this module cannot be used in conjunction
    with. This may be due to name conflicts in the interface, or
    competition for system or program resources, or due to internal
    limitations of Perl (for example, many modules that use source code
    filters are mutually incompatible).

None reported.


=head1 BUGS AND LIMITATIONS

=for author to fill in:
    A list of known problems with the module, together with some
    indication Whether they are likely to be fixed in an upcoming
    release. Also a list of restrictions on the features the module
    does provide: data types that cannot be handled, performance issues
    and the circumstances in which they may arise, practical
    limitations on the size of data sets, special cases that are not
    (yet) handled, etc.

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-parallel-jobs@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Olivier Evalet  C<< <evaleto@gelux.ch> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2006, Olivier Evalet C<< <evaleto@gelux.ch> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.
