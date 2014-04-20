package Test::Kit2;

use strict;
use warnings;

use Exporter;
use namespace::clean ();
use Import::Into;
use Module::Runtime 'use_module';
use Sub::Delete;

use base 'Exporter';
our @EXPORT = ('include');

=head1 NAME

Test::Kit2 - Build custom test packages with only the features you want

=head1 SYNOPSIS

In a module somewhere in your project...

    package MyProject::Test;

    use Test::Kit2;

    include 'Test::More';
    include 'Test::LongString';

    include 'Test::Warn' => {
        exclude => [ 'warning_is' ],
        renamed => {
            'warning_like' => 'test_warn_warning_like'
        },
    };

    include 'List::Util' => {
        import => [ 'min', 'max', 'shuffle' ],
    };

=cut

# deep strucutre:
#
# my %collission_check_cache = (
#     'MyTest::Awesome' => {
#         'ok' => 'Test::More',
#         'pass' => 'Test::More',
#         'warnings_are' => 'Test::Warn',
#         ...
#     },
#     ...
# )
#
my %collission_check_cache;

sub include {
    my @to_include = @_;

    my $class = __PACKAGE__;

    my $include_hashref;
    if (@to_include == 1) {
        $include_hashref = { $to_include[0] => {} };
    }
    else {
        $include_hashref = { @to_include };
    }

    return $class->_include($include_hashref);
}

sub _include {
    my $class = shift;
    my $include_hashref = shift;

    my $target = $class->_get_class_to_import_into();

    $class->_check_target_does_not_import($target);

    for my $pkg (sort keys %$include_hashref) {
        my $fake_pkg = $class->_create_fake_package($pkg, $include_hashref->{$pkg});
        $fake_pkg->import::into($target);
    }

    $class->_make_target_an_exporter($target);

    return;
}

sub _get_class_to_import_into {
    my $class = shift;

    # so, as far as I can tell, on Perl 5.14 and 5.16 at least, we have the
    # following callstack...
    #
    # 1. Test::Kit2
    # 2. MyTest
    # 3. main
    # 4. main
    # 5. main
    #
    # ... and we want to get the package name "MyTest" out of there.
    # So let's look for the first non-Test::Kit2 result

    for my $i (1 .. 20) {
        my $caller_pkg = (caller($i))[0];
        if ($caller_pkg ne 'Test::Kit2') {
            return $caller_pkg;
        }
    }

    die "Unable to find class to import into";
}

sub _create_fake_package {
    my $class = shift;
    my $pkg = shift;
    my $pkg_include_hashref = shift;

    my $fake_pkg = "Test::Kit::Fake::$pkg";

    my %exclude = map { $_ => 1 } @{ $pkg_include_hashref->{exclude} || [] };
    my %rename = %{ $pkg_include_hashref->{rename} || {} };
    my @import = @{ $pkg_include_hashref->{import} || [] };

    use_module($pkg)->import::into($fake_pkg, @import);
    my $functions_exported_by_pkg = namespace::clean->get_functions($fake_pkg);

    my @functions_to_install = (
        (grep { !$exclude{$_} && !$rename{$_} } sort keys %$functions_exported_by_pkg),
        (values %rename)
    );

    my @non_functions_to_install = $class->_get_non_functions_from_pkg($pkg);

    $class->_check_collissions(
        $pkg,
        [
            @functions_to_install,
            @non_functions_to_install,
        ]
    );

    {
        no strict 'refs';
        no warnings 'redefine';

        push @{ "$fake_pkg\::ISA" }, 'Exporter';
        @{ "$fake_pkg\::EXPORT" } = (
            @functions_to_install,
            @non_functions_to_install
        );

        for my $from (sort keys %rename) {
            my $to = $rename{$from};

            *{ "$fake_pkg\::$to" } = \&{ "$fake_pkg\::$from" };

            delete_sub("$fake_pkg\::$from");
        }
    }

    return $fake_pkg;
}

sub _check_collissions {
    my $class = shift;
    my $pkg = shift;
    my $functions_to_install = shift;

    my $target = $class->_get_class_to_import_into();

    for my $function (@$functions_to_install) {
        if (exists $collission_check_cache{$target}{$function} && $collission_check_cache{$target}{$function} ne $pkg) {
            die sprintf("subroutine %s() already supplied to %s by %s",
                $function,
                $target,
                $collission_check_cache{$target}{$function},
            );
        }
        else {
            $collission_check_cache{$target}{$function} = $pkg;
        }
    }

    return;
}

sub _check_target_does_not_import {
    my $class = shift;
    my $target = shift;

    return if $collission_check_cache{$target}; # already checked

    if ($target->can('import')) {
        die "Package $target already has an import() sub";
    }

    return;
}

sub _make_target_an_exporter {
    my $class = shift;
    my $target = shift;

    my @functions_to_install = sort keys %{ $collission_check_cache{$target} // {} };

    {
        no strict 'refs';
        push @{ "$target\::ISA" }, 'Exporter';
        @{ "$target\::EXPORT" } = @functions_to_install;
    }

    return;
}

sub _get_non_functions_from_pkg {
    my $class = shift;
    my $pkg = shift;

    # Unfortunately we can't do the "correct" thing here, which would be to
    # walk the symbol table of the fake package to find the non-sub variables
    # exported by the included package.
    #
    # This is because the most common case we're trying to handle is the
    # '$TODO' variable from Test::More, but it's impossible to catch that in
    # the fake package symbol table because every symbol table entry has a
    # scalar no matter what. ie the following two classes are indistinguishable:
    #
    # 1.
    #     package foo;
    #     our $x = undef;
    #     our @x = qw(a b c);
    #
    # 2.
    #     package foo;
    #     our @x = qw(a b c);
    #
    # One option would be to import '$VAR' if VAR is in the symbol table and
    # has no CODE, ARRAY, or HASH entry. But that breaks down if a package is
    # trying to export both '$VAR' and '@VAR'.
    #
    # So, instead of all that I'm going to simply assume that the package is an
    # Exporter and walk its @EXPORT array for things which start with '$', '@'
    # or '%'. This at least will work for the $Test::More::TODO case.
    #

    my @non_functions;

    my @package_export;
    {
        no strict 'refs';
        @package_export = @{ "$pkg\::EXPORT" };
    }

    for my $e (@package_export) {
        if ($e =~ m/^[\$\@\%]/) {
            push @non_functions, $e;
        }
    }

    return @non_functions;
}

1;
