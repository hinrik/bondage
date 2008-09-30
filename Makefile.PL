use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'App::Bondage',
    AUTHOR        => 'Hinrik Örn Sigurðsson <hinrik.sig@gmail.com>',
    VERSION_FROM  => 'lib/App/Bondage.pm',
    ABSTRACT_FROM => 'lib/App/Bondage.pm',
    LICENSE       => 'perl',
    EXE_FILES     => [ 'script/bondage' ],
    PREREQ_PM     => {
        'POE::Component::Client::DNS' => '0.99',
        'POE::Component::Daemon'      => '0',
        'POE::Component::IRC'         => '5.88',
        'POE::Filter::IRCD'           => '2.34',
        'Config::Any'                 => '0.11',
        'File::Spec'                  => '0',
        'File::Temp'                  => '0',
        'Tie::File'                   => '0',
        'Carp'                        => '0',
        'Digest::MD5'                 => '0',
        'Test::More'                  => '0',
    }
);
