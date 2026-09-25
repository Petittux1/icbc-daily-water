#!/system/bin/sh
# icbc_daily_water / webctl.sh v0.9.6 - WebUI 助手 (由 KSU 管理器 WebView 以 root 调用)
# 用法: webctl.sh status|setpin|settime|setenable|setmode|setopen|setsleep|setwatch|
#        trigger[NAME]|restart|log|profiles|profile add/del/set|record start/stop/status
M=/data/adb/modules/icbc_daily_water
CFG=/data/adb/icbc_water/sched.conf
LOG=$M/log.txt
PFX=/data/adb/icbc_water/profiles
REC=$M/record.sh
# 清理上次异常中断留下的配置临时文件；正式 PIN 只保存在 CFG。
rm -f "$CFG".tmp.* "$CFG".pin.* 2>/dev/null
cleanup_cfg_tmp() { rm -f "$CFG".tmp.* "$CFG".pin.* 2>/dev/null; }
trap 'cleanup_cfg_tmp' 0
trap 'cleanup_cfg_tmp; exit 143' 1 2 15

atomic_update() {  # FILE KEY VALUE; shell-only rewrite, same-directory mv
  AU_FILE=$1; AU_KEY=$2; AU_VAL=$3
  AU_TMP=$AU_FILE.tmp.$$
  rm -f "$AU_TMP" 2>/dev/null
  if ! ( umask 077; : > "$AU_TMP" ); then return 1; fi
  AU_FOUND=0
  if [ -f "$AU_FILE" ]; then
    while IFS= read -r AU_LINE || [ -n "$AU_LINE" ]; do
      case "$AU_LINE" in
        "$AU_KEY"=*) printf '%s=%s\n' "$AU_KEY" "$AU_VAL" >> "$AU_TMP"; AU_FOUND=1;;
        *) printf '%s\n' "$AU_LINE" >> "$AU_TMP";;
      esac
    done < "$AU_FILE"
  fi
  [ "$AU_FOUND" -eq 1 ] || printf '%s=%s\n' "$AU_KEY" "$AU_VAL" >> "$AU_TMP"
  chmod 600 "$AU_TMP" 2>/dev/null || { rm -f "$AU_TMP" 2>/dev/null; return 1; }
  if ! mv "$AU_TMP" "$AU_FILE" 2>/dev/null; then
    rm -f "$AU_TMP" 2>/dev/null
    return 1
  fi
  return 0
}

setval() {  # setval KEY VALUE  (值经调用方白名单校验)
  K=$1; V=$2
  if ! atomic_update "$CFG" "$K" "$V"; then
    echo "ERR write config"
    exit 1
  fi
  # PIN 只回显“已设置”，绝不能把明文带回 WebUI/API 或 shell 输出。
  if [ "$K" = "PIN" ]; then
    echo "SET PIN=已设置"
  else
    echo "SET $K=$V"
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

# profile 目录名/slug 校验: 空拒; 禁空白/斜杠/引号/壳元字符; 允中英数_横线; 长度<=24
slugok() {
  [ -n "$1" ] || return 1
  [ ${#1} -le 24 ] || return 1
  case "$1" in
    *' '*|*'/'*|*'\\'*) return 1;;
    *"'"*|*'"'*|*'`'*) return 1;;
    *'$'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*) return 1;;
    *'#'*|*'='*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'..'*|*'.') return 1;;
  esac
  # 允许 UTF-8 高字节，但拒绝换行/制表符等控制字节。
  if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then return 1; fi
  return 0
}

# Android 包名白名单；空值是合法的“裸录/当前画面”模式。
pkgok() {
  [ -z "$1" ] && return 0
  case "$1" in *[!0-9A-Za-z_.]*) return 1;; esac
  return 0
}

# profile 显示名会写入 conf 并被 service source，拒绝空白/壳元字符/控制字节。
nameok() {
  [ -n "$1" ] || return 1
  [ ${#1} -le 32 ] || return 1
  case "$1" in
    *' '*|*'/'*|*'\\'*|*"'"*|*'"'*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*) return 1;;
    *'('*|*')'*|*'!'*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'#'*|*'='*) return 1;;
  esac
  if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then return 1; fi
  return 0
}

coordok_web() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  return 0
}

pointsok_web() {
  [ "$#" -ge 2 ] 2>/dev/null || return 1
  while [ "$#" -ge 2 ]; do
    coordok_web "$1" || return 1
    coordok_web "$2" || return 1
    shift 2
  done
  [ "$#" -eq 0 ]
}

has_valid_actions() {
  AV_FILE=$1
  [ -f "$AV_FILE" ] || return 1
  while IFS= read -r AV_LINE || [ -n "$AV_LINE" ]; do
    AV_REST=${AV_LINE#W[0-9]* }
    case "$AV_REST" in
      tap\ *) set -- $AV_REST; [ "$#" -eq 3 ] && coordok_web "$2" && coordok_web "$3" && return 0;;
      sw@*)
        set -- $AV_REST; AV_DUR=${1#sw@}; shift
        case "$AV_DUR" in ''|*[!0-9]*) ;; *) pointsok_web "$@" && return 0;; esac
        ;;
      sw\ *) set -- $AV_REST; shift; pointsok_web "$@" && return 0;;
    esac
  done < "$AV_FILE"
  return 1
}

restart_svc() {
  for p in $(pgrep -f "$M/service.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    PG=$(awk '{print $5}' "/proc/$p/stat" 2>/dev/null)
    if [ "$PG" = "$p" ]; then
      kill -9 -"$p" 2>/dev/null
    else
      kill -9 "$p" 2>/dev/null
    fi
  done
  sleep 1
  # 独立会话全脱离启动, 避免随 WebUI 的 exec 会话结束被连带杀掉
  ( setsid sh $M/service.sh </dev/null >/dev/null 2>&1 & ) 2>/dev/null \
    || ( sh $M/service.sh </dev/null >/dev/null 2>&1 & )
  sleep 2
  pid=$(pgrep -f "$M/service.sh" 2>/dev/null | head -1)
  if [ -n "$pid" ]; then
    echo "SERVICE restarted pid=$pid"
  else
    echo "SERVICE restart-failed"
  fi
}

# 输出单个 profile 状态行 (webctl status 与 profiles 共用)
prof_line() {
  CD=$1
  PN=$(basename "$CD")
  P_NAME=; P_TYPE=; P_PKG=; P_SCHED=; P_ENABLE=
  [ -f $CD/conf ] && . $CD/conf 2>/dev/null
  T0=$(date +%Y%m%d)
  PD=no
  [ -f $CD/state.txt ] && [ "$(cat $CD/state.txt 2>/dev/null)" = "$T0" ] && PD=yes
  PTRY=0
  [ -f $CD/try.txt ] && PTRY=$(cat $CD/try.txt 2>/dev/null)
  PACTS=0
  # sw@DUR 是新格式; 同时兼容旧 sw 空格格式
  [ -f $CD/actions.rx ] && PACTS=$(grep -cE '^W[0-9]+ (tap|sw@[0-9]+|sw)($| )' $CD/actions.rx 2>/dev/null)
  echo "profile=$PN pname=${P_NAME:-$PN} ptype=${P_TYPE:-script} ppkg=${P_PKG:-} psched=${P_SCHED:-} penable=${P_ENABLE:-} pdone=$PD ptry=$PTRY pacts=${PACTS:-0}"
}

list_profiles() {
  mkdir -p $PFX 2>/dev/null
  for CD in $PFX/*; do
    [ -d "$CD" ] || continue
    prof_line "$CD"
  done
}

case "$1" in
  status)
    echo "=== 状态 ==="
    SVC=stopped
    pgrep -f "$M/service.sh" >/dev/null 2>&1 && SVC=running
    echo "service: $SVC"
    T=$(date +%Y%m%d)
    # DONE 看内置 icbc profile (脚本型工行浇水); FORCE 不写 => 可反复测试永不污染
    IDONE=no
    if [ -f $PFX/icbc/state.txt ] && [ "$(cat $PFX/icbc/state.txt 2>/dev/null)" = "$T" ]; then IDONE=yes; fi
    if [ "$IDONE" = "yes" ]; then
      echo "today: DONE"
    else
      echo "today: pending"
    fi
    ICT=0
    [ -f $PFX/icbc/try.txt ] && ICT=$(cat $PFX/icbc/try.txt 2>/dev/null)
    echo "fail_times: $ICT"
    if [ -f $CFG ]; then . $CFG; fi
    NOWT=$(date +%H%M)
    LAST=0
    [ -f $M/last.txt ] && LAST=$(cat $M/last.txt 2>/dev/null)
    I=$(( $(date +%s) - ${LAST:-0} ))
    [ $I -lt 0 ] && I=0
    A=0
    dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake' && A=1
    echo "=== 触发检查 ==="
    echo "svc=$SVC enable=${SCHED_ENABLE:-1} screen=$A now=$NOWT sched=$SCHED_TIME last_ago=$I"
    # 窗口: 内置工行定时 (到点后 60 分钟内, 跨零点衔接)
    NOWM_A=$(hhmm2m $NOWT); SCHEDM_A=$(hhmm2m $SCHED_TIME)
    W=0
    if [ $NOWM_A -ge $SCHEDM_A ] && [ $NOWM_A -le $((SCHEDM_A + 60)) ]; then W=1; fi
    if [ $SCHEDM_A -gt 1380 ] && [ $NOWM_A -le $((SCHEDM_A + 60 - 1440)) ]; then W=1; fi
    if [ $W -eq 1 ]; then echo "window_ok=yes"; else echo "window_ok=no"; fi
    if [ "$IDONE" = "yes" ]; then echo "done_ok=yes"; else echo "done_ok=no"; fi
    echo "=== Profiles ==="
    list_profiles
    echo "=== 配置 ==="
    # 状态接口也必须脱敏 PIN；WebUI 不应能通过 stdout 读到明文。
    if [ -f $CFG ]; then
      PINSET=$(sed -n 's/^PIN=//p' $CFG 2>/dev/null | head -1)
      if [ -n "$PINSET" ]; then
        sed 's/^PIN=.*/PIN=已设置/' $CFG 2>/dev/null
      else
        sed 's/^PIN=.*/PIN=/' $CFG 2>/dev/null
      fi
    fi
    ;;
  setpin)
    # 只接受 KernelSU exec 的 env 通道；PIN 不进入命令字符串/进程参数。
    V=$WEBUI_PIN
    unset WEBUI_PIN
    V=$(printf '%s' "$V" | tr -d ' \t')
    case "$V" in
      ''|*[!0-9]*) echo "ERR pin must be digits"; exit 1;;
    esac
    if [ ${#V} -lt 4 ] || [ ${#V} -gt 8 ]; then echo "ERR pin length 4-8"; exit 1; fi
    setval PIN "$V"
    unset WEBUI_PIN V
    ;;
  settime)
    V=$(printf '%s' "$2" | tr -d ' \t')
    case "$V" in
      ''|*[!0-9]*) echo "ERR time must be HHMM"; exit 1;;
    esac
    if [ ${#V} -ne 4 ]; then echo "ERR time must be 4 digits e.g. 0730"; exit 1; fi
    HH=${V%??}; MM=${V#??}
    if [ "$HH" -gt 23 ] || [ "$MM" -gt 59 ]; then echo "ERR invalid HHMM"; exit 1; fi
    setval SCHED_TIME "$V"
    ;;
  setenable)
    case "$2" in 1|0) setval SCHED_ENABLE "$2";; *) echo "ERR enable 0/1"; exit 1;; esac
    ;;
  setmode)
    case "$2" in pin|swipe) setval UNLOCK_MODE "$2";; *) echo "ERR mode pin|swipe"; exit 1;; esac
    ;;
  setopen)
    case "$2" in monkey|am) setval OPEN_MODE "$2";; *) echo "ERR open monkey|am"; exit 1;; esac
    ;;
  setsleep)
    case "$2" in 1|0) setval SLEEP_AFTER "$2";; *) echo "ERR sleep 0/1"; exit 1;; esac
    ;;
  setwatch)
    case "$2" in 1|0) setval WATCH_OPEN "$2";; *) echo "ERR watch 0/1"; exit 1;; esac
    ;;
  profiles)
    list_profiles
    ;;
  profile)
    SUB=$2
    case "$SUB" in
      add)
        # profile add SLUG NAME PKG [SCHED]  (录制型新 profile)
        SLUG=$3; NAME=$4; PKG=$5; SCHED=$6
        slugok "$SLUG" || { echo "ERR slug 仅字母数字_横线中文,<=24位"; exit 1; }
        nameok "$NAME" || { echo "ERR name 仅允许中文/字母数字/下划线/横线，<=32位"; exit 1; }
        pkgok "$PKG" || { echo "ERR pkg 仅允许字母数字下划线点，或留空"; exit 1; }
        if [ -d $PFX/$SLUG ]; then echo "ERR profile $SLUG exists"; exit 1; fi
        if [ -n "$SCHED" ]; then
          case "$SCHED" in ''|*[!0-9]*) echo "ERR sched HHMM"; exit 1;; esac
          [ ${#SCHED} -ne 4 ] && { echo "ERR sched HHMM"; exit 1; }
          HH=${SCHED%??}; MM=${SCHED#??}
          if [ "$HH" -gt 23 ] || [ "$MM" -gt 59 ]; then echo "ERR sched HHMM"; exit 1; fi
        fi
        mkdir -p $PFX/$SLUG
        CT=$PFX/$SLUG/conf.tmp.$$
        if ! ( umask 077; {
          echo P_NAME=$NAME
          echo P_TYPE=record
          echo P_PKG=$PKG
          [ -n "$SCHED" ] && echo P_SCHED=$SCHED
        } > "$CT" ); then
          echo "ERR write profile"
          exit 1
        fi
        chmod 600 "$CT" 2>/dev/null
        if ! mv "$CT" "$PFX/$SLUG/conf" 2>/dev/null; then
          rm -f "$CT" 2>/dev/null
          echo "ERR write profile"
          exit 1
        fi
        echo "PROFILE_ADD $SLUG"
        ;;
      del)
        SLUG=$3
        [ "$SLUG" = "icbc" ] && { echo "ERR 内置工行任务不可删"; exit 1; }
        slugok "$SLUG" || { echo "ERR slug"; exit 1; }
        [ -d $PFX/$SLUG ] || { echo "ERR no profile $SLUG"; exit 1; }
        rm -rf $PFX/$SLUG
        echo "PROFILE_DEL $SLUG"
        ;;
      set)
        # profile set SLUG KEY VALUE  KEY: p_name|p_pkg|p_sched|p_enable  (写 conf 大写 P_ 字段)
        SLUG=$3; KEY=$4; VAL=$5
        slugok "$SLUG" || { echo "ERR slug"; exit 1; }
        [ -f $PFX/$SLUG/conf ] || { echo "ERR no profile $SLUG"; exit 1; }
        case "$KEY" in
          p_name) KEY=P_NAME
            nameok "$VAL" || { echo "ERR name 禁空白/斜杠/壳元字符，且<=32位"; exit 1; }
            ;;
          p_pkg) KEY=P_PKG
            # 空值 = 清空 (亮屏即录)
            pkgok "$VAL" || { echo "ERR pkg 仅允许字母数字下划线点，或留空"; exit 1; }
            ;;
          p_sched) KEY=P_SCHED
            [ -n "$VAL" ] || { echo "ERR sched HHMM"; exit 1; }
            case "$VAL" in ''|*[!0-9]*) echo "ERR sched HHMM"; exit 1;; esac
            [ ${#VAL} -ne 4 ] && { echo "ERR sched HHMM"; exit 1; }
            HH=${VAL%??}; MM=${VAL#??}
            if [ "$HH" -gt 23 ] || [ "$MM" -gt 59 ]; then echo "ERR sched HHMM"; exit 1; fi
            ;;
          p_enable) KEY=P_ENABLE
            case "$VAL" in 1|0) ;; *) echo "ERR enable 0/1"; exit 1;; esac
            ;;
          *) echo "ERR key p_name|p_pkg|p_sched|p_enable"; exit 1;;
        esac
        if ! atomic_update "$PFX/$SLUG/conf" "$KEY" "$VAL"; then
          echo "ERR write profile"
          exit 1
        fi
        echo "SET $KEY=$VAL"
        ;;
      *) echo "ERR profile add|del|set"; exit 1;;
    esac
    ;;
  record)
    SUB=$2
    case "$SUB" in
      start)
        slugok "$3" || { echo "ERR slug"; exit 1; }
        [ -d $PFX/$3 ] || { echo "ERR no profile $3"; exit 1; }
        sh $REC start "$3"
        ;;
      stop)
        slugok "$3" || { echo "ERR slug"; exit 1; }
        sh $REC stop "$3"
        ;;
      status)
        sh $REC status
        ;;
      *) echo "ERR record start|stop|status"; exit 1;;
    esac
    ;;
  trigger)
    # 默认空=内置工行; 可指定 profile slug
    if [ -n "$2" ]; then
      slugok "$2" || { echo "ERR slug"; exit 1; }
      [ -d $PFX/$2 ] || { echo "ERR no profile $2"; exit 1; }
      # 录制型任务: 必须先录过动作才能跑, 否则直接提示 (避免白解锁开app空回放)
      PTYPE=$(sed -n 's/^P_TYPE=//p' $PFX/$2/conf 2>/dev/null)
      [ -z "$PTYPE" ] && PTYPE=script
      if [ "$PTYPE" != "script" ] && ! has_valid_actions "$PFX/$2/actions.rx"; then
        echo "ERR 任务还没有有效录制内容: 先点它卡片上的「开始录制」, 切到目标app操作, 再点「停止录制」生成动作, 之后才能跑"
        exit 1
      fi
      echo "$2" > $M/now.txt 2>/dev/null && echo "TRIGGERED $2" || { echo "ERR touch now.txt"; exit 1; }
    else
      # 默认空内容=内置工行；必须截断旧内容，不能用 touch 留下上次指定的任务名。
      : > $M/now.txt 2>/dev/null && echo "TRIGGERED" || { echo "ERR write now.txt"; exit 1; }
    fi
    ;;
  restart)
    restart_svc
    ;;
  log)
    tail -60 $LOG 2>/dev/null || echo "(no log yet)"
    ;;
  *)
    echo "usage: webctl.sh status|setpin|settime|setenable|setmode|setopen|setsleep|setwatch|trigger[NAME]|restart|log|profiles|profile add/del/set|record start/stop/status"
    ;;
esac
exit 0