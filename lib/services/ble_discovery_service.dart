import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/models.dart';

/// Maps BLE scan results onto [Device]s for the radar UI.
class BleDiscoveryService {
  BleDiscoveryService();

  StreamSubscription<List<ScanResult>>? _sub;
  final Map<String, Device> _byId = {};
  VoidCallback? onDevicesChanged;

  bool get scanning => FlutterBluePlus.isScanningNow;

  /// RSSI roughly mapped onto the radar radius 0–1 (not calibrated distance).
  static double rssiToRadius(int rssi) {
    const minDb = -90;
    const maxDb = -45;
    if (rssi == 127 || rssi == 0) return 0.78;
    final clamped = rssi.clamp(minDb, maxDb);
    return 1 - (clamped - minDb) / (maxDb - minDb);
  }

  Future<bool> ensurePermissions() async {
    try {
      if (await FlutterBluePlus.isSupported == false) return false;

      await Permission.locationWhenInUse.request();
      if (defaultTargetPlatform == TargetPlatform.android) {
        await Permission.bluetoothScan.request();
        await Permission.bluetoothConnect.request();
      }
      return await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
    } catch (e, s) {
      debugPrint('[BLE] permission $e $s');
      return false;
    }
  }

  List<Device> get devices => _byId.values.toList(growable: false);

  Future<void> start() async {
    if (await FlutterBluePlus.isSupported == false) {
      debugPrint('[BLE] not supported');
      return;
    }

    final ok = await ensurePermissions();
    if (!ok) return;

    await FlutterBluePlus.adapterState.where((v) => v == BluetoothAdapterState.on).first;
    await FlutterBluePlus.stopScan();

    await _sub?.cancel();
    _sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final id = r.device.remoteId.str;
        final name = r.device.platformName.trim().isNotEmpty
            ? r.device.platformName.trim()
            : r.advertisementData.advName.trim().isNotEmpty
                ? r.advertisementData.advName.trim()
                : id;
        _byId[id] = Device(
          id: id,
          name: name,
          isOnline: true,
          distance: rssiToRadius(r.rssi).clamp(0.12, 0.94),
          signalStrengthDbm: r.rssi,
        );
      }
      onDevicesChanged?.call();
    });

    await FlutterBluePlus.startScan(androidUsesFineLocation: false);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _byId.clear();
    onDevicesChanged?.call();
  }

  Future<void> dispose() async => stop();
}
