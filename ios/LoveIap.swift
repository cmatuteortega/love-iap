// The App Store half of love-iap: the same six C functions as
// android/love-iap/liap.cpp, exported from Swift with @_cdecl and found by
// iap.lua through ffi.C. Add this one file to the LÖVE Xcode project (iOS or
// macOS target); see the README for the three build settings it needs.
//
// StoreKit 2 rather than the original StoreKit: it is the one Apple maintains,
// it verifies transactions on the device, and it can list what the account
// owns (Transaction.currentEntitlements) without the password prompt a
// "restore" costs -- so iOS gets the same quiet sync at launch Android has.
// It needs iOS 15 / macOS 12; on anything older liap_start returns 0 and the
// game sees "unavailable".
//
// Threading: LÖVE runs Lua on the main thread on iOS, and the store is a
// @MainActor singleton, so StoreKit's async answers are picked up between
// frames when SDL pumps the main run loop. They only ever reach Lua as lines
// on `liapEvents`, which iap.lua drains with liap_poll.

import Foundation
import StoreKit

// MARK: - Event queue

final class LiapEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    // The C string last handed to Lua; valid until the next liap_poll, and
    // iap.lua copies it with ffi.string before then.
    private var current: UnsafeMutablePointer<CChar>?
    private var error: UnsafeMutablePointer<CChar>? = strdup("")

    func push(_ fields: String...) {
        let line = fields
            .map { $0.replacingOccurrences(of: "\t", with: " ")
                     .replacingOccurrences(of: "\n", with: " ")
                     .replacingOccurrences(of: "\r", with: " ") }
            .joined(separator: "\t")
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func pop() -> UnsafePointer<CChar>? {
        lock.lock()
        defer { lock.unlock() }
        free(current)
        current = nil
        if lines.isEmpty { return nil }
        current = strdup(lines.removeFirst())
        return UnsafePointer(current)
    }

    func setError(_ text: String) {
        lock.lock()
        free(error)
        error = strdup(text)
        lock.unlock()
    }

    func errorText() -> UnsafePointer<CChar>? {
        lock.lock()
        defer { lock.unlock() }
        return UnsafePointer(error)
    }
}

let liapEvents = LiapEvents()

// MARK: - Store

@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
@MainActor
final class LiapStore {
    static let shared = LiapStore()

    private var products: [String: Product] = [:]
    // Verified, delivered to Lua, not yet finished -- keyed by the token Lua
    // gets (the transaction id), so liap_finish can find it again.
    private var unfinished: [String: Transaction] = [:]
    private var listener: Task<Void, Never>?

    func start(_ ids: [String]) {
        if listener != nil { return }

        // Purchases that complete outside a buy() call: Ask to Buy approved,
        // a pending payment cleared, a purchase made on another device, a
        // refund. Apple asks for this to be listening from launch.
        listener = Task {
            for await update in Transaction.updates {
                self.handle(update)
            }
        }

        liapEvents.push("ready")
        Task {
            await self.loadProducts(ids)
            await self.sync()
        }
    }

    func buy(_ id: String) async {
        guard let product = products[id] else {
            liapEvents.push("failed", id, "unknown_product")
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let result):
                handle(result)
            case .userCancelled:
                liapEvents.push("failed", id, "cancelled")
            case .pending:
                liapEvents.push("purchase", id, "", "pending", "0", "1", "")
            @unknown default:
                liapEvents.push("failed", id, "error")
            }
        } catch {
            liapEvents.push("failed", id, reason(error))
        }
    }

    func finish(_ token: String) async {
        if let transaction = unfinished.removeValue(forKey: token) {
            await transaction.finish()
        }
        liapEvents.push("finished", token, "ok")
    }

    // AppStore.sync() is the "Restore purchases" button: it signs in to the
    // App Store if needed (which may ask for a password), so it is only ever
    // run when the player asks. The quiet sync after it is what reports.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            liapEvents.push("error", "restore", reason(error))
        }
        await sync()
    }

    private func loadProducts(_ ids: [String]) async {
        if ids.isEmpty { return }
        do {
            let found = try await Product.products(for: ids)
            for product in found {
                products[product.id] = product
                let micros = NSDecimalNumber(decimal: product.price * 1_000_000).int64Value
                liapEvents.push("product", product.id, product.displayPrice, product.displayName,
                                product.description, product.priceFormatStyle.currencyCode, String(micros))
            }
            for id in ids where products[id] == nil {
                liapEvents.push("missing", id)
            }
        } catch {
            liapEvents.push("error", "products", reason(error))
        }
    }

    // Everything owned, bracketed by syncing/synced so iap.lua can treat the
    // list as complete and revoke what is missing from it. Unfinished
    // transactions (a consumable paid for but never granted, say) come first
    // so they are delivered again.
    private func sync() async {
        liapEvents.push("syncing")
        for await result in Transaction.unfinished {
            handle(result)
        }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            let token = String(transaction.id)
            if unfinished[token] != nil { continue }  // already reported above
            liapEvents.push("purchase", transaction.productID, token, "purchased", "1",
                            String(transaction.purchasedQuantity), String(transaction.originalID))
        }
        liapEvents.push("synced")
    }

    private func handle(_ result: VerificationResult<Transaction>) {
        guard case .verified(let transaction) = result else {
            // The signature did not check out: never grant it. It stays
            // unfinished, so StoreKit offers it again later.
            if case .unverified(let transaction, _) = result {
                liapEvents.push("failed", transaction.productID, "unverified")
            }
            return
        }

        if transaction.revocationDate != nil {
            liapEvents.push("revoked", transaction.productID)
            Task { await transaction.finish() }
            return
        }

        let token = String(transaction.id)
        unfinished[token] = transaction
        liapEvents.push("purchase", transaction.productID, token, "purchased", "0",
                        String(transaction.purchasedQuantity), String(transaction.originalID))
    }

    // The reason vocabulary shared with LoveIap.java.
    private func reason(_ error: Error) -> String {
        if let error = error as? StoreKitError {
            switch error {
            case .userCancelled: return "cancelled"
            case .networkError: return "network"
            case .notAvailableInStorefront: return "unavailable"
            default: return "error"
            }
        }
        if let error = error as? Product.PurchaseError {
            switch error {
            case .productUnavailable: return "unknown_product"
            case .purchaseNotAllowed: return "unavailable"
            default: return "error"
            }
        }
        return "error"
    }
}

// MARK: - C interface (see iap.lua's CDEF)

@_cdecl("liap_start")
public func liap_start(_ ids: UnsafePointer<CChar>?) -> Int32 {
    guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) else {
        liapEvents.setError("StoreKit 2 needs iOS 15 or macOS 12")
        return 0
    }
    let csv = ids.map { String(cString: $0) } ?? ""
    let list = csv.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    Task { @MainActor in LiapStore.shared.start(list) }
    return 1
}

@_cdecl("liap_buy")
public func liap_buy(_ id: UnsafePointer<CChar>?) {
    guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, *), let id = id else { return }
    let product = String(cString: id)
    Task { @MainActor in await LiapStore.shared.buy(product) }
}

@_cdecl("liap_finish")
public func liap_finish(_ token: UnsafePointer<CChar>?, _ consume: Int32) {
    // StoreKit has one "finish" for both kinds; whether an item is consumable
    // is configured in App Store Connect, not here.
    guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, *), let token = token else { return }
    let key = String(cString: token)
    Task { @MainActor in await LiapStore.shared.finish(key) }
}

@_cdecl("liap_restore")
public func liap_restore() {
    guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) else { return }
    Task { @MainActor in await LiapStore.shared.restore() }
}

@_cdecl("liap_poll")
public func liap_poll() -> UnsafePointer<CChar>? {
    return liapEvents.pop()
}

@_cdecl("liap_error")
public func liap_error() -> UnsafePointer<CChar>? {
    return liapEvents.errorText()
}
