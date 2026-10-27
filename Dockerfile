FROM nginx:1.31.8-alpine
RUN apk upgrade --no-cache
COPY nginx/default.conf /etc/nginx/conf.d/
COPY src/ /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
