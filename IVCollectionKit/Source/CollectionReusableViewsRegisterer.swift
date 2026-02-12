//
//  CollectionReusableViewsRegisterer.swift
//  CollectionKit
//
//  Created by Igor Vedeneev on 06.02.18.
//  Copyright © 2018 Igor Vedeneev. All rights reserved.
//

import UIKit


/// Class responsible for registering classes and xibs in `UICollectionView`
final class CollectionReusableViewsRegisterer {
    static let fallbackSupplementaryViewReuseIdentifier = "_CollectionKit_FallbackSupplementaryView"

    weak var collectionView: UICollectionView?
    private var cellReuseIdentifiers: Set<String> = []
    private var headersReuseIdentifiers: Set<String> = []
    private var footersReuseIdentifiers: Set<String> = []
    private var supplementaryReuseIdentifiers: Set<String> = []
    private var fallbackSupplementaryViewKinds: Set<String> = []

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
    }

    func registerFallbackSupplementaryViewIfNeeded(kind: String) {
        guard !fallbackSupplementaryViewKinds.contains(kind) else { return }
        fallbackSupplementaryViewKinds.insert(kind)
        collectionView?.register(
            UICollectionReusableView.self,
            forSupplementaryViewOfKind: kind,
            withReuseIdentifier: Self.fallbackSupplementaryViewReuseIdentifier
        )
    }
    
    func registerCellIfNeeded(reuseIdentifier: String, cellClass: AnyClass) {
        guard !cellReuseIdentifiers.contains(reuseIdentifier) else { return }
        cellReuseIdentifiers.insert(reuseIdentifier)
        let bundle = Bundle(for: cellClass)
        if let _ = bundle.path(forResource: reuseIdentifier, ofType: "nib") {
            collectionView?.register(UINib(nibName: reuseIdentifier, bundle: bundle), forCellWithReuseIdentifier: reuseIdentifier)
        } else {
            collectionView?.register(cellClass, forCellWithReuseIdentifier: reuseIdentifier)
        }
    }
    
    func registerHeaderFooterViewIfNeeded(reuseIdentifier: String, viewClass: AnyClass, kind: String) {
        if kind == UICollectionView.elementKindSectionHeader && !headersReuseIdentifiers.contains(reuseIdentifier) {
            headersReuseIdentifiers.insert(reuseIdentifier)
        } else if kind == UICollectionView.elementKindSectionFooter && !footersReuseIdentifiers.contains(reuseIdentifier) {
            footersReuseIdentifiers.insert(reuseIdentifier)
        }

        let bundle = Bundle(for: viewClass)
        if let _ = bundle.path(forResource: reuseIdentifier, ofType: "nib") {
            collectionView?.register(UINib(nibName: reuseIdentifier, bundle: bundle), forSupplementaryViewOfKind: kind, withReuseIdentifier: reuseIdentifier)
        } else {
            collectionView?.register(viewClass, forSupplementaryViewOfKind: kind, withReuseIdentifier: reuseIdentifier)
        }
    }
    
    func registerSupplementaryViewIfNeeded(reuseIdentifier: String, viewClass: AnyClass, kind: String) {
        if !supplementaryReuseIdentifiers.contains(reuseIdentifier) {
            supplementaryReuseIdentifiers.insert(reuseIdentifier)
        }

        let bundle = Bundle(for: viewClass)
        if let _ = bundle.path(forResource: reuseIdentifier, ofType: "nib") {
            collectionView?.register(UINib(nibName: reuseIdentifier, bundle: bundle), forSupplementaryViewOfKind: kind, withReuseIdentifier: reuseIdentifier)
        } else {
            collectionView?.register(viewClass, forSupplementaryViewOfKind: kind, withReuseIdentifier: reuseIdentifier)
        }
    }
}
