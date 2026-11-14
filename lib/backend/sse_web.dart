import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'sse.dart';

/// Opens an SSE stream with the browser's EventSource. It reconnects on its
/// own after network errors; the stream errors only when the browser gives
/// up (e.g. an HTTP error status). [headers] can't be set on the web.
Stream<SseEvent> connectSse(Uri uri, {Map<String, String> headers = const {}}) {
  web.EventSource? source;
  late final StreamController<SseEvent> out;
  out = StreamController<SseEvent>(
    onListen: () {
      final s = web.EventSource(uri.toString());
      source = s;
      void forward(String name) {
        s.addEventListener(
          name,
          ((web.MessageEvent e) {
            final d = e.data;
            if (d.isA<JSString>()) out.add((event: name, data: (d as JSString).toDart));
          }).toJS,
        );
      }

      // Tramite names its events; plain "message" for anything else.
      for (final name in ['hello', 'vehicles', 'departures', 'message']) {
        forward(name);
      }
      s.onerror = ((web.Event _) {
        if (s.readyState == web.EventSource.CLOSED && !out.isClosed) {
          out.addError(Exception('SSE connection closed'));
          out.close();
        }
      }).toJS;
    },
    onCancel: () => source?.close(),
  );
  return out.stream;
}
