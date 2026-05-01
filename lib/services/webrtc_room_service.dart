import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/models.dart';

class PendingInvite {
  PendingInvite({
    required this.transferId,
    required this.remotePeerId,
    required this.remoteName,
    required this.channel,
    required this.fileName,
    required this.sizeBytes,
  });

  final String transferId;
  final String remotePeerId;
  final String remoteName;
  final RTCDataChannel channel;
  final String fileName;
  final int sizeBytes;
}

class _ActiveReceive {
  _ActiveReceive({
    required this.transferId,
    required this.fileName,
    required this.sizeBytes,
    required this.channel,
  });

  final String transferId;
  final String fileName;
  final int sizeBytes;
  final RTCDataChannel channel;

  final BytesBuilder chunkBuilder = BytesBuilder(copy: false);
}

/// WebSocket signaling + WebRTC data channel transfers inside a TakTak room.
class WebrtcRoomService {
  WebrtcRoomService({
    required this.localPeerId,
    required this.displayName,
    required this.signalUrlWs,
    required this.onPeers,
    required this.onIncomingTransfer,
    required this.onTransferProgress,
    required this.onTransferFinished,
    required this.onLog,
    required this.onTransferRemoved,
    this.chunkBytes = 32 * 1024,
  });

  final String localPeerId;
  final String displayName;
  String signalUrlWs;

  final void Function(List<RoomPeer> peers) onPeers;

  /// Text invite before chunks (UI prompts accept/refuse).
  final void Function(IncomingTransfer incoming) onIncomingTransfer;

  final void Function(String transferId, double progress01) onTransferProgress;

  final void Function(String transferId, String savedPath, String senderPeerId) onTransferFinished;

  final void Function(String message) onLog;

  final void Function(String transferId) onTransferRemoved;

  final int chunkBytes;

  static Map<String, dynamic> get iceConfig => {
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {'urls': ['stun:stun.l.google.com:19302']},
        ],
      };

  Future<bool> _hasRemoteOffer(RTCPeerConnection? pc) async {
    if (pc == null) return false;
    final rd = await pc.getRemoteDescription();
    return rd?.sdp?.trim().isNotEmpty ?? false;
  }

  WebSocketChannel? _socket;
  StreamSubscription<Object?>? _socketSub;

  final Map<String, RTCPeerConnection> _pcs = {};
  /// Outbound TakTak data channel keyed by peer (caller side).
  final Map<String, RTCDataChannel> _senderDcByPeer = {};
  final Map<String, List<RTCIceCandidate>> _pendingIce = {};

  /// Completes when remote answers invite with accepted/refused.
  final Map<String, Completer<bool>> _inviteWaiters = {};

  final Map<String, PendingInvite> pendingInvites = {};
  /// One active chunked receive loop per TakTak data channel identity (remotePeerId suffices for MVP).
  final Map<String, _ActiveReceive?> _receiveByRemote = {};

  final List<RoomPeer> _peersVisible = [];

  final Uuid _uuid = const Uuid();

  Future<void> connectAndJoin(String roomCode) async {
    final code = roomCode.trim().toUpperCase();
    await disposePeersOnly();
    _peersVisible.clear();
    final uri = Uri.parse(signalUrlWs);
    _socket = WebSocketChannel.connect(uri);

    await Future<void>.delayed(Duration.zero);

    void send(dynamic m) =>
        _socket?.sink.add(m is String ? m : jsonEncode(m));

    send({
      'type': 'identify',
      'peerId': localPeerId,
      'displayName': displayName,
    });
    send({'type': 'joinRoom', 'roomId': code});

    _socketSub?.cancel();
    _socketSub = _socket!.stream.listen(_onIncomingSignal, onError: (_) {
      onLog('Signaling stream error.');
    });

    onLog('Signaling handshake sent for room "$code".');
  }

  Future<void> dispose() async {
    try {
      _socket?.sink.add(jsonEncode({'type': 'leaveRoom'}));
    } catch (_) {}
    await disposePeersOnly();

    await _socketSub?.cancel();
    _socketSub = null;
    await _socket?.sink.close();
    _socket = null;

    _peersVisible.clear();
    onPeers(const []);
  }

  Future<void> disposePeersOnly() async {
    for (final pc in _pcs.values) {
      await pc.close();
    }
    _pcs.clear();
    _senderDcByPeer.clear();
    _pendingIce.clear();
    pendingInvites.clear();
    _receiveByRemote.clear();
    _inviteWaiters.clear();
  }

  Future<void> respondToInvite(String transferId, bool accept) async {
    final inv = pendingInvites.remove(transferId);
    if (inv == null) return;

    if (!accept) {
      await inv.channel.send(
        RTCDataChannelMessage(
          jsonEncode({'phase': 'refused', 'transferId': transferId}),
        ),
      );
      onTransferRemoved(transferId);
      return;
    }

    await inv.channel.send(
      RTCDataChannelMessage(
        jsonEncode({'phase': 'accepted', 'transferId': transferId}),
      ),
    );

    _receiveByRemote[inv.remotePeerId] = _ActiveReceive(
      transferId: transferId,
      fileName: inv.fileName,
      sizeBytes: inv.sizeBytes,
      channel: inv.channel,
    );
  }

  Future<void> sendFile({
    required String remotePeerId,
    required String filePathAbsolute,
    void Function(double frac)? onBytesProgress,
  }) async {
    if (remotePeerId == localPeerId) {
      throw ArgumentError.value(remotePeerId, 'remotePeerId', 'cannot self-send');
    }

    final file = File(filePathAbsolute);
    if (!await file.exists()) {
      throw StateError('file missing');
    }
    final name = _safeBasename(file.path);
    final size = await file.length();

    await _ensureOutboundLink(remotePeerId);

    final dc = _senderDcByPeer[remotePeerId];
    if (dc == null) throw StateError('no data channel');

    final transferId = _uuid.v4();
    final waiter = Completer<bool>();
    _inviteWaiters[transferId] = waiter;

    await dc.send(
      RTCDataChannelMessage(
        jsonEncode({
          'phase': 'invite',
          'transferId': transferId,
          'name': name,
          'size': size,
          'fromPeer': localPeerId,
          'fromName': displayName,
        }),
      ),
    );

    final accepted =
        await waiter.future.timeout(const Duration(minutes: 10), onTimeout: () => false);
    _inviteWaiters.remove(transferId);
    if (!accepted) {
      throw StateError('remote refused invite or timed out');
    }

    var sentBytes = 0;
    await for (final slice in file.openRead()) {
      final buf = Uint8List.fromList(slice);
      sentBytes += buf.length;

      await dc.send(RTCDataChannelMessage.fromBinary(buf));

      if (sentBytes % (chunkBytes * 4) < chunkBytes || sentBytes >= size) {
        onBytesProgress?.call(size == 0 ? 1 : sentBytes / size);
      }

      await _backpressure(dc);
    }

    await dc.send(
      RTCDataChannelMessage(
        jsonEncode({'phase': 'eof', 'transferId': transferId}),
      ),
    );
    onLog('Finished sending "$name" ($size bytes) → $remotePeerId');
    onBytesProgress?.call(1);
  }

  Future<void> _ensureOutboundLink(String remotePeerId) async {
    var pc = _pcs[remotePeerId];

    RTCDataChannel? dc = _senderDcByPeer[remotePeerId];
    final negotiated = pc != null && await _hasRemoteOffer(pc);

    final existingOpen =
        dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen && negotiated;

    if (existingOpen) return;

    if (pc != null && dc != null) {
      final hasRemote = await _hasRemoteOffer(pc);
      final dcOpen = dc.state == RTCDataChannelState.RTCDataChannelOpen;


      if (!dcOpen || !hasRemote) {
        await disposePeer(remotePeerId);
        pc = null;
        dc = null;




      }




    }



    if (pc == null) {
      final created = await _createCallerPeer(remotePeerId);
      pc = created;

      final init = RTCDataChannelInit()..ordered = true;
      final outbound = await created.createDataChannel('taktak-file', init);
      dc = outbound;

      _senderDcByPeer[remotePeerId] = outbound;
      outbound.onMessage = (m) => _onOutboundAck(remotePeerId, m);

      final offer = await created.createOffer({});
      await created.setLocalDescription(offer);
      _relay(remotePeerId, {'type': 'offer', 'sdp': offer.sdp});
    }



    final outboundFinal = _senderDcByPeer[remotePeerId];

    final callerPc = _pcs[remotePeerId];


    if (outboundFinal == null || callerPc == null) {



      throw StateError('failed to negotiate outbound dc');


    }




    await _waitAnswerAndStable(callerPc, outboundFinal, remotePeerId);



    await _waitChannelOpen(outboundFinal, label: remotePeerId);


  }


  Future<void> _waitAnswerAndStable(
    RTCPeerConnection pc,
    RTCDataChannel dc,
    String remotePeerId,
  ) async {
    for (var i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 75));
      if (await _hasRemoteOffer(pc)) {
        await _refreshIceDrain(remotePeerId);
      }
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) break;
      if (pc.connectionState ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          pc.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        break;
      }
    }
    if (dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      onLog(
        '[webrtc] Waiting for outbound channel (${dc.state}). '
        '${pc.connectionState ?? '?'} ${pc.iceConnectionState ?? '?'} ${pc.signalingState ?? '?'}',
      );
    }
  }

  Future<RTCPeerConnection> _createCallerPeer(String remotePeerId) async {
    final pc = await createPeerConnection(WebrtcRoomService.iceConfig);
    pc.onIceCandidate = (ev) async {
      if ((ev.candidate ?? '').trim().isEmpty) return;
      _relay(remotePeerId, {
        'type': 'candidate',
        'candidate': {'candidate': ev.candidate!, 'sdpMid': ev.sdpMid, 'sdpMLineIndex': ev.sdpMLineIndex ?? -1},
      });
    };
    pc.onConnectionState = (RTCPeerConnectionState? s) =>
        debugPrint('[webrtc][$remotePeerId] pc-state=${s?.name ?? '?'} signaling=${pc.signalingState?.name ?? '?'} '
            'ice=${pc.iceConnectionState?.name ?? '?'}');
    _pcs[remotePeerId] = pc;
    return pc;
  }

  Future<RTCPeerConnection> _ensureCalleePeer(String remotePeerId) async {
    if (_pcs.containsKey(remotePeerId)) return _pcs[remotePeerId]!;
    final pc = await createPeerConnection(WebrtcRoomService.iceConfig);

    pc.onIceCandidate = (ev) async {
      if ((ev.candidate ?? '').trim().isEmpty) return;
      _relay(remotePeerId, {
        'type': 'candidate',
        'candidate': {'candidate': ev.candidate!, 'sdpMid': ev.sdpMid, 'sdpMLineIndex': ev.sdpMLineIndex ?? -1},
      });
    };

    pc.onDataChannel = (RTCDataChannel inbound) {
      if (inbound.label == 'taktak-file') {
        _wireInboundDc(remotePeerId, inbound);
      }
    };

    _pcs[remotePeerId] = pc;
    return pc;
  }

  Future<void> _handleOffer(String remotePeerId, String sdpText) async {
    await disposePeer(remotePeerId);

    final pc = await _ensureCalleePeer(remotePeerId);
    await pc.setRemoteDescription(RTCSessionDescription(sdpText, 'offer'));
    await _flushIce(remotePeerId);
    final answer = await pc.createAnswer({});
    await pc.setLocalDescription(answer);
    _relay(remotePeerId, {'type': 'answer', 'sdp': answer.sdp});
  }

  Future<void> _handleAnswer(String remotePeerId, String sdpText) async {
    final pc = _pcs[remotePeerId];
    if (pc == null) return;

    await pc.setRemoteDescription(RTCSessionDescription(sdpText, 'answer'));
    await _flushIce(remotePeerId);
  }

  Future<void> _enqueueIce(String remotePeerId, RTCIceCandidate cand) async {
    final pc = _pcs[remotePeerId];

    if (pc != null && await _hasRemoteOffer(pc)) {
      await pc.addCandidate(cand);
    }



    else {



      (_pendingIce[remotePeerId] ??= []).add(cand);



    }



  }


  Future<void> _flushIce(String remotePeerId) async => _refreshIceDrain(remotePeerId);

  Future<void> _refreshIceDrain(String remotePeerId) async {
    final pc = _pcs[remotePeerId];
    if (pc == null) return;
    final queued = _pendingIce.remove(remotePeerId);
    if (queued == null || queued.isEmpty) return;
    for (final cand in queued) {
      await pc.addCandidate(cand);
    }
  }

  Future<void> disposePeer(String remotePeerId) async {
    final pc = _pcs.remove(remotePeerId);
    await pc?.close();
    _pendingIce.remove(remotePeerId);
    _senderDcByPeer.remove(remotePeerId);
    _receiveByRemote.remove(remotePeerId);
  }

  void _relay(String toPeerId, Map<String, Object?> body) {
    _socket?.sink.add(jsonEncode({'type': 'signal', 'to': toPeerId, 'body': body}));
  }

  void _onInboundPacket(String remotePeerId, RTCDataChannelMessage msg, RTCDataChannel dc) {
    if (msg.isBinary) {
      final rx = _receiveByRemote[remotePeerId];
      if (rx == null || rx.channel != dc) {
        return;
      }
      final bytes = msg.binary;
      if (bytes.isEmpty) return;

      rx.chunkBuilder.add(bytes);
      final total = rx.sizeBytes <= 0 ? 1 : rx.sizeBytes;
      final p01 =
          rx.chunkBuilder.length > total //
              ? 1.0
              : rx.chunkBuilder.length / total;

      onTransferProgress(rx.transferId, p01.clamp(0, 1));
      return;
    }

    Map<String, Object?> m;
    try {
      m = Map<String, Object?>.from(jsonDecode(msg.text) as Map);
    } catch (_) {
      return;
    }

    switch (m['phase'] as String?) {
      case 'invite':
        final transferId = m['transferId'] as String?;
        final sz = ((m['size'] as num?)?.toInt()) ?? 0;
        final rawName = (m['name'] as String?) ?? 'incoming.bin';
        if (transferId == null || sz <= 0) return;

        String rn;
        try {
          rn = _peersVisible.firstWhere((p) => p.peerId == remotePeerId).displayName;
        } catch (_) {
          rn = remotePeerId;
        }

        final friendlyFrom = (m['fromName'] as String?) ?? rn;

        final incoming = IncomingTransfer(
          transferId: transferId,
          remotePeerId: remotePeerId,
          remoteName: friendlyFrom,
          fileName: _safeBasename(rawName),
          sizeBytes: sz,
        );
        pendingInvites[transferId] = PendingInvite(
          transferId: transferId,
          remotePeerId: remotePeerId,
          remoteName: friendlyFrom,
          channel: dc,
          fileName: incoming.fileName,
          sizeBytes: sz,
        );
        onIncomingTransfer(incoming);
        break;
      case 'eof':
        scheduleMicrotask(() => _finishReceive(remotePeerId, m['transferId'] as String?));
        break;
      case 'accepted':
      case 'refused':
        break;
      default:
        break;
    }
  }

  Future<void> _finishReceive(String remotePeerId, String? transferId) async {
    if (transferId == null) return;
    final rx = _receiveByRemote[remotePeerId];
    if (rx == null || rx.transferId != transferId) return;

    final root = Directory(
      path.join((await getApplicationDocumentsDirectory()).path, 'taktak-incoming'),
    );

    root.createSync(recursive: true);
    final out = _allocateUniqueIncomingPath(root.path, rx.fileName);
    await File(out).writeAsBytes(rx.chunkBuilder.toBytes());

    await rx.channel.send(RTCDataChannelMessage(jsonEncode({'phase': 'ack', 'transferId': transferId})));

    onTransferFinished(transferId, out, remotePeerId);
    _receiveByRemote[remotePeerId] = null;

    debugPrint('[webrtc] saved inbound $transferId → $out');
  }

  void _onOutboundAck(String _, RTCDataChannelMessage msg) {
    if (msg.isBinary) return;
    Map<String, Object?> body;
    try {
      body = Map<String, Object?>.from(jsonDecode(msg.text) as Map);
    } catch (_) {
      return;
    }
    switch (body['phase'] as String?) {
      case 'accepted':
        final id = body['transferId'] as String?;
        if (id == null) return;
        final c = _inviteWaiters[id];
        if (c != null && !(c.isCompleted)) c.complete(true);
        break;
      case 'refused':
        final id = body['transferId'] as String?;
        if (id == null) return;
        final c = _inviteWaiters[id];
        if (c != null && !(c.isCompleted)) c.complete(false);
        break;
      default:
        break;
    }
  }

  Future<void> _onIncomingSignal(dynamic raw) async {
    Map<String, Object?> msg;
    try {
      msg = Map<String, Object?>.from(jsonDecode(raw as String) as Map);
    } catch (_) {
      return;
    }

    switch (msg['type'] as String?) {
      case 'roomJoined':
        _replacePeers(Map<String, Object?>.from(msg));
        break;
      case 'peerJoined':
        final pj = Map<String, Object?>.from((msg['peer'] as Map?) ?? {});
        final id = pj['peerId'] as String?;
        if (id == null || id == localPeerId) break;
        if (!_peersVisible.any((p) => p.peerId == id)) {
          _peersVisible.add(
            RoomPeer(peerId: id, displayName: pj['displayName'] as String? ?? 'Peer'),
          );
          _broadcastPeersSnapshot();
        }
        break;
      case 'peerLeft':
        final id = msg['peerId'] as String?;
        if (id == null) break;
        _peersVisible.removeWhere((z) => z.peerId == id);
        await disposePeer(id);
        _broadcastPeersSnapshot();
        break;
      case 'signal':
        final Map<String, Object?> body = Map<String, Object?>.from((msg['body'] as Map?) ?? {});
        final from = msg['from'] as String?;
        final t = body['type'] as String?;
        switch (t) {
          case 'offer':
            if (from != null && body['sdp'] is String) {
              await _handleOffer(from, body['sdp']! as String);
            }
            break;
          case 'answer':
            if (from != null && body['sdp'] is String) {
              await _handleAnswer(from, body['sdp']! as String);
            }
            break;
          case 'candidate':
            if (from == null) break;
            final c = Map<String, Object?>.from((body['candidate'] as Map?) ?? {});
            final cand = (c['candidate'] as String?) ?? '';
            if (cand.isEmpty) break;
            final ice =
                RTCIceCandidate(cand, c['sdpMid'] as String?, ((c['sdpMLineIndex'] as num?)?.toInt()) ?? -1);

            await _enqueueIce(from, ice);
            break;
          default:
            break;
        }
        break;
      case 'error':
        onLog('Server: ${msg['message']}');
        break;
      default:
        break;
    }
  }

  void _replacePeers(Map<String, Object?> envelope) {
    final rawPeers = envelope['peers'] as List?;
    final mapped =
        (rawPeers ?? const <Object?>[])
            .whereType<Map>()
            .where((pm) => (pm['peerId'] ?? '') != localPeerId)
            .map(
              (pm) =>
                  RoomPeer(peerId: pm['peerId']! as String, displayName: (pm['displayName'] ?? 'Peer') as String),
            )
            .toList();
    _peersVisible
      ..clear()
      ..addAll(mapped);
    _peersVisible.sort((a, b) => a.displayName.compareTo(b.displayName));
    _broadcastPeersSnapshot();
    onLog('Room snapshot: ${_peersVisible.length} peers (others).');
  }

  void _broadcastPeersSnapshot() {
    onPeers(List.unmodifiable(_peersVisible.where((z) => z.peerId != localPeerId).toList(growable: false)));
  }

  Future<void> _waitChannelOpen(RTCDataChannel dc, {String label = ''}) async {
    for (var tick = 0; tick < 600; tick++) {
      switch (dc.state) {
        case RTCDataChannelState.RTCDataChannelOpen:
          return;
        case RTCDataChannelState.RTCDataChannelClosed:
        case RTCDataChannelState.RTCDataChannelClosing:
          throw StateError('data channel aborted before opening ($label)');
        default:
          await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    throw TimeoutException('Data channel timed out.', const Duration(seconds: 30));
  }

  Future<void> _backpressure(RTCDataChannel dc) async {
    for (var i = 0; i < 80; i++) {
      int amt;
      try {
        amt = dc.bufferedAmount ?? 0;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 4));
        continue;
      }
      if (amt < 786_432) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 24));
    }
  }




  void _wireInboundDc(String remotePeerId, RTCDataChannel dc) {
    dc.onMessage = (m) => _onInboundPacket(remotePeerId, m, dc);
  }

  String _safeBasename(String logical) => path.basename(logical).replaceAll(RegExp(r'[/\\:?*\"]'), '_');

  String _allocateUniqueIncomingPath(String rootFolder, String filename) {
    final base =
        filename.trim().isEmpty ? 'received.bin' : filename.trim();

    final ext = path.extension(base);
    final stripped = path.basenameWithoutExtension(base);

    String attempt = path.join(rootFolder, base);
    if (!File(attempt).existsSync()) return attempt;

    var i = 1;
    while (true) {
      attempt =
          '${path.join(rootFolder, stripped)}_$i${ext.isEmpty ? '' : ext}';
      if (!File(attempt).existsSync()) {
        return attempt;
      }

      i++;
    }
  }
}
