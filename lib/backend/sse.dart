/// Server-Sent Events client: streamed HTTP on mobile and desktop, the
/// browser's EventSource on the web (where HTTP responses aren't streamed).
library;

export 'sse_io.dart' if (dart.library.js_interop) 'sse_web.dart' show connectSse;

/// One SSE event.
typedef SseEvent = ({String event, String data});
