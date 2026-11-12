# dmarc-report

Summarises DMARC aggregate reports and flags every message that came from an
address other than the expected sender.

DMARC reports arrive as XML, sometimes gzipped, sometimes zipped, and usually
several at a time — the reports for `bandsman.co.uk`, `concert-bands.co.uk`,
`concert-bands.com` and `nigelhorne.com` all land in the same mailbox. This
reads a whole directory, prints what each report says, then gives the totals
per source address **for each domain separately**, because an address that
legitimately sends for one domain is not thereby legitimate for another.

## Running it

```sh
./dmarc-report.pl                                  # ~/Downloads, or $DMARC_DIR
./dmarc-report.pl -d ~/Downloads -d /var/reports/dmarc
./dmarc-report.pl -e 67.205.23.146 -e 203.0.113.10 # allow more than one sender
perldoc dmarc-report.pl                            # full options
```

The expected sender defaults to `67.205.23.146`, the DreamHost VPS that sends
the sites' mail. `--dir` and `--expected` can each be given more than once.

Only `*.xml`, `*.xml.gz` and `*.zip` are considered. A file over 10 MB is
never opened and a file that does not contain a `<feedback>` document is
skipped, so pointing it at a downloads directory full of installers and data
sets costs nothing — it finishes in well under a second.

## Reading the output

Per report first, one line per source address:

```
google.com!bandsman.co.uk!1794355200!1794441599.xml
  reporter : google.com   report_id: 9250231420970591661
  period   : 2026-11-11 00:00 UTC -> 2026-11-11 23:59 UTC
  domain   : bandsman.co.uk   p=none sp=none adkim=r aspf=r pct=100
  164.92.141.245       8  dkim=fail  spf=fail     none      from=bandsman.co.uk  <== NOT 67.205.23.146
      dkim seen: none
      spf  seen: bandsman.co.uk=softfail
```

- `domain` / `p=` is the policy the receiving site applied, so `p=none` means
  nothing was blocked and these figures are observation only.
- `dkim=` and `spf=` are the verdicts DMARC made; `dkim seen:` and `spf seen:`
  are what the report says the message actually offered. `dkim seen: none`
  means the message carried no signature at all, which is a different problem
  from a signature that failed to verify.

Then the totals, grouped by domain:

```
bandsman.co.uk: 4 message(s)
  source_ip        messages   passed   failed  status
  67.205.23.146           4        4        0  expected, authenticating
                     dkim: bandsman.co.uk/202611=pass

concert-bands.co.uk: 3 message(s), 1 not from 67.205.23.146
  source_ip        messages   passed   failed  status
  67.205.23.146           2        2        0  expected, authenticating
  198.51.100.9            1        0        1  UNEXPECTED SOURCE

nigelhorne.com: 1 message(s)
  source_ip        messages   passed   failed  status
  67.205.23.146           1        0        1  expected, failing auth
```

The `status` column is the thing to read:

| Status | Meaning |
|---|---|
| `expected, authenticating` | the VPS sent it and DKIM or SPF passed — what you want |
| `expected, failing auth` | the VPS sent it, but the signature or SPF record did not hold up: the sending side is broken |
| `UNEXPECTED SOURCE` | something else sent as the domain: a forwarder, another mail client, or forgery |

The same address appears in each domain's block with that domain's own counts,
never one merged figure.

## Exit status

`0` when every message came from an expected sender, `1` when something else
did, so it is safe in a cron job:

```sh
dmarc-report.pl -d /var/reports/dmarc || echo 'unexpected sender'
```

`expected, failing auth` does not by itself make it exit 1: it is a delivery
problem on our side, not a foreign sender. Errors (no reports found, a missing
directory) exit non-zero with the reason on stderr.

## Weekly check

`dmarc-weekly.sh` is the cron wrapper: silent when every message came from the
expected sender, and otherwise a mail to `alerts@bandsman.co.uk` with the full
output. It is installed in the crontab for Mondays at 06:17.

```sh
DRY_RUN=1 dmarc-weekly.sh     # show what would be mailed, send nothing
```

It sets `PERL` to the perlbrew perl because cron's `PATH` has only the system
perl, which lacks `XML::LibXML`. Failures are always appended to
`~/dmarc-report.log`. There is no local MTA on this machine, so the mail step
needs `MAIL_COMMAND` set (anything reading a message with headers on stdin) or
msmtp/ssmtp installed; until then the output is logged and printed to stderr.

Once summarised, a report is moved into `$DMARC_DIR/archive` (override with
`DMARC_ARCHIVE_DIR`), so each week reports that week's mail rather than
repeating last week's. Only the files the summariser actually read are moved —
`dmarc-report.pl --file-list FILE` names them — so the installers and data sets
sharing the directory stay put. A report fetched twice keeps both copies, the
second renamed with a timestamp. `DMARC_ARCHIVE=0` turns archiving off; a run
with nothing new exits 0 and says nothing.

## Tests

```sh
prove t/            # or: prove -v t/dmarc-report.t
```

The tests run the script as a program, because the exit status is half of what
they check, and they build their fixtures in a temporary directory — no
network, no real reports needed. They cover each of the three formats, a
gzipped CSV and a **3 GB sparse `.zip`** that must be skipped in under two
seconds, and the exit status for expected, failing and foreign senders.

Requires `Test::Most`, `XML::LibXML`, `IO::Compress::{Gzip,Zip}`,
`IO::Uncompress::{Gunzip,Unzip}`, `Readonly` and `Time::HiRes`.
