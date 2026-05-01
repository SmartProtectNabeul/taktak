enum TransferPhase { awaitingAccept, transferring, finished, cancelled, error }

class Device {
  Device({
    required this.id,
    required this.name,
    required this.isOnline,
    required this.distance,
    this.signalStrengthDbm,
  });

  /// BLE remote id string or synthetic id for signaling-only peers.
  final String id;
  final String name;
  /// True while we have a recent BLE advertisement or signaling peer heartbeat.
  final bool isOnline;
  /// Radar placement 0–1 away from center.
  final double distance;

  /// Optional RSSI snapshot for BLE devices.
  final int? signalStrengthDbm;
}

class RoomPeer {
  const RoomPeer({required this.peerId, required this.displayName});

  final String peerId;
  final String displayName;
}

class IncomingTransfer {
  IncomingTransfer({
    required this.transferId,
    required this.remotePeerId,
    required this.remoteName,
    required this.fileName,
    required this.sizeBytes,
    this.phase = TransferPhase.awaitingAccept,
    this.savedPath,
    this.errorMessage,
  });

  final String transferId;
  final String remotePeerId;
  final String remoteName;
  final String fileName;
  final int sizeBytes;
  TransferPhase phase;
  String? savedPath;
  String? errorMessage;

  /// 0–1 while copying bytes (WebRTC inbound).
  double progress01 = 0;

  double get sizeMB => sizeBytes / (1024 * 1024);

  IncomingTransfer copyWith({
    TransferPhase? phase,
    String? savedPath,
    String? errorMessage,
  }) {
    return IncomingTransfer(
      transferId: transferId,
      remotePeerId: remotePeerId,
      remoteName: remoteName,
      fileName: fileName,
      sizeBytes: sizeBytes,
      phase: phase ?? this.phase,
      savedPath: savedPath ?? this.savedPath,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class AccountSession {
  AccountSession({
    required this.email,
    required this.displayName,
    required this.saltBytes,
    required this.passwordVerifier,
  });

  final String email;
  final String displayName;
  final List<int> saltBytes;
  final List<int> passwordVerifier;
}
