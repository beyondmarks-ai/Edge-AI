import 'package:edge/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('auth flow shows sign in, sign up, and dashboard skip', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EdgeApp());

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);

    await tester.tap(find.text('Sign Up'));
    await tester.pumpAndSettle();

    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Full name'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.byIcon(Icons.dashboard_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Attendence'), findsOneWidget);
    expect(find.text('Rag'), findsOneWidget);
    expect(find.text('Setting'), findsOneWidget);

    await tester.tap(find.text('Attendence'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Track daily presence, class records, and status updates here.',
      ),
      findsOneWidget,
    );
  });
}
