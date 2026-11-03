// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: Type-0 configuration space (single function endpoint)
//
// Register values use little-endian register order: rdata[7:0] is the byte at
// the lowest address.  Parameters follow PCIE_2_1 names where they exist.
`timescale 1ns / 1ps
module eerie_cfg #(
    parameter [23:0]  CLASS_CODE = 24'h058000,
    parameter [31:0]  BAR0 = 32'hFFFFF000,
    parameter [31:0]  BAR1 = 32'h00000000,
    parameter [31:0]  BAR2 = 32'h00000000,
    parameter [31:0]  BAR3 = 32'h00000000,
    parameter [31:0]  BAR4 = 32'h00000000,
    parameter [31:0]  BAR5 = 32'h00000000,
    parameter [31:0]  EXPANSION_ROM = 32'h00000000,
    parameter [31:0]  CARDBUS_CIS_POINTER = 32'h00000000,
    parameter [7:0]   HEADER_TYPE = 8'h00,
    parameter [7:0]   INTERRUPT_PIN = 8'h1,
    parameter [7:0]   CAPABILITIES_PTR = 8'h40,
    parameter         CMD_INTX_IMPLEMENTED = "TRUE",
    // PM
    parameter         PM_CAP_ON = "TRUE",
    parameter [7:0]   PM_BASE_PTR = 8'h40,
    parameter [7:0]   PM_CAP_NEXTPTR = 8'h48,
    parameter         PM_CAP_VERSION = 3,
    parameter         PM_CAP_PME_CLOCK = "FALSE",
    parameter         PM_CAP_DSI = "FALSE",
    parameter         PM_CAP_AUXCURRENT = 0,
    parameter         PM_CAP_D1SUPPORT = "FALSE",
    parameter         PM_CAP_D2SUPPORT = "FALSE",
    parameter [4:0]   PM_CAP_PMESUPPORT = 5'h00,
    parameter         PM_CSR_NOSOFTRST = "TRUE",
    // MSI
    parameter         MSI_CAP_ON = "TRUE",
    parameter [7:0]   MSI_BASE_PTR = 8'h48,
    parameter [7:0]   MSI_CAP_NEXTPTR = 8'h60,
    parameter         MSI_CAP_MULTIMSGCAP = 0,
    parameter         MSI_CAP_64_BIT_ADDR_CAPABLE = "TRUE",
    parameter         MSI_CAP_PER_VECTOR_MASKING_CAPABLE = "FALSE",
    // MSI-X
    parameter         MSIX_CAP_ON = "FALSE",
    parameter [7:0]   MSIX_BASE_PTR = 8'h9C,
    parameter [7:0]   MSIX_CAP_NEXTPTR = 8'h00,
    parameter [10:0]  MSIX_CAP_TABLE_SIZE = 11'h000,
    parameter         MSIX_CAP_TABLE_BIR = 0,
    parameter [28:0]  MSIX_CAP_TABLE_OFFSET = 29'h0,
    parameter         MSIX_CAP_PBA_BIR = 0,
    parameter [28:0]  MSIX_CAP_PBA_OFFSET = 29'h0,
    // PCI Express capability
    parameter [7:0]   PCIE_BASE_PTR = 8'h60,
    parameter [7:0]   PCIE_CAP_NEXTPTR = 8'h00,
    parameter [3:0]   PCIE_CAP_CAPABILITY_VERSION = 4'h2,
    parameter [3:0]   PCIE_CAP_DEVICE_PORT_TYPE = 4'h0,
    parameter         PCIE_CAP_SLOT_IMPLEMENTED = "FALSE",
    parameter integer DEV_CAP_MAX_PAYLOAD_SUPPORTED = 2,
    parameter integer DEV_CAP_PHANTOM_FUNCTIONS_SUPPORT = 0,
    parameter         DEV_CAP_EXT_TAG_SUPPORTED = "FALSE",
    parameter integer DEV_CAP_ENDPOINT_L0S_LATENCY = 0,
    parameter integer DEV_CAP_ENDPOINT_L1_LATENCY = 7,
    parameter         DEV_CAP_ROLE_BASED_ERROR = "TRUE",
    parameter         DEV_CAP_FUNCTION_LEVEL_RESET_CAPABLE = "FALSE",
    parameter         DEV_CONTROL_EXT_TAG_DEFAULT = "FALSE",
    parameter [3:0]   LINK_CAP_MAX_LINK_SPEED = 4'h1,
    parameter [5:0]   LINK_CAP_MAX_LINK_WIDTH = 6'h1,
    parameter         LINK_CAP_ASPM_SUPPORT = 1,
    parameter         LINK_CAP_L0S_EXIT_LATENCY_GEN1 = 7,
    parameter         LINK_CAP_L0S_EXIT_LATENCY_GEN2 = 7,
    parameter         LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN1 = 7,
    parameter         LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN2 = 7,
    parameter         LINK_CAP_L1_EXIT_LATENCY_GEN1 = 7,
    parameter         LINK_CAP_L1_EXIT_LATENCY_GEN2 = 7,
    parameter         LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN1 = 7,
    parameter         LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN2 = 7,
    parameter         LINK_CAP_CLOCK_POWER_MANAGEMENT = "FALSE",
    parameter         LINK_CAP_SURPRISE_DOWN_ERROR_CAPABLE = "FALSE",
    parameter         LINK_CAP_DLL_LINK_ACTIVE_REPORTING_CAP = "FALSE",
    parameter         LINK_CAP_LINK_BANDWIDTH_NOTIFICATION_CAP = "FALSE",
    parameter         LINK_CAP_ASPM_OPTIONALITY = "FALSE",
    parameter         LINK_STATUS_SLOT_CLOCK_CONFIG = "FALSE",
    parameter [3:0]   LINK_CTRL2_TARGET_LINK_SPEED = 4'h0,
    parameter         LINK_CTRL2_DEEMPHASIS = "FALSE",
    parameter [3:0]   CPL_TIMEOUT_RANGES_SUPPORTED = 4'h2,
    parameter         CPL_TIMEOUT_DISABLE_SUPPORTED = "FALSE",
    // DSN extended capability
    parameter         DSN_CAP_ON = "FALSE",
    parameter [11:0]  DSN_BASE_PTR = 12'h100,
    parameter [11:0]  DSN_CAP_NEXTPTR = 12'h000
) (
    input             clk,
    input             rst,

    // access port (from TLP config requests or the management interface)
    input             req_v,
    input             req_wr,
    input      [9:0]  req_dwaddr,
    input      [3:0]  req_be,
    input      [31:0] req_wdata,
    input             req_rw1c_as_rw,  // management write: RW1C bits written as RW
    input             req_ro_wr,       // management write: allow writing read-only bits (subset)
    output reg [31:0] rd_data,         // valid the cycle after req_v

    // identity
    input      [15:0] vend_id,
    input      [15:0] dev_id,
    input      [7:0]  rev_id,
    input      [15:0] subsys_vend_id,
    input      [15:0] subsys_id,
    input      [63:0] dsn,
    input      [4:0]  pciecap_int_msgnum,

    // status inputs
    input      [3:0]  link_speed,      // current link speed (1/2)
    input      [5:0]  link_width,
    input             link_training,
    input             dll_active,
    input             intx_status,     // legacy interrupt pending
    input             trn_pending,
    input             set_ur_detected,
    input             set_corr_detected,
    input             set_nonfatal_detected,
    input             set_fatal_detected,
    input             set_sig_target_abort,
    input             set_rcv_master_abort,
    input             set_sig_sys_error,
    input             set_detected_parity,
    input             set_master_data_parity,
    input             set_rcv_target_abort,
    input             set_pme_status,
    input             slot_pwr_v,
    input      [9:0]  slot_pwr,        // {scale[1:0], value[7:0]} from Set_Slot_Power_Limit

    // decoded control outputs
    output     [15:0] command,
    output     [15:0] status,
    output     [15:0] dev_control,
    output     [15:0] dev_status,
    output     [15:0] link_control,
    output     [15:0] link_status,
    output     [15:0] dev_control2,
    output     [15:0] link_control2,
    output     [1:0]  pm_power_state,
    output            pm_pme_en,
    output            pm_pme_status,
    output            msi_enable,
    output     [2:0]  msi_mme,
    output     [63:0] msi_addr,
    output     [15:0] msi_data,
    output            msix_enable,
    output            msix_fmask,
    output     [7:0]  int_line,
    output reg        flr_pulse,
    // BARs (masked values, type bits stripped) for address decode
    output     [31:0] bar0, bar1, bar2, bar3, bar4, bar5, rom_bar,
    output            rom_en
);
    localparam ISON_PM   = (PM_CAP_ON == "TRUE");
    localparam ISON_MSI  = (MSI_CAP_ON == "TRUE");
    localparam ISON_MSIX = (MSIX_CAP_ON == "TRUE");
    localparam ISON_DSN  = (DSN_CAP_ON == "TRUE");
    localparam MSI64     = (MSI_CAP_64_BIT_ADDR_CAPABLE == "TRUE");
    localparam MSIPVM    = (MSI_CAP_PER_VECTOR_MASKING_CAPABLE == "TRUE");

    function [31:0] bar_mask;     // writable bits of a BAR
        input [31:0] p;
        if (p == 32'd0) bar_mask = 32'd0;
        else if (p[0]) bar_mask = {p[31:2], 2'b00};
        else bar_mask = {p[31:4], 4'b0000};
    endfunction
    function [31:0] bar_ro;       // read-only type bits
        input [31:0] p;
        if (p == 32'd0) bar_ro = 32'd0;
        else if (p[0]) bar_ro = {30'd0, 2'b01};
        else bar_ro = {28'd0, p[3:0]};
    endfunction
    // upper half of a 64-bit BAR: all mask bits writable
    function [31:0] bar_mask_hi;
        input [31:0] p;
        bar_mask_hi = p;
    endfunction
    localparam BAR1_HI = !BAR0[0] && BAR0[2:1] == 2'b10;
    localparam BAR3_HI = !BAR2[0] && BAR2[2:1] == 2'b10;
    localparam BAR5_HI = !BAR4[0] && BAR4[2:1] == 2'b10;
    localparam [31:0] M0 = bar_mask(BAR0), M2 = bar_mask(BAR2), M4 = bar_mask(BAR4);
    localparam [31:0] M1 = BAR1_HI ? BAR1 : bar_mask(BAR1);
    localparam [31:0] M3 = BAR3_HI ? BAR3 : bar_mask(BAR3);
    localparam [31:0] M5 = BAR5_HI ? BAR5 : bar_mask(BAR5);
    localparam [31:0] R0 = bar_ro(BAR0), R2 = bar_ro(BAR2), R4 = bar_ro(BAR4);
    localparam [31:0] R1 = BAR1_HI ? 32'd0 : bar_ro(BAR1);
    localparam [31:0] R3 = BAR3_HI ? 32'd0 : bar_ro(BAR3);
    localparam [31:0] R5 = BAR5_HI ? 32'd0 : bar_ro(BAR5);
    localparam [31:0] MROM = (EXPANSION_ROM == 32'd0) ? 32'd0 : {EXPANSION_ROM[31:11], 11'd0};

    // ---------------- registers ----------------
    reg [15:0] r_cmd;          // bits 0,1,2,6,8,10
    reg [15:0] r_sts;          // RW1C bits 8,11..15
    reg [7:0]  r_cls, r_intline;
    reg [31:0] r_bar0, r_bar1, r_bar2, r_bar3, r_bar4, r_bar5, r_rom;
    reg        r_rom_en;
    reg [1:0]  r_pm_state;
    reg        r_pme_en, r_pme_sts;
    reg        r_msi_en; reg [2:0] r_msi_mme; reg [31:0] r_msi_alo, r_msi_ahi; reg [15:0] r_msi_data;
    reg [31:0] r_msi_mask;
    reg        r_msix_en, r_msix_fm;
    reg [15:0] r_devctl;       // bit 15 (FLR) not stored
    reg [3:0]  r_devsts;       // RW1C 0..3
    reg [15:0] r_lnkctl;
    reg [15:0] r_devctl2;
    reg [15:0] r_lnkctl2;
    reg [9:0]  r_slot_pwr;

    // ---------------- read-only images ----------------
    wire [2:0]  mps_sup  = DEV_CAP_MAX_PAYLOAD_SUPPORTED;
    wire [31:0] devcap = {3'b000,
                          (DEV_CAP_FUNCTION_LEVEL_RESET_CAPABLE == "TRUE"),
                          r_slot_pwr[9:8], r_slot_pwr[7:0], 2'b00,
                          (DEV_CAP_ROLE_BASED_ERROR == "TRUE"), 3'b000,
                          DEV_CAP_ENDPOINT_L1_LATENCY[2:0], DEV_CAP_ENDPOINT_L0S_LATENCY[2:0],
                          (DEV_CAP_EXT_TAG_SUPPORTED == "TRUE"), DEV_CAP_PHANTOM_FUNCTIONS_SUPPORT[1:0], mps_sup};
    wire        comclk = r_lnkctl[6];
    wire [2:0]  l0s_exit = (LINK_CAP_MAX_LINK_SPEED >= 2) ?
                           (comclk ? LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN2 : LINK_CAP_L0S_EXIT_LATENCY_GEN2) :
                           (comclk ? LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN1 : LINK_CAP_L0S_EXIT_LATENCY_GEN1);
    wire [2:0]  l1_exit  = (LINK_CAP_MAX_LINK_SPEED >= 2) ?
                           (comclk ? LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN2 : LINK_CAP_L1_EXIT_LATENCY_GEN2) :
                           (comclk ? LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN1 : LINK_CAP_L1_EXIT_LATENCY_GEN1);
    wire [1:0]  aspm_sup = LINK_CAP_ASPM_SUPPORT;
    wire [31:0] lnkcap = {8'd0, 1'b0, (LINK_CAP_ASPM_OPTIONALITY == "TRUE"),
                          (LINK_CAP_LINK_BANDWIDTH_NOTIFICATION_CAP == "TRUE"),
                          (LINK_CAP_DLL_LINK_ACTIVE_REPORTING_CAP == "TRUE"),
                          (LINK_CAP_SURPRISE_DOWN_ERROR_CAPABLE == "TRUE"),
                          (LINK_CAP_CLOCK_POWER_MANAGEMENT == "TRUE"),
                          l1_exit, l0s_exit, aspm_sup, LINK_CAP_MAX_LINK_WIDTH, LINK_CAP_MAX_LINK_SPEED};
    assign link_status = {2'b00, dll_active && (LINK_CAP_DLL_LINK_ACTIVE_REPORTING_CAP == "TRUE"),
                          (LINK_STATUS_SLOT_CLOCK_CONFIG == "TRUE"), link_training, 1'b0,
                          link_width, link_speed};
    wire [31:0] devcap2 = {27'd0, (CPL_TIMEOUT_DISABLE_SUPPORTED == "TRUE"), CPL_TIMEOUT_RANGES_SUPPORTED};
    wire [15:0] pcie_capreg = {2'b00, pciecap_int_msgnum, (PCIE_CAP_SLOT_IMPLEMENTED == "TRUE"),
                               PCIE_CAP_DEVICE_PORT_TYPE, PCIE_CAP_CAPABILITY_VERSION};
    wire [2:0]  mmc = MSI_CAP_MULTIMSGCAP;
    wire [15:0] msi_ctl = {7'd0, MSIPVM[0], MSI64[0], r_msi_mme, mmc, r_msi_en};
    wire [2:0]  pm_ver = PM_CAP_VERSION;
    wire [2:0]  pm_aux = PM_CAP_AUXCURRENT;
    wire [15:0] pmc = {PM_CAP_PMESUPPORT, (PM_CAP_D2SUPPORT == "TRUE"), (PM_CAP_D1SUPPORT == "TRUE"),
                       pm_aux, (PM_CAP_DSI == "TRUE"), 1'b0, (PM_CAP_PME_CLOCK == "TRUE"), pm_ver};
    wire [15:0] pmcsr = {r_pme_sts, 6'd0, r_pme_en, 4'd0, (PM_CSR_NOSOFTRST == "TRUE"), 1'b0, r_pm_state};
    wire [2:0]  tbir = MSIX_CAP_TABLE_BIR;
    wire [2:0]  pbir = MSIX_CAP_PBA_BIR;

    assign command      = r_cmd;
    assign status       = {r_sts[15:11], 2'b00, r_sts[8], 3'b000, 1'b1, intx_status, 3'b000};
    assign dev_control  = r_devctl;
    assign dev_status   = {10'd0, trn_pending, 1'b0, r_devsts};
    assign link_control = r_lnkctl;
    assign dev_control2 = r_devctl2;
    assign link_control2 = r_lnkctl2;
    assign pm_power_state = r_pm_state;
    assign pm_pme_en = r_pme_en;
    assign pm_pme_status = r_pme_sts;
    assign msi_enable = r_msi_en;
    assign msi_mme = r_msi_mme;
    assign msi_addr = {MSI64 ? r_msi_ahi : 32'd0, r_msi_alo[31:2], 2'b00};
    assign msi_data = r_msi_data;
    assign msix_enable = r_msix_en;
    assign msix_fmask = r_msix_fm;
    assign int_line = r_intline;
    assign bar0 = r_bar0 & M0; assign bar1 = r_bar1 & M1; assign bar2 = r_bar2 & M2;
    assign bar3 = r_bar3 & M3; assign bar4 = r_bar4 & M4; assign bar5 = r_bar5 & M5;
    assign rom_bar = r_rom & MROM; assign rom_en = r_rom_en && (MROM != 32'd0);

    // ---------------- read mux ----------------
    wire [9:0] a = req_dwaddr;
    wire [9:0] PM0 = PM_BASE_PTR[7:2], MSI0 = MSI_BASE_PTR[7:2], PX0 = PCIE_BASE_PTR[7:2], MX0 = MSIX_BASE_PTR[7:2];
    wire [9:0] DSN0 = DSN_BASE_PTR[11:2];
    reg  [31:0] rv;
    always @(*) begin
        rv = 32'd0;
        if (a == 10'h000) rv = {dev_id, vend_id};
        else if (a == 10'h001) rv = {status, command};
        else if (a == 10'h002) rv = {CLASS_CODE, rev_id};
        else if (a == 10'h003) rv = {8'h00, HEADER_TYPE, 8'h00, r_cls};
        else if (a == 10'h004) rv = (r_bar0 & M0) | R0;
        else if (a == 10'h005) rv = (r_bar1 & M1) | R1;
        else if (a == 10'h006) rv = (r_bar2 & M2) | R2;
        else if (a == 10'h007) rv = (r_bar3 & M3) | R3;
        else if (a == 10'h008) rv = (r_bar4 & M4) | R4;
        else if (a == 10'h009) rv = (r_bar5 & M5) | R5;
        else if (a == 10'h00A) rv = CARDBUS_CIS_POINTER;
        else if (a == 10'h00B) rv = {subsys_id, subsys_vend_id};
        else if (a == 10'h00C) rv = (r_rom & MROM) | {31'd0, r_rom_en && MROM != 0};
        else if (a == 10'h00D) rv = {24'd0, CAPABILITIES_PTR};
        else if (a == 10'h00F) rv = {16'h0000, INTERRUPT_PIN, r_intline};
        else if (ISON_PM && a == PM0)       rv = {pmc, PM_CAP_NEXTPTR, 8'h01};
        else if (ISON_PM && a == PM0 + 1)   rv = {16'h0000, pmcsr};
        else if (ISON_MSI && a == MSI0)     rv = {msi_ctl, MSI_CAP_NEXTPTR, 8'h05};
        else if (ISON_MSI && a == MSI0 + 1) rv = {r_msi_alo[31:2], 2'b00};
        else if (ISON_MSI && MSI64 && a == MSI0 + 2) rv = r_msi_ahi;
        else if (ISON_MSI && a == MSI0 + (MSI64 ? 3 : 2)) rv = {16'h0000, r_msi_data};
        else if (ISON_MSI && MSIPVM && a == MSI0 + (MSI64 ? 4 : 3)) rv = r_msi_mask;
        else if (ISON_MSI && MSIPVM && a == MSI0 + (MSI64 ? 5 : 4)) rv = 32'd0;
        else if (ISON_MSIX && a == MX0)     rv = {r_msix_en, r_msix_fm, 3'b000, MSIX_CAP_TABLE_SIZE, MSIX_CAP_NEXTPTR, 8'h11};
        else if (ISON_MSIX && a == MX0 + 1) rv = {MSIX_CAP_TABLE_OFFSET, tbir};
        else if (ISON_MSIX && a == MX0 + 2) rv = {MSIX_CAP_PBA_OFFSET, pbir};
        else if (a == PX0)      rv = {pcie_capreg, PCIE_CAP_NEXTPTR, 8'h10};
        else if (a == PX0 + 1)  rv = devcap;
        else if (a == PX0 + 2)  rv = {dev_status, r_devctl};
        else if (a == PX0 + 3)  rv = lnkcap;
        else if (a == PX0 + 4)  rv = {link_status, r_lnkctl};
        else if (a == PX0 + 9)  rv = devcap2;                    // +24h Device Capabilities 2
        else if (a == PX0 + 10) rv = {16'h0000, r_devctl2};      // +28h Device Control/Status 2
        // Link Status 2 bit 0 (bit 16 here): current de-emphasis, the PHY always runs at -3.5 dB
        else if (a == PX0 + 12) rv = {15'd0, 1'b1, r_lnkctl2};
        else if (ISON_DSN && a == DSN0)     rv = {DSN_CAP_NEXTPTR, 4'h1, 16'h0003};
        else if (ISON_DSN && a == DSN0 + 1) rv = dsn[31:0];
        else if (ISON_DSN && a == DSN0 + 2) rv = dsn[63:32];
    end

    // ---------------- write ----------------
    wire [31:0] wd = req_wdata;
    wire [31:0] bm = {{8{req_be[3]}}, {8{req_be[2]}}, {8{req_be[1]}}, {8{req_be[0]}}};
    wire        we = req_v && req_wr;
    // RW1C helper: clear the bits written with 1 (or write as RW for management)
    function [31:0] rw1c;
        input [31:0] cur; input [31:0] w; input [31:0] m; input as_rw;
        rw1c = as_rw ? ((cur & ~m) | (w & m)) : (cur & ~(w & m));
    endfunction
    function [31:0] rw;
        input [31:0] cur; input [31:0] w; input [31:0] m;
        rw = (cur & ~m) | (w & m);
    endfunction

    localparam [15:0] CMD_MASK = (CMD_INTX_IMPLEMENTED == "TRUE") ? 16'h0547 : 16'h0147;
    reg [31:0] t;
    always @(posedge clk) begin
        rd_data <= rv;
        flr_pulse <= 1'b0;
        if (rst) begin
            r_cmd <= 16'd0; r_sts <= 16'd0; r_cls <= 8'd0; r_intline <= 8'hFF;
            r_bar0 <= 0; r_bar1 <= 0; r_bar2 <= 0; r_bar3 <= 0; r_bar4 <= 0; r_bar5 <= 0; r_rom <= 0; r_rom_en <= 1'b0;
            r_pm_state <= 2'b00; r_pme_en <= 1'b0; r_pme_sts <= 1'b0;
            r_msi_en <= 1'b0; r_msi_mme <= 3'd0; r_msi_alo <= 32'd0; r_msi_ahi <= 32'd0; r_msi_data <= 16'd0;
            r_msi_mask <= 32'd0; r_msix_en <= 1'b0; r_msix_fm <= 1'b0;
            // MRRS 512B, No Snoop and Relaxed Ordering enabled (spec defaults)
            r_devctl <= 16'h2810 | ((DEV_CONTROL_EXT_TAG_DEFAULT == "TRUE") ? 16'h0100 : 16'h0000);
            r_devsts <= 4'd0; r_lnkctl <= 16'd0; r_devctl2 <= 16'd0;
            r_lnkctl2 <= {12'd0, (LINK_CTRL2_TARGET_LINK_SPEED == 4'd0) ? LINK_CAP_MAX_LINK_SPEED : LINK_CTRL2_TARGET_LINK_SPEED};
            r_slot_pwr <= 10'd0;
        end else begin
            // error / status set inputs
            if (set_ur_detected)       r_devsts[3] <= 1'b1;
            if (set_fatal_detected)    r_devsts[2] <= 1'b1;
            if (set_nonfatal_detected) r_devsts[1] <= 1'b1;
            if (set_corr_detected)     r_devsts[0] <= 1'b1;
            if (set_master_data_parity) r_sts[8]  <= 1'b1;
            if (set_sig_target_abort)  r_sts[11] <= 1'b1;
            if (set_rcv_target_abort)  r_sts[12] <= 1'b1;
            if (set_rcv_master_abort)  r_sts[13] <= 1'b1;
            if (set_sig_sys_error)     r_sts[14] <= 1'b1;
            if (set_detected_parity)   r_sts[15] <= 1'b1;
            if (set_pme_status)        r_pme_sts <= 1'b1;
            if (slot_pwr_v)            r_slot_pwr <= slot_pwr;
            if (we) begin
                if (a == 10'h001) begin
                    t = rw({16'd0, r_cmd}, wd, bm & {16'd0, CMD_MASK}); r_cmd <= t[15:0];
                    t = rw1c({r_sts, 16'd0}, wd, bm & 32'hF9000000, req_rw1c_as_rw); r_sts <= t[31:16];
                end
                if (a == 10'h003 && req_be[0]) r_cls <= wd[7:0];
                if (a == 10'h004) r_bar0 <= rw(r_bar0, wd, bm & M0);
                if (a == 10'h005) r_bar1 <= rw(r_bar1, wd, bm & M1);
                if (a == 10'h006) r_bar2 <= rw(r_bar2, wd, bm & M2);
                if (a == 10'h007) r_bar3 <= rw(r_bar3, wd, bm & M3);
                if (a == 10'h008) r_bar4 <= rw(r_bar4, wd, bm & M4);
                if (a == 10'h009) r_bar5 <= rw(r_bar5, wd, bm & M5);
                if (a == 10'h00C) begin r_rom <= rw(r_rom, wd, bm & MROM); if (req_be[0]) r_rom_en <= wd[0]; end
                if (a == 10'h00F && req_be[0]) r_intline <= wd[7:0];
                if (ISON_PM && a == PM0 + 1) begin
                    if (req_be[0] && (wd[1:0] == 2'b00 || wd[1:0] == 2'b11 ||
                                      (wd[1:0] == 2'b01 && PM_CAP_D1SUPPORT == "TRUE") ||
                                      (wd[1:0] == 2'b10 && PM_CAP_D2SUPPORT == "TRUE")))
                        r_pm_state <= wd[1:0];
                    if (req_be[1]) begin
                        if (PM_CAP_PMESUPPORT != 5'd0) r_pme_en <= wd[8];
                        if (wd[15] && !req_rw1c_as_rw) r_pme_sts <= 1'b0;
                        else if (req_rw1c_as_rw) r_pme_sts <= wd[15];
                    end
                end
                if (ISON_MSI && a == MSI0) begin
                    if (req_be[2]) begin
                        r_msi_en  <= wd[16];
                        r_msi_mme <= (wd[22:20] > mmc) ? mmc : wd[22:20];
                    end
                end
                if (ISON_MSI && a == MSI0 + 1) r_msi_alo <= rw(r_msi_alo, wd, bm & 32'hFFFFFFFC);
                if (ISON_MSI && MSI64 && a == MSI0 + 2) r_msi_ahi <= rw(r_msi_ahi, wd, bm);
                if (ISON_MSI && a == MSI0 + (MSI64 ? 3 : 2)) begin
                    t = rw({16'd0, r_msi_data}, wd, bm & 32'h0000FFFF); r_msi_data <= t[15:0];
                end
                if (ISON_MSI && MSIPVM && a == MSI0 + (MSI64 ? 4 : 3)) r_msi_mask <= rw(r_msi_mask, wd, bm);
                if (ISON_MSIX && a == MX0 && req_be[3]) begin r_msix_en <= wd[31]; r_msix_fm <= wd[30]; end
                if (a == PX0 + 2) begin
                    // Device Control (FLR bit 15 self-clearing) / Device Status RW1C
                    t = rw({16'd0, r_devctl}, wd, bm & {16'd0, 16'h7FFF &
                           {1'b1, 3'b111, 1'b1, 1'b1, (DEV_CAP_PHANTOM_FUNCTIONS_SUPPORT != 0),
                            (DEV_CAP_EXT_TAG_SUPPORTED == "TRUE"), 3'b111, 5'b11111}});
                    r_devctl <= t[15:0];
                    if (req_be[1] && wd[15] && DEV_CAP_FUNCTION_LEVEL_RESET_CAPABLE == "TRUE") flr_pulse <= 1'b1;
                    t = rw1c({12'd0, r_devsts, 16'd0}, wd, bm & 32'h000F0000, req_rw1c_as_rw); r_devsts <= t[19:16];
                end
                if (a == PX0 + 4) begin
                    t = rw({16'd0, r_lnkctl}, wd, bm & 32'h00000FCB); r_lnkctl <= t[15:0];
                end
                if (a == PX0 + 10) begin
                    t = rw({16'd0, r_devctl2}, wd, bm & 32'h0000001F); r_devctl2 <= t[15:0];
                end
                if (a == PX0 + 12) begin
                    t = rw({16'd0, r_lnkctl2}, wd, bm & 32'h0000007F); r_lnkctl2 <= t[15:0];
                end
            end
        end
    end
endmodule
