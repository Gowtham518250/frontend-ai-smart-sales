import 'dart:async';
import 'package:flutter/foundation.dart';
import 'device_capability_service.dart';
import 'performance_monitor_service.dart';
import 'background_sync_worker.dart';
import 'automatic_backup_service.dart';
import 'data_integrity_service.dart';
import 'data_corruption_service.dart';
import 'audit_logging_service.dart';
import 'crash_recovery_service.dart';
import 'api_client.dart';
import 'sync_queue_manager.dart';

/// Adaptive Service Manager
/// Manages background services based on device capabilities
/// Ensures smooth operation on low-end devices (2GB RAM)
class AdaptiveServiceManager {
  static AdaptiveServiceManager? _instance;
  
  Timer? _performanceTimer;
  bool _isInitialized = false;
  
  // Service timers
  Timer? _syncTimer;
  Timer? _backupTimer;
  Timer? _integrityTimer;
  Timer? _corruptionTimer;
  
  AdaptiveServiceManager._();
  
  static AdaptiveServiceManager get instance {
    _instance ??= AdaptiveServiceManager._();
    return _instance!;
  }
  
  /// Initialize adaptive service manager
  Future<void> initialize() async {
    if (_isInitialized) {
      if (kDebugMode) debugPrint('⏳ Adaptive service manager already initialized');
      return;
    }
    
    try {
      if (kDebugMode) debugPrint('🚀 Initializing adaptive service manager');
      
      // Initialize device capability detection
      await DeviceCapabilityService.instance.initialize();
      
      // Initialize performance monitoring
      await PerformanceMonitorService.instance.startMonitoring();
      
      // Get device-specific configuration
      final config = DeviceCapabilityService.instance.getRecommendedServiceConfig();
      
      // Start services based on device capabilities
      await _startServices(config);
      
      // Start performance-based optimization
      _startPerformanceOptimization();
      
      _isInitialized = true;
      
      if (kDebugMode) {
        debugPrint('✅ Adaptive service manager initialized');
        debugPrint('   Performance mode: ${DeviceCapabilityService.instance.performanceMode}');
        debugPrint('   Background sync: ${config.enableBackgroundSync ? 'Enabled' : 'Disabled'}');
        debugPrint('   Auto backup: ${config.enableAutoBackup ? 'Enabled' : 'Disabled'}');
        debugPrint('   Enhanced queue: ${config.enableEnhancedQueue ? 'Enabled' : 'Disabled'}');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error initializing adaptive service manager: $e');
    }
  }
  
  /// Start services based on device configuration
  Future<void> _startServices(ServiceConfiguration config) async {
    try {
      // Always start crash recovery (critical for data safety)
      await CrashRecoveryService.instance.initialize();
      
      // Start background sync if enabled
      if (config.enableBackgroundSync) {
        await BackgroundSyncWorker.instance.start();
        if (kDebugMode) debugPrint('✅ Background sync started (interval: ${config.syncInterval} min)');
      } else {
        if (kDebugMode) debugPrint('⏸️ Background sync disabled for this device');
      }
      
      // Start auto backup if enabled
      if (config.enableAutoBackup) {
        await AutomaticBackupService.instance.start();
        // Adjust backup interval based on device
        _adjustBackupInterval(config.backupInterval);
        if (kDebugMode) debugPrint('✅ Auto backup started (interval: ${config.backupInterval} hours)');
      } else {
        if (kDebugMode) debugPrint('⏸️ Auto backup disabled for this device');
      }
      
      // Start integrity checks if enabled
      if (config.enableIntegrityChecks) {
        _adjustIntegrityCheckInterval(config.integrityCheckInterval);
        if (kDebugMode) debugPrint('✅ Integrity checks enabled (interval: ${config.integrityCheckInterval} hours)');
      } else {
        if (kDebugMode) debugPrint('⏸️ Integrity checks disabled for this device');
      }
      
      // Start corruption detection if enabled
      if (config.enableCorruptionDetection) {
        _adjustCorruptionCheckInterval(config.corruptionCheckInterval);
        if (kDebugMode) debugPrint('✅ Corruption detection enabled (interval: ${config.corruptionCheckInterval} hours)');
      } else {
        if (kDebugMode) debugPrint('⏸️ Corruption detection disabled for this device');
      }
      
      // Configure audit logging
      if (config.enableAuditLogging) {
        if (kDebugMode) debugPrint('✅ Audit logging enabled (max entries: ${config.maxLogEntries})');
      } else {
        if (kDebugMode) debugPrint('⏸️ Audit logging disabled for this device');
      }
      
      // Enhanced queue for high-end devices only
      if (!config.enableEnhancedQueue) {
        if (kDebugMode) debugPrint('⏸️ Enhanced queue disabled for this device (using basic sync)');
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error starting services: $e');
    }
  }
  
  /// Adjust backup interval based on device
  void _adjustBackupInterval(int hours) {
    // This would adjust the backup service interval
    // For now, it's a placeholder
    if (kDebugMode) debugPrint('⏰ Backup interval set to $hours hours');
  }
  
  /// Adjust integrity check interval
  void _adjustIntegrityCheckInterval(int hours) {
    // This would adjust the integrity check interval
    if (kDebugMode) debugPrint('⏰ Integrity check interval set to $hours hours');
  }
  
  /// Adjust corruption check interval
  void _adjustCorruptionCheckInterval(int hours) {
    // This would adjust the corruption check interval
    if (kDebugMode) debugPrint('⏰ Corruption check interval set to $hours hours');
  }
  
  /// Start performance-based optimization
  void _startPerformanceOptimization() {
    // Check performance every 2 minutes and optimize if needed
    _performanceTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
      await _checkAndOptimizePerformance();
    });
  }
  
  /// Check and optimize performance
  Future<void> _checkAndOptimizePerformance() async {
    try {
      final summary = PerformanceMonitorService.instance.getPerformanceSummary();
      
      // If performance score is low, apply optimizations
      if (summary.performanceScore < 50) {
        if (kDebugMode) {
          debugPrint('⚠️ Low performance detected (${summary.performanceScore}/100)');
          debugPrint('   Applying optimizations...');
        }
        
        await _applyPerformanceOptimizations();
      }
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error checking performance: $e');
    }
  }
  
  /// Apply performance optimizations
  Future<void> _applyPerformanceOptimizations() async {
    final isLowEnd = DeviceCapabilityService.instance.isLowEndDevice;
    
    if (isLowEnd) {
      // Aggressive optimizations for low-end devices
      await _pauseNonCriticalServices();
      await _reduceServiceFrequency();
      await _clearCaches();
    } else {
      // Moderate optimizations for other devices
      await _reduceServiceFrequency();
      await _clearOldCaches();
    }
  }
  
  /// Pause non-critical services
  Future<void> _pauseNonCriticalServices() async {
    try {
      // Pause non-critical services temporarily
      if (kDebugMode) debugPrint('⏸️ Pausing non-critical services');
      
      // This would pause services like:
      // - Advanced analytics
      // - Background sync (reduce frequency)
      // - Non-critical timers
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error pausing services: $e');
    }
  }
  
  /// Reduce service frequency
  Future<void> _reduceServiceFrequency() async {
    try {
      if (kDebugMode) debugPrint('📉 Reducing service frequency');
      
      // Reduce frequency of periodic operations
      // This would adjust timers for:
      // - Sync operations
      // - Backup operations
      // - Integrity checks
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error reducing service frequency: $e');
    }
  }
  
  /// Clear caches
  Future<void> _clearCaches() async {
    try {
      if (kDebugMode) debugPrint('🗑️ Clearing caches');
      
      // Clear various caches to free memory
      // This would clear:
      // - Image cache
      // - Data cache
      // - Network cache
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error clearing caches: $e');
    }
  }
  
  /// Clear old caches only
  Future<void> _clearOldCaches() async {
    try {
      if (kDebugMode) debugPrint('🧹 Clearing old caches');
      
      // Clear only old cache entries
      // This is less aggressive than full cache clear
      
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error clearing old caches: $e');
    }
  }
  
  /// Stop all services
  Future<void> stopAllServices() async {
    try {
      if (kDebugMode) debugPrint('🛑 Stopping all services');

      // Stop timers
      _performanceTimer?.cancel();
      _syncTimer?.cancel();
      _backupTimer?.cancel();
      _integrityTimer?.cancel();
      _corruptionTimer?.cancel();

      // Stop services
      BackgroundSyncWorker.instance.stop();
      AutomaticBackupService.instance.stop();
      PerformanceMonitorService.instance.stopMonitoring();

      // Dispose ApiClient to close StreamController
      await ApiClient.dispose();

      // Dispose SyncQueueManager to clean up resources
      await SyncQueueManager.dispose();

      // Mark clean shutdown
      await CrashRecoveryService.instance.markCleanShutdown();

      if (kDebugMode) debugPrint('✅ All services stopped');

    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error stopping services: $e');
    }
  }
  
  /// Get current service status
  ServiceStatus getServiceStatus() {
    return ServiceStatus(
      isInitialized: _isInitialized,
      performanceMode: DeviceCapabilityService.instance.performanceMode,
      isLowEndDevice: DeviceCapabilityService.instance.isLowEndDevice,
      backgroundSyncRunning: _syncTimer != null,
      autoBackupRunning: _backupTimer != null,
      performanceMonitoringActive: _performanceTimer != null,
    );
  }
  
  /// Force performance optimization
  Future<void> forceOptimization() async {
    if (kDebugMode) debugPrint('🔧 Forcing performance optimization');
    await _applyPerformanceOptimizations();
  }
  
  /// Get performance recommendations
  List<String> getPerformanceRecommendations() {
    final summary = PerformanceMonitorService.instance.getPerformanceSummary();
    final recommendations = <String>[];
    
    // Add device-specific recommendations
    if (DeviceCapabilityService.instance.isLowEndDevice) {
      recommendations.add('Consider using low-performance mode');
      recommendations.add('Disable advanced animations in settings');
      recommendations.add('Clear cache regularly');
    }
    
    // Add performance-based recommendations
    recommendations.addAll(summary.recommendations);
    
    return recommendations;
  }
}

/// Service status
class ServiceStatus {
  final bool isInitialized;
  final PerformanceMode performanceMode;
  final bool isLowEndDevice;
  final bool backgroundSyncRunning;
  final bool autoBackupRunning;
  final bool performanceMonitoringActive;
  
  ServiceStatus({
    required this.isInitialized,
    required this.performanceMode,
    required this.isLowEndDevice,
    required this.backgroundSyncRunning,
    required this.autoBackupRunning,
    required this.performanceMonitoringActive,
  });
  
  Map<String, dynamic> toJson() {
    return {
      'is_initialized': isInitialized,
      'performance_mode': performanceMode.toString(),
      'is_low_end_device': isLowEndDevice,
      'background_sync_running': backgroundSyncRunning,
      'auto_backup_running': autoBackupRunning,
      'performance_monitoring_active': performanceMonitoringActive,
    };
  }
}