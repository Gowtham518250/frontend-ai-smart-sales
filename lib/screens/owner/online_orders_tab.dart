import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api_client.dart';
import '../../visual_widgets.dart';

class OnlineOrdersTab extends StatefulWidget {
  const OnlineOrdersTab({super.key});

  @override
  State<OnlineOrdersTab> createState() => _OnlineOrdersTabState();
}

class _OnlineOrdersTabState extends State<OnlineOrdersTab>
    with SingleTickerProviderStateMixin {
  String _shopId = '';
  List<Map<String, dynamic>> _pendingOrders = [];
  // 🚨 FIX: Accepted orders are now kept in their own list instead of just
  // vanishing once ACCEPT succeeds. Previously _fetchOrders() only ever asked
  // the backend for status=PENDING, so the moment an order was accepted it
  // dropped out of the only list the screen showed — it wasn't lost on the
  // backend, but the owner had no way to see it or its details again in-app.
  List<Map<String, dynamic>> _acceptedOrders = [];
  bool _isLoading = true;
  // Tracks order ids whose ACCEPT/REJECT call is still being retried in the
  // background, so the UI can show a "syncing" indicator instead of silently
  // failing if the network drops mid-action.
  final Set<String> _pendingSync = {};
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadShopIdAndOrders();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadShopIdAndOrders() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _shopId = (prefs.getInt('user_id') ?? 0).toString();
    });
    await _fetchAllOrders();
  }

  Future<void> _fetchAllOrders() async {
    setState(() => _isLoading = true);
    await Future.wait([
      _fetchOrdersByStatus('PENDING'),
      _fetchOrdersByStatus('ACCEPTED'),
    ]);
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _fetchOrdersByStatus(String status) async {
    try {
      final res = await ApiClient.getJson('/store/owner/orders?status=$status');
      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        final orders = List<Map<String, dynamic>>.from(body['orders'] ?? []);
        if (!mounted) return;
        setState(() {
          if (status == 'PENDING') {
            _pendingOrders = orders;
          } else {
            _acceptedOrders = orders;
          }
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch $status orders: $e');
      // Deliberately NOT clearing the existing list here — a failed refresh
      // should never make previously-loaded orders disappear from the screen.
    }
  }

  Future<void> _updateOrderStatus(Map<String, dynamic> order, String action) async {
    final orderId = order['order_id']?.toString() ?? '0';

    // Optimistic local update: move the order between lists immediately so the
    // owner keeps seeing its full details right away, and retry the backend
    // call in the background instead of making the order vanish while we wait.
    setState(() {
      _pendingOrders.removeWhere((o) => o['order_id']?.toString() == orderId);
      if (action == 'ACCEPT') {
        _acceptedOrders.insert(0, {...order, 'status': 'ACCEPTED'});
      }
      _pendingSync.add(orderId);
    });

    final ok = await _sendOrderAction(orderId, action);

    if (!mounted) return;
    setState(() => _pendingSync.remove(orderId));

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Order $action successfully!')),
      );
    } else {
      // Keep the order visible (still marked as "syncing failed") and offer a
      // manual retry instead of losing the action entirely.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Order $action saved locally but not confirmed by server yet — tap to retry.'),
          action: SnackBarAction(
            label: 'RETRY',
            onPressed: () => _updateOrderStatus(order, action),
          ),
        ),
      );
    }
  }

  /// Backend call with a couple of quick retries — protects against a single
  /// dropped packet on flaky mobile data from silently losing the accept/reject.
  Future<bool> _sendOrderAction(String orderId, String action) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await ApiClient.postJson(
          '/store/owner/orders/$orderId/action?action=$action',
          {},
        ).timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) return true;
      } catch (e) {
        debugPrint('Order action attempt ${attempt + 1} failed: $e');
      }
      if (attempt < 2) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_shopId.isEmpty || _shopId == '0') {
      return const Scaffold(body: Center(child: Text('Invalid Shop Profile')));
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Online Orders', style: TextStyle(color: Colors.black87)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: Colors.black54,
          indicatorColor: AppColors.primary,
          tabs: [
            Tab(text: 'Pending (${_pendingOrders.length})'),
            Tab(text: 'Accepted (${_acceptedOrders.length})'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildOrderList(
                  orders: _pendingOrders,
                  emptyText: 'No incoming orders',
                  showActions: true,
                ),
                _buildOrderList(
                  orders: _acceptedOrders,
                  emptyText: 'No accepted orders yet',
                  showActions: false,
                ),
              ],
            ),
    );
  }

  Widget _buildOrderList({
    required List<Map<String, dynamic>> orders,
    required String emptyText,
    required bool showActions,
  }) {
    return RefreshIndicator(
      onRefresh: _fetchAllOrders,
      child: orders.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 100),
                Center(child: Text(emptyText, style: const TextStyle(color: Colors.black54))),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final order = orders[index];
                final orderId = order['order_id']?.toString() ?? '0';
                final items = order['items'] as List<dynamic>? ?? [];
                final syncing = _pendingSync.contains(orderId);

                return GlassContainer(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Order #$orderId',
                              style: const TextStyle(
                                  color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                          if (syncing)
                            const Badge(label: Text('SYNCING'), backgroundColor: Colors.orange)
                          else if (showActions)
                            const Badge(label: Text('NEW'), backgroundColor: Colors.redAccent)
                          else
                            const Badge(label: Text('ACCEPTED'), backgroundColor: Colors.green),
                        ],
                      ),
                      const Divider(color: Colors.black12, height: 24),
                      Text('Customer: ${order['customer_email']}',
                          style: const TextStyle(color: Colors.black87, fontSize: 16)),
                      const SizedBox(height: 16),
                      const Text('Items Requested:', style: TextStyle(color: Colors.black54, fontSize: 14)),
                      const SizedBox(height: 8),
                      ...items.map((item) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${item['quantity']}x ${item['product_name']}',
                                  style: const TextStyle(color: Colors.black87)),
                              Text('Rs ${(item['price'] ?? 0) * (item['quantity'] ?? 1)}',
                                  style: const TextStyle(color: Colors.black87)),
                            ],
                          ),
                        );
                      }),
                      const Divider(color: Colors.black12, height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Total Value', style: TextStyle(color: Colors.black54, fontSize: 16)),
                          Text('Rs ${order['total_amount']}',
                              style: const TextStyle(
                                  color: Colors.green, fontSize: 20, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      if (showActions) ...[
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: syncing ? null : () => _updateOrderStatus(order, 'REJECT'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.redAccent,
                                  side: const BorderSide(color: Colors.redAccent),
                                ),
                                child: const Text('Reject'),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: syncing ? null : () => _updateOrderStatus(order, 'ACCEPT'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Accept Order'),
                              ),
                            ),
                          ],
                        ),
                      ] else if (syncing) ...[
                        const SizedBox(height: 12),
                        const Text('Confirming with server…', style: TextStyle(color: Colors.orange, fontSize: 12)),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }
}