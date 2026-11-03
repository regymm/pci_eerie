#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-P
# Regenerate rtl/pci_eerie_ports.vh / rtl/pci_eerie_params.vh from the Vivado PCIE_2_1 unisim model.
import re, sys
src = open(sys.argv[1] if len(sys.argv) > 1 else '/opt/Xilinx/Vivado/2023.2/data/verilog/src/unisims/PCIE_2_1.v').read()
ports = re.findall(r'^\s*(input|output)\s*(\[[^\]]+\])?\s*(\w+)\s*;', src, re.M)
params = re.findall(r'^\s*parameter\s*((?:integer|real)\s+|\[[^\]]+\]\s*)?(\w+)\s*=\s*([^;]+);', src, re.M)
ports.sort(key=lambda p: (p[0] != 'input', p[2]))
with open('rtl/pci_eerie_ports.vh', 'w') as f:
    f.write('// Generated from the PCIE_2_1 unisim model by tools/gen_ports.py - port list of pci_eerie\n')
    for i, (d, w, n) in enumerate(ports):
        f.write('    %-6s %-9s%s%s\n' % (d, (w + ' ') if w else '', n, ',' if i < len(ports) - 1 else ''))
with open('rtl/pci_eerie_params.vh', 'w') as f:
    f.write('// Generated from the PCIE_2_1 unisim model by tools/gen_ports.py - parameters of pci_eerie\n')
    out = ['    parameter %s%s = %s' % ((w.strip() + ' ') if w else '', n, v.strip()) for w, n, v in params if n != 'LOC']
    f.write(',\n'.join(out) + '\n')
