//
//  MoveReducer.swift
//  DeepDiff
//
//  Created by Khoa Pham.
//  Copyright © 2018 Khoa Pham. All rights reserved.
//

import Foundation

struct MoveReducer<T: DiffAware> {
  func reduce(changes: [Change<T>]) -> [Change<T>] {
    // Find pairs of .insert and .delete with same item
    let inserts = changes.compactMap { $0.insert }
    guard !inserts.isEmpty else { return changes }

    var result = changes
    var indicesToRemove = Set<Int>()

    for insert in inserts {
      guard let insertIndex = result.indices.first(where: {
              !indicesToRemove.contains($0) && (result[$0].insert?.item).map { T.compareContent($0, insert.item) } == true
            }),
            let deleteIndex = result.indices.first(where: {
              !indicesToRemove.contains($0) && (result[$0].delete?.item).map { T.compareContent($0, insert.item) } == true
            }),
            let insertChange = result[insertIndex].insert,
            let deleteChange = result[deleteIndex].delete
      else { continue }

      indicesToRemove.insert(insertIndex)
      indicesToRemove.insert(deleteIndex)
      result.append(.move(Move(item: insert.item, fromIndex: deleteChange.index, toIndex: insertChange.index)))
    }

    return result.enumerated().compactMap { indicesToRemove.contains($0.offset) ? nil : $0.element }
  }
}
