#!/bin/sh
#
# SoC cooled to --overheat-resume-c after an overheat pause
# (ar8030-lifecycled): live video again.
# See /usr/sbin/video-pause.
exec /usr/sbin/video-pause off
