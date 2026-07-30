import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';

class PurchaseOrdersPage extends StatefulWidget {
  const PurchaseOrdersPage({super.key});
  @override
  State<PurchaseOrdersPage> createState() => _PurchaseOrdersPageState();
}

class _PurchaseOrdersPageState extends State<PurchaseOrdersPage> {
  bool _loading = true;
  List<dynamic> _orders = [];

  static const _bg = Color(0xFF1A1A2E);
  static const _card = Color(0xFF16213E);

  @override
  void initState() {
    super.initState();
    _fetchOrders();
  }

  Future<void> _fetchOrders() async {
    try {
      // Load from local storage first for immediate response (offline-first)
      final prefs = await SharedPreferences.getInstance();
      final localPOData = prefs.getString('purchase_orders_data');
      
      if (localPOData != null && localPOData.isNotEmpty) {
        try {
          final d = jsonDecode(localPOData);
          setState(() => _orders = d is List ? d : (d['orders'] ?? []));
          debugPrint('✅ Purchase orders loaded from local storage');
        } catch (e) {
          debugPrint('⚠️ Error parsing local PO data: $e');
        }
      }
      
      // Then sync with backend for latest data
      try {
        final res = await ApiClient.getJson('/purchase-orders/');
        if (res.statusCode == 200) {
          final d = jsonDecode(res.body);
          setState(() => _orders = d is List ? d : (d['orders'] ?? []));
          // Save to local storage for offline use
          await prefs.setString('purchase_orders_data', json.encode(d));
          debugPrint('✅ Purchase orders synced from backend');
        }
      } catch (e) {
        debugPrint('⚠️ Backend PO sync failed, using local data: $e');
        // Keep using local data if backend sync fails
      }
    } catch (e) {
      debugPrint('❌ PO fetch error: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Color _statusColor(String status) {
    switch (status.toUpperCase()) {
      case 'DELIVERED': return Colors.greenAccent;
      case 'CANCELLED': return Colors.redAccent;
      default: return Colors.orangeAccent;
    }
  }

  Future<void> _markDelivered(dynamic poId) async {
    try {
      await ApiClient.postJson('/purchase-orders/$poId/mark-delivered', {});
      // Sync with backend and refresh local data
      await _fetchOrders();
    } catch (e) {
      debugPrint('⚠️ Failed to mark PO as delivered: $e');
      // Still refresh local data even if backend sync fails
      await _fetchOrders();
    }
  }

  Future<void> _cancelPO(dynamic poId) async {
    await ApiClient.postJson('/purchase-orders/$poId/cancel', {});
    _fetchOrders();
  }

  void _showCreatePO() {
    final supplierC = TextEditingController();
    final amountC = TextEditingController();
    final notesC = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New Purchase Order', style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            _field(supplierC, 'Supplier Name'),
            const SizedBox(height: 12),
            _field(amountC, 'Total Amount', numeric: true),
            const SizedBox(height: 12),
            _field(notesC, 'Notes / Items'),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  await ApiClient.postJson('/purchase-orders/', {
                    'supplier_name': supplierC.text,
                    'total_amount': double.tryParse(amountC.text) ?? 0,
                    'notes': notesC.text,
                    'items': [],
                  });
                  if (ctx.mounted) Navigator.pop(ctx);
                  _fetchOrders();
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.indigoAccent, padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text('Create PO', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, {bool numeric = false}) {
    return TextField(
      controller: c,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: Colors.white10,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _card,
        title: Text('Purchase Orders', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.indigoAccent,
        onPressed: _showCreatePO,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.indigoAccent))
          : RefreshIndicator(
              onRefresh: _fetchOrders,
              child: _orders.isEmpty
                  ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.receipt_long, color: Colors.white24, size: 80),
                      const SizedBox(height: 16),
                      Text('No purchase orders yet', style: GoogleFonts.poppins(color: Colors.white38)),
                    ]))
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _orders.length,
                      itemBuilder: (ctx, i) {
                        final po = _orders[i];
                        final status = (po['status'] ?? 'PENDING').toString().toUpperCase();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                              Text('PO #${po['id'] ?? i + 1}', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(color: _statusColor(status).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
                                child: Text(status, style: GoogleFonts.poppins(color: _statusColor(status), fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                            ]),
                            const SizedBox(height: 8),
                            Text(po['supplier_name']?.toString() ?? 'Supplier', style: GoogleFonts.poppins(color: Colors.white70)),
                            Text('Rs ${po['total_amount']?.toString() ?? '0'}', style: GoogleFonts.poppins(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 18)),
                            if (status == 'PENDING') ...[
                              const SizedBox(height: 12),
                              Row(children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () => _markDelivered(po['id']),
                                    icon: const Icon(Icons.check, size: 16),
                                    label: const Text('Delivered'),
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () => _cancelPO(po['id']),
                                    icon: const Icon(Icons.close, size: 16),
                                    label: const Text('Cancel'),
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                                  ),
                                ),
                              ]),
                            ],
                          ]),
                        );
                      },
                    ),
            ),
    );
  }
}
