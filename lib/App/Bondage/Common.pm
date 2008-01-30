package App::Bondage::Common;

use strict;
use warnings;

require Exporter;
our @ISA = qw( Exporter );
our @EXPORT = qw( $VERSION $HOMEPAGE $CRYPT_SALT );

our $VERSION    = '0.2.2';
our $HOMEPAGE   = 'http://search.cpan.org/dist/App-Bondage';
our $CRYPT_SALT = 'erxpnUyerCerugbaNgfhW';

1;
