import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'api_client.dart';
import 'local_storage_service.dart';
import 'secure_token_storage.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';

class PurchaseOrderPage extends StatefulWidget {
  const PurchaseOrderPage({super.key});

  @override
  State<PurchaseOrderPage> createState() => _PurchaseOrderPageState();
}

class _PurchaseOrderPageState extends State<PurchaseOrderPage> {
  bool _loading = true;
  List<dynamic> _orders = [];

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    setState(() => _loading = true);
    final localOrders = await LocalStorageService.loadPurchaseOrders();
    setState(() => _orders = List<dynamic>.from(localOrders));

    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isNotEmpty) {
        final response = await ApiClient.getJson(
          '/api/purchase-orders',
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final backendOrders = (data is List) ? data : data['orders'] ?? [];
          final parsed = List<dynamic>.from(backendOrders);
          setState(() => _orders = parsed);
          await LocalStorageService.savePurchaseOrders(parsed);
        }
      }
    } catch (_) {
      // ignore network failures and keep cached orders.
    }
    setState(() => _loading = false);
  }

  Future<void> _saveLocalOrder(Map<String, dynamic> order) async {
    final orders = await LocalStorageService.loadPurchaseOrders();
    orders.insert(0, order);
    await LocalStorageService.savePurchaseOrders(orders);
    setState(() => _orders = List<dynamic>.from(orders));

    // 🔧 FIX: previously nothing here ever told the backend a purchase
    // order was created — it only ever lived in local (on-device) storage.
    // Enqueue it on the same durable, auto-retrying sync queue used for
    // sales, so it reaches the server even if we're offline right now.
    await SyncQueueManager.enqueue('create_purchase_order', order);
    unawaited(SyncService.processQueueSafe());
  }

  /// Mark purchase order as received and update inventory stock
  Future<void> _receiveOrder(Map<String, dynamic> order) async {
    try {
      final items = order['items'] as List? ?? [];
      final backendProducts = await LocalStorageService.loadBackendProducts();
      final localProducts = await LocalStorageService.loadLocalProducts();
      
      // Update backend products
      for (var item in items) {
        final name = item['product_name']?.toString().toUpperCase() ?? '';
        final qty = double.tryParse(item['quantity']?.toString() ?? '0') ?? 0;
        final idx = backendProducts.indexWhere(
            (p) => p['product_name']?.toString().toUpperCase() == name);
        
        if (idx != -1) {
          backendProducts[idx]['current_stock'] = 
              (double.tryParse(backendProducts[idx]['current_stock']?.toString() ?? '0') ?? 0) + qty;
        }
      }
      
      await LocalStorageService.saveBackendProducts(backendProducts);
      
      // Update order status
      order['status'] = 'RECEIVED';
      order['received_at'] = DateTime.now().toIso8601String();
      
      // Save updated orders
      final orders = await LocalStorageService.loadPurchaseOrders();
      final idx = orders.indexWhere((o) => 
          (o['supplier'] == order['supplier'] && o['created_at'] == order['created_at']) ||
          o['id'] == order['id']);
      if (idx != -1) {
        orders[idx] = order;
        await LocalStorageService.savePurchaseOrders(orders);
      }

      // 🔧 FIX: marking an order received previously only updated local
      // storage — the backend never learned about it, so purchase orders
      // stayed "PENDING" server-side forever. Enqueue the status change
      // the same durable way sales updates are enqueued.
      await SyncQueueManager.enqueue('receive_purchase_order', {
        'order_id': order['id'],
        'status': 'RECEIVED',
        'received_at': order['received_at'],
        'items': order['items'],
      });
      unawaited(SyncService.processQueueSafe());
      
      if (mounted) {
        await _loadOrders();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Stock updated from Purchase Order'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showCreateOrderDialog() {
    final supplierController = TextEditingController();
    final amountController = TextEditingController();
    final noteController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('New Purchase Order', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              TextField(
                controller: supplierController,
                decoration: InputDecoration(
                  labelText: 'Supplier',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Order Value (₹)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                decoration: InputDecoration(
                  labelText: 'Item / Note',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    final supplier = supplierController.text.trim();
                    final amount = double.tryParse(amountController.text.trim()) ?? 0.0;
                    if (supplier.isEmpty || amount <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Supplier and amount are required')),
                      );
                      return;
                    }

                    final order = {
                      'id': DateTime.now().millisecondsSinceEpoch.toString(),
                      'supplier': supplier,
                      'amount': amount,
                      'created_at': DateTime.now().toIso8601String(),
                      'status': 'PENDING',
                      'notes': noteController.text.trim(),
                    };

                    await _saveLocalOrder(order);
                    if (mounted) Navigator.pop(context);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Purchase order saved locally')),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Create Order'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> order) {
    final amount = (order['amount'] as num?)?.toDouble() ?? double.tryParse(order['amount']?.toString() ?? '0') ?? 0.0;
    final status = order['status']?.toString().toUpperCase() ?? 'PENDING';
    final createdAt = order['created_at']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 6))],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(order['supplier']?.toString() ?? 'Supplier', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(order['notes']?.toString() ?? 'No items specified', style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey[600])),
                      const SizedBox(height: 8),
                      Text('Created: ${createdAt.split('T').first}', style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey[500])),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('₹${amount.toStringAsFixed(0)}', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: status == 'RECEIVED' || status == 'COMPLETED' ? const Color(0xFF10B981).withValues(alpha: 0.12) : const Color(0xFFF59E0B).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(status, style: TextStyle(color: status == 'RECEIVED' || status == 'COMPLETED' ? const Color(0xFF10B981) : const Color(0xFFF59E0B), fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
            if (status == 'PENDING') ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.check_circle_rounded, size: 16),
                  label: const Text('Mark Received'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: () => _receiveOrder(order),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Purchase Orders'),
        backgroundColor: const Color(0xFF6366F1),
      ),
      body: RefreshIndicator(
        onRefresh: _loadOrders,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _orders.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No purchase orders yet. Tap + to create one and keep supplier orders tracked.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.poppins(fontSize: 15, color: Colors.grey[600]),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _orders.length,
                    itemBuilder: (_, idx) => _buildOrderCard(Map<String, dynamic>.from(_orders[idx] as Map)),
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        onPressed: _showCreateOrderDialog,
        child: const Icon(Icons.add_shopping_cart_rounded),
      ),
    );
  }
}