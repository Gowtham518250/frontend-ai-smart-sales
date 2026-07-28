import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'local_storage_service.dart';

class SyncQueueManager {
  static const String _queueBoxName = 'sync_queue_secure_v3';
  static Box? _box;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  
  // 🔒 CRITICAL: Global sync lock to prevent overlapping HTTP deductions
  static bool isSyncing = false;

  static Future<List<int>> _getHiveKey() async {
    const keyStr = 'hive_encryption_key';
    String? stored = await _secureStorage.read(key: keyStr);
    if (stored == null) {
      final key = Hive.generateSecureKey();
      await _secureStorage.write(key: keyStr, value: base64UrlEncode(key));
      return key;
    }
    return base64Url.decode(stored);
  }

  static Future<Box> _getBox() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('user_id') ?? prefs.getInt('userId');
    final String scopedName = (userId == null || userId == 0)
        ? '${_queueBoxName}_unauthenticated'
        : '${_queueBoxName}_$userId';
    
    if (_box != null && _box!.isOpen && _box!.name == scopedName) return _box!;
    
    final key = await _getHiveKey();
    _box = await Hive.openBox(scopedName, encryptionCipher: HiveAesCipher(key));

    // Auto-recover any sales saved while app was stuck in unauthenticated state
    if (userId != null && userId > 0) {
      try {
        final unauthName = '${_queueBoxName}_unauthenticated';
        final unauthBox = await Hive.openBox(unauthName, encryptionCipher: HiveAesCipher(key));
        if (unauthBox.isNotEmpty) {
          if (kDebugMode) debugPrint('📦 [SyncQueue] Recovering ${unauthBox.length} items from unauthenticated queue');
          for (final k in unauthBox.keys) {
            await _box!.put(k, unauthBox.get(k));
          }
          await unauthBox.clear();
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ [SyncQueue] Error recovering unauth queue: $e');
      }
    }

    return _box!;
  }

  /// Add item to sync queue
  static Future<void> enqueue(String action, Map<String, dynamic> data) async {
    try {
      final box = await _getBox();
      
      // Prevent unbounded queue growth (OOM protection)
      if (box.length >= 500) {
        if (kDebugMode) debugPrint('📦 [SyncQueue] Queue limit reached (500). Dropping oldest item.');
        if (box.isNotEmpty) {
          await box.delete(box.keys.first);
        }
      }

      // 🔧 FIX: Check if sale_id already exists in queue (idempotency)
      if (action == 'save_sale' && data.containsKey('sale_id')) {
        final saleId = data['sale_id'].toString();
        Map<String, dynamic>? existing;
        try {
          existing = box.values.cast<Map<String, dynamic>>().firstWhere(
            (item) => item['action'] == 'save_sale' && 
                       item['data']['sale_id']?.toString() == saleId,
          );
        } catch (e) {
          existing = null;
        }
        if (existing != null) {
          if (kDebugMode) debugPrint('📦 [SyncQueue] Sale $saleId already in queue - skipping duplicate');
          return;
        }
      }
      
      // Generate unique Action ID
      final String actionId = sha256.convert(utf8.encode('$action${json.encode(data)}${DateTime.now().microsecondsSinceEpoch}')).toString().substring(0, 16);

      final item = {
        'action_id': actionId,
        'action': action,
        'data': data,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'retries': 0,
      };

      await box.put(actionId, item);
      if (kDebugMode) debugPrint('📦 [SyncQueue] Queued: $action ($actionId)');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ [SyncQueue] Enqueue Error: $e');
    }
  }

  /// Get the oldest item from queue
  static Future<Map<String, dynamic>?> peek() async {
    try {
      final box = await _getBox();
      if (box.isEmpty) return null;
      
      // Hive values are not necessarily ordered by insertion if we use keys
      // But we can get the first one
      return Map<String, dynamic>.from(box.values.first);
    } catch (e) {
      return null;
    }
  }

  /// Remove item by ID
  static Future<void> remove(String actionId) async {
    final box = await _getBox();
    await box.delete(actionId);
  }

  /// Update item (e.g. increment retries)
  static Future<void> update(String actionId, Map<String, dynamic> item) async {
    final box = await _getBox();
    await box.put(actionId, item);
  }

  /// Get all pending items
  static Future<List<Map<String, dynamic>>> getAll() async {
    final box = await _getBox();
    return box.values.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<int> getQueueSize() async {
    final box = await _getBox();
    return box.length;
  }

  static Future<void> clearQueue() async {
    try {
      final box = await _getBox();
      await box.clear();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ clearQueue: $e');
    }
  }

  /// Drop cached box handle so next enqueue opens the correct user-scoped box.
  static Future<void> resetBoxReference() async {
    if (_box != null && _box!.isOpen) {
      try {
        await _box!.close();
      } catch (_) {}
    }
    _box = null;
  }
}
