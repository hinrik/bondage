package App::Bondage::Common;

use strict;
use warnings;

require Exporter;
our @ISA = qw( Exporter );
our @EXPORT = qw( $APP_NAME $VERSION $HOMEPAGE $CRYPT_SALT );

our $APP_NAME   = 'bondage';
our $VERSION    = '0.2.1';
our $HOMEPAGE   = 'http://bondage.googlecode.com';
our $CRYPT_SALT = 'erxpnUyerCerugbaNgfhW';

1;
