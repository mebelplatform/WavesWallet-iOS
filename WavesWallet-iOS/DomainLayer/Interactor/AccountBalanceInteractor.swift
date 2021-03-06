//
//  AccountBalanceInteractor.swift
//  WavesWallet-iOS
//
//  Created by mefilt on 10.07.2018.
//  Copyright © 2018 Waves Platform. All rights reserved.
//

import Foundation
import Moya
import RealmSwift
import RxSwift
import RxSwiftExt

protocol AccountBalanceInteractorProtocol {
    func balances(by accountId: String) -> Observable<[AssetBalance]>
    func update(balance: AssetBalance) -> Observable<Void>
}

final class AccountBalanceInteractor: AccountBalanceInteractorProtocol {
    private let assetsInteractor: AssetsInteractorProtocol = AssetsInteractor()
    private let assetsProvider: MoyaProvider<Node.Service.Assets> = .init()
    private let addressesProvider: MoyaProvider<Node.Service.Addresses> = .init()
    private let matcherBalanceProvider: MoyaProvider<Matcher.Service.Balance> = .init(plugins: [NetworkLoggerPlugin(verbose: false)])
    private let leasingInteractor: LeasingInteractorProtocol = LeasingInteractor()
    private let realm = try! Realm()

    func balances(by accountAddress: String) -> Observable<[AssetBalance]> {
        let assetsBalance = self.assetsBalance(by: accountAddress)
        let accountBalance = self.accountBalance(by: accountAddress)
        let leasingTransactions = leasingInteractor.activeLeasingTransactions(by: accountAddress)
        let matcherBalances = self.matcherBalances(by: accountAddress)

        let list = Observable
            .zip(assetsBalance, accountBalance, leasingTransactions, matcherBalances)
            .map { AssetBalance.mapToAssetBalances(from: $0.0,
                                                   account: $0.1,
                                                   leasingTransactions: $0.2,
                                                   matcherBalances: $0.3) }
            .map { balances -> [AssetBalance] in

                let generalBalances = Environments.current.generalAssetIds.map { AssetBalance(model: $0) }
                var newList = balances
                for generalBalance in generalBalances {
                    if balances.contains(where: { $0.assetId == generalBalance.assetId }) == false {
                        newList.append(generalBalance)
                    }
                }
                return newList
            }
            .flatMap(weak: self, selector: { weak, balances -> Observable<[AssetBalance]> in
                let ids = balances.map { $0.assetId }

                return weak.assetsInteractor
                    .assetsBy(ids: ids, accountAddress: accountAddress)
                    .map { (assets) -> [AssetBalance] in
                        balances.forEach { $0.setAssetFrom(list: assets) }
                        return balances
                    }
            })
            .do(weak: self, onNext: { weak, balances in
                let ids = balances.map { $0.assetId }

                try? weak.realm.write {
                    let removeBalances = weak.realm
                        .objects(AssetBalance.self)
                        .filter(NSPredicate(format: "NOT (assetId IN %@)", ids))

                    let removeSettings = removeBalances
                        .toArray()
                        .map { $0.settings }
                        .compactMap { $0 }

                    weak.realm.delete(removeBalances)
                    weak.realm.delete(removeSettings)
                    weak.sort(balances: balances)
                    weak.realm.add(balances, update: true)
                }
            })

        return list
    }

    func update(balance: AssetBalance) -> Observable<Void> {
        try? self.realm.write {
            realm.add(balance, update: true)
        }

        return Observable.just(())
    }
}

fileprivate extension AssetBalance {
    class func mapToAssetBalances(from assets: Node.DTO.AccountAssetsBalance,
                                  account: Node.DTO.AccountBalance,
                                  leasingTransactions: [LeasingTransaction],
                                  matcherBalances: [String: Int64]) -> [AssetBalance] {
        let assetsBalance = assets.balances.map { AssetBalance(model: $0) }
        let accountBalance = AssetBalance(accountBalance: account,
                                          transactions: leasingTransactions)

        var list = [AssetBalance]()
        list.append(contentsOf: assetsBalance)
        list.append(accountBalance)

        list.forEach { asset in
            guard let balance = matcherBalances[asset.assetId] else { return }
            asset.reserveBalance = balance
        }
        
        return list
    }
}

fileprivate extension AccountBalanceInteractor {
    func matcherBalances(by accountAddress: String) -> Observable<[String: Int64]> {
        return WalletManager
            .getPrivateKey()
            .flatMap(weak: self, selector: { (owner, privateKey) -> Observable<[String: Int64]> in
                owner.matcherBalanceProvider
                    .rx
                    .request(.getReservedBalances(privateKey))                       
                    .map([String: Int64].self)
                    .asObservable()
                    .catchErrorJustReturn([String: Int64]())
            })
            .catchErrorJustReturn([String: Int64]())
    }

    func assetsBalance(by accountAddress: String) -> Observable<Node.DTO.AccountAssetsBalance> {
        return self.assetsProvider
            .rx
            .request(.getAssetsBalance(accountId: accountAddress))
            .map(Node.DTO.AccountAssetsBalance.self)
            .asObservable()
    }

    func accountBalance(by accountAddress: String) -> Observable<Node.DTO.AccountBalance> {
        return self.addressesProvider
            .rx
            .request(.getAccountBalance(id: accountAddress))
            .map(Node.DTO.AccountBalance.self)
            .asObservable()
    }
}

extension AccountBalanceInteractor {
    func sort(balances: [AssetBalance]) {

        let generalBalances = Environments
            .current
            .generalAssetIds

        let sort = balances.sorted { assetOne, assetTwo -> Bool in

            let isGeneralOne = assetOne.asset?.isGeneral ?? false
            let isGeneralTwo = assetTwo.asset?.isGeneral ?? false

            if isGeneralOne == true && isGeneralTwo == true {
                let indexOne = generalBalances
                    .enumerated()
                    .first(where: { $0.element.assetId == assetOne.assetId })
                    .map { $0.offset }

                let indexTwo = generalBalances
                    .enumerated()
                    .first(where: { $0.element.assetId == assetTwo.assetId })
                    .map { $0.offset }

                if let indexOne = indexOne, let indexTwo = indexTwo {
                    return indexOne < indexTwo
                }
                return false
            }

            if isGeneralOne {
                return true
            }

            return false
        }

        sort.enumerated().forEach { balance in
            
            let settings = AssetBalanceSettings()
            settings.assetId = balance.element.assetId
            settings.sortLevel = Float(balance.offset)

            if balance.element.assetId == Environments.Constants.wavesAssetId {
                settings.isFavorite = true
            }
            balance.element.settings = settings
        }
    }
}

fileprivate extension AssetBalance {
    fileprivate func setAssetFrom(list: [Asset]) {
        self.asset = list.first { $0.id == self.assetId }
    }
}

fileprivate extension AssetBalance {
    convenience init(model: Environment.AssetInfo) {
        self.init()
        self.assetId = model.assetId
    }

    convenience init(accountBalance: Node.DTO.AccountBalance, transactions: [LeasingTransaction]) {
        self.init()
        self.balance = accountBalance.balance
        self.leasedBalance = transactions
            .filter { $0.sender == accountBalance.address }
            .reduce(0) { $0 + $1.amount }
        self.assetId = Environments.Constants.wavesAssetId
    }

    convenience init(model: Node.DTO.AssetBalance) {
        self.init()
        self.assetId = model.assetId
        self.balance = model.balance
    }
}
