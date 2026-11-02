# TGL port notes — what changed from the CML build, and why

Every change below is quoted/verified against the actual Linux v6.6 sources
(`sound/soc/sof/intel/`), not from memory. File/line references are
`v6.6` unless noted. The bug that stopped the TGL boot at `FAILED: core
power` was **not** the firmware blob — it was a wrong core mask plus two
inverted gating writes in the host code.

## 1. `FAILED: core power` — the root cause

Old code:

```c
wr32(dsp, DSP_ADSPCS, rd32(dsp, DSP_ADSPCS) | ADSPCS_CRST(0xF) | ADSPCS_CSTALL(0xF));
wr32(dsp, DSP_ADSPCS, rd32(dsp, DSP_ADSPCS) | ADSPCS_SPA(0xF));
poll32(dsp, DSP_ADSPCS, ADSPCS_CPA(0xF), ADSPCS_CPA(0xF), 50000);   // FAILED on TGL
```

Facts from v6.6:

- `tgl_chip_info` / `tglh_chip_info` / `cml_chip_info` / `cnl_chip_info` all
  have `host_managed_cores_mask = BIT(0)` (tgl.c, cnl.c). Only **core 0** is
  host-managed. The comment in this file that claimed
  `host_managed_cores_mask = 0xF` for CNL/CML was wrong (SKL-era value,
  hallucinated); `hda_dsp_core_power_up()` also ANDs the mask with
  `host_managed_cores_mask` before doing anything (hda-dsp.c:163).
- `hda_dsp_core_power_up()` never touches CRST/CSTALL — it only sets SPA and
  polls CPA (hda-dsp.c:155-195). It polls with
  `HDA_DSP_RESET_TIMEOUT_US = 50000` (hda.h), the same 50 ms used here.
- On TGL, cores 1-3 are owned by the firmware. Setting SPA for them is not
  something the boot flow does, and polling their CPA can never succeed →
  the old `CPA(0xF)` poll timed out on every boot.

New code: `hda_dsp_core_reset_power_down(BIT(0))` (stall+reset, clear SPA,
poll CPA==0 — the exact sequence Linux runs on its boot-retry error path),
then `SPA(BIT(0))` + poll `CPA(BIT(0))`, 50 ms.

## 2. Clock/power gating was inverted

Old code re-enabled PCI `CGCTL` bit 6 right before firmware loading and never
touched the DSP gating bits. Linux v6.6, `hda_dsp_ctrl_clock_power_gating()`
(hda-ctrl.c), called as `pre_fw_run` **before** the boot and reversed in
`post_fw_run` after FW_READY:

- `PCI_CGCTL (0x48).ADSPDCGE (bit 1)` — audio DSP clock gating: **cleared**
- `HDA_VS_INTEL_EM2 (0x1030).L1SEN (bit 13)` — DMI L1 self-enable: **cleared**
- `PCI_PGCTL (0x44).ADSPPGD (bit 2)` — audio DSP power gating: **set**
  (bit set = gating disabled). Note `PCI_PGCTL` is the same offset as
  `PCI_TCSEL`; the kext's TCSEL clear at `start()` was silently clearing
  ADSPPGD and nothing ever set it back.
- `PCI_CGCTL.MISCBDCGE (bit 6)` — cleared (as `hda_dsp_ctrl_init_chip` does);
  the old code set it.

With DSP power gating enabled, the SPA→CPA handshake can stall — on TGL this
matters; Linux explicitly disables both gating bits for the boot window.

## 3. ICCMAX capture stream (new, TGL-only, knob `iccmax=0` to disable)

v6.6 boots cAVS 2.5 (ICL/TGL) through
`hda_dsp_cl_boot_firmware_iccmax()` (hda-loader.c:273-308): an extra
**capture** stream is prepared (`hda_cl_stream_prepare(...,
SNDRV_PCM_STREAM_CAPTURE)`, PAGE_SIZE buffer), programmed by
`hda_dsp_iccmax_stream_hw_params()` (hda-stream.c:347-404) — quoted:

> /\* minimal recommended programming for ICCMAX stream \*/

it programs BDLPL/BDLPU/CBL/LVI (single BDL entry), sets the per-stream PPCTL
decouple bit, writes the LTRP guardband:

> /\* Follow HW recommendation to set the guardband value to 95us during FW boot \*/
> `HDA_VS_INTEL_LTRP (0x1048)`, `HDA_VS_INTEL_LTRP_GB_MASK 0x3F`,
> `HDA_LTRP_GB_VALUE_US 95`

and **starts the DMA** (`SOF_HDA_SD_CTL_DMA_START`). It does **not** write
SD_FMT and does **not** write the stream tag. The stream is cleaned up right
after `hda_cl_copy_fw()` (which waits for `FSR_STATE_FW_ENTERED`), success or
failure, and the original guardband byte is restored.

This kext now does the same thing for every cold boot (skipped for `imr=1`),
tearing the stream down at the same point (after the FW_ENTERED wait) and on
every early-exit path (ROM IPC timeout, INIT_DONE timeout).

## 4. Cores 1-3 power-down removed

`cl_dsp_init()` step 5 (hda-loader.c:141-149) powers down
`host_managed_cores_mask & ~init_core_mask` — which is **0** on CNL/CML/TGL,
i.e. Linux never resets or powers down cores 1-3 during boot on these SoCs.
The old unconditional `CRST|CSTALL|~SPA(0xE)` write came from the same
hallucinated `0xF` reading and is removed.

## 5. Mechanical changes

- PCI match now accepts `0xA0C8` (TGL-LP) and `0x43C8` (TGL-H) in addition to
  `0x02C8` (CML-LP); the matched ID is logged.
- `sof_firmware_embed.s` / `Makefile` embed `sof-tgl.ri`
  (XMan header, payload offset 768, 512 KiB payload — parsed by the existing
  extended-manifest skip).
- Unchanged on purpose: IPC register offsets (`HIPCTDR 0xC0 … HIPCCTL 0xE8` =
  `CNL_DSP_IPC_BASE` family, used by TGL too), `ROM_STATUS 0x80000` FSR
  polling (`FSR_STATE_FW_ENTERED = 5` is the same success value on TGL),
  purge-FW IPC word (`0x01000000 | 0x00004000 | (tag-1)<<9` — verbatim
  hda-loader.c:109-112).

## What to watch in the boot log

| Stage | Expect |
|---|---|
| `iccmax capture idx=N RUN gb .. -> ..` | iccmax stream armed before the purge IPC |
| ROM IPC | `ROM IPC DONE` within 500 ms |
| `INIT_DONE` | `rom=0x…01` within 300 ms (tgl_chip_info `rom_init_timeout=300`) |
| `FW-Entered` | `OK rom=0x00000005` within 3 s (cl DMA moved: lpib/dpib sweep) |
| `FW-Version` / `IPC-Test` | fw_ready parsed, `ROUND-TRIP OK` |
| `Topology` | the hand-built DMIC pipeline accepted (`N OK, 0 FAIL`) |

If the ROM now stalls in `FSR_WAIT_FOR_DMA_BUFFER_FULL` (`rom=0x05000001`),
that is the old CML CL-DMA symptom — on TGL check the iccmax log line first
(was the stream actually started?), then `ltrp=` knob (Linux forces GB=95 us
— this build does it automatically while `iccmax` is on).

## Lab knobs touched

| Knob | Default | Meaning |
|---|---|---|
| `iccmax` | 1 | program+run the TGL iccmax capture stream during cold boot |
| `imr` | 0 | IMR boot path (iccmax is skipped there, like Linux) |
| `prefwrun` | 0 | extra POR cycle, now with the corrected `BIT(0)` mask |

## Reference files (v6.6)

- `sound/soc/sof/intel/hda-loader.c` — `cl_dsp_init`, `hda_dsp_cl_boot_firmware_iccmax`, `hda_cl_copy_fw`
- `sound/soc/sof/intel/hda-dsp.c` — `hda_dsp_core_power_up`, `hda_dsp_core_reset_power_down`, `hda_dsp_core_run`
- `sound/soc/sof/intel/hda-ctrl.c` — `hda_dsp_ctrl_clock_power_gating`
- `sound/soc/sof/intel/hda-stream.c` — `hda_dsp_iccmax_stream_hw_params`, `HDA_LTRP_GB_VALUE_US`
- `sound/soc/sof/intel/tgl.c`, `cnl.c` — chip info (core masks, `rom_init_timeout`)
- `sound/soc/sof/intel/hda.h` — all register/bit definitions quoted above
