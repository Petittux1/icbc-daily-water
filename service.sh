#!/system/bin/sh
# icbc_daily_water 浇水服务 (KSU 守护进程 v2.3: 轮询3->2s / 确认3->2s, 首点更快 + 日志裁剪)
PKG=com.icbc
M=/data/adb/modules/icbc_daily_water
ST=$M/state.txt
COOL=$M/cool.txt
TRY=$M/try.txt
LOG=$M/log.txt
DBG=$M/debug.txt

# 日志裁剪: 超过 200KB 保留末尾 100 行
if [ -f $LOG ]; then
  SZ=$(wc -c < $LOG 2>/dev/null)
  if [ "${SZ:-0}" -gt 200000 ]; then
    tail -100 $LOG > $LOG.tmp 2>/dev/null
    mv $LOG.tmp $LOG 2>/dev/null
  fi
fi

# 单例: 杀掉其它同脚本实例
for p in $(pgrep -f 'icbc_daily_water/service.sh' 2>/dev/null); do
  [ "$p" != "$$" ] && kill -9 $p 2>/dev/null
done

echo $(date +%m%d-%H%M) SD_BOOT >> $LOG

# 前台判定: 依次尝试三种源, 输出最后一条可用的
fg_detect() {
  out=$(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity)
  [ -z "$out" ] && out=$(dumpsys activity activities 2>/dev/null | grep -m1 -E 'mResumedActivity|mFocusedActivity')
  [ -z "$out" ] && out=$(dumpsys window windows 2>/dev/null | grep -m1 mCurrentFocus)
  [ -z "$out" ] && out=$(dumpsys window windows 2>/dev/null | grep -m1 mFocusedApp)
  echo "$out"
}

N=0
while true; do
  T=$(date +%Y%m%d)
  DONE=0
  [ -f $ST ] && [ "$(cat $ST 2>/dev/null)" = "$T" ] && DONE=1
  if [ $DONE -eq 0 ]; then
    CT=0
    [ -f $TRY ] && CT=$(cat $TRY 2>/dev/null)
    if [ ${CT:-0} -lt 3 ]; then
      C=0
      [ -f $COOL ] && C=$(cat $COOL 2>/dev/null)
      NOW=$(date +%s)
      if [ $((NOW-C)) -gt 900 ] || [ $C -eq 0 ]; then
        FG=$(fg_detect)
        [ -f $DBG ] && echo $(date +%H%M) DBG0 "$FG" >> $LOG
        case "$FG" in
          *"$PKG"*) IN=1;;
          *) IN=0;;
        esac
        if [ $IN -eq 1 ]; then
          sleep 2
          FG2=$(fg_detect)
          [ -f $DBG ] && echo $(date +%H%M) DBG1 "$FG2" >> $LOG
          case "$FG2" in
            *"$PKG"*) IN2=1;;
            *) IN2=0;;
          esac
          if [ $IN2 -eq 1 ]; then
            date +%s > $COOL
            echo $(date +%m%d-%H%M) TRIG >> $LOG
            sh $M/water.sh >> $LOG 2>&1
            RC=$?
            if [ $RC -eq 0 ]; then
              date +%Y%m%d > $ST
              echo $(date +%m%d-%H%M) OK >> $LOG
              rm -f $TRY
            else
              CT=$(cat $TRY 2>/dev/null)
              CT=${CT:-0}
              echo $((CT+1)) > $TRY
              echo $(date +%m%d-%H%M) FAIL$RC >> $LOG
            fi
          fi
        fi
      fi
    fi
  fi
  sleep 2
  N=$((N+1))
  if [ $N -ge 45 ]; then
    N=0
    [ -f $DBG ] && echo $(date +%H%M) TICK >> $LOG
  fi
done