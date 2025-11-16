# unrealircd-webpanel (Docker)

This folder contains a simple Debian-based Dockerfile that installs `nginx`, `php`, `php-fpm`, `composer`, and `git`, then clones the `unrealircd-webpanel` repository into the nginx web root.


Build and run with Docker Compose (recommended):

```bash
cd ./unrealircd-webpanel
docker compose up -d --build
```

By default the compose file exposes HTTP on `80` and HTTPS on `443`.
Environment variables are loaded from `.env`.

TLS / Let's Encrypt support
- If `DOMAIN` is set, the container will use `certbot` to obtain a certificate and store it in `./certbot/conf`.
- Challenge types:
	- `http-01` (default): Ensure port 80 on the host maps to the container and the domain resolves to this host.
	- `dns-01`: Useful for wildcard certs. Requires a DNS plugin and credentials.
- If `DOMAIN` is empty, the container generates a self-signed certificate automatically.


`.env` (key variables)

```bash
# Build-time clone toggle
SKIP_CLONE=0

# Host port mappings
HOST_PORT=80
HOST_PORT_SSL=443

# Certificate settings
DOMAIN=example.com
LETSENCRYPT_EMAIL=
LETSENCRYPT_CHALLENGE=http-01   # or dns-01
LETSENCRYPT_STAGING=0           # 1 to use LE staging
ADDITIONAL_DOMAINS=             # comma-separated (e.g., www.example.com,api.example.com)

# DNS-01 only
LETSENCRYPT_DNS_PROVIDER=       # e.g., cloudflare, route53, digitalocean
LETSENCRYPT_DNS_CREDENTIALS=    # e.g., /secrets/cloudflare.ini
LETSENCRYPT_DNS_PROPAGATION_SECONDS=60
# Alternative: provide custom certbot flags (e.g., --dns-route53)
LETSENCRYPT_DNS_PROVIDER_OPTS=
DNS_CLOUDFLARE_API_TOKEN=       # convenience for Cloudflare (see below)
```

DNS-01 setup
- Create a credentials file for your DNS provider in `./secrets` (ignored by git). Examples:
	- Cloudflare: `./secrets/cloudflare.ini` with `dns_cloudflare_api_token = <token>` and permissions `0600`.
	- Route53: set AWS credentials via environment or `~/.aws`; or set `LETSENCRYPT_DNS_PROVIDER_OPTS="--dns-route53"` and mount any needed files into `/secrets`.
- In `.env`, set:
	- `LETSENCRYPT_CHALLENGE=dns-01`
	- `LETSENCRYPT_DNS_PROVIDER=cloudflare` (or use `LETSENCRYPT_DNS_PROVIDER_OPTS`)
	- `LETSENCRYPT_DNS_CREDENTIALS=/secrets/cloudflare.ini`
	- Optionally adjust `LETSENCRYPT_DNS_PROPAGATION_SECONDS`.
- `docker compose up -d --build`

Cloudflare convenience
- Instead of preparing a credentials file, you can set `DNS_CLOUDFLARE_API_TOKEN=<token>` along with `LETSENCRYPT_DNS_PROVIDER=cloudflare`.
- If `LETSENCRYPT_DNS_CREDENTIALS` is empty, the container will create `/etc/letsencrypt/cloudflare.ini` with the token (chmod 600) and use it for the DNS-01 challenge.

Notes:
- The Dockerfile configures `php-fpm` to listen on TCP `127.0.0.1:9000` and a custom nginx site forwards PHP to that port.
- The image clones the GitHub repository at build time into `/var/www/html/unrealircd-webpanel`.
- If you need to persist data or manage configuration, consider mounting volumes for `/var/www/html` and configuration files.
 - Certificates and ACME state are persisted under `./certbot/conf`. Do not commit this directory.
 - For DNS-01, the container will attempt to install the appropriate certbot DNS plugin at startup based on `LETSENCRYPT_DNS_PROVIDER`. Alternatively, rebuild the image with the desired plugin preinstalled.
