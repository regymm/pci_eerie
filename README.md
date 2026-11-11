# pci_eerie

![pci_eerie as a PCIe host: K480T root port and Intel Optane on an M.2 adapter](doc/setup_k480t_optane.jpg)

*The PCIe host (root port) setup: a Kintex-7 480T card (YPCB) running pci_eerie as a Gen2 x2 root
port in a PUZHI PZ-SSD x8-to-M.2 adapter with an Intel Optane NVMe SSD; it enumerates the SSD and
reads/writes its NVMe registers, driven over JTAG (see "Root port on hardware" below).*

An open-source soft PCI Express endpoint and root port for Xilinx 7-series FPGAs, written in plain
Verilog-2005 (synthesizes with Vivado and with yosys/openXC7).

pci_eerie is an IO-level drop-in replacement for the `PCIE_2_1` integrated block: it has
exactly the ports and accepts exactly the parameters of the `PCIE_2_1` primitive (both
generated from the unisim model). A design that instantiates `PCIE_2_1` (for example
[pcie_7x](https://github.com/regymm/pcie_7x)'s `pcie_block.v`, or Vivado's `pcie_7x_0_pcie_7x.v`) switches to the
soft core by renaming the module of that instance. Nothing else changes: the GT/PIPE
wrapper, clocking, the TX/RX buffer BRAMs on the MIM ports, and the AXI↔TRN bridges all
stay as they are.

Scope: endpoint or root port (selected like on `PCIE_2_1`, by `PCIE_CAP_DEVICE_PORT_TYPE`
0 or 4), x1, x2 and x4 links (`LINK_CAP_MAX_LINK_WIDTH` 1, 2, 4; an x8 build trains to x4 so far),
2.5 GT/s and 5.0 GT/s (Gen1/Gen2), 64-bit TRN interface. Gen3 is not planned.

## Status

All tests run against the Vivado example design's root port model (itself a `PCIE_2_1` in
root-port mode) over a GTX serial link in xsim, i.e. against a real PCIe implementation
rather than a BFM. Current regression (`sim/regress.sh`), all passing:

| Test | Gen1 | Gen2 |
|------|------|------|
| `pio_writeReadBack_test0`: enumeration, BAR setup, MWr/MRd through pcie_7x's AXI-lite app | pass | pass (trains at 2.5, speed change to 5.0 GT/s) |
| `eerie_mem_test`: MWr/MRd of 1..32 DW incl. odd lengths, 8 back-to-back requests (memory test app) | pass | pass |
| `eerie_int_test`: MSI (64-bit capable) write, Assert/Deassert_INTA, Interrupt Status bit | pass | |
| `eerie_ur_test`: UR completions (MRd outside BARs, IORd w/o IO BAR), posted UR drop, Set_Slot_Power_Limit, Unlock, UR status bit | pass | |
| `eerie_cfg_dump`: configuration space 0x000-0x090, 0x100-0x108 | identical to PCIE_2_1 | |
| `eerie_stress_test` (40 write/read pairs) with a bit error injected into one TLP in each direction (Nak + replay both ways) | pass | pass |

Root port: the same tests with pci_eerie in the root port model (`RP=eerie`), against the
`PCIE_2_1` endpoint and against the pci_eerie endpoint, plus two root port tests that also run
with the `PCIE_2_1` root port for comparison:

| Test | RP pci_eerie, EP PCIE_2_1 | RP pci_eerie, EP pci_eerie | RP PCIE_2_1, EP either |
|------|------|------|------|
| the 9 runs above (Gen1 and Gen2) | all pass | all pass | (above) |
| `eerie_cfg_dump` through the root port | identical to the reference | identical | |
| `rp_cfg_dump`: the root port's own config space 0x000-0x12C via `cfg_mgmt`: reset value and read-back after writing all-ones / all-zeros | identical to the `PCIE_2_1` root port | identical | reference (`sim/ref/rp_cfg_dump_hard.txt`) |
| `rp_link_test`: Retrain Link, Secondary Bus Reset, Link Disable, then endpoint access (re-enumerated after hot reset and disable) | pass | pass | pass |

At Gen2 the pci_eerie root port trains at 2.5 GT/s and changes the link to 5.0 GT/s itself, as
the `PCIE_2_1` root port does; the example root port runs its user clock at 62.5 MHz at both
rates.

Multi-lane: the endpoint is the Vivado 7-series PCIe core of the root port example, renamed and
configured as an endpoint (`EP_LANES`, `tb/eerie_tb_ep_ml.v`, `PCIE_2_1` or pci_eerie inside),
the root port model gets `RP_LANES` lanes. `ml_width_test` checks that both sides report the
expected link width and speed and moves MWr/MRd of 1..32 DW (every packet length mod 4):

| Link | EP pci_eerie, RP PCIE_2_1 | EP PCIE_2_1, RP pci_eerie | both pci_eerie | both PCIE_2_1 |
|------|------|------|------|------|
| x2 Gen1 / Gen2 | pass / pass | | | pass (Gen1) |
| x4 Gen1 / Gen2 | pass / pass | pass / pass | pass / pass | pass / pass |
| x4 EP into an x1 / x2 RP | trains x1 / x2, pass | | | x1: pass |
| x1 / x2 EP into an x4 RP | | trains x1 / x2, pass | | x1: pass |
| x8 EP build, x8 RP | trains x4, pass | | | |

Root port test design (`tb/host_tb.v`, `sim/run_host.sh`): `syn/eerie_host_rp.v`, the Vivado root
port core with pci_eerie inside plus the JTAG-driven test application `syn/eerie_host_app.v`,
built x4 Gen2, against an x2 Gen2 endpoint (the shape of the Optane SSD of the K480T test below),
driven through the application's register bus as `tools/eerie_host.tcl` does over JTAG: link,
root port config space via `cfg_mgmt`, CfgRd0/CfgWr0 enumeration, BAR sizing and assignment,
MWr32/MRd32 and a 4 DW burst through BAR0:

| Root port pci_eerie (x4 Gen2) with | result |
|------|------|
| pci_eerie endpoint, x2 Gen2 | trains 5.0 GT/s x2, pass |
| `PCIE_2_1` endpoint, x2 Gen2 | trains 5.0 GT/s x2, pass |

The x1 tests above run unchanged on the multi-lane RTL. `tb/unit/ml_phy_tb.v` loops the
multi-lane PHY (striper, per-lane TX/RX, deskew, framing) back without a GT model: 300 random
TLPs and DLLPs at x2 and x4 with per-lane skew of 0..4 symbols and SKP symbols inserted / removed
on one lane at every SKP ordered set (elastic buffer), all received intact; with `+badcrc` every
fifth TLP carries a corrupted LCRC and exactly those are flagged bad.

At Gen1, the decoded link traffic of the pio test is identical, TLP for TLP, to the
`PCIE_2_1` reference run (`sim/ref/`).

On hardware (YPCB K480T card, xc7k480t-2 GTX, `syn/vivado_impl.tcl ypcb_k480t`, timing met at
WNS +0.85 ns) in an AMD Matisse host: the card enumerates at boot and after a JTAG reprogram plus
rescan, trains to 5.0 GT/s x1, and passes BAR0 MWr/MRd random-pattern tests (300 x 256 DW, no
mismatches) with no AER errors logged at the root port, the same result as the PCIE_2_1 build.

openXC7 on the same card (`syn/Makefile.openxc7 BOARD=ypcb_k480t`, Gen1, regymm/openxc7:timecardflex for
yosys/nextpnr; nextpnr estimate 132-165 MHz PIPE clock for 125 MHz): enumerates at 2.5 GT/s x1 and passes
the same BAR0 tests (300 x 256 DW, no AER errors) after a host boot. After a JTAG reconfiguration with the
host running, the PERST#-reset build fails memory reads until the host asserts PERST# (a hot reset or link
toggle does not help; the Vivado builds do not show this); building with `TOP_PARAMS="-chparam NO_RESET 1"`
(pcie_7x's internal power-on reset instead of PERST#) makes JTAG + rescan work. The timecardflex prjxray-db
has no frame addresses for the xc7k480t GT tiles, so the bitstream steps run in an image that has them
(openxc7-stable-202608), and `tools/fasm_canon.py` expands ranged FASM features for its fasm parser.
A Gen2 openXC7 build (`-chparam ENABLE_GEN2 1`, `--freq 250`) does not work: nextpnr estimates 151.6 MHz
for the 250 MHz PIPE clock and 111.8 MHz for the 125 MHz user clock, and on the card the link trains at
2.5 GT/s but the data link layer never comes up, so the device does not enumerate.

On an Artix-7 board (Meta Time Card with an AC7100B module, xc7a100t GTP, Gen1, same host,
`syn/ac7100b_pins.xdc`): on this card the link only comes up after a host PERST# (the PCIE_2_1
build behaves the same), so each bitstream was loaded over JTAG and the host rebooted.

* Vivado, `vivado_impl.tcl ac7100b`: enumerates at 2.5 GT/s x1 and passes the BAR0 test
  (300 x 256 DW, then 10 x 256 DW after each of 5 further reboots, 3 of them with a fresh JTAG
  load; no AER errors). In one earlier boot every BAR0 read returned all-ones; it did not
  happen again in the following 6 boots, and the cause is not known. A single all-ones read
  shortly after boot also shows up occasionally with the PCIE_2_1 build on this host.
* Vivado, `vivado_impl.tcl ac7100b_msi` (pcie_7x's MSI demo top, which fires an MSI about once a
  second): with pcie_7x's `pcie_7x_msi` demo driver every MSI is received and handled, the same
  as with the PCIE_2_1 build of that demo.
* openXC7, `Makefile.openxc7` (default `BOARD=ac7100b`, nextpnr estimate 127.9 MHz PIPE clock):
  3 of 3 program/reboot cycles enumerate and pass 50 x 256 DW. `BOARD=ac7100b_msi` (134.6 MHz):
  10 MSIs in 10 s received and handled.

Multi-lane on hardware: the same Time Card, all four lanes (Time Card V9 schematic J37 and the
AC7100B CON4 table: edge lane 0..3 = GTP quad 216 channel 1, 0, 2, 3; `syn/ac7100b_x4.xdc`).
pcie_7x is x1-only, so the x4 build (`vivado_impl.tcl ac7100b_x4`, `syn/top_ac7100b_x4.v`) is the
Vivado 7-series core of the root port example configured as an endpoint with pci_eerie in place
of `PCIE_2_1` (as `tb/eerie_tb_ep_ml.v` in simulation; it needs `PCIE_EX` like the simulation)
plus the testbench memory application, 125 MHz user clock. It trains 2.5 GT/s x4 (LnkCap and
LnkSta x4 on both sides) and passes the BAR0 test (300 x 256 DW after the JTAG load and reboot;
20-50 x 256 DW in each of 6 further boots once past the boot-time power management window below;
no AER errors). xc7a100t-2 (the AC7100B part): 125 MHz PIPE clock +0.45 ns, user clock +0.56 ns;
a -1 build misses the PIPE clock by 1.2 ns.

On this host, BAR0 tests run in the first ~15 s after boot can fail (all-ones reads): the
`powertop --auto-tune` boot service sets runtime PM to `auto`, the kernel runtime-suspends the
driverless function and restores its saved Command register (0, memory decoding off) when it
resumes it (`power/runtime_suspended_time` > 0). Running the test later, or writing `on` to the
device's `power/control`, avoids it; this is not related to the core, and is likely the cause of
the occasional all-ones reads noted for the x1 builds above.

Root port on hardware (the setup in the photo at the top: PCIe host Gen2 x2 reading and writing
NVMe registers): the YPCB K480T card as an x4 root port (`syn/top_ypcb_k480t_rp.v`: the Vivado
root port core with pci_eerie in place of `PCIE_2_1`, plus `syn/eerie_host_app.v`) plugged into a PUZHI
PZ-SSD (PCIe x8 female to M.2 adapter) with an Intel Optane Memory 16 GB (8086:2522, NVMe, Gen3 x2),
controlled over JTAG. Results with `vivado_impl.tcl ypcb_k480t_rp_pzssd` (x4 Gen2) and
`ypcb_k480t_rp_pzssd_gen1`:

* the link trains x2 (down-trained from x4) at 2.5 GT/s; the Gen2 build then changes it to 5.0 GT/s
  by itself (L0, Recovery, back to L0 at 5.0 GT/s);
* CfgRd0/CfgWr0 enumeration: vendor/device 8086:2522, class 01:08:02, PCIe capability LnkCap
  8 GT/s x2 / LnkSta 2.5 or 5.0 GT/s x2, BAR0 16 KB 64-bit sized and assigned, memory and bus
  master enabled;
* NVMe registers through MRd32: CAP 0x000000200401007F (MQES 128, TO 2 s), VS 1.1.0, CC/CSTS 0;
* MWr32 + MRd32 read-back of random values on the NVMe admin queue base registers (ASQ/ACQ,
  controller disabled): 4000 pairs at 2.5 GT/s and 4000 pairs at 5.0 GT/s, no mismatches, no
  Recovery entered during the test;
* hot reset from the root port (`pl_transmit_hot_rst`), link retrains to 5.0 GT/s x2 and the SSD
  enumerates again.

Board / adapter findings:

* REFCLK: the adapter's on-board 100 MHz oscillator drives REFCLK on the edge connector, so the
  card's normal GTX reference clock input is used (as in LiteNVMe's root port bench).
* Lane order: the adapter connects M.2 lanes 0..3 to edge lanes 3..0 (the x2 SSD was detected only
  on edge lanes 2-3). pci_eerie has no lane reversal, so `syn/ypcb_k480t_rp_pzssd.xdc` places core
  lane n on edge lane 3-n; `ypcb_k480t_rp` / `_gen1` keep the straight order for other slots.
* PERST#: the FPGA controls the edge connector's PERST# pin (Y26; driven low, released as open
  drain or driven high with ctl bit 2), and reads its level back, but the SSD does not see it: its
  link stays up with PERST# held low for seconds. Either the card buffers that pin towards the FPGA
  only or the adapter does not route it. The SSD is reset by the adapter's power-up; use the hot
  reset (`wr 302 40`, `wr 302 0`) to reset it in band.
* Power: the K480T needs 3.3 V on the edge connector (B8-B10) in addition to 12 V to start; on the
  test bench a wire from the adapter's 3.3 V provides it.

Commands (`tools/eerie_host.tcl`, Vivado batch mode; 2019.1 and 2023.2 both work):

```
vivado -mode batch -source tools/prog.tcl -tclargs syn/build_ypcb_k480t_rp_pzssd_xc7k480tffg1156-2/top.bit <cable serial>
vivado -mode batch -source tools/eerie_host.tcl -tclargs <cable serial> status    # LTSSM, width, speed, PERST#
vivado -mode batch -source tools/eerie_host.tcl -tclargs <cable serial> enum      # enumerate 01:00.0, NVMe CAP/VS/CSTS
vivado -mode batch -source tools/eerie_host.tcl -tclargs <cable serial> regtest 1000   # ASQ/ACQ read-back
vivado -mode batch -source tools/eerie_host.tcl -tclargs <cable serial> pipe      # per-lane receiver detection
vivado -mode batch -source tools/eerie_host.tcl -tclargs <cable serial> trace     # LTSSM state changes
vivado -mode batch -source tools/eerie_host.tcl -tclargs <cable serial> mrd 10000008  # one MRd32
```

`pipe` reads pci_eerie's `DBGVECA` (sticky per-lane RxElecIdle / RxValid / receiver detection /
RxStatus), which `vivado_impl.tcl` brings out of the root port core through its unused
`pipe_tx_0/1_sigs` outputs; `trace` is a 64-entry LTSSM transition log in the test application.

The x4 Gen2 root port runs its 64-bit user interface at 125 MHz: enough for the x2 link the SSD
trains, half of what an x4 Gen2 partner could send (that needs 250 MHz or a 128-bit path).
Timing (xc7k480t-2): 125 MHz PIPE clock +3.06 ns, user clock +2.68 ns, but the 250 MHz PIPE clock
misses by 0.94 ns (the multi-lane receive framing's LCRC state loop, deskew, and paths into the
Vivado core's PIPE lanes), so the 5.0 GT/s build is not timing-clean although it ran without errors
on the bench; the Gen1 builds meet timing.

openXC7 root port (`syn/Makefile.openxc7 BOARD=ypcb_k480t_rp`, Gen1 by default; add
`BUILDDIR=... TOP_PARAMS="-chparam ENABLE_GEN2 0 -chparam LANES 2 -chparam UCF 1"` for the x2 build;
synthesis / place and route in regymm/openxc7:timecardflex, `top.bit` in openxc7-stable-202608, whose
prjxray-db has the GTX CPLL / GTREFCLK bit fixes): builds, and on the card the CPLLs lock, the GT reset
sequence completes, the SSD's receivers are detected and its TS1s are received (Polling.Active is
left after the 1024 TS1), but the link stops in Polling.Configuration (no TS2 from the SSD, so it
apparently does not receive ours) and returns to Detect after 48 ms. Changes the Vivado core needed
for openXC7 (`syn/core_oxc_gtx.sed`): GTXE2_CHANNEL attributes the core leaves at their defaults are
set explicitly (the openXC7 flow writes unset attributes as 0), including TXPHDLY_CFG; the CPLL
power-down override and its BUFG on the reference clock are removed (with them the CPLLs do not
lock). With these, prjxray's bit2fasm shows the same GTX channel configuration as the Vivado
bitstream; what remains is in the fabric (nextpnr estimates 128 MHz PIPE clock for the x2 build).
`tools/eerie_host.tcl gt` reads the GT wrapper's reset state (`syn/core_rp_dbg.sed`).

Timing (Vivado 2023.2, the pcie_7x board top with pci_eerie, `syn/vivado_impl.tcl`):

| Board / part                           | PIPE clock            | user clock          |
|----------------------------------------|-----------------------|---------------------|
| HVS K70T, xc7k70t-1 (GTX), Gen2        | 250 MHz: +0.45 ns     | 125 MHz: +1.19 ns   |
| AC7100B pinout, xc7a100t-2 (GTP), Gen2 | 250 MHz: +0.05 ns     | 125 MHz: +0.75 ns   |
| AC7100B, xc7a100t-1 (GTP), Gen1        | 125 MHz: +3.23 ns     | 62.5 MHz: +6.26 ns  |

With `syn/pci_eerie_timing.xdc`, the two Gen2 builds meet setup and hold on every path, and
the Gen1 build meets them for the clocks it can use (see the -1 note below). The XDC also
false-paths pcie_7x's `pclk_sel` register into the BUFGCTRL select, as Xilinx's
own PCIe constraints do; that path is in the MMCM wrapper, not in pci_eerie. In a
Gen1-only build on a -1 part, the 250 MHz group of the PIPE clock mux still reports
violations, because that clock can never be selected there. Artix-7 -1 GTPs are limited to
3.75 Gb/s (RXUSRCLK minimum period 5.33 ns), so Gen2 needs a -2/-3 Artix-7 or a Kintex-7,
whichever core is used.

openXC7 (yosys + nextpnr-xilinx, `syn/Makefile.openxc7`): the AC7100B design with pci_eerie
synthesizes, places, routes and produces a bitstream (about 6.1k LUTs for the whole design).
nextpnr-xilinx's 7-series delay model is approximate (its PIPE clock estimates are 128-135 MHz on
the AC7100B and 132 MHz on the K480T for the 125 MHz a 2.5 GT/s link needs); the Gen1 openXC7
bitstreams work on both boards (above). The Vivado numbers above are the reliable ones.

Resources (Vivado, x1 Gen2 build): pci_eerie is 3.4k LUTs (incl. 318 as LUTRAM), 3.1k FFs and
1 BRAM36, plus the two MIM BRAM buffers that `pcie_block` already instantiates (4 BRAM36 at
`VC0_RX_RAM_LIMIT = 0x3FF`). yosys `synth_xilinx` gives a similar result (about 2.8k LCs).

## Getting started

```
git clone --recursive <this repository> pci_eerie     # ext/pcie_7x is a git submodule
cd pci_eerie                                          # (or: git submodule update --init)
```

Dependencies:

* [pcie_7x](https://github.com/regymm/pcie_7x) (submodule `ext/pcie_7x`): the GT/PIPE wrapper,
  clocking, BRAMs, AXI bridges and board tops the core is integrated and tested with. The
  scripts use `$PCIE_7X` if set, else `ext/pcie_7x`, else a `pcie_7x` checkout next to this
  repository.
* Vivado 2023.2 for simulation and the Vivado builds (`$VIVADO`, default
  `/opt/Xilinx/Vivado/2023.2`).
* For simulation only: the `imports/` directory of a Vivado PCIe (7 Series Integrated Block,
  `pcie_7x`) example design adapted to pcie_7x, which provides the root port model
  (`xilinx_pcie_2_1_rport_7x.v`, `pcie_2_1_rport_7x.v`), the `pci_exp_usrapp_*` tasks,
  `sys_clk_gen*.v`, `xil_sig2pipe.v`, `pcie_axi_trn_bridge.v` and the `*.vh` test files.
  These are Xilinx files and are not part of this repository; point `$PCIE_EX` at that
  directory (default `../pcie_7x_0_ex/imports`). `sim/files_common.f` lists what is used.
* For openXC7 builds: Docker with an openXC7 image (tested with `regymm/openxc7:timecardflex`).

Quick checks:

```
sim/run.sh eerie pio_writeReadBack_test0                       # needs PCIE_EX
vivado -mode batch -source syn/vivado_impl.tcl -tclargs hvs_k70t
docker run --rm -u $(id -u):$(id -g) -v $PWD:/mnt regymm/openxc7:timecardflex \
    make -C /mnt -f syn/Makefile.openxc7                       # AC7100B, Gen1
```

## Repository layout

```
rtl/                 the core: every file listed in rtl/files.f, include directory rtl/
  pci_eerie.v        top level, PCIE_2_1 ports/parameters
  pci_eerie_ports.vh, pci_eerie_params.vh   generated from the unisim model (tools/gen_ports.py)
  eerie_pl_rx.v      PHY RX: descrambler, symbol aligner, OS/TLP/DLLP parser, LCRC/CRC16 check
  eerie_pl_tx.v      PHY TX: TS1/TS2/EIOS/SKP/EIEOS generation, packet serializer, scrambler
                     (both per lane; the lane 0 packet path serves x1 links)
  eerie_pl_deskew.v  lane-to-lane deskew (per-lane FIFOs, SKP removal, alignment on COM)
  eerie_pl_rx_ml.v   x2/x4 receive framing: DW alignment, TLP/DLLP parser, LCRC/CRC16 check
  eerie_pl_tx_ml.v   x2/x4 transmit striping, logical idle, SKP ordered set scheduling
  eerie_ltssm.v      LTSSM (upstream port): Detect..L0, Recovery incl. speed change, hot reset
  eerie_dll.v        data link layer: DL/FC init, Ack/Nak, replay, TX queue in the MIM TX BRAM
  eerie_tl_rx.v      transaction RX: RX buffer in the MIM RX BRAM, BAR decode, cfg/UR/msg handling
  eerie_tl_tx.v      transaction TX: TRN TX + internal TLPs (completions, MSI, INTx, PM messages)
  eerie_cfg.v        type-0 configuration space (PM, MSI, MSI-X, PCIe capability, DSN)
  eerie_async_fifo.v, eerie_sync.v    clock domain crossing
  eerie_funcs.vh     scrambler / CRC functions
integration/pcie_block.v   pcie_7x's pcie_block with PCIE_2_1 replaced by pci_eerie
tb/                  testbench additions: board, PIPE/TLP monitors, error injection, extra tests,
                     the memory test application (eerie_tb_app.v) on pcie_7x (eerie_tb_ep.v, x1)
                     or on the Vivado core (eerie_tb_ep_ml.v, x1..x8)
tb/unit/             multi-lane PHY loopback unit test (run_ml_phy.sh)
sim/run.sh           xsim runner (Vivado 2023.2); sim/regress.sh runs several in parallel
sim/ref/             decoded reference traces / config dumps of the PCIE_2_1 runs (endpoint and
                     root port: rp_cfg_dump_hard.txt)
syn/                 Vivado implementation script (vivado_impl.tcl), board pin and timing
                     constraints, openXC7 Makefile, top_ypcb_k480t.v (K480T top for openXC7)
                     top_ac7100b_x4.v (Time Card x4 endpoint), eerie_host_rp.v + eerie_host_app.v +
                     top_ypcb_k480t_rp.v (root port test design: Vivado core, JTAG TLP engine)
tools/pipe_decode.py PIPE trace decoder (descrambles, frames, checks CRCs)
tools/gen_ports.py   regenerates rtl/pci_eerie_ports.vh / _params.vh from the unisim model
tools/fasm_canon.py  FASM canonicalizer used by the openXC7 flow
tools/prog.tcl       JTAG programming (Vivado; selects the cable by serial)
tools/eerie_host.tcl JTAG control of the root port test design (raw JTAG, BSCANE2 USER1)
ext/pcie_7x          pcie_7x (git submodule)
doc/                 photo of the PCIe host test setup (setup_k480t_optane.jpg)
```

`integration/pcie_block.v`, `tb/board.v` and `tb/pci_exp_usrapp_tx.v` are modified Xilinx
files and carry the Xilinx notice and the Vivado WebPACK EULA note, as in pcie_7x. Everything
else is CERN-OHL-P v2 (see LICENSE) unless the file says otherwise.

## Using it

1. Add `rtl/*.v` (the list in `rtl/files.f`) to the project and put `rtl/` on the include path.
2. In the file that instantiates `PCIE_2_1`, rename the instance's module to `pci_eerie`.
   `integration/pcie_block.v` is `pcie_7x/src/pcie_block.v` with only that change.
3. Keep `USERCLK2 = USERCLK`, 64-bit TRN, with a user clock fast enough for the link: 8 bytes
   per clock carry 62.5 MHz for x1 Gen1, 125 MHz up to x2 Gen2 / x4 Gen1, 250 MHz for x4 Gen2
   (the pcie_7x x1 settings are 62.5 MHz at Gen1 and 125 MHz at Gen2; a slower clock at the same
   rate works while the traffic allows, as the example root port's 62.5 MHz at x1 Gen2).
   Lanes: `LINK_CAP_MAX_LINK_WIDTH`; the GT wrapper must provide that many PIPE lanes.
4. Root port: instantiate it with the root port parameters (`PCIE_CAP_DEVICE_PORT_TYPE = 4`,
   `HEADER_TYPE = 01h`, as Vivado's root port configuration of the core does). The type-1
   header, the root port registers and the downstream link behaviour follow from those; the
   requester/completer ID comes from `CFGDSBUSNUMBER/DEVICENUMBER/FUNCTIONNUMBER`.
5. Timing: `syn/pci_eerie_timing.xdc` shows the constraints. The core's PIPE↔user crossings
   go through gray-coded FIFOs and 2-flop synchronizers, constrained as datapath-only paths.

Parameters that matter: `LINK_CAP_MAX_LINK_SPEED`, `PL_FAST_TRAIN` (simulation timer
shortcut), `VC0_TOTAL_CREDITS_*`, `VC0_CPL_INFINITE`, `VC0_RX_RAM_LIMIT` (buffer size, same
BRAM sizing as the hard block), `VC0_TX_LASTPACKET`, `DEV_CAP_MAX_PAYLOAD_SUPPORTED`, the
BAR/ROM parameters, all configuration-space/capability parameters, `LL_REPLAY_TIMEOUT*`,
`N_FTS_*`, `UPCONFIG_CAPABLE`, `DISABLE_SCRAMBLING`. The rest are accepted and ignored.

## Simulation

```
sim/run.sh eerie    pio_writeReadBack_test0 [-testplusarg pipe_log]   # soft core
sim/run.sh baseline pio_writeReadBack_test0 [-testplusarg pipe_log]   # PCIE_2_1 reference
GEN2=1 sim/run.sh eerie ...                 # both link partners 5.0 GT/s capable
APP=1  sim/run.sh eerie eerie_mem_test      # endpoint with the testbench memory application
RP=eerie sim/run.sh baseline ...            # pci_eerie as the root port, PCIE_2_1 endpoint
RP=eerie sim/run.sh eerie ...               # pci_eerie on both sides
sim/run.sh baseline rp_cfg_dump             # root port's own config space (diff vs sim/ref)
EP_LANES=4 sim/run.sh eerie ml_width_test   # x4 (Vivado core endpoint, x4 root port model)
EP_LANES=4 RP_LANES=1 sim/run.sh eerie ml_width_test   # x4 endpoint in an x1 slot
sim/regress.sh ml                           # multi-lane matrix (12 runs)
tb/unit/run_ml_phy.sh 4 00010302            # PHY loopback, x4, lane skews 2,3,1,0 symbols
PLUSARGS="-testplusarg elastic" tb/unit/run_ml_phy.sh 2   # with SKP insertion / removal
sim/run.sh eerie eerie_stress_test -testplusarg inject_rx_tlp=12 -testplusarg inject_tx_tlp=9
python3 tools/pipe_decode.py sim/build_eerie/pipe.log | less
sim/regress.sh                              # full regression (the 9 runs in the Status table)
sim/regress.sh "GEN2=1 pio_writeReadBack_test0" "APP=1 eerie_mem_test"   # chosen runs
sim/regress.sh "RP=eerie CFG=baseline APP=1 eerie_mem_test"              # CFG=: endpoint core
sim/regress.sh rp baseline                 # root port regression (11 runs), PCIE_2_1 endpoint
sim/run_host.sh [eerie|baseline]           # root port test design (x4 Gen2) vs an x2 Gen2 endpoint
PLUSARGS="-testplusarg badcrc" tb/unit/run_ml_phy.sh 4    # every 5th TLP with a bad LCRC, must be flagged
```

The endpoint side is `baseline` (`PCIE_2_1` in pcie_7x) or `eerie`. `RP=eerie` builds the root
port model with its one `PCIE_2_1` instance renamed to `pci_eerie` (a generated copy of
`pcie_2_1_rport_7x.v` in the build directory); `RP=hard` (default) keeps `PCIE_2_1`. The same
tests run with all four combinations.

Each run takes about 10-30 minutes (Vivado 2023.2 xsim, GTX model on both sides); the Gen2
stress test is the longest. `eerie_mem_test` and `eerie_int_test` need `APP=1`: they use the
testbench memory application (tb/eerie_tb_ep.v), which also implements the interrupt trigger at
BAR0 + 0xFF0. Without it `eerie_int_test` waits for an MSI that never comes and fails.
Every run prints "Check Device/Vendor ID - FAILED" / "SYSTEM CHECK FAILED" from the stock
system check, which expects the example design's IDs; the result is the
"Test Completed Successfully" / "TEST FAILED" line at the end.

Plusargs: `pipe_log` (PIPE symbol log), `pipe_ctl` (PIPE control signal changes),
`dll_mon` (DLL/TL internal events), `rp_mon_verbose` (every TLP seen by the root port),
`inject_rx_tlp=N` / `inject_tx_tlp=N` (flip a bit inside the N-th TLP received/sent by
the endpoint, at the PIPE).

## Architecture

```
            PIPE clock domain                              user clock domain
 PIPE RX -> eerie_pl_rx --(82b async FIFO)--> eerie_dll -> eerie_tl_rx -> TRN RX
                 |  OS events                    |  ^        |  ^  cfg      (MIM RX BRAM)
             eerie_ltssm                        Ack/Nak     eerie_cfg
                 |  mode/TS fields               v  |        |  v  completions/MSI/msgs
 PIPE TX <- eerie_pl_tx <--(67b packet FIFO)-- eerie_dll <- eerie_tl_tx <- TRN TX
                                             (MIM TX BRAM: TLP queue + replay buffer)
```

* **PHY.** Two symbols per PIPE clock (16-bit PIPE, 125/250 MHz), pipelined for 250 MHz.
  The receiver descrambles in arrival order, then aligns so that every start symbol
  (COM/STP/SDP) lands in the first slot of a pair. Packets and ordered sets have even
  length, so a parity change is always preceded by a filler symbol (SKP or logical idle),
  and the aligner drops it. LCRC is checked with a residue check and DLLP CRC16
  incrementally. TLPs reach the DLL DW-aligned in 64-bit beats, followed by an end marker
  that carries the status. The transmitter sends EIEOS at 5 GT/s as required, and sends
  only logical idle in Configuration.Idle / Recovery.Idle.
* **DLL.** The TX queue and the replay buffer are one ring buffer in the TX BRAM, indexed by
  a descriptor ring. A single send pointer serves both new (credit-gated) transmissions and
  replays. Sequence number and LCRC are added on the fly by the framer (STP/seq/LCRC/END),
  so a replay just re-frames the stored TLP. Acks are cumulative and processed in two steps.
  The replay timer runs only in L0, and REPLAY_NUM rollover retrains the link.
* **TL.** Received TLPs are written speculatively into the RX BRAM and committed or rewound
  when the end marker arrives. One read engine feeds either the TRN RX port or the internal
  handler, which runs CfgRd0/CfgWr0, generates UR completions and decodes messages. Credits
  are returned (UpdateFC) as buffer space is freed. Internal TLPs are inserted between user
  packets through the `tx_cfg_req`/`tx_cfg_gnt` handshake, with `trn_tdst_rdy` dropped for
  that window, the way the pcie_7x throttle logic expects. Every TRN TX beat is accepted,
  because the pcie_7x AXI→TRN bridge cannot hold data.

## Supported / not supported

Supported: Gen1/Gen2 x1 link training (polarity inversion, speed change, EIEOS), scrambling,
SKP insertion, Ack/Nak with replay and replay timer, flow control (finite P/NP, infinite
completions), BAR decode (32/64-bit memory, IO, expansion ROM), configuration space with
PM/MSI/MSI-X/PCIe/DSN capabilities and the `cfg_mgmt` port, capture of bus/device number,
UR completions, MSI and legacy INTx, PME_Turn_Off/PME_TO_Ack, PM_PME, Set_Slot_Power_Limit,
hot reset and link disable (as upstream port).

Root port (`PCIE_CAP_DEVICE_PORT_TYPE = 4`): downstream link training (link and lane number
assignment), autonomous speed change to 5.0 GT/s after the link comes up (when both sides
support it and Link Control 2 allows it), Retrain Link, Link Disable and hot reset (Secondary
Bus Reset or `PLTRANSMITHOTRST`) as the directing side; type-1 header and the root port
registers of the PCIe capability (slot status, Root Control, Root Status with PM_PME capture),
matching the `PCIE_2_1` root port register for register (`rp_cfg_dump`); configuration space
kept across link down; requests from the link (memory/IO, e.g. DMA and MSI writes) delivered on
TRN RX while Bus Master Enable is set (UR otherwise, with BAR hits for the root port's own
BAR0/BAR1), configuration requests from the link answered with UR, received messages decoded
onto `CFGMSGRECEIVED*` (INTx, ERR_*, PM_PME, PME_TO_Ack, PM_Active_State_Nak) and not
forwarded, the same as `PCIE_2_1` with `ENABLE_MSG_ROUTE = 0`.

Multi-lane (x2, x4): per-lane receiver detection, polarity and ordered sets, link width
negotiation as upstream and downstream port (the lanes that keep up in Polling and echo the link
number; partner lanes beyond the width get PAD lane numbers), down-training to x2 / x1, lane
deskew (SKP removal per lane, alignment on COM), x2/x4 framing and striping, lanes outside the
link in electrical idle. The receive framing handles two DWs per PIPE clock in three stages (DW
assembly; symbol decode into per-DW roles; data path): the LCRC is linear, so the data terms of
each DW are computed a stage early and the state update is a flat XOR of the registered state,
and the residue is compared when the entry leaves the output queue.

Not supported yet: lane reversal; x8 (an x8 build trains to x4: x8 Gen2 needs 16 bytes per
clock, a 128-bit DLL / TL / TRN); initiating L0s/L1/L2 (the core never enters ASPM or
PM L1 itself; its receiver tolerates the link partner's L0s); AER/ECRC; ERR_* error
messages; VC/RBAR/VSEC capabilities; USERCLK2 ≠ USERCLK; 128-bit TRN; `rx_np_ok`
throttling (non-posted requests are not held back); the DLLP and `PL2*`/`LL2*`/`TL2*` side
interfaces of `PCIE_2_1` (mostly tied off). As a root port: directed link changes on
`PLDIRECTEDLINK*` (only the autonomous speed change), `ENABLE_MSG_ROUTE` (messages are never
forwarded to TRN RX), sending PME_Turn_Off (`CFGPMSENDPMETON`), AER root error collection,
slot/hot-plug registers (Presence Detect State reads 1), routing by the bridge windows;
with a 62.5 MHz user clock at 5.0 GT/s the replay timer runs twice as long as required.

## Integration notes

Found while bringing the core up with `pcie_7x`:

* `pcie_7x_top_aximm` leaves `cfg_pciecap_interrupt_msgnum` undriven. In simulation its X
  reaches the PCIe capability register and corrupts the completion for config offset 0x60,
  which stalls the link (it happens with `PCIE_2_1` as well). pci_eerie reads undriven
  configuration-style inputs as their hardware value in simulation (data 0, active-low
  requests inactive). The testbench forces the port to 0 for the baseline runs.
* `pcie_block.v` never drives `cfg_turnoff_ok_w` (`CFGPMTURNOFFOKN`), so no PME_TO_Ack is
  ever sent through that wrapper, by either core.
* With the GTP model, Vivado 2023.2 rejects `SIM_VERSION "3.0"`; the testbench uses the GTX
  wrapper (`GT_DEVICE "GTX"`).

## Extending

* **x8.** The PHY parts are written for N lanes (deskew, LTSSM); x8 needs framing / striping
  of 16 symbols per clock and, for x8 Gen2 (4 GB/s), a 128-bit DLL / TL / TRN path (PCIE_2_1
  uses 128 bits at 250 MHz there), which also lets x4 Gen2 run at a 125 MHz user clock. The
  RX/TX buffers would move from the 64-bit MIM ports to internal 128-bit RAMs.
* **Root port.** Implemented (see above); the DLL is shared unchanged, the port role changes
  the LTSSM's Configuration and Recovery/Hot Reset/Disabled branches, the configuration space
  layout and the TL RX routing (`DSP` parameters of `eerie_ltssm` / `eerie_tl_rx`).
