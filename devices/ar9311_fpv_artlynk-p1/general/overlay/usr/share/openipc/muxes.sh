#!/bin/sh
#
# BetaFPV P1 board pins, run by S30customizer before ar8030-lifecycled
# starts. Pin numbers from MissingLynk ml-kernel (proxima-9311-air.dts,
# docs/status-led.md); our kernel builds neither gpio-keys-polled nor
# leds-gpio, so the lines stay free for sysfs.

# The GPIO controller is a module here (on the Ascent it is built in), and
# S30customizer runs before S35modules: load it now, or none of the lines
# below exist yet. S35modules then finds it loaded.
modprobe artosyn_gpio

# Bind button: GPIO42 (bank1 line19), active low. ar8030-lifecycled
# --bind-gpio 42 polls /sys/class/gpio/gpio42/value, which only exists
# once exported here.
echo 42 > /sys/class/gpio/export
echo in > /sys/class/gpio/gpio42/direction

# Status LEDs: red = GPIO0, green = GPIO1, both ACTIVE LOW (0 = lit). They
# share one series resistor, so a lit green starves the red: the hooks
# (/usr/share/openipc/p1-led.sh) only ever light one. Boot default: red,
# matching the "idle, never bound" state the unit is in until a link-state
# hook fires. Without this the lines float and both glow faintly.
echo 0 > /sys/class/gpio/export
echo 1 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio0/direction
echo out > /sys/class/gpio/gpio1/direction
echo 0 > /sys/class/gpio/gpio0/value
echo 1 > /sys/class/gpio/gpio1/value
