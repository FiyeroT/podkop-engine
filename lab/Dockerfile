# Стенд совместимости: xray-core (сервер VLESS+REALITY) и sing-box (клиент) в одном контейнере.
# Бинарники не запекаются в образ — монтируются из lab/bin, чтобы менять версии без пересборки.
FROM alpine:3.22
RUN apk add --no-cache nginx openssl curl jq bash coreutils libgcc \
 && mkdir -p /etc/nginx/tls /run/nginx \
 && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=reality.test" -addext "subjectAltName=DNS:reality.test" \
      -keyout /etc/nginx/tls/key.pem -out /etc/nginx/tls/cert.pem
COPY nginx.conf /etc/nginx/nginx.conf
COPY run-matrix.sh /lab/run-matrix.sh
WORKDIR /lab
ENTRYPOINT ["/lab/run-matrix.sh"]
