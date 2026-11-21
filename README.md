# CNN Hardware Accelerator 

## Overview

A hardware implementation of a Convolutional Neural Network (CNN) accelerator using synthesizable SystemVerilog RTL. The design extends a feature-extraction pipeline with a fully connected (FC) classification stage to perform end-to-end inference.

The architecture integrates feature-map buffering, address generation, weight streaming, parallel multiply-accumulate operations, and classification logic to process image data and generate class logits.

The FC datapath uses a four-lane MAC architecture with a two-level adder tree. Weights are streamed from DRAM through a two-tile ping-pong SRAM buffer, while partial sums are accumulated across tiles before bias addition and final classification.

### Key Features

- End-to-end CNN inference with feature extraction and fully connected classification.
- Four-lane parallel MAC datapath using multipliers and a two-level adder tree.
- Flattening and address-generation logic for feature-map processing.
- Ping-pong SRAM buffering for feature maps and FC weights.
- Tiled weight streaming with credit-based flow control.
- Per-class accumulation, bias addition, and argmax classification.
- SystemVerilog testbench with functional checks, DRAM protocol verification, and configurable test vectors.
- Synthesis and timing analysis using Synopsys Design Compiler.

## Architecture

The accelerator is organized into the following major stages:

1. **Feature Extraction:** Processes input image data and generates feature maps.
2. **Feature Buffering:** Uses ping-pong SRAM buffers to store intermediate feature data.
3. **Flattening:** Converts feature maps into a sequential stream using an address sequencer.
4. **MAC Engine:** Performs parallel multiply-accumulate operations using four processing lanes and a two-level adder tree.
5. **Tile Accumulation:** Accumulates partial sums across streamed weight tiles.
6. **Classification:** Adds per-class bias values and uses an argmax unit to determine the predicted class.

The FC stage uses a two-tile ping-pong weight buffer to overlap weight loading and computation, reducing the need to store the complete weight matrix on-chip.

## Repository Structure

```text
project/
├── srcs/
│   ├── rtl/
│   │   ├── dut.sv
│   │   ├── dut_feature.sv
│   │   ├── dut_cnn.sv
│   │   └── cnn_fc.sv
│   ├── tb/
│   │   ├── tb.sv
│   │   ├── dram.svp
│   │   └── memory_backend.svh
│   └── cpp/
│       └── memory_interface.cpp
│
├── cnn_ext/
│   ├── sim/
│   │   ├── tb_cnn.sv
│   │   ├── dram_model.sv
│   │   └── sram_models.sv
│   ├── scripts/
│   │   ├── gen_vectors.py
│   │   ├── regress_questa.sh
│   │   ├── regress_verilator.sh
│   │   └── cnn_report.py
│   ├── mutants/
│   ├── synth_open/
│   └── README_CNN.md
│
├── inputs/
├── outputs/
├── synthesis/
├── do/
├── cmake/
├── CMakeLists.txt
├── CMakePresets.json
└── setup.sh
```

### Important RTL Modules

| Module           | Description                                                                            |
| ---------------- | -------------------------------------------------------------------------------------- |
| `dut.sv`         | Top-level wrapper selecting the feature-extraction or full CNN implementation          |
| `dut_feature.sv` | Feature-extraction hardware                                                            |
| `dut_cnn.sv`     | Top-level full CNN accelerator                                                         |
| `cnn_fc.sv`      | Flattening, MAC datapath, tile accumulation, weight loading, bias addition, and argmax |
| `tb_cnn.sv`      | Dedicated end-to-end CNN verification testbench                                        |
| `dram_model.sv`  | Behavioral DRAM model for CNN simulation                                               |

## Technology Stack

- **HDL:** SystemVerilog
- **Simulation:** Siemens Questa / ModelSim
- **Synthesis:** Synopsys Design Compiler
- **Timing Analysis:** Design Compiler timing reports
- **Memory:** SRAM macros, ping-pong buffering, behavioral DRAM model
- **Build System:** CMake
- **Scripting:** Python, Bash, Tcl
- **Optional Verification and Synthesis:** Verilator, Yosys, ABC, OpenSTA

## Getting Started

### Prerequisites

- Linux environment
- CMake 3.26.5 or later
- Python 3
- Siemens Questa 2026.1
- Synopsys Design Compiler
- OpenRAM SRAM simulation models and libraries for the full synthesis flow

The provided `setup.sh` loads the course tool versions.

### 1. Configure the Environment

```bash
cd project
source setup.sh
```

### 2. Configure the Full CNN Build

```bash
mkdir -p build
cd build
cmake .. --preset cnn
```

The `cnn` preset enables the full CNN implementation using `FULL_CNN=ON`.

### 3. Run Functional Simulation

```bash
make vsim-cnn-c
```

This generates test vectors, compiles the RTL and testbench, and runs the simulation in batch mode.

For GUI-based simulation:

```bash
make vsim-cnn
```

### 4. Run Synthesis

```bash
make synth
```

Synthesis reports are generated under:

```text
build/synth/reports/
```

These include timing, cell-area, and setup/hold analysis reports.

### 5. Run the Combined CNN Evaluation

```bash
make cnn-report
```

This runs the CNN simulation and synthesis flow, then generates:

```text
build/cnn_summary.rpt
```

The summary includes simulation status, cycle count, clock period, estimated execution time, cell counts, area, and setup/hold slack.

## Configuration

The CNN testbench supports configurable class counts, stimulus modes, and random seeds.

For example:

```bash
cmake . -DCNN_NC=7 -DCNN_MODE=ties -DCNN_SEED=2
make vsim-cnn-c
```

Supported stimulus modes include `mixed`, `rand`, `zeros`, `accmax`, and `ties`.

## Verification

The dedicated CNN testbench checks:

- Feature-map correctness.
- Classification logits against expected results.
- DRAM read/write protocol behavior.
- End-to-end inference completion.

The repository also includes regression scripts and mutation-testing infrastructure to evaluate the effectiveness of the verification environment.

**Note:** The full CNN uses `cnn_ext/sim/tb_cnn.sv` for end-to-end verification. The course testbench is intended for the feature-extraction design and does not independently verify the full CNN classification path.

## Synthesis and Implementation Analysis

The full CNN can be synthesized using Synopsys Design Compiler. The generated reports can be used to examine:

- Standard-cell and sequential-cell counts.
- SRAM macro instances and area.
- Total design area.
- Setup timing and hold timing.
- Critical-path behavior.

An optional Yosys and OpenSTA flow is also included under `cnn_ext/synth_open/` for open-source synthesis and timing estimation.
