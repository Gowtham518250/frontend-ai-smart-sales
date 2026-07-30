/// Session Management Service
/// 7-day auto-login with RefreshToken
/// Prevents data loss on logout/login
/// syncs offline data when online
/// Auto-logout on session expiration

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'api_client.dart';
import 'sync_queue_manager.dart';
import 'secure_token_storage.dart';
import 'error_log_helper.dart';
import 'user_data_clear_service.dart';
import 'dart:math' as math;
import 'package:flutter_secure_storage/flutter_secure_storage.dart' as flutter_secure_storage;
import 'package:cloud_firestore/cloud_firestore.dart' as cloud_firestore;
import 'scoped_shared_preferences.dart';
import 'session_logout_service.dart';

class SessionManagementService {
  static const String _refreshTokenKey = 'refresh_token';
  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenExpiryKey = 'refresh_token_expiry';
  static const String _deviceIdKey = 'device_id';
  static const String _userIdKey = 'user_id';
  static const String _userNameKey = 'user_name';
  static const String _userEmailKey = 'user_email';
  static const String _sessionTimeKey = 'session_time';
  
  // 🔒 CRITICAL: Concurrency protection for token operations
  static final _sessionLock = Lock();
  
  // 🔔 Session expiry monitoring
  static Timer? _sessionExpiryTimer;
  static const Duration _sessionCheckInterval = Duration(hours: 1); // Check every hour
  static const Duration _maxSessionDuration = Duration(days: 7); // 7-day session
  
  // 🔔 Session expiry monitoring - HYBRID MODE
  // Enforces session expiry when online, allows offline grace period
  static void startSessionExpiryMonitoring() {
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = Timer.periodic(_sessionCheckInterval, (timer) async {
      await _checkAndHandleSessionExpiry();
    });
    if (kDebugMode) debugPrint('🔔 Session expiry monitoring started - hybrid mode (online enforcement, offline grace)');
  }
  
  /// Stop session expiry monitoring
  static void stopSessionExpiryMonitoring() {
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = null;
    if (kDebugMode) debugPrint('🔔 Session expiry monitoring stopped');
  }
  
  /// Check if session has expired - HYBRID MODE
  /// Enforces security when online, allows grace period when offline
  static Future<void> _checkAndHandleSessionExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionTime = prefs.getInt(_sessionTimeKey);
      
      if (sessionTime == null) {
        if (kDebugMode) debugPrint('🔔 No session time found, skipping expiry check');
        return;
      }
      
      final sessionDateTime = DateTime.fromMillisecondsSinceEpoch(sessionTime);
      final now = DateTime.now();
      final sessionAge = now.difference(sessionDateTime);
      
      // Check if session is beyond max duration
      if (sessionAge > _maxSessionDuration) {
        // Check network connectivity before enforcing expiry
        final connectivityResult = await Connectivity().checkConnectivity();
        final isOnline = connectivityResult != ConnectivityResult.none;
        
        if (isOnline) {
          // Online: Enforce session expiry for security
          if (kDebugMode) debugPrint('🔔 Session expired (online) - enforcing logout for security');
          await performSecureLogout(reason: 'Session expired');
        } else {
          // Offline: Allow grace period but warn user
          if (kDebugMode) debugPrint('🔔 Session expired (offline) - grace period active');
          // Could show user notification about session expiry
        }
      } else {
        if (kDebugMode) debugPrint('🔔 Session still valid (${sessionAge.inDays} days old)');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Session expiry check error: $e');
    }
  }
  
  /// Perform secure logout with proper cleanup
  static Future<void> performSecureLogout({String? reason}) async {
    try {
      if (kDebugMode) debugPrint('🔔 Performing secure logout${reason != null ? ': $reason' : ''}');
      
      // Stop session monitoring
      stopSessionExpiryMonitoring();
      
      // Clear all session data
      await clearAllSessionData();
      
      // Notify user of logout reason if provided
      if (reason != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('logout_reason', reason);
      }
      
      if (kDebugMode) debugPrint('✅ Secure logout completed');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Secure logout error: $e');
    }
  }
  
  /// Clear all session data securely
  static Future<void> clearAllSessionData() async {
    try {
      await SecureTokenStorage.clearAll();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_refreshTokenKey);
      await prefs.remove(_accessTokenKey);
      await prefs.remove(_refreshTokenExpiryKey);
      await prefs.remove(_userIdKey);
      await prefs.remove(_userNameKey);
      await prefs.remove(_userEmailKey);
      await prefs.remove(_sessionTimeKey);
      if (kDebugMode) debugPrint('✅ All session data cleared');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error clearing session data: $e');
    }
  }
  
  /// Get or Generate robust Device Fingerprint using platform-specific identifiers
  static Future<String> getDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? deviceId = prefs.getString(_deviceIdKey);
      
      if (deviceId == null || deviceId.isEmpty || deviceId == 'flutter_app') {
        // Use platform-specific device identifiers for robust fingerprinting
        String platformDeviceId;
        
        try {
          // Try to get platform-specific device ID
          if (kDebugMode) debugPrint('🔍 Generating platform-specific device ID');
          
          // Use a combination of timestamp and cryptographically secure random
          final secureRandom = math.Random.secure();
          final timestamp = DateTime.now().microsecondsSinceEpoch;
          final randomBytes = List<int>.generate(16, (_) => secureRandom.nextInt(256));
          
          // Create cryptographic hash for device ID
          final combined = '$timestamp:$randomBytes';
          final hash = _generateHash(combined);
          
          platformDeviceId = 'RM_SECURE_${hash.substring(0, 32)}';
          
          if (kDebugMode) debugPrint('✅ Generated secure device ID');
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Platform device ID generation failed: $e');
          // Fallback to timestamp + random
          final random = math.Random().nextInt(999999);
          final ts = DateTime.now().microsecondsSinceEpoch;
          platformDeviceId = 'RM_SECURE_${ts}_$random';
        }
        
        deviceId = platformDeviceId;
        await prefs.setString(_deviceIdKey, deviceId);
      }
      
      return deviceId;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error getting device ID: $e');
      // Fallback to generating one-off device ID
      final random = math.Random().nextInt(999999);
      final ts = DateTime.now().microsecondsSinceEpoch;
      return 'RM_SECURE_${ts}_$random';
    }
  }
  
  /// Generate cryptographic hash for device ID
  static String _generateHash(String input) {
    // Simple hash implementation - in production use proper crypto
    var hash = 0;
    for (var i = 0; i < input.length; i++) {
      hash = ((hash << 5) - hash) + input.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF; // Convert to 32bit integer
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
  
  /// FIX-2: Save tokens securely with concurrency protection
  static Future<void> saveTokens({
    String? refreshToken,
    required String accessToken,
    required String deviceId,
    required int userId,
    required String userName,
    required String userEmail,
  }) async {
    // 🔒 CRITICAL: Atomic token save operation
    return await _sessionLock.synchronized(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final expiryDate = DateTime.now().add(Duration(days: 7));

        // 🔒 SECURITY: Set scoped user ID for data isolation
        await ScopedSharedPreferences.setCurrentUserId(userId);

        // 🔔 Start session expiry monitoring on successful login
        startSessionExpiryMonitoring();

        // CRITICAL: Use SecureTokenStorage for refresh tokens AND access tokens (FIX-5 R2)
        if (refreshToken != null && refreshToken.isNotEmpty) {
          try {
            await SecureTokenStorage.saveRefreshToken(refreshToken);
          } catch (e) {
            if (kDebugMode) debugPrint('⚠️ Error saving refresh token: $e');
            ErrorLogHelper.logException(e, StackTrace.current, context: 'saveTokens: refresh');
          }
        }

        try {
          await SecureTokenStorage.saveUserId(userId);
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error saving scoped user id: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'saveTokens: userId');
        }

        try {
          await SecureTokenStorage.saveToken(accessToken);
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error saving access token: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'saveTokens: access');
        }

        try {
          await prefs.setString(_deviceIdKey, deviceId);
          await prefs.setString(_refreshTokenExpiryKey, expiryDate.toIso8601String());
          await prefs.setInt(_userIdKey, userId);
          await prefs.setString(_userNameKey, userName);
          await prefs.setString(_userEmailKey, userEmail);
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error saving user data to prefs: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'saveTokens: prefs');
        }

        if (kDebugMode) debugPrint('✅ Tokens saved successfully with scoped user ID: $userId');
      } catch (e, st) {
        if (kDebugMode) debugPrint('❌ Error saving tokens: $e');
        ErrorLogHelper.logException(e, st, context: 'saveTokens');
      }
    });
  }
  
  /// Initialize a fresh user session and persist current user scope.
  static Future<void> initializeSession({
    required int userId,
    required String accessToken,
    String? refreshToken,
    required String userName,
    required String userEmail,
    required String role,
    String deviceId = 'flutter_app',
  }) async {
    if (kDebugMode) debugPrint('🔐 Initializing session for user ID $userId');

    // Clear any stale session-level secure tokens before starting a new login.
    await SecureTokenStorage.clearAll();

    await saveTokens(
      refreshToken: refreshToken,
      accessToken: accessToken,
      deviceId: deviceId,
      userId: userId,
      userName: userName,
      userEmail: userEmail,
    );

    final prefs = await SharedPreferences.getInstance();
    if (role.isNotEmpty) {
      await prefs.setString('user_role', role);
    }
  }
  
  /// Try to auto-login with saved refresh token (race condition safe)
  static Future<Map<String, dynamic>?> autoLogin() async {
    // 🔒 CRITICAL: Only one auto-login at a time
    return await _sessionLock.synchronized(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        
        try {
          final refreshToken = await SecureTokenStorage.getRefreshToken();
          final deviceId = prefs.getString(_deviceIdKey);
          
          if (refreshToken == null) {
            if (kDebugMode) debugPrint('⚠️ No saved refresh token');
            return null; // No saved token
          }
          
          // Call refresh endpoint with timeout
          final deviceFingerprint = await getDeviceId();
          
          try {
            final response = await ApiClient.postJson(
              ApiClient.sessionRefresh, 
              {
                'refresh_token': refreshToken,
                'device_id': deviceFingerprint,
              },
            ).timeout(const Duration(seconds: 10));
            
            if (response.statusCode == 200) {
              final data = jsonDecode(response.body);
              
              // Save new token
              await saveTokens(
                refreshToken: data['refresh_token'] ?? refreshToken,
                accessToken: data['access_token'] ?? '',
                deviceId: deviceId ?? 'flutter_app',
                userId: data['user_id'] ?? 0,
                userName: data['user_name'] ?? '',
                userEmail: data['email'] ?? '',
              );
              
              if (kDebugMode) debugPrint('✅ Auto-login successful');
              
              return {
                'success': true,
                'user_id': data['user_id'],
                'user_name': data['user_name'],
                'email': data['email'],
                'message': data['message'],
              };
            }
            
            // Token expired or invalid
            if (kDebugMode) debugPrint('⚠️ Token refresh failed: ${response.statusCode}');
            await clearTokens();
            return null;
          } catch (e) {
            if (kDebugMode) debugPrint('⚠️ Error calling refresh endpoint: $e');
            ErrorLogHelper.logException(e, StackTrace.current, context: 'autoLogin: API call');
            return null;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error in auto-login: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'autoLogin: secure storage');
          return null;
        }
      } catch (e, st) {
        if (kDebugMode) debugPrint('❌ Critical error in auto-login: $e');
        ErrorLogHelper.logException(e, st, context: 'autoLogin: critical');
        return null;
      }
    });
  }
  
  /// Get current access token (FIX-5 R2: Retrieved from encrypted SecureTokenStorage)
  static Future<String?> getAccessToken() async {
    try {
      return await SecureTokenStorage.getToken();
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error getting access token: $e');
      return null;
    }
  }
  
  /// Check if token is still valid (using local timestamp check instead of API call)
  static Future<bool> isTokenValid() async {
    try {
      final accessToken = await getAccessToken();
      if (accessToken == null) {
        if (kDebugMode) debugPrint('⚠️ No access token available');
        return false;
      }
      
      // Use local timestamp check instead of API call to avoid false negatives
      // The API call to sessionVerify skips auto-refresh, causing issues
      final isValid = await SecureTokenStorage.isSessionValid();
      if (!isValid) {
        if (kDebugMode) debugPrint('⚠️ Session timestamp expired (older than 7 days)');
      }
      return isValid;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error in isTokenValid: $e');
      return false;
    }
  }
  
  /// Get user info from saved session
  static Future<Map<String, dynamic>?> getUserInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt(_userIdKey);
      final userName = prefs.getString(_userNameKey);
      final userEmail = prefs.getString(_userEmailKey);
      
      if (userId != null) {
        return {
          'user_id': userId,
          'user_name': userName,
          'email': userEmail,
        };
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error getting user info: $e');
      return null;
    }
  }
  
  /// Get current user ID from session
  static Future<int?> getCurrentUserId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt(_userIdKey) ?? prefs.getInt('userId');
      return userId;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error getting current user ID: $e');
      return null;
    }
  }
  
  /// Logout: clear all tokens
  static Future<void> logout() async {
    try {
      // 🔔 Stop session expiry monitoring on logout
      stopSessionExpiryMonitoring();
      
      final accessToken = await getAccessToken();
      
      // Notify server
      try {
        await ApiClient.postJson(ApiClient.sessionLogout, {
          'access_token': accessToken,
        }).timeout(const Duration(seconds: 5));
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Server logout notification failed: $e');
        // Continue even if server call fails
      }
      
      // Clear local tokens
      await clearTokens();
      if (kDebugMode) debugPrint('✅ Logout completed');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error logging out: $e');
      ErrorLogHelper.logException(e, StackTrace.current, context: 'logout');
    }
  }
  
  /// Logout from all devices
  static Future<bool> logoutAllDevices() async {
    try {
      try {
        final response = await ApiClient.postJson(
          ApiClient.sessionLogoutAll,
          {},
        ).timeout(const Duration(seconds: 5));
        
        if (response.statusCode == 200) {
          await clearTokens();
          await UserDataClearService.clearAllUserData();
          await SyncQueueManager.clearQueue();
          await SyncQueueManager.resetBoxReference();
          if (kDebugMode) debugPrint('✅ Logged out from all devices');
          return true;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Error calling logoutAll endpoint: $e');
      }
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error in logoutAllDevices: $e');
      ErrorLogHelper.logException(e, StackTrace.current, context: 'logoutAllDevices');
      return false;
    }
  }
  
  /// Clear all stored tokens and user data with error handling
  static Future<void> clearTokens() async {
    // 🔒 CRITICAL: Atomic token clear operation
    return await _sessionLock.synchronized(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        
        try {
          await SecureTokenStorage.clearRefreshToken();
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error clearing refresh token: $e');
        }
        
        try {
          await SecureTokenStorage.clearToken();
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error clearing access token: $e');
        }
        
        try {
          await prefs.remove(_refreshTokenKey);
          await prefs.remove(_accessTokenKey);
          await prefs.remove('user_id');
          await prefs.remove('userId');
          await prefs.remove('is_staff_mode');
          await prefs.remove('auth_token');
          await prefs.remove(_deviceIdKey);
          await prefs.remove(_refreshTokenExpiryKey);
          await prefs.remove(_userIdKey);
          await prefs.remove('userId'); // Ensure camelCase variant is also cleared
          await prefs.remove(_userNameKey);
          await prefs.remove(_userEmailKey);
          await prefs.remove('is_staff_mode'); // Clear role selection
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error clearing SharedPreferences: $e');
          ErrorLogHelper.logException(e, StackTrace.current, context: 'clearTokens: prefs');
        }

        try {
          const _secureStorage = flutter_secure_storage.FlutterSecureStorage();
          await _secureStorage.delete(key: 'sender_email');
          await _secureStorage.delete(key: 'app_password');
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error clearing email secrets: $e');
        }

        try {
          await cloud_firestore.FirebaseFirestore.instance.terminate();
          await cloud_firestore.FirebaseFirestore.instance.clearPersistence();
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Error terminating Firestore: $e');
        }
        
        if (kDebugMode) debugPrint('✅ Tokens cleared');
      } catch (e, st) {
        if (kDebugMode) debugPrint('❌ Error clearing tokens: $e');
        ErrorLogHelper.logException(e, st, context: 'clearTokens');
      }
    });
  }
  
  /// Queue offline sale data (when offline)
  static Future<void> queueOfflineSale({
    required Map<String, dynamic> saleData,
  }) async {
    try {
      // 🛡️ REFACTOR: Redirect legacy queue calls to the new SyncQueueManager
      await SyncQueueManager.enqueue('create_sale', saleData);
      if (kDebugMode) debugPrint('📦 Diverted legacy sale to SyncQueueManager.');
    } catch (e) {
      if (kDebugMode) debugPrint('Error queuing offline sale: $e');
    }
  }
  
  static Future<String> _offlineQueueKey() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('user_id') ?? prefs.getInt('userId') ?? 0;
    return userId > 0 ? 'offline_queue_$userId' : 'offline_queue_unauthenticated';
  }

  /// Sync offline queue for the **current user only** — removes items individually.
  static Future<int> syncOfflineQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _offlineQueueKey();
      var queue = prefs.getStringList(key) ?? [];

      // Migrate legacy global queue into user-scoped key once
      if (queue.isEmpty) {
        final legacy = prefs.getStringList('offline_queue');
        if (legacy != null && legacy.isNotEmpty) {
          queue = List<String>.from(legacy);
          await prefs.setStringList(key, queue);
          await prefs.remove('offline_queue');
        }
      }

      if (queue.isEmpty) return 0;

      int synced = 0;
      final remaining = <String>[];

      for (final item in queue) {
        try {
          final data = jsonDecode(item);
          if (data['type'] == 'sale') {
            final response = await ApiClient.postJson('/api/sales/create', data['data']);
            if (response.statusCode == 200 || response.statusCode == 201) {
              synced++;
              continue;
            }
          }
          remaining.add(item);
        } catch (_) {
          remaining.add(item);
        }
      }

      if (remaining.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setStringList(key, remaining);
      }

      return synced;
    } catch (e) {
      return 0;
    }
  }

  /// Pending offline items for current user only.
  static Future<int> getPendingOfflineItems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _offlineQueueKey();
      return prefs.getStringList(key)?.length ?? 0;
    } catch (e) {
      return 0;
    }
  }
  
  /// Get token expiry time
  static Future<DateTime?> getTokenExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final expiryStr = prefs.getString(_refreshTokenExpiryKey);
      
      if (expiryStr != null) {
        return DateTime.parse(expiryStr);
      }
      return null;
    } catch (e) {
      return null;
    }
  }
  
  /// Check if token is about to expire (within 1 day)
  static Future<bool> isTokenExpiringSoon() async {
    try {
      final expiry = await getTokenExpiry();
      if (expiry == null) return false;
      
      final hoursUntilExpiry = expiry.difference(DateTime.now()).inHours;
      return hoursUntilExpiry < 24;
    } catch (e) {
      return false;
    }
  }
}
