import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  test('parses the JSON share contract including its session identifier', () {
    final snapshot = ConversationSnapshot.fromJsonMap({
      'session_id': 'source-session',
      'messages': [
        {'role': 'user', 'content': 'Hello'},
        {'role': 'assistant', 'content': 'World'},
      ],
    });

    expect(snapshot.sessionId, 'source-session');
    expect(snapshot.messages.map((message) => message.content), ['Hello', 'World']);
  });

  test('imports only safe user and assistant text messages', () {
    final snapshot = ConversationSnapshot.fromJsonMap({
      'session_id': 'source-session',
      'messages': [
        {'role': 'user', 'content': 'Keep'},
        {'role': 'tool', 'content': 'Drop'},
        {'role': 'assistant', 'content': '<think>Drop</think>'},
        {'role': 'assistant', 'content': 'Keep too'},
      ],
    });

    expect(snapshot.importableMessages.map((message) => message.content), ['Keep', 'Keep too']);
  });

  test('reimporting a continued session preserves its existing messages', () {
    final app = AppState.createForTest();
    final existing = ChatSession(
      id: 'continued-session',
      title: 'Continued',
      model: 'model',
      messages: [Message(role: 'user', content: 'Existing work')],
    );
    app.sessions.add(existing);

    final imported = app.importSharedMessages(
      existing.id,
      [Message(role: 'assistant', content: 'Imported snapshot')],
    );

    expect(imported, same(existing));
    expect(existing.messages.map((message) => message.content), [
      'Existing work',
      'Imported snapshot',
    ]);
    expect(app.sessions.where((session) => session.id == existing.id), [existing]);
  });
}
