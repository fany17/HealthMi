#!/usr/bin/env python3
"""Prepare production Swift methods for offline tests with platform/IO doubles.

AppModel and SyncEngine method bodies are unchanged. The stress suite replaces
only the unsupported platform predicate macro with the identical closure.
"""

import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Temporary directory outside the repository")
    parser.add_argument("--model", type=Path, help="Optional baseline AppModel.swift")
    parser.add_argument("--suite", choices=("app", "engine", "stress"), default="app")
    parser.add_argument("--engine", type=Path, help="Optional baseline SyncEngine.swift")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output == root or root in output.parents:
        parser.error("output must be outside the repository")
    output.mkdir(parents=True, exist_ok=True)
    if args.suite in ("app", "engine"):
        for path in ("Sync/SyncDateRange.swift", "Sync/SyncRunMetrics.swift", "MiFitness/MiRegion.swift"):
            (output / Path(path).name).write_text((root / "HealthMi" / path).read_text())
    if args.suite == "app":
        for name in ("BackfillProgressStore", "BackfillRunner"):
            (output / f"{name}.swift").write_text((root / f"HealthMi/Sync/{name}.swift").read_text())
        engine_source = (root / "HealthMi/Sync/SyncEngine.swift").read_text()
        window = "    func syncWindow(" + engine_source.split("    func syncWindow(", 1)[1].split("    // MARK: - 取数与映射", 1)[0]
        (output / "Window.swift").write_text("import Foundation\nextension SyncEngine {\n" + window + "}\n")
        api_source = (root / "HealthMi/MiFitness/MiAPIClient.swift").read_text()
        errors = api_source.split("enum MiAPIError:", 1)[1].split("/// 小米健康云数据客户端", 1)[0]
        (output / "MiAPIError.swift").write_text("import Foundation\nenum MiAPIError:" + errors)
    if args.suite == "stress":
        output.mkdir(parents=True, exist_ok=True)
        source = (root / "HealthMi/Sync/StressStore.swift").read_text()
        method = "    static func replace(" + source.split("    static func replace(", 1)[1].split("    /// 删除指定时间范围", 1)[0]
        # Linux Foundation 6.0 cannot inspect this model key path. Evaluate the
        # identical predicate closure in the fake store; do not emulate SwiftData SQL.
        if method.count("#Predicate ") != 1:
            parser.error("review stress predicate adapter after source changes")
        method = method.replace("#Predicate ", "")
        (output / "StressStore.swift").write_text("import Foundation\n@MainActor enum StressStore {\n" + method + "}\n")
        for name in ("Doubles.swift", "Scenarios.swift"):
            (output / name).write_text((Path(__file__).parent / "stress" / name).read_text())
        print(f"Prepared production stress replacement method in {output}")
        return
    if args.suite == "engine":
        output.mkdir(parents=True, exist_ok=True)
        engine = args.engine or root / "HealthMi/Sync/SyncEngine.swift"
        (output / "SyncEngine.swift").write_text(engine.read_text().replace("import HealthKit\n", ""))
        for name in ("MiModels", "MiParser"):
            (output / f"{name}.swift").write_text((root / f"HealthMi/MiFitness/{name}.swift").read_text())
        states = (root / "HealthMi/Sync/SyncStateStore.swift").read_text()
        types = states.split("enum SyncDataType:", 1)[1].split("/// 每类数据的同步游标", 1)[0]
        (output / "SyncDataType.swift").write_text("enum SyncDataType:" + types)
        for name in ("Doubles.swift", "Scenarios.swift"):
            (output / name).write_text((Path(__file__).parent / "engine" / name).read_text())
        # Once introduced, compile the production replacement method unchanged
        # against the in-memory store, rather than testing a rewritten algorithm.
        writer = (root / "HealthMi/Health/HealthWriter.swift").read_text()
        query = "    func existingExternalIDs(" + writer.split("    func existingExternalIDs(", 1)[1].split("    /// 一次性批量保存", 1)[0]
        (output / "Queries.swift").write_text("import Foundation\nextension HealthWriter {\n" + query + "}\n")
        marker = "    func replace("
        if marker in writer:
            method = writer.split(marker, 1)[1].split("    // MARK: -", 1)[0]
            (output / "Replacement.swift").write_text("import Foundation\nextension HealthWriter {\n" + marker + method + "}\n")
        print(f"Prepared engine suite from {engine} in {output}")
        return
    model = args.model or root / "HealthMi/App/AppModel.swift"
    source = model.read_text()
    for module in ("HealthKit", "SwiftData"):
        statement = f"import {module}\n"
        if source.count(statement) != 1:
            parser.error(f"expected exactly one {module} import; review harness")
        source = source.replace(statement, "")
    # Reuse the production enum, rather than duplicating type names/order.
    states = (root / "HealthMi/Sync/SyncStateStore.swift").read_text()
    types = states.split("enum SyncDataType:", 1)[1].split("/// 每类数据的同步游标", 1)[0]
    output.mkdir(parents=True, exist_ok=True)
    (output / "AppModel.swift").write_text(source)
    (output / "SyncDataType.swift").write_text("enum SyncDataType:" + types)
    for filename in ("Doubles.swift", "Scenarios.swift"):
        (output / filename).write_text((Path(__file__).parent / filename).read_text())
    print(f"Prepared {model} in {output}")


if __name__ == "__main__":
    main()
