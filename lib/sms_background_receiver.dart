// ============================================================================
// SMS_BACKGROUND_RECEIVER.DART
// Native SMS receiver that survives OEM app kill on Xiaomi/Vivo/OPPO/Realme
// ============================================================================

import 'package:flutter/services.dart';
import 'package:telephony/telephony.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as developer;
import 'dart:convert';

const MethodChannel _nativeChannel = MethodChannel('com.retail_mind/sms_receiver');

/// This handler is invoked when SMS is received in the background
/// The @pragma annotation ensures this stays available even if app is killed
/// Telephony requires: void backgroundMessageHandler(SmsMessage message)
@pragma('vm:entry-point')
Future<void> smsBackgroundHandler(SmsMessage message) async {
  final sender = message.address ?? 'Unknown';
  final body   = message.body    ?? '';
  
  developer.log(
    'SMS received in background: from=$sender, length=${body.length}',
    name: 'sms_receiver',
  );

  try {
    // Cache the SMS data for processing when app resumes
    final prefs = await SharedPreferences.getInstance();
    
    // Use a single JSON list for the queue to prevent key-mismatch bugs
    final raw = prefs.getString('bg_sms_queue') ?? '[]';
    final List<dynamic> queue = jsonDecode(raw);
    
    queue.add({
      'sender': sender,
      'body': body,
      'time': DateTime.now().millisecondsSinceEpoch,
    });
    
    await prefs.setString('bg_sms_queue', jsonEncode(queue));
    
    developer.log(
      'SMS added to background queue. Total pending: ${queue.length}',
      name: 'sms_receiver',
    );
  } catch (e) {
    developer.log('Error caching SMS: $e', name: 'sms_receiver', error: e);
  }
}

/// Register the native SMS receiver
Future<bool> registerSmsBroadcastReceiver() async {
  try {
    final result = await _nativeChannel.invokeMethod<bool>(
      'registerSmsReceiver',
    );
    developer.log(
      'SMS BroadcastReceiver registered: $result',
      name: 'sms_receiver',
    );
    return result ?? false;
  } on PlatformException catch (e) {
    developer.log(
      'Failed to register SMS receiver: ${e.message}',
      name: 'sms_receiver',
      error: e,
    );
    return false;
  }
}

/// Unregister the native SMS receiver
Future<bool> unregisterSmsBroadcastReceiver() async {
  try {
    final result = await _nativeChannel.invokeMethod<bool>(
      'unregisterSmsReceiver',
    );
    developer.log(
      'SMS BroadcastReceiver unregistered: $result',
      name: 'sms_receiver',
    );
    return result ?? false;
  } on PlatformException catch (e) {
    developer.log(
      'Failed to unregister SMS receiver: ${e.message}',
      name: 'sms_receiver',
      error: e,
    );
    return false;
  }
}

/// Retrieve and clear pending background SMS
Future<List<Map<String, String>>> getPendingBackgroundSms() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bg_sms_queue') ?? '[]';
    final List<dynamic> list = jsonDecode(raw);
    
    if (list.isEmpty) return [];
    
    // Clear queue immediately after reading
    await prefs.remove('bg_sms_queue');
    
    final result = list.map((e) => {
      'sender': (e['sender'] ?? '').toString(),
      'body': (e['body'] ?? '').toString(),
    }).toList();

    developer.log(
      'Retrieved ${result.length} pending background SMS',
      name: 'sms_receiver',
    );
    
    return result;
  } catch (e) {
    developer.log(
      'Error retrieving pending SMS: $e',
      name: 'sms_receiver',
      error: e,
    );
    return [];
  }
}

/// Check if this is an OEM-restricted device (Xiaomi/Vivo/OPPO/Realme)
Future<bool> isOemRestrictedDevice() async {
  try {
    final result = await _nativeChannel.invokeMethod<bool>(
      'isOemRestrictedDevice',
    );
    return result ?? false;
  } catch (_) {
    return false;
  }
}

/// Request battery optimization exemption status
Future<bool> isIgnoringBatteryOptimizations() async {
  try {
    final result = await _nativeChannel.invokeMethod<bool>(
      'isIgnoringBatteryOptimizations',
    );
    return result ?? false;
  } catch (_) {
    return false;
  }
}

/// Request battery optimization exemption
Future<void> requestBatteryOptimizationExemption() async {
  try {
    await _nativeChannel.invokeMethod(
      'requestBatteryOptimizationExemption',
    );
  } catch (e) {
    developer.log(
      'Failed to request battery exemption: $e',
      name: 'sms_receiver',
      error: e,
    );
  }
}
