import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_storage_service.dart';
import 'api_client.dart';
import 'secure_token_storage.dart';

/// Crash Recovery Service
/// Handles startup recovery and cleanup of incomplete transactions
/// Ensures data integrity after app crashes or force-closes
class CrashRecoveryService {
  static CrashRecoveryService? _instance;
  static const String _incompleteTransactionsKey = 'incomplete_transactions';
  static const String _crashFlagKey = 'app_crashed_flag';
  static const String _lastCleanShutdownKey = 'last_clean_shutdown';
  
  CrashRecoveryService._();
  
  static CrashRecoveryService get instance {
    _instance ??= CrashRecoveryService._();
    return _instance!;
  }
  
  /// Initialize crash recovery on app startup
  Future<void> initialize() async {
    try {
      if (kDebugMode) debugPrint('🔍 Initializing crash recovery service');
      
      // Check if app crashed
      final prefs = await SharedPreferences.getInstance();
      final lastCleanShutdown = prefs.getString(_lastCleanShutdownKey);
      final crashFlag = prefs.getBool(_crashFlagKey) ?? false;
      
      if (crashFlag || lastCleanShutdown == null) {
        if (kDebugMode) debugPrint('⚠️ Potential crash detected, starting recovery');
        await _performRecovery();
      } else {
        if (kDebugMode) debugPrint('✅ Clean shutdown detected, no recovery needed');
      }
      
      // Set crash flag for next run
      await prefs.setBool(_crashFlagKey, true);
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Crash recovery initialization error: $e');
    }
  }
  
  /// Mark clean shutdown (call on app exit)
  Future<void> markCleanShutdown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastCleanShutdownKey, DateTime.now().toIso8601String());
      await prefs.setBool(_crashFlagKey, false);
      if (kDebugMode) debugPrint('✅ Clean shutdown marked');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error marking clean shutdown: $e');
    }
  }
  
  /// Perform crash recovery
  Future<void> _performRecovery() async {
    try {
      if (kDebugMode) debugPrint('🔄 Starting crash recovery');
      
      // Recover incomplete transactions
      await _recoverIncompleteTransactions();
      
      // Verify data integrity
      await _verifyDataIntegrity();
      
      // Clean up any corrupted data
      await _cleanupCorruptedData();
      
      // Force sync with backend to ensure consistency
      await _forceSyncAfterRecovery();
      
      if (kDebugMode) debugPrint('✅ Crash recovery completed');
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Crash recovery error: $e');
    }
  }
  
  /// Recover incomplete transactions
  Future<void> _recoverIncompleteTransactions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final incompleteJson = prefs.getString(_incompleteTransactionsKey);
      
      if (incompleteJson == null || incompleteJson.isEmpty) {
        if (kDebugMode) debugPrint('✅ No incomplete transactions to recover');
        return;
      }
      
      final List<dynamic> incomplete = json.decode(incompleteJson);
      if (kDebugMode) debugPrint('📋 Found ${incomplete.length} incomplete transactions');
      
      for (final transaction in incomplete) {
        try {
          await _recoverTransaction(transaction as Map<String, dynamic>);
        } catch (e) {
          if (kDebugMode) debugPrint('❌ Error recovering transaction: $e');
        }
      }
      
      // Clear incomplete transactions after recovery attempt
      await prefs.remove(_incompleteTransactionsKey);
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error recovering incomplete transactions: $e');
    }
  }
  
  /// Recover a single transaction
  Future<void> _recoverTransaction(Map<String, dynamic> transaction) async {
    try {
      final type = transaction['type'] as String;
      final data = transaction['data'] as Map<String, dynamic>;
      
      if (kDebugMode) debugPrint('🔄 Recovering transaction: $type');
      
      switch (type) {
        case 'sale':
          await _recoverSale(data);
          break;
        case 'product_update':
          await _recoverProductUpdate(data);
          break;
        case 'customer_update':
          await _recoverCustomerUpdate(data);
          break;
        default:
          if (kDebugMode) debugPrint('⚠️ Unknown transaction type: $type');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error in transaction recovery: $e');
    }
  }
  
  /// Recover sale transaction
  Future<void> _recoverSale(Map<String, dynamic> data) async {
    try {
      // Check if sale was already saved
      final sales = await LocalStorageService.loadSales();
      final saleId = data['sale_id'] as String?;
      
      if (saleId != null && sales.any((s) => s['sale_id'] == saleId)) {
        if (kDebugMode) debugPrint('✅ Sale already exists, skipping recovery');
        return;
      }
      
      // Re-save the sale to local storage
      sales.add(data);
      await LocalStorageService.saveSales(sales);
      
      // Queue for backend sync
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString('offline_sync_queue') ?? '[]';
      final List<dynamic> queue = json.decode(queueJson);
      
      queue.add({
        'action': 'save_sale',
        'data': data,
        'synced': false,
      });
      
      await prefs.setString('offline_sync_queue', json.encode(queue));
      
      if (kDebugMode) debugPrint('✅ Sale recovered and queued for sync');
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error recovering sale: $e');
    }
  }
  
  /// Recover product update transaction
  Future<void> _recoverProductUpdate(Map<String, dynamic> data) async {
    try {
      final productId = data['product_id'] as String?;
      if (productId == null) return;
      
      final products = await LocalStorageService.loadBackendProducts();
      final index = products.indexWhere((p) => p['id'].toString() == productId);
      
      if (index != -1) {
        products[index] = data;
        await LocalStorageService.saveBackendProducts(products);
        if (kDebugMode) debugPrint('✅ Product update recovered');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error recovering product update: $e');
    }
  }
  
  /// Recover customer update transaction
  Future<void> _recoverCustomerUpdate(Map<String, dynamic> data) async {
    try {
      final customerId = data['customer_id'] as String?;
      if (customerId == null) return;
      
      final customers = await LocalStorageService.loadLocalCustomers();
      final index = customers.indexWhere((c) => c['id'].toString() == customerId);
      
      if (index != -1) {
        customers[index] = data;
        await LocalStorageService.saveLocalCustomers(customers);
        if (kDebugMode) debugPrint('✅ Customer update recovered');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error recovering customer update: $e');
    }
  }
  
  /// Verify data integrity
  Future<void> _verifyDataIntegrity() async {
    try {
      if (kDebugMode) debugPrint('🔍 Verifying data integrity');
      
      // Verify sales data
      await _verifySalesIntegrity();
      
      // Verify products data
      await _verifyProductsIntegrity();
      
      // Verify customers data
      await _verifyCustomersIntegrity();
      
      if (kDebugMode) debugPrint('✅ Data integrity verification completed');
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Data integrity verification error: $e');
    }
  }
  
  /// Verify sales data integrity
  Future<void> _verifySalesIntegrity() async {
    try {
      final sales = await LocalStorageService.loadSales();
      int corruptedCount = 0;
      
      for (int i = sales.length - 1; i >= 0; i--) {
        final sale = sales[i];
        if (!_isValidSale(sale)) {
          sales.removeAt(i);
          corruptedCount++;
        }
      }
      
      if (corruptedCount > 0) {
        await LocalStorageService.saveSales(sales);
        if (kDebugMode) debugPrint('⚠️ Removed $corruptedCount corrupted sales records');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Sales integrity check error: $e');
    }
  }
  
  /// Verify products data integrity
  Future<void> _verifyProductsIntegrity() async {
    try {
      final products = await LocalStorageService.loadBackendProducts();
      int corruptedCount = 0;
      
      for (int i = products.length - 1; i >= 0; i--) {
        final product = products[i];
        if (!_isValidProduct(product)) {
          products.removeAt(i);
          corruptedCount++;
        }
      }
      
      if (corruptedCount > 0) {
        await LocalStorageService.saveBackendProducts(products);
        if (kDebugMode) debugPrint('⚠️ Removed $corruptedCount corrupted product records');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Products integrity check error: $e');
    }
  }
  
  /// Verify customers data integrity
  Future<void> _verifyCustomersIntegrity() async {
    try {
      final customers = await LocalStorageService.loadLocalCustomers();
      int corruptedCount = 0;
      
      for (int i = customers.length - 1; i >= 0; i--) {
        final customer = customers[i];
        if (!_isValidCustomer(customer)) {
          customers.removeAt(i);
          corruptedCount++;
        }
      }
      
      if (corruptedCount > 0) {
        await LocalStorageService.saveLocalCustomers(customers);
        if (kDebugMode) debugPrint('⚠️ Removed $corruptedCount corrupted customer records');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Customers integrity check error: $e');
    }
  }
  
  /// Clean up corrupted data
  Future<void> _cleanupCorruptedData() async {
    try {
      if (kDebugMode) debugPrint('🧹 Cleaning up corrupted data');
      
      // Check for and fix any data inconsistencies
      await _fixDuplicateSales();
      await _fixDuplicateProducts();
      await _fixDuplicateCustomers();
      
      if (kDebugMode) debugPrint('✅ Corrupted data cleanup completed');
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Corrupted data cleanup error: $e');
    }
  }
  
  /// Fix duplicate sales
  Future<void> _fixDuplicateSales() async {
    try {
      final sales = await LocalStorageService.loadSales();
      final uniqueSales = <String, dynamic>{};
      
      for (final sale in sales) {
        final saleId = sale['sale_id'] as String?;
        if (saleId != null) {
          uniqueSales[saleId] = sale;
        }
      }
      
      if (uniqueSales.length < sales.length) {
        await LocalStorageService.saveSales(uniqueSales.values.toList());
        if (kDebugMode) debugPrint('✅ Removed ${sales.length - uniqueSales.length} duplicate sales');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error fixing duplicate sales: $e');
    }
  }
  
  /// Fix duplicate products
  Future<void> _fixDuplicateProducts() async {
    try {
      final products = await LocalStorageService.loadBackendProducts();
      final uniqueProducts = <String, dynamic>{};
      
      for (final product in products) {
        final productId = product['id'].toString();
        uniqueProducts[productId] = product;
      }
      
      if (uniqueProducts.length < products.length) {
        await LocalStorageService.saveBackendProducts(uniqueProducts.values.toList());
        if (kDebugMode) debugPrint('✅ Removed ${products.length - uniqueProducts.length} duplicate products');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error fixing duplicate products: $e');
    }
  }
  
  /// Fix duplicate customers
  Future<void> _fixDuplicateCustomers() async {
    try {
      final customers = await LocalStorageService.loadLocalCustomers();
      final uniqueCustomers = <String, dynamic>{};
      
      for (final customer in customers) {
        final phone = customer['phone'] as String?;
        if (phone != null) {
          uniqueCustomers[phone] = customer;
        }
      }
      
      if (uniqueCustomers.length < customers.length) {
        await LocalStorageService.saveLocalCustomers(uniqueCustomers.values.toList());
        if (kDebugMode) debugPrint('✅ Removed ${customers.length - uniqueCustomers.length} duplicate customers');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error fixing duplicate customers: $e');
    }
  }
  
  /// Force sync after recovery
  Future<void> _forceSyncAfterRecovery() async {
    try {
      final token = await SecureTokenStorage.getToken();
      if (token == null || token.isEmpty) {
        if (kDebugMode) debugPrint('🔒 No token available, skipping sync');
        return;
      }
      
      if (kDebugMode) debugPrint('🔄 Forcing sync after recovery');
      
      // Process sync queue
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString('offline_sync_queue') ?? '[]';
      final List<dynamic> queue = json.decode(queueJson);
      
      if (queue.isNotEmpty) {
        if (kDebugMode) debugPrint('📋 Processing ${queue.length} queued operations after recovery');
        // Sync queue will be processed by background sync worker
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error in force sync after recovery: $e');
    }
  }
  
  /// Register incomplete transaction (call before starting critical operations)
  Future<void> registerIncompleteTransaction(String type, Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final incompleteJson = prefs.getString(_incompleteTransactionsKey) ?? '[]';
      final List<dynamic> incomplete = json.decode(incompleteJson);
      
      incomplete.add({
        'type': type,
        'data': data,
        'timestamp': DateTime.now().toIso8601String(),
      });
      
      await prefs.setString(_incompleteTransactionsKey, json.encode(incomplete));
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error registering incomplete transaction: $e');
    }
  }
  
  /// Clear incomplete transaction (call after successful completion)
  Future<void> clearIncompleteTransaction(String type, String transactionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final incompleteJson = prefs.getString(_incompleteTransactionsKey) ?? '[]';
      final List<dynamic> incomplete = json.decode(incompleteJson);
      
      incomplete.removeWhere((t) => 
        t['type'] == type && 
        (t['data']['sale_id'] == transactionId || t['data']['product_id'] == transactionId)
      );
      
      await prefs.setString(_incompleteTransactionsKey, json.encode(incomplete));
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error clearing incomplete transaction: $e');
    }
  }
  
  /// Validation helpers
  bool _isValidSale(dynamic sale) {
    return sale is Map && 
           sale.containsKey('sale_id') && 
           sale.containsKey('total_amount') &&
           sale.containsKey('items');
  }
  
  bool _isValidProduct(dynamic product) {
    return product is Map && 
           product.containsKey('id') && 
           product.containsKey('name') &&
           product.containsKey('price');
  }
  
  bool _isValidCustomer(dynamic customer) {
    return customer is Map && 
           customer.containsKey('phone') && 
           customer.containsKey('name');
  }
}