#!/bin/sh

# Mimic fpv_run_cx482.sh init sequence

echo "Setting up Caddx Ascent Lite muxes"

#SD0_detect, not use as gpio
devmem 0x10260028 32 0x1130

#SPI0 pinmux
devmem 0x11130050 32 0x1106
devmem 0x11130054 32 0x1106
devmem 0x1113004c 32 0x1106
devmem 0x11130048 32 0x1106
devmem 0x11130044 32 0x1202

#UART1
devmem 0x11130030 32 0x1205
devmem 0x11130034 32 0x1205

echo 0 > /sys/class/gpio/export
echo in > /sys/class/gpio/gpio0/direction

echo 56 > /sys/class/gpio/export
echo in > /sys/class/gpio/gpio56/direction
echo 57 > /sys/class/gpio/export
echo in > /sys/class/gpio/gpio57/direction
