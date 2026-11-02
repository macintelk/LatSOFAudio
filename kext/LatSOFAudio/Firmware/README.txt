This build embeds `sof-tgl.ri` (Tiger Lake, cAVS 2.5). It is placed in this
directory and embedded at link time:

    kext/LatSOFAudio/Firmware/sof-tgl.ri

To use a different SoC firmware (e.g. `sof-cml.ri` for Comet Lake), download
it from the official Sound Open Firmware binary releases:

    https://github.com/thesofproject/sof-bin/releases

then update the path in BOTH places:

    kext/LatSOFAudio/sof_firmware_embed.s   (.incbin line)
    kext/Makefile                           (make dependency)

SOF firmware is dual-licensed BSD-3-Clause / GPL-2.0 by its upstream
authors (Intel / NXP et al.) — see the sof-bin repository for details.
This project embeds it unmodified at build time only.
