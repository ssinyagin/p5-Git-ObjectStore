#!perl

use strict;
use warnings;

use Test::More;

use Git::ObjectStore;
use File::Temp;
use Data::Dumper;

# keep the temporary dirs
$File::Temp::KEEP_ALL = 1;

my $repodir = File::Temp->newdir();
my $repodirname = $repodir->dirname();
ok(defined($repodirname), 'created temporary dir: ' . $repodirname);

my $writer = new Git::ObjectStore('repodir' => $repodirname,
                                  'branchname' => 'test1',
                                  'writer' => 1);

ok( ref($writer), 'created a writer Git::ObjectStore');

my $changed = $writer->write_and_check('docs/001c', 'data1');
ok($changed, 'write_file returns true');

$changed = $writer->create_commit_and_packfile();
ok($changed, 'create_commit_and_packfile returns true');

my $wrkdir = File::Temp->newdir();
my $wrkdirname = $wrkdir->dirname();
ok(defined($wrkdirname), 'created temporary dir: ' . $wrkdirname);

ok(0 == system('git clone -b test1 ' . $repodirname . ' ' . $wrkdirname),
   'clone');

ok(chdir($wrkdirname), 'chdir');

ok(0 == system('git rm docs/001c'), 'git rm');
ok(0 == system('git commit -m xx'), 'git commit');
ok(0 == system('git push'), 'git push');

$writer = undef;

my $reader = new Git::ObjectStore('repodir' => $repodirname,
                                  'branchname' => 'test1');

ok( ref($reader), 'created a reader Git::ObjectStore');

ok(chdir('/'), 'chdir');


   


done_testing;


# Local Variables:
# mode: cperl
# indent-tabs-mode: nil
# cperl-indent-level: 4
# cperl-continued-statement-offset: 4
# cperl-continued-brace-offset: -4
# cperl-brace-offset: 0
# cperl-label-offset: -2
# End:
