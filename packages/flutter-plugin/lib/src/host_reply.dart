// The hybrid brain's reply stage, as one Dart surface for iOS and Android.
//
// The on-device brain (LocalConverseTransport, replyMode 'host') hears the user and speaks
// with the character's voice; the WORDS come from a HostReplySource — typically bitHuman's
// relay text brain (RelayTextBrain: a cheap cloud text model, the persona held server-side)
// or the app's own server. The transport turns the native brain's events into calls here:
//
//   reply_request {id, text, continuation, messages}  → reply(HostReplyRequest)  (stream it)
//   reply_cancel  {id, heardChars}                     → cancelled(id, heardChars) (barge-in;
//                                                         during OR after the stream)
//   the brain is ready (greet)                         → greeting()   (spoken verbatim)
//   the session ends                                   → close()
//
// Apache-2.0; (c) bitHuman.

/// One reply the on-device brain asks for.
class HostReplyRequest {
  const HostReplyRequest({
    required this.id,
    required this.text,
    this.continuation = false,
    this.messages = const [],
    this.maxTokens = 0,
  });

  /// The brain's request id; [HostReplySource.cancelled] names it.
  final int id;

  /// The user's turn, as the on-device speech-to-text heard it (or typed text).
  final String text;

  /// True when the user went on after a pause: the recognizer had split ONE
  /// utterance, the brain cancelled the reply to the first part, and [text] is the
  /// WHOLE utterance. It replaces the previous request's turn (a source with its
  /// own memory must not keep both).
  final bool continuation;

  /// The brain's own prompt for a source that keeps no memory: `role` / `content`
  /// maps — the system prompt, the bounded history, then this turn. A server that
  /// holds the persona and the memory (RelayTextBrain) ignores it.
  final List<Map<String, String>> messages;

  /// The brain's reply budget in tokens (0 = unspecified).
  final int maxTokens;
}

/// Where the hybrid brain's words come from. Implement [reply]; the rest is optional.
abstract class HostReplySource {
  HostReplySource();

  /// A source from a plain function of the brain's prompt (no memory of its own, no
  /// greeting): e.g. a canned stub in a test harness, or a call to the app's server
  /// that sends the whole prompt every turn.
  factory HostReplySource.fromMessages(
          Stream<String> Function(List<Map<String, String>> messages) reply) =
      _MessagesSource;

  /// Stream the reply to [request], in pieces of any size. The transport cancels the
  /// subscription when the brain drops the reply (barge-in, a new turn, stop); a
  /// stream error ends the turn with the brain's fallback line if nothing was spoken.
  Stream<String> reply(HostReplyRequest request);

  /// The person cut in on the reply to request [id] — while it streamed or after,
  /// while the voice was still speaking it — having heard [heardChars] of its text
  /// (Unicode code points; null = unknown). A source with memory keeps only what was
  /// heard. Called before the transport cancels the reply's subscription.
  void cancelled(int id, {int? heardChars}) {}

  /// The character's opening line, spoken verbatim when the brain is ready (null =
  /// no greeting). Never turned into a user turn.
  Future<String?> greeting() async => null;

  /// The session is over (the transport stopped): release the connection.
  Future<void> close() async {}
}

class _MessagesSource extends HostReplySource {
  _MessagesSource(this._reply);
  final Stream<String> Function(List<Map<String, String>> messages) _reply;
  @override
  Stream<String> reply(HostReplyRequest request) => _reply(request.messages);
}
