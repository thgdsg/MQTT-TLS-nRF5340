#!/usr/bin/env python3
"""Plot TLS handshake bar charts from a benchmark result directory."""

from __future__ import annotations

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

try:
    import matplotlib.pyplot as plt
    import numpy as np
except ModuleNotFoundError as exc:
    raise SystemExit(
        "Missing Python plotting dependency. On Arch/CachyOS, install it with:\n"
        "  sudo pacman -S python-matplotlib python-numpy\n"
        "or use a virtualenv with:\n"
        "  python -m pip install matplotlib numpy"
    ) from exc


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS_ROOT = PROJECT_ROOT / "benchmarking" / "results"

PQC_KEM_PREFIXES = ("MLKEM", "SecP", "X25519MLKEM")
PQC_SIG_PREFIXES = ("ML-DSA", "SLH-DSA")
SECURITY_LEVELS = (1, 3, 5)


def resolve_run_dir(value: str) -> Path:
    path = Path(value).expanduser()
    if path.exists():
        return path.resolve()

    candidate = DEFAULT_RESULTS_ROOT / value
    if candidate.exists():
        return candidate.resolve()

    raise FileNotFoundError(
        f"Benchmark result directory not found: {value}. "
        f"Tried {path} and {candidate}."
    )


def is_pqc_or_hybrid_kem(kex_group: str) -> bool:
    return kex_group.startswith(PQC_KEM_PREFIXES)


def is_pqc_signature(cert_sig_alg: str) -> bool:
    return cert_sig_alg.startswith(PQC_SIG_PREFIXES)


def is_pqc_or_hybrid_case(row: dict[str, str]) -> bool:
    return is_pqc_or_hybrid_kem(row.get("kex_group", "")) or is_pqc_signature(
        row.get("cert_sig_alg", "")
    )


def algorithm_sort_key(name: str, is_pqc: bool) -> tuple[int, str]:
    return (1 if is_pqc else 0, name.lower())


def float_or_none(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def int_or_none(value: str | None) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def normalize_security_level(level: int | None) -> int | None:
    if level is None:
        return None
    if level <= 2:
        return 1
    if level <= 3:
        return 3
    return 5


def kem_security_level(row: dict[str, str]) -> int | None:
    return normalize_security_level(int_or_none(row.get("kex_nist_level")))


def load_from_summary(summary_csv: Path) -> list[dict[str, str]]:
    if not summary_csv.exists():
        return []
    with summary_csv.open(newline="") as fp:
        rows = list(csv.DictReader(fp))
    return [row for row in rows if float_or_none(row.get("mean_handshake_ms")) is not None]


def load_from_attempts(run_dir: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for attempts_csv in sorted((run_dir / "cases").glob("*/attempts.csv")):
        with attempts_csv.open(newline="") as fp:
            attempts = list(csv.DictReader(fp))
        successes = [
            row
            for row in attempts
            if row.get("status") == "success"
            and row.get("warmup") != "1"
            and float_or_none(row.get("tls_handshake_ms")) is not None
        ]
        if not successes:
            continue

        first = successes[0]
        values = [float(row["tls_handshake_ms"]) for row in successes]
        rows.append(
            {
                "case_id": attempts_csv.parent.name.split("_", 1)[-1],
                "kex_group": first.get("kex_group", ""),
                "kex_nist_level": first.get("kex_nist_level", ""),
                "cert_sig_alg": first.get("cert_sig_alg", ""),
                "sig_nist_level": first.get("sig_nist_level", ""),
                "mean_handshake_ms": f"{statistics.mean(values):.3f}",
                "success_count": str(len(successes)),
            }
        )
    return rows


def load_rows(run_dir: Path) -> list[dict[str, str]]:
    rows = load_from_summary(run_dir / "summary.csv")
    if rows:
        return rows
    return load_from_attempts(run_dir)


def short_label(row: dict[str, str]) -> str:
    kex = row.get("kex_group", "")
    sig = row.get("cert_sig_alg", "")
    return f"{kex}\n{sig}"


def plot_group(rows: list[dict[str, str]], title: str, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    rows = sorted(rows, key=lambda row: float(row["mean_handshake_ms"]), reverse=True)

    fig_width = max(12, len(rows) * 0.62)
    fig, ax = plt.subplots(figsize=(fig_width, 7.5), constrained_layout=True)

    labels = [short_label(row) for row in rows]
    values = [float(row["mean_handshake_ms"]) for row in rows]
    colors = plt.cm.inferno(np.linspace(0.15, 0.9, len(values)))
    bars = ax.bar(range(len(values)), values, color=colors, edgecolor="#1a1a1a", linewidth=0.4)

    ax.set_title(title)
    ax.set_ylabel("TLS handshake mean (ms)")
    ax.set_xlabel("KEM / certificate signature")
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, rotation=65, ha="right", fontsize=8)
    ax.grid(axis="y", linestyle=":", alpha=0.35)

    for bar, value in zip(bars, values):
        ax.annotate(
            f"{value:.0f}",
            xy=(bar.get_x() + bar.get_width() / 2, bar.get_height()),
            xytext=(0, 3),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=7,
        )

    fig.savefig(output, dpi=180)
    plt.close(fig)


def plot_security_levels(
    rows: list[dict[str, str]],
    title_prefix: str,
    filename_prefix: str,
    out_dir: Path,
    run_id: str,
) -> dict[int, int]:
    counts: dict[int, int] = {}
    for level in SECURITY_LEVELS:
        level_rows = [row for row in rows if kem_security_level(row) == level]
        counts[level] = len(level_rows)
        if not level_rows:
            continue
        plot_group(
            level_rows,
            f"{title_prefix} - NIST level {level} - {run_id}",
            out_dir / f"{filename_prefix}_nist_level_{level}.png",
        )
    return counts


def plot_heatmap(rows: list[dict[str, str]], output: Path, run_id: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)

    values_by_pair: dict[tuple[str, str], list[float]] = defaultdict(list)
    values_by_signature: dict[str, list[float]] = defaultdict(list)
    for row in rows:
        kex = row.get("kex_group", "")
        sig = row.get("cert_sig_alg", "")
        value = float_or_none(row.get("mean_handshake_ms"))
        if not kex or not sig or value is None:
            continue
        values_by_pair[(kex, sig)].append(value)
        values_by_signature[sig].append(value)

    if not values_by_pair:
        raise SystemExit("No KEM/signature handshake values found for heatmap")

    kems = sorted(
        {kex for kex, _ in values_by_pair},
        key=lambda kex: algorithm_sort_key(kex, is_pqc_or_hybrid_kem(kex)),
    )
    sigs = sorted(
        {sig for _, sig in values_by_pair},
        key=lambda sig: (
            1 if is_pqc_signature(sig) else 0,
            statistics.mean(values_by_signature[sig]),
            sig.lower(),
        ),
    )

    matrix = np.full((len(sigs), len(kems)), np.nan)
    for row_idx, sig in enumerate(sigs):
        for col_idx, kex in enumerate(kems):
            pair_values = values_by_pair.get((kex, sig))
            if pair_values:
                matrix[row_idx, col_idx] = statistics.mean(pair_values)

    masked_matrix = np.ma.masked_invalid(matrix)
    cmap = plt.cm.Greens.copy()
    cmap.set_bad("#f1f1f1")

    fig_width = max(9.5, len(kems) * 0.72)
    fig_height = max(6.5, len(sigs) * 0.48)
    fig, ax = plt.subplots(figsize=(fig_width, fig_height), constrained_layout=True)
    image = ax.imshow(masked_matrix, cmap=cmap, aspect="auto")

    ax.set_title(f"TLS handshake heatmap - {run_id}")
    ax.set_xlabel("KEM / TLS key exchange group")
    ax.set_ylabel("Certificate signature algorithm")
    ax.set_xticks(range(len(kems)))
    ax.set_yticks(range(len(sigs)))
    ax.set_xticklabels(kems, rotation=55, ha="right", fontsize=8)
    ax.set_yticklabels(sigs, fontsize=8)

    for row_idx in range(len(sigs)):
        for col_idx in range(len(kems)):
            value = matrix[row_idx, col_idx]
            if np.isnan(value):
                continue
            ax.text(
                col_idx,
                row_idx,
                f"{value:.0f}",
                ha="center",
                va="center",
                fontsize=7,
                color="white" if value >= np.nanmedian(matrix) else "black",
            )

    colorbar = fig.colorbar(image, ax=ax)
    colorbar.set_label("TLS handshake mean (ms)")
    fig.savefig(output, dpi=180)
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "run_dir",
        help="Benchmark result directory or run id under benchmarking/results, e.g. 20260620_230500_123",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="Output directory for PNG files. Defaults to graphic/out/<run_id>.",
    )
    parser.add_argument(
        "--sec-levels",
        action="store_true",
        help=(
            "Also generate charts split by the KEM NIST security level "
            "(level 2 is grouped with level 1)."
        ),
    )
    parser.add_argument(
        "--heatmap",
        action="store_true",
        help=(
            "Also generate a KEM by certificate-signature heatmap using mean TLS "
            "handshake time. Classical algorithms are sorted before PQC/hybrid ones."
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_dir = resolve_run_dir(args.run_dir)
    rows = load_rows(run_dir)
    if not rows:
        raise SystemExit(f"No successful TLS handshake rows found in {run_dir}")

    pqc_rows = [row for row in rows if is_pqc_or_hybrid_case(row)]
    classical_rows = [row for row in rows if not is_pqc_or_hybrid_case(row)]

    out_dir = args.out_dir or (PROJECT_ROOT / "graphic" / "out" / run_dir.name)
    if pqc_rows:
        plot_group(
            pqc_rows,
            f"PQC / hybrid TLS handshakes - {run_dir.name}",
            out_dir / "tls_handshake_pqc_hybrid.png",
        )
    if classical_rows:
        plot_group(
            classical_rows,
            f"Classical TLS handshakes - {run_dir.name}",
            out_dir / "tls_handshake_classical.png",
        )

    if args.sec_levels:
        pqc_counts = plot_security_levels(
            pqc_rows,
            "PQC / hybrid TLS handshakes",
            "tls_handshake_pqc_hybrid",
            out_dir,
            run_dir.name,
        )
        classical_counts = plot_security_levels(
            classical_rows,
            "Classical TLS handshakes",
            "tls_handshake_classical",
            out_dir,
            run_dir.name,
        )
        for level in SECURITY_LEVELS:
            print(f"pqc_hybrid_nist_level_{level}={pqc_counts.get(level, 0)}")
            print(f"classical_nist_level_{level}={classical_counts.get(level, 0)}")

    if args.heatmap:
        plot_heatmap(rows, out_dir / "tls_handshake_heatmap.png", run_dir.name)
        print("heatmap=1")

    print(f"rows={len(rows)}")
    print(f"pqc_hybrid={len(pqc_rows)}")
    print(f"classical={len(classical_rows)}")
    print(f"out_dir={out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
