#!/usr/bin/env python3
"""Measure required developer-document context by routing contract."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--route")
    parser.add_argument("--all", action="store_true", dest="all_routes")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    contract = json.loads((root / "contracts/developer-doc-routing-v1.json").read_text(encoding="utf-8"))
    routes = {item["id"]: item for item in contract["routes"]}
    if args.route and args.all_routes or not args.route and not args.all_routes:
        parser.error("choose exactly one of --route or --all")
    selected = list(routes) if args.all_routes else [args.route]
    report = []
    baseline = contract["requiredReadBaseline"]
    for route_id in selected:
        route = routes.get(route_id)
        if route is None:
            raise SystemExit(f"unknown route: {route_id}")
        files = []
        for path in route["docs"]:
            if "<" in path:
                continue
            candidate = root / path
            if candidate.is_dir():
                files.extend(item.relative_to(root).as_posix() for item in sorted(candidate.rglob("*")) if item.is_file())
            else:
                files.append(path)
        measurements = [{"path": path, "bytes": len((root / path).read_bytes())} for path in files]
        total = sum(item["bytes"] for item in measurements)
        report.append({
            "route": route_id,
            "changeType": route["changeType"],
            "files": measurements,
            "totalBytes": total,
            "baselineBytes": baseline["bytes"],
            "reductionPercent": round((baseline["bytes"] - total) / baseline["bytes"] * 100, 2),
            "status": "pass" if total < baseline["bytes"] * 0.75 else "reference",
        })
    output = {"schemaVersion": 1, "unit": "utf8Bytes", "baseline": baseline, "routes": report}
    print(json.dumps(output, ensure_ascii=False, indent=2))
    documentation = next((item for item in report if item["route"] == "documentation"), None)
    if documentation and documentation["status"] != "pass":
        raise SystemExit("documentation required-read route did not reduce context below 75% of baseline")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
