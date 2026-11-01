#!/bin/bash
# ----------------------------------------------------------------------------------
#  Title      : Configure the audio codec SSM2603 of the Zybo Z7 for MiSTer
#  Project    : fpga-mister
#  File       : ssm2603-init.sh (/usr/local/sbin)
#  Author     : Konstantin Schmidt (mr_pleasant@gmx.de)
#  Company    : OHRZ
#  Created    : 2026-10-28
# ----------------------------------------------------------------------------------
#  Description: The PL (audio_out of sys_top) is the I2S master: MCLK = clk_audio
#               (24.576 MHz), BCLK = 64 x 48 kHz / 2 (32 bits per frame), I2S format,
#               16 bit, 48 kHz (MiSTer.ini hdmi_audio_96k=0). The codec runs as slave
#               with MCLK / 2 = 12.288 MHz (256 fs, normal mode) and drives the headphone
#               output from the DAC. Power-up sequence of the data sheet: everything but
#               the output stage, the registers, VMID settling, ACTIVE, the output stage.
#               Register write: byte 1 = register << 1 | data bit 8, byte 2 = data 7:0.
#               Environment: SSM2603_BUS (I2C bus, default 0), SSM2603_HP_VOL (headphone
#               volume 0x30..0x7f, 0x79 = 0 dB, 1 dB steps), SSM2603_I2CSET (command,
#               default i2cset; a test passes a logger).
# ----------------------------------------------------------------------------------
#  Copyright (c) 2026 by OHRZ
# ----------------------------------------------------------------------------------
set -euo pipefail

bus=${SSM2603_BUS:-0}
hp_vol=${SSM2603_HP_VOL:-0x79}
i2cset=${SSM2603_I2CSET:-i2cset}
addr=0x1a

wr() {   # wr <register> <9-bit value>
    $i2cset -y "$bus" "$addr" "$(( ($1 << 1) | ($2 >> 8) ))" "$(( $2 & 0xff ))"
}

wr 0x0f 0x000                       # R15 software reset
wr 0x06 0x077                       # R6  power: DAC on; line in, mic, ADC, output, oscillator, CLKOUT off
wr 0x02 $(( 0x100 | hp_vol ))       # R2  headphone volume, both channels (LRHPBOTH)
wr 0x04 0x012                       # R4  analog path: DAC selected, no bypass, no sidetone, mic muted
wr 0x05 0x000                       # R5  digital path: DAC not muted, no de-emphasis
wr 0x07 0x002                       # R7  interface: slave, I2S, 16 bit
wr 0x08 0x040                       # R8  sampling: CLKDIV2 (MCLK / 2), normal mode, SR 0, BOSR 0 = 48 kHz
sleep 0.1                           # VMID settles (data sheet: about C x 25 kOhm / 3.5)
wr 0x09 0x001                       # R9  ACTIVE
wr 0x06 0x067                       # R6  output stage on
echo "SSM2603 on i2c-$bus configured: I2S slave, 16 bit, 48 kHz, headphone volume $hp_vol"
