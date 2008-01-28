use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'App::Bondage',
    AUTHOR        => 'Hinrik Örn Sigurðsson <hinrik.sig@gmail.com>',
    VERSION_FROM  => 'lib/App/Bondage/Common.pm',
    ABSTRACT      => 'A featureful easy-to-use IRC bouncer',
    LICENSE       => 'perl',
    EXE_FILES     => [ 'bin/bondage' ],
    PREREQ_PM     => {
        'POE::Component::Client::DNS' => '0',
        'POE::Component::Daemon'      => '0',
        'POE::Component::IRC'         => '5.54', 
        'POE::Filter::IRCD'           => '2.34',
        'YAML::Syck'                  => '0',
    }
);
