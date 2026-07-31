import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'stock_alert_service.dart';
import 'inventory_management_service.dart';
import 'inventory_sync_service.dart';
import 'secure_token_storage.dart';
import 'financial_math.dart';
import 'sync_queue_manager.dart';
import 'local_storage_service.dart';
import 'retail_growth_kit.dart';
import 'sync_service.dart';
import 'agent_debug_log.dart';
import 'error_log_helper.dart';

/// PRODUCTION-READY SALE SERVICE: Integrated Idempotency, Encryption, and Error Handling.
class SaleService {
  
  /// Core Transaction Logic: 
  /// Backend Sync (Single Source of Truth) -> Local History Persistence -> Backend Stock Deduction.
  static final Set<String> _pendingSales = {}; // Track pending sales to prevent duplicates

  static Future<Map<String, dynamic>> submitSale({
    required String saleId,
    required List<Map<String, dynamic>> items,
    required double grandTotal,
    required double paidAmount,
    required String customerName,
    required String customerPhone,
    required bool withTax,
    required Map<String, dynamic> totals,
    String paymentMethod = 'Cash', // NEW: Track Cash vs Online
    bool isBorrow = false, // NEW: Indicates if this is a borrow/invoice sale
  }) async {
    const String context = 'SALE_SUBMIT';

    // Idempotency protection: Check if this sale is already being processed
    if (_pendingSales.contains(saleId)) {
      if (kDebugMode) debugPrint('🚨 Sale $saleId is already being processed - skipping duplicate');
      return {
        'success': false,
        'error': 'DUPLICATE_REQUEST',
        'message': 'This sale is already being processed'
      };
    }


    InventoryManagementService.suppressInventoryCallback = true;

    // 🔧 FIXED: Check if sale has already been synced to backend
    final isSynced = await _isSaleSynced(saleId);
    if (isSynced) {
      if (kDebugMode) debugPrint('⚠️ Sale $saleId already synced to backend - skipping');

      InventoryManagementService.suppressInventoryCallback = false;
      return {
        'success': true,
        'syncCount': 0,
        'saleId': saleId,
        'status': 'ALREADY_SYNCED',
        'message': 'Sale already synced to backend'
      };
    }

    // 🔧 FIX: Skip live-API stock validation (it caused infinite spin after 2-3 sales
    // by making per-item network calls that could hang). The backend already
    // enforces stock limits during invoice sync — we do a fast local-only check here.
    final stockValidation = await _validateStockAvailabilityLocally(items);
    if (!stockValidation['valid']) {
      return {
        'success': false,
        'error': 'INSUFFICIENT_STOCK',
        'message': stockValidation['message'],
        'insufficient_items': stockValidation['insufficient_items'],
      };
    }

    _pendingSales.add(saleId);

    // #region agent log
    AgentDebugLog.log(
      location: 'sale_service.dart:submitSale:entry',
      message: 'SALE CREATION START',
      hypothesisId: 'H1',
      data: {
        'saleId': saleId,
        'grandTotal': grandTotal,
        'paymentMethod': paymentMethod,
        'itemCount': items.length,
        'isBorrow': isBorrow,
      },
    );
    // #endregion
    
    try {
      if (kDebugMode) debugPrint('🚀 Processing ${isBorrow ? 'Invoice/Borrow' : 'Sale'} Transaction (Offline-First): $saleId');
      
      // ── 1. GENERATE PAYLOAD WITH STRICT MAPPING ──
      final String offlineId = '${saleId}_${DateTime.now().millisecondsSinceEpoch}';
      
      // 🔧 FIX: Load local products once before mapping to avoid await in non-async context
      final localProducts = await LocalStorageService.loadLocalProducts();
      
      final lineItems = items.map((item) {
        final productIdRaw = item['product_id'] ?? item['id'] ?? '0';
        final parsedId = int.tryParse(productIdRaw.toString()) ?? 0;
        
        // 🔧 FIX: Resolve numeric product_id from local cache if it's a barcode string
        int validId = parsedId > 0 ? parsedId : 0;
        if (validId == 0 && productIdRaw.toString().length > 3) {
          // Try to find numeric ID by barcode/name from local products
          final String itemName = item['product_name'] ?? item['itemName'] ?? item['name'] ?? '';
          final String barcode = item['barcode'] ?? '';
          
          // 🔧 FIX: Convert Map to List if needed, or iterate over values
          final productsList = localProducts is List ? localProducts as List : localProducts.values.toList();
          
          for (var p in productsList) {
            final pId = (p['id'] ?? p['product_id'] ?? '').toString();
            final pSku = (p['sku'] ?? p['barcode'] ?? '').toString();
            final pName = (p['product_name'] ?? p['name'] ?? '').toString().toLowerCase();
            
            if (pId.isNotEmpty && int.tryParse(pId) != null) {
              final int parsedPId = int.parse(pId);
              if (barcode.isNotEmpty && pSku == barcode) {
                validId = parsedPId;
                break;
              } else if (pName == itemName.toLowerCase()) {
                validId = parsedPId;
                break;
              }
            }
          }
        }
        
        final nameRaw = item['product_name'] ?? item['itemName'] ?? item['name'] ?? item['title'] ?? item['product'];
        String validName = nameRaw?.toString().trim() ?? '';
        if (validName.isEmpty || validName.toLowerCase() == 'unknown' || validName.toLowerCase() == 'unknown item') {
           if (kDebugMode) debugPrint('⚠️ Warning: Empty product name detected, falling back to Custom Item');
           validName = 'Custom Item';
        }

        final qtyRaw = item['qty'] ?? item['quantity'] ?? 1;
        final qty = (qtyRaw is num) ? qtyRaw.toInt() : int.tryParse(qtyRaw.toString()) ?? 1;
        
        // 🔧 FIX: Debug quantity parsing to ensure correct quantity is used
        if (kDebugMode) {
          debugPrint('🔍 [SaleService] Processing item: $validName');
          debugPrint('   Raw qty: $qtyRaw (${qtyRaw.runtimeType})');
          debugPrint('   Parsed qty: $qty');
        }

        final priceRaw = item['price'] ?? item['unit_price'] ?? 0;
        final price = (priceRaw is num) ? priceRaw.toDouble() : double.tryParse(priceRaw.toString()) ?? 0.0;
        final qtyDouble = (qtyRaw is num) ? qtyRaw.toDouble() : double.tryParse(qtyRaw.toString()) ?? 1.0;
        
        final lineTotal = CurrencyManager.multiply(price, qtyDouble);
        
        if (kDebugMode) {
          debugPrint('${isBorrow ? 'INVOICE' : 'SALE'} CREATED:\nid: $saleId\nproduct_name: $validName\nquantity: $qty\nprice: $price');
        }

        return {
          'product_id': validId > 0 ? validId : null,
          'product_name': validName,
          'quantity': qty,
          'qty': qty, // 🔧 FIX: Include both 'quantity' and 'qty' for compatibility
          'unit_price': price,
          'line_total': lineTotal,
        };
      }).toList();

// Step 1: Sync to backend — primary /auth/sales (production-proven), invoice API fallback
      bool backendSuccess = false;
      try {
        final token = await SecureTokenStorage.getToken() ?? '';
        
        final invoicePayload = {
          'invoice_number': saleId,
          'offline_id': offlineId,
          'customer_name': customerName.isNotEmpty ? customerName : 'Cash Customer',
          'customer_phone': customerPhone.isNotEmpty ? customerPhone : null,
          'total_amount': grandTotal,
          'paid_amount': paidAmount,
          'tax': withTax ? (totals['tax'] ?? 0.0) : 0.0,
          'payment_status': paidAmount >= grandTotal - 0.5 ? 'PAID' : (paidAmount > 0 ? 'PARTIAL' : 'UNPAID'),
          'invoice_date': DateTime.now().toIso8601String().split('T')[0],
          'notes': isBorrow ? 'Payment via $paymentMethod - Borrow Invoice' : 'Payment via $paymentMethod - Regular Sale',
          'line_items': lineItems,
        };

        // #region agent log
        AgentDebugLog.log(
          location: 'sale_service.dart:submitSale:pre_post',
          message: 'SALE SYNC START',
          hypothesisId: 'H7',
          data: {
            'primaryEndpoint': ApiClient.salesEndpoint,
            'fallbackEndpoint': ApiClient.invoicesCreate,
            'tokenPresent': token.isNotEmpty,
            'invoiceNumber': saleId,
            'lineItemCount': lineItems.length,
          },
        );
        // #endregion

        // PRIMARY: /api/invoices/sync — full offline payload sync
        backendSuccess = false;

        if (!backendSuccess) {
          var response = await ApiClient.postJson(ApiClient.invoicesSync, invoicePayload, headers: {
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          }).timeout(const Duration(seconds: 25));

          AgentDebugLog.log(
            location: 'sale_service.dart:submitSale:invoice_fallback_response',
            message: 'INVOICE API FALLBACK RESPONSE',
            hypothesisId: 'H2',
            data: {
              'statusCode': response.statusCode,
              'bodyPreview': response.body.length > 500 ? response.body.substring(0, 500) : response.body,
              'saleId': saleId,
            },
          );

          if (response.statusCode == 200 || response.statusCode == 201) {
            backendSuccess = true;
          } else {
            throw Exception('${isBorrow ? 'Invoice' : 'Sale'} backend returned status ${response.statusCode}: ${response.body}');
          }
        }

        if (backendSuccess) {
          await _markSaleAsSynced(saleId);
        }

        // #region agent log — H3: verify sale exists via GET /auth/sales
        try {
          final verifyRes = await ApiClient.getJson(
            ApiClient.salesEndpoint,
            headers: {if (token.isNotEmpty) 'Authorization': 'Bearer $token'},
          ).timeout(const Duration(seconds: 15));
          final body = verifyRes.body;
          final saleExists = body.contains(saleId);
          int salesCount = 0;
          if (verifyRes.statusCode == 200) {
            final decoded = json.decode(body);
            if (decoded is List) salesCount = decoded.length;
          }
          AgentDebugLog.log(
            location: 'sale_service.dart:submitSale:db_verify',
            message: 'DATABASE VERIFY GET /auth/sales',
            hypothesisId: 'H3',
            data: {
              'verifyStatusCode': verifyRes.statusCode,
              'returnedSalesCount': salesCount,
              'saleExists': saleExists,
              'saleId': saleId,
            },
          );
        } catch (verifyErr) {
          AgentDebugLog.log(
            location: 'sale_service.dart:submitSale:db_verify_error',
            message: 'DATABASE VERIFY FAILED',
            hypothesisId: 'H3',
            data: {'error': verifyErr.toString(), 'saleId': saleId},
          );
        }
        // #endregion
      } catch (e, st) {
        // #region agent log
        AgentDebugLog.log(
          location: 'sale_service.dart:submitSale:post_error',
          message: 'POST FAILED',
          hypothesisId: 'H2',
          data: {
            'error': e.toString(),
            'stackPreview': st.toString().split('\n').take(5).join(' | '),
            'saleId': saleId,
          },
        );
        // #endregion
        if (kDebugMode) debugPrint('${isBorrow ? 'Invoice' : 'Sale'} backend sync failed, falling back to queue: $e');
        
        final prefs = await SharedPreferences.getInstance();
        await _persistToLocalHistory(
          prefs: prefs,
          saleId: saleId,
          customerName: customerName,
          customerPhone: customerPhone,
          items: lineItems,
          grandTotal: grandTotal,
          paidAmount: paidAmount,
          withTax: withTax,
          totals: totals,
          paymentMethod: paymentMethod,
          syncStatus: 'pending',
        );

        final invoicePayload = {
          'invoice_number': saleId,
          'offline_id': offlineId,
          'customer_name': customerName.isNotEmpty ? customerName : 'Cash Customer',
          'customer_phone': customerPhone.isNotEmpty ? customerPhone : null,
          'total_amount': grandTotal,
          'paid_amount': paidAmount,
          'tax': withTax ? (totals['tax'] ?? 0.0) : 0.0,
          'payment_status': paidAmount >= grandTotal - 0.5 ? 'PAID' : (paidAmount > 0 ? 'PARTIAL' : 'UNPAID'),
          'invoice_date': DateTime.now().toIso8601String().split('T')[0],
          'notes': isBorrow ? 'Payment via $paymentMethod - Borrow Invoice' : 'Payment via $paymentMethod - Regular Sale',
          'line_items': lineItems,
        };
        
        try {
          await SyncQueueManager.enqueue('save_sale', {
            'is_borrow': isBorrow,
            'endpoint': ApiClient.invoicesSync,
            'payload': invoicePayload,
            'sale_id': saleId,
            'retry_priority': 'high',
          });
        } catch (queueError) {
          if (kDebugMode) debugPrint('⚠️ Failed to enqueue offline sale: $queueError');
          await ErrorLogHelper.logException(queueError, StackTrace.current, context: 'SaleService.submitSale:enqueue');
          rethrow; // Added to prevent silent data loss
        }

        // Always deduct stock locally even when offline so inventory remains accurate
        try {
          await InventoryManagementService.deductStockLocally(items, saleId: saleId);
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Local stock deduction after offline queue failed: $e');
        }

        SyncService.triggerDashboardRefresh();
        backendSuccess = false;
      } finally {
        // Always cleanup pending sales flag
        _pendingSales.remove(saleId);

        InventoryManagementService.suppressInventoryCallback = false;
      }
      
      // If backend succeeded, persist locally and return success
      if (backendSuccess) {
        // Step 2: Persist to local Hive BEFORE deducting stock (use normalized lineItems)
        final prefs = await SharedPreferences.getInstance();
        await _persistToLocalHistory(
          prefs: prefs,
          saleId: saleId,
          customerName: customerName,
          customerPhone: customerPhone,
          items: lineItems, // Use normalized lineItems with numeric prices/qtys
          grandTotal: grandTotal,
          paidAmount: paidAmount,
          withTax: withTax,
          totals: totals,
          paymentMethod: paymentMethod,
          syncStatus: 'synced',
        );
        
        await RetailGrowthKit.recordBillCompleted();
        
        // CRITICAL Fix: Notify Dashboard to reload immediately after sale saved to Hive
        // Without this, Dashboard keeps showing 'Create First Sale' because it never knows
        // the Hive box was updated.
        SyncService.triggerDashboardRefresh();
        unawaited(SyncService.downloadUserDataSafe());
        
        // Step 3: NOW deduct stock locally - sale already exists in Hive so _loadSales is safe
        try {
          await InventoryManagementService.deductStockLocally(items, saleId: saleId);
        } catch (e) {
          if (kDebugMode) debugPrint('Local stock deduction failed, but proceeding: $e');
        }
        
        // 🔧 REMOVED: refreshAllInventory should NOT be called after sales
        // The backend handles stock deduction during invoice sync, and local deduction is already done above
        // Calling refreshAllInventory here can cause sync conflicts and double-deduction issues

        final localSales = await LocalStorageService.loadSales();
        // #region agent log
        AgentDebugLog.log(
          location: 'sale_service.dart:submitSale:local_cache',
          message: 'LOCAL STORAGE AFTER SAVE',
          hypothesisId: 'H4',
          data: {
            'cacheCount': localSales.length,
            'syncStatus': 'synced',
            'isLocal': false,
            'pendingSync': false,
            'saleId': saleId,
          },
        );
        // #endregion

        // #region agent log
        AgentDebugLog.log(
          location: 'sale_service.dart:submitSale:final_result',
          message: 'FINAL RESULT',
          hypothesisId: 'H5',
          data: {
            'saleUploadedToBackend': true,
            'backendSuccess': true,
            'success': true,
            'saleId': saleId,
          },
        );
        // #endregion
        
        return {
          'success': true,
          'syncCount': items.length,
          'saleId': saleId,
          'status': 'COMMITTED_LOCALLY',
        };
      } else {
        // Step 2: Persist locally for offline fallback if backend sync failed
        final prefs = await SharedPreferences.getInstance();
        await _persistToLocalHistory(
          prefs: prefs,
          saleId: saleId,
          customerName: customerName,
          customerPhone: customerPhone,
          items: lineItems,
          grandTotal: grandTotal,
          paidAmount: paidAmount,
          withTax: withTax,
          totals: totals,
          paymentMethod: paymentMethod,
          syncStatus: 'pending',
        );

        await RetailGrowthKit.recordBillCompleted();
        SyncService.triggerDashboardRefresh();

        // #region agent log
        AgentDebugLog.log(
          location: 'sale_service.dart:submitSale:final_result',
          message: 'FINAL RESULT',
          hypothesisId: 'H5',
          data: {
            'saleUploadedToBackend': false,
            'backendSuccess': false,
            'success': true,
            'saleId': saleId,
            'status': 'QUEUED_OFFLINE',
          },
        );
        // #endregion
        return {
          'success': true,
          'saleId': saleId,
          'status': 'QUEUED_OFFLINE',
          'message': 'Sale saved locally and queued for retry when connectivity returns.',
        };
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('❌ TRANSACTION CRITICAL FAILURE [$context]: $e');
      if (kDebugMode) debugPrint(st.toString());
      // #region agent log
      AgentDebugLog.log(
        location: 'sale_service.dart:submitSale:critical_failure',
        message: 'CRITICAL FAILURE',
        hypothesisId: 'H5',
        data: {'error': e.toString(), 'saleId': saleId},
      );
      // #endregion
      return {
        'success': false,
        'error': e.toString(),
        'recovery_action': 'RETRY_SYNC',
      };
    } finally {
      _pendingSales.remove(saleId);

      InventoryManagementService.suppressInventoryCallback = false;
      InventoryManagementService.onInventoryChanged?.call();
    }
  }

  /// Background sync task that posts to /api/invoices/sync endpoint
  static Future<void> _syncToBackendBackground(Map<String, dynamic> invoicePayload, List<Map<String, dynamic>> items, String saleId) async {
    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      
      final response = await ApiClient.postJson(ApiClient.invoicesSync, invoicePayload, headers: {
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      }).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200 && response.statusCode != 201) {
        // Queue for high-reliability offline sync
        await SyncQueueManager.enqueue('save_sale', {
          'invoice_payload': invoicePayload,
          'sale_id': saleId,
          'retry_priority': 'high',
        });
      } else {
        await _deductStockViaBackend(items, saleId);
        await _markSaleAsSynced(saleId);
        // 🔧 REMOVED: refreshAllInventory should NOT be called after sales
        // The backend already handles stock deduction during invoice sync
        if (kDebugMode) debugPrint('✅ Invoice synced in background: ');
      }

    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Background sync failed: ');
    }
  }

  static Future<void> _deductStockViaBackend(List<Map<String, dynamic>> items, String saleId) async {
    try {
      // Prepare batch stock deduction request
      final stockUpdates = <Map<String, dynamic>>[];
      
      for (var item in items) {
        final productId = int.tryParse((item['product_id'] ?? item['id'] ?? '0').toString());
        if (productId != null && productId > 0) {
          stockUpdates.add({
            'product_id': productId,
            'qty': (item['qty'] is num ? (item['qty'] as num).toInt() : int.tryParse(item['qty']?.toString() ?? '1') ?? 1),
            'reference_id': saleId,
          });
        }
      }
      
      if (stockUpdates.isNotEmpty) {
        final result = await InventorySyncService.deductStockBatch(stockUpdates);
        if (kDebugMode) {
          debugPrint('🛒 Backend stock deduction: ${result['successful']}/${result['total_items']} successful');
          if (result['failed'] > 0) {
            debugPrint('⚠️ Failed deductions: ${result['failed_items']}');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Backend stock deduction failed: $e');
      // Don't fail the sale if stock deduction fails - backend will handle it during invoice sync
    }
  }

  /// 🔧 NEW: Mark sale as synced to backend to prevent re-processing
  static Future<void> _markSaleAsSynced(String saleId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final syncedSales = prefs.getStringList('synced_sales') ?? [];
      if (!syncedSales.contains(saleId)) {
        syncedSales.add(saleId);
        // 🔧 FIXED: Keep only last 1000 synced sales to prevent unlimited growth
        if (syncedSales.length > 1000) {
          syncedSales.removeRange(0, syncedSales.length - 1000);
        }
        await prefs.setStringList('synced_sales', syncedSales);
        if (kDebugMode) debugPrint('🔖 Marked sale as synced: $saleId');
      }
      
      // Also update sync metadata in local sales history
      final sales = await LocalStorageService.loadSales();
      bool updated = false;
      for (int i = 0; i < sales.length; i++) {
        if (sales[i]['sale_id'] == saleId) {
          sales[i] = {
            ...sales[i],
            'sync_status': 'synced',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            'last_sync_attempt': DateTime.now().toUtc().toIso8601String(),
          };
          updated = true;
          break;
        }
      }
      if (updated) {
        await LocalStorageService.saveSales(sales);
        if (kDebugMode) debugPrint('📝 Updated local sale sync status to synced: $saleId');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to mark sale as synced: $e');
    }
  }

  /// 🔧 NEW: Check if sale has been synced to backend
  static Future<bool> _isSaleSynced(String saleId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final syncedSales = prefs.getStringList('synced_sales') ?? [];
      return syncedSales.contains(saleId);
    } catch (e) {
      return false;
    }
  }

  /// Public helper to mark a queued sale as synced after background sync succeeds
  static Future<void> markSaleAsSynced(String saleId) async {
    if (saleId.isEmpty) return;
    await _markSaleAsSynced(saleId);
  }

  /// Fire-and-forget alert trigger to keep main thread fast
  static void _triggerBackgroundAlert(Map<String, dynamic> item) {
    try {
      StockAlertService.checkAndAlertLowStock(
        productName: item['product_name']?.toString() ?? 'Unknown',
        quantitySold: (item['qty'] is num 
            ? (item['qty'] as num).toDouble() 
            : double.tryParse(item['qty']?.toString() ?? '1') ?? 1.0).toInt(),
        productId: int.tryParse((item['product_id'] ?? item['id'] ?? '0').toString()) ?? 0,
      );
    } catch (_) {}
  }

  /// 🚀 FAST LOCAL-ONLY stock validation (reads from cache, no network call)
  /// This prevents the infinite-spin bug that occurred when per-item API calls hung.
  static Future<Map<String, dynamic>> _validateStockAvailabilityLocally(List<Map<String, dynamic>> items) async {
    try {
      final localProducts = await LocalStorageService.loadLocalProducts();
      final productsList = localProducts is List ? localProducts as List : localProducts.values.toList();
      final insufficientItems = <Map<String, dynamic>>[];

      for (var item in items) {
        final productId = int.tryParse((item['product_id'] ?? item['id'] ?? '0').toString()) ?? 0;
        final qty = (item['qty'] is num ? (item['qty'] as num).toInt() : int.tryParse(item['qty']?.toString() ?? '1') ?? 1);
        final itemName = (item['product_name'] ?? item['itemName'] ?? item['name'] ?? '').toString().toLowerCase();

        if (productId > 0 || itemName.isNotEmpty) {
          // Find the product in local cache
          Map<String, dynamic>? found;
          for (var p in productsList) {
            final pIdRaw = (p['id'] ?? p['product_id'] ?? '').toString();
            final pId = int.tryParse(pIdRaw) ?? 0;
            final pName = (p['product_name'] ?? p['name'] ?? '').toString().toLowerCase();

            if ((productId > 0 && pId == productId) || (itemName.isNotEmpty && pName == itemName)) {
              found = Map<String, dynamic>.from(p as Map);
              break;
            }
          }

          if (found != null) {
            final currentStock = (found['current_stock'] ?? found['stock'] ?? found['quantity'] ?? 9999) as num;
            if (qty > currentStock.toInt()) {
              insufficientItems.add({
                'product_id': productId,
                'product_name': found['product_name'] ?? found['name'] ?? itemName,
                'requested_qty': qty,
                'available_stock': currentStock.toInt(),
              });
            }
          }
          // If not found in cache → allow sale (backend will validate)
        }
      }

      if (insufficientItems.isEmpty) {
        return {'valid': true, 'message': 'Stock check passed'};
      }
      final productNames = insufficientItems.map((i) => i['product_name']).join(', ');
      return {
        'valid': false,
        'message': 'Insufficient stock for: $productNames',
        'insufficient_items': insufficientItems,
      };
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Local stock validation error (allowing sale): $e');
      return {'valid': true, 'message': 'Stock validation skipped'};
    }
  }

  /// 🔒 BACKEND stock validation — only called in background; NOT in the main sale submit path.
  static Future<Map<String, dynamic>> _validateStockAvailability(List<Map<String, dynamic>> items) async {
    try {
      final insufficientItems = <Map<String, dynamic>>[];
      
      for (var item in items) {
        final productId = int.tryParse((item['product_id'] ?? item['id'] ?? '0').toString());
        final qty = (item['qty'] is num ? (item['qty'] as num).toInt() : int.tryParse(item['qty']?.toString() ?? '1') ?? 1);
        
        if (productId != null && productId > 0 && qty > 0) {
          // Fetch current stock from backend
          final stockResult = await InventorySyncService.getCurrentStock(productId);
          
          if (stockResult['success'] == true) {
            final currentStock = stockResult['current_stock'] ?? 0;
            final productName = stockResult['product_name'] ?? 'Product';
            
            if (qty > currentStock) {
              insufficientItems.add({
                'product_id': productId,
                'product_name': productName,
                'requested_qty': qty,
                'available_stock': currentStock,
              });
            }
          }
        }
      }
      
      if (insufficientItems.isEmpty) {
        return {
          'valid': true,
          'message': 'All items have sufficient stock',
        };
      } else {
        final productNames = insufficientItems.map((item) => item['product_name']).join(', ');
        return {
          'valid': false,
          'message': 'Insufficient stock for: $productNames',
          'insufficient_items': insufficientItems,
        };
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Stock validation error: $e');
      return {
        'valid': true, // Allow sale to proceed if validation fails
        'message': 'Stock validation skipped due to error',
      };
    }
  }

  static void clearInFlight() => _pendingSales.clear();

  static Future<void> _persistToLocalHistory({
    required SharedPreferences prefs,
    required String saleId,
    required String customerName,
    required String customerPhone,
    required List<Map<String, dynamic>> items,
    required double grandTotal,
    required double paidAmount,
    required bool withTax,
    required Map<String, dynamic> totals,
    String paymentMethod = 'Cash', // NEW: Cash vs Online tracking
    String syncStatus = 'synced',
  }) async {
    List<dynamic> history = await LocalStorageService.loadSales();

    // Deduplication before appending history
    if (!history.any((s) => s['sale_id'] == saleId)) {
      // 🛡️ ANONYMOUS VIP TRACKING: Assign Guest ID if no phone
      final String safePhone = customerPhone.isNotEmpty ? customerPhone : 'GUEST_${saleId.length >= 6 ? saleId.substring(saleId.length - 6) : saleId.padLeft(6, '0')}';
      
      final String saleTimestamp = DateTime.now().toUtc().toIso8601String();
      
      // Normalize items for full compatibility with all parts of app
      final List<Map<String, dynamic>> normalizedItems = items.map((item) {
        final double price = item['unit_price'] ?? item['price'] ?? 0.0;
        final int qty = item['quantity'] ?? item['qty'] ?? 1;
        final double lineTotal = item['line_total'] ?? item['total'] ?? CurrencyManager.multiply(price, qty.toDouble());
        
        return {
          ...item,
          'price': price,
          'price_str': price.toString(),
          'unit_price': price,
          'qty': qty,
          'quantity': qty,
          'qty_str': qty.toString(),
          'total': lineTotal,
          'line_total': lineTotal,
          'total_with_tax': lineTotal, // For compatibility
          'product': item['product_name'] ?? item['product'] ?? item['item'] ?? '',
          'name': item['product_name'] ?? item['product'] ?? item['item'] ?? '',
          'item': item['product_name'] ?? item['product'] ?? item['item'] ?? '',
        };
      }).toList();
      
      // Get current user ID
      final userId = prefs.getInt('user_id') ?? prefs.getInt('userId');
      
      history.add({
        'sale_id': saleId,
        'created_at': saleTimestamp,
        'updated_at': saleTimestamp,
        'user_id': userId,
        'sync_status': syncStatus,
        'pending_sync': syncStatus != 'synced',
        'sync_attempts': 0,
        'last_sync_attempt': null,
        'backend_id': null,
        'is_deleted': false,
        'customer_name': customerName.isNotEmpty ? customerName : 'Guest Customer',
        'customer_phone': customerPhone, // Actual phone (Empty if private)
        'guest_id': safePhone, // Unique tracking ID for debt/loyalty
        'items': normalizedItems,
        'sale_date': saleTimestamp,
        'date': saleTimestamp, // CRITICAL FIX: DashboardPage._getLocalDate relies on this key
        'subtotal': totals['subtotal'].toString(),
        'total': grandTotal.toString(),
        'total_amount': grandTotal, // For compatibility
        'paid_amount': paidAmount.toString(),
        'payment_status': paidAmount >= grandTotal - 0.5 ? 'PAID' : (paidAmount > 0 ? 'PARTIAL' : 'UNPAID'),
        'gst_applied': withTax,
        'payment_method': paymentMethod, // NEW: Cash / Online / UPI
      });

      // Maintain performant history limit
      if (history.length > 5000) {
        history = history.sublist(history.length - 5000);
      }
      await LocalStorageService.saveSales(history);
      if (kDebugMode) debugPrint('📝 Created local sale with sync metadata: $saleId');
    }
  }

}



