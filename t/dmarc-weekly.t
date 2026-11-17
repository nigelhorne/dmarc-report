#!/usr/bin/env perl
#
# The wrapper is what cron actually runs, and what it does with the files is
# its own behaviour rather than the summariser's: which reports it moves, where
# to, and what it does on a week with nothing in it.  That is worth testing
# separately, and one bug already got through without it - a dry run was
# archiving the reports, because the clean-week path returned before DRY_RUN was
# ever looked at.

use strict;
use warnings;

use Test::Most;

use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

my $WRAPPER = File::Spec->catfile(dirname(File::Spec->rel2abs($0)), File::Spec->updir(), 'bin', 'dmarc-weekly.sh');
my $EXPECTED = '192.0.2.10';

BAIL_OUT("Cannot find $WRAPPER") unless(-x $WRAPPER);

sub slurp
{
	my $path = shift;

	local $/;
	open(my $fh, '<', $path) or return '';
	my $text = <$fh>;
	close($fh);

	return $text;
}

sub write_file
{
	my ($path, $content) = @_;

	open(my $fh, '>', $path) or die "Cannot write $path: $!";
	print $fh $content;
	close($fh) or die "Cannot close $path: $!";

	return $path;
}

# A report with one record, in the shape the reporters actually send.
sub report_xml
{
	my (%args) = @_;

	my $domain = $args{'domain'};
	my $ip = $args{'ip'} // $EXPECTED;
	my $count = $args{'count'} // 1;

	return <<XML;
<?xml version="1.0" encoding="UTF-8" ?>
<feedback>
 <report_metadata>
  <org_name>reporter.example</org_name>
  <report_id>$args{'name'}</report_id>
  <date_range><begin>1794355200</begin><end>1794441599</end></date_range>
 </report_metadata>
 <policy_published>
  <domain>$domain</domain><adkim>r</adkim><aspf>r</aspf><p>none</p><sp>none</sp><pct>100</pct>
 </policy_published>
 <record>
  <row>
   <source_ip>$ip</source_ip>
   <count>$count</count>
   <policy_evaluated><disposition>none</disposition><dkim>pass</dkim><spf>pass</spf></policy_evaluated>
  </row>
  <identifiers><header_from>$domain</header_from></identifiers>
  <auth_results>
   <dkim><domain>$domain</domain><selector>selector1</selector><result>pass</result></dkim>
   <spf><domain>$domain</domain><result>pass</result></spf>
  </auth_results>
 </record>
</feedback>
XML
}

# Run the wrapper the way cron does: no arguments at all, its behaviour chosen
# entirely by the environment.  HOME points into the temporary directory so the
# default archive and log paths are the ones under test, and MAIL_COMMAND keeps
# any mail in a file instead of trying to find a transport.
sub run_wrapper
{
	my @rest = @_;
	my $args = (ref($rest[0]) eq 'ARRAY') ? shift(@rest) : [];
	my %env = @rest;

	my $out = File::Spec->catfile($main::TMP, 'stdout.txt');
	my $err = File::Spec->catfile($main::TMP, 'stderr.txt');
	my $mail = File::Spec->catfile($main::TMP, 'mail.txt');
	unlink($mail);

	my %set = (
		HOME => $main::HOME,
		PERL => $^X,
		DMARC_EXPECTED => $EXPECTED,
		DMARC_LOG => File::Spec->catfile($main::HOME, 'dmarc-report.log'),
		MAIL_COMMAND => "cat > $mail",
		%env,
	);

	my $pid = fork();
	die "fork: $!" unless(defined($pid));

	if(!$pid) {
		foreach my $name (keys %set) {
			$ENV{$name} = $set{$name};
		}
		# Not inherited from whatever ran prove, so a variable that would
		# change the outcome cannot leak in from the developer's shell.
		foreach my $name (qw(DMARC_ARCHIVE_DIR DMARC_ARCHIVE DRY_RUN)) {
			delete($ENV{$name}) unless(exists($set{$name}));
		}
		open(STDOUT, '>', $out) or exit 127;
		open(STDERR, '>', $err) or exit 127;
		exec($WRAPPER, @$args) or exit 127;
	}

	waitpid($pid, 0);

	return ($? >> 8, slurp($out), slurp($err), (-e $mail ? slurp($mail) : ''));
}

sub reports_dir
{
	my ($name) = @_;

	my $dir = File::Spec->catdir($main::TMP, $name);
	mkdir($dir) or die "Cannot mkdir $dir: $!";

	return $dir;
}

# A HOME of its own for each subtest: the wrapper's archive and log defaults are
# derived from it, and sharing one would let an earlier subtest's leftovers
# decide a later subtest's result.
sub fresh_home
{
	my ($name) = @_;

	my $home = File::Spec->catdir($main::TMP, "home-$name");
	mkdir($home) or die "Cannot mkdir $home: $!";

	return $home;
}

$main::TMP = tempdir(CLEANUP => 1);
$main::HOME = fresh_home('default');

subtest 'a dry run moves nothing' => sub {
	my $home = fresh_home('dry');
	my $ARCHIVE = File::Spec->catdir($home, 'dmarc-archive');

	# A week with a finding, so the run has something it would archive and
	# something it would say.
	my $dir = reports_dir('dry-dirty');
	write_file(File::Spec->catfile($dir, 'ok.xml'), report_xml(name => 'ok.xml', domain => 'example.org'));
	write_file(File::Spec->catfile($dir, 'bad.xml'),
		report_xml(name => 'bad.xml', domain => 'example.org', ip => '203.0.113.7', count => 3));

	my ($status, $out, $err) = run_wrapper(HOME => $home, DMARC_DIR => $dir, DRY_RUN => 1);
	is($status, 1, 'the finding still sets the exit status');
	like($out, qr/would archive 2 report\(s\) to \Q$ARCHIVE\E/, 'it says what it would have archived, and where');
	is(join(',', sort { $a cmp $b } do { opendir(my $dh, $dir); grep { $_ ne '.' && $_ ne '..' } readdir($dh) }),
		'bad.xml,ok.xml', 'both reports are still in place');
	ok(!-d $ARCHIVE, 'no archive directory was created');

	# The regression that prompted these tests: on a week with nothing to
	# report, the wrapper returned before consulting DRY_RUN and archived the
	# lot anyway.
	my $clean = reports_dir('dry-clean');
	write_file(File::Spec->catfile($clean, 'ok.xml'), report_xml(name => 'ok.xml', domain => 'example.org'));

	($status, $out, $err) = run_wrapper(HOME => $home, DMARC_DIR => $clean, DRY_RUN => 1);
	is($status, 0, 'a clean week in rehearsal exits 0');
	is($out . $err, '', 'and says nothing');
	ok(-f File::Spec->catfile($clean, 'ok.xml'), 'the report is still there: a rehearsal has no side effects');
	ok(!-d $ARCHIVE, 'and still no archive directory');
};

subtest 'an empty directory is a quiet week' => sub {
	my $home = fresh_home('empty');
	my $ARCHIVE = File::Spec->catdir($home, 'dmarc-archive');
	my $dir = reports_dir('empty');
	my $log = File::Spec->catfile($main::TMP, 'empty.log');

	my ($status, $out, $err, $mail) = run_wrapper(HOME => $home, DMARC_DIR => $dir, DMARC_LOG => $log);
	is($status, 0, 'exits 0: nothing to report is not a failure');
	is($out . $err, '', 'says nothing on either stream');
	is($mail, '', 'sends no mail');
	ok(!-e $log, 'writes nothing to the log');
	ok(!-d $ARCHIVE, 'and creates no archive directory');

	# Silence has to mean "nothing new", not "the job broke": a directory that
	# does not exist is still a failure worth hearing about.  The wrapper takes
	# the summariser's own stderr into its message rather than passing it
	# through, so it shows up in the mail instead of on the cron stream.
	my $missing = File::Spec->catdir($main::TMP, 'no-such-directory');
	($status, $out, $err, $mail) = run_wrapper(HOME => $home, DMARC_DIR => $missing);
	cmp_ok($status, '>', 0, 'a missing directory is a failure');
	like($mail, qr/Not a directory/, 'and the failure is reported, not mistaken for a quiet week');
};

subtest 'a repeat download keeps both copies' => sub {
	my $home = fresh_home('repeat');
	my $ARCHIVE = File::Spec->catdir($home, 'dmarc-archive');
	my $dir = reports_dir('repeat');
	my $report = File::Spec->catfile($dir, 'a.xml');
	write_file($report, report_xml(name => 'a.xml', domain => 'example.org', count => 4));

	my ($status) = run_wrapper(HOME => $home, DMARC_DIR => $dir);
	is($status, 0, 'first week is clean');
	ok(-f File::Spec->catfile($ARCHIVE, 'a.xml'), 'the report was archived');

	# The same report fetched again, which happens when a reporter resends or a
	# download is repeated.  It must not overwrite the copy already there.
	write_file($report, report_xml(name => 'a.xml', domain => 'example.org', count => 9));
	($status) = run_wrapper(HOME => $home, DMARC_DIR => $dir);
	is($status, 0, 'second week is clean too');

	opendir(my $dh, $ARCHIVE) or die "Cannot open $ARCHIVE: $!";
	my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
	closedir($dh);

	is(scalar(@names), 2, 'both copies are kept');
	is($names[0], 'a.xml', 'the first copy keeps the plain name');
	like($names[1], qr/\Aa\.xml\.\d{14}\z/, 'the second gets a timestamp suffix');
	like(slurp(File::Spec->catfile($ARCHIVE, 'a.xml')), qr/<count>4<\/count>/,
		'the first copy is untouched, not overwritten by the repeat');
	like(slurp(File::Spec->catfile($ARCHIVE, $names[1])), qr/<count>9<\/count>/,
		'and the repeat is the one that was kept alongside it');
};

subtest 'a finding is mailed, and names the archive' => sub {
	my $home = fresh_home('finding');
	my $ARCHIVE = File::Spec->catdir($home, 'dmarc-archive');
	my $dir = reports_dir('finding');
	write_file(File::Spec->catfile($dir, 'bad.xml'),
		report_xml(name => 'bad.xml', domain => 'example.org', ip => '203.0.113.7', count => 3));

	my ($status, $out, $err, $mail) = run_wrapper(HOME => $home, DMARC_DIR => $dir);
	is($status, 1, 'exits 1');
	is($err, '', 'nothing on stderr, because a transport was available');
	like($mail, qr/^Subject: .*needs looking at/m, 'the mail has a subject');
	like($mail, qr/203\.0\.113\.7/, 'it carries the finding');
	like($mail, qr/1 report\(s\) moved to \Q$ARCHIVE\E/, 'and says where the reports went');
	ok(-f File::Spec->catfile($ARCHIVE, 'bad.xml'), 'the report was archived');
	like(slurp(File::Spec->catfile($main::HOME, 'dmarc-report.log')), qr/exit 1/,
		'the log records the run even though the mail went out');
};

subtest 'a crontab line can be printed, and nothing is run' => sub {
	my $home = fresh_home('crontab');
	my ($status, $out, $err, $mail) = run_wrapper(['--crontab'],
		HOME => $home, DMARC_EXPECTED => '192.0.2.10', MAIL_TO => 'alerts@example.org');

	is($status, 0, 'it exited 0');
	is($err, '', 'nothing on stderr');
	is($mail, '', 'nothing was mailed');

	like($out, qr/^# /m, 'it explains itself');
	like($out, qr/^\S+ \S+ \S+ \S+ \S+ DMARC_EXPECTED=/m, 'the line starts with the five cron fields');
	like($out, qr/\Q$WRAPPER\E/, 'and names the wrapper by its full path');
	like($out, qr/\bDMARC_EXPECTED=192\.0\.2\.10\b/, 'with the expected sender');
	like($out, qr/\bMAIL_TO=alerts\@example\.org\b/, 'the address a finding is mailed to');
	like($out, qr/\bPERL=\//, 'and an absolute perl, because cron has no useful PATH');

	# Printing must not be a rehearsal run of the check itself.
	ok(!-e File::Spec->catfile($home, 'dmarc-archive'), 'no archive directory was made');
	ok(!-e File::Spec->catfile($home, 'dmarc-report.log'), 'and nothing was logged');
};

done_testing();
