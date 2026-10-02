# love-iap

In-app purchases for [LÖVE](https://love2d.org) games, on Google Play (Android)
and the App Store (iOS, macOS): one Lua file for the game, one small native
bridge per platform, and a GitHub Action that adds the Android bridge to a
[love-android](https://github.com/love2d/love-android) build.

```lua
local iap = require "iap"

function love.load()
    iap.init {
        products = {
            { id = "coins_100", consumable = true },
            { id = "full_game" },
        },
        onPurchase = function(id, purchase)
            -- grant it and save the game before returning
        end,
    }
end

function love.update(dt)
    iap.update()
end

-- iap.buy("full_game")   iap.owns("full_game")   iap.price("coins_100")
```

On desktop (or any build without the bridge) every call is a harmless no-op,
so the same game code runs everywhere. With `mock = true` you get a fake store
on desktop instead, so purchase flows can be clicked through without a phone.

| | Status |
|---|---|
| `iap.lua` | Tested (`test/run.lua`, a fake native store, run in CI) |
| Android bridge | Compiled against Play Billing 9.1.0 in CI, and built into a real love-android APK in CI. No real purchase has been made with it yet: that needs an app on a Play Console testing track. |
| iOS / macOS bridge | Written against StoreKit 2. **Not compiled yet**: there's no macOS CI job, so expect to fix small things the first time it goes into Xcode. |

Only one-time products (consumable and non-consumable) are supported.
Subscriptions are not.

## How it fits together

```
your game ── iap.lua ── LuaJIT FFI ──► liap_start / liap_buy / liap_finish /
                                       liap_restore / liap_poll / liap_error
                                         ├─ Android: libliap.so (liap.cpp) ─JNI─► LoveIap.java ─► Play Billing
                                         └─ iOS/macOS: LoveIap.swift (@_cdecl) ─► StoreKit 2
```

- **Six C functions are the whole interface.** Both bridges export the same
  ones, so `iap.lua` doesn't care which platform it's on. The bridges link
  nothing from LÖVE or LuaJIT and include no `lua.h`, so they don't depend on
  the LÖVE version. Android reaches SDL at run time and handles SDL2 (LÖVE 11)
  and SDL3 (LÖVE 12) alike.
- **Nothing calls back into Lua from another thread.** The stores answer on
  their own threads. The bridges turn each answer into one line on a queue, and
  `iap.update()` drains that queue on the game thread and runs your callbacks.
- **A purchase is finished only after the game has granted it.** `onPurchase`
  runs first. Only after it returns does `iap.lua` acknowledge or consume the
  purchase (Play) or finish the transaction (StoreKit). Until then the store
  hands the purchase back at every launch, so a crash between paying and
  granting loses nothing. Return `false` from `onPurchase` to deliberately
  leave a purchase for later.
- **Consumables are protected against double grants.** The purchase token is
  written to a small ledger right after `onPurchase` returns. If a granted
  consumable comes back because finishing it never completed, it is finished
  again without a second grant. The one remaining gap is a crash *between* your
  grant and that ledger write. A game that needs exactly-once grants can store
  `purchase.token` with its own save.
- **Non-consumables are remembered locally** in `iap.txt` in the save
  directory, so `iap.owns` works offline and on the first frame. A full sync
  with the store makes this list match the store's, which is how a refund
  takes an item back. Syncs happen at every launch on Android and iOS, and on
  `iap.restore()`. Pass `revoke = false` to never take items back.

## Adding it to a game

### 1. The Lua side

Copy `iap.lua` into the game, or add this repo as a git submodule and require
it from there, e.g. `require "lib.love-iap.iap"`. Call `iap.init` once and
`iap.update()` every frame.

### 2. Android

In the game's workflow, add one step after checking out love-android and before
gradle:

```yaml
- name: Checkout LÖVE for Android
  uses: actions/checkout@v4
  with:
    repository: love2d/love-android
    ref: <pinned ref>
    path: love-android
    submodules: recursive

- uses: cmatuteortega/love-iap@v1      # or @<commit sha>
  with:
    love-android-path: love-android
    # billing-version: 9.1.0
```

Without GitHub Actions, run `android/install.sh path/to/love-android [billing version]`
yourself. It makes three edits and checks each one:

1. It copies `android/love-iap` into `app/src/main/cpp/lua-modules/`.
   love-android builds every folder there, which gives `libliap.so`, and
   compiles the Java listed in its `java.txt` (`LoveIap.java`).
2. It adds `com.android.billingclient:billing` to `app/build.gradle`. The
   library brings the `BILLING` permission with it.
3. It adds the `liap` target to the CMake targets that gradle packages.

It needs a love-android with `lua-modules` support and `minSdk` 23 or higher,
which Play Billing requires. That holds for the LÖVE 12 line, and CI builds
against a pinned commit of it.

#### Play Console

Purchases only work for an app that Play knows about:

1. Create the app in Play Console with the **same application id** as the
   build.
2. Upload a signed build to a testing track. Internal testing is fine. Play
   wants an AAB: build `bundleEmbedNoRecordRelease` next to the APK. Every
   build from then on must use the **same signing key**, so keep the keystore
   in your signing secrets.
3. Create the products under *Monetize → Products → In-app products* using the
   ids from `iap.init`, and activate them.
4. Add your Google account under *Settings → License testing*. Testers can
   buy with test cards and are never charged.
5. Install the app from the testing track's opt-in link. A sideloaded build
   with the same id and signing key also works, once the uploaded version
   exists.

Until steps 1–3 are done, expect every product to come back `missing` (or an
`onError("products", ...)`), even though billing itself may report `ready`.

### 3. iOS (and macOS)

This is done once per project in Xcode. LÖVE's Xcode project is in the LÖVE
source tree at `platform/xcode`.

1. Add `ios/LoveIap.swift` to the app target. If Xcode offers to create an
   Objective-C bridging header, decline: nothing in Objective-C calls into it.
2. *Signing & Capabilities → + Capability → In-App Purchase.*
3. Build settings, so that `ffi.C` can find the six functions in the shipped
   binary:
   - *Other Linker Flags*: add `-Wl,-export_dynamic`. Without it, link-time
     optimisation may remove functions that nothing in the binary calls.
   - *Strip Style*: `Non-Global Symbols`, not `All Symbols`.
   If either is missing, `iap.status()` returns `unavailable` with "the liap_*
   functions are not linked into this build". Check this on a Release build.
4. Set the deployment target to iOS 15 or macOS 12 or later, which StoreKit 2
   requires. On older systems the store reports `unavailable`.
5. In App Store Connect, sign the Paid Apps agreement and create the products
   with the same ids. To test in the simulator, add a StoreKit configuration
   file to the scheme (*Edit Scheme → Run → StoreKit Configuration*).

App Review rejects apps that sell non-consumables without a visible **Restore
purchases** button. Wire one to `iap.restore()`.

## API

### `iap.init(config)`

| field | |
|---|---|
| `products` | list of `{ id = "...", consumable = true }`; leave `consumable` out for one-time unlocks |
| `onPurchase(id, purchase)` | **grant it here**, and save before returning. `purchase` is `{ id, token, quantity, order, restored }`, where `restored` is true when it arrived through a sync rather than a purchase sheet. Return `false` to leave it unfinished. |
| `onRevoke(id)` | a non-consumable was refunded or is no longer owned |
| `onFail(id, reason)` | a purchase didn't happen (see reasons below) |
| `onPending(id)` | paid by a slow method; it arrives in `onPurchase` once payment clears |
| `onProduct(id, product)` | a product's price and title arrived from the store |
| `onReady()`, `onUnavailable(reason)`, `onSync()`, `onError(what, reason)` | optional |
| `file` | save file name (default `"iap.txt"`), or `false` to keep nothing |
| `revoke` | `false` to never take a non-consumable back (default `true`) |
| `mock` | `true` to use a fake store where there is no real one |

### Everything else

- `iap.update()`: call every frame. Callbacks only run from inside it.
- `iap.buy(id)`: opens the store's purchase sheet. The result arrives later.
- `iap.finish(id, token)`: finishes a purchase that `onPurchase` left
  unfinished by returning `false`. For games that grant on their own server:
  send `purchase.token` there, and call this once the server has granted it.
  Until then the store hands the purchase back at every launch, so the server
  must remember tokens it has already granted.
- `iap.restore()`: asks the store for everything this account owns.
- `iap.owns(id)`: whether a non-consumable is owned.
- `iap.product(id)`: `{ id, consumable, price, title, description, currency, micros }`,
  or `nil` until the store has answered. `price` is already formatted in the
  player's currency. Display it as is, and never hard-code a price.
- `iap.price(id)`: just `price`.
- `iap.status()`: `"off" | "starting" | "ready" | "unavailable" | "mock"`, plus a reason.
- `iap.available()`: `ready` or `mock`.

### Failure reasons

`cancelled`, `owned` (already owned; a sync follows, which delivers it),
`network`, `unavailable` (no store, billing disabled, or purchases not allowed
on this device), `unknown_product`, `not_ready`, `unverified` (iOS only:
StoreKit couldn't verify the transaction), `developer_error`, `not_owned`,
`error`.

## Native protocol

This only matters if you're porting the bridge somewhere else. `liap_poll()`
returns one event per call, as tab-separated fields, or `NULL` when there are
none:

| event | fields |
|---|---|
| `ready` | |
| `unavailable` | reason |
| `product` | id, formatted price, title, description, currency code, price in micros |
| `missing` | id |
| `purchase` | id, token, `purchased`/`pending`, acknowledged `0`/`1`, quantity, order id |
| `failed` | id, reason |
| `finished` | token, `ok` or a reason |
| `revoked` | id |
| `syncing` … `synced` | brackets a complete list of owned purchases |
| `error` | what (`products`, `sync`, `restore`), reason |

`liap_finish(token, consume)` acknowledges (`consume` = 0) or consumes
(`consume` = 1) on Play, and finishes the transaction on StoreKit.

## Developing

```sh
cc -shared -fPIC -o test/libliap.so test/fake_liap.c
LD_LIBRARY_PATH=test luajit test/run.lua       # iap.lua against a fake store

cp iap.lua example/ && love example            # the example, on the mock store
```

CI (`.github/workflows/ci.yml`) runs these tests, compiles `LoveIap.java`
against the real Play Billing library, and builds the example into a
love-android APK. It then checks the APK for `libliap.so`, `LoveIap` and Play
Billing. The APK is uploaded as an artifact.

## Releasing

Games pin a tag such as `@v1`. After a change is merged and CI is green, move
the tag: `git tag -f v1 && git push -f origin v1`, or cut `v1.x.y` tags if you
prefer exact pins.
