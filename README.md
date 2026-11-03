# pci_eerie

An open-source soft PCI Express endpoint for Xilinx 7-series FPGAs, written in plain
Verilog-2005 (synthesizes with Vivado and with yosys/openXC7).

pci_eerie is an IO-level drop-in replacement for the `PCIE_2_1` integrated block: it has
exactly the ports and accepts exactly the parameters of the `PCIE_2_1` primitive (both
generated from the unisim model). A design that instantiates `PCIE_2_1` (for example
[pcie_7x](https://github.com/regymm/pcie_7x)'s `pcie_block.v`, or Vivado's `pcie_7x_0_pcie_7x.v`) switches to the
soft core by renaming the module of that instance. Nothing else changes: the GT/PIPE
wrapper, clocking, the TX/RX buffer BRAMs on the MIM ports, and the AXI↔TRN bridges all
stay as they are.

Scope: endpoint, x1, 2.5 GT/s and 5.0 GT/s (Gen1/Gen2), 64-bit TRN interface. Gen3 is not
planned. The structure leaves room for more lanes and a root-port mode (see "Extending").

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

openXC7 (yosys + nextpnr-xilinx, `syn/Makefile.openxc7`): the AC7100B design with
pci_eerie synthesizes, places, routes and produces a bitstream (about 6.1k LUTs for the whole
design). nextpnr-xilinx's post-placement estimate is 112.7 MHz for the PIPE clock, below the
125 MHz a 2.5 GT/s link needs. Its 7-series delay model is approximate and this build prints
no post-route critical path, so whether an openXC7 bitstream holds 125 MHz in hardware is
still open. The Vivado numbers above are the reliable ones.

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
  eerie_ltssm.v      LTSSM (upstream port): Detect..L0, Recovery incl. speed change, hot reset
  eerie_dll.v        data link layer: DL/FC init, Ack/Nak, replay, TX queue in the MIM TX BRAM
  eerie_tl_rx.v      transaction RX: RX buffer in the MIM RX BRAM, BAR decode, cfg/UR/msg handling
  eerie_tl_tx.v      transaction TX: TRN TX + internal TLPs (completions, MSI, INTx, PM messages)
  eerie_cfg.v        type-0 configuration space (PM, MSI, MSI-X, PCIe capability, DSN)
  eerie_async_fifo.v, eerie_sync.v    clock domain crossing
  eerie_funcs.vh     scrambler / CRC functions
integration/pcie_block.v   pcie_7x's pcie_block with PCIE_2_1 replaced by pci_eerie
tb/                  testbench additions: board, PIPE/TLP monitors, error injection, extra tests,
                     a memory test application (eerie_tb_ep.v)
sim/run.sh           xsim runner (Vivado 2023.2); sim/regress.sh runs several in parallel
sim/ref/             decoded reference traces of the PCIE_2_1 runs
syn/                 Vivado implementation script (vivado_impl.tcl), board pin and timing
                     constraints, openXC7 Makefile, top_ypcb_k480t.v (K480T top for openXC7)
tools/pipe_decode.py PIPE trace decoder (descrambles, frames, checks CRCs)
tools/gen_ports.py   regenerates rtl/pci_eerie_ports.vh / _params.vh from the unisim model
tools/fasm_canon.py  FASM canonicalizer used by the openXC7 flow
ext/pcie_7x          pcie_7x (git submodule)
```

`integration/pcie_block.v`, `tb/board.v` and `tb/pci_exp_usrapp_tx.v` are modified Xilinx
files and carry the Xilinx notice and the Vivado WebPACK EULA note, as in pcie_7x. Everything
else is CERN-OHL-P v2 (see LICENSE) unless the file says otherwise.

## Using it

1. Add `rtl/*.v` (the list in `rtl/files.f`) to the project and put `rtl/` on the include path.
2. In the file that instantiates `PCIE_2_1`, rename the instance's module to `pci_eerie`.
   `integration/pcie_block.v` is `pcie_7x/src/pcie_block.v` with only that change.
3. Keep `USERCLK2 = USERCLK`, 64-bit TRN (the pcie_7x settings: 62.5 MHz user clock at Gen1,
   125 MHz at Gen2).
4. Timing: `syn/pci_eerie_timing.xdc` shows the constraints. The core's PIPE↔user crossings
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
sim/run.sh eerie eerie_stress_test -testplusarg inject_rx_tlp=12 -testplusarg inject_tx_tlp=9
python3 tools/pipe_decode.py sim/build_eerie/pipe.log | less
sim/regress.sh                              # full regression (the 9 runs in the Status table)
sim/regress.sh "GEN2=1 pio_writeReadBack_test0" "APP=1 eerie_mem_test"   # chosen runs
```

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

Not supported yet: more than one lane; initiating L0s/L1/L2 (the core never enters ASPM or
PM L1 itself; its receiver tolerates the link partner's L0s); AER/ECRC; ERR_* error
messages; VC/RBAR/VSEC capabilities; USERCLK2 ≠ USERCLK; 128-bit TRN; `rx_np_ok`
throttling (non-posted requests are not held back); the DLLP and `PL2*`/`LL2*`/`TL2*` side
interfaces of `PCIE_2_1` (mostly tied off); downstream (root port) operation.

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

* **More lanes.** `eerie_pl_rx`/`eerie_pl_tx` are per-lane. A xN link needs one instance of
  each per lane, a lane-deskew stage, an LTSSM that tracks TS reception per lane and assigns
  lane numbers, and a wider packet path towards the DLL (the DLL and TL already work on
  64-bit beats; x4 Gen2 needs 128 bits at 250 MHz or 64 bits at 500 MB/s per 125 MHz beat).
* **Root port.** It needs the downstream LTSSM variants (link/lane number assignment in
  Configuration, directed speed change), a type-1 header, and swapping the endpoint-only
  TL rules (completer ID capture, BAR filtering). The DLL is symmetric.
