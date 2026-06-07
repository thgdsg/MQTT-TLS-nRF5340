# Force all sysbuild domains to use nrfutil when west flash is invoked.
set(BOARD_FLASH_RUNNER nrfutil CACHE STRING "Use nrfutil for west flash" FORCE)

add_custom_target(force_nrfutil_flash_runner ALL
    COMMAND ${CMAKE_COMMAND}
        -DROOT_BUILD_DIR=${CMAKE_BINARY_DIR}
        -P ${APP_DIR}/cmake/force_nrfutil_runner.cmake
    DEPENDS firmware hci_ipc
)
