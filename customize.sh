#!/system/bin/sh
# icbc_daily_water 安装脚本 (KSU/Magisk customize.sh)
MODDIR=$(dirname "$0")
CFGDIR=/data/adb/icbc_water
CFG=$CFGDIR/sched.conf
PFX=$CFGDIR/profiles

# 配置外置: 模块重刷/更新不丢 PIN 与时间设置
mkdir -p $CFGDIR 2>/dev/null
rm -f "$CFG".tmp.* "$CFG".pin.* 2>/dev/null
if [ ! -f $CFG ]; then
  cp $MODDIR/sched.conf $CFG 2>/dev/null || touch $CFG 2>/dev/null
fi
chmod 600 $CFG 2>/dev/null
chmod 755 $MODDIR/service.sh $MODDIR/water.sh $MODDIR/webctl.sh $MODDIR/record.sh $MODDIR/replay.sh 2>/dev/null

# Profiles 目录 + 内置工行脚本型 profile (防重装后丢失)
mkdir -p $PFX 2>/dev/null
if [ ! -f $PFX/icbc/conf ]; then
  mkdir -p $PFX/icbc 2>/dev/null
  {
    echo P_NAME=工行定时浇水
    echo P_TYPE=script
    echo P_PKG=com.icbc
    echo P_SCHED=$(grep -m1 '^SCHED_TIME=' $CFG 2>/dev/null | cut -d= -f2)
  } > $PFX/icbc/conf 2>/dev/null
fi

# webroot 权限/SELinux 由 KSU 管理器自动处理, 这里不要动
exit 0