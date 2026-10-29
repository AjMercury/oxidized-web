# Basic configuration
The RESTful API and web interface are enabled by installing the `oxidized-web`
gem and configuring the `extensions.oxidized-web:` section in the configuration
file:
```yaml
extensions:
  oxidized-web:
    load: true
    # enter your configuration here
```

You can set the following parameter:
- `load`: `true`/`false`: Enables or disables the `oxidized-web` extension
  (default: `false`)
- `listen`: Specifies the interface to bind to (default: `127.0.0.1`). Valid
  options:
  - `127.0.0.1`: Allows IPv4 connections from localhost only
  - `'[::1]'`: Allows IPv6 connections from localhost only
  - `<IPv4-Address>` or `'[<IPv6-Address>]'`: Binds to a specific interface
  - `0.0.0.0`: Binds to any IPv4 interface
  - `'[::]'`:  Binds to any IPv4 and IPv6 interface
- `port`: Specifies the TCP port to listen to (default: `8888`)
- `url_prefix`: Defines a URL prefix (default: no prefix)
- `vhosts`: A list of virtual hosts to listen to. If not specified, it will
  respond to any virtual host.

## Examples

```yaml
# Listen on http://[::1]:8888/
extensions:
  oxidized-web:
    load: true
    listen: '[::1]'
    port: 8888
```

```yaml
# Listen on http://127.0.0.1:8888/
extensions:
  oxidized-web:
    load: true
    listen: 127.0.0.1
    port: 8888
```

```yaml
# Listen on http://[2001:db8:0:face:b001:0:dead:beaf]:8888/oxidized/
extensions:
  oxidized-web:
    load: true
    listen: '[2001:db8:0:face:b001:0:dead:beaf]'
    port: 8888
    url_prefix: oxidized
```

```yaml
# Listen on http://10.0.0.1:8000/oxidized/
extensions:
  oxidized-web:
    load: true
    listen: 10.0.0.1
    port: 8000
    url_prefix: oxidized
```

```yaml
# Listen on any interface to http://oxidized.rocks:8888 and
# http://oxidized:8888
extensions:
  oxidized-web:
    load: true
    listen: '[::]'
    url_prefix: oxidized
    vhosts:
     - oxidized.rocks
     - oxidized
```

# Hide node vars
Some node vars (enable, password) can contain sensible data. You can list the
vars to be hidden under `hide_node_vars`:
```yaml
extensions:
  oxidized-web:
    load: true
    hide_node_vars:
     - enable
     - password
```

## Administrator operations

Inventory writes, source reload, and manual backup use HTTP Basic
authentication. Configure both environment variables in the Oxidized systemd
service before enabling these operations:

```ini
Environment=OXIDIZED_WEB_ADMIN_USERNAME=oxidized-admin
EnvironmentFile=/etc/oxidized/web-admin.env
```

Store `OXIDIZED_WEB_ADMIN_PASSWORD` in a root-owned environment file with mode
`0600`; systemd reads it before starting the `oxidized` service account. Do not
put passwords in the Oxidized YAML file or in command-line arguments. Without both values, protected
operations return `503 Service Unavailable`.

Use HTTPS at the reverse proxy and preserve the browser's `Host` header. The
Web application checks the authenticated user and requires an `Origin` or
`Referer` matching that host for every state-changing request. It does not
accept proxy identity headers. Configure `vhosts` with the public hostname to
restrict accepted hosts.

The protected reload and manual-backup actions use `POST`; the former `GET`
forms of `/reload` and `/node/next/...` no longer perform state changes. The
existing `PUT /node/next/...` JSON API remains available to authenticated
administrators and now requires the same-origin check.

Device management currently supports only a plaintext CSV source with mapped
`name`, `model`, and `ip` fields. It refuses SQL, HTTP, NetBox, GPG-encrypted
CSV, unsupported delimiter/mapping layouts, and Core versions without the
history-preserving reload option. `description`, `enable`, `ssh_port`, and
`telnet_port` are shown only when mapped; ports use Core's `ssh_port` and
`telnet_port` node variables. Blank credential fields on edit keep the
existing stored values.
