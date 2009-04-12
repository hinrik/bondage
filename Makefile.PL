use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'App::Bondage',
    AUTHOR        => 'Hinrik Örn Sigurðsson <hinrik.sig@gmail.com>',
    VERSION_FROM  => 'lib/App/Bondage.pm',
    ABSTRACT_FROM => 'lib/App/Bondage.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.31
        ? (LICENSE => 'perl')
        : ()
    ),
    EXE_FILES     => [ 'script/bondage' ],
    PREREQ_PM     => {
        'POE::Component::Client::DNS' => '0.99',
        'POE::Component::Daemon'      => '0',
        'POE::Component::IRC'         => '6.06',
        'POE::Filter::IRCD'           => '2.34',
        'Config::Any'                 => '0.11',
        'Tie::File'                   => '0',
        'Digest::MD5'                 => '0',
        'Test::More'                  => '0',
    }
);
