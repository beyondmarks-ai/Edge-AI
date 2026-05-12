import 'package:edge/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows Firebase setup message when config is unavailable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const EdgeApp(firebaseReady: false, firebaseError: 'missing config'),
    );

    expect(find.text('Firebase setup required'), findsOneWidget);
    expect(find.text('missing config'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });
}
