cmake_minimum_required(VERSION 3.20.0)

set(BOARD_FLASH_RUNNER nrfutil CACHE STRING "Use nrfutil for west flash" FORCE)

set(PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(WOLFSSL_MODULE "${PROJECT_ROOT}/modules/wolfssl" CACHE PATH "wolfSSL module path")
set(WOLFMQTT_MODULE "${PROJECT_ROOT}/modules/wolfmqtt" CACHE PATH "wolfMQTT module path")
set(PQM4_MODULE "${PROJECT_ROOT}/modules/pqm4" CACHE PATH "pqm4 module path")
set(BENCH_GENERATED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../work/generated/default" CACHE PATH "Generated benchmark headers")

set(WOLFSSL_MLKEM "yes" CACHE STRING "Enable wolfSSL ML-KEM for TLS 1.3 PQC key exchange")
set(WOLFSSL_PQC_HYBRIDS "yes" CACHE STRING "Enable classical/PQC hybrid TLS groups")
set(WOLFSSL_TLS_NO_MLKEM_STANDALONE "no" CACHE STRING "Allow standalone ML-KEM TLS groups")

if(EXISTS "${WOLFSSL_MODULE}/zephyr/module.yml")
  list(APPEND ZEPHYR_EXTRA_MODULES "${WOLFSSL_MODULE}")
endif()

if(EXISTS "${WOLFMQTT_MODULE}/zephyr/module.yml")
  list(APPEND ZEPHYR_EXTRA_MODULES "${WOLFMQTT_MODULE}")
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(ipsp_mqtt_tls_wolf_benchmark)

if(CONFIG_APP_BENCH_TLS_GROUP_MLKEM512)
  set(BENCH_TLS_GROUP "MLKEM512")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_ML_KEM_512")
elseif(CONFIG_APP_BENCH_TLS_GROUP_MLKEM768)
  set(BENCH_TLS_GROUP "MLKEM768")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_ML_KEM_768")
elseif(CONFIG_APP_BENCH_TLS_GROUP_MLKEM1024)
  set(BENCH_TLS_GROUP "MLKEM1024")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_ML_KEM_1024")
elseif(CONFIG_APP_BENCH_TLS_GROUP_SECP256R1_MLKEM768)
  set(BENCH_TLS_GROUP "SecP256r1MLKEM768")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_SECP256R1MLKEM768")
elseif(CONFIG_APP_BENCH_TLS_GROUP_X25519_MLKEM768)
  set(BENCH_TLS_GROUP "X25519MLKEM768")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_X25519MLKEM768")
elseif(CONFIG_APP_BENCH_TLS_GROUP_SECP384R1_MLKEM1024)
  set(BENCH_TLS_GROUP "SecP384r1MLKEM1024")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_SECP384R1MLKEM1024")
elseif(CONFIG_APP_BENCH_TLS_GROUP_ECDHE_P256)
  set(BENCH_TLS_GROUP "ECDHE-P-256")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_ECC_SECP256R1")
elseif(CONFIG_APP_BENCH_TLS_GROUP_ECDHE_P384)
  set(BENCH_TLS_GROUP "ECDHE-P-384")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_ECC_SECP384R1")
elseif(CONFIG_APP_BENCH_TLS_GROUP_ECDHE_P521)
  set(BENCH_TLS_GROUP "ECDHE-P-521")
  set(BENCH_TLS_GROUP_ID "WOLFSSL_ECC_SECP521R1")
else()
  message(FATAL_ERROR "No benchmark TLS group selected")
endif()

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${BENCH_GENERATED_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_compile_definitions(app PRIVATE
  APP_TLS_GROUP_ID=${BENCH_TLS_GROUP_ID}
  APP_TLS_GROUP_NAME="${BENCH_TLS_GROUP}"
)

if(CONFIG_APP_BENCH_MLKEM_BACKEND_PQM4_CLEAN)
  set(PQM4_PQCLEAN_DIR "${PQM4_MODULE}/mupq/pqclean")
  set(PQM4_COMMON_DIR "${PQM4_PQCLEAN_DIR}/common")

  if(NOT EXISTS "${PQM4_COMMON_DIR}/fips202.c")
    message(FATAL_ERROR "pqm4 PQClean sources not found at ${PQM4_PQCLEAN_DIR}")
  endif()

  add_library(pqm4_pqclean_common OBJECT
    "${PQM4_COMMON_DIR}/fips202.c"
    src/pqm4_randombytes.c
  )
  target_include_directories(pqm4_pqclean_common PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    "${PQM4_COMMON_DIR}"
  )
  target_link_libraries(pqm4_pqclean_common PRIVATE zephyr_interface)

  function(add_pqm4_mlkem_clean target level)
    set(level_dir "${PQM4_PQCLEAN_DIR}/crypto_kem/ml-kem-${level}/clean")
    add_library(${target} OBJECT
      "${level_dir}/cbd.c"
      "${level_dir}/indcpa.c"
      "${level_dir}/kem.c"
      "${level_dir}/ntt.c"
      "${level_dir}/poly.c"
      "${level_dir}/polyvec.c"
      "${level_dir}/reduce.c"
      "${level_dir}/symmetric-shake.c"
      "${level_dir}/verify.c"
    )
    target_include_directories(${target} PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/src
      "${level_dir}"
      "${PQM4_COMMON_DIR}"
    )
    target_link_libraries(${target} PRIVATE zephyr_interface)
  endfunction()

  add_pqm4_mlkem_clean(pqm4_mlkem512_clean 512)
  add_pqm4_mlkem_clean(pqm4_mlkem768_clean 768)
  add_pqm4_mlkem_clean(pqm4_mlkem1024_clean 1024)

  target_sources(app PRIVATE
    src/pqm4_mlkem_backend.c
    $<TARGET_OBJECTS:pqm4_pqclean_common>
    $<TARGET_OBJECTS:pqm4_mlkem512_clean>
    $<TARGET_OBJECTS:pqm4_mlkem768_clean>
    $<TARGET_OBJECTS:pqm4_mlkem1024_clean>
  )
  target_compile_definitions(app PRIVATE APP_MLKEM_BACKEND_NAME="pqm4-clean")
else()
  target_compile_definitions(app PRIVATE APP_MLKEM_BACKEND_NAME="wolfssl")
endif()
