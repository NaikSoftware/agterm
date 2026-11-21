import '../terminal/vt.dart';

/// The open-check outcomes Chat's write paths are gated on.
class Checks {
  const Checks({this.keys = false, this.paste = false, this.clearInput, this.sendNow = false, this.server = false, this.attached = false,
      this.pastedCommandRuns = false, this.pastedBangSwitches = false, this.timeout = const Duration(seconds: 2)});
  final bool keys, paste; // checks 1, 2
  final (VtKey, int)? clearInput; // check 5: the one key Send repeats to clear; null: an adopted draft is never cleared
  final bool sendNow; // check 12
  final bool server, attached; // checks 1-3 passed on an elis-server row; on a row attached from another Mac
  final bool pastedCommandRuns, pastedBangSwitches; // checks 4, 14
  final Duration timeout; // check 3

  String? get writeBlocked => keys && paste ? null : 'Sending from the phone is not verified yet';

  /// [server]: the remote row is in an elis-server window; otherwise it is attached from another Mac.
  bool unverified({required bool remote, bool server = false}) => remote && !(server ? this.server : attached);

  String? writeBlockedOn({required bool remote, bool server = false}) =>
      writeBlocked ?? (unverified(remote: remote, server: server) ? 'Sending from the phone is not verified on remote sessions yet' : null);
}

// The open-check report, 2026-11-20, Claude 2.1.329.
// elis-server in a container: keys, paste/Send, multiSelect and Bash cards PASS; attached Mac not tested.
const checks = Checks(
  server: true,
  keys: true,
  paste: true,
  clearInput: (VtKey.u, vtCtrl),
  pastedCommandRuns: true,
  pastedBangSwitches: true,
  timeout: Duration(seconds: 2),
);
