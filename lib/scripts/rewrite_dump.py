#!/usr/bin/env python3
"""Rewrite a pg_dump --data-only file from js22's acc_-prefixed schema to
not-again's.

SURGICAL ON PURPOSE. The strings we are renaming also occur inside the DATA:
Shrine stores each upload's key on the row, and those keys begin with the
table-derived prefix `acc_receipts/`. Those keys point at real objects in the
bucket. Rewriting them would leave every receipt in the app pointing at a path
that does not exist, while the files themselves sat there untouched and
unreachable.

So only three kinds of line are rewritten, and data rows never are:

  COPY public.acc_postings (acc_account_id, …) FROM stdin;
  SELECT pg_catalog.setval('public.acc_postings_id_seq', 421, true);
  -- Data for Name: acc_postings; Type: TABLE DATA; …
"""
import re, sys

TABLES = ["accounts","admin_entities","currencies","entities","entity_groups",
          "exchange_rates","journal_entries","postings","receipts",
          "report_group_accounts","report_groups","reports","tax_categories",
          "taxpayers"]
COLUMNS = ["account_id","entity_id","posting_id","journal_entry_id",
           "report_group_id","entity_group_id","taxpayer_id"]

tbl = re.compile(r'\bacc_(%s)\b' % "|".join(sorted(TABLES, key=len, reverse=True)))
seq = re.compile(r'\bacc_(%s)_id_seq\b' % "|".join(sorted(TABLES, key=len, reverse=True)))
col = re.compile(r'\bacc_(%s)\b' % "|".join(sorted(COLUMNS, key=len, reverse=True)))

src, dst = sys.argv[1], sys.argv[2]
out, stats = [], {"copy": 0, "setval": 0, "comment": 0, "data_untouched": 0}

for line in open(src):
    if line.startswith("COPY public."):
        head, _, rest = line.partition("(")
        cols, _, tail = rest.rpartition(")")
        line = seq.sub(r"\1_id_seq", tbl.sub(r"\1", head)) + "(" + col.sub(r"\1", cols) + ")" + tail
        stats["copy"] += 1
    elif "pg_catalog.setval" in line:
        line = seq.sub(r"\1_id_seq", line)
        stats["setval"] += 1
    elif line.startswith("--"):
        line = tbl.sub(r"\1", line)
        stats["comment"] += 1
    else:
        stats["data_untouched"] += 1
    out.append(line)

open(dst, "w").writelines(out)
for k, v in stats.items():
    print("  %-16s %d" % (k, v))
