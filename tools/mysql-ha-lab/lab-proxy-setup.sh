#!/bin/bash
# 只在 LAB_PROXY 有值時動作（一般電腦什麼都不做）：讓 dnf 走只支援 HTTPS CONNECT 的代理
#   - 信任代理的 CA、dnf 設定 proxy
#   - Rocky 套件庫改用 dl.rockylinux.org 的 baseurl（不用 mirrorlist）
#   - percona-release 產生的 http:// 套件庫改成 https://（包一層同名指令，輸出不變）
P="$1"; [ -z "$P" ] && exit 0
if [ -f /run/secrets/labca ]; then cp /run/secrets/labca /etc/pki/ca-trust/source/anchors/lab-proxy.crt; update-ca-trust; fi
echo "proxy=$P" >> /etc/dnf/dnf.conf
sed -i -e 's/^mirrorlist=/#mirrorlist=/' -e 's/^#baseurl=/baseurl=/' -e 's#http://dl.rockylinux.org#https://dl.rockylinux.org#' /etc/yum.repos.d/rocky*.repo
cat > /usr/local/sbin/percona-release <<'W'
#!/bin/bash
/usr/bin/percona-release "$@"; rc=$?
sed -i 's#http://repo.percona.com#https://repo.percona.com#g' /etc/yum.repos.d/percona-*.repo 2>/dev/null
exit $rc
W
chmod +x /usr/local/sbin/percona-release
# rpm -i 直接下載網址時也要走代理
printf '%%_httpproxy %s\n%%_httpport %s\n' "$(echo "$P" | sed -E 's#https?://([^:]+):.*#\1#')" "${P##*:}" > /etc/rpm/macros.lab-proxy
