# SPDX-License-Identifier: CERN-OHL-P
# sed -E script for openXC7 builds of the Vivado core's GTX wrapper (syn/Makefile.openxc7): the core
# leaves these GTXE2_CHANNEL attributes commented out (silicon defaults), but the openXC7 bitstream
# flow writes unset attributes as 0 (the CPLL then never locks): set them explicitly, with the values
# the core's comments give (the set pcie_7x's pipe_wrapper_gtx.v sets, plus TXPHDLY_CFG: found by
# decoding the working Vivado bitstream with prjxray's bit2fasm and diffing the GTX features).
/GTXE2_CHANNEL #/,/^\s*\)\s*$/ {
  s|^(\s*)//(\s*\.CPLL_INIT_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.CPLL_LOCK_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXISCANRESET_TIME\s*\()|\1\2|
  s|^(\s*)//(\s*\.PD_TRANS_TIME_FROM_P2\s*\()|\1\2|
  s|^(\s*)//(\s*\.PD_TRANS_TIME_TO_P2\s*\()|\1\2|
  s|^(\s*)//(\s*\.TRANS_TIME_RATE\s*\()|\1\2|
  s|^(\s*)//(\s*\.TERM_RCAL_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.TERM_RCAL_OVRD\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXCDRFREQRESET_TIME\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXCDRPHRESET_TIME\s*\()|\1\2|
  s|^(\s*)//(\s*\.RX_BUFFER_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXBUFRESET_TIME\s*\()|\1\2|
  s|^(\s*)//(\s*\.TXPH_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.TXDLY_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.TXDLY_LCFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXDFELPMRESET_TIME\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXPH_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXDLY_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXDLY_LCFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXDLY_TAP_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.RXOOB_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.TST_RSV\s*\()|\1\2|
  s|^(\s*)//(\s*\.UCODEER_CLR\s*\()|\1\2|
  s|^(\s*)//(\s*\.SAS_MAX_COM\s*\()|\1\2|
  s|^(\s*)//(\s*\.SAS_MIN_COM\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_BURST_SEQ_LEN\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_BURST_VAL\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_EIDLE_VAL\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_MAX_BURST\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_MAX_INIT\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_MAX_WAKE\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_MIN_BURST\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_MIN_INIT\s*\()|\1\2|
  s|^(\s*)//(\s*\.SATA_MIN_WAKE\s*\()|\1\2|
  s|^(\s*)//(\s*\.ES_CONTROL\s*\()|\1\2|
  s|^(\s*)//(\s*\.ES_ERRDET_EN\s*\()|\1\2|
  s|^(\s*)//(\s*\.ES_PMA_CFG\s*\()|\1\2|
  s|^(\s*)//(\s*\.ES_PRESCALE\s*\()|\1\2|
  s|^(\s*)//(\s*\.ES_QUALIFIER\s*\()|\1\2|
  s|^(\s*)//(\s*\.ES_QUAL_MASK\s*\()|\1\2|
  s|^(\s*)//(\s*\.ES_SDATA_MASK\s*\()|\1\2|
  s|^(\s*)//(\s*\.ES_VERT_OFFSET\s*\()|\1\2|
  s|^(\s*)//(\s*\.TXPHDLY_CFG\s*\()|\1\2|
  # RX_DEBUG_CFG is the last active entry in the core; TST_RSV / UCODEER_CLR now follow it
  s|^(\s*\.RX_DEBUG_CFG\s*\([^)]*\))(\s)|\1,\2|
}
# CPLL start-up power-down override (cpllpd_ovrd, clocked by a BUFG on the GT reference clock):
# not used, as in pcie_7x's openXC7 GTX wrapper; with the extra BUFG load on the IBUFDS_GTE2 output the
# CPLLs do not lock in the openXC7 build. The reset FSM's CPLLPD / CPLLRESET stay.
s/\(cpllpd \| GT_CPLLPD\)/(GT_CPLLPD)/
s/\(cpllrst \| GT_CPLLRESET\)/(GT_CPLLRESET)/
s/^BUFG cpllpd_refclk_inst \(\.I \(PIPE_CLK\), \.O \(gt_cpllpdrefclk\)\);/assign gt_cpllpdrefclk = 1'b0;/
