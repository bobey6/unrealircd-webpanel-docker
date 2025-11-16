FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
     && apt-get install -y --no-install-recommends \
       nginx \
       php \
       php-fpm \
       php-zip \
       php-curl \
       php-mbstring \
       composer \
       git \
       ca-certificates \
       certbot \
       openssl \
       unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure php-fpm pools to listen on TCP 127.0.0.1:9000 so nginx can talk to it
RUN bash -c '\
  for f in /etc/php/*/fpm/pool.d/www.conf; do \
    if [ -f "$f" ]; then \
      sed -ri "s#^[[:space:]]*;?listen[[:space:]]*=.*#listen = 127.0.0.1:9000#" "$f"; \
    fi; \
  done'

# Use our nginx site config
COPY ./nginx_default /etc/nginx/sites-available/default

# Make cloning optional at build time (useful for mounting local source)
ARG SKIP_CLONE=0
# Clone the web panel into the nginx web root unless SKIP_CLONE=1
RUN rm -rf /var/www/html/* \
 && if [ "${SKIP_CLONE}" = "1" ]; then echo "Skipping git clone at build time"; else git clone --depth 1 https://github.com/unrealircd/unrealircd-webpanel /var/www/html/unrealircd-webpanel; fi \
 && chown -R www-data:www-data /var/www/html

# Add start script
COPY ./start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

EXPOSE 80

VOLUME ["/etc/letsencrypt", "/var/www/certbot"]

CMD ["/usr/local/bin/start.sh"]
