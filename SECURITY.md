# Reporting a security problem

**Please do not open a public issue.** Use GitHub's private vulnerability reporting: the **Security** tab of this repository → *Report a vulnerability*. That reaches the maintainer without the report being visible to anyone else, and needs no email address on either side.

If you cannot use that, and you found the problem on a **running installation** rather than in the code, that installation publishes its own operator's address at `/.well-known/security.txt`. They are the person who can take the site down; the maintainer of this repository is not.

## What happens next

This is maintained by one person, so here is what can honestly be promised:

- you will get an acknowledgement that a human has read it
- you will be told whether it is being treated as a vulnerability, and what is intended
- you will be told when a fix is released

No fixed timetable is offered, because a one-person project cannot keep one. What is offered is that you will not be left wondering.

## What is worth reporting

Anything that lets someone reach books they are not entitled to, act as an admin they are not, read receipts belonging to another business, or bypass a login. Also anything that leaks credentials — into logs, into an error page, into a URL.

**Some things are by design and are documented rather than defects:**

- **The owner account (`sudo`) can read every set of books on an installation.** That is inherent to running the server, and is stated in the README.
- **The person running the server can read the data.** Also inherent, also stated.
- **The public demo signs a visitor in without a password**, if the operator chose to seed it. It can read, and nothing else. Every request that is not a plain `GET` is refused, as are the filing actions even on `GET` (those would talk to a real tax authority); receipt upload and deletion are refused by a guard of their own; and `AdminEntity` refuses to put a demo account and a real one on the same books, or to give a demo account full access. **Any write reached from a demo session is a vulnerability and worth reporting.**

- **In development, uploads are served from `public/` without a login**, and the server binds to localhost only. Running development mode as an installation is not supported.

Known gaps are listed openly in [docs/known-limitations.md](docs/known-limitations.md). Something already described there is not news, but a way to exploit it is.

## Fixed vulnerabilities

Once fixed, they are published as GitHub Security Advisories on this repository, so anyone running an installation can see what changed and decide whether they were affected. Reporters are credited unless they ask not to be.
