#!/usr/bin/env bash
set -euo pipefail
HW=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HW/captures"

step() { printf '\n==================== %s ====================\n' "$*"; }
run()  { printf '\n$ %s\n' "$1"; bash -c "$1"; }

step "0. Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq ipvsadm nginx curl dnsmasq python3 tshark bind9-dnsutils iproute2 procps >/dev/null 2>&1
run "nginx -v; dnsmasq --version | head -1; ipvsadm --version; tshark --version | head -1; python3 --version"

step "Задание 1. Server Pool"
run "mkdir -p ~/backend1 ~/backend2"
run "echo '<h1>Response from Backend Server 1</h1>' > ~/backend1/index.html"
run "echo '<h2>*** Response from Backend Server 2 ***</h2>' > ~/backend2/index.html"
run "cd ~/backend1 && nohup python3 -m http.server 8081 >/tmp/backend1.log 2>&1 &"
run "cd ~/backend2 && nohup python3 -m http.server 8082 >/tmp/backend2.log 2>&1 &"
sleep 1
run "ss -ltnp | grep -E ':808[12]'"
run "curl -s http://127.0.0.1:8081"
run "curl -s http://127.0.0.1:8082"

step "Задание 2. DNS Load Balancing (dnsmasq)"
run "cat $HW/dnsmasq.conf"
run "dnsmasq --conf-file=$HW/dnsmasq.conf"
run "dig @127.0.0.1 my-awesome-highload-app.local"
for _ in 1 2 3 4; do run "dig @127.0.0.1 my-awesome-highload-app.local +short | tr '\n' ' '"; done
run "pkill -f 'http.server 8082'"
run "curl -sS --max-time 2 http://127.0.0.1:8082 || true"
run "dig @127.0.0.1 my-awesome-highload-app.local +noall +answer"
run "cat /var/log/dnsmasq-hw.log | tail -4"
run "cd ~/backend2 && nohup python3 -m http.server 8082 >/tmp/backend2.log 2>&1 &"
sleep 1

step "Задание 3. L4 балансировка (IPVS)"
run "ip link add dummy1 type dummy"
run "ip addr add 192.168.100.1/32 dev dummy1"
run "ip link set dummy1 up"
run "ip -br addr show dummy1"
run "ipvsadm -A -t 192.168.100.1:80 -s rr"
run "ipvsadm -a -t 192.168.100.1:80 -r 127.0.0.1:8081 -m"
run "ipvsadm -a -t 192.168.100.1:80 -r 127.0.0.1:8082 -m"
run "ipvsadm -Ln"
for _ in 1 2 3 4 5 6; do run "curl -s http://192.168.100.1"; done
sleep 3
run "ipvsadm -Ln"
run "ipvsadm -Ln --stats"
run "ipvsadm -Lnc"

step "Задание 4. L7 балансировка (NGINX, active-backup)"
run "rm -f /etc/nginx/sites-enabled/default"
run "cp $HW/nginx-highload.conf /etc/nginx/conf.d/highload.conf && cat /etc/nginx/conf.d/highload.conf"
run "nginx -t"
run "nginx"
run "ss -ltnp | grep nginx"

tshark -q -i lo -f 'tcp port 8888 or tcp port 8081 or tcp port 8082' -a duration:4 -w /tmp/normal.pcap 2>/dev/null &
sleep 2
run "curl -s -i http://127.0.0.1:8888/"
wait
cp /tmp/normal.pcap "$HW/captures/normal.pcap"
DECODE='-d tcp.port==8888,http -d tcp.port==8081,http -d tcp.port==8082,http'
run "tshark -r /tmp/normal.pcap $DECODE -Y http 2>/dev/null"
run "tshark -r /tmp/normal.pcap $DECODE -Y http -O http 2>/dev/null"

: > /var/log/nginx/highload_access.log
run "pkill -f 'http.server 8081'"
tshark -q -i lo -f 'tcp port 8888 or tcp port 8081 or tcp port 8082' -a duration:6 -w /tmp/failover.pcap 2>/dev/null &
sleep 2
for i in $(seq 10); do run "curl -s http://127.0.0.1:8888/"; done
wait
cp /tmp/failover.pcap "$HW/captures/failover.pcap"
run "cat /var/log/nginx/highload_access.log"
run "cat /var/log/nginx/highload_error.log"
run "tshark -r /tmp/failover.pcap -Y 'tcp.dstport==8081 && tcp.flags.syn==1' 2>/dev/null"
run "tshark -r /tmp/failover.pcap -Y 'tcp.dstport==8081 && tcp.flags.syn==1' 2>/dev/null | wc -l"
