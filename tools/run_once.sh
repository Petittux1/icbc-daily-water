#!/system/bin/sh
# 受控手动测试: 先把目标 App 切到首页, 再执行本脚本 → 当场跑一遍完整水链
# 不走守护进程, 不会抢跑, 便于观察/调试
M=/data/adb/modules/icbc_daily_water
echo GO $(date +%H%M%S)
sh $M/water.sh 2>&1 | tee /data/local/tmp/water_run.log
echo RC=$?