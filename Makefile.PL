use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'App::Bondage',
    AUTHOR        => 'Hinrik Örn Sigurðsson <hinrik.sig@gmail.com>',
    VERSION_FROM  => 'lib/App/Bondage/Common.pm',
    ABSTRACT_FROM => 'lib/App/Bondage.pm',
    LICENSE       => 'perl',
    EXE_FILES     => [ 'bin/bondage' ],
    PREREQ_PM     => {
        'POE::Component::Client::DNS' => '0.99',
        'POE::Component::Daemon'      => '0',
        'POE::Component::IRC'         => '5.56',
        'POE::Filter::IRCD'           => '2.34',
        'YAML::Syck'                  => '0',
    }
);
