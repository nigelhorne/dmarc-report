#!/usr/bin/env perl
#
# dmarc-report - summarise DMARC aggregate reports, and flag every source
# address that is not the host we expect to be sending as our domains.
#
# Aggregate reports arrive as XML, sometimes gzipped, and often several at a
# time, so this reads a whole directory rather than one file: every report
# that parses is summarised, then the totals per source address are given, and
# anything that did not come from the expected host is marked.  The exit
# status is the part a cron job can act on - 0 when every message came from
# the expected host and authenticated, 1 when something else did - so it can
# run unattended over a reports directory.
#
# Namespace: some reporters put the report in a namespace and some do not, so
# every lookup is by local-name() rather than by the plain element name.

use strict;
use warnings;

use File::Basename qw(basename);
use File::Spec;
use Getopt::Long qw(GetOptions);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use IO::Uncompress::Unzip qw($UnzipError);
use POSIX qw(strftime);
use Readonly;
use Pod::Usage qw(pod2usage);
use XML::LibXML;

# The VPS that sends the sites' mail.  Everything else is a finding.
my $DEFAULT_EXPECTED = '67.205.23.146';

my $home = $ENV{'HOME'} || (getpwuid($<))[7] || '.';
my $DEFAULT_DIR = $ENV{'DMARC_DIR'} || "$home/Downloads";

my (@dirs, @expected, $help);
GetOptions(
	'dir|d=s' => \@dirs,
	'expected|e=s' => \@expected,
	'help|h' => \$help,
) or pod2usage(-exitval => 2, -verbose => 0);
pod2usage(-exitval => 0, -verbose => 1) if($help);

@dirs = ($DEFAULT_DIR) unless(@dirs);
@expected = ($DEFAULT_EXPECTED) unless(@expected);
my %expected = map { $_ => 1 } @expected;

my @files;
foreach my $dir (@dirs) {
	die "Not a directory: $dir\n" unless(-d $dir);
	# Only the shapes a report arrives in.  A bare *.gz would also match
	# anything else parked in the same directory - a tarball, a downloaded
	# data set - and trying to parse those is both slow and misleading.
	foreach my $pattern ('*.xml', '*.xml.gz', '*.zip') {
		push @files, glob(File::Spec->catfile($dir, $pattern));
	}
}
my %seen;
@files = sort grep { !$seen{$_}++ } @files;
die "No reports found in: @dirs\n" unless(@files);

# Read one report, gunzipping it if it is compressed.  Reports are small, so
# they are parsed in memory and there is no need to unpack them onto disc.
# Reports are kilobytes.  Capping what is opened at all keeps a downloads
# directory usable: it holds installers, archives and data sets, and one of
# them is 13 GB, so matching on the extension alone is not enough.
Readonly::Scalar my $MAX_FILE_BYTES => 10 * 1024 * 1024;
Readonly::Scalar my $MAX_XML_BYTES => 20 * 1024 * 1024;

sub read_report
{
	my $path = shift;

	my $size = -s $path;
	die "too large to be a report ($size bytes)\n" if(defined($size) && $size > $MAX_FILE_BYTES);

	my $xml;
	if($path =~ /\.zip\z/) {
		$xml = read_zipped_xml($path);
	} elsif($path =~ /\.gz\z/) {
		$xml = read_gzipped_xml($path);
	} else {
		open(my $fh, '<', $path) or die "Cannot read $path: $!\n";
		local $/;
		$xml = <$fh>;
		close($fh);
	}

	# A DMARC report is a <feedback> document.  Saying so is clearer than
	# letting the XML parser complain about a CSV or a tarball.
	die "not a DMARC report\n" unless(index($xml, '<feedback') >= 0);

	return XML::LibXML->load_xml(string => $xml, no_network => 1);
}

sub read_gzipped_xml
{
	my $path = shift;

	my $gz = IO::Uncompress::Gunzip->new($path) or die "Cannot gunzip $path: $GunzipError\n";

	return _read_bounded($gz, $path);
}

# Reporters that send a .zip put the report inside, sometimes beside a
# signature file, so the first member ending in .xml is the one to read.
sub read_zipped_xml
{
	my $path = shift;

	my $zip = IO::Uncompress::Unzip->new($path) or die "Cannot open $path: $UnzipError\n";

	my $status = 1;
	while($status > 0) {
		my $name = $zip->getHeaderInfo()->{'Name'} || '';
		return _read_bounded($zip, $path) if($name =~ /\.xml\z/i);
		$status = $zip->nextStream();
	}

	die "No XML inside $path\n";
}

# Read to the end of the current stream, giving up rather than filling memory
# with something that turned out not to be a report.
sub _read_bounded
{
	my ($handle, $path) = @_;

	my $xml = '';
	while(1) {
		my $read = $handle->read(my $chunk, 65536);
		die "Cannot read $path: ", $handle->error(), "\n" if(!defined($read));
		last if($read == 0);
		$xml .= $chunk;
		die "expands beyond $MAX_XML_BYTES bytes; not a report\n" if(length($xml) > $MAX_XML_BYTES);
	}

	return $xml;
}

# The first non-empty text under a named child.  Used for the single-valued
# fields, where a reporter that repeats an element would otherwise make the
# concatenated text look like a value.
sub text_in
{
	my ($node, $name) = @_;

	return '' unless($node);

	foreach my $found ($node->findnodes(".//*[local-name()='$name']")) {
		my $text = $found->textContent;
		$text =~ s/\A\s+//;
		$text =~ s/\s+\z//;
		return $text if(length($text));
	}

	return '';
}

sub when
{
	my $epoch = shift;

	return '?' unless(defined($epoch) && $epoch =~ /\A\d+\z/);

	return strftime('%Y-%m-%d %H:%M UTC', gmtime($epoch));
}

# Totals per reported domain and source address, across every report.  One
# address spread over several reports is one problem, not several - but the
# reports for every domain arrive at the same mailbox, so their figures must
# not be added together: an address that legitimately sends for one domain is
# not thereby legitimate for another.
my %by_domain;
my ($total_messages, $total_records, $reports_read) = (0, 0, 0);
my $unexpected_messages = 0;

foreach my $path (@files) {
	my $doc = eval { read_report($path) };
	if(!$doc) {
		my ($why) = split(/\n/, "$@");
		# "not a report" is the normal case in a downloads directory, so it is
		# passed over; anything else means a report we could not read.
		warn 'Skipping ', basename($path), ": $why\n" unless($why =~ /not a (DMARC )?report|too large|expands beyond/);
		next;
	}
	$reports_read++;

	my ($meta) = $doc->findnodes("//*[local-name()='report_metadata']");
	my ($policy) = $doc->findnodes("//*[local-name()='policy_published']");

	my $begin = text_in($meta && $meta->findnodes(".//*[local-name()='date_range']") ? ($meta->findnodes(".//*[local-name()='date_range']"))[0] : undef, 'begin');
	my $end = text_in($meta && $meta->findnodes(".//*[local-name()='date_range']") ? ($meta->findnodes(".//*[local-name()='date_range']"))[0] : undef, 'end');

	print '=' x 78, "\n";
	print basename($path), "\n";
	printf "  reporter : %s   report_id: %s\n", text_in($meta, 'org_name'), text_in($meta, 'report_id');
	printf "  period   : %s -> %s\n", when($begin), when($end);
	printf "  domain   : %s   p=%s sp=%s adkim=%s aspf=%s pct=%s\n",
		text_in($policy, 'domain'), text_in($policy, 'p'), text_in($policy, 'sp'),
		text_in($policy, 'adkim'), text_in($policy, 'aspf'), text_in($policy, 'pct');

	my $reported_domain = text_in($policy, 'domain');

	my @records = $doc->findnodes("//*[local-name()='record']");
	if(!@records) {
		print "  (no records in this report)\n";
		next;
	}

	foreach my $record (@records) {
		my ($row) = $record->findnodes(".//*[local-name()='row']");
		my ($evaluated) = $record->findnodes(".//*[local-name()='policy_evaluated']");

		my $ip = text_in($row, 'source_ip');
		my $count = text_in($row, 'count') || 0;
		my $disposition = text_in($evaluated, 'disposition');
		my $dkim_verdict = text_in($evaluated, 'dkim');
		my $spf_verdict = text_in($evaluated, 'spf');
		my $header_from = text_in($record, 'header_from');

		# The addresses actually seen, which is what says whether a message
		# carried a signature at all rather than merely failing its check.
		my (@dkim_auth, @spf_auth);
		foreach my $results ($record->findnodes(".//*[local-name()='auth_results']")) {
			foreach my $dkim ($results->findnodes("*[local-name()='dkim']")) {
				push @dkim_auth, sprintf('%s/%s=%s',
					text_in($dkim, 'domain'), (text_in($dkim, 'selector') || '-'), text_in($dkim, 'result'));
			}
			foreach my $spf ($results->findnodes("*[local-name()='spf']")) {
				push @spf_auth, sprintf('%s=%s', text_in($spf, 'domain'), text_in($spf, 'result'));
			}
		}

		# A reporter that leaves policy_published out is grouped by the From
		# domain of the record instead, so nothing falls into a shared bucket.
		my $domain = $reported_domain || $header_from || '(unknown)';

		my $passed = ($dkim_verdict eq 'pass') || ($spf_verdict eq 'pass');
		my $flag = '';
		if(!$expected{$ip}) {
			$flag = '  <== NOT ' . join('/', @expected);
			$unexpected_messages += $count;
		} elsif(!$passed) {
			$flag = '  <== expected host, not authenticating';
		}

		printf "  %-16s %5d  dkim=%-5s spf=%-8s %-9s from=%s%s\n",
			$ip, $count, $dkim_verdict, $spf_verdict, $disposition, $header_from, $flag;
		printf "      dkim seen: %s\n", (@dkim_auth ? join(', ', @dkim_auth) : 'none');
		printf "      spf  seen: %s\n", (@spf_auth ? join(', ', @spf_auth) : 'none');

		$total_records++;
		$total_messages += $count;

		my $entry = $by_domain{$domain}{$ip} ||= {
			'count' => 0, 'pass' => 0, 'fail' => 0,
			'unexpected' => (!$expected{$ip} ? 1 : 0),
			'dkim_seen' => {},
		};
		$entry->{'count'} += $count;
		$entry->{'pass'} += $count if($passed);
		$entry->{'fail'} += $count if(!$passed);
		$entry->{'dkim_seen'}{$_} = 1 foreach(@dkim_auth);
	}
}

print '=' x 78, "\n";
printf "Totals over %d report(s): %d record(s), %d message(s)\n",
	$reports_read, $total_records, $total_messages;
foreach my $domain (sort keys %by_domain) {
	my $by_ip = $by_domain{$domain};

	my ($messages, $unexpected) = (0, 0);
	foreach my $ip (keys %{$by_ip}) {
		$messages += $by_ip->{$ip}{'count'};
		$unexpected += $by_ip->{$ip}{'count'} if($by_ip->{$ip}{'unexpected'});
	}

	printf "\n%s: %d message(s)", $domain, $messages;
	printf ", %d not from %s", $unexpected, join('/', @expected) if($unexpected);
	print "\n";

	printf "  %-16s %8s %8s %8s  %s\n", 'source_ip', 'messages', 'passed', 'failed', 'status';
	foreach my $ip (sort { $by_ip->{$b}{'count'} <=> $by_ip->{$a}{'count'} || $a cmp $b } keys %{$by_ip}) {
		my $entry = $by_ip->{$ip};
		my $status = $entry->{'unexpected'} ? 'UNEXPECTED SOURCE' : ($entry->{'fail'} ? 'expected, failing auth' : 'expected, authenticating');
		printf "  %-16s %8d %8d %8d  %s\n", $ip, $entry->{'count'}, $entry->{'pass'}, $entry->{'fail'}, $status;
		my @dkim = sort keys %{$entry->{'dkim_seen'}};
		printf "  %-16s   dkim: %s\n", '', (@dkim ? join(', ', @dkim) : 'no signature seen');
	}
}

print "\n";
if($unexpected_messages) {
	printf "%d message(s) came from addresses that are not %s.\n", $unexpected_messages, join('/', @expected);
	exit(1);
}
print "Every message came from ", join('/', @expected), ".\n";
exit(0);

__END__

=head1 NAME

dmarc-report - summarise DMARC aggregate reports and flag unexpected senders

=head1 SYNOPSIS

	dmarc-report [--dir DIR]... [--expected IP]...

	# only the reports of one domain, watching a different host
	dmarc-report -d ~/Downloads -e 203.0.113.10

	# in a cron job: nonzero when anything came from elsewhere
	dmarc-report -d /var/reports/dmarc || echo 'unexpected sender'

=head1 DESCRIPTION

Reads every C<*.xml>, C<*.xml.gz> and C<*.zip> file in each directory (the
default is C<$HOME/Downloads>, or C<$DMARC_DIR> when that is set), prints the
reporter, period, published policy and one line per source address, then the
totals per source address for each domain, over all the reports together.

The totals are kept per domain because the reports for several domains arrive
at the same mailbox: an address that legitimately sends for one domain is not
thereby legitimate for another, so adding the figures together would hide both
a real sender and a real problem.

Pointing it at a downloads directory is safe: a file too large to be a report
is never opened, and a file that does not contain a C<< <feedback> >> document
is passed over, so installers, archives and data sets in the same directory
cost nothing.

Any source address that is not one of the expected hosts is marked, and so is
an expected host whose mail did not authenticate, since that is the case worth
looking at: it means the host is sending but the signature or the SPF record
is wrong.

=head1 OPTIONS

=over 4

=item B<--dir>, B<-d> DIR

A directory of reports.  May be given more than once.

=item B<--expected>, B<-e> IP

A host that is allowed to send as these domains.  May be given more than
once.  Defaults to C<67.205.23.146>, the VPS that sends the sites' mail.

=item B<--help>, B<-h>

Print this documentation.

=back

=head1 EXIT STATUS

0 when every message came from an expected host and authenticated, 1 when
something else did, 2 on a usage error.

=cut
