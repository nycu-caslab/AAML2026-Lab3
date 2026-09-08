VERILOG ?= iverilog
SIM ?= vvp
TESTBENCH := TESTBENCH
RTL_DIR := RTL

.PHONY: verif1 verif2 verif3 verif4 regression verif_signed run clean

verif1:
	$(MAKE) run MODE=0 NCASES=10 OUT=verif1

verif2:
	$(MAKE) run MODE=1 NCASES=10 OUT=verif2

verif3:
	$(MAKE) run MODE=3 NCASES=25 OUT=verif3

verif4:
	$(MAKE) run MODE=4 NCASES=10 OUT=verif4

regression: verif1 verif2 verif3 verif4

verif_signed:
	@echo "verif_signed is not supported by this GEMV generator."

run:
	mkdir -p $(OUT)
	python3 data_generator.py --mode $(MODE) --target_dir $(OUT) --ncases $(NCASES)
	cp $(OUT)/input.txt $(OUT)/input.bk
	cp $(OUT)/input.txt $(TESTBENCH)/input.txt
	$(VERILOG) -g2005-sv -Wall -o $(OUT)/simulation $(TESTBENCH)/TESTBENCH.v -I $(TESTBENCH) -I $(RTL_DIR) -D RTL
	$(SIM) $(OUT)/simulation +access+r

clean:
	rm -rf verif1 verif2 verif3 verif4 dump.vcd
	rm -f $(TESTBENCH)/input.txt
	
# =============================================================================
# Arty A7-100T FPGA build and programming
# =============================================================================

VIVADO ?= vivado
VIVADO_JOBS ?= 4

BOARD_CREATE_TCL := BOARD/scripts/create_board_project.tcl
BOARD_BUILD_TCL := BOARD/scripts/build_bitstream.tcl
BOARD_PROGRAM_TCL := BOARD/scripts/program_fpga.tcl
BOARD_BITSTREAM := build/bitstream/gemv_board.bit

.PHONY: fpga_board_files
.PHONY: generate_gemv_bitstream program
.PHONY: fpga_clean clean_all


# Create the Vivado project from RTL, IP and XDC files.
fpga_board_files:
	@echo "============================================================"
	@echo "Preparing Vivado Arty A7-100T GEMV board files"
	@echo "============================================================"
	$(VIVADO) -mode batch \
		-source $(BOARD_CREATE_TCL)


# Run synthesis, implementation and generate a new bitstream.
# This target does not program the FPGA.
generate_gemv_bitstream: fpga_board_files
	@echo "============================================================"
	@echo "Running synthesis, implementation and bitstream generation"
	@echo "Vivado jobs: $(VIVADO_JOBS)"
	@echo "============================================================"
	$(VIVADO) -mode batch \
		-source $(BOARD_BUILD_TCL) \
		-tclargs $(VIVADO_JOBS)
	@test -f "$(BOARD_BITSTREAM)" || \
		(echo "ERROR: Bitstream generation failed." && exit 1)
	@echo "Generated bitstream: $(BOARD_BITSTREAM)"


# Program only, using the existing bitstream.
# This target does not rerun synthesis or implementation.
program:
	@echo "============================================================"
	@echo "Programming Arty A7-100T with existing bitstream"
	@echo "Bitstream: $(BOARD_BITSTREAM)"
	@echo "============================================================"
	@test -f "$(BOARD_BITSTREAM)" || \
		(echo "ERROR: Bitstream not found: $(BOARD_BITSTREAM)" && exit 1)
	$(VIVADO) -mode batch \
		-source $(BOARD_PROGRAM_TCL)

UART_PORT ?=
PYTHON ?= python3

.PHONY: hardware_verify

hardware_verify:
	@echo "============================================================"
	@echo "Running Arty A7 FPGA hardware verification"
	@echo "UART port: $(if $(UART_PORT),$(UART_PORT),automatic detection)"
	@echo "============================================================"
	@if [ -n "$(UART_PORT)" ]; then \
		test -e "$(UART_PORT)" || { \
			echo "ERROR: UART port not found: $(UART_PORT)"; \
			exit 1; \
		}; \
		$(PYTHON) HOST/uart_test.py --port "$(UART_PORT)"; \
	else \
		$(PYTHON) HOST/uart_test.py; \
	fi

# Remove Vivado projects, reports, bitstreams and session logs.
# The original simulation clean target remains unchanged.
fpga_clean:
	rm -rf ./build
	rm -f ./vivado*.jou
	rm -f ./vivado*.log
	rm -f ./vivado*.str
	rm -f ./vivado*.pb
	rm -f ./webtalk*.jou
	rm -f ./webtalk*.log


# Run both the original simulation clean and FPGA clean.
clean_all: clean fpga_clean