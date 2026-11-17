package Mail::Send::DKIM;

# The signing half of bin/mail-dkim: given an object configured with the
# domains this host signs for, a message either comes back signed or comes back
# as undef and the caller sends it as it is.  Nothing here dies on a signing
# problem, because a missing key must never stop mail being delivered.

use strict;
use warnings;

use Mail::DKIM::Signer;

our $VERSION = '0.001';

sub new
{
	my ($class, %args) = @_;

	my $home = $ENV{'HOME'} || (getpwuid($<))[7] || '.';

	my $domains = $args{'domains'} // $ENV{'DKIM_DOMAINS'} // '';
	my @domains = ref($domains) eq 'ARRAY' ? @$domains : split(/[\s,]+/, $domains);

	my $self = {
		'domains' => { map { lc($_) => 1 } grep { length } @domains },
		'keydir' => $args{'keydir'} // $ENV{'DKIM_KEYDIR'} // "$home/dkim",
		'selector' => $args{'selector'} // $ENV{'DKIM_SELECTOR'},
		'sendmail' => $args{'sendmail'} // $ENV{'SENDMAIL'} // '/usr/sbin/sendmail',
	};

	return bless($self, $class);
}

sub sign
{
	my ($self, $message) = @_;

	my $domain = from_domain($message);
	return unless(defined($domain));
	return unless($self->{'domains'}->{$domain});

	my $selector = $self->selector;
	return unless(defined($selector));

	my $keyfile = $self->{'keydir'} . "/$selector.private";
	unless(-r $keyfile) {
		warn "Mail::Send::DKIM: no readable key at $keyfile; sending $domain unsigned\n";
		return;
	}

	# DKIM hashes the message in the form it travels in, where every line
	# ends CRLF, so the signature is made over a CRLF copy of what arrived.
	(my $wire = $message) =~ s/\r\n/\n/g;
	$wire =~ s/\n/\r\n/g;

	my $signed;
	eval {
		my $signer = Mail::DKIM::Signer->new(
			Algorithm => 'rsa-sha256',
			Method => 'relaxed',
			Domain => $domain,
			Selector => $selector,
			KeyFile => $keyfile,
		);
		$signer->PRINT($wire);
		$signer->CLOSE;
		$signed = $signer->signature->as_string . "\n" . $message;
		1;
	} or do {
		my $error = $@ || 'unknown error';
		chomp($error);
		warn "Mail::Send::DKIM: cannot sign for $domain ($error); sending unsigned\n";
		return;
	};

	return $signed;
}

sub send
{
	my ($self, $message, @args) = @_;

	open(my $sendmail, '|-', $self->{'sendmail'}, @args) or do {
		warn "Mail::Send::DKIM: cannot run $self->{'sendmail'}: $!\n";
		return 1;
	};
	print $sendmail $message;

	return 0 if(close($sendmail));

	my $status = $? >> 8;

	return $status || 1;
}

#
# The domain an address is at, from the first From: header.  A header field can
# be folded over several lines, so the continuation lines are joined first, and
# a display name is dropped in favour of the address in angle brackets.
sub from_domain
{
	my $message = shift;

	my ($head) = $message =~ /\A(.*?)\r?\n\r?\n/s;
	$head = $message unless(defined($head));
	$head =~ s/\r?\n[ \t]+/ /g;
	return unless($head =~ /^From:[ \t]*(.*?)\s*$/mi);

	my $value = $1;
	my ($address) = $value =~ /<([^>]*)>/;
	$address = $value unless(defined($address));

	# An address can be followed by a comment, so the domain is the last
	# thing that looks like one rather than the end of the string.
	my @domains = $address =~ /\@([A-Za-z0-9.-]+)/g;
	return unless(@domains);

	return lc($domains[-1]);
}

#
# The key file is <keydir>/<selector>.private.  With no selector named the
# selector is the name of the only key in the directory, which is the usual
# case: one key, published for every domain this host sends as.  Anything
# ambiguous is a warning rather than a guess.
sub selector
{
	my $self = shift;

	my $selector = $self->{'selector'};
	return $selector if(defined($selector) && length($selector));

	opendir(my $dh, $self->{'keydir'}) or do {
		warn "Mail::Send::DKIM: cannot read $self->{'keydir'}: $!\n";
		return;
	};
	my @keys = sort grep { /\.private\z/ } readdir($dh);
	closedir($dh);

	unless(@keys == 1) {
		warn sprintf("Mail::Send::DKIM: %s holds %d key(s); name the selector to choose one\n",
			$self->{'keydir'}, scalar(@keys));
		return;
	}

	(my $found = $keys[0]) =~ s/\.private\z//;

	return $found;
}

1;

__END__

=head1 NAME

Mail::Send::DKIM - sign a message with DKIM and hand it to sendmail

=head1 SYNOPSIS

	use Mail::Send::DKIM;

	my $dkim = Mail::Send::DKIM->new(
		domains => ['example.org'],
		keydir => "$ENV{HOME}/dkim",
	);

	my $signed = $dkim->sign($message);
	$message = $signed if(defined($signed));

	exit($dkim->send($message, '-t', '-f', 'alerts@example.org'));

=head1 DESCRIPTION

Signs a message with DKIM when its C<From:> domain is one this host signs for,
and hands it to sendmail with whatever arguments sendmail should have.  The
signed form is C<rsa-sha256> with C<relaxed> canonicalization, which is the
shape receiving sites expect.

The signature covers the message in the form DKIM defines, where every line
ends CRLF; the message itself is handed over with the line endings it arrived
with, because sendmail expects the local form and puts the CRLF back for SMTP.

Nothing here dies because a key is missing: signing either produces a signed
message or produces nothing and says why on standard error, so a caller can
always fall back to sending the message as it is.

=head1 METHODS

=over 4

=item B<new> %options

=over 4

=item C<domains>

The domains to sign for, either an array reference or a string of them
separated by commas or spaces.  Defaults to C<$ENV{DKIM_DOMAINS}>.  A message
from any other domain is left alone.

=item C<keydir>

Where the private keys are.  Defaults to C<$ENV{DKIM_KEYDIR}>, or F<~/dkim>.

=item C<selector>

The selector the key is published under, which names the key file
F<< <keydir>/<selector>.private >>.  Defaults to C<$ENV{DKIM_SELECTOR}>; with
neither set, the only F<*.private> file in B<keydir> is used and its name is
the selector.

=item C<sendmail>

The program B<send> hands the message to.  Defaults to C<$ENV{SENDMAIL}>, or
F</usr/sbin/sendmail>.

=back

=item B<sign> $message

Returns the message with a C<DKIM-Signature> header added, or C<undef> when
there is nothing to do or nothing that can be done: the domain is not one of
B<domains>, there is no C<From:> header, no key can be found or read, or the
signer failed.  The reasons are warnings on standard error; the message itself
is never altered in the undef case, so the caller sends it unchanged.

=item B<send> $message, @arguments

Pipes the message to B<sendmail> with the arguments given - C<-t>, C<-f> and
the rest are sendmail's own - and returns C<0> when sendmail accepted the
message, sendmail's exit status when it did not, and C<1> when sendmail cannot
be run at all.

=item B<from_domain> $message

The domain of the address in the first C<From:> header, in lower case, or
C<undef> when there is no such header.  Folded headers and display names are
understood.

=back

=head1 ENVIRONMENT

B<DKIM_DOMAINS>, B<DKIM_KEYDIR>, B<DKIM_SELECTOR> and B<SENDMAIL> are read by
B<new> when the corresponding option is not given, so the command line
programme needs no configuration of its own.

=head1 SEE ALSO

L<bin/mail-dkim>, the command line front end, and L<Mail::DKIM::Signer>.

=head1 LICENCE

GNU General Public License, version 2, as in the F<LICENSE> file.

=cut
