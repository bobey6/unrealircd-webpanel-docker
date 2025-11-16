#!/bin/bash
set -e

# Basic paths
WEBROOT=/var/www/html/unrealircd-webpanel
ACME_WWW=/var/www/certbot
LE_CONF=/etc/letsencrypt

# Ensure webroot and acme directory exist and permissions are correct
mkdir -p "$WEBROOT" "$ACME_WWW"
chown -R www-data:www-data /var/www/html || true

# Ensure PHP dependencies are installed for the webpanel
if [ ! -d "$WEBROOT/vendor" ]; then
  echo "vendor/ directory missing in $WEBROOT, running composer install..."
  if command -v composer >/dev/null 2>&1; then
    (cd "$WEBROOT" && composer install --no-dev --prefer-dist --no-interaction) || echo "composer install failed; webpanel may not function correctly until dependencies are installed" >&2
  else
    echo "composer not found in container; cannot auto-install PHP dependencies" >&2
  fi
fi

# Start php-fpm (use available binary)
if [ -x "/usr/sbin/php-fpm8.4" ]; then
  /usr/sbin/php-fpm8.4 -D || true
elif [ -x "/usr/sbin/php-fpm" ]; then
  /usr/sbin/php-fpm -D || true
else
  for f in /usr/sbin/php*-fpm; do
    if [ -x "$f" ]; then
      "$f" -D || true
      break
    fi
  done
fi

# Wait a moment for php-fpm to start
sleep 1

# Helper to write ssl nginx config
write_ssl_conf() {
  local crt="$1" key="$2" domain="$3"
  cat > /etc/nginx/conf.d/ssl.conf <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $domain;

    ssl_certificate $crt;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    http2 on;

    root $WEBROOT;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass 127.0.0.1:9000;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files \$uri =404;
        expires max;
        log_not_found off;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    location /.well-known/acme-challenge/ {
        root $ACME_WWW;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

build_domain_args() {
  local primary="$1" extras="$2" args="-d $primary"
  IFS=',' read -ra arr <<< "$extras"
  for d in "${arr[@]}"; do
    d=$(echo "$d" | xargs)
    [ -n "$d" ] && args="$args -d $d"
  done
  echo "$args"
}

ensure_dns_plugin() {
  local provider="$1"
  if certbot plugins 2>/dev/null | grep -q "dns-$provider"; then
    return 0
  fi
  echo "DNS plugin dns-$provider not found. Attempting to install..."
  apt-get update && apt-get install -y --no-install-recommends "python3-certbot-dns-$provider" || {
    echo "Failed to install python3-certbot-dns-$provider. You may need to rebuild the image with the correct plugin or provide LETSENCRYPT_DNS_PROVIDER_OPTS manually." >&2
    return 1
  }
}

certbot_common_flags() {
  local email="$1" staging="$2"; shift || true
  local flags=(--non-interactive --agree-tos)
  if [ -z "$email" ]; then
    flags+=(--register-unsafely-without-email)
  else
    flags+=(--email "$email")
  fi
  if [ "$staging" = "1" ]; then
    flags+=(--staging)
  fi
  echo "${flags[@]}"
}

obtain_letsencrypt_http01() {
  local domain="$1" email="$2" staging="$3" extra_domains="$4"
  [ -f "$LE_CONF/live/$domain/fullchain.pem" ] && return 0
  echo "Attempting HTTP-01 cert for $domain"
  mkdir -p "$ACME_WWW"
  IFS=',' read -ra extras <<< "$extra_domains"
  local certbot_flags
  certbot_flags=$(certbot_common_flags "$email" "$staging")
  # shellcheck disable=SC2206
  local args=(certbot certonly --webroot -w "$ACME_WWW")
  args+=( -d "$domain" )
  for d in "${extras[@]}"; do
    d=$(echo "$d" | xargs)
    [ -n "$d" ] && args+=( -d "$d" )
  done
  # append common flags (already tokenized)
  # shellcheck disable=SC2206
  args+=( $certbot_flags )
  echo "CERTBOT DEBUG HTTP-01: ${args[*]}" >&2
  "${args[@]}"
}

obtain_letsencrypt_dns01() {
  local domain="$1" email="$2" staging="$3" provider="$4" creds="$5" propsec="$6" extra_domains="$7" provider_opts="$8"
  [ -f "$LE_CONF/live/$domain/fullchain.pem" ] && return 0
  if [ -z "$provider" ] && [ -z "$provider_opts" ]; then
    echo "LETSENCRYPT_DNS_PROVIDER or LETSENCRYPT_DNS_PROVIDER_OPTS must be set for dns-01" >&2
    return 1
  fi
  if [ -n "$provider" ]; then
    ensure_dns_plugin "$provider" || true
  fi
  IFS=',' read -ra extras <<< "$extra_domains"
  local certbot_flags
  certbot_flags=$(certbot_common_flags "$email" "$staging")
  # shellcheck disable=SC2206
  local args=(certbot certonly)
  if [ -n "$provider_opts" ]; then
    # shellcheck disable=SC2206
    args+=( $provider_opts )
  else
    args+=( "--dns-$provider" )
    [ -n "$creds" ] && args+=( "--dns-$provider-credentials" "$creds" )
    [ -n "$propsec" ] && args+=( "--dns-$provider-propagation-seconds" "$propsec" )
  fi
  args+=( -d "$domain" )
  for d in "${extras[@]}"; do
    d=$(echo "$d" | xargs)
    [ -n "$d" ] && args+=( -d "$d" )
  done
  # shellcheck disable=SC2206
  args+=( $certbot_flags )
  echo "Attempting DNS-01 cert for $domain using provider: ${provider:-custom opts}" 
  echo "CERTBOT DEBUG DNS-01: ${args[*]}" >&2
  "${args[@]}"
}

# If DOMAIN provided, try to get cert; otherwise create self-signed cert
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "" ]; then
  # ensure nginx will serve ACME challenge on port 80
  # update http site to serve .well-known from ACME_WWW: keep existing default config
  mkdir -p "$LE_CONF" "$ACME_WWW"
  chown -R www-data:www-data "$ACME_WWW" "$LE_CONF" || true

  CHALLENGE_METHOD=${LETSENCRYPT_CHALLENGE:-http-01}
  STAGING=${LETSENCRYPT_STAGING:-0}
  ADDL=${ADDITIONAL_DOMAINS:-}
  if [ "$CHALLENGE_METHOD" = "dns-01" ]; then
    # If Cloudflare token is provided and no credentials file specified, generate one under /etc/letsencrypt
    CF_CREDS="$LETSENCRYPT_DNS_CREDENTIALS"
    if [ "${LETSENCRYPT_DNS_PROVIDER}" = "cloudflare" ] && [ -n "${DNS_CLOUDFLARE_API_TOKEN}" ]; then
      CF_CREDS=${CF_CREDS:-"$LE_CONF/cloudflare.ini"}
      if [ ! -f "$CF_CREDS" ]; then
        echo "dns_cloudflare_api_token = ${DNS_CLOUDFLARE_API_TOKEN}" > "$CF_CREDS"
        chmod 600 "$CF_CREDS" || true
      fi
    fi
    if obtain_letsencrypt_dns01 "$DOMAIN" "$LETSENCRYPT_EMAIL" "$STAGING" "$LETSENCRYPT_DNS_PROVIDER" "$CF_CREDS" "$LETSENCRYPT_DNS_PROPAGATION_SECONDS" "$ADDL" "$LETSENCRYPT_DNS_PROVIDER_OPTS"; then
      crt="$LE_CONF/live/$DOMAIN/fullchain.pem"
      key="$LE_CONF/live/$DOMAIN/privkey.pem"
      write_ssl_conf "$crt" "$key" "$DOMAIN"
      echo "Obtained Let's Encrypt DNS-01 cert for $DOMAIN"
    else
      echo "Failed to obtain DNS-01 cert for $DOMAIN — falling back to self-signed"
      DOMAIN_FALLBACK=${DOMAIN:-localhost}
      mkdir -p /etc/ssl/private
      crt=/etc/ssl/private/selfsigned.crt
      key=/etc/ssl/private/selfsigned.key
      if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=$DOMAIN_FALLBACK" -keyout "$key" -out "$crt"
      fi
      write_ssl_conf "$crt" "$key" "$DOMAIN_FALLBACK"
    fi
  elif obtain_letsencrypt_http01 "$DOMAIN" "$LETSENCRYPT_EMAIL" "$STAGING" "$ADDL"; then
    crt="$LE_CONF/live/$DOMAIN/fullchain.pem"
    key="$LE_CONF/live/$DOMAIN/privkey.pem"
    write_ssl_conf "$crt" "$key" "$DOMAIN"
    echo "Obtained Let's Encrypt cert for $DOMAIN"
  else
    echo "Failed to obtain Let's Encrypt cert for $DOMAIN — falling back to self-signed"
    DOMAIN_FALLBACK=${DOMAIN:-localhost}
    mkdir -p /etc/ssl/private
    crt=/etc/ssl/private/selfsigned.crt
    key=/etc/ssl/private/selfsigned.key
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=$DOMAIN_FALLBACK" -keyout "$key" -out "$crt"
    fi
    write_ssl_conf "$crt" "$key" "$DOMAIN_FALLBACK"
  fi
else
  echo "No DOMAIN set — generating self-signed certificate"
  mkdir -p /etc/ssl/private
  crt=/etc/ssl/private/selfsigned.crt
  key=/etc/ssl/private/selfsigned.key
  if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -subj "/CN=localhost" -keyout "$key" -out "$crt"
  fi
  write_ssl_conf "$crt" "$key" "_"
fi

# Reload nginx so ssl.conf is picked up
nginx -s reload || true

# Start nginx in the foreground
nginx -g 'daemon off;'
