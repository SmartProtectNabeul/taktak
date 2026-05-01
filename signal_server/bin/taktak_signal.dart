import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

/// Minimal room-based signaling: peers join rooms and exchange WebRTC SDP/ICE payloads.
///
/// Windows (no Git on PATH): from `signal_server/`, double-click **`run.bat`** or run `.\run_signal.ps1`.
/// Or: `%USERPROFILE%\Documents\flutter\bin\cache\dart-sdk\bin\dart.exe run bin/taktak_signal.dart [port]`
/// (defaults to port **8787**).
Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args.first) ?? 8787 : 8787;
  final hub = SignalHub();

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stderr.writeln('TakTak signaling on ws://${server.address.host}:$port/');

  await for (final request in server) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }

    final ws = await WebSocketTransformer.upgrade(request);
    final channel = IOWebSocketChannel(ws);
    hub.attach(ws, channel);
  }
}

final class PeerInfo {
  PeerInfo({
    required this.socket,
    required this.channel,
    required this.peerId,
    required this.displayName,
    required this.roomId,
  });

  WebSocket socket;
  IOWebSocketChannel channel;
  String peerId;
  String displayName;
  String roomId;

  void send(Map<String, Object?> obj) => channel.sink.add(jsonEncode(obj));
}

final class SignalHub {
  final LinkedHashMap<WebSocket, PeerInfo?> _sessions = LinkedHashMap();
  final Map<String, Set<WebSocket>> _rooms = {};

  void attach(WebSocket ws, IOWebSocketChannel channel) {
    _sessions[ws] = null;

    channel.stream.listen(
      (raw) => _onMessage(ws, channel, raw),
      onDone: () => _dispose(ws),
      onError: (_) => _dispose(ws),
      cancelOnError: true,
    );
  }

  void _onMessage(WebSocket ws, IOWebSocketChannel channel, dynamic raw) {
    late final Map<String, Object?> msg;
    try {
      msg = Map<String, Object?>.from(jsonDecode(raw as String) as Map);
    } catch (_) {
      channel.sink.add(jsonEncode({'type': 'error', 'message': 'invalid_json'}));
      return;
    }

    switch (msg['type'] as String?) {
      case 'identify':
        _identify(
          ws,
          channel,
          peerId: msg['peerId'] as String?,
          displayName: msg['displayName'] as String?,
        );
        break;
      case 'leaveRoom':
        _leave(ws);
        break;
      case 'joinRoom':
        _join(ws, channel, roomId: msg['roomId'] as String?);
        break;
      case 'signal':
        _relay(ws, channel, to: msg['to'] as String?, body: msg['body']);
        break;
      default:
        channel.sink.add(jsonEncode({'type': 'error', 'message': 'unknown_type'}));
    }
  }

  void _identify(WebSocket ws, IOWebSocketChannel channel,
      {String? peerId, String? displayName}) {
    if (peerId == null || peerId.isEmpty) {
      channel.sink.add(jsonEncode({'type': 'error', 'message': 'peerId_required'}));
      return;
    }
    final existing = _sessions[ws];
    if (existing != null) {
      existing.peerId = peerId;
      existing.displayName = displayName ?? existing.displayName;
    } else {
      _sessions[ws] = PeerInfo(
        socket: ws,
        channel: channel,
        peerId: peerId,
        displayName: displayName ?? 'Peer',
        roomId: '',
      );
    }
    channel.sink.add(jsonEncode({'type': 'identified'}));
  }

  void _join(WebSocket ws, IOWebSocketChannel channel, {String? roomId}) {
    final peer = _sessions[ws];
    if (peer == null || peer.peerId.isEmpty) {
      channel.sink.add(jsonEncode({'type': 'error', 'message': 'identify_first'}));
      return;
    }
    if (roomId == null || roomId.trim().length < 3) {
      channel.sink.add(jsonEncode({'type': 'error', 'message': 'invalid_room'}));
      return;
    }

    final nextRoom = roomId.trim().toUpperCase();
    _leave(ws);

    peer.roomId = nextRoom;
    _rooms.putIfAbsent(nextRoom, () => {}).add(ws);

    final peers =
        _rooms[nextRoom]
            ?.map((s) => _sessions[s])
            .whereType<PeerInfo>()
            .map(
              (p) => {'peerId': p.peerId, 'displayName': p.displayName},
            )
            .toList(growable: false) ??
        [];

    for (final otherWs in _rooms[nextRoom] ?? {}) {
      if (otherWs == ws) continue;
      final otherPeer = _sessions[otherWs];
      if (otherPeer == null) continue;
      otherPeer.send({
        'type': 'peerJoined',
        'peer': {'peerId': peer.peerId, 'displayName': peer.displayName},
      });
    }

    peer.send({
      'type': 'roomJoined',
      'roomId': nextRoom,
      'peers': peers,
    });
  }

  void _leave(WebSocket ws) {
    final peer = _sessions[ws];
    if (peer == null || peer.roomId.isEmpty) return;

    final roomId = peer.roomId;
    final leavingId = peer.peerId;
    peer.roomId = '';

    final room = _rooms[roomId];
    if (room == null) return;

    for (final other in room) {
      if (other == ws) continue;
      _sessions[other]?.send({'type': 'peerLeft', 'peerId': leavingId});
    }

    room.remove(ws);
    if (room.isEmpty) _rooms.remove(roomId);
  }

  void _relay(WebSocket ws, IOWebSocketChannel channel, {String? to, Object? body}) {
    final from = _sessions[ws];
    if (from == null || from.roomId.isEmpty) {
      channel.sink.add(jsonEncode({'type': 'error', 'message': 'not_in_room'}));
      return;
    }
    if (to == null || to.isEmpty || body is! Map) {
      channel.sink.add(jsonEncode({'type': 'error', 'message': 'bad_signal'}));
      return;
    }

    WebSocket? targetWs;
    for (final candidate in _rooms[from.roomId] ?? {}) {
      final p = _sessions[candidate];
      if (p?.peerId == to) {
        targetWs = candidate;
        break;
      }
    }
    if (targetWs == null) {
      channel.sink.add(jsonEncode({'type': 'error', 'message': 'peer_not_in_room'}));
      return;
    }

    final target = _sessions[targetWs];
    target?.send({
      'type': 'signal',
      'from': from.peerId,
      'body': body,
    });
  }

  void _dispose(WebSocket ws) {
    _leave(ws);
    _sessions.remove(ws);
  }
}
