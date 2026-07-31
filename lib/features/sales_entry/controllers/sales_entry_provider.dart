import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/sales_item.dart';
import '../services/voice_nlp_service.dart';
import '../../../native_language_service.dart';
import '../../../sale_service.dart';
import '../../../local_storage_service.dart';
import '../../../inventory_sync_service.dart';
import '../../../format_helper.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

class SalesEntryProvider extends ChangeNotifier {
  List<SalesItem> entries = [];
  bool withTax = true;
  double paidAmount = 0.0;
  bool isOnlinePayment = false;
  String? paymentStatus;
  String selectedPaymentMethod = 'Cash'; // NEW: Track payment method
  
  // Loading states
  bool isSaving = false;
  bool isGeneratingBill = false;

  // Customer Details
  final TextEditingController customerPhoneController = TextEditingController();
  final TextEditingController customerNameController = TextEditingController();

  // Shop Details (Load from preferences)
  String shopName = 'My Shop';
  String shopLocation = '';
  String shopType = '';
  String shopPhone = '';
  String shopEmail = '';

  SalesEntryProvider() {
    _initializeEmptyRow();
  }

  void _initializeEmptyRow() {
    entries.add(SalesItem(id: DateTime.now().millisecondsSinceEpoch.toString()));
    notifyListeners();
  }

  // --- Calculations ---

  double get totalAmount {
    double total = 0.0;
    for (var entry in entries) {
      total += entry.finalAmount;
    }
    return total;
  }

  double get subtotalAmount {
    double total = 0.0;
    for (var entry in entries) {
      total += entry.subtotal;
    }
    return total;
  }

  // --- Actions ---

  void addEntry() {
    entries.add(SalesItem(id: DateTime.now().millisecondsSinceEpoch.toString()));
    notifyListeners();
  }

  void removeEntry(int index) {
    if (entries.length > 1) {
      entries.removeAt(index);
      notifyListeners();
    }
  }

  void updateEntry(int index, SalesItem newItem) {
    if (index >= 0 && index < entries.length) {
      entries[index] = newItem;
      notifyListeners();
    }
  }

  void toggleTax() {
    withTax = !withTax;
    notifyListeners();
  }

  void setOnlinePayment(bool value) {
    isOnlinePayment = value;
    notifyListeners();
  }

  // --- Voice Processing ---

  Future<void> processVoiceCommand(String text, {List<Map<String, dynamic>> inventory = const []}) async {
    // 1. Instantly intercept and translate text using Offline Native Language Service
    final translatedText = await NativeLanguageService.translateToEnglish(text);

    final parsedItems = VoiceNlpService.parseMultipleItems(translatedText, knownInventory: inventory);
    
    if (parsedItems.isNotEmpty) {
      // Clear empty first row if needed
      if (entries.length == 1 && entries.first.itemName.isEmpty) {
        entries.clear();
      }

      for (var item in parsedItems) {
        entries.add(SalesItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          itemName: item['item'] ?? '',
          quantity: double.tryParse(item['qty'].toString()) ?? 1.0,
          price: double.tryParse(item['price'].toString()) ?? 0.0,
        ));
      }
      notifyListeners();
    }
  }

  // --- Submit Logic ---

  Future<bool> submitSale() async {
    if (entries.isEmpty || totalAmount <= 0) return false;

    // Set loading state
    isSaving = true;
    notifyListeners();

    // 🔧 CRITICAL FIX: Ensure products are available before sale
    await _ensureProductsAvailable();

    // Build items payload - 🔧 FIXED: Filter out empty/invalid items
    final itemsPayload = <Map<String, dynamic>>[];
    for (final e in entries.where((e) => e.itemName.isNotEmpty && e.itemName.trim() != 'Unknown' && e.price > 0)) {
      // 🔧 CRITICAL FIX: Look up actual database product_id for stock deduction
      final actualProductId = await _lookupProductIdByName(e.itemName);

      // 🔧 FALLBACK: Log warning if product lookup fails but still submit sale
      if (actualProductId == 0 && kDebugMode) {
        debugPrint('⚠️ Product lookup failed for: ${e.itemName}, submitting without stock deduction');
      }

      itemsPayload.add({
        'itemName': e.itemName,
        'product_id': actualProductId, // 0 if not found, backend will handle gracefully
        'quantity': e.quantity,
        'price': e.price,
        'gst': e.gst,
        'discount': e.discount,
        'total': e.finalAmount,
      });
    }

    // 🔧 FIXED: Don't submit sales if no valid items
    if (itemsPayload.isEmpty) {
      print('No valid items to submit');
      return false;
    }

    try {
      final result = await SaleService.submitSale(
        saleId: DateTime.now().millisecondsSinceEpoch.toString(),
        items: itemsPayload,
        grandTotal: totalAmount,
        paidAmount: totalAmount,
        customerName: customerNameController.text.trim(),
        customerPhone: customerPhoneController.text.trim(),
        withTax: withTax,
        totals: {
          'subtotal': subtotalAmount,
          'cgst': withTax ? subtotalAmount * 0.09 : 0.0,
          'sgst': withTax ? subtotalAmount * 0.09 : 0.0,
        },
        paymentMethod: isOnlinePayment ? 'Online' : 'Cash',
      );

      if (result['success'] == true) {
        _clearForm();
        isSaving = false;
        notifyListeners();
        return true;
      }
      isSaving = false;
      notifyListeners();
      return false;
    } catch (e) {
      print('Error submitting sale: ');
      isSaving = false;
      notifyListeners();
      return false;
    }
  }

  /// Save sale as credit - creates ledger entry and updates customer balance
  Future<bool> saveAsCredit() async {
    if (entries.isEmpty || totalAmount <= 0) return false;

    // Set loading state
    isSaving = true;
    notifyListeners();

    // 🔧 CRITICAL Fix: Ensure products are available before sale
    await _ensureProductsAvailable();

    // Build items payload - 🔧 FIXED: Filter out empty/invalid items
    final itemsPayload = <Map<String, dynamic>>[];
    for (final e in entries.where((e) => e.itemName.isNotEmpty && e.itemName.trim() != 'Unknown' && e.price > 0)) {
      // 🔧 CRITICAL FIX: Look up actual database product_id for stock deduction
      final actualProductId = await _lookupProductIdByName(e.itemName);

      // 🔧 FALLBACK: Log warning if product lookup fails but still submit sale
      if (actualProductId == 0 && kDebugMode) {
        debugPrint('⚠️ Product lookup failed for: ${e.itemName}, submitting without stock deduction');
      }

      itemsPayload.add({
        'itemName': e.itemName,
        'product_id': actualProductId, // 0 if not found, backend will handle gracefully
        'quantity': e.quantity,
        'price': e.price,
        'gst': e.gst,
        'discount': e.discount,
        'total': e.finalAmount,
      });
    }

    // 🔧 FIXED: Don't submit sales if no valid items
    if (itemsPayload.isEmpty) {
      print('No valid items to submit');
      return false;
    }

    try {
      final result = await SaleService.submitSale(
        saleId: DateTime.now().millisecondsSinceEpoch.toString(),
        items: itemsPayload,
        grandTotal: totalAmount,
        paidAmount: 0.0, // Credit sale - no payment
        customerName: customerNameController.text.trim(),
        customerPhone: customerPhoneController.text.trim(),
        withTax: withTax,
        totals: {
          'subtotal': subtotalAmount,
          'cgst': withTax ? subtotalAmount * 0.09 : 0.0,
          'sgst': withTax ? subtotalAmount * 0.09 : 0.0,
        },
        paymentMethod: 'Credit',
      );

      if (result['success'] == true) {
        // Add to customer ledger (khata)
        await _addToCustomerLedger(
          customerName: customerNameController.text.trim(),
          customerPhone: customerPhoneController.text.trim(),
          amount: totalAmount,
          saleId: result['saleId']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
        );
        
        _clearForm();
        isSaving = false;
        notifyListeners();
        return true;
      }
      isSaving = false;
      notifyListeners();
      return false;
    } catch (e) {
      print('Error saving sale as credit: ');
      isSaving = false;
      notifyListeners();
      return false;
    }
  }

  /// Add credit entry to customer ledger
  Future<void> _addToCustomerLedger({
    required String customerName,
    required String customerPhone,
    required double amount,
    required String saleId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Load existing ledger entries
      final ledgerKey = 'khata_ledger';
      final ledgerData = prefs.getString(ledgerKey);
      List<Map<String, dynamic>> ledger = [];
      
      if (ledgerData != null) {
        try {
          ledger = List<Map<String, dynamic>>.from(
            jsonDecode(ledgerData).map((e) => Map<String, dynamic>.from(e))
          );
        } catch (_) {}
      }

      // Add new credit entry
      final phone = customerPhone.isNotEmpty ? customerPhone : 'GUEST_${saleId.substring(saleId.length - 6)}';
      final name = customerName.isNotEmpty ? customerName : 'Guest Customer';
      
      ledger.add({
        'customer_name': name,
        'customer_phone': phone,
        'amount': amount,
        'type': 'CREDIT',
        'sale_id': saleId,
        'date': DateTime.now().toIso8601String(),
        'balance': amount, // This will be recalculated when loading
      });

      // Save updated ledger
      await prefs.setString(ledgerKey, jsonEncode(ledger));
      
      // Update customer balance in customers data
      final customersKey = 'customers';
      final customersData = prefs.getString(customersKey);
      List<Map<String, dynamic>> customers = [];
      
      if (customersData != null) {
        try {
          customers = List<Map<String, dynamic>>.from(
            jsonDecode(customersData).map((e) => Map<String, dynamic>.from(e))
          );
        } catch (_) {}
      }

      // Find or create customer
      final customerIndex = customers.indexWhere((c) => c['phone'] == phone);
      
      if (customerIndex >= 0) {
        // Update existing customer
        customers[customerIndex]['credit_balance'] = 
            (customers[customerIndex]['credit_balance'] as num? ?? 0) + amount;
        customers[customerIndex]['credit_limit'] = 
            (customers[customerIndex]['credit_limit'] as num? ?? 0) + amount;
        customers[customerIndex]['last_transaction'] = DateTime.now().toIso8601String();
      } else {
        // Create new customer
        customers.add({
          'customer_name': name,
          'phone': phone,
          'email': '',
          'city': '',
          'credit_limit': amount,
          'credit_balance': amount,
          'total_purchases': amount,
          'last_purchase': DateTime.now().toIso8601String(),
          'purchase_count': 1,
        });
      }

      await prefs.setString(customersKey, jsonEncode(customers));
      
    } catch (e) {
      print('Error adding to customer ledger: ');
    }
  }

  void _clearForm() {
    entries.clear();
    customerNameController.clear();
    customerPhoneController.clear();
    _initializeEmptyRow();
  }

  @override
  void dispose() {
    customerNameController.dispose();
    customerPhoneController.dispose();
    super.dispose();
  }

  /// 🔧 NEW: Look up actual database product_id from product name
  Future<int> _lookupProductIdByName(String productName) async {
    try {
      // Try to find product by product name (fuzzy match)
      final products = await LocalStorageService.loadBackendProducts();
      
      if (products == null || products.isEmpty) {
        // 🔧 CRITICAL FIX: If no products in local storage, log warning
        if (kDebugMode) debugPrint('⚠️ No products in local storage - product lookup will fail');
        return 0;
      }

      final normalizedName = productName.toLowerCase().trim();
      // 1. Exact match first (fixes incorrect inventory deduction on similarly named products)
      for (var product in products) {
        final productDbName = (product['product_name'] ?? product['name'] ?? '').toString().toLowerCase().trim();
        if (productDbName == normalizedName) {
          return int.tryParse(product['id']?.toString() ?? '0') ?? 0;
        }
      }
      
      // 2. Loose fallback (only if exact match fails)
      for (var product in products) {
        final productDbName = (product['product_name'] ?? product['name'] ?? '').toString().toLowerCase().trim();
        if (productDbName.isNotEmpty && (productDbName.contains(normalizedName) || normalizedName.contains(productDbName))) {
          return int.tryParse(product['id']?.toString() ?? '0') ?? 0;
        }
      }

      if (kDebugMode) debugPrint('⚠️ Could not find product_id for product name: $productName');
      return 0; // Return 0 if not found (backend will handle gracefully)
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error looking up product_id: $e');
      return 0;
    }
  }

  /// 🔧 NEW: Force refresh inventory from backend before processing sales
  Future<void> _ensureProductsAvailable() async {
    try {
      final products = await LocalStorageService.loadBackendProducts();
      if (products.isEmpty) {
        if (kDebugMode) debugPrint('🔄 No products found, forcing inventory refresh...');
        await InventorySyncService.refreshAllInventory();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to ensure products available: $e');
    }
  }

  // 🚨 NEW: Set payment method
  void setPaymentMethod(String method) {
    selectedPaymentMethod = method;
    isOnlinePayment = method == 'UPI';
    notifyListeners();
  }

  // 🚨 NEW: Generate bill preview (does NOT save)
  Future<void> generateBillPreview() async {
    isGeneratingBill = true;
    notifyListeners();
    
    // Simulate PDF generation delay
    await Future.delayed(const Duration(milliseconds: 500));
    
    isGeneratingBill = false;
    notifyListeners();
  }
}
