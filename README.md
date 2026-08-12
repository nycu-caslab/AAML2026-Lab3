# AAML2026_lab3_design
## TODO

[Lab introduction of Lab3](https://nycu-caslab.github.io/AAML2026/labs/lab_3.html)


## Directory Structure
```bash
.
├── README.md
├── lab3-1
│   ├── data_generator.py
│   ├── Makefile
│   ├── Makefile_ncverilog
│   ├── Makefile_vcs
│   ├── RTL
│   │   ├── global_buffer.v
│   │   └── TPU.v
│   └── TESTBENCH
│       ├── PATTERN.v
│       └── TESTBENCH.v
└── lab3-2
    ├── data_generator.py
    ├── Makefile
    ├── Makefile_ncverilog
    ├── Makefile_vcs
    ├── requirements.txt
    ├── RTL
    │   ├── global_buffer.v
    │   └── TPU.v
    └── TESTBENCH
        ├── PATTERN.v
        └── TESTBENCH.v
```

- `lab3-1`: Row-stationary 2D convolution design problem.
- `lab3-2`: GEMM design problem.
- `RTL`: The source code of your design.
- `TESTBENCH`: The testbench to test your design.
- `data_generator.py`: The generator to generate test cases.
- `dump.(vcd|fsdb)`: The waveform after running any test.

## Makefile
Run the Makefile commands inside `lab3-1` or `lab3-2`.

- `make verif1`
    - Run the code with #1 test case.
- `make verif2`
    - Run the code with #2 test case.
- `make verif3`
    - Run the code with #3 test case.
- `make verif4`
    - Run the code with #4 test case.
