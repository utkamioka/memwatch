#!/bin/bash
# =============================================================================
# memwatch.sh - Linux 用 メモリリーク監視ツール (Bash + 標準コマンドのみ)
#
#   collect : システムの空きメモリと対象プロセスのメモリ使用量を CSV に1行追記
#             (crontab から定期実行する想定)
#   graph   : CSV から増加傾向 (MB/時) を計算し、グラフ (SVG 埋め込み HTML) を出力
#
# 使い方:
#   memwatch.sh collect [対象] [--csv PATH] [-v]
#       対象 (いずれか1つ。省略時はシステム全体のみ記録)
#         --service NAME   systemd サービス (cgroup 内の全プロセス＝子プロセスも合算)
#         --name NAME      プロセス名 (comm 完全一致) のプロセスを合算
#         --cmdline TEXT   コマンドラインに TEXT を含むプロセスを合算
#         --pidfile PATH   PID ファイル
#         --pid PID        PID 直接指定
#       --csv PATH  出力先 (既定: /var/log/memwatch/memwatch.csv)
#                   date の書式可 (例: /var/log/memwatch/app_%Y%m%d.csv で日別)
#
#   memwatch.sh graph [--csv FILE...] [-o OUT.html] [--hours N]
#                     [--warn-mb-per-hour N] [--min-hours N] [--min-r2 N]
#       --csv FILE...          入力 CSV (複数・ワイルドカード可)
#       -o OUT.html            出力 HTML (既定: /var/log/memwatch/memwatch.html, "" で出力なし)
#       --hours N              直近 N 時間だけを対象
#       --warn-mb-per-hour N   RSS 増加率が N MB/時 を超えたら警告 (stderr + syslog, 終了コード 2)
#       --min-hours N          警告判定に必要な最低観測時間 (既定: 2)
#       --min-r2 N             警告判定に必要な R^2 (既定: 0.6)
#
# 使用コマンド: bash awk sort date flock find grep sed ps pgrep systemctl logger
# =============================================================================

set -u
export LC_ALL=C   # 小数点・ソート順を固定

HEADER="timestamp,epoch,mem_total_kb,mem_free_kb,mem_available_kb,buffers_kb,cached_kb,swap_total_kb,swap_free_kb,target,status,main_pid,pids,nproc,rss_kb,pss_kb,rss_anon_kb,vmsize_kb,vmswap_kb,threads,fds"

die() { echo "memwatch: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 対象プロセスの検索 (結果は PIDS / MAIN_PID に設定)
# -----------------------------------------------------------------------------
sysprop() {  # RHEL7 の systemd は --value 非対応のため sed で取り出す
    systemctl show -p "$2" "$1" 2>/dev/null | sed -n "s/^$2=//p"
}

find_service() {
    local unit=$1 cg base
    [[ $unit == *.* ]] || unit=$unit.service
    MAIN_PID=$(sysprop "$unit" MainPID)
    [[ $MAIN_PID =~ ^[0-9]+$ && $MAIN_PID -gt 0 ]] || MAIN_PID=""
    PIDS=""
    cg=$(sysprop "$unit" ControlGroup)
    if [[ -n $cg ]]; then
        # cgroup v2 / v1(systemd) / hybrid。子 cgroup の分も含める
        for base in /sys/fs/cgroup /sys/fs/cgroup/systemd /sys/fs/cgroup/unified; do
            if [[ -f $base$cg/cgroup.procs ]]; then
                PIDS=$(find "$base$cg" -name cgroup.procs -exec cat {} + 2>/dev/null)
                break
            fi
        done
    fi
    PIDS=$(printf '%s\n' $PIDS $MAIN_PID | sort -un)
}

oldest_pid() {  # 起動が最も古いプロセス = メインとみなす
    [[ -n $1 ]] || return
    ps -o pid= --sort=start_time -p "$(echo $1 | tr ' ' ',')" 2>/dev/null | head -n1 | tr -d ' '
}

find_name() {
    PIDS=$(pgrep -x -- "${1:0:15}")   # comm は15文字で切り詰められる
    MAIN_PID=$(oldest_pid "$PIDS")
}

find_cmdline() {
    local p list=""
    for p in $(pgrep -f -- "$1"); do
        [[ $p == "$$" ]] && continue
        # 自分自身 (cron 経由の bash -c 含む) を除外
        grep -qa memwatch "/proc/$p/cmdline" 2>/dev/null && continue
        list+="$p "
    done
    PIDS=$list
    MAIN_PID=$(oldest_pid "$PIDS")
}

find_pidfile() {
    local p=""
    PIDS=""; MAIN_PID=""
    [[ -r $1 ]] && read -r p _ < "$1"
    if [[ $p =~ ^[0-9]+$ && -d /proc/$p ]]; then PIDS=$p; MAIN_PID=$p; fi
}

find_pid() {
    PIDS=""; MAIN_PID=""
    if [[ $1 =~ ^[0-9]+$ && -d /proc/$1 ]]; then PIDS=$1; MAIN_PID=$1; fi
}

# -----------------------------------------------------------------------------
# collect
# -----------------------------------------------------------------------------
collect() {
    local mode="" arg="" csv="/var/log/memwatch/memwatch.csv" verbose=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            --service|--name|--cmdline|--pidfile|--pid)
                [[ -n $mode ]] && die "対象の指定は1つだけにしてください"
                [[ $# -ge 2 ]] || die "$1 に値がありません"
                mode=${1#--}; arg=$2; shift 2 ;;
            --csv) [[ $# -ge 2 ]] || die "--csv に値がありません"; csv=$2; shift 2 ;;
            -v|--verbose) verbose=1; shift ;;
            *) die "不明なオプション: $1" ;;
        esac
    done

    local epoch ts sysmem
    epoch=$(date +%s)
    ts=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S')
    sysmem=$(awk '
        /^MemTotal:/{t=$2} /^MemFree:/{f=$2} /^MemAvailable:/{a=$2}
        /^Buffers:/{b=$2} /^Cached:/{c=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
        END{printf "%s,%s,%s,%s,%s,%s,%s", t, f, a, b, c, st, sf}' /proc/meminfo)

    PIDS=""; MAIN_PID=""
    case $mode in
        service) find_service "$arg" ;;
        name)    find_name "$arg" ;;
        cmdline) find_cmdline "$arg" ;;
        pidfile) find_pidfile "$arg" ;;
        pid)     find_pid "$arg" ;;
    esac

    local target=${arg//,/_} status="SYSTEM_ONLY" proc=",,,,,,,,,"
    local p s r a v w t x alive="" nalive=0
    local rss=0 pss=0 anon=0 vsz=0 swp=0 thr=0 fds=0 pss_ok=1 fd_ok=1
    [[ -z $mode ]] && target=""
    if [[ -n $mode ]]; then
        status="NOT_FOUND"
        for p in $PIDS; do
            s=$(awk '/^VmRSS:/{r=$2} /^RssAnon:/{a=$2} /^VmSize:/{v=$2}
                     /^VmSwap:/{w=$2} /^Threads:/{t=$2}
                     END{if (r != "") print r+0, a+0, v+0, w+0, t+0}' \
                "/proc/$p/status" 2>/dev/null)
            [[ -n $s ]] || continue          # 終了済み / カーネルスレッド / ゾンビ
            read -r r a v w t <<< "$s"
            alive+="${alive:+ }$p"; nalive=$((nalive + 1))
            rss=$((rss + r)); anon=$((anon + a)); vsz=$((vsz + v))
            swp=$((swp + w)); thr=$((thr + t))
            x=$(awk '/^Pss:/{print $2; exit}' "/proc/$p/smaps_rollup" 2>/dev/null)
            if [[ -n $x ]]; then pss=$((pss + x)); else pss_ok=0; fi
            if x=$(ls -U "/proc/$p/fd" 2>/dev/null); then
                fds=$((fds + $(printf '%s' "$x" | grep -c .)))
            else
                fd_ok=0                       # 権限不足 (root で実行してください)
            fi
        done
        if (( nalive > 0 )); then
            status="OK"
            [[ " $alive " == *" $MAIN_PID "* ]] || MAIN_PID=${alive%% *}
            (( pss_ok )) || pss=""
            (( fd_ok ))  || fds=""
            proc="$MAIN_PID,${alive// /;},$nalive,$rss,$pss,$anon,$vsz,$swp,$thr,$fds"
        fi
    fi

    local row="$ts,$epoch,$sysmem,$target,$status,$proc"
    local out
    out=$(date -d "@$epoch" +"$csv")
    mkdir -p "$(dirname "$out")" || die "ディレクトリを作成できません: $(dirname "$out")"
    {
        flock -x 9
        [[ -s $out ]] || printf '%s\n' "$HEADER" >&9
        printf '%s\n' "$row" >&9
    } 9>> "$out"

    (( verbose )) && echo "$ts ${target:-system} status=$status rss=$( [[ $status == OK ]] && echo "${rss}kB" || echo - ) -> $out"
    return 0
}

# -----------------------------------------------------------------------------
# graph (解析と HTML 生成は awk で実施)
# -----------------------------------------------------------------------------
read -r -d '' AWK_GRAPH <<'AWK'
function floor_(x) { return (x == int(x)) ? x : (x < 0 ? int(x) - 1 : int(x)) }
function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
function setv(k, i, v, d) { if (v != "") V[k SUBSEP i] = v / d }
function fmtn(v,   av) {
    v = sprintf("%.6g", v) + 0; av = (v < 0) ? -v : v
    if (v == int(v)) return sprintf("%d", v)
    return (av >= 1) ? sprintf("%.1f", v) : sprintf("%.2f", v)
}
function X(e) { return CL + (e - CT0) / (CT1 - CT0) * CPW }
function Y(v) { return CT + (CHI - v) / (CHI - CLO) * CPH }

function niceticks(lo, hi,   span, raw, mag, step, M, k, v) {
    span = hi - lo; if (span <= 0) span = 1
    raw = span / 5; mag = 10 ^ floor_(log(raw) / log(10))
    split("1 2 2.5 5 10", M, " ")
    for (k = 1; k <= 5; k++) { step = M[k] * mag; if (raw <= step * 1.000001) break }
    NT = 0; v = floor_(lo / step) * step
    while (NT < 100) { TK[++NT] = v; if (v >= hi - step * 1e-6) break; v += step }
}

function legend(x, label, color, dash) {
    return sprintf("<line x1=\"%.1f\" y1=\"16\" x2=\"%.1f\" y2=\"16\" stroke=\"%s\" stroke-width=\"2\"%s/>\n<text x=\"%.1f\" y=\"20\" class=\"legend\">%s</text>\n",
        x, x + 18, color, dash ? " stroke-dasharray=\"5,3\"" : "", x + 22, esc(label))
}
function poly(pts, color) {
    return sprintf("<polyline points=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"1.5\"/>\n", pts, color)
}

# spec: "キー|ラベル|色[|nz]" を ; 区切り (nz = 全て0なら非表示)
function chart(title, ylabel, h, spec, trend, spans,
               w, B, R, ns, S, P, k, m, SK, SL, SC, has, nz, i, j, v, first, lo, hi,
               o, lx, span, e, x, y, bi, best, d, lab, anchor, pts, r, tb) {
    w = 1100; CL = 70; R = 20; CT = 34; B = 42; CPW = w - CL - R; CPH = h - CT - B
    ns = split(spec, S, ";"); m = 0
    for (k = 1; k <= ns; k++) {
        split(S[k], P, "|"); has = 0; nz = 0
        for (i = s0; i <= n; i++) if ((P[1] SUBSEP i) in V) { has = 1; if (V[P[1] SUBSEP i] != 0) nz = 1 }
        if (!has || (P[4] == "nz" && !nz)) continue
        m++; SK[m] = P[1]; SL[m] = P[2]; SC[m] = P[3]
    }
    if (m == 0) return ""
    trend = trend && HASTR
    first = 1
    for (k = 1; k <= m; k++) for (i = s0; i <= n; i++) if ((SK[k] SUBSEP i) in V) {
        v = V[SK[k] SUBSEP i]
        if (first || v < lo) lo = v
        if (first || v > hi) hi = v
        first = 0
    }
    if (trend) {
        tb = TRB + TRS * SEGH
        if (TRB < lo) lo = TRB; if (TRB > hi) hi = TRB
        if (tb < lo) lo = tb;   if (tb > hi) hi = tb
    }
    if (lo == hi) { lo -= 1; hi += 1 }
    niceticks(lo, hi)
    CLO = (TK[1] < lo) ? TK[1] : lo; CHI = (TK[NT] > hi) ? TK[NT] : hi
    CT0 = E[s0]; CT1 = E[n]; if (CT1 == CT0) CT1 = CT0 + 1

    o = sprintf("<svg viewBox=\"0 0 %d %d\" xmlns=\"http://www.w3.org/2000/svg\" class=\"chart\">\n", w, h)
    o = o sprintf("<text x=\"%d\" y=\"20\" class=\"title\">%s</text>\n", CL, esc(title))
    lx = w - R
    if (trend) { lx -= length(TRLABEL) * 6.5 + 28; o = o legend(lx, TRLABEL, "#000", 1) }
    for (k = m; k >= 1; k--) { lx -= length(SL[k]) * 6.5 + 28; o = o legend(lx, SL[k], SC[k], 0) }

    if (spans) for (i = s0; i <= n; i++) if (ST[i] == "NOT_FOUND") {
        j = (i < n) ? i + 1 : i; x = X(E[j]) - X(E[i]); if (x < 1) x = 1
        o = o sprintf("<rect x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\" fill=\"#e33\" opacity=\"0.1\"/>\n", X(E[i]), CT, x, CPH)
    }
    for (k = 1; k <= NT; k++) {
        y = Y(TK[k])
        o = o sprintf("<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" class=\"grid\"/>\n", CL, y, CL + CPW, y)
        o = o sprintf("<text x=\"%d\" y=\"%.1f\" class=\"ytick\">%s</text>\n", CL - 6, y + 4, fmtn(TK[k]))
    }
    o = o sprintf("<text transform=\"translate(16,%d) rotate(-90)\" class=\"ylabel\">%s</text>\n", CT + int(CPH / 2), esc(ylabel))

    # X 軸: 目盛り位置に最も近いサンプルの時刻を表示 (strftime 不要)
    span = CT1 - CT0
    for (k = 0; k <= 8; k++) {
        e = CT0 + span * k / 8; x = X(e)
        bi = s0; best = -1
        for (i = s0; i <= n; i++) {
            d = E[i] - e; if (d < 0) d = -d
            if (best < 0 || d < best) { best = d; bi = i } else if (E[i] > e) break
        }
        if (span > 86400) lab = substr(TS[bi], 6, 11)
        else if (span < 600) lab = substr(TS[bi], 12, 8)
        else lab = substr(TS[bi], 12, 5)
        anchor = (k == 0) ? "start" : ((k == 8) ? "end" : "middle")
        o = o sprintf("<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" class=\"grid\"/>\n", x, CT, x, CT + CPH)
        o = o sprintf("<text x=\"%.1f\" y=\"%d\" class=\"xtick\" text-anchor=\"%s\">%s</text>\n", x, CT + CPH + 16, anchor, lab)
    }
    o = o sprintf("<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" class=\"frame\"/>\n", CL, CT, CPW, CPH)

    for (k = 1; k <= m; k++) {           # 欠損値のところで線を切る
        pts = ""
        for (i = s0; i <= n; i++) {
            if ((SK[k] SUBSEP i) in V) pts = pts sprintf("%.1f,%.1f ", X(E[i]), Y(V[SK[k] SUBSEP i]))
            else if (pts != "") { o = o poly(pts, SC[k]); pts = "" }
        }
        if (pts != "") o = o poly(pts, SC[k])
    }
    for (r = 1; r <= NR_; r++)
        o = o sprintf("<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"#e00\" stroke-dasharray=\"2,3\"/>\n", X(E[RSI[r]]), CT, X(E[RSI[r]]), CT + CPH)
    if (trend)
        o = o sprintf("<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#000\" stroke-width=\"1.2\" stroke-dasharray=\"6,4\"/>\n",
                      X(E[seg]), Y(TRB), X(E[n]), Y(tb))
    return o "</svg>\n"
}

# 最小二乗法 (x: 区間開始からの時間[h], y: MB) → LS 傾き / LB 切片 / LR2 決定係数
function linreg(k,   i, c, x, y, mx, my, sxx, syy, sxy) {
    c = 0; mx = 0; my = 0
    for (i = seg; i <= n; i++) if ((k SUBSEP i) in V) { c++; mx += (E[i] - E[seg]) / 3600; my += V[k SUBSEP i] }
    if (c < 3) return 0
    mx /= c; my /= c; sxx = syy = sxy = 0
    for (i = seg; i <= n; i++) if ((k SUBSEP i) in V) {
        x = (E[i] - E[seg]) / 3600 - mx; y = V[k SUBSEP i] - my
        sxx += x * x; syy += y * y; sxy += x * y
    }
    if (sxx == 0) return 0
    LS[k] = sxy / sxx; LB[k] = my - LS[k] * mx
    LR2[k] = (syy > 0) ? sxy * sxy / (sxx * syy) : 1
    return 1
}

BEGIN { FS = ","; n = 0 }
/^timestamp,/ { for (i = 1; i <= NF; i++) col[$i] = i; next }
{
    if ($(col["epoch"]) == "") next
    n++
    E[n] = $(col["epoch"]) + 0; TS[n] = $(col["timestamp"])
    TG[n] = $(col["target"]); ST[n] = $(col["status"]); MP[n] = $(col["main_pid"]); NP[n] = $(col["nproc"])
    setv("avail", n, $(col["mem_available_kb"]), 1024)
    setv("free",  n, $(col["mem_free_kb"]), 1024)
    if ($(col["swap_total_kb"]) != "" && $(col["swap_free_kb"]) != "")
        V["swapu" SUBSEP n] = ($(col["swap_total_kb"]) - $(col["swap_free_kb"])) / 1024
    setv("rss",    n, $(col["rss_kb"]), 1024)
    setv("pss",    n, $(col["pss_kb"]), 1024)
    setv("anon",   n, $(col["rss_anon_kb"]), 1024)
    setv("vmswap", n, $(col["vmswap_kb"]), 1024)
    setv("nproc",  n, $(col["nproc"]), 1)
    setv("thr",    n, $(col["threads"]), 1)
    setv("fds",    n, $(col["fds"]), 1)
}
END {
    s0 = 1
    if (HOURS != "") { for (i = 1; i <= n; i++) if (E[i] >= E[n] - HOURS * 3600) { s0 = i; break } }
    if (n - s0 + 1 < 2) { print "データが不足しています (" (n - s0 + 1) " 行)" > "/dev/stderr"; exit 1 }

    # 再起動検出 (main_pid の変化)。傾向は最後の再起動以降で計算
    seg = s0; NR_ = 0; prev = ""
    for (i = s0; i <= n; i++) if (MP[i] != "") {
        if (prev != "" && MP[i] != prev) { RSI[++NR_] = i; seg = i }
        prev = MP[i]
    }
    SEGH = (E[n] - E[seg]) / 3600
    tg = ""; for (i = n; i >= s0; i--) if (TG[i] != "") { tg = TG[i]; break }
    anyok = 0; for (i = s0; i <= n; i++) if (ST[i] == "OK") { anyok = 1; break }

    SUM = sprintf("対象: %s  期間: %s ～ %s (%d サンプル)\n", (tg == "" ? "(system)" : tg), TS[s0], TS[n], n - s0 + 1)
    SUM = SUM sprintf("再起動検出: %d 回 / 傾向計算区間: 直近 %.1f 時間\n", NR_, SEGH)
    split("rss pss avail", K, " "); split("RSS PSS MemAvailable", KL, " ")
    for (k = 1; k <= 3; k++) if (linreg(K[k]))
        SUM = SUM sprintf("  %-13s %+9.3f MB/時  (%+8.1f MB/日, R^2=%.2f)\n", KL[k], LS[K[k]], LS[K[k]] * 24, LR2[K[k]])
    printf "%s", SUM

    HASTR = ("rss" in LS)
    if (HASTR) { TRS = LS["rss"]; TRB = LB["rss"]; TRLABEL = sprintf("RSS trend %+.2f MB/h", TRS) }

    if (WARN != "" && HASTR && SEGH >= MINH + 0 && LR2["rss"] >= MINR2 + 0 && TRS > WARN + 0)
        printf "@@WARN@@ memory leak suspected: %s RSS %+.2f MB/h (R2=%.2f, %.1f h)\n", tg, TRS, LR2["rss"], SEGH

    if (OUT == "") exit 0
    charts = chart("System memory", "MB", 280, "avail|MemAvailable|#1f77b4;free|MemFree|#ff7f0e;swapu|Swap used|#9467bd|nz", 0, 0)
    if (anyok) {
        charts = charts chart(sprintf("Target process memory (%s process(es))", (NP[n] == "" ? "?" : NP[n])), "MB", 280,
                              "rss|RSS|#1f77b4;pss|PSS|#ff7f0e;anon|RssAnon|#2ca02c;vmswap|Swap|#d62728|nz", 1, 1)
        charts = charts chart("Processes / Threads", "count", 220, "nproc|Processes|#8c564b;thr|Threads|#9467bd", 0, 1)
        charts = charts chart("Open file descriptors", "count", 220, "fds|FDs|#17becf", 0, 1)
    }
    printf "<!DOCTYPE html>\n<html lang=\"ja\"><head><meta charset=\"utf-8\">\n<title>memwatch - %s</title>\n", esc(tg == "" ? "system" : tg) > OUT
    print "<style>\nbody{font-family:sans-serif;margin:16px;background:#fff;color:#222}\nh1{font-size:18px}\npre{background:#f4f4f4;padding:10px;font-size:13px}\n.chart{width:100%;max-width:1100px;display:block;margin:8px 0 16px}\n.chart .title{font-size:14px;font-weight:bold}\n.chart .legend{font-size:11px}\n.chart .grid{stroke:#ddd;stroke-width:1}\n.chart .frame{fill:none;stroke:#999}\n.chart .ytick{font-size:11px;text-anchor:end;fill:#555}\n.chart .xtick{font-size:11px;fill:#555}\n.chart .ylabel{font-size:11px;text-anchor:middle;fill:#555}\n.note{font-size:12px;color:#666}\n</style></head><body>" > OUT
    printf "<h1>メモリ監視: %s</h1>\n<pre>%s</pre>\n", esc(tg == "" ? "system" : tg), esc(SUM) > OUT
    printf "<p class=\"note\">赤い点線: 再起動 / 赤い網掛け: プロセス未検出 / 黒い破線: 最新区間の RSS 増加傾向 &nbsp; 生成: %s</p>\n", NOW > OUT
    printf "%s</body></html>\n", charts > OUT
    close(OUT)
}
AWK

graph() {
    local out="/var/log/memwatch/memwatch.html" hours="" warn="" minh=2 minr2=0.6
    local pats=() files=() pat f
    while [[ $# -gt 0 ]]; do
        case $1 in
            --csv) shift; while [[ $# -gt 0 && $1 != -* ]]; do pats+=("$1"); shift; done ;;
            -o|--output) out=${2-}; shift 2 ;;
            --hours) hours=${2:?}; shift 2 ;;
            --warn-mb-per-hour) warn=${2:?}; shift 2 ;;
            --min-hours) minh=${2:?}; shift 2 ;;
            --min-r2) minr2=${2:?}; shift 2 ;;
            *) die "不明なオプション: $1" ;;
        esac
    done
    [[ ${#pats[@]} -gt 0 ]] || pats=("/var/log/memwatch/memwatch.csv")
    for pat in "${pats[@]}"; do
        for f in $pat; do [[ -f $f ]] && files+=("$f"); done   # ワイルドカード展開
    done
    [[ ${#files[@]} -gt 0 ]] || die "CSV が見つかりません: ${pats[*]}"

    local tmp="" res rc warnmsg
    [[ -n $out ]] && { mkdir -p "$(dirname "$out")"; tmp="$out.tmp"; }
    res=$(
        { echo "$HEADER"; cat "${files[@]}" | grep -v '^timestamp,' | sort -t, -k2,2n; } |
        awk -v OUT="$tmp" -v HOURS="$hours" -v WARN="$warn" -v MINH="$minh" \
            -v MINR2="$minr2" -v NOW="$(date '+%Y-%m-%d %H:%M:%S')" "$AWK_GRAPH"
    )
    rc=$?
    [[ -n $res ]] && printf '%s\n' "$res" | grep -v '^@@WARN@@'
    (( rc == 0 )) || { rm -f "$tmp"; return "$rc"; }
    if [[ -n $tmp && -f $tmp ]]; then
        mv -f "$tmp" "$out" && echo "グラフ出力: $out"
    fi
    warnmsg=$(printf '%s\n' "$res" | sed -n 's/^@@WARN@@ //p')
    if [[ -n $warnmsg ]]; then
        echo "WARNING: $warnmsg" >&2
        logger -t memwatch -p user.warning -- "$warnmsg" 2>/dev/null
        return 2
    fi
    return 0
}

# -----------------------------------------------------------------------------
case ${1-} in
    collect) shift; collect "$@" ;;
    graph)   shift; graph "$@" ;;
    *) sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
