#!/system/bin/sh
# icbc_daily_water / record.sh v0.9.6  操作录制内核
# 纯 root 后台录制: getevent 读触摸事件流 -> 压缩成动作序列 actions.rx
# 用法: record.sh start PROFILE | stop PROFILE | status
# 行为: 从 WebUI 点「开始」起, 等「目标 app 打开到前台」才真正开录(切换动作不录);
#       之后**只在目标 app 停留期间**录取: 切走/回桌面自动暂停, 回到目标 app 继续,
#       锁屏/暗屏自动暂停, 解锁继续; 「停止」收尾存档。
#       P_PKG 为空 = 亮屏即开录全量录入 (适合先测坐标/无固定 app 的操作)。
#       PROFILE 为 profiles/ 下目录名(ASCII slug), 显示名在 conf P_NAME。
M=/data/adb/modules/icbc_daily_water
BASE=/data/adb/icbc_water
PFX=$BASE/profiles
PIDF=$BASE/rec.pid
TMP=$BASE/rec.tmp.actions
NAME=$BASE/rec.name   # 当前正在录制的 profile 名 (daemon 写, stop 删, status 读)
LOG=$BASE/rec.log

log() { echo "$(date +%m%d-%H%M%S) $*" >> $LOG; }

# 录制 profile 目录名白名单；避免 stop/pkill 把 shell 元字符当参数模式。
slugok() {
  [ -n "$1" ] || return 1
  case "$1" in
    *' '*|*'/'*|*'\\'*|*"'"*|*'"'*|*'`'*) return 1;;
    *'$'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*) return 1;;
    *'!'*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'#'*|*'='*|*'.'*) return 1;;
  esac
  if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then return 1; fi
  return 0
}

restore_rec_stayon() {
  RS=$(cat $BASE/rec.stayon 2>/dev/null)
  case "$RS" in
    true|false|usb|ac|wireless) svc power stayon "$RS" 2>/dev/null;;
  esac
  rm -f $BASE/rec.stayon 2>/dev/null
}

# 回放期间禁止新录制；回放进程异常退出后由 owner PID 自动清理陈旧锁。
replay_busy() {
  [ -d "$BASE/replay.lock" ] || return 1
  RP=$(cat "$BASE/replay.lock/owner" 2>/dev/null)
  case "$RP" in
    ''|*[!0-9]*) rm -rf "$BASE/replay.lock" 2>/dev/null; return 1;;
  esac
  if kill -0 "$RP" 2>/dev/null; then return 0; fi
  rm -rf "$BASE/replay.lock" 2>/dev/null
  return 1
}

START_LOCK=$BASE/rec.start.lock
release_start_lock() { rm -rf "$START_LOCK" 2>/dev/null; }
acquire_start_lock() {
  if mkdir "$START_LOCK" 2>/dev/null; then
    echo $$ > "$START_LOCK/owner" 2>/dev/null
    return 0
  fi
  LP=$(cat "$START_LOCK/owner" 2>/dev/null)
  case "$LP" in
    ''|*[!0-9]*) rm -rf "$START_LOCK" 2>/dev/null;;
    *) kill -0 "$LP" 2>/dev/null && return 1;;
  esac
  rm -rf "$START_LOCK" 2>/dev/null
  mkdir "$START_LOCK" 2>/dev/null || return 1
  echo $$ > "$START_LOCK/owner" 2>/dev/null
  return 0
}

# 设备解析: 在当前 shell 内设置 TDEV (须直接调用, 不能放 $(...) 子 shell 里)
disc_tdev() {
  TDEV=; BDEV=; PDEV=
  BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  if [ -f $M/dev.conf ] && grep -q "BID=$BID" $M/dev.conf 2>/dev/null; then
    . $M/dev.conf 2>/dev/null
  fi
  # event 编号跨启动可能复用；缓存节点存在不等于仍是触摸屏，需复核 name。
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
  if [ -z "$TDEV" ]; then
    for e in /dev/input/event*; do
      case "$(getevent -p $e 2>/dev/null)" in
        *Xiaomi_Touch_Input_0*) [ -z "$TDEV" ] && TDEV=$e;;
      esac
    done
    [ -z "$TDEV" ] && TDEV=/dev/input/event8
  fi
}

# 设备几何: 当前 shell 内设置 K/SW/SH (像素宽/高)。K = 轴max / 屏宽SW, 自适应。
disc_geo() {
  K=100
  SW=$(sed -n 's/^SW=\([0-9][0-9]*\).*/\1/p' $M/water.sh 2>/dev/null | head -1)
  case "$SW" in ''|*[!0-9]*) SW=1220;; esac
  SH=$(sed -n 's/^SH=\([0-9][0-9]*\).*/\1/p' $M/water.sh 2>/dev/null | head -1)
  case "$SH" in ''|*[!0-9]*) SH=2656;; esac
  if [ -n "$TDEV" ] && [ -e "$TDEV" ]; then
    P=$(getevent -p $TDEV 2>/dev/null)
    # getevent -p 的 ABS 摘要行可能同时列出 0035/0036；必须取
    # 0035:/0036: 的明细行，不能把摘要行误当成 max 行。
    MX=$(printf '%s\n' "$P" | grep -A2 -m1 -E 'ABS_MT_POSITION_X|(^|[[:space:]])0035[[:space:]]*:' | grep -m1 'max' | sed -E 's/.*max[^0-9]*([0-9]+).*/\1/')
    MY=$(printf '%s\n' "$P" | grep -A2 -m1 -E 'ABS_MT_POSITION_Y|(^|[[:space:]])0036[[:space:]]*:' | grep -m1 'max' | sed -E 's/.*max[^0-9]*([0-9]+).*/\1/')
    case "$MX" in ''|*[!0-9]*) MX=;; esac
    case "$MY" in ''|*[!0-9]*) MY=;; esac
    if [ -n "$MX" ] && [ "$MX" -gt 20000 ] 2>/dev/null; then
      K=$(( MX / SW ))
      [ $K -lt 1 ] && K=100
    fi
    # SH 是显示区高度，不是触摸面板 overscan 的轴 max；保留 water.sh 的
    # 已校准显示尺寸，避免 MY/K 把底部手势区错误地下移。
  fi
}

# 系统手势区过滤: 起点在底部导航条/左右边缘的 sw 丢弃 (MIUI 手势导航)
zone_sw() {  # 入参 SX SY; 命中返回 1 (丢弃), 未命中返回 0
  SX=$1; SY=$2
  [ "$SX" -le 60 ] && return 1          # 左边缘返回手势(含边界)
  [ "$SX" -ge $(( SW - 60 )) ] && return 1   # 右边缘返回手势(含边界)
  [ "$SY" -gt $(( SH - 130 )) ] && return 1  # 底部上滑回桌面/任务
  return 0
}

istate() {  # 0=屏幕亮且未锁(可录) 1=暂停(锁屏/暗屏/状态未知)
  P=$(dumpsys power 2>/dev/null)
  case "$P" in *mWakefulness=Awake*) ;; *) echo 1; return;; esac
  W=$(dumpsys window 2>/dev/null)
  if printf '%s' "$W" | grep -qE 'mShowingLockscreen=true|mDreamingLockscreen=true|isStatusBarKeyguard=true'; then
    echo 1; return
  fi
  # 无法读取锁屏服务时 fail-closed，避免把未知状态录成当前画面。
  if ! printf '%s' "$W" | grep -qE 'mShowingLockscreen=|mDreamingLockscreen=|isStatusBarKeyguard=|mCurrentFocus|mFocusedApp|WindowManager|Window #'; then
    echo 1; return
  fi
  echo 0
}

fg_pkg() {  # 当前前台包名 (无则空); 统一只返回包名，不把组件名/设备行当包名
  L=$(dumpsys activity activities 2>/dev/null | grep -m1 'topResumedActivity')
  if [ -z "$L" ]; then
    L=$(dumpsys activity activities 2>/dev/null | grep -m1 -E 'topActivity=|mResumedActivity|mFocusedActivity')
  fi
  case "$L" in
    ''|*null*) L=$(dumpsys window windows 2>/dev/null | grep -m1 -E 'mCurrentFocus|mFocusedApp');;
  esac
  [ -n "$L" ] || return

  # 先按字段取第一个用户 ID 后的包名。不能用 sed 的贪婪 .*，否则
  # HyperOS 的 isolated 进程(u0_a123)会把后面的 taskId 当成包名。
  R=$(printf '%s\n' "$L" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^u[0-9][0-9]*(_a[0-9][0-9]*)?$/ && i < NF) {
        print $(i + 1); exit
      }
    }
  }')
  if [ -z "$R" ]; then
    # 没有 user id 时，从带组件分隔符的字段取包名。
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

  # 最后的兼容格式：ActivityRecord{... package/component。
  R=$(printf '%s\n' "$L" | sed -E 's/.*(topResumedActivity|topActivity|mResumedActivity|mFocusedActivity|mCurrentFocus|mFocusedApp)=[^ ]+ ([^ }/]+).*/\2/')
  case "$R" in ''|*[!A-Za-z0-9._-]*) return;; esac
  printf '%s\n' "$R"
}

# App 绑定模式允许的瞬时覆盖层。这里用精确包名，避免把组件/设备字段误当包名。
app_fg_ok() {
  case "$1" in
    "$PKG"|permissioncontroller|com.android.permissioncontroller|com.android.systemui|com.android.settings) return 0;;
  esac
  return 1
}

# 返回手势的起点在系统左右边缘。App 绑定模式保留它；裸录仍由 zone_sw 丢弃。
edge_sw() {
  [ -n "$PTS" ] || return 1
  [ "$EDGE_MOVE" -eq 1 ] 2>/dev/null || return 1
  [ "$SX" -le 60 ] && return 0
  [ "$SX" -ge $(( SW - 60 )) ] && return 0
  return 1
}

now_ms() {
  R=$(date +%s%3N 2>/dev/null)
  # 某些 toybox date 不支持 %3N；避免把字面量 N 当成毫秒参与算术。
  if [ ${#R} -lt 13 ]; then R=$(date +%s)000; fi
  printf '%s\n' "$R"
}

px() {  # hex(可能带 0x/前导0) -> 十进制; 失败给 0
  V=${1#0x}
  case "$V" in
    ''|*[!0-9a-fA-F]*) echo 0;;
    *) printf '%d' "0x$V" 2>/dev/null || echo 0;;
  esac
}

coordok_rec() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  return 0
}

pointsok_rec() {
  [ "$#" -ge 2 ] 2>/dev/null || return 1
  while [ "$#" -ge 2 ]; do
    coordok_rec "$1" || return 1
    coordok_rec "$2" || return 1
    shift 2
  done
  [ "$#" -eq 0 ]
}

# 只统计完整、非负整数坐标的动作；空/损坏录制不能覆盖旧流程。
rec_count_rx() {
  RCF=$1; RCC=0
  [ -f "$RCF" ] || { echo 0; return; }
  while IFS= read -r RCL || [ -n "$RCL" ]; do
    RCR=${RCL#W[0-9]* }
    case "$RCR" in
      tap\ *) set -- $RCR; [ "$#" -eq 3 ] && coordok_rec "$2" && coordok_rec "$3" && RCC=$((RCC+1));;
      sw@*)
        set -- $RCR; RCD=${1#sw@}; shift
        case "$RCD" in ''|*[!0-9]*) ;; *) pointsok_rec "$@" && RCC=$((RCC+1));; esac
        ;;
      sw\ *) set -- $RCR; shift; pointsok_rec "$@" && RCC=$((RCC+1));;
    esac
  done < "$RCF"
  echo "$RCC"
}

# 动作落盘: 手势完成瞬间前台复查(app绑定) + 系统手势区过滤(裸录)
put_gesture() {
  # 在任何前台查询前先取动作完成时刻; fg_pkg 可能耗时几十/上百ms,
  # 若放查询之后会把 sw 时长和动作时间戳人为拉长, 回放节奏失真。
  NOW=$(now_ms)
  MS=$(( NOW - T0 ))
  # 抬手前再核对一次屏幕状态，避免恰好在锁屏/暗屏边界把最后一下误存。
  if [ "$(istate)" != "0" ]; then
    log "PUT_SKIP 锁屏/暗屏时完成手势 起点$SX,$SY"
    return
  fi
  # app 绑定: 抬手瞬间复查前台。普通动作仍严格要求目标 App/允许的覆盖层；
  # 但左右边缘返回在抬手前必然把前台切回上一个页面，不能再用“抬手后包名”
  # 把它误判成离开 App。对边缘横滑改用按下瞬间已经确认过的归属。
  DIFF=0
  if [ $APPAWARE -eq 1 ]; then
    FG_NOW=$(fg_pkg)
    if app_fg_ok "$FG_NOW"; then
      :
    elif [ "$TOUCH_OK" -eq 1 ] && edge_sw; then
      log "PUT_EDGE 保留左右边缘返回 起点$SX,$SY 前台=$FG_NOW"
      # 返回后先暂停，避免下一次触摸落到上一个页面；回到目标 App 后自动恢复。
      APP_PAUSE=1
    else
      DIFF=1
    fi
  fi
  if [ $DIFF -eq 1 ]; then
    APP_PAUSE=1
    log "PUT_SKIP 手势完成时已离开目标app($PKG) 起点$SX,$SY"
    log "PAUSE 离开目标app (手势完成复查)"
    return
  fi
  if [ -z "$PTS" ]; then
    echo "W$MS tap $SX $SY" >> $TMP
  else
    # sw@DUR = 该滑动真实耗时ms (回放按它贴回原速度, 边缘返回需快速fling才触发)
    DUR=$(( NOW - TDOWN ))
    [ "$DUR" -lt 1 ] 2>/dev/null && DUR=1
    if [ $APPAWARE -eq 1 ]; then
      # app 绑定: 位置不限(含左/右边缘返回与底部上滑返回), 由上方完成时前台复查裁决
      echo "W$MS sw@$DUR $SX $SY $PTS $X $Y" >> $TMP
    elif ! zone_sw $SX $SY; then
      # 裸录只录普通区域滑动; zone_sw 返回 1 代表系统手势区
      log "ZONE_SKIP 系统手势区 sw 起点 $SX,$SY"
    else
      echo "W$MS sw@$DUR $SX $SY $PTS $X $Y" >> $TMP
    fi
  fi
}

# ---------- start ----------
start() {
  N=$1
  [ -n "$N" ] || { echo "ERR profile required"; exit 1; }
  slugok "$N" || { echo "ERR bad profile name"; exit 1; }
  CDIR=$PFX/$N
  [ -d "$CDIR" ] || { echo "ERR no profile: $N"; exit 1; }
  acquire_start_lock || { echo "ERR another start in progress"; exit 1; }
  trap 'release_start_lock' 0
  if replay_busy; then
    echo "ERR replay in progress"
    exit 1
  fi
  if [ -f $PIDF ]; then
    OLD_PID=$(cat $PIDF 2>/dev/null)
    case "$OLD_PID" in
      ''|*[!0-9]*) rm -f $PIDF $NAME;;
      *)
        if kill -0 "$OLD_PID" 2>/dev/null; then
          OLD_CMD=$(tr '\000' ' ' < "/proc/$OLD_PID/cmdline" 2>/dev/null)
          case "$OLD_CMD" in
            *record.sh*"_daemon"*) echo "ERR already recording pid=$OLD_PID"; exit 1;;
            *) rm -f $PIDF $NAME;;
          esac
        else
          rm -f $PIDF $NAME
        fi
        ;;
    esac
  fi
  rm -f $TMP
  # 后台 daemon (setsid 脱离, 退出终端不影响; daemon 自写 pid 到 $PIDF)
  setsid sh $M/record.sh _daemon $N </dev/null >>$LOG 2>&1 &
  sleep 1
  if [ -f $PIDF ] && kill -0 $(cat $PIDF 2>/dev/null) 2>/dev/null; then
    log "REC_START $N"
    echo "REC_START $N pid=$(cat $PIDF)"
  else
    echo "ERR start failed"; exit 1
  fi
}

# ---------- 后端 ----------
_daemon() {
  N=$1
  echo $$ > $PIDF
  echo "$N" > $NAME
  CDIR=$PFX/$N
  P_TYPE=script; P_PKG=; P_NAME=
  [ -f $CDIR/conf ] && . $CDIR/conf 2>/dev/null
  PKG=$P_PKG
  # 录制型 profile 的空包名才表示裸录；脚本型/旧配置缺包名回退工行。
  if [ "$P_TYPE" != "record" ] && [ -z "$PKG" ]; then PKG=com.icbc; fi
  disc_tdev
  [ -e "$TDEV" ] || { log "FATAL 触摸设备不可用: $TDEV"; exit 1; }
  disc_geo
  chmod 600 "$LOG" "$TMP" 2>/dev/null
  log "DAEMON start N=$N K=$K TDEV=$TDEV PKG=$PKG SW=$SW SH=$SH MX=${MX:-} MY=${MY:-}"
  # 录制期间保持屏幕常亮 (否则录到一半超时锁屏), stop 时恢复
  STAY0=$(dumpsys power 2>/dev/null | grep -m1 'mStayOn=' | sed 's/.*mStayOn=\([^ ]*\).*/\1/')
  case "$STAY0" in true|false|usb|ac|wireless) ;; *) STAY0=false;; esac
  echo "$STAY0" > $BASE/rec.stayon 2>/dev/null
  chmod 600 $BASE/rec.stayon 2>/dev/null
  svc power stayon true 2>/dev/null
  # 子进程异常退出时也恢复录制前常亮状态；stop 的 kill -9 仍由 stop 兜底。
  trap 'restore_rec_stayon' 0
  trap 'restore_rec_stayon; trap - 0; exit 143' 1 2 15
  T0=$(now_ms)
  TSTART=$(date +%s)
  ACTIVE=0; STARTED=0
  SX=0; SY=0; X=0; Y=0
  PTS=""
  TDOWN=$(now_ms)
  LASTX=-9999; LASTY=-9999
  PAUSED=$(istate)   # 启动时按真实屏幕状态初始化 (亮屏未锁=0 直接可录)
  APPAWARE=0; APP_PAUSE=0; READY=0; MISS=0; FGW=0
  TOUCH_OK=0; TOUCH_FG=; EDGE_MOVE=0; LAST_FG=
  if [ -n "$PKG" ]; then
    APPAWARE=1
    LAST_FG=$(fg_pkg)
    if [ "$LAST_FG" = "$PKG" ]; then READY=1; log "READY 目标app已在前台, 开始录取"; fi
  else
    READY=1; log "READY 未设目标app, 亮屏即录"   # 未设 PKG = 亮屏即开录 (任意 app)
  fi
  : > $TMP
  CNT=0
  LASTCHK=0
  getevent -t $TDEV 2>/dev/null | while IFS= read -r line; do
    CNT=$((CNT+1))
    # 原始事件采样: 前6行打日志, 便于核对 getevent 真实输出格式
    if [ $CNT -le 6 ]; then
      log "RAW$CNT $line"
    fi
    # 状态/前台检查: 首行立即确认，之后按时间且每12行最多一次。
    # 不用“每6行”硬触发；快速边缘滑动可能只有几十行，频繁 dumpsys
    # 会把 getevent 消费拖慢，反而漏掉返回手势。
    if [ "$CNT" -eq 1 ] || { [ $((CNT % 12)) -eq 0 ] && [ $(( $(now_ms) - LASTCHK )) -ge 120 ]; }; then
      NS=$(istate)
      if [ "$NS" -ne "$PAUSED" ]; then
        if [ "$NS" -eq 1 ]; then
          if [ $ACTIVE -eq 1 ]; then
            ACTIVE=0; STARTED=0
            log "PAUSE_TRUNC 放弃未完成手势 $SX,$SY"
          fi
          log "PAUSE 锁屏/暗屏"
        else
          T0=$(now_ms)
          log "RESUME 亮屏解锁"
        fi
        PAUSED=$NS
      fi
      if [ $APPAWARE -eq 1 ]; then
        FP=$(fg_pkg)
        LAST_FG=$FP
        if [ "$READY" = "0" ]; then
          # 诊断: 每20次检查(~6s)打一次前台返回值, 定位"识别不到app"
          FGW=$((FGW+1))
          if [ $((FGW % 20)) -eq 1 ]; then
            log "FGWAIT 前台=<${FP}> 目标=<${PKG}> 等待目标app到前台"
          fi
          # 非空 P_PKG 必须等目标 App；不能因前台解析暂时失败就偷偷改成全量裸录。
          # 这里只给出可见提示，状态仍保持等待，避免录到桌面/其它 App。
          if [ $(( $(date +%s) - TSTART )) -ge 45 ] && [ $((FGW % 20)) -eq 1 ]; then
            log "WAIT_APP 45s仍未识别目标app($PKG), 继续等待，不降级裸录"
          fi
        fi
        case "$FP" in
          "$PKG")
            # 目标app在前台
            MISS=0
            if [ "$READY" = "0" ]; then
              READY=1
              T0=$(now_ms)
              log "READY 目标app已到前台, 开始录取"
            elif [ "$APP_PAUSE" = "1" ]; then
              APP_PAUSE=0
              T0=$(now_ms)
              log "RESUME 回到目标app, 继续录取"
            fi
            ;;
          permissioncontroller|com.android.permissioncontroller|com.android.systemui|com.android.settings)
            # 权限弹窗/系统UI覆盖: 仍算目标app操作会话, 不停录不截断
            MISS=0
            ;;
          *)
            # 空结果或其它包不能证明仍在目标app；连续N次确认才真暂停。
            # 手势进行中不掐断，等抬手由 put_gesture 精确复查裁决。
            MISS=$((MISS+1))
            if [ "$READY" = "1" ] && [ "$APP_PAUSE" = "0" ] && [ $MISS -ge 3 ]; then
              if [ $ACTIVE -eq 1 ]; then
                log "PEND_QUIT 离开确认中但手势未完成, 等抬手裁决 起点$SX,$SY"
              else
                APP_PAUSE=1
                log "PAUSE 离开目标app (连续$MISS次确认)"
              fi
              MISS=0
            fi
            ;;
        esac
      fi
      # 检查完成后再记时间；dumpsys 较慢时不会让下一行立即重复检查。
      LASTCHK=$(now_ms)
    fi
    [ "$PAUSED" = "1" ] && continue
    [ "$READY" = "0" ] && continue
    [ "$APP_PAUSE" = "1" ] && continue

    # getevent -t 可能输出: [timestamp] /dev/input/eventN: TYPE CODE VALUE；
    # 也可能省略设备路径。先去掉时间戳/路径，再取最后三个字段，避免把
    # /dev/input/eventN: 误当成 TYPE 而漏录所有真实动作。
    DATA=${line#*] }
    case "$DATA" in
      *': '*) DATA=${DATA##*: };;
    esac
    set -- $DATA
    T=$1; C=$2; V=$3
    case "$T" in
      0000|EV_SYN)
        # 内核通知用户态此前丢帧时，混用两帧坐标会生成错误手势；直接丢弃当前手势。
        case "$C" in
          0003|SYN_DROPPED)
            if [ $ACTIVE -eq 1 ]; then
              log "SYN_DROPPED 放弃不完整手势 $SX,$SY"
              ACTIVE=0; STARTED=0; PTS=""
              TOUCH_OK=0; EDGE_MOVE=0
            fi
            ;;
        esac
        ;;
      0003|EV_ABS)   # ABS
        case "$C" in
          0035|ABS_MT_POSITION_X)   # X
            X=$(( $(px $V) / K ))
            # 该触摸驱动的同一采样帧是 X 后 Y；等 Y 到达后再采样，
            # 避免把新 X 与上一帧旧 Y 配成中间点，导致斜向/竖向滑动轨迹失真。
            ;;
          0036|ABS_MT_POSITION_Y)   # Y
            Y=$(( $(px $V) / K ))
            if [ $ACTIVE -eq 1 ] && [ $STARTED -eq 0 ]; then
              # 同帧 X,Y 到齐才定起点 (BTN_TOUCH 先于坐标到达, 按下瞬间取不到准确值)
              SX=$X; SY=$Y; LASTX=$X; LASTY=$Y; STARTED=1
            elif [ $ACTIVE -eq 1 ] && [ $STARTED -eq 1 ]; then
              DX=$((X-LASTX)); DY=$((Y-LASTY))
              ADX=$((X-SX)); [ "$ADX" -lt 0 ] && ADX=$(( -ADX ))
              [ "$ADX" -ge 20 ] && EDGE_MOVE=1
              if [ $(( DX*DX + DY*DY )) -ge 100 ] && { [ "$X" -ne "$LASTX" ] || [ "$Y" -ne "$LASTY" ]; }; then
                if [ -n "$PTS" ]; then PTS="$PTS $X $Y"; else PTS="$X $Y"; fi
                LASTX=$X; LASTY=$Y
              fi
            fi
            ;;
          0039|ABS_MT_TRACKING_ID)  # 手指抬起信号
            [ "$V" = "ffffffff" ] && UP=1 || UP=0
            if [ "$UP" = "1" ] && [ $ACTIVE -eq 1 ]; then
              ACTIVE=0; STARTED=0
              put_gesture
            fi
            ;;
        esac
        ;;
      0001|EV_KEY)   # KEY
        case "$C" in
          014a|BTN_TOUCH)  # 触摸键
            case "$V" in
              00000001|DOWN)
                # 按下
                ACTIVE=1; STARTED=0; PTS=""
                TOUCH_OK=0; TOUCH_FG=; EDGE_MOVE=0
                TDOWN=$(now_ms)   # 手势起始时刻(算 sw 真实耗时, 回放贴原速度)
                if [ $APPAWARE -eq 1 ]; then
                  # 返回手势完成前后台会切换；复用最近一次前台采样，避免在
                  # BTN_TOUCH 事件流中阻塞 dumpsys（快速边缘滑动的时序不能被打断）。
                  TOUCH_FG=$LAST_FG
                  # 缓存为空/已不是允许包时才做一次按下前确认；正常目标 App
                  # 会话走零额外 dumpsys，避免快速边缘滑动被拖慢。
                  if ! app_fg_ok "$TOUCH_FG"; then TOUCH_FG=$(fg_pkg); fi
                  if app_fg_ok "$TOUCH_FG"; then TOUCH_OK=1; fi
                fi
                ;;
              00000000|UP)
                # 抬起: 落动作
                if [ $ACTIVE -eq 1 ]; then
                  ACTIVE=0
                  [ $STARTED -eq 0 ] && { SX=$X; SY=$Y; }   # 兜底: 坐标先于按下到达的驱动
                  STARTED=0
                  put_gesture
                fi
                ;;
            esac
            ;;
        esac
        ;;
    esac
  done
  if [ $ACTIVE -eq 1 ]; then
    ACTIVE=0
    log "END_TRUNC 放弃未完成手势 $SX,$SY"
  fi
  log "DAEMON end"
  # 正常退出时由 EXIT trap 收尾; 若 getevent 自行结束, 也恢复常亮状态
  restore_rec_stayon
}

# ---------- stop ----------
stop() {
  N=$1
  [ -n "$N" ] || { echo "ERR profile required"; exit 1; }
  slugok "$N" || { echo "ERR bad profile name"; exit 1; }
  # 没有活动 owner 时绝不把全局临时动作归档到任意 profile。
  if [ ! -f "$PIDF" ]; then
    rm -f "$TMP" "$NAME" "$START_LOCK" 2>/dev/null
    echo "ERR no active recording"
    exit 1
  fi
  if [ -f $PIDF ]; then
    ACTIVE_NAME=$(cat $NAME 2>/dev/null)
    [ -n "$ACTIVE_NAME" ] || { echo "ERR recording state unknown"; exit 1; }
    if [ "$ACTIVE_NAME" != "$N" ]; then
      echo "ERR recording another profile: $ACTIVE_NAME"
      exit 1
    fi
    PID=$(cat $PIDF 2>/dev/null)
    case "$PID" in
      ''|*[!0-9]*) echo "ERR invalid recording pid"; exit 1;;
    esac
    if kill -0 "$PID" 2>/dev/null; then
      # PID 复用保护：只终止确认属于该录制 daemon 的进程组。
      CM=$(tr '\000' ' ' < "/proc/$PID/cmdline" 2>/dev/null)
      if [ -n "$CM" ]; then
        case "$CM" in
          *record.sh*"_daemon"*"$N"*) ;;
          *) echo "ERR pid ownership mismatch"; exit 1;;
        esac
      fi
      RPG=$(awk '{print $5}' "/proc/$PID/stat" 2>/dev/null)
      if [ "$RPG" = "$PID" ]; then
        kill -9 -"$PID" 2>/dev/null   # setsid 独立进程组
      else
        kill -9 "$PID" 2>/dev/null
      fi
    fi
    rm -f $PIDF
  fi
  # 兜底: 按命令行杀掉管道子壳/getevent (读取端消失后 getevent 会 SIGPIPE 自灭)
  pkill -9 -f "record.sh _daemon $N" 2>/dev/null
  sleep 0.6
  # 恢复录制前屏幕常亮状态
  restore_rec_stayon
  rm -f $NAME
  CDIR=$PFX/$N
  [ -d "$CDIR" ] || { echo "ERR no profile: $N"; exit 1; }
  CNT=$(rec_count_rx "$TMP")
  CNT=${CNT:-0}
  if [ "$CNT" -ge 1 ] 2>/dev/null; then
    AT=$CDIR/actions.rx.tmp.$$
    if cp "$TMP" "$AT" 2>/dev/null && chmod 600 "$AT" 2>/dev/null && mv "$AT" "$CDIR/actions.rx" 2>/dev/null; then
      rm -f $NAME
      log "REC_STOP $N actions=$CNT"
      echo "REC_STOP $N actions=$CNT -> $CDIR/actions.rx"
    else
      rm -f "$AT" 2>/dev/null
      rm -f "$CDIR/actions.rx" 2>/dev/null
      log "REC_STOP $N write-failed"
      echo "ERR write actions.rx"
      exit 1
    fi
  else
    # 空录制不能继续沿用旧 actions.rx，否则下次会误回放上一次流程。
    rm -f "$CDIR/actions.rx"
    rm -f $NAME
    log "REC_STOP $N empty"
    echo "REC_STOP $N empty (没有抓到有效动作)"
  fi
}

# ---------- status ----------
status() {
  if [ -f $PIDF ] && kill -0 $(cat $PIDF 2>/dev/null) 2>/dev/null; then
    echo "recording=yes pid=$(cat $PIDF) name=$(cat $NAME 2>/dev/null)"
    echo "state=$(istate)  # 0=录取中 1=暂停(锁屏)"
    CNT=$(rec_count_rx "$TMP")
    echo "actions=${CNT:-0}"
    grep -E 'DAEMON start|READY|PAUSE|RESUME' $LOG 2>/dev/null | tail -4
  else
    echo "recording=no"
  fi
}

case "$1" in
  start) start "$2";;
  stop)  stop "$2";;
  status) status;;
  _daemon) _daemon "$2";;
  *) echo "usage: record.sh start PROFILE|stop PROFILE|status"; exit 1;;
esac