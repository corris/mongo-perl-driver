use strict;
use warnings;
use lib 'ext';
use inc::Module::Install;

name 'MongoDB';
perl_version '5.8.7';
author 'Florian Ragwitz <rafl@debian.org>';
author 'Kristina Chodorow <kristina@10gen.com>';
license 'Apache';
all_from 'lib/MongoDB.pm';

requires 'Any::Moose';
# C::M::Modifiers isn't always needed. It'll be used only if Any::Moose decides
# to use Mouse instead of Moose. We depend on it anyway to make sure it's there
# when it's needed.
requires 'Class::Method::Modifiers';
requires 'Digest::MD5';
requires 'Tie::IxHash';
requires 'DateTime';
requires 'XSLoader';
requires 'boolean';
test_requires 'Test::Exception';
test_requires 'Tie::IxHash';
test_requires 'DateTime';
test_requires 'boolean';
test_requires 'Data::Types';
test_requires 'File::Slurp';
test_requires 'FileHandle';
test_requires 'JSON';
test_requires 'File::Temp' => '0.17';
test_requires 'Try::Tiny';

mongo;

no_index directory => 'ext';

repository 'git://github.com/mongodb/mongo-perl-driver.git';

my @arch = $Config::Config{ccflags} =~ m/-arch\s+(\S+)/g;
my $archStr = join '', map { " -arch $_ " } @arch;

my $ccflags = makemaker_args->{CCFLAGS};
$ccflags = $ccflags . $archStr;
makemaker_args(CCFLAGS => $ccflags);

makemaker_args(
    dynamic_lib => {
        OTHERLDFLAGS => $archStr
    }
);


if ($Config::Config{useithreads}) {
    tests 't/*.t t/threads/*.t';
}

WriteAll;

package MY;
our $VERSION = '0.43';

use Config;

sub const_cccmd {
    my $inherited = shift->SUPER::const_cccmd(@_);
    return '' unless $inherited;

    if ($Config{cc} =~ /^cl\b/) {
        warn 'you are using MSVC... my condolences.';
        $inherited .= ' /Fo$@';
    }
    else {
        $inherited .= ' -o $@';
    }

    if ($Config{use64bitint}) {
        $inherited .= ' -DUSE_64_BIT_INT';
    }
    else {
        $inherited .= ' ';
    }

    return $inherited;
}
