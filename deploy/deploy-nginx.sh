#!/bin/bash
# 部署「即存」解析反代到 nginx。幂等,可重复跑。
#
# 前置:/tmp 下这四个文件已就位:
#   jicun-site.conf   站点配置
#   jicun-limits.conf http 级配置(限流 + 日志格式)
#   jicun-cfip.sh     优选 IP 聚合脚本
#   jicun-cfip.cron   聚合脚本的 cron 条目
# nginx -t 不通过会自动还原,不会把站点弄挂。
#
# 两份 API Key 都不在这四个文件里,它们是服务器上的:
#   /etc/nginx/jicun-secret.conf   media-parser 的 mp- key
# 第一次部署时如果 /tmp/jicun-secret.conf 在,就装过去;之后一直留在服务器上,
# 重复部署不会覆盖它。谁都没有的话直接报错退出 —— 少了它 nginx -t 也过不了。
#
# 曾经还有第二份 jicun-secret2.conf(BugPk 上游的 key),由 nginx 注入给
# /parse2/* 那几条反代。后来解析改成 **APP 直连上游**,那几条 location 已经删掉,
# 这份密钥也就没用了 —— 上游的 key 现在编译在客户端里(见 lib/parse_service.dart
# 的 upstreamApiKey)。
#
# 用法:sudo bash /tmp/jicun-deploy.sh

set -u

SITE=/etc/nginx/sites-available/mxper.cc.cd
LIMITS=/etc/nginx/conf.d/jicun-limits.conf
SECRET=/etc/nginx/jicun-secret.conf
CFIP_BIN=/usr/local/bin/jicun-cfip.sh
CFIP_CRON=/etc/cron.d/jicun-cfip
OUT_DIR=/var/www/jicun
BACKUP_ROOT=/root/nginx-backup
KEEP_BACKUPS=2
TS=$(date +%Y%m%d-%H%M%S)
BK=$BACKUP_ROOT/$TS

# 这个目录只会加不会减,每次部署长一份(一组:<TS>/ 目录 + nginx-full-<TS>.tar.gz)。
# 只留最近 KEEP_BACKUPS 份,更旧的整组删掉 —— 回滚只会用到最近那份。
prune_backups() {
    local keep entry ts
    keep=$(for entry in "$BACKUP_ROOT"/*; do
        [ -e "$entry" ] || continue
        echo "$entry" | grep -oE '[0-9]{8}-[0-9]{6}'
    done | sort -u | tail -n "$KEEP_BACKUPS")

    for entry in "$BACKUP_ROOT"/*; do
        [ -e "$entry" ] || continue
        ts=$(echo "$entry" | grep -oE '[0-9]{8}-[0-9]{6}')
        # 认不出时间戳的东西不碰(万一以后往里放了别的东西)
        [ -n "$ts" ] || continue
        echo "$keep" | grep -qx "$ts" || rm -rf -- "$entry"
    done
}

mkdir -p "$BK"
cp -a "$SITE" "$BK/mxper.cc.cd.orig"
if [ -f "$LIMITS" ]; then
    cp -a "$LIMITS" "$BK/jicun-limits.conf.orig"
fi
tar czf "$BACKUP_ROOT/nginx-full-$TS.tar.gz" /etc/nginx 2>/dev/null
prune_backups

# API Key:只认服务器上那一份。给了新的才装,否则原地不动 ——
# 免得某次部署手上没有密钥,反而把它覆盖没了。
if [ -f /tmp/jicun-secret.conf ]; then
    install -m 600 -o root -g root /tmp/jicun-secret.conf "$SECRET"
    rm -f /tmp/jicun-secret.conf
    echo "=== 已更新 $SECRET ==="
fi
if [ ! -f "$SECRET" ]; then
    echo "!!! 缺少 $SECRET,站点配置里的 include 会失败。" >&2
    echo "!!! 把密钥文件放到 /tmp/jicun-secret.conf 再跑一次。" >&2
    exit 1
fi

cp /tmp/jicun-limits.conf "$LIMITS"
cp /tmp/jicun-site.conf "$SITE"

echo "=== nginx -t ==="
if nginx -t; then
    systemctl reload nginx
    echo "=== RELOADED OK ==="
    echo "备份目录: $BK"
    echo "整包备份: $BACKUP_ROOT/nginx-full-$TS.tar.gz"
else
    echo "=== 配置检查不通过,正在还原 ==="
    cp -a "$BK/mxper.cc.cd.orig" "$SITE"
    if [ -f "$BK/jicun-limits.conf.orig" ]; then
        cp -a "$BK/jicun-limits.conf.orig" "$LIMITS"
    else
        rm -f "$LIMITS"
    fi
    nginx -t
    echo "=== 已还原,站点保持原状 ==="
    exit 1
fi

# 优选 IP 的聚合脚本和 cron。跟 nginx 配置分开装 —— 它们挂了不影响站点。
# 这两步放在 reload 之后:万一这里出错,站点已经是好的。
echo "=== 安装优选 IP 聚合 ==="
install -m 755 /tmp/jicun-cfip.sh "$CFIP_BIN"
# cron.d 的文件必须是 644 且末尾有换行,否则 cron 会静默忽略。
install -m 644 /tmp/jicun-cfip.cron "$CFIP_CRON"
mkdir -p "$OUT_DIR"

# 立刻跑一次:既生成首份 ips.json,也顺便验证脚本在这台机器上跑得通。
bash "$CFIP_BIN" | sed 's/^/  /'
echo "=== ips.json ==="
cat "$OUT_DIR/ips.json" 2>/dev/null || echo "  (没有生成,APP 会继续用内置池)"
echo

# ── 自检:四条上游路各自试一发 ──
#
# 部署完当场就知道通没通,不用再回本地敲 curl。测的是「配置有没有生效」和
# 「nginx 到上游通不通」,不关心链接本身能不能解析 —— 所以随便给一条抖音链接,
# 四条路都拿它去打:上游会回 422「解析参数与该平台不匹配」,那也是**通了**的表现
# (说明请求到了上游),真正要警惕的是 404(路没配上)和 502(到上游断了)。
echo "=== 自检:上游四条路 ==="
PROBE_LINK=${JICUN_PROBE_LINK:-https://v.douyin.com/cfrsgHwx7bs/}
# curl 的 -w 模板放进变量再传:写成字面量时,%{...} 会被**调用方**的 shell
# (本机 PowerShell)当成变量插值吃掉,于是 curl 收到一个叫 %http_code 的东西,
# 打出来的就不是状态码。这是实测踩到的。
PROBE_FMT='%{http_code}'
for pair in "dy:抖音" "ks:快手" "wx:微信视频号" "db:豆包"; do
    code=${pair%%:*}
    name=${pair##*:}
    http=$(curl -s -m 30 -o /tmp/jicun-probe.out -w "$PROBE_FMT" \
        "https://mxper.cc.cd/parse2/$code?url=$PROBE_LINK" 2>/dev/null || echo 000)
    head=$(head -c 120 /tmp/jicun-probe.out 2>/dev/null | tr -d '\n')
    case "$http" in
        200|422) mark="OK  " ;;
        *)       mark="!!  " ;;
    esac
    echo "  $mark /parse2/$code ($name) → HTTP $http  $head"
done
rm -f /tmp/jicun-probe.out
echo "  (200/422 都算通;404 = 配置没生效;502 = 本机到上游断;000 = 本机出不去)"
echo

