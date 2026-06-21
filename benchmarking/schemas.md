# Benchmark CSV Schemas

All benchmark files are CSV so they can be inspected with shell tools,
spreadsheets, Python, or R. Generated inputs and outputs are written under
`benchmarking/` only.

## Input Cases

`generate_cases.py` writes `cases/<timestamp>_benchmark_cases.csv`.

Columns:

- `case_id`: stable case identifier.
- `enabled`: `1` or `0`.
- `kex_group`: TLS 1.3 key exchange group, such as `MLKEM768`.
  With universal KEM firmware enabled, this is the group forced by the
  benchmark server for the case; the board firmware may advertise multiple
  groups from one flashed image.
- `kex_nist_level`: NIST security level for the key exchange group.
- `kex_public_key_bytes`: public key / key share size for the key exchange.
- `kex_ciphertext_bytes`: ciphertext / peer key share size for the key exchange.
- `kex_shared_secret_bytes`: derived shared secret size for the key exchange.
- `cert_sig_alg`: certificate/signature algorithm to use for server auth.
- `sig_nist_level`: NIST security level for the signature algorithm.
- `sig_public_key_bytes`: signature public key size.
- `sig_private_key_bytes`: signature private key size.
- `sig_signature_bytes`: signature size.
- `iterations`: measured attempts for this case.
- `warmup_iterations`: attempts discarded before measurement.
- `expected_support`: `required`, `probe`, or `known_unsupported`.
- `notes`: free-form explanation.

## Run Manifest

`results/<run_id>/run_manifest.csv` records the randomized execution order.

Columns:

- `sequence`: 1-based execution order after shuffling.
- all input case columns.
- `seed`: seed used to shuffle cases.
- `run_id`: result directory name.

## Attempts

Each case writes `results/<run_id>/cases/<sequence>_<case_id>/attempts.csv`.

Columns:

- `attempt_index`: 1-based attempt index, including warmups.
- `warmup`: `1` for warmup attempt, `0` for measured attempt.
- `status`: `success`, `timeout`, `error`, or `unsupported`.
- key exchange metadata: `kex_group`, `kex_nist_level`,
  `kex_public_key_bytes`, `kex_ciphertext_bytes`,
  `kex_shared_secret_bytes`
- certificate/signature metadata: `cert_sig_alg`, `sig_nist_level`,
  `sig_public_key_bytes`, `sig_private_key_bytes`, `sig_signature_bytes`
- `tcp_connect_ms`: TCP connect time measured by the board.
- `tls_handshake_ms`: TLS path time measured by the board, after TCP connect and
  including local wolfSSL TLS context setup.
- `raw_handshake_ms`: TLS network handshake time measured by the board, after
  subtracting local `tls_setup_ms` from `tls_handshake_ms`.
- `mqtt_connect_ms`: MQTT CONNECT/SUBSCRIBE time measured by the board.
- `full_connect_ms`: TCP + TLS + MQTT time measured by the board.
- `error_code`: firmware or host error code when applicable.
- `message`: short diagnostic.
- `client_wall_cycles`: wall-clock hardware cycles consumed by this board-side attempt.
- `client_cpu_cycles`: non-idle client CPU cycles consumed by this board-side attempt.
- `client_cpu_ms`: `client_cpu_cycles` converted to milliseconds.
- `client_cpu_pct_x100`: client CPU utilization percentage multiplied by 100.
- `client_wolfssl_peak_bytes`: peak bytes allocated through wolfSSL during the attempt.
- `client_wolfssl_failures`: wolfSSL allocation failures during the attempt.
- `client_heap_current_bytes`: system heap bytes allocated when the attempt finished.
- `client_heap_peak_bytes`: peak system heap bytes allocated during the attempt.

## Summary

`results/<run_id>/summary.csv` contains one row per case.

Columns:

- `case_id`, `kex_group`, `kex_nist_level`, `cert_sig_alg`, `sig_nist_level`
- key size metadata: `kex_public_key_bytes`, `kex_ciphertext_bytes`,
  `kex_shared_secret_bytes`, `sig_public_key_bytes`, `sig_private_key_bytes`,
  `sig_signature_bytes`
- `status`: `success`, `partial`, `failed`, or `unsupported`.
- `success_count`, `fail_count`, `timeout_count`
- `mean_handshake_ms`, `median_handshake_ms`, `p95_handshake_ms`
- `min_handshake_ms`, `max_handshake_ms`, `stddev_handshake_ms`
- `handshake_throughput_hps`
- raw TLS network-handshake aggregates: `mean_raw_handshake_ms`,
  `median_raw_handshake_ms`, `p95_raw_handshake_ms`,
  `min_raw_handshake_ms`, `max_raw_handshake_ms`,
  `stddev_raw_handshake_ms`, `raw_handshake_throughput_hps`
- `mean_full_connect_ms`, `connections_per_second`
- client resource aggregates: `mean_client_cpu_ms`, `mean_client_cpu_pct`,
  `max_client_wolfssl_peak_bytes`, `max_client_wolfssl_failures`,
  `max_client_heap_current_bytes`, `max_client_heap_peak_bytes`
- `notes`
