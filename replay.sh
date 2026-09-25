#!/system/bin/sh
# icbc_daily_water / replay.sh v0.9.6  动作回放内核
# 读 profiles/<name>/actions.rx (record.sh 产物), 按记录时序逐动作 sendevent 注入
# 用法: replay.sh PROFILE [LOGFILE]
M=/data/adb/modules/icbc_daily_water
BASE=/data/adb/icbc_water
PFX=$BASE/profiles
LOGF=$M/log.txt
[ -n "$2" ] && LOGF=$2

# ---------- 设备/注入原语 (与 service.sh 同源, 缩放 K 与 record.sh 一致) ----------
discdev() {
  TDEV=; BDEV=; PDEV=
  for e in /dev/input/event*; do
    P=$(getevent -p $e 2>/dev/null)
    case "$P" in *Xiaomi_Touch_Input_0*) [ -z "$TDEV" ] && TDEV=$e;; esac
    case "$P" in *'009e'*) [ -z "$BDEV" ] && BDEV=$e;; esac
    case "$P" in *'0074'*) [ -z "$PDEV" ] && PDEV=$e;; esac
  done
  [ -z "$TDEV" ] && TDEV=/dev/input/event8
}
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
if [ -f $M/dev.conf ] && grep -q "BID=$BID" $M/dev.conf 2>/dev/null; then
  . $M/dev.conf 2>/dev/null
fi
if [ -n "$TDEV" ] && [ -e "$TDEV" ]; then
  case "$TDEV" in
    /dev/input/*)
      case "$(getevent -p $TDEV 2>/dev/null)" in
        *Xiaomi_Touch_Input_0*) ;;
        *) TDEV=;;
      esac
      ;;
  esac
else
  TDEV=
fi
if [ -z "$TDEV" ] || [ ! -e "$TDEV" ]; then
  discdev
  { echo "BID=$BID"; echo "TDEV=$TDEV"; echo "BDEV=$BDEV"; echo "PDEV=$PDEV"; } > $M/dev.conf 2>/dev/null
fi
# 没有可确认的触摸设备时必须失败，不能让 sendevent 报错后仍标记回放成功。
case "$TDEV" in
  /dev/input/*) case "$(getevent -p "$TDEV" 2>/dev/null)" in *Xiaomi_Touch_Input_0*) ;; *) echo "ERR touch device unavailable" >&2; exit 2;; esac;;
  *) echo "ERR touch device unavailable" >&2; exit 2;;
esac

# 缩放 K = 轴max / 屏宽 (与 record.sh 相同推导; 缺省 100)
K=100
SW=$(sed -n 's/^SW=\([0-9][0-9]*\).*/\1/p' $M/water.sh 2>/dev/null | head -1)
case "$SW" in ''|*[!0-9]*) SW=1220;; esac
if [ -n "$TDEV" ] && [ -e "$TDEV" ]; then
  P=$(getevent -p $TDEV 2>/dev/null)
  # 只从 0035: 的轴明细行取 max，避免命中 ABS 摘要行。
  MX=$(printf '%s\n' "$P" | grep -A2 -m1 -E 'ABS_MT_POSITION_X|(^|[[:space:]])0035[[:space:]]*:' | grep -m1 'max' | sed -E 's/.*max[^0-9]*([0-9]+).*/\1/')
  case "$MX" in ''|*[!0-9]*) MX=;; esac
  if [ -n "$MX" ] && [ "$MX" -gt 20000 ] 2>/dev/null; then
    K=$(( MX / SW ))
    [ $K -lt 1 ] && K=100
  fi
fi

sleep_ms() {  # 毫秒级等待，兼容 Android toybox 的小数 sleep
  MS=${1:-0}
  case "$MS" in ''|*[!0-9]*) return 0;; esac
  [ "$MS" -le 0 ] 2>/dev/null && return 0
  SEC=$(( MS / 1000 ))
  REM=$(( MS % 1000 ))
  [ "$SEC" -gt 0 ] && sleep "$SEC"
  [ "$REM" -gt 0 ] && sleep "0.$(printf '%03d' "$REM")"
}

coordok() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  return 0
}

pointsok() {  # 剩余参数必须是完整的非负整数 x/y 对
  [ "$#" -ge 2 ] 2>/dev/null || return 1
  while [ "$#" -ge 2 ]; do
    coordok "$1" || return 1
    coordok "$2" || return 1
    shift 2
  done
  [ "$#" -eq 0 ]
}

stap() {  # 点按: tap x y
  # Xiaomi/HyperOS 的旧版注入帧序在 v0.9.4 真机上已验证。
  # 保留 BTN_TOUCH 之前的 slot/坐标/压力字段，避免部分 HyperOS 输入栈
  # 把仅带 BTN_TOOL_FINGER 的新帧序解释成不同的 Y 映射。
  sendevent $TDEV 3 47 0
  sendevent $TDEV 3 57 1
  sendevent $TDEV 3 53 $(( $1 * K ))
  sendevent $TDEV 3 54 $(( $2 * K ))
  sendevent $TDEV 3 48 20
  sendevent $TDEV 3 49 20
  sendevent $TDEV 1 330 1
  sendevent $TDEV 0 0 0
  sleep 0.15
  sendevent $TDEV 3 57 -1
  sendevent $TDEV 1 330 0
  sendevent $TDEV 0 0 0
}

# 折线滑动: sswp DUR x1 y1 [x2 y2 ...]   DUR=录制时该滑动真实耗时ms (0=未知)
# 逐点直注 + 按 DUR 摊薄节奏: 记录点本身已按 >=10px 位移采样, 直注即保原轨迹;
# 不做 12 步插值(那会把一个 300ms 侧滑拖成数秒, 系统只当页面拖拽, 边缘返回不触发)。
# 边缘返回/切页等手势靠"快速 fling"识别, 速度必须贴近录制时。
sswp() {
  DUR=${1:-0}
  shift
  P="$1 $2"
  shift 2
  while [ $# -ge 2 ]; do P="$P $1 $2"; shift 2; done
  # P 是完整点列 (奇偶成对)
  set -- $P
  NP=$#
  [ "$NP" -lt 2 ] 2>/dev/null && NP=2
  # NP 是坐标字段数, 不是点数; 以点数计算节奏, 避免 2x 点数导致过度扣时
  NPT=$((NP / 2))
  [ "$NPT" -lt 1 ] 2>/dev/null && NPT=1
  # 按下: 第一点 (帧序复刻设备: BTN_TOUCH->BTN_TOOL_FINGER->TRACKING_ID->X->Y->SYN,
  #        tool finger 缺了 SystemUI 手势导航不认, 边缘滑动返回会失效)
  sendevent $TDEV 1 330 1
  sendevent $TDEV 1 325 1
  sendevent $TDEV 3 57 1
  sendevent $TDEV 3 53 $(( $1 * K ))
  sendevent $TDEV 3 54 $(( $2 * K ))
  sendevent $TDEV 0 0 0
  shift 2
  # 节奏: 把 DUR 摊到各采样点(注入本身约 15ms/点, 先扣掉, 余量再 sleep)
  GAP=0
  case "$DUR" in ''|*[!0-9]*) DUR=0;; esac
  if [ "$DUR" -gt 0 ] 2>/dev/null; then
    C=$(( (DUR - NPT * 15) / NPT ))
    [ "$C" -lt 0 ] && C=0
    [ "$C" -gt 60 ] && C=60
    # 只在确有正余量时等待; 避免每个采样点都启动一次零等待
    [ "$C" -gt 0 ] && GAP="0.$(printf '%03d' "$C")"
  fi
  while [ $# -ge 2 ]; do
    sendevent $TDEV 3 53 $(( $1 * K ))
    sendevent $TDEV 3 54 $(( $2 * K ))
    sendevent $TDEV 0 0 0
    shift 2
    [ "$GAP" != "0" ] && [ $# -ge 2 ] && sleep "$GAP"
  done
  # 保留很短的抬手前稳定时间, 但不把快速侧滑拖成慢拖拽
  sleep 0.01
  sendevent $TDEV 3 57 -1
  sendevent $TDEV 1 325 0
  sendevent $TDEV 1 330 0
  sendevent $TDEV 0 0 0
}

# ---------- 回放 ----------
N=$1
[ -n "$N" ] || { echo "ERR profile required"; exit 1; }
RX=$PFX/$N/actions.rx
[ -f "$RX" ] || { echo "ERR no actions.rx for $N"; exit 1; }

# 与录制互斥：锁由 replay.sh 自身持有，异常退出时由 owner PID 判定并清理。
# 若录制仍在运行，宁可跳过本次回放，也不把两路 sendevent 混在一起。
if [ -f "$BASE/rec.pid" ]; then
  RRP=$(cat "$BASE/rec.pid" 2>/dev/null)
  case "$RRP" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$RRP" 2>/dev/null && { echo "ERR recording in progress" >&2; exit 3; };;
  esac
fi
LOCKDIR=$BASE/replay.lock
mkdir -p "$BASE" 2>/dev/null
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  OLD=$(cat "$LOCKDIR/owner" 2>/dev/null)
  case "$OLD" in
    ''|*[!0-9]*) rm -rf "$LOCKDIR" 2>/dev/null;;
    *) kill -0 "$OLD" 2>/dev/null && { echo "ERR replay already running" >&2; exit 3; }; rm -rf "$LOCKDIR" 2>/dev/null;;
  esac
  mkdir "$LOCKDIR" 2>/dev/null || { echo "ERR cannot acquire replay lock" >&2; exit 3; }
fi
echo $$ > "$LOCKDIR/owner" 2>/dev/null
release_lock() { rm -rf "$LOCKDIR" 2>/dev/null; }
trap 'release_lock' 0
trap 'release_lock; exit 143' 1 2 15

echo $(date +%m%d-%H%M) REPLAY_START $N K=$K TDEV=$TDEV SW=$SW MX=${MX:-} >> $LOGF
# 禁止动作坐标中的通配符展开；设备发现已经完成。
set -f
PREV=0
STEP=0
while IFS= read -r line; do
  # 跳过空行/注释
  case "$line" in ''|'#'*) continue;; esac
  MS=$(printf '%s' "$line" | sed -E 's/^W([0-9]+).*/\1/')
  case "$MS" in ''|*[!0-9]*) continue;; esac
  REST=${line#W[0-9]* }
  GOOD=0
  case "$REST" in
    tap\ *)
      set -- $REST
      if [ "$#" -eq 3 ] && coordok "$2" && coordok "$3"; then GOOD=1; fi
      ;;
    sw@*)
      # sw@DUR x1 y1 [x2 y2 ...]  DUR=原始滑动耗时, 用于贴回原速度
      set -- $REST
      RDUR=${1#sw@}   # 剥掉 sw@ 前缀得纯数字
      shift            # 去 sw@DUR
      case "$RDUR" in ''|*[!0-9]*) ;; *) pointsok "$@" && GOOD=1;; esac
      ;;
    sw\ *)
      # 旧格式 sw x1 y1 ... (无DUR), DUR=0
      set -- $REST
      shift
      pointsok "$@" && GOOD=1
      ;;
  esac
  [ "$GOOD" -eq 1 ] || continue
  # 等待相对差 (动作间至少留 0.5s, 防快操作连发导致 app 没跟上点错)
  D=$(( MS - PREV ))
  PREV=$MS
  [ "$D" -lt 500 ] 2>/dev/null && D=500
  if [ "$D" -gt 0 ] 2>/dev/null; then
    sleep_ms "$D"
  fi
  case "$REST" in
    tap\ *)
      set -- $REST
      RX0=$2; RY0=$3
      stap $RX0 $RY0
      STEP=$((STEP+1))
      ;;
    sw@*)
      set -- $REST
      RDUR=${1#sw@}
      shift
      sswp "$RDUR" "$@"
      STEP=$((STEP+1))
      ;;
    sw\ *)
      set -- $REST
      shift
      sswp 0 "$@"
      STEP=$((STEP+1))
      ;;
  esac
done < "$RX"
if [ "$STEP" -eq 0 ]; then
  echo "ERR no valid actions in $RX" >&2
  exit 2
fi
echo $(date +%m%d-%H%M) REPLAY_END $N steps=$STEP >> $LOGF
echo "REPLAY_DONE $N steps=$STEP"