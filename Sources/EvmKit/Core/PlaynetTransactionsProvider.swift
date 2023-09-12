import Foundation
import BigInt
import Alamofire
import HsToolKit

public struct JSONRPCResult<T: Decodable>: Decodable {
    public var id: Int
    public var jsonrpc: String
    public var result: T
}

public struct EthereumBlockInfo: Equatable {
    public static func == (lhs: EthereumBlockInfo, rhs: EthereumBlockInfo) -> Bool {
        lhs.number == rhs.number
    }
    
    public var number: EthereumBlock
    public var timestamp: String
    public var transactions: [EthereumTransaction]
}

public struct JSONRPCErrorResult: Decodable {
    public var id: Int
    public var jsonrpc: String
    public var error: JSONRPCErrorDetail
}

public struct JSONRPCErrorDetail: Decodable, Equatable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var data: String?

    public init(
        code: Int,
        message: String,
        data: String?
    ) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String {
        "Code: \(code)\nMessage: \(message)"
    }
}

public enum JSONRPCError: Error {
    case executionError(JSONRPCErrorResult)
    case requestRejected(Data)
    case encodingError
    case decodingError
    case unknownError
    case noResult
    // WebSocket
    case invalidConnection
    case connectionNotOpen
    case connectionTimeout
    case pendingRequestsOnReconnecting
    case maxAttemptsReachedOnReconnecting

    public var isExecutionError: Bool {
        switch self {
        case .executionError:
            return true
        default:
            return false
        }
    }
}

public enum EthereumBlock: Hashable {
    case Latest
    case Earliest
    case Pending
    case Number(Int)

    public var stringValue: String {
        switch self {
        case .Latest:
            return "latest"
        case .Earliest:
            return "earliest"
        case .Pending:
            return "pending"
        case let .Number(int):
            return int.toHexString
        }
    }

    public var intValue: Int? {
        switch self {
        case let .Number(int):
            return int
        default:
            return nil
        }
    }

    public init(rawValue: Int) {
        self = .Number(rawValue)
    }

    public init(rawValue: String) {
        if rawValue == "latest" {
            self = .Latest
        } else if rawValue == "earliest" {
            self = .Earliest
        } else if rawValue == "pending" {
            self = .Pending
        } else {
            self = .Number(Int(rawValue.noHexPrefix, radix: 16) ?? 0)
        }
    }
}

extension String {
    var noHexPrefix: String {
        if self.hasPrefix("0x") {
            let index = self.index(self.startIndex, offsetBy: 2)
            return String(self[index...])
        }
        return self
    }
}

extension EthereumBlock: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        let strValue = try value.decode(String.self)
        self = EthereumBlock(rawValue: strValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

extension EthereumBlock: Comparable {
    static public func == (lhs: EthereumBlock, rhs: EthereumBlock) -> Bool {
        lhs.stringValue == rhs.stringValue
    }

    static public func < (lhs: EthereumBlock, rhs: EthereumBlock) -> Bool {
        switch lhs {
        case .Earliest:
            return false
        case .Latest:
            return rhs != .Pending ? true : false
        case .Pending:
            return true
        case let .Number(lhsInt):
            switch rhs {
            case .Earliest:
                return false
            case .Latest:
                return true
            case .Pending:
                return true
            case let .Number(rhsInt):
                return lhsInt < rhsInt
            }
        }
    }
}

extension EthereumBlockInfo: Codable {
    enum CodingKeys: CodingKey {
        case number
        case timestamp
        case transactions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let number = try? container.decode(EthereumBlock.self, forKey: .number) else {
            throw JSONRPCError.decodingError
        }

        guard let timestamp = try? container.decode(String.self, forKey: .timestamp) else {
            throw JSONRPCError.decodingError
        }

        guard let transactions = try? container.decode([EthereumTransaction].self, forKey: .transactions) else {
            throw JSONRPCError.decodingError
        }

        self.number = number
        self.timestamp = timestamp
        self.transactions = transactions
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(number, forKey: .number)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(transactions, forKey: .transactions)
    }
}

extension Int {
    var toHexString: String {
        String(format: "%02X", self)
    }
}

public struct EthereumTransaction: Decodable, Encodable {
    let blockHash: String
    let blockNumber: String
    let from: String
    let gas: String
    let gasPrice: String
    let maxFeePerGas: String
    let maxPriorityFeePerGas: String
    let hash: String
    let input: String
    let nonce: String
    let to: String?
    let transactionIndex: String
    let value: String
    let type: String
    let accessList: [String]
    let chainId: String
}


class PlaynetTransactionProvider {
    private let networkManager: NetworkManager
    private let baseUrl: String
    private let address: Address

    init(baseUrl: String, address: Address, logger: Logger) {
        networkManager = NetworkManager(interRequestInterval: 1, logger: logger)
        self.baseUrl = baseUrl
        self.address = address
    }
    
    private func callRpcMethod(method: String, params: Any) async throws -> Data {
        guard let requestData = try? JSONSerialization.data(withJSONObject: params, options: []) else {
            throw RequestError.serializationError
        }

        guard let url = URL(string: baseUrl) else {
            throw RequestError.baseUrlError
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = requestData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
    
    private func fetchChainTip() async throws -> Int {
        let blockNumberRequestParams: [String : Any] = [
            "jsonrpc": "2.0",
            "method": "eth_blockNumber",
            "id": 1
        ]
        
        let data = try await callRpcMethod(method: "POST", params: blockNumberRequestParams)
        let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as! [String : Any]
        
        if let result = json["result"] as? String,
           let blockNumber = Int(result.dropFirst(2), radix: 16) {
            return blockNumber
        } else {
            print("Failed to parse response.")
            throw RequestError.invalidResult
        }
    }
    
    private func txs(blockHeight: Int) async throws -> [[String: Any]] {
        let hexBlockHeight = "0x" + String(format: "%x", blockHeight)
        let blockRequestParams: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "eth_getBlockByNumber",
            "params": [hexBlockHeight, true] as [Any], // Block height and includeTransactions
            "id": 1
        ]
        
        let data = try await callRpcMethod(method: "POST", params: blockRequestParams)
        
        if let fullBlock = try? JSONDecoder().decode(JSONRPCResult<EthereumBlockInfo>.self, from: data) {
            print("Received full block: \n \(fullBlock)")
            
            var transactions = [[String: Any]]()
                        
            for transaction in fullBlock.result.transactions {
                guard transaction.from == address.hex || transaction.to == address.hex else { continue }
                                                
                guard
                    let blockNumberInt = Int(transaction.blockNumber.noHexPrefix, radix: 16),
                    let timestampInt = Int(fullBlock.result.timestamp.noHexPrefix, radix: 16),
                    let gasInt = Int(transaction.gas.noHexPrefix, radix: 16),
                    let gasPriceInt = Int(transaction.gasPrice.noHexPrefix, radix: 16),
                    let nonceInt = Int(transaction.nonce.noHexPrefix, radix: 16),
                    let transactionIndexInt = Int(transaction.transactionIndex.noHexPrefix, radix: 16),
                    let valueBigInt = BigInt(transaction.value.noHexPrefix, radix: 16)
                else { continue }
                
                let dictionaryRepresentation: [String: Any] = [
                    "blockHash": transaction.blockHash,
                    "blockNumber": String(blockNumberInt),
                    "timeStamp": String(timestampInt),
                    "from": transaction.from,
                    "gas": String(gasInt),
                    "gasPrice": String(gasPriceInt),
                    "maxFeePerGas": transaction.maxFeePerGas,
                    "maxPriorityFeePerGas": transaction.maxPriorityFeePerGas,
                    "hash": transaction.hash,
                    "input": transaction.input,
                    "nonce": String(nonceInt),
                    "to": transaction.to ?? "",
                    "transactionIndex": String(transactionIndexInt),
                    "value": String(valueBigInt),
                    "type": transaction.type,
                    "accessList": transaction.accessList,
                    "chainId": transaction.chainId,
                ]
                
                transactions.append(dictionaryRepresentation)
            }
            
            return transactions
        } else {
            return []
        }
    }
}

extension PlaynetTransactionProvider: ITransactionProvider {
    func transactions(startBlock: Int) async throws -> [ProviderTransaction] {
        let chainTip = try await fetchChainTip()
        
        var userTxs = [[String: Any]]()
        
        if startBlock <= chainTip {
            for blockHeight in startBlock ... chainTip {
                let transactions = try await txs(blockHeight: blockHeight)
                userTxs.append(contentsOf: transactions)
            }
        }
        
        return userTxs.compactMap { try? ProviderTransaction(JSON: $0) }
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    

    func internalTransactions(startBlock: Int) async throws -> [ProviderInternalTransaction] {
//        let params: [String: Any] = [
//            "module": "account",
//            "action": "txlistinternal",
//            "address": address.hex,
//            "startblock": startBlock,
//            "sort": "desc"
//        ]
//
//        let array = try await fetch(params: params)
//        return array.compactMap { try? ProviderInternalTransaction(JSON: $0) }
        return []
    }

    func internalTransactions(transactionHash: Data) async throws -> [ProviderInternalTransaction] {
//        let params: [String: Any] = [
//            "module": "account",
//            "action": "txlistinternal",
//            "txhash": transactionHash.hs.hexString,
//            "sort": "desc"
//        ]
//
//        let array = try await fetch(params: params)
//        return array.compactMap { try? ProviderInternalTransaction(JSON: $0) }
        return []
    }

    func tokenTransactions(startBlock: Int) async throws -> [ProviderTokenTransaction] {
//        let params: [String: Any] = [
//            "module": "account",
//            "action": "tokentx",
//            "address": address.hex,
//            "startblock": startBlock,
//            "sort": "desc"
//        ]
//
//        let array = try await fetch(params: params)
//        return array.compactMap { try? ProviderTokenTransaction(JSON: $0) }
        return []
    }

    public func eip721Transactions(startBlock: Int) async throws -> [ProviderEip721Transaction] {
//        let params: [String: Any] = [
//            "module": "account",
//            "action": "tokennfttx",
//            "address": address.hex,
//            "startblock": startBlock,
//            "sort": "desc"
//        ]
//
//        let array = try await fetch(params: params)
//        return array.compactMap { try? ProviderEip721Transaction(JSON: $0) }
        return []
    }

    public func eip1155Transactions(startBlock: Int) async throws -> [ProviderEip1155Transaction] {
//        let params: [String: Any] = [
//            "module": "account",
//            "action": "token1155tx",
//            "address": address.hex,
//            "startblock": startBlock,
//            "sort": "desc"
//        ]
//
//        let array = try await fetch(params: params)
//        return array.compactMap { try? ProviderEip1155Transaction(JSON: $0) }
        return []
    }

}

extension PlaynetTransactionProvider {

    public enum RequestError: Error {
        case invalidResponse
        case invalidStatus
        case responseError(message: String?, result: String?)
        case invalidResult
        case rateLimitExceeded
        case baseUrlError
        case serializationError
    }

}
