import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sse.dart';

/// Opens an SSE stream. Cancelling the subscription closes the connection;
/// the stream ends (or errors) when the server or network drops it, and the
/// caller decides whether to reconnect.
Stream<SseEvent> connectSse(Uri uri, {Map<String, String> headers = const {}}) {
  final client = http.Client();
  late final StreamController<SseEvent> out;
  StreamSubscription<String>? lines;
  out = StreamController<SseEvent>(
    onListen: () async {
      try {
        final req = http.Request('GET', uri)
          ..headers.addAll(headers)
          ..headers['Accept'] = 'text/event-stream';
        final res = await client.send(req);
        if (res.statusCode != 200) {
          final body = await res.stream.bytesToString();
          throw Exception('SSE ${res.statusCode}: $body');
        }
        var event = 'message';
        final data = StringBuffer();
        lines = res.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            if (line.isEmpty) {
              if (data.isNotEmpty) out.add((event: event, data: data.toString()));
              event = 'message';
              data.clear();
            } else if (line.startsWith('event:')) {
              event = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              if (data.isNotEmpty) data.write('\n');
              data.write(line.substring(5).trimLeft());
            } // id:, retry: and ": comments" (heartbeats) are ignored
          },
          onError: (Object e) => out.isClosed ? null : out.addError(e),
          onDone: () => out.isClosed ? null : out.close(),
          cancelOnError: true,
        );
      } catch (e) {
        if (!out.isClosed) {
          out.addError(e);
          await out.close();
        }
        client.close();
      }
    },
    onCancel: () async {
      await lines?.cancel();
      client.close();
    },
  );
  return out.stream;
}
