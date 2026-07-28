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

class _OnlineOrdersTabState extends State<OnlineOrdersTab> {
  String _shopId = '';
  List<Map<String, dynamic>> _pendingOrders = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadShopIdAndOrders();
  }
  
  Future<void> _loadShopIdAndOrders() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _shopId = (prefs.getInt('user_id') ?? 0).toString();
    });
    await _fetchOrders();
  }

  Future<void> _fetchOrders() async {
    setState(() => _isLoading = true);
    try {
      final res = await ApiClient.getJson('/store/owner/orders?status=PENDING');
      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        setState(() {
          _pendingOrders = List<Map<String, dynamic>>.from(body['orders'] ?? []);
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch orders: $e');
    }
    setState(() => _isLoading = false);
  }

  Future<void> _updateOrderStatus(String orderId, String action) async {
    try {
      final res = await ApiClient.postJson('/store/owner/orders/$orderId/action?action=$action', {});
      if (res.statusCode == 200) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Order $action successfully!')));
        _fetchOrders();
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${res.body}')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
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
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _fetchOrders,
            child: _pendingOrders.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 100),
                    Center(child: Text('No incoming orders', style: TextStyle(color: Colors.black54))),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _pendingOrders.length,
                  itemBuilder: (context, index) {
                    final order = _pendingOrders[index];
                    final orderId = order['order_id']?.toString() ?? '0';
                    final items = order['items'] as List<dynamic>? ?? [];

                    return GlassContainer(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Order #$orderId', style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                              const Badge(label: Text('NEW'), backgroundColor: Colors.redAccent),
                            ],
                          ),
                          const Divider(color: Colors.black12, height: 24),
                          Text('Customer: ${order['customer_email']}', style: const TextStyle(color: Colors.black87, fontSize: 16)),
                          const SizedBox(height: 16),
                          const Text('Items Requested:', style: TextStyle(color: Colors.black54, fontSize: 14)),
                          const SizedBox(height: 8),
                          ...items.map((item) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('${item['quantity']}x ${item['product_name']}', style: const TextStyle(color: Colors.black87)),
                                  Text('Rs ${(item['price'] ?? 0) * (item['quantity'] ?? 1)}', style: const TextStyle(color: Colors.black87)),
                                ],
                              ),
                            );
                          }),
                          const Divider(color: Colors.black12, height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Total Value', style: TextStyle(color: Colors.black54, fontSize: 16)),
                              Text('Rs ${order['total_amount']}', style: const TextStyle(color: Colors.green, fontSize: 20, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => _updateOrderStatus(orderId, 'REJECT'),
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
                                  onPressed: () => _updateOrderStatus(orderId, 'ACCEPT'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primary,
                                    foregroundColor: Colors.white,
                                  ),
                                  child: const Text('Accept Order'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
          ),
    );
  }
}
