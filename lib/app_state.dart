import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'models/models.dart';
import 'services/auth_store.dart';
import 'services/ble_discovery_service.dart';
import 'services/webrtc_room_service.dart';

class AppState extends ChangeNotifier {
  AppState({this.scaffoldMessengerKey});

  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  static const String _prefsHostKey = 'signal_url';
  static const String _prefsPeerUuid = 'local_peer_uuid';

  SharedPreferences? _prefs;
  BleDiscoveryService? _bleSvc;
  WebrtcRoomService? _webrtc;

  final AuthStore auth = AuthStore();

  AccountSession? account;
  bool isReceivingMode = true;
  bool isOnlineTransport = false;

  String signalingUrl = 'ws://127.0.0.1:8787/';
  String peerIdLocal = const Uuid().v4();

  String? currentRoom;
  List<RoomPeer> roomPeers = [];
  List<IncomingTransfer> incomingTransfers = [];
  String? selectedSendPeerId;

  final List<Device> bleDevicesLive = [];

  String get displayNameResolved => account?.displayName ?? 'Anonymous';

  void toast(String text) {
    scaffoldMessengerKey?.currentState?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> bootstrap({bool startBleRadiosWhenOffline = true}) async {
    _prefs = await SharedPreferences.getInstance();

    final storedWs = (_prefs!.getString(_prefsHostKey) ?? '').trim();
    if (storedWs.isNotEmpty) {
      signalingUrl = storedWs.endsWith('/') ? storedWs : '$storedWs/';
    }

    final storedId = (_prefs!.getString(_prefsPeerUuid) ?? '').trim();
    if (storedId.isEmpty) {
      peerIdLocal = const Uuid().v4();
      await _prefs!.setString(_prefsPeerUuid, peerIdLocal);
    } else {
      peerIdLocal = storedId;
    }

    _bleSvc ??=
        BleDiscoveryService()
          ..onDevicesChanged = () =>
              SchedulerBinding.instance.addPostFrameCallback((_) => _syncBle());

    notifyListeners();

    if (startBleRadiosWhenOffline && !isOnlineTransport) await startBleSweep();
  }

  void _syncBle() {
    bleDevicesLive
      ..clear()
      ..addAll(_bleSvc?.devices ?? const []);
    if (!isOnlineTransport) notifyListeners();
  }

  Future<void> persistSignalingUrl(String raw) async {
    if (_prefs == null) await bootstrap();
    var next = raw.trim();
    if (next.isEmpty) next = signalingUrl;
    signalingUrl = next.endsWith('/') ? next : '$next/';
    await _prefs!.setString(_prefsHostKey, signalingUrl);
    notifyListeners();

    await _webrtc?.dispose();
    _webrtc = null;

    if (isOnlineTransport && (currentRoom?.isNotEmpty ?? false)) {
      await reconnectRoom();
    }
  }

  Future<void> userFlippedOnlineToggle(bool desired) =>
      setOnlineTransport(desired, reconcileRoomAfterConnect: true);

  void _attachWebrtc() {
    _webrtc ??= WebrtcRoomService(
      localPeerId: peerIdLocal,
      displayName: displayNameResolved,
      signalUrlWs: signalingUrl,
      onPeers: (list) {
        roomPeers = list.where((x) => x.peerId != peerIdLocal).toList(growable: false);
        notifyListeners();
      },
      onIncomingTransfer: (invite) {
        incomingTransfers.insert(0, invite);
        notifyListeners();
      },
      onTransferProgress: (tid, frac) {
        for (final row in incomingTransfers) {
          if (row.transferId == tid) {
            row.progress01 = frac;
            row.phase = TransferPhase.transferring;
            break;
          }
        }
        notifyListeners();
      },
      onTransferFinished: (tid, saved, _) {
        for (final row in incomingTransfers) {
          if (row.transferId == tid) {
            row.phase = TransferPhase.finished;
            row.savedPath = saved;
            row.progress01 = 1;
            break;
          }
        }
        notifyListeners();
        toast('Saved ${path.basename(saved)}');
      },
      onLog: debugPrint,
      onTransferRemoved: (tid) {
        incomingTransfers.removeWhere((x) => x.transferId == tid);
        notifyListeners();
      },
    );
  }

  Future<void> setOnlineTransport(bool wantCloud, {bool reconcileRoomAfterConnect = false}) async {
    isOnlineTransport = wantCloud;
    notifyListeners();

    if (wantCloud) {
      await _bleSvc?.stop();
      bleDevicesLive.clear();
      if (reconcileRoomAfterConnect && (currentRoom?.isNotEmpty ?? false)) {
        await reconnectRoom();
      }
    } else {
      await _webrtc?.dispose();
      _webrtc = null;
      incomingTransfers.clear();
      roomPeers.clear();
      selectedSendPeerId = null;
      await startBleSweep();
    }

    notifyListeners();
  }

  Future<void> startBleSweep() async {
    if (_bleSvc == null || _prefs == null) await bootstrap();

    bleDevicesLive.clear();
    notifyListeners();

    await _bleSvc!.ensurePermissions();
    await _bleSvc!.stop();
    await _bleSvc!.start();
    _syncBle();
    notifyListeners();
  }

  String randomInviteCode() {
    const alphabet = 'ABCDEFGHJKMNPRTUWXYZ23456789';
    final rand = math.Random.secure();
    return List.generate(6, (_) => alphabet[rand.nextInt(alphabet.length)]).join();
  }

  Future<void> joinRoom(String codeRaw) async {
    final code = codeRaw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    if (code.length < 3) {
      toast('Rooms need ≥3 alphanumeric characters.');
      return;
    }

    currentRoom = code;
    await setOnlineTransport(true, reconcileRoomAfterConnect: false);

    notifyListeners();

    _attachWebrtc();
    _webrtc!.signalUrlWs = signalingUrl;
    await _webrtc!.connectAndJoin(code);

    toast('Room "$code" active.');
  }

  Future<void> reconnectRoom() async {
    final code = currentRoom?.trim();
    if (code == null || code.isEmpty) return;
    await joinRoom(code);
  }

  Future<void> leaveRoom() async {
    await _webrtc?.dispose();
    _webrtc = null;
    currentRoom = null;
    roomPeers.clear();
    selectedSendPeerId = null;
    incomingTransfers.clear();
    notifyListeners();

    if (!isOnlineTransport) await startBleSweep();
  }

  Future<String?> login(String unusedEmailGuess, String password) async {
    if (_prefs == null) await bootstrap();
    final row = await auth.verifySavedAccount(password: password, prefs: _prefs!);

    if (row == null) return 'Incorrect password.';
    account = row;
    notifyListeners();

    if (isOnlineTransport && (currentRoom?.isNotEmpty ?? false)) await reconnectRoom();
    toast('Hello ${row.displayName}.');
    return null;
  }

  Future<String?> register(String emailGuess, String displayNameGuess, String passwordGuess) async {
    if (_prefs == null) await bootstrap();
    if (passwordGuess.length < 8) return 'Password must be eight characters.';
    await auth.register(email: emailGuess, password: passwordGuess, displayName: displayNameGuess, prefs: _prefs!);
    await login(emailGuess, passwordGuess);
    return null;
  }

  Future<void> logout() async {
    account = null;

    incomingTransfers.clear();
    selectedSendPeerId = null;
    await leaveRoom();
    await setOnlineTransport(false);
    notifyListeners();
  }

  Future<void> acceptInvite(String tid) async {
    await _webrtc?.respondToInvite(tid, true);
    for (final row in incomingTransfers) {
      if (row.transferId == tid) {
        row.phase = TransferPhase.transferring;
        break;
      }
    }
    notifyListeners();
  }

  Future<void> refuseInvite(String tid) async {
    await _webrtc?.respondToInvite(tid, false);
    incomingTransfers.removeWhere((row) => row.transferId == tid);
    notifyListeners();
  }

  List<Device> get radarDots {
    if (isOnlineTransport) {
      if (roomPeers.isEmpty) return const [];
      return List<Device>.generate(roomPeers.length, (i) {
        final rp = roomPeers[i];
        final radar = BleDiscoveryService.rssiToRadius(rp.peerId.hashCode % 120);
        return Device(id: rp.peerId, name: rp.displayName, distance: radar, isOnline: true);
      });
    }

    final copy = [...bleDevicesLive];
    copy.sort((a, b) {
      final c = a.name.compareTo(b.name);
      return c == 0 ? a.id.compareTo(b.id) : c;
    });
    return copy;
  }

  Future<void> pickSendFile() async {
    if (!isOnlineTransport ||
        currentRoom == null ||
        currentRoom!.trim().isEmpty) {
      toast('Stay online with an active signaling room.');
      return;
    }

    final receiver =
        selectedSendPeerId ?? (roomPeers.isNotEmpty ? roomPeers.first.peerId : null);
    if (receiver == null) {
      toast('Select a signaling peer.');
      return;
    }

    try {
      final pick = await FilePicker.pickFiles(withData: false);
      final filePath = pick?.files.single.path;
      if (filePath == null || filePath.trim().isEmpty) return;

      _attachWebrtc();
      _webrtc!.signalUrlWs = signalingUrl;

      await _webrtc!.sendFile(remotePeerId: receiver, filePathAbsolute: filePath);
      toast('Send complete.');
    } catch (e) {
      toast('$e');
    }
  }

  void toggleReceivingMode(bool receiving) {
    isReceivingMode = receiving;
    notifyListeners();
  }

  void selectSendingPeer(String peerKey) {
    selectedSendPeerId = peerKey;
    notifyListeners();
  }

  void injectDebugIncomingInvite() {
    incomingTransfers.insert(
      0,
      IncomingTransfer(
        transferId: DateTime.now().millisecondsSinceEpoch.toString(),
        remotePeerId: 'debug-peer',
        remoteName: 'Debug peer',
        fileName: 'mock.zip',
        sizeBytes: 64 << 20,
      ),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    Future.microtask(() async {
      await _bleSvc?.dispose();
      await _webrtc?.dispose();
    });
    super.dispose();
  }
}
