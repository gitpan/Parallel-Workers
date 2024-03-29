use strict;
use warnings;
use ExtUtils::MakeMaker;

eval 'use ExtUtils::MakeMaker::Coverage';
warn "Optional ExtUtils::MakeMaker::Coverage not available\n" if $@;

WriteMakefile(
    ( MM->can( 'signature_target' ) ? ( SIGN => 1 ) : () ),
    NAME          => 'Parallel::Workers',
    AUTHOR        => 'Andy Armstrong <andy@hexten.net>',
    LICENSE       => 'perl',
    VERSION_FROM  => 'lib/Parallel/Workers.pm',
    ABSTRACT_FROM => 'lib/Parallel/Workers.pm',
    PL_FILES      => {},
    PREREQ_PM     => {
        'Test::More' => 0,
        'Storable'   => 0,
        'IO::Handle' => 0,
        'IO::Select' => 0,
        'Config'     => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES    => 'Parallel-Workers-*' },
);
