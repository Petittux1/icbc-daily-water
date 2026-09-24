#!/system/bin/sh
# customize.sh - 模块刷入时由 KSU/Magisk 安装器执行: 设置文件权限
# 只在安装/更新时运行一次, 平时不会执行
SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=false

ui_print "- 正在安装 ICBC 浇水小助手 (仅供学习)"
ui_print "- 安装目录: $MODPATH"
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/water.sh 0 0 0755
set_perm $MODPATH/tools/run_once.sh 0 0 0755
set_perm $MODPATH/module.prop 0 0 0644
set_perm $MODPATH/README.md 0 0 0644
set_perm $MODPATH/LICENSE 0 0 0644
set_perm $MODPATH/tools/px.py 0 0 0644
ui_print "- 安装完成, 请重启手机生效"