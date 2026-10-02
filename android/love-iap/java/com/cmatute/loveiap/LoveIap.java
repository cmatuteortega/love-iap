package com.cmatute.loveiap;

import android.app.Activity;

import com.android.billingclient.api.AcknowledgePurchaseParams;
import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingClientStateListener;
import com.android.billingclient.api.BillingFlowParams;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.ConsumeParams;
import com.android.billingclient.api.PendingPurchasesParams;
import com.android.billingclient.api.ProductDetails;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.QueryProductDetailsParams;
import com.android.billingclient.api.QueryProductDetailsResult;
import com.android.billingclient.api.QueryPurchasesParams;
import com.android.billingclient.api.UnfetchedProduct;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;

/**
 * The Google Play half of love-iap.
 *
 * Called from liap.cpp (and so from Lua, through LuaJIT's FFI) on LÖVE's game
 * thread; Play Billing answers on the UI thread. The two never share anything
 * but a queue: every result becomes one tab-separated line in {@link #events},
 * and Lua drains it once a frame through {@link #poll}. Nothing here ever calls
 * back into native code, so there is no lifetime or threading contract with
 * Lua beyond "strings go in, strings come out".
 *
 * The event lines are the protocol shared with ios/LoveIap.swift, and iap.lua
 * is the only reader -- see the "Native protocol" section of the README.
 */
public final class LoveIap {
    private static final ConcurrentLinkedQueue<String> events = new ConcurrentLinkedQueue<>();
    private static final ConcurrentHashMap<String, ProductDetails> products = new ConcurrentHashMap<>();

    private static volatile BillingClient client;
    // The product whose purchase flow is open. Play reports a failed or
    // cancelled flow without naming the product, so it is remembered here.
    private static volatile String buying;
    private static volatile List<String> ids = Collections.emptyList();

    private LoveIap() {}

    // --- Called from native ------------------------------------------------

    public static void start(final Activity activity, String csv) {
        if (client != null) return;
        ids = split(csv);

        client = BillingClient.newBuilder(activity.getApplicationContext())
            .setListener(LoveIap::onPurchasesUpdated)
            .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
            .enableAutoServiceReconnection()
            .build();

        client.startConnection(new BillingClientStateListener() {
            @Override
            public void onBillingSetupFinished(BillingResult result) {
                if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
                    emit("unavailable", reason(result));
                    return;
                }
                emit("ready");
                queryProducts();
                sync();
            }

            @Override
            public void onBillingServiceDisconnected() {
                // enableAutoServiceReconnection() reconnects on the next call.
            }
        });
    }

    public static void buy(final Activity activity, final String id) {
        final BillingClient c = client;
        if (c == null || !c.isReady()) {
            emit("failed", id, "not_ready");
            return;
        }
        final ProductDetails details = products.get(id);
        if (details == null) {
            emit("failed", id, "unknown_product");
            return;
        }

        buying = id;
        activity.runOnUiThread(() -> {
            BillingFlowParams.ProductDetailsParams.Builder product =
                BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(details);
            ProductDetails.OneTimePurchaseOfferDetails offer = details.getOneTimePurchaseOfferDetails();
            if (offer != null && offer.getOfferToken() != null) product.setOfferToken(offer.getOfferToken());

            BillingFlowParams flow = BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(Collections.singletonList(product.build()))
                .build();

            BillingResult result = c.launchBillingFlow(activity, flow);
            if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
                buying = null;
                emit("failed", id, reason(result));
            }
        });
    }

    /**
     * Called by Lua once the game has granted what a purchase bought. Until
     * then the purchase stays unfinished and Play hands it back on every
     * sync, which is what makes a crash between "paid" and "granted" safe.
     * Unacknowledged purchases are refunded by Play after three days.
     */
    public static void finish(final String token, boolean consume) {
        final BillingClient c = client;
        if (c == null) {
            emit("finished", token, "not_ready");
            return;
        }
        if (consume) {
            c.consumeAsync(ConsumeParams.newBuilder().setPurchaseToken(token).build(),
                (result, t) -> emit("finished", token, reason(result)));
        } else {
            c.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(token).build(),
                result -> emit("finished", token, reason(result)));
        }
    }

    /** Play has no separate restore: asking for current purchases is it. */
    public static void restore() {
        if (client == null) return;
        sync();
    }

    public static String poll() {
        return events.poll();
    }

    // --- Play callbacks ----------------------------------------------------

    private static void onPurchasesUpdated(BillingResult result, List<Purchase> purchases) {
        String id = buying;
        buying = null;

        int code = result.getResponseCode();
        if (code == BillingClient.BillingResponseCode.OK) {
            if (purchases != null) for (Purchase p : purchases) emitPurchase(p);
            return;
        }
        emit("failed", id == null ? "" : id, reason(result));
        // Owned already: the purchase exists, the game just has not heard of
        // it (another device, a reinstall). A sync delivers it.
        if (code == BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED) sync();
    }

    private static void queryProducts() {
        List<String> want = ids;
        if (want.isEmpty()) return;

        List<QueryProductDetailsParams.Product> list = new ArrayList<>();
        for (String id : want) {
            list.add(QueryProductDetailsParams.Product.newBuilder()
                .setProductId(id)
                .setProductType(BillingClient.ProductType.INAPP)
                .build());
        }

        client.queryProductDetailsAsync(
            QueryProductDetailsParams.newBuilder().setProductList(list).build(),
            (BillingResult result, QueryProductDetailsResult found) -> {
                if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
                    emit("error", "products", reason(result));
                    return;
                }
                for (ProductDetails d : found.getProductDetailsList()) {
                    products.put(d.getProductId(), d);
                    ProductDetails.OneTimePurchaseOfferDetails offer = d.getOneTimePurchaseOfferDetails();
                    emit("product", d.getProductId(),
                        offer == null ? "" : offer.getFormattedPrice(),
                        d.getName(),
                        d.getDescription(),
                        offer == null ? "" : offer.getPriceCurrencyCode(),
                        offer == null ? "0" : Long.toString(offer.getPriceAmountMicros()));
                }
                for (UnfetchedProduct u : found.getUnfetchedProductList()) emit("missing", u.getProductId());
            });
    }

    // Everything the account owns or has pending, bracketed so Lua can tell a
    // complete answer (and so revoke what is no longer in it) from a partial one.
    private static void sync() {
        client.queryPurchasesAsync(
            QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build(),
            (result, purchases) -> {
                if (result.getResponseCode() != BillingClient.BillingResponseCode.OK) {
                    emit("error", "sync", reason(result));
                    return;
                }
                emit("syncing");
                for (Purchase p : purchases) emitPurchase(p);
                emit("synced");
            });
    }

    private static void emitPurchase(Purchase p) {
        String state;
        switch (p.getPurchaseState()) {
            case Purchase.PurchaseState.PURCHASED: state = "purchased"; break;
            case Purchase.PurchaseState.PENDING: state = "pending"; break;
            default: return;
        }
        String order = p.getOrderId();
        for (String id : p.getProducts()) {
            emit("purchase", id, p.getPurchaseToken(), state,
                p.isAcknowledged() ? "1" : "0",
                Integer.toString(p.getQuantity()),
                order == null ? "" : order);
        }
    }

    // --- Helpers -----------------------------------------------------------

    // The reason vocabulary is shared with iOS; iap.lua passes it through.
    private static String reason(BillingResult result) {
        switch (result.getResponseCode()) {
            case BillingClient.BillingResponseCode.OK: return "ok";
            case BillingClient.BillingResponseCode.USER_CANCELED: return "cancelled";
            case BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED: return "owned";
            case BillingClient.BillingResponseCode.ITEM_NOT_OWNED: return "not_owned";
            case BillingClient.BillingResponseCode.ITEM_UNAVAILABLE: return "unknown_product";
            case BillingClient.BillingResponseCode.NETWORK_ERROR:
            case BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE:
            case BillingClient.BillingResponseCode.SERVICE_DISCONNECTED: return "network";
            case BillingClient.BillingResponseCode.BILLING_UNAVAILABLE:
            case BillingClient.BillingResponseCode.FEATURE_NOT_SUPPORTED: return "unavailable";
            case BillingClient.BillingResponseCode.DEVELOPER_ERROR: return "developer_error";
            default: return "error";
        }
    }

    private static List<String> split(String csv) {
        List<String> out = new ArrayList<>();
        if (csv == null) return out;
        for (String s : csv.split(",")) {
            s = s.trim();
            if (!s.isEmpty()) out.add(s);
        }
        return out;
    }

    private static void emit(String... fields) {
        StringBuilder line = new StringBuilder();
        for (int i = 0; i < fields.length; i++) {
            if (i > 0) line.append('\t');
            String f = fields[i];
            if (f != null) line.append(f.replace('\t', ' ').replace('\n', ' ').replace('\r', ' '));
        }
        events.add(line.toString());
    }
}
