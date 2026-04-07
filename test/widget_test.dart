import 'package:flutter_test/flutter_test.dart';

import 'package:scanner_camera/main.dart';

void main() {
  testWidgets('renders live scanner translation shell', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LiveTextScannerApp());
    await tester.pump();

    expect(find.text('Live Camera OCR + Translation'), findsOneWidget);
    expect(find.text('Scanner'), findsOneWidget);
    expect(find.text('Recognized Text'), findsOneWidget);
    expect(find.text('Translate To'), findsOneWidget);
  });
}
