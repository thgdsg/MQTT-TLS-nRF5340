#!/usr/bin/env python3
"""Generate reproducible TLS benchmark input cases."""

from __future__ import annotations

import argparse
import csv
import random
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parent
CASES_DIR = ROOT / "cases"


@dataclass(frozen=True)
class KemCase:
    name: str
    nist_level: int
    public_key_bytes: int
    ciphertext_bytes: int
    shared_secret_bytes: int


@dataclass(frozen=True)
class SigCase:
    name: str
    nist_level: int
    public_key_bytes: int
    private_key_bytes: int
    signature_bytes: int
    expected_support: str = "probe"
    notes: str = ""


KEMS = [
    KemCase("MLKEM512", 1, 800, 768, 32),
    KemCase("MLKEM768", 3, 1184, 1088, 32),
    KemCase("MLKEM1024", 5, 1568, 1568, 32),
    KemCase("ECDHE-P-256", 1, 65, 65, 32),
    KemCase("ECDHE-P-384", 3, 97, 97, 48),
    KemCase("ECDHE-P-521", 5, 133, 133, 66),
]

SIGS = [
    SigCase("ML-DSA-44", 2, 1312, 2560, 2420),
    SigCase("ML-DSA-65", 3, 1952, 4032, 3309),
    SigCase("ML-DSA-87", 5, 2592, 4896, 4627),
    SigCase("SLH-DSA-SHAKE-128s", 1, 32, 64, 7856),
    SigCase("SLH-DSA-SHAKE-192s", 3, 48, 96, 16224),
    SigCase("SLH-DSA-SHAKE-256s", 5, 64, 128, 29792),
    SigCase("ECDSA-P-256", 1, 65, 32, 64, "required", "classic approximate NIST level 1"),
    SigCase("ECDSA-P-384", 3, 97, 48, 96, "required", "classic approximate NIST level 3"),
    SigCase("ECDSA-P-521", 5, 133, 66, 132, "required", "classic approximate NIST level 5"),
    SigCase("RSA-PSS-3072", 1, 384, 384, 384, "required", "classic approximate NIST level 1"),
    SigCase("RSA-PSS-7680", 3, 960, 960, 960, "required", "classic approximate NIST level 3"),
    SigCase("RSA-PSS-15360", 5, 1920, 1920, 1920, "required", "classic approximate NIST level 5"),
]

FIELDNAMES = [
    "case_id",
    "enabled",
    "kex_group",
    "kex_nist_level",
    "kex_public_key_bytes",
    "kex_ciphertext_bytes",
    "kex_shared_secret_bytes",
    "cert_sig_alg",
    "sig_nist_level",
    "sig_public_key_bytes",
    "sig_private_key_bytes",
    "sig_signature_bytes",
    "iterations",
    "warmup_iterations",
    "expected_support",
    "notes",
]


def slug(value: str) -> str:
    return re.sub(r"_+", "_", re.sub(r"[^a-z0-9]+", "_", value.lower())).strip("_")


def build_cases(iterations: int, warmup_iterations: int) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for kem in KEMS:
        for sig in SIGS:
            case_id = f"{slug(kem.name)}__{slug(sig.name)}"
            rows.append(
                {
                    "case_id": case_id,
                    "enabled": "1",
                    "kex_group": kem.name,
                    "kex_nist_level": str(kem.nist_level),
                    "kex_public_key_bytes": str(kem.public_key_bytes),
                    "kex_ciphertext_bytes": str(kem.ciphertext_bytes),
                    "kex_shared_secret_bytes": str(kem.shared_secret_bytes),
                    "cert_sig_alg": sig.name,
                    "sig_nist_level": str(sig.nist_level),
                    "sig_public_key_bytes": str(sig.public_key_bytes),
                    "sig_private_key_bytes": str(sig.private_key_bytes),
                    "sig_signature_bytes": str(sig.signature_bytes),
                    "iterations": str(iterations),
                    "warmup_iterations": str(warmup_iterations),
                    "expected_support": sig.expected_support,
                    "notes": sig.notes,
                }
            )
    return rows


def write_cases(rows: list[dict[str, str]], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite existing cases file: {output}")

    with output.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=None, help="shuffle seed")
    parser.add_argument("--iterations", type=int, default=10, help="measured attempts per case")
    parser.add_argument("--warmup-iterations", type=int, default=2, help="warmup attempts per case")
    parser.add_argument("--output", type=Path, default=None, help="output CSV path")
    parser.add_argument("--no-shuffle", action="store_true", help="keep deterministic matrix order")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    seed = args.seed if args.seed is not None else random.SystemRandom().randint(1, 2**31 - 1)
    rows = build_cases(args.iterations, args.warmup_iterations)

    if not args.no_shuffle:
        rng = random.Random(seed)
        rng.shuffle(rows)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output = args.output or CASES_DIR / f"{timestamp}_benchmark_cases.csv"
    write_cases(rows, output)
    print(f"seed={seed}")
    print(f"cases={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
