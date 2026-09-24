#!/system/bin/sh
# icbc_daily_water / water.sh v7.6  首点提速 + 首页判定耐心等待(前2次探测不回退, 不抢跑)
# 纯 root 直控: screencap 取屏 + 像素探针判定 + sendevent 注入, 不用无障碍/Xposed/input
echo VER v7.6

# ============ 设备配置区 (每台设备按 README 校准) ============
D=0                          # 显示ID: adb shell dumpsys display 查 mDisplayId, 多数手机为 0
SW=1220                      # 屏幕宽(像素): adb shell wm size
SH=2656                      # 屏幕高(像素)
WORK=/data/local/tmp         # 截图/取证输出目录
SNAP=0                       # 1=留取证截图(便于排查) 0=跳过(更省时)
CHOWN=                       # 取证文件属主 (留空=不 chown)
# ============================================================

RAW=$WORK/zxr.raw
M=/data/adb/modules/icbc_daily_water

L=$M/lock
mkdir $L 2>/dev/null || exit 9
trap 'rmdir $L 2>/dev/null' 0 1 2 15

# ================= 设备发现 (单遍扫描 + boot_id 缓存) =================
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
if [ -z "$TDEV" ] || [ ! -e "$TDEV" ]; then
  discdev
  { echo "BID=$BID"; echo "TDEV=$TDEV"; echo "BDEV=$BDEV"; echo "PDEV=$PDEV"; } > $M/dev.conf 2>/dev/null
fi
echo DEVT TDEV=$TDEV BDEV=$BDEV PDEV=$PDEV

# ================= 注入原语 =================
stap() {
  sendevent $TDEV 3 47 0
  sendevent $TDEV 3 57 1
  sendevent $TDEV 3 53 $(( $1 * 100 ))
  sendevent $TDEV 3 54 $(( $2 * 100 ))
  sendevent $TDEV 3 48 20
  sendevent $TDEV 3 49 20
  sendevent $TDEV 1 330 1
  sendevent $TDEV 0 0 0
  sleep 0.08
  sendevent $TDEV 3 57 -1
  sendevent $TDEV 1 330 0
  sendevent $TDEV 0 0 0
}

sswipe() {
  sendevent $TDEV 3 47 0
  sendevent $TDEV 3 57 1
  sendevent $TDEV 3 53 $(( $1 * 100 ))
  sendevent $TDEV 3 54 $(( $2 * 100 ))
  sendevent $TDEV 3 48 20
  sendevent $TDEV 1 330 1
  sendevent $TDEV 0 0 0
  i=0
  while [ $i -le 10 ]; do
    sendevent $TDEV 3 53 $(( ( $1 + ($3 - $1) * i / 10 ) * 100 ))
    sendevent $TDEV 3 54 $(( ( $2 + ($4 - $2) * i / 10 ) * 100 ))
    sendevent $TDEV 0 0 0
    i=$((i+1))
  done
  sleep 0.1
  sendevent $TDEV 3 57 -1
  sendevent $TDEV 1 330 0
  sendevent $TDEV 0 0 0
}

sback() {
  [ -z "$BDEV" ] && return 1
  sendevent $BDEV 1 158 1
  sendevent $BDEV 0 0 0
  sleep 0.05
  sendevent $BDEV 1 158 0
  sendevent $BDEV 0 0 0
}

# ================= 截图/探针 =================
shot() {
  screencap -d $D $RAW
  echo "SHOT rc=$? sz=$(wc -c < $RAW 2>/dev/null)"
}
snap() {  # snap <tag>  取证留档 (SNAP=0 时跳过)
  [ "$SNAP" = "1" ] || return 0
  screencap -d $D -p $WORK/zx_v75_$1.png 2>/dev/null
  RCN=$?
  [ -n "$CHOWN" ] && chown $CHOWN $WORK/zx_v75_$1.png 2>/dev/null
  echo "SNAP $1 rc=$RCN"
}
PX() { set -- $(dd if=$RAW bs=1 skip=$((12+(($2*$SW+$1)*4))) count=3 2>/dev/null | od -An -tu1 -v); Rv=$1; Gv=$2; Bv=$3; }
DPX() { echo "DPX ($1,$2) RGB=$Rv,$Gv,$Bv"; }
ORANGE() { [ $Rv -gt 200 ] && [ $Gv -gt 90 ] && [ $Gv -lt 190 ] && [ $Bv -lt 140 ]; }
BLUE() { [ $Bv -gt 200 ] && [ $Rv -lt 170 ] && [ $Gv -gt 100 ] && [ $Gv -lt 220 ]; }

# ================= 震动提示 (守护态可靠) =================
buzz() {
  for n in /sys/class/leds/vibrator/activate /sys/class/leds/vibrator/state /sys/class/leds/vibrator/transient; do
    if [ -w "$n" ]; then
      echo 1 > $n 2>/dev/null
      sleep 0.9
      echo 0 > $n 2>/dev/null
      echo "BUZZ $n rc=0"
      return 0
    fi
  done
  echo BUZZ no-node
  return 1
}

# ================= 屏幕状态 =================
W=0
dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake' && W=1
echo S0_WAKE W=$W
if [ $W -eq 0 ]; then
  if [ -n "$PDEV" ]; then
    sendevent $PDEV 1 116 1
    sendevent $PDEV 0 0 0
    sleep 0.05
    sendevent $PDEV 1 116 0
    sendevent $PDEV 0 0 0
  elif [ -n "$TDEV" ]; then
    sendevent $TDEV 1 143 1
    sendevent $TDEV 0 0 0
    sleep 0.05
    sendevent $TDEV 1 143 0
    sendevent $TDEV 0 0 0
  fi
  sleep 2
fi
svc power stayon true 2>/dev/null

# ---- 1. 回到工行首页: 橙色卡行三点投票 (≥2 即首页) ----
H=0
C1=0; C2=0; C3=0
if [ -n "$BDEV" ]; then
  i=0
  while [ $i -lt 6 ]; do
    shot
    PX 216 778; C1=0; ORANGE && C1=1; DPX 216 778
    PX 518 780; C2=0; ORANGE && C2=1; DPX 518 780
    PX 746 748; C3=0; ORANGE && C3=1; DPX 746 748
    V=$((C1+C2+C3))
    echo "VOTE=$V"
    if [ $V -ge 2 ]; then
      H=1
      echo S1_HOME
      snap home
      break
    fi
    # 耐心等待: 前 2 次探测不回退, 避免和冷启动/手动导航打架
    if [ $i -ge 2 ]; then
      sback
    fi
    sleep 2
    i=$((i+1))
  done
fi
if [ $H -ne 1 ]; then
  echo S1_MONKEY
  monkey -p com.icbc -c android.intent.category.LAUNCHER 1
  sleep 10
  shot
  PX 216 778; C1=0; ORANGE && C1=1; DPX 216 778
  PX 518 780; C2=0; ORANGE && C2=1; DPX 518 780
  PX 746 748; C3=0; ORANGE && C3=1; DPX 746 748
  V=$((C1+C2+C3))
  echo "VOTE=$V"
  [ $V -ge 2 ] && H=1
fi
if [ $H -ne 1 ]; then
  echo HOME_FAIL
  screencap -d $D -p $WORK/zx_home_fail.png 2>/dev/null
  [ -n "$CHOWN" ] && chown $CHOWN $WORK/zx_home_fail.png 2>/dev/null
  buzz
  echo FAIL_END 1
  exit 1
fi

# ---- 2. 入口点击 + 广告快速防御 (复用 S1 的 RAW, 不再重截) ----
PX 1150 345
L0=$(((Rv+Gv+Bv)/3))
PX 600 1200
MX=$Rv; MN=$Rv
[ $Gv -gt $MX ] && MX=$Gv
[ $Gv -lt $MN ] && MN=$Gv
[ $Bv -gt $MX ] && MX=$Bv
[ $Bv -lt $MN ] && MN=$Bv
M0=$((MX-MN))
if [ $L0 -ge 160 ] && [ $M0 -le 70 ]; then
  echo S2_ENTRY
  stap 606 1067
  sleep 2
  shot
  PX 1150 345
  L1=$(((Rv+Gv+Bv)/3))
  echo "S2_AFTER_ENTRY L=$L1"
  # 广告防御: 仅当页面又暗又变(和首页/任务页都不同)才快速点, 最多2次, 每次等2秒
  K=0
  while [ $K -lt 2 ]; do
    PX 1150 345; L1=$(((Rv+Gv+Bv)/3)); PX 750 750; WP_A=0; BLUE && WP_A=1
    if [ $L1 -lt 130 ] && [ $WP_A -eq 0 ]; then
      echo S2_ADQ
      stap 1144 326
      sleep 2
      shot
      K=$((K+1))
    else
      break
    fi
  done
  shot
  snap s2_done
  PX 1150 345; DPX 1150 345
  PX 750 750; DPX 750 750
  PX 608 2138; DPX 608 2138
fi

# ---- 3. 下滑一屏 + 立即参与 ----
echo S3_SWIPE
sswipe 610 1900 610 900
sleep 2
shot
snap s3_swiped
PX 1150 345; DPX 1150 345
PX 750 750; DPX 750 750
PX 608 2138; DPX 608 2138
echo S3_TAP
stap 608 2138
sleep 3
shot
snap s3_tapped
PX 1150 345; DPX 1150 345
PX 750 750; DPX 750 750
PX 608 2138; DPX 608 2138

# ---- 4. 浇水页确认 + 浇水 (WP=0 时多等5秒重判一次) ----
WP=0
TRY=0
while [ $TRY -lt 2 ]; do
  shot
  PX 750 746
  WP=0
  BLUE && WP=1
  DPX 750 746
  if [ $WP -eq 1 ]; then
    break
  fi
  TRY=$((TRY+1))
  sleep 5
done
snap s4
if [ $WP -eq 1 ]; then
  echo S4_WP
  stap 750 750
  sleep 2
  screencap -d $D -p $WORK/zx_water.png 2>/dev/null
  [ -n "$CHOWN" ] && chown $CHOWN $WORK/zx_water.png 2>/dev/null
  echo WATER_OK
  buzz
  echo FAIL_END 0
  exit 0
else
  screencap -d $D -p $WORK/zx_water_fail.png 2>/dev/null
  [ -n "$CHOWN" ] && chown $CHOWN $WORK/zx_water_fail.png 2>/dev/null
  echo WATERPAGE_FAIL
  buzz
  echo FAIL_END 2
  exit 2
fi