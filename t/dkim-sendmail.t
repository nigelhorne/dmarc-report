#!/usr/bin/env perl
#
# The wrapper signs a message and hands it to sendmail, so what is tested here
# is both halves: the message sendmail is given (and whether its signature
# verifies) and the arguments and exit status it is called with.
#
# The key pair is made at run time, so no key material lives in the repository,
# and the public half is served to the verifier through a stubbed DNS lookup
# rather than being published anywhere.

use strict;
use warnings;

use Test::Most;

use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

my $SCRIPT = File::Spec->catfile(dirname(File::Spec->rel2abs($0)), File::Spec->updir(), 'bin', 'dkim-sendmail');

BAIL_OUT("Cannot find $SCRIPT") unless(-r $SCRIPT);

plan skip_all => 'Mail::DKIM is needed to sign and verify'
	unless(eval { require Mail::DKIM::Signer; require Mail::DKIM::Verifier; require Mail::DKIM::DNS; require Net::DNS::RR; 1 });

my $openssl;
foreach my $dir (File::Spec->path()) {
	my $candidate = File::Spec->catfile($dir, 'openssl');
	if(-x $candidate) {
		$openssl = $candidate;
		last;
	}
}
plan skip_all => 'openssl is needed to make a key pair' unless($openssl);

my $TMP = tempdir(CLEANUP => 1);
my $KEYS = File::Spec->catdir($TMP, 'keys');
my $MANY = File::Spec->catdir($TMP, 'many-keys');
my $EMPTY = File::Spec->catdir($TMP, 'no-keys');
my $CAPTURE = File::Spec->catdir($TMP, 'capture');
foreach my $dir ($KEYS, $MANY, $EMPTY, $CAPTURE) {
	mkdir($dir) or BAIL_OUT("Cannot make $dir: $!");
}

# openssl announces "writing RSA key" on stderr, which has no place in the
# test output.  The redirection is done in the child, after the fork, so there
# is no filehandle to put back afterwards.
sub quietly
{
	my @command = @_;

	my $pid = fork();
	die "fork: $!" unless(defined($pid));

	if(!$pid) {
		open(STDOUT, '>', File::Spec->devnull) or exit 127;
		open(STDERR, '>', File::Spec->devnull) or exit 127;
		exec(@command) or exit 127;
	}

	waitpid($pid, 0);

	return $? >> 8;
}

sub quietly_output
{
	my @command = @_;

	my $pid = open(my $pipe, '-|');
	die "fork: $!" unless(defined($pid));

	if(!$pid) {
		open(STDERR, '>', File::Spec->devnull) or exit 127;
		exec(@command) or exit 127;
	}

	my $text = do { local $/; <$pipe> };
	close($pipe);

	return $text;
}

my $KEY = File::Spec->catfile($KEYS, 'selector1.private');
BAIL_OUT("openssl could not make a key") unless(quietly($openssl, 'genrsa', '-out', $KEY, 2048) == 0);
BAIL_OUT("openssl could not make a second key") if(
	quietly($openssl, 'genrsa', '-out', File::Spec->catfile($MANY, 'selector1.private'), 2048) != 0);
BAIL_OUT("openssl could not make a third key") if(
	quietly($openssl, 'genrsa', '-out', File::Spec->catfile($MANY, 'selector2.private'), 2048) != 0);

# The public half, as the TXT record at <selector>._domainkey.<domain> would
# carry it: base64 of the SubjectPublicKeyInfo, with the PEM markers gone.
sub public_key
{
	my $pem = quietly_output($openssl, 'rsa', '-in', $KEY, '-pubout');
	BAIL_OUT("openssl could not read $KEY") unless($pem =~ /KEY-----/);

	$pem =~ s/-----[^-]+-----//g;
	$pem =~ s/\s+//g;

	my $record = 'v=DKIM1; k=rsa; p=' . $pem;

	my @chunks;
	for(my $offset = 0; $offset < length($record); $offset += 255) {
		push @chunks, substr($record, $offset, 255);
	}

	return @chunks;
}

sub verify_signature
{
	my $message = shift;

	my @chunks = public_key();

	no warnings qw(once redefine);
	local *Mail::DKIM::DNS::query = sub {
		return Net::DNS::RR->new(type => 'TXT', txtdata => \@chunks);
	};

	my $verifier = Mail::DKIM::Verifier->new();
	$verifier->PRINT($message);
	$verifier->CLOSE;

	return $verifier->result;
}

# A sendmail that records what it was given instead of sending, so both the
# message and the command line can be checked.
my $FAKE = File::Spec->catfile($TMP, 'fake-sendmail.sh');

sub slurp
{
	my $path = shift;

	local $/;
	open(my $fh, '<', $path) or return '';
	my $text = <$fh>;
	close($fh);

	return $text;
}

open(my $fake, '>', $FAKE) or BAIL_OUT("Cannot write $FAKE: $!");
print $fake <<'SENDMAIL';
#!/bin/sh
cat > "$DKIM_TEST_CAPTURE/message"
: > "$DKIM_TEST_CAPTURE/args"
for arg in "$@"; do
	printf '%s\n' "$arg" >> "$DKIM_TEST_CAPTURE/args"
done
exit "${DKIM_TEST_EXIT:-0}"
SENDMAIL
close($fake);
chmod(0755, $FAKE) or BAIL_OUT("Cannot make $FAKE executable: $!");

my $INPUT_ID = 0;

# Run the wrapper as a program, with a message on stdin and the environment
# cron would give it.  Values of undef mean "leave this one unset", and an
# array reference before the environment is the arguments to pass on.
sub run_wrapper
{
	my ($message, @rest) = @_;
	my $args = (ref($rest[0]) eq 'ARRAY') ? shift(@rest) : [];
	my %env = @rest;

	my $input = File::Spec->catfile($TMP, 'stdin-' . ++$INPUT_ID);
	open(my $in, '>', $input) or die "Cannot write $input: $!";
	print $in $message;
	close($in);

	my $out = File::Spec->catfile($TMP, 'stdout.txt');
	my $err = File::Spec->catfile($TMP, 'stderr.txt');
	unlink(File::Spec->catfile($CAPTURE, 'message'), File::Spec->catfile($CAPTURE, 'args'));

	my %set = (
		HOME => $TMP,
		DKIM_KEYDIR => $KEYS,
		DKIM_SELECTOR => undef,
		DKIM_DOMAINS => undef,
		SENDMAIL => $FAKE,
		DKIM_TEST_CAPTURE => $CAPTURE,
		DKIM_TEST_EXIT => undef,
		%env,
	);

	my $pid = fork();
	die "fork: $!" unless(defined($pid));

	if(!$pid) {
		foreach my $name (keys %set) {
			if(defined($set{$name})) {
				$ENV{$name} = $set{$name};
			} else {
				delete($ENV{$name});
			}
		}
		open(STDIN, '<', $input) or exit 127;
		open(STDOUT, '>', $out) or exit 127;
		open(STDERR, '>', $err) or exit 127;
		exec($^X, $SCRIPT, @$args) or exit 127;
	}

	waitpid($pid, 0);

	return (
		$? >> 8,
		slurp(File::Spec->catfile($CAPTURE, 'message')),
		slurp(File::Spec->catfile($CAPTURE, 'args')),
		slurp($err),
	);
}

sub message
{
	my (%args) = @_;

	my $from = $args{'from'};
	my $headers = defined($from) ? "From: $from\n" : '';

	return $headers . <<'MESSAGE';
To: webmaster@example.org
Subject: Registration
Date: Mon, 17 Nov 2026 12:00:00 +0000
Message-ID: <message-1@example.org>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Body line one.
Body line two.
MESSAGE
}

subtest 'a message from a domain we sign for is signed and the signature verifies' => sub {
	my $input = message(from => 'alerts@example.org');
	my ($status, $sent, undef, $err) = run_wrapper($input, DKIM_DOMAINS => 'example.org');

	is($status, 0, 'the wrapper exited 0');
	is($err, '', 'nothing on stderr') or diag($err);

	like($sent, qr/\ADKIM-Signature: /, 'the signature is the first header');
	like($sent, qr/d=example\.org/, 'it is for the domain in From:');
	like($sent, qr/s=selector1/, 'it names the selector from the key file');
	like($sent, qr/a=rsa-sha256/, 'it is rsa-sha256');
	like($sent, qr/c=relaxed/, 'canonicalization is relaxed');
	is(verify_signature($sent), 'pass', 'the signature verifies against the published key');

	like($sent, qr/^Subject: Registration\r?$/m, 'the headers are still there');
	like($sent, qr/^Body line two\.\r?$/m, 'so is the body');
};

subtest 'a display name, and a domain in another case, are both understood' => sub {
	my $input = message(from => '"Site Alerts" <Alerts@Example.ORG>');
	my ($status, $sent) = run_wrapper($input, DKIM_DOMAINS => 'example.org');

	is($status, 0, 'the wrapper exited 0');
	like($sent, qr/\ADKIM-Signature: /, 'it was signed');
	like($sent, qr/d=example\.org/, 'the domain is the one in the address, not the display name');
	is(verify_signature($sent), 'pass', 'and it verifies');
};

subtest 'every domain in the list is signed, not only the first' => sub {
	my $input = message(from => 'alerts@example.net');
	my ($status, $sent) = run_wrapper($input, DKIM_DOMAINS => 'example.org, example.net');

	is($status, 0, 'the wrapper exited 0');
	like($sent, qr/d=example\.net/, 'the second domain is signed for itself');
	is(verify_signature($sent), 'pass', 'and it verifies');
};

subtest 'a message from a domain that is not ours is passed through untouched' => sub {
	my $input = message(from => 'someone@example.com');
	my ($status, $sent, undef, $err) = run_wrapper($input, DKIM_DOMAINS => 'example.org');

	is($status, 0, 'the wrapper exited 0');
	is($sent, $input, 'the message reached sendmail byte for byte');
	is($err, '', 'and it was not worth a warning');
};

subtest 'a message with no From: header is passed through untouched' => sub {
	my $input = message();
	my ($status, $sent) = run_wrapper($input, DKIM_DOMAINS => 'example.org');

	is($status, 0, 'the wrapper exited 0');
	is($sent, $input, 'nothing to sign, so nothing changed');
};

subtest 'with no domains configured nothing is signed' => sub {
	my $input = message(from => 'alerts@example.org');
	my ($status, $sent) = run_wrapper($input);

	is($status, 0, 'the wrapper exited 0');
	is($sent, $input, 'the message is untouched');
};

subtest 'a missing key is a warning and an unsigned delivery, not a lost message' => sub {
	my $input = message(from => 'alerts@example.org');
	my ($status, $sent, undef, $err) = run_wrapper($input,
		DKIM_DOMAINS => 'example.org', DKIM_KEYDIR => $EMPTY);

	is($status, 0, 'the wrapper still exited 0');
	is($sent, $input, 'the message was delivered anyway');
	like($err, qr/no readable key|0 key/, 'and the reason was on stderr');
};

subtest 'more than one key and no selector is a warning, not a guess' => sub {
	my $input = message(from => 'alerts@example.org');
	my ($status, $sent, undef, $err) = run_wrapper($input,
		DKIM_DOMAINS => 'example.org', DKIM_KEYDIR => $MANY);

	is($status, 0, 'the wrapper exited 0');
	is($sent, $input, 'the message was delivered unsigned');
	like($err, qr/2 key/, 'and it said why it could not choose');

	my ($chosen_status, $chosen) = run_wrapper($input,
		DKIM_DOMAINS => 'example.org', DKIM_KEYDIR => $MANY, DKIM_SELECTOR => 'selector1');

	is($chosen_status, 0, 'with a selector it exited 0');
	like($chosen, qr/s=selector1/, 'the named key was used');
};

subtest 'sendmail arguments are passed through unchanged and in order' => sub {
	my $input = message(from => 'alerts@example.org');
	my ($status, undef, $args) = run_wrapper($input,
		['-t', '-f', 'bounce@example.org', '-odq'], DKIM_DOMAINS => 'example.org');

	is($status, 0, 'the wrapper exited 0');
	is($args, "-t\n-f\nbounce\@example.org\n-odq\n", 'every argument was handed to sendmail');
};

subtest 'sendmail\'s own exit status is what the caller sees' => sub {
	my $input = message(from => 'alerts@example.org');
	my ($status) = run_wrapper($input, DKIM_DOMAINS => 'example.org', DKIM_TEST_EXIT => 75);

	is($status, 75, 'a sendmail that failed is reported as failed');
};

subtest 'sendmail that cannot be run is reported' => sub {
	my $input = message(from => 'alerts@example.org');
	my ($status, undef, undef, $err) = run_wrapper($input,
		DKIM_DOMAINS => 'example.org', SENDMAIL => File::Spec->catfile($TMP, 'no-such-sendmail'));

	is($status, 1, 'the wrapper exited 1');
	like($err, qr/cannot run/, 'and said it could not run sendmail');
};

done_testing();
