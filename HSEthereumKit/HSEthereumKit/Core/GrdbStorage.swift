import RxSwift
import GRDB
import RxGRDB

class GrdbStorage {
    private let dbPool: DatabasePool

    init(databaseFileName: String) {
        let databaseURL = try! FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("\(databaseFileName).sqlite")

        dbPool = try! DatabasePool(path: databaseURL.path)

        try? migrator.migrate(dbPool)
    }

    var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createTransactions") { db in
            try db.create(table: EthereumTransaction.databaseTableName) { t in
                t.column(EthereumTransaction.Columns.hash.name, .text).notNull()
                t.column(EthereumTransaction.Columns.nonce.name, .integer).notNull()
                t.column(EthereumTransaction.Columns.input.name, .text).notNull()
                t.column(EthereumTransaction.Columns.from.name, .text).notNull()
                t.column(EthereumTransaction.Columns.to.name, .text).notNull()
                t.column(EthereumTransaction.Columns.value.name, .text).notNull()
                t.column(EthereumTransaction.Columns.gasLimit.name, .integer).notNull()
                t.column(EthereumTransaction.Columns.gasPrice.name, .integer).notNull()
                t.column(EthereumTransaction.Columns.timestamp.name, .double).notNull()
                t.column(EthereumTransaction.Columns.contractAddress.name, .text)
                t.column(EthereumTransaction.Columns.blockHash.name, .text)
                t.column(EthereumTransaction.Columns.blockNumber.name, .integer)
                t.column(EthereumTransaction.Columns.confirmations.name, .integer)
                t.column(EthereumTransaction.Columns.gasUsed.name, .integer)
                t.column(EthereumTransaction.Columns.cumulativeGasUsed.name, .integer)
                t.column(EthereumTransaction.Columns.isError.name, .boolean)
                t.column(EthereumTransaction.Columns.transactionIndex.name, .integer)
                t.column(EthereumTransaction.Columns.txReceiptStatus.name, .boolean)

                t.primaryKey([EthereumTransaction.Columns.hash.name, EthereumTransaction.Columns.contractAddress.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createBalances") { db in
            try db.create(table: EthereumBalance.databaseTableName) { t in
                t.column(EthereumBalance.Columns.address.name, .text).notNull()
                t.column(EthereumBalance.Columns.value.name, .text).notNull()

                t.primaryKey([EthereumBalance.Columns.address.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createBlockchainStates") { db in
            try db.create(table: BlockchainState.databaseTableName) { t in
                t.column(BlockchainState.Columns.primaryKey.name, .text).notNull()
                t.column(BlockchainState.Columns.lastBlockHeight.name, .integer)
                t.column(BlockchainState.Columns.gasPrice.name, .text)

                t.primaryKey([BlockchainState.Columns.primaryKey.name], onConflict: .replace)
            }
        }

        return migrator
    }

}

extension GrdbStorage: IStorage {

    var lastBlockHeight: Int? {
        return try! dbPool.read { db in
            try BlockchainState.fetchOne(db)?.lastBlockHeight
        }
    }

    var gasPrice: Decimal? {
        return try! dbPool.read { db in
            try BlockchainState.fetchOne(db)?.gasPrice
        }
    }

    func balance(forAddress address: String) -> Decimal? {
        let request = EthereumBalance.filter(EthereumBalance.Columns.address == address)

        return try! dbPool.read { db in
            try request.fetchOne(db)?.value
        }
    }

    func transactionsSingle(fromHash: String?, limit: Int?, contractAddress: String?) -> Single<[EthereumTransaction]> {
        // todo: implement method and check for invalid transactions
        return Single.just([])
    }

    func save(lastBlockHeight: Int) {
        _ = try? dbPool.write { db in
            let state = try BlockchainState.fetchOne(db) ?? BlockchainState()
            state.lastBlockHeight = lastBlockHeight
            try state.insert(db)
        }
    }

    func save(gasPrice: Decimal) {
        _ = try? dbPool.write { db in
            let state = try BlockchainState.fetchOne(db) ?? BlockchainState()
            state.gasPrice = gasPrice
            try state.insert(db)
        }
    }

    func save(balance: Decimal, address: String) {
        _ = try? dbPool.write { db in
            let balanceObject = EthereumBalance(address: address, value: balance)
            try balanceObject.insert(db)
        }
    }

    func save(transactions: [EthereumTransaction]) {
        _ = try? dbPool.write { db in
            for transaction in transactions {
                try transaction.insert(db)
            }
        }
    }

    func clear() {
        _ = try? dbPool.write { db in
            try BlockchainState.deleteAll(db)
            try EthereumBalance.deleteAll(db)
            try EthereumTransaction.deleteAll(db)
        }
    }

    func lastTransactionBlockHeight(erc20: Bool) -> Int? {
        return try! dbPool.read { db in
            let predicate: SQLExpressible

            if erc20 {
                predicate = EthereumTransaction.Columns.contractAddress != nil
            } else {
                predicate = EthereumTransaction.Columns.contractAddress == nil
            }

            return try EthereumTransaction.filter(predicate).order(EthereumTransaction.Columns.blockNumber.desc).fetchOne(db)?.blockNumber
        }
    }

}
