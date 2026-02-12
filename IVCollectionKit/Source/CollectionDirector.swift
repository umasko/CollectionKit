//
//  ProductDetailDirector.swift
//  Marketplace
//
//  Created by Igor Vedeneev on 13.08.17.
//  Copyright © 2017 WeAreLT. All rights reserved.
//

import UIKit

open class CollectionDirector: NSObject {
    /// Array of sections models
    public private(set) var sections = [AbstractCollectionSection]()
    ///Register cell classes & xibs automatically
    open var shouldUseAutomaticViewRegistration: Bool = false
    ///Adjust z position for headers/footers to prevent scroll indicator hiding at iOS11
    open var shouldAdjustSupplementaryViewLayerZPosition: Bool = true
    ///Forward scrollView delegate messages to specific object
    open weak var scrollDelegate: UIScrollViewDelegate?

    private let sectionsLock = NSRecursiveLock()

    private weak var collectionView: UICollectionView?
    private lazy var viewsRegisterer: CollectionReusableViewsRegisterer? = {
        guard let cv = collectionView else { return nil }
        return CollectionReusableViewsRegisterer(collectionView: cv)
    }()

    private var sectionIds: [String] = []
    private var lastCommitedSectionAndItemsIdentifiers: [String: [String]] = [:]

    /// Flag indicating whether updates are currently in progress
    private var isPerformingUpdates = false

    /// Flag indicating that another update was requested while a batch update was in progress
    private var needsUpdateAfterCurrentBatch = false
    private var pendingUpdateCompletion: (() -> Void)?

    var isEmpty: Bool {
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        if sections.isEmpty {
            return true
        }
        return sections.reduce(true, { $0 && $1.numberOfItems() == 0 })
    }

    /// Ensures the current code is running on the main thread (DEBUG only)
    private func assertMainThread(function: String = #function) {
        #if DEBUG
        assert(Thread.isMainThread, "CollectionDirector.\(function) must be called on the main thread")
        #endif
    }

    private func withSectionsLock<T>(_ block: () -> T) -> T {
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        return block()
    }

    public init(collectionView: UICollectionView,
                sections: [AbstractCollectionSection] = [],
                shouldUseAutomaticViewRegistration: Bool = true,
                shouldAdjustSupplementaryViewLayerZPosition: Bool = true)
    {
        
        self.collectionView = collectionView
        super.init()
        collectionView.dataSource = self
        collectionView.delegate = self
        self.shouldUseAutomaticViewRegistration = shouldUseAutomaticViewRegistration
        self.shouldAdjustSupplementaryViewLayerZPosition = shouldAdjustSupplementaryViewLayerZPosition
    }
    
    /// Safely retrieves a section at the given index
    /// - Parameter index: The section index
    /// - Returns: The section if it exists, nil otherwise
    private func section(for index: Int) -> AbstractCollectionSection? {
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        guard sections.indices.contains(index) else {
            return nil
        }
        return sections[index]
    }

    /// Save all section and items and sections identifiers "snapshot". It will be used to compare current state during next update
    private func createSnapshot() {
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        sectionIds = sections.map { $0.identifier }
        lastCommitedSectionAndItemsIdentifiers = [:]
        for s in sections {
            lastCommitedSectionAndItemsIdentifiers[s.identifier] = s.currentItemIds()
        }
    }

    private var sectionsCount: Int {
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        return sections.count
    }
}

//MARK:- Public
extension CollectionDirector {
    /// Invokes empty batch update block. Typical use case: re-calculate cell size or toggle state of expandable section
    public func setNeedsUpdate() {
        assertMainThread()
        collectionView?.performBatchUpdates({}, completion: nil)
    }

    public func remove(section: AbstractCollectionSection) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        guard let index = sections.firstIndex(where: { $0.identifier == section.identifier }) else { return }
        sections.remove(at: index)
    }

    public func removeSection(at index: Int) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        guard sections.indices.contains(index) else { return }
        sections.remove(at: index)
    }

    public func removeSections(in range: Range<Int>) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        let clampedRange = range.clamped(to: 0..<sections.count)
        guard !clampedRange.isEmpty else { return }
        sections.removeSubrange(clampedRange)
    }

    /// Reloads collectionview and saves director state
    public func reload() {
        assertMainThread()
        collectionView?.reloadData()
        createSnapshot()
    }

    public func contains(section: AbstractCollectionSection) -> Bool {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        return sections.contains(where: { $0.identifier == section.identifier })
    }

    public func append(sectionsToAppend: [AbstractCollectionSection]) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        sections.append(contentsOf: sectionsToAppend)
    }

    public func remove(sectionsToRemove: [AbstractCollectionSection]) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        let indicies = sectionsToRemove.compactMap { sec in
            return self.sections.firstIndex(where: { $0 == sec })
        }
        sections.remove(at: indicies.sorted().reversed())
    }
    
    /// Calculates and performs managed UICollectionView updates based on diff between sections array state
    /// after last update or reload and current state
    /// if `UICollectionView` is empty performs `reloadData` instead of batch updates to prevent crash
    /// - parameter forceReloadDataForLargeAmountOfChanges: if there is > 50 section changes perform reload data instead of animated updates. `false` by default
    /// - parameter completion: closure, which will be called after all updates has been performed. Nullable
    ///
    public func performUpdates(forceReloadDataForLargeAmountOfChanges: Bool = false,
                               completion: (() -> Void)? = nil)
    {
        assertMainThread()

        // If a batch update is already in progress, flag for retry after it completes
        guard !isPerformingUpdates else {
            needsUpdateAfterCurrentBatch = true
            let existing = pendingUpdateCompletion
            pendingUpdateCompletion = {
                existing?()
                completion?()
            }
            return
        }

        isPerformingUpdates = true

        let newSectionIds = sections.map { $0.identifier }
        let oldSectionIds = sectionIds
        let sectionChanges = diff(old: oldSectionIds, new: newSectionIds)

        // if there is no sections in cv, it crashes :(
        if oldSectionIds.isEmpty {
            reload()
            isPerformingUpdates = false
            completion?()
            return
        }

        if sectionChanges.count > 50 && forceReloadDataForLargeAmountOfChanges {
            reload()
            isPerformingUpdates = false
            completion?()
            return
        }

        let converter = IndexPathConverter()
        var itemChanges = [ChangeWithIndexPath]()
        for (idx, section) in sections.enumerated() {
            let oldItemIds = lastCommitedSectionAndItemsIdentifiers[section.identifier] ?? section.currentItemIds()
            let diff_ = diff(old: oldItemIds, new: section.currentItemIds())
            guard !diff_.isEmpty else { continue }
            itemChanges.append(converter.convert(changes: diff_, section: idx))
        }

        createSnapshot()

        guard let cv = collectionView else {
            isPerformingUpdates = false
            completion?()
            return
        }

        cv.performBatchUpdates({
            itemChanges.forEach { (changesWithIndexPath) in

                changesWithIndexPath.deletes.executeIfPresent { deletes in
                    let indexPaths: [IndexPath]

                    if !sectionChanges.isEmpty {
                        indexPaths = deletes.compactMap { delete -> IndexPath? in
                            guard newSectionIds.indices.contains(delete.section),
                                  let oldIdx = oldSectionIds.firstIndex(of: newSectionIds[delete.section])
                            else { return nil }
                            return IndexPath(item: delete.item, section: oldIdx)
                        }
                    } else {
                        indexPaths = deletes
                    }

                    cv.deleteItems(at: indexPaths)
                }

                changesWithIndexPath.inserts.executeIfPresent {
                    cv.insertItems(at: $0)
                }

                changesWithIndexPath.moves.executeIfPresent {
                    $0.forEach { move in
                        let from: IndexPath
                        let to: IndexPath = move.to
                        if !sectionChanges.isEmpty {
                            guard newSectionIds.indices.contains(move.to.section),
                                  let oldSectionIdx = oldSectionIds.firstIndex(of: newSectionIds[move.to.section]) else {
                                assertionFailure("Invalid move: section index out of bounds or not found.")
                                return
                            }
                            from = IndexPath(item: move.from.item, section: oldSectionIdx)
                        } else {
                            from = move.from
                        }

                        cv.moveItem(at: from, to: to)
                    }
                }
            }

            let sectionDeletes = sectionChanges.compactMap { $0.delete?.index }
            sectionDeletes.executeIfPresent { deletes in
                cv.deleteSections(IndexSet(deletes))
            }

            let sectionInserts = sectionChanges.compactMap { $0.insert?.index }
            sectionInserts.executeIfPresent { inserts in
                cv.insertSections(IndexSet(inserts))
            }

            sectionChanges.compactMap { $0.move }.executeIfPresent { moves in
                moves.forEach { cv.moveSection($0.fromIndex, toSection: $0.toIndex) }
            }
        }) { [weak self, weak cv] _ in
            self?.isPerformingUpdates = false

            // Perform reloads AFTER batch updates complete
            if let cv = cv {
                let replaceIndexPaths = itemChanges.flatMap { $0.replaces }
                if !replaceIndexPaths.isEmpty {
                    cv.reloadItems(at: replaceIndexPaths)
                }

                let replaceSections = sectionChanges.compactMap { $0.replace?.index }
                if !replaceSections.isEmpty {
                    cv.reloadSections(IndexSet(replaceSections))
                }

                // Invalidate layout after batch updates to pick up supplementary view changes
                // (must be AFTER batch completes, not before — calling it before performBatchUpdates
                // causes compositional layouts to fetch NEW-state section definitions while UIKit
                // is still trying to animate the OLD→NEW transition, crashing for sections that
                // changed emptiness)
                cv.collectionViewLayout.invalidateLayout()
            }
            completion?()

            // Process any updates that were requested while batch update was in progress
            if let self, self.needsUpdateAfterCurrentBatch {
                self.needsUpdateAfterCurrentBatch = false
                let pendingCompletion = self.pendingUpdateCompletion
                self.pendingUpdateCompletion = nil
                DispatchQueue.main.async {
                    self.performUpdates(completion: pendingCompletion)
                }
            }
        }
    }
    /// Removes all sections from director
    /// - parameter clearSections: if `true` removes all items from sections. Remember, that you should override `removeAll()` method in your custom section. This method removes all items from array in `CollectionSection` implementation and does nothing by default
    public func removeAll(clearSections: Bool = false) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        if clearSections {
            sections.forEach { $0.removeAll() }
        }
        sections.removeAll()
        createSnapshot()
    }

    public func append(section: AbstractCollectionSection) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        sections.append(section)
    }

    public func insert(section: AbstractCollectionSection,
                       after afterSection: AbstractCollectionSection)
    {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        guard let afterIndex = sections.firstIndex(where: { afterSection == $0 }) else { return }
        sections.insert(section, at: afterIndex + 1)
    }

    public func insert(section: AbstractCollectionSection, at index: Int) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        guard sections.indices.contains(index) else { return }
        sections.insert(section, at: index)
    }

    public func append(sections newSections: [AbstractCollectionSection]) {
        assertMainThread()
        sectionsLock.lock()
        defer { sectionsLock.unlock() }
        self.sections.append(contentsOf: newSections)
    }
}

//MARK:- UICollectionViewDataSource
extension CollectionDirector: UICollectionViewDataSource {
    open func numberOfSections(in collectionView: UICollectionView) -> Int {
        return sectionsCount
    }

    open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return self.section(for: section)?.numberOfItems() ?? 0
    }

    open func collectionView(_ collectionView: UICollectionView,
                             cellForItemAt indexPath: IndexPath) -> UICollectionViewCell
    {
        guard let section = section(for: indexPath.section),
              let item = section.item(for: indexPath.row) else {
            // Return an empty cell instead of crashing - this can happen during rapid updates
            assertionFailure("Failed to retrieve item for indexPath \(indexPath.description)")
            // Register a fallback cell class if needed
            let fallbackId = "_CollectionKit_FallbackCell"
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: fallbackId)
            return collectionView.dequeueReusableCell(withReuseIdentifier: fallbackId, for: indexPath)
        }
        if shouldUseAutomaticViewRegistration {
            viewsRegisterer?.registerCellIfNeeded(reuseIdentifier: item.reuseIdentifier, cellClass: item.cellType)
        }

        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: item.reuseIdentifier, for: indexPath)
        item.configure(cell)
        return cell
    }

    open func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        guard let section = self.section(for: indexPath.section) else {
            return dequeueFallbackSupplementaryView(collectionView: collectionView, ofKind: kind, for: indexPath)
        }

        if let item = section.supplementaryItems[kind] {
            if shouldUseAutomaticViewRegistration {
                viewsRegisterer?.registerSupplementaryViewIfNeeded(reuseIdentifier: item.reuseIdentifier, viewClass: item.viewType, kind: kind)
            }
            let supplementaryView = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: item.reuseIdentifier, for: indexPath)
            item.configure(supplementaryView)
            return supplementaryView
        }

        switch kind {
        case UICollectionView.elementKindSectionHeader:
            guard let header = section.headerItem else {
                return dequeueFallbackSupplementaryView(collectionView: collectionView, ofKind: kind, for: indexPath)
            }
            if shouldUseAutomaticViewRegistration {
                viewsRegisterer?.registerHeaderFooterViewIfNeeded(reuseIdentifier: header.reuseIdentifier, viewClass: header.viewType, kind: kind)
            }
            let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: header.reuseIdentifier, for: indexPath)
            header.configure(headerView)
            return headerView
        case UICollectionView.elementKindSectionFooter:
            guard let footer = section.footerItem else {
                return dequeueFallbackSupplementaryView(collectionView: collectionView, ofKind: kind, for: indexPath)
            }
            if shouldUseAutomaticViewRegistration {
                viewsRegisterer?.registerHeaderFooterViewIfNeeded(reuseIdentifier: footer.reuseIdentifier, viewClass: footer.viewType, kind: kind)
            }
            let footerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: footer.reuseIdentifier, for: indexPath)
            footer.configure(footerView)
            return footerView

        default:
            return dequeueFallbackSupplementaryView(collectionView: collectionView, ofKind: kind, for: indexPath)
        }
    }

    private func dequeueFallbackSupplementaryView(collectionView: UICollectionView, ofKind kind: String, for indexPath: IndexPath) -> UICollectionReusableView {
        viewsRegisterer?.registerFallbackSupplementaryViewIfNeeded(kind: kind)
        return collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: CollectionReusableViewsRegisterer.fallbackSupplementaryViewReuseIdentifier,
            for: indexPath
        )
    }
}

//MARK:- UICollectionViewDelegateFlowLayout
extension CollectionDirector : UICollectionViewDelegateFlowLayout {
    open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        section(for: indexPath.section)?.didSelectItem(at: indexPath)
    }

    open func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        section(for: indexPath.section)?.didDeselectItem(at: indexPath)
    }

    open func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        section(for: indexPath.section)?.willDisplayItem(at: indexPath, cell: cell)
    }

    open func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let section = section(for: indexPath.section),
              section.numberOfItems() > indexPath.row else { return }
        section.didEndDisplayingItem(at: indexPath, cell: cell)
    }

    open func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        section(for: indexPath.section)?.shouldHighlightItem(at: indexPath) ?? true
    }

    open func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        section(for: indexPath.section)?.didHighlightItem(at: indexPath)
    }

    open func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        section(for: indexPath.section)?.didUnhighlightItem(at: indexPath)
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard let section = self.section(for: indexPath.section) else {
            // Return a minimal size instead of crashing
            assertionFailure("Failed to retrieve section for indexPath \(indexPath.description)")
            return CGSize(width: 1, height: 1)
        }

        let adjustsWidth = section.itemAdjustsWidth(at: indexPath.item)
        let adjustsHeight = section.itemAdjustsHeight(at: indexPath.item)

        let insets = collectionView.contentInset
        let boundingWidth = collectionView.bounds.width - insets.left - insets.right
        let boundingHeight = collectionView.bounds.height - insets.top - insets.bottom
        let boundingSize = CGSize(width: boundingWidth, height: boundingHeight)

        guard var size = section.sizeForItem(at: indexPath, boundingSize: boundingSize) else {
            // Return a minimal size instead of crashing
            assertionFailure("Failed to retrieve size for item at indexPath \(indexPath.description)")
            return CGSize(width: 1, height: 1)
        }

        let sectionInsets = section.insetForSection
        if adjustsWidth {
            let horizontalSectionInsets = sectionInsets.right + sectionInsets.left
            size.width = boundingWidth - horizontalSectionInsets
        }

        if adjustsHeight {
            let verticalSectionInsets = sectionInsets.top + sectionInsets.bottom
            size.height = boundingHeight - verticalSectionInsets
        }

        return size
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        return self.section(for: section)?.insetForSection ?? .zero
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        guard let section_ = self.section(for: section) else { return .zero }
        return section_.headerItem?.estimatedSize(boundingSize: collectionView.bounds.size) ?? .zero
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
        guard let section_ = self.section(for: section) else { return .zero }
        return section_.footerItem?.estimatedSize(boundingSize: collectionView.bounds.size) ?? .zero
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        return self.section(for: section)?.minimumInterItemSpacing ?? .leastNormalMagnitude
    }

    open func collectionView(_ collectionView: UICollectionView,
                             layout collectionViewLayout: UICollectionViewLayout,
                             minimumLineSpacingForSectionAt section: Int) -> CGFloat
    {
        return self.section(for: section)?.lineSpacing ?? 0
    }

    open func collectionView(_ collectionView: UICollectionView,
                             willDisplaySupplementaryView view: UICollectionReusableView,
                             forElementKind elementKind: String,
                             at indexPath: IndexPath)
    {
        guard let section = self.section(for: indexPath.section) else { return }
        if let supplementaryItem = section.supplementaryItems[elementKind] {
            supplementaryItem.onDisplay?()
        }
        switch elementKind {
        case UICollectionView.elementKindSectionHeader:
            section.headerItem?.onDisplay?()
        case UICollectionView.elementKindSectionFooter:
            section.footerItem?.onDisplay?()
        default:
            break
        }

        guard shouldAdjustSupplementaryViewLayerZPosition, #available(iOS 11.0, *) else { return }
        view.layer.zPosition = 0
    }

    open func collectionView(_ collectionView: UICollectionView,
                             didEndDisplayingSupplementaryView view: UICollectionReusableView,
                             forElementOfKind elementKind: String,
                             at indexPath: IndexPath)
    {
        guard let section = self.section(for: indexPath.section) else { return }
        if let supplementaryItem = section.supplementaryItems[elementKind] {
            supplementaryItem.onEndDisplay?()
        }
        switch elementKind {
        case UICollectionView.elementKindSectionHeader:
            section.headerItem?.onEndDisplay?()
        case UICollectionView.elementKindSectionFooter:
            section.footerItem?.onEndDisplay?()
        default:
            break
        }
    }
}

//MARK:- UIScrollViewDelegate
extension CollectionDirector : UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.scrollDelegate?.scrollViewDidScroll?(scrollView)
    }
}

//MARK:- Responder chain
extension CollectionDirector {
    open override func responds(to selector: Selector) -> Bool {
        return super.responds(to: selector) || scrollDelegate?.responds(to: selector) == true
    }
    
    open override func forwardingTarget(for selector: Selector) -> Any? {
        return scrollDelegate?.responds(to: selector) == true ? scrollDelegate : super.forwardingTarget(for: selector)
    }
}
