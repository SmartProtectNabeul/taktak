import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../widgets/radar_view.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final TextEditingController _signalCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      _signalCtrl.text = app.signalingUrl;
    });
  }

  @override
  void dispose() {
    _signalCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('TakTak', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.05)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: [
                Text(
                  store.isOnlineTransport ? 'Online • WebRTC signaling' : 'Offline • BLE scan',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                Switch.adaptive(
                  value: store.isOnlineTransport,
                  activeTrackColor: const Color(0xFF66FCF1),
                  inactiveTrackColor: Colors.white24,
                  onChanged: (v) => Future.microtask(() => store.userFlippedOnlineToggle(v)),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          _sidebar(context, store),
          Expanded(child: _stack(context, store)),
        ],
      ),
    );
  }

  Widget _sidebar(BuildContext context, AppState store) {
    return SizedBox(
      width: 280,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0x801F2833), border: Border(right: BorderSide(color: Colors.white10))),
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            _accountChip(context, store),
            const Divider(color: Colors.white12),
            const Text('SIGNALLING SERVER', style: TextStyle(color: Colors.grey, fontSize: 11)),
            TextField(controller: _signalCtrl, decoration: const InputDecoration(hintText: 'ws://127.0.0.1:8787/')),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                child: const Text('Save websocket URL'),
                onPressed: () => store.persistSignalingUrl(_signalCtrl.text.trim()),
              ),
            ),
            if (store.isOnlineTransport) ...[
              const Divider(color: Colors.white12),
              ListTile(
                leading: const Icon(Icons.meeting_room),
                title: const Text('Current room'),
                subtitle: Text(store.currentRoom ?? 'None'),
                onTap: () => _roomDialog(context, store),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: store.leaveRoom, child: const Text('Disconnect room')),
              ),
              const Text('PICK SEND TARGET', style: TextStyle(color: Colors.grey, fontSize: 11)),
              if (store.roomPeers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('Waiting for collaborators…'),
                ),
              ...store.roomPeers.map((p) {
                final sel = store.selectedSendPeerId == p.peerId;
                return ChoiceChip(
                  label: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: Text(p.displayName, overflow: TextOverflow.ellipsis),
                  ),
                  selected: sel,
                  onSelected: (_) => store.selectSendingPeer(p.peerId),
                );
              }),
              const SizedBox(height: 14),
              FilledButton.icon(
                icon: const Icon(Icons.send),
                onPressed:
                    store.isReceivingMode //
                        ? null
                        : () => Future.microtask(store.pickSendFile),
                label: const Text('Pick file → selected peer'),
              ),
            ],
            if (!store.isOnlineTransport)
              TextButton.icon(
                onPressed: () => Future.microtask(store.startBleSweep),
                icon: const Icon(Icons.bluetooth_connected),
                label: const Text('Refresh BLE radios'),
              ),
            const Divider(color: Colors.white12),
            ToggleButtons(
              isSelected: [store.isReceivingMode, !store.isReceivingMode],
              onPressed: (idx) => store.toggleReceivingMode(idx == 0),
              children: const [Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Receiving')), Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Sending'))],
            ),
          ],
        ),
      ),
    );
  }

  Widget _accountChip(BuildContext context, AppState store) {
    final logged = store.account != null;
    final subtitle =
        logged
            ? Text('Signed in • ${store.account!.email}', overflow: TextOverflow.ellipsis)
            : const Text('Local PBKDF2 credentials');
    return ListTile(
      leading: Icon(Icons.person, color: logged ? const Color(0xFF66FCF1) : Colors.grey),
      title: Text(logged ? store.account!.displayName : 'Account'),
      subtitle: subtitle,
      onTap: () => showAccountSheet(context),
    );
  }

  Future<void> showAccountSheet(BuildContext context) async {
    final mail = TextEditingController();
    final display = TextEditingController();
    final pass = TextEditingController();
    var registerMode = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctxInner, setter) => Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 18),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      registerMode ? 'Create account locally' : 'Unlock saved profile',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 14),
                    if (registerMode) TextField(controller: mail, decoration: const InputDecoration(labelText: 'Email')),
                    TextField(controller: display, decoration: InputDecoration(labelText: registerMode ? 'Display handle' : 'Unused / optional')),
                    TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: () async {
                        final app = ctx.read<AppState>();
                        if (registerMode) {
                          final err = await app.register(mail.text, display.text, pass.text);
                          if (ctxInner.mounted) {
                            Navigator.pop(context);
                          }
                          if (err != null && context.mounted) app.toast(err);
                        } else {
                          final err = await app.login('', pass.text);
                          if (ctxInner.mounted) {
                            Navigator.pop(context);
                          }
                          if (err != null && context.mounted) app.toast(err);
                        }
                      },
                      child: Text(registerMode ? 'Register' : 'Sign in'),
                    ),
                    TextButton(
                      onPressed: () => setter(() => registerMode = !registerMode),
                      child: Text(registerMode ? 'Have an identity? Unlock' : 'Need an account? Create'),
                    ),
                    if (context.read<AppState>().account != null)
                      TextButton(
                        child: const Text('Sign out', style: TextStyle(color: Colors.redAccent)),
                        onPressed: () {
                          Navigator.pop(context);
                          context.read<AppState>().logout();
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    mail.dispose();
    display.dispose();
    pass.dispose();
  }

  Future<void> _roomDialog(BuildContext context, AppState app) async {
    final ctrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('TakTak room'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Room passphrase')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Dismiss')),
          TextButton(onPressed: () => ctrl.text = app.randomInviteCode(), child: const Text('Random')),
          FilledButton(
            child: const Text('Connect'),
            onPressed: () {
              Navigator.pop(ctx);
              app.joinRoom(ctrl.text);
            },
          ),
        ],
      ),
    );

    ctrl.dispose();
  }

  Widget _stack(BuildContext context, AppState store) {
    return Stack(
      children: [
        Center(child: RadarView(devices: store.radarDots)),
        if (store.radarDots.isEmpty)
          const Positioned(
            bottom: 28,
            left: 0,
            right: 0,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 48),
              child: Text(
                'No dots yet.\nBluetooth: stay offline and radios will populate.\nWebRTC: go online & join one shared room phrase.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        if (store.incomingTransfers.isNotEmpty)
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(34),
              child: SizedBox(width: 360, child: _transferColumn(store)),
            ),
          ),
        if (kDebugMode)
          Positioned(
            top: 28,
            right: 44,
            child: TextButton(
              onPressed: () => context.read<AppState>().injectDebugIncomingInvite(),
              child: const Text('Simulate inbound'),
            ),
          ),
      ],
    );
  }

  Widget _transferColumn(AppState store) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children:
          store.incomingTransfers.take(5).map((xfer) => _transferCard(store, xfer)).toList(growable: false),
    );
  }

  Widget _transferCard(AppState store, IncomingTransfer xfer) {
    late final Widget footer;
    if (xfer.phase == TransferPhase.awaitingAccept) {
      footer = Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(onPressed: () => store.refuseInvite(xfer.transferId), child: const Text('Refuse')),
          const SizedBox(width: 14),
          FilledButton(onPressed: () => store.acceptInvite(xfer.transferId), child: const Text('Accept')),
        ],
      );

    }



    else if (xfer.phase == TransferPhase.transferring || xfer.phase == TransferPhase.finished) {



      footer = Column(




        crossAxisAlignment: CrossAxisAlignment.stretch,





        children: [






          Padding(




            padding: const EdgeInsets.only(top: 6),




            child: LinearProgressIndicator(value: xfer.progress01.clamp(0, 1)),




          ),

          if (xfer.savedPath != null) Text(xfer.savedPath!, style: const TextStyle(fontSize: 11)),
        ],
      );
    } else {
      footer = const SizedBox.shrink();



    }



    return Card(
      margin: const EdgeInsets.only(bottom: 12),

      color: Colors.black.withValues(alpha: 0.66),




      child: Padding(




        padding: const EdgeInsets.all(15),




        child: Column(




          crossAxisAlignment: CrossAxisAlignment.start,




          children: [




            Text('Incoming • ${xfer.remoteName}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              '${xfer.fileName} · ${xfer.sizeMB.toStringAsFixed(2)} MiB · ${xfer.phase.name}',
              style: const TextStyle(color: Colors.white38, fontSize: 13),




            ),
            const SizedBox(height: 12),
            footer,
          ],

        ),

      ),
    );






  }



}

