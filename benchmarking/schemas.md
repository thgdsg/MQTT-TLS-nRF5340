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
- `kex_nist_level`: NIST security level for the key exchange group.
- `cert_sig_alg`: certificate/signature algorithm to use for server auth.
- `sig_nist_level`: NIST security level for the signature algorithm.
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
- `tcp_connect_ms`: TCP connect time measured by the board.
- `tls_handshake_ms`: TLS handshake time measured by the board.
- `mqtt_connect_ms`: MQTT CONNECT/SUBSCRIBE time measured by the board.
- `full_connect_ms`: TCP + TLS + MQTT time measured by the board.
- `error_code`: firmware or host error code when applicable.
- `message`: short diagnostic.

## Summary

`results/<run_id>/summary.csv` contains one row per case.

Columns:

- `case_id`, `kex_group`, `cert_sig_alg`
- `status`: `success`, `partial`, `failed`, or `unsupported`.
- `success_count`, `fail_count`, `timeout_count`
- `mean_handshake_ms`, `median_handshake_ms`, `p95_handshake_ms`
- `min_handshake_ms`, `max_handshake_ms`, `stddev_handshake_ms`
- `handshake_throughput_hps`
- `mean_full_connect_ms`, `connections_per_second`
- `notes`
