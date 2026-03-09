import 'package:flutter_test/flutter_test.dart';
import 'package:changeui/main.dart';

void main() {
  testWidgets('App loads test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that our app displays the main title.
    expect(find.text('AI BG Remover & Changer'), findsOneWidget);
  });
}
