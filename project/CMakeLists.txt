cmake_minimum_required(VERSION 3.26.5)
project(StudentCNN CXX)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(CLASS "464" CACHE STRING "Course: 464 or 564")
set(TEST "-1" CACHE STRING "Test index; -1 runs all deployed tests")
set(UNITY_ID "jdoe12" CACHE STRING "Student Unity ID")
set(DC_CLOCK_PER "10.0" CACHE STRING "Synthesis clock period in ns")
option(FULL_CNN "Elaborate the full CNN accelerator (dut_cnn) instead of the feature-extraction core (dut_feature)" OFF)
# Capture the preset environment so plain make synth also receives the path.
set(STUDENT_SRAM_ENV "")
if(DEFINED ENV{SRAM_PATH} AND NOT "$ENV{SRAM_PATH}" STREQUAL "")
  get_filename_component(STUDENT_SRAM_PATH "$ENV{SRAM_PATH}" ABSOLUTE BASE_DIR "${CMAKE_SOURCE_DIR}")
  list(APPEND STUDENT_SRAM_ENV "SRAM_PATH=${STUDENT_SRAM_PATH}")
  message(STATUS "SRAM libraries: ${STUDENT_SRAM_PATH}")
elseif(IS_DIRECTORY "/mnt/coe/workspace/ece/ece564-common/OpenRAM/memories")
  # SRAM_PATH not exported (e.g. cmake run without --preset): fall back to the course location
  set(STUDENT_SRAM_PATH "/mnt/coe/workspace/ece/ece564-common/OpenRAM/memories")
  list(APPEND STUDENT_SRAM_ENV "SRAM_PATH=${STUDENT_SRAM_PATH}")
  message(STATUS "SRAM libraries (default course path): ${STUDENT_SRAM_PATH}")
endif()
if(NOT CLASS MATCHES "^(464|564)$")
  message(FATAL_ERROR "CLASS must be 464 or 564")
endif()
file(READ "${CMAKE_SOURCE_DIR}/student-config.json" CONFIG)
string(JSON FIRST GET "${CONFIG}" tests start)
string(JSON LAST GET "${CONFIG}" tests end)
if(NOT "${TEST}" MATCHES "^-?[0-9]+$")
  message(FATAL_ERROR "TEST must be -1 or a deployed test index")
endif()
if(NOT "${TEST}" EQUAL -1 AND ("${TEST}" LESS FIRST OR "${TEST}" GREATER LAST))
  message(FATAL_ERROR "TEST must be -1 or in ${FIRST}..${LAST}")
endif()
math(EXPR TEST_LIMIT "${LAST}+1")
string(JSON SUBMISSION GET "${CONFIG}" compress)
file(WRITE "${CMAKE_BINARY_DIR}/submission-config.json" "${SUBMISSION}")
add_custom_target(compress
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/student_compress.py"
    --root "${CMAKE_SOURCE_DIR}" --config "${CMAKE_BINARY_DIR}/submission-config.json"
    --id "${UNITY_ID}" --output-dir "${CMAKE_BINARY_DIR}" VERBATIM)
option(ENABLE_HDL_TOOLS "Configure simulator and synthesis targets" ON)
if(NOT ENABLE_HDL_TOOLS)
  return()
endif()
find_program(VLOG vlog REQUIRED)
find_program(VSIM vsim REQUIRED)
find_program(VLIB vlib REQUIRED)
include("${CMAKE_SOURCE_DIR}/cmake/QuestaDPI.cmake")
configure_questa_dpi()
add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/memory_interface.so"
  COMMAND "${DPI_CXX}" -m64 -std=c++17 -O2 -fPIC -shared -DMEMORY_ONLY
    -I "${DPI_INCLUDE_DIR}" "${CMAKE_SOURCE_DIR}/srcs/cpp/memory_interface.cpp"
    -o "${CMAKE_BINARY_DIR}/memory_interface.so"
  DEPENDS "${CMAKE_SOURCE_DIR}/srcs/cpp/memory_interface.cpp" VERBATIM)
add_custom_target(memory_interface DEPENDS "${CMAKE_BINARY_DIR}/memory_interface.so")
file(GLOB_RECURSE RTL CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/srcs/rtl/*.sv" "${CMAKE_SOURCE_DIR}/srcs/rtl/*.v")
# Keep SRAM macro models in a separate library shared by DUT compilations.
set(SRAM_LIBRARY_ARGS "")
set(SRAM_DEPENDENCIES "")
if(STUDENT_SRAM_PATH)
  file(GLOB_RECURSE SRAM_MODELS CONFIGURE_DEPENDS
    "${STUDENT_SRAM_PATH}/sram_*.v" "${STUDENT_SRAM_PATH}/sram_*.sv")
  # Alternative edge models declare the same modules as their standard files.
  list(FILTER SRAM_MODELS EXCLUDE REGEX "\\.posedge\\.(v|sv)$")
  list(SORT SRAM_MODELS COMPARE NATURAL)
  if(NOT SRAM_MODELS)
    message(FATAL_ERROR "No SRAM models found under ${STUDENT_SRAM_PATH}; update SRAM_PATH in CMakePresets.json")
  endif()
  list(LENGTH SRAM_MODELS SRAM_MODEL_COUNT)
  message(STATUS "SRAM simulation models: ${SRAM_MODEL_COUNT}")
  set(SRAM_BUILD_DIR "${CMAKE_BINARY_DIR}/sram-models")
  set(SRAM_LIBRARY "${SRAM_BUILD_DIR}/work")
  set(SRAM_STAMP "${SRAM_LIBRARY}/.stamp")
  file(MAKE_DIRECTORY "${SRAM_BUILD_DIR}")
  file(CONFIGURE OUTPUT "${SRAM_BUILD_DIR}/settings.txt"
    CONTENT "VLOG=@VLOG@\nVLIB=@VLIB@\nMODELS=@SRAM_MODELS@\n" @ONLY)
  add_custom_command(OUTPUT "${SRAM_STAMP}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${SRAM_LIBRARY}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${QUESTA_ROOT}/modelsim.ini" "${SRAM_BUILD_DIR}/modelsim.ini"
    COMMAND "${VLIB}" "${SRAM_LIBRARY}"
    COMMAND "${VLOG}" -64 -sv -timescale=1ns/1ps -work "${SRAM_LIBRARY}"
      -modelsimini "${SRAM_BUILD_DIR}/modelsim.ini" ${SRAM_MODELS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${SRAM_STAMP}"
    DEPENDS ${SRAM_MODELS} "${SRAM_BUILD_DIR}/settings.txt" "${QUESTA_ROOT}/modelsim.ini"
    WORKING_DIRECTORY "${SRAM_BUILD_DIR}" COMMENT "Compiling SRAM macro models" VERBATIM)
  add_custom_target(vlog-sram DEPENDS "${SRAM_STAMP}")
  set(SRAM_LIBRARY_ARGS -L "${SRAM_LIBRARY}")
  set(SRAM_DEPENDENCIES vlog-sram)
endif()
set(DEFINES +define+USE_DPI_DRAM +define+POOL_DENOMINATOR=4)
if(CLASS STREQUAL "564")
  list(APPEND DEFINES +define+CLASS_564)
endif()
if(FULL_CNN)
  list(APPEND DEFINES +define+FULL_CNN)
  message(STATUS "FULL_CNN=ON : dut = full CNN accelerator (see cnn_ext/README_CNN.md; the course tb cannot check it)")
else()
  message(STATUS "FULL_CNN=OFF: dut = feature-extraction core (course deliverable)")
endif()
foreach(kind IN ITEMS student golden)
  if(kind STREQUAL "golden")
    set(SUFFIX "-golden")
    set(DESIGN "${CMAKE_SOURCE_DIR}/srcs/tb/golden_dut.svp")
  else()
    set(SUFFIX "-dut")
    set(DESIGN ${RTL})
  endif()
  set(EXTRA_LIBRARIES "")
  set(EXTRA_DEPENDENCIES "")
  if(kind STREQUAL "student")
    set(EXTRA_LIBRARIES ${SRAM_LIBRARY_ARGS})
    set(EXTRA_DEPENDENCIES ${SRAM_DEPENDENCIES})
  endif()
  set(LIBRARY "${CMAKE_BINARY_DIR}/${kind}/work")
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/${kind}")
  configure_file("${QUESTA_ROOT}/modelsim.ini" "${CMAKE_BINARY_DIR}/${kind}/modelsim.ini" COPYONLY)
  # Always compile when invoked so CLASS changes and added RTL files are respected.
  add_custom_target(vlog${SUFFIX}
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${LIBRARY}"
    COMMAND "${VLIB}" "${LIBRARY}"
    COMMAND "${VLOG}" -64 -sv -work "${LIBRARY}" ${DEFINES} ${EXTRA_LIBRARIES}
      "+incdir+${CMAKE_SOURCE_DIR}/srcs/tb" "+incdir+${CMAKE_SOURCE_DIR}/srcs/rtl"
      "${CMAKE_SOURCE_DIR}/srcs/tb/dram.svp" "${CMAKE_SOURCE_DIR}/srcs/tb/tri_state_driver.sv"
      "${CMAKE_SOURCE_DIR}/srcs/tb/tb.sv" ${DESIGN}
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/${kind}" DEPENDS memory_interface ${EXTRA_DEPENDENCIES} VERBATIM)
  set(SIM_DIR "${CMAKE_BINARY_DIR}/${kind}/outputs")
  foreach(number RANGE ${FIRST} ${LAST})
    file(MAKE_DIRECTORY "${SIM_DIR}/output${number}/${CLASS}")
  endforeach()
  set(ARGS -64 -modelsimini "${CMAKE_BINARY_DIR}/${kind}/modelsim.ini"
    -sv_lib "${CMAKE_BINARY_DIR}/memory_interface" ${EXTRA_LIBRARIES} -voptargs=+acc "${LIBRARY}.tb"
    "+class=${CLASS}" "+test=${TEST}" "+number_of_test=${TEST_LIMIT}"
    "+input_dir=${CMAKE_SOURCE_DIR}/inputs" "+output_dir=${CMAKE_SOURCE_DIR}/outputs"
    "+sim_output_dir=${SIM_DIR}" "+log_file=${CMAKE_BINARY_DIR}/${kind}/result.log")
  add_custom_target(vsim${SUFFIX}
    COMMAND "${VSIM}" ${ARGS} WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/${kind}"
    DEPENDS vlog${SUFFIX} VERBATIM)
  add_custom_target(vsim${SUFFIX}-c
    COMMAND "${VSIM}" -c ${ARGS} -do "onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0"
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/${kind}" DEPENDS vlog${SUFFIX} VERBATIM)
endforeach()

# ---------------------------------------------------------------------------
# CNN extension (Questa only): testbench cnn_ext/sim/tb_cnn.sv checks dut_cnn end-to-end.
#   make cnn-vectors   generate DRAM image + golden (python3)
#   make vlog-cnn      compile dut_cnn + tb_cnn (+ OpenRAM SRAM models when SRAM_PATH is set)
#   make vsim-cnn      GUI,   make vsim-cnn-c  batch (prints [TB ] report, ends with RESULT: PASS|FAIL)
# Options: -DCNN_NC=<1..16> -DCNN_MODE=<mixed|rand|zeros|accmax|ties> -DCNN_SEED=<n>
# The course tb.sv/DPI DRAM cannot check dut_cnn (no FC weights in inputs/), so tb_cnn uses its own
# behavioural DRAM (cnn_ext/sim/dram_model.sv, same RD/WR timing as the calibrated dut_feature).
# ---------------------------------------------------------------------------
set(CNN_NC "10" CACHE STRING "CNN classes (1..16)")
set(CNN_MODE "mixed" CACHE STRING "CNN stimulus: mixed|rand|zeros|accmax|ties")
set(CNN_SEED "1" CACHE STRING "CNN stimulus seed")
set(CNN_DIR "${CMAKE_BINARY_DIR}/cnn")
set(CNN_VEC "${CNN_DIR}/vec")
file(MAKE_DIRECTORY "${CNN_DIR}" "${CNN_VEC}")
configure_file("${QUESTA_ROOT}/modelsim.ini" "${CNN_DIR}/modelsim.ini" COPYONLY)
add_custom_target(cnn-vectors
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/cnn_ext/scripts/gen_vectors.py"
    --mode "${CNN_MODE}" --seed "${CNN_SEED}" --nc "${CNN_NC}" --out "${CNN_VEC}" VERBATIM)
set(CNN_SRAM_SRC "")
if(NOT STUDENT_SRAM_PATH)
  # no OpenRAM models configured: fall back to behavioural stand-ins
  message(WARNING "SRAM_PATH is not set: CNN simulation uses behavioural SRAM stand-ins and 'make synth' will leave the SRAM macros UNLINKED (black boxes). Configure with --preset so SRAM_PATH is exported.")
  set(CNN_SRAM_SRC "${CMAKE_SOURCE_DIR}/cnn_ext/sim/sram_models.sv")
endif()
set(CNN_LIB "${CNN_DIR}/work")
add_custom_target(vlog-cnn
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CNN_LIB}"
  COMMAND "${VLIB}" "${CNN_LIB}"
  COMMAND "${VLOG}" -64 -sv -work "${CNN_LIB}" ${SRAM_LIBRARY_ARGS}
    "${CMAKE_SOURCE_DIR}/cnn_ext/sim/dram_model.sv" "${CMAKE_SOURCE_DIR}/cnn_ext/sim/tb_cnn.sv"
    "${CMAKE_SOURCE_DIR}/srcs/rtl/dut_cnn.sv" "${CMAKE_SOURCE_DIR}/srcs/rtl/cnn_fc.sv" ${CNN_SRAM_SRC}
  WORKING_DIRECTORY "${CNN_DIR}" DEPENDS ${SRAM_DEPENDENCIES} VERBATIM)
set(CNN_ARGS -64 -modelsimini "${CNN_DIR}/modelsim.ini" ${SRAM_LIBRARY_ARGS} -voptargs=+acc
  "-GNC=${CNN_NC}" "${CNN_LIB}.tb_cnn" "+VEC=${CNN_VEC}")
add_custom_target(vsim-cnn COMMAND "${VSIM}" ${CNN_ARGS}
  WORKING_DIRECTORY "${CNN_DIR}" DEPENDS vlog-cnn cnn-vectors VERBATIM)
add_custom_target(vsim-cnn-c
  COMMAND "${VSIM}" -c ${CNN_ARGS} -do "onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0"
  WORKING_DIRECTORY "${CNN_DIR}" DEPENDS vlog-cnn cnn-vectors VERBATIM)

find_program(DC_SHELL dc_shell)
if(DC_SHELL AND NOT STUDENT_SRAM_PATH)
  message(FATAL_ERROR "SRAM_PATH is not set and the default course path was not found: Design Compiler would leave the SRAM macros UNLINKED (black boxes, zero area). Export SRAM_PATH or configure with --preset.")
endif()
if(DC_SHELL)
  file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/dc" "${CMAKE_BINARY_DIR}/dc/svf")
  configure_file("${CMAKE_SOURCE_DIR}/synthesis/.synopsys_dc.setup" "${CMAKE_BINARY_DIR}/dc/.synopsys_dc.setup" COPYONLY)
  string(JOIN " " RTL_LIST ${RTL})
  set(SYNTH_DEFINES "POOL_DENOMINATOR=4")
  if(CLASS STREQUAL "564")
    string(APPEND SYNTH_DEFINES " CLASS_564")
  endif()
  if(FULL_CNN)
    string(APPEND SYNTH_DEFINES " FULL_CNN")
  endif()
  foreach(dir reports gl sdf logs)
    file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/synth/${dir}")
  endforeach()
  add_custom_target(synth
    COMMAND "${CMAKE_COMMAND}" -E env ${STUDENT_SRAM_ENV} "DC_CLOCK_PER=${DC_CLOCK_PER}"
      "OUTPUT_DIR=${CMAKE_BINARY_DIR}/synth" "RTL_FILES=" "RTL_SV_FILES=${RTL_LIST}"
      "RTL_SV_DEFINES=${SYNTH_DEFINES}" "MODULE_NAME=dut"
      "${DC_SHELL}" -no_gui -x
      "set_app_var search_path [concat {${CMAKE_SOURCE_DIR}/synthesis} [get_app_var search_path]]; source ${CMAKE_SOURCE_DIR}/synthesis/run_all.tcl"
    WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/dc" VERBATIM)
else()
  add_custom_target(synth COMMAND "${CMAKE_COMMAND}" -E echo "dc_shell not found; source setup.sh and reconfigure"
    COMMAND "${CMAKE_COMMAND}" -E false VERBATIM)
endif()

# ---------------------------------------------------------------------------
# make cnn-report : Questa run of the full CNN + Design Compiler synthesis + one summary
#   (cycle count, cells, cell/macro/total area, clock period, total execution time, slacks)
#   -> build/cnn_summary.rpt.  Requires -DFULL_CNN=ON (preset "cnn").
# ---------------------------------------------------------------------------
if(FULL_CNN AND DC_SHELL)
  add_custom_target(cnn-report
    COMMAND "${CMAKE_COMMAND}" --build "${CMAKE_BINARY_DIR}" --target vsim-cnn-c
    COMMAND "${CMAKE_COMMAND}" --build "${CMAKE_BINARY_DIR}" --target synth
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/cnn_ext/scripts/cnn_report.py"
      --build "${CMAKE_BINARY_DIR}" --clock "${DC_CLOCK_PER}" --nc "${CNN_NC}" --out "${CMAKE_BINARY_DIR}/cnn_summary.rpt"
    USES_TERMINAL VERBATIM)
else()
  add_custom_target(cnn-report COMMAND "${CMAKE_COMMAND}" -E echo "cnn-report needs: cmake .. --preset cnn (FULL_CNN=ON) and dc_shell on PATH (source setup.sh)"
    COMMAND "${CMAKE_COMMAND}" -E false VERBATIM)
endif()
