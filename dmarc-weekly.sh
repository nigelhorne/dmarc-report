#!/bin/sh
#
# Weekly DMARC check, meant to be run from cron.
#
# Silent when every message came from the expected sender; when dmarc-report.pl
# exits non-zero it sends the full output to MAIL_TO, and always records the
# failure in LOG so the same information survives a week in which no mail
# transport was available.
#
# The reports it summarised are then moved into $HOME/dmarc-archive, so that
# next week's run reports that week's mail rather than repeating last week's.
# That is outside the reports directory on purpose: the directory is a downloads
# folder, and an archive inside it is just more clutter there.
# Only the files dmarc-report.pl says it read are moved: a downloads directory
# also holds installers and data sets, and one of them is 13 GB.
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
ARCHIVE=${DMARC_ARCHIVE_DIR:-$HOME/dmarc-archive}
MAIL_TO=${MAIL_TO:-alerts@bandsman.co.uk}
LOG=${DMARC_LOG:-$HOME/dmarc-report.log}
SUBJECT="DMARC: mail that needs looking at"

MOVED=0

# A temporary file per run, so two runs cannot tread on each other's list.
LIST=$(mktemp "${TMPDIR:-/tmp}/dmarc-read.XXXXXX") || LIST=
trap 'if [ -n "${LIST:-}" ]; then rm -f "$LIST"; fi' EXIT HUP INT TERM

if [ -n "$LIST" ]; then
	output=$("$PERL" "$REPORT" -d "$REPORTS" --file-list "$LIST" 2>&1)
else
	output=$("$PERL" "$REPORT" -d "$REPORTS" 2>&1)
fi
status=$?

# Move aside the reports just summarised.  A name already in the archive is
# kept: the same report can legitimately be fetched twice, and the second copy
# must not overwrite the first.
archive_reports()
{
	# A rehearsal must not have side effects, and this is the one place that
	# moves files, so every caller is covered by the check being here.
	if [ "${DRY_RUN:-0}" = 1 ] || [ "${DMARC_ARCHIVE:-1}" = 0 ]; then
		return 0
	fi
	if [ -z "$LIST" ] || [ ! -s "$LIST" ]; then
		return 0
	fi

	if ! mkdir -p "$ARCHIVE"; then
		echo "dmarc-weekly: cannot create $ARCHIVE; reports left where they are" >&2
		return 1
	fi

	while IFS= read -r report_file; do
		[ -n "$report_file" ] || continue
		[ -f "$report_file" ] || continue
		target="$ARCHIVE/$(basename "$report_file")"
		if [ -e "$target" ]; then
			target="$target.$(date +%Y%m%d%H%M%S)"
		fi
		if mv -- "$report_file" "$target"; then
			MOVED=$((MOVED + 1))
		fi
	done < "$LIST"

	return 0
}

# Nothing new this week is the normal quiet outcome once the previous reports
# have been archived, so it is not a failure to report.
case "$status" in
	0) ;;
	*)
		case "$output" in
			*"No reports found"*)
				archive_reports
				exit 0
				;;
		esac
		;;
esac

if [ "$status" -eq 0 ]; then
	archive_reports
	exit 0
fi

printf '%s  %s  exit %s\n%s\n\n' "$(date '+%Y-%m-%d %H:%M')" "$REPORTS" "$status" "$output" >> "$LOG"

message="DMARC check of $REPORTS at $(date '+%Y-%m-%d %H:%M') exited $status.

Addresses that are not the expected sender are marked UNEXPECTED SOURCE.
'expected, failing auth' is different: the VPS sent it, but its signature or
SPF record did not hold up, and that is a sending problem on our side.
A message marked 'authenticated, but quarantined' passed DKIM or SPF and was
filed anyway, and 'expected sender, quarantined' means our own mail is being
filed; both are listed again under 'Filed by policy'.

$output"

if [ "${DRY_RUN:-0}" = 1 ]; then
	printf 'would mail %s\n%s\n' "$MAIL_TO" "$message"
	printf 'would archive %s report(s) to %s\n' "$(grep -c . "$LIST" 2>/dev/null || echo 0)" "$ARCHIVE"
	exit "$status"
fi

archive_reports
if [ "$MOVED" -gt 0 ]; then
	message="$message
$MOVED report(s) moved to $ARCHIVE."
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
