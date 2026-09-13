#!/bin/sh

# Mimic fpv_run_cx482.sh init sequence

echo "Setting up Caddx Ascent Lite muxes"

#SD0_detect, not use as gpio
devmem 0x10260028 32 0x1130

# The vendor script's "SPI0 pinmux" block used to be here, copied verbatim
# from fpv_run_cx482.sh. This board has no SPI0 peripheral behind those
# pins (the only SPI-adjacent controller in use is SPI-NAND/FMC100, a
# separate interface) -- 0x11130044/48/4c/50/54 are, on this SoC's pin
# table, the AR8030's own SDIO1 CLK/D0/D1/DETECT/PWEN lines (see
# drivers/vendor/mmc/platform/sdhci_hi3516cv610.c's SDIO1_*_OFS
# constants, all relative to the "ioconfig1"@0x11130000 regmap that
# &sdio1's iocfg_regmap phandle points at). The kernel's SDIO1 driver
# already pinmuxes them correctly at boot, before this script (S30)
# ever runs; writing here was silently reconfiguring them away from the
# SDIO1 function immediately after boot, disconnecting the AR8030 bus
# before it could ever be probed.

#UART1
devmem 0x11130030 32 0x1205
devmem 0x11130034 32 0x1205

echo 0 > /sys/class/gpio/export
echo in > /sys/class/gpio/gpio0/direction

echo 56 > /sys/class/gpio/export
echo in > /sys/class/gpio/gpio56/direction
echo 57 > /sys/class/gpio/export
echo in > /sys/class/gpio/gpio57/direction

# Status LEDs -- same two pins the vendor's fpv_run_cx482.sh drives
# (LED_R=gpio7_7/gpio63, LED_G=gpio1_0/gpio8), confirmed by hand on real
# hardware: value 1 = ON. Direction only, no value -- S67ar8030-led-status
# owns the actual on/off/blink state from first boot onward, see its own
# script for the pattern (reverse-engineered from the vendor's
# ar_ldyhs_sky binary, see ar8030-transport/README.md).
echo 63 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio63/direction
echo 8 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio8/direction
