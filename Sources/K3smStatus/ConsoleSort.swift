/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import Foundation

public enum CellValue {
    case text(String), integer(Int64), number(Double), load(unit: Int, value: Double)

    fileprivate func compare(_ other: Self) -> ComparisonResult {
        switch (self, other) {
        case let (.text(a), .text(b)): return a.localizedStandardCompare(b)
        case let (.integer(a), .integer(b)): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case let (.number(a), .number(b)): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case let (.load(au, av), .load(bu, bv)):
            if au != bu { return au < bu ? .orderedAscending : .orderedDescending }
            return av == bv ? .orderedSame : (av < bv ? .orderedAscending : .orderedDescending)
        default: return .orderedSame
        }
    }
}

public protocol ConsoleSortable {
    func sortValue(_ column: ColumnID?, now: Date) -> CellValue?
}

public struct ConsoleSort {
    public var column: ColumnID?
    public var ascending: Bool

    public init(column: ColumnID?, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    public func rows<Row: ConsoleSortable>(_ rows: [Row], now: Date = Date()) -> [Row] {
        rows.map { ($0, $0.sortValue(column, now: now)) }.sorted { a, b in
            guard let left = a.1 else { return false }
            guard let right = b.1 else { return true }
            return left.compare(right) == (ascending ? .orderedAscending : .orderedDescending)
        }.map { $0.0 }
    }
}

extension Pod: ConsoleSortable {
    public func sortValue(_ column: ColumnID?, now: Date) -> CellValue? {
        switch column {
        case nil: return .text(name)
        case .node: return nodeName.map(CellValue.text)
        case .runsAs: return .text(WorkloadsDisplay.runsAs(kind))
        case .cores: return cpuRequest.map(CellValue.number)
        case .memory: return memoryRequest.map(CellValue.integer)
        case .age: return created.map { .number(now.timeIntervalSince($0)) }
        default: return nil
        }
    }
}

extension ClusterEvent: ConsoleSortable {
    public func sortValue(_ column: ColumnID?, now: Date) -> CellValue? {
        switch column {
        case nil: return .text(message)
        case .age: return time.map { .number(now.timeIntervalSince($0)) }
        case .reason: return .text(reason)
        case .object: return .text(object)
        default: return nil
        }
    }
}

extension NodeRow: ConsoleSortable {
    public func sortValue(_ column: ColumnID?, now: Date) -> CellValue? {
        switch column {
        case nil: return .text(name)
        case .status: return .text(status)
        case .version: return .text(version)
        case .load:
            if let cpuLoadFraction { return .load(unit: 0, value: cpuLoadFraction) }
            return cpuLoadCores.map { .load(unit: 1, value: $0) }
        default: return nil
        }
    }
}

extension RegistryImage: ConsoleSortable {
    public func sortValue(_ column: ColumnID?, now: Date) -> CellValue? {
        switch column {
        case nil: return .text(reference)
        case .size: return sizeBytes.map(CellValue.integer)
        case .pods: return pods.map { .integer(Int64($0)) }
        case .nodes: return .text(cachedOnText)
        default: return nil
        }
    }
}

extension BuildRecord: ConsoleSortable {
    public func sortValue(_ column: ColumnID?, now: Date) -> CellValue? {
        switch column {
        case nil: return .text(title)
        case .status: return .text(status.word)
        case .started: return startedAt.map { .number($0.timeIntervalSinceReferenceDate) }
        case .duration: return duration(now: now).map(CellValue.number)
        default: return nil
        }
    }
}

extension ServiceRow: ConsoleSortable {
    public func sortValue(_ column: ColumnID?, now: Date) -> CellValue? {
        switch column {
        case nil: return .text(name)
        case .type: return .text(type)
        case .clusterIP: return .text(clusterIP)
        case .ports: return servicePorts.first.map { .integer(Int64($0.port)) }
        case .hosts: return .text(hostsText)
        default: return nil
        }
    }
}

extension StorageRow: ConsoleSortable {
    public func sortValue(_ column: ColumnID?, now: Date) -> CellValue? {
        switch column {
        case nil: return .text(claim ?? "no claim")
        case .volume: return volume.map(CellValue.text)
        case .capacity: return capacityBytes.map(CellValue.integer)
        case .phase: return .text(phase)
        default: return nil
        }
    }
}

extension ModelRow: ConsoleSortable {
    public func sortValue(_ column: ColumnID?, now: Date) -> CellValue? {
        switch column {
        case nil: return .text(name)
        case .phase: return .text(phase)
        case .ready: return .integer(Int64(readyReplicas))
        case .endpoint: return endpoint.map(CellValue.text)
        default: return nil
        }
    }
}
