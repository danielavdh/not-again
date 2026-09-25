# Setting up the services

Step-by-step for the five outside services this app can use: a server, DNS, object storage, email, and optionally a CDN. Plus the GitHub token the deploy needs.

⚠️ **Written September 2026, against the providers named below.** Control panels get redesigned constantly, so buttons move and menus get renamed. The *shape* of each task stays the same even when the wording does not: create a thing, restrict it, take a key. If a screen does not match, the provider's own documentation is the authority, and an assistant like Claude is good at translating "the docs say X, my screen says Y".

Nothing here is compulsory. Any server, any S3-compatible storage, any SMTP provider will do — these are the ones the reference installation uses, so they are the ones written up. It's not an ad, just an example.

Roughly what it costs: a small server around €4–5 a month, storage a few cents per gigabyte, email free at this volume, DNS free, CDN very little if you want one.

<!-- toc -->

**Contents**

- [1. The server — Hetzner](#1-the-server--hetzner)
    - [Encrypting that volume](#encrypting-that-volume)
- [2. DNS — ClouDNS, or your registrar](#2-dns--cloudns-or-your-registrar)
- [3. Object storage — Scaleway](#3-object-storage--scaleway)
- [4. Email — Scaleway Transactional Email](#4-email--scaleway-transactional-email)
- [5. CDN — Bunny (optional)](#5-cdn--bunny-optional)
- [6. The GitHub token for deploying](#6-the-github-token-for-deploying)
- [7. Mirroring to a second provider — OVH (optional)](#7-mirroring-to-a-second-provider--ovh-optional)
- [When it is all done](#when-it-is-all-done)

<!-- tocstop -->

---

## 1. The server — Hetzner

**Create it.** Hetzner Cloud → new project → **Add Server**. A CX22 is plenty. Choose Ubuntu.
Add your SSH key during creation — the box for it is on the same page, and adding it now saves you a password dance later.

If you have never made an SSH key, do this on your own computer first, then paste the contents of `~/.ssh/id_ed25519.pub` into Hetzner:

```bash
ssh-keygen -t ed25519          # press enter at every prompt
cat ~/.ssh/id_ed25519.pub
```

**If you did not add the key at creation**, Hetzner emails you a temporary root password. Then:

```bash
ssh root@<your server IP>      # it forces you to set a new password immediately
exit
ssh-copy-id root@<your server IP>
ssh root@<your server IP>      # should now let you straight in, no password
```

**Firewall.** Hetzner Cloud → **Firewalls** → Create. Name it something like `web-and-ssh`, and add three inbound rules, each allowed from any IPv4 and any IPv6:

| Port | What it is |
|---|---|
| 22 | SSH — you |
| 80 | HTTP — needed for the certificate |
| 443 | HTTPS — the app |

Leave outbound alone. Attach the server to it. One firewall can be shared by every server you run.

**Software the server needs.** Do it once, while you are logged in (log into the server => in terminal `ssh 'root@<IP-address>'` - `exit` to close the connection):

```bash
apt update
apt install -y cryptsetup unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && ./aws/install
rm -rf awscliv2.zip aws
```

installs cryptsetup and the aws client. Configuration later (README Backups section).

**A volume for the database.** Hetzner Cloud → **Volumes** → create one and attach it to the server.
The database will live here rather than on the server's own disk, which means you can encrypt it, resize it, and detach it if you rebuild the machine.

### Encrypting that volume

Worth doing if the books are not only your own. It protects against the disk leaving the building — a decommissioned drive, a seized or stolen machine. It does **not** protect against someone who has root on a running server, because the key has to be readable at boot for the database to start unattended. That is a real limit, not a detail: what actually keeps people out is the firewall and
your SSH configuration.

**Everything from here on is typed on the server, over SSH.** (in your terminal)

⚠️ **You will have to erase the volume entirely** first, so it is very important that you get the PATH to it correctly (the wrong path could erase your whole server)

#### Find path to the volume

Hetzner Cloud → **Volumes** → find your volume's row. At the end of the row is a ⋯ button (three dots) — click it and choose Show configuration.
The path appears three times, it starts with `/dev/disk/by-id/<something containing the word Volume and ending with a number>`, e.g. `/dev/disk/by-id/scsi-0HC_Volume_123456789`. And it is NOT something with sdb or sdc!
	
#### Set three variables for this session

Login to the server (=> in terminal `ssh 'root@<IP-address>'`) and set these three variables now (replace each <xxxxx> with the correct value). **Every command afterwards can be pasted unchanged as long as you stay in the same terminal window**.

```bash
VOL=</dev/disk/by-id/scsi-0HC_Volume_123456789>    
NAME=<not-again-db-crypt>               # a name you choose for the unlocked disk; it appears as /dev/mapper/<NAME>
DATA=/root/<service>-db/data            # <service> = the service: value in config/deploy.yml 
```

#### Check before going on:

(in that same window) check you got the path right:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$VOL"      # right size, MOUNTPOINTS still empty
echo "$DATA"      # the service name matches config/deploy.yml
```

Good: one line, the size you created, FSTYPE and MOUNTPOINTS both empty.

```
NAME SIZE FSTYPE MOUNTPOINTS
  sdc   10G
```

Stop if: not a block device (wrong path, or the volume isn't attached), anything in FSTYPE or MOUNTPOINTS, or extra lines underneath.
	
#### Encrypt it

⚠️ **This erases everything on `$VOL`.** Last chance to be sure. 

Keep going while logged into the server:

```bash
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 "$VOL"
```

It makes you type `YES` in capitals, then asks for a passphrase. **Keep that LUKS passphrase somewhere off the server, best alongside your master.key** — it is your only way in if the key file is lost.

A key file lets the server unlock the disk itself after a reboot, since nobody is there to do it manually:

```bash
dd if=/dev/urandom of=/root/.$NAME.key bs=1024 count=4
chmod 0400 /root/.$NAME.key
cryptsetup luksAddKey "$VOL" /root/.$NAME.key
```
This will ask you for the passphrase you just set.

Unlock it, put a filesystem on it, and attach it to the folder the database will use:

```bash
cryptsetup open --key-file /root/.$NAME.key "$VOL" "$NAME"
mkfs.ext4 /dev/mapper/$NAME
mkdir -p "$DATA"
mount /dev/mapper/$NAME "$DATA"
rm -rf "$DATA"/lost+found      # PostgreSQL will not set itself up in a folder that has anything in it
```

The last line matters. `mkfs.ext4` puts a `lost+found` folder on every filesystem it makes, and that is enough for PostgreSQL to consider the folder occupied and refuse to create the database. Deleting it is safe: it is where `fsck` puts files it rescues from a damaged disk, and `fsck` makes it again if it ever needs it.

#### Make it survive a reboot

On a reboot the disk needs to be unlocked and mounted automatically. Two files fix that (there is nothing to substitute):

```bash
echo "$NAME $VOL /root/.$NAME.key luks" >> /etc/crypttab        # to unlock the disk
echo "/dev/mapper/$NAME $DATA ext4 defaults 0 2" >> /etc/fstab  # to mount it and where
```

Check each got one new line, with real values and no gaps:

```bash
tail -1 /etc/crypttab
tail -1 /etc/fstab
```

**No `nofail`** — deliberately. Most guides suggest it, and it is wrong here, especially on a first deploy. It means "carry on booting even if this fails to mount", which would leave the server running with nothing at that folder — and Kamal would then start PostgreSQL on the ordinary unencrypted disk, working perfectly and looking entirely normal. Without it, a failed unlock stops the boot. Noisy, but it cannot fail quietly.

#### Check

⚠️ Do not skip this. If either line is wrong you want to find out now, while the disk is still empty (still in same session/window).

```bash
umount "$DATA"
cryptsetup close "$NAME"
cryptdisks_start "$NAME"     # reads /etc/crypttab
mount -a                     # reads /etc/fstab
findmnt "$DATA"
```

The first time the server reboots for any reason — a kernel update, usually — run 

```bash
findmnt /root/<service>-db/data
```

Replace <service> with the real value from config/deploy.yml:

It must print a line showing `/dev/mapper/<your name>`. Nothing printed means the folder is not on the encrypted disk: fix it before deploying anything.

#### Check the database actually started

`kamal accessory boot db` says `exit status 0` even when the database then fails to start, so check rather than assume. On the server:

```bash
docker ps --format '{{.Names}}\t{{.Status}}'
```

You want `Up 2 minutes` next to `<service>-db`. **`Restarting (1) 5 seconds ago` means it is failing and trying again** — every few seconds, for ever. That is the symptom; nothing else tells you.

#### If it says Restarting

Usually because the `rm -rf` line above was skipped. `docker logs <service>-db` is the only place it says why:

```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
initdb: detail: It contains a lost+found directory, perhaps due to it being a mount point.
```

Fix it on the server, replacing `<service>` with the `service:` value from `config/deploy.yml`:

```bash
docker stop <service>-db
rm -rf /root/<service>-db/data/lost+found
docker start <service>-db
docker exec <service>-db pg_isready -U <the POSTGRES_USER from config/deploy.yml>
```

You want `accepting connections`.

---

## 2. DNS — ClouDNS, or your registrar

**Before the first deploy**, so the certificate can be issued:

| Type | Name | Points at |
|---|---|---|
| A | `@` (the bare domain) | <203.0.113.10> |   
| A | `www` | <203.0.113.10> |

\# replace <203.0.113.10> with the real IPv4 — the same one you put in config/deploy.yml under servers.web

Both names must also appear in `config/deploy.yml` under `proxy: host:`, comma-separated with **no space** after the comma.

DNS takes time to spread. If you are moving an existing domain, lower its TTL a day beforehand so the change takes minutes rather than hours.

**Later**, two more sets: the CNAME for the CDN (step 5) and the mail records (step 4).

---

## 3. Object storage — Scaleway

**Make a project first.** Scaleway console → project selector → **Create project**. Everything else lives inside it, and a per-project key cannot see other projects — which is what stops one app's backup script writing into another app's bucket.

**Create the buckets.** Storage → **Object Storage** → Create a bucket. Region `fr-par` unless you prefer another. **Visibility: Private** for every one.

| Bucket | For | Needed? |
|---|---|---|
| `<app-files>` | receipts and their thumbnails | yes |
| `<app-db-backups>` | nightly database dumps | in practice, yes |
| `<app-tax>` | copies of digitally submitted returns | only if you file to HMRC |

**Make an application and give it permission.** Scaleway calls the thing that holds keys an "Application".

1. Profile menu (top right) → **Identity and Access Management (IAM)**.
2. **Applications** tab → *Create application*. Name it after the app.
3. **Policies** tab → *Create policy*. Name it `<app>-storage-policy`.
   - Principal: the application you just made.
   - Scope: the project you made.
   - Rules: under Storage, either `ObjectStorageFullAccess`, or — to be stricter — `ObjectStorageObjectsRead`, `ObjectStorageObjectsWrite` and `ObjectStorageObjectsDelete`.
4. Back in **Applications** → your application → **API keys** → *Generate API key*. Say yes when asked whether it is for Object Storage, and pick the project.
5. Set the expiry to **never**, unless you enjoy outages on an anniversary.
6. Copy the **access key** and **secret key**. The secret is shown once.

Both go into `credentials.yml.enc` under `s3:` — see the README's Configuration section.

**Lifecycle rules on the backup bucket**, so old dumps expire instead of piling up for ever. Open that bucket → **Lifecycle rules** → create one per prefix:

| Rule scope (prefix) | Expire after |
|---|---|
| `daily/` | 30 days |
| `weekly/` | 90 days |
| `monthly/` | 365 days |
| `yearly/` | 3653 days |

The action is **Expiration**. Prefixes need the trailing slash.

---

## 4. Email — Scaleway Transactional Email

Every mail this app sends is transactional: resets, invitations, export notices. Scaleway TEM is built for exactly that. It does not rewrite links or add unsubscribe headers, as marketing platforms do. The free monthly allowance is far more than this app sends.

Use the same Scaleway project as your storage (§3).

1. **Add your domain**: console → **Domains & Web Hosting** → **Transactional Email** → add it.
2. **Add the four records it shows** at your DNS provider, then wait for verification:
    - SPF — `TXT` at the domain: `v=spf1 include:_spf.tem.scaleway.com -all`
    - DKIM — `TXT` at `<id>._domainkey`
    - MX — `blackhole.tem.scaleway.com`, but ONLY if the domain receives no mail

      ⚠️ **A domain with a real mailbox keeps its own MX.** The blackhole host accepts mail and
      discards it, so adding it where mail is actually delivered destroys every incoming message.
      Scaleway's check only asks that an MX exists: verified 2026-09-24 on a domain whose MX points
      at Zoho — green in the console, and mail from it then passed DKIM, SPF and DMARC at the
      receiving end, with its mailbox untouched. A send-only domain has no MX of its
      own, which is why Scaleway offers the blackhole.
    - DMARC — `TXT` at `_dmarc`: `v=DMARC1; p=none` to start
3. **Create a key that can only send mail.** IAM → **Applications** → create one, e.g. `<service>-mail`. IAM → **Policies** → give that application `TransactionalEmailFullAccess`, scoped to this project only. Then generate an API key for it and copy the **secret** — it is shown once.

    A separate application because this key is the SMTP password: if it ever leaks, it can send mail and nothing else. Your receipts stay out of reach.

4. Put it in credentials:

```yaml
smtp:
  server:   smtp.tem.scaleway.com
  port:     587
  username: <the project ID>
  password: <that application's secret key>
```

**Port 587**, not 465 or 25: the app upgrades the connection with STARTTLS, and Hetzner blocks outbound 25 and 465 by default.

5. **Test the login before deploying** — it connects and authenticates but sends nothing:

```bash
bin/rails runner 'require "net/smtp"; c = Rails.application.credentials.smtp; s = Net::SMTP.new(c[:server], c[:port].to_i); s.enable_starttls_auto; s.start("<your domain>", c[:username], c[:password], :plain) { puts "OK" }'
```

`OK` means you are ready. `535 Permission denied` almost always means the policy is missing, or the username is the organisation ID instead of the project ID. IAM changes can take a minute to apply.

6. **After deploying**, send yourself a password reset.

---

## 5. CDN — Bunny (optional)

Skip this entirely if you like. Leave `ASSET_HOST` unset and the app serves its own stylesheets, javascripts, fonts and images perfectly well.

1. Bunny dashboard → **Pull Zones** → *Add Pull Zone*.
   - Name: your app's name, which gives you `<name>.b-cdn.net`.
   - **Origin URL**: your app's real address, `https://<your domain>`.
   - Pricing zone: Europe, plus North America if your readers are there.
2. **Caching** → General → Cache Expiration Time: **1 year**. Turn **Smart Cache** on. Leave *Vary Cache by Request Header* empty — the app sets its own CORS headers, and varying on `Origin` only fragments the cache.
3. **Custom hostname**: General → Hostnames → add `cdn.<your domain>`, then create a `CNAME` at your DNS provider pointing `cdn` at `<name>.b-cdn.net`. Back in Bunny, enable free SSL and tick **Force SSL**.
4. **Security** → SSL: turn off TLS 1.0 and 1.1., and set TLS security level to 'modern only'.
5. Set `ASSET_HOST: cdn.<your domain>` in `config/deploy.yml` (changes take effect after next deploy).

⚠️ After changing response headers (CORS especially), **purge the pull zone**. Assets are cached for a year, so a stale copy otherwise lingers.

---

## 6. The GitHub token for deploying

Kamal pushes the built app to a container registry, and GitHub does not accept your github account password for that.

1. GitHub → profile picture → **Settings** → **Developer settings**, at the bottom of the left sidebar.
2. **Personal access tokens** → **Tokens (classic)** → *Generate new token (classic)*.
3. Name it after the app, so several are tellable apart.
4. **Expiration: No expiration** — otherwise deploys break one day with no warning.
5. **Scopes: `write:packages` and `delete:packages`.** GitHub ticks `repo` along with them — that is its own behaviour, not a requirement of the deploy. Untick it if the form lets you: Kamal builds locally and only pushes and pulls the image, so nothing here reads your repositories. If it insists, leave it, and know that the token is then as powerful as your account is over every private repository — which is the reason to give each app its own and to delete one the moment it is out of use.
6. Generate, and copy it — it starts `ghp_` and is shown once.

It goes into `.kamal/secrets` as `KAMAL_REGISTRY_PASSWORD`.

Fine-grained tokens can be limited to a single repository, which is safer, but they expire within a year and have to be renewed. If you change a token, update `.kamal/secrets`. Changes take effect after next deploy.

---

## 7. Mirroring to a second provider — OVH (optional)

Not required to run the app — this is for someone who decides losing the *primary* provider's
account, not just a disk, would be a real problem. See "Mirroring to a second provider" in
`docs/maintenance.md` for the reasoning; this section is only the click-by-click.

**Why OVH specifically**: pure per-GB billing, no monthly minimum, no egress fees (as of January
2026) — Hetzner Object Storage was tried first and reversed on cost: its flat per-hour fee costs
far more than this app's actual data volumes (a few tens of MB a night) justify. Already a listed
provider in this app's own README.

**Create the project and bucket.**

1. New account → account type **Company**, if the cost is meant to be a deductible business expense (gets you a proper VAT invoice; a private-individual invoice can often still be deducted, but this is the cleaner paper trail).
2. **Public Cloud project** → **Storage** → **Object Storage** → **Create a container**.
3. **Region: 1-AZ, not 3-AZ** — Strasbourg (SBG) or Gravelines (GRA), either is fine. The console's "recommended" default is usually the pricier 3-AZ option; skip it. The extra redundancy is pointless on top of already having two separate providers — that is what actually protects the data, not internal replication within one of them.
4. **Versioning: enable.** Cheap, and turns a delete into a recoverable marker instead of the object actually vanishing.
5. **Encryption**: leave the default (server-side, OVH-managed keys) ticked.
6. **Object Lock: enable.** ⚠️ **Only decidable at creation — cannot be turned on later.** This does not lock anything by itself yet; it is the prerequisite for the per-object locking below.
7. **User**: create one now if you have not got one. Copy the **Access Key** and **Secret Key** immediately — the secret is normally shown once.

**Configure retention** (a separate screen, usually under the bucket's General info tab):

**Default retention: Disabled.** A bucket-wide default would apply to every upload including the
nightly database dumps, blocking the lifecycle rule below from ever actually deleting them — the
lock would win. Locking stays per-object, applied only to the long-lived files (not yet wired
into the mirror script — see its own header comment).

**Lifecycle rule**, on the **Lifecycle** tab:

| Field | Value |
|---|---|
| Rule name | `daily` (or similar) |
| Scope | prefix `daily/` |
| Expire current version | 75 days after creation |
| Delete incomplete multipart uploads | after 7 days |
| Status | Enabled |

**AWS CLI profile**, on your own machine (this step, not the server yet):

```bash
aws configure --profile ovh
# Access Key ID: <the one you saved>
# Secret Access Key: <the one you saved>
# region: sbg
# output format: json
```

Find the bucket's **S3 endpoint** on its General info tab (`https://s3.sbg.io.cloud.ovh.net/` for
Strasbourg) and verify the credentials work:

```bash
aws s3 ls --profile ovh --endpoint-url https://s3.sbg.io.cloud.ovh.net/
```

Empty output, no error, means it works.

⚠️ **These credentials never go into `credentials.yml.enc`.** The Rails app does not talk to this bucket at all — only `lib/scripts/mirror_to_second_provider.sh` does, via this AWS CLI profile, on whichever machine runs it — your own machine to test it, the server for the nightly run (see "Mirroring to a second provider" in `maintenance.md` for the cron lines).

Worth a glance before agreeing to anything: OVH's Auftragsverarbeitungsvertrag (DPA) is a standard Article 28 instrument, nothing alarming — but its clause 10.3 means account termination or non-renewal *for any reason* can trigger automatic, irreversible deletion of everything, including the mirrored backups. Billing health for this account needs the same attention Scaleway's does.

---

## When it is all done

Back to [self-hosting.md](self-hosting.md): [Configuration](self-hosting.md#configuration-steps-2-and-3),
then [Deploying](self-hosting.md#deploying-step-5), then [Backups](self-hosting.md#backups-step-7).

