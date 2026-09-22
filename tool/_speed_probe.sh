#!/system/bin/sh
# 下载测速:分别量原画(8K/34.7Mbps)、720P、540P 三条流在手机这条网络上的真实吞吐。
# 每档取 8MB,顺带看服务端认不认 Range(分段下载的前提)。

probe() {
  name="$1"
  url="$2"
  mb="$3"
  end=$(( mb * 1024 * 1024 - 1 ))
  out=$(curl -s -m 90 -o /dev/null \
      -H "Range: bytes=0-${end}" \
      -w "%{http_code} %{size_download} %{time_total} %{speed_download}" \
      "$url" 2>&1)
  echo "$name $out"
}

echo "name http_code bytes seconds bytes_per_sec"
probe "orig8k" "$(cat /data/local/tmp/u_orig.txt)" 8
probe "720p"   "$(cat /data/local/tmp/u_720.txt)" 8
probe "540p"   "$(cat /data/local/tmp/u_540.txt)" 8
