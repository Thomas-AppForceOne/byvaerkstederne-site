#!/usr/bin/env python3
"""read-tier-mail.py — read mail delivered to the operator test mailbox.

WHY
---
Mailpit proves what the code *renders*: the Playwright suites assert subject,
body, links, sender and footer against a local sink. It cannot prove what a
deployed tier actually *delivers* — that path runs through one.com's relay,
and the only way to see the result is to open the mailbox it landed in.

This reads that mailbox. It is the tier-side counterpart to the Mailpit
helpers in tests/helpers/mail.js, and it is READ-ONLY: the IMAP folder is
selected with readonly=True, nothing is marked, moved or deleted.

MAILBOX
-------
test@hackersbychoice.dk (one.com, IMAP imap.one.com:993). Plus-addressing is
supported — verified with a probe, not assumed — so one mailbox serves every
purpose while staying distinguishable:

    test+kontakt@   the contact address dev renders in mails
    test+admin@     the tier's super-admin account
    test+userN@     disposable member registrations

CREDENTIALS
-----------
Never in the repo, never on the command line. The password lives in the macOS
Keychain and is read at runtime, the same pattern deploy/lib/ssh-auth.sh and
the age keys use:

    security add-generic-password -a "$USER" -s bv-mail-test-hbc -U -w

Override the item name with BV_TEST_MAILBOX_KEYCHAIN and the address with
BV_TEST_MAILBOX if a tier ever needs its own mailbox.

USAGE
-----
    scripts/read-tier-mail.py --to test+kontakt@hackersbychoice.dk
    scripts/read-tier-mail.py --subject "Velkommen" --since-minutes 30 --body
    scripts/read-tier-mail.py --to test+admin@hackersbychoice.dk --json

Exit codes: 0 messages found, 1 none matched, 2 configuration/credential
problem, 3 connection or login failure. "None matched" is deliberately
distinct from "could not look" — a missing mail is a finding, an unreachable
mailbox is not.
"""

from __future__ import annotations

import argparse
import email
import imaplib
import json
import os
import subprocess
import sys
from email.header import decode_header, make_header
from email.utils import parsedate_to_datetime
from datetime import datetime, timedelta, timezone

IMAP_HOST = "imap.one.com"
IMAP_PORT = 993
DEFAULT_MAILBOX = "test@hackersbychoice.dk"
DEFAULT_KEYCHAIN_ITEM = "bv-mail-test-hbc"


def keychain_password(item: str) -> str:
    """The mailbox password from the login Keychain. Never echoed."""
    result = subprocess.run(
        ["security", "find-generic-password", "-a", os.environ.get("USER", ""), "-s", item, "-w"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        sys.exit(
            f"read-tier-mail: no Keychain item '{item}' for account "
            f"'{os.environ.get('USER', '')}'.\n"
            f"  Add it with: security add-generic-password -a \"$USER\" -s {item} -U -w\n"
            f"  (-w last so it prompts instead of taking the password as an argument)"
        )
    return result.stdout.strip()


def decoded(value: str | None) -> str:
    """RFC 2047 header -> text. Danish subjects arrive encoded."""
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def body_text(msg: email.message.Message) -> str:
    """Prefer text/plain; fall back to the HTML part verbatim."""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                payload = part.get_payload(decode=True) or b""
                return payload.decode(part.get_content_charset() or "utf-8", "replace")
        for part in msg.walk():
            if part.get_content_type() == "text/html":
                payload = part.get_payload(decode=True) or b""
                return payload.decode(part.get_content_charset() or "utf-8", "replace")
        return ""
    payload = msg.get_payload(decode=True) or b""
    return payload.decode(msg.get_content_charset() or "utf-8", "replace")


def main() -> int:
    parser = argparse.ArgumentParser(description="Read mail delivered to the operator test mailbox.")
    parser.add_argument("--to", help="only messages addressed to this address (plus-alias aware)")
    parser.add_argument("--subject", help="only messages whose subject contains this text")
    parser.add_argument("--since-minutes", type=int, default=0, help="only messages newer than N minutes")
    parser.add_argument("--limit", type=int, default=10, help="most recent N matches (default 10)")
    parser.add_argument("--body", action="store_true", help="print the message body too")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    mailbox = os.environ.get("BV_TEST_MAILBOX", DEFAULT_MAILBOX)
    item = os.environ.get("BV_TEST_MAILBOX_KEYCHAIN", DEFAULT_KEYCHAIN_ITEM)
    password = keychain_password(item)

    try:
        conn = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT, timeout=30)
    except Exception as exc:  # noqa: BLE001 — the reason is what the operator needs
        print(f"read-tier-mail: cannot reach {IMAP_HOST}:{IMAP_PORT} — {type(exc).__name__}: {exc}", file=sys.stderr)
        return 3
    try:
        conn.login(mailbox, password)
    except Exception as exc:  # noqa: BLE001
        print(
            f"read-tier-mail: login refused for {mailbox} — {type(exc).__name__}: {exc}\n"
            f"  The transport is fine if another account on the same host logs in; check the\n"
            f"  Keychain item '{item}' and that the mailbox is fully provisioned.",
            file=sys.stderr,
        )
        return 3

    # readonly=True: this tool never mutates the mailbox, so a verification run
    # can never destroy the evidence someone else is about to look at.
    conn.select("INBOX", readonly=True)

    criteria: list[str] = []
    if args.to:
        criteria += ["TO", f'"{args.to}"']
    if args.subject:
        criteria += ["SUBJECT", f'"{args.subject}"']
    if args.since_minutes:
        since = datetime.now(timezone.utc) - timedelta(minutes=args.since_minutes)
        criteria += ["SINCE", since.strftime("%d-%b-%Y")]
    if not criteria:
        criteria = ["ALL"]

    typ, data = conn.search(None, *criteria)
    ids = (data[0].split() if data and data[0] else [])[-args.limit :]

    results = []
    for msg_id in reversed(ids):
        typ, raw = conn.fetch(msg_id, "(RFC822)")
        if not raw or not raw[0]:
            continue
        msg = email.message_from_bytes(raw[0][1])
        # SINCE has date granularity; narrow to the actual cutoff here.
        if args.since_minutes:
            try:
                sent = parsedate_to_datetime(msg.get("Date"))
                if sent and sent < datetime.now(timezone.utc) - timedelta(minutes=args.since_minutes):
                    continue
            except Exception:
                pass
        entry = {
            "date": decoded(msg.get("Date")),
            "from": decoded(msg.get("From")),
            "to": decoded(msg.get("To")),
            "subject": decoded(msg.get("Subject")),
        }
        if args.body:
            entry["body"] = body_text(msg)
        results.append(entry)

    conn.logout()

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    else:
        for entry in results:
            print(f"{entry['date']}  {entry['from']}")
            print(f"  To:      {entry['to']}")
            print(f"  Subject: {entry['subject']}")
            if args.body:
                print("  ---")
                for line in entry["body"].splitlines():
                    print(f"  {line}")
            print()
        if not results:
            print("no matching messages")

    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
