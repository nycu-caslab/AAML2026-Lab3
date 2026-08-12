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
