# Rocky Linux 9 + systemd + 依「步驟 1」用 Elastic 官方 RPM 套件庫安裝 Elasticsearch（叢集節點用，尚未啟動）
# ES_MAJOR=9 / ES_VERSION=9.5.5 或 ES_MAJOR=8 / ES_VERSION=8.19.23
FROM eslab-rocky9-base
ARG ES_MAJOR=9
ARG ES_VERSION=9.5.5
RUN rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch \
 && printf '[elasticsearch]\nname=Elasticsearch repository for %s.x packages\nbaseurl=https://artifacts.elastic.co/packages/%s.x/yum\ngpgcheck=1\ngpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch\nenabled=0\nautorefresh=1\ntype=rpm-md\n' $ES_MAJOR $ES_MAJOR > /etc/yum.repos.d/elasticsearch.repo \
 && dnf install -y --enablerepo=elasticsearch elasticsearch-$ES_VERSION \
 && dnf clean all
