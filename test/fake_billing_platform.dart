import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';

/// Fake Google Play store: the test drives purchase updates by hand.
class FakeBillingPlatform implements BillingPlatform {
  FakeBillingPlatform({this.storeAvailable = true, this.autoResult});
  final bool storeAvailable;

  /// When set, every [buy] is answered with a purchase update of this status.
  PurchaseStatus? autoResult;
  final controller = StreamController<List<PurchaseDetails>>.broadcast();
  final completed = <PurchaseDetails>[];
  final bought = <({String product, String accountId, String? replacing})>[];
  final queriedIds = <String>[];
  int restores = 0;
  List<PurchaseDetails> owned = [];

  @override
  Future<bool> isAvailable() async => storeAvailable;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => controller.stream;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async {
    queriedIds.addAll(ids);
    return ProductDetailsResponse(
      productDetails: [
        for (final id in ids)
          ProductDetails(
            id: id,
            title: id,
            description: id,
            price: '€4.99',
            rawPrice: 4.99,
            currencyCode: 'EUR',
          ),
      ],
      notFoundIDs: const [],
    );
  }

  @override
  Future<bool> buy({
    required ProductDetails product,
    required String accountId,
    PurchaseDetails? replacing,
  }) async {
    bought.add((
      product: product.id,
      accountId: accountId,
      replacing: replacing?.productID,
    ));
    final status = autoResult;
    if (status != null) {
      scheduleMicrotask(
        () => controller.add([
          purchase(product.id, status, token: 'token-${bought.length}'),
        ]),
      );
    }
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase);
    purchase.pendingCompletePurchase = false;
  }

  @override
  Future<void> restorePurchases({String? accountId}) async {
    restores++;
    scheduleMicrotask(() => controller.add(List.of(owned)));
  }
}

PurchaseDetails purchase(
  String productId,
  PurchaseStatus status, {
  String token = 'token-1',
}) =>
    PurchaseDetails(
        purchaseID: 'GPA.$token',
        productID: productId,
        verificationData: PurchaseVerificationData(
          localVerificationData: '{}',
          serverVerificationData: token,
          source: 'google_play',
        ),
        transactionDate: '0',
        status: status,
      )
      ..pendingCompletePurchase =
          status == PurchaseStatus.purchased ||
          status == PurchaseStatus.restored;

/// A [PlayBillingService] over [FakeBillingPlatform] whose server verdict is
/// [verdict] (default: verified, acknowledge).
PlayBillingService fakeBillingService(
  FakeBillingPlatform store, {
  PlayVerifyOutcome Function(String token)? verdict,
  List<String>? verified,
}) => PlayBillingService(
  platform: store,
  uid: () => 'user-1',
  verifier:
      ({
        required String productId,
        required String purchaseToken,
        required String packageName,
      }) async {
        verified?.add('$productId:$purchaseToken:$packageName');
        return (verdict ??
            (_) => PlayVerifyOutcome(
              UpgradeResult.ok,
              tier: ovidTierForProduct(productId),
              acknowledge: true,
            ))(purchaseToken);
      },
);
