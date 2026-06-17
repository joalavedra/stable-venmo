import Foundation

/// Chain + token constants and minimal ERC-20 calldata encoding for USDC on Base Sepolia.
enum EVM {
    static let chainId = 84532                                  // Base Sepolia
    static let chainHex = "0x14a34"
    static let rpcURL = URL(string: "https://sepolia.base.org")!

    /// Circle USDC on Base Sepolia (6 decimals).
    static let usdc = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
    static let usdcDecimals = 6

    // MARK: - ABI encoding (manual)

    /// `balanceOf(address)` calldata: selector `0x70a08231` + 32-byte left-padded address.
    static func balanceOfCalldata(_ owner: String) -> String {
        "0x70a08231" + pad32(address: owner)
    }

    /// `transfer(address,uint256)` calldata: selector `0xa9059cbb` + padded args.
    static func transferCalldata(to: String, amountBaseUnits: UInt64) -> String {
        "0xa9059cbb" + pad32(address: to) + pad32(uint: amountBaseUnits)
    }

    /// USDC display amount (e.g. 5.25) -> base units (5_250_000).
    static func toBaseUnits(_ amount: Decimal) -> UInt64 {
        let scaled = amount * pow(10, usdcDecimals)
        return NSDecimalNumber(decimal: scaled).uint64Value
    }

    /// 32-byte hex of a `balanceOf` result -> human USDC amount.
    static func usdcFromHex(_ hex: String) -> Decimal {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let raw = UInt64(clean.suffix(16), radix: 16) else { return 0 }
        return Decimal(raw) / pow(10, usdcDecimals)
    }

    private static func pad32(address: String) -> String {
        let clean = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        return String(repeating: "0", count: 64 - clean.count) + clean.lowercased()
    }

    private static func pad32(uint value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 64 - hex.count) + hex
    }
}

/// A chain the embedded wallet can switch to, for validating `wallet_switchEthereumChain`.
struct Chain: Identifiable, Equatable, Sendable {
    let id: Int        // EIP-155 chain id
    let name: String
    let hex: String    // chain id as a 0x-prefixed hex string

    static let baseSepolia = Chain(id: 84532, name: "Base Sepolia", hex: "0x14a34")
    static let polygonAmoy = Chain(id: 80002, name: "Polygon Amoy", hex: "0x13882")
    static let supported: [Chain] = [.baseSepolia, .polygonAmoy]

    static func named(_ id: Int?) -> Chain? {
        guard let id else { return nil }
        return supported.first { $0.id == id }
    }
}

/// Minimal JSON-RPC read path for `eth_call balanceOf`. Balance reads don't need the wallet,
/// so a plain RPC call against the public endpoint is simpler than going through the provider.
enum RPC {
    struct CallError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func usdcBalance(of address: String) async throws -> Decimal {
        let params: [Any] = [
            ["to": EVM.usdc, "data": EVM.balanceOfCalldata(address)],
            "latest",
        ]
        let hex = try await call(method: "eth_call", params: params)
        return EVM.usdcFromHex(hex)
    }

    /// A smart account is counterfactual until its first transaction deploys it; afterwards
    /// `eth_getCode` returns its contract bytecode rather than empty (`0x`).
    static func isContractDeployed(_ address: String) async throws -> Bool {
        let code = try await call(method: "eth_getCode", params: [address, "latest"])
        return code != "0x" && !code.isEmpty
    }

    // keccak256("Transfer(address,address,uint256)")
    private static let transferTopic =
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

    /// Recent USDC transfers (sent + received) for `address` via `eth_getLogs`, scanned in
    /// 2000-block chunks (the public RPC's hard `eth_getLogs` range limit) over a recent window.
    static func usdcTransfers(of address: String) async throws -> [USDCTransfer] {
        let latest = try await blockNumber()
        let owner = address.lowercased()
        let topic = topicAddress(address)
        let chunk = 2_000   // public Base Sepolia RPC caps eth_getLogs at 2000 blocks
        let chunks = 12     // ~24k blocks (~13h)

        var result: [USDCTransfer] = []
        var toBlock = latest
        for _ in 0..<chunks {
            let fromBlock = max(0, toBlock - chunk)
            let fromHex = "0x" + String(fromBlock, radix: 16)
            let toHex = "0x" + String(toBlock, radix: 16)
            async let sent = transfersIn(topics: [transferTopic, topic], from: fromHex, to: toHex, owner: owner)
            async let received = transfersIn(topics: [transferTopic, nil, topic], from: fromHex, to: toHex, owner: owner)
            result += (await sent) + (await received)
            if fromBlock == 0 { break }
            toBlock = fromBlock - 1
        }

        var seen = Set<String>()
        return result
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.blockNumber > $1.blockNumber }
    }

    private static func transfersIn(
        topics: [String?], from: String, to: String, owner: String
    ) async -> [USDCTransfer] {
        let logs = (try? await getLogs(topics: topics, from: from, to: to)) ?? []
        return logs.compactMap { USDCTransfer(log: $0, owner: owner) }
    }

    private static func blockNumber() async throws -> Int {
        let hex = try await call(method: "eth_blockNumber", params: [])
        return Int(hex.dropFirst(2), radix: 16) ?? 0
    }

    private static func getLogs(topics: [String?], from: String, to: String) async throws -> [[String: Any]] {
        let jsTopics: [Any] = topics.map { $0 as Any? ?? NSNull() }
        let filter: [String: Any] = [
            "address": EVM.usdc,
            "fromBlock": from,
            "toBlock": to,
            "topics": jsTopics,
        ]
        let result = try await rawResult(method: "eth_getLogs", params: [filter])
        return result as? [[String: Any]] ?? []
    }

    private static func rawResult(method: String, params: [Any]) async throws -> Any? {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        var request = URLRequest(url: EVM.rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = json?["error"] as? [String: Any] {
            throw CallError(message: (error["message"] as? String) ?? "RPC error")
        }
        return json?["result"]
    }

    private static func topicAddress(_ address: String) -> String {
        let clean = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        return "0x" + String(repeating: "0", count: 64 - clean.count) + clean.lowercased()
    }

    private static func call(method: String, params: [Any]) async throws -> String {
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ]
        var request = URLRequest(url: EVM.rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let result = json?["result"] as? String { return result }
        let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "eth_call failed"
        throw CallError(message: message)
    }
}

/// A single USDC transfer parsed from a `Transfer` event log.
struct USDCTransfer: Identifiable, Sendable {
    let id: String
    let hash: String
    let counterparty: String
    let amount: Decimal
    let isOutgoing: Bool
    let blockNumber: Int

    init?(log: [String: Any], owner: String) {
        guard let topics = log["topics"] as? [String], topics.count >= 3,
              let data = log["data"] as? String,
              let hash = log["transactionHash"] as? String,
              let blockHex = log["blockNumber"] as? String else { return nil }
        let from = "0x" + topics[1].suffix(40).lowercased()
        let to = "0x" + topics[2].suffix(40).lowercased()
        let outgoing = from == owner
        self.hash = hash
        self.isOutgoing = outgoing
        self.counterparty = outgoing ? to : from
        self.amount = EVM.usdcFromHex(data)
        self.blockNumber = Int(blockHex.dropFirst(2), radix: 16) ?? 0
        self.id = hash + "-" + ((log["logIndex"] as? String) ?? "0")
    }
}
