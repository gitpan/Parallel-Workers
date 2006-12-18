use Test::More tests => 8;

use_ok( 'Parallel::Workers' );
use_ok( 'Parallel::Workers::Transaction' );
use File::Basename;
use Data::Dumper;

my @hosts=(
  'host-1',
  'host-2',
);
my $id;
#
#LOCAL JOB
###################################################################################
my $worker=Parallel::Workers->new(maxworkers=>5,timeout=>10, backend=>"Local",
                                 transaction=>{pre=>TRANSACTION_TERM, do =>TRANSACTION_TERM, post=>TRANSACTION_CONT, enable=>1}
                                 );
ok(defined($worker),"new local worker");

$id=$worker->create(hosts => \@hosts, 
                              command=>"`echo olivier`"
                     );
$info=$worker->info();
ok($info->{$id}{'host-1'}{do} eq "olivier\n", "id=$id, host-13 do = olivier ");
ok(!defined ($info->{$id}{'host-1'}{pre}), "id=$id, host-13 pre is UNDEF");
ok(!defined ($info->{$id}{'host-1'}{post}), "id=$id, host-13 post is UNDEF");

$id=$worker->create(hosts => \@hosts, 
#                              pre=>"`echo olivier >/dev/null`",
                              command=>"system", params=>"\"ls -l slk\""
                     );
$info=$worker->info();
ok(!defined ($info->{$id}{'host-1'}{do}), "id=$id, host-13 do = UNDEF ");

#print Dumper ($info);





