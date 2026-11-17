# dmarc-report

## Name

dmarc-report - summarise DMARC aggregate reports and flag unexpected senders

## Synopsis

```
    dmarc-report [--dir DIR]... [--expected IP]... [--file-list FILE]

    # only the reports of one domain, watching a different host
    dmarc-report -d ~/Downloads -e 203.0.113.10

    # in a cron job: nonzero when anything came from elsewhere
    dmarc-report -d /var/reports/dmarc || echo 'unexpected sender'
```

## Description

Summarises DMARC aggregate reports and flags every message that came from an
address other than the expected sender.

DMARC reports arrive as XML, sometimes gzipped, sometimes zipped, and usually
several at a time - the reports for `bandsman.co.uk`, `concert-bands.co.uk`,
`concert-bands.com` and `nigelhorne.com` all land in the same mailbox.  This
reads a whole directory, prints what each report says, then gives the totals
per source address **for each domain separately**, because an address that
legitimately sends for one domain is not thereby legitimate for another.

Pointing it at a downloads directory is safe: a file too large to be a report
is never opened, and a file that does not contain a `<feedback>` document
is passed over, so installers, archives and data sets in the same directory
cost nothing.

Any source address that is not one of the expected hosts is marked, and so is
an expected host whose mail did not authenticate, since that is the case worth
looking at: it means the host is sending but the signature or the SPF record
is wrong.

The totals are kept per domain because the reports for several domains arrive
at the same mailbox: an address that legitimately sends for one domain is not
thereby legitimate for another, so adding the figures together would hide both
a real sender and a real problem.

### Running It

```
    ./dmarc-report.pl                                  # ~/Downloads, or $DMARC_DIR
    ./dmarc-report.pl -d ~/Downloads -d /var/reports/dmarc
    ./dmarc-report.pl -e 67.205.23.146 -e 203.0.113.10 # allow more than one sender
    perldoc dmarc-report.pl                            # full options
```

The expected sender defaults to `67.205.23.146`, the DreamHost VPS that sends
the sites' mail.  `--dir` and `--expected` can each be given more than once.

Only `*.xml`, `*.xml.gz` and `*.zip` are considered.  A file over 10 MB is
never opened and a file that does not contain a `<feedback>` document is
skipped, so pointing it at a downloads directory full of installers and data
sets costs nothing - it finishes in well under a second.

### Reading the Output

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

- `domain` / `p=` is the policy the receiving site applied, so `p=none` means nothing was blocked and these figures are observation only.
- `dkim=` and `spf=` are the verdicts DMARC made; `dkim seen:` and `spf seen:` are what the report says the message actually offered.
- `dkim seen: none` means the message carried no signature at all, which is a different problem from a signature that failed to verify.

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

The `status` column is the thing to read; these are its values and their meaning:

- `expected, authenticating` - the VPS sent it and DKIM or SPF passed, which is what you want
- `expected, failing auth` - the VPS sent it, but the signature or SPF record did not hold up: the sending side is broken
- `UNEXPECTED SOURCE` - something else sent as the domain: a forwarder, another mail client, or forgery

The same address appears in each domain's block with that domain's own counts,
never one merged figure.

### Exit Status

`0` when every message came from an expected sender, `1` when something else
did, `2` on a usage error, so it is safe in a cron job:

```
    dmarc-report.pl -d /var/reports/dmarc || echo 'unexpected sender'
```

`expected, failing auth` does not by itself make it exit 1: it is a delivery
problem on our side, not a foreign sender.  Errors (no reports found, a
missing directory) exit non-zero with the reason on stderr.

## Options

- **--dir**, **-d** DIR

    A directory of reports.  May be given more than once.

- **--expected**, **-e** IP

    A host that is allowed to send as these domains.  May be given more than
    once.  Defaults to `67.205.23.146`, the VPS that sends the sites' mail.

- **--file-list** FILE

    Write to FILE the path of every report that was read, one per line.  Only
    files that were actually summarised are listed: the installers, archives and
    data sets that share the directory are not, so a caller can safely move what
    is named there out of the way and have the next run report only what is new.

- **--help**, **-h**

    Print this documentation.

## Weekly Check

`dmarc-weekly.sh` is the cron wrapper: silent when every message came from
the expected sender, and otherwise a mail to `alerts@bandsman.co.uk` with the
full output.  It is installed in the crontab for Mondays at 06:17.

```
    DRY_RUN=1 dmarc-weekly.sh     # show what would be mailed, send nothing
```

It sets `PERL` to the perlbrew perl because cron's `PATH` has only the system
perl, which lacks `XML::LibXML`.  Failures are always appended to
`~/dmarc-report.log`.  There is no local MTA on this machine, so the mail step
needs `MAIL_COMMAND` set (anything reading a message with headers on stdin) or
msmtp/ssmtp installed; until then the output is logged and printed to stderr.

Once summarised, a report is moved into `$HOME/dmarc-archive` (override with
`DMARC_ARCHIVE_DIR`), so each week reports that week's mail rather than
repeating last week's, and nothing accumulates next to the downloads.  The
archive lives outside `DMARC_DIR` on purpose.

Only the files the summariser actually read are moved - `dmarc-report.pl
\--file-list FILE` names them - so the installers and data sets sharing the
directory stay put.  A report fetched twice keeps both copies, the second
renamed with a timestamp.  `DMARC_ARCHIVE=0` turns archiving off; a run with
nothing new exits 0 and says nothing.

## Cookbook: Trends Across Reporters

`dmarc-report.pl` answers "is anything wrong this week".  [Database::BI](https://metacpan.org/pod/Database%3A%3ABI)
answers the questions that need several reports at once: whether Gmail and
Outlook are seeing the same spoofing run, which addresses are new today,
whether the quarantine share matches `pct`, and how the volume moved when the
policy tightened.

BI reads the report files themselves.  It takes each repeated `record` element
as a row and names every column after the path it followed to reach the value,
so the nesting costs nothing:

```
    report_metadata_org_name          google.com
    report_metadata_date_range_begin  1794614400
    policy_published_p                quarantine
    policy_published_pct              25
    row_source_ip                     185.247.116.62
    row_count                         5
    row_policy_evaluated_disposition  quarantine
    identifiers_header_from           bandsman.co.uk
    auth_results_spf_result           softfail
```

The columns differ from one reporter to the next - Google sends
`extra_contact_info`, Microsoft sends `fo` and the envelope addresses, and
neither fills every field - but nothing has to be converted first.

### Opening a Report

Start the viewer from the root of the Database-BI distribution: the templates
are loaded from `web/` relative to the current directory, so the
`database-bi` installed on `PATH` renders "Could not render a response"
when started anywhere else.  Then open a file with _Open file..._:

```
    database-bi
```

Archived names contain `!`, so pick the file rather than typing a URL; the
URL behind the panel is `/open?path=/home/njh/dmarc-archive/...xml` with the
name percent-encoded.

### Several Reports at Once

`/combine` stacks whole reports into one table, which is what makes a trend
visible.  The first is `l=`, every further one `c=`:

```
    /combine?l=path:/home/njh/dmarc-archive/google.com!...!1794355200!1794441599.xml
            &c=path:/home/njh/dmarc-archive/google.com!...!1794441600!1794527999.xml
```

Every column from every source appears and cells are blank where a reporter
does not send that field, so Google and Microsoft reports stack together
cleanly.  In the browser the same thing is the _Combine data_ panel.

### Questions Worth Asking

- Which reporters see the campaign?

    Filter `report_metadata_org_name` to `google.com` and to
    `protection.outlook.com`, or stack both with `/combine` and pivot
    `report_metadata_org_name` against `report_metadata_date_range_begin`
    summing `row_count`.  Two reporters listing the same address on the same day
    is one run of mail reaching both, not two separate ones.

- Is our own mail getting through?

    Filter `row_source_ip` to your expected sender.  Every row
    should have `row_policy_evaluated_disposition` `none` and a passing
    `row_policy_evaluated_dkim` or `row_policy_evaluated_spf`.  If it shows
    `quarantine`, the policy is catching your own mail and the record needs
    changing back.

- Is `pct` doing what it says?

    Filter `row_policy_evaluated_disposition` to `quarantine` and compare its
    share of `row_count` with `policy_published_pct` in the same report.  The
    same address appearing under both `quarantine` and `none` in one report is
    the sampling working as intended.

- What is new?

    Sort by `report_metadata_date_range_begin`, then `row_source_ip`.  An address
    under one day only is either a one-off or a new sender; an address under
    several days is a campaign.

- Who is sending most?

    Pivot `row_source_ip` against `row_count`, summed and sorted descending.

The date columns are epoch seconds, so they sort correctly as numbers.  A chart
can bucket them by day with `span=1d&agg=sum`, but the buckets follow the
timezone of the machine running BI (`America/New_York` here), so a report that
begins at 00:00 UTC lands on the previous local day: the label is the day it
ended as much as the day it began.

### What the Rows Cannot Tell You

Reports contain every message the receiver evaluated, not only the ones it
quarantined: `row_policy_evaluated_disposition` is what happened, and a report
full of `quarantine` rows still describes mail delivered to a spam folder
rather than refused.  A reporter that stops sending looks exactly like a quiet
week, so absence of rows is worth noticing.  And BI reads the files you point
it at rather than hunting for new ones, so open the archive once the weekly
wrapper has put this week's reports in it.

## Tests

```
    prove t/            # or: prove -v t/dmarc-report.t
```

The tests run the scripts as programs, because the exit status is half of what
they check, and they build their fixtures in a temporary directory - no
network, no real reports needed.

`t/dmarc-report.t` covers each of the three formats, a gzipped CSV and a
**3 GB sparse `.zip`** that must be skipped in under two seconds, and the exit
status for expected, failing and foreign senders.

`t/dmarc-weekly.t` covers what the wrapper does with the files, which is its
own behaviour rather than the summariser's.  Each run gets its own `HOME`, so
the archive and log defaults land in the temporary directory:

- a dry run moves nothing and creates no archive directory, on a week with a finding and on a clean one - the clean case is what once archived the lot
- a repeat download is kept beside the first copy under a timestamp, not on top of it
- an empty reports directory exits 0 without a word, while a missing one still fails and says why
- a finding is mailed, and the mail says how many reports were archived.

`t/readme.t` runs pod2github over this file and fails if the committed
README.md is not what it produces, so the two cannot drift apart.  Regenerate
it with:

```
    pod2github dmarc-report.pl > README.md
```

The title in that output comes from `.pod2github-header.md`, named by
`.pod2github.yml`: the generator shifts the POD headings down a level, which
would otherwise leave the README with no H1 at all.

Requires `Test::Most`, `XML::LibXML`, `IO::Compress::{Gzip,Zip}`,
`IO::Uncompress::{Gunzip,Unzip}`, `Readonly` and `Time::HiRes`.
