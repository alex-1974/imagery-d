"""Check a pinned feature benchmark receipt against local regression ceilings.

These machine-specific ceilings detect regression; they do not establish
cross-platform performance or acceptance of gaps to mature implementations.
Run the benchmark with the documented affinity/build/warmup before this tool.
"""
import argparse
import csv
import json
import math
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('receipt', type=Path)
parser.add_argument('--domain', choices=['scalar', 'rgb'], required=True)
parser.add_argument('--size', type=int, choices=[1024, 4096], required=True)
parser.add_argument('--budgets', type=Path, default=Path(__file__).resolve().parents[1]/'docs/benchmarks/feature-budget-2026-11-22.json')
args = parser.parse_args()
budgets = json.loads(args.budgets.read_text())
lines = args.receipt.read_text().splitlines()
expected_input = 'rgb8' if args.domain == 'rgb' else 'float32-values'
metadata = dict(field.split('=', 1) for field in lines[0].split() if '=' in field) if lines else {}
if (metadata.get('size') != str(args.size) or metadata.get('input') != expected_input
        or metadata.get('compiler') != 'LDC' or metadata.get('tile') != '256'
        or int(metadata.get('repeats', 0)) < 3):
    raise SystemExit('Receipt metadata must match LDC, size/domain, tile=256 and >=3 measured repetitions')
header, observed, failures = None, set(), []
for line in lines:
    row = next(csv.reader([line]))
    if row and row[0] == 'feature':
        header = row
        continue
    if not header or not row or row[0] not in budgets['operators']:
        continue
    feature = row[0]
    if feature in observed:
        failures.append(f'{feature}: duplicate measurement')
    observed.add(feature)
    record = dict(zip(header, row))
    budget = budgets['operators'][feature]
    latency = float(record['ns_per_pixel'])
    allocation = int(record['gc_bytes_per_call'])/args.size**2
    if not math.isfinite(latency) or latency <= 0 or latency > budget['ns_per_pixel'][args.domain]:
        failures.append(f'{feature}: {latency} ns/pixel exceeds {budget["ns_per_pixel"][args.domain]}')
    if allocation < 0 or allocation > budget['gc_bytes_per_pixel']:
        failures.append(f'{feature}: {allocation:.3f} allocated bytes/pixel exceeds {budget["gc_bytes_per_pixel"]}')
    if not math.isfinite(float(record['checksum'])):
        failures.append(f'{feature}: nonfinite output checksum')
    if 'peak_tile_bytes' in record and not 0 < int(record['peak_tile_bytes']) <= 8*1024*1024:
        failures.append(f'{feature}: engine tile payload exceeds 8 MiB')
required = set(budgets['operators'])-({'clahe'} if args.domain == 'scalar' else set())
failures += [f'{feature}: missing' for feature in sorted(required-observed)]
if failures:
    raise SystemExit('\n'.join(failures))
print(f'PASS: {len(observed)} {args.size}² {args.domain} local latency/allocation ceilings')
