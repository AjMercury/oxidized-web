# Oxidized Web Authentication

Web 0.24.0 requires a local SQLite user database and a valid authenticated
session for every dashboard, configuration, history, inventory, and API route.
Only the login page and local static assets are public. JSON/text API requests
without a valid session receive `401`; browser pages redirect to `/login`.
HTTP Basic Authorization headers are ignored.

## First administrator

The gem installs `oxidized-web-user`. Run it as the same Unix account that runs
Oxidized so the database is created with the right owner:

```sh
sudo install -o oxidized -g oxidized -m 0700 -d /var/lib/oxidized
sudo -u oxidized env OXIDIZED_WEB_AUTH_DB=/var/lib/oxidized/web-auth.sqlite3 \
  /usr/local/bin/oxidized-web-user bootstrap-admin
```

The command prompts for a username and password without echoing the password.
It requires 12 or more characters and will not create default credentials. The
first administrator can create administrator and viewer accounts under User
Management. Administrators can change their password in My Profile. Resetting a
user password or disabling their account revokes that user's existing sessions.

### Migrate an existing Basic-auth administrator

If the previous service uses `OXIDIZED_WEB_ADMIN_USERNAME` and
`OXIDIZED_WEB_ADMIN_PASSWORD`, migrate once before removing those variables from
the protected service environment. Run the command as the service account and
use the same auth database path configured for Oxidized Web:

```sh
sudo -u oxidized env OXIDIZED_WEB_AUTH_DB=/var/lib/oxidized/web-auth.sqlite3 \
  /usr/local/bin/oxidized-web-user migrate-legacy-admin
```

The command reads the legacy values only from its process environment, hashes
the password into SQLite, never prints either value, and removes both variables
from its own environment. It does not run automatically at service startup.
After success, remove the legacy variables from the protected service file and
restart Oxidized Web. If the old values are unavailable or do not meet current
credential validation, use the interactive `bootstrap-admin` command above;
neither path creates a default account.

## SQLite database and service environment

Set the same database path for the service and bootstrap command. SQLite is
created with private file permissions, foreign keys, and WAL mode. Back it up
with Oxidized stopped or use a SQLite-consistent backup utility; it contains
password hashes, active server-side sessions, rate-limit state, and audit
events. Passwords are stored as PBKDF2-HMAC-SHA256 hashes (600,000 iterations),
never as plaintext.

Example `/etc/oxidized/web-auth.env`:

```ini
OXIDIZED_WEB_AUTH_DB=/var/lib/oxidized/web-auth.sqlite3
OXIDIZED_WEB_AUTH_REQUIRE_HTTPS=true
OXIDIZED_WEB_TRUSTED_PROXIES=127.0.0.1,::1
```

Protect the environment file, and add it to `oxidized.service` with
`EnvironmentFile=/etc/oxidized/web-auth.env`. The default database path is
`~/.config/oxidized/web-auth.sqlite3` for the service account. Production must
keep HTTPS required. `OXIDIZED_WEB_AUTH_REQUIRE_HTTPS=false` is only suitable
for isolated local development.

## Reverse proxy

Bind Oxidized Web to loopback. Terminate TLS at Nginx or Caddy, preserve the
public `Host`, and overwrite the forwarded protocol header. Do not configure
the proxy to pass a client-supplied authentication identity header; Web does
not use forwarded identity headers.

Example Nginx location:

```nginx
location / {
    proxy_pass http://127.0.0.1:8888;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
}
```

The default trusted proxy list is loopback only. If the proxy connects from a
different address, set `OXIDIZED_WEB_TRUSTED_PROXIES` to that exact address or
its narrowly scoped subnet. The application trusts `X-Forwarded-Proto` only
when the immediate `REMOTE_ADDR` belongs to this configured list; it does not
trust arbitrary forwarded authentication or host headers. Login rate limiting
uses `X-Forwarded-For` only through a configured trusted proxy and selects the
nearest untrusted address from the validated chain; direct clients cannot
choose their rate-limit identity by sending a forwarding header. The Nginx
example overwrites `X-Forwarded-For` with `$remote_addr` so client-supplied
chains cannot poison it. Set the Core
Web `vhosts` allowlist to the public hostname as a separate Host-header check.

## Sessions, CSRF, and roles

- Session identifiers are cryptographically random; only their SHA-256 hashes
  are stored in SQLite. Login rotates the anonymous pre-login session.
- Cookies are `HttpOnly`, `SameSite=Lax`, and `Secure` when HTTPS is required.
  Sessions expire after eight idle hours and twelve absolute hours.
- Login failures are rate-limited per username and resolved client address.
  Limits persist across service restarts; no shared proxy-wide lockout bucket
  can block all users.
- Every state-changing request requires a server-issued CSRF token and a
  same-origin HTTPS Origin or Referer. Browser forms include the token. API
  clients must keep the session cookie and send `X-CSRF-Token` on writes.
- Administrators can manage inventory, queue backups, and manage users.
  Viewers can read dashboards, device data, history, diffs, and exports but
  cannot mutate inventory or user accounts.
- Login/logout, user changes, and inventory administration events are written
  to the SQLite audit table. Passwords and submitted credentials are never
  included in audit records or application logs.
- The login page may remember only the username in a protected cookie. No
  password or authentication token is stored in browser local storage.

If the database is missing or unavailable, protected routes fail closed. If
all administrators are lost, run the bootstrap command as the service account;
it creates an administrator only when the database has no administrator.
