#!/usr/bin/env perl
#
# App::DMARC - the programmes are the product here, so there is no module to
# install alongside them; the distribution exists so that they can be fetched,
# tested and put on a PATH with one command.

use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
	'NAME' => 'App::DMARC',
	'VERSION' => '0.001',
	'ABSTRACT' => 'Watch DMARC reports, and sign the mail they describe',
	'AUTHOR' => 'Nigel Horne <njh@bandsman.co.uk>',
	'LICENSE' => 'gpl_2',
	'MIN_PERL_VERSION' => '5.016',
	'EXE_FILES' => [
		'bin/dmarc-report.pl',
		'bin/dmarc-weekly.sh',
		'bin/dmarc-check-mail.pl',
		'bin/mail-dkim',
	],
	'PREREQ_PM' => {
		'IO::Compress::Gzip' => 0,
		'IO::Compress::Zip' => 0,
		'IO::Uncompress::Gunzip' => 0,
		'IO::Uncompress::Unzip' => 0,
		'Mail::DKIM' => 0,
		'Readonly' => 0,
		'XML::LibXML' => 0,
	},
	'TEST_REQUIRES' => {
		'File::Temp' => 0,
		'Net::DNS' => 0,
		'Pod::Github' => 0,
		'Test::Most' => 0,
		'Time::HiRes' => 0,
	},
	'META_MERGE' => {
		'resources' => {
			'repository' => 'https://github.com/nigelhorne/dmarc-report',
			'bugtracker' => 'https://github.com/nigelhorne/dmarc-report/issues',
		},
	},
);
