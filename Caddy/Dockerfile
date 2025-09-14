FROM caddy:latest

# OpenSSL 설치
RUN apk update && apk add --no-cache openssl gettext  # envsubst는 gettext에 포함

# 자체 서명된 SSL 인증서 생성
RUN mkdir -p /etc/caddy/certs /etc/caddy/private && \
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/caddy/private/server_pkey.pem \
        -out /etc/caddy/certs/server.crt \
        -subj "/C=KR/ST=Seoul/L=Gaepo/O=42Seoul/OU=./CN=yeomin.42.fr/emailAddress=yeomin@student.42seoul.kr"

# Caddyfile 템플릿 복사
COPY ./Caddyfile /etc/caddy/Caddyfile

# Ensure permissions
RUN chmod 600 /etc/caddy/certs/server.crt /etc/caddy/private/server_pkey.pem


# Replace placeholders and run Caddy
CMD sh -c 'caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'