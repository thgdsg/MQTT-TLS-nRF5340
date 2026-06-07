if(NOT DEFINED ROOT_BUILD_DIR)
    message(FATAL_ERROR "ROOT_BUILD_DIR is required")
endif()

set(runner_files
    "${ROOT_BUILD_DIR}/firmware/zephyr/runners.yaml"
    "${ROOT_BUILD_DIR}/hci_ipc/zephyr/runners.yaml"
)

foreach(runner_file ${runner_files})
    if(EXISTS "${runner_file}")
        file(READ "${runner_file}" runner_yaml)
        string(REPLACE "flash-runner: nrfjprog" "flash-runner: nrfutil"
               runner_yaml "${runner_yaml}")
        file(WRITE "${runner_file}" "${runner_yaml}")
        message(STATUS "Using nrfutil flash runner: ${runner_file}")
    endif()
endforeach()
