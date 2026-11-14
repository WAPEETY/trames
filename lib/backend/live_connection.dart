import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'sse.dart';

/// The app's one subscription stream to Tramite. Screens [subscribe] to the
/// topics they show (a stop's departures, a ride, a line, the map area) and
/// cancel when they stop showing them; the connection keeps the union,
/// tells Tramite about changes in batches, and re-subscribes everything after
/// a reconnect. Each subscription gets the topic's current state right away,
/// then every change.
class LiveConnection {
  LiveConnection(this.client);

  final TramiteClient client;

  /// Whether the stream is open (for "live data unavailable" hints).
  final ValueNotifier<bool> connected = ValueNotifier(false);

  final Map<String, Set<_Listener>> _listeners = {};

  /// Last data per topic: late subscribers get it at once.
  final Map<String, Object?> _last = {};
  final Set<String> _toAdd = {};
  final Set<String> _toRemove = {};
  StreamSubscription<SseEvent>? _sse;
  String? _streamId;
  bool _paused = false;
  Timer? _retry;
  Timer? _flush;
  bool _flushing = false;

  /// Follows [topic]: [onData] gets its data (the JSON of the matching GET
  /// endpoint) now if known, and on every change.
  LiveSubscription subscribe(String topic, void Function(Object? data) onData) {
    final l = _Listener(onData);
    final set = _listeners.putIfAbsent(topic, () => {});
    final first = set.isEmpty;
    set.add(l);
    if (first) {
      _toRemove.remove(topic);
      _toAdd.add(topic);
      _scheduleFlush();
    } else if (_last.containsKey(topic)) {
      scheduleMicrotask(() => l.active ? l.onData(_last[topic]) : null);
    }
    _ensureOpen();
    return LiveSubscription._(() => _unsubscribe(topic, l));
  }

  void _unsubscribe(String topic, _Listener l) {
    l.active = false;
    final set = _listeners[topic];
    if (set == null || !set.remove(l) || set.isNotEmpty) return;
    _listeners.remove(topic);
    _last.remove(topic);
    if (!_toAdd.remove(topic)) _toRemove.add(topic);
    _scheduleFlush();
  }

  /// App in the background: close the stream (subscriptions are kept).
  void pause() {
    _paused = true;
    _close();
  }

  /// Back in the foreground: reopen and re-subscribe.
  void resume() {
    _paused = false;
    _ensureOpen();
  }

  void _ensureOpen() {
    if (_paused || _sse != null || _retry != null || _listeners.isEmpty) return;
    _sse = connectSse(client.uri('/v1/stream'), headers: kHeaders).listen(
      _onEvent,
      onError: (Object _) => _dropped(),
      onDone: _dropped,
      cancelOnError: true,
    );
  }

  void _close() {
    _retry?.cancel();
    _retry = null;
    _sse?.cancel();
    _sse = null;
    _streamId = null;
    connected.value = false;
  }

  /// Connection lost: reconnect in a while, then subscribe everything again.
  void _dropped() {
    _close();
    if (_paused || _listeners.isEmpty) return;
    _retry = Timer(const Duration(seconds: 3), () {
      _retry = null;
      _ensureOpen();
    });
  }

  void _onEvent(SseEvent e) {
    final j = jsonDecode(e.data) as Map<String, dynamic>;
    if (e.event == 'hello') {
      _streamId = j['id'] as String;
      connected.value = true;
      // A new stream follows nothing: send the whole current set.
      _toAdd
        ..clear()
        ..addAll(_listeners.keys);
      _toRemove.clear();
      _flushNow();
      return;
    }
    final topic = j['topic'] as String?;
    final set = topic == null ? null : _listeners[topic];
    if (set == null || j['error'] != null) return;
    _last[topic!] = j['data'];
    for (final l in set.toList()) {
      if (l.active) l.onData(j['data']);
    }
  }

  /// Changes made in the same moment go out in one request.
  void _scheduleFlush() {
    _flush?.cancel();
    _flush = Timer(const Duration(milliseconds: 50), _flushNow);
  }

  Future<void> _flushNow() async {
    final id = _streamId;
    if (id == null || _flushing || (_toAdd.isEmpty && _toRemove.isEmpty)) return;
    final add = _toAdd.toList(), remove = _toRemove.toList();
    _toAdd.clear();
    _toRemove.clear();
    _flushing = true;
    try {
      await client.updateTopics(id, add: add, remove: remove);
    } on TramiteException catch (e) {
      if (e.status == 404) {
        _dropped(); // the stream is gone: reconnect, which re-subscribes all
      }
      // 400: a topic Tramite won't serve (e.g. coverage changed): dropped.
    } catch (_) {
      // network: try the same change again shortly
      _toAdd.addAll(add.where(_listeners.containsKey));
      _toRemove.addAll(remove.where((t) => !_listeners.containsKey(t)));
      _scheduleFlush();
    } finally {
      _flushing = false;
    }
    if (_toAdd.isNotEmpty || _toRemove.isNotEmpty) _scheduleFlush();
  }
}

class _Listener {
  _Listener(this.onData);
  final void Function(Object? data) onData;
  bool active = true;
}

/// One screen's interest in one topic; [cancel] when no longer shown.
class LiveSubscription {
  LiveSubscription._(this._cancel);
  final void Function() _cancel;
  bool _done = false;

  void cancel() {
    if (_done) return;
    _done = true;
    _cancel();
  }
}

/// A set of subscriptions kept in step with what a screen shows: [sync] to
/// the topics wanted now, it subscribes the new ones and cancels the rest.
class LiveTopics {
  LiveTopics(this.connection);
  final LiveConnection connection;
  final Map<String, LiveSubscription> _subs = {};

  Iterable<String> get topics => _subs.keys;

  void sync(Map<String, void Function(Object? data)> wanted) {
    for (final t in _subs.keys.where((t) => !wanted.containsKey(t)).toList()) {
      _subs.remove(t)!.cancel();
    }
    wanted.forEach((t, onData) => _subs.putIfAbsent(t, () => connection.subscribe(t, onData)));
  }

  void clear() => sync(const {});
}
