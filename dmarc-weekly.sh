#!/bin/sh
#
# Weekly DMARC check, meant to be run from cron.
#
# Silent when every message came from the expected sender; when dmarc-report.pl
# exits non-zero it sends the full output to MAIL_TO, and always records the
# failure in LOG so the same information survives a week in which no mail
# transport was available.
#
# Cron runs with almost no environment, so the perl that has XML::LibXML is
# named explicitly instead of being found on PATH: the system perl does not
# have it, and a job that fails for that reason would be silent.
#
# This machine has no local MTA (no mail, mailx, sendmail or msmtp), so out of
# the box the message goes to the log.  Set MAIL_COMMAND to anything that reads
# a message with headers on stdin, e.g.
#	MAIL_COMMAND='ssh vps38148.dreamhostps.com /usr/sbin/sendmail -t'
# or install msmtp/ssmtp and it is picked up automatically.

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPORT="$SELF_DIR/dmarc-report.pl"

PERL=${PERL:-/home/njh/perl5/perlbrew/perls/perl-5.40.0/bin/perl}
[ -x "$PERL" ] || PERL=perl

REPORTS=${DMARC_DIR:-$HOME/Downloads}
MAIL_TO=${MAIL_TO:-alerts@bandsman.co.uk}
LOG=${DMARC_LOG:-$HOME/dmarc-report.log}
SUBJECT="DMARC: mail from an address that is not the VPS"

# One run, one answer: the output is captured so that it can be both logged
# and mailed, and so that a clean week prints nothing at all.
output=$("$PERL" "$REPORT" -d "$REPORTS" 2>&1)
status=$?

if [ "$status" -eq 0 ]; then
	exit 0
fi

printf '%s  %s  exit %s\n%s\n\n' "$(date '+%Y-%m-%d %H:%M')" "$REPORTS" "$status" "$output" >> "$LOG"

message="DMARC check of $REPORTS at $(date '+%Y-%m-%d %H:%M') exited $status.

Addresses that are not the expected sender are marked UNEXPECTED SOURCE.
'expected, failing auth' is different: the VPS sent it, but its signature or
SPF record did not hold up, and that is a sending problem on our side.

$output"

if [ "${DRY_RUN:-0}" = 1 ]; then
	printf 'would mail %s\n%s\n' "$MAIL_TO" "$message"
	printf 'logged to %s\n' "$LOG"
	exit "$status"
fi

sent=0

# A command that reads a complete message on stdin, headers included.
if [ -n "${MAIL_COMMAND:-}" ]; then
	printf 'To: %s\nSubject: %s\n\n%s\n' "$MAIL_TO" "$SUBJECT" "$message" | sh -c "$MAIL_COMMAND" && sent=1
elif command -v mail > /dev/null 2>&1; then
	printf '%s\n' "$message" | mail -s "$SUBJECT" "$MAIL_TO" && sent=1
elif command -v mailx > /dev/null 2>&1; then
	printf '%s\n' "$message" | mailx -s "$SUBJECT" "$MAIL_TO" && sent=1
elif command -v sendmail > /dev/null 2>&1; then
	printf 'To: %s\nSubject: %s\n\n%s\n' "$MAIL_TO" "$SUBJECT" "$message" | sendmail -t && sent=1
fi

if [ "$sent" -eq 0 ]; then
	# Nothing could send it.  Say so on stderr, which cron keeps, and leave the
	# exit status non-zero so the week is not mistaken for a clean one.
	echo "dmarc-weekly: no mail transport; output is in $LOG" >&2
	printf '%s\n' "$message" >&2
fi

exit "$status"
