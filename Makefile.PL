use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Net::Amazon::Glacier',
    AUTHOR              => q{Tim Nordenfur <tim@gurka.se>},
    VERSION_FROM        => 'lib/Net/Amazon/Glacier.pm',
    ABSTRACT_FROM       => 'lib/Net/Amazon/Glacier.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
		'Net::Amazon::Signature::V4' => 0,
		'Net::Amazon::TreeHash' => 0,
		'Digest::SHA' => 0,
		'File::Slurp' => 0,
		'JSON::PP' => 0,
		'LWP::UserAgent' => 0,
		'LWP::Protocol::https' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Net-Amazon-Glacier-*' },
);
