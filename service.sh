#!/system/bin/sh
# icbc_daily_water / service.sh v0.9.6  合并守护 + 多 Profile 调度
# 每个 profile 独立: 定时窗口 / DONE(当天已跑) / try(失败计数) / 录制动作回放
# 内置工行浇水 = 脚本型 profile (water.sh 逻辑, 含检测/重试)
# 录制型 profile = 到点 亮屏->解锁->开PKG->replay actions.rx
# 纯 root 直控(sendevent/screencap), 不 hook 不无障碍。
# FORCE(now.txt 含 profile名,空=内置工行) 无条件且不写 DONE, 永不污染定时。
M=/data/adb/modules/icbc_daily_water
PKG=com.icbc
LOG=$M/log.txt
CFG=/data/adb/icbc_water/sched.conf
BASE=/data/adb/icbc_water
PFX=$BASE/profiles
POWER_BAK=$BASE/power.bak

# ---------- 配置 (WebUI 可改, 存 /data/adb/icbc_water/sched.conf) ----------
[ -f $CFG ] && . $CFG
SCHED_ENABLE=${SCHED_ENABLE:-1}
SCHED_TIME=${SCHED_TIME:-0730}
UNLOCK_MODE=${UNLOCK_MODE:-pin}
OPEN_MODE=${OPEN_MODE:-monkey}
SLEEP_AFTER=${SLEEP_AFTER:-1}
WATCH_OPEN=${WATCH_OPEN:-0}
PIN=${PIN:-}
PIN_X0=${PIN_X0:-290}
PIN_Y0=${PIN_Y0:-1015}
PIN_DX=${PIN_DX:-320}
PIN_DY=${PIN_DY:-210}

# 日志裁剪: 超过 200KB 保留末尾 100 行
if [ -f $LOG ]; then
  SZ=$(wc -c < $LOG 2>/dev/null)
  if [ "${SZ:-0}" -gt 200000 ]; then
    tail -100 $LOG > $LOG.tmp 2>/dev/null
    mv $LOG.tmp $LOG 2>/dev/null
  fi
fi

# 结束旧服务时尽量连同其独立进程组里的 water/replay 子进程一起结束，
# 避免重启后旧注入继续与新任务并发；只有确认 PGID==PID 才使用负 PID。
kill_service_tree() {
  KST=$1
  KPG=$(awk '{print $5}' "/proc/$KST/stat" 2>/dev/null)
  case "$KPG" in
    "$KST") kill -9 -"$KST" 2>/dev/null;;
    *) kill -9 "$KST" 2>/dev/null;;
  esac
}

# 单例: 杀掉其它同脚本实例 (重启服务/重装时防重复)
for p in $(pgrep -f "$M/service.sh" 2>/dev/null); do
  [ "$p" != "$$" ] && kill_service_tree "$p"
done
sleep 1

VER=$(grep -m1 '^version=' $M/module.prop 2>/dev/null | cut -d= -f2)
echo $(date +%m%d-%H%M) SD_BOOT M8 $VER SCHED=$SCHED_TIME EN=$SCHED_ENABLE WATCH=$WATCH_OPEN >> $LOG

# ---------- 设备发现 (getevent 单遍扫描 + boot_id 缓存) ----------
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
# BDEV/PDEV 也必须复核；event 编号在重启/热插拔后可能复用。
case "$BDEV" in
  /dev/input/*) case "$(getevent -p "$BDEV" 2>/dev/null)" in *009e*|*KEY_BACK*) ;; *) BDEV=;; esac;;
  *) BDEV=;;
esac
case "$PDEV" in
  /dev/input/*) case "$(getevent -p "$PDEV" 2>/dev/null)" in *0074*|*KEY_POWER*) ;; *) PDEV=;; esac;;
  *) PDEV=;;
esac
if [ -z "$TDEV" ] || [ ! -e "$TDEV" ] || [ -z "$BDEV" ] || [ -z "$PDEV" ]; then
  discdev
  { echo "BID=$BID"; echo "TDEV=$TDEV"; echo "BDEV=$BDEV"; echo "PDEV=$PDEV"; } > $M/dev.conf 2>/dev/null
fi
echo DEVT TDEV=$TDEV BDEV=$BDEV PDEV=$PDEV >> $LOG
# 与录制/回放共用触摸轴缩放，避免不同设备上 PIN/唤醒坐标错位。
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

# ---------- 注入原语 (sendevent) ----------
stap() {
  sendevent $TDEV 3 47 0
  sendevent $TDEV 3 57 1
  sendevent $TDEV 3 53 $(( $1 * K ))
  sendevent $TDEV 3 54 $(( $2 * K ))
  sendevent $TDEV 3 48 20
  sendevent $TDEV 3 49 20
  sendevent $TDEV 1 330 1
  sendevent $TDEV 0 0 0
  sleep 0.08
  sendevent $TDEV 3 57 -1
  sendevent $TDEV 1 330 0
  sendevent $TDEV 0 0 0
}

# 带节奏上滑 (锁屏呼出键盘, 贴屏幕底起手 y2550, 每步30ms)
sweep_up() {
  sendevent $TDEV 3 47 0
  sendevent $TDEV 3 57 1
  sendevent $TDEV 3 53 $(( 610 * K ))
  sendevent $TDEV 3 54 $(( 2550 * K ))
  sendevent $TDEV 3 48 20
  sendevent $TDEV 3 49 20
  sendevent $TDEV 1 330 1
  sendevent $TDEV 0 0 0
  k=0
  while [ $k -le 13 ]; do
    sendevent $TDEV 3 53 $(( 610 * K ))
    sendevent $TDEV 3 54 $(( ( 2550 - 88 * k ) * K ))
    sendevent $TDEV 0 0 0
    sleep 0.03
    k=$((k+1))
  done
  sleep 0.1
  sendevent $TDEV 3 57 -1
  sendevent $TDEV 1 330 0
  sendevent $TDEV 0 0 0
}

sback() {
  [ -n "$BDEV" ] || return 1
  sendevent $BDEV 1 158 1
  sendevent $BDEV 0 0 0
  sleep 0.05
  sendevent $BDEV 1 158 0
  sendevent $BDEV 0 0 0
}

# ---------- 屏幕/解锁 ----------
wake_screen() {
  n=0
  while [ $n -lt 3 ]; do
    A=0
    dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake' && A=1
    [ $A -eq 1 ] && return 0
    if [ -n "$PDEV" ]; then
      sendevent $PDEV 1 116 1; sendevent $PDEV 0 0 0
      sleep 0.05
      sendevent $PDEV 1 116 0; sendevent $PDEV 0 0 0
    elif [ -n "$TDEV" ]; then
      sendevent $TDEV 1 143 1; sendevent $TDEV 0 0 0
      sleep 0.05
      sendevent $TDEV 1 143 0; sendevent $TDEV 0 0 0
    fi
    sleep 1.5
    n=$((n+1))
  done
  return 1
}

lock_state() {  # 0=明确未锁, 1=明确锁定, 2=无法确认
  L=$(dumpsys window 2>/dev/null)
  if printf '%s' "$L" | grep -qE 'mShowingLockscreen=true|mDreamingLockscreen=true|isStatusBarKeyguard=true'; then
    echo 1
  elif printf '%s' "$L" | grep -qE 'mShowingLockscreen=|mDreamingLockscreen=|isStatusBarKeyguard=|mCurrentFocus|mFocusedApp|WindowManager|Window #'; then
    echo 0
  else
    echo 2
  fi
}

pin_enter() {
  i=0
  while [ $i -lt ${#PIN} ]; do
    d=$(printf '%s' "$PIN" | cut -c $((i+1)))
    if [ "$d" = "0" ]; then
      r=3; c=1
    else
      v=${d#0}
      r=$(( (v - 1) / 3 )); c=$(( (v - 1) % 3 ))
    fi
    x=$(( PIN_X0 + c * PIN_DX ))
    y=$(( PIN_Y0 + r * PIN_DY ))
    stap $x $y
    sleep 0.3
    i=$((i+1))
  done
}

unlock_screen() {
  # 1) 系统 dismiss (无密码锁屏可直接解)
  wm dismiss-keyguard 2>/dev/null
  sleep 0.3
  LS=$(lock_state)
  [ "$LS" = "0" ] && return 0
  [ "$LS" = "2" ] && return 1
  # 2) pin 模式: 带节奏上滑呼出键盘 -> 盲打完整PIN (长度够系统自动提交)
  if [ "$UNLOCK_MODE" = "pin" ] && [ -n "$PIN" ]; then
    n=0
    while [ $n -lt 3 ]; do
      sweep_up
      sleep 1.2
      pin_enter
      sleep 2
      LS=$(lock_state)
      [ "$LS" = "0" ] && return 0
      [ "$LS" = "2" ] && return 1
      # 不把锁屏/键盘截图写入共享存储，避免泄露通知或 PIN 键盘状态。
      sback 2>/dev/null
      sleep 0.8
      n=$((n+1))
    done
  fi
  # 3) 上滑兜底 (swipe 模式/无密码)
  n=0
  while [ $n -lt 3 ]; do
    sweep_up
    sleep 1.5
    LS=$(lock_state)
    [ "$LS" = "0" ] && return 0
    [ "$LS" = "2" ] && return 1
    n=$((n+1))
  done
  return 1
}

open_pkg() {  # 用 OPEN_MODE 方式拉起指定包
  P=$1
  if [ "$OPEN_MODE" = "am" ]; then
    am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$P" 2>/dev/null
  else
    monkey -p "$P" -c android.intent.category.LAUNCHER 1 2>/dev/null
  fi
}

# HHMM → 当日分钟数 (防前导0八进制坑, 非法值返回0)
hhmm2m() {
  case "$1" in
    [0-9][0-9][0-9][0-9])
      h=${1%??}; h=${h#0}; h=${h:-0}
      m=${1#??}; m=${m#0}; m=${m:-0}
      echo $(( h * 60 + m ));;
    *) echo 0;;
  esac
}

# ---------- 前台判定 (链路B 用) ----------
fg_detect() {
  out=$(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity)
  case "$out" in ''|*null*) out=$(dumpsys activity activities 2>/dev/null | grep -m1 -E 'topActivity=|mResumedActivity|mFocusedActivity');; esac
  case "$out" in ''|*null*) out=$(dumpsys window windows 2>/dev/null | grep -m1 -E 'mCurrentFocus|mFocusedApp');; esac
  echo "$out"
}

fg_pkg() {  # 从 dumpsys 行提取精确包名；空结果表示无法确认前台
  L=${1:-$(fg_detect)}
  [ -n "$L" ] || return
  R=$(printf '%s\n' "$L" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^u[0-9][0-9]*(_a[0-9][0-9]*)?$/ && i < NF) {
        print $(i + 1); exit
      }
    }
  }')
  if [ -z "$R" ]; then
    R=$(printf '%s\n' "$L" | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i ~ /\/.*/ && $i !~ /^ActivityRecord/) {
          split($i, a, "/"); print a[1]; exit
        }
      }
    }')
  fi
  if [ -n "$R" ]; then
    R=${R%%/*}
    case "$R" in ''|*[!A-Za-z0-9._-]*) return;; esac
    printf '%s\n' "$R"
    return
  fi
  R=$(printf '%s\n' "$L" | sed -E 's/.*(topResumedActivity|mResumedActivity|mFocusedActivity|mCurrentFocus|mFocusedApp)=[^ ]+ ([^ }/]+).*/\2/')
  case "$R" in ''|*[!A-Za-z0-9._-]*) return;; esac
  printf '%s\n' "$R"
}

# ---------- 内置工行 profile 兜底 (防删除/首次安装缺目录) ----------
ensure_profiles() {
  mkdir -p $PFX 2>/dev/null
  if [ ! -f $PFX/icbc/conf ]; then
    mkdir -p $PFX/icbc 2>/dev/null
    {
      echo P_NAME=工行定时浇水
      echo P_TYPE=script
      echo P_PKG=com.icbc
      echo P_SCHED=$SCHED_TIME
    } > $PFX/icbc/conf 2>/dev/null
    echo $(date +%m%d-%H%M) ICBC_PROFILE default created >> $LOG
  fi
}

# WATCH_OPEN 链路不经过 run_profile，但同样必须保护并恢复用户方向锁。
watch_water_preserve_rotation() {
  WROT0=$(settings get system accelerometer_rotation 2>/dev/null)
  case "$WROT0" in
    0|1) ;;
    *)
      WROT0=$(dumpsys window 2>/dev/null | grep -m1 -E 'rotationMode=|mRotationMode=')
      case "$WROT0" in
        *ROTATION_MODE_FREE*) WROT0=1;;
        *) WROT0=0;;
      esac
      ;;
  esac
  WUROT0=$(settings get system user_rotation 2>/dev/null)
  case "$WUROT0" in 0|1|2|3) ;; *) WUROT0=0;; esac
  WNOW_TMO=$(settings get system screen_off_timeout 2>/dev/null)
  case "$WNOW_TMO" in ''|*[!0-9]*) WNOW_TMO=30000;; esac
  WSTAY0=$(dumpsys power 2>/dev/null | grep -m1 'mStayOn=' | sed 's/.*mStayOn=\([^ ]*\).*/\1/')
  case "$WSTAY0" in true|false|usb|ac|wireless) ;; *) WSTAY0=false;; esac
  WSTAY_RAW=$(settings get global stay_on_while_plugged_in 2>/dev/null)
  case "$WSTAY_RAW" in ''|*[!0-9]*) WSTAY_RAW=-;; esac
  mkdir -p "$BASE" 2>/dev/null
  echo "$WROT0 $WUROT0" > "$BASE/rot.lock.bak" 2>/dev/null
  echo "$WNOW_TMO $WSTAY_RAW $WSTAY0" > "$POWER_BAK" 2>/dev/null
  chmod 600 "$BASE/rot.lock.bak" "$POWER_BAK" 2>/dev/null
  settings put system screen_off_timeout 600000 2>/dev/null
  cmd window set-user-rotation lock 0 2>/dev/null
  settings put system accelerometer_rotation 0 2>/dev/null
  settings put system user_rotation 0 2>/dev/null
  svc power stayon true 2>/dev/null
  echo $(date +%m%d-%H%M) WATCH_KEEPALIVE tmo=$WNOW_TMO stay=$WSTAY0 rot=$WROT0 urot=$WUROT0 >> $LOG
  sh $M/water.sh >> $LOG 2>&1
  WRC=$?
  if [ "$WROT0" = "0" ]; then
    cmd window set-user-rotation lock "$WUROT0" 2>/dev/null
    settings put system accelerometer_rotation 0 2>/dev/null
    settings put system user_rotation "$WUROT0" 2>/dev/null
  else
    cmd window set-user-rotation free 2>/dev/null
    settings put system accelerometer_rotation 1 2>/dev/null
    settings put system user_rotation "$WUROT0" 2>/dev/null
  fi
  restore_power_bak
  rm -f "$BASE/rot.lock.bak" 2>/dev/null
  echo $(date +%m%d-%H%M) WATCH_ROTRESTORE rot=$WROT0 urot=$WUROT0 tmo=$WNOW_TMO stay=$WSTAY0 >> $LOG
  return "$WRC"
}

# ---------- 跑一个 profile ----------
# $1=目录名 $2=FORCE(1/0)
run_profile() {
  PN=$1; FORCEF=$2
  CDIR=$PFX/$PN
  # 读 profile 配置 (P_ 前缀防与全局冲突)
  P_NAME=; P_TYPE=script; P_PKG=; P_SCHED=; P_ENABLE=
  [ -f $CDIR/conf ] && . $CDIR/conf 2>/dev/null
  # 录制型 profile 允许 P_PKG 为空: 亮屏回放当前画面, 不强行打开工行。
  # 脚本型 profile 若历史配置缺包名, 仍回退到内置工行。
  if [ "$P_TYPE" = "script" ] && [ -z "$P_PKG" ]; then P_PKG=com.icbc; fi
  [ -z "$P_SCHED" ] && P_SCHED=$SCHED_TIME
  PDONE=0
  [ -f $CDIR/state.txt ] && [ "$(cat $CDIR/state.txt 2>/dev/null)" = "$T" ] && PDONE=1
  PCT=0
  [ -f $CDIR/try.txt ] && PCT=$(cat $CDIR/try.txt 2>/dev/null)
  PCT=${PCT:-0}
  # 只有定时写 last.txt; FORCE 手动测试不污染
  [ $FORCEF -eq 0 ] && date +%s > $M/last.txt
  date +%s > $M/cool.txt
  if [ $FORCEF -eq 1 ]; then
    echo $(date +%m%d-%H%M) V2_FORCE P=$PN DONE=$PDONE TRY=$PCT >> $LOG
  else
    echo $(date +%m%d-%H%M) V2_SCHED P=$PN >> $LOG
  fi
  # 屏幕亮着(在用手机) → 先主动锁屏, 再走正常解锁链 => 正大光明接管, 不抢你正在用的界面
  if [ $A -eq 1 ] && [ -n "$PDEV" ]; then
    sendevent $PDEV 1 116 1; sendevent $PDEV 0 0 0
    sleep 0.05
    sendevent $PDEV 1 116 0; sendevent $PDEV 0 0 0
    sleep 1
    echo $(date +%m%d-%H%M) V2_PRE_LOCK P=$PN >> $LOG
  fi
  NOW_TMO=$(settings get system screen_off_timeout 2>/dev/null)
  case "$NOW_TMO" in
    ''|*[!0-9]*) NOW_TMO=30000;;
  esac
  # 记录方向锁原值 (跑完恢复)。settings 的持久开关优先；读空时才用
  # dumpsys window 交叉确认，避免 dumpsys 的瞬时显示覆盖用户真实设置。
  ROT0=$(settings get system accelerometer_rotation 2>/dev/null)
  case "$ROT0" in
    0|1) ROTSRC=settings;;
    *) ROT0=; ROTSRC=dumpsys;;
  esac
  RMODE=$(dumpsys window 2>/dev/null | grep -m1 -E 'rotationMode=|mRotationMode=')
  if [ -z "$ROT0" ]; then
    case "$RMODE" in
      *ROTATION_MODE_FREE*) ROT0=1;;
      *ROTATION_MODE_LOCKED*) ROT0=0;;
      *) ROT0=0;;  # 无法确认时保守按锁定，绝不擅自开启自动旋转
    esac
  fi
  UROT0=$(settings get system user_rotation 2>/dev/null)
  case "$UROT0" in 0|1|2|3) ;; *) UROT0=0;; esac
  # 备份供服务异常退出/重启后的恢复逻辑使用; 不记录 PIN 等敏感配置
  mkdir -p "$BASE" 2>/dev/null
  echo "$ROT0 $UROT0" > "$BASE/rot.lock.bak" 2>/dev/null
  chmod 600 "$BASE/rot.lock.bak" 2>/dev/null
  # 记录常亮设置, 即使 SLEEP_AFTER=0 也要恢复 timeout/stayon。
  STAY0=$(dumpsys power 2>/dev/null | grep -m1 'mStayOn=' | sed 's/.*mStayOn=\([^ ]*\).*/\1/')
  case "$STAY0" in true|false|usb|ac|wireless) ;; *) STAY0=false;; esac
  STAY_RAW=$(settings get global stay_on_while_plugged_in 2>/dev/null)
  case "$STAY_RAW" in ''|*[!0-9]*) STAY_RAW=-;; esac
  settings put system screen_off_timeout 600000 2>/dev/null
  echo "$NOW_TMO $STAY_RAW $STAY0" > "$POWER_BAK" 2>/dev/null
  chmod 600 "$POWER_BAK" 2>/dev/null
  # 跑之前先强制锁竖屏: 解锁/注入/回放全程保持同一方向, 防中途被重力感应带成横屏
  # 导致注入坐标整体错位(竖屏坐标灌进横屏 = 点错位置)
  cmd window set-user-rotation lock 0 2>/dev/null
  settings put system accelerometer_rotation 0 2>/dev/null
  settings put system user_rotation 0 2>/dev/null
  echo V2_KEEPALIVE tmo=${NOW_TMO:-?} stay=$STAY0 rot=$ROT0 urot=$UROT0 P=$PN >> $LOG
  svc power stayon true 2>/dev/null
  ABORT=0
  wake_screen
  WRC=$?
  echo V2_WOKE P=$PN RC=$WRC >> $LOG
  if [ $WRC -ne 0 ]; then
    RC=3; ABORT=1
  else
    sleep 0.5
    unlock_screen
    URC=$?
    echo V2_UNLOCK P=$PN RC=$URC >> $LOG
    if [ $URC -ne 0 ]; then
      RC=3; ABORT=1
    else
      sleep 1
      if [ -n "$P_PKG" ]; then
        open_pkg "$P_PKG"
        ORC=$?
        echo V2_OPEN P=$PN PKG=$P_PKG RC=$ORC >> $LOG
        if [ $ORC -ne 0 ]; then
          RC=3; ABORT=1
        else
          # 录制型: 有包名时必须确认精确包名已到前台；超时不再盲回放。
          APPOK=0; i=0
          while [ $i -lt 30 ]; do
            if [ "$(fg_pkg)" = "$P_PKG" ]; then APPOK=1; break; fi
            sleep 0.5
            i=$((i+1))
          done
          if [ $APPOK -ne 1 ]; then
            echo V2_APP_TIMEOUT P=$PN PKG=$P_PKG >> $LOG
            RC=3; ABORT=1
          fi
        fi
      else
        echo "V2_OPEN P=$PN PKG= (裸录/当前画面)" >> $LOG
      fi
      if [ $ABORT -eq 0 ]; then
        if [ "$P_TYPE" = "script" ]; then
          sleep 8
          # 脚本型: 走 water.sh (含前台门/检测/重试)
          sh $M/water.sh >> $LOG 2>&1
          RC=$?
        else
          sleep 5
          sh $M/replay.sh $PN >> $LOG 2>&1
          RC=$?
        fi
      fi
    fi
  fi
  if [ $RC -eq 0 ]; then
    [ $FORCEF -eq 0 ] && date +%Y%m%d > $CDIR/state.txt
    rm -f $CDIR/try.txt
    echo $(date +%m%d-%H%M) V2_OK P=$PN >> $LOG
  elif [ $RC -eq 9 ] || [ $RC -eq 3 ]; then
    echo $(date +%m%d-%H%M) V2_SKIP$RC P=$PN >> $LOG
  else
    PCT=$(cat $CDIR/try.txt 2>/dev/null)
    PCT=${PCT:-0}
    echo $((PCT+1)) > $CDIR/try.txt
    echo $(date +%m%d-%H%M) V2_FAIL$RC P=$PN >> $LOG
  fi
  if [ "${SLEEP_AFTER:-1}" = "1" ]; then
    sleep 3
    svc power stayon false 2>/dev/null
    [ -n "$PDEV" ] && { sendevent $PDEV 1 116 1; sendevent $PDEV 0 0 0; sleep 0.05; sendevent $PDEV 1 116 0; sendevent $PDEV 0 0 0; }
    echo $(date +%m%d-%H%M) V2_SLEEP P=$PN >> $LOG
  fi
  # timeout/stayon 无论是否自动熄屏都恢复，避免脚本留下常亮副作用。
  restore_power_bak
  # 无条件恢复方向锁原值。先用 WindowManager 命令恢复模式, 再写 settings
  # 兜底(MIUI 部分版本只认其中一条路径); 无论 SLEEP_AFTER 是否开启都执行。
  if [ "$ROT0" = "0" ]; then
    cmd window set-user-rotation lock "$UROT0" 2>/dev/null
    settings put system accelerometer_rotation 0 2>/dev/null
    settings put system user_rotation "$UROT0" 2>/dev/null
  else
    cmd window set-user-rotation free 2>/dev/null
    settings put system accelerometer_rotation 1 2>/dev/null
    settings put system user_rotation "$UROT0" 2>/dev/null
  fi
  rm -f "$BASE/rot.lock.bak" 2>/dev/null
  echo $(date +%m%d-%H%M) V2_ROTRESTORE rot=$ROT0 urot=$UROT0 P=$PN >> $LOG
}

# ---------- 异常退出后的方向恢复 ----------
# service 正常收尾会在 run_profile 尾部恢复；若进程被 kill/重启，则在下次
# 启动时读取一次性备份。备份只含 0/1 和 0..3，不含任何凭据。
restore_rotation_bak() {
  [ -f "$BASE/rot.lock.bak" ] || return 0
  read RR RU < "$BASE/rot.lock.bak" 2>/dev/null
  case "$RR" in 0|1) ;; *) rm -f "$BASE/rot.lock.bak" 2>/dev/null; return 0;; esac
  case "$RU" in 0|1|2|3) ;; *) RU=0;; esac
  if [ "$RR" = "0" ]; then
    cmd window set-user-rotation lock "$RU" 2>/dev/null
    settings put system accelerometer_rotation 0 2>/dev/null
    settings put system user_rotation "$RU" 2>/dev/null
  else
    # free 模式不接受旋转角度参数；同时恢复原来的 user_rotation。
    cmd window set-user-rotation free 2>/dev/null
    settings put system accelerometer_rotation 1 2>/dev/null
    settings put system user_rotation "$RU" 2>/dev/null
  fi
  rm -f "$BASE/rot.lock.bak" 2>/dev/null
  echo $(date +%m%d-%H%M) SD_ROTRESTORE rot=$RR urot=$RU >> $LOG
}

# 异常退出后的屏幕超时/常亮恢复；与方向备份分离，便于保持 rot.lock.bak
# 的稳定格式 (ROT UROT)。只保存数值/枚举，不保存 PIN。
restore_power_bak() {
  [ -f "$POWER_BAK" ] || return 0
  read PTMO PRAW PEFF < "$POWER_BAK" 2>/dev/null
  case "$PTMO" in
    ''|*[!0-9]*) rm -f "$POWER_BAK" 2>/dev/null; return 0;;
  esac
  settings put system screen_off_timeout "$PTMO" 2>/dev/null
  case "$PRAW" in
    ''|-|*[!0-9]*)
      case "$PEFF" in
        true|false|usb|ac|wireless) svc power stayon "$PEFF" 2>/dev/null;;
      esac
      ;;
    *) settings put global stay_on_while_plugged_in "$PRAW" 2>/dev/null;;
  esac
  rm -f "$POWER_BAK" 2>/dev/null
  PWR=$PRAW
  [ "$PWR" = "-" ] && PWR=$PEFF
  echo $(date +%m%d-%H%M) SD_POWER_RESTORE tmo=$PTMO stay=${PWR:-unknown} >> $LOG
}

# ---------- 主循环 ----------
# 若上次进程在方向/常亮备份期间被杀/重启，启动先恢复原状态
restore_rotation_bak
restore_power_bak

# service 进程若被 TERM/INT/HUP 终止，也尝试立即恢复；kill -9 仍由下次启动
# 读取 rot.lock.bak 兜底。信号处理不记录任何敏感配置。
service_term() {
  trap - 0
  restore_rotation_bak
  restore_power_bak
  exit 143
}
trap 'restore_rotation_bak; restore_power_bak' 0
trap 'service_term' 1 2 15

ensure_profiles
N=0
AL=0
while true; do
  # 配置热加载: WebUI 保存后 2 秒内生效, 不再需要重启服务
  [ -f $CFG ] && . $CFG 2>/dev/null
  T=$(date +%Y%m%d)
  FORCE=0
  FPN=
  if [ -f $M/now.txt ]; then
    FORCE=1
    FPN=$(cat $M/now.txt 2>/dev/null)
    rm -f $M/now.txt
  fi
  CT=0
  [ -f $M/try.txt ] && CT=$(cat $M/try.txt 2>/dev/null)
  C=0
  [ -f $M/cool.txt ] && C=$(cat $M/cool.txt 2>/dev/null)
  NOW=$(date +%s)
  COOLOK=0
  if [ $((NOW-C)) -gt 900 ] || [ $C -eq 0 ]; then COOLOK=1; fi
  NOWT=$(date +%H%M)
  A=0
  dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake' && A=1
  LAST=0
  [ -f $M/last.txt ] && LAST=$(cat $M/last.txt 2>/dev/null)
  INTERVAL=$(( NOW - ${LAST:-0} ))
  [ $INTERVAL -lt 0 ] && INTERVAL=0
  # 久未运行(≥6小时)清全局失败计数 (历史 try.txt 兜底)
  if [ $INTERVAL -ge 21600 ]; then
    rm -f $M/try.txt 2>/dev/null
    CT=0
  fi
  NOWM=$(hhmm2m $NOWT)

  # ---- 遍历各 profile 找命中 (FORCE 无条件 / 定时 窗口内&当天未跑&失败<3) ----
  HIT=
  for pconf in $PFX/*/conf; do
    [ -f "$pconf" ] || continue
    PN=$(echo "$pconf" | sed -E 's|.*/profiles/([^/]+)/conf|\1|')
    P_TYPE=script; P_PKG=; P_SCHED=; P_ENABLE=
    . $pconf 2>/dev/null
    # 录制型 profile 的空包名是有效配置, 不要在调度层改写成 com.icbc。
    if [ "$P_TYPE" = "script" ] && [ -z "$P_PKG" ]; then P_PKG=com.icbc; fi
    # 定时沿用: profile 未写 P_SCHED/P_ENABLE 则用全局
    PSCHED=${P_SCHED:-$SCHED_TIME}
    PEN=${P_ENABLE:-$SCHED_ENABLE}
    # 触发窗口: 到点后60分钟内 (纯看时间; 跨零点衔接)
    PSM=$(hhmm2m $PSCHED)
    WINDOW_OK=0
    if [ $NOWM -ge $PSM ] && [ $NOWM -le $((PSM + 60)) ]; then WINDOW_OK=1; fi
    if [ $PSM -gt 1380 ] && [ $NOWM -le $((PSM + 60 - 1440)) ]; then WINDOW_OK=1; fi
    # DONE/失败: profile 自己的文件
    PDONE=0
    [ -f $PFX/$PN/state.txt ] && [ "$(cat $PFX/$PN/state.txt 2>/dev/null)" = "$T" ] && PDONE=1
    PCT=0
    [ -f $PFX/$PN/try.txt ] && PCT=$(cat $PFX/$PN/try.txt 2>/dev/null)
    PCT=${PCT:-0}
    # FORCE 无条件优先: 指定任务必须立即执行，不能被目录顺序中先命中的定时任务抢走。
    if [ $FORCE -eq 1 ]; then
      FM=0
      if [ -z "$FPN" ] && [ "$PN" = "icbc" ]; then FM=1; fi
      if [ -n "$FPN" ] && [ "$FPN" = "$PN" ]; then FM=1; fi
      if [ $FM -eq 1 ]; then
        HIT=$PN
        HITF=1
        break
      fi
      continue
    fi
    if [ "$PEN" = "1" ] && [ $WINDOW_OK -eq 1 ] && [ $PDONE -eq 0 ] && [ ${PCT:-0} -lt 3 ]; then
      HIT=$PN
      HITF=0
      break
    fi
  done

  if [ -n "$HIT" ]; then
    run_profile $HIT ${HITF:-0}
    continue
  fi

  # ---- 链路B: 每日首次打开工行自动浇水 (原 v1, 仅作用于 icbc 脚本型) ----
  if [ "${WATCH_OPEN:-0}" = "1" ] && [ -f $PFX/icbc/conf ]; then
    IDONE=0
    [ -f $PFX/icbc/state.txt ] && [ "$(cat $PFX/icbc/state.txt 2>/dev/null)" = "$T" ] && IDONE=1
    ICT=0
    [ -f $PFX/icbc/try.txt ] && ICT=$(cat $PFX/icbc/try.txt 2>/dev/null)
    if [ $IDONE -eq 0 ] && [ ${ICT:-0} -lt 3 ] && [ $COOLOK -eq 1 ]; then
      FG=$(fg_detect)
      [ -f $M/debug.txt ] && echo $(date +%H%M) DBG0 "$FG" >> $LOG
      FGP=$(fg_pkg "$FG")
      case "$FGP" in
        "$PKG") IN=1;;
        *) IN=0;;
      esac
      if [ $IN -eq 1 ]; then
        sleep 2
        FG2=$(fg_detect)
        [ -f $M/debug.txt ] && echo $(date +%H%M) DBG1 "$FG2" >> $LOG
        FGP2=$(fg_pkg "$FG2")
        case "$FGP2" in
          "$PKG") IN2=1;;
          *) IN2=0;;
        esac
        if [ $IN2 -eq 1 ]; then
          date +%s > $M/cool.txt
          echo $(date +%m%d-%H%M) TRIG P=icbc >> $LOG
          watch_water_preserve_rotation
          RC=$?
          if [ $RC -eq 0 ]; then
            date +%Y%m%d > $PFX/icbc/state.txt
            rm -f $PFX/icbc/try.txt
            echo $(date +%m%d-%H%M) OK P=icbc >> $LOG
          else
            # 9=锁被占(并发抢跑) 3=工行未到前台: 都不算失败, 不污染失败计数
            if [ $RC -eq 9 ] || [ $RC -eq 3 ]; then
              echo $(date +%m%d-%H%M) SKIP$RC P=icbc >> $LOG
            else
              ICT=$(cat $PFX/icbc/try.txt 2>/dev/null)
              ICT=${ICT:-0}
              echo $((ICT+1)) > $PFX/icbc/try.txt
              echo $(date +%m%d-%H%M) FAIL$RC P=icbc >> $LOG
            fi
          fi
          continue
        fi
      fi
    fi
  fi

  sleep 2
  N=$((N+1))
  if [ $N -ge 45 ]; then
    N=0
    [ -f $M/debug.txt ] && echo $(date +%H%M) TICK >> $LOG
  fi
  AL=$((AL+1))
  if [ $AL -ge 300 ]; then
    AL=0
    echo $(date +%H%M) ALIVE >> $LOG
  fi
done