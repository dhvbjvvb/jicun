#!/bin/bash
# 把 APP 上报的优选 IP 聚合成 /var/www/jicun/ips.json,由 cron 每 10 分钟跑一次。
#
# 为什么排名只能来自客户端:
#   源站在美国,到 Cloudflare 走的是机房直连 —— 握手 2ms、ttfb 70~110ms。
#   国内手机同一条路是 200~350ms。在源站上跑 CloudflareSpeedTest 挑出来的 IP,
#   是「对机房最优」,不是「对用户最优」,两者可以完全不相干。
#
# 那源站能不能当健康检查用?不能。实测:源站连 103.21.244.207 直接超时,
# 而这个 IP 从国内客户端测是最好的之一。源站到某个 anycast 地址的路由坏掉,
# 跟用户的请求没有任何关系 —— 拿它当过滤器只会把好 IP 扔掉。
#
# 真正的过滤器是上报本身:APP 只有在某个 IP 上完成了针对 mxper.cc.cd 的
# 合法 TLS 握手(证书校验通过)才会把它选为赢家并上报。所以「被上报过」
# 就等于「刚刚真的能用」。
#
# 输出两档:
#   tier1 至少 MIN_REPORTS 个客户端上报过的 —— 按上报次数排,次数相同看平均耗时
#   tier2 种子列表顶上 —— 上报量还不够时,列表主要还是它
#
# 发布节奏(cron 每 10 分钟)跟统计窗口是两回事。上报日志不按时间清,而是按行数
# 轮转:统计只取最近 WINDOW_LINES 条,日志攒到 MAX_LOG_LINES 行才挪走重开。
# 这样每跑一次不会把样本窗口截短,用户少的时候也能凑够票数。
#
# 用法:cron 调用,或手动 bash jicun-cfip.sh 立刻重算一次。
set -u

REPORT_LOG=/var/log/nginx/jicun-cfip.log
OUT=/var/www/jicun/ips.json

MAX_IPS=12        # 下发多少条
MAX_REPORTED=20   # 聚合时最多考虑多少个上报过的 IP
MIN_REPORTS=2     # 至少几个客户端上报过才敢让它排到种子前面
MIN_MS=10         # 低于这个的耗时当异常值丢掉(时钟问题)
MAX_MS=5000       # 高于这个的当没测出来
WINDOW_LINES=300  # 统计只看最近这么多条上报
MAX_LOG_LINES=1000 # 日志攒到这个行数才轮转(约 100 KB 封顶)

# 种子:国内线路上用 CloudflareSpeedTest 实测出来的候选,按延迟从低到高。
# 更新办法见 lib/preferred_ip.dart 文件头。
SEED="173.245.49.168 104.16.78.124 173.245.49.9 103.21.244.207 103.21.244.156 188.114.96.62 104.21.76.47 172.67.187.175 104.27.61.170 172.64.185.27"

log() { echo "[$(date -Is)] $*"; }

# 把上报日志算成「按可信度排序的 IP 列表」。
# 日志行由 nginx 的 jicun_cfip 格式写出,形如:
#   1.2.3.4 - [2026-09-17T13:40:00+00:00] ip=104.16.78.124 ms=248
# 字段名 ip=/ms= 是跟 nginx 那边的接口契约,改一边要同步改另一边。
#
# 只取最近 WINDOW_LINES 条:日志本身最多留 MAX_LOG_LINES 行,所以这个窗口
# 是「最近若干次上报」而不是「最近若干分钟」—— 用户少的时候窗口自动拉长。
reported=""
if [ -s "$REPORT_LOG" ]; then
    reported=$(tail -n "$WINDOW_LINES" "$REPORT_LOG" | awk -v lo="$MIN_MS" -v hi="$MAX_MS" -v need="$MIN_REPORTS" '
        {
            ip = ""; ms = "";
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^ip=/) { split($i, a, "="); ip = a[2] }
                if ($i ~ /^ms=/) { split($i, b, "="); ms = b[2] }
            }
            # 这个端点是公开的,谁都能往里灌东西。只认长得像 IP 的。
            if (ip !~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) next
            if (ms + 0 < lo || ms + 0 > hi) next
            count[ip]++
            total[ip] += ms
        }
        END {
            for (ip in count) {
                if (count[ip] < need) continue
                printf "%d %.0f %s\n", count[ip], total[ip] / count[ip], ip
            }
        }
    ' "$REPORT_LOG" | sort -k1,1nr -k2,2n | awk -v cap="$MAX_REPORTED" 'NR <= cap { print $3 }')
fi

ordered=""
add() {
    case " $ordered " in *" $1 "*) return ;; esac
    ordered="$ordered $1"
}

for ip in $reported; do
    [ "$(echo $ordered | wc -w)" -ge "$MAX_IPS" ] && break
    add "$ip"
done
for ip in $SEED; do
    [ "$(echo $ordered | wc -w)" -ge "$MAX_IPS" ] && break
    add "$ip"
done

if [ -z "$(echo $ordered)" ]; then
    # 一个都没有:宁可让 APP 继续用内置池,也不要下发一份空列表把它清空。
    log "没有任何可用 IP,保留上一份 $OUT 不动"
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
chmod 755 "$(dirname "$OUT")"
tmp=$(mktemp)
# 中途挂掉(磁盘满、被 kill)也不留垃圾:这个目录是 /tmp,攒多了没人清。
trap 'rm -f "$tmp"' EXIT
{
    printf '{"updated":"%s","ips":[' "$(date -Is)"
    first=1
    for ip in $ordered; do
        [ "$first" -eq 1 ] || printf ','
        printf '"%s"' "$ip"
        first=0
    done
    printf ']}\n'
} > "$tmp"
# mktemp 建出来是 600,nginx 以 www-data 跑,读不了就是 403。必须放开。
chmod 644 "$tmp"
mv "$tmp" "$OUT"

log "上报 $(echo $reported | wc -w) 个 / 已下发 $(echo $ordered | wc -w) 个:$(echo $ordered | tr ' ' ',')"

# 上报日志攒够了才挑走,不是每跑一次就清。10 分钟一轮的话,每轮都清会把
# 统计窗口也砍成 10 分钟,用户少的时候一个窗口里凑不齐票。
#
# 挪走再让 nginx 重开,不能直接 truncate —— nginx 拿着 fd 和偏移量,
# 截断之后会写出一堆空洞。
if [ -s "$REPORT_LOG" ] && [ "$(wc -l < "$REPORT_LOG")" -gt "$MAX_LOG_LINES" ]; then
    mv "$REPORT_LOG" "$REPORT_LOG.old"
    nginx -s reopen 2>/dev/null || true
    rm -f "$REPORT_LOG.old"
    log "上报日志已轮转(超过 $MAX_LOG_LINES 行)"
fi
